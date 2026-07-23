<#
  select-fareway-shop.ps1 - turns the RAW Fareway storefront candidate captures (one {id,term,candidates[]}
  per commodity, produced by the browser sweep) into the one-row-per-commodity shop file that
  build-fareway-regular.ps1 consumes: out\fareway\fareway-shop-<date>.json.

  For each commodity it keeps only candidates whose NAME matches >=1 of the commodity's include
  patterns AND 0 of its exclude patterns (commodities.json), then picks the CHEAPEST PLAIN base item
  by a heuristic per-unit (weighted -> $/lb; oz/floz package -> price/oz; else absolute price), so the
  Fareway cell reflects the cheapest matching everyday/sale shelf price. Emits {id,name,price,per,orig,
  unit,size,url}. build-fareway-regular then does the authoritative unit conversion + link emission.
#>
param(
  [string]$In = "",
  [string]$Out = "",
  [string]$Today = ""
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$asof = if ($Today) { $Today } else { (Get-Date).ToString('yyyy-MM-dd') }
$scratch = 'C:\Users\Owner\AppData\Local\Temp\claude\C--Codex\32c86fd5-620b-4a8f-a670-285987b7c2fb\scratchpad'
if (-not $In)  { $In  = Join-Path $scratch "fareway-shop-$asof.jsonl" }
if (-not $Out) { $Out = Join-Path $root "out\fareway\fareway-shop-$asof.json" }

$commod = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
$incMap = @{}; $excMap = @{}; $unitMap = @{}
foreach ($c in $commod) {
  $incMap[[string]$c.id] = @($c.include)
  $excMap[[string]$c.id] = @($c.exclude)
  $unitMap[[string]$c.id] = [string]$c.unit
}

# read JSONL: each line = {id, term, candidates:[{name,price,per,orig,unit,size,url}]}
$rows = @()
if (-not (Test-Path $In)) { throw "input not found: $In" }
foreach ($line in (Get-Content $In)) {
  $line = $line.Trim(); if (-not $line) { continue }
  try { $rows += (ConvertFrom-Json $line) } catch { Write-Warning "bad JSONL line skipped" }
}
# dedupe by id: last capture wins
$byIdRaw = [ordered]@{}
foreach ($r in $rows) { $byIdRaw[[string]$r.id] = $r }

function PerUnit($c) {
  $price = 0.0; [void][double]::TryParse((([string]$c.price) -replace '[^0-9.]',''), [ref]$price)
  if ($price -le 0) { return [double]::PositiveInfinity }
  $unit = [string]$c.unit; $size = [string]$c.size; $per = ([string]$c.per).ToLower()
  $um = [regex]::Match($unit, '\$?\s*([\d.]+)\s*/\s*(lb|pound)')
  if ($um.Success) { return [double]$um.Groups[1].Value }
  if ($per -eq 'pound') { return $price }
  $oz = [regex]::Match($size, '([\d.]+)\s*(fl\s*oz|floz|oz)')
  if ($oz.Success) { $n=[double]$oz.Groups[1].Value; if ($n -gt 0) { return $price / $n } }
  return $price   # absolute (each / ct / unknown) - lets compare-deals do the exact math later
}

$outRows = New-Object System.Collections.ArrayList
$dropped = @()
foreach ($id in $byIdRaw.Keys) {
  if (-not $incMap.ContainsKey($id)) { continue }
  $inc = $incMap[$id]; $exc = $excMap[$id]
  $cands = @($byIdRaw[$id].candidates)
  $matches = @()
  foreach ($c in $cands) {
    $name = [string]$c.name; if (-not $name) { continue }
    $okInc = $false; foreach ($p in $inc) { if ($name -imatch $p) { $okInc = $true; break } }
    if (-not $okInc) { continue }
    $bad = $false; foreach ($p in $exc) { if ($p -and $name -imatch $p) { $bad = $true; break } }
    if ($bad) { continue }
    $matches += $c
  }
  if (-not $matches.Count) { $dropped += $id; continue }
  $best = $matches | Sort-Object @{Expression={PerUnit $_}}, @{Expression={([string]$_.name).Length}} | Select-Object -First 1
  [void]$outRows.Add([ordered]@{
    id=$id; name=[string]$best.name; price=[string]$best.price; per=[string]$best.per;
    orig=[string]$best.orig; unit=[string]$best.unit; size=[string]$best.size; url=[string]$best.url
  })
}
$outDir = Split-Path $Out -Parent; New-Item -ItemType Directory -Force -Path $outDir | Out-Null
($outRows | ConvertTo-Json -Depth 5) | Set-Content $Out -Encoding UTF8
Write-Output ("fareway-shop-$asof.json: $($outRows.Count) commodities selected (from $($byIdRaw.Count) captured); $($dropped.Count) had no include-match")
if ($dropped.Count) { Write-Output ("  no-match ids: " + ($dropped -join ', ')) }
