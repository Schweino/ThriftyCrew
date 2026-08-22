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

  *** IT ROTATES NOW - IT USED TO PULL THE WHOLE CATALOGUE EVERY DAY (2026-08-22). ***
  BRAD'S RULING: "Bakers should be following the SAME logic as literally everyone else when it comes to ad
  rotation and 'everyday' pricing. IDK why its pulling the entire thing but it needs to stop."

  capture-policy-lib.ps1 decides what each of the seven stores is asked for daily - ad rollover, sale expiry,
  and a 90-day quarterly rotation (total terms / 90 = 7 a day). Every store honoured it except this lane,
  which took no slice at all and walked all 598 terms at 180ms pacing every morning: ~5 minutes of the daily
  run, the single largest remaining cost in the pipeline, to re-read prices that had not moved.

  THE BUDGET LIMITS WHAT WE ASK, NOT WHAT WE WRITE. That sentence is the whole design, and it is written here
  because the Hy-Vee lane learned it the expensive way six hours before this change (commit b649fdcc): a
  budget was added there by REPLACING the work list with the slice, so the output file contained 7 rows
  instead of 1,554, the THROTTLE-WIPEOUT guard correctly quarantined it, the script exited before the cursor
  commit, and the same 7 products were re-taken every day while Hy-Vee's prices sat frozen. So here:

    - the slice is a set of TERMS WE ASK ABOUT today (rotation from the shared cursor, expiring sales first);
    - every OTHER term's rows are carried forward from the previous capture, at their last known price, with
      their own as_of and not_reverified=true - present in the file, never passed off as fresh;
    - the file therefore still carries its full ~7,275 rows on every run.

  WHY CARRY-FORWARD IS SAFE HERE WHEN THE OLD COMMENT SAID IT WAS NOT. The tail of this file used to refuse
  carry-forward, and it was RIGHT about the thing it named: carry-forward-regular.ps1 keys on the ITEM NAME
  and walks every prior file in the window, including the browser-era Baker's captures whose names carry the
  size ("... Chicken Wings (2.5 lb)" @ $3.20/lb) where the API's do not ("... Chicken Wings" @ $8.99/"2.5 lb").
  Two different names for one product means both rows survive and the stale per-lb copy can win the
  cheapest-per-store slot. That objection is satisfied rather than overruled:
    - the carry keys on Kroger's OWN product_id, not on the name, so one product can never become two;
    - it reads ONE file - the previous capture of THIS lane - not every file in the window. Every row in it
      carries product_id and source_ad='kroger-api' (7,287/7,287 on 2026-08-22), so no browser-era row can
      enter through this door;
    - a term we DID ask about today has its previous rows discarded outright: the fresh response for that
      term is the catalogue for that term. Without that rule the file would only ever grow.

  USAGE
    -Verify           compare against the current board and WRITE NOTHING (review before trusting)
    -Full             ask about EVERY term (the old behaviour). See below for how often that is needed.
    -Limit N          only the first N terms of whatever list is in play (smoke test)
    -ResultsPerTerm N how many products per search (default 15)
    -Commodities ids  targeted re-price of specific commodity ids, merged into the newest capture

  HOW OFTEN A FULL PULL IS STILL NEEDED. The rotation covers 598 terms at ceil(598/90) = 7 a day, so a
  complete sweep takes ceil(598/7) = 86 days against capture-policy's 90-day MaxCarryDays - a 4-day margin.
  That margin is the whole answer: if this lane runs every day, no row ever ages out and no full pull is
  required. Every day the daily run does NOT happen spends one of those four days. So: run -Full once a
  quarter as a matter of course, and run it after any stretch where the daily lane missed more than four
  days in a 90-day window (out\capture-cursor-log.jsonl records every advance, so the gaps are countable).
  A row whose as_of is past MaxCarryDays is DROPPED by the carry rather than published stale, so the cost of
  skipping the full pull is coverage, never a wrong price.
  Credentials: grocery\.krogerkey (gitignored) or $env:KROGER_CLIENT_ID / $env:KROGER_CLIENT_SECRET in CI.
#>
param(
  [switch]$Verify,
  [switch]$SelfTest,
  # Ask about EVERY term instead of today's rotation slice. The pre-2026-08-22 behaviour, kept because a
  # comprehensive refresh is still wanted occasionally - see the header for how often.
  [switch]$Full,
  [int]$Limit = 0,
  [int]$ResultsPerTerm = 25,   # 15 missed real staples behind promo churn (vegetable oil, fresh cauliflower)
  [string]$LocationId = '61500319',   # Baker's - Saddlecreek, 888 S Saddle Creek Rd, Omaha 68106
  [int]$PaceMs = 180,
  # Pull ONLY these commodity ids (targeted re-price). Empty = the full term list.
  [string[]]$Commodities = @(),
  [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $root 'omaha-time.ps1')
$out  = if ($OutDir) { $OutDir } else { Join-Path $root 'out' }
if (-not (Test-Path $out)) { New-Item -ItemType Directory -Path $out -Force | Out-Null }
if (-not (Test-Path (Join-Path $out 'regular'))) { New-Item -ItemType Directory -Path (Join-Path $out 'regular') -Force | Out-Null }
$today = Get-OmahaDateKey

function Get-BakersAdWindow([datetime]$Date) {
  # Baker's weekly ad is Wednesday through Tuesday in Omaha. Derive the
  # containing window from the same Central-local date used to stamp the
  # successful store capture; this prevents the customer-facing legacy guide
  # from lagging the promotion coordinator by one full ad cycle.
  $daysSinceWednesday = (([int]$Date.DayOfWeek - [int][DayOfWeek]::Wednesday) + 7) % 7
  $from = $Date.Date.AddDays(-$daysSinceWednesday)
  return [ordered]@{ from=$from.ToString('yyyy-MM-dd'); to=$from.AddDays(6).ToString('yyyy-MM-dd') }
}

function Update-BakersAdSchedule([string]$ScheduleFile, [string]$DetectedOn) {
  if (-not (Test-Path -LiteralPath $ScheduleFile)) { throw "Baker's ad schedule is missing: $ScheduleFile" }
  $schedule = Get-Content -LiteralPath $ScheduleFile -Raw -Encoding UTF8 | ConvertFrom-Json
  $record = @($schedule.stores | Where-Object { [string]$_.store -eq "Baker's" }) | Select-Object -First 1
  if (-not $record) { throw "Baker's ad schedule record is missing" }
  $window = Get-BakersAdWindow ([datetime]$DetectedOn)
  $changed = -not $record.current -or [string]$record.current.from -ne $window.from -or [string]$record.current.to -ne $window.to
  $record.method = 'server'
  $record.current = [pscustomobject]$window
  $record.next_pull = ([datetime]$window.to).AddDays(1).ToString('yyyy-MM-dd')
  if ($changed) {
    $history = @($record.history)
    if (-not @($history | Where-Object { [string]$_.from -eq $window.from -and [string]$_.to -eq $window.to }).Count) {
      $record.history = @($history) + ,([pscustomobject][ordered]@{ from=$window.from; to=$window.to; detected=$DetectedOn })
    }
  }
  $schedule.updated = $DetectedOn
  $temporary = "$ScheduleFile.tmp-$([guid]::NewGuid().ToString('N'))"
  try {
    ($schedule | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $ScheduleFile -Force
  } finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
  return $window
}

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

# ============================================================================================
# THE ROTATION HALF. Everything below is PURE - no network, no disk, no credentials - and it all
# lives ABOVE the -SelfTest block on purpose. -SelfTest exits before the term list and the first
# request, so a function defined further down cannot be reached by a fixture at all. That is not a
# style preference: the Hy-Vee budget bug of 2026-08-22 lived in code no self-test could execute,
# and it collapsed that file to 7 rows for two days.
# ============================================================================================

# EVERY PRICE FIELD THIS FILE'S ROWS CARRY, enumerated from the live capture
# (out\regular\bakers-regular-2026-08-22.json, 7,287 rows) rather than from memory:
#   on every row     store item ad_price size regular source_ad as_of current_price product_id
#                    size_raw size_basis stock_level found_by_term net_weight sold_by
#   on most rows     store_category (7,287) link_url (7,287) store_aisle (7,129)
#   on promo rows    base_price marked_down ad_from ad_to (1,306)
# The carry copies the row WHOLE - every property it has, known or not - rather than naming a key
# list that a later field addition would silently fall out of. Hy-Vee's carry names its keys and
# had to be fixed on 2026-08-22 when base_price/marked_down were dropped from carried markdowns and
# price-split typed them EVERYDAY at the sale price. Copying everything cannot have that bug.
function Get-BakersCarryRow($prow, [string]$today) {
  <#
    .SYNOPSIS One row of the previous capture, carried at its last known price and SAID SO.
    .DESCRIPTION
      A carried row must never be laundered into looking freshly verified. So as_of keeps the date the
      store actually told us this price - it is NOT restamped to today - and not_reverified=true rides
      on the row, exactly as the Hy-Vee lane does it. guard 9 counts those flags and prints them.

      AND BRAD'S RULING ON AN ENDED SALE (2026-08-22, already ratified for Hy-Vee): when a sale's dates
      end, the sale price drops away and the everyday price is what remains. Baker's is the ONE lane that
      knows those dates - 1,306 of 7,287 rows carry ad_from/ad_to straight from Kroger's own
      price.expirationDate - so a carried promo row whose window has passed reverts to base_price as an
      everyday row. Without this, the rotation would publish an expired 7-day flyer price for up to 86
      days, which is precisely the failure the ad/everyday split exists to end.
  #>
  $row = [ordered]@{}
  foreach ($p in $prow.PSObject.Properties) { $row[$p.Name] = $p.Value }
  if (-not $row.Contains('as_of')) { $row['as_of'] = '' }
  $row['not_reverified'] = $true
  $to = [string]$prow.ad_to
  $base = $null
  if ($null -ne $prow.base_price) { try { $base = [double]$prow.base_price } catch { $base = $null } }
  if ($to -match '^\d{4}-\d{2}-\d{2}$' -and $today -match '^\d{4}-\d{2}-\d{2}$' -and $to -lt $today -and $null -ne $base -and $base -gt 0) {
    # current_price follows ad_price so guard 10's contract (what we publish == what the store charges)
    # still holds on the reverted row; sale_expired_on keeps the reason visible rather than making the
    # reversion look like a silent re-price.
    $row['ad_price'] = ('$' + $base.ToString('0.00'))
    $row['current_price'] = $base
    foreach ($k in @('base_price', 'marked_down', 'ad_from', 'ad_to')) { if ($row.Contains($k)) { $row.Remove($k) } }
    $row['sale_expired_on'] = $to
  }
  return $row
}

function Test-BakersWipeout([int]$RowCount, [int]$PrevMax) {
  <#
    THE THROTTLE-WIPEOUT RULE, as one expression the run and the fixtures both read - the same shape
    Test-HyVeeWipeout uses, and for the same reason: a guard written twice can be weakened in one place.
    A file under half the recent high-water mark is quarantined, never written over good data.
    It is NOT the thing to relax when a budgeted run looks thin. The fix for that is to stop handing this
    guard a collapsed file, which is what the carry below exists to do.
  #>
  return ($PrevMax -gt 100 -and $RowCount -lt ($PrevMax * 0.5))
}

function Invoke-BakersCarryMerge {
  <#
    .SYNOPSIS Today's fresh rows plus every row we did not ask about, and nothing else.
    .DESCRIPTION
      THE THREE RULES, stated once here so the fixtures test this exact text:

        1. A FRESH ROW ALWAYS WINS, keyed on Kroger's product_id. A product can legitimately answer
           several search terms, so the same product may sit under term B in yesterday's file and come
           back under term A today; keying on the id (never the name) means that is one row, not two.
        2. A TERM WE ASKED ABOUT TODAY IS RE-STATED, NOT ADDED TO. Its previous rows are discarded:
           today's response IS the catalogue for that term. Without this rule a delisted product would
           be carried forever and the file could only grow.
        3. EVERY OTHER TERM'S ROWS ARE CARRIED, at their last known price, marked not_reverified -
           unless their as_of is already past MaxCarryDays, in which case they are DROPPED and counted.
           capture-policy-lib is explicit that rows carried longer than that expire, and dropping one is
           a coverage gap the ledger can see; publishing it is a stale price nothing reports.

      A term that FAILED both request passes is deliberately NOT in AskedTerms, so its rows carry. That
      retires the 2026-07-28 defect this file documents at length - "because this is a comprehensive pull
      that deliberately skips carry-forward, a skipped term is an INSTANT HOLE in the board" (8 dead terms
      silently dropped cucumbers, spinach, yeast and canned mixed vegetables). A hole is now a carry.

    .PARAMETER Fresh       today's rows, in pull order (ordered hashtables or objects)
    .PARAMETER PrevDeals   the previous capture's deals
    .PARAMETER AskedTerms  hashtable of commodity id -> $true for the terms this run actually re-read
    .PARAMETER Today       yyyy-MM-dd
    .PARAMETER MaxCarryDays  rows whose as_of is older than this are dropped (0 = never expire)
    .OUTPUTS @{ Rows; Carried; Expired; Restated; Superseded }
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()]$Fresh,
    [AllowEmptyCollection()]$PrevDeals = @(),
    [hashtable]$AskedTerms = @{},
    [Parameter(Mandatory)][string]$Today,
    [int]$MaxCarryDays = 0
  )
  $rows = New-Object System.Collections.Generic.List[object]
  $freshIds = @{}
  foreach ($r in @($Fresh)) {
    [void]$rows.Add($r)
    # Read through IDictionary when it IS one: in PS 5.1 `$psCustomObject['key']` and
    # `$orderedHashtable.key` are not interchangeable, and a silent $null here would make every
    # fresh row look id-less and let the carry duplicate all of them.
    # NOT $pid - that is a read-only automatic variable (the process id) and assigning to it throws
    # "Cannot overwrite variable PID" from inside the function, killing the whole run.
    $rid = if ($r -is [System.Collections.IDictionary]) { [string]$r['product_id'] } else { [string]$r.product_id }
    if ($rid) { $freshIds[$rid] = $true }
  }
  $carried = 0; $expired = 0; $restated = 0; $superseded = 0
  $todayD = $null
  if ($MaxCarryDays -gt 0) { try { $todayD = [datetime]::ParseExact($Today, 'yyyy-MM-dd', $null) } catch { $todayD = $null } }
  foreach ($d in @($PrevDeals)) {
    $rid = [string]$d.product_id
    if ($rid -and $freshIds.ContainsKey($rid)) { $superseded++; continue }        # rule 1
    if ($AskedTerms.ContainsKey([string]$d.found_by_term)) { $restated++; continue } # rule 2
    if ($null -ne $todayD) {                                                       # rule 3
      $ao = [string]$d.as_of
      if ($ao -match '^\d{4}-\d{2}-\d{2}$') {
        $aoD = $null
        try { $aoD = [datetime]::ParseExact($ao, 'yyyy-MM-dd', $null) } catch { $aoD = $null }
        if ($aoD -and (($todayD - $aoD).TotalDays -gt $MaxCarryDays)) { $expired++; continue }
      }
    }
    [void]$rows.Add([pscustomobject](Get-BakersCarryRow $d $Today))
    $carried++
  }
  # .ToArray(), NOT the List itself. In Windows PowerShell 5.1 `@( )` around a
  # System.Collections.Generic.List[object] throws "ArgumentException: Argument types do not match", and
  # every caller here wraps the result in @( ). audit-ff-carry.ps1 carries a long note about this exact
  # trap - it silently broke that script on every run for 17 days.
  return [pscustomobject]@{ Rows = $rows.ToArray(); Carried = $carried; Expired = $expired
                            Restated = $restated; Superseded = $superseded }
}

# ---------------------------------------------------------------- self-test (no credentials, no network)
# Fixtures are REAL rows read off the Saddlecreek store on 2026-07-24 - every case is a known answer, and
# several are the exact products that produced the 4x Kerrygold underprice this resolver exists to prevent.
if ($SelfTest) {
  $wed = Get-BakersAdWindow ([datetime]'2026-08-12')
  $tue = Get-BakersAdWindow ([datetime]'2026-08-18')
  if ($wed.from -ne '2026-08-12' -or $wed.to -ne '2026-08-18' -or $tue.from -ne '2026-08-12' -or $tue.to -ne '2026-08-18') {
    throw "Baker's Wednesday-Tuesday ad-window self-test failed"
  }
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

  # ==================================================================================================
  # THE ROTATION (2026-08-22). Baker's used to ask for all 598 terms every day; Brad's ruling ended it.
  # Every case below is about ONE sentence, the one the Hy-Vee lane had to learn twice:
  # A BUDGET LIMITS WHAT WE ASK, NEVER WHAT WE WRITE.
  # These FAIL on the code that shipped before this change - there was no slice, no carry and no cursor,
  # so a rotation-sized run produced a rotation-sized FILE.
  # Synthetic 240-term population, frozen rows, no network, no live policy files, no writes outside TEMP.
  # ==================================================================================================
  . (Join-Path $root 'capture-policy-lib.ps1')
  function B([string]$label, [bool]$cond) { if ($cond) { Write-Output ("ok    " + $label) } else { Write-Output ("FAIL  " + $label); $script:fail++ } }

  $NT_TERMS = 240
  $bkPrev = New-Object System.Collections.Generic.List[object]
  $bkTerms = New-Object System.Collections.Generic.List[object]
  for ($i = 0; $i -lt $NT_TERMS; $i++) {
    $cid = ('fix-{0:d3}' -f $i)
    [void]$bkTerms.Add([pscustomobject]@{ id = $cid; term = ('term ' + $cid) })
    # two products per term, one of them a live promo carrying Kroger's own window
    [void]$bkPrev.Add([pscustomobject][ordered]@{
      store="Baker's"; item=("Fixture Product $i A"); ad_price='$2.50'; size='16 oz'; regular=$null
      source_ad='kroger-api'; as_of='2026-08-21'; current_price=2.5; product_id=("P$i-A")
      size_raw='16 oz'; size_basis='label'; stock_level='HIGH'; found_by_term=$cid
      net_weight='1.0 [lb_av]'; sold_by='UNIT'; store_category='Grocery'; store_aisle='GROCERY'
      link_url='https://www.bakersplus.com/p/x/1' })
    [void]$bkPrev.Add([pscustomobject][ordered]@{
      store="Baker's"; item=("Fixture Product $i B"); ad_price='$3.99'; size='12 oz'; regular=$null
      source_ad='kroger-api'; as_of='2026-08-21'; current_price=3.99; product_id=("P$i-B")
      size_raw='12 oz'; size_basis='label'; stock_level='HIGH'; found_by_term=$cid
      net_weight='0.75 [lb_av]'; sold_by='UNIT'; store_category='Grocery'; store_aisle='GROCERY'
      link_url='https://www.bakersplus.com/p/x/2'
      base_price=5.49; marked_down=$true; ad_from='2026-08-19'; ad_to='2026-08-26' })
  }
  $POP = $bkPrev.Count            # 480 rows
  # the rotation budget for this population, from the policy's own quarter: ceil(240/90) = 3 terms a day
  $bkBudget = [int][math]::Ceiling($NT_TERMS / [double](Get-PolicyQuarterDays))
  B "the daily slice is ceil($NT_TERMS terms / $(Get-PolicyQuarterDays)d) = $bkBudget term(s), not the whole list" ($bkBudget -eq 3)

  # --- (a) a rotation-sized slice still writes a row for EVERY product the previous file had ---------
  $sliceA = Select-ExpiryFirstSlice -Items $bkTerms.ToArray() -Expiring @() -Budget $bkBudget -CursorStart 0 -KeyOf { param($t) @([string]$t.id) }
  $askA = @{}; foreach ($t in @($sliceA.Items)) { $askA[[string]$t.id] = $true }
  # the store answers: one fresh row per asked term (the second product of that term is gone today -
  # a re-read term is RESTATED, so that row must not survive)
  $freshA = New-Object System.Collections.Generic.List[object]
  foreach ($t in @($sliceA.Items)) {
    $n = [int](([string]$t.id) -replace '\D','')
    [void]$freshA.Add([pscustomobject][ordered]@{
      store="Baker's"; item=("Fixture Product $n A"); ad_price='$2.29'; size='16 oz'; regular=$null
      source_ad='kroger-api'; as_of='2026-08-22'; current_price=2.29; product_id=("P$n-A")
      size_raw='16 oz'; size_basis='label'; stock_level='HIGH'; found_by_term=([string]$t.id)
      net_weight='1.0 [lb_av]'; sold_by='UNIT' })
  }
  $mA = Invoke-BakersCarryMerge -Fresh $freshA.ToArray() -PrevDeals $bkPrev.ToArray() -AskedTerms $askA -Today '2026-08-22' -MaxCarryDays 90
  $rowsA = @($mA.Rows)
  $termsOut = @{}; foreach ($r in $rowsA) { $termsOut[[string]$r.found_by_term] = $true }
  B "MUST-FIRE (a): a $bkBudget-term slice against $NT_TERMS terms still writes a row for EVERY commodity (got $($termsOut.Count))" ($termsOut.Count -eq $NT_TERMS)
  # $POP rows in, $bkBudget of them re-read and re-stated at a new price, $bkBudget of them genuinely
  # delisted from their term's response: $POP - $bkBudget rows out. The pre-change code wrote $bkBudget.
  B "(a) and every product outside the re-read terms is still in the file ($($rowsA.Count) rows of $POP; $($mA.Superseded) re-priced, $($mA.Restated) delisted by a re-read term)" (
      ($rowsA.Count -eq ($POP - $bkBudget)) -and ($mA.Superseded -eq $bkBudget) -and ($mA.Restated -eq $bkBudget))
  B "(a) the budget limited ASKING only: $($freshA.Count) fresh + $($mA.Carried) carried = $($rowsA.Count)" (
      ($freshA.Count -eq $bkBudget) -and ($mA.Carried -eq ($POP - (2 * $bkBudget))) -and ($rowsA.Count -eq ($freshA.Count + $mA.Carried)))
  $frA = @($rowsA | Where-Object { [string]$_.product_id -eq 'P0-A' })[0]
  B '(a) an asked row is genuinely fresh: as_of today, the price the store just gave, no not_reverified flag' (
      ($null -ne $frA) -and ([string]$frA.as_of -eq '2026-08-22') -and ([string]$frA.ad_price -eq '$2.29') -and ($null -eq $frA.not_reverified))
  B '(a) a re-read term is RESTATED, not added to: the product its response no longer carries is gone' (
      @($rowsA | Where-Object { [string]$_.product_id -eq 'P0-B' }).Count -eq 0)

  # --- (b) carried rows keep their price fields and are NOT marked re-verified today -----------------
  $carA = @($rowsA | Where-Object { [string]$_.product_id -eq 'P100-B' })[0]
  # -and short-circuits on purpose: on the pre-change code the row is not in the file at all and this
  # must report FAIL, not throw an exception that swallows every case after it.
  B '(b) MUST-FIRE: a carried promo row keeps ad_price / current_price / base_price / marked_down / ad_from / ad_to / size / product_id / link_url / source_ad' (
      ($null -ne $carA) -and ([string]$carA.ad_price -eq '$3.99') -and ($carA.current_price -eq 3.99) -and
      ($carA.base_price -eq 5.49) -and ([bool]$carA.marked_down) -and ([string]$carA.ad_to -eq '2026-08-26') -and
      ([string]$carA.size -eq '12 oz') -and ([string]$carA.size_basis -eq 'label') -and
      ([string]$carA.link_url -ne '') -and ([string]$carA.store_category -eq 'Grocery'))
  B "(b) provenance survives the carry - guards.ps1 asserts every Baker's row carries source_ad='kroger-api'" (
      @($rowsA | Where-Object { [string]$_.source_ad -ne 'kroger-api' }).Count -eq 0)
  B '(b) a carried row is NOT laundered into looking fresh: as_of stays 2026-08-21 and not_reverified is set' (
      ($null -ne $carA) -and ([string]$carA.as_of -eq '2026-08-21') -and ([bool]$carA.not_reverified))
  B '(b) NO carried row claims to have been verified today' (
      @($rowsA | Where-Object { $_.not_reverified -and ([string]$_.as_of -eq '2026-08-22') }).Count -eq 0)
  # Brad's ruling, already ratified for Hy-Vee: when the sale's dates end the everyday price is what remains.
  $mExp = Invoke-BakersCarryMerge -Fresh @() -PrevDeals @($bkPrev[1]) -AskedTerms @{} -Today '2026-08-27' -MaxCarryDays 90
  $expRow = @($mExp.Rows)[0]
  B '(b) a carried promo whose window has PASSED reverts to everyday at base_price, sale fields dropped, reason recorded' (
      ([string]$expRow.ad_price -eq '$5.49') -and ($expRow.current_price -eq 5.49) -and
      ($null -eq $expRow.marked_down) -and ($null -eq $expRow.ad_to) -and ([string]$expRow.sale_expired_on -eq '2026-08-26'))
  $mOpen = Invoke-BakersCarryMerge -Fresh @() -PrevDeals @($bkPrev[1]) -AskedTerms @{} -Today '2026-08-23' -MaxCarryDays 90
  B '(b) CLEAN TWIN: the same window still open stays the sale at $3.99 with its was-price intact' (
      ([string]@($mOpen.Rows)[0].ad_price -eq '$3.99') -and (@($mOpen.Rows)[0].base_price -eq 5.49))
  $mAged = Invoke-BakersCarryMerge -Fresh @() -PrevDeals @($bkPrev[0]) -AskedTerms @{} -Today '2026-12-01' -MaxCarryDays 90
  B '(b) a row past MaxCarryDays is DROPPED and counted, never published stale' (
      (@($mAged.Rows).Count -eq 0) -and ($mAged.Expired -eq 1))

  # --- (c) the THROTTLE-WIPEOUT guard does not trip on a budgeted run --------------------------------
  B "(c) MUST-FIRE: the guard does NOT trip on a budgeted run ($($rowsA.Count) rows vs a $POP high-water mark)" (
      -not (Test-BakersWipeout -RowCount $rowsA.Count -PrevMax $POP))
  B '(c) MUST-FIRE: the OLD shape - writing only what was asked - DOES trip it, which is what quarantined Hy-Vee for two days' (
      Test-BakersWipeout -RowCount $bkBudget -PrevMax $POP)
  B '(c) the guard itself is untouched: a genuinely collapsed run is still refused' (
      (Test-BakersWipeout -RowCount 100 -PrevMax 480) -and (-not (Test-BakersWipeout -RowCount 241 -PrevMax 480)))

  # --- (d) consecutive runs ask for DIFFERENT terms (the cursor advances) ----------------------------
  $sliceB = Select-ExpiryFirstSlice -Items $bkTerms.ToArray() -Expiring @() -Budget $bkBudget -CursorStart ([int]$sliceA.CursorNext) -KeyOf { param($t) @([string]$t.id) }
  $askB = @{}; foreach ($t in @($sliceB.Items)) { $askB[[string]$t.id] = $true }
  B "(d) MUST-FIRE: tomorrow's slice is DISJOINT from today's (cursor 0 -> $($sliceA.CursorNext) -> $($sliceB.CursorNext))" (
      ([int]$sliceA.CursorNext -eq $bkBudget) -and (@($askA.Keys | Where-Object { $askB.ContainsKey([string]$_) }).Count -eq 0))
  $freshB = New-Object System.Collections.Generic.List[object]
  foreach ($t in @($sliceB.Items)) {
    $n = [int](([string]$t.id) -replace '\D','')
    foreach ($sfx in @('A', 'B')) {
      [void]$freshB.Add([pscustomobject][ordered]@{
        store="Baker's"; item=("Fixture Product $n $sfx"); ad_price='$2.79'; size='16 oz'; regular=$null
        source_ad='kroger-api'; as_of='2026-08-23'; current_price=2.79; product_id=("P$n-$sfx")
        size_raw='16 oz'; size_basis='label'; stock_level='HIGH'; found_by_term=([string]$t.id)
        net_weight='1.0 [lb_av]'; sold_by='UNIT' })
    }
  }
  $mB = Invoke-BakersCarryMerge -Fresh $freshB.ToArray() -PrevDeals $rowsA -AskedTerms $askB -Today '2026-08-23' -MaxCarryDays 90
  B "(d) and the second run also writes every remaining product, not just its own slice ($(@($mB.Rows).Count) rows)" (
      @($mB.Rows).Count -eq $rowsA.Count)
  B "(d) yesterday's fresh row is now a CARRIED row - still in the file, still at its own as_of, flagged" (
      ([string]@($mB.Rows | Where-Object { [string]$_.product_id -eq 'P0-A' })[0].as_of -eq '2026-08-22') -and
      ([bool]@($mB.Rows | Where-Object { [string]$_.product_id -eq 'P0-A' })[0].not_reverified))
  # an expiring sale is re-priced FIRST, ahead of whatever sits at the cursor
  $sliceX = Select-ExpiryFirstSlice -Items $bkTerms.ToArray() -Expiring @('fix-200') -Budget $bkBudget -CursorStart 0 -KeyOf { param($t) @([string]$t.id) }
  B "(d) an expiring sale leads the slice instead of waiting its quarter (Brad: reprice when a sale price drops off)" (
      ([string]@($sliceX.Items)[0].id -eq 'fix-200') -and (@($sliceX.Items).Count -eq $bkBudget))

  # --- (d)/(e) the cursor FILE: one advance a day, never on a replay, never on a run that got nothing -
  $bkTmp = Join-Path ([IO.Path]::GetTempPath()) ('bkcur-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $bkTmp -Force | Out-Null
  try {
    $realToday = (Get-Date).ToString('yyyy-MM-dd')
    $cFile = Join-Path $bkTmp 'capture-cursor.json'
    # (e) THE CASE THAT MATTERS MOST. The file is written with all its carried rows even when every
    # request failed, so Test-CaptureLanded would say LANDED - which is why the lane passes -Landed
    # itself. A run that asked and was answered by nobody must NOT burn its slice.
    $e1 = Step-CaptureCursor -Store "Baker's" -Today $realToday -OutDir $bkTmp -Landed $false
    B '(e) MUST-FIRE: a run that fetched NOTHING does not advance the cursor, and writes no cursor file' (
        (-not $e1.Advanced) -and (-not (Test-Path $cFile)) -and ($e1.Reason -match 'no fresh rows landed'))
    $d1 = Step-CaptureCursor -Store "Baker's" -Today $realToday -OutDir $bkTmp -Landed $true
    $onDisk = -1
    if (Test-Path $cFile) { $onDisk = [int](ConvertFrom-Json ([IO.File]::ReadAllText($cFile))).Bakers }
    B "(d) MUST-FIRE: Baker's now HAS a term cursor - it advances by the rotation and lands on disk (#$onDisk)" (
        ($d1.Advanced) -and ($onDisk -eq [int]$d1.To) -and ($onDisk -gt 0))
    $d2 = Step-CaptureCursor -Store "Baker's" -Today $realToday -OutDir $bkTmp -Landed $true
    B '(d) a second run the same day does not rotate again (one slice per day, however often the lane runs)' (
        (-not $d2.Advanced) -and ([int](ConvertFrom-Json ([IO.File]::ReadAllText($cFile))).Bakers -eq $onDisk))
    $d3 = Step-CaptureCursor -Store "Baker's" -Today '2026-01-01' -OutDir $bkTmp -Landed $true
    B '(d) a REPLAY (or a self-test on a frozen date) never moves the live rotation' (
        (-not $d3.Advanced) -and ([int](ConvertFrom-Json ([IO.File]::ReadAllText($cFile))).Bakers -eq $onDisk))
  } finally { Remove-Item -LiteralPath $bkTmp -Recurse -Force -ErrorAction SilentlyContinue }

  # --- the comprehensive pull is unchanged: every term asked, nothing carried -----------------------
  $askFull = @{}; foreach ($t in $bkTerms) { $askFull[[string]$t.id] = $true }
  $mFull = Invoke-BakersCarryMerge -Fresh $bkPrev.ToArray() -PrevDeals $bkPrev.ToArray() -AskedTerms $askFull -Today '2026-08-22' -MaxCarryDays 90
  B '-Full (every term asked): the catalogue is restated wholesale and NOTHING is carried' (
      (@($mFull.Rows).Count -eq $POP) -and ($mFull.Carried -eq 0))

  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output ("SELF-TEST FAIL: " + $fail + " case(s)"); exit 1 }
}

# ---------------------------------------------------------------- pull
$terms = (Get-Content (Join-Path $root 'commodity-search.json') -Raw | ConvertFrom-Json).terms
# THE POLICY IS LOADED FIRST, NOT LAST. It answers three separate questions below - the promo-length
# bound, today's slice, and the carry window - so it has to be in scope before any of them.
$script:PolicyOk = $false
$script:PromoMaxDays = 90
$script:CarryDays = 90
try {
  . (Join-Path $root 'capture-policy-lib.ps1')
  $script:PromoMaxDays = [int](Get-PolicyQuarterDays)
  $script:CarryDays = [int](Get-PolicyMaxCarryDays)
  $script:PolicyOk = $true
} catch { Write-Warning ("bakers-api: capture-policy did not load (" + $_.Exception.Message + ") - falling back to a COMPREHENSIVE pull this pass") }

# THE TERM LIST COMES FROM Get-AllTerms, NOT FROM THE RAW PROPERTY BAG (2026-08-22).
# The cursor indexes Get-AllTerms' order - sorted by commodity id, one entry PER TERM - so slicing any
# other list would make the cursor's integer mean something different here than it does for the other
# five term-rotation stores. It also fixes a quiet pre-existing defect: commodity-search.json lets a
# commodity carry an ARRAY of terms (popsicles does), and `[string]$property.Value` on an array joins
# them into one nonsense query string. Get-AllTerms flattens them properly - 598 terms, not 597.
$allTerms = if ($script:PolicyOk) { @(Get-AllTerms) } else {
  @($terms.PSObject.Properties | ForEach-Object {
      $n = $_.Name
      foreach ($v in @($_.Value)) { [pscustomobject]@{ id = $n; term = [string]$v } }
    } | Sort-Object id)
}
$termList = @($allTerms)
$fetchList = @($allTerms)     # what we actually ASK about today
$askedTerms = @{}             # commodity id -> $true, for the carry
$rotationMode = 'full'
$bkPlan = $null
$script:BkCursorFrom = $null
$script:BkCursorNext = $null

# TARGETED RE-PRICE. -Commodities takes specific commodity ids and pulls ONLY those.
# The capture policy produces exactly this kind of list - the items whose sale ended
# today, and the ones that lost their cell when an ad closed - and re-pulling all
# 598 terms to refresh two of them is what put Family Fare over its request budget.
# Filtering here means a targeted re-price costs two requests, not six hundred.
if ($Commodities -and $Commodities.Count) {
  $want = @{}; foreach ($c in $Commodities) { $want[[string]$c] = $true }
  $fetchList = @($allTerms | Where-Object { $want.ContainsKey([string]$_.id) })
  $rotationMode = 'targeted'
  Write-Output ("bakers-api: TARGETED re-price of {0} term(s) for: {1}" -f $fetchList.Count, ($Commodities -join ', '))
  if ($fetchList.Count -eq 0) { Write-Warning 'none of the requested commodity ids exist in commodity-search.json'; exit 1 }
}
# ---------------------------------------------------------------- today's slice
# BRAD'S RULING, APPLIED: the same ad-rotation + everyday logic as literally everyone else.
# Get-CapturePlan gives the daily drip (598/90 = 7 terms) plus today's capped slice of sales whose
# window ended, all bounded by this store's own call cap ($StoreCallCap, 250 for Baker's).
# Select-ExpiryFirstSlice puts the expiring commodities at the FRONT and fills the rest from the
# shared rotation cursor, exactly as the Family Fare and Hy-Vee lanes do.
elseif (-not $Full -and $script:PolicyOk) {
  try {
    $bkPlan = Get-CapturePlan -Store "Baker's" -Today $today
    $bkCur = Get-CaptureCursor -Store "Baker's" -OutDir $out
    $bkSlice = Select-ExpiryFirstSlice -Items $allTerms -Expiring @($bkPlan.SaleExpiries) `
                 -Budget ([int]$bkPlan.TermBudget) -CursorStart $bkCur -KeyOf { param($t) @([string]$t.id) }
    $sliceTerms = @($bkSlice.Items)
    # ALL OF A COMMODITY'S TERMS OR NONE OF THEM. popsicles carries two search terms, and the rotation
    # walk is positional, so a slice boundary can fall between them. The carry discards a term's old
    # rows when that term was re-read, so half-asking a commodity would drop the rows its OTHER term
    # found. One extra request is a much cheaper answer than a hole.
    $sliceIds = @{}; foreach ($t in $sliceTerms) { $sliceIds[[string]$t.id] = $true }
    $sliceTerms = @($allTerms | Where-Object { $sliceIds.ContainsKey([string]$_.id) })
    $fetchList = $sliceTerms
    $rotationMode = 'rotation'
    $script:BkCursorFrom = [int]$bkCur
    $script:BkCursorNext = [int]$bkSlice.CursorNext
    Write-Output ("bakers-api: capture-policy slice = {0} term(s) to ASK about today (rotation {1}/{2}, {3}/day; {4} expiring sale term(s) at the front; quarter {5}d; cap {6}) - every other term's rows are CARRIED, not dropped" -f `
      $fetchList.Count, $bkCur, $allTerms.Count, $bkPlan.RotationTerms, $bkSlice.Prepended, $bkPlan.QuarterDays, $bkPlan.CallCap)
    if ($bkSlice.Prepended -gt 0) {
      Write-Output ("bakers-api: expiring sale(s) re-priced FIRST: " + ((@($bkSlice.Items | Select-Object -First $bkSlice.Prepended) | ForEach-Object { $_.id }) -join ', '))
    }
    if ($bkPlan.ExpiryDeferred -gt 0) {
      Write-Output ("bakers-api: {0} expiry(ies) did not fit today's cap - they stay OWED in sale-windows.json and lead tomorrow's slice (oldest {1})" -f $bkPlan.ExpiryDeferred, $bkPlan.ExpiryOldest)
    }
  } catch {
    Write-Warning ("bakers-api: could not compute today's slice (" + $_.Exception.Message + ") - COMPREHENSIVE pull this pass")
    $fetchList = @($allTerms); $rotationMode = 'full'
  }
}
elseif ($Full) { Write-Output 'bakers-api: -Full - asking about EVERY term (the comprehensive refresh; see the header for how often this is needed)' }

if ($Limit -gt 0) { $fetchList = @($fetchList | Select-Object -First $Limit) }
foreach ($t in $fetchList) { $askedTerms[[string]$t.id] = $true }
Write-Output ("bakers-api: {0} of {1} term(s) [{2}], store {3}, {4} results/term" -f $fetchList.Count, $termList.Count, $rotationMode, $LocationId, $ResultsPerTerm)

$deals = New-Object System.Collections.Generic.List[object]
$seen = @{}          # keyed by productId: a product legitimately answers several terms
$stats = [ordered]@{ terms=0; fail=0; products=0; promo=0; dated=0; longpromo=0; nopriced=0; refused=0 }
$refusals = New-Object System.Collections.Generic.List[object]
$termReceipts = @{}
$termOrdinals = @{}
# Keyed on id|term, not on id alone: a commodity may carry SEVERAL search terms (popsicles does), and
# keying on the id would let one of its terms overwrite the other's receipt. The ordinal is the term's
# position in the same list the rotation cursor indexes, so a receipt states exactly where in the
# quarter this term sat.
function Get-TermKey($tp) { return ([string]$tp.id + '|' + [string]$tp.term) }
for ($termOrdinal = 0; $termOrdinal -lt $termList.Count; $termOrdinal++) {
  $termOrdinals[(Get-TermKey $termList[$termOrdinal])] = $termOrdinal
}

# RETRY FAILED TERMS ONCE (2026-07-28). A term was one HTTP call with no retry, and a failure just
# `continue`d - so every product only reachable through that term vanished from the day's capture. Because
# this is a comprehensive pull that deliberately skips carry-forward, a skipped term is an INSTANT HOLE in
# the board. The 2026-07-28 morning pull had 8 failed terms out of 518 and silently dropped cucumbers,
# spinach, yeast and canned mixed vegetables from Baker's; a re-pull four hours later had all four back,
# same store, same rules. It costs ~8 extra requests to stop that, and Baker's had been losing 1-6 cells a
# day to it. The only pre-existing gate was `products < 100`, which 6,800 rows sail through.
# 2026-08-22: a term that still fails both passes is no longer a hole either - it is REMOVED from
# $askedTerms below, so its previous rows are carried forward instead of discarded. The retry stays: a
# carried row is a price we could not check, and one extra request is a much better outcome than that.
$pending = [object[]]@($fetchList)
$pass = 0
while ($pending.Count -gt 0 -and $pass -le 1) {
  if ($pass -eq 1) {
    Write-Output ("bakers-api: retrying {0} failed term(s) once at a slower pace" -f $pending.Count)
    Start-Sleep -Seconds 5
  }
  $failedThisPass = New-Object System.Collections.Generic.List[object]
foreach ($tp in $pending) {
  $id = [string]$tp.id; $term = [string]$tp.term
  if (-not $term) { continue }
  $url = 'https://api.kroger.com/v1/products?filter.term={0}&filter.locationId={1}&filter.limit={2}' -f [uri]::EscapeDataString($term), $LocationId, $ResultsPerTerm
  try { $r = Get-KrogerJson $url } catch {
    $failedThisPass.Add($tp); Write-Warning ("term '$term' failed (pass $pass): " + $_.Exception.Message); Start-Sleep -Milliseconds ($PaceMs * 3); continue
  }
  $stats.terms++
  $responseRows = @($r.data)
  $termReceipts[(Get-TermKey $tp)] = [ordered]@{
    term_key = $id
    term = $term
    ordinal = [int]$termOrdinals[(Get-TermKey $tp)]
    outcome = $(if ($responseRows.Count -gt 0) { 'success' } else { 'empty' })
    row_count = $responseRows.Count
  }
  foreach ($p in $responseRows) {
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
      found_by_term = $id
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
    if ($promo -gt 0 -and $reg -gt $promo) {
      $row['base_price'] = $reg; $row['marked_down'] = $true; $stats.promo++
      # KROGER TELLS US WHEN THE PROMO ENDS, AND WE WERE THROWING IT AWAY (2026-08-21).
      # price carries effectiveDate and expirationDate. Measured on one live search:
      #   Tyson All Natural Boneless Skinless   reg 4.99   promo 2.99    08-19..08-26    7d  <- the flyer deal
      #   Perdue Harvestland                    reg 12     promo 11      08-19..09-02   14d
      #   Tyson Thin Sliced                     reg 12.49  promo 10      08-19..09-16   28d
      #   Simple Truth Organic                  reg 15.99  promo 14.99   08-08..09-09   32d
      # ONE field carries the right window for BOTH kinds - short for a flyer deal, long for a running
      # promo - so Baker's needs neither a TTL nor a second ad slot. Without these dates
      # build-sale-windows stamped the store's 7-day ad cycle on all of them, retiring the 14/28/32-day
      # promos up to three weeks early while the store was still charging them.
      # THE 9999 SENTINEL IS "NEVER EXPIRES", NOT A DATE. Every non-promo item in that same response
      # carried expirationDate 9999-12-31, which makes it the clean live-promo test - and publishing it
      # as a window would claim the sale runs for eight thousand years.
      # A WINDOW LONGER THAN THE QUARTER IS NOT A SALE, IT IS THE PRICE.
      # Measured on the first full pull carrying these dates: 1,402 promos, of which 124 run longer
      # than 90 days, 39 longer than 180, and one - an American Greetings card - to 2099-12-12, a
      # 26,822-day "sale". 9999-12-31 is not the only sentinel Kroger uses, so filtering that literal
      # alone lets the next one through; the honest test is the LENGTH, not the spelling.
      # Brad's own definition settles what to do with them: everyday is "a price people can buy at any
      # time". A 364-day promo IS that. So a window longer than capture-policy's quarter is treated as
      # NO sale at all - the row keeps its price as everyday and gets no ad window - rather than
      # publishing a discount that never expires, which is exactly the failure the whole ad/everyday
      # split exists to end. Bounded by the POLICY's own number, never a fresh literal, so the two
      # cannot drift: at a 90-day rotation we would re-capture such a row before it ended anyway.
      $eff = [string]$it.price.effectiveDate.value
      $exp = [string]$it.price.expirationDate.value
      if ($eff -match '^(\d{4}-\d{2}-\d{2})' -and $exp -match '^(\d{4}-\d{2}-\d{2})') {
        $efd = $null; $exd = $null
        try { $efd = [datetime]::ParseExact(([regex]::Match($eff,'^\d{4}-\d{2}-\d{2}').Value),'yyyy-MM-dd',$null) } catch {}
        try { $exd = [datetime]::ParseExact(([regex]::Match($exp,'^\d{4}-\d{2}-\d{2}').Value),'yyyy-MM-dd',$null) } catch {}
        if ($efd -and $exd -and $exd -gt $efd -and (($exd - $efd).TotalDays -le $script:PromoMaxDays)) {
          $row['ad_from'] = $efd.ToString('yyyy-MM-dd')
          $row['ad_to']   = $exd.ToString('yyyy-MM-dd')
          $stats.dated++
        } else {
          # Not a sale by our definition: undo the markdown flags so nothing downstream treats this
          # long-running promotional price as a temporary one.
          $row.Remove('base_price'); $row.Remove('marked_down'); $stats.promo--; $stats.longpromo++
        }
      }
    }
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
if ($pending.Count -gt 0) {
  Write-Output ("bakers-api: {0} term(s) failed twice: {1}" -f $pending.Count, (@($pending | ForEach-Object { $_.term }) -join ', '))
  # A FAILED TERM IS NOT AN ASKED TERM. This one line is what turns the 2026-07-28 "instant hole"
  # into a carry: with the term out of $askedTerms, Invoke-BakersCarryMerge keeps its previous rows
  # instead of restating the term from a response we never received.
  foreach ($tp in $pending) { $askedTerms.Remove([string]$tp.id) }
  Write-Output '           their previous rows are CARRIED forward, not dropped (this used to be a board hole)'
}
$captureTerms = New-Object System.Collections.Generic.List[object]
foreach ($tp in $termList) {
  $tk = Get-TermKey $tp
  if ($termReceipts.ContainsKey($tk)) { $captureTerms.Add([pscustomobject]$termReceipts[$tk]); continue }
  # NOT-ASKED AND BLOCKED ARE DIFFERENT THINGS, AND MUST NEVER SHARE A NUMBER. "not present" vs "not
  # asked" being the same value is exactly what hid the Hy-Vee freeze for two days. A term outside
  # today's slice says so, and says its rows were carried.
  $asked = $askedTerms.ContainsKey([string]$tp.id) -or @($fetchList | Where-Object { (Get-TermKey $_) -eq $tk }).Count -gt 0
  $captureTerms.Add([pscustomobject][ordered]@{
    term_key = [string]$tp.id
    term = [string]$tp.term
    ordinal = [int]$termOrdinals[$tk]
    outcome = $(if ($asked) { 'blocked' } else { 'not_asked' })
    row_count = 0
    reason = $(if ($asked) { 'Kroger API request failed twice - previous rows carried forward' }
               else { "outside today's capture-policy slice - previous rows carried at their last known price" })
  })
}

Write-Output ("bakers-api: terms ok={0} failed={1} | fresh rows={2} (promo/sale={3}, unpriced={4}, size-REFUSED={5})" -f $stats.terms, $stats.fail, $stats.products, $stats.promo, $stats.nopriced, $stats.refused)
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
# A TARGETED RE-PRICE MERGES; IT DOES NOT OVERWRITE.
# The thin-pull guard below is exactly right for a full run - 38 rows replacing a
# 10,000-row capture is a catastrophe wearing the costume of a successful pull.
# But a -Commodities run is DELIBERATELY thin: it re-prices the handful of items
# whose sale ended or whose ad closed. So here it merges its rows into the newest
# existing capture, replacing only the commodities it actually pulled and leaving
# every other row untouched. Without this, a targeted re-price can only ever be
# refused, which is what happened the first time it was tried.
if ($Commodities -and $Commodities.Count) {
  $regDir = Join-Path $out 'regular'   # $out is the RESOLVED dir (line ~79); $OutDir may be ''
  $prev = Get-ChildItem (Join-Path $regDir 'bakers-regular-*.json') -EA SilentlyContinue |
          Sort-Object Name -Descending | Select-Object -First 1
  if (-not $prev) {
    Write-Warning 'bakers-api: targeted re-price needs an existing capture to merge into; none found. Nothing written.'
    exit 1
  }
  $base = Get-Content $prev.FullName -Raw | ConvertFrom-Json
  $keep = @($base.deals | Where-Object { -not ($Commodities -contains [string]$_.found_by_term_id) -and
                                          -not ($Commodities -contains [string]$_.commodity_id) })
  # Older captures may not carry an id on the row; fall back to the search term.
  if (@($keep).Count -eq @($base.deals).Count) {
    $wantTerms = @{}
    foreach ($c in $Commodities) { if ($terms.PSObject.Properties.Name -contains $c) { $wantTerms[[string]$terms.$c] = $true } }
    $keep = @($base.deals | Where-Object { -not $wantTerms.ContainsKey([string]$_.found_by_term) })
  }
  # .ToArray(), NOT @($deals). $deals is a System.Collections.Generic.List[object],
  # and in Windows PowerShell 5.1 the array-subexpression @( ) around one throws
  # "ArgumentException: Argument types do not match". audit-ff-carry.ps1 carries a
  # long note about this exact trap - it silently broke that script on every run
  # for 17 days. Same list type, same mistake, caught here by hitting it.
  $fresh = $deals.ToArray()
  $before = @($base.deals).Count
  $base.deals = @($keep) + $fresh
  $base | Add-Member -NotePropertyName last_targeted_reprice -NotePropertyValue @{
    at = (Get-Date).ToString('s'); commodities = $Commodities; rows_pulled = @($fresh).Count
    replaced = ($before - @($keep).Count)
  } -Force
  $outFile = Join-Path $regDir ("bakers-regular-" + (Get-Date).ToString('yyyy-MM-dd') + ".json")
  Set-Content -Path $outFile -Value ($base | ConvertTo-Json -Depth 8) -Encoding UTF8
  Write-Output ("bakers-api: TARGETED MERGE - kept {0} row(s), replaced with {1} freshly pulled, wrote {2}" -f @($keep).Count, @($fresh).Count, (Split-Path $outFile -Leaf))
  exit 0
}
# ---------------------------------------------------------------- the rotation commit
# BEFORE THE WRITE, NOT AFTER IT - and this is not a style choice. The Hy-Vee lane put its commit after
# the write, the THROTTLE-WIPEOUT guard exited 2 twelve lines earlier, and the cursor was therefore NEVER
# CREATED: every run re-took the same slice and that store's prices froze for two days with every
# mechanism reporting success. A refused write must not also refuse the rotation.
#
# -Landed IS PASSED EXPLICITLY, and that is the one thing this lane must not leave to the default.
# Step-CaptureCursor would otherwise call Test-CaptureLanded, which reads
# out\regular\bakers-regular-<date>.json and counts rows - and that file now carries ~7,275 rows on EVERY
# run because the un-asked terms are carried forward. It would answer LANDED even on a morning when every
# single request failed, and the slice would burn. So the lane supplies the honest signal: did the store
# actually ANSWER for at least one term we asked about? Same judgement Test-HyVeeCursorAdvance makes.
# Replay refusal, one-slice-per-day and the atomic temp-then-move all still come from Step-CaptureCursor;
# only the landing question is answered here, where it can be answered truthfully.
if ($null -ne $script:BkCursorNext -and $script:PolicyOk) {
  try {
    $bkLanded = ($stats.terms -gt 0)
    $cs = Step-CaptureCursor -Store "Baker's" -Today $today -OutDir $out -Landed $bkLanded
    if ($cs.Advanced) { Write-Output ("bakers-api: rotation cursor advanced #{0} -> #{1} ({2})" -f $cs.From, $cs.To, $cs.Reason) }
    else { Write-Warning ("bakers-api: rotation cursor HELD at #{0} - {1}" -f $script:BkCursorFrom, $cs.Reason) }
  } catch {
    Write-Warning ("bakers-api: the rotation cursor could not be written (" + $_.Exception.Message + ") - the next run re-asks this same slice; nothing is lost.")
  }
}

# ---------------------------------------------------------------- carry forward, then write
# THE BUDGET LIMITS WHAT WE ASK, NOT WHAT WE WRITE. The rules live in Invoke-BakersCarryMerge, above
# -SelfTest, so the fixtures drive this exact text rather than a transcription of it.
#
# THE OLD COMMENT THAT STOOD HERE said carry-forward was "intentionally skipped" because this pull is
# comprehensive and because carry-forward-regular.ps1 keys on the ITEM NAME - the API writes
# "Kroger Raw Frozen Bone In Skin On Chicken Wings" $8.99 / "2.5 lb" where the browser era wrote
# "Kroger ... Chicken Wings (2.5 lb)" $3.20 / "lb", so a name-keyed carry sees two items, keeps both, and
# the stale per-lb copy can win the cheapest-per-store slot. Every word of that was true, and none of it
# is true of THIS carry: it keys on Kroger's own product_id (one product can never become two), reads
# ONLY the previous capture of this lane (every row of which carries source_ad='kroger-api'), and
# discards a term's old rows outright whenever that term was re-read today. The reason was satisfied,
# not overruled. See the file header.
$regDir = Join-Path $out 'regular'
$prevFile = Get-ChildItem (Join-Path $regDir 'bakers-regular-*.json') -EA SilentlyContinue |
            Where-Object { $_.BaseName -match '^bakers-regular-\d{4}-\d{2}-\d{2}$' } |
            Sort-Object Name -Descending | Select-Object -First 1
$prevDeals = @()
$prevName = ''
if ($prevFile) {
  try { $prevDeals = @((Get-Content $prevFile.FullName -Raw | ConvertFrom-Json).deals); $prevName = $prevFile.Name }
  catch { Write-Warning ("bakers-api: the previous capture " + $prevFile.Name + " could not be read (" + $_.Exception.Message + ") - NOTHING can be carried this run"); $prevDeals = @() }
}
# A ROTATION RUN WITH NOTHING TO CARRY IS A COLD START, AND IT MUST SAY SO. Today's ~7 terms are not a
# catalogue; without a previous capture this run can only write what it asked for, which is exactly the
# collapsed file the wipeout guard below exists to refuse. It is left to that guard rather than refused
# here, because on a genuine first-ever run (no Baker's file at all, prevMax 0) writing the slice IS the
# right thing - it seeds the file that tomorrow carries from.
if ($rotationMode -eq 'rotation' -and @($prevDeals).Count -eq 0) {
  Write-Warning "bakers-api: no previous capture to carry from - this run can only write the terms it asked about. Run with -Full to seed a complete capture."
}
# A FULL PULL RESTATES EVERY TERM IT SUCCEEDED ON, so a clean -Full run carries nothing: $askedTerms holds
# all 598 ids and rule 2 discards the previous file wholesale. The exception is the point - a term that
# failed both passes was struck from $askedTerms above, so its rows are CARRIED instead of leaving the
# board hole this file has documented since 2026-07-28. One code path for both modes, and the counters
# printed below say which happened.
$merge = Invoke-BakersCarryMerge -Fresh $deals.ToArray() -PrevDeals $prevDeals -AskedTerms $askedTerms `
           -Today $today -MaxCarryDays $script:CarryDays
$allRows = $merge.Rows
Write-Output ("bakers-api: {0} fresh row(s) + {1} carried (not re-verified) = {2} row(s) | {3} superseded by a fresh row, {4} restated by a re-read term, {5} EXPIRED past the {6}-day carry" -f `
  $deals.Count, $merge.Carried, $allRows.Count, $merge.Superseded, $merge.Restated, $merge.Expired, $script:CarryDays)
if ($prevName) { Write-Output ("bakers-api: carried from " + $prevName) }

# THE THIN-PULL REFUSAL, NOW MEASURED ON THE FILE WE ARE ABOUT TO WRITE. It used to read
# `$stats.products -lt 100` - the count of FRESHLY PULLED rows - which is exactly the conflation that
# quarantined Hy-Vee for two days: on a 7-term rotation day a perfect run legitimately pulls ~90 fresh
# rows and writes 7,275. What must never collapse is the FILE, so that is what is measured. The fresh-row
# floor is kept for a comprehensive pull, where it means what it always meant.
if (($Full -or $rotationMode -eq 'full') -and $stats.products -lt 100) {
  Write-Warning ("bakers-api: a COMPREHENSIVE pull returned only $($stats.products) products - refusing to overwrite the capture with a thin pull (a partial pull is an overwrite). Nothing written.")
  exit 1
}
# A ROW-COUNT GATE CANNOT SEE A TERM-SHAPED HOLE (2026-07-28). 8 dead terms out of 518 still yields ~6,800
# rows, so the check above waves it through while four commodities silently leave the board. Gate on term
# completeness too, AFTER the retry pass: if more than 2% of terms are still dead, this capture has holes
# we cannot see the shape of, and yesterday's complete capture is the better thing to keep serving.
# ONLY ON A COMPREHENSIVE PULL, since 2026-08-22. On a 7-term rotation day ONE flaky term is 14% and this
# would refuse the entire file - for a term whose rows are now carried forward intact. A gate that fires
# on the healthy case is a gate people route around. A failed term in rotation mode is reported, carried,
# and re-asked when the rotation comes back to it.
$termTotal = @($fetchList).Count
if (($Full -or $rotationMode -eq 'full') -and $termTotal -gt 0 -and (($stats.fail / $termTotal) -gt 0.02)) {
  Write-Warning ("bakers-api: {0} of {1} terms ({2:P1}) failed BOTH passes - refusing to overwrite the capture with a term-holed pull. The newest existing capture keeps serving. Nothing written." -f $stats.fail, $termTotal, ($stats.fail / $termTotal))
  exit 1
}
# THROTTLE-WIPEOUT GUARD: never let a broken run clobber good data. Its rule lives in Test-BakersWipeout,
# above -SelfTest, so the run and the fixtures read the same text. This is the guard the carry above exists
# to keep un-tripped: it is NOT the thing to relax when a budgeted run looks thin.
$prevMax = 0
foreach ($pf in (Get-ChildItem (Join-Path $regDir 'bakers-regular-*.json') -EA SilentlyContinue |
    Where-Object { $_.BaseName -match '^bakers-regular-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 4)) {
  try { $c = @((Get-Content $pf.FullName -Raw | ConvertFrom-Json).deals).Count; if ($c -gt $prevMax) { $prevMax = $c } } catch {}
}
if (Test-BakersWipeout -RowCount $allRows.Count -PrevMax $prevMax) {
  $qDir = Join-Path $out 'throttled'
  if (-not (Test-Path $qDir)) { New-Item -ItemType Directory -Path $qDir -Force | Out-Null }
  $pfile = Join-Path $qDir ("bakers-$today.throttled.json")   # NOT out\regular - see guards invariant 7
  ([ordered]@{ store="Baker's"; week_of=$today; price_type='everyday'; throttled=$true; deal_count=$allRows.Count; deals=$allRows } | ConvertTo-Json -Depth 6) | Set-Content $pfile -Encoding UTF8
  Write-Warning ("bakers-api: THROTTLE-WIPEOUT guard tripped - only " + $allRows.Count + " rows vs " + $prevMax + " last time. NOT overwriting.")
  exit 2   # never a bare return: at script scope that reports SUCCESS to capture-run
}
$doc = [ordered]@{
  store = "Baker's"; week_of = $today; price_type = 'everyday'
  price_mode = 'in-store'; mode_verified = $today   # Kroger's API prices ARE the store's shelf prices (locationId-scoped, no delivery markup layer)
  source = 'kroger-public-api'; location_id = $LocationId; store_label = "Baker's - Saddlecreek, Omaha 68106"
  # PARTIAL IS THE HONEST WORD FOR A ROTATION DAY. 'full' now means only what it says: every term asked.
  coverage_mode = $(if (($Full -or $rotationMode -eq 'full') -and $stats.fail -eq 0) { 'full' } else { 'partial' })
  rotation_mode = $rotationMode
  # "not asked" and "not present" must never be the same number again - that conflation is what froze the
  # Hy-Vee file for two days. Recorded in the FILE, not just on the console.
  terms_total = @($termList).Count; terms_asked = @($fetchList).Count
  cursor_from = $script:BkCursorFrom; cursor_next = $script:BkCursorNext
  fresh_rows = $deals.Count; carried_rows = $merge.Carried; not_reverified = $merge.Carried
  carry_expired = $merge.Expired; carry_days = $script:CarryDays
  carried_from = $prevName
  pull_terms = $stats.terms; capture_terms = $captureTerms.ToArray(); deal_count = $allRows.Count
  deals = $allRows
}
$file = Join-Path $out ('regular\bakers-regular-' + $today + '.json')
($doc | ConvertTo-Json -Depth 6) | Set-Content $file -Encoding UTF8
Write-Output ("bakers-api: wrote $($allRows.Count) rows ($($deals.Count) fresh) -> " + (Split-Path $file -Leaf))
$bakersWindow = Update-BakersAdSchedule (Join-Path $root 'ad-schedule.json') $today
Write-Output ("bakers-api: advanced ad schedule to {0}..{1}" -f $bakersWindow.from, $bakersWindow.to)

# THE EXPIRY LEDGER MOVES WITH THE CAPTURE. build-sale-windows keeps an unprocessed window instead of
# pruning it by date, so something has to say which expiries were actually re-priced or the backlog is
# re-queued forever. Written only when the file landed, for the same reason the cursor is.
if ((Test-Path $file) -and $script:PolicyOk -and $rotationMode -eq 'rotation') {
  try {
    $mk = Set-SaleExpiryProcessed -Store "Baker's" -Today $today -OutDir $out -Landed $true
    if ($mk.Marked -gt 0) { Write-Output ("bakers-api: recorded " + $mk.Marked + " sale re-price(s) in sale-windows.json") }
  } catch { Write-Warning ("bakers-api: sale-expiry ledger not updated (" + $_.Exception.Message + ") - those re-prices stay owed and lead tomorrow's slice") }
}

# SIZE-HEAL IS STILL SKIPPED, and now for a stronger reason than "the pull is comprehensive".
# heal-degraded-sizes.ps1 repairs a row whose size came back '' or 'each' when an earlier capture had a
# real count at the same price - the shallow-browser-capture class. This lane cannot produce that row:
# Resolve-KrogerSize either proves a size from the label plus Kroger's netWeight or REFUSES the product
# outright (it is counted into out\kroger-api-eval\refused-<date>.json and never written), so there is no
# degraded size to heal. And the carry above copies the row WHOLE - the resolved `size`, `size_raw` and
# `size_basis` travel with it - so a carried row cannot degrade either; it is the same string the resolver
# proved on the day it was captured. Running the heal would only expose these rows to its name-keyed
# matching for no possible gain.
Write-Output 'bakers-api: size-heal intentionally skipped - the resolver refuses rather than degrades, and the carry preserves the proven size verbatim (see comment).'
