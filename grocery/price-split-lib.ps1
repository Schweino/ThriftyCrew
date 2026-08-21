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
  if ($null -eq $was -and $Store -eq 'Fareway') { $was = Get-PsNum $Row.regular }

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

  return $script:psFail
}
