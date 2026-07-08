<#
  verify-apply.ps1 - Stage 3 of the semantic verify pass.
  Reads comparison-<date>.json + verify-verdicts-<date>.json (the LLM judgment) and writes
  verified-<date>.json: each commodity keeps only entries the judge CONFIRMED, re-ranks them,
  attaches annotations (e.g. "premium variety"), and drops a commodity that falls below -MinStores
  confirmed stores. Prints a change report (winners that moved, items dropped, annotations added).

  Verdict file shape:
    { week_of, verdicts: [ { id, entries: [ { store, keep: bool, annotation: string|null, reason: string } ] } ] }
#>
param([string]$CompareFile = "", [string]$VerdictFile = "", [string]$OutDir = "", [int]$MinStores = 2)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
if (-not $CompareFile) { $CompareFile = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName }
$doc = Get-Content $CompareFile -Raw | ConvertFrom-Json
$week = [string]$doc.week_of
if (-not $VerdictFile) { $VerdictFile = Join-Path $OutDir ("verify-verdicts-"+$week+".json") }
$verdicts = Get-Content $VerdictFile -Raw | ConvertFrom-Json

# flat lookup "<id>|<store>" -> verdict entry (avoids nested-hashtable indexing quirks)
$vlook = @{}
foreach ($c in $verdicts.verdicts) { foreach ($e in $c.entries) { $vlook[("$($c.id)|$($e.store)")] = $e } }

$verified = New-Object System.Collections.Generic.List[object]
$changes  = New-Object System.Collections.Generic.List[object]
foreach ($row in $doc.comparison) {
  $kept = New-Object System.Collections.Generic.List[object]
  $ord = 0
  foreach ($s in $row.stores) {
    $v = $vlook[("$($row.id)|$($s.store)")]
    if ($v -and ($v.keep -eq $false)) { $changes.Add("DROP    $($row.commodity): $($s.store) `"$($s.item)`" - $($v.reason)"); continue }
    $ann = if ($v) { $v.annotation } else { $null }
    if ($ann) { $changes.Add("NOTE    $($row.commodity): $($s.store) - $ann") }
    # keep ad + note: SaleBadge's flash-window parser reads them, and publish PREFERS this verified board -
    # dropping them silently killed flash-date badges whenever the verified board was the build input.
    $kept.Add([pscustomobject]@{ store=$s.store; per_unit=[double]$s.per_unit; unit=$s.unit; type=$s.type; bulk=[bool]$s.bulk; membership=[bool]$s.membership; item=$s.item; ad=$s.ad; note=$s.note; size=$s.size; annotation=$ann; ord=$ord }); $ord++
  }
  if ($kept.Count -lt $MinStores) { $changes.Add("REMOVE  $($row.commodity): only $($kept.Count) confirmed store(s) left"); continue }
  $ranked = @($kept.ToArray() | Sort-Object per_unit, ord)   # stable: ties keep original ranking order
  if ($ranked[0].store -ne $row.cheapest_store) { $changes.Add("WINNER  $($row.commodity): $($row.cheapest_store) `$$('{0:N2}' -f $row.cheapest_price) -> $($ranked[0].store) `$$('{0:N2}' -f $ranked[0].per_unit)") }
  $nm = @($ranked | Where-Object { -not $_.membership } | Select-Object -First 1)
  $verified.Add([pscustomobject]@{
    commodity=$row.commodity; id=$row.id; unit=$row.unit
    cheapest_store=$ranked[0].store; cheapest_price=$ranked[0].per_unit; cheapest_type=$ranked[0].type; cheapest_annotation=$ranked[0].annotation
    nomem_store=$(if($nm.Count){$nm[0].store}else{$null}); nomem_price=$(if($nm.Count){$nm[0].per_unit}else{$null}); nomem_annotation=$(if($nm.Count){$nm[0].annotation}else{$null})
    stores=$ranked
  })
}

$out = [ordered]@{ built_at=(Get-Date).ToString('s'); week_of=$week; verified_from=$CompareFile; commodities=$verified.Count; comparison=$verified.ToArray() }
$file = Join-Path $OutDir ("verified-"+$week+".json")
($out | ConvertTo-Json -Depth 8) | Set-Content $file -Encoding UTF8

Write-Output ("VERIFIED  week $week   commodities kept: " + $verified.Count + " / " + @($doc.comparison).Count)
Write-Output ("=" * 70)
if ($changes.Count -gt 0) { foreach ($c in $changes.ToArray()) { Write-Output $c } } else { Write-Output "no changes - every published winner passed semantic verification" }
Write-Output ""
Write-Output ("Saved: " + $file)
