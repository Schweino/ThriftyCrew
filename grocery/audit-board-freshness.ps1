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
    ! PRODUCER STOPPED   a store's newest read is more than ProducerStopDays before TODAY (never the board's week_of).
    ! AGING              more than StaleShareMax of the store's judged captured rows were withheld STALE/UNDATED.
    ! REPRICE OWED       a sale or rollback ended and the store's re-read of that item is owed more than RepriceOwedDays
                         (2026-09-26, design\PLAN-board-clock-2026-09-26.md W8, Brad's D2: "it should be part of the
                         automated job to detect that and fix the price on the day after the sale"). build-sale-windows
                         writes refresh_on = end + 1, capture-policy puts the item at the head of that store's next
                         capture, and a landed capture marks repriced_for. An entry still owed days later means that
                         loop did not close - the throttle ate it, or the store's capture is not landing - and until it
                         does the item's cell falls back to the store's everyday price or to nothing. Input: the
                         grocery root's sale-windows.json (-SaleWindowsFile in fixtures).
                         RepriceOwedDays = 3, on ProducerStopDays' reasoning: every store is captured daily and
                         expiries lead its worklist, so 3 tolerates one missed run and a weekend-sized gap. On
                         2026-09-26 0 of 423 windows were owed, so it is not red on its first run.
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
# WHAT THE SELF-TEST READS: only in-memory fixture boards; the real board is read below the self-test branch.
# gate-inputs: grocery\audit-board-freshness.ps1, lib\board-clock.ps1, lib\json-io.ps1
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([string]$OutDir = '', [string]$SaleWindowsFile = '', [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path (Split-Path $root -Parent) 'lib\board-clock.ps1')   # Get-TcBoardNewestReads, Get-TcDaysSince: the one walk, measured to a real date
$script:ProducerStopDays = 3
$script:StaleShareMax = 0.10
$script:RepriceOwedDays = 3

# The re-prices a store still owes more than $OwedDays after its sale or rollback ended. An entry is owed while
# refresh_on <= today and repriced_for <> refresh_on - the SAME test capture-policy-lib's SaleExpiries uses, so this
# can never call "owed" what the worklist calls done. Returns lines ('! REPRICE OWED ...') and a finding count.
function Get-RepriceOwed($SaleWindows, [int]$OwedDays, [datetime]$Now) {
  $lines = New-Object System.Collections.Generic.List[string]
  $by = @{}
  foreach ($w in @($SaleWindows.windows)) {
    if ($null -eq $w) { continue }
    $ro = [string]$w.refresh_on
    if ($ro -notmatch '^\d{4}-\d{2}-\d{2}$') { continue }
    if ([string]::Equals([string]$w.repriced_for, $ro, [StringComparison]::Ordinal)) { continue }   # done for THIS window
    $age = Get-TcDaysSince $ro $Now
    if ($null -eq $age -or $age -le $OwedDays) { continue }   # not yet due, or due and still inside the bar
    $st = [string]$w.store
    if (-not $by.ContainsKey($st)) { $by[$st] = New-Object System.Collections.Generic.List[object] }
    $by[$st].Add([pscustomobject]@{ id = [string]$w.id; refresh_on = $ro; age = $age })
  }
  foreach ($st in @($by.Keys | Sort-Object)) {
    $g = @($by[$st].ToArray() | Sort-Object refresh_on, id)
    [void]$lines.Add(("! REPRICE OWED  {0}: {1} ended sale(s) not re-read more than {2} day(s) after they ended (oldest refresh_on {3}, {4} d): {5}" -f $st, $g.Count, $OwedDays, $g[0].refresh_on, $g[0].age, ((@($g | Select-Object -First 12) | ForEach-Object { $_.id }) -join ', ')))
  }
  return [pscustomobject]@{ lines = $lines.ToArray(); findings = $by.Count }
}

# One pure function over the two documents, so the self-test drives exactly what production runs.
# $Now IS THE REAL DATE, NEVER THE BOARD'S week_of (2026-09-26, design\PLAN-board-clock-2026-09-26.md). week_of is the
# ad set the board is for and lags the real date whenever no weekly ad is due - 3 days on 2026-09-26 - and measuring
# PRODUCER STOPPED against it read a stopped store up to that lag FRESHER than it was, in the one check whose job is
# catching a stopped feed. Production passes today; fixtures pass a literal. The per-store newest read is
# lib\board-clock.ps1's walk (board cells and withheld rows), the one copy of it.
function Get-BoardFreshness($Board, $Withheld, [int]$StopDays, [double]$ShareMax, [datetime]$Now) {
  $lines = New-Object System.Collections.Generic.List[string]
  $findings = 0
  if (-not $Board) { [void]$lines.Add('! BLIND  no board to judge'); return [pscustomobject]@{ lines = $lines.ToArray(); findings = 1; stores = 0 } }
  $bd = [string]$Board.week_of
  if (-not $Withheld -or [string]$Board.provenance_contract -ne 'on') {
    [void]$lines.Add("! BLIND  the $bd board carries no provenance record (provenance_contract='" + [string]$Board.provenance_contract + "'), so how old its prices are cannot be judged")
    return [pscustomobject]@{ lines = $lines.ToArray(); findings = 1; stores = 0 }
  }
  $nowS = $Now.ToString('yyyy-MM-dd')
  $reads = Get-TcBoardNewestReads $Board $Withheld
  $newest = $reads.by_store; $published = $reads.published
  $stale = @{}
  foreach ($w in @($Withheld.withheld)) {
    $st = [string]$w.store
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
    $age = Get-TcDaysSince $nw $Now
    $pub = if ($published.ContainsKey($st)) { $published[$st] } else { 0 }
    [void]$lines.Add(("  {0,-12} newest read {1} ({2} d before {7}); {3} captured cell(s) published; withheld for age {4} of {5} judged row(s) ({6:P0})" -f $st, $(if ($nw) { $nw } else { 'NONE' }), $(if ($null -ne $age) { $age } else { '-' }), $pub, $sN, $j, $share, $nowS))
    if ($j -gt 0 -and ($null -eq $age -or $age -gt $StopDays)) {
      [void]$lines.Add(("! PRODUCER STOPPED  {0}: newest price read {1}, more than {2} day(s) before today ({3}; the board is for the {4} ad set) - its capture is not landing" -f $st, $(if ($nw) { "$nw ($age d)" } else { 'never' }), $StopDays, $nowS, $bd)); $findings++
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
    $ok = Get-BoardFreshness (_Board $B @(,@('milk', 'Aldi', '2026-09-16'))) (_Wh @{ Aldi = 50 } @()) 3 0.10 ([datetime]$B)
    _T 'MUST NOT FIRE  a store read yesterday with nothing withheld for age raises nothing' ($ok.findings -eq 0) (($ok.lines) -join ' | ')
    # at the bar: newest exactly 3 days old
    $at = Get-BoardFreshness (_Board $B @(,@('milk', 'Aldi', '2026-09-14'))) (_Wh @{ Aldi = 50 } @()) 3 0.10 ([datetime]$B)
    _T 'MUST NOT FIRE  newest read exactly 3 days before the board (the bar) is not a stopped producer' ($at.findings -eq 0) (($at.lines) -join ' | ')
    $past = Get-BoardFreshness (_Board $B @(,@('milk', 'Aldi', '2026-09-13'))) (_Wh @{ Aldi = 50 } @()) 3 0.10 ([datetime]$B)
    _T 'MUST FIRE  newest read 4 days before the board (one day past the bar) is PRODUCER STOPPED - the 2026-09-13 stop' (@($past.lines | Where-Object { $_ -match '^! PRODUCER STOPPED  Aldi: newest price read 2026-09-13 \(4 d\)' }).Count -eq 1) (($past.lines) -join ' | ')
    # every row withheld, nothing published: the store still counts as judged, and its newest read comes from the withheld rows
    $gone = Get-BoardFreshness (_Board $B @()) (_Wh @{ "Sam's Club" = 20 } @(@("Sam's Club", 'STALE', '2026-08-15'), @("Sam's Club", 'STALE', '2026-08-20'))) 3 0.10 ([datetime]$B)
    _T 'MUST FIRE  a store whose every row was withheld still reports, from the withheld rows, as PRODUCER STOPPED' (@($gone.lines | Where-Object { $_ -match "^! PRODUCER STOPPED  Sam's Club: newest price read 2026-08-20" }).Count -eq 1) (($gone.lines) -join ' | ')
    # aging share at and past its bar
    $wh10 = @(1..5 | ForEach-Object { ,@('Walmart', 'STALE', '2026-08-30') })
    $sAt = Get-BoardFreshness (_Board $B @(,@('eggs', 'Walmart', '2026-09-17'))) (_Wh @{ Walmart = 50 } $wh10) 3 0.10 ([datetime]$B)
    _T 'MUST NOT FIRE  exactly 10% withheld for age (5 of 50, the bar) is not AGING' (@($sAt.lines | Where-Object { $_ -match '^! AGING' }).Count -eq 0) (($sAt.lines) -join ' | ')
    $wh6 = @(1..6 | ForEach-Object { ,@('Walmart', 'STALE', '2026-08-30') })
    $sPast = Get-BoardFreshness (_Board $B @(,@('eggs', 'Walmart', '2026-09-17'))) (_Wh @{ Walmart = 50 } $wh6) 3 0.10 ([datetime]$B)
    _T 'MUST FIRE  6 of 50 (12%, one row past the bar) withheld for age is AGING' (@($sPast.lines | Where-Object { $_ -match '^! AGING  Walmart' }).Count -eq 1) (($sPast.lines) -join ' | ')
    $wrongStore = Get-BoardFreshness (_Board $B @(,@('eggs', 'Hy-Vee', '2026-09-17'))) (_Wh @{ 'Hy-Vee' = 50 } @(1..20 | ForEach-Object { ,@('Hy-Vee', 'WRONG-STORE', '2026-09-10') })) 3 0.10 ([datetime]$B)
    _T 'MUST NOT FIRE  rows withheld for a reason other than age (WRONG-STORE) do not count toward AGING' (@($wrongStore.lines | Where-Object { $_ -match '^! AGING' }).Count -eq 0) (($wrongStore.lines) -join ' | ')
    $blind = Get-BoardFreshness (_Board $B @(,@('milk', 'Aldi', '2026-09-16')) 'OFF') $null 3 0.10 ([datetime]$B)
    _T 'MUST FIRE  a board built without the provenance contract is BLIND, never a clean report' (@($blind.lines | Where-Object { $_ -match '^! BLIND' }).Count -eq 1) (($blind.lines) -join ' | ')
    # THE LAG (2026-09-26, PLAN-board-clock). The board is for the 09-23 ad set and no ad was due since. Measured against
    # week_of, a store last read 09-22 was 1 day old; it is 4 days old on 09-26, one past the 3-day bar.
    $lag = Get-BoardFreshness (_Board '2026-09-23' @(,@('milk', 'Aldi', '2026-09-22'))) (_Wh @{ Aldi = 50 } @()) 3 0.10 ([datetime]'2026-09-26')
    _T 'MUST FIRE  a store last read 09-22 is PRODUCER STOPPED on 09-26 though the board is for the 09-23 ad set (the lag read it 1 day old)' (@($lag.lines | Where-Object { $_ -match '^! PRODUCER STOPPED  Aldi: newest price read 2026-09-22 \(4 d\), more than 3 day\(s\) before today \(2026-09-26; the board is for the 2026-09-23 ad set\)' }).Count -eq 1) (($lag.lines) -join ' | ')
    # ---- REPRICE OWED (W8). refresh_on = end + 1; the bar is 3 days past it. Fixture day 2026-09-26.
    function _Sw([object[]]$rows) { [pscustomobject]@{ windows = @(foreach ($r in $rows) { [pscustomobject]@{ id = $r[0]; store = $r[1]; refresh_on = $r[2]; repriced_for = $r[3] } }) } }
    $swNow = [datetime]'2026-09-26'
    $roAt = Get-RepriceOwed (_Sw @(,@('butter', 'Walmart', '2026-09-23', ''))) 3 $swNow
    _T 'MUST NOT FIRE at the bar  a re-price owed exactly 3 days (refresh_on 09-23 on 09-26) is inside the bar' ($roAt.findings -eq 0) (($roAt.lines) -join ' | ')
    $roPast = Get-RepriceOwed (_Sw @(@('butter', 'Walmart', '2026-09-22', ''), @('eggs', 'Walmart', '2026-09-20', ''))) 3 $swNow
    _T 'MUST FIRE one step past the bar  owed 4 days (refresh_on 09-22) is REPRICE OWED, one line per store, oldest named first' (@($roPast.lines | Where-Object { $_ -match "^! REPRICE OWED  Walmart: 2 ended sale\(s\) not re-read more than 3 day\(s\) after they ended \(oldest refresh_on 2026-09-20, 6 d\): eggs, butter" }).Count -eq 1 -and $roPast.findings -eq 1) (($roPast.lines) -join ' | ')
    $roDone = Get-RepriceOwed (_Sw @(,@('butter', "Sam's Club", '2026-09-20', '2026-09-20'))) 3 $swNow
    _T 'CLEAN TWIN  a re-price a landed capture recorded (repriced_for = refresh_on) is never owed, however old' ($roDone.findings -eq 0) (($roDone.lines) -join ' | ')
    $roStale = Get-RepriceOwed (_Sw @(,@('butter', "Sam's Club", '2026-09-20', '2026-08-01'))) 3 $swNow
    _T 'MUST FIRE  a re-price recorded for an EARLIER window does not discharge this one' ($roStale.findings -eq 1) (($roStale.lines) -join ' | ')
    $lagOk = Get-BoardFreshness (_Board '2026-09-23' @(,@('milk', 'Aldi', '2026-09-26'))) (_Wh @{ Aldi = 50 } @()) 3 0.10 ([datetime]'2026-09-26')
    _T 'CLEAN TWIN  a store read today under the same lagging ad set raises nothing, and its line says 0 d before today' ($lagOk.findings -eq 0 -and @($lagOk.lines | Where-Object { $_ -match 'newest read 2026-09-26 \(0 d before 2026-09-26\)' }).Count -eq 1) (($lagOk.lines) -join ' | ')
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
$res = Get-BoardFreshness $board $wh $script:ProducerStopDays $script:StaleShareMax (Get-Date)
Write-Output ("board freshness: " + $(if ($bf) { $bf.Name } else { 'no board' }) + " (producer-stop floor " + $script:ProducerStopDays + " d, age-withheld ceiling " + ('{0:P0}' -f $script:StaleShareMax) + ")")
foreach ($l in $res.lines) { Write-Output $l }
# THE RE-PRICE LOOP (W8). sale-windows.json is regenerated by the daily chain and gitignored, so a clean checkout has
# none: that is said plainly and is never a finding, and never a clean report either.
if (-not $SaleWindowsFile) { $SaleWindowsFile = Join-Path $root 'sale-windows.json' }
$owedFindings = 0
if (Test-Path -LiteralPath $SaleWindowsFile) {
  $swDoc = [IO.File]::ReadAllText($SaleWindowsFile) | ConvertFrom-Json
  $ro = Get-RepriceOwed $swDoc $script:RepriceOwedDays (Get-Date)
  $owedFindings = $ro.findings
  Write-Output ('reprice loop: ' + @($swDoc.windows).Count + ' sale window(s) tracked; ' + $ro.findings + ' store(s) owe a re-price more than ' + $script:RepriceOwedDays + ' day(s) after the sale ended')
  foreach ($l in $ro.lines) { Write-Output $l }
} else {
  Write-Output ('reprice loop: NOT JUDGED - no ' + (Split-Path $SaleWindowsFile -Leaf) + ' here (the daily chain writes it), so whether ended sales were re-read is unknown')
}
Write-Output ('BOARD-FRESHNESS-COMPLETE stores=' + $res.stores + ' findings=' + ($res.findings + $owedFindings))
exit 0
