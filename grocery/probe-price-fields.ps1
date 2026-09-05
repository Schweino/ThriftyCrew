<#
  probe-price-fields.ps1 - PHASE 0 of PLAN-live-price-state-2026-08-21.md.

  THE QUESTION, and it is Brad's (2026-08-21): "Can we triage why theres no end date? We should
  figure that out first before making a decision."

  He is right that the plan had it backwards. It listed "does this store expose a sale end date?" as
  MUST VERIFY for six of nine sources, and then asked him to choose a markdown TTL as though the
  absence were established. A TTL is the fallback for a source that provably cannot date its own
  discount. A source that CAN date one needs no TTL at all - it gets a real ad_to and expires by
  arithmetic, exactly like a flyer already does through Test-AdWindowClosed.

  So this answers three questions per source, from the bytes and never from belief:

    1. LIVE    does the payload say a discount is currently running? (onSale, promo, marked_down,
               a was-price, a strike-through)
    2. ENDS    does it say WHEN that discount ends - a date, a duration, or a promotion id that
               could be resolved to one?
    3. ELSEWHERE if not, is the end date reachable from a second FIRST-PARTY surface (the flyer
               feed, a promotions endpoint, the product page rather than the search tile)?

  It writes the raw payload for every source it can reach to out\audit\price-fields\, so the answer
  in the report is always backed by bytes somebody else can re-read. That is the phase gate: every
  row of the plan's 3.2 table cites a file.

  HEADLESS ONLY, DELIBERATELY. Kroger, Hy-Vee and Freshop answer server-side. Walmart, Sam's, Aldi
  and Fareway need a logged-in Chrome, so this emits their PROBE PLAN - the exact expression to run
  in each tab - rather than pretending it captured them. A probe that silently skips four of seven
  stores and prints a clean summary is the confident-ok-over-an-empty-examination shape this estate
  keeps rediscovering; the report names them as NOT PROBED.

  Usage: probe-price-fields.ps1 [-OutDir <dir>] [-Term 'butter']
#>
param(
  [string]$OutDir = '',
  [string]$Term = 'butter'
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$dir = Join-Path $OutDir 'audit\price-fields'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$today = (Get-Date).ToString('yyyy-MM-dd')

$findings = New-Object System.Collections.Generic.List[object]
function Add-Finding($source, $live, $ends, $elsewhere, $evidence, $note) {
  [void]$findings.Add([ordered]@{
    source = $source; says_discount_is_live = $live; says_when_it_ends = $ends
    end_date_reachable_elsewhere = $elsewhere; evidence = $evidence; note = $note
  })
}

# Every key name that could plausibly carry a promotion window. Searched over the RAW TEXT of each
# payload, so a field nested anywhere is still found. Deliberately generous: a false positive costs
# one look, a false negative costs a wrong TTL.
$END_HINTS = @(
  'promoend','promo_end','promostart','promo_start','enddate','end_date','startdate','start_date',
  'validto','valid_to','validfrom','valid_from','expir','effectiveend','effective_end',
  'salestart','sale_start','saleend','sale_end','salefinish','sale_finish','finish_date',
  'promotionend','promotion_end','offerend','offer_end','rollbackend','rollback_end',
  'displayend','display_end','availableuntil','runsthrough','through_date','duration','promotionid','promotion_id'
)
function Find-EndHints([string]$raw) {
  $hits = New-Object System.Collections.Generic.List[string]
  $low = $raw.ToLower()
  foreach ($h in $END_HINTS) {
    $i = $low.IndexOf($h)
    if ($i -ge 0) {
      # keep a little context so the report shows the value, not just the key
      $s = [math]::Max(0, $i - 30); $len = [math]::Min(140, $raw.Length - $s)
      [void]$hits.Add((($raw.Substring($s, $len)) -replace '\s+', ' '))
    }
  }
  return $hits
}

Write-Output ("PHASE 0 - why is there no end date?   probe term: '$Term'   $today")
Write-Output ('=' * 88)

# ---------------------------------------------------------------- 1. Kroger (Baker's)
Write-Output ''
Write-Output "-- Baker's (Kroger public API)"
try {
  $cid = $env:KROGER_CLIENT_ID; $csec = $env:KROGER_CLIENT_SECRET
  if (-not $cid) {
    $kf = Join-Path $root '.krogerkey'
    if (Test-Path $kf) { $k = Read-JsonFile $kf; $cid = [string]$k.client_id; $csec = [string]$k.client_secret }
  }
  if (-not $cid) { throw 'no Kroger credentials (.krogerkey / KROGER_CLIENT_ID)' }
  $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($cid + ':' + $csec))
  $tok = (Invoke-RestMethod -Method Post -Uri 'https://api.kroger.com/v1/connect/oauth2/token' `
      -Headers @{ Authorization = 'Basic ' + $b64; 'Content-Type' = 'application/x-www-form-urlencoded' } `
      -Body 'grant_type=client_credentials&scope=product.compact' -TimeoutSec 30).access_token
  $url = 'https://api.kroger.com/v1/products?filter.term={0}&filter.locationId=61500319&filter.limit=25' -f [uri]::EscapeDataString($Term)
  $resp = Invoke-WebRequest -Uri $url -Headers @{ Authorization = 'Bearer ' + $tok; Accept = 'application/json' } -UseBasicParsing -TimeoutSec 30
  $raw = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
  $f = Join-Path $dir "bakers-kroger-$today.json"
  [IO.File]::WriteAllText($f, $raw, (New-Object System.Text.UTF8Encoding($false)))
  $doc = $raw | ConvertFrom-Json
  # a product with a live promo is the only one that could carry a window
  $promo = @($doc.data | Where-Object { $_.items -and @($_.items | Where-Object { $_.price -and $_.price.promo -gt 0 -and $_.price.promo -lt $_.price.regular }).Count -gt 0 })
  $hints = Find-EndHints $raw
  Write-Output ("   products=" + @($doc.data).Count + "  with a live promo=" + $promo.Count)
  Write-Output ("   price object keys: " + ((@($doc.data)[0].items[0].price.PSObject.Properties.Name) -join ', '))
  Write-Output ("   item keys        : " + ((@($doc.data)[0].items[0].PSObject.Properties.Name) -join ', '))
  if ($hints.Count) { foreach ($h in $hints) { Write-Output ("   HINT " + $h) } } else { Write-Output '   no promotion-window key anywhere in the payload' }
  Add-Finding "Baker's (Kroger /v1/products)" $true ($hints.Count -gt 0) 'flyer lane (bakers-deals ad_from/ad_to)' (Split-Path $f -Leaf) `
    ("price exposes promo vs regular so LIVE is knowable; window keys found: " + $(if ($hints.Count) { $hints.Count } else { 0 }))
} catch {
  Write-Output ('   NOT PROBED: ' + $_.Exception.Message)
  Add-Finding "Baker's (Kroger /v1/products)" 'unknown' 'unknown' 'unknown' '' ('probe failed: ' + $_.Exception.Message)
}

# ---------------------------------------------------------------- 2. Hy-Vee (persisted GraphQL)
Write-Output ''
Write-Output '-- Hy-Vee (persisted GraphQL, Omaha #01)'
try {
  $qFile = Join-Path $root 'hyvee\query-b64.txt'
  if (-not (Test-Path $qFile)) { throw "missing $qFile" }
  $QUERY = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(((Get-Content $qFile -Raw) -replace '\s','')))
  # THE DOCUMENT ITSELF IS EVIDENCE. If it never SELECTS a promotion end field, the response cannot
  # carry one - and that is a different answer from "the store does not have it".
  $qf = Join-Path $dir "hyvee-query-document-$today.graphql"
  [IO.File]::WriteAllText($qf, $QUERY, (New-Object System.Text.UTF8Encoding($false)))
  $qHints = Find-EndHints $QUERY
  Write-Output ("   query document: " + $QUERY.Length + " chars -> " + (Split-Path $qf -Leaf))
  Write-Output ("   promotion-ish fields SELECTED by the document: " + $(if ($qHints.Count) { $qHints.Count } else { 'NONE' }))
  foreach ($h in $qHints) { Write-Output ("   HINT " + $h) }
  # and a live response for a product we know was marked down today
  $hv = Get-ChildItem (Join-Path $OutDir 'regular\hyvee-regular-*.json') | Sort-Object Name -Descending | Select-Object -First 1
  $prodId = $null
  if ($hv) {
    $doc = Read-JsonFile $hv.FullName
    $row = @($doc.deals) | Where-Object { $_.product_id -gt 0 } | Select-Object -First 1
    if ($row) { $prodId = [int]$row.product_id }
  }
  if ($prodId) {
    $body = @{ operationName='getProductDetailsWithPrice'; query=$QUERY; variables=@{
        productId=$prodId; storeId=1465; locationIds=@('adcb2ae1-f440-4512-bfe8-9624832c72a9')
        pickupLocationHasLocker=$false; retailItemEnabled=$true; targeted=$false; foodHealthScoreEnabled=$false } } | ConvertTo-Json -Depth 6 -Compress
    $r = Invoke-WebRequest -Uri 'https://www.hy-vee.com/aisles-online/api/graphql/two-legged/getProductDetailsWithPrice' `
        -Method Post -Body $body -UseBasicParsing -TimeoutSec 25 `
        -Headers @{ 'content-type'='application/json'; 'x-operation-name'='getProductDetailsWithPrice'; 'apollographql-client-name'='aisles-online-web'; 'User-Agent'='Mozilla/5.0' }
    $raw = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    $f = Join-Path $dir "hyvee-response-$today.json"
    [IO.File]::WriteAllText($f, $raw, (New-Object System.Text.UTF8Encoding($false)))
    $rHints = Find-EndHints $raw
    $sp = ($raw | ConvertFrom-Json).data.storeProducts.storeProducts | Where-Object { [int]$_.storeId -eq 1465 } | Select-Object -First 1
    Write-Output ("   live response for productId $prodId -> " + (Split-Path $f -Leaf))
    Write-Output ("   storeProducts keys: " + (($sp.PSObject.Properties.Name) -join ', '))
    Write-Output ("   promotion-ish keys in the RESPONSE: " + $(if ($rHints.Count) { $rHints.Count } else { 'NONE' }))
    foreach ($h in $rHints) { Write-Output ("   HINT " + $h) }
    Add-Finding 'Hy-Vee (persisted GraphQL)' $true ($rHints.Count -gt 0) 'Flipp weekly-ad feed (ads-*.json, store-level window only)' `
      ((Split-Path $qf -Leaf) + ' + ' + (Split-Path $f -Leaf)) `
      ('onSale + basePrice give LIVE; document selects ' + $(if ($qHints.Count) { $qHints.Count } else { 0 }) + ' promotion-ish field(s)')
  } else {
    Write-Output '   no product_id available to probe a live response'
    Add-Finding 'Hy-Vee (persisted GraphQL)' $true 'unknown' 'Flipp weekly-ad feed' (Split-Path $qf -Leaf) 'query document captured; no live response probed'
  }
} catch {
  Write-Output ('   NOT PROBED: ' + $_.Exception.Message)
  Add-Finding 'Hy-Vee (persisted GraphQL)' 'unknown' 'unknown' 'unknown' '' ('probe failed: ' + $_.Exception.Message)
}

# ---------------------------------------------------------------- 3. Family Fare (Freshop)
Write-Output ''
Write-Output '-- Family Fare (Freshop search)'
try {
  $ffAk = 'family_fare'; $ffSid = '6401'; $ffB = 'https://api.freshop.ncrcloud.com/1'
  # NO fields= WHITELIST ON PURPOSE. The puller passes one; asking for the narrowed set here would hide
  # any sale-date field the catalog does carry and let this probe report a false absence.
  $ffUrl = "$ffB/products?app_key=$ffAk&store_id=$ffSid&q=" + [uri]::EscapeDataString($Term) + '&limit=25'
  $lib = Join-Path $root 'ff-price-lib.ps1'
  # reuse the real endpoint the puller uses rather than guessing one
  $ffCfg = Select-String -LiteralPath (Join-Path $root 'pull-regular-familyfare.ps1') -Pattern 'api\.freshop\.com[^''"]*' | Select-Object -First 1
  if ($ffCfg) { Write-Output ('   puller endpoint: ' + ($ffCfg.Matches[0].Value.Substring(0,[Math]::Min(120,$ffCfg.Matches[0].Value.Length)))) }
  $r = Invoke-WebRequest -Uri $ffUrl -UseBasicParsing -TimeoutSec 25
  $raw = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
  $f = Join-Path $dir "familyfare-freshop-$today.json"
  [IO.File]::WriteAllText($f, $raw, (New-Object System.Text.UTF8Encoding($false)))
  $hints = Find-EndHints $raw
  $doc = $raw | ConvertFrom-Json
  Write-Output ("   items=" + @($doc.items).Count + " -> " + (Split-Path $f -Leaf))
  if (@($doc.items).Count) { Write-Output ("   item keys: " + ((@($doc.items)[0].PSObject.Properties.Name) -join ', ')) }
  if ($hints.Count) { foreach ($h in $hints) { Write-Output ("   HINT " + $h) } } else { Write-Output '   no promotion-window key anywhere in the payload' }
  # THE PRODUCT RECORD IS NOT THE WHOLE STORE. It carries no dates, but it carries offer_ids,
  # circular_ids and has_featured_offer - references to records that might. Following them is the
  # difference between "Family Fare cannot date a sale" and "we were reading the wrong endpoint",
  # and only one of those two answers licenses a TTL.
  $offHints = @(); $circHints = @()
  foreach ($pair in @(@('offers', "$ffB/offers?app_key=$ffAk&store_id=$ffSid&limit=25"),
                      @('circulars', "$ffB/circulars?app_key=$ffAk&store_id=$ffSid&limit=10"))) {
    try {
      $rr = Invoke-WebRequest -Uri $pair[1] -UseBasicParsing -TimeoutSec 25
      $rawx = [Text.Encoding]::UTF8.GetString($rr.RawContentStream.ToArray())
      $fx = Join-Path $dir ("familyfare-freshop-" + $pair[0] + "-$today.json")
      [IO.File]::WriteAllText($fx, $rawx, (New-Object System.Text.UTF8Encoding($false)))
      $dx = $rawx | ConvertFrom-Json
      $itx = if ($dx.items) { @($dx.items) } else { @($dx) }
      $kx = if ($itx.Count) { @($itx[0].PSObject.Properties.Name) } else { @() }
      $dated = @($kx | Where-Object { $_ -match 'start_date|finish_date' })
      Write-Output ("   /" + $pair[0] + ": " + $itx.Count + " record(s) -> " + (Split-Path $fx -Leaf))
      Write-Output ("     window keys: " + $(if ($dated.Count) { $dated -join ', ' } else { 'NONE' }))
      if ($pair[0] -eq 'offers') { $offHints = $dated } else { $circHints = $dated }
    } catch { Write-Output ("   /" + $pair[0] + ": ERR " + $_.Exception.Message) }
  }
  Add-Finding 'Family Fare (Freshop)' $true ($offHints.Count -gt 0) `
    ('/offers carries ' + ($offHints -join '/') + ' with product_ids; /circulars carries ' + ($circHints -join '/')) `
    ((Split-Path $f -Leaf) + ' + familyfare-freshop-offers/circulars') `
    ('the PRODUCT record has no date field at all (74 keys, only last_updated_at), but /offers does - so this store CAN date a sale and needs no TTL')
} catch {
  Write-Output ('   NOT PROBED: ' + $_.Exception.Message)
  Add-Finding 'Family Fare (Freshop)' 'unknown' 'unknown' 'unknown' '' ('probe failed: ' + $_.Exception.Message)
}

# ---------------------------------------------------------------- 4. the browser stores: PROBE PLAN, not a claim
Write-Output ''
Write-Output '-- Walmart / Sam''s Club / Aldi / Fareway: NOT PROBED HERE (need a logged-in Chrome)'
Write-Output '   Run each expression in that store''s tab and save the result under out\audit\price-fields\.'
$browser = [ordered]@{
  'Walmart'    = "JSON.stringify((()=>{const d=JSON.parse(document.getElementById('__NEXT_DATA__').textContent);const s=JSON.stringify(d);return {hits:['wasPrice','rollback','priceDisplayCodes','submapType','eventAttributes','priceRange','unitPrice'].filter(k=>s.includes(k)),sample:(d.props.pageProps.initialData.searchResult.itemStacks[0].items[0]||{}).priceInfo};})())"
  "Sam's Club" = "JSON.stringify((()=>{const d=JSON.parse(document.getElementById('__NEXT_DATA__').textContent);const s=JSON.stringify(d);return {hits:['instantSavings','savingsEndDate','promotion','wasPrice','strikethrough','endDate','validThru'].filter(k=>s.includes(k))};})())"
  'Aldi'       = "JSON.stringify((()=>{const c=document.querySelector('[data-testid=item-card-image]');const t=c?c.closest('div').innerText:'';const s=document.documentElement.innerHTML;return {cardText:t.slice(0,300),hits:['was ','strikethrough','line-through','promotionEndDate','endDate','validUntil','sale_end'].filter(k=>s.includes(k))};})())"
  'Fareway'    = "JSON.stringify((()=>{const s=document.documentElement.innerHTML;const a=window.__APOLLO_CLIENT__&&JSON.stringify(window.__APOLLO_CLIENT__.cache.extract()).slice(0,0);return {hits:['Original Price','line-through','promotionEndDate','endDate','validUntil','expires','sale_end','priceExpiry'].filter(k=>s.includes(k))};})())"
}
foreach ($k in $browser.Keys) {
  Write-Output ''
  Write-Output ("   [$k]")
  Write-Output ('   ' + $browser[$k])
  Add-Finding $k 'unknown' 'unknown' 'unknown' '' 'NOT PROBED - needs a logged-in Chrome; expression emitted in the probe plan'
}
$planFile = Join-Path $dir "browser-probe-plan-$today.json"
[IO.File]::WriteAllText($planFile, (($browser | ConvertTo-Json -Depth 4)), (New-Object System.Text.UTF8Encoding($false)))

# ---------------------------------------------------------------- report
$rep = [ordered]@{
  generated = (Get-Date).ToString('s'); term = $Term
  question  = 'Per source: does it say a discount is LIVE, does it say when it ENDS, and if not is the end date reachable from another first-party surface? A source that can date its own discount needs no TTL.'
  probed    = @($findings | Where-Object { $_.evidence })
  not_probed= @($findings | Where-Object { -not $_.evidence } | ForEach-Object { $_.source })
  findings  = $findings.ToArray()
}
$rf = Join-Path $dir "phase0-report-$today.json"
[IO.File]::WriteAllText($rf, ($rep | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
Write-Output ''
Write-Output ('=' * 88)
Write-Output ("probed " + @($rep.probed).Count + " of " + $findings.Count + " source(s); NOT PROBED: " + (@($rep.not_probed) -join ', '))
Write-Output ("report -> " + $rf)
Write-Output 'PROBE-PRICE-FIELDS-COMPLETE'
