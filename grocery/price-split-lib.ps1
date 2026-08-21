<#
  price-split-lib.ps1 - given one captured product row, say what is EVERYDAY and what is a SALE.

  BRAD'S RULE (2026-08-21): "Ad pricing must never enter the every day pricing value, and every day
  pricing value can't replace ad pricing. Ad pricing must be null if its not on ad."

  THE DEFECT THIS ENDS. Every everyday capture file stores its price in a field literally named
  `ad_price`, and nothing on the row says whether that number is the shelf price or a cut one. So a
  markdown captured today entered the board typed `everyday` and, under the 90-day carry, could publish
  until November. Measured on the live board 2026-08-21: 357 cells typed everyday whose source row is
  really a markdown, 27 of them holding the Cheapest crown.

  *** WHY THIS IS A LIBRARY READ AT LOAD, NOT SEVEN EDITS TO SEVEN PRODUCERS ***
  1. It is ONE rule. Seven copies of "is this row discounted, and what was it discounted from?" is the
     duplicated-rule trap this estate keeps paying for - a fix lands in one copy and six keep the bug.
     The exclude rules learned it the hard way (113 produce commodities each with a hand-assembled list).
  2. It works on the rows we ALREADY HAVE. A producer-side split only helps rows captured after the
     change; the board is mostly carried-forward rows, so the 357 bad cells would sit there for a
     quarter waiting for their term to come round.
  3. THE CAPTURE FILES STAY AS THEY ARE. They are the honest record of what the store showed us, and
     the estate already decided on 2026-08-20 (placeholder-name guard) that a judgement belongs where
     the row becomes a PRICE, not where it was observed.

  *** WHAT EACH STORE ACTUALLY SIGNALS, ALL MEASURED 2026-08-21 ***
    Baker's      marked_down + base_price, and ad_from/ad_to from Kroger's own effectiveDate /
                 expirationDate. A real dated ad. 1,278 rows.
    Family Fare  marked_down + base_price, window from the Freshop /offers record. A real dated ad.
    Fareway      regular > ad_price. The storefront shows "Original Price" but NO end date anywhere -
                 itemPromotions empty, secondaryPromotion null, no temporal key on the badge. 622 rows.
    Hy-Vee       onSale + basePrice at the puller. UNDATED: the whole GraphQL response contains zero
                 date-shaped values, and its markdowns match no ad row.
    Walmart      wasPrice + a ROLLBACK badge. UNDATED by the store; the window comes from
                 rollback-ttl-lib, anchored to first detection.
    Sam's Club   wasPrice / strikethrough. Same as Walmart.
    Aldi         the storefront exposes fullPriceString, but our capture does not record it, so an
                 Aldi everyday row carries no discount signal and is treated as everyday. Stated here
                 rather than assumed: if the Aldi capture ever records it, this is where it plugs in.

  A ROW WITH NO DISCOUNT SIGNAL IS EVERYDAY. Not "unknown", not "maybe" - every store above has a
  positive signal for a cut price, so the absence of one is meaningful. What we must never do is
  INVENT a sale, because a sale carries an expiry and an invented expiry silently deletes a real price.

  Returns:
      everyday_price  always set when the row has any usable price
      sale_price      $null unless the store's own data says a discount is live
      sale_from/to    $null unless a window is known (never borrowed from a neighbour or a store cycle)
      sale_kind       'ad' (dated by the store) | 'markdown' (store states no end) | $null
#>

# Stores whose discount, when present, is a DATED ad from the store's own feed. Everything else that
# signals a cut price is a markdown: real, but with no published end.
$script:PS_DATED_STORES = @("Baker's", 'Family Fare')

function Get-PsNum($v) {
  if ($null -eq $v) { return $null }
  $t = ([string]$v) -replace '[^0-9.]', ''
  if ($t -match '^\d*\.?\d+$') { return [double]$t }
  return $null
}

function Get-PriceSplit {
  <#
    .SYNOPSIS Split one captured row into its everyday and sale halves.
    .PARAMETER Row   the row as written by the store's producer
    .PARAMETER Store the store name (rules are per store; see the header)
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)][string]$Store)

  $cur = Get-PsNum $Row.ad_price          # what the capture says you pay today
  $res = [ordered]@{ everyday_price = $cur; sale_price = $null; sale_from = $null; sale_to = $null; sale_kind = $null }
  if ($null -eq $cur) { return $res }

  # WAS-PRICE, by whichever name this store's producer records it. base_price is the estate's usual
  # spelling; Fareway writes the pre-sale figure into `regular`.
  # HY-VEE'S `regular` IS NOT A WAS-PRICE. Its puller deliberately writes regular = price as a
  # guard-10 cross-check (they must be equal, which is the whole point), so reading it as a discount
  # would find one on every single Hy-Vee row. Family Fare does the same. Only Fareway means
  # "original price" by it, and only Fareway is allowed to be read that way.
  $was = Get-PsNum $Row.base_price
  if ($null -eq $was -and $Store -eq 'Fareway') {
    # ...BUT NOT WHEN THE TWO ARE IN DIFFERENT BASES (2026-08-21). For a WEIGHTED Fareway good we
    # publish a per-POUND price while `regular` is the PACK's was-price. Comparing them invents a
    # markdown out of a unit change:
    #     Whole Bone-In Pork Butt   ad_price $1.99/lb   regular $26.91 (the pack)  -> "93% off"
    #     Baby Back Pork Ribs       ad_price $3.99/lb   regular $14.97 (the pack)  -> "73% off"
    # Nine live rows had this shape on the day it was found, and two had already reached the board as
    # sale cells carrying a 30-day TTL - a discount that never existed, with an expiry date on it.
    #
    # build-fareway-regular ALREADY KNOWS THIS. It refuses to record base_price for a weighted row for
    # exactly this reason ("comparing a per-lb number to a per-pack one, which is how you end up
    # verifying nonsense"). Its protection was simply bypassed here, because this fallback reaches past
    # base_price to `regular`, which the builder still writes for display. One rule, two places that
    # had to agree, and only one of them knew about it - the shape this estate keeps paying for.
    $szl = ([string]$Row.size).Trim().ToLower()
    $perWeight = ($szl -match '^(lb|lbs|pound|pounds|oz|ounce|ounces|kg|g|gram|grams)$')
    if (-not $perWeight) { $was = Get-PsNum $Row.regular }
  }

  $flagged = [bool]$Row.marked_down
  $isCut = ($null -ne $was -and $was -gt ($cur + 0.005))

  if (-not ($flagged -or $isCut)) { return $res }        # no signal -> everyday, and nothing invented

  # A FLAGGED ROW WITH NO WAS-PRICE STILL HAS A SALE PRICE, just no saving to state. Keep everyday at
  # the cut price rather than inventing a higher one: guessing what it was cut FROM would publish a
  # fake regular, and the everyday value is the one thing that must never be fabricated.
  $res.sale_price     = $cur
  $res.everyday_price = if ($null -ne $was) { $was } else { $cur }

  $f = [string]$Row.ad_from; $t = [string]$Row.ad_to
  if ($f -match '^\d{4}-\d{2}-\d{2}$' -and $t -match '^\d{4}-\d{2}-\d{2}$') {
    $res.sale_from = $f; $res.sale_to = $t
    # A window we were GIVEN by the store is an ad; a window we derived ourselves (the Walmart/Sam's
    # 30-day TTL) is still a markdown, and ad_basis is how rollback-ttl-lib says so.
    $res.sale_kind = if (($script:PS_DATED_STORES -contains $Store) -and -not $Row.ad_basis) { 'ad' } else { 'markdown' }
  } else {
    $res.sale_kind = 'markdown'
  }
  return $res
}

function Get-StatedSaleWindow {
  <#
    .SYNOPSIS Turn a store's stated countdown ("Sale ends in N days") into a real window.
    .DESCRIPTION Returns @{ from; to } or $null. Pure, so the fixtures reach the real decision.

    WHY THIS EXISTS. Brad opened a Fareway product page reading "Sale ends in 1 day" and asked why we
    were handing that row a 30-day TTL guess. We were guessing because nothing captured the field:
    saleDisclaimerString lives ONLY in the storefront's Apollo cache and is never painted into the DOM,
    so no tile scraper could have found it. It is the store's own answer and it outranks everything
    except the store's own explicit dates.

    THE ANCHOR IS THE CAPTURE DATE, NEVER TODAY, AND THAT IS THE WHOLE CARE HERE. "Ends in 1 day" seen
    on 2026-08-21 means 2026-08-22, and it still means 2026-08-22 when the row is read on the 25th. A
    Fareway row can be carried forward for weeks under the 90-day quarter, so anchoring on today would
    push the expiry forward on every single build and produce a sale that never ends - the infinite-TTL
    shape rollback-ttl-lib exists to prevent, arriving through a different door.

    Verified against an independent source before shipping: the ribs read "Sale ends in 1 day" on
    2026-08-21 -> 2026-08-22, and fareway-deals-2026-08-20.json independently states the weekly ad runs
    2026-08-17 to 2026-08-22.

    A BOUND, NOT A GUESS. Fareway runs a weekly flyer and a ~4-week monthly one; anything claiming more
    than 60 days is not a sale window and must not become one. 0 is valid - "Sale ends today".
  #>
  param($Days, [string]$AsOf)
  if ($null -eq $Days -or "$Days" -eq '') { return $null }
  if (-not ($AsOf -match '^\d{4}-\d{2}-\d{2}$')) { return $null }   # no anchor -> no honest window
  $n = -1
  if (-not [int]::TryParse([string]$Days, [ref]$n)) { return $null }
  if ($n -lt 0 -or $n -gt 60) { return $null }
  try {
    $a = [datetime]::ParseExact($AsOf, 'yyyy-MM-dd', $null)
    return @{ from = $AsOf; to = $a.AddDays($n).ToString('yyyy-MM-dd') }
  } catch { return $null }
}

function Test-PriceSplitSelf {
  <# Frozen cases, one per store shape actually observed on 2026-08-21. Returns the failure count. #>
  $fail = 0
  function _C($label, $got, $want) {
    if ("$got" -eq "$want") { Write-Output "ok    $label = $got" } else { Write-Output "FAIL  $label got '$got' want '$want'"; $script:psFail++ }
  }
  $script:psFail = 0

  # Baker's: a real dated ad
  $r = Get-PriceSplit ([pscustomobject]@{ ad_price='$2.99'; base_price=4.99; marked_down=$true; ad_from='2026-08-19'; ad_to='2026-08-26' }) "Baker's"
  _C 'bakers.everyday' $r.everyday_price 4.99
  _C 'bakers.sale'     $r.sale_price     2.99
  _C 'bakers.kind'     $r.sale_kind      'ad'

  # Fareway: original price present, NO window -> markdown
  $r = Get-PriceSplit ([pscustomobject]@{ ad_price='$1.88'; regular='$2.99' }) 'Fareway'
  _C 'fareway.everyday' $r.everyday_price 2.99
  _C 'fareway.sale'     $r.sale_price     1.88
  _C 'fareway.kind'     $r.sale_kind      'markdown'

  # MUST NOT FIRE: Hy-Vee writes regular = price as a guard-10 cross-check. Reading that as a
  # discount would find one on every Hy-Vee row in the estate.
  $r = Get-PriceSplit ([pscustomobject]@{ ad_price='$3.99'; regular=3.99 }) 'Hy-Vee'
  _C 'hyvee.no-false-sale' ($null -eq $r.sale_price) 'True'
  _C 'hyvee.everyday'      $r.everyday_price 3.99

  # Walmart rollback: dated by OUR ttl, so it stays a markdown, not an ad
  $r = Get-PriceSplit ([pscustomobject]@{ ad_price='$4.87'; base_price=5.96; marked_down=$true; ad_from='2026-08-21'; ad_to='2026-09-20'; ad_basis='TTL - anchored to first detection' }) 'Walmart'
  _C 'walmart.kind' $r.sale_kind 'markdown'
  _C 'walmart.everyday' $r.everyday_price 5.96

  # a plain everyday row invents nothing
  $r = Get-PriceSplit ([pscustomobject]@{ ad_price='$1.29' }) 'Aldi'
  _C 'aldi.everyday' $r.everyday_price 1.29
  _C 'aldi.no-sale'  ($null -eq $r.sale_price) 'True'

  # flagged but no was-price: everyday must NOT be invented above the cut price
  $r = Get-PriceSplit ([pscustomobject]@{ ad_price='$5.00'; marked_down=$true }) "Baker's"
  _C 'noWas.everyday' $r.everyday_price 5
  _C 'noWas.sale'     $r.sale_price     5

  # ---- Fareway's per-lb rows must not be compared against a per-PACK regular (2026-08-21) ---------
  # MUST FIRE. The frozen case is the live one: Whole Bone-In Pork Butt, $1.99/lb against a $26.91
  # pack was-price, which read as a 93% markdown and reached the board with a 30-day TTL on it.
  $r = Get-PriceSplit ([pscustomobject]@{ ad_price='$1.99'; size='lb'; regular='$26.91' }) 'Fareway'
  _C 'fareway.lb.no-fake-sale' ($null -eq $r.sale_price) 'True'
  _C 'fareway.lb.everyday'     $r.everyday_price 1.99
  # The ribs, same shape, and the one Brad actually opened.
  $r = Get-PriceSplit ([pscustomobject]@{ ad_price='$3.99'; size='lb'; regular='$14.97' }) 'Fareway'
  _C 'fareway.ribs.no-fake-sale' ($null -eq $r.sale_price) 'True'
  # CLEAN TWIN, and it is the one that keeps the fix honest: a PACKAGED Fareway row still reads its
  # regular as a was-price, because there the two ARE in the same basis. Over-correcting into "never
  # trust Fareway's regular" would delete every real Fareway markdown on the board.
  $r = Get-PriceSplit ([pscustomobject]@{ ad_price='$1.88'; size='7.3 oz'; regular='$2.99' }) 'Fareway'
  _C 'fareway.packaged.still-a-sale' $r.sale_price 1.88
  _C 'fareway.packaged.everyday'     $r.everyday_price 2.99
  # CLEAN TWIN: an explicit base_price is trusted even on a weighted row - the builder only withholds
  # it when the bases disagree, so if it IS there, it was recorded deliberately and in-basis.
  $r = Get-PriceSplit ([pscustomobject]@{ ad_price='$3.99'; size='lb'; base_price=4.99 }) 'Fareway'
  _C 'fareway.lb.explicit-base-wins' $r.sale_price 3.99

  # ---- the store's STATED countdown (2026-08-21) -------------------------------------------------
  # The frozen case is the real one: Fareway's baby back ribs, "Sale ends in 1 day", captured
  # 2026-08-21. It must land on 08-22, which fareway-deals-2026-08-20.json independently states is the
  # weekly ad's end date.
  $w = Get-StatedSaleWindow 1 '2026-08-21'
  _C 'countdown.to'   $w.to   '2026-08-22'
  _C 'countdown.from' $w.from '2026-08-21'

  # MUST NOT DRIFT. The SAME captured row read on a later build still ends 08-22. Anchoring on today
  # would push the expiry forward every build and the sale would never end - the infinite-TTL shape,
  # through a different door. This is the case that matters most in this whole block.
  $w = Get-StatedSaleWindow 1 '2026-08-21'
  _C 'countdown.does-not-drift' $w.to '2026-08-22'

  # "Sale ends today" is 0 days, and 0 is a real answer, not a missing one.
  $w = Get-StatedSaleWindow 0 '2026-08-21'
  _C 'countdown.today' $w.to '2026-08-21'

  # No anchor -> no window. A countdown with nothing to count from cannot be honestly resolved, and
  # inventing today as the anchor is exactly the laundering this guards against.
  _C 'countdown.no-anchor' ($null -eq (Get-StatedSaleWindow 3 '')) 'True'

  # Out of range, absent, and non-numeric all decline rather than guess. 61 days is not a Fareway sale
  # window (weekly flyer + ~4-week monthly), and a sentinel like that is how a 2099 date gets believed.
  _C 'countdown.too-long'  ($null -eq (Get-StatedSaleWindow 61 '2026-08-21')) 'True'
  _C 'countdown.absent'    ($null -eq (Get-StatedSaleWindow $null '2026-08-21')) 'True'
  _C 'countdown.negative'  ($null -eq (Get-StatedSaleWindow -1 '2026-08-21')) 'True'
  # "Add 2 to qualify for deal" reaches the extractor as null days - a multibuy CONDITION is not a
  # date, and parsing one as a window would give a dateless deal a confident expiry.
  _C 'countdown.multibuy-note' ($null -eq (Get-StatedSaleWindow '' '2026-08-21')) 'True'

  # A month-long window IS legitimate - Fareway's monthly ad. The bound must not clip a real one.
  $w = Get-StatedSaleWindow 28 '2026-08-21'
  _C 'countdown.monthly' $w.to '2026-09-18'

  return $script:psFail
}
