<#
  compare-deals.ps1 - The Omaha cross-store comparison engine.
  Brand-agnostic: every deal is bucketed into a COMMODITY (chicken breast, cottage cheese, ...),
  its price + size normalized to ONE canonical unit (per lb / oz / fl oz / each / dozen), then the
  cheapest store per commodity is named. Brand does not matter; unit price does.

  Input : the latest out\ads-YYYY-MM-DD.json from pull-grocery-ads.ps1 (Hy-Vee/Aldi/Family Fare),
          plus optional out\bakers\bakers-deals-*.json and out\sams\sams-deals-*.json (same shape).
  Output: out\comparison-YYYY-MM-DD.json + a "Cheapest in Omaha this week" report.

  Usage:  powershell -ExecutionPolicy Bypass -File compare-deals.ps1
          powershell -ExecutionPolicy Bypass -File compare-deals.ps1 -MinStores 1   (show single-store too)
#>
param(
  [string]$AdsFile = "",
  [string]$BakersFile = "",
  [string]$SamsFile = "",
# Sam's captures are partial (see the loader below): every capture inside this window is loaded, and the
# freshest one that covers a given commodity wins it. Warehouse "everyday" prices are stable enough for this;
# tighten it if Sam's starts moving prices weekly.
[int]$SamsMaxAgeDays = 90,   # = capture policy MaxCarryDays; see regular-fileset-lib.ps1
  # Walmart's out\regular captures are unioned the same way (see the everyday-price loader): a partial daily
  # refresh must not shrink the board, so every Walmart capture inside this window is loaded and the freshest
  # one covering each commodity wins. Walmart is everyday-priced, so an older capture is only ever a gap-filler.
  [int]$WalmartMaxAgeDays = 90,   # = capture policy MaxCarryDays; see regular-fileset-lib.ps1
  [string]$FarewayFile = "",
  # DEFAULT 1, matching the daily pipeline (check-ad-cycles passes -MinStores 1 explicitly). It was 2 until
  # 2026-07-23, when a MANUAL rerun during the Fareway incident silently dropped every single-store tail
  # commodity (achiote-paste, berbere, onion-soup-mix...) from the board - the pipeline and a human running
  # the same script must produce the same board.
  [int]$MinStores = 1,
  [string]$OutDir = "",
  [string]$CommoditiesFile = "",
  [string]$OutName = "comparison",
  [string]$RegularDir = "",
  [string]$ExtraDir = "",
  # Pin the sanity bands the same way -CommoditiesFile pins the rules. The regression harness needs BOTH
  # frozen or it is not hermetic: it froze the data, then read the LIVE rule + band files, so every ordinary
  # rule edit tripped it and it sat red for weeks until nobody read it. See regression-test.ps1.
  [string]$BandsFile = "",
  # PIN THE REVIEWED-EXCEPTION FILE THE SAME WAY (2026-09-06, PLAN-top5 area 4). The self-test read the
  # SHIPPED instore-channel-allowlist.json and asserted two specific ids were still in it, so a reviewer
  # retiring either exception would have turned the PRICE ENGINE's own self-test red - a verdict resting on
  # two inputs where the harness had frozen only one. That is the same class as the bands note above.
  # Defaults to the live file, so every production caller is unchanged.
  [string]$ChannelAllowlistFile = "",
  [switch]$SelfTest,
  # -Explain <commodity-id>: read-only ownership dump for ONE cell, then exit. See the block near
  # Match-Category. Writes no board, so it is safe to run against a live tree mid-pipeline.
  [string]$Explain = "",
  # ---- THE PRODUCT IDENTITY TABLE (2026-08-22, PLAN-product-identity step 1) --------------------
  # -IdentityNamespace <staple|recipe>: emit graph\identity\<ns>\<store>.jsonl for this run - one row
  # per (store, product key) recording which commodity owns the product, which include pattern fired,
  # how many excludes were tested, and which other commodities also wanted it.
  #
  # OPT-IN, NOT DEFAULT-ON, and that is section 10.9 rather than caution: compare-deals is ALSO run
  # ad hoc - -Explain, -SelfTest, and apply-coverage-batch.ps1, which edits commodities.json and
  # re-runs the engine three or four times per attempt to see what a rule edit moved. Those runs
  # carry a DIFFERENT rules hash, so a default-on emitter would rewrite the whole table with trial
  # rules and hand the next reader a table that never described a published board. The chain names
  # the namespace explicitly (check-ad-cycles -> staple, recipe-overlay -> recipe); nothing else emits.
  #
  # -NoIdentity is the kill switch section 10.17 asks for: the gate ships ADVISORY and is promoted by
  # Brad, and until then step 1 must be revertible without a code revert. It wins over the namespace.
  [switch]$NoAisleAdmission,   # dry-run arm only: admit Family Fare rows the store shelves outside their commodity's departments (aisle-lib.ps1)
  [string]$IdentityNamespace = "",
  [switch]$NoIdentity,
  # THE PROVENANCE CONTRACT (2026-09-19, provenance-contract-lib.ps1). A captured price publishes only when it
  # proves when it was read (within the policy's MaxPublishAgeDays), where (the pinned store), that it is buyable
  # there, that it is a store read and not our own board, and that the store's own department does not name a form
  # its commodity excludes. 0 = read the limit from capture-policy-lib. -NoProvenanceContract is a MEASUREMENT arm
  # only (what the board would be without it); the board it writes says so in `provenance_contract`, and
  # guards.ps1 refuses to publish one.
  [int]$MaxPublishAgeDays = 0,
  # THE DATE THIS BOARD JUDGES VALIDITY AT, yyyy-MM-dd (2026-09-26, design\PLAN-board-clock-2026-09-26.md, Brad's D1):
  # which sales have ended, the 90-day publish window, the Sam's / Walmart / BOGO file ages, the rollback anchor.
  # Default: the real date of the run. A PINNED run (regression-test, build-regression-baseline, a fixture) passes
  # its frozen date here - reproducibility is kept by SAYING the date, never by borrowing the ad set's. week_of and
  # the file name stay the ad set (the newest ads-<D>.json's today), which ~60 readers pick files by.
  [string]$JudgeDate = '',
  [switch]$NoProvenanceContract
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
# The one place that decides what is EVERYDAY and what is a SALE on a captured row. See its header.
. (Join-Path $root 'price-split-lib.ps1')
# What a captured price must prove before it may publish (see the -MaxPublishAgeDays parameter above).
. (Join-Path $root 'provenance-contract-lib.ps1')
. (Join-Path $root 'capture-policy-lib.ps1')
if ($MaxPublishAgeDays -le 0) { $MaxPublishAgeDays = Get-PolicyMaxPublishAgeDays }
$PROV_PINS = Get-PclPinnedStores
if (-not $OutDir)  { $OutDir  = Join-Path $root 'out' }
if (-not $AdsFile) { $AdsFile = (Get-ChildItem (Join-Path $OutDir 'ads-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName }
# WHICH FILES THIS BUILD ACTUALLY OPENS (2026-08-21). grocery\out holds 870 tracked files, and the ones
# the engine still NEEDS are named exactly like the ones it has finished with - a dated capture looks
# identical to a disposable output. The board reads a UNION of dated captures (up to 14 days for
# Walmart, up to the 90-day quarter elsewhere) because the rotation only re-prices ~7 items per store
# per day, so a three-week-old file can be the only place a store's price for a commodity exists.
# Deleting by date bins prices the board is ranking on, and it does not error - it just publishes a
# different store as cheapest. The engine always knew which files it opened; it never wrote it down.
. (Join-Path $PSScriptRoot 'input-usage-lib.ps1')
$inputUsage = New-InputUsageTracker
Add-InputUsed -Tracker $inputUsage -Path $AdsFile -Role 'ads'
# READ JSON WITHOUT INVENTING MOJIBAKE (2026-09-05).
# `Get-Content -Raw | ConvertFrom-Json` with no -Encoding decodes as the system ANSI codepage in Windows
# PowerShell 5.1, so a BOM-LESS UTF-8 input arrives one generation mangled and the engine WRITES that
# mangled name onto the board. Not hypothetical: sams-deals-2026-07-29.json begins 7B 0D 0A (no BOM) while
# every other Sam's slice begins EF BB BF, and the board's shampoo/Sam's cell shipped as
# "TRESemm" + A-tilde + copyright-sign from a file whose bytes on disk are perfectly clean - which is also
# why heal-mojibake could never fix it: there was nothing wrong with the file.
# Same shape as the Hy-Vee carry read (pull-regular-hyvee.ps1) and the same fix: ReadAllText defaults to
# UTF-8 and honours a BOM when there is one, so both file shapes decode correctly.
function Read-JsonFile([string]$Path) {
  return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json)
}
# THE STORE'S OWN PRODUCT ID as one string, for Select-FreshestCaptureRows' same-product supersession.
# Written as an explicit loop rather than a Where-Object pipeline: an empty pipeline in a cast expression
# is $null, not '', and .Trim() on it throws mid-build over 40,000 rows. Most rows have no id at all
# (Walmart's July batch captures carry none), so the empty case is the COMMON path, not the edge.
function Get-ProdKey($d) {
  foreach ($f in @('item_id', 'product_id', 'sams_item_id')) {
    $v = ('' + $d.$f).Trim()
    if ($v) { return $v }
  }
  return ''
}
if (-not $CommoditiesFile) { $CommoditiesFile = Join-Path $root 'commodities.json' }
$cdoc = Read-JsonFile $CommoditiesFile
# a rule FILE may be a bare array (staples) or a wrapper { global_exclude:[...], commodities:[...] } (recipe
# set, which relaxes sauce/canned/frozen since those items legitimately ARE those forms).
if ($cdoc.PSObject.Properties['commodities']) { $commodities = $cdoc.commodities; $GEX_OVERRIDE = @($cdoc.global_exclude) } else { $commodities = $cdoc; $GEX_OVERRIDE = $null }
# SANITY PRICE BANDS ARE DERIVED, NEVER TYPED (Brad, queue 2026-09-21-6b17b1, 2026-09-22: "Derive from data", and on the
# rollout: "We need to fix it now, properly, and to make sure we are future proof so this doesn't happen again. I dont
# care how long it takes."). Every commodity's band is derived from this build's own price evidence in the pre-pass below
# (derived-band-lib.ps1). A TYPED band is read in exactly two places:
#   1. an explicit -BandsFile, which only the PINNED regression harness passes (regression-test.ps1 and
#      build-regression-baseline.ps1 freeze the rules they ran under, inline band_min/band_max included), so a frozen
#      baseline keeps judging what it always judged;
#   2. a commodity's own "band_override": { "min": x, "max": y, "reason": "..." }, used ONLY while the build derives no
#      band for it (fewer than 3 priced rows), and refused without a reason. More evidence retires it by itself.
# A live rules file that still carries band_min/band_max has them IGNORED and COUNTED in out\band-derivation-<date>.json
# (typed_fields_ignored), never silently honoured: that is the number nobody re-reads as prices move.
$BANDS = @{}
$PINNED_BANDS = [bool]$BandsFile
$BAND_OVERRIDES = @{}
$TYPED_FIELDS_IGNORED = New-Object System.Collections.ArrayList
if ($PINNED_BANDS) {
  if (Test-Path $BandsFile) { $bDoc = Read-JsonFile $BandsFile; foreach ($p in $bDoc.bands.PSObject.Properties) { $BANDS[$p.Name] = $p.Value } }
  # pinned rules may carry inline band_min/band_max (the recipe set): they override the bands file, because a recipe
  # commodity that shares an id with a staple can use a different unit (oz vs lb).
  foreach ($c in $commodities) { if ($c.PSObject.Properties['band_min']) { $BANDS[[string]$c.id] = [pscustomobject]@{ min=[double]$c.band_min; max=[double]$c.band_max } } }
} else {
  foreach ($c in $commodities) {
    if ($null -eq $c) { continue }
    if ($c.PSObject.Properties['band_min'] -or $c.PSObject.Properties['band_max']) { [void]$TYPED_FIELDS_IGNORED.Add([string]$c.id) }
    if ($c.PSObject.Properties['band_override'] -and $null -ne $c.band_override) {
      $bo = $c.band_override
      if (-not ($bo.PSObject.Properties['reason'] -and ([string]$bo.reason).Trim())) { throw ('band_override on commodity ' + $c.id + ' carries no reason; an override is refused without one') }
      $BAND_OVERRIDES[[string]$c.id] = [pscustomobject]@{ min = [double]$bo.min; max = [double]$bo.max; reason = [string]$bo.reason }
    }
  }
}
. (Join-Path $PSScriptRoot 'compare-deals\refusals.ps1')
# IN-STORE PRICE MODE, ENFORCED PER ROW (2026-08-31). See instore-lib.ps1 for the rule and the founding
# achiote bug. It is shared with audit-coverage-gaps.ps1, which would otherwise report every row this gate
# refuses as "the store carries it but the board is missing it".
. (Join-Path $PSScriptRoot 'instore-lib.ps1')
. (Join-Path $PSScriptRoot 'compare-deals\ranking.ps1')
# bulk / non-single-unit heuristic on a size string (so the winner line can flag "10 lb pack" etc.)
# THE PRICING MATH LIVES IN A LIBRARY NOW (2026-09-09, backlog I82). It used to be defined here and
# LIFTED as source text by twelve other scripts, because this file runs a pipeline on load and could
# not be dot-sourced. The functions never had that problem - they are pure - so they moved out and
# every caller dot-sources them instead of cutting them out with a regex.
. (Join-Path $PSScriptRoot 'pricing-math-lib.ps1')
# THE TILE CARRIES ITS LINK (design/PLAN-link-rides-with-price-2026-09-27.md L1): the per-store URL rules, one copy
# shared with derive-links-from-prices.ps1. Proven once per build, not per row.
. (Join-Path $PSScriptRoot 'link-identity-lib.ps1')
# Sam's Club is the only store requiring a paid membership (100% deterministic) - drives the "no-membership" winner.
function Test-Membership([string]$store) { return ($store -eq "Sam's Club") }

# ---------------------------------------------------------------- unit conversion
# THE COUNT VOCABULARY, ONCE (2026-09-06). Three lists had drifted apart: Convert-ToUnit's 'each' arm
# accepted head|loaf, Get-SizeAmount's bare-token list did not, and the each-branch's own bare-size regex
# accepted bunch(es) only (patched 2026-08-31 for green onions). Hy-Vee's "Bud Iceberg Lettuce | head |
# $1.97" was unpriced for exactly that reason: the branch that decides it never learned the word. Each list
# was edited alone on the day it bit, which is how three copies of one rule become three different rules.
#
# THERE ARE TWO VOCABULARIES HERE, NOT ONE, and collapsing them is the mistake this comment exists to stop.
#   WHOLE-PURCHASE tokens name the thing a shopper carries out: a head of lettuce, a loaf, a bunch, "1 ct".
#     A size that is ONLY one of these words means the ad prices ONE item, so the row prices per-each.
#   CONTAINER tokens (pk/pack/pkg/package) name a box with an UNKNOWN number inside. "6 pk" is a real count
#     and still divides; a bare "pkg" is not a count at all and must keep dropping - the mystery-tray fixture
#     in the self-test pins it. Putting pkg in the whole-purchase list prices a package as one item.
# Convert-ToUnit's 'each' arm takes BOTH, because there it is always converting a STATED number ("2 pkg" is
# two packages); the two bare-size gates take the whole-purchase list only.
# THESE ARE FUNCTIONS, NOT $script: VARIABLES (2026-09-06). They were made functions while three builders
# lifted function BODIES out of this file by regex, because a top-level constant does not travel with a
# lift: the first cut used variables and turned both build-*-deals suites red on "watermelon each ->
# engine returned null (size='each')". Since I82 (2026-09-09) they live in pricing-math-lib.ps1, every
# builder dot-sources it, and that reason is history. Keep them functions anyway - the library's header
# promises it holds no $script: state.
# WRITTEN WITH A PARAMETER LIST AND THE CLOSING BRACE AT COLUMN 0. Section 30's library closure check
# extracts bodies with `^function\s+NAME\s*\(.*?^\}`, and it SKIPS a function that shape does not match
# without saying so - a one-line `function F { ... }` would simply go unchecked. Do not compact these.
# canonical amount = how many <category unit> are in "$num $token"
# ---------------------------------------------------------------- size parsing
# returns canonical amount (in category unit) from a size string, or $null if not derivable
# ---------------------------------------------------------------- price parsing
# Normalize spelled-out small numbers to digits so a word-form BOGO ("buy two, get one free" -
# how Hy-Vee's Flipp feed writes them) parses like "buy 2 get 1 free". Only touches the price text,
# never the stored name or category matching, so it can't create a false commodity match.
# returns @{ per_item; kind; note } where per_item = dollars for ONE package of the listed size,
# or $null if price can't be read. kind flags per-lb / per-each markers found in the text.
# ---------------------------------------------------------------- unit price for a categorized deal
<#
  Test-NameOffersTwoSizes - is this name an EITHER/OR ad, whose price buys one of two different packages?

  WHY (2026-08-29). Kroger writes its weekly ad as one price over two products: "Kroger Ice Cream 48 fl oz
  or Private Selection Ice Cream 16 fl oz - $1.99". The size field on those rows is "each", so Get-UnitPrice
  falls through to reading a size out of the NAME - and a regex reading a name that states TWO sizes takes
  the FIRST one. That is not a parse, it is a coin flip, and it is a BIASED one: ads lead with the bigger
  package, so the guess always lands on the size that makes the row look cheapest, which is precisely the
  direction that wins a crown. Measured on comparison-2026-08-26: 8 such rows, all Baker's, and 2 of them
  held the crown - ice-cream published at $0.0415/fl oz off the 48 oz reading when the $1.99 may well buy
  the 16 oz tub ($0.1244, 3x), and popsicles at "per-36-pack" off "36 ct or 12-18 ct".

  So: when the name offers two DIFFERENT sizes, the basis is not derivable from it and the row must not be
  priced from its name at all. It drops out of the ranking exactly like any other bad parse - the board
  still ships on the runner-up. This does NOT touch the store's own size field, which is a statement about
  the unit actually being priced; only the name fallback, which is the guess.

  DELIBERATELY NARROW, AND NARROWED AGAIN THE SAME DAY. Both sides of the "or" must state a size, and they
  must disagree WITHIN THE SAME UNIT FAMILY. The same-family rule is not tidiness - it is what separates a
  genuine either/or from an "or" that joins two DESCRIPTIONS. thriftycrew-11 scanned the day's real captures
  and found the only two "or" names in 415 Walmart rows were one product twice:
      "( 2 Pack ) Lucky Leaf Premium Strawberry Rhubarb Pie Filling Or Topping, 21 oz Can"
  Here "or" joins "Pie Filling" and "Topping", and the first version of this function refused it: it saw
  "2 pk" on the left, "21 oz" on the right, called them different, and would have dropped a perfectly
  priceable row while logging something that read entirely correct. A real either/or ad offers two
  COMPARABLE packages and states them in the same measure (48 fl oz or 16 fl oz; 36 ct or 12-18 ct); a pack
  count on one side and a jar weight on the other is a name, not an alternative.

  So: "Orange or Apple Juice 64 fl oz" (one size) stays priceable, "Coke 12 pk or Pepsi 12 pk" (agreeing)
  stays priceable, and the Lucky Leaf rows (no shared family) stay priceable. Only a genuine ambiguity is
  refused.
#>
# Conservative: return a unit price ONLY when confidently derivable; else $null (dropped, not guessed).
# A "Buy N, get K ..." conditional deal that NEEDS a captured regular price + a unit basis to be priceable.
# (Plain "N for $M" is NOT included here - it prices on its own without a regular.)
function Get-RowSrcDate([string]$store, $row, [string]$fileDate) {
  # A ROW IS AS OLD AS ITS OWN EVIDENCE, NEVER AS YOUNG AS ITS FILE (2026-08-02).
  # Get-RegularSrcDate above dates every row in a file by the file's NAME. That was fine while a store's
  # out\regular file was written whole by one capture. It stopped being fine the moment a file could hold
  # rows of MIXED age: refresh-sams-verified.ps1 re-prices the ~20 hand-verified Sam's rows a fresh capture
  # confirms and carries the other 40 unchanged, so naming the result sams-regular-2026-08-01.json handed
  # all 60 rows an 08-01 stamp. The 40 carried rows then out-ranked Sam's real 2026-07-29 feed and took
  # cells off it: sandwich-bags flipped from the 580-ct Ziploc at $0.0168/ea to a 300-ct SNACK bag at
  # $0.0309/ea - 84% dearer, on a row nothing had re-verified. The guards caught it before it published.
  # DIRECTIONAL ON PURPOSE. A row's own as_of is used only when it is OLDER than the file date, which can
  # only ever make a row rank LOWER. The opposite direction - trusting a row that claims to be fresher than
  # the file it lives in - is the as_of laundering fixed in the Fareway builder the same day, and it is the
  # one mistake that could let a stale price out-rank a live one.
  # SAM'S ONLY, and that limit was MEASURED, not assumed. Applied to Walmart as well, this moved three cells
  # the wrong way in one rebuild (lime-juice, pudding-cups and taco-sauce all landed at ~2x their own stored
  # link) because Walmart's rows are carried forward across a 14-day UNION with their original as_of: re-dating
  # them changes which capture is "newest" for a commodity, and a different product wins the cell. That union
  # has its own ordering discipline and its own guard; perturbing it is a separate piece of work with its own
  # evidence. Sam's is the store with a mixed-age file, so Sam's is the store this fixes.
  if (-not $fileDate) { return '' }
  if ($store -ne "Sam's Club") { return $fileDate }
  $ao = ''
  if ($row.PSObject.Properties['as_of']) { $ao = [string]$row.as_of }
  if (($ao -match '^\d{4}-\d{2}-\d{2}$') -and ($ao -lt $fileDate)) { return $ao }
  return $fileDate
}

# SELECT-FRESHESTCAPTUREROWS NOW LIVES IN capture-depth-lib.ps1 (2026-08-21), because this engine is not
# its only reader: audit-capture-eviction checks the published board against the same rule and used to do
# it from a hand-restated copy, kept honest by a test-auditors grep for a shared literal. A grep can see a
# literal change and cannot see a change in MEANING - and the meaning did change the day the everyday/sale
# split made one product emit two rows. The lib's header carries the full history: the onions bug the
# freshness rule exists for, the baby-formula bug the depth exception exists for, and the cherries cell
# that made depth count distinct products instead of rows.
. (Join-Path $PSScriptRoot 'capture-depth-lib.ps1')


# IS THIS AD FILE LIVE ON THE BOARD'S OWN DATE? Pure, so the self-test below can reach the real code instead
# of a copy of it - the inline version of this check had no test at all, and an inline copy is how a guard
# ends up proven against something the pipeline does not run. Returns $null when the file is live, or the
# reason string when it is not. Judged against the BOARD's date, never the wall clock, so a pinned regression
# run stays reproducible. Absent evidence is not evidence: no ad_to is never expired, no ad_from never early.
function Test-AdWindowClosed {
  param($Doc, [datetime]$BoardDate)
  if ($Doc.ad_to) {
    $adTo = $null; try { $adTo = [datetime]$Doc.ad_to } catch {}
    if ($adTo -and $adTo -lt $BoardDate) { return ("its ad window closed " + $Doc.ad_to + " (" + [int](($BoardDate - $adTo).TotalDays) + "d before this board's " + $BoardDate.ToString('yyyy-MM-dd') + ")") }
  }
  if ($Doc.ad_from) {
    $adFrom = $null; try { $adFrom = [datetime]$Doc.ad_from } catch {}
    if ($adFrom -and $adFrom -gt $BoardDate) { return ("its ad window does not open until " + $Doc.ad_from + " (" + [int](($adFrom - $BoardDate).TotalDays) + "d after this board's " + $BoardDate.ToString('yyyy-MM-dd') + ")") }
  }
  return $null
}

function Add-TcNamelessRow {
  <# Record a row whose name did not parse. Returns the running total, so -SelfTest can assert it.

     THE FORMAT LAYER (2026-09-07, backlog E5). Add-Norm drops a nameless row before any business rule
     runs, and until now said nothing - so a capture whose name field moved would yield fewer rows and
     produce no signal at all. E5 calls that silent by construction, and this is the one site in the
     engine that had it: the file-level drops Write-Warning, and the expired-sale drop already counts
     into $health.

     PER STORE, because the total is the wrong grain: three nameless rows across seven stores is feed
     noise, three from ONE store is that store's capture shape having moved.

     NULL-SAFE ON BOTH COUNTERS, because a $script: variable does not travel with a lifted function
     and three scripts lift from this file ([[compare-deals-lifters-need-functions-not-variables]]). #>
  param([string]$Store)
  if ($null -eq $script:NamelessRowsByStore) { $script:NamelessRowsByStore = @{} }
  $k = [string]$Store
  if (-not $k) { $k = '(no store)' }
  $script:NamelessRowsByStore[$k] = 1 + [int]$script:NamelessRowsByStore[$k]
  $script:NamelessRows = 1 + [int]$script:NamelessRows
  return $script:NamelessRows
}

function Format-TcNamelessByStore {
  <# The per-store breakdown as one stable string, or '' when there is nothing to say.

     -join and NOT Join-String: this estate is PowerShell 5.1 and Join-String is a 7-only cmdlet. It
     would have thrown inside the health block, where $ErrorActionPreference is Stop. #>
  param($ByStore)
  if ($null -eq $ByStore -or -not $ByStore.Keys.Count) { return '' }
  return (($ByStore.Keys | Sort-Object | ForEach-Object { $_ + '=' + [int]$ByStore[$_] }) -join ',')
}

# ---------------------------------------------------------------- SELF-TEST (provable multibuy math; -SelfTest exits here)
# Which everyday-price files (out\regular\<store>-regular-<date>.json) to load per store. EVERYDAY-ONLY stores
# (Walmart) run no weekly ad cycle, so a partial daily refresh (a throttled ~50-item pull) must UNION with the
# recent captures or it collapses the board - the 2026-07-23 incident, when a 50-of-410 Walmart pull cut the
# store to 80 cells and the coverage guard blocked the publish. Every OTHER store here runs weekly SALES, and
# dating its everyday rows would let today's everyday price filter a still-valid sale out of the freshness
# ranker - so they stay newest-file-only. PURE function (operates on a passed file list, reads no disk) so
# `compare-deals.ps1 -SelfTest` can prove the union never silently regresses to newest-only.
# Select-RegularFileSet + the everyday-only store list now live in regular-fileset-lib.ps1, shared with
# guards.ps1. They used to be here only, and guards.ps1 answered "which files does the board price from?"
# with its own simpler "newest per store" - which is a DIFFERENT answer for Walmart, the one store this
# function unions. 332 live Walmart cells were priced from files guards 5 and 10 never opened. A guard must
# iterate the same file set the engine priced from, or it is guarding a different board than the one that
# ships. The self-test cases below still exercise it through the lib.
. (Join-Path $PSScriptRoot 'regular-fileset-lib.ps1')

# Get-DisplayedUnitPrice / ConvertTo-DisplayedUnitToken. ONE parser for the stores' unit-price literals,
# shared with audit-basis-reconcile, audit-pack-basis and the derived-size density rule, rather than a
# second inline copy here - a shared-lib fix ships nothing while callers keep inline copies.
. (Join-Path $PSScriptRoot 'derived-size-density-lib.ps1')
. (Join-Path $PSScriptRoot 'derived-band-lib.ps1')   # Get-TcDerivedBands: the band is derived, never typed (6b17b1)
$BAND_GROUPS = @{}; try { $BAND_GROUPS = Get-TcStoreReferenceGroups (Read-JsonFile (Join-Path $PSScriptRoot 'stores.json')) } catch { Write-Warning ('stores.json reference groups unreadable - every store is judged as retail: ' + $_.Exception.Message) }

# ---------------------------------------------------------------- THE STORE'S OWN PER-UNIT NUMBER
# (2026-09-04, queue 2026-09-04-def37c, triage-plans\plan-2026-09-04.json)
#
# Sam's and Walmart publish a unit price on every row they capture (sams_unit_price "$0.05/oz",
# wm_unit_price "37.3 c/fl oz"). It is the store's OWN arithmetic on its OWN pack, so it is the one
# machine-readable proof that a warehouse pack really is that cheap per ounce - and it never reached the
# board. sanity-check.ps1 has carried a native_unit_price cross-check since it was written, and NOT ONE
# comparison row has ever carried that field: no producer populated it, so the check has been dormant for
# every store since day one and the only valve for a true-but-47%-cheaper cell was a hand-written ack with
# a short expiry. Sam's Quaker Old Fashioned Oats 160 oz at $7.98 (= $0.0499/oz, and Sam's own shelf says
# $0.05/oz) was acked as real on 2026-07-29, the ack expired 2026-08-13, and the flag re-armed and paged
# again today. It would page again on every future expiry, as would 32 other store-verified outliers.
#
# TWO FUNCTIONS, BOTH PURE, BOTH REACHED BY -SelfTest, because the two halves happen at different moments:
# the PARSE happens at ingest (Add-Norm, which sees the capture row but not the commodity) and the RESOLVE
# happens at the emit (which knows the commodity's unit but no longer has the capture row).
#
# THE UNIT FAMILY IS THE WHOLE POINT. A store pricing per EACH against a commodity priced per OUNCE is not
# a disagreement, it is a different question, and reporting it as a mismatch is how a cross-check earns a
# reputation for crying wolf (measured: 5 of the 38 verifiable outlier rows, and 168 of 906 Sam's/Walmart
# cells, are exactly this shape). So: emit NOTHING when the families differ. The single exception is lb
# against an oz commodity, which is the same measure in a different magnitude and converts exactly.
function Resolve-NativeUnitPrice($Value, [string]$NativeUnit, [string]$CommodityUnit) {
  if ($null -eq $Value) { return $null }
  $v = [double]$Value
  if ($v -le 0) { return $null }
  if (-not $NativeUnit -or -not $CommodityUnit) { return $null }
  $n = $NativeUnit.Trim().ToLower(); $c = $CommodityUnit.Trim().ToLower()
  if ($n -eq $c) { return [pscustomobject]@{ price = [math]::Round($v, 6); unit = $c } }
  if ($n -eq 'lb' -and $c -eq 'oz') { return [pscustomobject]@{ price = [math]::Round($v / 16.0, 6); unit = 'oz' } }
  return $null
}

if ($SelfTest) {
  $__cdHostPath = $PSCommandPath; $__cdHostDir = $PSScriptRoot   # the moved self-test reads the HOST's path and folder, never its own
. (Join-Path $PSScriptRoot 'compare-deals\selftest-1.ps1')
. (Join-Path $PSScriptRoot 'compare-deals\selftest-2.ps1')
  exit $LASTEXITCODE   # an exit inside a dot-sourced piece ends only the piece; this one ends the host
}

# ---------------------------------------------------------------- load + normalize all sources
$deals = New-Object System.Collections.Generic.List[object]
function Get-RowProductId($row) {
  <#
    THE STORE'S OWN ID FOR THIS LISTING, when the capture row carries one. Enumerated on the live
    captures 2026-08-22 (PLAN section 10.15 asks for exactly this census, because "the source has an id"
    and "our row records it" are different questions):
        Baker's      product_id   7,289 rows      Hy-Vee       product_id   1,554 rows
        Family Fare  product_id   5,224 rows      Walmart      item_id        136 rows
        Aldi, Fareway, Sam's Club, hunter-*       NO id field on the row -> name-keyed
    Aldi and Fareway rows do carry link_url, which is a stabler key than a name; adopting it is a
    deliberate change to those lanes' contract (they belong to the browser-lane session, section 5.5),
    so it is NOT taken here. Ad rows have no store id by nature and are name-keyed on purpose
    (section 10.14).
    Returns '' rather than $null so the caller never has to test for both.
  #>
  # DIRECT property access, not PSObject.Properties.Name -contains. This is called once per capture row
  # - about 40,000 times per build - and materialising the property-name collection for each row cost a
  # measured ~10s of the ship path. A missing property on a PSCustomObject reads as $null, which is
  # exactly the answer wanted, so the membership test bought nothing.
  if ($null -eq $row) { return '' }
  $v = ('' + $row.product_id).Trim()
  if ($v) { return $v }
  $v = ('' + $row.item_id).Trim()
  if ($v) { return $v }
  return ''
}
# FAMILY FARE SHELF-PATH ADMISSION (2026-09-11, queue 2026-09-11-62b248). The store's own canonical_url is
# indexed as the everyday rows load (Add-AisleShelfRow, in the regular loader below) and read in the hot loop
# (Get-AisleAdmissionRefusal), so a Family Fare row the store shelves outside its commodity's departments
# cannot price a cell. The rule is aisle-lib.ps1, the one copy aisle-test.ps1 also judges the live board by.
# -NoAisleAdmission turns only the refusal off, for the dry-run arm that measures what it refuses.
. (Join-Path $PSScriptRoot 'aisle-lib.ps1')
$AisleShelf = New-AisleShelfIndex
$AisleRefused = New-Object System.Collections.Generic.List[object]
. (Join-Path $PSScriptRoot 'compare-deals\identity.ps1')
# everyday/regular shelf-price files (out\regular\<store>-regular-<date>.json), newest per store; price_type=everyday.
# -RegularDir lets the regression harness pin the everyday-price channel to a FROZEN copy - the default
# newest-per-store auto-load is exactly the unpinned input that made the "frozen" regression drift.
# ---- the ad rows a storefront markdown can INHERIT its window from --------------------------------
# Brad, 2026-08-21: "if an item has a sale price, it MUST of been on some ad previously." Largely
# true, and where it is true the store has ALREADY told us when the sale ends - so the honest move is
# to go and get that date rather than invent a TTL. Measured on this board: 176 of 377 undated sale
# cells match a real ad row (Hy-Vee 60 of 82). Hy-Vee's butter is the case that proved it - published
# as an undated sale at $2.48 while sitting in the 3 Day Sale flyer as "Hy-Vee butter, 16 oz., $2.48"
# valid 08-21..08-23.
# LIVE ADS ONLY here, deliberately: an expired flyer's dates would retire the cell the moment they
# were applied, and a flyer that has not opened would keep it alive past its real end. The
# sale-without-ad ledger asks the other question ("was it EVER advertised") and passes -IncludeExpired.
. (Join-Path $root 'ad-match-lib.ps1')
. (Join-Path $root 'rollback-ttl-lib.ps1')   # the LAST-RESORT window: see the TTL block in the split below
$script:AdIndex = $null
try { $script:AdIndex = Import-AdRows -OutDir $OutDir -BoardDate ([string]$judge) } catch { Write-Warning ("ad-match index unavailable (" + $_.Exception.Message + ") - undated sales stay undated") }
$script:AdInherited = 0
$script:TtlDated = 0
# Sales dated by the STORE's own stated countdown (Fareway saleDisclaimerString). Counted separately
# from ad-inherited and TTL windows so the three sources stay distinguishable in the health block -
# a real date from the store and a 30-day guess must never read as the same fact.
$script:StoreCountdown = 0

$regDir = if ($RegularDir) { $RegularDir } else { Join-Path $OutDir 'regular' }
if (Test-Path $regDir) {
  # ONLY canonically-named files are data: "<store>-regular-<yyyy-MM-dd>.json", nothing else. This glob used
  # to be a bare '*.json', which made every file dropped in out\regular a "store". A throttled 0-row diagnostic
  # named "family-fare-regular-2026-07-14.PARTIAL.json" therefore (a) matched, and (b) sorted AFTER the good
  # "...-07-14.json" (case-insensitively 'p' > 'j'), so -Descending picked the EMPTY file and Family Fare
  # contributed zero everyday rows to the board while every log said the pull had succeeded. Anchor the name.
  # Newest-per-store, EXCEPT Walmart. Walmart is EVERYDAY-priced (no weekly ad cycle), and its browser capture
  # can run as a partial daily refresh (e.g. a 50-item core-staple pull). "Newest file wins" then SHRINKS the
  # board to whatever that partial covered - on 2026-07-23 a 50-term refresh cut Walmart from 410 cells to 80
  # and the coverage guard (correctly) blocked the publish. So Walmart UNIONS its recent captures and tags each
  # row with src_date; the freshness-per-commodity ranker (see "rank" below) then keeps today's price where it
  # exists and the last full capture everywhere else - no stale-low, no coverage loss. This is the same
  # multi-capture pattern Sam's already uses. Every OTHER store here can run weekly sales, so unioning old files
  # would resurrect expired prices; they stay newest-only.
  $regFiles = Select-RegularFileSet (Get-ChildItem (Join-Path $regDir '*-regular-*.json') -ErrorAction SilentlyContinue) ([datetime]$judge) $WalmartMaxAgeDays
  # Recorded on the SELECTED set, not on everything in the directory. Which captures the union actually
  # ADMITTED is the whole question a cleanup has to answer; what is merely present on disk is not.
  foreach ($rfu in $regFiles) { Add-InputUsed -Tracker $inputUsage -Path $rfu.FullName -Role 'everyday' }
  foreach ($rf in $regFiles) {
    $ex = Read-JsonFile $rf.FullName
    # PRICE-MODE GATE (2026-07-15): Aldi/Fareway are Instacart storefronts whose DELIVERY catalog is marked up
    # ~10-50%. A file that does not MACHINE-PROVE it was captured in-store (price_mode='in-store' AND a
    # mode_verified date) is DROPPED here so its marked-up prices can never enter the board. Fareway shipped
    # 320 delivery-priced cells exactly this way. audit-price-mode.ps1 reports it; this is what enforces it.
    if (@('Aldi','Fareway') -contains [string]$ex.store -and ([string]$ex.price_mode -ne 'in-store' -or -not [string]$ex.mode_verified)) {
      Write-Warning ("price-mode: DROPPED $([string]$ex.store) everyday file (price_mode='$([string]$ex.price_mode)' mode_verified='$([string]$ex.mode_verified)') - not proven in-store; its prices are EXCLUDED from the board until re-captured In-Store and stamped")
      continue
    }
    $pt = if ($ex.price_type) { [string]$ex.price_type } else { 'everyday' }
    # WHAT THIS FILE SAYS ABOUT THE STORE IT WAS READ AT, for the provenance contract. Only for the stores whose
    # files are NEVER carried forward (Walmart, Sam's): there the file's store line describes every row in it. A
    # carry lane's file holds rows read on other days, possibly at another store (Hy-Vee's 1465 rows sat inside
    # files whose own header was current), so there only the ROW's own stamp can prove where it was read.
    $regFileSource = if (@('Walmart', "Sam's Club") -contains [string]$ex.store) { (@([string]$ex.source, [string]$ex.club, [string]$ex.store_label) | Where-Object { $_ }) -join ' | ' } else { '' }
    # WHICH out\regular rows carry their capture date: see Get-RegularSrcDate. Walmart unions captures, and
    # Sam's has a SECOND everyday source (out\sams) that its out\regular copy has to be ranked against; every
    # other store's out\regular file is its only everyday source and stays date-less.
    $sd = Get-RegularSrcDate ([string]$ex.store) ([string]$rf.BaseName)
    # $sd is the FILE's date. Get-RowSrcDate lets a row carrying an OLDER as_of keep it, so a file that holds
    # rows of mixed age (refresh-sams-verified re-prices some rows and carries the rest) cannot hand the
    # carried ones the refreshed file's freshness. Backward only - see that function.
    # THE EVERYDAY/SALE SPLIT (2026-08-21, Brad: "Ad pricing must never enter the every day pricing
    # value"). An out\regular file is nominally the store's EVERYDAY channel, but the row it carries is
    # simply "what you pay today" - which for 357 board cells was really a markdown, typed everyday,
    # 27 of them holding the Cheapest crown and none of them expiring under the 90-day carry.
    # price-split-lib reads each store's own discount signal (see its header for what each one is) and
    # returns the two halves. Applied HERE rather than in seven producers so it covers the rows already
    # on disk - the board is mostly carried-forward rows, which a producer-side fix could not reach for
    # a quarter - and so the capture files stay the honest record of what the store showed us.
    foreach ($d in $ex.deals) {
      if ([string]$ex.store -eq 'Family Fare') { Add-AisleShelfRow $AisleShelf $d }   # the store's own shelf path, indexed as it loads (aisle-lib.ps1)
      $rsd = Get-RowSrcDate ([string]$ex.store) $d $sd
      $spl = Get-PriceSplit $d ([string]$ex.store)
      $script:LastBasis = if ($spl.sale_from) { 'store' } else { '' }
      if ($spl.sale_price) {
        # THE STORE STATED A COUNTDOWN. Highest precedence after its own explicit dates, because it
        # IS the store's own answer - Fareway's saleDisclaimerString, "Sale ends in N days", captured
        # from the storefront's Apollo cache. Brad found this by opening a product page and asking why
        # a row with a visible end date was being given a 30-day guess.
        #
        # DERIVED FROM THE ROW'S OWN as_of, NEVER FROM TODAY. The countdown is relative to the day it
        # was captured: "ends in 1 day" seen on 08-21 means 08-22, and still means 08-22 when the row
        # is read on 08-25. Reading it against today would push the expiry forward every single build
        # and produce a sale that never ends - the same infinite-TTL shape the rollback anchor exists
        # to prevent, arriving through a different door.
        # Verified against an independent source before shipping: the ribs read "Sale ends in 1 day"
        # on 2026-08-21 -> 2026-08-22, and fareway-deals-2026-08-20.json independently states the
        # weekly ad runs 2026-08-17 to 2026-08-22.
        # The derivation lives in price-split-lib beside the split it belongs to, so the frozen
        # fixtures exercise the REAL decision rather than a transcription of it.
        # ANCHORED ON THE ROW'S as_of, not $rsd's file date and not today - see that function's header.
        if (-not $spl.sale_from -and $null -ne $d.sale_ends_days) {
          $anchorDate = if ([string]$d.as_of -match '^\d{4}-\d{2}-\d{2}$') { [string]$d.as_of } else { $rsd }
          $sw = Get-StatedSaleWindow $d.sale_ends_days $anchorDate
          if ($sw) {
            $spl.sale_from = $sw.from; $spl.sale_to = $sw.to
            $script:StoreCountdown++; $script:LastBasis = 'store'
          }
        }
        # INHERIT THE AD'S WINDOW when the store's own row carried none. This is what turns "a sale
        # we cannot date" into "a sale that ends on the day the flyer says", and it is the difference
        # between a TTL guess and the store's own answer.
        if (-not $spl.sale_from -and $script:AdIndex) {
          $adHit = Find-AdForCell -Index $script:AdIndex -Store ([string]$ex.store) -Item ([string]$d.item) -PriceText ('$' + $spl.sale_price)
          if ($adHit -and $adHit.from -match '^\d{4}-\d{2}-\d{2}$' -and $adHit.to -match '^\d{4}-\d{2}-\d{2}$') {
            $spl.sale_from = $adHit.from; $spl.sale_to = $adHit.to; $script:AdInherited++; $script:LastBasis = 'ad'
          }
        }
        # LAST RESORT: a TTL, anchored to the first day we saw this exact cut price (Brad's rule for
        # Fareway, Walmart and Sam's - the three stores that publish no end date). Deliberately AFTER
        # the ad lookup: a real window from the store's own flyer always beats a number we chose.
        # Keyed on the store's product id, never the name, so a re-listing cannot restart the clock;
        # a row with no identity gets no window rather than a name-keyed guess.
        if (-not $spl.sale_from -and (Test-RollbackTtlStore ([string]$ex.store))) {
          $ttlKey = ''
          if ($d.item_id)   { $ttlKey = [string]$d.item_id }
          elseif ($d.sams_item_id) { $ttlKey = [string]$d.sams_item_id }
          elseif ($d.product_id)   { $ttlKey = [string]$d.product_id }
          elseif ($d.link_url -match '/products/(\d+)') { $ttlKey = $Matches[1] }
          if ($ttlKey) {
            # -AsOf IS THE ROW'S OWN CAPTURE DATE. Brad's ruling (2026-08-22): the TTL runs from DETECTION,
            # and detection is the capture that first showed the cut price, not the day this ledger met
            # the row. Passing only -Today handed a five-week-old Fareway markdown a fresh 30 days on
            # the day the ledger was created. Row as_of first, the file's date as the fallback.
            $ttlAsOf = if ([string]$d.as_of -match '^\d{4}-\d{2}-\d{2}$') { [string]$d.as_of } else { [string]$rsd }
            $rw = Get-RollbackWindow -Store ([string]$ex.store) -ItemId $ttlKey -Price ([double]$spl.sale_price) -Today ([string]$judge) -AsOf $ttlAsOf -Root $root
            if ($rw) { $spl.sale_from = $rw.ad_from; $spl.sale_to = $rw.ad_to; $script:TtlDated++; $script:LastBasis = 'ttl' }
          }
        }
        # A CUT PRICE IS A SALE, AND IT CARRIES ITS OWN WINDOW. Typed 'sale' so build-sale-windows
        # dates it, the page badges it, and it can expire. Its everyday half is emitted separately
        # below so the cell the shopper reverts to is never lost.
        # $d LAST so the store's own published unit price rides this row. THE SALE HALF ONLY: wm_unit_price
        # / sams_unit_price describe the price the store is charging TODAY, which is this half. The everyday
        # half below is what the row was cut FROM, and pairing the store's sale unit price with it would
        # manufacture a disagreement out of a discount.
        Add-Norm -Store $d.store -Name $d.item -PriceText ('$' + $spl.sale_price) -SizeText $d.size -Regular $d.regular -SourceAd $d.source_ad -PriceType 'sale' -SrcDate $rsd -AdFrom $spl.sale_from -AdTo $spl.sale_to -AdBasis $script:LastBasis -ProductId (Get-RowProductId $d) -Fulfillment ([string]$d.fulfillment) -SrcFile ([string]$rf.BaseName) -ProvRow $d -ProvKind 'capture' -FileSource $regFileSource -SrcRow $d
        # AND THE PRICE IT REVERTS TO. Without this row the everyday value disappears the moment a
        # store discounts an item, which is the other half of Brad's rule - everyday must not be
        # replaced by the ad. Only emitted when the store told us what it was cut FROM; a flagged row
        # with no was-price would otherwise publish the sale price twice under two labels.
        if ($spl.everyday_price -and $spl.everyday_price -gt $spl.sale_price) {
          Add-Norm -Store $d.store -Name $d.item -PriceText ('$' + $spl.everyday_price) -SizeText $d.size -Regular $null -SourceAd $d.source_ad -PriceType 'everyday' -SrcDate $rsd -ProductId (Get-RowProductId $d) -Fulfillment ([string]$d.fulfillment) -SrcFile ([string]$rf.BaseName) -ProvRow $d -ProvKind 'capture' -FileSource $regFileSource
        }
      } else {
        # not split: the row's own price IS what the store's published unit price describes, so carry $d.
        Add-Norm -Store $d.store -Name $d.item -PriceText $d.ad_price -SizeText $d.size -Regular $d.regular -SourceAd $d.source_ad -PriceType $pt -SrcDate $rsd -ProductId (Get-RowProductId $d) -Fulfillment ([string]$d.fulfillment) -SrcFile ([string]$rf.BaseName) -ProvRow $d -ProvKind 'capture' -FileSource $regFileSource -SrcRow $d
      }
    }
  }
}

# ---------------------------------------------------------------- categorize + price
# Prepared/processed/different-form terms: none of our raw staples are these, so a deal
# whose name contains one is NOT the plain commodity and is dropped (protects accuracy).
# THE EXCLUDE LIST IS A LIBRARY NOW (2026-09-09, backlog I82). It used to be defined here and
# regex-lifted out of this file's source by seven other scripts - and by this file's own self-test,
# which runs before the definition. It is a FUNCTION so it travels to a caller; a $script: constant
# would not, which this estate has already paid to learn.
. (Join-Path $PSScriptRoot 'global-exclude-lib.ps1')
$GLOBAL_EXCLUDE = Get-TcGlobalExclude
# a wrapper rule-file can replace the global list (the recipe set relaxes sauce/canned/frozen/juice)
if ($GEX_OVERRIDE) { $GLOBAL_EXCLUDE = $GEX_OVERRIDE }
# A store can rename a product without changing the product, and the rename silently un-matches it. Sam's moved
# from hand-shortened names to real catalog titles: "Member's Mark Boneless Skinless Chicken Breast" became
# "Member's Mark Boneless and Skinless Chicken Breast, priced per pound". Every include pattern here was written
# against the short form, so one inserted "and" turned a priced cell into a "doesn't carry" tile - and NOTHING
# caught it, because "doesn't carry" is a legitimate state that no audit can tell apart from a real gap.
# So: test includes against the raw name AND a normalized variant (drop the store's per-unit suffix, treat
# "X and Y" as "X Y"). The variant is used for INCLUDES ONLY. Excludes and the global list keep matching the RAW
# name, which is what makes this safe in one direction: normalizing can only ever ADD an include match, it can
# never quietly un-exclude something. (It matters concretely: "mix and match" normalizes to "mix match", which
# WOULD fall into the '\bmix\b' global whose lookahead is written to spare "mix & match".)
function Get-MatchTexts([string]$name) {
  $n = $name.ToLower()
  $v = $n -replace ',?\s*priced per\s+\w+', ''            # Sam's "..., priced per pound" / "per each" suffix
  $v = (($v -replace '\band\b', ' ') -replace '\s{2,}', ' ').Trim()
  return ,@($n, $v)                                        # [0] is always the RAW name
}
function Match-Category($name) {
  $texts = Get-MatchTexts $name
  $n = $texts[0]
  # Which global prepared-food tokens hit this name (usually none). A commodity whose PLAIN form legitimately
  # IS one of these (pasta-sauce is a sauce, soda is soda, ice-cream is ice cream...) declares relax_global:
  # ["\\bsauce\\b", ...] in commodities.json to waive EXACTLY those tokens for itself - every other commodity
  # still gets the full global protection (a "chicken sauce" can never enter chicken-breast).
  $ghits = @(); foreach ($g in $GLOBAL_EXCLUDE) { if ($n -match $g) { $ghits += $g } }
  foreach ($c in $commodities) {
    $hit = $false
    foreach ($inc in $c.include) { foreach ($t in $texts) { if ($t -match $inc) { $hit=$true; break } }; if ($hit) { break } }
    if (-not $hit) { continue }
    if ($ghits.Count) {
      $relax = @($c.relax_global | Where-Object { $_ })
      $blocked = $false
      foreach ($g in $ghits) { if ($relax -notcontains $g) { $blocked = $true; break } }
      if ($blocked) { continue }
    }
    $bad = $false
    foreach ($exc in $c.exclude) { if ($n -match $exc) { $bad=$true; break } }
    if ($bad) { continue }
    return $c
  }
  return $null
}

# ---------------------------------------------------------------- -Explain: why does this cell say that?
# READ-ONLY. Prints the ownership decision for one commodity and exits WITHOUT writing a board.
#
# Added 2026-08-21 after working out by hand why Family Fare's whole-cloves cell published $11.92/oz when a
# $2.99 jar sat in the same capture. That took about ten passes of throwaway script re-deriving what this
# engine already knows. The answer, once found, was one line long: ground-cloves' include list contained
# 'whole\s+cloves?', so it claimed the cheap jars first and whole-cloves never saw them.
#
# That is the CONTESTED failure - two commodities match one product and the winner is whichever sits earlier
# in commodities.json. audit-match-contested finds them in bulk; this answers the opposite question, the one
# actually asked when a single cell looks wrong: which rows could this commodity have had, and who took them.
#
# It lives HERE, inside the engine, on purpose. Match-Category is already copied into two auditors (see
# design\FINDINGS-contested-2026-08-21.md #6); a diagnostic that re-implemented the matcher would be the
# fourth copy and the first one anyone actually trusts, which is how a debugging tool starts lying.
if ($Explain) {
  $target = @($commodities | Where-Object { [string]$_.id -eq $Explain })
  if (-not $target.Count) { Write-Output ("-Explain: no commodity with id '" + $Explain + "'"); exit 1 }
  $tc = $target[0]
  $pos = [array]::IndexOf(@($commodities | ForEach-Object { [string]$_.id }), [string]$tc.id)
  Write-Output ("EXPLAIN  " + $tc.id + "  (" + $tc.label + ")   unit=" + $tc.unit + "   position " + $pos + " of " + @($commodities).Count + " in commodities.json")
  Write-Output ("  include: " + (@($tc.include) -join '  |  '))
  Write-Output ""
  $mine = 0; $lost = 0
  foreach ($d in $deals) {
    $nm = [string]$d.name
    if (-not $nm) { continue }
    $texts = Get-MatchTexts $nm
    $hit = $false
    foreach ($inc in $tc.include) { foreach ($t in $texts) { if ($t -match $inc) { $hit = $true; break } }; if ($hit) { break } }
    if (-not $hit) { continue }                       # this commodity's patterns never wanted it
    $winner = Match-Category $nm
    $wid = if ($winner) { [string]$winner.id } else { '<unmatched>' }
    if ($wid -eq [string]$tc.id) {
      $mine++
      Write-Output ("  OURS      {0,-12} {1,-9} {2,-10} {3}" -f $d.store, $d.price_text, $d.size_text, $nm)
    } else {
      $lost++
      # WHY it went elsewhere: our own exclude threw it out, or another commodity simply got there first.
      $n0 = $texts[0]; $selfExc = @()
      foreach ($exc in $tc.exclude) { if ($n0 -match $exc) { $selfExc += $exc } }
      $why = if ($selfExc.Count) { "our exclude " + $selfExc[0] }
             elseif ($wid -eq '<unmatched>') { "global exclude / no commodity" }
             else {
               $wpos = [array]::IndexOf(@($commodities | ForEach-Object { [string]$_.id }), $wid)
               if ($wpos -ge 0 -and $wpos -lt $pos) { "CONTESTED - '" + $wid + "' sits earlier (position " + $wpos + ")" }
               else { "claimed by '" + $wid + "'" }
             }
      Write-Output ("  LOST ->   {0,-12} {1,-9} {2,-10} {3}" -f $d.store, $d.price_text, $d.size_text, $nm)
      Write-Output ("            {0}" -f $why)
    }
  }
  Write-Output ""
  Write-Output ("  {0} row(s) this commodity keeps, {1} its patterns matched but lost." -f $mine, $lost)
  Write-Output "  A LOST row reading CONTESTED is decided by array order, not by a rule. Fix it with an"
  Write-Output "  explicit exclude on the commodity that should not have it - never by reordering the file."
  Write-Output "  (read-only: no board was written)"
  exit 0
}

# dedup identical rows (Family Fare's circular API repeats items across pages)
$seen = @{}; $ded = New-Object System.Collections.Generic.List[object]
# THIS DEDUPE IS ALSO THE UNION'S "NEWEST SIGHTING WINS" (measured 2026-09-26, PLAN-board-clock W1b). Sam's captures
# load newest first, so when a product shows the SAME price in several captures only the newest sighting survives here,
# and its older capture never counts as deeper in Select-FreshestCaptureRows. The rollback split retypes the newest
# sighting's cut price to sale; keyed on that type, an older identical everyday sighting stopped matching, survived,
# made its old capture "deeper", and handed 3 Sam's cells to an older, cheaper product (oatmeal, olive-oil,
# sliced-cheese) in the zero-lag A/B. So a split row dedupes on the type it had BEFORE the split (dedupe_type).
foreach ($d in $deals) {
  $dt = if ($d.PSObject.Properties['dedupe_type'] -and [string]$d.dedupe_type) { [string]$d.dedupe_type } else { [string]$d.price_type }
  $k = ($d.store + '|' + $d.name + '|' + $d.price_text + '|' + $d.size_text + '|' + $dt)
  if (-not $seen.ContainsKey($k)) { $seen[$k]=$true; $ded.Add($d) }
}
$deals = $ded

# Flat list of every matched deal (priced or not). Grouping by id afterward avoids per-id hashtable indexing.
$matched = New-Object System.Collections.Generic.List[object]
$flagged = New-Object System.Collections.Generic.List[object]
$mbUnpriced = New-Object System.Collections.Generic.List[object]   # Buy-N-Get-K deals we recognized but could NOT price -> surfaced, never silently dropped
# THE HOT LOOP RUNS THE PRECOMPILED MATCHER (2026-08-22). Profiled: 139 of 159 seconds per build was
# Match-Category - 45.7 million `-match` evaluations from an interpreted triple loop. match-lib makes
# the SAME decision (first-match-wins, global-exclude + relax_global, excludes on the raw name) from
# compiled regexes behind a sound literal prefilter, 17x faster on the full corpus.
# Match-Category above is NOT deleted and is NOT dead: it is the reference implementation. -Explain and
# the routing fixtures still call it, and test-match-lib.ps1 extracts it verbatim from this file every
# suite run and demands match-lib agree with it on every distinct name the engine feeds it - zero
# divergences or the suite goes red. That is what lets a second copy of the one rule that decides which
# product owns a cell exist at all.
. (Join-Path $PSScriptRoot 'match-lib.ps1')
$fastMatcher = New-CommodityMatcher -Commodities $commodities -GlobalExclude $GLOBAL_EXCLUDE
# THE RULINGS ARE LOADED BEFORE THE LOOP (2026-09-18, queue 2026-09-18-b1d8e3), because Get-FirstRefusal now
# asks them which refusal a doubly-refused row is filed under. The drop after the loop reads this same table.
. (Join-Path $PSScriptRoot 'known-wrong-lib.ps1')
$KW_BLOCKS = Get-KnownWrongBlocks -Path (Join-Path $PSScriptRoot 'known-wrong.json')
# THE CHANNEL INDEX (2026-09-01). Built from the rows already in memory - no capture file is read twice -
# so it knows, per store and per item id, the freshest thing the store said about that listing's channel.
# See instore-lib.ps1 for the rule and for the 21-cell browser probe that promoted it from a watcher to a
# refusal. Built HERE and not at load time because it has to see EVERY capture in the union before it can
# say which sighting is the newest one.
$CHANNEL_ALLOW = Get-ChannelAllowlist -Path $(if ($ChannelAllowlistFile) { $ChannelAllowlistFile } else { Join-Path $PSScriptRoot 'instore-channel-allowlist.json' })
$CHANNEL_INDEX = New-ChannelIndex -Rows $deals -Allowlist $CHANNEL_ALLOW
$channelRefused = @{}
$channelAllowed = 0
# Every row the provenance contract withheld, one row each, so the totals below derive from the rows (measurement.md).
$ProvWithheld = New-Object System.Collections.ArrayList
$ProvJudged = @{}
# THE IDENTITY TABLE COLLECTS EVERY ROW, INCLUDING THE UNMATCHED ONES. "No commodity owns this product
# under today's rules" is an answer, and it is the answer audit-coverage-gaps spends 100 seconds a day
# recomputing. Collected as references to rows already in memory, so this costs nothing here; the actual
# detail scan happens once per distinct name after the board is written (see the emission block).
$IDENT_ON = ($IdentityNamespace -ne '') -and (-not $NoIdentity)
$identityRows = $(if ($IDENT_ON) { New-Object System.Collections.Generic.List[object] } else { $null })
$AisleCatMap = $(if ($NoAisleAdmission) { @{} } else { Get-AisleCategoryMap -Root $PSScriptRoot })
# ---- THE BAND IS DERIVED FROM THIS BUILD'S OWN EVIDENCE (Brad's ruling "Derive from data", 2026-09-22, queue
# 2026-09-21-6b17b1; derived-band-lib.ps1 has the rule and its constant). A PRE-PASS resolves and prices every row once,
# collects each commodity's per-unit evidence across stores, derives the band, and the loop below reuses the pre-pass
# answers (so the matcher and the pricing math still run once per row). The typed bands are still READ, into
# $TYPED_BANDS, for ONE purpose: out\band-derivation-<date>.json states per commodity what the typed band would have
# admitted and refused against the derived one, so the switch is measured on every build rather than asserted once.
$prePass = New-Object System.Collections.ArrayList
$bandEvidence = New-Object System.Collections.ArrayList
foreach ($d0 in $deals) {
  $c0 = Resolve-Commodity -Matcher $fastMatcher -Name $d0.name
  $u0 = $null
  if ($c0) {
    $u0 = Get-UnitPrice $d0 $c0
    if ($u0 -and [double]$u0.unit_price -gt 0) { [void]$bandEvidence.Add([pscustomobject]@{ id = [string]$c0.id; store = [string]$d0.store; per_unit = [math]::Round([double]$u0.unit_price, 4); name = [string]$d0.name }) }
  }
  [void]$prePass.Add([pscustomobject]@{ d = $d0; c = $c0; up = $u0 })
}
$TYPED_BANDS = @{}; foreach ($k0 in $BANDS.Keys) { $TYPED_BANDS[$k0] = $BANDS[$k0] }
$evArr = $bandEvidence.ToArray()
$DERIVED_BANDS = Get-TcDerivedBands -Rows $evArr -Groups $BAND_GROUPS
# SHADOW MODE, NOT IN FORCE (2026-09-22). Measured on the first switch over comparison-2026-09-22 at K=5: 25 crowns moved,
# and the typed bands turned out to be doing IDENTITY work the derived band cannot: salt | Aldi went to "Clancy's Coconut
# Oil Himalayan Pink Salt Popcorn", jalapenos | Walmart to a jalapeno hummus, butter | Sam's to a butter seasoning,
# cooked-quinoa | Baker's to a smoked-salmon bowl - wrong products the typed band refused by price - while real warehouse
# bulk (Sam's bay leaves, curry powder, thyme, yeast, 50 lb rice) sits more than 5x under the median of small jars and was
# newly REFUSED, the very class the ruling exists to stop. So the derivation runs and reports on every build
# (out\band-derivation-<date>.json) and the typed bands stay in force until the two defects in that measurement have
# owners: identity through excludes, not bands, and a bulk-aware reference. plan-2026-09-22-5, item 6b17b1.
# THE MIGRATION ROAD, IN FORCE: a commodity with NO typed band takes its DERIVED band (before this it had no band at all,
# only the universal floor). So a typed band leaves commodities.json one measured commodity at a time and the commodity
# lands on the derived band, never on nothing. Measured on comparison-2026-09-22 before switching: 20 rows on untyped
# commodities fall outside their derived bands, all on the HIGH side (e.g. "(6 Cans) Libby's Whole Kernel Sweet Corn" at
# 7.90 per can, a pack price read per can). vegetable-oil's typed band was removed in the same change (Brad's founding cell).
# MEASURED AND NARROWED THE SAME DAY: giving EVERY untyped commodity its derived band removed four real cells from the
# rebuild (Sam's bay leaves, curry powder and thyme sit more than 5x under the median of small jars and were refused,
# three crowns went dearer; Family Fare's freeze-dried basil was refused on the high side), so the derived band is in
# force ONLY on a commodity that declares "band": "derived" in commodities.json. vegetable-oil is the first (Brad's
# founding cell, its typed 0.04 floor removed). Every other commodity keeps exactly what it had: its typed band, or none.
# SUPERSEDED THE SAME DAY (Brad's rollout ruling, quoted at the band read above). The two defects named in the shadow note
# got owners before the switch: identity through excludes and wrong-basis rulings (every one of the 28 board cells the
# all-derived arm changed was read, plan-2026-09-22-5), and a bulk-aware reference (the warehouse reference group,
# stores.json). So the derived band is now in force for EVERY commodity with evidence, and the per-commodity "band":
# "derived" opt-in and the TC_DERIVED_BANDS arm are gone. A pinned run (-BandsFile) keeps its frozen typed bands.
$THIN_OVERRIDES_USED = New-Object System.Collections.ArrayList
if (-not $PINNED_BANDS) {
  $BANDS = @{}
  foreach ($k0 in $DERIVED_BANDS.Keys) { $BANDS[$k0] = $DERIVED_BANDS[$k0] }
  foreach ($k0 in $BAND_OVERRIDES.Keys) { if (-not $BANDS.ContainsKey($k0)) { $BANDS[$k0] = $BAND_OVERRIDES[$k0]; [void]$THIN_OVERRIDES_USED.Add($k0) } }
}
$evIds = @{}; foreach ($e0 in $evArr) { $evIds[[string]$e0.id] = 1 + $(if ($evIds.ContainsKey([string]$e0.id)) { $evIds[[string]$e0.id] } else { 0 }) }
$THIN_COMMODITIES = @($evIds.Keys | Where-Object { -not $DERIVED_BANDS.ContainsKey($_) } | Sort-Object)
try {
  $sweep = [ordered]@{}
  foreach ($kk in @(3.0, 4.0, 5.0, 6.0)) {
    $dk = Get-TcDerivedBands -Rows $evArr -K $kk -Groups $BAND_GROUPS
    $na = 0; $nr = 0
    foreach ($e in $evArr) {
      $inT = Test-TcInBand $TYPED_BANDS[[string]$e.id] ([double]$e.per_unit)
      $inD = Test-TcInBand $dk[[string]$e.id] ([double]$e.per_unit) $(if ($BAND_GROUPS.ContainsKey([string]$e.store)) { [string]$BAND_GROUPS[[string]$e.store] } else { 'retail' })
      if ($inD -and -not $inT) { $na++ }; if ($inT -and -not $inD) { $nr++ }
    }
    $sweep[('K=' + $kk)] = [ordered]@{ newly_admitted_rows = $na; newly_refused_rows = $nr }
  }
  $admitted = New-Object System.Collections.ArrayList; $refused = New-Object System.Collections.ArrayList
  foreach ($e in $evArr) {
    $tb = $TYPED_BANDS[[string]$e.id]; $db = $DERIVED_BANDS[[string]$e.id]
    $inT = Test-TcInBand $tb ([double]$e.per_unit); $inD = Test-TcInBand $db ([double]$e.per_unit) $(if ($BAND_GROUPS.ContainsKey([string]$e.store)) { [string]$BAND_GROUPS[[string]$e.store] } else { 'retail' })
    $rowRec = [ordered]@{ id = $e.id; store = $e.store; name = $e.name; per_unit = $e.per_unit; typed = $(if ($tb) { ('' + $tb.min + '-' + $tb.max) } else { 'none' }); derived = $(if ($db) { ('' + $db.min + '-' + $db.max) } else { 'none' }) }
    if ($inD -and -not $inT) { [void]$admitted.Add($rowRec) }
    if ($inT -and -not $inD) { [void]$refused.Add($rowRec) }
  }
  $bdoc = [ordered]@{ date = $today; rule = 'band = [ref / K, ref * K] (warehouse stores: floor ref / (K * W)), ref = median of the retail stores'' cheapest per-unit (>= 3 retail stores) else of every store''s cheapest (>= 3 stores) else median of rows (>= 3 rows) else no band'; K = $script:TcBandK; W = $script:TcBandW
    pinned_typed_bands = $PINNED_BANDS
    evidence_rows = $evArr.Count; derived_commodities = $DERIVED_BANDS.Count; typed_commodities = $TYPED_BANDS.Count; k_sweep = $sweep
    typed_fields_ignored = @($TYPED_FIELDS_IGNORED.ToArray())
    thin_commodities = @($THIN_COMMODITIES | ForEach-Object { [ordered]@{ id = $_; rows = $evIds[$_]; override = $(if ($BAND_OVERRIDES.ContainsKey($_)) { $BAND_OVERRIDES[$_] } else { $null }) } })
    thin_overrides_used = @($THIN_OVERRIDES_USED.ToArray())
    newly_admitted = $admitted.ToArray(); newly_refused = $refused.ToArray() }
  [IO.File]::WriteAllText((Join-Path $OutDir ('band-derivation-' + $(if ((Split-Path $CommoditiesFile -Leaf) -eq 'commodities.json') { '' } else { [IO.Path]::GetFileNameWithoutExtension($CommoditiesFile) + '-' }) + $today + '.json')), ($bdoc | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
  Write-Output ('bands: ' + $(if ($PINNED_BANDS) { 'PINNED typed bands from -BandsFile (' + $TYPED_BANDS.Count + ')' } else { 'derived for ' + $DERIVED_BANDS.Count + ' commodities' }) + ' from ' + $evArr.Count + ' priced rows (K=' + $script:TcBandK + ', W=' + $script:TcBandW + '); ' + $THIN_COMMODITIES.Count + ' thin commodit(y/ies) with no band, ' + $THIN_OVERRIDES_USED.Count + ' band_override(s) in use, ' + $TYPED_FIELDS_IGNORED.Count + ' typed band field(s) ignored; ' + $refused.Count + ' row(s) outside a band (out\band-derivation-' + $today + '.json)')
} catch { Write-Warning ('band-derivation report failed (the derived bands are still in force): ' + $_.Exception.Message) }
foreach ($pp in $prePass) {
  $d = $pp.d
  $c = $pp.c
  if ($IDENT_ON) { [void]$identityRows.Add($d) }
  if (-not $c) { continue }
  $up = $pp.up
  $uprice = $null; $basis = 'UNPRICED'; $note = ''
  if ($up) {
    $uprice = [math]::Round($up.unit_price,4); $basis = $up.basis; $note = $up.note
    # THE PROVENANCE CONTRACT FIRST (2026-09-19, provenance-contract-lib.ps1). A captured row that cannot prove
    # when, where and that it is buyable is WITHHELD before any price rule looks at it: its store falls through to
    # its next row that CAN prove it, or the cell is empty. Flagged and counted, never silent, like every refusal
    # below, so a contract that is too tight reads as findings and a smaller board rather than as nothing.
    $provV = $null
    if (-not $NoProvenanceContract) {
      $provV = Test-CellProvenance -Store ([string]$d.store) -Row $d.prov_row -Kind $(if ($d.prov_kind) { [string]$d.prov_kind } else { 'ad' }) `
        -FileDate ([string]$d.src_date) -SrcFile ([string]$d.src_file) -FileSource ([string]$d.file_source) -Commodity $c `
        -BoardDate ([string]$judge) -MaxAgeDays $MaxPublishAgeDays -Pins $PROV_PINS
      if ([string]$d.prov_kind -eq 'capture') { $ProvJudged[[string]$d.store] = 1 + $(if ($ProvJudged.ContainsKey([string]$d.store)) { $ProvJudged[[string]$d.store] } else { 0 }) }
    }
    if ($provV -and -not $provV.ok) {
      $flagged.Add([pscustomobject]@{ id=$c.id; label=$c.label; store=$d.store; name=$d.name; unit=$c.unit; unit_price=$uprice; band=("provenance=" + $provV.why + ": " + $provV.detail); price_text=$d.price_text; size_text=$d.size_text })
      [void]$ProvWithheld.Add([pscustomobject]@{ id=[string]$c.id; store=[string]$d.store; name=[string]$d.name; why=[string]$provV.why; detail=[string]$provV.detail; as_of=[string]$provV.as_of; unit_price=$uprice; price_type=[string]$d.price_type })
      $uprice = $null; $basis = ('WITHHELD-' + $provV.why)   # the store falls through to a row that can prove itself
    } else {
    # ONE CALL DECIDES WHICH REFUSAL FIRES FIRST (Get-FirstRefusal, above): the piece rule, then the band, the
    # floor and the two pack rules. The branches below are the old chain's bodies, unchanged, keyed on its answer.
    $refusal = Get-FirstRefusal $c.id $c.unit $uprice $d.size_text $d.name $up.pieces ([string]$d.store) $KW_BLOCKS
    if ($refusal -eq 'known-wrong') {
      # AN ADJUDICATED WRONG PRODUCT that another check also refused (see Get-FirstRefusal). Filed under its
      # identity refusal so no reader of flagged-*.json mistakes it for a price the band censored.
      $flagged.Add([pscustomobject]@{ id=$c.id; label=$c.label; store=$d.store; name=$d.name; unit=$c.unit; unit_price=$uprice; band='known-wrong'; price_text=$d.price_text; size_text=$d.size_text })
      $uprice = $null; $basis = 'KNOWN-WRONG'   # refused either way; the store falls through to its next real row
    }
    elseif ($refusal -eq 'piece') {
      # ONE PIECE is too small to be the thing the commodity names - a mini, a single-serve, a snack format.
      # Flagged rather than silently dropped, for the same reason as the two pack rules: a floor set too
      # high has to read as findings, not as a quietly emptier board. Tested FIRST since 2026-09-18 (f90ba6).
      $flagged.Add([pscustomobject]@{ id=$c.id; label=$c.label; store=$d.store; name=$d.name; unit=$c.unit; unit_price=$uprice; band=("min_piece_oz>=$($MINPIECE[[string]$c.id])"); price_text=$d.price_text; size_text=$d.size_text })
      $uprice = $null; $basis = 'WRONG-PIECE-FORM'   # drop from ranking; board still ships via runner-up
    }
    elseif ($refusal -eq 'count-conflict') {
      # The size field's count is not the name's count (or is a sheet/slice count), so the basis is wrong. Flagged,
      # and the store falls through to its next row. No band and no threshold decide it (queue 2026-09-22-8d2ad5).
      $flagged.Add([pscustomobject]@{ id=$c.id; label=$c.label; store=$d.store; name=$d.name; unit=$c.unit; unit_price=$uprice; band=('count-conflict: ' + (Get-EachCountConflict ([string]$d.size_text) ([string]$d.name) $up.pieces)); price_text=$d.price_text; size_text=$d.size_text })
      $uprice = $null; $basis = 'COUNT-CONFLICT'
    }
    elseif ($refusal -eq 'band') {
      $bn = $BANDS[$c.id]
      # band_ref / band_group / band_kind: what the band judged against, so audit-band-refusals can ask whether the refusal is
      # EXPLAINED as a basis error (the band's job) or is hiding a wrong product or a real bargain (Brad, 2026-09-22).
      $bGrp = if ($BAND_GROUPS.ContainsKey([string]$d.store)) { [string]$BAND_GROUPS[[string]$d.store] } else { 'retail' }
      $bLo = if ($bGrp -eq 'warehouse' -and $bn.PSObject.Properties['wmin'] -and $null -ne $bn.wmin) { $bn.wmin } else { $bn.min }
      $flagged.Add([pscustomobject]@{ id=$c.id; label=$c.label; store=$d.store; name=$d.name; unit=$c.unit; unit_price=$uprice; band=("$($bLo)-$($bn.max)"); band_ref=$(if ($bn.PSObject.Properties['reference']) { $bn.reference } else { $null }); band_group=$bGrp; band_kind=$(if ($bn.PSObject.Properties['reference']) { 'derived' } else { 'typed' }); price_text=$d.price_text; size_text=$d.size_text })
      # An out-of-band multibuy is reflected in the multibuy signal too, and SAYS WHICH HALF IT IS (2026-09-25,
      # queue 2026-09-23-9459a1): on a complete basis the band refused a real price (band review owns it, and
      # check-ad-cycles does not page it as a price flag); with an unresolved pack count the capture needs review.
      if (Test-IsMultibuy $d.price_text) {
        $mbHalf = Get-MultibuyRefusalHalf ([string]$basis) ([string]$c.unit)
        $mbWhy = if ($mbHalf -eq 'complete-basis') { "on a complete basis ($basis) - the band refuses a real price; see band review" } else { "with an unresolved pack count ($basis) - review the capture" }
        $mbUnpriced.Add([pscustomobject]@{ id=$c.id; label=$c.label; store=$d.store; name=$d.name; price_text=$d.price_text; regular=$d.regular; size_text=$d.size_text; half=$mbHalf; reason=("priced but OUT-OF-BAND (`$$uprice outside $($bn.min)-$($bn.max)) $mbWhy") })
      }
      $uprice = $null; $basis = 'OUT-OF-BAND'   # bad parse -> drop from ranking
    }
    elseif ($refusal -eq 'floor') {
      # in-band (or band-less) but below the universal per-unit floor -> a dropped-decimal / unit error.
      $flagged.Add([pscustomobject]@{ id=$c.id; label=$c.label; store=$d.store; name=$d.name; unit=$c.unit; unit_price=$uprice; band=("floor>=$($FLOOR[[string]$c.unit])"); price_text=$d.price_text; size_text=$d.size_text })
      $uprice = $null; $basis = 'IMPLAUSIBLE-LOW'   # drop from ranking; board still ships via runner-up
    }
    elseif ($refusal -eq 'pack-cap') {
      # right contents, WRONG PACK FORM for a commodity that is defined by its form (see Test-PackSize).
      # Flagged rather than silently dropped, so a cap set too tight shows up as findings instead of as a
      # quietly emptier board.
      $flagged.Add([pscustomobject]@{ id=$c.id; label=$c.label; store=$d.store; name=$d.name; unit=$c.unit; unit_price=$uprice; band=("max_pack_oz<=$($MAXPACK[[string]$c.id])"); price_text=$d.price_text; size_text=$d.size_text })
      $uprice = $null; $basis = 'WRONG-PACK-FORM'   # drop from ranking; board still ships via runner-up
    }
    elseif ($refusal -eq 'pack-floor') {
      # The same rule from below: a package too SMALL to be the thing the commodity names. FLAGGED, not
      # silently dropped, for the same reason the cap is - a floor set too high must show up as findings
      # rather than as a quietly emptier board.
      $flagged.Add([pscustomobject]@{ id=$c.id; label=$c.label; store=$d.store; name=$d.name; unit=$c.unit; unit_price=$uprice; band=("min_pack_oz>=$($MINPACK[[string]$c.id])"); price_text=$d.price_text; size_text=$d.size_text })
      $uprice = $null; $basis = 'WRONG-PACK-FORM'   # drop from ranking; board still ships via runner-up
    }
    elseif ((-not $NoAisleAdmission) -and ([string]$d.store -eq 'Family Fare') -and ($aisleNo = Get-AisleAdmissionRefusal -CatMap $AisleCatMap -Store ([string]$d.store) -CommodityId ([string]$c.id) -Dept (Get-AisleShelfDept $AisleShelf ([string]$d.product_id) ([string]$d.name)))) {
      # WRONG AISLE (2026-09-11, queue 2026-09-11-62b248). Family Fare itself shelves this product in a department
      # its commodity's category does not allow; aisle-lib.ps1 holds the rule. The founding row was a pizza-SAUCE
      # squeeze bottle, 'Contadina Tmto Bsl Pizza Squz Btl', holding the frozen-pizza cell at $2.99: its
      # abbreviated name carries no type word for any exclude to see, and the store had filed it in
      # pantry/canned_goods. A row with no shelf path is ADMITTED - only a department the store authored can
      # refuse. Flagged rather than silently dropped, like every refusal above, so a department map that is too
      # tight reads as findings and not as a quietly emptier board.
      $flagged.Add([pscustomobject]@{ id=$c.id; label=$c.label; store=$d.store; name=$d.name; unit=$c.unit; unit_price=$uprice; band=("aisle=" + $aisleNo.dept + " (" + $aisleNo.reason + ")"); price_text=$d.price_text; size_text=$d.size_text })
      $AisleRefused.Add([pscustomobject]@{ id=[string]$c.id; store=[string]$d.store; name=[string]$d.name; dept=[string]$aisleNo.dept; unit_price=$uprice })
      $uprice = $null; $basis = 'WRONG-AISLE'   # drop from ranking; board still ships via runner-up
    }    else {
      # RIGHT PRODUCT, NOT ON THE SHELF (see the channel block in instore-lib.ps1). A ship-only or
      # third-party listing is not an in-store price and must not be published as one. Since 2026-09-01
      # this asks the ID-KEYED question rather than the row-keyed one: refusing the 08-31 row of a
      # ship-only product achieves nothing while its pre-field 08-11 row is still standing, and the engine
      # unions 90 days. Flagged rather than silently dropped, so the day this gate starts refusing a
      # store's whole column it shows up as findings and not as a quiet gap.
      $chan = Get-ChannelVerdict -Index $CHANNEL_INDEX -Store ([string]$d.store) -SrcFile ([string]$d.src_file) -ItemId ([string]$d.product_id) -Fulfillment $d.fulfillment -ItemName ([string]$d.name)
      if ($chan.why -eq 'REVIEWED-EXCEPTION') { $channelAllowed++ }
      if (-not $chan.in_store) {
        $flagged.Add([pscustomobject]@{ id=$c.id; label=$c.label; store=$d.store; name=$d.name; unit=$c.unit; unit_price=$uprice; band=("channel=$($chan.why) not in-store"); price_text=$d.price_text; size_text=$d.size_text })
        $channelRefused[[string]$chan.why] = 1 + $(if ($channelRefused.ContainsKey([string]$chan.why)) { $channelRefused[[string]$chan.why] } else { 0 })
        $uprice = $null; $basis = 'NOT-IN-STORE'   # drop from ranking; board still ships via runner-up
      }
    }
    }   # end of the provenance contract's else: the price rules above run only on a row that proved itself
  }
  # SAFETY NET: a recognized multibuy that came back UNPRICED means the capture is incomplete
  # (this is exactly how the Baker's chicken-thighs Buy-1-Get-2 was lost). Surface it loudly.
  if ((-not $up) -and (Test-IsMultibuy $d.price_text)) {
    $mbPc = Resolve-MultibuyPackCount $d
    $why = if (-not $d.regular -or ("" + $d.regular) -eq '') { 'missing regular price - a Buy-N-Get-K needs the "regular retail" number to price' }
           elseif ([string]$c.unit -eq 'each' -and $mbPc.conflict) { ('pack count conflict (' + $mbPc.from + ') - the row states two different counts, so it is refused rather than guessed; an unresolved pack count, review the capture') }
           else { 'has regular but no unit basis - add the pack size (e.g. "12 pk 12 fl oz"), or "lb" for a per-pound item' }
    $mbUnpriced.Add([pscustomobject]@{ id=$c.id; label=$c.label; store=$d.store; name=$d.name; price_text=$d.price_text; regular=$d.regular; size_text=$d.size_text; half='unresolved'; reason=$why })
  }
  # PER-CELL membership (not whole-store): a Hy-Vee row whose price is the PERKS member price is membership-gated
  # just like a Sam's Club cell, so it is excluded from the "cheapest without membership" column. Hy-Vee's regular
  # (non-Perks) prices stay no-membership. Label is Brad's exact wording.
  $perks = ([string]$d.price_text -match '(?i)perks\s*price')
  $memLabel = if ($perks) { 'Perks membership required' } elseif (Test-Membership $d.store) { 'membership' } else { '' }
  $matched.Add([pscustomobject]@{
    id=$c.id; label=$c.label; unit=$c.unit; store=$d.store; name=$d.name; price_type=$d.price_type;
    # size_text through Resolve-CellSizeText (2026-09-10, queue 2026-09-10-d9e085): when Get-UnitPrice priced
    # the row from the NAME's volume it says so in size_override, and the cell must name the quantity it was
    # divided by. bulk still reads the store's own size_text, which is unchanged by this.
    price_text=$d.price_text; size_text=(Resolve-CellSizeText $d.size_text $up); regular=$d.regular; bulk=(Test-Bulk $d.size_text $d.name); membership=((Test-Membership $d.store) -or $perks); member_label=$memLabel;
    # Carry the SOURCE through to the page. Without it build-deals-page cannot tell an ad-backed sale from a
    # one-off price snapshot, so it stamped every sale chip with the store's ad-cycle end date - dressing an
    # undated Aisles Online markdown up as "Sale thru Jul 19". A date we invented is worse than no date.
    source_ad=$d.source_ad; src_date=$d.src_date; ad_from=$d.ad_from; ad_to=$d.ad_to; ad_basis=$d.ad_basis;
    # CAN THIS ROW BE LINKED? Carried as ONE boolean rather than four id fields, because the ranker
    # only ever asks the yes/no question (see the tie-break below) and the projection is built ~40,000
    # times a build. Computed from the SOURCE row: the projection above deliberately drops the id
    # fields, which is why the tie-break silently did nothing the first time it was written - it was
    # reading link_url off a shape that never had it.
    has_identity=[bool]($d.link_url -or $d.item_id -or $d.product_id -or $d.sams_item_id)
    # link / link_source: stamped by Add-Norm from the capture row (PLAN-link-rides-with-price L1).
    link=[string]$d.link; link_source=[string]$d.link_source
    # THE STORE'S OWN PRODUCT ID, carried as ONE string for Select-FreshestCaptureRows' same-product
    # supersession (2026-09-05). Name equality alone leaves a stale row standing whenever a store re-words
    # a listing between captures, and Walmart's July batch names are truncated at 60 chars so they cannot
    # match their own full-name twin. Empty where the capture had no id - the lib then falls back to the
    # exact name, which is what every non-Walmart, non-Sam's row has always used.
    prod_key=(Get-ProdKey $d)
    # THE STORE'S OWN PER-UNIT NUMBER, still raw. Resolved against $f.unit at the emit below, because only
    # there is it known which commodity's unit this row is finally being compared in.
    native_up=$d.native_up; native_up_unit=$d.native_up_unit
    # pu_rounding_pct: the error bar Sam's own cent rounding puts on a DERIVED size, carried from the row so
    # the crown step can ask whether a winner's margin is thinner than its own size's precision.
    # split_from: the whole flyer line this row was cut out of, or '' - provenance for the soundness audit.
    pu_rounding_pct=$d.pu_rounding_pct; split_from=$d.split_from
    # as_of: THE DAY THIS PRICE WAS READ AT THE STORE, as the provenance contract established it (2026-09-19). The
    # board carries it per cell so the page, the audits and the next verifier can see how old a price is instead of
    # inferring it from a file date. '' for flyer rows, which carry their window in ad_from/ad_to instead.
    as_of=$(if ($provV -and [string]$d.prov_kind -eq 'capture') { [string]$provV.as_of } else { '' })
    unit_price=$uprice; basis=$basis; note=$note })
}

# candidates audit file (includes matched-but-UNPRICED deals so the semantic pass can recover / reject them)
$candList = New-Object System.Collections.Generic.List[object]
foreach ($g in ($matched | Group-Object id)) {
  $f = $g.Group[0]
  # price_type added 2026-07-23 so derive-recipe-floors.ps1 can tell an EVERYDAY candidate from a sale -
  # the everyday floor per store is the cheapest everyday-typed candidate, which the comparison row hides
  # whenever a sale is winning that store.
  # src_date added 2026-08-06. The candidates artifact used to drop the ONE field the per-store ranking
  # actually turns on (Select-FreshestCaptureRows filters on src_date), so every auditor reading this file
  # was structurally blind to a freshness EVICTION: a row visible here, cheaper than the board cell, with
  # no way to tell whether it lost on price or was filtered out before price was ever compared. That is how
  # Sam's baby-formula shipped at $1.4445/oz on 2026-08-06 with a real $0.7704/oz row sitting in this file.
  # audit-capture-eviction.ps1 reads it. An artifact that omits the deciding field cannot be audited.
  # prod_key added 2026-09-05, for the same reason src_date was added 2026-08-06: it is a field the
  # per-store ranking turns on (Select-FreshestCaptureRows supersedes an older row by the same product's
  # newer one), so an artifact without it cannot be audited against the rule the engine actually ran.
  $candList.Add([pscustomobject]@{ id=$g.Name; label=$f.label; unit=$f.unit; candidates=@($g.Group | Select-Object store,name,price_text,size_text,regular,unit_price,basis,price_type,src_date,prod_key,as_of) })
}
$candPfx = if ($OutName -eq 'comparison') { 'candidates' } else { "$OutName-candidates" }
(@{ week_of=$today; commodities=$candList } | ConvertTo-Json -Depth 8) | Set-Content (Join-Path $OutDir ("$candPfx-"+$today+".json")) -Encoding UTF8

# ---------------------------------------------------------------- adjudicated-wrong cells, dropped HERE
# known-wrong.json used to be read only by audit-known-wrong.ps1 and guards.ps1, and both of those run
# AFTER the board is built. A ruling could therefore block a publish but never correct a board: the wrong
# cell stayed, the gate went red, and every publish stopped until a human hand-edited a commodity rule.
# That made twenty-two accuracy findings into tripwires instead of fixes. Dropping the row here lets the
# store fall through to its own next-best REAL row, which is what the shopper should have been seeing.
# The matching lives in known-wrong-lib.ps1 and is shared with the audit, so the two can never disagree
# about what a ruling covers. $KW_BLOCKS is loaded above the matching loop (see Get-FirstRefusal).
$kwDropped = 0
if ($KW_BLOCKS.Count) {
  $kept = New-Object System.Collections.Generic.List[object]
  foreach ($m in $matched) {
    if ($m.unit_price -ne $null -and (Test-KnownWrong -Blocks $KW_BLOCKS -CommodityId ([string]$m.id) -Store ([string]$m.store) -ProductName ([string]$m.name))) {
      $kwDropped++
      Write-Output ("  known-wrong: dropped [{0}] {1} '{2}' (unit_price {3}) - already adjudicated wrong; the store falls through to its next-best row" -f $m.store, $m.id, $m.name, $m.unit_price)
      continue
    }
    [void]$kept.Add($m)
  }
  $matched = $kept
}
Write-Output ("known-wrong: $($KW_BLOCKS.Count) active blocked cell(s) in the ruling file, $kwDropped priced row(s) dropped from this board")
Write-Output ("aisle-admission: refused {0} Family Fare row(s) the store shelves outside their commodity's departments; shelf paths indexed for {1} product id(s) and {2} name(s){3}" -f $AisleRefused.Count, $AisleShelf.by_id.Count, $AisleShelf.by_name.Count, $(if ($NoAisleAdmission) { ' - REFUSAL DISABLED by -NoAisleAdmission' } else { '' }))
foreach ($ar in $AisleRefused) { Write-Output ("  aisle-admission: refused [{0}] {1} '{2}' (unit_price {3}) - the store shelves it in '{4}'" -f $ar.store, $ar.id, $ar.name, $ar.unit_price, $ar.dept) }
# THE CHANNEL REFUSAL, COUNTED OUT LOUD. A gate that drops rows silently is indistinguishable from a
# capture that never found them, which is how the whole in-store class stayed invisible for a month.
if ($channelRefused.Count) {
  $parts = @(); foreach ($k in ($channelRefused.Keys | Sort-Object)) { $parts += ("$k=" + $channelRefused[$k]) }
  Write-Output ("in-store channel: " + (($channelRefused.Values | Measure-Object -Sum).Sum) + " priced row(s) refused as not-on-the-shelf (" + ($parts -join ', ') + "); " + $channelAllowed + " row(s) kept by a reviewed exception in instore-channel-allowlist.json")
} else {
  Write-Output "in-store channel: no priced row refused (every matched row either records a shelf channel or has no capture that ever recorded one)"
}
# THE PROVENANCE CONTRACT, COUNTED OUT LOUD, PER STORE AND REASON, WITH ITS DENOMINATOR (measurement.md): rows withheld
# of the captured rows judged. Written to provenance-withheld-<date>.json, one row per withheld row, so what the next
# capture owes is readable rather than inferred from a smaller board.
if ($NoProvenanceContract) {
  Write-Output "provenance contract: OFF (-NoProvenanceContract, a measurement arm) - this board is NOT publishable"
} else {
  foreach ($s in ($ProvJudged.Keys | Sort-Object)) {
    $wh = @($ProvWithheld | Where-Object { $_.store -eq $s })
    $by = @($wh | Group-Object why | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '
    Write-Output ("provenance contract: {0,-12} withheld {1,5} of {2,5} captured row(s) judged (max age {3} d){4}" -f $s, $wh.Count, $ProvJudged[$s], $MaxPublishAgeDays, $(if ($by) { " - $by" } else { '' }))
  }
  $pwPath = Join-Path $OutDir ($(if ($OutName -eq 'comparison') { 'provenance-withheld' } else { "$OutName-provenance-withheld" }) + "-" + $today + ".json")   # per run, like candidates and flagged: the recipe run wrote the staple run's list over
  (@{ board = $today; max_publish_age_days = $MaxPublishAgeDays; judged = $ProvJudged; withheld = @($ProvWithheld) } | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $pwPath -Encoding UTF8
}

# ---------------------------------------------------------------- rank: cheapest per store, then across stores
# WHICH CELLS CARRY SAM'S CENT-ROUNDING, AND WHICH CROWNS IT PUTS IN DOUBT (2026-09-11, queue
# 2026-09-10-c8eb72). Both rules are pricing-math-lib's - Get-CellRoundingPct and Get-RoundingBandTies - so the
# board, the ingest builder and the audit all read one copy, and test-pu-lib can drive them from frozen cases
# without a board. This file used to be where such a rule would have been written, and this estate has already
# paid for the second copy of one.
$report = New-Object System.Collections.Generic.List[object]
foreach ($g in ($matched | Where-Object { $_.unit_price -ne $null } | Group-Object id)) {
  $priced = $g.Group
  # Per store: the FRESHEST capture that covers this commodity wins it outright; only then take that capture's
  # cheapest row. Without this, loading Sam's partial captures together (see the loader) would let a stale-low
  # price from an old capture out-rank today's real price - a worse bug than the coverage gap it fixes.
  # Rows with NO src_date (weekly ads, out\regular\ everyday files) are never filtered out - they are a store's
  # only source and carry no capture-date to compare, so they always stay eligible alongside the newest capture.
  $byStore = $priced | Group-Object store | ForEach-Object {
    $rows = Select-FreshestCaptureRows $_.Group
    # A TIE GOES TO THE ROW WE CAN LINK (2026-08-22). Price first, exactly as before - this changes no
    # cell's price and cannot make the board dearer. It only decides what happens when two rows cost
    # the SAME per unit, where the order was previously whatever the group happened to yield.
    # Measured the day it shipped: Aldi pancake-mix had
    #     Millville Complete Buttermilk Pancake & Waffle Mix  $1.95/32 oz  (08-15, no link)
    #     Aunt Maple's Buttermilk Pancake Mix 32 OZ           $1.95/32 oz  (08-22, linked)
    # - identical price and size, and the unlinkable one won, so the tile carried a link to a
    # different brand and audit-tile-integrity hard-failed the publish on brand-mismatch.
    # An unlinked row cannot be verified against the shelf, cannot be re-found, and gives the reader
    # nowhere to click. Between two prices that are equal in every way we can measure, the one we can
    # stand behind should win. Sorting is stable, so rows that are equal on both keys keep their
    # previous relative order.
    # AND A TIE ON BOTH OF THOSE GOES TO THE SMALLER PACKAGE (2026-08-31). A case pack ties its own single
    # unit on per-unit price by construction - twelve jars at one price each cost the same per ounce as one
    # jar - so whenever a store lists both, the contest between them was decided by group order alone.
    # Measured the day it shipped: harissa-paste at Walmart had
    #     (12 pack) Mina, Harissa Spicy Moroccan Red Pepper Sauce, 10 Fl oz   $59.76 / 120 oz
    #     Mina, Harissa Spicy Moroccan Red Pepper Sauce, 10 Fl oz              $4.98 /  10 oz
    # - both exactly $0.498/oz, and the CASE won, so the board told a reader the cheapest harissa in Omaha
    # was a $59.76 purchase and two recipes were billed the whole case (see the cheapest-is-per-unit-not-
    # per-purchase class). Between two prices equal in every way we can measure, the one that costs the
    # shopper less to walk out with should win. Third key on purpose: it cannot move a price, cannot
    # outrank the linkability tie-break above, and only speaks where both were already silent.
    # An unreadable size sorts last - we cannot claim a package is smaller when we cannot read it.
    Select-StoreWinner $rows
  }
  $ranked = @(Select-CrossStoreRank $byStore)
  if ($ranked.Count -lt $MinStores) { continue }
  $f = $priced[0]
  $nm = @($ranked | Where-Object { -not $_.membership } | Select-Object -First 1)
  # A CROWN WON BY LESS THAN ITS OWN SIZE'S PRECISION IS NOT A CROWN (2026-09-11, queue 2026-09-10-c8eb72).
  # The winner here can be a Sam's row whose size is a price quotient, and the board used to rank that
  # quotient as an exact number. Live case: bbq-sauce, Sam's "Sweet Baby Ray's Original Barbecue Sauce, 1
  # gal." at $0.07/oz over Walmart's $0.0743 - a 6% margin decided by a size with a 7.1% error bar. Sam's own
  # arithmetic proves only that the jug weighs more than 159.73 oz and at most 184.31 oz (11.98/size rounds to
  # $0.07 nowhere else), so the true per-oz is somewhere in [0.0650, 0.0750) and Walmart's 0.0743 is INSIDE
  # it. The jug's net weight is in no artifact here and the Sam's PDP answers a bot wall, so the honest act is
  # to SAY SO rather than to pick a winner.
  # THE CROWN IS NOT REASSIGNED, deliberately: the runner-up is not proven cheaper either, and handing it the
  # crown would publish the opposite unproven claim. Each store keeps its own printed unit price; the
  # commodity gains a flag, audit-unit-basis-outlier lists it, and how the page SHOWS a tie is Brad's ruling
  # brad-2026-09-11-rounding-tie. Until then nothing visible changes.
  $tieWith = Get-RoundingBandTies $ranked[0] (@($ranked | Select-Object -Skip 1))
  $tieWith = @($tieWith)
  $withinRounding = ($tieWith.Count -gt 0)
  $report.Add([pscustomobject]@{
    commodity = $f.label; id=$g.Name; unit=$f.unit
    cheapest_store = $ranked[0].store
    cheapest_price = $ranked[0].unit_price
    cheapest_type = $ranked[0].price_type
    # Emitted on EVERY row, true or false, because it is a verdict computed for every row: an absent field
    # would let "we did not look" read as "we looked and it was clean", which is the one reading this estate
    # refuses. cheapest_tie_with is empty unless the flag is true.
    cheapest_within_rounding = $withinRounding
    cheapest_tie_with = $tieWith
    nomem_store = $(if($nm.Count){$nm[0].store}else{$null})
    nomem_price = $(if($nm.Count){$nm[0].unit_price}else{$null})
    nomem_type  = $(if($nm.Count){$nm[0].price_type}else{$null})
    # ad_from / ad_to ON THE CELL (2026-08-21). This is the field build-sale-windows needs in order to
    # date a sale from the deal that actually won the cell instead of from the store's one ad cycle.
    # Emitted for every cell; empty on an everyday cell, which is correct - an everyday price has no
    # window and must never be given one.
    # native_unit_price / native_unit: THE STORE'S OWN per-unit number for THIS row, in THIS commodity's
    # unit, or absent. Emitted only when the store's unit and the commodity's unit are the same family
    # (lb converts to oz; everything else that disagrees emits nothing, because a per-each price against
    # a per-ounce commodity is a different question, not a disagreement). sanity-check.ps1 reads it: an
    # outlier the store's own arithmetic reproduces is recorded as outlier-verified instead of paging.
    # ABSENT MEANS UNPROVEN, NEVER AGREEING - Aldi, Baker's, Fareway, Family Fare and Hy-Vee publish no
    # unit price, so their outliers stay ordinary outliers and keep paging.
    stores = @($ranked | ForEach-Object {
      $nat = Resolve-NativeUnitPrice $_.native_up ([string]$_.native_up_unit) ([string]$f.unit)
      $row = [ordered]@{ store=$_.store; per_unit=$_.unit_price; unit=$f.unit; type=$_.price_type; bulk=$_.bulk; membership=$_.membership; member_label=$_.member_label; item=$_.name; ad=$_.price_text; size=$_.size_text; basis=$_.basis; note=$_.note; source_ad=$_.source_ad; ad_from=$_.ad_from; ad_to=$_.ad_to; ad_basis=$_.ad_basis; as_of=[string]$_.as_of }
      if ($nat) { $row['native_unit_price'] = $nat.price; $row['native_unit'] = $nat.unit }
      # link / link_source (PLAN-link-rides-with-price L1): the price's own product link, from the row that set it.
      # row = that product; none = a storefront row with no identity (capture defect); ad = a flyer line, which Brad's
      # D1 ruling says the system must still resolve to a product. link is absent unless source is row.
      if ([string]$_.link_source) { $row['link_source'] = [string]$_.link_source }
      if ([string]$_.link) { $row['link'] = [string]$_.link }
      # deal_qty / deal_condition: the quantity condition this per-unit was priced under (Brad's ruling on a2af45,
      # 2026-09-22: the deal IS the price and the condition is SHOWN). Absent means the price holds for one unit.
      $null = Add-TcDealConditionFields $row ([string]$_.price_text) ([string]$_.note)
      # pu_rounding_pct: this cell's per-unit was divided by a size Sam's cent rounding produced, so it is
      # only exact to +/- this percent. Emitted ONLY where it is true of the number shown (see
      # Get-CellRoundingPct), and absent everywhere else - no other store's size is a quotient.
      $rp = Get-CellRoundingPct $_
      if ($null -ne $rp) { $row['pu_rounding_pct'] = $rp }
      # split_from: the whole two-product flyer line this row was cut out of, so a reader of the board can
      # see the ad said "A or B" and this cell is the A half.
      if ([string]$_.split_from) { $row['split_from'] = [string]$_.split_from }
      [pscustomobject]$row
    })
  })
}
$report = @($report | Sort-Object commodity)

# ---------------------------------------------------------------- health + flagged (drive the automation alert)
$flagPfx = if ($OutName -eq 'comparison') { 'flagged' } else { "$OutName-flagged" }
# COULD-NOT-LOOK (2026-09-19, backlog I183/I209). A product name the matcher could not decide inside its regex
# bound was left off the board exactly like an unmatched one - but it is NOT unmatched, and a missing cell nobody
# can see is how a hang turns into a quietly thinner board. It rides the flagged file, which check-ad-cycles
# pages as review flags, and the health block. Expected empty: the 2026-09-19 corpus of 42,753 names had none.
$matchBlind = Get-CommodityMatcherBlind -Matcher $fastMatcher
$matchBlindRows = @($matchBlind.could_not_look | ForEach-Object { [pscustomobject]@{ name = $_.name; commodity = $_.commodity; kind = $_.kind; looks = $_.looks } })
(@{ week_of=$today; flagged_count=$flagged.Count; flagged=$flagged.ToArray(); multibuy_unpriced=$mbUnpriced.ToArray(); match_could_not_look=$matchBlindRows } | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $OutDir ("$flagPfx-"+$today+".json")) -Encoding UTF8
$storesWithData = @($matched | Where-Object { $_.unit_price -ne $null } | ForEach-Object { $_.store } | Select-Object -Unique | Sort-Object)
$health = [ordered]@{ stores_with_data=$storesWithData; store_count=$storesWithData.Count; commodities_compared=$report.Count; flagged_out_of_band=$flagged.Count; multibuy_unpriced=$mbUnpriced.Count; match_could_not_look=$matchBlindRows.Count; match_timeouts=$matchBlind.timeouts; match_timeout_ms=$matchBlind.timeout_ms; expired_sale_rows_dropped=$script:ExpiredSaleRows; nameless_rows_dropped=$script:NamelessRows; nameless_rows_by_store=(Format-TcNamelessByStore $script:NamelessRowsByStore); sale_windows_inherited_from_ads=$script:AdInherited; sale_windows_from_ttl=$script:TtlDated; sale_windows_from_store_countdown=$script:StoreCountdown; rollbacks_split=$script:RollbackSplit; rollbacks_with_revert=$script:RollbackRevert; judged_on=$judge }

# ---------------------------------------------------------------- output
# provenance_contract / max_publish_age_days: whether this board was built under the provenance contract, and at what
# age limit. guards.ps1 refuses to publish a board that says OFF (the -NoProvenanceContract measurement arm).
$out = [ordered]@{ built_at=(Get-Date).ToString('s'); week_of=$today; judged_on=$judge; source=$AdsFile; commodities_compared=$report.Count; provenance_contract=$(if ($NoProvenanceContract) { 'OFF' } else { 'on' }); max_publish_age_days=$MaxPublishAgeDays; health=$health; comparison=$report }
$file = Join-Path $OutDir ($OutName + "-" + $today + ".json")
($out | ConvertTo-Json -Depth 8) | Set-Content $file -Encoding UTF8

# PERSIST THE TTL ANCHORS, or the whole mechanism is a no-op that looks like it works.
# Get-RollbackWindow records first_seen in memory; without this write it is discarded at process
# exit, every build re-anchors every markdown to ITS OWN run date, and a 30-day TTL silently becomes
# a rolling 30-days-from-now that never expires. That is precisely the failure rollback-ttl-lib's
# must-fire fixture exists to catch, reintroduced one layer up by simply not saving.
# Caught because the ledger file was absent after a build that dated 372 cells from it.
try { [void](Save-RollbackLedger $root) } catch { Write-Warning ('rollback ledger not saved (' + $_.Exception.Message + ') - TTL anchors will re-date on the next build') }

Write-Output ("CHEAPEST IN OMAHA  -  week of " + $today + "   (commodities with >= $MinStores stores: " + $report.Count + ")")
Write-Output ("=" * 78)
foreach ($row in $report) {
  $u = $row.unit
  Write-Output ""
  $nmtxt = if ($row.nomem_store -and ($row.nomem_store -ne $row.cheapest_store)) { ('   |  no-membership: {0} ${1}' -f $row.nomem_store, ('{0:N2}' -f $row.nomem_price)) } else { '' }
  Write-Output ('{0}  ->  cheapest: {1} ${2}/{3} ({4}){5}' -f $row.commodity, $row.cheapest_store, ('{0:N2}' -f $row.cheapest_price), $u, $row.cheapest_type, $nmtxt)
  foreach ($s in $row.stores) {
    $mk = ''
    if ($s.membership) { $mk += '(member) ' }
    if ($s.bulk) { $mk += '(bulk) ' }
    Write-Output ('    {0,-13} ${1,-8}/{2,-6} {3,-10} {4}{5}' -f $s.store, ('{0:N2}' -f $s.per_unit), $u, ('['+$s.type+']'), $mk, ($s.item.Substring(0,[math]::Min(40,$s.item.Length))))
  }
}
if ($mbUnpriced.Count -gt 0) {
  Write-Output ""
  Write-Output ("!! MULTIBUY UNPRICED: " + $mbUnpriced.Count + " Buy-N-Get-K deal(s) recognized but NOT priced - fix the capture, do not publish as-is:")
  foreach ($m in $mbUnpriced.ToArray()) { Write-Output ("   [" + $m.label + "] " + $m.store + ": '" + $m.price_text + "' - " + $m.reason) }
}
if ($matchBlindRows.Count -gt 0 -or $matchBlind.timeouts -gt 0) {
  Write-Output ""
  Write-Output ("!! MATCHER COULD-NOT-LOOK: " + $matchBlindRows.Count + " product name(s) left off the board UNDECIDED, " + $matchBlind.timeouts + " regex match(es) hit the " + $matchBlind.timeout_ms + " ms bound - NOT 'no commodity'. Fix the include named below (an ambiguous pattern backtracks):")
  foreach ($q in @($matchBlind.quarantined)) { Write-Output ("   QUARANTINED  [" + $q.commodity + "/" + $q.kind + "] " + $q.pattern) }
  foreach ($x in @($matchBlindRows | Select-Object -First 10)) { Write-Output ("   [" + $x.commodity + "/" + $x.kind + "] '" + ([string]$x.name).Substring(0, [Math]::Min(80, ([string]$x.name).Length)) + "'") }
}
Write-Output ""
Write-Output ("Saved: " + $file)

# ---------------------------------------------------------------- THE WIDE PRICE TABLE (2026-08-21)
# Brad's model: one row per ITEM, carrying every store's everyday price, ad price and ad window as
# columns, and pages show the cheaper of the two. When the ad's window closes the ad column nulls out
# and the everyday price returns BY ARITHMETIC - no re-capture needed. Under the 90-day carry that is
# the difference between a finished sale falling off by itself and one publishing for a quarter.
#
# BUILT HERE, NOT IN A SEPARATE PASS, and that is the load-bearing decision. Every price in the table
# is chosen from the SAME $priced rows by the SAME Select-FreshestCaptureRows the ranking above used.
# A standalone builder reading comparison-*.json could only ever see the ONE winning row per store,
# so it could not know the everyday price behind a sale cell - and a builder re-reading the candidate
# pool would be a second implementation of "which row wins", which is precisely how a table and the
# board it describes drift while both look correct.
# The parity check below then proves, per cell, that they still agree.
. (Join-Path $PSScriptRoot 'price-table-lib.ps1')
$ptRows = New-Object System.Collections.Generic.List[object]
foreach ($g in ($matched | Where-Object { $_.unit_price -ne $null } | Group-Object id)) {
  $f0 = $g.Group[0]
  # -Pick is the board's OWN per-store rule, so a price-tie inside one store resolves to the product the board
  # shows rather than to whatever 5.1's unstable sort yields (backlog I175).
  [void]$ptRows.Add((Build-PriceTableRow -Id $g.Name -Commodity ([string]$f0.label) -Unit ([string]$f0.unit) -Rows $g.Group -Today $judge -Pick ${function:Select-StoreWinner}))
}
$ptTable = @($ptRows | Sort-Object id)
$ptStoreOrder = @('Hy-Vee', 'Aldi', 'Family Fare', 'Fareway', "Baker's", "Sam's Club", 'Walmart')
$ptDoc = [ordered]@{
  week_of = $today
  built_at = (Get-Date).ToString('s')
  note = 'WIDE price table, one row per item. Per store: everyday price, ad price, and the ad window. ad is NULL when the item is not on ad - Brad''s founding rule - and an ad whose ad_to has passed is nulled at build time rather than cleaned up later. `shown` is the cheaper of the two, which is what a page must display. Derived from the same candidate rows and the same eligibility rule the board ranks with; price-table-parity proves they agree per cell.'
  stores = $ptStoreOrder
  rows = $ptTable.Count
  items = $ptTable
}
$ptFile = Join-Path $OutDir (($(if ($OutName -eq 'comparison') { 'price-table' } else { "$OutName-price-table" })) + '-' + $today + '.json')
[IO.File]::WriteAllText($ptFile, ($ptDoc | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
# The CSV is a RENDERING of the JSON, regenerated every build, never authored - so the two cannot
# disagree about a price the way two hand-maintained files would.
$ptCsv = ConvertTo-PriceTableCsv -Table $ptTable -StoreOrder $ptStoreOrder
$ptCsvFile = [IO.Path]::ChangeExtension($ptFile, 'csv')
[IO.File]::WriteAllText($ptCsvFile, $ptCsv, (New-Object System.Text.UTF8Encoding($false)))

$ptCells = 0; $ptWithAd = 0; $ptWithEv = 0; $ptBoth = 0
foreach ($r in $ptTable) {
  foreach ($k in $r.stores.Keys) {
    $ptCells++
    $c = $r.stores[$k]
    if ($null -ne $c.ad) { $ptWithAd++ }
    if ($null -ne $c.everyday) { $ptWithEv++ }
    if ($null -ne $c.ad -and $null -ne $c.everyday) { $ptBoth++ }
  }
}
Write-Output ("price-table: {0} item(s), {1} store cell(s) - {2} carry an everyday price, {3} carry a LIVE ad, {4} carry both" -f $ptTable.Count, $ptCells, $ptWithEv, $ptWithAd, $ptBoth)
# PARITY, EVERY BUILD, NOT ON A SCHEDULE. A table that disagrees with the board it describes is worse
# than no table, because it will be believed. This is cheap and it is the only thing standing between
# "derived from the same rows" and "actually still the same answer".
$ptBad = @(Test-PriceTableParity -Table $ptTable -Comparison ([pscustomobject]@{ comparison = $report }))
if ($ptBad.Count) {
  Write-Output ("!! PRICE-TABLE PARITY: {0} cell(s) disagree with the published board - the table and the ranker have drifted:" -f $ptBad.Count)
  foreach ($b in ($ptBad | Select-Object -First 12)) { Write-Output ("   [{0}] {1}: {2}" -f $b.id, $b.store, $b.why) }
} else {
  Write-Output ("price-table: parity OK - every one of the {0} cell(s) matches the price the board published" -f $ptCells)
}
Write-Output ("Saved: " + $ptFile)
Write-Output ("Saved: " + $ptCsvFile)

# ---------------------------------------------------------------- THE PRODUCT IDENTITY TABLE (2026-08-22)
# PLAN-product-identity step 1. The engine has always known which commodity owns which product; it has
# never written it down. Twenty other scripts therefore carry their own copy of the decision - two of them
# HARD gates - and the daily chain recomputes a stable answer about twenty times. This block emits the
# answer as a first-class, git-tracked artifact so everything downstream can be a lookup.
#
# IT RUNS AFTER THE BOARD IS WRITTEN, ON PURPOSE. The board is the product; the table describes it. A
# crash in here must never cost today's prices, so it is wrapped and reported rather than thrown - and the
# failure is not silent, because a table left at yesterday's rules_hash is exactly what the parity gate in
# guards.ps1 reports (section 10.7: an absent or stale row is BLIND, never a pass).
if ($IDENT_ON) {
  try {
    if (@('staple', 'recipe') -notcontains $IdentityNamespace) {
      throw ("-IdentityNamespace must be 'staple' or 'recipe' (got '" + $IdentityNamespace + "'). Section 10.20: feed ingredient ids are costed by bid through meal-prep, not matched, so there is no third namespace to invent.")
    }
    . (Join-Path $PSScriptRoot 'identity-lib.ps1')
    $idSw = [Diagnostics.Stopwatch]::StartNew()
    $rulesHash = Get-IdentityRulesHash -GroceryRoot $root

    # ---- pass 1: which product ids are AMBIGUOUS today -------------------------------------------
    # A store id is supposed to name one product, but a capture union can carry the same id under two
    # different normalised names (an ad title and a catalog title, a renamed listing carried forward).
    # Keying those on the id would make the row's meaning depend on iteration order, and the parity gate
    # joins a board cell by NAME - so an id whose names disagree is demoted to name keys for this run and
    # counted. Measured, not assumed: the count is printed and lands in the manifest.
    # Get-MatchTexts is memoised across BOTH passes: the same normalisation would otherwise run twice
    # for every one of ~40,000 rows, which measured ~2.5s of pure repetition on a warm run.
    $nameKeyCache = @{}
    $idNames = @{}
    foreach ($d in $identityRows) {
      $sid = [string]$d.product_id
      if (-not $sid) { continue }
      $nm0 = [string]$d.name
      if (-not $nameKeyCache.ContainsKey($nm0)) { $nameKeyCache[$nm0] = (Get-MatchTexts $nm0)[1] }
      $nk = $nameKeyCache[$nm0]
      $k = ([string]$d.store + '|' + $sid)
      if (-not $idNames.ContainsKey($k)) { $idNames[$k] = @{} }
      $idNames[$k][$nk] = $true
    }
    $ambiguous = @{}
    foreach ($k in $idNames.Keys) { if ($idNames[$k].Count -gt 1) { $ambiguous[$k] = $true } }

    # ---- pass 2: one current row per (store, key) -------------------------------------------------
    # Previous tables are read per store and consulted for REUSE. A stored row is still today's answer
    # only when BOTH the rules hash matches AND the stored name_key equals the name the rules would see
    # now (section 10.3): a Kroger product_id is stable across a size or label variant, and the rules
    # match the NAME, so a hash check alone would keep an assignment made for a different product.
    # Sub-timings are printed, not inferred. This block sits on the ship path, and "the identity table
    # cost N seconds" is useless for deciding what to fix; read/match/write separately is not.
    $tRead = [double]0; $tMatch = [double]0
    $detailCache = @{}
    $prevByStore = @{}
    $rowsByStore = @{}
    $seenByStore = @{}
    $reusedByStore = @{}
    $reused = 0; $rematched = 0; $contested = 0; $identityBlind = 0
    foreach ($d in $identityRows) {
      $store = [string]$d.store
      if (-not $prevByStore.ContainsKey($store)) {
        $swR = [Diagnostics.Stopwatch]::StartNew()
        $prevByStore[$store] = Read-IdentityTable -GroceryRoot $root -Namespace $IdentityNamespace -Store $store
        $tRead += $swR.Elapsed.TotalSeconds
        $rowsByStore[$store] = New-Object System.Collections.Generic.List[object]
        $seenByStore[$store] = @{}
      }
      $name = [string]$d.name
      if (-not $nameKeyCache.ContainsKey($name)) { $nameKeyCache[$name] = (Get-MatchTexts $name)[1] }
      $nameKey = $nameKeyCache[$name]
      $sid = [string]$d.product_id
      if ($sid -and $ambiguous.ContainsKey($store + '|' + $sid)) { $sid = '' }
      $kk = Get-IdentityKey -ProductId $sid -NameKey $nameKey
      if ($seenByStore[$store].ContainsKey($kk.key)) { continue }   # first row wins; the key is the row
      $seenByStore[$store][$kk.key] = $true

      $prev = $prevByStore[$store][$kk.key]
      $firstSeen = $(if ($prev -and $prev.first_seen) { [string]$prev.first_seen } else { [string]$judge })
      if ($prev -and [string]$prev.rules_hash -eq $rulesHash -and [string]$prev.name_key -eq $nameKey) {
        # REUSE. This is what makes daily work proportional to NEW products rather than to the catalog.
        $reused++
        $reusedByStore[$store] = [int]$reusedByStore[$store] + 1
        [void]$rowsByStore[$store].Add($prev)
        if (@($prev.candidates).Count) { $contested++ }
        continue
      }
      $rematched++
      if (-not $detailCache.ContainsKey($name)) {
        $swM = [Diagnostics.Stopwatch]::StartNew()
        $detailCache[$name] = Resolve-CommodityDetail -Matcher $fastMatcher -Name $name
        $tMatch += $swM.Elapsed.TotalSeconds
      }
      $det = $detailCache[$name]
      # A COULD-NOT-LOOK IS NOT WRITTEN. A stored row with commodity = $null means "no commodity owns this under
      # these rules" and is REUSED next run while the rules hash holds, so writing one here would settle the
      # question nobody could answer. Left out, the key is simply matched again next run. (I183/I209)
      if ($det.could_not_look) { $identityBlind++; continue }
      $cid = $(if ($det.commodity) { 'commodity:' + $IdentityNamespace + ':' + [string]$det.commodity.id } else { $null })
      if (@($det.candidates).Count) { $contested++ }
      [void]$rowsByStore[$store].Add([pscustomobject]@{
        store = $store
        key = $kk.key
        key_kind = $kk.key_kind
        name = $name
        name_key = $nameKey
        size = [string]$d.size_text
        namespace = $IdentityNamespace
        commodity = $cid            # $null = no commodity owns this product under these rules
        how = 'rule'
        include_hit = [string]$det.include_hit
        include_hit_ix = [int]$det.include_hit_ix
        excludes_tested = [int]$det.excludes_tested
        candidates = @($det.candidates)
        rules_hash = $rulesHash
        first_seen = $firstSeen
      })
    }

    # ---- write, atomically, and only where the bytes moved ---------------------------------------
    $storeSummary = New-Object System.Collections.Generic.List[object]
    $changedFiles = 0
    $swW = [Diagnostics.Stopwatch]::StartNew()
    foreach ($store in ($rowsByStore.Keys | Sort-Object)) {
      $n = $rowsByStore[$store].Count
      # PROVABLY UNCHANGED, so do not re-serialise 35,000 rows to find that out. Every row of this store
      # came back from the previous table AND the row count is the same, so the key SET is the same, the
      # sort is the same, and each row serialises to the bytes it was read from (the round-trip is what
      # the "0 changed" run already demonstrates). A REMOVED product changes the count, so a shrinking
      # table still goes through the full write. This is what keeps a quiet morning near zero cost.
      if ($n -gt 0 -and [int]$reusedByStore[$store] -eq $n -and $prevByStore[$store].Count -eq $n) {
        $storeSummary.Add([pscustomobject]@{ store = $store; rows = $n; changed = $false })
        continue
      }
      $res = Save-IdentityTable -GroceryRoot $root -Namespace $IdentityNamespace -Store $store -Rows $rowsByStore[$store]
      if ($res.changed) { $changedFiles++ }
      $storeSummary.Add([pscustomobject]@{ store = $store; rows = $res.rows; changed = $res.changed })
    }
    # -BoardDate here is the ad set, recorded as a LABEL that pairs the manifest with its board; it computes no age.
    $null = Save-IdentityManifest -GroceryRoot $root -Namespace $IdentityNamespace -RulesHash $rulesHash -BoardDate ([string]$today) -Stores $storeSummary -Reused $reused -Matched $rematched -Contested $contested -IdCollisions $ambiguous.Count   # board-clock:allow a label pairing the manifest with its board, never an age
    $tWrite = $swW.Elapsed.TotalSeconds
    $idSw.Stop()
    $idRowTotal = 0
    foreach ($s in $storeSummary) { $idRowTotal += [int]$s.rows }
    Write-Output ("identity[{0}]: {1} row(s) across {2} store file(s) ({3} changed) - {4} reused at rules_hash {5}, {6} re-matched, {7} contested, {8} ambiguous product id(s) demoted to name keys" -f `
      $IdentityNamespace, $idRowTotal, $storeSummary.Count, $changedFiles, $reused, $rulesHash.Substring(0, 12), $rematched, $contested, $ambiguous.Count)
    Write-Output ("identity[{0}]: {1:N1}s total - read {2:N1}s, match {3:N1}s, write {4:N1}s" -f $IdentityNamespace, $idSw.Elapsed.TotalSeconds, $tRead, $tMatch, $tWrite)
    if ($identityBlind -gt 0) { Write-Output ("!! identity[{0}]: {1} product key(s) NOT written because the matcher could not decide them inside its bound - they are re-matched next run, never stored as unmatched" -f $IdentityNamespace, $identityBlind) }
  } catch {
    # LOUD, NOT FATAL. The board is already written and correct; what is now wrong is the table, and the
    # honest consequence is that it stays at its previous rules_hash - which is precisely the state the
    # parity gate reports as BLIND rather than as agreement.
    # WITH THE LINE NUMBER. A bare .Message on a PowerShell runtime error is frequently unlocatable
    # ("Argument types do not match", "Value cannot be null") and this block is 100 lines long.
    Write-Output ("!! identity[" + $IdentityNamespace + "]: the identity table was NOT updated this run - " + $_.Exception.Message + " (compare-deals.ps1 line " + $_.InvocationInfo.ScriptLineNumber + ")")
    Write-Output ("   The board is unaffected. guards' parity gate will report this as stale/BLIND until the table is rebuilt.")
  }
}

# ---------------------------------------------------------------- THE INPUT LEDGER (2026-08-21)
# -IsLiveBuild only when this run built the PUBLISHED board. A regression or fixture run reads a PINNED
# set of inputs, and stamping those would mark files the live board has not touched in weeks as alive -
# worse than no record, because it reads as evidence. $OutName is the honest test: every pinned harness
# passes its own name so its artifacts do not collide with the real ones.
$liveBuild = ($OutName -eq 'comparison') -and (-not $RegularDir) -and (-not $ExtraDir)
$iuCount = Save-InputUsage -Tracker $inputUsage -OutDir $OutDir -Today $judge -IsLiveBuild:$liveBuild
if ($iuCount -ge 0) {
  Write-Output ("input-usage: recorded {0} file(s) this build -> {1}" -f $iuCount, (Join-Path $OutDir 'input-usage.json'))
} else {
  Write-Output "input-usage: NOT recorded (this is a pinned/regression run, not the live board)"
}
