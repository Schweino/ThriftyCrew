<#
  verify-prep.ps1 - Stage 1 of the semantic verify pass.
  Reads the latest comparison-<date>.json and emits a compact verify-input-<date>.json:
  per commodity, the ranked store entries that would publish (store, item, size, unit price, sale/everyday).
  This is the input an LLM judges in stage 2 (is each item the PLAIN commodity in a comparable form?).
#>
param([string]$CompareFile = "", [string]$OutDir = "")
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
if (-not $CompareFile) { $CompareFile = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName }

$doc = Get-Content $CompareFile -Raw | ConvertFrom-Json
$week = [string]$doc.week_of
$commodities = New-Object System.Collections.Generic.List[object]
foreach ($row in $doc.comparison) {
  $entries = New-Object System.Collections.Generic.List[object]
  foreach ($s in $row.stores) {
    $entries.Add([ordered]@{ store=$s.store; item=$s.item; size=$s.size; unit_price=$s.per_unit; type=$s.type; bulk=[bool]$s.bulk })
  }
  $commodities.Add([ordered]@{ id=$row.id; label=$row.commodity; unit=$row.unit; entries=$entries.ToArray() })
}
$out = [ordered]@{ week_of=$week; unit_note="unit_price is per the commodity's unit"; commodities=$commodities.ToArray() }
$file = Join-Path $OutDir ("verify-input-"+$week+".json")
($out | ConvertTo-Json -Depth 8) | Set-Content $file -Encoding UTF8
Write-Output ("verify input: " + $commodities.Count + " commodities -> " + $file)
