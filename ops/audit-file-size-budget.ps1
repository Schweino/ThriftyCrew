<#
  audit-file-size-budget.ps1 - no tracked script grows past 1,000 lines unnoticed, held by a per-file ratchet.

  WHAT IT COUNTS. Every tracked .ps1 and .py file (git ls-files), its lines counted as git stores them: one per LF,
  plus one for a last line with no LF. A CR is never counted, so a CRLF worktree reads the same as LF main. A file
  split into a host plus a folder of pieces (the 2026-09-27 shape: ops\push-main.ps1 beside ops\push-main\*.ps1) is
  judged PER PIECE, because each piece is its own tracked file: a split that leaves every piece under the limit
  leaves nothing to mark.

  WHY (B2 of design\PLAN-efficiency-budgets-2026-09-27.md, ruled by Brad 2026-09-27: "Yes, all of it"). A full day went
  to cleanup that morning, including four files of 3,700 to 8,000 lines, and each grew one reasonable change at a time
  because nothing measured it. Two rules, both one-way:
    1. NO NEW FILE OVER THE LIMIT. A tracked script over 1,000 lines with no mark is a rise.
    2. EVERY FILE ALREADY OVER IT HAS ITS OWN MARK, which may only fall. One line over its mark is a rise.
  A file whose mark is kept but which is now at or under the limit, or no longer tracked, is SPOKEN as droppable.

  A RATCHET IN THE EXEMPLAR'S SHAPE (ops\audit-always-loaded-bytes.ps1, og-11). A plain run never writes the mark:
  run-gates runs this on a code push, and a rewrite there would dirty the checkout being pushed. -Tighten records each
  believable fall and drops the marks of files now under the limit or gone; -Accept records the current sizes of every
  file over the limit, whatever they are (a deliberate growth goes here, with its reason in the commit). A MISSING OR
  UNREADABLE MARK IS EXIT 3 on a plain run: a gate that minted its own mark would bless whatever it found.

  PLAUSIBILITY (og-19). A fall is believed per file: a split legitimately cuts a file by 70%, so the ratchet library's
  60% bar would refuse the very change this budget exists to encourage. What is NOT believed is a population of zero
  (exit 3, blind) and a tracked file that reads as 0 lines while its mark is not: that is a broken read, and -Tighten
  keeps the mark and says so.

  WHAT IT DOES WHEN THE PRODUCER STOPS. The scripts are the producer. If they vanish the counts fall and this says
  "can tighten"; a population of zero is exit 3, never a clean 0.

  COST. run-gates keys this on the code scan set (*.ps1 *.py and friends), so a data-only push replays its pass and
  pays nothing; a code push pays one git ls-files and one read of each script, about 1 s on 994 files.

  SCOPE OF A CLEAN REPORT: UNSOUND for "no file is too big" (a 999-line file of one-line functions is not judged, and a
  .js, .sh or .md file is not counted), COMPLETE for a rise in what it counts: a finding is a tracked .ps1/.py file whose
  LF count is over its mark, or over the limit with no mark, and that count IS the size.

  Usage:
    .\audit-file-size-budget.ps1            measure and ratchet against ops\out\file-size-budget-baseline.json; writes nothing
    .\audit-file-size-budget.ps1 -Tighten   the same, and record each believable fall
    .\audit-file-size-budget.ps1 -Accept    record the CURRENT size of every file over the limit as its mark
    .\audit-file-size-budget.ps1 -Json      also print one `file-size-json: {...}` line before the marker (the weekly report reads it)
    .\audit-file-size-budget.ps1 -SelfTest  frozen fixtures, plus this script's live path run as a child against a temp repository

  Exit: 0 = nothing over its mark. 2 = a rise, or -Tighten refused an implausible fall. 3 = could not evaluate
  (not a git checkout, nothing tracked, or no readable mark).
#>
# The self-test builds its repositories under %TEMP% and runs this file as a child, so it reads nothing else of this repo.
# gate-inputs: lib\guard-contract.ps1, lib\ratchet.ps1, lib\lf-write.ps1, lib\git-repo-env.ps1
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param([switch]$SelfTest, [switch]$Accept, [switch]$Tighten, [switch]$Json, [string]$Root = '', [string]$BaselineFile = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ratchet.ps1')        # Read-TcRatchetBaseline, Get-TcRatchetBlindToken
. (Join-Path $repo 'lib\lf-write.ps1')       # Write-TcLfFile: the mark is tracked and stored eol=lf
. (Join-Path $repo 'lib\git-repo-env.ps1')   # Clear-TcGitRepoEnv: a hook in a linked worktree exports GIT_DIR

$script:FSB_NAME = 'file-size-budget'
# THE LIMIT (B2, Brad's ruling). The plan's own number, not a sweep: 1,000 lines is where the 2026-09-27 split began.
$script:FSB_LIMIT = 1000
$script:FSB_NOTE = 'Per-file marks for the file-size budget (B2 of design/PLAN-efficiency-budgets-2026-09-27.md, ruled by Brad 2026-09-27). Lines as git stores them, of every tracked .ps1/.py file over the limit. No NEW file may exceed the limit; each mark may only go DOWN; a deliberate growth is recorded with -Accept and its reason in the commit.'

function Get-TcLineCount {
  <# Lines as git stores them: one per LF, plus one for a final line with no LF. A CR is never a line. Pure. #>
  param([string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return 0 }
  $n = $Text.Length - $Text.Replace("`n", '').Length
  if ($Text[$Text.Length - 1] -ne "`n") { $n++ }
  return $n
}

function Get-TcFileSizeRows {
  <# Every tracked .ps1/.py below one checkout root as rows { path; lines }, forward slashes, ordinal order.
     Returns { Ok; Why; Rows }. Not a git checkout, or git failing, is Ok = $false: never an empty clean set. #>
  param([string]$RootFull)
  Clear-TcGitRepoEnv
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $ls = $null; $rc = $null
  try { $ls = @(& git -C $RootFull ls-files -z -- '*.ps1' '*.py' 2>$null); $rc = $LASTEXITCODE } catch { $rc = -1 } finally { $ErrorActionPreference = $prev }
  if ($rc -ne 0) { return [pscustomobject]@{ Ok = $false; Why = "git ls-files exited $rc"; Rows = @() } }
  $names = [System.Collections.Generic.List[string]]::new()
  foreach ($chunk in $ls) { foreach ($p in ([string]$chunk).Split([char]0)) { if ($p) { $names.Add($p) } } }
  $arr = $names.ToArray()
  [Array]::Sort($arr, [StringComparer]::Ordinal)
  $rows = [System.Collections.Generic.List[object]]::new()
  foreach ($p in $arr) {
    $full = Join-Path $RootFull ($p -replace '/', '\')
    if (-not [IO.File]::Exists($full)) { continue }   # deleted in the working tree: not a file that can grow
    $rows.Add([pscustomobject]@{ path = $p; lines = (Get-TcLineCount ([IO.File]::ReadAllText($full))) })
  }
  return [pscustomobject]@{ Ok = $true; Why = ''; Rows = $rows.ToArray() }
}

function Get-TcFileSizeVerdict {
  <# The ratchet's answer. Rows: { path; lines }. Marks: hashtable path -> lines (ordinal keys expected).
     Returns { Code; Rose; Fell; Droppable; Broken; Over } where
       Rose      - rows over their mark, or over the limit with no mark ("path lines mark|none")
       Fell      - rows under their mark and still over the limit
       Droppable - marked paths now at or under the limit, or no longer present
       Broken    - marked paths present at 0 lines (a read that failed, never a fall)
       Over      - every row over the limit, largest first
     Code is 2 on any rise, else 0. One function, so the fixture drives the rule the live path runs. #>
  param($Rows, [hashtable]$Marks, [int]$Limit)
  $rose = [System.Collections.Generic.List[string]]::new()
  $fell = [System.Collections.Generic.List[object]]::new()
  $drop = [System.Collections.Generic.List[string]]::new()
  $broken = [System.Collections.Generic.List[string]]::new()
  $over = [System.Collections.Generic.List[object]]::new()
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($r in @($Rows)) {
    $p = [string]$r.path; $n = [int]$r.lines
    [void]$seen.Add($p)
    $has = $Marks.ContainsKey($p)
    if ($n -gt $Limit) { $over.Add($r) }
    if ($has) {
      $m = [int]$Marks[$p]
      if ($n -gt $m) { $rose.Add(('{0} {1} mark {2}' -f $p, $n, $m)) }
      elseif ($n -eq 0 -and $m -gt 0) { $broken.Add($p) }
      elseif ($n -le $Limit) { $drop.Add($p) }
      elseif ($n -lt $m) { $fell.Add([pscustomobject]@{ path = $p; lines = $n; mark = $m }) }
    } elseif ($n -gt $Limit) {
      $rose.Add(('{0} {1} mark none (new over the {2}-line limit)' -f $p, $n, $Limit))
    }
  }
  foreach ($k in @($Marks.Keys)) { if (-not $seen.Contains([string]$k)) { $drop.Add([string]$k) } }
  $overArr = @($over.ToArray() | Sort-Object -Property @{ Expression = { [int]$_.lines }; Descending = $true }, @{ Expression = { [string]$_.path } })
  $code = 0; if ($rose.Count) { $code = 2 }
  return [pscustomobject]@{ Code = $code; Rose = $rose.ToArray(); Fell = $fell.ToArray(); Droppable = $drop.ToArray(); Broken = $broken.ToArray(); Over = $overArr }
}

if ($SelfTest) {
  $script:bad = 0; $script:cases = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    $script:cases++
    if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  $kMF = 'MUST' + ' FIRE'; $kMNF = 'MUST' + ' NOT FIRE'; $kCT = 'CLEAN' + ' TWIN'
  $utf8 = New-Object Text.UTF8Encoding($false)
  $wt = Join-Path $env:TEMP ('fsb-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $wt -ErrorAction Stop | Out-Null
  try {
    # ---- the line count ----
    T ($kMF + '  a CRLF file counts its LFs, never its CRs ("a\r\nb\r\n" is 2 lines)') ((Get-TcLineCount "a`r`nb`r`n") -eq 2) ([string](Get-TcLineCount "a`r`nb`r`n"))
    T ($kCT + '  a last line with no LF still counts ("a\nb" is 2 lines), and an empty file is 0') (((Get-TcLineCount "a`nb") -eq 2) -and ((Get-TcLineCount '') -eq 0)) ("{0}/{1}" -f (Get-TcLineCount "a`nb"), (Get-TcLineCount ''))

    # ---- the verdict, AT the limit and one line past it, AT a mark and one line past it (og-06) ----
    $v = Get-TcFileSizeVerdict -Rows @([pscustomobject]@{ path = 'a.ps1'; lines = 10 }) -Marks @{} -Limit 10
    T ($kMNF + '  a NEW file exactly AT the limit (10 lines, limit 10) is not a rise') ($v.Code -eq 0 -and $v.Rose.Count -eq 0) ("code=$($v.Code)")
    $v = Get-TcFileSizeVerdict -Rows @([pscustomobject]@{ path = 'a.ps1'; lines = 11 }) -Marks @{} -Limit 10
    T ($kMF + '  a NEW file ONE LINE past the limit (11 lines, limit 10) with no mark is a rise, exit 2') ($v.Code -eq 2 -and $v.Rose.Count -eq 1 -and $v.Rose[0] -match 'mark none') ("code=$($v.Code) rose=$($v.Rose -join ';')")
    $v = Get-TcFileSizeVerdict -Rows @([pscustomobject]@{ path = 'big.ps1'; lines = 50 }) -Marks @{ 'big.ps1' = 50 } -Limit 10
    T ($kCT + '  a marked file AT its mark (50 lines, mark 50) holds with exit 0') ($v.Code -eq 0 -and $v.Fell.Count -eq 0 -and $v.Over.Count -eq 1) ("code=$($v.Code)")
    $v = Get-TcFileSizeVerdict -Rows @([pscustomobject]@{ path = 'big.ps1'; lines = 51 }) -Marks @{ 'big.ps1' = 50 } -Limit 10
    T ($kMF + '  a marked file ONE LINE past its mark (51 lines, mark 50) is a rise, exit 2') ($v.Code -eq 2 -and $v.Rose[0] -match '^big\.ps1 51 mark 50') ("code=$($v.Code) rose=$($v.Rose -join ';')")
    $v = Get-TcFileSizeVerdict -Rows @([pscustomobject]@{ path = 'big.ps1'; lines = 49 }) -Marks @{ 'big.ps1' = 50 } -Limit 10
    T ($kMNF + '  a marked file one line UNDER its mark is a fall, exit 0: a fall never fails') ($v.Code -eq 0 -and $v.Fell.Count -eq 1 -and $v.Fell[0].lines -eq 49) ("code=$($v.Code) fell=$($v.Fell.Count)")
    # THE SPLIT (the 2026-09-27 shape): a host cut to under the limit plus two pieces, each under it. Per piece, so clean.
    $split = @([pscustomobject]@{ path = 'ops/host.ps1'; lines = 8 }, [pscustomobject]@{ path = 'ops/host/piece-1.ps1'; lines = 9 }, [pscustomobject]@{ path = 'ops/host/piece-2.ps1'; lines = 10 })
    $v = Get-TcFileSizeVerdict -Rows $split -Marks @{ 'ops/host.ps1' = 27 } -Limit 10
    T ($kMNF + '  a split into a host and pieces, every piece at or under the limit, is no rise, and the host''s mark is droppable') ($v.Code -eq 0 -and (@($v.Droppable) -join ',') -eq 'ops/host.ps1') ("code=$($v.Code) drop=$($v.Droppable -join ',')")
    $split2 = @([pscustomobject]@{ path = 'ops/host.ps1'; lines = 8 }, [pscustomobject]@{ path = 'ops/host/piece-1.ps1'; lines = 19 })
    $v = Get-TcFileSizeVerdict -Rows $split2 -Marks @{ 'ops/host.ps1' = 27 } -Limit 10
    T ($kMF + '  a PIECE over the limit is judged as its own file: a new file over the limit, exit 2') ($v.Code -eq 2 -and $v.Rose[0] -match '^ops/host/piece-1\.ps1 19 mark none') ("rose=$($v.Rose -join ';')")
    $v = Get-TcFileSizeVerdict -Rows @([pscustomobject]@{ path = 'big.ps1'; lines = 0 }) -Marks @{ 'big.ps1' = 50 } -Limit 10
    T ($kMF + '  a marked file that reads 0 lines is a BROKEN read, never a fall to record') ($v.Code -eq 0 -and $v.Broken.Count -eq 1 -and $v.Fell.Count -eq 0 -and $v.Droppable.Count -eq 0) ("broken=$($v.Broken.Count) fell=$($v.Fell.Count)")
    $v = Get-TcFileSizeVerdict -Rows @() -Marks @{ 'gone.ps1' = 50 } -Limit 10
    T ($kCT + '  a marked file no longer tracked is droppable, not a rise') ($v.Code -eq 0 -and (@($v.Droppable) -join ',') -eq 'gone.ps1') ("drop=$($v.Droppable -join ',')")

    # ---- THE LIVE PATH, DRIVEN: this script as a child against a temp repository and a temp mark ----
    $fx = Join-Path $wt 'repo'
    New-Item -ItemType Directory -Path (Join-Path $fx 'ops') -Force -ErrorAction Stop | Out-Null
    $long = (1..1200 | ForEach-Object { "# line $_" }) -join "`n"
    [IO.File]::WriteAllText((Join-Path $fx 'ops\big.ps1'), $long + "`n", $utf8)              # 1,200 lines
    [IO.File]::WriteAllText((Join-Path $fx 'ops\small.py'), "x = 1`n", $utf8)                # 1 line
    [IO.File]::WriteAllText((Join-Path $fx 'notes.md'), ($long + "`n"), $utf8)                # not counted: not a script
    Clear-TcGitRepoEnv
    $prevE = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
      $null = & git -C $fx init -q 2>$null
      $null = & git -C $fx add -A 2>$null
    } finally { $ErrorActionPreference = $prevE }
    $noMark = Join-Path $wt 'no-mark.json'
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $fx -BaselineFile $noMark
    $rc0 = $LASTEXITCODE
    T ($kMF + '  a plain run with NO mark exits 3 and writes none') ($rc0 -eq 3 -and -not (Test-Path -LiteralPath $noMark)) ("rc=$rc0 written=$(Test-Path -LiteralPath $noMark)")
    $bl = Join-Path $wt 'baseline.json'
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $fx -BaselineFile $bl -Accept
    $rcA = $LASTEXITCODE
    $b = [IO.File]::ReadAllBytes($bl)
    $cr = 0; foreach ($x in $b) { if ($x -eq 13) { $cr++ } }
    $doc = [IO.File]::ReadAllText($bl) | ConvertFrom-Json
    $bigMark = @(@($doc.files) | Where-Object { $_.path -eq 'ops/big.ps1' })
    T ($kCT + '  -Accept records ONLY the file over the limit (ops/big.ps1 at 1,200), LF bytes, the limit and the note') `
      ($rcA -eq 0 -and $cr -eq 0 -and @($doc.files).Count -eq 1 -and $bigMark.Count -eq 1 -and [int]$bigMark[0].lines -eq 1200 -and [int]$doc.limit -eq 1000 -and [string]$doc.note -like 'Per-file marks*') `
      ("rc=$rcA cr=$cr files=$(@($doc.files).Count)")
    $o1 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $fx -BaselineFile $bl -Json)
    $rc1 = $LASTEXITCODE
    $jl = @($o1 | Where-Object { "$_" -like 'file-size-json: *' })
    T ($kMNF + '  the tree as accepted is green, and -Json carries files_over=1 and the largest file') `
      ($rc1 -eq 0 -and $jl.Count -eq 1 -and ("$($jl[0])" -match '"files_over":\s*1') -and ("$($jl[0])" -match 'ops/big\.ps1')) ("rc=$rc1 json=$($jl -join '')")
    [IO.File]::AppendAllText((Join-Path $fx 'ops\big.ps1'), "# one more`n", $utf8)
    $o2 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $fx -BaselineFile $bl)
    $rc2 = $LASTEXITCODE
    T ($kMF + '  one line added to a marked file fails the child run with exit 2 and names the file') ($rc2 -eq 2 -and (($o2 -join "`n") -match 'ops/big\.ps1 1201 mark 1200')) ("rc=$rc2")
    $blB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($bl))
    [IO.File]::WriteAllText((Join-Path $fx 'ops\big.ps1'), ((1..1100 | ForEach-Object { "# line $_" }) -join "`n") + "`n", $utf8)
    $o3 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $fx -BaselineFile $bl)
    $rc3 = $LASTEXITCODE
    $same3 = [string]::Equals($blB64, [Convert]::ToBase64String([IO.File]::ReadAllBytes($bl)), [StringComparison]::Ordinal)
    T ($kCT + '  a FALL (1,100 against 1,200) without -Tighten is spoken ("CAN tighten") and NOT written') ($rc3 -eq 0 -and $same3 -and (($o3 -join "`n") -match 'CAN tighten')) ("rc=$rc3 unchanged=$same3")
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $fx -BaselineFile $bl -Tighten
    $rc4 = $LASTEXITCODE
    $doc4 = [IO.File]::ReadAllText($bl) | ConvertFrom-Json
    T ($kCT + '  -Tighten records the fall: the mark is now 1,100') ($rc4 -eq 0 -and [int](@($doc4.files)[0].lines) -eq 1100) ("rc=$rc4 mark=$(@($doc4.files)[0].lines)")
    $plain = Join-Path $wt 'plain'
    New-Item -ItemType Directory -Path $plain -ErrorAction Stop | Out-Null
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $plain -BaselineFile $bl
    $rc5 = $LASTEXITCODE
    T ($kMF + '  a directory that is not a git checkout exits 3 BLIND, never a clean 0') ($rc5 -eq 3) ("rc=$rc5")
  } catch {
    $script:cases++; $script:bad++
    Write-Output ('  X     the suite threw: ' + $_.Exception.Message)
  } finally {
    Remove-Item -LiteralPath $wt -Recurse -Force -ErrorAction SilentlyContinue
  }
  $expected = 18
  if ($script:cases -ne $expected) { Write-Output ("  X     ran $($script:cases) case(s), expected $expected"); $script:bad++ }
  if ($script:bad -eq 0) { Write-Output ("FILE-SIZE-BUDGET SELF-TEST PASS ($($script:cases) of $expected cases)"); Write-GuardComplete -Name $script:FSB_NAME -Summary "selftest ok cases=$($script:cases)"; exit 0 }
  Write-Output ("FILE-SIZE-BUDGET SELF-TEST FAILED ($($script:bad))"); Write-GuardComplete -Name $script:FSB_NAME -Summary "selftest failed=$($script:bad)"; exit 2
}

# ---- live measurement ----
if (-not $Root) { $Root = $repo }
$rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
$set = Get-TcFileSizeRows -RootFull $rootFull
if (-not $set.Ok -or -not @($set.Rows).Count) {
  $why = if ($set.Ok) { 'no tracked .ps1/.py file' } else { $set.Why }
  Write-Output ("file-size-budget: BLIND - {0} at {1}, so a count here would describe a broken checkout, not the budget" -f $why, $rootFull)
  Exit-Guard -Name $script:FSB_NAME -Summary 'scanned=0 blind=no-population' -Code 3
}
$blF = if ($BaselineFile) { $BaselineFile } else { Join-Path $here 'out\file-size-budget-baseline.json' }
$marks = New-Object 'System.Collections.Hashtable' ([StringComparer]::Ordinal)
$rb = Read-TcRatchetBaseline -Path $blF -Field 'limit'
if ($rb.State -ceq 'read') { foreach ($mf in @($rb.Doc.files)) { if ($mf -and $mf.path) { $marks[[string]$mf.path] = [int]$mf.lines } } }
$v = Get-TcFileSizeVerdict -Rows $set.Rows -Marks $marks -Limit $script:FSB_LIMIT
$sum = "scanned=$(@($set.Rows).Count) over=$(@($v.Over).Count) marks=$($marks.Count)"

function Write-FsbBaseline($Files) {
  $note = if ($rb.Doc -and $rb.Doc.note) { [string]$rb.Doc.note } else { $script:FSB_NOTE }
  $json = [ordered]@{ note = $note; generated = (Get-Date).ToString('s'); limit = $script:FSB_LIMIT; files = @($Files) } | ConvertTo-Json -Depth 4
  $dir = Split-Path $blF -Parent
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  return (Write-TcLfFile $blF $json)
}
if ($Json) {
  $top = @(@($v.Over) | Select-Object -First 5 | ForEach-Object { [ordered]@{ path = [string]$_.path; lines = [int]$_.lines; mark = $(if ($marks.ContainsKey([string]$_.path)) { [int]$marks[[string]$_.path] } else { $null }) } })
  $overLines = 0; foreach ($o in @($v.Over)) { $overLines += [int]$o.lines }
  $markLines = 0; foreach ($k in @($marks.Keys)) { $markLines += [int]$marks[$k] }
  $jd = [ordered]@{ known = ($rb.State -ceq 'read'); limit = $script:FSB_LIMIT; scanned = @($set.Rows).Count; files_over = @($v.Over).Count; lines_over = $overLines; mark_lines = $markLines; marks = $marks.Count; rose = @($v.Rose).Count; largest = $top }
  Write-Output ('file-size-json: ' + ($jd | ConvertTo-Json -Depth 4 -Compress))
}
if ($Accept) {
  $files = @(@($v.Over) | Sort-Object -Property path | ForEach-Object { [ordered]@{ path = [string]$_.path; lines = [int]$_.lines } })
  $null = Write-FsbBaseline $files
  Write-Output ("  marks written: {0} file(s) over the {1}-line limit. From here each may only go DOWN. Commit ops\out\file-size-budget-baseline.json." -f $files.Count, $script:FSB_LIMIT)
  Exit-Guard -Name $script:FSB_NAME -Summary "$sum accepted" -Code 0
}
if ($rb.State -cne 'read') {
  Write-Output ("file-size-budget: COULD NOT EVALUATE - the mark at {0} is {1} ({2}). A plain run never mints one; record it deliberately with -Accept and commit it." -f $blF, $rb.State, $rb.Why)
  Exit-Guard -Name $script:FSB_NAME -Summary ("$sum blind=" + (Get-TcRatchetBlindToken $rb.State)) -Code 3
}
Write-Output ("file-size-budget: {0} tracked script(s) read, {1} over the {2}-line limit, {3} with a mark" -f @($set.Rows).Count, @($v.Over).Count, $script:FSB_LIMIT, $marks.Count)
foreach ($o in @($v.Over)) {
  $mk = if ($marks.ContainsKey([string]$o.path)) { ('mark {0:N0}' -f [int]$marks[[string]$o.path]) } else { 'NO MARK' }
  Write-Output ('  {0,7:N0}  {1}  ({2})' -f [int]$o.lines, $o.path, $mk)
}
foreach ($x in @($v.Broken)) { Write-Output ("  BROKEN READ  {0} reads 0 lines against a mark of {1}: its mark is kept, never lowered to a blind 0" -f $x, $marks[$x]) }
if (@($v.Rose).Count) {
  Write-Output ("file-size-budget: RATCHET BROKEN - {0} file(s) grew past their budget:" -f @($v.Rose).Count)
  foreach ($r in @($v.Rose)) { Write-Output ('  ROSE  ' + $r) }
  Write-Output '  Split the file (a host plus a folder of pieces, each under the limit), move code to a library, or, if the growth is the decision, record it with -Accept and say why in the commit.'
  Exit-Guard -Name $script:FSB_NAME -Summary "$sum rose=$(@($v.Rose).Count)" -Code 2
}
if (@($v.Fell).Count -or @($v.Droppable).Count) {
  if ($Tighten) {
    $keep = [System.Collections.Generic.List[object]]::new()
    $dropSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($d in @($v.Droppable)) { [void]$dropSet.Add([string]$d) }
    $fellBy = @{}; foreach ($f in @($v.Fell)) { $fellBy[[string]$f.path] = [int]$f.lines }
    foreach ($k in (@($marks.Keys) | Sort-Object)) {
      if ($dropSet.Contains([string]$k)) { continue }
      $n = if ($fellBy.ContainsKey([string]$k)) { $fellBy[[string]$k] } else { [int]$marks[$k] }
      $keep.Add([ordered]@{ path = [string]$k; lines = $n })
    }
    $null = Write-FsbBaseline $keep.ToArray()
    Write-Output ("  ratchet tightened: {0} mark(s) lowered, {1} dropped. New marks written - commit them, or they protect only this checkout." -f @($v.Fell).Count, @($v.Droppable).Count)
  } else {
    foreach ($f in @($v.Fell)) { Write-Output ("  can tighten: {0} is {1:N0} lines against a mark of {2:N0}" -f $f.path, $f.lines, $f.mark) }
    foreach ($d in @($v.Droppable)) { Write-Output ("  can drop:    {0} is at or under the limit, or no longer tracked" -f $d) }
    Write-Output '  ratchet CAN tighten. NOT written: this may be a pre-push gate. Record it with -Tighten and commit ops\out\file-size-budget-baseline.json.'
  }
}
Exit-Guard -Name $script:FSB_NAME -Summary $sum -Code 0
