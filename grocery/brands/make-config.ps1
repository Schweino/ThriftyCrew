<#
  make-config.ps1 - Build a brand-config-N.json from a lightweight batch-spec.
  Pulls include/exclude/unit straight from commodities.json (single source of truth) so
  matching can never drift from the board. The spec only supplies label/queries/brands
  (+ optional excludeAdd). Emits the {commodities:{id:{label,unit,queries,include,exclude,brands}}} shape.
  Usage: make-config.ps1 -SpecPath batch-spec-N.json -OutPath brand-config-N.json
#>
param([Parameter(Mandatory=$true)][string]$SpecPath,[Parameter(Mandatory=$true)][string]$OutPath)
$ErrorActionPreference='Stop'
$root='C:\Codex\income\grocery'
$commAll=Get-Content "$root\commodities.json" -Raw | ConvertFrom-Json
$specObj=Get-Content $SpecPath -Raw | ConvertFrom-Json
$cfgOut=[ordered]@{ commodities=[ordered]@{} }
$missing=@()
foreach($prop in $specObj.PSObject.Properties){
  $id=$prop.Name; $s=$prop.Value
  $c=$commAll | Where-Object { $_.id -eq $id }
  if(-not $c){ $missing+=$id; continue }
  $inc = (@($c.include) -join '|')
  $exc = (@($c.exclude) -join '|')
  if(($s.PSObject.Properties.Name -contains 'excludeAdd') -and $s.excludeAdd){ if($exc){ $exc = $exc + '|' + [string]$s.excludeAdd } else { $exc = [string]$s.excludeAdd } }
  $label = if(($s.PSObject.Properties.Name -contains 'label') -and $s.label){ [string]$s.label } else { [string]$c.label }
  $cfgOut.commodities[$id]=[ordered]@{ label=$label; unit=[string]$c.unit; queries=@($s.queries); include=$inc; exclude=$exc; brands=@($s.brands) }
}
if($missing.Count){ Write-Output ("WARN not on board (skipped): " + ($missing -join ', ')) }
($cfgOut | ConvertTo-Json -Depth 8) | Set-Content $OutPath -Encoding UTF8
Write-Output ("wrote " + $OutPath + " with " + $cfgOut.commodities.Count + " commodities")
