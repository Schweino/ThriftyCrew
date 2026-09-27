<#
  report-efficiency-budgets.ps1 - every efficiency budget's number, its mark, its 4-week trend and its STATE, once a week.

  B4 of design\PLAN-efficiency-budgets-2026-09-27.md, ruled by Brad 2026-09-27 ("Yes, all of it"). ops\brain-digest.ps1
  prints this as a section of the Monday morning page. It READS and never fails anything: the budgets that can refuse a
  push (B1 push cost, B2 file size, the always-loaded bytes) refuse it themselves, at the push.

  THE BUDGET POLICY, agreed in advance (the brief for B1-B4, 2026-09-27; reliability-craft/slos-and-error-budgets.md
  section 4: a budget with no policy is a gauge nobody acts on). Each budget with a mark is in exactly one state, and
  the state carries its action:
    healthy           - carry on.
    at risk           - it GREW over the last four weeks, with 25% or more headroom left: review what grew.
    nearly exhausted  - under 25% headroom left ((mark - current) / mark < 0.25): new machinery must shrink something
                        else first. A ratchet AT its mark is here by definition, which is the ratchet's own rule: to add,
                        take away. The plan's "within 10% of its mark" flag is inside this state and printed beside it.
    over              - past the mark: cleanup before new feature work.
  A budget with no mark yet is REPORT ONLY (its number and trend, no state), and a number that could not be read is
  UNKNOWN, never 0.

  THE BUDGETS (the plan's list): push cost for a data-only and a code push (B1, ops\push-cost-budget.ps1), the files
  over 1,000 lines (B2, ops\audit-file-size-budget.ps1), the always-loaded bytes (ops\audit-always-loaded-bytes.ps1),
  the script-census orphans outside grocery\ (grocery\audit-script-census.ps1's wide tier), the worktree count, and the
  plans marked under way (ops\plan_citation.py's own reading of a Status line).

  THE 4-WEEK TREND comes from this report's own history: each run appends one row of its numbers to
  %LOCALAPPDATA%\ThriftyCrew\efficiency-budgets\history.jsonl (outside the repo, machine-local like the rows it reads),
  and the trend compares today with the newest row at least 28 days old. Until one exists it says so and names the
  first row's date, rather than inventing a trend.

  SCOPE OF A CLEAN REPORT: UNSOUND. It reports the budgets that exist; bloat of a kind nobody measures is invisible here.

  Usage:
    .\report-efficiency-budgets.ps1            print the section and append today's row to the history
    .\report-efficiency-budgets.ps1 -Json      also one `efficiency-json: {...}` line
    .\report-efficiency-budgets.ps1 -NoRecord  print, append nothing
    .\report-efficiency-budgets.ps1 -SelfTest  the policy's states at their bars, the trend and the page, from fixtures
  Exit: 0 always, unless -SelfTest fails.
#>
# gate-inputs: ops\report-efficiency-budgets.ps1, lib\guard-contract.ps1, lib\append-line.ps1
[CmdletBinding()]
param([switch]$SelfTest, [switch]$Json, [switch]$NoRecord, [string]$HistoryFile = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\append-line.ps1')

# The policy's bar, as the brief states it: under 25% headroom is nearly exhausted. The 10% flag is the plan's B4 line.
$script:EB_NEARLY = 0.25
$script:EB_WITHIN = 0.10
$script:EB_TREND_DAYS = 28

function Get-TcBudgetState {
  <# The policy state of one budget. Current and Mark are UNTYPED: $null is unknown / no mark, never 0. Pure. #>
  param($Current, $Mark, $FourWeeksAgo, [bool]$Known = $true)
  if (-not $Known) { return 'unknown' }
  if ($null -eq $Mark -or $null -eq $Current) { return 'report only' }
  if ([double]$Current -gt [double]$Mark) { return 'over' }
  if ([double]$Mark -le 0 -or (([double]$Mark - [double]$Current) / [double]$Mark) -lt $script:EB_NEARLY) { return 'nearly exhausted' }
  if ($null -ne $FourWeeksAgo -and [double]$Current -gt [double]$FourWeeksAgo) { return 'at risk' }
  return 'healthy'
}

function Get-TcBudgetAction([string]$State) {
  switch -CaseSensitive ($State) {
    'healthy'          { return 'carry on' }
    'at risk'          { return 'review what grew' }
    'nearly exhausted' { return 'new machinery must shrink something else first' }
    'over'             { return 'cleanup before new feature work' }
    'report only'      { return 'no mark yet' }
    'unknown'          { return 'the counter could not run' }
    default            { throw ('Get-TcBudgetAction: unknown state ' + $State) }
  }
}

function Get-TcBudgetTrendBase {
  <# From the history rows (oldest first), the value of Name in the newest row at least -Days old at NowUtc, as
     { Value; Date; FirstDate }. Value $null when no row is that old (or it lacks the name). Pure. #>
  param($Rows, [string]$Name, [datetime]$NowUtc, [int]$Days = 28)
  $o = [ordered]@{ Value = $null; Date = $null; FirstDate = $null }
  foreach ($r in @($Rows)) {
    if (-not $r) { continue }
    $t = $null; try { $t = [DateTime]::Parse([string]$r.utc).ToUniversalTime() } catch { continue }
    if ($null -eq $o.FirstDate) { $o.FirstDate = $t }
    if (($NowUtc - $t).TotalDays -ge $Days -and $r.values -and $r.values.PSObject.Properties[$Name] -and $null -ne $r.values.$Name) {
      $o.Value = [double]$r.values.$Name; $o.Date = $t
    }
  }
  return [pscustomobject]$o
}

function Format-TcBudgetLines {
  <# The section as lines. Budgets: { Name; Current; Mark; Unit; Base; Note }. PURE, so fixtures drive the wording. #>
  param($Budgets, $FirstDate = $null)
  $out = [System.Collections.Generic.List[string]]::new()
  $out.Add('EFFICIENCY BUDGETS (weekly)')
  $out.Add('  ' + ('{0,-24} {1,10} {2,10} {3,14}  {4}' -f 'budget', 'now', 'mark', '4 weeks ago', 'state'))
  $flag = 0
  foreach ($b in @($Budgets)) {
    $st = Get-TcBudgetState -Current $b.Current -Mark $b.Mark -FourWeeksAgo $b.Base -Known ([bool]$b.Known)
    $cur = if (-not $b.Known) { '?' } elseif ($null -eq $b.Current) { '-' } else { ('{0:N0}{1}' -f [double]$b.Current, $b.Unit) }
    $mk = if ($null -eq $b.Mark) { '-' } else { ('{0:N0}{1}' -f [double]$b.Mark, $b.Unit) }
    $bs = if ($null -eq $b.Base) { '-' } else { ('{0:N0}{1}' -f [double]$b.Base, $b.Unit) }
    $w = ''
    if ($null -ne $b.Current -and $null -ne $b.Mark -and [double]$b.Mark -gt 0 -and ([double]$b.Mark - [double]$b.Current) / [double]$b.Mark -lt $script:EB_WITHIN -and $st -cne 'over') { $w = ', WITHIN 10% OF ITS MARK' }
    if ($st -ceq 'over' -or $st -ceq 'nearly exhausted' -or $st -ceq 'at risk') { $flag++ }
    $line = '  ' + ('{0,-24} {1,10} {2,10} {3,14}  {4}{5} - {6}' -f $b.Name, $cur, $mk, $bs, $st.ToUpperInvariant(), $w, (Get-TcBudgetAction $st))
    if ($b.Note) { $line += (' (' + $b.Note + ')') }
    $out.Add($line)
  }
  if ($null -eq $FirstDate) { $out.Add('  4-week trend: no history yet; this is its first row.') }
  elseif (-not @(@($Budgets) | Where-Object { $null -ne $_.Base }).Count) { $out.Add(('  4-week trend: none yet - the history starts {0:yyyy-MM-dd}, and a trend needs a row {1} days old.' -f $FirstDate, $script:EB_TREND_DAYS)) }
  $out.Add(('  Policy: healthy carry on; at risk review what grew; nearly exhausted (under 25% headroom) shrink something else first; over, cleanup before new feature work. {0} budget(s) need attention.' -f $flag))
  return ,$out.ToArray()
}

function Get-TcChildLines([string]$File, [string[]]$ArgList) {
  <# A child script's stdout lines, or $null when it could not run. Its exit code is not the reading: a red budget is a
     number to report, not a failure of the report. #>
  try { return ,@(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo $File) @ArgList) } catch { return $null }
}

if ($SelfTest) {
  $script:bad = 0; $script:cases = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    $script:cases++
    if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  $kMF = 'MUST' + ' FIRE'; $kMNF = 'MUST' + ' NOT FIRE'; $kCT = 'CLEAN' + ' TWIN'
  try {
    # THE POLICY'S BARS (og-06), in binary-exact numbers against a mark of 100.
    T ($kMF + '  one unit past the mark (101 against 100) is OVER') ((Get-TcBudgetState 101 100 $null) -ceq 'over') ''
    T ($kCT + '  AT the mark (100 against 100): no headroom, NEARLY EXHAUSTED, which is a ratchet''s own rule') ((Get-TcBudgetState 100 100 $null) -ceq 'nearly exhausted') ''
    T ($kMF + '  24% headroom (76 against 100), one step under the 25% bar, is NEARLY EXHAUSTED') ((Get-TcBudgetState 76 100 $null) -ceq 'nearly exhausted') ''
    T ($kMNF + '  exactly 25% headroom (75 against 100), AT the bar, is not nearly exhausted') ((Get-TcBudgetState 75 100 $null) -ceq 'healthy') ''
    T ($kMF + '  with headroom, a number that GREW over four weeks (75 now, 50 then) is AT RISK') ((Get-TcBudgetState 75 100 50) -ceq 'at risk') ''
    T ($kMNF + '  with headroom, a number that held or fell over four weeks is HEALTHY') (((Get-TcBudgetState 50 100 75) -ceq 'healthy') -and ((Get-TcBudgetState 50 100 50) -ceq 'healthy')) ''
    T ($kMNF + '  no mark is REPORT ONLY, never over, and a mark of $null is never read as 0') ((Get-TcBudgetState 9999 $null $null) -ceq 'report only') ''
    T ($kMNF + '  a number that could not be read is UNKNOWN, never 0 and never healthy') ((Get-TcBudgetState $null 100 $null $false) -ceq 'unknown') ''
    T ($kCT + '  a counter that ran and has no number yet (push cost before 9 runs) is REPORT ONLY, not unknown') ((Get-TcBudgetState $null $null $null $true) -ceq 'report only') ''
    $threw = $false; try { $null = Get-TcBudgetAction 'sideways' } catch { $threw = $true }
    T ($kMF + '  an unknown state throws rather than printing no action') $threw ''
    # THE TREND reads the newest row at least 28 days old, and says when there is none.
    $now = [DateTime]::Parse('2026-10-26T06:45:00Z').ToUniversalTime()
    $hist = @(
      [pscustomobject]@{ utc = '2026-09-27T06:45:00Z'; values = [pscustomobject]@{ a = 10 } },
      [pscustomobject]@{ utc = '2026-09-28T06:45:00Z'; values = [pscustomobject]@{ a = 12 } },
      [pscustomobject]@{ utc = '2026-09-29T06:45:00Z'; values = [pscustomobject]@{ a = 14 } })
    $tb = Get-TcBudgetTrendBase -Rows $hist -Name 'a' -NowUtc $now
    T ($kCT + '  the base is the newest row at least 28 days old (09-28 at 28.0 days, not 09-29 at 27.0)') ($tb.Value -eq 12) ("value=$($tb.Value)")
    $tb2 = Get-TcBudgetTrendBase -Rows $hist -Name 'a' -NowUtc $now.AddDays(-5)
    T ($kMNF + '  with no row 28 days old there is no base ($null), and the first row''s date is known') ($null -eq $tb2.Value -and $tb2.FirstDate.Day -eq 27) ("value=$($tb2.Value)")
    # THE PAGE
    $page = Format-TcBudgetLines -Budgets @(
      [pscustomobject]@{ Name = 'push cost (data)'; Current = 510; Mark = 500; Unit = ' s'; Base = $null; Note = ''; Known = $true },
      [pscustomobject]@{ Name = 'always-loaded bytes'; Current = 95; Mark = 100; Unit = ' B'; Base = $null; Note = ''; Known = $true },
      [pscustomobject]@{ Name = 'worktrees'; Current = 160; Mark = $null; Unit = ''; Base = $null; Note = ''; Known = $true }) -FirstDate $now
    $pt = $page -join "`n"
    T ($kCT + '  the page states each budget''s state with its action, flags within 10%, and counts what needs attention') `
      (($pt -match 'push cost \(data\)\s+510 s\s+500 s\s+-\s+OVER - cleanup before new feature work') -and ($pt -match 'NEARLY EXHAUSTED, WITHIN 10% OF ITS MARK - new machinery must shrink') -and ($pt -match 'worktrees\s+160\s+-\s+-\s+REPORT ONLY') -and ($pt -match '2 budget\(s\) need attention')) $pt
  } catch {
    $script:cases++; $script:bad++
    Write-Output ('  X     the suite threw: ' + $_.Exception.Message)
  }
  $expected = 13
  if ($script:cases -ne $expected) { Write-Output ("  X     ran $($script:cases) case(s), expected $expected"); $script:bad++ }
  if ($script:bad -eq 0) { Write-Output ("EFFICIENCY-BUDGETS SELF-TEST PASS ($($script:cases) of $expected cases)"); Write-GuardComplete -Name 'efficiency-budgets' -Summary "selftest ok cases=$($script:cases)"; exit 0 }
  Write-Output ("EFFICIENCY-BUDGETS SELF-TEST FAILED ($($script:bad))"); Write-GuardComplete -Name 'efficiency-budgets' -Summary "selftest failed=$($script:bad)"; exit 1
}

# ---- live: gather each budget ----
$budgets = [System.Collections.Generic.List[object]]::new()
function Add-Budget([string]$Name, $Current, $Mark, [string]$Unit, [string]$Note = '', [bool]$Known = ($null -ne $Current)) { $budgets.Add([pscustomobject]@{ Name = $Name; Current = $Current; Mark = $Mark; Unit = $Unit; Base = $null; Note = $Note; Known = $Known }) }

# B1: push cost, both classes.
$pc = Get-TcChildLines 'ops\push-cost-budget.ps1' @('-Json')
$pj = $null
if ($pc) { $l = @($pc | Where-Object { "$_" -like 'push-cost-json: *' }); if ($l.Count) { try { $pj = ("$($l[0])".Substring('push-cost-json: '.Length)) | ConvertFrom-Json } catch { $pj = $null } } }
foreach ($c in @('data', 'code')) {
  if ($pj) {
    $cj = $pj.classes.$c
    $note = if ([string]$cj.state -ceq 'report-only') { ('report-only: ' + [string]$cj.why) } else { ('median of ' + [int]$cj.n + ' runs') }
    Add-Budget ("push cost ($c)") $cj.median_s $cj.mark_s ' s' $note $true
  } else { Add-Budget ("push cost ($c)") $null $null ' s' 'ops\push-cost-budget.ps1 could not run' }
}
# B2: files over 1,000 lines: their total lines against the sum of their marks.
$fs = Get-TcChildLines 'ops\audit-file-size-budget.ps1' @('-Json')
$fj = $null
if ($fs) { $l = @($fs | Where-Object { "$_" -like 'file-size-json: *' }); if ($l.Count) { try { $fj = ("$($l[0])".Substring('file-size-json: '.Length)) | ConvertFrom-Json } catch { $fj = $null } } }
if ($fj -and $fj.known) {
  $big = @($fj.largest | Select-Object -First 3 | ForEach-Object { '{0} {1:N0}' -f ([string]$_.path -replace '^.*/', ''), [int]$_.lines }) -join ', '
  $rn = if ([int]$fj.rose) { ('{0} file(s) over their own mark; ' -f [int]$fj.rose) } else { '' }
  Add-Budget 'lines in files >1,000' $fj.lines_over $fj.mark_lines '' ('{0}{1} files; largest {2}' -f $rn, [int]$fj.files_over, $big)
} else { Add-Budget 'lines in files >1,000' $null $null '' 'ops\audit-file-size-budget.ps1 could not read its mark' }
# The always-loaded bytes.
$al = Get-TcChildLines 'ops\audit-always-loaded-bytes.ps1' @()
$alCur = $null; $alMark = $null
if ($al) { foreach ($x in @($al)) { $m = [regex]::Match("$x", '^always-loaded-bytes: ([\d,]+) B against a mark of ([\d,]+) B') ; if ($m.Success) { $alCur = [int]($m.Groups[1].Value -replace ',', ''); $alMark = [int]($m.Groups[2].Value -replace ',', '') } } }
if ($null -eq $alCur -and $al) { foreach ($x in @($al)) { $m = [regex]::Match("$x", 'RATCHET BROKEN - ([\d,]+) B now against a mark of ([\d,]+) B'); if ($m.Success) { $alCur = [int]($m.Groups[1].Value -replace ',', ''); $alMark = [int]($m.Groups[2].Value -replace ',', '') } } }
Add-Budget 'always-loaded bytes' $alCur $alMark ' B'
# Script-census orphans outside grocery\ (the wide tier's ratchet).
$sc = Get-TcChildLines 'grocery\audit-script-census.ps1' @()
$scCur = $null; $scMark = $null
if ($sc) { foreach ($x in @($sc)) { $m = [regex]::Match("$x", 'wide tier: \d+ uncalled outside .*?\((\d+) not yet recorded in KNOWN\)(?:\s+baseline (\d+))?'); if ($m.Success) { $scCur = [int]$m.Groups[1].Value; if ($m.Groups[2].Success) { $scMark = [int]$m.Groups[2].Value } } } }
Add-Budget 'script-census orphans' $scCur $scMark '' 'uncalled outside grocery\ and not recorded in KNOWN'
# Worktrees on this box: report only (B3 trims them nightly).
$wtCount = $null
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try { $wl = @(& git -C $repo worktree list --porcelain 2>$null); if ($LASTEXITCODE -eq 0) { $wtCount = @($wl | Where-Object { "$_" -like 'worktree *' }).Count } } catch { } finally { $ErrorActionPreference = $prev }
Add-Budget 'worktrees' $wtCount $null '' 'B3 removes the clean merged ones untouched 3+ days, nightly'
# Plans marked under way, by plan_citation.py's own reading of a Status line at origin/main.
$planCount = $null
$py = 'C:\Codex\Python312\python.exe'
if ([IO.File]::Exists($py)) {
  $code = "import sys; sys.path.insert(0, r'" + (Join-Path $repo 'ops') + "'); import plan_citation as p; ps, why = p.read_plans(cwd=r'" + $repo + "'); print('plans-under-way: ' + ('none' if ps is None else str(sum(1 for t in ps.values() if p.plan_state(t)[0] == 'under-way'))))"
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $po = @(& $py -c $code 2>$null); $pl = @($po | Where-Object { "$_" -match '^plans-under-way: (\d+)$' }); if ($pl.Count) { $planCount = [int]([regex]::Match("$($pl[0])", '(\d+)$').Groups[1].Value) } } catch { } finally { $ErrorActionPreference = $prev }
}
Add-Budget 'plans under way' $planCount $null '' 'Status line ruled or under way, at origin/main'

# ---- the trend, from this report's own history ----
$hf = if ($HistoryFile) { $HistoryFile } elseif ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'ThriftyCrew\efficiency-budgets\history.jsonl' } else { '' }
$hist = [System.Collections.Generic.List[object]]::new()
if ($hf -and [IO.File]::Exists($hf)) { foreach ($l in [IO.File]::ReadAllLines($hf)) { if ($l.Trim()) { try { $hist.Add(($l | ConvertFrom-Json)) } catch { } } } }
$nowU = [DateTime]::UtcNow
$first = $null
foreach ($b in $budgets) { $tb = Get-TcBudgetTrendBase -Rows $hist.ToArray() -Name $b.Name -NowUtc $nowU -Days $script:EB_TREND_DAYS; $b.Base = $tb.Value; if ($null -eq $first) { $first = $tb.FirstDate } }
$lines = Format-TcBudgetLines -Budgets $budgets.ToArray() -FirstDate $first
foreach ($l in $lines) { Write-Output $l }
$vals = [ordered]@{}; foreach ($b in $budgets) { $vals[$b.Name] = $b.Current }
if (-not $NoRecord -and $hf) {
  try {
    $d = Split-Path $hf -Parent
    if (-not [IO.Directory]::Exists($d)) { $null = [IO.Directory]::CreateDirectory($d) }
    $null = Add-TcLine -Path $hf -Text ([ordered]@{ utc = $nowU.ToString('o'); values = $vals } | ConvertTo-Json -Compress)
  } catch { Write-Output ('  (the history row could not be written: ' + $_.Exception.Message + ')') }
}
if ($Json) {
  $jb = @($budgets | ForEach-Object { [ordered]@{ name = $_.Name; current = $_.Current; mark = $_.Mark; four_weeks_ago = $_.Base; state = (Get-TcBudgetState -Current $_.Current -Mark $_.Mark -FourWeeksAgo $_.Base -Known ([bool]$_.Known)) } })
  Write-Output ('efficiency-json: ' + ([ordered]@{ budgets = $jb } | ConvertTo-Json -Depth 4 -Compress))
}
$unk = @($budgets | Where-Object { -not $_.Known }).Count
Write-GuardComplete -Name 'efficiency-budgets' -Summary ("budgets={0} unknown={1}" -f $budgets.Count, $unk)
exit 0
