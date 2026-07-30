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
# verdict_schema is read by the AGENT that judges this file. `item` in each verdict entry is what makes a
# drop safely applicable and PERMANENT: verify-apply refuses to apply a drop to a cell holding a different
# product than was judged (the board is rebuilt between judgment and apply routinely), and it records
# confirmed drops into verdict-suppressions.json so the same wrong product never needs re-judging. Without
# `item`, identity falls back to the name quoted in the reason - which 39 of the first 81 drops did not have.
$out = [ordered]@{
  week_of=$week
  unit_note="unit_price is per the commodity's unit"
  verdict_schema="Write verify-verdicts-<week>.json as { week_of, verdicts: [ { id, entries: [ { store, item: <copy the EXACT item string you judged from this file>, keep: bool, annotation: string|null, reason: string } ] } ] }. The item field is REQUIRED on every entry you write: it is the witness that lets a drop apply safely and persist."
  commodities=$commodities.ToArray()
}
$file = Join-Path $OutDir ("verify-input-"+$week+".json")
($out | ConvertTo-Json -Depth 8) | Set-Content $file -Encoding UTF8
Write-Output ("verify input: " + $commodities.Count + " commodities -> " + $file)
