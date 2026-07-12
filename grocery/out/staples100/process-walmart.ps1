# Fold the vetted Walmart winners (walmart-final.csv, pipe-delimited) into the engine:
# out\regular\walmart-regular-2026-07-12.json (append; skip ids already present) + store-walmart7-urls.json
$ErrorActionPreference = 'Stop'
$root = 'C:\Codex\income\grocery'
$rows = Import-Csv (Join-Path $root 'out\staples100\walmart-final.csv') -Delimiter '|'
$rf = Join-Path $root 'out\regular\walmart-regular-2026-07-12.json'
$doc = Get-Content $rf -Raw | ConvertFrom-Json
$haveNames = @{}; foreach ($d in $doc.deals) { $haveNames[[string]$d.item] = $true }
$urlRows = @(); $added = 0
foreach ($r in $rows) {
  if (-not $haveNames.ContainsKey([string]$r.name)) {
    $doc.deals += [pscustomobject]@{ store='Walmart'; item=[string]$r.name; ad_price=('$'+$r.price); size=[string]$r.size; regular=$null; source_ad='walmart.com (Omaha, staples100 2026-07-12)' }
    $added++
  }
  $urlRows += [pscustomobject]@{ id=[string]$r.id; url=('https://www.walmart.com'+[string]$r.url); price=[string]$r.price; size=[string]$r.size; name=[string]$r.name }
}
$doc | ConvertTo-Json -Depth 6 | Set-Content $rf -Encoding UTF8
ConvertTo-Json @($urlRows) -Depth 4 | Set-Content (Join-Path $root 'out\url-inputs\store-walmart7-urls.json') -Encoding UTF8
Write-Output ("walmart-regular: +" + $added + " -> " + @($doc.deals).Count + " deals; url-input rows: " + @($urlRows).Count)
