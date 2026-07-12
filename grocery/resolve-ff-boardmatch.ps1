<#
  resolve-ff-boardmatch.ps1 - THE fix for link/price divergence at Family Fare. The board (recipe-board.json /
  comparison) records the EXACT product it priced per store (stores[].item + size). The "See item" link must
  point at THAT SAME product, or the per-unit won't match the card price. This re-resolves every Family Fare
  cell listed in out\link-price-mismatch.json by looking up the BOARD's item name in the Freshop API, matching
  the same product (name + size), and storing its URL + CURRENT price. That unifies link==board product and
  refreshes the price in one step. Writes out\url-inputs\store-ff9-urls.json.
#>
param([string]$OutDir = "")
$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$mm = @(Get-Content (Join-Path $OutDir 'link-price-mismatch.json') -Raw | ConvertFrom-Json) | Where-Object { $_.store -eq 'Family Fare' }
# board item per (id) from recipe-board + comparison
$board = @{}
foreach ($bf in @('comparison','recipe-board')) {
  $f = if ($bf -eq 'comparison') { (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName } else { Join-Path $OutDir 'recipe-board.json' }
  if (-not (Test-Path $f)) { continue }
  foreach ($it in (Get-Content $f -Raw | ConvertFrom-Json).comparison) { $ff = $it.stores | Where-Object { $_.store -eq 'Family Fare' } | Select-Object -First 1; if ($ff) { $board[[string]$it.id] = @{ item=[string]$ff.item; size=[string]$ff.size } } }
}
function norm($s){ (([string]$s).ToLower() -replace '[^a-z0-9 ]',' ' -replace '\s+',' ').Trim() }
$rows = New-Object System.Collections.Generic.List[object]; $miss = New-Object System.Collections.Generic.List[string]
foreach ($c in $mm) { $id=[string]$c.id; if (-not $board.ContainsKey($id)) { $miss.Add("$id (no board item)"); continue }
  $bi = $board[$id].item; if (-not $bi) { $miss.Add("$id (blank board item)"); continue }
  $bwords = @((norm $bi) -split ' ' | Where-Object { $_.Length -gt 2 })
  $api = 'https://api.freshop.ncrcloud.com/1/products?app_key=family_fare&store_id=6401&limit=25&q=' + [uri]::EscapeDataString($bi)
  $best=$null; $bestScore=-1
  try { foreach ($p in @(((Invoke-WebRequest -Uri $api -UseBasicParsing -TimeoutSec 20 -Headers @{'User-Agent'='Mozilla/5.0';'Accept'='application/json'}).Content|ConvertFrom-Json).items)) {
      $pn = norm $p.name; $hits = 0; foreach ($w in $bwords) { if ($pn -match ('\b'+[regex]::Escape($w)+'\b')) { $hits++ } }
      # bonus if size matches the board's size
      if ($board[$id].size -and (norm $p.size) -eq (norm $board[$id].size)) { $hits += 2 }
      if ($hits -gt $bestScore -and $p.base_price) { $bestScore=$hits; $best=$p }
    } } catch {}
  Start-Sleep -Milliseconds 250
  # require a solid name overlap so we don't grab a wrong product
  if ($best -and $bestScore -ge [math]::Max(2, [int]($bwords.Count*0.5))) {
    $rows.Add([pscustomobject]@{ id=$id; url=$best.canonical_url; price=[math]::Round([double]$best.base_price,2); size=$best.size; name=$best.name })
    "OK   {0,-22} board='{1}' -> link='{2}' `${3} / {4}" -f $id,$bi,$best.name,$best.base_price,$best.size
  } else { $miss.Add("$id (board='$bi' no confident match, score=$bestScore)"); "MISS {0,-22} board='{1}'" -f $id,$bi }
}
$dir=Join-Path $OutDir 'url-inputs'; ($rows|ConvertTo-Json -Depth 4)|Set-Content (Join-Path $dir 'store-ff9-urls.json') -Encoding UTF8
"---- matched $($rows.Count)/$($mm.Count); misses:"; $miss | ForEach-Object { "   $_" }