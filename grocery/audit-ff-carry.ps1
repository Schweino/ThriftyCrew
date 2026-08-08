<#
  audit-ff-carry.ps1 - COMPLETENESS guard for the Family Fare Freshop pull. Catches the class where the pull
  silently drops a term (rate-limit -> HTTP 200 with 0 items) so a product FF actually carries shows "No price
  yet" on the board (the 2026-07-13 ground-pork bug). coverage-gaps CANNOT see this - it only scans the raw pull,
  and a dropped item was never pulled.

  How: read the latest family-fare-regular file's `empty_terms` (terms that returned nothing even after the pull's
  recovery passes), and re-probe each ONE more time against the Freshop API (token-less). If the API returns a real
  matching, priced product, FF genuinely carries it and the pull dropped it -> a confirmed victim. Small, targeted
  (only the still-empty terms), so it doesn't hammer the API.

  Advisory (does NOT hard-gate publish - a transient throttle should not take the board down; the pull's recovery
  passes are the primary defense). -Alert emails once per NEW victim-set.
#>
param([switch]$Alert, [switch]$SelfTest, [string]$OutDir = "")
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
# Alerts go out through Send-Alert (alert-lib.ps1), never as `powershell -File send-alert.ps1 -Body $long`:
# Windows refuses to start a process whose command line passes 32767 chars, so an oversized body did not
# arrive truncated - it did not arrive at all, and the launch error read like the CHECK had crashed. Three
# consecutive guard-blind days went unpaged that way on 2026-08-03/04/05. See alert-lib.ps1.
. (Join-Path $root 'alert-lib.ps1')
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
# COVERAGE LEDGER. THE FOUNDING INCIDENT OF THIS WHOLE COMPONENT IS IN THIS FILE: the .ToArray() note ~30
# lines down records that this script threw on its own report line on EVERY run since 2026-07-13 - after all
# 464 Freshop probes had been made and BEFORE it printed one word - so 'ff-carry' appears ZERO times in 2,716
# lines of ad-cycle-log.txt and the Family Fare pull-drop watch was decorative for 17 days. Nothing could
# notice, because a check that produces no output produces nothing to be suspicious of either.
# A ledger row is what makes that noticeable: no row, or a row several days old, is a finding in
# audit-coverage-ledger.ps1 (NEVER-RECORDED / STALE) even though this script said nothing at all.
# It is a function so every exit path can use it, and it returns nothing on purpose - Write-Output inside a
# function pollutes the caller's stdout, and check-ad-cycles parses this script's stdout.
function Emit-Coverage([int]$elig, [int]$exam, [string]$why) {
  try {
    $covLib = Join-Path $root 'coverage-lib.ps1'
    if (Test-Path $covLib) {
      . $covLib
      if ($exam -le 0) { Write-CoverageRecord -Check 'audit-ff-carry' -OutDir $OutDir -Eligible $elig -Examined $exam -Detail $why -Blind }
      else { Write-CoverageRecord -Check 'audit-ff-carry' -OutDir $OutDir -Eligible $elig -Examined $exam -Detail $why }
    }
  } catch { }
}
$probed = 0
$ff = $null; $doc = $null; $emptyTerms = @()
# THE SELF-TEST MUST NOT DEPEND ON PULL STATE. Both early exits below sit ABOVE the fixture block, so a
# -SelfTest run on any day with no FF file - or with no empty terms, which is the HEALTHY state - printed
# SKIP/OK and exited 0 without executing a single fixture. A self-test that reports success without running
# is worse than none: test-auditors would read it green forever. Skipping the pull-state gates under
# -SelfTest is what makes the fixtures reachable in every data state. ($ffDeals on line ~71 is already
# $doc-null-safe, and the fixture block exits before the probe loop ever reads $emptyTerms.)
if (-not $SelfTest) {
  $ff = Get-ChildItem (Join-Path $OutDir 'regular\family-fare-regular-*.json') -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $ff) { $null = Emit-Coverage 0 0 'no family-fare-regular file to read empty_terms from - the FF pull-drop watch had nothing to work with'; Write-Output 'ff-carry: SKIP (no FF regular file)'; exit 0 }
  $doc = ConvertFrom-Json ([IO.File]::ReadAllText($ff.FullName))
  $emptyTerms = @($doc.empty_terms)
  if ($emptyTerms.Count -eq 0) { $null = Emit-Coverage 0 0 ('the FF pull left no empty terms in ' + $ff.Name + ' - nothing needed re-probing'); Write-Output 'ff-carry: OK  the FF pull left no empty terms'; exit 0 }
}

$tmp = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $root 'commodities.json'))); $commods = @($tmp)
$terms = (ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $root 'commodity-search.json')))).terms
# term-string -> commodity (to apply the right include/exclude)
# EVERY term maps back to its commodity, not just the first. [string]$p.Value JOINED a multi-term
# commodity into one key ("popsicles ice pops") that no real search will ever produce, so that commodity's
# probes could never be attributed and it would read as permanently uncovered.
. (Join-Path $root 'search-terms-lib.ps1')
$termToId = @{}; foreach ($tp in (Get-SearchTermPairs $terms)) { $termToId[$tp.term] = $tp.id }
$byId = @{}; foreach ($c in $commods) { $byId[[string]$c.id] = $c }
function Match-Local($c, $name) {
  if (-not $c) { return $false }
  $n = $name.ToLower(); $hit = $false
  foreach ($inc in $c.include) { try { if ($n -match $inc) { $hit = $true; break } } catch {} }
  if (-not $hit) { return $false }
  foreach ($e in $c.exclude) { try { if ($n -match $e) { return $false } } catch {} }
  return $true
}
$ak = 'family_fare'; $sid = '6401'; $b = 'https://api.freshop.ncrcloud.com/1'; $UA = @{ 'User-Agent' = 'Mozilla/5.0' }
# WHAT empty_terms MEANS CHANGED UNDER THIS CHECK ON 2026-07-30, AND IT INVERTED THE ANSWER.
# The pull now walks the 526-term list from a ROTATING CURSOR and buys only the ~60-70 terms Freshop's
# per-window budget allows (see the term-budget cursor comment in pull-regular-familyfare.ps1). So
# empty_terms is no longer 'terms Freshop refused' - it is overwhelmingly 'terms this run never asked for'.
# Re-probing one of those and finding a real product therefore proves NOTHING about a drop. Measured
# 2026-07-31: of the 24 terms this check reported as pull-drop victims, 15 had their commodity ALREADY
# PRICED in the very file whose empty_terms list flagged them - arriving under a different search term or
# as a carry-forward row. Examples: 'chili beans' was empty while the same file priced 12 chili-bean rows
# including Our Family 15.5 oz at $0.99; 'shallots', 'pork tenderloin whole boneless' and
# '93 lean ground beef' each named the product ALREADY ON THE BOARD as their own victim.
# A victim must be a term whose COMMODITY has no priced row in this pull at all. That one condition took
# the 24 candidates down to the 9 that are genuinely uncovered, and lost none of them.
$ffDeals = @(); if ($doc) { $ffDeals = @($doc.deals) }
$script:covCache = @{}
function Has-FeedCoverage($c, $deals) {
  if (-not $c) { return $false }
  $k = [string]$c.id
  if ($script:covCache.ContainsKey($k)) { return $script:covCache[$k] }
  $found = $false
  foreach ($d in $deals) {
    if ($found) { break }
    if (-not $d.item) { continue }
    if (-not (Match-Local $c ([string]$d.item))) { continue }
    $pr = 0.0
    [void][double]::TryParse([string]$d.current_price, [ref]$pr)
    if ($pr -le 0) { [void][double]::TryParse([string]$d.regular, [ref]$pr) }
    if ($pr -gt 0) { $found = $true }
  }
  $script:covCache[$k] = $found
  return $found
}
# PICK THE CHEAPEST MATCH, NOT THE FIRST ONE FRESHOP SORTED TO THE TOP - see the note at the victim line.
# The multi-buy guard here is the same one pull-regular-familyfare needs: Freshop returns '4 for $5.00' as
# the price text, and stripping non-digits from that yields 45.
function Pick-Cheapest($items) {
  $best = $null; $bestP = [double]::MaxValue
  foreach ($it in $items) {
    $txt = [string]$it.price
    $p = 0.0
    if ($txt -and -not $txt.Contains(' for ')) { [void][double]::TryParse(($txt -replace '[^0-9.]', ''), [ref]$p) }
    if ($p -le 0) { [void][double]::TryParse((([string]$it.base_price) -replace '[^0-9.]', ''), [ref]$p) }
    if ($p -gt 0 -and $p -lt $bestP) { $bestP = $p; $best = $it }
  }
  return $best
}
if ($SelfTest) {
  # FROZEN FIXTURES - never regenerate these from the live pull. Each pair is one MUST-FIRE (the real bug)
  # and one CLEAN-TWIN (the case that must stay silent), taken from the 2026-07-31 adjudication.
  $fails = New-Object System.Collections.Generic.List[string]
  $fx = @(
    [pscustomobject]@{ item = 'Our Family Chili Beans, In Mild Chili Sauce 15.5 Oz'; current_price = 0.99; regular = 0.99 },
    [pscustomobject]@{ item = 'Yellow Nectarines'; current_price = 4.29; regular = 4.29 }
  )
  if (-not $byId['chili-beans']) { $fails.Add('MUST-FIRE fixture cannot run: commodity chili-beans is gone from commodities.json') }
  elseif (-not (Has-FeedCoverage $byId['chili-beans'] $fx)) { $fails.Add('MUST-FIRE: chili-beans is priced in the fixture feed but Has-FeedCoverage says it is not - the 2026-07-31 15-of-24 false-positive class is back') }
  $script:covCache = @{}
  if (-not $byId['soy-sauce']) { $fails.Add('CLEAN-TWIN fixture cannot run: commodity soy-sauce is gone from commodities.json') }
  elseif (Has-FeedCoverage $byId['soy-sauce'] $fx) { $fails.Add('CLEAN-TWIN: soy-sauce has no row in the fixture feed but Has-FeedCoverage claims coverage - real pull-drops would be suppressed') }
  $script:covCache = @{}
  $sk = @(
    [pscustomobject]@{ name = 'Claussen Sauerkraut, Premium Crisp 32 Fl Oz'; price = '$6.49'; base_price = 6.49 },
    [pscustomobject]@{ name = 'Our Family Old Fashioned Shredded Sauerkraut 14.4 Oz'; price = '$1.69'; base_price = 1.69 }
  )
  $pk = Pick-Cheapest $sk
  if (-not $pk -or ([string]$pk.name) -ne 'Our Family Old Fashioned Shredded Sauerkraut 14.4 Oz') { $fails.Add('MUST-FIRE: Pick-Cheapest named the first result, not the cheapest - the report is back to headlining a $6.49 jar over a $1.69 one') }
  $mb = @(
    [pscustomobject]@{ name = 'Spice Supreme Spice Ground Cloves'; price = '4 for $5.00'; base_price = 5.0 },
    [pscustomobject]@{ name = 'Claussen Sauerkraut, Premium Crisp 32 Fl Oz'; price = '$6.49'; base_price = 6.49 }
  )
  $pk2 = Pick-Cheapest $mb
  if (-not $pk2 -or ([string]$pk2.name) -ne 'Spice Supreme Spice Ground Cloves') { $fails.Add('CLEAN-TWIN: the multi-buy row was read by stripping digits - "4 for $5.00" became 45 and the $6.49 row looked cheaper') }
  if ($fails.Count) { foreach ($f in $fails) { Write-Output ('  SELF-TEST FAIL  ' + $f) }; Write-Output 'ff-carry SELF-TEST FAILED'; exit 2 }
  Write-Output 'ff-carry: own-feed-coverage and cheapest-pick fixtures both hold - SELF-TEST PASS'
  exit 0
}
$victims = New-Object System.Collections.Generic.List[object]
$suppressed = 0
foreach ($term in $emptyTerms) {
  $c = $byId[$termToId[[string]$term]]
  if ($c -and (Has-FeedCoverage $c $ffDeals)) { $suppressed++; continue }
  $items = @()
    # $probed is incremented INSIDE the try, after the call returns - so it counts probes that got a RESPONSE,
  # not times round the loop. That is the whole distinction the coverage ledger exists for: a run where
  # Freshop refuses every call would otherwise record 464 examined and look identical to a healthy run,
  # when in truth it examined nothing and proved nothing. Counted this way it records 0 of 464, which the
  # ledger reports as BLIND.
  try { $r = Invoke-RestMethod -Uri ("$b/products?app_key=$ak&store_id=$sid&q=" + [uri]::EscapeDataString([string]$term) + "&limit=15&fields=name,price,base_price") -Headers $UA -TimeoutSec 25; $items = @($r.items); $probed++ } catch {}
  Start-Sleep -Milliseconds 400
  $good = @($items | Where-Object { $_.name -and (Match-Local $c ([string]$_.name)) -and ($_.base_price -or $_.price) })
  if ($good.Count) { $victims.Add([pscustomobject]@{ term = [string]$term; commodity = $termToId[[string]$term]; product = [string]$good[0].name }) }
}
# .ToArray(), NOT @($victims). In Windows PowerShell 5.1 the array-subexpression @( ) around a
# System.Collections.Generic.List[object] throws "ArgumentException: Argument types do not match" - it is fine
# around a List[string] and fine around the bare list, which is why this reads as harmless. It is not: this
# line threw on EVERY run since the script was wired into check-ad-cycles on 2026-07-13, after all 464 Freshop
# probes had already been made, and before the report, the OK line and the -Alert branch. check-ad-cycles pipes
# only stdout and a native child's crash is not a PowerShell exception, so its try/catch never fired and the
# failure printed nothing at all: 'ff-carry' appears 0 times in 2,716 lines of ad-cycle-log.txt. The FF
# pull-drop watch (the 2026-07-13 ground-pork class) was decorative for its entire life.
# ToArray() also keeps the JSON shape right at every size - [] at zero, [ {..} ] at one - where a bare list
# double-wraps and ConvertTo-Json would unwrap a single victim into an object.
# COVERAGE FIRST, REPORT SECOND - and that order is the whole point here. The very next line is the one that
# threw on every run for 17 days (@( ) around a List[object]; see its own note below), and NOTHING after it
# ran. Recording coverage BEFORE it means a repeat of that failure still leaves a row saying how many terms
# were actually probed, instead of leaving no trace whatsoever.
# $probed counts probes that got a RESPONSE, not loop iterations: a run where Freshop refuses every call is
# 0 examined of N eligible, which the ledger reports as BLIND - not as a clean bill of health.
$null = Emit-Coverage $emptyTerms.Count $probed ('empty FF search terms re-probed against Freshop from ' + $ff.Name)
$report = [ordered]@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); empty_terms = $emptyTerms.Count; confirmed_victims = $victims.ToArray() }
Set-Content (Join-Path $OutDir 'ff-carry-report.json') -Value ($report | ConvertTo-Json -Depth 4) -Encoding UTF8

# SAY WHAT WAS SUPPRESSED. A filter that removes 15 of 24 findings and reports only the survivors is one
# bad predicate away from reporting nothing at all, and 'OK, 0 victims' reads identically whether the pull
# is healthy or the filter has eaten every real case. The counts make that distinguishable from the log.
$probeStat = ' (' + $probed + ' of ' + $emptyTerms.Count + ' empty term(s) re-probed; ' + $suppressed + ' skipped because this pull already prices that commodity)'
# ZERO PROBES IS NOT A CLEAN BILL OF HEALTH. Every Freshop call is wrapped in an empty catch, so a throttled
# window returns 0 items for all of them, $victims stays empty, and this used to print the same confident
# "OK no term is missing" as a run that actually checked 123 terms. Observed live 2026-07-31 (throttled by
# repeated runs): "ff-carry: OK ... (0 of 466 empty term(s) re-probed)" with exit 0, while the coverage
# ledger next to it correctly said BLIND. The ledger catching it does not excuse this line lying.
# $attempted, NOT $emptyTerms.Count: if every empty term was suppressed because this pull already prices
# that commodity, then probing nothing is the CORRECT answer and must stay a clean exit 0. Only a run that
# had real work to do and completed none of it is blind - a hard zero, so there is no threshold to tune and
# no cry-wolf risk. Exit 3 is the estate's could-not-evaluate code; check-ad-cycles words it separately.
$attempted = $emptyTerms.Count - $suppressed
if ($attempted -gt 0 -and $probed -eq 0) {
  Write-Output ("ff-carry: BLIND  Freshop answered NONE of the " + $attempted + " term(s) this run needed to probe, so nothing was checked - this is not an OK" + $probeStat)
  exit 3
}
if ($victims.Count -eq 0) { Write-Output ("ff-carry: OK  no term is missing from the feed AND carried by FF" + $probeStat); Write-GuardComplete -Name 'ff-carry'; exit 0 }
Write-Output ("ff-carry: FOUND " + $victims.Count + " uncovered term(s) - FF carries these and this pull has no priced row for them" + $probeStat + ":")
foreach ($v in $victims) { Write-Output ("  " + $v.commodity.PadRight(20) + " <- '" + $v.product + "' " + $v.size + " " + $v.price) }
if ($Alert) {
  $sig = (@($victims | ForEach-Object { $_.commodity } | Sort-Object) -join ';')
  $sigHash = [BitConverter]::ToString((New-Object Security.Cryptography.SHA256Managed).ComputeHash([Text.Encoding]::UTF8.GetBytes($sig))).Replace('-', '').Substring(0, 16)
  $sigF = Join-Path $OutDir 'ff-carry-alert.sig'
  $last = if (Test-Path $sigF) { (Get-Content $sigF -Raw).Trim() } else { '' }
  if ($sigHash -ne $last) {
    $body = "The Family Fare pull dropped item(s) FF actually carries (Freshop rate-limit survived the recovery passes). Board shows 'No price yet' for:`n" + (($victims | ForEach-Object { $_.commodity + ' <- ' + $_.product }) -join "`n") + "`nRe-run pull-regular-familyfare.ps1 (recovery should catch them) or investigate persistent throttling."
    try { Send-Alert -Subject "Grocery: Family Fare pull dropped a carried item - review" -Body $body | Out-Null; Set-Content $sigF -Value $sigHash -Encoding UTF8 } catch {}
  }
}
Write-GuardComplete -Name 'ff-carry'; exit 0
