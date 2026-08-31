<#
  instore-lib.ps1 - THE one definition of "is this row an IN-STORE shelf price?".

  ONE COPY ON PURPOSE. compare-deals.ps1 enforces this rule and audit-coverage-gaps.ps1 has to agree with
  it: that auditor reports "this store carries the product but is missing from the board", and every row
  this gate refuses looks exactly like one of those gaps. Its own header says an auditor that disagrees
  with the engine is a permanent false alarm, which is why it already lifts $GLOBAL_EXCLUDE out of the
  engine rather than keeping a second opinion. Same reasoning, same fix: both dot-source this.

      . (Join-Path $root 'instore-lib.ps1')
      if (-not (Test-InStore $row.fulfillment)) { ... }
#>

# IN-STORE PRICE MODE, ENFORCED PER ROW (2026-08-31). Brad's standing rule is that this board publishes
# what a shopper pays ON THE SHELF in Omaha. The Walmart capture carries that answer per row and nothing
# read it: `fulfillment` is STORE for a shelf item, FC for a walmart.com item shipped from a fulfillment
# centre, and MARKETPLACE for a third-party seller. Every one of those rows was being admitted and stamped
# source_ad='everyday shelf price', which is a false provenance claim on a price no Omaha shelf carries.
#
# THE FOUNDING BUG: achiote-paste. The 2026-08-30 capture holds BOTH of these -
#     Chef Merito Achiote Seasoning Paste, 3.5 Oz                              STORE   $2.27
#     Chef Merito Achiote ... Annatto Seed Paste, 3.5 oz, (Pack of 12)         FC     $16.24  <- won the crown
# the same jar, from the same brand, and the board crowned the shipped 12-pack case at $0.3867/oz because a
# case wins on per-unit. cochinita-pibil was then billed the whole 42 oz case and its cheapest-everywhere
# price computed 55% ABOVE its everyday price.
#
# ABSENT SIGNAL IS NOT A VERDICT. Only walmart-regular-2026-08-30 carries the field at all (499 of 525 rows);
# every older capture in the carry window has none, and a missing field must never read as "not in store" -
# that would empty most of the Walmart column on the day this shipped. So no signal passes, and the gate arms
# itself store by store as captures refresh. See the could-not-run-is-not-a-failure class.
# MEASURED 2026-08-31, so nobody has to re-derive it. The signal is WALMART-ONLY today - no other
# store's capture carries a fulfillment field on any row - and it arrived with the 08-30 pull:
#     walmart-regular-2026-08-29   234 rows,      0 carry the signal
#     walmart-regular-2026-08-30   525 rows,    499 carry it  (95%)
#     walmart-regular-2026-08-31 11694 rows,  11603 carry it  (99%)
#
# THE UNKNOWNS ARE FILLING IN, WHICH IS THE THING TO CHECK RATHER THAN ASSUME. Walmart is priced from
# a 90-day UNION, so a board cell held by a row captured before 08-30 has no signal and is ADMITTED by
# the rule above. Counting Walmart board cells whose winning product appears in NO signal-carrying
# capture, as each one landed:
#     signal up to 2026-08-29 -> 529 of 529 unknown (100%)
#     signal up to 2026-08-30 -> 508 of 529         ( 96%)
#     signal up to 2026-08-31 ->  71 of 529         ( 13%)
# So they resolve as captures refresh, exactly as designed, and the remaining 71 clear when a later
# pull returns those products or their rows age out of the window. DO NOT GATE ON THEM: an absent
# signal is not evidence a product is off the shelf, and hard-failing the unknowns would empty most of
# the Walmart column for a fact nobody measured. That is the could-not-run-is-not-a-failure class.
$SHELF_FULFILLMENT = @('STORE')
function Test-InStore($ful) {
  $f = ('' + $ful).Trim().ToUpper()
  if (-not $f) { return $true }
  return ($SHELF_FULFILLMENT -contains $f)
}
