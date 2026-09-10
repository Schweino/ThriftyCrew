<#
  tune-alert-rearm.ps1 - an alert's re-arm window, moved by how often that alert turns out to be RIGHT.

  WS 10b of design\PLAN-brain-v2-2026-09-09.md.

  THE LOOP IT CLOSES. grocery\audit-alert-precision.ps1 computes each alert type's live precision from
  the dispositions grocery\triage-close.ps1 records, and nothing acted on it: an alert that is wrong four
  times in five re-paged on exactly the same 14-day clock as one that is right every time. This is the
  actuator, and it is bounded on every side:

    * DOUBLES the window when a type has at least 5 judged closes and precision under 40%. An alert that
      is mostly wrong should interrupt less often.
    * HALVES it when a type has at least 10 judged closes and precision over 80%. An alert that is right
      should come back sooner.
    * CLAMPED to 7..56 days. The reader ignores a value outside that rather than trusting it.
    * ONE MOVE PER TYPE PER 14 DAYS. A second move inside the window is REFUSED, the value KEPT and the
      refusal SPOKEN - a run that declined to act must not look like a run with nothing to do.
    * A type with no close in 30 days is PRINTED, NOT TUNED. A precision nobody is still measuring is not
      evidence about today, and that is this loop's answer to "what does it do when the producer stops".

  PRECISION IS A PERCENT. grocery\triage-lib.ps1's Get-TcPrecision returns 0..100, so the bars are 40 and
  80. The plan wrote 0.4 and 0.8; a fraction compared against a percent would double every window on the
  first run.

  WHAT READS THE FILE. grocery\alert-tuning.json is read by check-ad-cycles.ps1 inside its REVIEW-ACKLOAD
  region - so test-auditors.ps1 runs the real read - for the one alert that HAS a re-arm clock: the price
  flag mail, type key 'grocery new price flag s'. Every other type's row is recorded and reported and moves
  nothing, because nothing else re-arms. Measured 2026-09-10: 148 queue items, 23 dispositioned, and no
  type at 5 judged closes, so the file starts empty and the first real move is weeks away.

  The bars, the clamp and the rate limit are FIRST PLAUSIBLE VALUES, the plan's, NOT a sweep. They are in
  docs\CONTROL-CONSTANTS.md; when the second value is chosen, what else was tried goes there.

  SCOPE OF A CLEAN REPORT: "no move" means no type cleared a bar or a move was refused, and both are
  printed. It says nothing about whether an alert is useful, only whether it has been right.

  EXIT: 0 report produced (a move or a refusal is content), 3 could not evaluate (no readable queue).
#>
[CmdletBinding()]
param([switch]$SelfTest, [switch]$Json, [switch]$DryRun, [string]$QueueFile = '', [string]$TuningFile = '')

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $here 'triage-lib.ps1')

$script:REARM_DEFAULT    = 14
$script:REARM_MIN        = 7
$script:REARM_MAX        = 56
$script:LOW_PRECISION    = 40.0
$script:LOW_MIN_CASES    = 5
$script:HIGH_PRECISION   = 80.0
$script:HIGH_MIN_CASES   = 10
$script:MOVE_EVERY_DAYS  = 14
$script:STALE_CLOSE_DAYS = 30
$script:PRICE_FLAG_TYPE  = 'grocery new price flag s'

function Get-RearmMove {
  <# @{ Next; Action = double | halve | hold | refused | stale; Why }. PURE. #>
  param([int]$Current, [int]$Judged, $Rate, [string]$LastMove, [string]$LastClose, [datetime]$Now)
  if ($Current -lt $script:REARM_MIN -or $Current -gt $script:REARM_MAX) { $Current = $script:REARM_DEFAULT }
  $lc = $null
  try { if ($LastClose) { $lc = [datetime]$LastClose } } catch { $lc = $null }
  if ($null -eq $lc -or ($Now - $lc).TotalDays -gt $script:STALE_CLOSE_DAYS) {
    return @{ Next = $Current; Action = 'stale'; Why = ("no judged close in {0} days - printed, not tuned" -f $script:STALE_CLOSE_DAYS) }
  }
  $want = $Current; $act = 'hold'; $why = 'inside both bars'
  if ($null -ne $Rate -and $Judged -ge $script:LOW_MIN_CASES -and [double]$Rate -lt $script:LOW_PRECISION) {
    $want = [math]::Min($script:REARM_MAX, $Current * 2); $act = 'double'
    $why = ("{0}% over {1} judged, under {2}%" -f $Rate, $Judged, $script:LOW_PRECISION)
  } elseif ($null -ne $Rate -and $Judged -ge $script:HIGH_MIN_CASES -and [double]$Rate -gt $script:HIGH_PRECISION) {
    $want = [math]::Max($script:REARM_MIN, [int][math]::Floor($Current / 2)); $act = 'halve'
    $why = ("{0}% over {1} judged, over {2}%" -f $Rate, $Judged, $script:HIGH_PRECISION)
  } elseif ($null -eq $Rate) {
    $why = ("{0} judged, too few to state a precision" -f $Judged)
  } else {
    $why = ("{0}% over {1} judged, inside both bars" -f $Rate, $Judged)
  }
  if ($want -eq $Current) {
    if ($act -ne 'hold') { $why += $(if ($act -eq 'double') { ' - already at the ceiling' } else { ' - already at the floor' }) }
    return @{ Next = $Current; Action = 'hold'; Why = $why }
  }
  $lm = $null
  try { if ($LastMove) { $lm = [datetime]$LastMove } } catch { $lm = $null }
  if ($null -ne $lm -and ($Now - $lm).TotalDays -lt $script:MOVE_EVERY_DAYS) {
    return @{ Next = $Current; Action = 'refused'
              Why = ("would {0} to {1} ({2}), but it moved {3}d ago - one move per {4} days, KEPT at {5}" -f $act, $want, $why, [int]($Now - $lm).TotalDays, $script:MOVE_EVERY_DAYS, $Current) }
  }
  return @{ Next = $want; Action = $act; Why = $why }
}

function Read-TuningDoc {
  <# @{ types = @{ type = @{ rearm_days; last_move; moves = @(...) } } }, from the file or empty. #>
  param([string]$Path)
  $doc = @{ types = @{} }
  if (-not (Test-Path -LiteralPath $Path)) { return $doc }
  $raw = [IO.File]::ReadAllText($Path)
  if (-not $raw.Trim()) { return $doc }
  $j = $raw | ConvertFrom-Json
  if ($j.types) {
    foreach ($p in $j.types.PSObject.Properties) {
      $moves = @()
      if ($p.Value.moves) { $moves = @($p.Value.moves) }
      $doc.types[$p.Name] = @{ rearm_days = [int]$p.Value.rearm_days; last_move = [string]$p.Value.last_move; moves = $moves }
    }
  }
  return $doc
}

if ($SelfTest) {
  $ran = New-Object System.Collections.Generic.List[string]
  $fails = New-Object System.Collections.Generic.List[string]
  function Case([string]$Label, [string]$Name, [bool]$Ok, [string]$Detail = '') {
    [void]$ran.Add($Name)
    if (-not $Ok) { [void]$fails.Add("$Label $Name") }
    Write-Output ("  {0,-14} {1,-66} {2}" -f $Label, $Name, $(if ($Ok) { 'ok' } else { "FAIL $Detail" }))
  }
  $now = [datetime]'2026-10-15T08:00:00'
  $recent = '2026-10-10T12:00:00'

  $m1 = Get-RearmMove -Current 14 -Judged 5 -Rate 20.0 -LastMove '' -LastClose $recent -Now $now
  Case 'MUST FIRE' 'five judged closes at 20% precision double the window from 14 to 28' ($m1.Action -eq 'double' -and $m1.Next -eq 28) "$($m1.Action) $($m1.Next)"
  $m2 = Get-RearmMove -Current 14 -Judged 10 -Rate 90.0 -LastMove '' -LastClose $recent -Now $now
  Case 'MUST FIRE' 'ten judged closes at 90% halve the window from 14 to 7' ($m2.Action -eq 'halve' -and $m2.Next -eq 7) "$($m2.Action) $($m2.Next)"
  $m3 = Get-RearmMove -Current 28 -Judged 6 -Rate 10.0 -LastMove '2026-10-05' -LastClose $recent -Now $now
  Case 'MUST FIRE' 'a second move inside 14 days is REFUSED and the value KEPT' ($m3.Action -eq 'refused' -and $m3.Next -eq 28 -and $m3.Why -match 'KEPT') "$($m3.Action) $($m3.Next)"
  $m4 = Get-RearmMove -Current 14 -Judged 8 -Rate 10.0 -LastMove '' -LastClose '2026-09-01' -Now $now
  Case 'MUST FIRE' 'a type with no close in 30 days is printed, not tuned' ($m4.Action -eq 'stale' -and $m4.Next -eq 14) "$($m4.Action)"

  $m5 = Get-RearmMove -Current 14 -Judged 4 -Rate $null -LastMove '' -LastClose $recent -Now $now
  Case 'MUST NOT FIRE' 'four judged closes (no precision stated) move nothing' ($m5.Action -eq 'hold' -and $m5.Next -eq 14) "$($m5.Action)"
  $m6 = Get-RearmMove -Current 14 -Judged 9 -Rate 95.0 -LastMove '' -LastClose $recent -Now $now
  Case 'MUST NOT FIRE' 'nine judged at 95% do not halve - halving needs ten' ($m6.Action -eq 'hold') "$($m6.Action)"
  $m7 = Get-RearmMove -Current 56 -Judged 20 -Rate 5.0 -LastMove '' -LastClose $recent -Now $now
  Case 'MUST NOT FIRE' 'doubling never passes the 56-day ceiling' ($m7.Next -eq 56 -and $m7.Action -eq 'hold') "$($m7.Next)"
  $m8 = Get-RearmMove -Current 7 -Judged 20 -Rate 99.0 -LastMove '' -LastClose $recent -Now $now
  Case 'MUST NOT FIRE' 'halving never passes the 7-day floor' ($m8.Next -eq 7 -and $m8.Action -eq 'hold') "$($m8.Next)"
  $m9 = Get-RearmMove -Current 14 -Judged 30 -Rate 60.0 -LastMove '' -LastClose $recent -Now $now
  Case 'MUST NOT FIRE' 'precision between the bars moves nothing' ($m9.Action -eq 'hold' -and $m9.Next -eq 14) "$($m9.Action)"
  $m10 = Get-RearmMove -Current 400 -Judged 5 -Rate 20.0 -LastMove '' -LastClose $recent -Now $now
  Case 'MUST NOT FIRE' 'an out-of-range stored value is not trusted - it restarts from 14' ($m10.Next -eq 28) "$($m10.Next)"

  $m11 = Get-RearmMove -Current 14 -Judged 5 -Rate 20.0 -LastMove '2026-09-30' -LastClose $recent -Now $now
  Case 'CLEAN TWIN' 'a move 15 days after the last one is allowed' ($m11.Action -eq 'double' -and $m11.Next -eq 28) "$($m11.Action) $($m11.Next)"
  $items = @(
    [pscustomobject]@{ type = 't'; disposition = 'confirmed'; resolved_ts = $recent },
    [pscustomobject]@{ type = 't'; disposition = 'false-alarm'; resolved_ts = $recent },
    [pscustomobject]@{ type = 't'; disposition = 'false-alarm'; resolved_ts = $recent },
    [pscustomobject]@{ type = 't'; disposition = 'false-alarm'; resolved_ts = $recent },
    [pscustomobject]@{ type = 't'; disposition = 'false-alarm'; resolved_ts = $recent })
  $pr = Get-TcPrecision -Items $items -MinCases 5
  $prRows = @($pr)
  Case 'CLEAN TWIN' 'precision is a PERCENT: 1 right of 5 judged is 20, not 0.2' ($prRows.Count -eq 1 -and [double]$prRows[0].Rate -eq 20.0) "$($prRows[0].Rate)"
  $cac = [IO.File]::ReadAllText((Join-Path $here 'check-ad-cycles.ps1'))
  $b = $cac.IndexOf('<<REVIEW-ACKLOAD-' + 'BEGIN>>'); $e = $cac.IndexOf('<<REVIEW-ACKLOAD-' + 'END>>')
  $region = if ($b -ge 0 -and $e -gt $b) { $cac.Substring($b, $e - $b) } else { '' }
  Case 'CLEAN TWIN' 'check-ad-cycles reads the tuning file INSIDE the region test-auditors runs' ($region.Contains('alert-tuning' + '.json') -and $region.Contains($script:PRICE_FLAG_TYPE)) "region=$($region.Length)"

  Write-Output ''
  if ($fails.Count) {
    Write-Output ("tune-alert-rearm selftest: {0} FAILED of {1}" -f $fails.Count, $ran.Count)
    $fails | ForEach-Object { Write-Output "  $_" }
    Exit-Guard -Name 'ALERT-TUNING-SELFTEST' -Code 1 -Summary "failed=$($fails.Count) cases=$($ran.Count)"
  }
  Write-Output ("tune-alert-rearm selftest: {0} of {0} cases pass" -f $ran.Count)
  Exit-Guard -Name 'ALERT-TUNING-SELFTEST' -Code 0 -Summary "cases=$($ran.Count)"
}

# ------------------------------------------------------------------------------------------------ live
if (-not $QueueFile) { $QueueFile = Join-Path $here 'triage-queue.json' }
if (-not $TuningFile) { $TuningFile = Join-Path $here 'alert-tuning.json' }
if (-not (Test-Path -LiteralPath $QueueFile)) {
  Write-Output ("ALERT TUNING BLIND: {0} does not exist (it is gitignored), so no window was judged and none moved." -f $QueueFile)
  if ($Json) { 'alert-tuning-json: {"known": false}' }
  Exit-Guard -Name 'ALERT-TUNING' -Code 3 -Summary 'blind=no-queue'
}
$q = $null
try { $q = [IO.File]::ReadAllText($QueueFile) | ConvertFrom-Json } catch { $q = $null }
$items = @()
if ($q) { $items = @($q.items) }
if (-not $items.Count) {
  Write-Output 'ALERT TUNING BLIND: the queue did not parse or holds no items. An unreadable queue moves no window.'
  if ($Json) { 'alert-tuning-json: {"known": false}' }
  Exit-Guard -Name 'ALERT-TUNING' -Code 3 -Summary 'blind=no-items'
}

$now = Get-Date
$doc = Read-TuningDoc -Path $TuningFile
$precR = Get-TcPrecision -Items $items -MinCases $script:LOW_MIN_CASES
$prec = @($precR)
$lastClose = @{}
foreach ($it in $items) {
  if (-not ($it.PSObject.Properties['disposition'] -and $it.disposition)) { continue }
  $t = [string]$it.type; $ts = [string]$it.resolved_ts
  if ($ts -and (-not $lastClose.ContainsKey($t) -or $ts -gt $lastClose[$t])) { $lastClose[$t] = $ts }
}

$moved = 0; $refused = 0; $stale = 0; $changed = $false
Write-Output 'ALERT RE-ARM TUNING - the window moves with how often the alert was right'
Write-Output ''
foreach ($r in $prec) {
  $cur = $script:REARM_DEFAULT; $lm = ''
  if ($doc.types.ContainsKey($r.Type)) { $cur = [int]$doc.types[$r.Type].rearm_days; $lm = [string]$doc.types[$r.Type].last_move }
  $lc = if ($lastClose.ContainsKey($r.Type)) { $lastClose[$r.Type] } else { '' }
  $mv = Get-RearmMove -Current $cur -Judged $r.Judged -Rate $r.Rate -LastMove $lm -LastClose $lc -Now $now
  $reads = if ($r.Type -eq $script:PRICE_FLAG_TYPE) { 'read by check-ad-cycles' } else { 'recorded only - nothing re-arms on it' }
  Write-Output ("  {0,-8} {1,2}d -> {2,2}d  {3}  [{4}; {5}]" -f $mv.Action, $cur, $mv.Next, $r.Type, $mv.Why, $reads)
  switch ($mv.Action) {
    'refused' { $refused++ }
    'stale' { $stale++ }
    { $_ -in @('double', 'halve') } {
      $moved++; $changed = $true
      $prev = @()
      if ($doc.types.ContainsKey($r.Type)) { $prev = @($doc.types[$r.Type].moves) }
      $prev += [ordered]@{ date = $now.ToString('s'); from = $cur; to = $mv.Next; action = $mv.Action; precision = $r.Rate; judged = $r.Judged }
      $doc.types[$r.Type] = @{ rearm_days = $mv.Next; last_move = $now.ToString('s'); moves = $prev }
    }
  }
}
$moves30 = 0
foreach ($k in $doc.types.Keys) {
  foreach ($m in @($doc.types[$k].moves)) {
    try { if (($now - [datetime]$m.date).TotalDays -le 30) { $moves30++ } } catch { }
  }
}
Write-Output ''
Write-Output ("  {0} type(s) with dispositions: {1} moved, {2} refused by the rate limit, {3} stale; {4} move(s) on record in 30 days" -f $prec.Count, $moved, $refused, $stale, $moves30)

$absent = -not (Test-Path -LiteralPath $TuningFile)
if (-not $DryRun -and ($changed -or $absent)) {
  $types = [ordered]@{}
  foreach ($k in ($doc.types.Keys | Sort-Object)) {
    $types[$k] = [ordered]@{ rearm_days = $doc.types[$k].rearm_days; last_move = $doc.types[$k].last_move; moves = @($doc.types[$k].moves) }
  }
  $out = [ordered]@{
    note = 'Written by grocery\tune-alert-rearm.ps1 (WS 10b). Per alert type: the re-arm window moved by live precision - doubled under 40% at 5 judged, halved over 80% at 10, clamped 7..56, one move per 14 days. check-ad-cycles.ps1 reads the price-flag row only; a missing or out-of-range row means 14. Edit by hand only to reverse a move, and say so in the move list.'
    types = $types
  }
  [IO.File]::WriteAllText($TuningFile, ($out | ConvertTo-Json -Depth 6) + "`n", (New-Object Text.UTF8Encoding($false)))
  Write-Output ("  written: {0}" -f $TuningFile)
} elseif ($DryRun) { Write-Output '  -DryRun: nothing written' }

if ($Json) {
  'alert-tuning-json: ' + (([ordered]@{ known = $true; types = $prec.Count; moved = $moved; refused = $refused; stale = $stale; moves_30d = $moves30 }) | ConvertTo-Json -Compress)
}
Write-Output 'SCOPE OF A CLEAN REPORT: whether each alert has been RIGHT, never whether it is useful. A refusal is printed, not hidden.'
Exit-Guard -Name 'ALERT-TUNING' -Code 0 -Summary ("types={0} moved={1} refused={2} stale={3}" -f $prec.Count, $moved, $refused, $stale)
