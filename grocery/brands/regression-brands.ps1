<#
  regression-brands.ps1 - Guards against new bugs when adding a brand batch.
  Compares current brands-board.json against a baseline snapshot: every commodity that
  existed in the baseline MUST still exist with a byte-identical node (no silent drops or
  mutations of already-shipped data). New commodities are allowed. Exit 2 on any regression.
  Usage: regression-brands.ps1 -Baseline <path-to-snapshot.json>
#>
param([Parameter(Mandatory=$true)][string]$Baseline)
$ErrorActionPreference='Stop'
$here='C:\Codex\income\grocery'
$cur  = Get-Content "$here\out\brands\brands-board.json" -Raw | ConvertFrom-Json
$base = Get-Content $Baseline -Raw | ConvertFrom-Json
$fail=0
foreach($p in $base.commodities.PSObject.Properties){
  $id=$p.Name
  $curNode=$cur.commodities.$id
  if($null -eq $curNode){ Write-Output ("REGRESSION: lost commodity '"+$id+"'"); $fail=1; continue }
  $a=($p.Value  | ConvertTo-Json -Depth 9 -Compress)
  $b=($curNode  | ConvertTo-Json -Depth 9 -Compress)
  if($a -ne $b){ Write-Output ("REGRESSION: commodity '"+$id+"' node changed"); $fail=1 }
}
$baseCount=@($base.commodities.PSObject.Properties).Count
$curCount=@($cur.commodities.PSObject.Properties).Count
Write-Output ("baseline commodities: {0} -> current: {1} (added {2})" -f $baseCount,$curCount,($curCount-$baseCount))
# structural QA on every commodity (unit/floor/null/dup/spread) reused from qa-brands
& "$here\brands\qa-brands.ps1" | Out-Null
if($LASTEXITCODE -eq 2){ Write-Output 'REGRESSION: qa-brands hard error'; $fail=1 }
if($fail){ Write-Output 'REGRESSION FAILED'; exit 2 } else { Write-Output 'REGRESSION OK: all prior commodities intact + QA clean' }
