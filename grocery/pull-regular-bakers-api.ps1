<#
  pull-regular-bakers-api.ps1 - Baker's everyday/current shelf prices from KROGER'S OWN PUBLIC API
  (developer.kroger.com), Omaha Saddlecreek store. Built 2026-07-24.

  WHY THIS EXISTS: Baker's was the last store that could only be read through a real browser - bakersplus.com
  is Akamai-walled, so no headless job could touch it, and a same-day flash-sale check therefore depended on
  Brad's Claude app being open at 6am. Baker's is a Kroger banner, and Kroger publishes a SANCTIONED product
  API with per-store pricing, including the promo (sale) price. Front door instead of the window: no bot wall,
  no pacing ritual, no browser, no app. This puller is the headless replacement.

  THE PRICE WE PUBLISH: price.promo when the store has an active promo, else price.regular. That is what the
  store charges today, which is exactly what the board must show (the "safe is not accurate" rule - publishing
  the regular price during a sale is still a wrong price). Both numbers ride on the row:
      ad_price      = what you pay today   (promo ?? regular)
      current_price = the same value       (the guard-10 contract: a later edit that reaches for the regular
                                            price moves one without the other and the gate hard-fails)
      base_price    = the regular price, ONLY when a promo is live (the was-price)
      marked_down   = true in that case
  `regular` stays null, matching the browser SKILL's convention, so nothing downstream mistakes it for a
  multibuy "regular retail" and runs BOGO math on it.

  BASIS: Kroger returns price and size in the SAME basis (size "1 lb" on a by-weight item means the price IS
  per pound; "12 ct" means the price is for the pack of 12). Both sides come from one field pair, so the
  Walmart pack-price-vs-unit-price catastrophe cannot happen here. Sizes like "1.25 lb" on a pre-packed tray
  are the one ambiguous shape (package price vs per-lb); the per-unit band and the cheapest-per-store ranker
  bound the risk, and -Verify prints them for eyes.

  It writes EVERY result per term and lets compare-deals apply the tested include/exclude + per-unit + band
  filter, the same division of labour the other pullers use. Picking a "best" item here would duplicate
  matching logic in a second place, which is how the two-copies-of-the-same-math blind spot got created.

  *** STATUS 2026-07-24: EVALUATED, WORKS, NOT WIRED INTO THE PIPELINE. ONE BLOCKER. ***
  The pull itself is sound (443/447 terms, 4,804 products, store-scoped, guard-10 contract clean, 97 of 116
  comparable cells agreed with the browser-captured board within 2%). It is BLOCKED on one thing:

    KROGER'S "N ct / M unit" SIZE IS AMBIGUOUS AND THE ENGINE GUESSES WRONG.
      "4 ct / 16 oz"  Kerrygold butter $9.99  -> 16 oz is the TOTAL     -> $9.99/lb
      "6 ct / 8 fl oz" Horizon milk   $8.49   -> 8 fl oz is EACH box    -> 48 fl oz total
    Same string shape, opposite meanings, and no unit-price field exists in the API response to arbitrate.
    Our per-unit engine read the Kerrygold as 4 x 16 oz = 4 lb and published $2.50/lb - a 4x UNDERPRICE that
    sailed straight through the butter price band (1.80-9.00) because it looks perfectly ordinary. Guard 4
    (board vs verified link) is what caught it, along with ~30 more of the same class (chicken thighs came
    out $0.699/lb against a $1.99 link). Guards exit 2; nothing shipped.

  BEFORE THIS CAN FEED THE BOARD, resolve the basis from data rather than the string. The response carries
  the two fields that can do it: items[].soldBy ("UNIT" vs by-weight) and itemInformation.netWeight
  ("0.5 [lb_av]" on the 8 oz butter - authoritative). Rule to build and TEST: for a weight/volume commodity
  prefer netWeight; fall back to the size string only when the shape is unambiguous (single quantity, no
  "N ct /" prefix); refuse otherwise rather than guess. Also worth taking: productPageURI is the REAL product
  URL ("/p/<slug>/<upc>"), which is what a link_url should be built from - never from productId alone.

  USAGE
    -Verify           compare against the current board and WRITE NOTHING (review before trusting)
    -Limit N          only the first N terms (smoke test)
    -ResultsPerTerm N how many products per search (default 15)
  Credentials: grocery\.krogerkey (gitignored) or $env:KROGER_CLIENT_ID / $env:KROGER_CLIENT_SECRET in CI.
#>
param(
  [switch]$Verify,
  [int]$Limit = 0,
  [int]$ResultsPerTerm = 15,
  [string]$LocationId = '61500319',   # Baker's - Saddlecreek, 888 S Saddle Creek Rd, Omaha 68106
  [int]$PaceMs = 180
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$out  = Join-Path $root 'out'
$today = (Get-Date).ToString('yyyy-MM-dd')

# ---------------------------------------------------------------- credentials
$cid = $env:KROGER_CLIENT_ID; $csec = $env:KROGER_CLIENT_SECRET
if (-not $cid -or -not $csec) {
  $kf = Join-Path $root '.krogerkey'
  if (-not (Test-Path $kf)) { throw "Kroger credentials missing: create grocery\.krogerkey (gitignored) or set KROGER_CLIENT_ID / KROGER_CLIENT_SECRET." }
  $k = Get-Content $kf -Raw | ConvertFrom-Json
  $cid = [string]$k.client_id; $csec = [string]$k.client_secret
}

$script:Token = $null; $script:TokenAt = [datetime]::MinValue
function Get-KrogerToken {
  # 30-minute tokens; refresh at 25 so a long run never dies mid-sweep.
  if ($script:Token -and (([datetime]::Now - $script:TokenAt).TotalMinutes -lt 25)) { return $script:Token }
  $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($cid + ':' + $csec))
  $r = Invoke-RestMethod -Method Post -Uri 'https://api.kroger.com/v1/connect/oauth2/token' `
        -Headers @{ Authorization = 'Basic ' + $b64; 'Content-Type' = 'application/x-www-form-urlencoded' } `
        -Body 'grant_type=client_credentials&scope=product.compact'
  $script:Token = [string]$r.access_token; $script:TokenAt = [datetime]::Now
  return $script:Token
}

function Get-KrogerJson([string]$url) {
  # PS 5.1's Invoke-RestMethod mis-decodes the UTF-8 body (Kroger's names carry (R)/(TM) glyphs), which would
  # corrupt product names - and names are what the include/exclude matcher reads. Pull raw bytes and decode
  # UTF-8 explicitly instead of trusting the pipeline's guess.
  $h = @{ Authorization = 'Bearer ' + (Get-KrogerToken); Accept = 'application/json' }
  $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing
  $bytes = $resp.RawContentStream.ToArray()
  return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
}

function Clean-Name([string]$s) {
  # Brand glyphs only: (R), (TM), the replacement char, and a curly apostrophe -> straight. Never touch words,
  # sizes or numbers - the matcher and the per-unit engine both read this string.
  # KEEP THIS FILE PURE ASCII: PS 5.1 reads a BOM-less UTF-8 script as ANSI, so a literal non-ASCII glyph in
  # the SOURCE becomes mojibake and the script will not even parse. Reference characters by code point.
  $t = $s.Replace([string][char]0x00AE, '').Replace([string][char]0x2122, '').Replace([string][char]0xFFFD, ' ')
  $t = $t.Replace([string][char]0x2019, "'").Replace([string][char]0x2018, "'")
  # Anything still outside printable ASCII becomes a space. Kroger's titles carry stray glyphs (a caret-like
  # mark on "Fresh Natural^", non-breaking hyphens in "5-7 Bananas", a replacement char mid-word in
  # "Milk?Product"), and the include/exclude matcher reads this string as a lowercase regex subject - a stray
  # byte sitting inside a word silently breaks the match and the store vanishes from that row. Spaces are
  # safe: they only ever split tokens the matcher already treats as separated.
  $t = ($t -replace '[^\x20-\x7E]', ' ')
  return (($t -replace '\s{2,}', ' ').Trim())
}

# ---------------------------------------------------------------- pull
$terms = (Get-Content (Join-Path $root 'commodity-search.json') -Raw | ConvertFrom-Json).terms
$termList = @($terms.PSObject.Properties)
if ($Limit -gt 0) { $termList = $termList | Select-Object -First $Limit }
Write-Output ("bakers-api: {0} term(s), store {1}, {2} results/term" -f $termList.Count, $LocationId, $ResultsPerTerm)

$deals = New-Object System.Collections.Generic.List[object]
$seen = @{}          # keyed by productId: a product legitimately answers several terms
$stats = [ordered]@{ terms=0; fail=0; products=0; promo=0; nopriced=0 }
$ambiguous = New-Object System.Collections.Generic.List[object]

foreach ($tp in $termList) {
  $id = $tp.Name; $term = [string]$tp.Value
  if (-not $term) { continue }
  $url = 'https://api.kroger.com/v1/products?filter.term={0}&filter.locationId={1}&filter.limit={2}' -f [uri]::EscapeDataString($term), $LocationId, $ResultsPerTerm
  try { $r = Get-KrogerJson $url } catch {
    $stats.fail++; Write-Warning ("term '$term' failed: " + $_.Exception.Message); Start-Sleep -Milliseconds ($PaceMs * 3); continue
  }
  $stats.terms++
  foreach ($p in @($r.data)) {
    $it = @($p.items)[0]
    if (-not $it -or -not $it.price) { $stats.nopriced++; continue }
    $reg = 0.0; $promo = 0.0
    [void][double]::TryParse([string]$it.price.regular, [ref]$reg)
    [void][double]::TryParse([string]$it.price.promo,   [ref]$promo)
    # A promo of 0 means "no promo", not "free".
    $cur = if ($promo -gt 0) { $promo } else { $reg }
    if ($cur -le 0) { $stats.nopriced++; continue }
    $prodId = [string]$p.productId
    if ($seen.ContainsKey($prodId)) { continue }
    $seen[$prodId] = $true
    $name = Clean-Name ([string]$p.description)
    $size = ([string]$it.size).Trim()
    if ($size -match '^\s*1\s*lb\s*$') { $size = 'lb' }   # our per-lb convention; identical math, canonical shape
    $row = [ordered]@{
      store       = "Baker's"
      item        = $name
      ad_price    = ('$' + $cur.ToString('0.00'))
      size        = $size
      regular     = $null
      source_ad   = 'kroger-api'
      as_of       = $today
      current_price = $cur          # guard-10 contract: what the store charges, recorded independently
      product_id  = $prodId
      # NO link_url on purpose. Baker's product pages are /p/<slug>/<upc>, and a URL built from productId
      # alone is a GUESS - shipping an unverified link would put a possibly-404 "See item" on a tile, which
      # is worse than the honest store-search fallback the page already uses. product_id is recorded so a
      # later pass can resolve real URLs and prove them before any of them reach a tile.
      stock_level = [string]$it.inventory.stockLevel
    }
    if ($promo -gt 0 -and $reg -gt $promo) { $row['base_price'] = $reg; $row['marked_down'] = $true; $stats.promo++ }
    $deals.Add([pscustomobject]$row)
    $stats.products++
    # flag the one genuinely ambiguous size shape for human eyes (package price vs per-lb)
    if ($size -match '^\s*[\d.]+\s*lb\s*$' -and $size -ne 'lb') { $ambiguous.Add(($name + ' | ' + $size + ' | $' + $cur)) }
  }
  Start-Sleep -Milliseconds $PaceMs
}

Write-Output ("bakers-api: terms ok={0} failed={1} | products={2} (promo/sale={3}, skipped-unpriced={4})" -f $stats.terms, $stats.fail, $stats.products, $stats.promo, $stats.nopriced)
if ($ambiguous.Count -gt 0) {
  Write-Output ("bakers-api: {0} row(s) carry a multi-pound pack size (price could be pack or per-lb - the band + ranker bound this, listing for eyes):" -f $ambiguous.Count)
  $ambiguous | Select-Object -First 8 | ForEach-Object { Write-Output ('    ' + $_) }
}

# ---------------------------------------------------------------- verify mode: compare, write nothing
if ($Verify) {
  $cmpF = Get-ChildItem (Join-Path $out 'comparison-*.json') | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  $cmp = (Get-Content $cmpF.FullName -Raw | ConvertFrom-Json).comparison
  Write-Output ''
  Write-Output ("VERIFY vs " + $cmpF.BaseName + " (Baker's cells only) - does the API agree with what the browser pull put on the board?")
  # Compare PER-UNIT to PER-UNIT using the engine's own per-unit math (pu-lib), never pack price vs per-unit -
  # different denominators is how you "prove" a 3x discrepancy that isn't there.
  . (Join-Path $root 'pu-lib.ps1')
  $agree = 0; $differ = 0; $rows = New-Object System.Collections.Generic.List[object]
  foreach ($r in $cmp) {
    $b = @($r.stores | Where-Object { $_.store -eq "Baker's" })[0]
    if (-not $b) { continue }
    $boardItem = [string]$b.item
    $hit = $deals | Where-Object { $_.item -eq $boardItem } | Select-Object -First 1
    if (-not $hit) { continue }
    $bp = 0.0; [void][double]::TryParse((([string]$hit.ad_price) -replace '[^0-9.]',''), [ref]$bp)
    $apu = Get-LinkPerUnit ([string]$hit.size) ([string]$r.unit) $bp ([string]$hit.item)
    $bpu = [double]$b.per_unit
    $verdict = 'UNPRICEABLE'
    if ($null -ne $apu -and $apu -gt 0 -and $bpu -gt 0) {
      $off = [math]::Abs($apu - $bpu) / $bpu
      if ($off -le 0.02) { $verdict = 'agree'; $agree++ } else { $verdict = ('DIFFER ' + [math]::Round($off * 100) + '%'); $differ++ }
    }
    $rows.Add([pscustomobject]@{ id=$r.id; board_pu=$bpu; unit=$r.unit; api_pu=$apu; api_size=$hit.size; type=$b.type; promo=[bool]$hit.marked_down; verdict=$verdict })
  }
  Write-Output ("matched {0} board item(s) by exact name: {1} agree (within 2%), {2} differ" -f $rows.Count, $agree, $differ)
  Write-Output ''
  foreach ($x in ($rows | Sort-Object { $_.verdict -eq 'agree' })) {
    $apuS = if ($null -ne $x.api_pu) { ('{0:N4}' -f $x.api_pu) } else { 'n/a' }
    Write-Output ("    {0,-22} board {1,-9} api {2,-9} /{3,-7} [{4,-10}] {5,-8} {6} {7}" -f $x.id, ('{0:N4}' -f $x.board_pu), $apuS, $x.unit, $x.api_size, $x.type, $x.verdict, $(if ($x.promo) { 'PROMO' } else { '' }))
  }
  Write-Output ''
  Write-Output 'VERIFY ONLY - nothing written. Re-run without -Verify to write the capture.'
  exit 0
}

# ---------------------------------------------------------------- write
if ($stats.products -lt 100) {
  Write-Warning ("bakers-api: only $($stats.products) products - refusing to overwrite the capture with a thin pull (a partial pull is an overwrite). Nothing written.")
  exit 1
}
$doc = [ordered]@{
  store = "Baker's"; week_of = $today; price_type = 'everyday'
  price_mode = 'in-store'; mode_verified = $today   # Kroger's API prices ARE the store's shelf prices (locationId-scoped, no delivery markup layer)
  source = 'kroger-public-api'; location_id = $LocationId; store_label = "Baker's - Saddlecreek, Omaha 68106"
  pull_terms = $stats.terms; deal_count = $deals.Count
  deals = $deals.ToArray()
}
$file = Join-Path $out ('regular\bakers-regular-' + $today + '.json')
($doc | ConvertTo-Json -Depth 6) | Set-Content $file -Encoding UTF8
Write-Output ("bakers-api: wrote $($deals.Count) rows -> " + (Split-Path $file -Leaf))

# NO carry-forward here, deliberately. Those helpers exist for PARTIAL browser pulls of the same catalogue.
# This pull is comprehensive (all 447 terms, ~4,800 products vs the browser pass's ~250), and the browser
# captures use a DIFFERENT naming convention for the same product - the API says
#   "Kroger Raw Frozen Bone In Skin On Chicken Wings" $8.99 / "2.5 lb"
# where the browser wrote
#   "Kroger Raw Frozen Bone In Skin On Chicken Wings (2.5 lb)" $3.20 / "lb"
# Carry-forward keys on the name, sees two different items, and keeps BOTH - so a stale 07-18 per-lb row
# competes with today's real price and can win the cheapest-per-store slot. That is the stale-low failure
# the union rules were written to prevent. A comprehensive pull IS the catalogue; the coverage-regression
# guard is what protects us if it ever comes back thin, and the thin-pull refusal above is the first line.
Write-Output 'bakers-api: comprehensive pull - carry-forward/size-heal intentionally skipped (see comment).'
