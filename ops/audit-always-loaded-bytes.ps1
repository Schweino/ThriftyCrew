<#
  audit-always-loaded-bytes.ps1 - the bytes every ThriftyCrew session loads before it does anything, held by a ratchet.

  WHAT IT COUNTS. The ThriftyCrew side of the always-loaded budget (W6.6 of
  design\PLAN-brain-consults-on-code-and-analysis-2026-09-22.md): the root CLAUDE.md plus every .claude\rules\**\*.md
  file the Claude Code loader treats as UNCONDITIONAL, read through lib\rule-scope.ps1's Get-RuleScope, the same reading
  ops\audit-rule-currency.ps1 uses. A file with no paths: key, one whose paths: resolves to nothing or only **, and one
  whose only scope key is inert (globs:, alwaysApply:, a mis-cased Paths:) all load in every session and all count. A file
  scoped by a live paths: key is listed and not counted, because it loads only when a matching file is touched.

  WHY (2026-09-25, Brad's D2 ruling, "Keep A, ratchet the size (Recommended)"). Option A loads every rules file in full,
  and nothing budgeted what that costs: a ThriftyCrew session started with 155,320 B of instructions on 2026-09-22 and
  181,413 B on 2026-09-25 (the option B measurement, rows on branch experiment/rules-split-option-b). Option B, which
  would have cut it, was built and missed all three of W2.3's bars. So the size is kept and ratcheted: a TC edit that
  GROWS these files is caught at the TC push that makes it, and the number can only be worked downwards.

  A BYTE IS COUNTED AS GIT STORES IT: a CR immediately before an LF is not counted. A fresh checkout is CRLF and main is
  LF (CLAUDE.md), so counting disk bytes raw would turn a clean CRLF worktree red over line endings, not growth. Every
  other byte counts, a BOM included. The mark is therefore comparable to `git cat-file -s origin/main:<path>` summed.

  A RATCHET THAT FAILS ONLY ON A RISE, in the exemplar's shape (ops\audit-write-only-reports.ps1). A plain run never
  writes its mark: run-gates runs this on every pre-push, and a rewrite there would dirty the checkout being pushed
  without riding the push. A fall is SPOKEN ("ratchet CAN tighten") and the committed mark KEPT; -Tighten records a fall
  through lib\ratchet.ps1's Test-RatchetMove, whose plausibility bar refuses a fall to zero or one over 60% in a run;
  -Accept records the current total whatever it is. A MISSING OR UNREADABLE MARK IS EXIT 3 on a plain run, never a
  write: a gate that minted its own mark would bless whatever the checkout happened to hold.

  WHAT IT DOES WHEN THE PRODUCER STOPS (ops-and-gates.md, every threshold). The rules files are the producer. If they
  shrink or vanish the count falls and this says "can tighten"; it cannot fire on nothing happening, and does not need
  to, because the budget is an upper bound on a cost. A missing CLAUDE.md is exit 3, not a fall.

  SCOPE OF A CLEAN REPORT: UNSOUND for the whole budget, COMPLETE for a rise in what it counts. It counts only the two
  ThriftyCrew-side sources the plan names. It cannot see the user-scope ~/.claude/CLAUDE.md, C:\Codex\CLAUDE.md,
  MEMORY.md, a CLAUDE.local.md, an @import inside CLAUDE.md (none today), a nested CLAUDE.md loaded on traversal, or a
  paths: file whose trigger fires in most sessions; the brain's check-skills reports the machine-wide sum per project
  from the InstructionsLoaded log for exactly that reason. A clean report here therefore says the TC files did not grow,
  never that a session's start is within budget. A finding (a rise) is real because the count IS the bytes: a rise is a
  rise of what those files hold, and the cure is to shorten the text or move it to where it is read on demand.

  Usage:
    .\audit-always-loaded-bytes.ps1            measure, report per file, ratchet against ops\out\always-loaded-bytes-baseline.json; writes nothing
    .\audit-always-loaded-bytes.ps1 -Tighten   the same, and record a believable FALL as the new mark
    .\audit-always-loaded-bytes.ps1 -Accept    record the CURRENT total as the mark, whatever it is (a deliberate growth goes here, with its reason in the commit)
    .\audit-always-loaded-bytes.ps1 -SelfTest  frozen fixtures, plus this script's live path run as a child against a temp tree

  Exit: 0 = at or under the mark. 2 = ABOVE the mark, or -Tighten refused an implausible fall. 3 = could not evaluate
  (no CLAUDE.md, no mark, or an unreadable one).
#>
# The self-test builds every tree it reads under %TEMP% and runs this file as a child, so it reads nothing else of this repo.
# gate-inputs: lib\guard-contract.ps1, lib\ratchet.ps1, lib\lf-write.ps1, lib\rule-scope.ps1
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param([switch]$SelfTest, [switch]$Accept, [switch]$Tighten, [string]$Root = '', [string]$BaselineFile = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ratchet.ps1')      # Test-RatchetMove: the verdict, and the plausibility bar a -Tighten must clear
. (Join-Path $repo 'lib\lf-write.ps1')     # Write-TcLfFile: the mark is tracked and stored eol=lf
. (Join-Path $repo 'lib\rule-scope.ps1')   # Get-RuleScope: the loader's reading of a rules file's scope, shared with audit-rule-currency

$script:ALB_NAME = 'always-loaded-bytes'
$script:ALB_NOTE = 'High-water mark for the always-loaded budget ratchet, ThriftyCrew side (W6.6, Brad''s D2 ruling 2026-09-25: keep option A, ratchet the size). Bytes as git stores them, of CLAUDE.md plus every unconditional .claude/rules file. This number may only go DOWN; a deliberate growth is recorded with -Accept and its reason in the commit.'

function Get-LoadedByteCount {
  <# The bytes git stores for this file's content: every byte, less each CR that sits immediately before an LF. Pure. #>
  param([byte[]]$Bytes)
  if ($null -eq $Bytes) { return 0 }
  $n = $Bytes.Length
  for ($i = 0; $i -lt $Bytes.Length - 1; $i++) {
    if ($Bytes[$i] -eq 13 -and $Bytes[$i + 1] -eq 10) { $n-- }
  }
  return $n
}

function Get-AlwaysLoadedSet {
  <# The always-loaded files under one checkout root, as rows { path; bytes; scope; why; counted }, the repo-relative
     path written with forward slashes and the rows in ordinal path order (CLAUDE.md first). Returns
     { rows; total; counted; skipped; claude_md } where total sums the counted rows. #>
  param([string]$RootFull)
  $rows = New-Object System.Collections.Generic.List[object]
  $cm = Join-Path $RootFull 'CLAUDE.md'
  $hasCm = [IO.File]::Exists($cm)
  if ($hasCm) {
    $rows.Add([pscustomobject]@{ path = 'CLAUDE.md'; bytes = (Get-LoadedByteCount ([IO.File]::ReadAllBytes($cm))); scope = 'unconditional'; why = 'the project CLAUDE.md'; counted = $true })
  }
  $rd = Join-Path $RootFull '.claude\rules'
  $found = New-Object System.Collections.Generic.List[string]
  if ([IO.Directory]::Exists($rd)) {
    foreach ($f in [IO.Directory]::EnumerateFiles($rd, '*', [IO.SearchOption]::AllDirectories)) {
      if ([IO.Path]::GetExtension($f) -ne '.md') { continue }   # ordinal-insensitive in PS; the loader reads .md files
      [void]$found.Add($f)
    }
  }
  $rel = New-Object System.Collections.Generic.List[string]
  foreach ($f in $found) { [void]$rel.Add(($f.Substring($RootFull.TrimEnd('\').Length + 1) -replace '\\', '/')) }
  $relArr = $rel.ToArray()
  [Array]::Sort($relArr, [StringComparer]::Ordinal)
  foreach ($r in $relArr) {
    $full = Join-Path $RootFull ($r -replace '/', '\')
    $bytes = [IO.File]::ReadAllBytes($full)
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $sc = Get-RuleScope -Text $text
    $isU = ($sc.Scope -eq 'unconditional')
    $why = [string]$sc.Why
    if (@($sc.InertKeys).Count) { $why = $why + '; inert key ' + (@($sc.InertKeys) -join ',') }
    $rows.Add([pscustomobject]@{ path = $r; bytes = (Get-LoadedByteCount $bytes); scope = [string]$sc.Scope; why = $why; counted = $isU })
  }
  $total = 0; $nc = 0; $ns = 0
  foreach ($x in $rows) { if ($x.counted) { $total += [int]$x.bytes; $nc++ } else { $ns++ } }
  return [pscustomobject]@{ rows = $rows.ToArray(); total = $total; counted = $nc; skipped = $ns; claude_md = $hasCm }
}

function Get-AlwaysLoadedVerdict {
  <# The ratchet's answer for a total against its mark: { Verdict; Code; Message }. rose is exit 2; held, a believable
     fall and an implausible fall are all exit 0 here (a plain run never writes, so a fall of either kind is only
     spoken; -Tighten decides what to do with it). One function, so the fixture drives the rule the live path runs. #>
  param([int]$Bytes, [int]$Mark)
  $m = Test-RatchetMove -Name $script:ALB_NAME -Count $Bytes -Baseline $Mark
  $code = 0
  if ($m.Verdict -eq 'rose') { $code = 2 }
  return [pscustomobject]@{ Verdict = [string]$m.Verdict; Code = $code; Message = [string]$m.Message }
}

if ($SelfTest) {
  $script:bad = 0; $script:cases = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    $script:cases++
    if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  $utf8 = New-Object Text.UTF8Encoding($false)
  $wt = Join-Path $env:TEMP ('alb-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $wt -ErrorAction Stop | Out-Null
  try {
    # ---- the byte count ----
    $crlf = [byte[]](97, 13, 10, 98, 13, 10)
    T 'MUST FIRE  a CRLF file counts as the LF bytes git stores (a\r\nb\r\n is 4, not 6), so a fresh CRLF checkout is not red over line endings' `
      ((Get-LoadedByteCount $crlf) -eq 4) ([string](Get-LoadedByteCount $crlf))
    $loneCr = [byte[]](97, 13, 98, 10)
    T 'CLEAN TWIN  a CR that is not before an LF still counts, and so does the LF (a\rb\n is 4)' `
      ((Get-LoadedByteCount $loneCr) -eq 4) ([string](Get-LoadedByteCount $loneCr))
    $bomd = [byte[]](0xEF, 0xBB, 0xBF, 120, 10)
    T 'CLEAN TWIN  a BOM counts: the loader reads the file''s bytes, and only CR-before-LF is a checkout artefact (5 B)' `
      ((Get-LoadedByteCount $bomd) -eq 5) ([string](Get-LoadedByteCount $bomd))

    # ---- the set: which files count ----
    $fx = Join-Path $wt 'set'
    New-Item -ItemType Directory -Path (Join-Path $fx '.claude\rules\sub') -Force -ErrorAction Stop | Out-Null
    [IO.File]::WriteAllText((Join-Path $fx 'CLAUDE.md'), "# project`n", $utf8)                                   # 10 B
    [IO.File]::WriteAllText((Join-Path $fx '.claude\rules\a.md'), "# a rule body`n", $utf8)                      # 14 B
    [IO.File]::WriteAllBytes((Join-Path $fx '.claude\rules\sub\b.md'), [byte[]](35, 32, 98, 13, 10))             # "# b\r\n" = 4 B counted
    [IO.File]::WriteAllText((Join-Path $fx '.claude\rules\c.md'), "---`npaths:`n  - `"grocery/**`"`n---`n# scoped`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $fx '.claude\rules\d.md'), "---`nglobs: grocery/**`n---`n# d`n", $utf8)  # 30 B, inert key
    [IO.File]::WriteAllText((Join-Path $fx '.claude\rules\notes.txt'), "not a rules file`n", $utf8)
    $s = Get-AlwaysLoadedSet -RootFull $fx
    $paths = @($s.rows | ForEach-Object { $_.path }) -join ','
    T 'the set is CLAUDE.md first, then every .md below .claude/rules in ordinal order, and no .txt' `
      ($paths -eq 'CLAUDE.md,.claude/rules/a.md,.claude/rules/c.md,.claude/rules/d.md,.claude/rules/sub/b.md') $paths
    $cRow = @($s.rows | Where-Object { $_.path -eq '.claude/rules/c.md' })[0]
    T 'MUST NOT FIRE  a rules file scoped by a live paths: key is listed and NOT counted: it loads only when grocery/ is touched' `
      ($null -ne $cRow -and -not $cRow.counted -and $cRow.scope -eq 'scoped') ("counted=$($cRow.counted) scope=$($cRow.scope)")
    $dRow = @($s.rows | Where-Object { $_.path -eq '.claude/rules/d.md' })[0]
    T 'MUST FIRE  a rules file whose only scope key is inert (globs:) IS counted: the loader reads paths: alone, so it loads in every session' `
      ($null -ne $dRow -and $dRow.counted -and $dRow.bytes -eq 30 -and $dRow.why -match 'inert key globs') ("counted=$($dRow.counted) bytes=$($dRow.bytes) why=$($dRow.why)")
    T 'the total is the counted rows only: 10 + 14 + 30 + 4 = 58 B over 4 files, 1 skipped' `
      ($s.total -eq 58 -and $s.counted -eq 4 -and $s.skipped -eq 1 -and $s.claude_md) ("total=$($s.total) counted=$($s.counted) skipped=$($s.skipped)")
    $empty = Join-Path $wt 'empty'
    New-Item -ItemType Directory -Path $empty -ErrorAction Stop | Out-Null
    $e = Get-AlwaysLoadedSet -RootFull $empty
    T 'a tree with no CLAUDE.md reports it absent and counts 0, so the live path can say BLIND rather than a clean 0' `
      (-not $e.claude_md -and $e.total -eq 0 -and @($e.rows).Count -eq 0) ("claude_md=$($e.claude_md) total=$($e.total)")

    # ---- the verdict, AT the mark and one byte past it (ops-and-gates.md, backlog I196) ----
    $v0 = Get-AlwaysLoadedVerdict -Bytes 155505 -Mark 155505
    T 'CLEAN TWIN  AT the mark (155,505 B against a mark of 155,505 B) holds with exit 0' ($v0.Verdict -eq 'held' -and $v0.Code -eq 0) ("$($v0.Verdict) code=$($v0.Code)")
    $v1 = Get-AlwaysLoadedVerdict -Bytes 155506 -Mark 155505
    T 'MUST FIRE  ONE BYTE PAST the mark (155,506 B against 155,505 B) is a rise, exit 2' ($v1.Verdict -eq 'rose' -and $v1.Code -eq 2) ("$($v1.Verdict) code=$($v1.Code)")
    $v2 = Get-AlwaysLoadedVerdict -Bytes 155504 -Mark 155505
    T 'MUST NOT FIRE  one byte UNDER the mark is a fall, exit 0: a fall never fails' ($v2.Verdict -eq 'tightened' -and $v2.Code -eq 0) ("$($v2.Verdict) code=$($v2.Code)")
    $v3 = Get-AlwaysLoadedVerdict -Bytes 0 -Mark 155505
    T 'MUST NOT FIRE  a fall to 0 is implausible and exit 0 on a plain run; the mark is kept, never lowered to a blind 0' ($v3.Verdict -eq 'implausible' -and $v3.Code -eq 0) ("$($v3.Verdict) code=$($v3.Code)")

    # ---- THE LIVE PATH, DRIVEN: this script as a child against a temp tree and a temp mark ----
    # The fixture tree is the set above: 58 B counted.
    $noMark = Join-Path $wt 'no-mark.json'
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $fx -BaselineFile $noMark
    $rc0 = $LASTEXITCODE
    T 'a plain run with NO mark exits 3 and writes none: a gate that minted its own mark would bless whatever it found' `
      ($rc0 -eq 3 -and -not (Test-Path -LiteralPath $noMark)) ("rc=$rc0 written=$(Test-Path -LiteralPath $noMark)")
    # MUST FIRE, found by the mutation probe (M9 survived without it): a checkout with no CLAUDE.md is BLIND even when a
    # mark exists, so a broken tree cannot read as a large fall that is merely "can tighten".
    $blEmpty = Join-Path $wt 'baseline-empty.json'
    $null = Write-TcLfFile $blEmpty ([ordered]@{ note = 'fixture'; generated = '2026-01-01T00:00:00'; bytes = 58; files = @() } | ConvertTo-Json -Depth 4)
    $oE = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $empty -BaselineFile $blEmpty)
    $rcE = $LASTEXITCODE
    T 'MUST FIRE  a checkout with NO CLAUDE.md exits 3 BLIND even with a mark, never a fall that reads "can tighten"' `
      ($rcE -eq 3 -and (($oE -join "`n") -match 'BLIND')) ("rc=$rcE")
    $blFx = Join-Path $wt 'baseline.json'
    $seed = [ordered]@{ note = 'fixture note (W6.6 fixture)'; generated = '2026-01-01T00:00:00'; bytes = 60; files = @([ordered]@{ path = 'CLAUDE.md'; bytes = 14 }) } | ConvertTo-Json -Depth 4
    $null = Write-TcLfFile $blFx $seed
    $seedB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($blFx))
    $o1 = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $fx -BaselineFile $blFx
    $rc1 = $LASTEXITCODE
    $o1 = @($o1)
    $same1 = [string]::Equals($seedB64, [Convert]::ToBase64String([IO.File]::ReadAllBytes($blFx)), [StringComparison]::Ordinal)
    T 'a FALL (58 B, mark 60 B) without -Tighten is spoken ("CAN tighten") and NOT written, so a gate run leaves its checkout clean' `
      ($rc1 -eq 0 -and $same1 -and (($o1 -join "`n") -match 'CAN tighten')) ("rc=$rc1 markUnchanged=$same1")
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $fx -BaselineFile $blFx -Tighten
    $rc2 = $LASTEXITCODE
    $b2 = [IO.File]::ReadAllBytes($blFx)
    $cr2 = 0; foreach ($x in $b2) { if ($x -eq 13) { $cr2++ } }
    $bom2 = ($b2.Length -ge 3 -and $b2[0] -eq 0xEF -and $b2[1] -eq 0xBB -and $b2[2] -eq 0xBF)
    $doc2 = $null
    if ($bom2) { $doc2 = [Text.Encoding]::UTF8.GetString($b2, 3, $b2.Length - 3) | ConvertFrom-Json }
    $nFiles2 = if ($doc2) { @($doc2.files).Count } else { -1 }
    T '-Tighten records the fall in the bytes git stores: no CR, the BOM, one trailing LF, bytes=58 over 4 files, and the note kept' `
      ($rc2 -eq 0 -and $cr2 -eq 0 -and $bom2 -and $b2[-1] -eq 10 -and $null -ne $doc2 -and [int]$doc2.bytes -eq 58 -and $nFiles2 -eq 4 -and [string]$doc2.note -eq 'fixture note (W6.6 fixture)') `
      ("rc=$rc2 cr=$cr2 bom=$bom2 bytes=$(if ($doc2) { $doc2.bytes }) files=$nFiles2 note=$(if ($doc2) { $doc2.note })")
    $blRise = Join-Path $wt 'baseline-rise.json'
    $null = Write-TcLfFile $blRise ([ordered]@{ note = 'fixture'; generated = '2026-01-01T00:00:00'; bytes = 57; files = @() } | ConvertTo-Json -Depth 4)
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $fx -BaselineFile $blRise
    $rc3 = $LASTEXITCODE
    T 'CLEAN TWIN  one byte OVER the mark (58 B against 57 B) still fails the child run with exit 2, so not writing on a fall did not disarm the ratchet' ($rc3 -eq 2) ("rc=$rc3")
  } catch {
    $script:cases++; $script:bad++
    Write-Output ('  X     the suite threw: ' + $_.Exception.Message)
  } finally {
    Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction SilentlyContinue
  }
  # A LITERAL LIST KNOWS ITS OWN NUMBER, so a shortfall is a defect rather than a smaller tree (ops-and-gates.md).
  $expected = 17
  if ($script:cases -ne $expected) { Write-Output ("  X     ran $($script:cases) case(s), expected $expected"); $script:bad++ }
  if ($script:bad -eq 0) { Write-Output ("ALWAYS-LOADED-BYTES SELF-TEST PASS ($($script:cases) of $expected cases)"); Write-GuardComplete -Name $script:ALB_NAME -Summary "selftest ok cases=$($script:cases)"; exit 0 }
  Write-Output ("ALWAYS-LOADED-BYTES SELF-TEST FAILED ($($script:bad))"); Write-GuardComplete -Name $script:ALB_NAME -Summary "selftest failed=$($script:bad)"; exit 2
}

# ---- live measurement ----
if (-not $Root) { $Root = $repo }
$rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
$set = Get-AlwaysLoadedSet -RootFull $rootFull
if (-not $set.claude_md) {
  Write-Output ("always-loaded-bytes: BLIND - no CLAUDE.md at $rootFull, so a total here would describe a broken checkout, not the budget")
  Exit-Guard -Name $script:ALB_NAME -Summary 'scanned=0 blind=no-claude-md' -Code 3
}
$blF = if ($BaselineFile) { $BaselineFile } else { Join-Path $here 'out\always-loaded-bytes-baseline.json' }
$blDoc = $null; $base = $null
if (Test-Path -LiteralPath $blF) {
  try { $blDoc = Get-Content -LiteralPath $blF -Raw -Encoding UTF8 | ConvertFrom-Json; $base = [int]$blDoc.bytes } catch { $blDoc = $null; $base = $null }
}
$markBy = @{}
if ($blDoc -and $blDoc.files) { foreach ($mf in @($blDoc.files)) { $markBy[[string]$mf.path] = [int]$mf.bytes } }
Write-Output ("always-loaded-bytes: {0} file(s) load in every ThriftyCrew session, {1:N0} B as git stores them; {2} scoped file(s) listed, not counted" -f $set.counted, $set.total, $set.skipped)
foreach ($r in $set.rows) {
  $tag = if ($r.counted) { 'counted' } else { 'SCOPED ' }
  $delta = ''
  if ($r.counted -and $markBy.ContainsKey([string]$r.path)) {
    $d = [int]$r.bytes - [int]$markBy[[string]$r.path]
    $delta = if ($d -eq 0) { '  (at its mark)' } else { ('  ({0:+#,0;-#,0} B against its mark of {1:N0})' -f $d, $markBy[[string]$r.path]) }
  } elseif ($r.counted -and $blDoc) { $delta = '  (NEW: not in the mark)' }
  Write-Output ('  {0}  {1,9:N0} B  {2}  [{3}]{4}' -f $tag, [int]$r.bytes, $r.path, $r.why, $delta)
}

function Write-AlbBaseline([int]$Total) {
  $note = if ($blDoc -and $blDoc.note) { [string]$blDoc.note } else { $script:ALB_NOTE }
  $files = @($set.rows | Where-Object { $_.counted } | ForEach-Object { [ordered]@{ path = [string]$_.path; bytes = [int]$_.bytes } })
  $json = [ordered]@{ note = $note; generated = (Get-Date).ToString('s'); bytes = $Total; files = $files } | ConvertTo-Json -Depth 4
  $blDir = Split-Path $blF -Parent
  if ($blDir -and -not (Test-Path -LiteralPath $blDir)) { New-Item -ItemType Directory -Force -Path $blDir | Out-Null }
  return (Write-TcLfFile $blF $json)
}
$sum = "scanned=$($set.counted) bytes=$($set.total)"
if ($Accept) {
  $null = Write-AlbBaseline $set.total
  Write-Output ("  mark written: {0:N0} B over {1} file(s). From here the number may only go DOWN. Commit ops\out\always-loaded-bytes-baseline.json." -f $set.total, $set.counted)
  Exit-Guard -Name $script:ALB_NAME -Summary "$sum baseline=$($set.total) accepted" -Code 0
}
if ($null -eq $base) {
  Write-Output ("always-loaded-bytes: COULD NOT EVALUATE - no readable mark at $blF. A plain run never mints one; record it deliberately with -Accept and commit it.")
  Exit-Guard -Name $script:ALB_NAME -Summary "$sum baseline=none" -Code 3
}
$v = Get-AlwaysLoadedVerdict -Bytes $set.total -Mark $base
if ($v.Verdict -eq 'rose') {
  Write-Output ("always-loaded-bytes: RATCHET BROKEN - {0:N0} B now against a mark of {1:N0} B, {2:N0} B more that EVERY ThriftyCrew session pays before its first tool call. Shorten the text you added, move depth to a file read on demand, or, if the growth is the decision, record it with -Accept and say why in the commit." -f $set.total, $base, ($set.total - $base))
  Exit-Guard -Name $script:ALB_NAME -Summary "$sum baseline=$base" -Code 2
}
if ($v.Verdict -eq 'tightened' -or $v.Verdict -eq 'implausible') {
  if ($v.Verdict -eq 'implausible') {
    Write-Output ('  ' + $v.Message + ' (-Accept is this script''s -AcceptDrop.)')
    if ($Tighten) { Exit-Guard -Name $script:ALB_NAME -Summary "$sum baseline=$base refused-to-lower" -Code 2 }
  } elseif ($Tighten) {
    $null = Write-AlbBaseline $set.total
    Write-Output ("  ratchet tightened: {0:N0} B, was {1:N0} B. New mark written - commit it, or it protects only this checkout." -f $set.total, $base)
  } else {
    Write-Output ("  ratchet CAN tighten: {0:N0} B, mark {1:N0} B. NOT written: this may be a pre-push gate, and a rewrite here dirties the checkout being pushed without riding the push. Record it with -Tighten and commit ops\out\always-loaded-bytes-baseline.json." -f $set.total, $base)
  }
}
Write-Output ("always-loaded-bytes: {0:N0} B against a mark of {1:N0} B." -f $set.total, $base)
Exit-Guard -Name $script:ALB_NAME -Summary "$sum baseline=$base" -Code 0
