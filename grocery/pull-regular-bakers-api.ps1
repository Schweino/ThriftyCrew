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

  *** THE SIZE-BASIS RESOLVER (2026-07-24, v2 - what unblocked this puller). ***
  Kroger's "N ct / M unit" size string carries BOTH conventions in live data, proven store-side:
      "4 ct / 16 oz"   Kerrygold butter  netWeight 1.0 lb  -> 16 oz is the TOTAL   (per-item 4 oz)
      "12 ct / 1 oz"   string cheese     netWeight 0.75 lb -> 1 oz is PER-ITEM     (total 12 oz)
  Same shape, opposite meanings, no unit-price field to arbitrate - a string-only reading published
  Kerrygold at $2.50/lb (4x under) and the butter band never blinked; guard 4 caught it. So v2 resolves the
  basis from DATA, refusing when it cannot prove it:

    1. soldBy=WEIGHT + size "1 lb" -> per-POUND price, size 'lb'. Its netWeight is the random tray/case
       weight (Tyson breast reads 22.56 lb on a per-lb card) and MUST be ignored. Any other size with
       soldBy=WEIGHT is refused - per-lb pricing with a not-per-lb label is a contradiction we don't guess at.
    2. Single-quantity labels ("8 oz", "3 lb", "1 gal", "12 ct", "15.2 fl oz") are unambiguous: trust them.
    3. Compound "N ct|pk / M oz|fl oz|lb": test BOTH hypotheses (M=total vs M=per-item) against
       itemInformation.netWeight in log space; accept the nearer only if it is inside tolerance AND clearly
       separated from the loser (a dead heat is a refusal - Kroger's own netWeight is sometimes wrong: a
       Dr Pepper 12-pack carries a 24-pack's 19.53 lb, and that row must die, not ship). Weight units get a
       tight tolerance; fl oz gets a wider one because netWeight is mass and density varies.
    4. Resolved compounds emit "N pk X oz|fl oz" (per-item form) - the ONE shape our engine prices correctly
       on every commodity axis: weight/volume commodities multiply to the total, each/dozen commodities read
       N items (that split is pinned in test-pu-lib). Emitting the bare total would orphan eggs (dozen needs
       the count); emitting the bare count would orphan butter (lb needs the weight).
    5. No netWeight + compound shape, bare numbers that netWeight cannot corroborate, and every other
       unparseable shape -> REFUSED, counted, and listed in out\kroger-api-eval\refused-<date>.json.
       A refused row is a gap the coverage machinery can see; a guessed row is a lie nothing can.
  Links come from productPageURI (the store's own /p/<slug>/<upc>), never guessed from productId.

  USAGE
    -Verify           compare against the current board and WRITE NOTHING (review before trusting)
    -Limit N          only the first N terms (smoke test)
    -ResultsPerTerm N how many products per search (default 15)
  Credentials: grocery\.krogerkey (gitignored) or $env:KROGER_CLIENT_ID / $env:KROGER_CLIENT_SECRET in CI.
#>
param(
  [switch]$Verify,
  [switch]$SelfTest,
  [int]$Limit = 0,
  [int]$ResultsPerTerm = 25,   # 15 missed real staples behind promo churn (vegetable oil, fresh cauliflower)
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
# NOT UNDER -SelfTest (2026-08-08). The self-test below is deliberately credential-free and network-free -
# it only exercises Resolve-KrogerSize / Clean-Name against frozen rows - but this throw sat ABOVE it, so
# -SelfTest died here on any machine without .krogerkey. That made the script unreachable on the change-time
# gate, which carries no secrets by design: gates run #2 failed on it while nothing was actually broken.
if (-not $SelfTest -and (-not $cid -or -not $csec)) {
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
        -Body 'grant_type=client_credentials&scope=product.compact' -TimeoutSec 30
  $script:Token = [string]$r.access_token; $script:TokenAt = [datetime]::Now
  return $script:Token
}

function Get-KrogerJson([string]$url) {
  # PS 5.1's Invoke-RestMethod mis-decodes the UTF-8 body (Kroger's names carry (R)/(TM) glyphs), which would
  # corrupt product names - and names are what the include/exclude matcher reads. Pull raw bytes and decode
  # UTF-8 explicitly instead of trusting the pipeline's guess.
  $h = @{ Authorization = 'Bearer ' + (Get-KrogerToken); Accept = 'application/json' }
  $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 30
  $bytes = $resp.RawContentStream.ToArray()
  return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
}

function Get-NetOz([string]$netWeightRaw) {
  # itemInformation.netWeight arrives as "0.5 [lb_av]" / "12 [oz_av]" / "1.2 [kg]". Returns ounces, or $null.
  if (-not $netWeightRaw) { return $null }
  $m = [regex]::Match($netWeightRaw, '([0-9]+(?:\.[0-9]+)?)\s*\[\s*(lb_av|oz_av|kg|g)\s*\]')
  if (-not $m.Success) { return $null }
  $v = [double]$m.Groups[1].Value
  switch ($m.Groups[2].Value) {
    'lb_av' { return $v * 16 }
    'oz_av' { return $v }
    'kg'    { return $v * 35.274 }
    'g'     { return $v * 0.035274 }
  }
  return $null
}

function Resolve-KrogerSize([string]$sizeRaw, [string]$soldBy, [string]$netWeightRaw, [string]$name = '') {
  # Returns @{ size = <canonical engine-parseable string> ; basis = <how it was proven> }
  # or      @{ size = $null ; basis = 'refused: <reason>' }.  NEVER guesses - see the header.
  $s = ([string]$sizeRaw).Trim()
  $sl = $s.ToLower()
  # normalize Kroger's spelled-out / shorthand unit words to the tokens every rule below expects
  $sl = $sl -replace 'fluid\s+ounces?', 'fl oz'
  $sl = $sl -replace '\bounces?\b', 'oz'
  $sl = $sl -replace '\bfo\b', 'fl oz'          # Kroger prints "30 FO" for fluid ounces
  $sl = $sl -replace '^net\s*wt\.?\s*', ''      # "net wt 15 oz (425g)" -> "15 oz (425g)"
  $sl = ($sl -replace '\([^)]*\)', ' ')         # drop parentheticals: "(425g)", "(8.5 in)"
  $sl = ($sl -replace '\s{2,}', ' ').Trim()

  # (1) by-weight pricing: the price IS per pound; netWeight is the incidental tray/case weight - ignore it.
  if ($soldBy -eq 'WEIGHT') {
    if ($sl -match '^1\s*lbs?\.?$') { return @{ size = 'lb'; basis = 'soldby-weight' } }
    return @{ size = $null; basis = 'refused: soldBy=WEIGHT with non-per-lb label [' + $s + ']' }
  }

  $netOz = Get-NetOz $netWeightRaw

  # (2) compound "N <count-word> / M unit" - the ambiguous shape. Resolve M=total vs M=per-item via
  # netWeight. The count word can be a NOUN ("8 biscuits / 16.3 oz", "4 sticks / 16 oz") - the shape,
  # not the word, is what makes it a count-plus-weight compound.
  $cm = [regex]::Match($sl, '^([0-9]+)\s*(?:ct|count|pk|packs?|biscuits?|sticks?|rolls?|bars?|cans?|bottles?|pouch(?:es)?|cups?|slices?|links?|patties|packets?|pods?|loaves|loaf|buns?|muffins?|bagels?|tortillas?|shells?|pieces?|ea|each)\s*/\s*([0-9]+(?:\.[0-9]+)?)\s*(fl\s*oz|floz|oz|lbs?)(\s*each)?\b')
  if ($cm.Success) {
    $n = [double]$cm.Groups[1].Value
    $mv = [double]$cm.Groups[2].Value
    $mu = ($cm.Groups[3].Value -replace '\s','')
    $isFl = ($mu -match 'fl|floz'); if ($mu -match '^lbs?$') { $mv = $mv * 16; $mu = 'oz' }
    $declaredEach = [bool]$cm.Groups[4].Value
    if ($n -le 0 -or $mv -le 0) { return @{ size = $null; basis = 'refused: degenerate compound [' + $s + ']' } }
    if ($n -eq 1) { $tot = $mv }        # 1-count: both hypotheses coincide
    else {
      if ($null -eq $netOz -or $netOz -le 0) {
        if ($declaredEach) { $tot = $n * $mv }   # "12 ct / 1 oz each" declares per-item explicitly
        else { return @{ size = $null; basis = 'refused: compound [' + $s + '] with no netWeight to arbitrate' } }
      } else {
        # fl oz vs a MASS netWeight: assume ~water density (1 fl oz ~ 1.04 oz) and widen the tolerance.
        $dens = 1.0; $tolWin = 1.30; if ($isFl) { $dens = 1.04; $tolWin = 1.50 }
        $eTot  = [math]::Abs([math]::Log(($mv * $dens) / $netOz))
        $eEach = [math]::Abs([math]::Log(($n * $mv * $dens) / $netOz))
        $win = [math]::Min($eTot, $eEach); $lose = [math]::Max($eTot, $eEach)
        if ($win -gt [math]::Log($tolWin)) { return @{ size = $null; basis = ('refused: compound [' + $s + '] matches neither reading (netWt ' + [math]::Round($netOz,1) + ' oz)') } }
        if (($lose - $win) -lt [math]::Log(1.6)) { return @{ size = $null; basis = ('refused: compound [' + $s + '] readings too close to call (netWt ' + [math]::Round($netOz,1) + ' oz)') } }
        $tot = if ($eTot -lt $eEach) { $mv } else { $n * $mv }
        if ($declaredEach -and $eEach -gt $eTot) { return @{ size = $null; basis = ('refused: [' + $s + '] declares per-item but netWeight says total') } }
      }
    }
    # Emit per-item multipack form: total AND count survive, so lb/oz/floz commodities price the total
    # while each/dozen commodities price the count (the each-vs-weight split pinned in test-pu-lib).
    $per = [math]::Round($tot / $n, 2)
    $u = 'oz'; if ($isFl) { $u = 'fl oz' }
    return @{ size = ([string][int]$n + ' pk ' + $per + ' ' + $u); basis = $(if ($n -eq 1) { 'label' } else { 'netweight' }) }
  }

  # (3) single-quantity weight/volume labels. Normally unambiguous - EXCEPT when the product NAME declares a
  # pack count ("StarKist ... 3pk" with size "5 oz": is 5 oz the total or one can?). Both live conventions
  # exist: Land O Lakes "2 Pack" size "2 lb" is the TOTAL, StarKist "3pk" size "5 oz" is PER-CAN. netWeight
  # arbitrates exactly as it does for compounds; without it a name-counted single label is a refusal.
  # Resolved rows emit the "N pk X oz" pack form so guard 5's name-count reconciliation holds by construction.
  $nameCnt = 0
  if ($name) {
    $ncm = [regex]::Match($name.ToLower(), '\b([0-9]+)\s*(?:-\s*)?(?:pk|pack|count|ct)\b')
    if ($ncm.Success) { $nc = [int]$ncm.Groups[1].Value; if ($nc -ge 2 -and $nc -le 48) { $nameCnt = $nc } }
  }
  $sq = [regex]::Match($sl, '^([0-9]+(?:\.[0-9]+)?)\s*(fl\s*oz|floz|oz|lbs?)\.?$')
  if ($sq.Success -and $nameCnt -gt 1) {
    $v = [double]$sq.Groups[1].Value
    $u = ($sq.Groups[2].Value -replace '\s','') -replace 'floz','floz'
    $isFl = ($u -match 'fl'); $inOz = $v; if ($u -match '^lbs?$') { $inOz = $v * 16 }
    if ($null -eq $netOz -or $netOz -le 0) { return @{ size = $null; basis = ('refused: name declares ' + $nameCnt + '-pack but single label [' + $s + '] has no netWeight to arbitrate') } }
    $dens = 1.0; $tolWin = 1.30; if ($isFl) { $dens = 1.04; $tolWin = 1.50 }
    $eTot  = [math]::Abs([math]::Log(($inOz * $dens) / $netOz))            # label IS the pack total
    $eEach = [math]::Abs([math]::Log(($nameCnt * $inOz * $dens) / $netOz)) # label is one item of the pack
    $win = [math]::Min($eTot, $eEach); $lose = [math]::Max($eTot, $eEach)
    if ($win -gt [math]::Log($tolWin) -or (($lose - $win) -lt [math]::Log(1.6))) {
      return @{ size = $null; basis = ('refused: name ' + $nameCnt + '-pack vs label [' + $s + '] - netWeight ' + [math]::Round($netOz,1) + ' oz proves neither reading') }
    }
    $totOz = if ($eTot -lt $eEach) { $inOz } else { $nameCnt * $inOz }   # everything in oz - a lb label already converted
    $per = [math]::Round($totOz / $nameCnt, 2)
    $uu = 'oz'; if ($isFl) { $uu = 'fl oz' }
    return @{ size = ([string]$nameCnt + ' pk ' + $per + ' ' + $uu); basis = 'netweight-namecount' }
  }
  # truly single (no name-declared count) - trust the label.
  if ($sl -match '^1\s*lbs?\.?$')                        { return @{ size = 'lb'; basis = 'label' } }
  if ($sl -match '^([0-9]+(?:\.[0-9]+)?)\s*lbs?\.?$')    { return @{ size = ($sl -replace 'lbs\b','lb'); basis = 'label' } }
  if ($sl -match '^[0-9]+(?:\.[0-9]+)?\s*(fl\s*oz|floz|oz)\.?$') { return @{ size = ($sl -replace 'floz','fl oz'); basis = 'label' } }
  if ($sl -match '^([0-9]+)\s*(ct|count|ea|each)(\s*\(.*\))?$') {
    $mm = [regex]::Match($sl, '^([0-9]+)')
    return @{ size = ($mm.Groups[1].Value + ' ct'); basis = 'label' }   # "(8.5 in)" plate-diameter suffix dropped
  }
  if ($sl -match '^([0-9]+)\s*(rolls?|sheets?)\b')       { $mm = [regex]::Match($sl, '^([0-9]+)'); return @{ size = ($mm.Groups[1].Value + ' ct'); basis = 'label' } }
  if ($sl -match '^([0-9]+(?:\.[0-9]+)?|[0-9]+/[0-9]+)\s*(gal|gallon)s?\.?$') { return @{ size = ($sl -replace 'gallons?\b','gal'); basis = 'label' } }
  if ($sl -match '^([0-9]+(?:\.[0-9]+)?)\s*(l|liter|litre)s?\.?$') {
    $mm = [regex]::Match($sl, '^([0-9]+(?:\.[0-9]+)?)')
    return @{ size = ([string][math]::Round([double]$mm.Groups[1].Value * 33.814, 1) + ' fl oz'); basis = 'label' }
  }
  if ($sl -match '^([0-9]+(?:\.[0-9]+)?)\s*ml\.?$') {
    $mm = [regex]::Match($sl, '^([0-9]+(?:\.[0-9]+)?)')
    return @{ size = ([string][math]::Round([double]$mm.Groups[1].Value / 29.5735, 1) + ' fl oz'); basis = 'label' }
  }
  if ($sl -match '^(dozen|1\s*doz)$')                    { return @{ size = '12 ct'; basis = 'label' } }
  if ($sl -match '^(each|1\s*ea)$')                      { return @{ size = 'each'; basis = 'label' } }
  # pt/qt pass through UNCONVERTED: berries sold by the "pint" are dry-volume clamshells, and the engine's
  # commodity-declared pint_oz machinery owns that translation - converting to fl oz here would bypass it.
  if ($sl -match '^[0-9]+(?:\.[0-9]+)?\s*(pt|pints?|qt|quarts?)\.?$') { return @{ size = $sl; basis = 'label' } }
  # bare "N pk" is N items, same as "N ct": count-commodities divide by it, weight commodities correctly
  # cannot price it (a pack count carries no weight).
  if ($sl -match '^([0-9]+)\s*(?:pk|packs?)$') { $mm = [regex]::Match($sl, '^([0-9]+)'); return @{ size = ($mm.Groups[1].Value + ' ct'); basis = 'label' } }
  # area-sized rolls (foil "75 sq ft", wax paper): ONE roll = one each. The commodity is priced per box on
  # the board (cheapest roll wins), exactly how the browser rows always recorded these.
  if ($sl -match '^[0-9]+(?:\.[0-9]+)?\s*(sq\s*\.?\s*(ft|feet)|sf)$') { return @{ size = 'each'; basis = 'label' } }

  # (4) bare number ("8" on the Kerrygold foil = 8 oz): only when netWeight corroborates the oz reading.
  if ($sl -match '^([0-9]+(?:\.[0-9]+)?)$') {
    $v = [double]$sl
    if ($null -ne $netOz -and $netOz -gt 0 -and $v -gt 0) {
      $e = [math]::Abs([math]::Log($v / $netOz))
      if ($e -le [math]::Log(1.2)) { return @{ size = ([string]$v + ' oz'); basis = 'netweight' } }
    }
    return @{ size = $null; basis = 'refused: bare number [' + $s + '] netWeight cannot corroborate' }
  }

  return @{ size = $null; basis = 'refused: unrecognized shape [' + $s + ']' }
}

function Clean-Name([string]$s) {
  # Brand glyphs only: (R), (TM), the replacement char, and a curly apostrophe -> straight. Never touch words,
  # sizes or numbers - the matcher and the per-unit engine both read this string.
  # KEEP THIS FILE PURE ASCII: PS 5.1 reads a BOM-less UTF-8 script as ANSI, so a literal non-ASCII glyph in
  # the SOURCE becomes mojibake and the script will not even parse. Reference characters by code point.
  $t = $s.Replace([string][char]0x00AE, '').Replace([string][char]0x2122, '').Replace([string][char]0xFFFD, ' ')
  $t = $t.Replace([string][char]0x2019, "'").Replace([string][char]0x2018, "'")
  # TRANSLITERATE ACCENTED LETTERS FIRST. "Spaces are safe" was false for an accent INSIDE a word: it split the
  # word in half. "Mezzetta Sliced Hot Jalapeno Peppers" (with an n-tilde) became "Jalape o", which no longer
  # contains the token "jalapeno", so both real Baker's pickled-jalapeno SKUs ($0.187 and $0.208/oz) fell off
  # the row and "Ranch Style Beans with Sliced Jalapeno Peppers" won the cell at $0.0833/oz - a can of BEANS
  # named as the product, 2.2x underpriced, on the board and on the live trend page. 19 names were split this
  # way, including "Starbucks Cr me Br l e" (Crème Brûlée). Decompose to FormD and drop the combining marks, so
  # n-tilde -> n and e-acute -> e, THEN blank whatever genuinely has no letter form.
  $t = [string]::Join('', ($t.Normalize([Text.NormalizationForm]::FormD).ToCharArray() | Where-Object {
    [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne [Globalization.UnicodeCategory]::NonSpacingMark
  }))
  # Anything still outside printable ASCII becomes a space. Kroger's titles carry stray glyphs (a caret-like
  # mark on "Fresh Natural^", non-breaking hyphens in "5-7 Bananas", a replacement char mid-word in
  # "Milk?Product"), and the include/exclude matcher reads this string as a lowercase regex subject - a stray
  # byte sitting inside a word silently breaks the match and the store vanishes from that row.
  $t = ($t -replace '[^\x20-\x7E]', ' ')
  return (($t -replace '\s{2,}', ' ').Trim())
}

function Get-KrogerTaxonomy($p) {
  # THE STORE'S OWN CLAIM ABOUT WHAT THIS PRODUCT IS - the one thing the estate has never recorded.
  # Every check we run inherits ONE premise: that the include regex in commodities.json identified the
  # product correctly. 47 of the 99 wrong numbers that reached shoppers in 22 days were that premise being
  # wrong, and nothing downstream could see it because nothing downstream had a second source. Kroger's
  # product payload carries the store's own merchandising taxonomy alongside the price we already take, so
  # recording it costs ZERO extra requests - it is the same response, read one field wider. (Precisely how
  # Freshop's canonical_url sat unread inside a fields= whitelist until 2026-07-16.)
  #
  # IT REFUSES RATHER THAN GUESSES. This runs against a payload shape we have never inspected on disk: the
  # pull writes only the fields it uses, so no raw Kroger response in out\ shows what `categories` or
  # `aisleLocations` actually contain here. So: a value is recorded ONLY when it is a non-empty STRING in
  # the shape we expect. An object, a number, an empty array or a missing property all yield NOTHING - and
  # nothing is the honest output, because audit-store-taxonomy.ps1 reports "0 rows carried a department"
  # out loud instead of calling an unchecked store clean.
  $cats = New-Object System.Collections.Generic.List[string]
  foreach ($cv in @($p.categories)) { if (($cv -is [string]) -and ([string]$cv).Trim()) { $cats.Add(([string]$cv).Trim()) } }
  $aisle = ''
  foreach ($av in @($p.aisleLocations)) {
    if (-not $av) { continue }
    $dv = $av.description
    if (($dv -is [string]) -and ([string]$dv).Trim()) { $aisle = ([string]$dv).Trim(); break }
  }
  return @{ category = (($cats.ToArray()) -join ' > '); aisle = $aisle }
}

# ---------------------------------------------------------------- self-test (no credentials, no network)
# Fixtures are REAL rows read off the Saddlecreek store on 2026-07-24 - every case is a known answer, and
# several are the exact products that produced the 4x Kerrygold underprice this resolver exists to prevent.
if ($SelfTest) {
  $fail = 0
  function T([string]$label, $got, [string]$want) {
    $g = if ($null -eq $got) { '<refused>' } else { [string]$got }
    if ($g -eq $want) { Write-Output ("ok    " + $label + "  -> " + $g) }
    else { Write-Output ("FAIL  " + $label + "  got [" + $g + "] want [" + $want + "]"); $script:fail++ }
  }
  # the two live conventions of the SAME compound shape, both proven by netWeight
  T 'Kerrygold "4 ct / 16 oz" nw 1.0 lb (M=TOTAL)'    (Resolve-KrogerSize '4 ct / 16 oz' 'UNIT' '1.0 [lb_av]').size    '4 pk 4 oz'
  T 'string cheese "12 ct / 1 oz" nw 0.75 lb (M=EACH)' (Resolve-KrogerSize '12 ct / 1 oz' 'UNIT' '0.75 [lb_av]').size  '12 pk 1 oz'
  T 'eggs "12 ct / 24 oz" nw 1.5 lb (M=TOTAL)'         (Resolve-KrogerSize '12 ct / 24 oz' 'UNIT' '1.5 [lb_av]').size  '12 pk 2 oz'
  # fl oz packs: netWeight is MASS; density assumption only has to split hypotheses a factor of N apart
  T 'Horizon "6 ct / 8 fl oz" nw 3.29 lb (M=EACH)'     (Resolve-KrogerSize '6 ct / 8 fl oz' 'UNIT' '3.29 [lb_av]').size '6 pk 8 fl oz'
  T 'Sprite "12 pk / 12 fl oz" nw 9.9 lb (M=EACH)'     (Resolve-KrogerSize '12 pk / 12 fl oz' 'UNIT' '9.9 [lb_av]').size '12 pk 12 fl oz'
  # Kroger's own netWeight can be wrong (a 12-pack wearing a 24-pack's 19.53 lb) - MUST refuse, not guess
  T 'Dr Pepper bad netWeight -> refuse'                (Resolve-KrogerSize '12 pk / 12 fl oz' 'UNIT' '19.53 [lb_av]').size '<refused>'
  T 'compound with NO netWeight -> refuse'             (Resolve-KrogerSize '4 ct / 16 oz' 'UNIT' '').size               '<refused>'
  # explicit "each" suffix declares per-item even without netWeight
  T 'Sargento "12 ct / 1 oz each" no nw'               (Resolve-KrogerSize '12 ct / 1 oz each' 'UNIT' '').size          '12 pk 1 oz'
  # by-weight pricing: per-lb, and the tray/case netWeight (Tyson 22.56 lb!) must be IGNORED
  T 'Heritage breast "1 lb" WEIGHT nw 4.63 lb'         (Resolve-KrogerSize '1 lb' 'WEIGHT' '4.63 [lb_av]').size         'lb'
  T 'Tyson "1 lb" WEIGHT nw 22.56 lb'                  (Resolve-KrogerSize '1 lb' 'WEIGHT' '22.56 [lb_av]').size        'lb'
  T 'WEIGHT with non-1-lb label -> refuse'             (Resolve-KrogerSize '10 lb' 'WEIGHT' '10 [lb_av]').size          '<refused>'
  # unambiguous single-quantity labels pass through
  T 'fixed 1.25 lb tray, soldBy UNIT'                  (Resolve-KrogerSize '1.25 lb' 'UNIT' '1.25 [lb_av]').size        '1.25 lb'
  T '"32 oz" single'                                   (Resolve-KrogerSize '32 oz' 'UNIT' '2.0 [lb_av]').size           '32 oz'
  T '"1 gal" single'                                   (Resolve-KrogerSize '1 gal' 'UNIT' '8.6 [lb_av]').size           '1 gal'
  T '"1/2 gal" fraction'                               (Resolve-KrogerSize '1/2 gal' 'UNIT' '').size                    '1/2 gal'
  T '"15.2 fl oz" single'                              (Resolve-KrogerSize '15.2 fl oz' 'UNIT' '').size                 '15.2 fl oz'
  T 'plates "48 ct (8.5 in)" -> count, suffix dropped' (Resolve-KrogerSize '48 ct (8.5 in)' 'UNIT' '1.3 [lb_av]').size  '48 ct'
  T '"12 rolls" -> 12 ct'                              (Resolve-KrogerSize '12 rolls' 'UNIT' '').size                   '12 ct'
  T '"2 l" -> fl oz'                                   (Resolve-KrogerSize '2 l' 'UNIT' '').size                        '67.6 fl oz'
  # bare number: only a corroborating netWeight licenses the oz reading
  T 'Kerrygold foil "8" nw 0.5 lb'                     (Resolve-KrogerSize '8' 'UNIT' '0.5 [lb_av]').size               '8 oz'
  T 'bare "8" no netWeight -> refuse'                  (Resolve-KrogerSize '8' 'UNIT' '').size                          '<refused>'
  # long-tail shapes from the first live sweep (369 refusals triaged 2026-07-24)
  T 'butter "4 sticks / 16 oz" nw 1 lb (word count)'   (Resolve-KrogerSize '4 sticks / 16 oz' 'UNIT' '1.0 [lb_av]').size '4 pk 4 oz'
  T 'biscuits "8 biscuits / 16.3 oz" nw 1.02 lb'       (Resolve-KrogerSize '8 biscuits / 16.3 oz' 'UNIT' '1.02 [lb_av]').size '8 pk 2.04 oz'
  T '"12 ounces" spelled out'                          (Resolve-KrogerSize '12 ounces' 'UNIT' '').size                  '12 oz'
  T '"64 fluid ounces" spelled out'                    (Resolve-KrogerSize '64 fluid ounces' 'UNIT' '').size            '64 fl oz'
  T '"30 fo" Kroger fluid-oz shorthand'                (Resolve-KrogerSize '30 fo' 'UNIT' '').size                      '30 fl oz'
  T '"net wt 15 oz (425g)" prefix+parenthetical'       (Resolve-KrogerSize 'net wt 15 oz (425g)' 'UNIT' '').size        '15 oz'
  T '"1 pt" passes through (pint_oz machinery owns it)' (Resolve-KrogerSize '1 pt' 'UNIT' '').size                      '1 pt'
  T '"1 qt" passes through'                            (Resolve-KrogerSize '1 qt' 'UNIT' '').size                       '1 qt'
  T 'bare "2 pk" -> 2 ct (count only, no weight)'      (Resolve-KrogerSize '2 pk' 'UNIT' '').size                       '2 ct'
  T 'foil "75 sq ft" -> each (one roll)'               (Resolve-KrogerSize '75 sq ft' 'UNIT' '1.1 [lb_av]').size        'each'
  T 'foil "75 sf" shorthand -> each'                   (Resolve-KrogerSize '75 sf' 'UNIT' '').size                      'each'
  # single label + NAME-declared pack count: netWeight arbitrates total-vs-per-item (guard 5's class)
  T 'StarKist "5 oz" name 3pk nw 0.94 lb (per-CAN)'    (Resolve-KrogerSize '5 oz' 'UNIT' '0.94 [lb_av]' 'StarKist Chunk Light Tuna 3pk Can').size '3 pk 5 oz'
  T 'LandOLakes "2 lb" name 2 Pack nw 2.0 lb (TOTAL)'  (Resolve-KrogerSize '2 lb' 'UNIT' '2.0 [lb_av]' 'Land O Lakes Butter Sticks 2 Pack').size '2 pk 16 oz'
  T 'name-pack single label, no netWeight -> refuse'   (Resolve-KrogerSize '10.5 oz' 'UNIT' '' 'Bobos PB&J 5 Pack Sleeve').size '<refused>'
  T 'Bobos "10.5 oz" 5 Pack nw 10.5 oz (TOTAL)'        (Resolve-KrogerSize '10.5 oz' 'UNIT' '0.66 [lb_av]' 'Bobos PB&J 5 Pack Sleeve').size '5 pk 2.1 oz'
  T 'name-count does NOT fire on count labels'         (Resolve-KrogerSize '12 ct' 'UNIT' '1.0 [lb_av]' 'Eggo Waffles 12 ct').size '12 ct'
  # the emitted multipack form must price correctly on BOTH commodity axes (this is why we emit "N pk X oz")
  . (Join-Path $root 'pu-lib.ps1')
  T 'engine: "4 pk 4 oz" on an oz commodity'   ('{0:N4}' -f (Get-LinkPerUnit '4 pk 4 oz' 'oz' 9.99 'Kerrygold Butter Sticks'))   ('{0:N4}' -f 0.6244)
  T 'engine: "12 pk 2 oz" on a dozen commodity' ('{0:N4}' -f (Get-LinkPerUnit '12 pk 2 oz' 'dozen' 3.99 'Eggs'))                 ('{0:N4}' -f 3.99)
  T 'engine: "12 pk 12 fl oz" on a floz commodity' ('{0:N4}' -f (Get-LinkPerUnit '12 pk 12 fl oz' 'floz' 11.99 'Sprite Cans'))   ('{0:N4}' -f 0.0833)
  # CLEAN-NAME MUST TRANSLITERATE, NOT BLANK. Founding bug (2026-07-29): an accent inside a word was replaced
  # with a space, so "Jalapeno" (n-tilde) became "Jalape o" and stopped matching its own commodity - both real
  # Baker's pickled-jalapeno SKUs fell off the row and a can of Ranch Style Beans won the cell at 2.2x under.
  # Non-ASCII is built from code points because this file must stay pure ASCII (see Clean-Name's header).
  $NT = [char]0x00F1; $EG = [char]0x00E8; $UC = [char]0x00FB; $EA = [char]0x00E9; $RG = [char]0x00AE
  T 'clean-name: n-tilde transliterates, word stays whole' (Clean-Name ("Mezzetta Sliced Hot Jalape${NT}o Peppers")) 'Mezzetta Sliced Hot Jalapeno Peppers'
  T 'clean-name: multiple accents in one name'             (Clean-Name ("Starbucks Cr${EG}me Br${UC}l${EA}e K-Cup")) 'Starbucks Creme Brulee K-Cup'
  T 'clean-name: (R) still stripped, not spaced'           (Clean-Name ("Kroger${RG} 100% Pure Olive Oil")) 'Kroger 100% Pure Olive Oil'
  T 'clean-name: plain ASCII is untouched'                 (Clean-Name 'Kroger 80/20 Ground Beef Roll 1 LB') 'Kroger 80/20 Ground Beef Roll 1 LB'
  # a glyph with no letter form must still become a space, not vanish into a joined word
  T 'clean-name: non-letter glyph becomes a space'          (Clean-Name ("Fresh Natural" + [string][char]0x2038 + "Chicken")) 'Fresh Natural Chicken'

    # STORE-TAXONOMY CAPTURE (the second opinion). These fixtures are the ONLY thing standing between this
  # puller and a fabricated department, because the Kroger payload shape is not on disk anywhere to check
  # against - see Get-KrogerTaxonomy's header.
  # MUST-FIRE: the founding class. Family Fare's own taxonomy files "Blue Buffalo ... Brown Rice Recipe Food
  # For Puppies" under pets_wildlife/dog while our brown-rice include claims it is brown rice; the same
  # product at Baker's must come back carrying Kroger's Pet category so audit-store-taxonomy can see it.
  $fxPet = New-Object psobject -Property @{ categories = @('Pet Care', 'Dog Food'); aisleLocations = @((New-Object psobject -Property @{ description = 'PET FOOD' })) }
  T 'taxonomy MUST-FIRE: Kroger categories join'   (Get-KrogerTaxonomy $fxPet).category 'Pet Care > Dog Food'
  T 'taxonomy MUST-FIRE: aisle description'        (Get-KrogerTaxonomy $fxPet).aisle    'PET FOOD'
  # CLEAN TWIN: an ordinary grocery row records its own department and nothing else changes.
  $fxOk = New-Object psobject -Property @{ categories = @('Dairy'); aisleLocations = @((New-Object psobject -Property @{ description = 'DAIRY' })) }
  T 'taxonomy CLEAN: a food row carries its department' (Get-KrogerTaxonomy $fxOk).category 'Dairy'
  # REFUSALS - the shapes we have never seen and must never invent from. Each must yield an EMPTY string, so
  # the row simply has no department and the audit says so out loud, rather than a type name being published
  # as a "department".
  T 'taxonomy REFUSES a missing property'   (Get-KrogerTaxonomy (New-Object psobject)).category ''
  T 'taxonomy REFUSES an empty array'       (Get-KrogerTaxonomy (New-Object psobject -Property @{ categories = @() })).category ''
  T 'taxonomy REFUSES non-string elements'  (Get-KrogerTaxonomy (New-Object psobject -Property @{ categories = @((New-Object psobject -Property @{ id = 7 })) })).category ''
  T 'taxonomy REFUSES a blank aisle'        (Get-KrogerTaxonomy (New-Object psobject -Property @{ aisleLocations = @((New-Object psobject -Property @{ description = '   ' })) })).aisle ''

  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output ("SELF-TEST FAIL: " + $fail + " case(s)"); exit 1 }
}

# ---------------------------------------------------------------- pull
$terms = (Get-Content (Join-Path $root 'commodity-search.json') -Raw | ConvertFrom-Json).terms
$termList = @($terms.PSObject.Properties)
if ($Limit -gt 0) { $termList = $termList | Select-Object -First $Limit }
Write-Output ("bakers-api: {0} term(s), store {1}, {2} results/term" -f $termList.Count, $LocationId, $ResultsPerTerm)

$deals = New-Object System.Collections.Generic.List[object]
$seen = @{}          # keyed by productId: a product legitimately answers several terms
$stats = [ordered]@{ terms=0; fail=0; products=0; promo=0; nopriced=0; refused=0 }
$refusals = New-Object System.Collections.Generic.List[object]

# RETRY FAILED TERMS ONCE (2026-07-28). A term was one HTTP call with no retry, and a failure just
# `continue`d - so every product only reachable through that term vanished from the day's capture. Because
# this is a comprehensive pull that deliberately skips carry-forward, a skipped term is an INSTANT HOLE in
# the board. The 2026-07-28 morning pull had 8 failed terms out of 518 and silently dropped cucumbers,
# spinach, yeast and canned mixed vegetables from Baker's; a re-pull four hours later had all four back,
# same store, same rules. It costs ~8 extra requests to stop that, and Baker's had been losing 1-6 cells a
# day to it. The only pre-existing gate was `products < 100`, which 6,800 rows sail through.
$pending = [object[]]@($termList)
$pass = 0
while ($pending.Count -gt 0 -and $pass -le 1) {
  if ($pass -eq 1) {
    Write-Output ("bakers-api: retrying {0} failed term(s) once at a slower pace" -f $pending.Count)
    Start-Sleep -Seconds 5
  }
  $failedThisPass = New-Object System.Collections.Generic.List[object]
foreach ($tp in $pending) {
  $id = $tp.Name; $term = [string]$tp.Value
  if (-not $term) { continue }
  $url = 'https://api.kroger.com/v1/products?filter.term={0}&filter.locationId={1}&filter.limit={2}' -f [uri]::EscapeDataString($term), $LocationId, $ResultsPerTerm
  try { $r = Get-KrogerJson $url } catch {
    $failedThisPass.Add($tp); Write-Warning ("term '$term' failed (pass $pass): " + $_.Exception.Message); Start-Sleep -Milliseconds ($PaceMs * 3); continue
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
    $nwRaw = ''; if ($p.itemInformation -and $p.itemInformation.netWeight) { $nwRaw = [string]$p.itemInformation.netWeight }
    $res = Resolve-KrogerSize ([string]$it.size) ([string]$it.soldBy) $nwRaw $name
    if ($null -eq $res.size) {
      $stats.refused++
      $refusals.Add([pscustomobject]@{ item=$name; size_raw=[string]$it.size; soldBy=[string]$it.soldBy; netWeight=$nwRaw; price=$cur; reason=[string]$res.basis; product_id=$prodId })
      continue
    }
    # real product URL from the store's own page URI (strip the API-attribution query); never guessed
    $link = ''
    if ($p.productPageURI) { $link = 'https://www.bakersplus.com' + (([string]$p.productPageURI) -split '\?')[0] }
    $row = [ordered]@{
      store       = "Baker's"
      item        = $name
      ad_price    = ('$' + $cur.ToString('0.00'))
      size        = [string]$res.size
      regular     = $null
      source_ad   = 'kroger-api'
      as_of       = $today
      current_price = $cur          # guard-10 contract: what the store charges, recorded independently
      product_id  = $prodId
      size_raw    = [string]$it.size
      size_basis  = [string]$res.basis
      stock_level = [string]$it.inventory.stockLevel
      # 2026-07-28: keep Kroger's OWN package weight on the row. The resolver above already uses it to settle
      # the "4 ct / 16 oz" total-vs-per-item ambiguity at CAPTURE time, but nothing re-checked it afterwards -
      # and the shipped cell is not the captured row. Carry-forward, an override, a board merge or an engine
      # change can all move the size or the price downstream, and Kroger has no unit-price field to catch it
      # (that is stated in this file's own header). netWeight is the one INDEPENDENT statement of package size
      # this API gives us, so recording it lets audit-basis-reconcile verify what we actually PUBLISH.
      # soldBy rides along because it decides whether netWeight means anything: on a per-pound card it is the
      # random tray weight (Tyson breast reads 22.56 lb) and must be ignored, exactly as rule 1 does above.
      net_weight  = $nwRaw
            sold_by     = [string]$it.soldBy
    }
    # THE SECOND OPINION, CARRIED. Additive only: two optional properties, nothing else on this row changes,
    # and a row Kroger tells us nothing about simply does not get them. See Get-KrogerTaxonomy.
    $ktx = Get-KrogerTaxonomy $p
    if ($ktx.category) { $row['store_category'] = $ktx.category }
    if ($ktx.aisle)    { $row['store_aisle']    = $ktx.aisle }
    if ($link) { $row['link_url'] = $link }
    if ($promo -gt 0 -and $reg -gt $promo) { $row['base_price'] = $reg; $row['marked_down'] = $true; $stats.promo++ }
    $deals.Add([pscustomobject]$row)
    $stats.products++
  }
  Start-Sleep -Milliseconds $PaceMs
}
  $pending = [object[]]$failedThisPass.ToArray()
  $pass++
}
# only terms that failed BOTH passes count as failures
$stats.fail = $pending.Count
if ($pending.Count -gt 0) { Write-Output ("bakers-api: {0} term(s) failed twice and are NOT in this capture: {1}" -f $pending.Count, (@($pending | ForEach-Object { $_.Value }) -join ', ')) }

Write-Output ("bakers-api: terms ok={0} failed={1} | rows={2} (promo/sale={3}, unpriced={4}, size-REFUSED={5})" -f $stats.terms, $stats.fail, $stats.products, $stats.promo, $stats.nopriced, $stats.refused)
if ($refusals.Count -gt 0) {
  $refDir = Join-Path $out 'kroger-api-eval'
  if (-not (Test-Path $refDir)) { New-Item -ItemType Directory -Path $refDir -Force | Out-Null }
  $refFile = Join-Path $refDir ('refused-' + $today + '.json')
  ([ordered]@{ date=$today; count=$refusals.Count; note='rows the size-basis resolver REFUSED to price (see pull-regular-bakers-api.ps1 header) - each is a coverage gap, never a guessed price'; rows=$refusals.ToArray() } | ConvertTo-Json -Depth 4) | Set-Content $refFile -Encoding UTF8
  Write-Output ("bakers-api: {0} refusal(s) listed in {1} - top reasons:" -f $refusals.Count, (Split-Path $refFile -Leaf))
  $refusals | Group-Object { ($_.reason -split '\[')[0] } | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { Write-Output ('    ' + $_.Count + 'x  ' + $_.Name) }
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
# A ROW-COUNT GATE CANNOT SEE A TERM-SHAPED HOLE (2026-07-28). 8 dead terms out of 518 still yields ~6,800
# rows, so the check above waves it through while four commodities silently leave the board. Gate on term
# completeness too, AFTER the retry pass: if more than 2% of terms are still dead, this capture has holes
# we cannot see the shape of, and yesterday's complete capture is the better thing to keep serving. Same
# principle as the row gate - a partial pull is an overwrite - just measured on the axis that was blind.
$termTotal = @($termList).Count
if ($termTotal -gt 0 -and (($stats.fail / $termTotal) -gt 0.02)) {
  Write-Warning ("bakers-api: {0} of {1} terms ({2:P1}) failed BOTH passes - refusing to overwrite the capture with a term-holed pull. The newest existing capture keeps serving. Nothing written." -f $stats.fail, $termTotal, ($stats.fail / $termTotal))
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
