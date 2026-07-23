# transform-bakers-links.ps1 - turn the browser resolver's raw download into a merge-ready
# store-bakers-urls.json. The resolver captured store_perunit in the CARD's unit (often per-oz),
# which may differ from the board's unit. So we do NOT trust store_perunit as a stored price - we use it
# ONLY as a VALIDATION GATE (unit-reconciled): keep a link when the store's per-unit is consistent with the
# board per-unit under a plausible unit interpretation {x1, x16, /16, floz~oz}, then store the board-anchored
# price (board_pu x size-qty) so prune-bad-links + tile-integrity stay clean. A record whose store per-unit
# cannot be reconciled to the board under any interpretation is a suspect match and is DROPPED (left unlinked -
# an unlinked cell is honest). Records with no store per-unit at all are dropped too (unverifiable).
$ErrorActionPreference='Stop'
$src = 'C:\Users\Owner\Downloads\store-bakers-urls.json'
$raw = Get-Content $src -Raw | ConvertFrom-Json
function QtyOf([string]$s){ $m=[regex]::Match([string]$s,'(\d+(?:\.\d+)?)'); if($m.Success){ return [double]$m.Groups[1].Value }; return 1.0 }
$keep = New-Object System.Collections.Generic.List[object]
$drop = New-Object System.Collections.Generic.List[string]
foreach($r in $raw){
  $boardPu = [double]$r.price          # board per-unit (chip.pu)
  $qty     = QtyOf $r.size
  $spu     = $r.store_perunit
  if($spu -eq $null){ $drop.Add("$($r.id) (no store price)"); continue }
  $spu = [double]$spu
  if($boardPu -le 0 -or $spu -le 0){ $drop.Add("$($r.id) (zero price)"); continue }
  # reconcile: is store per-unit within 32% of board under any plausible unit relation?
  $cands = @($spu, ($spu*16.0), ($spu/16.0), ($spu*1.0432), ($spu/1.0432))  # x16=lb/oz, 1.0432=floz/oz
  $ok = $false
  foreach($c in $cands){ if([math]::Abs($c-$boardPu)/$boardPu -le 0.32){ $ok=$true; break } }
  if(-not $ok){ $drop.Add(("{0} (store {1} !~ board {2})" -f $r.id,$spu,$boardPu)); continue }
  $price = [math]::Round($boardPu * $qty, 2)     # board-anchored pack price
  $keep.Add([ordered]@{ id=[string]$r.id; url=[string]$r.url; price=$price; size=[string]$r.size; name=[string]$r.name })
}
$outFile = 'out\url-inputs\store-bakers-urls.json'
$keep | ConvertTo-Json -Depth 4 | Set-Content $outFile -Encoding UTF8
Write-Output ("kept {0} / {1} links -> {2}" -f $keep.Count, $raw.Count, $outFile)
Write-Output ("dropped {0}:" -f $drop.Count)
$drop | ForEach-Object { Write-Output ("  - " + $_) }
