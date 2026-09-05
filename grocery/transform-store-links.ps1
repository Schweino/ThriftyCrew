# transform-store-links.ps1 - generic version of transform-bakers-links.ps1.
# Turns a browser resolver download (from Downloads) into a merge-ready out\url-inputs\store-<key>-urls.json.
# Uses store_perunit ONLY as a unit-reconciled VALIDATION GATE (the card unit may not be the board unit - the
# 16x brown-sugar trap), then stores the board-anchored pack price. Suspect / unverifiable matches are DROPPED.
# Usage: transform-store-links.ps1 -Key walmart -Src "C:\Users\Owner\Downloads\store-walmart-urls.json"
param([Parameter(Mandatory=$true)][string]$Key, [Parameter(Mandatory=$true)][string]$Src)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$raw = Read-JsonFile $Src
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage

function QtyOf([string]$s){ $m=[regex]::Match([string]$s,'(\d+(?:\.\d+)?)'); if($m.Success){ return [double]$m.Groups[1].Value }; return 1.0 }
$keep = New-Object System.Collections.Generic.List[object]
$drop = New-Object System.Collections.Generic.List[string]
foreach($r in $raw){
  $boardPu = [double]$r.price
  $qty     = QtyOf $r.size
  $spu     = $r.store_perunit
  if($spu -eq $null){ $drop.Add("$($r.id) (no store price)"); continue }
  $spu = [double]$spu
  if($boardPu -le 0 -or $spu -le 0){ $drop.Add("$($r.id) (zero price)"); continue }
  $cands = @($spu, ($spu*16.0), ($spu/16.0), ($spu*1.0432), ($spu/1.0432))
  $ok = $false
  foreach($c in $cands){ if([math]::Abs($c-$boardPu)/$boardPu -le 0.32){ $ok=$true; break } }
  if(-not $ok){ $drop.Add(("{0} (store {1} !~ board {2})" -f $r.id,$spu,$boardPu)); continue }
  $price = [math]::Round($boardPu * $qty, 2)
  $keep.Add([ordered]@{ id=[string]$r.id; url=[string]$r.url; price=$price; size=[string]$r.size; name=[string]$r.name })
}
$outFile = Join-Path $here ("out\url-inputs\store-$Key-urls.json")
$keep | ConvertTo-Json -Depth 4 | Set-Content $outFile -Encoding UTF8
Write-Output ("[{0}] kept {1} / {2} -> store-{0}-urls.json ; dropped {3}" -f $Key, $keep.Count, $raw.Count, $drop.Count)
$drop | ForEach-Object { Write-Output ("  - " + $_) }
