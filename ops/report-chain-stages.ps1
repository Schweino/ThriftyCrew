<#
  report-chain-stages.ps1 - where a board run's wall clock actually went, derived from the chain's own log.

  WHY THIS EXISTS. check-ad-cycles prints ONE total for the ship path and one for the advisory fan-out, and
  nothing for the stages around them. On 2026-09-19 that left 19 minutes of a 37-minute run unattributed, and
  two sessions in a row reasoned about "the slow part" from a profile taken in August against code that had
  since been made 17x faster. A number nobody can attribute is a number nobody can optimise.

  TWO SOURCES, AND IT SAYS WHICH IT USED. Since 2026-09-19 check-ad-cycles' own Log writes a stage clock to
  grocery\out\logs\chain-stages-<date>.jsonl - one row per logged line, carrying the gap before it. When that
  file covers the run, this reads it. When it does not (any run before that change, or a day whose file was
  pruned), it falls back to the log's own timestamps: every line is stamped, so the silence BETWEEN two lines
  is the work after the first one spoke. Both give the same arithmetic; the JSONL is simply not guessing about
  lines the log never wrote.

  SCOPE OF A CLEAN REPORT: this is UNSOUND as a profiler. It attributes a gap to the stage that spoke LAST,
  which is wrong whenever a stage logs nothing at its start, spawns children that log on their own, or runs
  concurrently with another (the INSPECT fan-out is 8-way, so its gap is wall clock and not CPU). Treat a big
  row as "the run was silent here, starting after this line", and confirm any stage you intend to optimise by
  timing it directly. A stage that never logs at all is invisible to this and will inflate its predecessor.

      powershell -NoProfile -File ops\report-chain-stages.ps1                      # the newest run in the log
      powershell -NoProfile -File ops\report-chain-stages.ps1 -Top 25
      powershell -NoProfile -File ops\report-chain-stages.ps1 -Date 2026-09-19 -Run 2
#>
[CmdletBinding()]
param(
  [string]$LogFile = '',
  [string]$Date = '',          # yyyy-MM-dd; default: the date of the newest 'run complete' line
  [int]$Run = 0,               # which run of that date, 1-based in time order; default: the last
  [int]$Top = 15,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'

function Get-StageClockGaps {
  # Rows are check-ad-cycles' own stage clock: one JSON object per logged line, `secs` being the gap BEFORE
  # that line. A gap therefore belongs to whatever spoke previously, which is the same charging rule the
  # adjacency reader uses - so the two sources are directly comparable and the report can say which it used.
  param([string[]]$Rows, [datetime]$From, [datetime]$To)
  $parsed = New-Object System.Collections.Generic.List[object]
  foreach ($l in $Rows) {
    if (-not ("$l").Trim()) { continue }
    try { $o = $l | ConvertFrom-Json } catch { continue }
    if (-not $o.at) { continue }
    $t = [datetime]::Parse([string]$o.at)
    if ($t -lt $From -or $t -gt $To) { continue }
    $head = [string]$o.head
    $tag = if ($head -match '^([^:]{1,44}):') { $matches[1].Trim() } else { ($head -split '\s+' | Select-Object -First 4) -join ' ' }
    $parsed.Add([pscustomobject]@{ at = $t; tag = $tag; secs = [double]$o.secs })
  }
  $out = New-Object System.Collections.Generic.List[object]
  for ($i = 1; $i -lt $parsed.Count; $i++) {
    if ($parsed[$i].secs -le 0) { continue }
    $out.Add([pscustomobject]@{ seconds = [math]::Round($parsed[$i].secs); at = $parsed[$i-1].at; after = $parsed[$i-1].tag; before = $parsed[$i].tag })
  }
  return ,$out.ToArray()
}

function Get-ChainStageGaps {
  param([string[]]$Lines, [datetime]$From, [datetime]$To)
  $rx = [regex]'^\[(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})\]\s*(.*)$'
  $ev = New-Object System.Collections.Generic.List[object]
  foreach ($line in $Lines) {
    $m = $rx.Match($line)
    if (-not $m.Success) { continue }
    $t = [datetime]::ParseExact($m.Groups[1].Value + ' ' + $m.Groups[2].Value, 'yyyy-MM-dd HH:mm:ss', $null)
    if ($t -lt $From -or $t -gt $To) { continue }
    $rest = $m.Groups[3].Value
    # the chain writes "<stage>: <text>"; keep the stage, else the first few words
    $tag = if ($rest -match '^([^:]{1,44}):') { $matches[1].Trim() } else { ($rest -split '\s+' | Select-Object -First 4) -join ' ' }
    $ev.Add([pscustomobject]@{ at = $t; tag = $tag; text = $rest })
  }
  $out = New-Object System.Collections.Generic.List[object]
  for ($i = 1; $i -lt $ev.Count; $i++) {
    $secs = ($ev[$i].at - $ev[$i-1].at).TotalSeconds
    if ($secs -le 0) { continue }
    $out.Add([pscustomobject]@{ seconds = [math]::Round($secs); at = $ev[$i-1].at; after = $ev[$i-1].tag; before = $ev[$i].tag })
  }
  return ,$out.ToArray()
}

if ($SelfTest) {
  $fails = 0
  function T([string]$label, [bool]$ok) { if ($ok) { Write-Output "  ok    $label" } else { Write-Output "  FAIL  $label"; $script:fails++ } }
  $script:fails = 0

  # MUST FIRE: a silence between two stamped lines is attributed to the line BEFORE it, with its length.
  $fix = @(
    '[2026-09-19T17:00:00] alpha: started',
    '[2026-09-19T17:00:10] beta: started',
    '[2026-09-19T17:05:10] gamma: started'
  )
  $g = Get-ChainStageGaps -Lines $fix -From ([datetime]'2026-09-19T16:00:00') -To ([datetime]'2026-09-19T18:00:00')
  T 'two gaps found from three stamped lines' ($g.Count -eq 2)
  $biggest = $g | Sort-Object seconds -Descending | Select-Object -First 1
  T 'the 300s silence is attributed to beta, the stage that spoke before it' ($biggest.seconds -eq 300 -and $biggest.after -eq 'beta')
  T 'the 10s gap is attributed to alpha' (($g | Where-Object { $_.after -eq 'alpha' }).seconds -eq 10)

  # MUST NOT FIRE: lines outside the window contribute nothing, so a run cannot inherit the previous run's silence.
  $g2 = Get-ChainStageGaps -Lines $fix -From ([datetime]'2026-09-19T17:00:05') -To ([datetime]'2026-09-19T17:00:20')
  T 'a window that holds one line yields no gaps' ($g2.Count -eq 0)

  # MUST FIRE, the stage-clock reader: the same 300s silence, read from check-ad-cycles' own rows rather than
  # guessed from adjacency, lands on the same stage with the same number - which is what lets the report claim
  # the two sources are comparable.
  $clk = @(
    '{"at":"2026-09-19T17:00:00","secs":0,"head":"alpha: started"}',
    '{"at":"2026-09-19T17:00:10","secs":10,"head":"beta: started"}',
    '{"at":"2026-09-19T17:05:10","secs":300,"head":"gamma: started"}'
  )
  $gc = Get-StageClockGaps -Rows $clk -From ([datetime]'2026-09-19T16:00:00') -To ([datetime]'2026-09-19T18:00:00')
  $gcBig = $gc | Sort-Object seconds -Descending | Select-Object -First 1
  T 'stage clock: the 300s gap is charged to beta, exactly as adjacency charges it' ($gcBig.seconds -eq 300 -and $gcBig.after -eq 'beta')
  T 'stage clock: a malformed row is skipped rather than killing the read' ((Get-StageClockGaps -Rows (@('not json') + $clk) -From ([datetime]'2026-09-19T16:00:00') -To ([datetime]'2026-09-19T18:00:00')).Count -eq 2)

  # MUST NOT FIRE: rows outside the window contribute nothing, so yesterday's clock cannot inflate today's run.
  T 'stage clock: rows outside the run window are ignored' ((Get-StageClockGaps -Rows $clk -From ([datetime]'2026-09-19T17:00:05') -To ([datetime]'2026-09-19T17:00:20')).Count -eq 0)

  # CLEAN TWIN: an unstamped line (a child`s own multi-line output) is skipped, not mis-parsed into a zero-time stage.
  $fix2 = @('[2026-09-19T17:00:00] alpha: started', 'continuation of alpha with no timestamp', '[2026-09-19T17:00:30] beta: started')
  $g3 = Get-ChainStageGaps -Lines $fix2 -From ([datetime]'2026-09-19T16:00:00') -To ([datetime]'2026-09-19T18:00:00')
  T 'an unstamped continuation line is ignored and the 30s still lands on alpha' ($g3.Count -eq 1 -and $g3[0].after -eq 'alpha' -and $g3[0].seconds -eq 30)

  if ($script:fails -eq 0) { Write-Output "report-chain-stages self-test: PASS ($script:fails failure(s))"; exit 0 }
  Write-Output "report-chain-stages SELF-TEST FAIL: $script:fails failure(s)"; exit 1
}

$root = Split-Path $PSScriptRoot -Parent
if (-not $LogFile) { $LogFile = Join-Path $root 'grocery\ad-cycle-log.txt' }
if (-not (Test-Path $LogFile)) { Write-Output "report-chain-stages: no log at $LogFile"; exit 3 }

$lines = Get-Content $LogFile
$completes = @($lines | Select-String -Pattern '^\[(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})\] run complete;.*total=(\d+)s' -AllMatches)
if (-not $completes.Count) { Write-Output 'report-chain-stages: the log holds no "run complete" line, so no run can be bounded'; exit 3 }

$runs = foreach ($c in $completes) {
  $m = [regex]::Match($c.Line, '^\[(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})\] run complete;.*total=(\d+)s')
  [pscustomobject]@{
    end   = [datetime]::ParseExact($m.Groups[1].Value + ' ' + $m.Groups[2].Value, 'yyyy-MM-dd HH:mm:ss', $null)
    total = [int]$m.Groups[3].Value
    date  = $m.Groups[1].Value
  }
}
$runs = @($runs | Sort-Object end)
if ($Date) { $runs = @($runs | Where-Object { $_.date -eq $Date }) }
if (-not $runs.Count) { Write-Output "report-chain-stages: no run complete line for date '$Date'"; exit 3 }
$pick = if ($Run -gt 0) { if ($Run -gt $runs.Count) { Write-Output "report-chain-stages: asked for run $Run of $($runs.Count)"; exit 3 }; $runs[$Run-1] } else { $runs[-1] }

$from = $pick.end.AddSeconds(-1 * $pick.total)

# PREFER THE STAGE CLOCK when it covers this run (see the header). It is the same arithmetic without the
# adjacency guess, and it is only a preference: a run older than the clock still reports from the log.
$source = 'log adjacency'
$gaps = $null
$clockPath = Join-Path (Split-Path $LogFile -Parent) ('out\logs\chain-stages-' + $pick.date + '.jsonl')
if (Test-Path $clockPath) {
  $clockRows = @(Get-Content $clockPath -ErrorAction SilentlyContinue)
  $fromClock = Get-StageClockGaps -Rows $clockRows -From $from -To $pick.end
  if (@($fromClock).Count -gt 0) {
    $gaps = $fromClock
    $source = "stage clock ($([IO.Path]::GetFileName($clockPath)))"
  }
}
if (-not $gaps) { $gaps = Get-ChainStageGaps -Lines $lines -From $from -To $pick.end }
Write-Output ("run ending {0}, total {1}s ({2:N1} min), window {3} -> {4}" -f $pick.end.ToString('yyyy-MM-dd HH:mm:ss'), $pick.total, ($pick.total/60), $from.ToString('HH:mm:ss'), $pick.end.ToString('HH:mm:ss'))
Write-Output ("source: {0}; {1} stamped point(s) in the window. A gap is charged to the stage that spoke BEFORE it (see this file's SCOPE line)" -f $source, (@($gaps).Count + 1))
Write-Output ''
$byStage = $gaps | Group-Object after | ForEach-Object {
  [pscustomobject]@{ seconds = [int](($_.Group | Measure-Object seconds -Sum).Sum); stage = $_.Name; gaps = $_.Count }
} | Sort-Object seconds -Descending
$sum = ($gaps | Measure-Object seconds -Sum).Sum
Write-Output ("silence charged to each stage, top {0} of {1} stage(s); {2}s of the {3}s run is between stamped lines:" -f $Top, @($byStage).Count, [int]$sum, $pick.total)
foreach ($s in ($byStage | Select-Object -First $Top)) {
  Write-Output ("  {0,7}s  {1,5:N1}%  {2}  ({3} gap(s))" -f $s.seconds, (100.0*$s.seconds/[math]::Max(1,$pick.total)), $s.stage, $s.gaps)
}
Write-Output ''
Write-Output 'single longest silences:'
foreach ($g in ($gaps | Sort-Object seconds -Descending | Select-Object -First 5)) {
  Write-Output ("  {0,7}s  from {1}  after [{2}]  ->  [{3}]" -f $g.seconds, $g.at.ToString('HH:mm:ss'), $g.after, $g.before)
}
Write-Output 'REPORT-CHAIN-STAGES-COMPLETE'
exit 0
