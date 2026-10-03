# Emits browser-cfg.json: the SAME matching config the browser bucketers use, generated from
# brand-config.json so FF (PS) and the browser stores can never diverge. inc/ex have (?i) stripped
# (browser uses the 'i' flag). Store-brand handled per-store in the browser bucketer.
param(
  [string]$ConfigPath = '',
  [string]$OutPath = ''
)
. (Join-Path $PSScriptRoot '..\..\lib\lf-write.ps1')       # Write-TcLfFile: a tracked file is written in the bytes git stores
$ErrorActionPreference='Stop'
$here=$PSScriptRoot
if(-not $ConfigPath){ $ConfigPath = Join-Path $here 'brand-config.json' }
if(-not $OutPath){ $OutPath = Join-Path $here 'browser-cfg.json' }
$cfg = (Get-Content $ConfigPath -Raw | ConvertFrom-Json).commodities
$out=[ordered]@{}
foreach($cid in $cfg.PSObject.Properties.Name){
  $c=$cfg.$cid
  $inc = ([string]$c.include) -replace '^\(\?i\)',''
  $ex  = ([string]$c.exclude) -replace '^\(\?i\)',''
  $out[$cid]=[ordered]@{ u=[string]$c.unit; brands=@($c.brands | Where-Object { $_ -ne 'Great Value' }); inc=$inc; ex=$ex }
}
$null = ($out | ConvertTo-Json -Depth 6 -Compress) | Write-TcLfFile -Path $OutPath
Write-Output ($OutPath + ": " + $out.Count + " commodities")