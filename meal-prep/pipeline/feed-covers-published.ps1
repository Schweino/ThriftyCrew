# feed-covers-published.ps1 - refuses to let a recipe be live on the site while the feed its own card
# fetches cannot price it.
#
# WHY THIS EXISTS (2026-08-15). Every recipe card fetches its live prices at view time. Until today that
# fetch was /api/v2/recipe-feed/<slug>?contract=4, served by the V3 platform deleted on 2026-08-14. It did
# not fail cleanly. It kept answering from a STORED release, so it returned 200 with frozen prices for any
# recipe that existed when that release was minted, and 404 for every recipe published after it. Two
# recipes published on 2026-08-15 rendered "current release price loading" twice and an EMPTY cost section,
# and had to be set back to draft. They were complete, audited GO, and in the database. Nothing failed at
# publish time; the pages were simply wrong once a reader opened them.
#
# THE HOLE THAT LET IT THROUGH is that publishing and pricing were checked separately. publish.ps1 proved
# the post went up and verified its bytes. audit-db-agreement proved the two masters agreed. Neither asked
# the only question that matters to a reader: can the feed this card will fetch actually price this recipe?
# Nobody owned that question, so it was answered at post-publish review instead of at publish.
#
# WHAT IT CHECKS, per recipe that is PUBLISHED (present in db\published-hashes.json):
#   1. the slug resolves in the feed's `recipes` map. The cards no longer key on slug - smp-feed is one
#      file for the whole catalogue, which is why the 404 class cannot recur - but the Meal Plan Builder,
#      the top-5 tool and the free-dinner rotation all resolve by slug, so a missing slug is still a live
#      defect on those surfaces. This is the check that fires for the two recipes above.
#   2. every board commodity id its card carries resolves in `ingredients`. Without it the receipt has no
#      store, no unit and no link for that line.
#   3. every one of those ids ALSO resolves in `pricing_inputs`, with a usable current per-unit price.
#      This is the one that actually protects the cost section: `ingredients` carries a per-unit price and
#      `pricing_inputs` carries the whole-package basis, and the card cannot price a line without both. A
#      bid present in one and absent from the other reads as covered on any count-based check and still
#      renders "Price unavailable in this release" to the reader.
#
# The bids are read from the BUILT CARD (db\built\<slug>.body.html), not from the spec, deliberately. The
# card's baked smp-sc-data is the exact list the browser will look up; a spec-derived list would be
# checking a different question from the one the reader asks.
#
# WHICH FEED. Default is the estate's canonical feed on disk (grocery\out\smp-feed.json) - the one the next
# deploy will publish - so this runs inside the publish chain with no network and refuses BEFORE a recipe
# goes live. -Live fetches the deployed URL instead, which is the right mode for a daily gate: it answers
# "is what readers are fetching right now covering what is actually published", a question the local file
# cannot answer if a deploy failed.
#
# Exit codes follow the estate contract: 0 clean, 1 findings, 2 hard, 3 could-not-evaluate.
# Self-test:  powershell -File meal-prep\pipeline\feed-covers-published.ps1 -SelfTest
param(
  [string]$FeedPath = '',
  [switch]$Live,
  [string[]]$Slugs,
  [switch]$SelfTest,
  [string]$Root = ''
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = if ($Root) { $Root } else { Split-Path -Parent $here }
$repo = Split-Path $mp -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

$FEED_URL = 'https://feed.thriftycrew.com/smp-feed.json'

# Pull the bid list out of a built card the same way the browser will: the baked smp-sc-data block.
# Returns $null when the card has no scaler block at all, which is a DIFFERENT finding from "no bids" -
# a card with no cost section is not a card this guard has anything to say about.
function Get-CardBids {
  param([string]$Html)
  $m = [regex]::Match($Html, '<script type="application/json" class="smp-sc-data">(.*?)</script>', 'Singleline')
  if (-not $m.Success) { return $null }
  try { $d = $m.Groups[1].Value | ConvertFrom-Json } catch { return $null }
  $out = New-Object System.Collections.Generic.List[string]
  # `if ($b)` alone is not the test: a whitespace-only bid is TRUTHY in PowerShell, so "   " was
  # collected as a real commodity id, looked up in the feed, missed, and reported as
  # "1 bid(s) absent from ingredients:    " - a finding naming nothing. Worse, it made this extractor
  # and Get-CardUnbidItems disagree about the same line, which is two definitions of "has a bid" in one
  # file. Trim-and-test is the definition audit-unbid-ingredients uses; both extractors now share it.
  foreach ($it in $d.ing) { $b = [string]$it.bid; if ($b -and $b.Trim() -ne '') { [void]$out.Add($b) } }
  return , $out.ToArray()
}

# THE BLIND SPOT THIS GATE HAD (2026-08-29). Get-CardBids skips a line with no bid - `if ($b)` - so the
# ONE defect that guarantees the browser cannot price a card was the one thing this gate could not see.
# A card carrying an unbid line collected only its OTHER bids, every one of them covered, and the gate
# read clean. Three LIVE paid cards sat that way: baked-turkey-kibbeh-casserole (Bulgur Wheat),
# musakhan-sumac-chicken (Sumac) and turkey-meatball-sub-bake (Keto Bun).
#
# It matters because the browser is fail-closed. tpl2-scaler-prefix.html:317 returns null for the WHOLE
# batch total if any line prices to null, and its price() returns null when `it.bid` is falsy - so one
# unbid line does not cost the reader one row, it takes down the total, the per-serving figure and the
# composition chart together. That is strictly worse than a bid the feed happens to miss, which is what
# this gate already refuses. Returns the reader-facing item names, because "Sumac" is what a person can
# act on and "" is not.
function Get-CardUnbidItems {
  param([string]$Html)
  $m = [regex]::Match($Html, '<script type="application/json" class="smp-sc-data">(.*?)</script>', 'Singleline')
  if (-not $m.Success) { return $null }
  try { $d = $m.Groups[1].Value | ConvertFrom-Json } catch { return $null }
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($it in $d.ing) {
    $b = [string]$it.bid
    if ($b -and $b.Trim() -ne '') { continue }
    $nm = [string]$it.item
    if (-not $nm) { $nm = '(unnamed line)' }
    [void]$out.Add($nm)
  }
  return , $out.ToArray()
}

# PURE. Every input injected so the fixtures below are deterministic and cannot rot as the catalogue moves.
# $CardBids is slug -> string[]. The three feed maps are name -> anything; only presence is read, except
# pricing_inputs where a present-but-unusable entry has to count as absent (see check 3 in the header).
# $Exempt is db\no-board-price-ok.json's bid list - commodities the estate has DECIDED have no first-party
# Omaha board price and are carried by a documented register-estimate label instead. cost-engine.ps1 already
# suppresses its unpriced advisory for exactly this set, and a second, divergent copy of that decision here
# is the two-copies-of-a-rule shape. They are still REPORTED, on their own line: an exemption that prints
# nothing is indistinguishable from a check that never ran, and these lines do still render as unavailable
# to a reader. What they must not do is fail the gate, because a gate that is red on day one for a reason
# somebody already ruled on stops being read.
function Test-FeedCoverage {
  param(
    [string[]]$PublishedSlugs,
    [hashtable]$CardBids,
    [hashtable]$FeedRecipes,
    [hashtable]$FeedIngredients,
    [hashtable]$FeedPricingInputs,
    [string[]]$Exempt = @(),
    # slug -> array of "Item [VERDICT]" for lines whose carriage is not CARRIED, from costed.json's
    # `uncarried` field. Derived by lib\carriage-lib.ps1 in cost-recipes.ps1; this gate only reads it.
    [hashtable]$Uncarried = @{},
    # slug -> array of reader-facing item names on the BUILT CARD that carry no bid at all. Read from
    # the card, like $CardBids, because the card is what the browser gets. NOT exemptible: the
    # no-board-price allowlist excuses a bid the boards do not price, and an absent bid is not that.
    [hashtable]$CardUnbid = @{}
  )
  $findings = New-Object System.Collections.Generic.List[object]
  $exempted = New-Object System.Collections.Generic.List[object]
  foreach ($slug in $PublishedSlugs) {
    # CARRIAGE FIRST, and it is NOT exemptible. A recipe whose ingredient no Omaha store is proven to
    # stock comes down whatever the feed says about pricing - Brad's standing rule, 2026-08-22: one
    # uncarried ingredient and we cannot use the recipe. The no-board-price allowlist deliberately does
    # not apply here; it excuses BOARD PRICING, never carriage, and reading it as both is the bug this
    # gate exists to close.
    if ($Uncarried.ContainsKey($slug) -and @($Uncarried[$slug]).Count) {
      $findings.Add([pscustomobject]@{
        slug    = $slug
        verdict = 'NOT-CARRIED'
        detail  = ("no Omaha store is proven to carry: " + ((@($Uncarried[$slug]) | Select-Object -First 6) -join ', '))
      })
      continue
    }
    # UNBID SECOND, and ahead of the feed checks for the same reason carriage comes first: no amount of
    # feed coverage rescues a line the browser has no key to look up. Its own verdict, so the report
    # names the actual fix (heal the spec's bid) instead of sending the reader to hunt a feed row.
    if ($CardUnbid.ContainsKey($slug) -and @($CardUnbid[$slug]).Count) {
      $findings.Add([pscustomobject]@{
        slug    = $slug
        verdict = 'UNBID_LINE'
        detail  = ("the card's live scaler cannot price, so the whole total reads Unavailable: " + ((@($CardUnbid[$slug]) | Select-Object -First 6) -join ', '))
      })
      continue
    }
    $missIng = New-Object System.Collections.Generic.List[string]
    $missPin = New-Object System.Collections.Generic.List[string]
    $exBids  = New-Object System.Collections.Generic.List[string]
    $bids = if ($CardBids.ContainsKey($slug)) { $CardBids[$slug] } else { $null }
    if ($null -ne $bids) {
      foreach ($b in $bids) {
        if ($Exempt -contains $b) { [void]$exBids.Add($b); continue }
        if (-not $FeedIngredients.ContainsKey($b)) { [void]$missIng.Add($b) }
        $usable = $false
        if ($FeedPricingInputs.ContainsKey($b)) {
          $cur = $FeedPricingInputs[$b].current
          # A present key is not a priced key. An entry whose `current` is absent or carries no per-unit
          # price prices nothing, and counting it as covered is how a coverage check reads green over the
          # exact line the reader sees as unavailable.
          if ($null -ne $cur -and [double]$cur.perUnitMicros -gt 0) { $usable = $true }
        }
        if (-not $usable) { [void]$missPin.Add($b) }
      }
    }
    if ($exBids.Count) { $exempted.Add([pscustomobject]@{ slug = $slug; bids = $exBids.ToArray() }) }
    $slugMissing = -not $FeedRecipes.ContainsKey($slug)
    if (-not $slugMissing -and $missIng.Count -eq 0 -and $missPin.Count -eq 0) { continue }
    $why = New-Object System.Collections.Generic.List[string]
    if ($slugMissing) { $why.Add('slug absent from the feed''s recipes map') }
    if ($missIng.Count) { $why.Add(("{0} bid(s) absent from ingredients: {1}" -f $missIng.Count, (($missIng | Select-Object -First 6) -join ', '))) }
    if ($missPin.Count) { $why.Add(("{0} bid(s) with no usable pricing_inputs: {1}" -f $missPin.Count, (($missPin | Select-Object -First 6) -join ', '))) }
    $findings.Add([pscustomobject]@{
      slug    = $slug
      verdict = $(if ($missIng.Count -or $missPin.Count) { 'BIDS_UNPRICEABLE' } else { 'SLUG_MISSING' })
      detail  = ($why -join '; ')
    })
  }
  return [pscustomobject]@{ findings = $findings.ToArray(); exempted = $exempted.ToArray() }
}

# ======================================================================================================
# FIXTURES. Frozen at the founding bug, with a clean twin that must pass or this is only a refuser.
# ======================================================================================================
if ($SelfTest) {
  # EAP=Stop for the suite itself: a case that cannot RUN must fail out loud, not be skipped into a
  # cheerful tally. (The lesson feed-freshness.ps1 carries, and the reason its count is pinned.)
  $ErrorActionPreference = 'Stop'
  $n = 0; $bad = 0
  function TT($m, $cond, $got) { $script:n++; if ($cond) { Write-Output ("  ok    " + $m) } else { Write-Output ("  FAIL  " + $m + "   got: " + $got); $script:bad++ } }
  # The cases below judge findings; exemptions are asserted explicitly. `,@(...)` is load-bearing: PS 5.1
  # unrolls a one-element array on function OUTPUT, so a single finding would come back as a bare object
  # and every `$f.Count -eq 1` assertion would read $null and fail. Do not simplify this to a bare return.
  function Invoke-Cov { $r = (Test-FeedCoverage @args).findings; return , @($r) }

  $PIN = @{ 'chicken-thigh' = @{ current = @{ perUnitMicros = 2430000 } }
            'rice'          = @{ current = @{ perUnitMicros = 61000 } } }
  $ING = @{ 'chicken-thigh' = @{ store = 'Aldi' }; 'rice' = @{ store = "Sam's Club" } }
  $CARDS = @{ 'country-captain-chicken' = @('chicken-thigh', 'rice'); 'american-goulash-pasta' = @('rice') }

  # -- THE FOUNDING BUG, frozen. country-captain-chicken is published and complete, and the feed the
  #    cards fetch has never heard of the slug. This is the exact state on 2026-08-15.
  $f = Invoke-Cov -PublishedSlugs @('country-captain-chicken') -CardBids $CARDS `
        -FeedRecipes @{ 'american-goulash-pasta' = 1 } -FeedIngredients $ING -FeedPricingInputs $PIN
  TT 'MUST FIRE  a published recipe the feed''s recipes map does not carry is a finding' `
     ($f.Count -eq 1 -and $f[0].verdict -eq 'SLUG_MISSING') ("count=$($f.Count) " + ($f | ForEach-Object { $_.verdict }))

  # -- the check that actually protects the cost section: bid present in ingredients, absent from
  #    pricing_inputs. Every count-based check reads green here and the reader still sees "unavailable".
  $f = Invoke-Cov -PublishedSlugs @('country-captain-chicken') -CardBids $CARDS `
        -FeedRecipes @{ 'country-captain-chicken' = 1 } -FeedIngredients $ING `
        -FeedPricingInputs @{ 'rice' = @{ current = @{ perUnitMicros = 61000 } } }
  TT 'MUST FIRE  a bid in ingredients but NOT in pricing_inputs is a finding' `
     ($f.Count -eq 1 -and $f[0].verdict -eq 'BIDS_UNPRICEABLE' -and $f[0].detail -match 'chicken-thigh') $($f | ForEach-Object { $_.detail })

  # -- present-but-unpriced. The shape a coverage check keyed on presence alone cannot see.
  $f = Invoke-Cov -PublishedSlugs @('country-captain-chicken') -CardBids $CARDS `
        -FeedRecipes @{ 'country-captain-chicken' = 1 } -FeedIngredients $ING `
        -FeedPricingInputs @{ 'chicken-thigh' = @{ current = @{ perUnitMicros = 0 } }; 'rice' = @{ current = @{ perUnitMicros = 61000 } } }
  TT 'MUST FIRE  a pricing_inputs entry present with a zero per-unit price counts as absent' `
     ($f.Count -eq 1 -and $f[0].detail -match 'chicken-thigh') $($f | ForEach-Object { $_.detail })

  $f = Invoke-Cov -PublishedSlugs @('country-captain-chicken') -CardBids $CARDS `
        -FeedRecipes @{ 'country-captain-chicken' = 1 } -FeedIngredients $ING `
        -FeedPricingInputs @{ 'chicken-thigh' = @{}; 'rice' = @{ current = @{ perUnitMicros = 61000 } } }
  TT 'MUST FIRE  a pricing_inputs entry with no `current` at all counts as absent' `
     ($f.Count -eq 1 -and $f[0].detail -match 'chicken-thigh') $($f | ForEach-Object { $_.detail })

  # -- a bid missing from ingredients is caught too, not just from pricing_inputs
  $f = Invoke-Cov -PublishedSlugs @('country-captain-chicken') -CardBids $CARDS `
        -FeedRecipes @{ 'country-captain-chicken' = 1 } -FeedIngredients @{ 'rice' = @{} } -FeedPricingInputs $PIN
  TT 'MUST FIRE  a bid absent from ingredients is a finding' `
     ($f.Count -eq 1 -and $f[0].detail -match 'absent from ingredients') $($f | ForEach-Object { $_.detail })

  # -- THE CLEAN TWIN. Same slugs, same bids, a feed that covers them. Must be silent.
  $f = Invoke-Cov -PublishedSlugs @('country-captain-chicken', 'american-goulash-pasta') -CardBids $CARDS `
        -FeedRecipes @{ 'country-captain-chicken' = 1; 'american-goulash-pasta' = 1 } `
        -FeedIngredients $ING -FeedPricingInputs $PIN
  TT 'CLEAN TWIN  both published recipes fully covered is silent' ($f.Count -eq 0) ("count=$($f.Count)")

  # -- THE ALLOWLIST, honoured from the file cost-engine already reads. aji-amarillo-paste is on it: the
  #    estate ruled it has no first-party Omaha board price and carries a register-estimate label
  #    instead. It must not fail the gate, and it must not vanish either.
  #
  #    THIS FIXTURE USED TO BE doubanjiang, AND THAT WAS THE BUG WRITTEN DOWN AS A TEST. doubanjiang has
  #    never been found in any Omaha store - it is searched as "chili bean sauce", which returns Bush's
  #    chili beans - so this self-test was asserting that an ingredient nobody stocks must pass the
  #    publish gate. Three paid recipes shipped on that assertion. The allowlist excuses BOARD PRICING
  #    for a food we know is on a shelf; aji-amarillo-paste (Walmart) actually is one.
  $CARDS2 = @{ 'peruvian-pollo-saltado' = @('chicken-thigh', 'aji-amarillo-paste') }
  $r = Test-FeedCoverage -PublishedSlugs @('peruvian-pollo-saltado') -CardBids $CARDS2 `
        -FeedRecipes @{ 'peruvian-pollo-saltado' = 1 } -FeedIngredients $ING -FeedPricingInputs $PIN `
        -Exempt @('aji-amarillo-paste', 'dried-guajillo-chiles')
  TT 'CLEAN TWIN  an allowlisted no-board-price bid does not fail the gate' ($r.findings.Count -eq 0) ("findings=$($r.findings.Count)")
  TT 'MUST FIRE  ...but it is still REPORTED, never silently dropped' `
     ($r.exempted.Count -eq 1 -and $r.exempted[0].bids -contains 'aji-amarillo-paste') ("exempted=$($r.exempted.Count)")

  # -- CARRIAGE IS NOT EXEMPTIBLE. The allowlist says "may skip board pricing", never "is carried".
  #    A recipe with an uncarried line comes down even when its bid is allowlisted and the feed is fine.
  $r = Test-FeedCoverage -PublishedSlugs @('peruvian-pollo-saltado') -CardBids $CARDS2 `
        -FeedRecipes @{ 'peruvian-pollo-saltado' = 1 } -FeedIngredients $ING -FeedPricingInputs $PIN `
        -Exempt @('aji-amarillo-paste') -Uncarried @{ 'peruvian-pollo-saltado' = @('Aji Amarillo Paste [UNKNOWN]') }
  TT 'MUST FIRE  an uncarried line fails the gate even when its bid is allowlisted' `
     ($r.findings.Count -eq 1 -and $r.findings[0].verdict -eq 'NOT-CARRIED') ("findings=$($r.findings.Count) verdict=$($r.findings[0].verdict)")

  # -- UNKNOWN takes a LIVE recipe down. Brad's call, 2026-08-22: on a page already selling to readers,
  #    "we cannot prove Omaha has it" is not good enough to leave up.
  $r = Test-FeedCoverage -PublishedSlugs @('country-captain-chicken') -CardBids $CARDS `
        -FeedRecipes @{ 'country-captain-chicken' = 1 } -FeedIngredients $ING -FeedPricingInputs $PIN `
        -Uncarried @{ 'country-captain-chicken' = @('Doubanjiang [UNKNOWN]') }
  TT 'MUST FIRE  UNKNOWN carriage on a live recipe is a takedown finding' `
     ($r.findings.Count -eq 1 -and $r.findings[0].verdict -eq 'NOT-CARRIED') ("findings=$($r.findings.Count)")

  # -- and a fully carried recipe is untouched by the new check
  $r = Test-FeedCoverage -PublishedSlugs @('country-captain-chicken') -CardBids $CARDS `
        -FeedRecipes @{ 'country-captain-chicken' = 1 } -FeedIngredients $ING -FeedPricingInputs $PIN `
        -Uncarried @{ 'american-goulash-pasta' = @('Something [UNKNOWN]') }
  TT 'CLEAN TWIN  another recipe''s uncarried line does not fail this one' ($r.findings.Count -eq 0) ("findings=$($r.findings.Count)")

  # -- THE BLIND SPOT, frozen (2026-08-29). A card carrying a line with NO bid at all. Every bid it DOES
  #    carry is covered, so every check above this one reads green - which is exactly how three live
  #    paid cards sat with a dark scaler while this gate reported them clean.
  $r = Test-FeedCoverage -PublishedSlugs @('country-captain-chicken') -CardBids $CARDS `
        -FeedRecipes @{ 'country-captain-chicken' = 1 } -FeedIngredients $ING -FeedPricingInputs $PIN `
        -CardUnbid @{ 'country-captain-chicken' = @('Sumac') }
  TT 'MUST FIRE  a card line with NO bid is a finding even when every other bid is covered' `
     ($r.findings.Count -eq 1 -and $r.findings[0].verdict -eq 'UNBID_LINE' -and $r.findings[0].detail -match 'Sumac') `
     ("findings=$($r.findings.Count) verdict=$($r.findings | ForEach-Object { $_.verdict })")

  # -- AND IT IS NOT EXEMPTIBLE. no-board-price-ok excuses a bid the boards do not price; it cannot
  #    excuse the absence of a bid, because there is no id for the allowlist to name.
  $r = Test-FeedCoverage -PublishedSlugs @('country-captain-chicken') -CardBids $CARDS `
        -FeedRecipes @{ 'country-captain-chicken' = 1 } -FeedIngredients $ING -FeedPricingInputs $PIN `
        -Exempt @('chicken-thigh', 'rice') -CardUnbid @{ 'country-captain-chicken' = @('Keto Bun') }
  TT 'MUST FIRE  an unbid line is not pardoned by the no-board-price allowlist' `
     ($r.findings.Count -eq 1 -and $r.findings[0].verdict -eq 'UNBID_LINE') ("findings=$($r.findings.Count)")

  # -- CLEAN TWIN. Another recipe's unbid line must not fail this one.
  $r = Test-FeedCoverage -PublishedSlugs @('country-captain-chicken') -CardBids $CARDS `
        -FeedRecipes @{ 'country-captain-chicken' = 1 } -FeedIngredients $ING -FeedPricingInputs $PIN `
        -CardUnbid @{ 'american-goulash-pasta' = @('Sumac') }
  TT 'CLEAN TWIN  another recipe''s unbid line does not fail this one' ($r.findings.Count -eq 0) ("findings=$($r.findings.Count)")

  # -- THE EXTRACTOR, against the real baked shape. Get-CardBids skipping bid-less lines is correct for
  #    what it returns; the bug was that nothing ELSE looked. These two must disagree on the same card.
  $cardHtml = '<script type="application/json" class="smp-sc-data">{"ing":[' +
              '{"item":"Ground Turkey","bid":"93-7-ground-turkey","gpu":"453.592"},' +
              '{"item":"Sumac","grams":62},' +
              '{"item":"Salt","bid":"   "}' +
              ']}</script>'
  # NO @() HERE, and that is the point. `return , $arr` emits the array as ONE object so a single-element
  # result does not unroll to a bare string; wrapping the call in @() re-wraps that object and every
  # .Count reads 1 whatever the card said. Measured on this very fixture: a 2-unbid card reported 1, and
  # a card with ZERO unbid lines also reported 1 - the shape that would have made this whole check vacuous.
  $gotBids  = Get-CardBids $cardHtml
  $gotUnbid = Get-CardUnbidItems $cardHtml
  TT 'MUST FIRE  the extractor names an item with no bid property at all' ($gotUnbid -contains 'Sumac') ($gotUnbid -join ',')
  TT 'MUST FIRE  a whitespace-only bid counts as unbid, matching audit-unbid-ingredients' `
     ($gotUnbid -contains 'Salt') ($gotUnbid -join ',')
  TT 'CLEAN TWIN a properly bid line is not reported as unbid' (-not ($gotUnbid -contains 'Ground Turkey')) ($gotUnbid -join ',')
  # THE PARTITION IS THE INVARIANT. Every line lands in exactly one extractor - no line counted twice,
  # none dropped. This is what caught the whitespace-bid disagreement: Get-CardBids collected "   " as a
  # real id while Get-CardUnbidItems called the same line unbid, so a 3-line card reported 2+2.
  TT 'the two extractors partition the card: 1 bid + 2 unbid on a 3-line card' `
     ($gotBids.Count -eq 1 -and $gotUnbid.Count -eq 2) ("bids=$($gotBids.Count) unbid=$($gotUnbid.Count)")
  TT 'MUST FIRE  a whitespace-only bid is NOT collected as a real commodity id' `
     (-not ($gotBids -contains '   ')) ($gotBids -join '|')
  # A card whose every line IS bid must yield an EMPTY unbid list, not $null - the caller tests .Count.
  $cleanHtml = '<script type="application/json" class="smp-sc-data">{"ing":[{"item":"Rice","bid":"rice"}]}</script>'
  $cleanUnbid = Get-CardUnbidItems $cleanHtml
  TT 'CLEAN TWIN a fully bid card yields an empty unbid list, not null' `
     ($null -ne $cleanUnbid -and $cleanUnbid.Count -eq 0) ('count=' + $(if ($null -eq $cleanUnbid) { 'null' } else { $cleanUnbid.Count }))

  # and the allowlist must not become a blanket pardon for the rest of the card
  $r = Test-FeedCoverage -PublishedSlugs @('peruvian-pollo-saltado') -CardBids $CARDS2 `
        -FeedRecipes @{ 'peruvian-pollo-saltado' = 1 } -FeedIngredients @{ 'rice' = @{} } -FeedPricingInputs $PIN `
        -Exempt @('aji-amarillo-paste')
  TT 'MUST FIRE  an exemption pardons only its own bid, not the card' `
     ($r.findings.Count -eq 1 -and $r.findings[0].detail -match 'chicken-thigh') ("findings=$($r.findings.Count)")

  # -- a DRAFT recipe the feed does not cover is not a finding: nothing is live, nothing is wrong. Without
  #    this the guard goes red for every recipe still being worked on and a permanently-red light stops
  #    being read (the standing regression-test lesson).
  $f = Invoke-Cov -PublishedSlugs @('american-goulash-pasta') -CardBids $CARDS `
        -FeedRecipes @{ 'american-goulash-pasta' = 1 } -FeedIngredients $ING -FeedPricingInputs $PIN
  TT 'CLEAN TWIN  an unpublished recipe is not judged' ($f.Count -eq 0) ("count=$($f.Count)")

  # -- a published slug with no built card is reported on its slug alone, never silently skipped:
  #    "could not read the card" must not read as "the card is fine".
  $f = Invoke-Cov -PublishedSlugs @('ghost-recipe') -CardBids $CARDS `
        -FeedRecipes @{ 'country-captain-chicken' = 1 } -FeedIngredients $ING -FeedPricingInputs $PIN
  TT 'MUST FIRE  a published slug with no card and no feed entry is still a finding' `
     ($f.Count -eq 1 -and $f[0].verdict -eq 'SLUG_MISSING') ("count=$($f.Count)")

  # -- THE SEAL. A guard whose only caller is its own test runs never (the tested-is-not-run lesson), so
  #    assert the production caller in source. propagate-recipes.ps1 is the publish chain; this guard is
  #    worth nothing if it is not a stage in it.
  $prod = Join-Path $here 'propagate-recipes.ps1'
  $src = if (Test-Path $prod) { Get-Content $prod -Raw } else { '' }
  TT 'the publish chain invokes this guard' ($src -match 'feed-covers-published\.ps1') 'not invoked by propagate-recipes.ps1'
  TT 'MUST FIRE  the guard runs BEFORE publish in that chain, not after' `
     ($src -match '(?s)feed-covers-published\.ps1.*publish\.ps1') 'the guard stage is not ordered before the publish stage'

  # -- AND IT MUST BE CALLED IN-PROCESS. -Slugs is [string[]], and `powershell -File` passes only the
  #    FIRST element (measured 2026-08-15): this gate ran over one dirty slug and reported the whole set
  #    clean. A gate that silently narrows its own scope to n=1 is worse than no gate, because it is green.
  #    Asserted in SOURCE against every production caller, because the defect is invocation shape and no
  #    pure function can reproduce it.
  foreach ($callerName in @('propagate-recipes.ps1', 'wave-publish.ps1')) {
    $cp = Join-Path $here $callerName
    if (-not (Test-Path $cp)) { continue }
    $ctext = Get-Content $cp -Raw
    $viaFile = [regex]::IsMatch($ctext, '-File[^\r\n]*feed-covers-published\.ps1[^\r\n]*-Slugs')
    TT ("MUST FIRE  {0} calls this guard in-process, not via ``powershell -File``" -f $callerName) `
       (-not $viaFile) 'called via -File, so only the first slug is ever checked'
  }

  # -- the card parser has to survive the real artifact, or every bid list silently comes back empty and
  #    the guard reads green over a catalogue it never checked.
  $sample = Join-Path $mp 'db\built\american-goulash-pasta.body.html'
  if (Test-Path $sample) {
    $b = Get-CardBids ([IO.File]::ReadAllText($sample))
    TT 'the card parser finds bids in a real built card' ($null -ne $b -and $b.Count -ge 5) ("got " + $(if ($null -eq $b) { 'null' } else { $b.Count }))
  } else { TT 'a real built card is available to parse' $false "missing $sample" }

  if ($bad -eq 0) { Write-Output ("SELFTEST: {0}/{0} pass" -f $n); exit 0 }
  Write-Output ("SELFTEST: {0}/{1} pass - {2} FAILED" -f ($n - $bad), $n, $bad); exit 1
}

# ---- live ---------------------------------------------------------------------------------------------
$feedSrc = ''
try {
  if ($Live) {
    $tmp = Join-Path $env:TEMP ('feedcov-live-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
    Invoke-WebRequest -Uri $FEED_URL -OutFile $tmp -TimeoutSec 40 -UseBasicParsing
    $feedSrc = $tmp
  } elseif ($FeedPath) { $feedSrc = $FeedPath }
  else { $feedSrc = Join-Path $repo 'grocery\out\smp-feed.json' }
  if (-not (Test-Path $feedSrc)) { Write-Output ("FEEDCOV: cannot read the feed at " + $feedSrc); Write-GuardComplete -Name 'FEEDCOV' -Summary 'could not evaluate: no feed'; exit 3 }
  $feed = Get-Content $feedSrc -Raw -Encoding utf8 | ConvertFrom-Json
} catch {
  Write-Output ("FEEDCOV: the feed could not be read or parsed: " + $_.Exception.Message)
  Write-GuardComplete -Name 'FEEDCOV' -Summary 'could not evaluate: feed unreadable'
  exit 3
}

$hashFile = Join-Path $mp 'db\published-hashes.json'
if (-not (Test-Path $hashFile)) { Write-Output 'FEEDCOV: no db\published-hashes.json, so nothing is known to be published'; Write-GuardComplete -Name 'FEEDCOV' -Summary 'could not evaluate: no published set'; exit 3 }
$published = @()
foreach ($p in ((Get-Content $hashFile -Raw -Encoding utf8 | ConvertFrom-Json).PSObject.Properties)) { $published += [string]$p.Name }
if ($Slugs) { $published = @($published | Where-Object { $Slugs -contains $_ }) }
if (-not $published.Count) { Write-Output 'FEEDCOV: no published slugs in scope'; Write-GuardComplete -Name 'FEEDCOV' -Summary '0 slugs in scope'; exit 0 }

$cardBids = @{}
$cardUnbid = @{}
$noCard = New-Object System.Collections.Generic.List[string]
foreach ($slug in $published) {
  $cf = Join-Path $mp ('db\built\' + $slug + '.body.html')
  if (-not (Test-Path $cf)) { $noCard.Add($slug); continue }
  $html = [IO.File]::ReadAllText($cf)
  $b = Get-CardBids $html
  if ($null -eq $b) { $noCard.Add($slug); continue }
  $cardBids[$slug] = $b
  $u = Get-CardUnbidItems $html
  if ($null -ne $u -and @($u).Count) { $cardUnbid[$slug] = $u }
}

function ToMap($obj) { $h = @{}; if ($null -ne $obj) { foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value } }; return $h }
# THE SAME allowlist cost-engine.ps1 reads, not a copy of the decision. Unreadable means empty, so a
# corrupted allowlist makes the gate STRICTER, never blanket-permissive.
$exempt = @()
$okFile = Join-Path $mp 'db\no-board-price-ok.json'
if (Test-Path $okFile) { try { $exempt = @((Get-Content $okFile -Raw -Encoding utf8 | ConvertFrom-Json).bids) } catch { $exempt = @() } }

# CARRIAGE, read from costed.json where cost-recipes.ps1 recorded it. Unreadable means EMPTY, which
# makes this gate blind rather than permissive-by-accident - so a missing/corrupt costed.json is called
# out loudly instead of quietly passing every recipe.
$uncarried = @{}
$costedFile = Join-Path $mp 'db\costed.json'
$carriageKnown = $false
if (Test-Path $costedFile) {
  try {
    foreach ($c in (Get-Content $costedFile -Raw | ConvertFrom-Json)) {
      if (($c.PSObject.Properties.Name -contains 'uncarried') -and @($c.uncarried).Count) { $uncarried[[string]$c.slug] = @($c.uncarried) }
    }
    $carriageKnown = $true
  } catch { $uncarried = @{}; $carriageKnown = $false }
}

$res = Test-FeedCoverage -PublishedSlugs $published -CardBids $cardBids `
         -FeedRecipes (ToMap $feed.recipes) -FeedIngredients (ToMap $feed.ingredients) `
         -FeedPricingInputs (ToMap $feed.pricing_inputs) -Exempt $exempt -Uncarried $uncarried `
         -CardUnbid $cardUnbid
$findings = @($res.findings)

$where = $(if ($Live) { "the LIVE feed at $FEED_URL" } else { $feedSrc })
Write-Output ("FEEDCOV: {0} published recipe(s) checked against {1} (feed generated {2}, week {3})" -f $published.Count, $where, $feed.generated, $feed.week_of)
if (-not $carriageKnown) {
  Write-Output 'FEEDCOV: WARNING - db\costed.json is missing or unparseable, so CARRIAGE WAS NOT CHECKED on any recipe. Pricing coverage below is still valid; carriage is simply unknown this run.'
}
if ($noCard.Count) { Write-Output ("FEEDCOV: {0} published slug(s) have no readable built card, so their bids were not checked: {1}" -f $noCard.Count, (($noCard | Select-Object -First 8) -join ', ')) }
if (@($res.exempted).Count) {
  # Visible, every run. These lines DO still render as unavailable to a reader; they are accepted, not fixed.
  $exBids = @($res.exempted | ForEach-Object { $_.bids } | Sort-Object -Unique)
  Write-Output ("FEEDCOV: {0} published recipe(s) carry an allowlisted no-board-price bid ({1}) - accepted per db\no-board-price-ok.json, still unavailable on the card: {2}" -f @($res.exempted).Count, ($exBids -join ', '), ((@($res.exempted) | ForEach-Object { $_.slug } | Select-Object -First 8) -join ', '))
}
foreach ($f in $findings) { Write-Output ("  X {0}  [{1}]  {2}" -f $f.slug, $f.verdict, $f.detail) }

if ($findings.Count) {
  Write-Output ("FEEDCOV: {0} published recipe(s) the cards' own feed cannot fully price. Each one renders a broken cost section to readers right now." -f $findings.Count)
  Write-GuardComplete -Name 'FEEDCOV' -Summary ("{0} finding(s) over {1} published recipe(s)" -f $findings.Count, $published.Count)
  exit 1
}
Write-Output 'FEEDCOV: every published recipe resolves in the feed its card fetches, and every bid on every card is priceable.'
Write-GuardComplete -Name 'FEEDCOV' -Summary ("clean over {0} published recipe(s)" -f $published.Count)
exit 0
