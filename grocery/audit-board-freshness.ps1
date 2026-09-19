<#
  audit-board-freshness.ps1 - IS EVERY STORE STILL BEING RE-READ, AND ARE ITS PRICES INSIDE THE PUBLISH LIMIT?

  THE FLOOR THIS ESTATE DID NOT HAVE (2026-09-19). Every threshold in the chain was an UPPER bound, so none could
  fire on nothing happening (ops-and-gates.md, backlog I80). Between 2026-08-15 and 2026-09-17 the board's measured
  defect rate went from 18.2% to 37.1% (36 defects in 100 verified), and the causes were all a producer that STOPPED
  or SLOWED while every job still read green:
    - the 2026-08-20 policy re-read each store's list once every ~86 days, and nothing measured what that did;
    - from 2026-09-13 to 09-18 the unattended Fareway and Sam's captures logged "worklist is empty" and read nothing;
    - the Chrome capture that is the ONLY road for Walmart and Aldi stopped on 09-13 (a usage limit), then sat at
      "Manual only", and no watcher looked at it;
    - the capture write had raised NameError since 2026-09-12, hidden only because no run had terms to write.
  One question catches every one of those, whatever the cause: for each store, when was the newest price READ, and
  what share of what the board judged was withheld for being too old? design\PLAN-board-accuracy-2026-09-19.md.

  INPUTS: the newest out\comparison-*.json (each captured cell carries as_of since the provenance contract) and
  out\provenance-withheld-<board date>.json (every row the contract withheld, with its reason and as_of).

  FINDINGS start with '!' (the chain's convention, see audit-row-age):
    ! PRODUCER STOPPED   a store's newest read is more than ProducerStopDays before the board date.
    ! AGING              more than StaleShareMax of the store's judged captured rows were withheld STALE/UNDATED.
    ! BLIND              the board carries no provenance record, so freshness cannot be judged at all.

  THE CONSTANTS, AND WHAT ELSE WAS TRIED (ops-and-gates.md I94): both are the FIRST PLAUSIBLE numbers, not the
  survivors of a sweep. ProducerStopDays = 3: every store is captured daily, so 3 tolerates one missed run and a
  weekend-sized gap, and would have fired on 2026-09-16 for the stop that began 09-13. StaleShareMax = 0.10: with the
  rotation sized to re-read every term inside the publish limit (capture-policy's capacity invariant), a healthy store
  withholds close to nothing for age; 10% leaves room for a single missed day. Tighten either with evidence.
  WHAT THE NUMBERS DO WHEN THE PRODUCER STOPS: the newest read stops moving, so PRODUCER STOPPED fires within
  ProducerStopDays; the stale share climbs daily, so AGING follows. That is the point of both.

  SCOPE OF A CLEAN REPORT: sound for the two questions it asks, over the stores that appear in the board or the
  withheld file. It is blind to a store that vanished from both entirely (such a store also has no cells, which
  the coverage-regression guard reports). A finding is complete: the dates it compares are the dates on the rows.

  Usage:  audit-board-freshness.ps1 [-OutDir <grocery\out>]      exit 0, findings on stdout (the chain alerts)
          audit-board-freshness.ps1 -SelfTest
#>
param([string]$OutDir = '', [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:ProducerStopDays = 3
$script:StaleShareMax = 0.10

# One pure function over the two documents, so the self-test drives exactly what production runs.
function Get-BoardFreshness($Board, $Withheld, [int]$StopDays, [double]$ShareMax) {
  $lines = New-Object System.Collections.Generic.List[string]
  $findings = 0
  if (-not $Board) { [void]$lines.Add('! BLIND  no board to judge'); return [pscustomobject]@{ lines = $lines.ToArray(); findings = 1; stores = 0 } }
  $bd = [string]$Board.week_of
  if (-not $Withheld -or [string]$Board.provenance_contract -ne 'on') {
    [void]$lines.Add("! BLIND  the $bd board carries no provenance record (provenance_contract='" + [string]$Board.provenance_contract + "'), so how old its prices are cannot be judged")
    return [pscustomobject]@{ lines = $lines.ToArray(); findings = 1; stores = 0 }
  }
  $boardD = [datetime]::ParseExact($bd, 'yyyy-MM-dd', $null)
  $newest = @{}; $published = @{}
  foreach ($r in @($Board.comparison)) {
    foreach ($s in @($r.stores)) {
      $st = [string]$s.store
      if (-not $published.ContainsKey($st)) { $published[$st] = 0 }
      if ([string]$s.as_of -match '^\d{4}-\d{2}-\d{2}$') {
        $published[$st]++
        if (-not $newest.ContainsKey($st) -or [string]$s.as_of -gt $newest[$st]) { $newest[$st] = [string]$s.as_of }
      }
    }
  }
  $stale = @{}
  foreach ($w in @($Withheld.withheld)) {
    $st = [string]$w.store
    if ([string]$w.as_of -match '^\d{4}-\d{2}-\d{2}$' -and (-not $newest.ContainsKey($st) -or [string]$w.as_of -gt $newest[$st])) { $newest[$st] = [string]$w.as_of }
    if (@('STALE', 'UNDATED') -contains [string]$w.why) { $stale[$st] = 1 + $(if ($stale.ContainsKey($st)) { $stale[$st] } else { 0 }) }
  }
  $judged = @{}
  if ($Withheld.judged) { foreach ($p in $Withheld.judged.PSObject.Properties) { $judged[$p.Name] = [int]$p.Value } }
  $stores = @(@($judged.Keys) + @($published.Keys) | Select-Object -Unique | Sort-Object)
  foreach ($st in $stores) {
    $j = if ($judged.ContainsKey($st)) { $judged[$st] } else { 0 }
    $sN = if ($stale.ContainsKey($st)) { $stale[$st] } else { 0 }
    $share = if ($j -gt 0) { $sN / [double]$j } else { 0.0 }
    $nw = if ($newest.ContainsKey($st)) { $newest[$st] } else { '' }
    $age = if ($nw) { [int]($boardD - [datetime]::ParseExact($nw, 'yyyy-MM-dd', $null)).TotalDays } else { $null }
    $pub = if ($published.ContainsKey($st)) { $published[$st] } else { 0 }
    [void]$lines.Add(("  {0,-12} newest read {1} ({2} d before the board); {3} captured cell(s) published; withheld for age {4} of {5} judged row(s) ({6:P0})" -f $st, $(if ($nw) { $nw } else { 'NONE' }), $(if ($null -ne $age) { $age } else { '-' }), $pub, $sN, $j, $share))
    if ($j -gt 0 -and ($null -eq $age -or $age -gt $StopDays)) {
      [void]$lines.Add(("! PRODUCER STOPPED  {0}: newest price read {1}, more than {2} day(s) before the {3} board - its capture is not landing" -f $st, $(if ($nw) { "$nw ($age d)" } else { 'never' }), $StopDays, $bd)); $findings++
    }
    if ($j -gt 0 -and $share -gt $ShareMax) {
      [void]$lines.Add(("! AGING  {0}: {1} of {2} judged row(s) ({3:P0}) withheld as older than the publish limit (max {4:P0}) - the rotation is not re-reading this store fast enough" -f $st, $sN, $j, $share, $ShareMax)); $findings++
    }
  }
  return [pscustomobject]@{ lines = $lines.ToArray(); findings = $findings; stores = $stores.Count }
}

if ($SelfTest) {
  $n = 0; $bad = 0
  function _T([string]$label, [bool]$ok, [string]$got) { $script:n++; if ($ok) { Write-Output ('  ok    ' + $label) } else { $script:bad++; Write-Output ('  FAIL  ' + $label + '   got: ' + $got) } }
  function _Board([string]$date, [object[]]$cells, [string]$pc = 'on') {
    $rows = @(foreach ($c in $cells) { [pscustomobject]@{ id = $c[0]; stores = @([pscustomobject]@{ store = $c[1]; as_of = $c[2] }) } })
    [pscustomobject]@{ week_of = $date; provenance_contract = $pc; comparison = $rows }
  }
  function _Wh([hashtable]$judged, [object[]]$rows) {
    [pscustomobject]@{ judged = [pscustomobject]$judged; withheld = @(foreach ($r in $rows) { [pscustomobject]@{ store = $r[0]; why = $r[1]; as_of = $r[2] } }) }
  }
  try {
    $B = '2026-09-17'
    # healthy: read yesterday, nothing stale
    $ok = Get-BoardFreshness (_Board $B @(,@('milk', 'Aldi', '2026-09-16'))) (_Wh @{ Aldi = 50 } @()) 3 0.10
    _T 'MUST NOT FIRE  a store read yesterday with nothing withheld for age raises nothing' ($ok.findings -eq 0) (($ok.lines) -join ' | ')
    # at the bar: newest exactly 3 days old
    $at = Get-BoardFreshness (_Board $B @(,@('milk', 'Aldi', '2026-09-14'))) (_Wh @{ Aldi = 50 } @()) 3 0.10
    _T 'MUST NOT FIRE  newest read exactly 3 days before the board (the bar) is not a stopped producer' ($at.findings -eq 0) (($at.lines) -join ' | ')
    $past = Get-BoardFreshness (_Board $B @(,@('milk', 'Aldi', '2026-09-13'))) (_Wh @{ Aldi = 50 } @()) 3 0.10
    _T 'MUST FIRE  newest read 4 days before the board (one day past the bar) is PRODUCER STOPPED - the 2026-09-13 stop' (@($past.lines | Where-Object { $_ -match '^! PRODUCER STOPPED  Aldi: newest price read 2026-09-13 \(4 d\)' }).Count -eq 1) (($past.lines) -join ' | ')
    # every row withheld, nothing published: the store still counts as judged, and its newest read comes from the withheld rows
    $gone = Get-BoardFreshness (_Board $B @()) (_Wh @{ "Sam's Club" = 20 } @(@("Sam's Club", 'STALE', '2026-08-15'), @("Sam's Club", 'STALE', '2026-08-20'))) 3 0.10
    _T 'MUST FIRE  a store whose every row was withheld still reports, from the withheld rows, as PRODUCER STOPPED' (@($gone.lines | Where-Object { $_ -match "^! PRODUCER STOPPED  Sam's Club: newest price read 2026-08-20" }).Count -eq 1) (($gone.lines) -join ' | ')
    # aging share at and past its bar
    $wh10 = @(1..5 | ForEach-Object { ,@('Walmart', 'STALE', '2026-08-30') })
    $sAt = Get-BoardFreshness (_Board $B @(,@('eggs', 'Walmart', '2026-09-17'))) (_Wh @{ Walmart = 50 } $wh10) 3 0.10
    _T 'MUST NOT FIRE  exactly 10% withheld for age (5 of 50, the bar) is not AGING' (@($sAt.lines | Where-Object { $_ -match '^! AGING' }).Count -eq 0) (($sAt.lines) -join ' | ')
    $wh6 = @(1..6 | ForEach-Object { ,@('Walmart', 'STALE', '2026-08-30') })
    $sPast = Get-BoardFreshness (_Board $B @(,@('eggs', 'Walmart', '2026-09-17'))) (_Wh @{ Walmart = 50 } $wh6) 3 0.10
    _T 'MUST FIRE  6 of 50 (12%, one row past the bar) withheld for age is AGING' (@($sPast.lines | Where-Object { $_ -match '^! AGING  Walmart' }).Count -eq 1) (($sPast.lines) -join ' | ')
    $wrongStore = Get-BoardFreshness (_Board $B @(,@('eggs', 'Hy-Vee', '2026-09-17'))) (_Wh @{ 'Hy-Vee' = 50 } @(1..20 | ForEach-Object { ,@('Hy-Vee', 'WRONG-STORE', '2026-09-10') })) 3 0.10
    _T 'CLEAN TWIN  rows withheld for a reason other than age (WRONG-STORE) do not count toward AGING' (@($wrongStore.lines | Where-Object { $_ -match '^! AGING' }).Count -eq 0) (($wrongStore.lines) -join ' | ')
    $blind = Get-BoardFreshness (_Board $B @(,@('milk', 'Aldi', '2026-09-16')) 'OFF') $null 3 0.10
    _T 'MUST FIRE  a board built without the provenance contract is BLIND, never a clean report' (@($blind.lines | Where-Object { $_ -match '^! BLIND' }).Count -eq 1) (($blind.lines) -join ' | ')
  } catch { _T 'the self-test ran to its end with no unexpected error' $false ($_.Exception.Message + ' line ' + $_.InvocationInfo.ScriptLineNumber) }
  Write-Output ('audit-board-freshness SELF-TEST {0} ({1} of {2} failed)' -f $(if ($bad) { 'FAIL' } else { 'PASS' }), $bad, $n)
  if ($bad) { exit 1 }
  exit 0
}

if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$bf = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^comparison-\d{4}-\d{2}-\d{2}\.json$' } | Sort-Object Name -Descending | Select-Object -First 1
$board = if ($bf) { [IO.File]::ReadAllText($bf.FullName) | ConvertFrom-Json } else { $null }
$wh = $null
if ($board) {
  $wf = Join-Path $OutDir ('provenance-withheld-' + [string]$board.week_of + '.json')
  if (Test-Path -LiteralPath $wf) { $wh = [IO.File]::ReadAllText($wf) | ConvertFrom-Json }
}
$res = Get-BoardFreshness $board $wh $script:ProducerStopDays $script:StaleShareMax
Write-Output ("board freshness: " + $(if ($bf) { $bf.Name } else { 'no board' }) + " (producer-stop floor " + $script:ProducerStopDays + " d, age-withheld ceiling " + ('{0:P0}' -f $script:StaleShareMax) + ")")
foreach ($l in $res.lines) { Write-Output $l }
Write-Output ('BOARD-FRESHNESS-COMPLETE stores=' + $res.stores + ' findings=' + $res.findings)
exit 0
