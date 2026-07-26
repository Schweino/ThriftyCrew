<#
  build-r300-fills.ps1 - turn every row this batch contributed to a store file (Family Fare + Hy-Vee via the
  primer, Baker's via the Kroger API) into validate-fills.ps1's candidate shape, so the STANDING guard - not
  just my own diff - re-runs each product name through the real Match-Category (array order + GLOBAL_EXCLUDE +
  relax_global) and proves it resolves to the commodity it was fetched for.

  This is the check the purge script alone cannot make: purge tests my new id's include/exclude in isolation,
  Match-Category tests it against all 445 commodities in ORDER. That gap is exactly how
  "Marie Callender's Turkey Breast & Stuffing" reached the STUFFING-MIX cell.
#>
$ErrorActionPreference = 'Stop'
$root = 'C:\Codex\income\grocery'
$today = (Get-Date).ToString('yyyy-MM-dd')
$ids = @()
foreach ($f in @('out\r300\r300-ids.txt','out\r300\batch8-ids.txt')) { $fp = Join-Path $root $f; if (Test-Path $fp) { $ids += ((Get-Content $fp -Raw).Trim() -split ',') } }
$ids = @($ids | Where-Object { $_ })

$rules = @{}
foreach ($c in (Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json)) { $rules[[string]$c.id] = $c }
function Test-Match([string]$name, [string]$id) {
  $r = $rules[$id]; if (-not $r) { return $false }
  $ok = $false; foreach ($p in $r.include) { if ($p -and $name -imatch $p) { $ok = $true; break } }
  if (-not $ok) { return $false }
  foreach ($p in $r.exclude) { if ($p -and $name -imatch $p) { return $false } }
  return $true
}

$files = @(
  @{ store = 'Family Fare'; f = "family-fare-regular-$today.json" },
  @{ store = 'Hy-Vee';      f = "hyvee-regular-$today.json" },
  @{ store = "Baker's";     f = "bakers-regular-$today.json" }
)
$groups = New-Object System.Collections.ArrayList
foreach ($fx in $files) {
  $p = Join-Path $root ('out\regular\' + $fx.f)
  if (-not (Test-Path $p)) { continue }
  $doc = Get-Content $p -Raw | ConvertFrom-Json
  foreach ($id in $ids) {
    $c = New-Object System.Collections.ArrayList
    foreach ($r in @($doc.deals)) {
      if (-not (Test-Match ([string]$r.item) $id)) { continue }
      $price = 0.0; [void][double]::TryParse((([string]$r.ad_price) -replace '[^0-9.]', ''), [ref]$price)
      [void]$c.Add([pscustomobject]@{ item = [string]$r.item; price = $price; size = [string]$r.size })
    }
    if ($c.Count) { [void]$groups.Add([pscustomobject]@{ store = $fx.store; id = $id; cands = @($c | Sort-Object price) }) }
  }
}
$outF = Join-Path $root 'out\r300\r300-fill-candidates.json'
(@{ readme = 'r300 batch fill rows, per store x commodity, cheapest-first - input for validate-fills.ps1'; candidates = $groups.ToArray() } | ConvertTo-Json -Depth 6) | Set-Content $outF -Encoding UTF8
Write-Output ("wrote {0} store x commodity group(s) -> {1}" -f $groups.Count, $outF)

