<#
  import-instacart-batch.ps1 - generalized importer for Instacart storefront captures (Aldi, Fareway) in the
  id\t name~~price~~size | ... format. Instacart tiles jam badge text ("Best seller","Store choice"), estimated
  by-weight pricing ("per pound$899/lb"), and sale "Original Price: $X.XX" into the name field, and often omit
  a clean size - all cleaned/guarded here. compare-deals matches by rule. price_mode must be IN-STORE (Aldi OLA
  42 / Fareway In-Store) - Pickup/Delivery are marked up. Usage:
    .\import-instacart-batch.ps1 -Store Fareway -Raw out\staples500\fareway-batch1-raw.txt -SourceLabel "Fareway Omaha In-Store shelf price (batch capture)"
#>
param([Parameter(Mandatory=$true)][string]$Store, [Parameter(Mandatory=$true)][string]$Raw, [string]$SourceLabel = "")
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$today = (Get-Date).ToString('yyyy-MM-dd')
$regDir = Join-Path $root 'out\regular'
if (-not $SourceLabel) { $SourceLabel = "$Store In-Store shelf price (batch capture)" }
$prefix = switch ($Store) { 'Aldi' {'aldi-regular'} 'Fareway' {'fareway-regular'} default { ($Store.ToLower() -replace '[^a-z0-9]', '') + '-regular' } }

function CleanName([string]$n) {
  $n = $n -replace '(?i)^\s*(Best\s*seller|Store\s*choice|New\b|Popular|Low\s*fat|Low\s*carb|Low\s*sodium|Keto\s*diet|No\s*sugar\s*added|High\s*protein|Fan\s*favorite|Sugar\s*free)+', ''
  $n = $n -replace '(?i)per\s+(?:package|pound|lb|each)\s*(?:\(estimated\))?\s*\$\d+(?:\.\d+)?\s*(?:each|/\s*pkg|/\s*lb)?\s*(?:\(est\.?\))?', ''
  $n = $n -replace '(?i)Original\s+Price:\s*\$\d+(?:\.\d+)?(?:\$[\d.]+)?(?:\d+%\s*off)?', ''
  $n = $n -replace '\$\d+(?:\.\d+)?\s*/\s*(?:lb|pkg|oz|ea|each)\b', ''
  $n = $n -replace '\$\d+(?:\.\d+)?', ''
  $n = $n -replace '\d+%\s*off', ''
  $n = ($n -replace '\s+', ' ').Trim()
  return $n
}
function GetSize([string]$field, [string]$name) {
  if ($field -and $field.Trim()) { return $field.Trim() }
  $m = [regex]::Match($name, '(\d+(?:\.\d+)?)\s*(fl\s*oz|floz|oz|lb|ct)\b', 'IgnoreCase')
  if ($m.Success) { return ($m.Groups[1].Value + ' ' + (($m.Groups[2].Value.ToLower()) -replace '\s+', ' ')) }
  return ''
}
# a name is garbage if it has no run of >=3 letters (e.g. leftover "Original Price" junk stripped to symbols)
function GoodName([string]$n) { return ($n -and $n.Length -ge 3 -and ($n -match '[A-Za-z]{3,}')) }

# READ THE CAPTURE AS UTF-8, AND REPAIR ANYTHING ALREADY MANGLED UPSTREAM.
# A browser Blob download is UTF-8; PowerShell 5.1's Get-Content defaults to the system ANSI codepage
# (Windows-1252 here), so a bare read corrupts every non-ASCII byte and then the row is SAVED that way - the
# damage is baked into the bytes, so reading correctly later does not undo it. That shipped 16 mangled board
# rows on 2026-07-29, 6 of them CROWNS ("Member(junk)s Mark Wildflower Pure Premium Honey" was the first thing
# a shopper read on the honey row). capture-lib.ps1 fixed the four live builders; these four batch importers
# were missed, so the next staples expansion would have re-introduced it.
# Measured on the staged batch files: walmart 50 of 50 lines corrupted by the default read, bakers 40 of 50,
# aldi 2 of 49, fareway 2 of 50. Walmart hits EVERY line because its unit price carries a cent glyph - so the
# corruption lands in the PRICE field, not just the name.
# Repair-Mojibake is applied per LINE rather than per parsed name: it is a no-op on clean text (it fires only
# on a mojibake signature that round-trips through a THROWING UTF-8 decoder), so this is uniform across all
# four importers and cannot damage good data.
. (Join-Path $PSScriptRoot 'capture-lib.ps1')
$lines = @(Get-Content (Join-Path $root $Raw) -Encoding UTF8) | ForEach-Object { Repair-Mojibake $_ }
$rows = New-Object System.Collections.ArrayList; $seen = @{}; $skip = 0
foreach ($ln in $lines) {
  if (-not ($ln -match "`t")) { continue }
  $prodStr = ($ln -split "`t", 2)[1]
  foreach ($p in ($prodStr -split '\|')) {
    $f = $p -split '~~'
    if ($f.Count -lt 2) { continue }
    $nm = CleanName ([string]$f[0])
    $price = 0.0; [void][double]::TryParse((([string]$f[1]) -replace '[^0-9.]', ''), [ref]$price)
    $sizeF = ''; if ($f.Count -ge 3) { $sizeF = [string]$f[2] }
    $size = GetSize $sizeF $nm
    if ($price -le 0 -or -not (GoodName $nm) -or -not $size) { $skip++; continue }
    $key = ($nm + '|' + $size).ToLower(); if ($seen.ContainsKey($key)) { continue }; $seen[$key] = $true
    [void]$rows.Add([ordered]@{ store = $Store; item = $nm; ad_price = ('$' + $price); size = $size; regular = $price; current_price = $price; source_ad = $SourceLabel; as_of = $today })
  }
}

$prev = Get-ChildItem (Join-Path $regDir ($prefix + '-*.json')) -EA SilentlyContinue | Where-Object { $_.BaseName -match ('^' + $prefix + '-\d{4}-\d{2}-\d{2}$') } | Sort-Object Name -Descending | Select-Object -First 1
$merged = New-Object System.Collections.ArrayList; $mseen = @{}; $doc = $null
if ($prev) { $doc = Get-Content $prev.FullName -Raw | ConvertFrom-Json; foreach ($r in @($doc.deals)) { [void]$merged.Add($r); $mseen[(([string]$r.item) + '|' + ([string]$r.size)).ToLower()] = $true } }
$added = 0
foreach ($r in $rows) { $k = (([string]$r.item) + '|' + ([string]$r.size)).ToLower(); if ($mseen.ContainsKey($k)) { continue }; $mseen[$k] = $true; [void]$merged.Add([pscustomobject]$r); $added++ }
$outFile = Join-Path $regDir ($prefix + "-$today.json")
if ($doc) { $doc.deals = $merged.ToArray(); if ($doc.PSObject.Properties['deal_count']) { $doc.deal_count = $merged.Count } else { $doc | Add-Member deal_count $merged.Count -Force }; ($doc | ConvertTo-Json -Depth 6) | Set-Content $outFile -Encoding UTF8 }
else { ([ordered]@{ store = $Store; week_of = $today; price_type = 'everyday'; price_mode = 'in-store'; deal_count = $merged.Count; deals = $merged.ToArray() } | ConvertTo-Json -Depth 6) | Set-Content $outFile -Encoding UTF8 }
Write-Output ("$Store : parsed $($rows.Count) sized rows ($skip skipped noise/no-size), added $added new, total $($merged.Count) -> $(Split-Path $outFile -Leaf)")
