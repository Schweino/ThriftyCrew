<#
  derived-band-lib.ps1 - A COMMODITY'S SANITY BAND IS DERIVED FROM ITS OWN PRICE EVIDENCE, NEVER TYPED.

  Brad's ruling on queue 2026-09-21-6b17b1, 2026-09-22, verbatim: "Derive from data". Until then 360 commodities
  carried a hand-typed band_min/band_max in commodities.json (plus price-bands.json), and a typed floor is a number
  nobody re-reads as prices move: vegetable-oil's 0.04 refused Sam's own consistent $7.16 / 192 fl oz canola
  (0.0373/fl oz) and held the cell dearer (memory conformance-guard-cannot-see-rule-bug: a band floor censored 50 cells
  of real bargains; .claude/rules/grocery.md: no hard-coded bands).

  THE RULE. For each commodity, over every priced row the engine read this build (every store, sale and everyday, the
  capture window the engine already loads):
    1. each store contributes ONE number, the median of its own rows' per-unit prices, so one store's bad parse or one
       store's many rows cannot move the reference;
    2. the reference is the median of those store numbers when at least $MinStores stores have evidence, else the
       median of all rows when there are at least $MinStores rows, else there is NO band (the universal per-unit floor
       in compare-deals still applies);
    3. band = [ reference / K , reference * K ].
  K is a FIRST PLAUSIBLE NUMBER chosen by a small sweep over comparison-2026-09-22's evidence (K = 3, 4, 5, 6; the
  counts are in plan-2026-09-22-5 item 6b17b1): against the typed bands, rows newly refused were K=3 1,286, K=4 581,
  K=5 280, K=6 150. 5 was taken as the widest band that still refuses a factor-of-10 basis error with margin on both sides;
  6 refuses fewer real rows and admits a 6x error. It is not a tuned optimum and nothing rules out a better value.
  WHAT IT DOES WHEN THE PRODUCER STOPS: with no evidence there is no band, so a commodity with fewer than MinStores
  stores and rows is guarded only by the universal floor - the same as the 232 commodities that had no typed band.

  Pure: no disk, no clock. compare-deals computes the evidence in a pre-pass and calls Get-TcDerivedBands once.
  Fixtures: grocery/test-derived-band.ps1 -SelfTest (run-gates runs it; run it by hand after any change here).
#>

$script:TcBandK = 5.0          # first plausible number, see header
$script:TcBandMinStores = 3    # first plausible number: a median of two is an average, not a reference

function Get-TcMedian([double[]]$Values) {
  $v = @($Values | Sort-Object)
  if ($v.Count -eq 0) { return $null }
  $m = [int][math]::Floor($v.Count / 2)
  if ($v.Count % 2 -eq 1) { return [double]$v[$m] }
  return (([double]$v[$m - 1] + [double]$v[$m]) / 2.0)
}

function Get-TcDerivedBands {
  <# .PARAMETER Rows  objects with id, store, per_unit (> 0). .OUTPUTS hashtable id -> { min; max; reference; stores; rows; basis } #>
  param([object[]]$Rows, [double]$K = $script:TcBandK, [int]$MinStores = $script:TcBandMinStores)
  $byId = @{}
  foreach ($r in @($Rows)) {
    if ($null -eq $r -or $null -eq $r.per_unit) { continue }
    $pu = [double]$r.per_unit
    if ($pu -le 0) { continue }
    $id = [string]$r.id
    if (-not $byId.ContainsKey($id)) { $byId[$id] = @{} }
    $st = [string]$r.store
    if (-not $byId[$id].ContainsKey($st)) { $byId[$id][$st] = New-Object System.Collections.ArrayList }
    [void]$byId[$id][$st].Add($pu)
  }
  $out = @{}
  foreach ($id in $byId.Keys) {
    $storeMed = @(); $all = @()
    foreach ($st in $byId[$id].Keys) {
      $vals = [double[]]($byId[$id][$st].ToArray())
      $storeMed += (Get-TcMedian $vals); $all += $vals
    }
    $ref = $null; $basis = ''
    if ($storeMed.Count -ge $MinStores) { $ref = Get-TcMedian ([double[]]$storeMed); $basis = 'median of store medians' }
    elseif ($all.Count -ge $MinStores) { $ref = Get-TcMedian ([double[]]$all); $basis = 'median of rows (fewer than ' + $MinStores + ' stores)' }
    if ($null -eq $ref -or $ref -le 0) { continue }
    $out[$id] = [pscustomobject]@{ min = [math]::Round($ref / $K, 6); max = [math]::Round($ref * $K, 6); reference = [math]::Round($ref, 6); stores = $storeMed.Count; rows = $all.Count; basis = $basis }
  }
  return $out
}

function Test-TcInBand($Band, [double]$PerUnit) {
  if ($null -eq $Band) { return $true }
  return ($PerUnit -ge [double]$Band.min -and $PerUnit -le [double]$Band.max)
}
