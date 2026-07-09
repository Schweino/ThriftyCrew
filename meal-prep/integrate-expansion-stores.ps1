<#
  integrate-expansion-stores.ps1 - Folds per-store backfill results (Walmart/Sam's/Hy-Vee/Aldi/Baker's) for
  the 43 newly-added recipe commodities into recipe-board-everyday.json + product-urls.json.

  Expects up to 5 input files in grocery\out\ (any subset; skips missing ones):
    expansion-walmart.json, expansion-sams.json, expansion-hyvee.json, expansion-aldi.json, expansion-bakers.json
  Shape: { "store": "<Exact Store Name>", "items": [ { "id":"<board id>", "per_unit":<n>, "unit":"<u>",
           "item":"<product name>", "size":"<size str>", "url":"<link or empty>" }, ... ],
           "skipped": [ {"id":"...", "why":"..."} ] }

  Idempotent: replaces a store's existing row on a given id if re-run (does not duplicate).
#>
$ErrorActionPreference = 'Stop'
$mp = $PSScriptRoot
$g  = Join-Path (Split-Path $mp -Parent) 'grocery'
$storeFiles = @(
  @{ file = 'expansion-walmart.json'; name = 'Walmart' },
  @{ file = 'expansion-sams.json';    name = "Sam's Club" },
  @{ file = 'expansion-hyvee.json';   name = 'Hy-Vee' },
  @{ file = 'expansion-aldi.json';    name = 'Aldi' },
  @{ file = 'expansion-bakers.json';  name = "Baker's" }
)

$bevF = Join-Path $g 'out\recipe-board-everyday.json'
$bev = Get-Content $bevF -Raw | ConvertFrom-Json
$rowById = @{}; foreach ($r in $bev.comparison) { $rowById[[string]$r.id] = $r }

$puF = Join-Path $g 'product-urls.json'
$pu = Get-Content $puF -Raw | ConvertFrom-Json

$totalAdded = 0; $totalSkipped = 0
foreach ($sf in $storeFiles) {
  $path = Join-Path $g ('out\' + $sf.file)
  if (-not (Test-Path $path)) { Write-Output ("(no file: " + $sf.file + " - skipping " + $sf.name + ")"); continue }
  $doc = Get-Content $path -Raw | ConvertFrom-Json
  $storeName = if ($doc.store) { [string]$doc.store } else { $sf.name }
  $n = 0
  foreach ($it in $doc.items) {
    $id = [string]$it.id
    if (-not $rowById.ContainsKey($id)) {
      # brand-new id (e.g. Pork Loin / Fat Free Cheddar - Family Fare didn't carry it but this store does):
      # mint a new row rather than discard a legitimately-collected price.
      if (-not $it.commodity -or -not $it.unit) { Write-Output ("  SKIP unknown id '" + $id + "' from " + $storeName + " (no commodity/unit given to mint a new row)"); continue }
      $newRow = [pscustomobject]@{ id=$id; commodity=[string]$it.commodity; unit=[string]$it.unit; category=$(if($it.category){[string]$it.category}else{'Sauces & Condiments'}); cheapest_store=''; cheapest_price=0; cheapest_type='everyday'; stores=@() }
      $bev.comparison = @($bev.comparison) + $newRow
      $rowById[$id] = $newRow
      Write-Output ("  minted new commodity '" + $id + "' (" + $it.commodity + ") from " + $storeName)
    }
    $row = $rowById[$id]
    $stores = @($row.stores | Where-Object { [string]$_.store -ne $storeName })
    $newEntry = [pscustomobject]@{ store=$storeName; per_unit=[math]::Round([double]$it.per_unit,4); unit=[string]$row.unit; type='everyday'; bulk=[bool]($it.bulk); membership=($storeName -eq "Sam's Club"); item=[string]$it.item; size=[string]$it.size }
    $stores += $newEntry
    $row.stores = $stores
    # recompute cheapest_* for this row (upsert props: some older rows lack cheapest_* fields)
    $ranked = @($stores | Sort-Object per_unit)
    $row | Add-Member -NotePropertyName cheapest_store -NotePropertyValue ([string]$ranked[0].store) -Force
    $row | Add-Member -NotePropertyName cheapest_price -NotePropertyValue ([double]$ranked[0].per_unit) -Force
    $row | Add-Member -NotePropertyName cheapest_type -NotePropertyValue ([string]$ranked[0].type) -Force
    $n++; $totalAdded++
    # product link
    if ($it.url) {
      if (-not $pu.items.PSObject.Properties[$id]) { $pu.items | Add-Member -NotePropertyName $id -NotePropertyValue ([pscustomobject]@{ commodity=[string]$row.commodity }) }
      $entry = $pu.items.$id
      if ($entry.PSObject.Properties[$storeName]) { $entry.$storeName = [pscustomobject]@{ url=[string]$it.url; price=[double]$it.price; size=[string]$it.size; name=[string]$it.item } }
      else { $entry | Add-Member -NotePropertyName $storeName -NotePropertyValue ([pscustomobject]@{ url=[string]$it.url; price=[double]$it.price; size=[string]$it.size; name=[string]$it.item }) }
    }
  }
  foreach ($sk in $doc.skipped) { $totalSkipped++; Write-Output ("  skip (" + $storeName + "): " + $sk.id + " - " + $sk.why) }
  Write-Output ($storeName + ": +" + $n + " ids priced")
}

($bev | ConvertTo-Json -Depth 8) | Set-Content $bevF -Encoding UTF8
($pu | ConvertTo-Json -Depth 6) | Set-Content $puF -Encoding UTF8
Write-Output ("TOTAL: " + $totalAdded + " store-entries added, " + $totalSkipped + " skipped")
Write-Output "NEXT: recipe-overlay.ps1, top5-weekly.ps1, export-feed.ps1, add-serving-scaler.ps1 -All, then commit+push+push-data."
