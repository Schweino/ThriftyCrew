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
param([switch]$SelfTest)
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
function Get-DependencyGaps {
  # A file that CALLS a function must be able to resolve it: a real dot-source (not a mention of the lib in
  # a comment or a fixture string), a local definition, or a conditional load. Defect 3 was exactly this
  # distinction, and a substring check cannot make it.
  param([string]$Text, [string]$FnName, [string]$LibLeaf)
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
  if ($defines -or $sourced) { return $null }
  return ("calls $FnName $calls time(s) but neither defines it nor dot-sources $LibLeaf")
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
  if ($fail) { Write-Output "SELF-TEST FAILED ($fail)"; exit 2 }
  Write-Output 'SELF-TEST PASS - four founding defects armed, five clean twins hold'
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
  try { $names = @(& git diff --name-only) | Where-Object { $_ } } finally { $ErrorActionPreference = $prevEap }
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
    if (-not $beforeBytes.Length) { continue }
    $checked++
    if (-not (Test-BomUnchanged -Before $beforeBytes -After $after)) {
      [void]$findings.Add("BOM CHANGED   $n - a read/write pair stripped or added a byte-order mark")
    }
    if ($n -like '*.ps1') {
      $err = $null
      [void][System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$null, [ref]$err)
      if ($err -and $err.Count) { [void]$findings.Add("PARSE FAIL    $n line $($err[0].Extent.StartLineNumber): $($err[0].Message)") }
      else { $parsed++ }
      $txt = [IO.File]::ReadAllText($full)
      $gap = Get-DependencyGaps -Text $txt -FnName 'Read-JsonFile' -LibLeaf 'json-io.ps1'
      if ($gap) { [void]$findings.Add("DEPENDENCY    $n - $gap") }
    }
  }
  Write-Output ("verify-bulk-edit: $checked modified tracked file(s) compared against HEAD; $parsed .ps1 parsed clean; $($findings.Count) finding(s)")
  $findings | ForEach-Object { Write-Output ("  " + $_) }
  Write-GuardComplete -Name 'verify-bulk-edit' -Summary "$($findings.Count) finding(s) over $checked file(s)"
  if ($findings.Count) { exit 1 }
  exit 0
}
finally { Pop-Location }
