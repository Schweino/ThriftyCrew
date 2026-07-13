# Emits browser-cfg.json: the SAME matching config the browser bucketers use, generated from
# brand-config.json so FF (PS) and the browser stores can never diverge. inc/ex have (?i) stripped
# (browser uses the 'i' flag). Store-brand handled per-store in the browser bucketer.
$ErrorActionPreference='Stop'
$here=$PSScriptRoot
$cfg = (Get-Content (Join-Path $here 'brand-config.json') -Raw | ConvertFrom-Json).commodities
$out=[ordered]@{}
foreach($cid in $cfg.PSObject.Properties.Name){
  $c=$cfg.$cid
  $inc = ([string]$c.include) -replace '^\(\?i\)',''
  $ex  = ([string]$c.exclude) -replace '^\(\?i\)',''
  $out[$cid]=[ordered]@{ u=[string]$c.unit; brands=@($c.brands | Where-Object { $_ -ne 'Great Value' }); inc=$inc; ex=$ex }
}
($out | ConvertTo-Json -Depth 6 -Compress) | Set-Content (Join-Path $here 'browser-cfg.json') -Encoding UTF8
Write-Output ("browser-cfg.json: " + $out.Count + " commodities")