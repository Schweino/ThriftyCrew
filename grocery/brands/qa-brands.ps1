<#
  qa-brands.ps1 - Validates out\brands\brands-board.json before it ships. Exit 2 = FAIL (block publish).
  Catches: unknown board id, unit mismatch vs commodities.json, null/zero/negative prices, duplicate brand
  labels, implausible per-unit outliers (parse errors), and commodities with no store-brand row. Prints a
  report; -Strict makes warnings fatal too.
#>
param([switch]$Strict)
$ErrorActionPreference='Stop'
$here='C:\Codex\income\grocery'
$bb = Get-Content (Join-Path $here 'out\brands\brands-board.json') -Raw | ConvertFrom-Json
$com = Get-Content (Join-Path $here 'commodities.json') -Raw | ConvertFrom-Json
$comById=@{}; foreach($x in $com){ $comById[[string]$x.id]=$x }
# floor per unit: nothing legit is below these $/unit (parse-error catcher)
$floor=@{ oz=0.01; floz=0.004; lb=0.10; each=0.10; dozen=0.50; gallon=0.50 }

$errors=@(); $warns=@(); $okCount=0
foreach($p in $bb.commodities.PSObject.Properties){
  $cid=$p.Name; $c=$p.Value
  if(-not $comById.ContainsKey($cid)){ $errors += "[$cid] not a real board commodity id"; continue }
  $boardUnit=[string]$comById[$cid].unit
  $cfgUnit=([string]$c.unit) -replace '\s',''
  if($cfgUnit -ne ($boardUnit -replace '\s','')){ $warns += "[$cid] unit '$($c.unit)' != commodities.json '$boardUnit'" }
  $seen=@{}; $hasStore=$false; $allPer=@()
  foreach($b in $c.brands){
    $lbl=[string]$b.label
    if($seen.ContainsKey($lbl)){ $errors += "[$cid] duplicate brand '$lbl'" } ; $seen[$lbl]=$true
    if($b.store){ $hasStore=$true }
    $nPrices=0
    foreach($sp in $b.prices.PSObject.Properties){
      $v=$b.prices.$($sp.Name)
      if($null -eq $v){ continue }
      $nPrices++; $allPer += [double]$v
      if([double]$v -le 0){ $errors += "[$cid] $lbl @ $($sp.Name): non-positive $v" }
      $fl = if($floor.ContainsKey($cfgUnit)){ $floor[$cfgUnit] } else { 0.004 }
      if([double]$v -lt $fl){ $errors += "[$cid] $lbl @ $($sp.Name): $v/$($c.unit) below floor $fl (likely parse error)" }
    }
    if($nPrices -eq 0){ $errors += "[$cid] brand '$lbl' has no prices" }
  }
  if(-not $hasStore){ $warns += "[$cid] no store-brand row" }
  # intra-commodity spread: max/min across all brand cells should be sane (< 30x); catches gross outliers
  if($allPer.Count -ge 2){ $mn=($allPer|Measure-Object -Minimum).Minimum; $mx=($allPer|Measure-Object -Maximum).Maximum
    if($mn -gt 0 -and ($mx/$mn) -gt 30){ $warns += ("[$cid] per-unit spread {0:N3}..{1:N3} = {2:N0}x (check for a parse error)" -f $mn,$mx,($mx/$mn)) } }
  $okCount++
}
Write-Output ("QA brands-board: " + $okCount + " commodities checked")
if($warns.Count){ Write-Output ("`nWARNINGS ("+$warns.Count+"):"); $warns | ForEach-Object { Write-Output ("  ~ "+$_) } }
if($errors.Count){ Write-Output ("`nERRORS ("+$errors.Count+"):"); $errors | ForEach-Object { Write-Output ("  X "+$_) } }
else { Write-Output "`nNo hard errors." }
if($errors.Count -gt 0 -or ($Strict -and $warns.Count -gt 0)){ exit 2 } else { exit 0 }