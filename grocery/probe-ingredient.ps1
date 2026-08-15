<#
  probe-ingredient.ps1 - ask the SERVER-SEARCHABLE stores, right now, whether they carry one ingredient.

  WHERE THIS SITS. price-ingredient.ps1 answers from data already on disk in milliseconds and is always the
  first question. This script is the SECOND question, asked only about the ingredients price-ingredient
  returned as ABSENT: a live, targeted, single-term search. It is the server half of the Recipe Hunter's
  pricing stage; the browser half (Aldi, Fareway, Sam's Club, Walmart, Hy-Vee) is driven by the
  recipe-hunter-pricer agent in real Chrome tabs, because those five cannot be searched from a script.

  WHY ONLY TWO STORES.
    Baker's      sanctioned Kroger public API, filter.term search.                      SEARCHABLE
    Family Fare  the store's own Freshop catalog, q= search. NOT Instacart.             SEARCHABLE
    Hy-Vee       pull-regular-hyvee.ps1 is a REFRESH, not a pull - grep it for "search"
                 and there are zero hits. Its work list is two closed sets: yesterday's
                 own file, and its entries in product-urls.json. A product not already
                 in one of those can never enter (89.3% of the store's catalog is
                 absent). A NEW ingredient therefore needs the browser.               BROWSER
    Aldi         Instacart storefront, walled.                                          BROWSER
    Fareway      Instacart storefront, walled.                                          BROWSER
    Sam's Club   CAPTCHA-walled.                                                        BROWSER
    Walmart      walled.                                                                BROWSER

  PRICE MODE. Baker's is the Kroger API's own shelf price. Family Fare is Freshop pickup, which is the
  store's own catalog price - the ~10% delivery markup that audit-price-mode.ps1 guards against is an
  INSTACART property, and neither of these two is an Instacart storefront. That guard is scoped to Aldi and
  Fareway for exactly that reason. The browser half must still set and stamp in-store mode itself.

  IT DOES NOT WRITE TO THE BOARD. Output is evidence for a decision - "does anyone carry this, and roughly
  what does it cost" - not a priced board row. Turning a probe hit into a board cell is the normal capture
  path's job, with its sizing, unit-basis and matching rules. Never shortcut that.

  Usage:
    .\probe-ingredient.ps1 saffron
    .\probe-ingredient.ps1 "lamb shoulder" -Json
    .\probe-ingredient.ps1 saffron -Store bakers
    .\probe-ingredient.ps1 -SelfTest
#>
param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Term = @(),
  [ValidateSet('all', 'bakers', 'family-fare')][string]$Store = 'all',
  [int]$Limit = 25,
  [int]$TimeoutSec = 25,
  [switch]$Json,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
# The Freshop price rule lives in one place and is shared with pull-regular-familyfare.ps1. Its switch is
# deliberately NOT named -SelfTest: a dot-sourced param() block runs in THIS scope and would reset ours.
. (Join-Path $root 'ff-price-lib.ps1')

# ---------------------------------------------------------------------------------------- pure helpers
function Get-ProbeSize($Item) {
  foreach ($k in @('size', 'customerFacingSize', 'netContent')) {
    $v = [string]$Item.$k
    if ($v) { return $v }
  }
  return ''
}

# A probe hit is only useful if the NAME plausibly contains the thing we asked for. Freshop and Kroger both
# return fuzzy matches: searching "saffron" returns Saffron Road frozen meals and saffron yellow rice long
# before it returns a jar of saffron threads. Scoring keeps the caller honest about which is which instead of
# handing back the first row and calling it a price.
function Get-ProbeRelevance([string]$Name, [string]$Term) {
  if (-not $Name -or -not $Term) { return 0 }
  $n = $Name.ToLowerInvariant()
  $t = $Term.ToLowerInvariant()
  $words = @($t -split '\s+' | Where-Object { $_ })
  $hits = @($words | Where-Object { $n.Contains($_) }).Count
  if ($hits -eq 0) { return 0 }
  $score = [int](100 * $hits / [Math]::Max(1, $words.Count))
  # whole phrase present is a much stronger signal than the words scattered through a longer name
  if ($n.Contains($t)) { $score += 40 }
  # LENGTH IS THE DISCRIMINATOR, and it has to be continuous rather than a threshold. A product whose name
  # is mostly the ingredient probably IS the ingredient; a name that goes on to list other foods is probably
  # a DISH containing it. Measured on the real saffron pull: the jar "Spice Islands Spanish Threads Saffron,
  # Kosher" is 44 chars, "Mahatma Authentic Saffron Yellow Rice..." is 79, and the "Saffron Road ... Frozen
  # Meal" is 95. A <=40 char bonus gave all three an identical 140 and ranked a frozen meal level with the
  # jar; a proportional penalty separates them 129 / 121 / 117 in the right order.
  $score -= [Math]::Min(40, [int]($n.Length / 4))
  return $score
}

if ($SelfTest) {
  # Hermetic: no network, no credentials, no capture files.
  $bad = 0
  if ((Get-ProbeSize ([pscustomobject]@{ size = '4 oz' })) -ne '4 oz') { Write-Output '  X size'; $bad++ }
  if ((Get-ProbeSize ([pscustomobject]@{ customerFacingSize = '1 lb' })) -ne '1 lb') { Write-Output '  X kroger size'; $bad++ }
  if ((Get-ProbeSize ([pscustomobject]@{})) -ne '') { Write-Output '  X missing size should be empty'; $bad++ }
  # MUST-FIRE: the real saffron pull returned 3 decoys and 1 real jar. The jar must outrank the decoys.
  $jar = Get-ProbeRelevance 'Spice Islands Spanish Threads Saffron, Kosher' 'saffron'
  $rice = Get-ProbeRelevance 'Mahatma Authentic Saffron Yellow Rice, Seasoned Rice with Spices, Gluten Free, 10 oz Bag' 'saffron'
  $meal = Get-ProbeRelevance 'Saffron Road Chickpea Masala with Cumin Basmati Rice Gluten-Free Vegan Indian Frozen Meal' 'saffron'
  if ($jar -le $rice) { Write-Output "  X MUST-FIRE: the saffron JAR ($jar) did not outrank saffron yellow RICE ($rice)"; $bad++ }
  if ($jar -le $meal) { Write-Output "  X MUST-FIRE: the saffron JAR ($jar) did not outrank a frozen MEAL ($meal)"; $bad++ }
  if ((Get-ProbeRelevance 'Great Value Ketchup' 'saffron') -ne 0) { Write-Output '  X an unrelated name scored above zero'; $bad++ }
  # multi-word: both words present beats one
  $both = Get-ProbeRelevance 'Boneless Lamb Shoulder Roast' 'lamb shoulder'
  $one = Get-ProbeRelevance 'Ground Lamb' 'lamb shoulder'
  if ($both -le $one) { Write-Output '  X a two-word match did not outrank a one-word match'; $bad++ }
  # the shared Freshop rule must be reachable from here
  if (-not (Get-Command Get-FfPrice -ErrorAction SilentlyContinue)) { Write-Output '  X Get-FfPrice not dot-sourced'; $bad++ }
  if ($null -ne (Get-FfPrice ([pscustomobject]@{ price = '4 for $5.00'; base_price = 5.0 }))) { Write-Output '  X the shared multi-buy rule did not apply'; $bad++ }
  if ($bad -eq 0) { Write-Output 'probe-ingredient SELF-TEST PASS (size, relevance ranks the real jar over the decoys, shared Freshop rule reachable)'; exit 0 }
  Write-Output ("probe-ingredient SELF-TEST FAIL ({0} problem(s))" -f $bad); exit 1
}

if (-not $Term -or $Term.Count -eq 0) { Write-Output "probe-ingredient: give one or more ingredient terms. -SelfTest to verify."; exit 1 }

# ------------------------------------------------------------------------------------------- Baker's
$script:KToken = $null; $script:KTokenAt = [datetime]::MinValue
function Get-KrogerCreds {
  $cid = $env:KROGER_CLIENT_ID; $csec = $env:KROGER_CLIENT_SECRET
  if (-not $cid -or -not $csec) {
    $kf = Join-Path $root '.krogerkey'
    if (-not (Test-Path $kf)) { return $null }
    $k = Get-Content $kf -Raw | ConvertFrom-Json
    $cid = [string]$k.client_id; $csec = [string]$k.client_secret
  }
  if (-not $cid -or -not $csec) { return $null }
  return @{ id = $cid; secret = $csec }
}
function Get-KrogerToken($Creds) {
  if ($script:KToken -and (([datetime]::Now - $script:KTokenAt).TotalMinutes -lt 25)) { return $script:KToken }
  $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($Creds.id + ':' + $Creds.secret))
  $r = Invoke-RestMethod -Method Post -Uri 'https://api.kroger.com/v1/connect/oauth2/token' `
        -Headers @{ Authorization = 'Basic ' + $b64; 'Content-Type' = 'application/x-www-form-urlencoded' } `
        -Body 'grant_type=client_credentials&scope=product.compact' -TimeoutSec $TimeoutSec
  $script:KToken = [string]$r.access_token; $script:KTokenAt = [datetime]::Now
  return $script:KToken
}
function Probe-Bakers([string]$t) {
  $creds = Get-KrogerCreds
  if (-not $creds) { return @{ store = "Baker's"; state = 'NO-CREDENTIALS'; note = 'grocery\.krogerkey missing and KROGER_CLIENT_ID/SECRET unset'; hits = @() } }
  try {
    # PS 5.1 mis-decodes the UTF-8 body (Kroger names carry (R)/(TM) glyphs) and names are what every
    # matcher reads, so pull raw bytes and decode explicitly rather than trusting the pipeline's guess.
    $url = 'https://api.kroger.com/v1/products?filter.term={0}&filter.locationId=61500319&filter.limit={1}' -f [uri]::EscapeDataString($t), $Limit
    $h = @{ Authorization = 'Bearer ' + (Get-KrogerToken $creds); Accept = 'application/json' }
    $resp = Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec $TimeoutSec
    $doc = ([Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json)
    $hits = @()
    foreach ($p in @($doc.data)) {
      $it = @($p.items)[0]
      $price = $null
      if ($it -and $it.price) { if ($it.price.promo -gt 0) { $price = [double]$it.price.promo } elseif ($it.price.regular -gt 0) { $price = [double]$it.price.regular } }
      $nm = [string]$p.description
      $hits += [pscustomobject]@{ item = $nm; price = $price; size = (Get-ProbeSize $it)
                                  relevance = (Get-ProbeRelevance $nm $t)
                                  url = ('https://www.bakersplus.com/p/' + [string]$p.productId) }
    }
    return @{ store = "Baker's"; state = 'OK'; note = 'kroger-public-api, locationId 61500319'; hits = @($hits | Sort-Object -Property @{E={$_.relevance};D=$true}, price) }
  } catch { return @{ store = "Baker's"; state = 'ERROR'; note = $_.Exception.Message; hits = @() } }
}

# --------------------------------------------------------------------------------------- Family Fare
function Probe-FamilyFare([string]$t) {
  $ak = 'family_fare'; $sid = '6401'; $b = 'https://api.freshop.ncrcloud.com/1'
  $UA = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
  try {
    $fields = 'id,name,size,price,base_price,unit_price,canonical_url'
    $uri = "$b/products?app_key=$ak&store_id=$sid&q=" + [uri]::EscapeDataString($t) + "&limit=$Limit&fields=$fields"
    $r = $null
    try { $r = Invoke-RestMethod -Uri $uri -Headers $UA -TimeoutSec $TimeoutSec }
    catch {
      # Freshop rejects the canonical_url whitelist intermittently; fall back to the minimal field set
      # rather than returning nothing. Rows then carry no product identity, which is noted, not hidden.
      $uri = "$b/products?app_key=$ak&store_id=$sid&q=" + [uri]::EscapeDataString($t) + "&limit=$Limit&fields=name,size,price,base_price,unit_price"
      $r = Invoke-RestMethod -Uri $uri -Headers $UA -TimeoutSec $TimeoutSec
    }
    $hits = @()
    foreach ($it in @($r.items)) {
      if (-not $it.name) { continue }
      $price = Get-FfPrice $it     # $null = no honest price (multi-buy offer text); keep the row, flag it
      $nm = [string]$it.name
      $hits += [pscustomobject]@{ item = $nm; price = $price; size = (Get-ProbeSize $it)
                                  relevance = (Get-ProbeRelevance $nm $t)
                                  url = [string]$it.canonical_url }
    }
    return @{ store = 'Family Fare'; state = 'OK'; note = 'Freshop catalog (store_id 6401, Omaha), pickup = the store''s own shelf price, NOT Instacart'; hits = @($hits | Sort-Object -Property @{E={$_.relevance};D=$true}, price) }
  } catch { return @{ store = 'Family Fare'; state = 'ERROR'; note = $_.Exception.Message; hits = @() } }
}

# ------------------------------------------------------------------------------------------- drive it
$stores = switch ($Store) { 'bakers' { @('bakers') } 'family-fare' { @('family-fare') } default { @('bakers', 'family-fare') } }
$results = New-Object System.Collections.ArrayList
foreach ($t in $Term) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $per = @()
  foreach ($s in $stores) { $per += $(if ($s -eq 'bakers') { Probe-Bakers $t } else { Probe-FamilyFare $t }) }
  $sw.Stop()
  # THIS SCRIPT DOES NOT RULE ON CARRIAGE, AND THE FIRST VERSION DID (2026-08-15).
  # It declared CARRIED whenever a hit scored >=100. Probing "saffron" at Baker's then returned
  # "Saffron Roadr Drunken Noodles With Chicken" at relevance 130, one point ABOVE the actual jar of saffron
  # threads at 129, because the BRAND NAME contains the term. That verdict would have told the Hunter
  # "Baker's carries saffron" on the strength of a frozen noodle dish, and a recipe would have been accepted
  # against a price for something else entirely. No string heuristic settles "is this product actually the
  # ingredient"; that is a judgment call, and the recipe-hunter-pricer agent exists to make it. Relevance is
  # a SORT HINT for the reader, never a verdict. What this script reports is what it actually knows: whether
  # any candidate rows came back.
  $withRows = @($per | Where-Object { $_.state -eq 'OK' -and @($_.hits).Count -gt 0 })
  [void]$results.Add([pscustomobject]@{
    term = $t
    server_result = $(if ($withRows.Count -gt 0) { 'CANDIDATES-FOUND' } else { 'NO-CANDIDATES' })
    adjudication = 'REQUIRED - a candidate is not a carriage claim; the pricer agent decides which row, if any, is the ingredient'
    responded = @($withRows | ForEach-Object { $_.store })
    stores = @($per | ForEach-Object { [pscustomobject]@{ store = $_.store; state = $_.state; note = $_.note
                                                          hits = @($_.hits | Select-Object -First 8) } })
    ms = $sw.ElapsedMilliseconds })
}

if ($Json) {
  [pscustomobject]@{ probed = @($stores); browser_required = @('Hy-Vee', 'Aldi', 'Fareway', "Sam's Club", 'Walmart'); results = @($results) } | ConvertTo-Json -Depth 7
  exit 0
}

foreach ($r in $results) {
  Write-Output ''
  Write-Output ("{0}  '{1}'  [{2}ms]" -f $r.server_result, $r.term, $r.ms)
  foreach ($s in $r.stores) {
    Write-Output ("   {0,-13} {1}   {2}" -f $s.store, $s.state, $s.note)
    if (-not $s.hits -or @($s.hits).Count -eq 0) { Write-Output '        (no rows returned)'; continue }
    foreach ($h in $s.hits | Select-Object -First 5) {
      $p = $(if ($null -eq $h.price) { 'no-honest-price' } else { '$' + $h.price })
      Write-Output ("        rel {0,-4} {1,-16} {2,-11} {3}" -f $h.relevance, $p, $h.size, ([string]$h.item))
    }
  }
  Write-Output '   NOTE: rows above are CANDIDATES, not prices for this ingredient. Relevance is a sort hint only -'
  Write-Output '         probing "saffron" ranks a Saffron Road frozen noodle dish above the actual jar of saffron.'
  Write-Output '         The pricer agent must decide which row, if any, is really the ingredient.'
  Write-Output '         The five walled stores (Hy-Vee, Aldi, Fareway, Sam''s Club, Walmart) are NOT covered here, so'
  Write-Output '         NO-CANDIDATES is not "nobody carries it" - it is two of seven stores answering.'
}
