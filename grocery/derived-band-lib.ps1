<#
  derived-band-lib.ps1 - A COMMODITY'S SANITY BAND IS DERIVED FROM ITS OWN PRICE EVIDENCE, NEVER TYPED.

  Brad's ruling on queue 2026-09-21-6b17b1, 2026-09-22, verbatim: "Derive from data". And on the rollout, the same day:
  "We need to fix it now, properly, and to make sure we are future proof so this doesn't happen again. I dont care how
  long it takes." Until then 360 commodities carried a hand-typed band_min/band_max in commodities.json, and a typed
  floor is a number nobody re-reads as prices move: vegetable-oil's 0.04 refused Sam's own consistent $7.16 / 192 fl oz
  canola (0.0373/fl oz) and held the cell dearer (memory conformance-guard-cannot-see-rule-bug; .claude/rules/grocery.md:
  no hard-coded bands).

  THE RULE. For each commodity, over every priced row the engine read this build (every store, sale and everyday):
    1. each store contributes ONE number, its CHEAPEST row's per-unit price, which is the number the board publishes for
       that store. Not the median of its rows: the first cut used it and every wrong product a rule admits (pink-salt
       popcorn, jalapeno hummus, a salmon bowl) pulled a commodity's median UP, so the floor rose over real cheap rows and
       refused them (Aldi and Hy-Vee iodized salt, Fareway and Hy-Vee bananas). One store's bad row still cannot move the
       reference, because the reference is the median ACROSS stores;
    2. the RETAIL reference is the median of the RETAIL stores' numbers when at least $MinStores retail stores have
       evidence, else the median of every store's number (warehouse included) when at least $MinStores stores do, else
       the median of all rows when there are at least $MinStores rows, else there is NO band (the universal per-unit
       floor in compare-deals still applies);
    3. band = [ reference / K , reference * K ] for a retail store's row;
    4. a WAREHOUSE store's row (stores.json reference_group = "warehouse", never a list in code) is judged against the
       same reference with a floor W times lower: [ reference / (K * W) , reference * K ]. Warehouse packs are bulk, and
       bulk is legitimately cheaper per unit than the small jars the retail reference is made of: measured on the
       derived-arm board of 2026-09-22 (compare-deals -OutName armD under TC_DERIVED_BANDS=enforce), Sam's 50 lb rice,
       curry powder 18 oz, thyme 8.25 oz, bay leaves 2 oz and yeast 2 x 16 oz sat 1.95x, 3.09x, 3.54x, 5.89x and 6.76x
       under the retail reference, and yeast is refused by a single-reference band (K = 5). A warehouse row is never
       judged against its OWN store's rows: one store's median of one or two rows is the row itself, and a band built
       from the row it judges can never refuse it.
  K = 5 and W = 1.5 are FIRST PLAUSIBLE NUMBERS. K came from a sweep over comparison-2026-09-22's evidence: rows newly
  refused against the typed bands were K=3 1,286, K=4 581, K=5 280, K=6 150, and 5 is the widest band that still refuses
  a factor-of-10 basis error with margin; 6 admits a 6x error. W is bounded on both sides by measurement, and 1.5 is the
  one value tried inside the bounds: K * W must EXCEED 6.76 (the deepest real warehouse discount measured, Sam's yeast)
  and must stay UNDER 10, so a factor-of-10 basis error of a warehouse price that sits AT the retail reference is still
  refused. K * W = 7.5. The first cut used W = 4 (K * W = 20), chosen under an earlier median-of-medians reference, and
  it admitted Sam's "Rotella's Italian Vienna Bread 17 oz." at 0.1753 per loaf, a 17-ounces-read-as-17-loaves error
  9.58x under the reference (plan-2026-09-22-5). A real bulk row deeper than 7.5x under retail is REFUSED by this rule,
  and audit-band-refusals.ps1 pages it by name because it is not a basis error: that is the loop that moves W, never a
  quiet edit here.
  WHAT IT DOES WHEN THE PRODUCER STOPS: with no evidence there is no band, and the universal floor alone guards.

  Pure: no disk, no clock. compare-deals computes the evidence in a pre-pass and calls Get-TcDerivedBands once.
  Fixtures: grocery/test-derived-band.ps1 -SelfTest (run-gates runs it; run it by hand after any change here).
#>

$script:TcBandK = 5.0          # first plausible number, see header
$script:TcBandW = 1.5          # warehouse floor allowance: K*W = 7.5, inside the measured bounds (6.76, 10); see header
$script:TcBandMinStores = 3    # first plausible number: a median of two is an average, not a reference

function Get-TcMedian([double[]]$Values) {
  $v = @($Values | Sort-Object)
  if ($v.Count -eq 0) { return $null }
  $m = [int][math]::Floor($v.Count / 2)
  if ($v.Count % 2 -eq 1) { return [double]$v[$m] }
  return (([double]$v[$m - 1] + [double]$v[$m]) / 2.0)
}

function Get-TcStoreReferenceGroups($StoresDoc) {
  # store name -> 'warehouse' | 'retail', read from stores.json (reference_group). Absent means retail.
  $g = @{}
  foreach ($s in @($StoresDoc.stores)) {
    if ($null -eq $s -or -not $s.name) { continue }
    $v = 'retail'
    if ($s.PSObject.Properties['reference_group'] -and [string]$s.reference_group) { $v = [string]$s.reference_group }
    $g[[string]$s.name] = $v
  }
  return $g
}

function Get-TcDerivedBands {
  <# .PARAMETER Rows  objects with id, store, per_unit (> 0). .PARAMETER Groups store -> 'warehouse'|'retail'.
     .OUTPUTS hashtable id -> { min; max; wmin; reference; stores; retail_stores; rows; basis } #>
  param([object[]]$Rows, [double]$K = $script:TcBandK, [int]$MinStores = $script:TcBandMinStores, [hashtable]$Groups = @{}, [double]$W = $script:TcBandW)
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
    $retailMed = @(); $storeMed = @(); $all = @()
    foreach ($st in $byId[$id].Keys) {
      $vals = [double[]]($byId[$id][$st].ToArray())
      $med = ([double[]]$vals | Measure-Object -Minimum).Minimum   # the store's CHEAPEST row: what the board publishes
      $storeMed += $med; $all += $vals
      $grp = if ($Groups.ContainsKey($st)) { [string]$Groups[$st] } else { 'retail' }
      if ($grp -ne 'warehouse') { $retailMed += $med }
    }
    $ref = $null; $basis = ''
    if ($retailMed.Count -ge $MinStores) { $ref = Get-TcMedian ([double[]]$retailMed); $basis = 'median of retail store minima' }
    elseif ($storeMed.Count -ge $MinStores) { $ref = Get-TcMedian ([double[]]$storeMed); $basis = 'median of store minima (fewer than ' + $MinStores + ' retail stores)' }
    elseif ($all.Count -ge $MinStores) { $ref = Get-TcMedian ([double[]]$all); $basis = 'median of rows (fewer than ' + $MinStores + ' stores)' }
    if ($null -eq $ref -or $ref -le 0) { continue }
    $out[$id] = [pscustomobject]@{ min = [math]::Round($ref / $K, 6); max = [math]::Round($ref * $K, 6); wmin = [math]::Round($ref / ($K * $W), 6)
      reference = [math]::Round($ref, 6); stores = $storeMed.Count; retail_stores = $retailMed.Count; rows = $all.Count; basis = $basis }
  }
  return $out
}

function Test-TcInBand($Band, [double]$PerUnit, [string]$Group = 'retail') {
  # A band with a wmin applies it to a warehouse row; a typed band (no wmin) is one band for every store.
  if ($null -eq $Band) { return $true }
  $lo = [double]$Band.min
  if ($Group -eq 'warehouse' -and $Band.PSObject.Properties['wmin'] -and $null -ne $Band.wmin) { $lo = [double]$Band.wmin }
  return ($PerUnit -ge $lo -and $PerUnit -le [double]$Band.max)
}
