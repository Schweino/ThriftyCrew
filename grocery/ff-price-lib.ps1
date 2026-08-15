<#
  ff-price-lib.ps1 - the ONE rule for turning a Freshop product row into the price a shopper pays today.

  WHY IT IS A LIB. Two callers now read Freshop: pull-regular-familyfare.ps1 (the 3-hourly sweep that feeds
  the board) and probe-ingredient.ps1 (the Recipe Hunter's targeted single-term probe). Both have to make
  the same call about the same field, and a second inline copy is how a corrected rule ships to one caller
  and not the other. This file is the authority; callers dot-source it.

  THE TWO RULES, BOTH PAID FOR IN PRODUCTION:

  1. READ `price`, NOT `base_price`. base_price is the REGULAR price; price is what the store charges today.
     Reading base_price first is the bug that had the board publishing Hy-Vee sirloin at $13.99/lb while
     Omaha #01 charged $11.99, and Baker's chicken breast at $2.89/lb against a real $2.29. Freshop happened
     to return the two fields identical for all 375 Family Fare products sampled 2026-07-14, so it was
     harmless - and a loaded gun. The day Freshop populates a markdown into `price`, the old order quietly
     publishes the regular price and nothing downstream catches it.

  2. A MULTI-BUY OFFER IS NOT A PRICE. DROP IT, DO NOT FLIP IT. Freshop returns offers as text: "4 for
     $5.00". Stripping non-digits yields "45.00", so the row publishes at $45. Measured 2026-07-31: 28 of
     3,856 Family Fare rows carried a price built exactly that way, and one was LIVE ON THE BOARD -
     ground-cloves at Family Fare, 1.25 oz, ad $45, which the engine correctly divided into $36.00/oz
     against a real cheapest of $1.09/oz. No price band, no guard and no audit blinked, because $45 for a
     spice jar is absurd but not arithmetically impossible.
     Freshop's own row says base_price=5.0 and unit_price=1.25, so the OFFER costs $5.00 and one jar inside
     it works out at $1.25. Neither number says what ONE jar costs a shopper who does not buy four, and
     "4 for $5.00" is very often must-buy-four. Two readings, no way to choose: the honest output is NO ROW.
     If a later pass proves Family Fare honours the single price, read unit_price here and require
     n * unit_price to reconcile with base_price before trusting it. Do not simply divide.

  Returns $null when the row must be dropped. $null means "no honest price", never "free".

  Usage:
    . ff-price-lib.ps1
    $p = Get-FfPrice $item        # $null = drop this row
    .\ff-price-lib.ps1 -FfPriceSelfTest

  THE SWITCH IS NOT CALLED -SelfTest, AND THAT IS DELIBERATE (2026-08-15).
  Dot-sourcing runs the dot-sourced file's param() block IN THE CALLER'S SCOPE. A lib declaring
  `param([switch]$SelfTest)` therefore RESETS the caller's own $SelfTest to $false the moment it is
  dot-sourced. That is not theoretical: adding this lib to pull-regular-familyfare.ps1 silently disarmed
  that script's `if ($SelfTest)` guard, so `pull-regular-familyfare.ps1 -SelfTest` skipped its hermetic
  self-test and ran a LIVE Freshop pull instead - burning the term budget and looking, from the outside,
  like a self-test that simply printed a lot. Any name a caller might also use is unsafe here; this one is
  namespaced so it cannot collide.
#>
param([switch]$FfPriceSelfTest)

function Get-FfPrice($Item) {
  if (-not $Item) { return $null }
  $priceText = [string]$Item.price
  # rule 2: multi-buy offer text is not a unit price
  if ($priceText -and $priceText.Contains(' for ')) { return $null }
  # rule 1: current price wins; regular price is the fallback, never the default
  $cur = 0.0;  [void][double]::TryParse(($priceText -replace '[^0-9.]', ''), [ref]$cur)
  $base = 0.0; [void][double]::TryParse((([string]$Item.base_price) -replace '[^0-9.]', ''), [ref]$base)
  $val = $cur
  if ($val -le 0) { $val = $base }
  if ($val -le 0) { return $null }
  return [double]$val
}

if ($FfPriceSelfTest) {
  $bad = 0
  function T($label, $got, $want) {
    $ok = ($null -eq $want -and $null -eq $got) -or ($null -ne $want -and $null -ne $got -and [math]::Abs($got - $want) -lt 0.0001)
    if (-not $ok) { Write-Output ("  X {0}: got {1}, want {2}" -f $label, $(if ($null -eq $got) { 'null' } else { $got }), $(if ($null -eq $want) { 'null' } else { $want })); $script:bad++ }
  }
  # MUST-FIRE: the founding bug, frozen. ground-cloves @ Family Fare, live on the board at $45.
  T 'multi-buy "4 for $5.00" is dropped' (Get-FfPrice ([pscustomobject]@{ price = '4 for $5.00'; base_price = 5.0 })) $null
  T 'multi-buy "3 for $5.00" is dropped' (Get-FfPrice ([pscustomobject]@{ price = '3 for $5.00'; base_price = 5.0 })) $null
  T 'multi-buy "2 for $3.00" is dropped' (Get-FfPrice ([pscustomobject]@{ price = '2 for $3.00'; base_price = 3.0 })) $null
  # CLEAN TWINS: ordinary rows still price
  T 'plain current price'      (Get-FfPrice ([pscustomobject]@{ price = '$3.59'; base_price = 3.59 })) 3.59
  T 'current beats regular'    (Get-FfPrice ([pscustomobject]@{ price = '$2.29'; base_price = 2.89 })) 2.29
  T 'falls back to base'       (Get-FfPrice ([pscustomobject]@{ price = '';      base_price = 4.19 })) 4.19
  T 'numeric price field'      (Get-FfPrice ([pscustomobject]@{ price = 5.0;     base_price = 6.0  })) 5.0
  # no honest price is null, not zero
  T 'no price at all -> null'  (Get-FfPrice ([pscustomobject]@{ price = ''; base_price = 0 })) $null
  T 'null item -> null'        (Get-FfPrice $null) $null
  if ($bad -eq 0) { Write-Output 'ff-price-lib SELF-TEST PASS (multi-buy dropped, current beats regular, no-price is null)'; exit 0 }
  Write-Output ("ff-price-lib SELF-TEST FAIL ({0} problem(s))" -f $bad); exit 1
}
