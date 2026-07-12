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
# read the canonical consistency report (falls back to the old mismatch file for manual runs).
# Repair set = mismatch (link price drifted) UNION no_link (chip renders NO link: URL missing entirely, or
# suppressed by the identity gate). Mismatch-only left no_link chips broken forever - a chip with NO stored URL
# was never in mismatch, so it was never repaired (the FF peaches/apples linkless chips Brad caught).
$mmFile = Join-Path $OutDir 'consistency-report.json'
if (Test-Path $mmFile) {
  $rep = Get-Content $mmFile -Raw | ConvertFrom-Json
  $seen = @{}
  $mm = @(@($rep.mismatch) + @($rep.no_link) | Where-Object { $_ -and ([string]$_.store) -eq 'Family Fare' } | Where-Object { $k = [string]$_.id; if ($seen.ContainsKey($k)) { $false } else { $seen[$k] = $true; $true } })
}
else { $mm = @(Get-Content (Join-Path $OutDir 'link-price-mismatch.json') -Raw | ConvertFrom-Json) | Where-Object { $_.store -eq 'Family Fare' } }
# commodity label + include/exclude for the fallback search (a flyer-only board name like "Tree Ripened Yellow
# Flesh Peaches, Small" won't exist verbatim in Freshop; the commodity LABEL - "Peaches" - will)
$cmeta = @{}
try { foreach ($cdef in (Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json)) { $cmeta[[string]$cdef.id] = @{ label=[string]$cdef.label; inc=@($cdef.include); exc=@($cdef.exclude) } } } catch {}
# board item per (id) from recipe-board + comparison. ORDER MATTERS: recipe-board first, comparison LAST so
# the STAPLE row's product wins when an id exists in both (product-urls holds ONE entry per id x store, and the
# staple board is the primary surface; letting recipe-board overwrite repaired staple milk against a "Whole
# Milk Mozzarella" recipe row - a wrong-product repair).
$board = @{}
foreach ($bf in @('recipe-board','comparison')) {
  $f = if ($bf -eq 'comparison') { (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName } else { Join-Path $OutDir 'recipe-board.json' }
  if (-not (Test-Path $f)) { continue }
  foreach ($it in (Get-Content $f -Raw | ConvertFrom-Json).comparison) { $ff = $it.stores | Where-Object { $_.store -eq 'Family Fare' } | Select-Object -First 1; if ($ff) { $board[[string]$it.id] = @{ item=[string]$ff.item; size=[string]$ff.size } } }
}
function norm($s){ (([string]$s).ToLower() -replace '[^a-z0-9 ]',' ' -replace '\s+',' ').Trim() }
# Freshop session token (same as pull-regular-familyfare): tokenless calls now 400, and a REUSED token gets
# rate-limited to 200-with-zero-items. Mint fresh, re-mint on any empty/error result.
$UA = @{ 'User-Agent'='Mozilla/5.0'; 'Accept'='application/json' }
function Get-FreshToken {
  foreach ($tu in @('https://api.freshop.ncrcloud.com/2/sessions?app_key=family_fare','https://api.freshop.ncrcloud.com/1/sessions?app_key=family_fare')) {
    try { $ts = Invoke-RestMethod -Uri $tu -Method Post -Headers $UA -TimeoutSec 20; if ($ts.token) { return [string]$ts.token } } catch {}
  }
  return ''
}
$script:tok = Get-FreshToken
function Search-Freshop([string]$q) {
  for ($try = 0; $try -lt 3; $try++) {
    $tq = if ($script:tok) { '&token=' + $script:tok } else { '' }
    try {
      $r = Invoke-RestMethod -Uri ('https://api.freshop.ncrcloud.com/1/products?app_key=family_fare&store_id=6401' + $tq + '&limit=25&fields=name,size,base_price,canonical_url&q=' + [uri]::EscapeDataString($q)) -Headers $UA -TimeoutSec 25
      if (@($r.items).Count -gt 0) { return @($r.items) }
    } catch {}
    $script:tok = Get-FreshToken
    Start-Sleep -Milliseconds 700
  }
  return @()
}
$rows = New-Object System.Collections.Generic.List[object]; $miss = New-Object System.Collections.Generic.List[string]
foreach ($c in $mm) { $id=[string]$c.id; if (-not $board.ContainsKey($id)) { $miss.Add("$id (no board item)"); continue }
  $bi = $board[$id].item; if (-not $bi) { $miss.Add("$id (blank board item)"); continue }
  $bwords = @((norm $bi) -split ' ' | Where-Object { $_.Length -gt 2 })
  $best=$null; $bestScore=-1
  foreach ($p in (Search-Freshop $bi)) {
      $pn = norm $p.name; $hits = 0; foreach ($w in $bwords) { if ($pn -match ('\b'+[regex]::Escape($w)+'\b')) { $hits++ } }
      # bonus if size matches the board's size
      if ($board[$id].size -and (norm $p.size) -eq (norm $board[$id].size)) { $hits += 2 }
      if ($hits -gt $bestScore -and $p.base_price) { $bestScore=$hits; $best=$p }
  }
  Start-Sleep -Milliseconds 250
  # require a solid name overlap so we don't grab a wrong product
  if ($best -and $bestScore -ge [math]::Max(2, [int]($bwords.Count*0.5))) {
    $rows.Add([pscustomobject]@{ id=$id; url=$best.canonical_url; price=[math]::Round([double]$best.base_price,2); size=$best.size; name=$best.name })
    "OK   {0,-22} board='{1}' -> link='{2}' `${3} / {4}" -f $id,$bi,$best.name,$best.base_price,$best.size
    continue
  }
  # FALLBACK: search by the commodity LABEL and validate with the commodity's OWN include/exclude (not the
  # flyer name). Grabs the store's plain product page for a flyer-worded sale item ("Tree Ripened Yellow Flesh
  # Peaches, Small" -> label "Peaches" -> "Fresh Peaches"). CHEAPEST valid match = the same pick compare-deals
  # would make; the build's price band still guards the final render.
  $fb = $null
  if ($cmeta.ContainsKey($id) -and $cmeta[$id].label) {
    $cands = @()
    foreach ($p in (Search-Freshop $cmeta[$id].label)) {
      if (-not $p.base_price -or -not $p.canonical_url) { continue }
      $inc = $false; foreach ($pat in $cmeta[$id].inc) { if ($pat -and ([string]$p.name) -imatch $pat) { $inc = $true; break } }
      if (-not $inc) { continue }
      $bad = $false; foreach ($pat in $cmeta[$id].exc) { if ($pat -and ([string]$p.name) -imatch $pat) { $bad = $true; break } }
      if (-not $bad) { $cands += ,$p }
    }
    $fb = $cands | Sort-Object { [double]$_.base_price } | Select-Object -First 1
    Start-Sleep -Milliseconds 250
  }
  if ($fb) {
    $rows.Add([pscustomobject]@{ id=$id; url=$fb.canonical_url; price=[math]::Round([double]$fb.base_price,2); size=$fb.size; name=$fb.name })
    "OK   {0,-22} board='{1}' -> label-fallback link='{2}' `${3} / {4}" -f $id,$bi,$fb.name,$fb.base_price,$fb.size
  } else { $miss.Add("$id (board='$bi' no confident match, score=$bestScore)"); "MISS {0,-22} board='{1}'" -f $id,$bi }
}
$dir=Join-Path $OutDir 'url-inputs'; ($rows|ConvertTo-Json -Depth 4)|Set-Content (Join-Path $dir 'store-ff9-urls.json') -Encoding UTF8
"---- matched $($rows.Count)/$($mm.Count); misses:"; $miss | ForEach-Object { "   $_" }