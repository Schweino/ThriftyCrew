<#
  add-coverage-allowlist-2026-07-31.ps1 - record the reviewed coverage-gap verdicts from plan-2026-07-31.json
  item f3fd16, so audit-coverage-gaps stops re-reporting cells a human has already adjudicated.

  The allowlist affects the AUDIT'S REPORTING ONLY. It never touches the board, never adds or removes a price,
  and never changes a rule. It is the record of "a human read this candidate row and it is not a gap".

  26 gaps were classified line by line against out\coverage-gaps.json (06:10) and the stores' own captures:
     11  audit fuzzy-match FALSE candidates  -> allowlisted here, each with the candidate name that caused it
      5  Aldi cells whose new capture carries no pack COUNT on an each-commodity -> allowlisted here
      1  taco-sauce @ Sam's - a genuine what-should-this-commodity-MEAN question -> parked for Brad, allowlisted
      1  teriyaki-sauce @ Fareway - candidate names itself a BBQ sauce -> allowlisted rather than widen an include
      7  Family Fare terms starved by the throttle sweep      -> NOT allowlisted: transient, self-heals on the
                                                                 sweep, and silencing them would hide a real
                                                                 coverage regression if the sweep stopped working
      1  canned-mushrooms @ Aldi                              -> NOT allowlisted: a REAL matching bug, fixed in
                                                                 commodities.json (conjunction-free exclude)
  Nothing here is allowlisted because it was noisy. Two categories are deliberately left to keep firing.
#>
param([switch]$Apply)
$ErrorActionPreference = 'Stop'
$path = 'C:\Codex\ThriftyCrew\grocery\coverage-gap-allowlist.json'
$today = '2026-07-31'
$src = 'REVIEWED 2026-07-31 against out\coverage-gaps.json (06:10) + the store captures named in each entry (plan-2026-07-31.json item f3fd16)'

# commodity, store, why
$adds = @(
  # ---- FALSE FUZZY-MATCH CANDIDATES (the audit loosens includes on purpose; these are its known false shape)
  @('cherries', 'Family Fare', 'FALSE FUZZY-MATCH: the only candidate is "Finest Reserve Cherry Habanero Pepper Jelly 9 Oz" - a pepper jelly whose name carries the word cherry. Not fresh cherries. Correctly excluded; the board is unaffected.'),
  @('grapefruit', "Sam's Club", 'FALSE FUZZY-MATCH: the only candidate is "NatureWell Bergamot & Grapefruit Moisturizing Cream, 16 oz., 2 pk." - a SKIN CREAM. Not produce. Correctly excluded.'),
  @('jalapenos', "Sam's Club", 'FALSE FUZZY-MATCH: all three candidates are processed goods flavoured with jalapeno - "Member''s Mark Smoked Sausage Made with Bacon, Jalapeno & Monterey Jack Cheese", "Member''s Mark Jalapeno Grassfed Beef Sticks" and "Member''s Mark Jalapeno Flakes" (a dried spice). None is a fresh pepper. Correctly excluded.'),
  @('oat-milk', "Sam's Club", 'FALSE SUBSTRING MATCH: the only candidate is "Bubs Goat Milk Toddler Nutritional Drink, 20 oz., 3 pk." - the audit''s loosened matcher finds "oat milk" inside "G-OAT MILK". It is goat milk for toddlers, not oat milk. Correctly excluded.'),
  @('teriyaki-sauce', 'Family Fare', 'FALSE FUZZY-MATCH: the only candidate is "Pineapple Teriyaki Brats 4 Ct." - fresh sausage flavoured with teriyaki, not a bottle of sauce. This commodity is priced per FL OZ of sauce. Correctly excluded.'),
  @('doubanjiang', 'Family Fare', 'FALSE FUZZY-MATCH, the known chili-beans class (already allowlisted for Hy-Vee, Fareway, Baker''s and Walmart on 2026-07-27; extended to Family Fare here). The audit loosens the include "chili\s+bean\s+sauce" - correct for real doubanjiang / Lee Kum Kee chili bean sauce - into a pattern that matches American canned CHILI BEANS. All four candidates are exactly that: "Mrs. Grimes Original Chili Beans In Chili Sauce 40 Oz", "Bush''s Best Chili Beans Mild Chili Sauce Red Beans 16 Oz", the Pinto twin, and "Our Family Chili Beans, In Mild Chili Sauce 15.5 Oz". This mainstream Omaha store carries no fermented broad-bean chili paste; doubanjiang has no cell at any store, so the board is unaffected. DELETE-TRIGGER: delete when a Family Fare search for "doubanjiang" or "chili bean sauce" returns a real fermented broad-bean paste (Lee Kum Kee, Pixian).'),
  @('coconut', 'Family Fare', 'FALSE FUZZY-MATCH: the only candidate is "Hostess Coconut & Marshmallow Snoballs 2 Ea" - a snack cake. Not coconut. Correctly excluded.'),
  @('coconut', "Sam's Club", 'FALSE FUZZY-MATCH: candidates are "Red Bull Energy Coconut Edition 8.4 oz., 24 pk." (an energy drink) and "Ava Organics Coconut Crispy Rollers, 14.1 oz." (a wafer snack). Neither is coconut. Correctly excluded.'),
  @('coconut', 'Walmart', 'FALSE FUZZY-MATCH, known shape: candidates are "nutpods Dairy-Free Half and Half Alternative Almond Coconut Blend, 16 fl oz" (a coffee creamer) and "Pillsbury Creamy Supreme Coconut Pecan Frosting, 15 oz Tub" (frosting). Coconut-FLAVOURED processed goods, not coconut. Correctly excluded.'),
  @('dried-cranberries', 'Walmart', 'FALSE FUZZY-MATCH: the only candidate is "Sargento Balanced Breaks Sharp Cheddar Cheese, Cashews, Cherry Infused Dried Cranberries" - a cheese-and-nut snack tray priced as a tray, not plain dried cranberries. Same shape as the Aldi trail-mix entry reviewed 2026-07-29. Correctly excluded.'),
  @('refrigerated-biscuits', "Sam's Club", 'WRONG FORM: the only candidate is "Pillsbury Southern Style Biscuits 2 oz., 24 pk." - Sam''s sells this as a FROZEN case, not the refrigerated dough tube this commodity prices. Correctly excluded; allowlisting rather than widening the include, which would mix two different products in one cell.'),

  # ---- ALDI: the 2026-07-29 browser capture records net WEIGHT and no pack COUNT, on each-commodities
  @('hamburger-buns', 'Aldi', 'CAPTURE CARRIES NO COUNT (not a matching bug): "L Oven Fresh Hamburger Buns 12 OZ" is stamped size "11 oz" in aldi-regular-2026-07-29.json. hamburger-buns is an EACH commodity, and a net weight states no bun count, so the engine correctly refuses to price it - defaulting a count would be inventing the number. Walmart''s "Great Value White Hamburger Buns, 11 oz, 8 Count" prices fine at $0.185/each off the count in ITS name, which is the proof the engine is right and the capture is short a field. Queued for the Wednesday browser pass to read the real pack count off the product page (believed 8 ct - VERIFY, never assume).'),
  @('hot-dog-buns', 'Aldi', 'CAPTURE CARRIES NO COUNT (not a matching bug): candidates "L Oven Fresh Hot Dog Buns 12 OZ" and "Specially Selected Brioche Hot Dog Buns 9.52 OZ" carry net weight only. hot-dog-buns is an EACH commodity, so with no count the engine correctly refuses to price per bun. Count queued for the Wednesday browser pass.'),
  @('bottled-water', 'Aldi', 'CAPTURE CARRIES NO COUNT (not a matching bug): "Puraqua Purified Water 16.9 FL OZ" is priced $3.19, which is a 24-PACK total wearing one bottle''s size. bottled-water is an EACH commodity so nothing publishes today, and that refusal is the only reason a wrong number did not ship: if this commodity were priced per FL OZ, the same row would have published $0.189/fl oz off a pack total. Pack count queued for the Wednesday browser pass; the other four Puraqua/Ozarka candidates share the shape.'),
  @('microwave-popcorn', 'Aldi', 'CAPTURE CARRIES NO COUNT (not a matching bug): "Clancy S Movie Theater Butter Microwave Popcorn 2.5 OZ" at $4.49 is a multi-bag BOX priced as one 2.5 oz bag. microwave-popcorn is an EACH commodity and the capture states no bag count, so the engine correctly refuses. Count queued for the Wednesday browser pass.'),
  @('gelatin', 'Aldi', 'CAPTURE CARRIES NO COUNT (not a matching bug): "Baker S Corner Strawberry Gelatin 3 OZ" and the Orange twin carry net weight only; gelatin is an EACH commodity. Engine correctly refuses to price per box without a count. Queued for the Wednesday browser pass.'),

  # ---- JUDGMENT CALLS
  @('taco-sauce', "Sam's Club", 'PARKED FOR BRAD - a what-should-this-commodity-MEAN question, not a bug. The candidate "Taco Bell Mild Sauce, 25 oz." $4.98 genuinely IS taco sauce, but no workable include token admits it without also dragging in the Fire/Diablo/Hot Sauce bottles: the estate carries ~21 distinct Taco Bell products (seasonings, Verde Salsa, Salsa Con Queso, and the heat-level sauce bottles) across 4+ stores. Widening the include is a decision about what the commodity is FOR, so it is Brad''s call, not the developer''s. Allowlisted as a REVIEWED GAP meanwhile - the cell stays empty rather than filled with a guess. Open question recorded in plan-2026-07-31.json open_questions_for_brad.'),
  # ---- FOUND ON THE REBUILT BOARD, not in the 06:10 gap file: same known false-fuzzy class, new store.
  # (Added after the rebuild: audit-coverage-gaps surfaced it once the FF sweep bought the term.)
  @('sponges', 'Family Fare', 'FALSE FUZZY-MATCH on a BRAND NAME, the known SpongeBob class (already allowlisted for Baker''s). The only row matching /sponge/ in family-fare-regular-2026-07-31.json is "Popsicle Confection Bars, Fruit Punch & Cotton Candy, Sponge Bob Square Pants 6 Ea" $7.49 - a box of ice pops, verified as the sole match. Family Fare carries no cleaning sponge in our feed at all, so this is a PULL-TERM gap wearing a false candidate, not a matching bug. DELETE-TRIGGER: delete the moment family-fare-regular-*.json contains a row matching "scrub(ber)?\s+sponge" or "cleaning\s+sponge".'),

  @('teriyaki-sauce', 'Fareway', 'WRONG FORM, by the product''s own name: the only candidate is "Kikkoman Teriyaki Original BBQ Sauce" - Kikkoman names this a BBQ sauce, and it is formulated and priced as one. Allowlisted rather than widening the teriyaki include, which would let every teriyaki-flavoured BBQ and marinade bottle into the cell and make the crown meaningless.')
)

$text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
$doc = $text | ConvertFrom-Json
$existing = @{}
foreach ($e in @($doc.allow)) { $existing[([string]$e.commodity + '|' + [string]$e.store)] = $true }

$new = @()
foreach ($a in $adds) {
  $k = $a[0] + '|' + $a[1]
  if ($existing.ContainsKey($k)) { Write-Output ("  skip (already allowlisted): " + $k); continue }
  $new += [pscustomobject][ordered]@{ commodity = $a[0]; store = $a[1]; why = $a[2]; reviewed = $today; reviewed_source = $src }
  Write-Output ("  add " + $k)
}
Write-Output ("adding " + $new.Count + " entr(ies) to " + @($doc.allow).Count + " existing")
if (-not $Apply) { Write-Output 'DRY RUN - pass -Apply to write.'; exit 0 }

$doc.allow = @(@($doc.allow) + $new)
$json = ($doc | ConvertTo-Json -Depth 12)
$null = $json | ConvertFrom-Json      # parse gate
[IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("wrote " + $path + " (" + @($doc.allow).Count + " entries)")
