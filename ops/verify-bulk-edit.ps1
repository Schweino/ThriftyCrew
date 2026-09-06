# verify-bulk-edit.ps1 - the checks a MECHANICAL edit across many files must pass before it is believed.
#
# WHY THIS EXISTS (2026-09-05). A regex sweep converted 608 JSON reads across 191 files. It introduced SIX
# defects, every one of them a silent assumption about structure, and NOT ONE was caught by the transform:
#
#   1. BOM STRIPPED (44 files)   read with utf-8-sig, written with utf-8. Assumed the pair round-trips.
#   2. FIXTURE REWRITTEN         a guard's frozen must-fire literal was itself converted, so the test
#                                reported 0 findings and PASSED. Assumed a literal in a test is code.
#   3. DOT-SOURCE SKIPPED        the "already wired?" check matched a MENTION of the lib inside a fixture
#                                string. Assumed a substring means a dependency is loaded.
#   4. FIXTURE DIR UNREACHABLE   32 BLIND-path assertions died at startup because a copied script could not
#                                see the new lib. Assumed a copied script keeps its dependencies.
#   5. WRONG DEPTH (27 files)    the dot-source hopped one level to the repo root; meal-prep\pipeline is two.
#                                Assumed every script sits one level below the root.
#   6. RETURN UNROLLED           the new reader returned a single-element JSON array as the ELEMENT, because
#                                a PowerShell function unrolls a collection on return. Assumed a wrapper is
#                                equivalent to the pipeline it replaced.
#
# THE POINT IS NOT THAT ASSUMPTIONS WERE MADE. It is that every one of these was SECONDS to check and none
# of them was checked, because none of them was ever WRITTEN DOWN as something that had to be true. Defect 6
# is the one that matters most: the other five failed loudly (a parse error, a missing command, red
# assertions), and 6 would have passed every gate in this estate while quietly returning a different shape
# at 608 call sites.
#
# So this is the enumeration, as a script rather than as a habit. An invariant a person has to remember
# before a big edit is an invariant that gets skipped on the edit that matters. Run it against the working
# tree after any bulk transform, BEFORE running the suite - it is seconds, and it localises the damage that
# the suite can only report as "32 things are red".
#
#   ops\verify-bulk-edit.ps1                 check every modified tracked file against HEAD
#   ops\verify-bulk-edit.ps1 -SelfTest       frozen must-fire fixtures + clean twins
# Exit 0 = every invariant holds. 1 = findings. 2 = self-test regression. 3 = BLIND (nothing to compare).
param([switch]$SelfTest, [switch]$Staged)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$repo = Split-Path $PSScriptRoot -Parent

# ---- the invariants, as functions, so the self-test drives the SAME code the live path does -------------
function Test-BomUnchanged {
  # Reading with a BOM-stripping decoder and writing with one that does not restore it silently removes it.
  # On a .ps1 that is the very bug the sweep was fixing, aimed at our own source.
  param([byte[]]$Before, [byte[]]$After)
  $b = ($Before.Length -ge 3 -and $Before[0] -eq 0xEF -and $Before[1] -eq 0xBB -and $Before[2] -eq 0xBF)
  $a = ($After.Length  -ge 3 -and $After[0]  -eq 0xEF -and $After[1]  -eq 0xBB -and $After[2]  -eq 0xBF)
  return ($b -eq $a)
}
function Test-EolUnchanged {
  # Compared on BYTES. `git show` normalises line endings on the way out, so comparing a working file to a
  # git blob "found" a mass EOL rewrite that had never happened - measured and wrong on 2026-09-05.
  # Both sides here come from the same decoder, so a difference is real. See [[compare-bytes-not-decodings]].
  param([string]$BeforeText, [string]$AfterText)
  $bc = ([regex]::Matches($BeforeText, "`r`n")).Count
  $ac = ([regex]::Matches($AfterText,  "`r`n")).Count
  $bl = ($BeforeText.Length - $BeforeText.Replace("`n",'').Length) - $bc
  $al = ($AfterText.Length  - $AfterText.Replace("`n",'').Length)  - $ac
  # allow line COUNT to change (an edit adds lines); require the STYLE not to flip
  if ($bc -gt 0 -and $ac -eq 0) { return $false }
  if ($bl -gt 0 -and $al -eq 0 -and $bc -eq 0) { return $false }
  if ($bc -eq 0 -and $ac -gt 0 -and $bl -gt 0) { return $false }
  return $true
}
function Get-FrozenLiteralBreaks {
  <# A line the author MARKED as frozen may not change. Returns the marked BEFORE lines that no longer
     appear verbatim in AFTER.

     WHY (2026-09-06, PLAN-top5-2026-09-06 area 4, defect 2 of the 2026-09-05 sweep). A regex sweep
     converted a guard's frozen MUST-FIRE literal - a bare `Get-Content | ConvertFrom-Json` sitting inside
     a fixture STRING, there precisely because it is the bug the guard detects - into the fixed shape. The
     guard then found 0 findings and PASSED. It had stopped being able to fail and nothing said so.

     The estate already marks such lines: `json-readers:allow` tells the READER audit to skip them. What it
     told no TRANSFORM was to leave them alone, because nothing compared them across an edit. This does.

     THE ESCAPE IS AN ENVIRONMENT VARIABLE, NOT THE COMMIT MESSAGE, and that is a measurement rather than a
     preference: a pre-commit hook cannot see the message it is about to commit. Measured on this box -
     .git\COMMIT_EDITMSG holds the PREVIOUS commit's text when pre-commit runs, so reading it would let
     yesterday's wording authorise today's edit. TC_FROZEN_LITERAL must instead NAME what is being changed
     and why, so the escape appears in the run's own transcript. #>
  param([string]$BeforeText, [string]$AfterText)
  $breaks = New-Object System.Collections.ArrayList
  if (-not $BeforeText) { return ,@() }
  $afterLines = @{}
  foreach ($a in ($AfterText -split "`r?`n")) { $afterLines[$a.TrimEnd()] = $true }
  $n = 0
  foreach ($b in ($BeforeText -split "`r?`n")) {
    $n++
    if ($b -notmatch 'frozen-literal|json-readers:allow') { continue }
    # A COMMENT ABOUT the marker is not a marked line. The header of this very file names both markers in
    # prose, and so does audit-json-readers' own documentation.
    if ($b.TrimStart().StartsWith('#')) { continue }
    if (-not $afterLines.ContainsKey($b.TrimEnd())) { [void]$breaks.Add("line $n : " + $b.Trim()) }
  }
  return ,@($breaks.ToArray())
}

function Get-DependencyGaps {
  # A file that CALLS a function must be able to resolve it: a real dot-source (not a mention of the lib in
  # a comment or a fixture string), a local definition, or a conditional load. Defect 3 was exactly this
  # distinction, and a substring check cannot make it.
  param([string]$Text, [string]$FnName, [string]$LibLeaf, [string]$FilePath = '')
  $calls = 0
  foreach ($l in ($Text -split "`r?`n")) {
    $t = $l.TrimStart()
    if ($t.StartsWith('#')) { continue }
    if ($l -match ("(?<![\w-])" + [regex]::Escape($FnName) + "\s") -and $l -notmatch 'function\s') { $calls++ }
  }
  if ($calls -eq 0) { return $null }
  $defines = [bool]([regex]::Match($Text, 'function\s+' + [regex]::Escape($FnName) + '\b').Success)
  $sourced = $false
  foreach ($l in ($Text -split "`r?`n")) {
    $t = $l.TrimStart()
    if ($t.StartsWith('#')) { continue }
    if (($t.StartsWith('. ') -or $t -match '\{\s*\.\s') -and $l -match [regex]::Escape($LibLeaf)) { $sourced = $true; break }
  }
  if ($defines) { return $null }
  if (-not $sourced) { return ("calls $FnName $calls time(s) but neither defines it nor dot-sources $LibLeaf") }
  # A DOT-SOURCE THAT DOES NOT RESOLVE IS NOT WIRING (defect 5). 27 files hopped ONE level to the repo root
  # from two levels down, so each dot-sourced a path that does not exist and threw at STARTUP. Checking only
  # that the LINE is present calls all 27 correctly wired, so evaluate the path the file actually writes.
  # The walk-up form resolves at any depth and needs no check.
  if ($FilePath -and ($Text -notmatch 'while\s*\(')) {
    foreach ($ln2 in ($Text -split "`r?`n")) {
      $t2 = $ln2.TrimStart()
      if ($t2.StartsWith('#') -or -not $t2.StartsWith('. ')) { continue }
      if ($ln2 -notmatch [regex]::Escape($LibLeaf)) { continue }
      if ($ln2 -match 'Split-Path\s+\$PSScriptRoot\s+-Parent') {
        $probe = Join-Path (Join-Path (Split-Path (Split-Path $FilePath -Parent) -Parent) 'lib') $LibLeaf
        if (-not (Test-Path $probe)) { return ("dot-sources $LibLeaf via a single -Parent hop, but nothing resolves at $probe - it will throw at startup") }
      }
    }
  }
  return $null
}

if ($SelfTest) {
  $fail = 0
  $bom = [byte[]](0xEF,0xBB,0xBF,0x41); $nob = [byte[]](0x41)
  if (-not (Test-BomUnchanged -Before $bom -After $nob)) { Write-Output '  PASS  MUST FIRE: a stripped BOM is reported (defect 1, 44 files)' } else { Write-Output '  FAIL  a stripped BOM went unreported'; $fail++ }
  if (Test-BomUnchanged -Before $bom -After $bom) { Write-Output '  PASS  CLEAN TWIN: an unchanged BOM is not a finding' } else { Write-Output '  FAIL  an unchanged BOM was reported'; $fail++ }
  if (-not (Test-EolUnchanged -BeforeText "a`r`nb" -AfterText "a`nb")) { Write-Output '  PASS  MUST FIRE: CRLF flipped to LF is reported' } else { Write-Output '  FAIL  an EOL flip went unreported'; $fail++ }
  if (Test-EolUnchanged -BeforeText "a`r`nb" -AfterText "a`r`nb`r`nc") { Write-Output '  PASS  CLEAN TWIN: adding lines in the SAME style is not an EOL flip' } else { Write-Output '  FAIL  a legitimate added line was called an EOL flip'; $fail++ }
  $g = Get-DependencyGaps -Text "`$x = Read-JsonFile `$p" -FnName 'Read-JsonFile' -LibLeaf 'json-io.ps1'
  if ($g) { Write-Output '  PASS  MUST FIRE: a call with no dot-source and no definition is reported (defect 3)' } else { Write-Output '  FAIL  an unresolvable call went unreported'; $fail++ }
  # CLEAN TWIN: the exact shape that fooled the sweep - the lib named only inside a STRING. Still a gap.
  $g = Get-DependencyGaps -Text "`$x = Read-JsonFile `$p`n`$msg = 'see lib\json-io.ps1 for why'" -FnName 'Read-JsonFile' -LibLeaf 'json-io.ps1'
  if ($g) { Write-Output '  PASS  MUST FIRE: a MENTION of the lib in a string does not count as wiring (the exact defect-3 shape)' } else { Write-Output '  FAIL  a string mention was accepted as a dot-source - defect 3 can recur'; $fail++ }
  $g = Get-DependencyGaps -Text ". (Join-Path `$root 'lib\json-io.ps1')`n`$x = Read-JsonFile `$p" -FnName 'Read-JsonFile' -LibLeaf 'json-io.ps1'
  if (-not $g) { Write-Output '  PASS  CLEAN TWIN: a real dot-source resolves the call' } else { Write-Output '  FAIL  a correctly wired file was reported'; $fail++ }
  $g = Get-DependencyGaps -Text "function Read-JsonFile { }`n`$x = Read-JsonFile `$p" -FnName 'Read-JsonFile' -LibLeaf 'json-io.ps1'
  if (-not $g) { Write-Output '  PASS  CLEAN TWIN: a local definition resolves the call' } else { Write-Output '  FAIL  a self-defining file was reported'; $fail++ }
  $g = Get-DependencyGaps -Text "# Read-JsonFile is what you should use" -FnName 'Read-JsonFile' -LibLeaf 'json-io.ps1'
  if (-not $g) { Write-Output '  PASS  CLEAN TWIN: a comment recommending the function is not a call' } else { Write-Output '  FAIL  a comment was counted as a call'; $fail++ }

  # ---- FROZEN LITERALS (defect 2, added 2026-09-06) ------------------------------------------------------
  # The needle is BUILT rather than written out, or these fixture lines would be frozen literals themselves
  # and this file could never be edited again ([[selftest-greps-its-own-source]]).
  $mk = 'json-readers' + ':' + 'allow'
  $frozenBefore = "  `$bare = (Get-Content `$p -Raw | ConvertFrom-Json).item   # $mk this IS the founding bug`n  `$other = 1"
  $frozenAfter  = "  `$bare = (Read-JsonFile `$p).item   # $mk this IS the founding bug`n  `$other = 1"
  $fb = Get-FrozenLiteralBreaks -BeforeText $frozenBefore -AfterText $frozenAfter
  if ($fb.Count -eq 1) { Write-Output '  PASS  MUST FIRE: a sweep that converted a MARKED frozen literal is reported (defect 2 - the guard that stopped being able to fail)' }
  else { Write-Output "  FAIL  a converted frozen literal went unreported ($($fb.Count))"; $fail++ }
  $fb = Get-FrozenLiteralBreaks -BeforeText $frozenBefore -AfterText ($frozenBefore + "`n  `$added = 2")
  if ($fb.Count -eq 0) { Write-Output '  PASS  CLEAN TWIN: the marked line unchanged while its neighbours change is not a finding' }
  else { Write-Output '  FAIL  an untouched frozen literal was reported'; $fail++ }
  $fb = Get-FrozenLiteralBreaks -BeforeText $frozenBefore -AfterText "  `$other = 1"
  if ($fb.Count -eq 1) { Write-Output '  PASS  MUST FIRE: DELETING a marked line is the same loss as changing it' }
  else { Write-Output '  FAIL  a deleted frozen literal went unreported'; $fail++ }
  # THE MARKER NAMED IN PROSE IS NOT A MARKED LINE. This file's own header names both markers, and so does
  # audit-json-readers' documentation; a guard that freezes its own explanation cannot be edited.
  $fb = Get-FrozenLiteralBreaks -BeforeText "# lines carrying $mk are skipped by the reader audit" -AfterText '# rewritten prose'
  if ($fb.Count -eq 0) { Write-Output '  PASS  CLEAN TWIN: the marker named in a COMMENT is documentation, not a frozen line' }
  else { Write-Output '  FAIL  a comment about the marker was frozen - the documentation could never be edited'; $fail++ }
  # Trailing whitespace is not a change of the literal.
  $fb = Get-FrozenLiteralBreaks -BeforeText $frozenBefore -AfterText ($frozenBefore -replace '(?m)$', '  ')
  if ($fb.Count -eq 0) { Write-Output '  PASS  CLEAN TWIN: trailing whitespace is not a change to the literal' }
  else { Write-Output '  FAIL  trailing whitespace was called a frozen-literal break'; $fail++ }
  if ($fail) { Write-Output "SELF-TEST FAILED ($fail)"; exit 2 }
  Write-Output 'SELF-TEST PASS - every founding defect armed (BOM, EOL, unresolvable call, converted frozen literal) and every clean twin holds'
  exit 0
}

# ---- live path: every modified TRACKED file, compared against HEAD ---------------------------------------
Push-Location $repo
try {
  # NO EAP=STOP AROUND A NATIVE CHILD (2026-09-05). In PS 5.1, git writing a single warning line to stderr
  # becomes a NativeCommandError, and under $ErrorActionPreference='Stop' that is TERMINATING in the CALLER.
  # git emits an autocrlf warning on this repo, so this threw on its first real run. The estate documents
  # this trap in guards.ps1, test-guards.ps1 and check-ad-cycles - and it still caught me, which is the
  # argument for the check existing rather than the habit.
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    # -Staged is what the pre-commit hook passes: judge what is ABOUT TO BE COMMITTED, not another
    # session's unstaged work in a shared tree. Blocking a commit over someone else's in-flight edit is
    # how a gate gets uninstalled.
    $raw = if ($Staged) { @(& git diff --cached --name-only --diff-filter=ACM) } else { @(& git diff --name-only) }
    $names = @($raw) | Where-Object { $_ }
  } finally { $ErrorActionPreference = $prevEap }
  if (-not $names.Count) { Write-Output 'BLIND: no modified tracked files to verify'; Write-GuardComplete -Name 'verify-bulk-edit' -Summary 'nothing to compare'; exit 3 }
  $findings = New-Object System.Collections.ArrayList
  $checked = 0; $parsed = 0
  foreach ($n in $names) {
    $full = Join-Path $repo $n
    if (-not (Test-Path $full)) { continue }
    $after = [IO.File]::ReadAllBytes($full)
    # -- git show gives the BLOB. Use it for the BOM (git does not filter it) and never for line endings.
    # THE BLOB, AS BYTES. Piping git's output through PowerShell would decode and re-encode it, and this
    # script exists to compare bytes - see [[compare-bytes-not-decodings]]. cmd redirects the raw stream.
    $tmp = [IO.Path]::GetTempFileName()
    $prevEap2 = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & cmd /c "git show `"HEAD:$n`" > `"$tmp`" 2>nul" | Out-Null } finally { $ErrorActionPreference = $prevEap2 }
    if (-not (Test-Path $tmp)) { continue }
    $beforeBytes = [IO.File]::ReadAllBytes($tmp)
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    # A NEWLY ADDED file has no HEAD version, so there is nothing to compare BOM or EOL against - but it
    # still must parse and still must resolve what it calls. Skipping it entirely (the first version did)
    # let a brand-new file with a broken dot-source walk straight through the hook.
    $isNew = (-not $beforeBytes.Length)
    $checked++
    if ((-not $isNew) -and (-not (Test-BomUnchanged -Before $beforeBytes -After $after))) {
      [void]$findings.Add("BOM CHANGED   $n - a read/write pair stripped or added a byte-order mark")
    }
    # A MARKED FROZEN LITERAL MAY NOT CHANGE (2026-09-06). Decoded on both sides with the SAME decoder, so
    # a difference is a real difference - the estate's compare-bytes-not-decodings rule applies to the BOM
    # and EOL checks above, and to a text comparison it means "one decoder, both sides".
    if ((-not $isNew) -and (-not $env:TC_FROZEN_LITERAL)) {
      $bStart = if ($beforeBytes.Length -ge 3 -and $beforeBytes[0] -eq 0xEF -and $beforeBytes[1] -eq 0xBB -and $beforeBytes[2] -eq 0xBF) { 3 } else { 0 }
      $beforeText = [Text.Encoding]::UTF8.GetString($beforeBytes, $bStart, $beforeBytes.Length - $bStart)
      $aStart = if ($after.Length -ge 3 -and $after[0] -eq 0xEF -and $after[1] -eq 0xBB -and $after[2] -eq 0xBF) { 3 } else { 0 }
      $afterText = [Text.Encoding]::UTF8.GetString($after, $aStart, $after.Length - $aStart)
      foreach ($fbk in (Get-FrozenLiteralBreaks -BeforeText $beforeText -AfterText $afterText)) {
        [void]$findings.Add("FROZEN LITERAL $n - $fbk")
      }
    }
    if ($n -like '*.ps1') {
      $err = $null
      [void][System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$null, [ref]$err)
      if ($err -and $err.Count) { [void]$findings.Add("PARSE FAIL    $n line $($err[0].Extent.StartLineNumber): $($err[0].Message)") }
      else { $parsed++ }
      $txt = [IO.File]::ReadAllText($full)
      $gap = Get-DependencyGaps -Text $txt -FnName 'Read-JsonFile' -LibLeaf 'json-io.ps1' -FilePath $full
      if ($gap) { [void]$findings.Add("DEPENDENCY    $n - $gap") }
    }
  }
  Write-Output ("verify-bulk-edit: $checked modified tracked file(s) compared against HEAD; $parsed .ps1 parsed clean; $($findings.Count) finding(s)")
  $findings | ForEach-Object { Write-Output ("  " + $_) }
  if (@($findings | Where-Object { $_ -like 'FROZEN LITERAL*' }).Count) {
    Write-Output '  A line marked `json-readers:allow` or `frozen-literal` is a fixture, not code: it is the BUG a'
    Write-Output '  guard detects, written out on purpose. Converting one makes the guard report 0 findings and PASS'
    Write-Output '  while no longer able to fail (2026-09-05, defect 2). If the change is deliberate, say what it is:'
    Write-Output '    $env:TC_FROZEN_LITERAL = ''<file>: why this fixture is being retired''   (then commit, then clear it)'
    Write-Output '  The commit MESSAGE cannot carry this - a pre-commit hook sees the PREVIOUS commit''s message.'
  }
  Write-GuardComplete -Name 'verify-bulk-edit' -Summary "$($findings.Count) finding(s) over $checked file(s)"
  if ($findings.Count) { exit 1 }
  exit 0
}
finally { Pop-Location }
