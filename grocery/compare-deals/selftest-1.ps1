  $script:fail = 0
  function _Near($label, $got, $want, $tol) {
    if ($null -eq $got) { Write-Output ("FAIL  $label  got <null> want $want"); $script:fail++; return }
    if ([math]::Abs([double]$got - [double]$want) -le $tol) { Write-Output ("ok    $label  = " + ('{0:N4}' -f [double]$got)) }
    else { Write-Output ("FAIL  $label  got " + ('{0:N4}' -f [double]$got) + " want $want"); $script:fail++ }
  }
  function _Null($label, $got) {
    if ($null -eq $got) { Write-Output ("ok    $label  correctly UNPRICED") } else { Write-Output ("FAIL  $label  should be null, got " + $got.unit_price); $script:fail++ }
  }
  function _D($price,$name,$reg,$size) { [pscustomobject]@{ price_text=$price; name=$name; regular=$reg; size_text=$size } }
  function _C($unit) { [pscustomobject]@{ unit=$unit } }
  # a commodity carrying the pack_is_package declaration (see the 'each' branch of Get-UnitPrice)
  function _CP($unit) { [pscustomobject]@{ unit=$unit; pack_is_package=$true } }
  # a commodity carrying the weight_is_one_unit declaration (see the 'each' branch of Get-UnitPrice)
  function _CW($unit) { [pscustomobject]@{ unit=$unit; weight_is_one_unit=$true } }

  # 1. soda-style Buy 2 Get 3 Free, regular $11.99/pack, 12-pack x 12 fl oz = 144 fl oz -> (2*11.99/5)/144
  _Near 'B2G3 soda /floz'        (Get-UnitPrice (_D 'Buy 2 Get 3 Free' 'Coca-Cola 12 pk' 11.99 '12 pk 12 fl oz') (_C 'floz')).unit_price 0.0333 0.0005
  # 1b. A BUNCH IS ONE PURCHASE on a count commodity, and nothing at all on a weight one (2026-08-31).
  # Asserted on Get-SizeAmount directly, which is the function that reads the size word. The cases
  # around it drive Get-UnitPrice, the MULTIBUY engine, and routing a plain shelf price through that
  # would be testing the wrong thing - the first cut did exactly that and reported a null the size
  # parser was never asked for.
  # Driven through Get-UnitPrice, which is the path the BOARD takes. The first cut asserted on
  # Get-SizeAmount and passed while the board still dropped the cell, because the branch that calls
  # Get-SizeAmount is scoped to weight/volume units and never sees an `each` commodity at all.
  _Near 'bunch on an each commodity is ONE purchase'  (Get-UnitPrice (_D '$3.00' 'Green Onions Scallions' $null 'bunch') (_C 'each')).unit_price 3.00 0.001
  _Near '...and the plural spells the same'           (Get-UnitPrice (_D '$3.00' 'Green Onions Scallions' $null 'bunches') (_C 'each')).unit_price 3.00 0.001
  # CLEAN TWIN: the tokens that already worked still do, so this added a word and moved nothing.
  _Near 'CLEAN TWIN  bare each still per-each'        (Get-UnitPrice (_D '$1.25' 'yogurt cup' $null 'each') (_C 'each')).unit_price 1.25 0.001
  _Near 'CLEAN TWIN  1 ct still per-each'             (Get-UnitPrice (_D '$1.25' 'yogurt cup' $null '1 ct') (_C 'each')).unit_price 1.25 0.001
  # MUST STILL DROP: a package whose count nobody stated is not a per-each price, and `bunch` must not
  # have widened that hole - this is the "bare package price with unknown count -> drop" guard.
  _Null 'MUST STILL DROP  a bare package with no count' (Get-UnitPrice (_D '$4.99' 'mystery tray' $null 'pkg') (_C 'each'))
  # 2. chicken thighs Buy 1 Get 2 Free, regular $5.98/lb, per-lb basis -> 5.98/3
  _Near 'B1G2 chicken /lb'       (Get-UnitPrice (_D 'Buy 1 Get 2 Free' 'Tyson chicken thighs' 5.98 'lb') (_C 'lb')).unit_price 1.9933 0.001
  # 3. same deal, per-lb regular but NO size -> must be UNPRICED so the safety net flags it (not a silent wrong price)
  _Null 'B1G2 chicken no-size'   (Get-UnitPrice (_D 'Buy 1 Get 2 Free' 'Tyson chicken thighs' 5.98 '') (_C 'lb'))
  # 4. Buy 2 Get 1 50% off, regular $3.00 each -> (2*3 + 1*3*0.5)/3
  _Near 'B2G1-50off /each'       (Get-UnitPrice (_D 'Buy 2 Get 1 50% off' 'yogurt cup' 3.00 'each') (_C 'each')).unit_price 2.50 0.001
  # 5. Buy 3 Get 2 for $1, regular $2.50 -> (3*2.50 + 2*1)/5
  _Near 'B3G2-for-1 /each'       (Get-UnitPrice (_D 'Buy 3 Get 2 for $1' 'bread loaf' 2.50 'each') (_C 'each')).unit_price 1.90 0.001
  # 5b. A MULTIBUY DIVIDES ITS PACK COUNT (2026-09-25, queue 2026-09-23-9459a1). Frozen from flagged-2026-09-23,
  # Family Fare, bar-soap (each): BOGO 40% on a 6-bar pack at reg 13.59 is 10.872 a PACK, (13.59 + 13.59 * 0.6) / 2,
  # and 1.812 a bar. It published nothing (the band refused 10.872) and paged as "a bad multibuy parse".
  _Near 'MUST FIRE  Dove 6 Ea BOGO 40% prices per BAR' (Get-UnitPrice (_D 'Buy 1 get 1 40% off' 'Dove Beauty Bar Soap Sensitive, 6 Ea' 13.59 '6 ea') (_C 'each')).unit_price 1.812 0.0005
  _Near 'MUST FIRE  Dove Replenish 6 Ea per BAR'      (Get-UnitPrice (_D 'Buy 1 get 1 40% off' 'Dove Replenish Dragon Fruit & Coconut Cream Scent Beauty Bar 6 Ea' 13.99 '6 ea') (_C 'each')).unit_price 1.8653 0.0005
  _Near 'MUST FIRE  a count in the name alone divides' (Get-UnitPrice (_D 'Buy 1 get 1 40% off' 'Dove Beauty Bar Soap Sensitive, 6 Ea' 13.59 '') (_C 'each')).unit_price 1.812 0.0005
  # a count CONFLICT is refused, never guessed: the name says 6, the size says 4
  _Null 'MUST FIRE  name 6 Ea vs size 4 ct is a count conflict' (Get-UnitPrice (_D 'Buy 1 get 1 40% off' 'Dove Beauty Bar Soap Sensitive, 6 Ea' 13.59 '4 ct') (_C 'each'))
  $mbCf = Resolve-MultibuyPackCount (_D 'Buy 1 get 1 40% off' 'Dove Beauty Bar Soap Sensitive, 6 Ea' 13.59 '4 ct')
  if ($mbCf.conflict -and $null -eq $mbCf.count) { Write-Output ('ok    MUST FIRE  the conflict names both counts (' + $mbCf.from + ')') } else { Write-Output 'FAIL  a 6-vs-4 count conflict was not reported as a conflict'; $script:fail++ }
  # CLEAN TWIN: a multibuy with no stated count keeps its per-each answer (case 4 above), and a pack_is_package
  # commodity still prices the PACKAGE, because that declaration answers before the multibuy division.
  _Near 'CLEAN TWIN  multibuy on a pack_is_package commodity stays per package' (Get-UnitPrice (_D 'Buy 1 get 1 40% off' 'Texas Toast 6 ct' 3.00 '6 ct') (_CP 'each')).unit_price 2.40 0.001
  # 5b-ii. EVERY NON-PLAIN PRICE DIVIDES ITS PACK COUNT, READ AT THE RANGE'S LEAST FAVOURABLE END (2026-09-28, queue
  # 2026-09-25-633d2b, plan-2026-09-28-9). Frozen from candidates-2026-09-28: an "N for $M" deal on an each commodity
  # shipped its per-PACKAGE price as one unit. The King's Hawaiian case kills the reader-swap mutant: Get-PackCount
  # reads '6 to 12 ct' as 12 (0.3333, understated); the each reader takes 6.
  _Near 'MUST FIRE  Pillsbury 6 Ea 2 for $6.00 prices per pastry' (Get-UnitPrice (_D '2 for $6.00' 'Pillsbury Toaster Pastries, Apple 6 Ea' $null '6 ea') (_C 'each')).unit_price 0.50 0.0005
  $khName = 'King''s Hawaiian rolls, 6 to 12 ct., 2/ $8.00'
  _Near 'MUST FIRE  King''s Hawaiian 6 to 12 ct 2/$8 reads the least favourable 6' (Get-UnitPrice (_D $khName $khName $null '') (_C 'each')).unit_price 0.6667 0.0005
  _Near 'MUST FIRE  Sunbelt (2/$5) 8-10 ct reads the least favourable 8' (Get-UnitPrice (_D '$2.50' 'Sunbelt Bakery Granola Bars (2/$5)' $null '8-10 ct') (_C 'each')).unit_price 0.3125 0.0005
  $lbName = 'La Banderita flour tortillas, 20 or 30 ct., 2/ $5.00'
  _Near 'MUST FIRE  La Banderita 20 or 30 ct 2/$5 reads the least favourable 20' (Get-UnitPrice (_D $lbName $lbName $null '') (_C 'each')).unit_price 0.125 0.0005
  # CLEAN TWIN: a single-piece N-for-$M with no count anywhere stays per-each; a plain price still divides its count;
  # a pack_is_package commodity still prices per package under an N-for-$M.
  _Near 'CLEAN TWIN  Hass Avocado 2 for $3.00 with no count stays 1.50 each' (Get-UnitPrice (_D '2 for $3.00' 'Hass Avocado' $null '') (_C 'each')).unit_price 1.50 0.0005
  _Near 'CLEAN TWIN  plain $2.99 12 ct still per-12-pack' (Get-UnitPrice (_D '$2.99' 'Dinner Rolls 12 ct' $null '12 ct') (_C 'each')).unit_price 0.2492 0.0005
  _Near 'CLEAN TWIN  garlic-bread 8 Ea 2 for $5.00 on pack_is_package stays per package' (Get-UnitPrice (_D '2 for $5.00' 'Garlic Bread 8 Ea' $null '8 ea') (_CP 'each')).unit_price 2.50 0.001
  # CLEAN TWIN: the real premium sale on a complete basis still prices exactly as before (Dove Hand Wash 12 fl oz,
  # BOGO 40% at reg 5.99 = 4.792 / 12 = 0.3993/fl oz), and is filed on the COMPLETE-BASIS half, not the unresolved one.
  $hw = Get-UnitPrice (_D 'Buy 1 get 1 40% off' 'Dove Hand Wash, Antibacterial 12 Fl Oz' 5.99 '12 oz') (_C 'floz')
  _Near 'CLEAN TWIN  Dove Hand Wash 12 fl oz still 0.3993/fl oz' $hw.unit_price 0.3993 0.0005
  $h1 = Get-MultibuyRefusalHalf ([string]$hw.basis) 'floz'
  $h2 = Get-MultibuyRefusalHalf 'per-each' 'each'
  $h3 = Get-MultibuyRefusalHalf '' 'each'
  if ($h1 -eq 'complete-basis' -and $h2 -eq 'unresolved' -and $h3 -eq 'unresolved') { Write-Output 'ok    CLEAN TWIN  hand wash is complete-basis; a per-each fall-through and an UNPRICED row are unresolved' }
  else { Write-Output ("FAIL  refusal halves wrong: handwash=$h1 per-each=$h2 unpriced=$h3"); $script:fail++ }
  # 6. plain N-for-$M (no regular needed): milk 2 for $5 -> 2.50/gal
  _Near '2-for-5 milk /gal'      (Get-UnitPrice (_D '2 for $5' 'milk gallon' $null 'gallon') (_C 'gallon')).unit_price 2.50 0.001
  # 7. multibuy MISSING regular -> UNPRICED (can't compute the discount without it)
  _Null 'B2G3 missing-regular'   (Get-UnitPrice (_D 'Buy 2 Get 3 Free' 'soda' $null '12 pk 12 fl oz') (_C 'floz'))
  # 8. detector recognizes the phrasings that need a regular (digit AND word-numeral forms - Hy-Vee spells them out)
  foreach ($t in @('Buy 2 Get 3 Free','Buy 2, Get 3 Free','BUY 1 GET 2 FREE','Buy 2 Get 1 50% off','buy one, get one FREE','buy two, get one free')) {
    if (Test-IsMultibuy $t) { Write-Output "ok    detect '$t'" } else { Write-Output "FAIL  detect '$t'"; $script:fail++ }
  }
  # 9. word-numeral BOGO prices like its digit form: "buy two, get one free" reg $3.00/each -> (2*3)/3
  _Near 'word B2G1-free /each'   (Get-UnitPrice (_D 'buy two, get one free' 'bread loaf' 3.00 'each') (_C 'each')).unit_price 2.00 0.001
  # 10. classic word BOGO "buy one, get one free" reg $4.00/each -> (1*4)/2
  _Near 'word BOGO /each'        (Get-UnitPrice (_D 'buy one, get one free' 'bread loaf' 4.00 'each') (_C 'each')).unit_price 2.00 0.001
  # 10b. A QUANTITY-CONDITIONAL DEAL IS THE PRICE AND CARRIES ITS CONDITION (Brad's ruling on a2af45, 2026-09-22).
  # Reached through Add-TcDealConditionFields, the exact call the emit makes on every store row.
  function _DC($label, $ad, $note, $wantQty, $wantText) {
    $row = [ordered]@{ store = 'X' }
    $null = Add-TcDealConditionFields $row $ad $note
    $gq = if ($row.Contains('deal_qty')) { $row['deal_qty'] } else { $null }
    $gt = if ($row.Contains('deal_condition')) { $row['deal_condition'] } else { $null }
    if ([string]$gq -eq [string]$wantQty -and [string]$gt -eq [string]$wantText) { Write-Output ("ok    $label  qty=" + [string]$gq + " '" + [string]$gt + "'") }
    else { Write-Output ("FAIL  $label  got qty=" + [string]$gq + " '" + [string]$gt + "' want qty=" + [string]$wantQty + " '" + [string]$wantText + "'"); $script:fail++ }
  }
  # MUST FIRE, the founding row (comparison-2026-09-22, yellow-bell-pepper | Family Fare): the engine's own note plus the ad's qualifier
  _DC 'deal: FF "10 for $10.00 with purchase of 10" (founding row)' '10 for $10.00 with purchase of 10' '10 for $10' 10 'when you buy 10'
  _DC 'deal: plain "2 for $5"' '2 for $5.00' '2 for $5' 2 '2 for $5'
  _DC 'deal: "3 for $4.50" keeps its cents' '3 for $4.50' '3 for $4.5' 3 '3 for $4.50'
  _DC 'deal: BOGO buy 1 get 1 free' 'Buy 1 Get 1 Free' 'BOGO buy 1 get 1 free (reg 3.99)' 2 'buy 1 get 1 free'
  _DC 'deal: buy 2 get 1 for $1' 'Buy 2 Get 1 for $1' 'buy 2 get 1 for $1 (reg 2.5)' 3 'buy 2 get 1 for $1'
  _DC 'deal: buy 2 get 1 50% off' 'Buy 2 Get 1 50% off' 'buy 2 get 1 50% off (reg 3)' 3 'buy 2 get 1 50% off'
  # MUST NOT FIRE: a plain price, a cents price, and "1 for $2" carry no condition
  _DC 'deal: plain $1.99 carries none' '$1.99' '' '' ''
  _DC 'deal: cents price carries none' '49c lb' 'cents' '' ''
  _DC 'deal: "1 for $2" carries none' '1 for $2.00' '1 for $2' '' ''
  # CLEAN TWIN: the price the engine computes for the founding row is still the effective per-unit, $1.00 each
  _Near 'deal: FF 10-for-10 still prices $1.00 each' (Get-UnitPrice (_D '10 for $10.00 with purchase of 10' 'Yellow Bell Pepper' $null '1 ea') (_C 'each')).unit_price 1.00 0.0001

  # 10c. AN "A or B" SIZE READS THE SMALLER SIZE (2026-09-22, plan-2026-09-22-5)
  $orXtra = Get-SizeAmount '56 or 67.5 oz' 'floz'
  if ($null -ne $orXtra -and [math]::Abs([double]$orXtra - 56) -lt 0.0001) { Write-Output "ok    MUST FIRE 'Xtra laundry detergent, 56 or 67.5 oz' reads 56 fl oz, the least favourable size" } else { Write-Output ("FAIL  '56 or 67.5 oz' read as " + $orXtra + ", want 56"); $script:fail++ }
  _Near 'or-size: Xtra 3/$10 at 56 oz /floz' (Get-UnitPrice (_D '3/ $10.00' 'Xtra laundry detergent, 56 or 67.5 oz.' $null '56 or 67.5 oz') (_C 'floz')).unit_price 0.0595 0.0001
  $orOne = Get-SizeAmount '67.5 oz' 'floz'
  if ($null -ne $orOne -and [math]::Abs([double]$orOne - 67.5) -lt 0.0001) { Write-Output "ok    CLEAN TWIN a single size '67.5 oz' still reads 67.5" } else { Write-Output ("FAIL  single size read as " + $orOne); $script:fail++ }
  # 10d. A COUNT RANGE TAKES ITS SMALLER COUNT TOO (2026-09-25, queue 2026-09-19-dc1b5b). Frozen founding row,
  # Fareway on comparison-2026-09-23: storage-bags priced per-42-pack 0.095; the least favourable end is 3.99/25.
  _Near 'MUST FIRE  Fareway storage bags 25-42 ct prices per bag on 25' (Get-UnitPrice (_D '$3.99' 'Bright Essentials Storage Bags' $null '25-42 ct') (_C 'each')).unit_price 0.1596 0.00005
  $crDesc = Get-EachPackCount '24-12 ct'; $crDescOld = Get-PackCount '24-12 ct'
  if ($crDesc -eq $crDescOld) { Write-Output "ok    MUST NOT FIRE a descending '24-12 ct' is not a range and reads as Get-PackCount does ($crDescOld)" } else { Write-Output ("FAIL  '24-12 ct' read " + $crDesc + ", Get-PackCount reads " + $crDescOld); $script:fail++ }
  $crOne = Get-EachPackCount '42 ct'
  if ($crOne -eq 42) { Write-Output "ok    CLEAN TWIN a single '42 ct' still reads 42" } else { Write-Output ("FAIL  '42 ct' read as " + $crOne); $script:fail++ }
  $crMm = Get-SizeAmount '10-10.5 oz' 'oz'
  if ($null -ne $crMm -and [math]::Abs([double]$crMm - 10) -lt 0.0001) { Write-Output "ok    CLEAN TWIN Fireside Marshmallows '10-10.5 oz' still reads 10 oz" } else { Write-Output ("FAIL  '10-10.5 oz' read as " + $crMm); $script:fail++ }
  _Near 'CLEAN TWIN  shrimp 31-40 ct 3 lb bag still prices per lb' (Get-UnitPrice (_D '$20.97' 'Member''s Mark Farm Raised Large Raw Shrimp, Frozen, 31-40 ct' $null '3 lb bag') (_C 'lb')).unit_price 6.99 0.0005
  # 11. the tightened GLOBAL_EXCLUDE 'mix' token must SKIP "mix & match" (a multibuy) but still catch "drink mix"
  $mixTok = '(?i)\bmix\b(?!\s*(?:&|and)\s*match)'
  if ('tyson chicken thighs, mix & match buy 1 get 2 free' -notmatch $mixTok) { Write-Output "ok    'mix & match' not excluded" } else { Write-Output "FAIL  'mix & match' wrongly excluded"; $script:fail++ }
  if ('grape drink mix' -match $mixTok) { Write-Output "ok    'drink mix' still excluded" } else { Write-Output "FAIL  'drink mix' no longer excluded"; $script:fail++ }

  # --- 11b: Hy-Vee PERKS dual price -> publish the PERKS (member) price, never the non-member or the savings ---
  # garlic bread: "$2.98 PERKS PRICES, NON-MEMBER PRICE $3.48" -> 2.98 (not 3.48; a Perks each-item with no pack prices per-each)
  _Near 'Hy-Vee Perks each ($2.98)'   (Get-UnitPrice (_D 'Hy-Vee garlic bread, SAVE! .50, $2.98 PERKS PRICES, NON-MEMBER PRICE $3.48' 'Hy-Vee garlic bread, SAVE! .50, $2.98 PERKS PRICES, NON-MEMBER PRICE $3.48' $null $null) (_C 'each')).unit_price 2.98 0.001
  # cauliflower with a "SAVE! 50c" savings must NOT be read as 0.50 -> 3.49
  _Near 'Hy-Vee Perks vs cents-save'  (Get-UnitPrice (_D ([char]0x201C+'Bud by Dole cauliflower, SAVE! 50'+[char]0x00A2+', $3.49 PERKS PRICES. NON-MEMBER PRICE $3.99') 'Bud by Dole cauliflower' $null $null) (_C 'each')).unit_price 3.49 0.001
  # bare "$1 PERKS" (no decimal) -> 1.00
  _Near 'Hy-Vee Perks whole-dollar'   (Get-UnitPrice (_D 'Larabar protein bars, $1 PERKS PRICES. NON-MEMBER PRICE $1.25' 'Larabar protein bars, $1 PERKS PRICES. NON-MEMBER PRICE $1.25' $null $null) (_C 'each')).unit_price 1.00 0.001
  # membership detection (the flag the board uses to gate the nomem column) fires on the Perks pattern, not on plain rows
  if ('Hy-Vee garlic bread, $2.98 PERKS PRICES, NON-MEMBER PRICE $3.48' -match '(?i)perks\s*price') { Write-Output 'ok    Perks membership flag detected' } else { Write-Output 'FAIL  Perks membership flag NOT detected'; $script:fail++ }
  if ('Hy-Vee milk $2.98' -notmatch '(?i)perks\s*price') { Write-Output 'ok    plain Hy-Vee row not flagged membership' } else { Write-Output 'FAIL  plain row wrongly flagged membership'; $script:fail++ }

  # --- 11b2: MUST-FIRE FIXTURE for this guard's FOUNDING BUG - the weight-package divisor ------------------
  # Added 2026-07-29. The golden regression test exists because of one bug: the first weight-package divisor
  # read the pack size out of the item NAME, so "Kroger Yellow Onions (3 lb bag)" priced per POUND got divided
  # by 3 and published at $0.33/lb. The fix was to read the PRICE TEXT only. Nothing in the suite actually
  # proved the guard could still catch that, so a green run could equally have meant "working" or "blind" -
  # the [[guard-fixture-rule]] failure mode. These are the founding bug and its clean twin, pinned:
  #   MUST-FIRE  : pack size in the NAME + a plain per-lb price  -> must NOT divide
  #   CLEAN TWIN : pack size in the PRICE TEXT                   -> must divide
  _Near 'onions (3 lb bag) in NAME - must NOT divide' (Get-UnitPrice (_D '$0.99' 'Kroger Yellow Onions (3 lb bag)' $null 'lb') (_C 'lb')).unit_price 0.99 0.001
  _Near 'onions "Per 3-Lb Bag" in PRICE - must divide' (Get-UnitPrice (_D '$4.99 Per 3-Lb Bag' 'Kroger Yellow Onions' $null 'lb') (_C 'lb')).unit_price 1.6633 0.001
  # the sibling that produced the same class on Aldi grapes: "$4.99 Per 2-Lb. Pkg" published as $4.99/lb
  _Near 'grapes "Per 2-Lb. Pkg" - must divide'        (Get-UnitPrice (_D '$4.99 Per 2-Lb. Pkg' 'Aldi Red Seedless Grapes' $null 'lb') (_C 'lb')).unit_price 2.495 0.001

  # --- 11c: per-lb RATE printed in the size text (2026-07-28 corned-beef / red-onion mispricing) -----------
  # Hy-Vee random-weight rows read "2.85 lbs ($8.99/lb)" with the per-POUND rate captured as the price. The
  # price must be published as-is, NOT divided by the weight. These three cases pin all three outcomes.
  _Near 'per-lb rate in size (heavy pkg)' (Get-UnitPrice (_D '$8.99' 'TableMakers, Corned Beef Brisket Point Cut' $null '2.85 lbs ($8.99/lb)') (_C 'lb')).unit_price 8.99 0.001
  _Near 'per-lb rate in size (light pkg)' (Get-UnitPrice (_D '$1.28' 'Sweet Red Onions' $null '0.85 lbs ($1.28/lb)') (_C 'lb')).unit_price 1.28 0.001
  # price != the stated rate -> it IS a package total and must still divide: $0.19 / 0.15 lb = $1.267/lb
  _Near 'package total w/ rate shown'     (Get-UnitPrice (_D '$0.19' 'B-Size Gold Potatoes' $null '0.15 lbs ($1.29/lb)') (_C 'lb')).unit_price 1.2667 0.001

  # --- 11c-bis: A PER-POUND PRICE ON AN OUNCE COMMODITY (2026-09-07, queue 2026-09-07-e9edb9) -------------
  # Hy-Vee's deli lines: "<product>, $9.99 lb." The perlb marker fires, the commodity is OZ, and the size
  # parser used to read the same "9.99 lb" out of the NAME as a 9.99-pound pack -> 9.99/159.84 = 0.0625
  # exactly, for ANY price. Five rows carried that 1/16 fingerprint on 09-07 and the band refused all five,
  # which held the board on the censorship ratchet. Rows are the REAL ones off flagged-2026-09-07.
  # MUST FIRE (the founding row): 9.99/lb -> 0.6244/oz, not 0.0625.
  _Near 'MUST FIRE  Hy-Vee deli $9.99 lb. on an OZ commodity' (Get-UnitPrice (_D 'Di Lusso premium sliced cheese, $9.99 lb.' 'Di Lusso premium sliced cheese, $9.99 lb.' $null '') (_C 'oz')).unit_price 0.6244 0.0002
  _Near 'MUST FIRE  the same shape at $21.99 lb. (parmesan)' (Get-UnitPrice (_D 'Parmigiano reggiano cheese, $21.99 lb.' 'Parmigiano reggiano cheese, $21.99 lb.' $null '') (_C 'oz')).unit_price 1.3744 0.0002
  # ...and it is the RATE that converts, so the answer must not be 1/16 of itself any more. A separate
  # assertion because 0.0625 is what a wrong reading returns for every one of these rows, at every price.
  $_dl = (Get-UnitPrice (_D 'Di Lusso premium sliced cheese, $9.99 lb.' 'Di Lusso premium sliced cheese, $9.99 lb.' $null '') (_C 'oz')).unit_price
  if ([math]::Abs([double]$_dl - 0.0625) -gt 0.0001) { Write-Output 'ok    MUST FIRE  the 1/16 fingerprint is gone (any price divided by its own pounds returns exactly 0.0625)' }
  else { Write-Output 'FAIL  the 1/16 fingerprint is BACK - a per-lb price is being read as a pack weight again'; $script:fail++ }
  # MUST NOT FIRE: the same token on an LB commodity was always read correctly and must not move.
  _Near 'MUST NOT FIRE  $1.88 lb. on an LB commodity is unchanged' (Get-UnitPrice (_D 'Gala or Granny Smith apples, $1.88 lb.' 'Gala or Granny Smith apples, $1.88 lb.' $null '') (_C 'lb')).unit_price 1.88 0.001
  # CLEAN TWIN: the ordinary OZ path is untouched - the real Fareway cell from the same commodity.
  _Near 'CLEAN TWIN  an ordinary OZ row with a size still divides' (Get-UnitPrice (_D '$2.48' 'Fareway American Cheese Slices' $null '12 oz') (_C 'oz')).unit_price 0.2067 0.001
  # CLEAN TWIN: a genuine multi-pound package on an OZ commodity (the price is a TOTAL, not a rate) still
  # divides - the rate test requires the number glued to "lb" to BE the number taken as the price, and
  # "$12.16 ... 5 lbs." has a whole product name in between. This is the real Sam's cell, 12.16/80 oz.
  _Near 'CLEAN TWIN  a 5 lb pack total on an OZ commodity still divides' (Get-UnitPrice (_D '$12.16' "Member's Mark American Cheese 5 lbs., 160 slices" $null '5 lb') (_C 'oz')).unit_price 0.152 0.001
  # A STATED SIZE STILL WINS, which is today's behaviour and not a new ruling: size_text is the store's own
  # statement about the unit being priced, so the new branch is scoped to rows that have no size at all -
  # exactly the Hy-Vee ad shape. This case is here because the guard is a real branch and an untested
  # branch is how the next wrong price gets in.
  _Near 'a stated size beats the bare rate (guard branch)' (Get-UnitPrice (_D 'Deli sliced cheese, $9.99 lb.' 'Deli sliced cheese' $null '12 oz') (_C 'oz')).unit_price 0.8325 0.001

  # --- 11c-ter: THE FUEL-SAVER CLAUSE IS NOT A PRICE (2026-09-07, queue 2026-09-07-05e4c3) ----------------
  # The row that held the laundry-pods crown at $0.10 a pod from 08-31 to 09-06, frozen exactly as the
  # engine saw it. laundry-pods is an each-commodity and the line states no count, so after the strip the
  # correct answer is UNPRICED - the $12.94 is a tub price, and inventing a pod count would be a fabricated
  # number. Understating is wrong; a believable wrong number on a live page is worse.
  # SINGLE-QUOTED LITERALS WITH DOUBLED APOSTROPHES, never double quotes: "... coupon, $12.94" expands $12
  # as a variable and feeds the case ".94" - a fixture that can never match anything, passing by finding
  # nothing. The cent sign is the one piece built by concatenation, and it is inside the parentheses so the
  # whole thing arrives as ONE argument rather than three positional ones.
  _Null 'MUST FIRE  the Gain Flings fuel-saver line no longer prices as 10 cents' (Get-UnitPrice (_D ('Gain Flings, EARN 10' + [char]0x00A2 + ' OFF PER GALLON, -3.00 off with manufacturer''s digital coupon, $12.94') 'Gain Flings' $null '') (_C 'each'))
  # and the price it DOES read is the line's own trailing dollar token, proven on a count-bearing twin.
  _Near 'the same line WITH a pack count prices off $12.94, not 10 cents' (Get-UnitPrice (_D ('Gain Flings 42 ct., EARN 10' + [char]0x00A2 + ' OFF PER GALLON, -3.00 off with manufacturer''s digital coupon, $12.94') 'Gain Flings' $null '') (_C 'each')).unit_price 0.3081 0.001
  # the three siblings that were live or built the same morning, all with the FUEL SAVER prefix.
  _Null 'MUST FIRE  diapers FUEL SAVER 25 cents'      (Get-UnitPrice (_D ('Pampers Swaddlers diapers, FUEL SAVER EARN 25' + [char]0x00A2 + ' OFF PER GALLON -3.00 off with manufacturer''s digital coupon, $24.97') 'Pampers Swaddlers diapers' $null '') (_C 'each'))
  _Null 'MUST FIRE  facial tissue FUEL SAVER 3 cents' (Get-UnitPrice (_D ('Hy-Vee facial tissue, FUEL SAVER EARN 3' + [char]0x00A2 + ' OFF PER GALLON, $2.29') 'Hy-Vee facial tissue' $null '') (_C 'each'))
  # a FUEL SAVER line on an LB commodity prices per lb off its own trailing token - the clause goes, the
  # price stays. This is the row that proves the strip does not simply blank the line.
  _Near 'FUEL SAVER on an lb commodity prices $5.99/lb' (Get-UnitPrice (_D ('Smart Chicken boneless skinless chicken thighs, FUEL SAVER EARN 3' + [char]0x00A2 + ' OFF PER GALLON, $5.99 lb.') 'Smart Chicken boneless skinless chicken thighs' $null '') (_C 'lb')).unit_price 5.99 0.001
  # MUST NOT FIRE: a real cents PRICE is not a fuel-saver reward. The strip is anchored on OFF PER GALLON,
  # so the shape that made this fix risky at all still prices exactly as it did.
  _Near 'MUST NOT FIRE  "Bananas, 49 cents lb." still prices 0.49/lb' (Get-UnitPrice (_D ('Bananas, 49' + [char]0x00A2 + ' lb.') 'Bananas' $null '') (_C 'lb')).unit_price 0.49 0.001
  # CLEAN TWIN: the Hy-Vee storage-bags row from the same ad, no fuel-saver clause, still priced (not blanked).
  # Its value moved 0.0299 -> 0.0399 on 2026-09-25 (queue 2026-09-19-dc1b5b): a count range takes its SMALLER count,
  # 2.99/75, the same least favourable reading a weight range has taken since plan-2026-09-22-5.
  _Near 'CLEAN TWIN  Hy-Vee storage bags 75 to 100 ct., $2.99 (least favourable 75)' (Get-UnitPrice (_D 'Hy-Vee storage bags, 75 to 100 ct., $2.99' 'Hy-Vee storage bags' $null '') (_C 'each')).unit_price 0.0399 0.0001

  # --- 11c-quater: A SAVINGS CLAUSE IS NOT A PRICE EITHER (2026-09-18, queue 2026-09-18-f90ba6) ------------
  # The two rows that held the board from 09-14 to 09-18, frozen verbatim off comparison-2026-09-17 (Hy-Vee,
  # 0.5/each, note 'cents', guard 8d HARD FAIL). Both are each-commodities whose line states no count. The
  # 50 cents was accepted as a per-each RATE only because a cents read is not a plain package price; once the
  # line reads its own dollar, the existing "bare package price with unknown count -> drop" rule in the each
  # branch of Get-UnitPrice refuses it, exactly as it refuses Gain Flings above. So the honest answer is
  # UNPRICED (the cell falls to a store we can divide), and the price the line DOES carry is proven separately.
  # Literals and the concatenated cent sign follow the 11c-ter rules above.
  _Null 'MUST FIRE  Hy-Vee mini donuts, SAVE 50 cents, $1.99 no longer prices as 50 cents (no count: UNPRICED)' (Get-UnitPrice (_D ('Hy-Vee mini donuts, SAVE 50' + [char]0x00A2 + ', $1.99') ('Hy-Vee mini donuts, SAVE 50' + [char]0x00A2 + ', $1.99') $null '') (_C 'each'))
  _Null 'MUST FIRE  Quaker protein bars, SAVE 50 cents, $3.98 no longer prices as 50 cents (no count: UNPRICED)' (Get-UnitPrice (_D ('Quaker protein bars, SAVE 50' + [char]0x00A2 + ', $3.98') ('Quaker protein bars, SAVE 50' + [char]0x00A2 + ', $3.98') $null '') (_C 'each'))
  _Near 'the donuts line reads its own $1.99 as the price' (Get-ItemPrice ('Hy-Vee mini donuts, SAVE 50' + [char]0x00A2 + ', $1.99') 'Hy-Vee mini donuts' $null).per_item 1.99 0.001
  _Near 'the protein-bars line reads its own $3.98 as the price' (Get-ItemPrice ('Quaker protein bars, SAVE 50' + [char]0x00A2 + ', $3.98') 'Quaker protein bars' $null).per_item 3.98 0.001
  _Near 'MUST FIRE  the mojibake twin (U+00C2 U+00A2) of the donuts line reads 1.99' (Get-ItemPrice ('Hy-Vee mini donuts, SAVE 50' + [char]0x00C2 + [char]0x00A2 + ', $1.99') 'Hy-Vee mini donuts' $null).per_item 1.99 0.001
  _Near 'MUST FIRE  SAVE with the bang (Zevia soda, SAVE! 50 cents, $5.99) reads 5.99' (Get-ItemPrice ('Zevia soda, SAVE! 50' + [char]0x00A2 + ', $5.99') 'Zevia soda' $null).per_item 5.99 0.001
  _Near 'MUST FIRE  the coupon shape (pickles, - 50 cents off with digital coupon, $1.99) reads 1.99' (Get-ItemPrice ('Hy-Vee pickles, - 50' + [char]0x00A2 + ' off with digital coupon, $1.99') 'Hy-Vee pickles' $null).per_item 1.99 0.001
  # THE STRUCTURAL RULE, ALONE: the donuts line reworded so NEITHER strip matches ("SAVE UP TO"). Only the
  # cents-beside-a-dollar rule in the cents branch stands between this line and 50 cents, which is what proves
  # that rule is load-bearing on its own and not a restatement of the two strips.
  _Near 'MUST FIRE  a savings wording no strip knows (SAVE UP TO 50 cents, $1.99) still reads 1.99' (Get-ItemPrice ('Hy-Vee mini donuts, SAVE UP TO 50' + [char]0x00A2 + ', $1.99') 'Hy-Vee mini donuts' $null).per_item 1.99 0.001
  # MUST NOT FIRE: a cents price on a line with no dollar amount anywhere still prices off its cents.
  _Near 'MUST NOT FIRE  "Limes, 25 cents each" (no dollar amount) still reads 0.25' (Get-ItemPrice ('Limes, 25' + [char]0x00A2 + ' each') 'Limes' $null).per_item 0.25 0.001
  # THE PRICE FIELD WINS OVER A PRICE IN THE NAME (2026-09-29, queue 2026-09-29-c70eb2). Frozen from
  # candidates-2026-09-29: Fareway's ad line names its own per-lb rate, and the engine read that rate as the
  # item price and then divided it by the 2.5 lb size again (1.596, published 2026-09-28). Pre-fix: 1.596.
  _Near 'MUST FIRE  Fareway bacon "(only $3.99/lb)" with price_text $9.97 / 2.5 lb prices 3.988/lb, never 1.596' (Get-UnitPrice (_D '$9.97' 'Fareway Hickory Smoked Bacon 2.5 lb (only $3.99/lb)' $null '2.5 lb') (_C 'lb')).unit_price 3.988 0.001
  _Near 'MUST FIRE  the same line reads $9.97 from the price field, not $3.99 from the name' (Get-ItemPrice '$9.97' 'Fareway Hickory Smoked Bacon 2.5 lb (only $3.99/lb)' $null).per_item 9.97 0.001
  # CLEAN TWINS: the NAME-only per-lb branch still divides a package price, a multibuy in the name agrees with
  # its per-item price field, and a name-only price (no money in the price field) still prices off the name.
  _Near 'MUST NOT FIRE  "Kirkwood Chicken Thighs, Per LB" $9.39 / 4.1 lb stays 2.2902' (Get-UnitPrice (_D '$9.39' 'Kirkwood Chicken Thighs, Per LB' $null '4.1 lb') (_C 'lb')).unit_price 2.2902 0.001
  _Near 'MUST NOT FIRE  "Pork Ribeye Chops (4/$5)" price_text $1.25 still reads 1.25 per item' (Get-ItemPrice '$1.25' 'Pork Ribeye Chops (4/$5)' $null).per_item 1.25 0.001
  _Near 'MUST NOT FIRE  empty price field still reads the name ("Pork Ribeye Chops (4/$5)" -> 1.25)' (Get-ItemPrice '' 'Pork Ribeye Chops (4/$5)' $null).per_item 1.25 0.001

  # --- 11d: SIZE-PARSER DIVERGENCE FIXES (2026-07-30) - the engine vs pu-lib split, closed --------------
  # Every case is a REAL row from 2026-07-29: Bush's beans band-flagged at $0.3988/oz, Hy-Vee Cola flagged
  # at $0.3933/floz, Sam's grits PUBLISHED at $0.1049/oz (".98 oz" read as 98 oz), Kemps OJ band-dropped
  # at $0.007/floz (".5 Gal." read as 5 gal). MUST-FIRE: cases 1,3,4,5 all fail on the pre-fix engine.
  _Near 'weight-first pack "16 oz 6 pk"'   (Get-UnitPrice (_D '$6.38' "Bush's Garbanzo Beans, 6 pk" $null '16 oz 6 pk') (_C 'oz')).unit_price 0.0665 0.001
  _Near 'pack-first order (must stay)'     (Get-UnitPrice (_D '$6.38' "Bush's Garbanzo Beans, 6 pk" $null '6 pk 16 oz') (_C 'oz')).unit_price 0.0665 0.001
  _Near 'x-separator "12 x 12 fl oz"'      (Get-UnitPrice (_D '$4.72' 'Hy-Vee Cola 12Pk' $null '12 x 12 fl oz') (_C 'floz')).unit_price 0.0328 0.001
  # MUST-FIRE (2026-08-28): a size that states its own pack TOTAL in brackets. The pack-first branch's
  # \D+? gap crossed the "(" and read "2 pk (32 oz)" as two packs OF 32 oz - 64 oz for a 32 oz product.
  # Real row: shaved-beef-steak|Sam's Club, Demakes Bros. Choice Beef Shaved Steak $17.47, PUBLISHED at
  # $4.3675/lb against a true $8.735/lb, which also mis-awarded the row's Cheapest badge (Aldi wins it at
  # $7.3714) and blew up philly-cheesesteak-stuffed-peppers' cheapest-per-serving to $18.28 vs a $4.37
  # everyday. Fails at 4.3675 on the pre-fix engine. pu-lib has always read this string correctly.
  _Near 'bracketed pack total "2 pk (32 oz)"' (Get-UnitPrice (_D '$17.47' 'Demakes Bros. Choice Beef Shaved Steak' $null '16 oz x 2 pk (32 oz)') (_C 'lb')).unit_price 8.735 0.001
  # THE OPPOSITE DIRECTION, and why the arithmetic decides rather than the bracket: "6 pk (12 fl oz)"
  # names a PER-ITEM size, so its total is 72 fl oz, not 12. Nothing in the string multiplies to 12, so
  # the bracket is not taken. A blanket "trailing bracket wins" rule would price this six-pack as one can.
  _Near 'bracketed PER-ITEM size stays a pack' (Get-UnitPrice (_D '$5.99' 'Sparkling Water 6 pk' $null '6 pk (12 fl oz)') (_C 'floz')).unit_price 0.0832 0.001
  # the times-sign twin, built from [char]0x00D7 so this file never carries the literal. MUST-FIRE:
  # the 2026-07-30 batch shipped the times branch as a literal while this file was BOM-less and read
  # as ANSI - two mojibake chars that can never match a real U+00D7 - and every suite stayed green
  # because only ASCII 'x' was fixtured. This case is the one that goes red if the escape regresses.
  _Near ('times-sign "12 ' + [char]0x00D7 + ' 12 fl oz"') (Get-UnitPrice (_D '$4.72' 'Hy-Vee Cola 12Pk' $null ('12 ' + [char]0x00D7 + ' 12 fl oz')) (_C 'floz')).unit_price 0.0328 0.001
  # THE CENT-SIGN TWIN of the times-sign case above, and the one that goes red if the cents branch ever
  # regresses to a literal. Until 2026-08-26 that branch carried the MOJIBAKE pair U+00C2 U+00A2, so it
  # priced corrupted input and returned NOTHING for a real cent sign - and no fixture noticed, because the
  # only cent-bearing case in this suite ("SAVE! 50c" above) is answered by the savings branch long before
  # the cents branch is reached, and passes either way. Both spellings are asserted: the clean glyph the
  # fixed capture sink delivers, and the mangled pair still present in captures inside the carry window.
  _Near ('cent-sign "88' + [char]0x00A2 + '"')                (Get-UnitPrice (_D ('88' + [char]0x00A2) 'Store brand cabbage' $null $null) (_C 'each')).unit_price 0.88 0.001
  _Near ('cent-sign mojibake twin (carry window)')            (Get-UnitPrice (_D ('88' + [char]0x00C2 + [char]0x00A2) 'Store brand cabbage' $null $null) (_C 'each')).unit_price 0.88 0.001
  # the x-branch must NOT read marketing '2X' as a pack count (the each-number is required immediately):
  # with the lazy gap this halved 4 live cleaner names ('2X Concentrated ... 33.8 fl oz' -> 67.6).
  _Near '2X-marketing not a pack count'     (Get-UnitPrice (_D '$4.24' 'cleaner' $null 'fabuloso multi-purpose cleaner, 2x concentrated formula, lavender, 33.8 fl oz') (_C 'floz')).unit_price 0.1254 0.001
  _Near 'leading-dot ".98 oz" + name pack' (Get-UnitPrice (_D '$10.28' 'Quaker Instant Grits, Variety Pack, .98 oz., 46 pk.' $null '46 ct') (_C 'oz')).unit_price 0.228 0.001
  _Near 'leading-dot ".5 Gal." via name'   (Get-UnitPrice (_D '$4.49' 'Kemps 100% Pure Orange Juice From Concentrate .5 Gal. Jug' $null '0.5 gll') (_C 'floz')).unit_price 0.0702 0.001
  # ---- NAME VOLUME ON A FL-OZ COMMODITY WHOSE SIZE FIELD IS A BARE WEIGHT LABEL (2026-09-10, queue 2026-09-10-d9e085) ----
  # THE FOUNDING ROW, verbatim from out\sams\sams-deals-2026-09-10.json (sams_item_id 2RM6ZTFLHABN): Sam's printed
  # $0.09/oz, the capture derived size '122 oz' = 10.98 / 0.09, and the fl-oz commodity divided by that quotient.
  # Before the fix this priced 0.0900 with basis 'size 122 floz' and left a WEIGHT-kind size on a volume cell,
  # which is the one kind_mismatch_crown that held the 2026-09-10 board.
  $nvfRanch = Get-UnitPrice (_D '$10.98' "Member's Mark Ranch Dressing, 1 gal." $null '122 oz') (_C 'floz')
  _Near 'MUST FIRE  ranch 1 gal. with a 122 oz quotient size prices from the NAME volume (10.98 / 128)' $nvfRanch.unit_price 0.0858 0.0001
  if (($nvfRanch -is [hashtable]) -and ([string]$nvfRanch.basis -match 'NAME volume') -and ([string]$nvfRanch.size_override -eq '128 fl oz')) { Write-Output ('ok    MUST FIRE  ...its basis names the NAME volume and the cell size becomes ''' + $nvfRanch.size_override + '''') }
  else { Write-Output ('FAIL  MUST FIRE  ranch basis/size_override: basis=''' + $nvfRanch.basis + ''' size_override=''' + $nvfRanch.size_override + ''''); $script:fail++ }
  _Near 'MUST FIRE  the 09-02 capture of the same jug (135.25 oz = 10.82 / 0.08) lands on 128 as well' (Get-UnitPrice (_D '$10.82' "Member's Mark Ranch Dressing, 1 gal." $null '135.25 oz') (_C 'floz')).unit_price 0.08453 0.0001
  _Near 'MUST FIRE  Frank''s RedHot 1 gal. at a 129 oz quotient prices 15.48 / 128' (Get-UnitPrice (_D '$15.48' "Frank's RedHot Original Cayenne Pepper Hot Sauce, 1 gal." $null '129 oz') (_C 'floz')).unit_price 0.1209 0.0001
  $nvfBbq = Get-UnitPrice (_D '$11.98' "Sweet Baby Ray's Original Barbecue Sauce, 1 gal." $null '171.143 oz') (_C 'oz')
  _Near 'CLEAN TWIN  the same gallon shape on an OZ commodity keeps its 171.143 oz size (a 1.3 g/ml sauce really weighs that)' $nvfBbq.unit_price 0.0700 0.0001
  $nvfMilk = Get-UnitPrice (_D '$2.39' 'Our Family Milk, Lowfat, Chocolate 0.5 Gal' $null '64 oz') (_C 'floz')
  _Near 'CLEAN TWIN  Family Fare 0.5 Gal at 64 oz prices 2.39 / 64 before and after' $nvfMilk.unit_price 0.03734 0.0001
  if (($nvfMilk -is [hashtable]) -and ([string]$nvfMilk.size_override -eq '64 fl oz')) { Write-Output 'ok    CLEAN TWIN  ...and its emitted size flips to the truthful kind, 64 fl oz' }
  else { Write-Output ('FAIL  CLEAN TWIN  Family Fare 0.5 Gal size_override=''' + $nvfMilk.size_override + ''''); $script:fail++ }
  # The name parser on its own, because the bar below would mask a misread: ".5 Gal" read as 5 gal is 10x the size
  # and is refused by the bar either way, so only a direct assertion proves the fraction and the leading dot.
  _Near 'MUST NOT FIRE  a name ".5 Gal." is 64 fl oz, never 640' (Get-NameVolumeFloz 'Kemps Orange Juice .5 Gal. Jug') 64 0.0001
  _Near 'MUST NOT FIRE  a name "1/2 Gal" is 64 fl oz, never 256' (Get-NameVolumeFloz 'Hy-Vee Orange Juice 1/2 Gal') 64 0.0001
  _Near 'CLEAN TWIN  a name "1 L (33.8 Fl Oz)" is 33.814 fl oz' (Get-NameVolumeFloz 'Crest Mouthwash Pro Health, Clean Mint, 1 L (33.8 Fl Oz) 33.8 Oz') 33.814 0.0001
  if ($null -eq (Get-NameVolumeFloz 'Brand A Juice 1 gal or Brand B Juice 2 qt')) { Write-Output 'ok    MUST NOT FIRE  a name stating TWO volumes states no single one' }
  else { Write-Output 'FAIL  MUST NOT FIRE  a two-volume name returned a volume'; $script:fail++ }
  $nvfPack = Get-UnitPrice (_D '$6.00' 'Cola 2 L, 6 pk' $null '405.6 oz') (_C 'floz')
  _Near 'MUST NOT FIRE  a 6-pack of 2 L bottles keeps its 405.6 oz pack size (6.0x one bottle is outside the bar)' $nvfPack.unit_price 0.01479 0.0001
  $nvfFl = Get-UnitPrice (_D '$10.98' "Member's Mark Ranch Dressing, 1 gal." $null '128 fl oz') (_C 'floz')
  _Near 'CLEAN TWIN  a size already stated in fl oz is the store''s own volume and is untouched' $nvfFl.unit_price 0.0858 0.0001
  if (($nvfPack -is [hashtable]) -and ($nvfBbq -is [hashtable]) -and ($nvfFl -is [hashtable]) -and -not $nvfPack.ContainsKey('size_override') -and -not $nvfBbq.ContainsKey('size_override') -and -not $nvfFl.ContainsKey('size_override')) { Write-Output 'ok    MUST NOT FIRE  no size_override on the multipack, the OZ commodity, or a size already in fl oz' }
  else { Write-Output 'FAIL  MUST NOT FIRE  a size_override appeared where the size field was already the right quantity'; $script:fail++ }
  # THE EMISSION compare-deals runs at its matched-row add, through the same function.
  if (((Resolve-CellSizeText '122 oz' $nvfRanch) -eq '128 fl oz') -and ((Resolve-CellSizeText '171.143 oz' $nvfBbq) -eq '171.143 oz') -and ((Resolve-CellSizeText '12 oz' $null) -eq '12 oz')) { Write-Output 'ok    MUST FIRE  the cell carries 128 fl oz for the ranch jug; CLEAN TWIN every other row keeps its store size' }
  else { Write-Output ('FAIL  Resolve-CellSizeText: ranch=''' + (Resolve-CellSizeText '122 oz' $nvfRanch) + ''' bbq=''' + (Resolve-CellSizeText '171.143 oz' $nvfBbq) + ''''); $script:fail++ }
  # --- 11d2: PACK COUNT BEATS THE PER-EACH MARKER (2026-08-22) ----------------------------------------------
  # MUST-FIRE: "Bottled Water 24 Pack, $3.87 each" on an each-commodity is 24 bottles at $0.161, not one at
  # $3.87 - the marker used to return before Get-PackCount ran. Both orderings (count in the name, count in
  # the size) and the marker in the price text. pu-lib's fixture for the same row lives in test-pu-lib.ps1.
  _Near 'per-each marker + "24 Pack" in NAME -> /24'    (Get-UnitPrice (_D '$3.87 each' 'Bottled Water 24 Pack' $null 'each') (_C 'each')).unit_price 0.16125 0.0005
  _Near 'per-each marker + "24 ct" in SIZE -> /24'      (Get-UnitPrice (_D '$3.87 each' 'Bottled Water' $null '24 ct') (_C 'each')).unit_price 0.16125 0.0005
  _Near 'per-each marker, no pack anywhere -> per-each' (Get-UnitPrice (_D '$3.87 each' 'Bottled Water' $null 'each') (_C 'each')).unit_price 3.87 0.001
  # --- 11d3: A PER-EACH MARKER IN THE NAME DOES NOT MAKE A PER-POUND PRICE PER EACH (2026-09-18, backlog I222) --
  # The founding row, frozen from walmart-capture-2026-08-31.csv: "Fresh Purple Eggplant, Each | $1.82 | $1.82/lb",
  # reaching the builder's output as size "lb". The marker came from the NAME and priced $1.82 each.
  _Null 'MUST FIRE  Walmart "Fresh Purple Eggplant, Each" $1.82 size lb is UNPRICED, not $1.82 each' (Get-UnitPrice (_D '$1.82' 'Fresh Purple Eggplant, Each' $null 'lb') (_C 'each'))
  _Null 'MUST FIRE  the 2026-07-25 sighting of the same eggplant, size "1 lb", is UNPRICED too'      (Get-UnitPrice (_D '$1.82' 'Fresh Purple Eggplant, Each' $null '1 lb') (_C 'each'))
  _Null 'MUST FIRE  Walmart "Fresh Pickling Cucumbers, Each" $1.56 size lb is UNPRICED'             (Get-UnitPrice (_D '$1.56' 'Fresh Pickling Cucumbers, Each' $null 'lb') (_C 'each'))
  _Near 'CLEAN TWIN  a weight_is_one_unit loaf named "..., Each" at 14 oz still prices one loaf'     (Get-UnitPrice (_D '$1.47' 'French Bread Loaf, Each' $null '14 oz') (_CW 'each')).unit_price 1.47 0.001
  _Near 'CLEAN TWIN  Walmart "Fresh Cantaloupe, Each" $2.50 size each still prices $2.50 each'       (Get-UnitPrice (_D '$2.5' 'Fresh Cantaloupe, Each' $null 'each') (_C 'each')).unit_price 2.5 0.001
  _Near 'CLEAN TWIN  a price text that itself says each ("$2.99 each") still wins over a lb size'   (Get-UnitPrice (_D '$2.99 each' 'Cantaloupe' $null 'lb') (_C 'each')).unit_price 2.99 0.001
  _Near 'CLEAN TWIN  the same "$1.82" row on a POUND commodity still prices $1.82/lb'                (Get-UnitPrice (_D '$1.82 lb' 'Fresh Purple Eggplant, Each' $null 'lb') (_C 'lb')).unit_price 1.82 0.001
  # the decimal in "$3.87 each" must never be read as an 87-pack (Get-PackCount's lookbehind)
  if ($null -eq (Get-PackCount '$3.87 each')) { Write-Output 'ok    "$3.87 each" is not an 87-pack' } else { Write-Output 'FAIL  Get-PackCount read "$3.87 each" as a pack count'; $script:fail++ }
  # a pack_is_package commodity keeps the package price even with the marker (the garlic-bread ruling)
  _Near 'pack_is_package + marker stays per-package'    (Get-UnitPrice (_D '$6.99 each' 'Texas Toast' $null '6 ct') (_CP 'each')).unit_price 6.99 0.001
  # --- 11d3: LITRE / ML / QUART MULTIPACKS, WEIGHT-FIRST (2026-08-22) -------------------------------------
  # MUST-FIRE: "2 l 6 pk" is 12 litres = 405.77 fl oz; it was multiplied for oz/lb/gal only. Both orderings.
  _Near 'weight-first "2 l 6 pk" /floz'     (Get-UnitPrice (_D '$6.00' 'Cola 6 pk' $null '2 l 6 pk') (_C 'floz')).unit_price 0.014787 0.0001
  _Near 'pack-first "6 pk 2 l" /floz'       (Get-UnitPrice (_D '$6.00' 'Cola 6 pk' $null '6 pk 2 l') (_C 'floz')).unit_price 0.014787 0.0001
  _Near 'weight-first "500 ml 24 pk" /floz' (Get-UnitPrice (_D '$4.87' 'Water 24 pk' $null '500 ml 24 pk') (_C 'floz')).unit_price 0.012 0.0005
  _Near 'weight-first "1 qt 4 pk" /floz'    (Get-UnitPrice (_D '$8.00' 'Broth 4 pk' $null '1 qt 4 pk') (_C 'floz')).unit_price 0.0625 0.0005
  _Near 'weight-first "2 ltr 6 pk" /floz'   (Get-UnitPrice (_D '$6.00' 'Cola 6 pk' $null '2 ltr 6 pk') (_C 'floz')).unit_price 0.014787 0.0001
  # --- 11e: pack_is_package - portion count inside ONE package (2026-07-30 garlic-bread basis bug) ---------
  # The live row: Baker's "New York Bakery Gluten Free Texas Toast" $6.99 / "6 ct" published $1.165/each and
  # took the cheapest slot from Fareway's whole $3.99 loaf. MUST-FIRE: with the declaration the price stays the
  # PACKAGE price. CLEAN TWIN: the identical row on an undeclared commodity must still divide, because that is
  # what every other each-commodity (bagels, buns, popsicles, corn) needs.
  _Near 'pack_is_package: 6 ct stays per-package' (Get-UnitPrice (_D '$6.99' 'New York Bakery Texas Toast with Real Garlic' $null '6 ct') (_CP 'each')).unit_price 6.99 0.001
  _Near 'undeclared commodity still divides'      (Get-UnitPrice (_D '$6.99' 'New York Bakery Texas Toast with Real Garlic' $null '6 ct') (_C  'each')).unit_price 1.165 0.001
  # the declaration must not invent a basis where there is no count at all - a bare loaf is still per-each
  _Near 'pack_is_package: no count -> per-each'   (Get-UnitPrice (_D '$3.99' 'Fareway Garlic Bread' $null 'each') (_CP 'each')).unit_price 3.99 0.001

  # --- 11e2: weight_is_one_unit - A PACKAGED GOOD'S WEIGHT IS ITS COUNT (2026-09-06) ----------------------
  # The live row, frozen from walmart-regular-2026-09-05 and the reason this declaration exists: Walmart's
  # CURRENT french-bread capture states the loaf's weight, was therefore unpriceable, and so the board went
  # on publishing $1.25 from a 07-18 capture whose size was the word "each" - a stale cell, not a missing
  # one. MUST-FIRE: the declaring commodity reads the shelf price as the price of one loaf.
  _Near 'weight_is_one_unit: 14 oz loaf is one loaf' (Get-UnitPrice (_D '$1.47' 'Freshness Guaranteed French Bakery Bread Loaf, 14 oz, 1 Loaf' $null '14 oz') (_CW 'each')).unit_price 1.47 0.001
  # CLEAN TWIN 1 - THE PRODUCE GUARD, and the whole reason this is a per-commodity declaration rather than a
  # blanket rule. The identical row on an UNDECLARED commodity must still be refused, because for produce a
  # weight really is an unknown number of items.
  _Null 'weight_is_one_unit: undeclared commodity still refuses a weight-only row' (Get-UnitPrice (_D '$1.47' 'Freshness Guaranteed French Bakery Bread Loaf, 14 oz, 1 Loaf' $null '14 oz') (_C 'each'))
  # CLEAN TWIN 2 - the produce row itself, on an undeclared commodity, still refused. Written this way on
  # purpose: "a kiwi commodity carrying the flag" is not a behaviour to pin, it is a RULE ERROR, and the
  # thing that must never happen is the flag reaching produce at all. audit-weight-is-one-unit.ps1 is the
  # test for that half; this is the engine half.
  _Null 'weight_is_one_unit: a 2 lb produce bag on an undeclared commodity still refuses' (Get-UnitPrice (_D '$7.57' 'Organic Green Kiwi, 2 lbs.' $null '2 lb') (_C 'each'))
  # CLEAN TWIN 3 - a REAL pack count still divides. The declaration answers a row with NO count; it must not
  # outrank one that has a count, or a 2-pack of loaves would publish as one loaf at twice the price.
  _Near 'weight_is_one_unit: a real pack count still divides' (Get-UnitPrice (_D '$5.98' 'Nature Own Butterbread, 2 pack, 30 oz' $null '2 pack 30 oz') (_CW 'each')).unit_price 2.99 0.001
  # CLEAN TWIN 4 - the declaration must not invent a basis out of nothing. No count and no weight anywhere
  # is still an unknown package, and it still drops.
  _Null 'weight_is_one_unit: no count and no weight is still a drop' (Get-UnitPrice (_D '$4.99' 'Bakery Mystery Tray' $null 'pkg') (_CW 'each'))

  # --- 11e3: sq_ft - THE AREA UNIT (2026-09-06 foil ruling) ----------------------------------------------
  # aluminum-foil had no board row at ALL: Convert-ToUnit had no sq_ft arm, so all 47 matched rows returned
  # null and the commodity read, from outside, like a foil Omaha does not sell.
  # MUST-FIRE 1 - the store states the area in size_text.
  _Near 'sq_ft: 75 sq ft from size_text' (Get-UnitPrice (_D '$4.98' 'Hy Vee Aluminum Foil' $null '75 sq ft') (_C 'sq_ft')).unit_price 0.0664 0.0001
  # MUST-FIRE 2 - the store states a COUNT in size_text and the area only in the NAME. "200 ct" is not an
  # area, so it must convert to nothing and let the name fallback answer.
  _Near 'sq_ft: 200 sq. ft. read from the NAME when size says 200 ct' (Get-UnitPrice (_D '$20.99' 'Reynolds Wrap Aluminum Foil 200 sq. ft. Box' $null '200 ct') (_C 'sq_ft')).unit_price 0.10495 0.0001
  # MUST-FIRE 3 - Baker's truncates product names at 60 characters, mid-word.
  _Near 'sq_ft: the 60-char truncation "Square Fee" still reads' (Get-UnitPrice (_D '$6.99' 'Reynolds Wrap Heavy Duty Aluminum Foil Food Wrap 12 INCH 50 Square Fee' $null 'each') (_C 'sq_ft')).unit_price 0.1398 0.0001
  # CLEAN TWIN 1 - A COUNT IS NOT AN AREA. Pre-cut pop-up sheets state "50 ct" and give an area nowhere;
  # crowning them at $0.0896 "per sq ft" would be a fabricated basis on a product that is not roll foil.
  _Null 'sq_ft: pre-cut pop-up SHEETS (50 ct, no area) stay unpriced' (Get-UnitPrice (_D '$4.48' 'Reynolds Wrap Pre-Cut Pop-Up Aluminum Foil Sheets, 14 x 10.25 inches, 50 Sheets' $null '50 ct') (_C 'sq_ft'))
  # CLEAN TWIN 2 - and no leakage the other way: a weight commodity handed an area token gets nothing.
  _Null 'sq_ft: a lb commodity handed "75 sq ft" returns null (no cross-unit leakage)' (Get-UnitPrice (_D '$4.98' 'Hy Vee Aluminum Foil' $null '75 sq ft') (_C 'lb'))

  # --- 11e4: the count vocabulary, shared (2026-09-06) ----------------------------------------------------
  # MUST-FIRE: Hy-Vee prices iceberg lettuce by the HEAD. lettuce is an each-commodity, "head" was in
  # Convert-ToUnit's each arm but in NEITHER bare-size gate, and Hy-Vee simply had no lettuce cell.
  _Near 'count vocabulary: a bare "head" is one lettuce' (Get-UnitPrice (_D '$1.97' 'Bud Iceberg Lettuce' $null 'head') (_C 'each')).unit_price 1.97 0.001
  _Near 'count vocabulary: a bare "loaf" is one loaf'    (Get-UnitPrice (_D '$2.49' 'Bakery Fresh French Bread' $null 'loaf') (_C 'each')).unit_price 2.49 0.001
  # CLEAN TWIN - and the container words stay OUT of it. A "pkg" is a box with an unknown number inside;
  # this is the drop the 2026-07-30 garlic-bread ruling turns on, and the case below it has guarded since.
  _Null 'count vocabulary: a bare "pkg" is still an unknown package' (Get-UnitPrice (_D '$4.99' 'mystery tray' $null 'pkg') (_C 'each'))
  # PARITY: the two bare-size gates must accept the SAME words. Testing them through behaviour rather than
  # through the constant, so a future hand-typed list in either place is caught by what it DOES.
  foreach ($tok in @('ct','count','ea','each','bunch','bunches','head','loaf')) {
    $viaEach = (Get-UnitPrice (_D '$3.00' 'parity probe' $null $tok) (_C 'each')).unit_price
    $viaSize = Get-SizeAmount $tok 'each'
    if ($viaEach -eq 3.00 -and $viaSize -eq 1) { Write-Output "ok    count vocabulary parity: '$tok' is one whole purchase in BOTH gates" }
    else { Write-Output "FAIL  count vocabulary parity: '$tok' disagrees between the gates (each-branch=$viaEach size-parser=$viaSize) - the three lists have drifted again"; $script:fail++ }
  }

  # --- 11f: max_pack_oz - the PACK FORM cap (2026-08-08 packet-vs-canister ruling) -------------------------
  # The live rows: "Taco Seasoning (packet)" was filled with McCormick Mild Taco Seasoning Mix 8.5 Oz, and
  # "Ranch Seasoning Mix (packet)" with Great Value Classic Ranch 8 oz Canister. Both are the bulk form of the
  # right contents, at a per-oz rate a packet buyer never pays. MUST-FIRE: the canister is rejected. CLEAN
  # TWINS: the real packet passes, an undeclared commodity is untouched, and an item whose size cannot be read
  # passes (an unknown size is not a violation - treating it as one would empty every store that omits sizes).
  $MAXPACK['_selftest-packet'] = 4
  if (-not (Test-PackSize '_selftest-packet' '8.5 oz' 'Mc Cormick Mild Taco Seasoning Mix 8.5 Oz')) { Write-Output 'ok    max_pack_oz rejects the 8.5 oz canister' } else { Write-Output 'FAIL  max_pack_oz let the bulk canister through'; $script:fail++ }
  if (-not (Test-PackSize '_selftest-packet' '8 oz' 'Great Value Classic Ranch Salad Dressing & Recipe Mix, 8 oz Canister')) { Write-Output 'ok    max_pack_oz rejects the 8 oz canister' } else { Write-Output 'FAIL  max_pack_oz let the ranch canister through'; $script:fail++ }
  if (Test-PackSize '_selftest-packet' '1.25 oz' 'Our Family Seasoning Mix, Taco 1.25 Oz') { Write-Output 'ok    max_pack_oz keeps the real 1.25 oz packet' } else { Write-Output 'FAIL  max_pack_oz rejected a real packet'; $script:fail++ }
  if (Test-PackSize '_selftest-packet' '4 oz' 'Great Value Classic Ranch Mix, 1 oz Packets, 4 Count') { Write-Output 'ok    max_pack_oz keeps a 4-count of packets' } else { Write-Output 'FAIL  max_pack_oz rejected a multi-packet box'; $script:fail++ }
  if (Test-PackSize '_selftest-packet' '' 'Taco Seasoning Mix') { Write-Output 'ok    max_pack_oz: unreadable size is NOT a violation' } else { Write-Output 'FAIL  max_pack_oz rejected an item whose size it could not read'; $script:fail++ }
  if (Test-PackSize 'undeclared-commodity' '8.5 oz' 'Mc Cormick Mild Taco Seasoning Mix 8.5 Oz') { Write-Output 'ok    max_pack_oz: undeclared commodity untouched' } else { Write-Output 'FAIL  max_pack_oz fired on a commodity that never declared it'; $script:fail++ }
  $MAXPACK.Remove('_selftest-packet')

  # --- 11f2: min_pack_oz - the PACK FORM FLOOR (2026-09-06 rotisserie ruling) -----------------------------
  # The live rows, all of which weight_is_one_unit made priceable on the same day, on a commodity whose
  # include is the bare word `rotisserie`: Land O'Frost Rotisserie Seasoned Turkey Breast 8 oz TOOK Family
  # Fare's cell off a real $7.99 whole chicken, and Aldi's "Lunch Mate Rotisserie Chicken 16 OZ" - deli
  # slices whose name contains no word to exclude on - would have opened a cell Aldi has no whole bird in.
  # MUST-FIRE: both are refused. CLEAN TWINS: the real whole birds pass, and the two that carry NO readable
  # size (the shape most whole-chicken rows actually have - "each", "1 ea") pass, because an unknown size
  # is not a violation. That last twin is the one that matters: get it wrong and this gate empties the
  # commodity it was written to protect.
  $MINPACK['_selftest-whole-bird'] = 32
  if (-not (Test-PackSizeFloor '_selftest-whole-bird' '8 oz' "Land O'Frost Bistro Favorites 100% Natural Rotisserie Seasoned Turkey Breast 8oz")) { Write-Output 'ok    min_pack_oz refuses the 8 oz turkey breast' } else { Write-Output 'FAIL  min_pack_oz let the deli turkey breast hold a rotisserie-chicken cell'; $script:fail++ }
  if (-not (Test-PackSizeFloor '_selftest-whole-bird' '16 oz' 'Lunch Mate Rotisserie Chicken 16 OZ')) { Write-Output 'ok    min_pack_oz refuses the 16 oz deli pack (no word in it to exclude on)' } else { Write-Output 'FAIL  min_pack_oz admitted a 16 oz deli pack as a whole chicken'; $script:fail++ }
  if (Test-PackSizeFloor '_selftest-whole-bird' '2.25 lb' '(Hot) Freshness Guaranteed Traditional Rotisserie Whole Chicken, 2.25 lb') { Write-Output 'ok    min_pack_oz keeps the 2.25 lb whole bird' } else { Write-Output 'FAIL  min_pack_oz rejected a real whole rotisserie chicken'; $script:fail++ }
  if (Test-PackSizeFloor '_selftest-whole-bird' '2 lb' 'Simple Truth Cold Deli Fresh Whole Rotisserie Chicken') { Write-Output 'ok    min_pack_oz is INCLUSIVE at the bound (2 lb = 32 oz passes)' } else { Write-Output 'FAIL  min_pack_oz is exclusive at the bound and drops the 2 lb birds'; $script:fail++ }
  if (Test-PackSizeFloor '_selftest-whole-bird' 'each' "Member's Mark Seasoned Rotisserie Chicken") { Write-Output 'ok    min_pack_oz: unreadable size is NOT a violation (this is most whole-bird rows)' } else { Write-Output 'FAIL  min_pack_oz treated a sizeless row as a violation - this empties the commodity'; $script:fail++ }
  if (Test-PackSizeFloor 'undeclared-commodity' '8 oz' "Land O'Frost Rotisserie Seasoned Turkey Breast 8 Oz") { Write-Output 'ok    min_pack_oz: undeclared commodity untouched' } else { Write-Output 'FAIL  min_pack_oz fired on a commodity that never declared it'; $script:fail++ }
  # THE MINI LOAF (2026-09-06, queue 2026-09-06-796030). Widening french-bread to admit Kroger's shelf name
  # 'French Loaf' also admits Fareway's 'Mini French Loaf' $1.49 / 8 oz, which is not a loaf of French bread
  # and would undercut every real one. It could not be observed on the 2026-09-06 board because that row
  # lives in fareway-deals-2026-09-06.json, whose ad window does not open until 2026-09-07 - so the board
  # could not answer the question and this fixture does. french-bread declares min_pack_oz 12 (b28788fa),
  # and 8 oz must lose to it. Frozen here rather than left to tomorrow's unattended build.
  $MINPACK['_selftest-loaf'] = 12
  if (-not (Test-PackSizeFloor '_selftest-loaf' '8 oz' 'Mini French Loaf')) { Write-Output 'ok    min_pack_oz refuses the 8 oz Fareway Mini French Loaf' } else { Write-Output 'FAIL  min_pack_oz admitted an 8 oz mini loaf - the french-bread widening will undercut every real loaf when the 09-07 Fareway ad opens'; $script:fail++ }
  if (Test-PackSizeFloor '_selftest-loaf' '16 oz' 'Private Selection French Loaf') { Write-Output 'ok    min_pack_oz keeps the real 16 oz French Loaf the widening was written for' } else { Write-Output 'FAIL  min_pack_oz rejected the 16 oz loaf the 2026-09-06 widening exists to admit'; $script:fail++ }
  if (Test-PackSizeFloor '_selftest-loaf' '12 oz' 'a loaf exactly at the floor') { Write-Output 'ok    min_pack_oz is INCLUSIVE at 12 oz for french-bread too' } else { Write-Output 'FAIL  min_pack_oz is exclusive at the bound and drops 12 oz loaves'; $script:fail++ }
  $MINPACK.Remove('_selftest-loaf')
  # and the two caps do not interfere: a commodity may declare either, both, or neither
  if (Test-PackSize '_selftest-whole-bird' '8 oz' 'anything') { Write-Output 'ok    min_pack_oz and max_pack_oz are independent declarations' } else { Write-Output 'FAIL  declaring min_pack_oz silently applied a max_pack_oz cap'; $script:fail++ }
  $MINPACK.Remove('_selftest-whole-bird')

  # --- 11f3: min_piece_oz - HOW BIG ONE PIECE HAS TO BE (2026-09-06, Brad's T2 ruling) --------------------
  # All rows frozen from the 2026-09-05 board. THE CASE THIS RULE EXISTS FOR is the third one: Totino's is
  # sold BOTH as a single 10.2 oz party pizza and as a 42 oz box of four, and a rule that could only see the
  # box would refuse the single while admitting the four-pack of the identical pizza. So the test divides by
  # the count the engine actually priced on, which is why Get-UnitPrice reports `pieces` back.
  $MINPIECE['_selftest-pizza'] = 12
  if (Test-PieceSize '_selftest-pizza' '27.3 oz' 'Di Giorno Frozen Pizza, Rising Crust Sausage & Pepperoni Pizza, 27.3oz' 1) { Write-Output 'ok    min_piece_oz keeps a 27.3 oz whole pizza' } else { Write-Output 'FAIL  min_piece_oz rejected a real full-size pizza'; $script:fail++ }
  if (-not (Test-PieceSize '_selftest-pizza' '10.2 oz' "Totino's Party Pizza, Pepperoni and Cheese, Thin Crust, 10.2 oz" 1)) { Write-Output 'ok    min_piece_oz refuses the single 10.2 oz party pizza' } else { Write-Output 'FAIL  min_piece_oz admitted a party pizza as a pizza'; $script:fail++ }
  if (-not (Test-PieceSize '_selftest-pizza' '42 oz' "Totino's Party Pizza, Triple Meat, Thin Crust, 42 oz, 4 Count" 4)) { Write-Output 'ok    min_piece_oz refuses the 4-COUNT box of the same party pizza (42 oz / 4 = 10.5)' } else { Write-Output 'FAIL  min_piece_oz saw only the box: a multipack of minis is admitted while the single is refused'; $script:fail++ }
  if (-not (Test-PieceSize '_selftest-pizza' '9 ct 5.40 oz' 'Red Baron Pepperoni French Bread Frozen Personal Pizza, 5.40 oz., 9 pk.' 9)) { Write-Output 'ok    min_piece_oz refuses a 9-pack of 5.40 oz personal pizzas' } else { Write-Output 'FAIL  min_piece_oz admitted single-serve pizzas'; $script:fail++ }
  # CLEAN TWIN, and the load-bearing one: MOST real frozen-pizza rows state only "each" (Fareway's whole
  # column, Walmart's Red Baron, Aldi's Mama Cozzi thin crust). A floor that condemned a sizeless row would
  # empty the commodity it was written to protect and leave only the minis it was written to refuse.
  if (Test-PieceSize '_selftest-pizza' 'each' 'Red Baron Four Cheese Classic Crust Frozen Pizza' 1) { Write-Output 'ok    min_piece_oz: unreadable size is NOT a violation (most real pizza rows say only "each")' } else { Write-Output 'FAIL  min_piece_oz condemned a sizeless row - this empties the commodity'; $script:fail++ }
  # a pack_is_package commodity compares PACKAGES, so its package IS its piece and must not be divided
  if (Test-PieceSize '_selftest-pizza' '8 ct 12.5 oz' 'a declared-package commodity, 12.5 oz total' 1) { Write-Output 'ok    min_piece_oz honours pieces=1 for a pack_is_package commodity' } else { Write-Output 'FAIL  min_piece_oz divided a package the board compares whole'; $script:fail++ }
  if (Test-PieceSize 'undeclared-commodity' '4.2 oz' 'Great Value Pepperoni Pizza Snack Builders, 4.20 oz' 1) { Write-Output 'ok    min_piece_oz: undeclared commodity untouched' } else { Write-Output 'FAIL  min_piece_oz fired on a commodity that never declared it'; $script:fail++ }
  # a missing/zero pieces count must degrade to 1, never to a divide-by-zero or a silent pass
  if (-not (Test-PieceSize '_selftest-pizza' '4.2 oz' 'Great Value Pepperoni Pizza Snack Builders, 4.20 oz' $null)) { Write-Output 'ok    min_piece_oz treats an absent piece count as 1 rather than passing blind' } else { Write-Output 'FAIL  min_piece_oz passed a row whose piece count it could not read'; $script:fail++ }
  # --- THE REFUSAL ORDER (2026-09-18, queue 2026-09-18-f90ba6): the definition is tested before the band ------
  # Frozen verbatim from flagged-2026-09-17.json, where each was filed as band '1.5-14' and counted by
  # audit-band-censorship as a price the band censored (the ratchet read 32 against 29). Each fails the piece
  # rule too, and a row that fails BOTH is the only case where the order shows, so the fixture band is
  # frozen-pizza's real 1.5-14. Never regenerate these from a board built after the reorder: it files them
  # as min_piece_oz already, so a regenerated fixture would pass by finding nothing.
  $BANDS['_selftest-pizza'] = [pscustomobject]@{ min = 1.5; max = 14 }
  $ordCases = @(
    @('Totino''s Party Pizza, Pepperoni, Thin Crust, 17g Protein, 40.8 oz, 4 Count (Frozen)', '40.8 oz', 1.4925, 4),
    @('Mama Cozzi''s Pizza Kitchen French Bread Pepperoni Pizza, 2 Count', '11.25 oz', 1.495, 2),
    @('Red Baron Pepperoni French Bread Frozen Personal Pizza, 5.40 oz., 9 pk.', '9 ct 5.40 oz', 1.4422, 9)
  )
  foreach ($oc in $ordCases) {
    $ordGot = Get-FirstRefusal '_selftest-pizza' 'each' $oc[2] $oc[1] $oc[0] $oc[3]
    if ($ordGot -eq 'piece') { Write-Output ('ok    MUST FIRE  refusal order: ' + $oc[0] + ' at ' + $oc[2] + ' is refused by the PIECE rule, not the band') }
    else { Write-Output ('FAIL  refusal order: ' + $oc[0] + ' read [' + $ordGot + '] - the band runs before the piece rule again, so audit-band-censorship counts a definitional refusal as price censorship'); $script:fail++ }
  }
  # CLEAN TWIN: a real full-size pizza ABOVE the band max still reads as a BAND refusal (the piece rule passes
  # it, so the sanity net is still the one that speaks), and the single 10.2 oz party pizza at an in-band price
  # still reads as a piece refusal, as it did before the reorder.
  $ordRao = Get-FirstRefusal '_selftest-pizza' 'each' 14.99 '18.3 oz' 'Rao''s Uncured Pepperoni Pizza 18.3 oz' 1
  if ($ordRao -eq 'band') { Write-Output 'ok    CLEAN TWIN  refusal order: Rao''s 18.3 oz at $14.99 passes the piece rule and is still refused by the band' } else { Write-Output ('FAIL  refusal order: Rao''s 18.3 oz at $14.99 read [' + $ordRao + '] instead of band'); $script:fail++ }
  $ordOne = Get-FirstRefusal '_selftest-pizza' 'each' 1.99 '10.2 oz' 'Totino''s Party Pizza, Pepperoni and Cheese, Thin Crust, 10.2 oz' 1
  if ($ordOne -eq 'piece') { Write-Output 'ok    CLEAN TWIN  refusal order: the single 10.2 oz party pizza at an in-band $1.99 is still a piece refusal' } else { Write-Output ('FAIL  refusal order: the single 10.2 oz party pizza read [' + $ordOne + '] instead of piece'); $script:fail++ }
  $ordTony = Get-FirstRefusal '_selftest-pizza' 'each' 2.96 '18.56 oz' 'Tony''s Pepperoni Pizzeria Style Crust Frozen Pizza, 18.56 oz' 1
  if ($ordTony -eq '') { Write-Output 'ok    CLEAN TWIN  refusal order: the Walmart Tony''s 18.56 oz at $2.96 (the live cell) is refused by nothing' } else { Write-Output ('FAIL  refusal order: the live Tony''s cell read [' + $ordTony + '] - a real pizza is refused'); $script:fail++ }
  $BANDS.Remove('_selftest-pizza')
  # --- A SIZE COUNT THAT DISAGREES WITH THE NAME IS REFUSED AS COUNT-CONFLICT (2026-09-25, queue 2026-09-22-8d2ad5) ---
  # Frozen verbatim from comparison-2026-09-23 / candidates-2026-09-23. The Benner row goes through the REAL
  # Get-UnitPrice first, so the case proves the engine's own basis (per-24-pack from the size field) is what is refused.
  $ccBen = Get-UnitPrice ([pscustomobject]@{ name='Benner Black Tea Bags 100 CT'; price_text='$1.49'; size_text='24 ct'; regular=$null }) ([pscustomobject]@{ unit='each' })
  $ccBenGot = if ($ccBen) { Get-FirstRefusal '_selftest-cc' 'each' ([math]::Round($ccBen.unit_price,4)) '24 ct' 'Benner Black Tea Bags 100 CT' $ccBen.pieces 'Aldi' } else { '<unpriced>' }
  if ($ccBenGot -eq 'count-conflict') { Write-Output ('ok    MUST FIRE  count-conflict: Aldi Benner Black Tea Bags 100 CT sized 24 ct (' + $ccBen.basis + ') is refused, not priced per 24') } else { Write-Output ('FAIL  count-conflict: Benner 100 CT sized 24 ct read [' + $ccBenGot + '] - a size count the name contradicts is a basis again'); $script:fail++ }
  $ccWil = Get-FirstRefusal '_selftest-cc' 'each' 0.0087 '160 ct' 'Willow Facial Tissue 144 CT' 160 'Aldi'
  if ($ccWil -eq 'count-conflict') { Write-Output 'ok    MUST FIRE  count-conflict: Aldi Willow Facial Tissue 144 CT sized 160 ct is refused' } else { Write-Output ('FAIL  count-conflict: Willow 144 CT sized 160 ct read [' + $ccWil + ']'); $script:fail++ }
  # The sub-unit shape, and it must be called COUNT-CONFLICT even with a band that would also refuse it.
  $BANDS['_selftest-cc'] = [pscustomobject]@{ min = 0.5; max = 3 }
  $ccBou = Get-FirstRefusal '_selftest-cc' 'each' 0.0283 '246 ct' 'Bounty Paper Towels Select-A-Size White, 2 Triple Rolls, 123 Sheets per Roll' 246 'Walmart'
  if ($ccBou -eq 'count-conflict') { Write-Output 'ok    MUST FIRE  count-conflict: Walmart Bounty 2 Triple Rolls, 123 Sheets per Roll sized 246 ct (a sheet count) is COUNT-CONFLICT, not OUT-OF-BAND' } else { Write-Output ('FAIL  count-conflict: Bounty 246 ct of sheets read [' + $ccBou + '] instead of count-conflict'); $script:fail++ }
  $BANDS.Remove('_selftest-cc')
  # CLEAN TWINs: count-times-pack totals, a name with no count, a count that IS a multiple (at the bar: 200 = 2 x 100
  # exactly; a step past it, 201, fires), and a shrimp grade on a per-lb commodity all still price.
  $ccTwins = @(
    @('Marathon Embossed 1-Ply White Beverage Napkins, 6 pk., 3000 ct.', '3000 ct', 3000, 'each'),
    @('Q-tips Cotton Swabs, 1750 ct., 3 pk.', '1750 ct', 1750, 'each'),
    @('Kroger Facial Tissue', '160 ct', 160, 'each'),
    @('Selftest Tea Bags 100 CT', '200 ct', 200, 'each'),
    @('Scott 1000 Toilet Paper, 1000 Sheets per Roll', '8 ct', 8, 'each'),
    @('Suavitel Complete Dryer Sheets, Fabric Conditioner, Field Flowers, 70 Sheets', '70 ct', 70, 'each'),
    @('Member''s Mark Farm Raised Large Raw Shrimp, Frozen, 31-40 ct', '3 lb', 1, 'lb')
  )
  foreach ($tw in $ccTwins) {
    $twUp = if ($tw[3] -eq 'lb') { 7.99 } else { 0.05 }   # a real per-lb price clears the lb floor
    $twGot = Get-FirstRefusal '_selftest-cc' $tw[3] $twUp $tw[1] $tw[0] $tw[2] 'Walmart'
    if ($twGot -eq '') { Write-Output ('ok    CLEAN TWIN  count-conflict: ' + $tw[0] + ' sized ' + $tw[1] + ' still prices (refused by nothing)') } else { Write-Output ('FAIL  count-conflict: ' + $tw[0] + ' sized ' + $tw[1] + ' read [' + $twGot + '] - a legal count is refused'); $script:fail++ }
  }
  $ccPast = Get-FirstRefusal '_selftest-cc' 'each' 0.05 '201 ct' 'Selftest Tea Bags 100 CT' 201 'Walmart'
  if ($ccPast -eq 'count-conflict') { Write-Output 'ok    MUST FIRE  count-conflict: a step past the multiple bar (100 CT sized 201 ct) is refused' } else { Write-Output ('FAIL  count-conflict: 100 CT sized 201 ct read [' + $ccPast + ']'); $script:fail++ }
  # MUST NOT FIRE: the basis came from somewhere other than the size count (pieces differ), so the size is not judged.
  $ccOther = Get-FirstRefusal '_selftest-cc' 'each' 0.05 '24 ct' 'Benner Black Tea Bags 100 CT' 100 'Aldi'
  if ($ccOther -eq '') { Write-Output 'ok    MUST NOT FIRE  count-conflict: a basis not taken from the size count is not judged against it' } else { Write-Output ('FAIL  count-conflict: pieces 100 read [' + $ccOther + ']'); $script:fail++ }
  # --- IDENTITY BEFORE SANITY (2026-09-18, queue 2026-09-18-b1d8e3) ------------------------------------------
  # Frozen verbatim from flagged-2026-09-17.json: Hy-Vee's La Banderita Yellow Corn Tortilla 30 Ct at 0.0997
  # against tortillas' real 0.1-1.2 band, a row the ruling tortillas|HyVee|la-banderita-yellow-corn-tortilla-30-ct
  # already names. It read 'band' and audit-band-censorship counted it. The ruling goes through the REAL
  # Get-KnownWrongBlocks from a per-run temp file, never a fixed name, so the parse is exercised too.
  . (Join-Path $__cdHostDir 'known-wrong-lib.ps1')
  $kwTmp = Join-Path ([IO.Path]::GetTempPath()) ('cd-kw-' + [guid]::NewGuid().ToString('N') + '.json')
  try {
    [IO.File]::WriteAllText($kwTmp, '{"entries":[{"commodity":"_selftest-tortillas","store":"Hy-Vee","names":["La Banderita Yellow Corn Tortilla 30 Ct"]}]}', (New-Object System.Text.UTF8Encoding($false)))
    $kwFix = Get-KnownWrongBlocks -Path $kwTmp
  } finally { Remove-Item -LiteralPath $kwTmp -Force -ErrorAction SilentlyContinue }
  $BANDS['_selftest-tortillas'] = [pscustomobject]@{ min = 0.1; max = 1.2 }
  $kwGot = Get-FirstRefusal '_selftest-tortillas' 'each' 0.0997 '30 ea' 'La Banderita Yellow Corn Tortilla 30 Ct' 30 'Hy-Vee' $kwFix
  if ($kwGot -eq 'known-wrong') { Write-Output 'ok    MUST FIRE  refusal order: the ruled Hy-Vee corn tortilla at 0.0997 is filed as known-wrong, not as a band the audit counts' } else { Write-Output ('FAIL  refusal order: the ruled Hy-Vee corn tortilla read [' + $kwGot + '] - an identity refusal is scored as band censorship again'); $script:fail++ }
  # CLEAN TWIN: a real FLOUR tortilla just under the floor, named by no ruling, is still a BAND refusal, so a
  # genuinely censored price still reaches the audit (Aldi's Pueblo Lindo Fajita Flour 20 CT, same file).
  $kwFlour = Get-FirstRefusal '_selftest-tortillas' 'each' 0.0925 '23 oz' 'Pueblo Lindo Fajita Flour Tortillas 20 CT' 20 'Aldi' $kwFix
  if ($kwFlour -eq 'band') { Write-Output 'ok    CLEAN TWIN  refusal order: Aldi''s unruled flour tortilla at 0.0925 is still a band refusal' } else { Write-Output ('FAIL  refusal order: an unruled flour tortilla read [' + $kwFlour + '] instead of band'); $script:fail++ }
  # CLEAN TWIN: the SAME product at a store no ruling names keeps its band label (a ruling is per store).
  $kwOther = Get-FirstRefusal '_selftest-tortillas' 'each' 0.0863 '30 pk 0.83 oz' 'La Banderita Yellow Corn Tortilla 30 Ct' 30 'Baker''s' $kwFix
  if ($kwOther -eq 'band') { Write-Output 'ok    CLEAN TWIN  refusal order: the same product at Baker''s, where no ruling names it, is still a band refusal' } else { Write-Output ('FAIL  refusal order: an unruled store read [' + $kwOther + '] - a ruling leaked across stores'); $script:fail++ }
  # MUST NOT FIRE: the ruled row at an IN-BAND price is refused by nothing here. The known-wrong drop after the
  # loop removes it exactly as before, which is why this order change cannot move a cell.
  $kwIn = Get-FirstRefusal '_selftest-tortillas' 'each' 0.15 '30 ea' 'La Banderita Yellow Corn Tortilla 30 Ct' 30 'Hy-Vee' $kwFix
  if ($kwIn -eq '') { Write-Output 'ok    MUST NOT FIRE  refusal order: an in-band ruled row is left to the post-loop known-wrong drop' } else { Write-Output ('FAIL  refusal order: an in-band ruled row read [' + $kwIn + '] - the loop now refuses what only the drop should'); $script:fail++ }
  $BANDS.Remove('_selftest-tortillas')
  # --- THE PIECE DECLARATION ON breakfast-sandwiches REACHES ITS FOUNDING ROWS (2026-09-18, b1d8e3) ----------
  # Read from the REAL commodities.json this run loaded, so deleting min_piece_oz there, or moving it out of
  # the measured gap, turns these red. Brad's T2 (2026-09-06): an 'each' unit says the pieces are
  # interchangeable, so a snack format is a different product. Measured over the 85 breakfast-sandwiches
  # candidates of 2026-09-17: every priced piece is 3.4 to 9.24 oz, the only pieces under 3.4 are the two
  # Odom's rows below (1.6, 1.45), and both were band-refused and counted as censorship.
  if (-not (Test-PieceSize 'breakfast-sandwiches' '12 pk 1.6 oz' 'Odom''s Tennessee Pride Maple Sausage Buttermilk Biscuit Frozen Breakfast Sandwiches' 12)) { Write-Output 'ok    MUST FIRE  breakfast-sandwiches min_piece_oz refuses Baker''s 12 pk 1.6 oz Odom''s biscuit sandwich' } else { Write-Output 'FAIL  breakfast-sandwiches min_piece_oz admits a 1.6 oz snack-size sandwich against 3.4 to 9 oz pieces'; $script:fail++ }
  if (-not (Test-PieceSize 'breakfast-sandwiches' '14.515 oz' 'Odoms Tennessee Pride Maple Pancake Sausage Sandwiches, Frozen Breakfast Sandwiches, 10 Count' 10)) { Write-Output 'ok    MUST FIRE  breakfast-sandwiches min_piece_oz refuses Walmart''s 10 ct 14.515 oz Odom''s (1.45 oz a piece)' } else { Write-Output 'FAIL  breakfast-sandwiches min_piece_oz admits a 1.45 oz piece'; $script:fail++ }
  if (Test-PieceSize 'breakfast-sandwiches' '4 pk 3.5 oz' 'Kroger Bacon Egg and Cheese Croissant Breakfast Sandwich' 4) { Write-Output 'ok    CLEAN TWIN  breakfast-sandwiches min_piece_oz keeps the live Baker''s cell, a 3.5 oz croissant sandwich' } else { Write-Output 'FAIL  breakfast-sandwiches min_piece_oz refuses the live Baker''s croissant sandwich'; $script:fail++ }
  if (Test-PieceSize 'breakfast-sandwiches' '27.2 oz' 'Jimmy Dean Frozen Breakfast Sandwich, Ham & Cheese Croissant, 27.2 oz, 8 Count' 8) { Write-Output 'ok    CLEAN TWIN  breakfast-sandwiches min_piece_oz keeps the smallest priced piece on the commodity (3.4 oz)' } else { Write-Output 'FAIL  breakfast-sandwiches min_piece_oz refuses a 3.4 oz full-size sandwich'; $script:fail++ }
  # THE COUNT-FIRST IDIOM, both directions. "16 pk 2.63 oz" is sixteen 2.63 oz corn dogs and must be read as
  # a 2.63 oz piece; halve the per-item size and the same grammar must refuse it. Without this the naive
  # Get-PackOz reading (2.63 total / 16 pieces = 0.16 oz) would refuse every real Baker's corn dog.
  $MINPIECE['_selftest-corndog'] = 1.5
  if (Test-PieceSize '_selftest-corndog' '16 pk 2.63 oz' 'Kroger Classic Corn Dogs' 16) { Write-Output 'ok    min_piece_oz reads "16 pk 2.63 oz" as a 2.63 oz PIECE, not a 2.63 oz box' } else { Write-Output 'FAIL  min_piece_oz divided a per-item size again - every real Baker''s corn dog is refused'; $script:fail++ }
  if (-not (Test-PieceSize '_selftest-corndog' '46 pk 0.66 oz' 'State Fair Classic Mini Corn Dogs' 46)) { Write-Output 'ok    min_piece_oz still refuses a 0.66 oz mini stated the same way' } else { Write-Output 'FAIL  min_piece_oz stopped refusing minis stated in the count-first idiom'; $script:fail++ }
  if (Test-PieceSize '_selftest-corndog' '42.761 oz' 'Bar-S Classic Corn Dogs, 16-Count' 16) { Write-Output 'ok    min_piece_oz still divides a genuine PACK TOTAL (42.761 oz / 16 = 2.67)' } else { Write-Output 'FAIL  min_piece_oz stopped dividing a real pack total'; $script:fail++ }
  if (Test-PieceSize '_selftest-corndog' '3 to 4 oz' 'a choose-your-size ad' 1) { Write-Output 'ok    min_piece_oz reads an ascending range as the LARGER size (choose-your-size)' } else { Write-Output 'FAIL  min_piece_oz read a size range as its smaller end - Get-SizeAmount reads the larger and the two must agree'; $script:fail++ }
  if (-not (Test-PieceSize '_selftest-corndog' '0.5 to 1 oz' 'a range that is small at BOTH ends' 1)) { Write-Output 'ok    min_piece_oz still refuses a range whose LARGER end is under the floor' } else { Write-Output 'FAIL  min_piece_oz let a size range pass on its mere presence'; $script:fail++ }
  $MINPIECE.Remove('_selftest-corndog')
  $MINPIECE.Remove('_selftest-pizza')

  # AND THE OTHER HALF OF BRAD'S RULE: for a commodity compared by WEIGHT, format is irrelevant and none of
  # this applies. Bacon ends at $2.398/lb really are cheaper bacon. Pinned because the tempting next edit is
  # to "also check piece size on weight commodities", which would refuse them.
  if (Test-PieceSize 'bacon' '80 oz' 'Webster City Bacon Ends' 1) { Write-Output 'ok    min_piece_oz: a weight-unit commodity declares nothing and is never piece-tested' } else { Write-Output 'FAIL  min_piece_oz reached a by-weight commodity - bacon ends are cheaper bacon, not a smaller piece'; $script:fail++ }

  # --- 11f4: Test-Membership - THE ONE-LINE FUNCTION NOTHING EVER TESTED (2026-09-06, backlog E26) -------
  # FOUND BY SWEEP, NOT BY A FAILURE. E26's shape is a term that evaluates to the identity on every
  # fixture, so the code path never runs and a green suite says nothing about it. Test-Membership is
  # exactly that: it returns true only for Sam's Club, and every fixture in this file uses Walmart, so
  # its true branch had never executed in a test. It is correct today - the live board carries 376
  # Sam's Club rows and all 376 are flagged - which is the point. Untested is not the same as wrong,
  # and it is not the same as safe either.
  #
  # WHAT IT COSTS A READER IF IT BREAKS. This decides the `membership` flag and the 'membership' label
  # on a live paid page. A Sam's Club price shown without it is a price the reader cannot actually get
  # without paying for a membership first, which is the understating half of the accuracy rule and is
  # exactly as wrong as overstating.
  #
  # THE STRING IS THE FRAGILE PART, so the fixture pins it. Both the code and the board use U+0027, the
  # straight apostrophe (verified byte by byte against comparison-2026-09-06.json). A curly U+2019
  # arriving from a capture, a store rename, or a well-meant editor autocorrect turns this comparison
  # false for every row at once, silently, with no other symptom.
  if (Test-Membership "Sam's Club") { Write-Output 'ok    Test-Membership fires for the exact live store string' } else { Write-Output 'FAIL  Test-Membership does not recognise the store string the board actually carries - every Sam''s Club row loses its membership label'; $script:fail++ }
  if (-not (Test-Membership 'Walmart')) { Write-Output 'ok    Test-Membership does not fire for a non-membership store' } else { Write-Output 'FAIL  Test-Membership labelled Walmart as membership-only'; $script:fail++ }
  if (-not (Test-Membership ([string][char]0x53 + 'am' + [string][char]0x2019 + 's Club'))) { Write-Output 'ok    Test-Membership is documented as apostrophe-exact: the curly form does NOT match' } else { Write-Output 'FAIL  Test-Membership matched a curly apostrophe - the comment above is now wrong'; $script:fail++ }
  if (-not (Test-Membership '')) { Write-Output 'ok    Test-Membership: an empty store is not a membership store' } else { Write-Output 'FAIL  Test-Membership fired on an empty store string'; $script:fail++ }
  if (-not (Test-Membership 'Sams Club')) { Write-Output 'ok    Test-Membership does not fire on the apostrophe-less spelling' } else { Write-Output 'FAIL  Test-Membership matched a spelling the board does not use'; $script:fail++ }

  # --- 11g: Test-InStore - the IN-STORE PRICE MODE gate (2026-08-31 achiote ruling) ------------------------
  # The live rows, both from walmart-regular-2026-08-30, both the same 3.5 oz Chef Merito jar:
  #   STORE $2.27 (on the Omaha shelf)  vs  FC $16.24 for a (Pack of 12) shipped case, which took the crown
  # at $0.3867/oz and billed cochinita-pibil the whole 42 oz case. MUST-FIRE: the FC case and a MARKETPLACE
  # third-party row are both refused. CLEAN TWINS: the STORE jar passes, and a row with NO signal passes -
  # every capture before 2026-08-30 predates the field, and treating absence as "not in store" would empty
  # the Walmart column on the day this shipped.
  if (-not (Test-InStore 'FC'))          { Write-Output 'ok    in-store gate refuses the FC shipped case (the achiote bug)' } else { Write-Output 'FAIL  in-store gate admitted a ship-only FC row'; $script:fail++ }
  if (-not (Test-InStore 'MARKETPLACE')) { Write-Output 'ok    in-store gate refuses a third-party MARKETPLACE row' }        else { Write-Output 'FAIL  in-store gate admitted a marketplace row'; $script:fail++ }
  if (Test-InStore 'STORE')              { Write-Output 'ok    in-store gate keeps the STORE shelf row' }                    else { Write-Output 'FAIL  in-store gate dropped a real shelf row'; $script:fail++ }
  if (Test-InStore '')                   { Write-Output 'ok    in-store gate: absent signal is NOT a verdict' }              else { Write-Output 'FAIL  in-store gate treated a missing signal as not-in-store'; $script:fail++ }
  if (Test-InStore $null)                { Write-Output 'ok    in-store gate: null signal is NOT a verdict' }                else { Write-Output 'FAIL  in-store gate treated a null signal as not-in-store'; $script:fail++ }
  if (Test-InStore ' store ')            { Write-Output 'ok    in-store gate is case/whitespace tolerant' }                  else { Write-Output 'FAIL  in-store gate rejected a padded STORE value'; $script:fail++ }

  # --- 11g2: Get-ChannelVerdict - the CHANNEL PROOF BY ITEM ID (2026-09-01 shelf-badge probe) --------------
  # FROZEN, and frozen from the rows that were actually wrong. The browser probe read all 21 doubted cells
  # on 2026-09-01 (out\instore-badge-evidence.json) and found 19 of them are NOT sold in the Omaha store,
  # eight of those holding a commodity crown. These rows are copied from that evidence and from the frozen
  # guard fixtures under regression-inputs\guard-fixtures\instore-channel-*; they are NEVER regenerated
  # from the live board, because the bug they encode would vanish and the test would pass by finding nothing.
  #
  # WHY THE ID AND NOT THE ROW. The engine unions 90 days of captures. Refusing the 08-31 row of a ship-only
  # product does nothing while its pre-field 08-06 row is still standing, which is exactly how red curry
  # paste published $23.40 from a carried row while the fresher row for the SAME item id read FC. Case 2 is
  # that pair and it is the case a row-keyed gate cannot see.
  function _CR($store,$file,$id,$ful,$name) { [pscustomobject]@{ store=$store; src_file=$file; item_id=$id; product_id=$id; fulfillment=$ful; name=$name } }
  $cRows = @(
    # walmart-regular-2026-08-06: PRE-FIELD (no row carries the field), so a blank here is "not collected"
    (_CR 'Walmart' 'walmart-regular-2026-08-06' '754814279'   ''            'Thai Kitchen Red Curry Paste, 35.0 oz Cup'),
    (_CR 'Walmart' 'walmart-regular-2026-08-06' '8886020987'  ''            'Scott Paper Towels Choose-A-Sheet 6 Double Rolls'),
    (_CR 'Walmart' 'walmart-regular-2026-08-06' '999999999'   ''            'Fixture Never-Seen-Again Staple, 16 oz'),
    (_CR 'Walmart' 'walmart-regular-2026-08-06' '111111111'   ''            'Fixture Clean Staple, 16 oz'),
    # walmart-regular-2026-08-31: FIELD-BEARING (the real file fills it on 11,603 of 11,694 rows), so a
    # blank here is "the puller could not attribute this row" - over half of those are (N pack) bundles.
    (_CR 'Walmart' 'walmart-regular-2026-08-31' '754814279'   'FC'          'Thai Kitchen Red Curry Paste, 35.0 oz Cup'),
    (_CR 'Walmart' 'walmart-regular-2026-08-31' '8886020987'  'FC'          'Scott Paper Towels Choose-A-Sheet 6 Double Rolls'),
    (_CR 'Walmart' 'walmart-regular-2026-08-31' '15706413058' ''            '(2 pack) Suave Skin Solutions Silkening Body Lotion for Dry Skin with Baby Oil, All Skin Types, 32 oz'),
    (_CR 'Walmart' 'walmart-regular-2026-08-31' '30919180'    ''            'El Guapo Mexican Bay Leaves, 0.5 oz Bag'),
    (_CR 'Walmart' 'walmart-regular-2026-08-31' '233387802'   'MARKETPLACE' 'Thai Kitchen Premium Fish Sauce, 23.66 fl oz'),
    (_CR 'Walmart' 'walmart-regular-2026-08-31' '111111111'   'STORE'       'Fixture Clean Staple, 16 oz'),
    (_CR 'Walmart' 'walmart-regular-2026-08-31' '222222222'   'STORE'       'Fixture Second Store Row, 8 oz')
  )
  $cAllow = @{ 'Walmart|id|30919180' = "browser probe 2026-09-01: 'Out of stock at Omaha L St Supercenter / Available for pickup nearby' - a store-channel SKU"
               'Walmart|id|8886020987' = "browser probe 2026-09-01: Pickup 'As soon as 6pm today' at 6.84, the price the board publishes" }
  # BUILT FROM A List[object], WHICH IS WHAT THE ENGINE ACTUALLY PASSES. The first draft of this fixture
  # handed New-ChannelIndex a plain array, and PS 5.1 treats the two differently: `@($Rows)` on a parameter
  # bound to a List[object] throws "Argument types do not match" while the same expression on an array is
  # fine. The gate crashed the entire board build and this suite stayed green, because the fixture could not
  # reach the caller's real type. See the note in instore-lib.ps1's New-ChannelIndex.
  $cRowsList = New-Object System.Collections.Generic.List[object]
  foreach ($cr in $cRows) { [void]$cRowsList.Add($cr) }
  $cIdx = New-ChannelIndex -Rows $cRowsList -Allowlist $cAllow
  if ($cIdx -and $cIdx.Bearing.Count -ge 2) { Write-Output 'ok    channel index builds from the List[object] the engine really passes (PS 5.1 @() trap)' }
  else { Write-Output 'FAIL  channel index could not be built from a List[object] - the shape the engine passes every run'; $script:fail++ }
  function _CV($file,$id,$ful,$name) { Get-ChannelVerdict -Index $cIdx -Store 'Walmart' -SrcFile $file -ItemId $id -Fulfillment $ful -ItemName $name }
  # MUST FIRE 1 - the "(N pack)" online bundle: blank inside a capture that fills the field everywhere else.
  $v = _CV 'walmart-regular-2026-08-31' '15706413058' '' '(2 pack) Suave Skin Solutions Silkening Body Lotion for Dry Skin with Baby Oil, All Skin Types, 32 oz'
  if ((-not $v.in_store) -and $v.why -eq 'BLANK-IN-FIELD-BEARING-CAPTURE') { Write-Output 'ok    channel gate refuses a blank fulfillment inside a field-bearing capture (the "(2 pack)" bundle that held the lotion crown)' }
  else { Write-Output ("FAIL  channel gate admitted an unattributed row in a field-bearing capture (why=" + $v.why + ") - the online-bundle class is back on the board"); $script:fail++ }
  # MUST FIRE 2 - THE FOUNDING PAIR, and the case a row-keyed gate cannot see: the board prices the carried
  # pre-field 08-06 row while the SAME item id reads FC in the fresher 08-31 capture.
  $v = _CV 'walmart-regular-2026-08-06' '754814279' '' 'Thai Kitchen Red Curry Paste, 35.0 oz Cup'
  if ((-not $v.in_store) -and $v.why -eq 'PRE-FIELD-ROW-OUTLIVING-A-REFUSAL') { Write-Output 'ok    channel gate refuses a pre-field row whose item id is refused in a fresher capture (the red-curry founding pair)' }
  else { Write-Output ("FAIL  channel gate is row-keyed again (why=" + $v.why + ") - a ship-only product can price the board through a 90-day-old carried row"); $script:fail++ }
  # MUST FIRE 3 - the store says third-party outright.
  $v = _CV 'walmart-regular-2026-08-31' '233387802' 'MARKETPLACE' 'Thai Kitchen Premium Fish Sauce, 23.66 fl oz'
  if (-not $v.in_store) { Write-Output "ok    channel gate refuses an explicit MARKETPLACE row (fish sauce, sold by Noelle's Suitcase)" }
  else { Write-Output 'FAIL  channel gate admitted a third-party marketplace row'; $script:fail++ }
  # CLEAN TWIN 1 - a real shelf row is untouched.
  $v = _CV 'walmart-regular-2026-08-31' '111111111' 'STORE' 'Fixture Clean Staple, 16 oz'
  if ($v.in_store) { Write-Output 'ok    channel gate keeps a STORE row' } else { Write-Output 'FAIL  channel gate dropped a real shelf row'; $script:fail++ }
  # CLEAN TWIN 2 - THE ONE THAT STOPS THIS EMPTYING THE WALMART COLUMN. A pre-field row whose id no
  # field-bearing capture has ever seen carries no evidence either way, and absence is still not a verdict.
  $v = _CV 'walmart-regular-2026-08-06' '999999999' '' 'Fixture Never-Seen-Again Staple, 16 oz'
  if ($v.in_store -and $v.why -eq 'NO-SIGNAL') { Write-Output 'ok    channel gate: a pre-field row with NO fresher evidence is still admitted (absence is not a verdict)' }
  else { Write-Output ("FAIL  channel gate condemned an unmeasured pre-field row (why=" + $v.why + ") - this empties most of the Walmart column"); $script:fail++ }
  # CLEAN TWIN 3 - evidence cuts both ways: a fresher capture that says STORE clears the carried row.
  $v = _CV 'walmart-regular-2026-08-06' '111111111' '' 'Fixture Clean Staple, 16 oz'
  if ($v.in_store -and $v.why -eq 'PROVEN-STORE-BY-FRESHER-CAPTURE') { Write-Output 'ok    channel gate clears a carried row whose item id is proven STORE in a fresher capture' }
  else { Write-Output ("FAIL  channel gate ignored positive fresher evidence (why=" + $v.why + ")"); $script:fail++ }
  # CLEAN TWIN 4 - the reviewed exception. El Guapo bay leaves is blank in a field-bearing capture and the
  # browser probe found a store-level line for it, so refusing it would throw away a correct cell.
  $v = _CV 'walmart-regular-2026-08-31' '30919180' '' 'El Guapo Mexican Bay Leaves, 0.5 oz Bag'
  if ($v.in_store -and $v.why -eq 'REVIEWED-EXCEPTION') { Write-Output 'ok    channel gate honours a reviewed exception (El Guapo bay leaves, store-level line read on the page)' }
  else { Write-Output ("FAIL  channel gate refused a cell a human verified in the store (why=" + $v.why + ") - understating is as wrong as overstating"); $script:fail++ }
  # ...and the exception list may NOT overrule the store's own word. If it could, one allowlist line would
  # quietly re-open the achiote hole this whole gate exists to close.
  $cAllow2 = @{ 'Walmart|id|233387802' = 'a reviewer who tried to rescue a marketplace listing' }
  $cIdx2 = New-ChannelIndex -Rows $cRows -Allowlist $cAllow2
  $v = Get-ChannelVerdict -Index $cIdx2 -Store 'Walmart' -SrcFile 'walmart-regular-2026-08-31' -ItemId '233387802' -Fulfillment 'MARKETPLACE' -ItemName 'Thai Kitchen Premium Fish Sauce, 23.66 fl oz'
  if (-not $v.in_store) { Write-Output 'ok    a reviewed exception cannot overrule an explicit FC/MARKETPLACE row (it only ever answers a DOUBT)' }
  else { Write-Output 'FAIL  the exception list overruled the store stating the channel itself - the achiote hole is re-opened'; $script:fail++ }
  # ...and with no index at all the gate degrades to exactly the old row-keyed rule, refusing nothing new.
  $v = Get-ChannelVerdict -Index $null -Store 'Walmart' -SrcFile 'walmart-regular-2026-08-31' -ItemId '15706413058' -Fulfillment '' -ItemName 'x'
  if ($v.in_store) { Write-Output 'ok    channel gate with no capture context degrades to Test-InStore rather than refusing blind' }
  else { Write-Output 'FAIL  channel gate refuses rows when it has no index to reason from - a could-not-run reported as a failure'; $script:fail++ }
  # THE LOADER, AGAINST A FROZEN FILE (2026-09-06, PLAN-top5 area 4). This case used to read the SHIPPED
  # allowlist and assert two specific ids were still in it - so a reviewer retiring either exception would
  # have turned the PRICE ENGINE's own self-test red, for a correct edit. The verdict rested on two inputs
  # and the harness had frozen only one. It is frozen now: the fixture carries the id-keyed shape, the
  # name-keyed fallback, and one entry with no store that must be SKIPPED, and none of them is a ruling
  # anybody can retire. -ChannelAllowlistFile is the same pinning -CommoditiesFile and -BandsFile already do.
  $cFix = Get-ChannelAllowlist -Path (Join-Path $__cdHostDir 'regression-inputs\guard-fixtures\instore-channel-allowlist-fixture.json')
  # Three keys exactly: entry 1 yields BOTH an id key and a name key, entry 2 a name key, entry 3 nothing.
  if ($cFix.ContainsKey('Walmart|id|30919180') -and $cFix.ContainsKey('Fareway|nm|a store that publishes no id, 12 oz') -and
      (-not $cFix.ContainsKey('|id|99999999')) -and $cFix.Count -eq 3) {
    Write-Output 'ok    the allowlist loader reads the id-keyed shape, the name-keyed fallback, and SKIPS an entry with no store (frozen fixture)'
  } else { Write-Output ('FAIL  the allowlist loader lost a key shape (count=' + $cFix.Count + ' keys: ' + (($cFix.Keys | Sort-Object) -join ' | ') + ')'); $script:fail++ }
  # LIVE-TWIN, LABELLED AS SUCH. The shipped file is still parsed and its two probe-verified ids named,
  # because a data file that quietly stops loading silently drops two correct cells. A red here means the
  # LIVE FILE changed or broke - a reviewer's decision or a real defect - not that this watcher went blind.
  # If a reviewer retires one of these on purpose, update this line: that edit IS the record of the call.
  $cShip = Get-ChannelAllowlist -Path $(if ($ChannelAllowlistFile) { $ChannelAllowlistFile } else { Join-Path $__cdHostDir 'instore-channel-allowlist.json' })
  if ($cShip.ContainsKey('Walmart|id|30919180') -and $cShip.ContainsKey('Walmart|id|8886020987')) { Write-Output 'ok    LIVE-TWIN: the shipped instore-channel-allowlist.json parses and still carries both cells the 2026-09-01 probe verified in store' }
  else { Write-Output 'FAIL  LIVE-TWIN: instore-channel-allowlist.json does not load or lost a reviewed exception - two correct cells are being refused (this reads LIVE data, so check the file before the code)'; $script:fail++ }

  # --- 11h: Select-StoreWinner - the case-pack tie-break (2026-08-31 harissa ruling) -----------------------
  # The live rows: Walmart listed Mina Harissa as a single 10 oz jar at $4.98 AND as a (12 pack) at $59.76.
  # Both are exactly $0.498/oz, so the two existing keys were silent and the CASE won on group order - the
  # board published "$59.76" as the cheapest harissa in Omaha and two recipes were billed the whole case.
  # MUST-FIRE: the single jar wins that tie. CLEAN TWINS: a genuinely cheaper case still wins on price (this
  # tie-break must never make the board dearer); the linkability key still outranks size; and equal sizes
  # fall through to the previous behaviour.
  # PARENTHESISE EVERY CALL. Without them PowerShell binds the comma to _W's LAST argument, so the whole
  # fixture collapses to ONE row and the assertions pass against a list they never built - a test that
  # cannot fail is worth less than no test (see the fix-needs-a-reachable-self-test class). Caught here.
  function _W($n,$up,$sz,$id) { [pscustomobject]@{ name=$n; unit_price=$up; size_text=$sz; has_identity=$id } }
  $tie = @((_W '(12 pack) Mina, Harissa Spicy Moroccan Red Pepper Sauce , 10 Fl oz' 0.498 '120 oz' $true),
           (_W 'Mina, Harissa Spicy Moroccan Red Pepper Sauce , 10 Fl oz'           0.498 '10 oz'  $true))
  if ((Select-StoreWinner $tie).size_text -eq '10 oz') { Write-Output 'ok    tie-break: the single 10 oz jar beats the 12-pack case (the harissa bug)' } else { Write-Output 'FAIL  tie-break: the case pack still won a per-unit tie'; $script:fail++ }
  # reversed input order - the rule must decide this, not the order it happened to receive
  if ((Select-StoreWinner @($tie[1],$tie[0])).size_text -eq '10 oz') { Write-Output 'ok    tie-break is order-independent' } else { Write-Output 'FAIL  tie-break depended on input order'; $script:fail++ }
  $cheaperCase = @((_W 'Single jar, 10 oz' 0.60 '10 oz' $true), (_W '(12 pack) case, 120 oz' 0.40 '120 oz' $true))
  if ((Select-StoreWinner $cheaperCase).size_text -eq '120 oz') { Write-Output 'ok    tie-break never overrides a genuinely cheaper per-unit price' } else { Write-Output 'FAIL  tie-break made the board dearer'; $script:fail++ }
  $linkWins = @((_W 'small but unlinkable, 10 oz' 0.50 '10 oz' $false), (_W 'larger but linkable, 120 oz' 0.50 '120 oz' $true))
  if ((Select-StoreWinner $linkWins).has_identity) { Write-Output 'ok    linkability still outranks package size' } else { Write-Output 'FAIL  size tie-break outranked the linkability key'; $script:fail++ }
  $sameSize = @((_W 'Millville Complete Buttermilk Pancake & Waffle Mix' 1.95 '32 oz' $false), (_W "Aunt Maple's Buttermilk Pancake Mix 32 OZ" 1.95 '32 oz' $true))
  if ((Select-StoreWinner $sameSize).has_identity) { Write-Output 'ok    equal sizes fall through to the linkable row (the 2026-08-22 pancake fixture)' } else { Write-Output 'FAIL  size key disturbed the pancake-mix tie-break'; $script:fail++ }
  $unreadable = @((_W 'no size stated' 0.50 '' $true), (_W 'stated 10 oz' 0.50 '10 oz' $true))
  if ((Select-StoreWinner $unreadable).size_text -eq '10 oz') { Write-Output 'ok    an unreadable size sorts last rather than winning by default' } else { Write-Output 'FAIL  a row with no readable size beat one with a real size'; $script:fail++ }
  # TOTAL ORDER (key 4). PS 5.1's Sort-Object is not stable, so rows equal on keys 1-3 must still resolve to
  # the SAME winner every run or a board cell is not reproducible. Same input, both orders, one answer.
  $twinA = @((_W 'Zeta brand, 10 oz' 0.50 '10 oz' $true), (_W 'Alpha brand, 10 oz' 0.50 '10 oz' $true))
  $wA = (Select-StoreWinner $twinA).name
  $wB = (Select-StoreWinner @($twinA[1],$twinA[0])).name
  if ($wA -eq $wB -and $wA -eq 'Alpha brand, 10 oz') { Write-Output 'ok    rows equal on every real key resolve to ONE reproducible winner' } else { Write-Output ("FAIL  equal rows are order-dependent ('$wA' vs '$wB') - the board cell is not reproducible"); $script:fail++ }

  # --- 11i: Select-CrossStoreRank - WHICH STORE WEARS A TIED CROWN (2026-09-19, backlog I175) --------------
  # FROZEN FOUNDING CASE: collard-greens on comparison-2026-09-17, Hy-Vee and Baker's both $1.99/bunch, plus
  # the rest of that cell's stores. Under the old `Sort-Object unit_price` reversing the input alone moved the
  # crown between them. Every order of the same rows must give ONE crown, and it is the key-3 answer.
  function _X($st, $up, $mem) { [pscustomobject]@{ store = $st; unit_price = $up; membership = $mem } }
  $cgRows = @((_X 'Hy-Vee' 1.99 $false), (_X "Baker's" 1.99 $false), (_X 'Fareway' 2.49 $false), (_X 'Walmart' 2.78 $false), (_X 'Family Fare' 2.99 $false))
  $cgOrders = @(@(0,1,2,3,4), @(4,3,2,1,0), @(1,0,2,3,4), @(2,4,1,3,0), @(3,0,4,1,2))
  $cgCrowns = @($cgOrders | ForEach-Object { $ord = $_; $inRows = @($ord | ForEach-Object { $cgRows[$_] }); $rk = @(Select-CrossStoreRank $inRows); [string]$rk[0].store } | Select-Object -Unique)
  # MUST FIRE: a tied crown is the same store in every input order, and it is the key-3 (store name) answer.
  if ($cgCrowns.Count -eq 1 -and $cgCrowns[0] -eq "Baker's") { Write-Output 'ok    a tied crown is one reproducible store whatever the input order (the collard-greens case)' } else { Write-Output ('FAIL  a tied crown depends on input order: ' + ($cgCrowns -join ' | ')); $script:fail++ }
  # MUST FIRE: a tie never crowns the membership store over one anybody can shop at, in either order.
  $memTie = @((_X "Sam's Club" 0.10 $true), (_X 'Walmart' 0.10 $false))
  $m1 = @(Select-CrossStoreRank $memTie)[0].store; $m2 = @(Select-CrossStoreRank @($memTie[1], $memTie[0]))[0].store
  if ($m1 -eq 'Walmart' -and $m2 -eq 'Walmart') { Write-Output 'ok    a price tie goes to the store with no membership' } else { Write-Output ("FAIL  a tie crowned '$m1' / '$m2' - the membership store took a tied crown"); $script:fail++ }
  # CLEAN TWIN: the tie-break never outranks price. A genuinely cheaper membership store still wears the crown,
  #   and every row survives the rank (count in = count out).
  $cheapMem = @((_X 'Walmart' 0.11 $false), (_X "Sam's Club" 0.10 $true), (_X 'Aldi' 0.12 $false))
  $cmRank = @(Select-CrossStoreRank $cheapMem)
  if ($cmRank.Count -eq 3 -and $cmRank[0].store -eq "Sam's Club" -and $cmRank[1].store -eq 'Walmart') { Write-Output 'ok    a cheaper membership store still wins, and the rank keeps every store' } else { Write-Output ('FAIL  the tie-break reordered unequal prices: ' + (($cmRank | ForEach-Object { $_.store }) -join ',')); $script:fail++ }

  # the 'snax' GLOBAL_EXCLUDE token (blocks snack TRAYS from winning real-commodity cells). $GLOBAL_EXCLUDE
  # is defined AFTER this block exits, so read the token from this script's own source (the extraction regex
  # audit-match-soundness.ps1 already uses) - a hard-coded 'snax' literal here would pass whether or not the
  # engine still carries the token, i.e. a gate that can never arm. MUST-FIRE while the token is absent.
  # THE LIST IS A LIBRARY NOW (2026-09-09, backlog I82), so the token comes from the real list rather
  # than from a regex over this file's own source. The REASON the old code read source is unchanged and
  # still honoured: a hard-coded 'snax' literal here would pass whether or not the engine still carries
  # the token, which is a gate that can never arm. Calling the library reads the SAME list the engine
  # prices with, so the case still MUST FIRE when the token is removed.
  . (Join-Path $__cdHostDir 'global-exclude-lib.ps1')
  $snaxTok = @(Get-TcGlobalExclude | Where-Object { $_ -like '*snax*' })[0]
  if ($snaxTok -and ('go2snax, hard salami, mild cheddar cheese' -match $snaxTok)) { Write-Output "ok    'snax' exclude catches the GO2snax tray" } else { Write-Output "FAIL  'snax' token absent from GLOBAL_EXCLUDE or no longer catches GO2snax"; $script:fail++ }
  if ($snaxTok -and ("member's mark standard shredded mild yellow cheddar cheese 5 lbs." -notmatch $snaxTok)) { Write-Output "ok    real shredded cheese not excluded by 'snax'" } else { Write-Output "FAIL  'snax' wrongly excludes real cheese (or token absent)"; $script:fail++ }

  # --- 12-14: partial-pull coverage (reproduces the 2026-07-23 Walmart flood) -----------------------------
  # A throttled Walmart pull returns ~50 of 410 commodities. Under newest-file-wins that partial REPLACED the
  # last full capture and cut the store to 80 cells; the coverage guard blocked the publish and the un-deduped
  # alerts flooded. These cases fail the build if the union ever regresses, so the automated job proves the fix
  # is intact on every run (guards.ps1 runs this self-test as a blocking invariant).
  function _RegFiles($names){ $names | ForEach-Object { [pscustomobject]@{ BaseName=$_; Name=($_ + '.json') } } }
  $asof = [datetime]'2026-07-23'
  # 12. the partial pull must UNION with the last full capture, not replace it (both files load)
  $u = @(Select-RegularFileSet (_RegFiles @('walmart-regular-2026-07-18','walmart-regular-2026-07-23')) $asof 14 | ForEach-Object { $_.BaseName })
  if ($u.Count -eq 2) { Write-Output 'ok    Walmart partial pull UNIONS with last full capture (no collapse)' }
  else { Write-Output ("FAIL  Walmart union regressed to newest-only ({0} file) - the 2026-07-23 collapse would recur" -f $u.Count); $script:fail++ }
  # 13. an ad-cycling store stays newest-only (dating its everyday rows would filter a still-valid weekly sale)
  $b = @(Select-RegularFileSet (_RegFiles @('bakers-regular-2026-07-11','bakers-regular-2026-07-18')) $asof 14 | ForEach-Object { $_.BaseName })
  if ($b.Count -eq 1 -and $b[0] -eq 'bakers-regular-2026-07-18') { Write-Output 'ok    ad-cycling store stays newest-only (sales not filtered out)' }
  else { Write-Output "FAIL  ad-cycling store must stay newest-only (union would drop valid sales)"; $script:fail++ }
  # 14. a Walmart capture older than the union window is excluded (never resurrect ancient prices)
  $o = @(Select-RegularFileSet (_RegFiles @('walmart-regular-2026-06-01','walmart-regular-2026-07-23')) $asof 14 | ForEach-Object { $_.BaseName })
  if ($o.Count -eq 1 -and $o[0] -eq 'walmart-regular-2026-07-23') { Write-Output 'ok    stale-beyond-window Walmart capture excluded' }
  else { Write-Output "FAIL  union age window not enforced (would load ancient prices)"; $script:fail++ }

  # --- 15: universal implausibility floor (the band-less dropped-decimal backstop) --------------------------
  # a decimal-drop below the per-unit floor is dropped; a real cheap staple and the exempt 'each' unit survive.
  if (-not (Test-Floor 'oz' 0.0023))  { Write-Output 'ok    floor drops $0.0023/oz decimal-drop (the grits bug)' } else { Write-Output 'FAIL  floor let a $0.0023/oz price through'; $script:fail++ }
  if (Test-Floor 'oz' 0.0304)         { Write-Output 'ok    floor keeps real $0.0304/oz salt' } else { Write-Output 'FAIL  floor wrongly dropped real salt'; $script:fail++ }
  if (-not (Test-Floor 'lb' 0.03))    { Write-Output 'ok    floor drops $0.03/lb decimal-drop' } else { Write-Output 'FAIL  floor let a $0.03/lb price through'; $script:fail++ }
  if (Test-Floor 'each' 0.0043)       { Write-Output "ok    'each' exempt (500-ct swab box legitimately sub-cent)" } else { Write-Output "FAIL  'each' should be unfloored"; $script:fail++ }

  # --- 16-19: the file set GUARDS iterate must be the one the BOARD was priced from ------------------------
  # Item 9 (2026-07-30) gave guards.ps1 this function; it then reopened its own hole by re-deriving the AS-OF
  # from (Get-Date).Date while the engine resolves it against $ads.today - the value it also NAMES the board
  # with. FROZEN founding bug, measured 2026-07-30 08:19: comparison-2026-07-29.json was rebuilt from
  # ads-2026-07-29 on 07-30, so walmart-regular-2026-07-15.json (711 rows, 323 carrying current_price) was
  # priced into the shipped board and sat outside guard 5's and guard 10's file set. These cases run the REAL
  # entry point guards.ps1 calls, over a synthetic out\ tree in TEMP, so they cannot pass while the production
  # path stops using it. Synthetic and frozen - never regenerated from the live board.
  $sd = Join-Path $env:TEMP ('regfileset-selftest-' + [guid]::NewGuid())
  New-Item -ItemType Directory (Join-Path $sd 'regular') -Force | Out-Null
  # THE EDGE CAPTURE. Cases 16/17/19 all turn on a Walmart capture that is exactly ONE WINDOW old
  # relative to the 07-29 board: in reach for that board, out of reach for 07-30's. That date was
  # frozen at 2026-07-15 because the window was then 14 days. When the capture policy moved the
  # window to the 90-day quarter (2026-08-20), the literal quietly became a 15-day-old file sitting
  # INSIDE a 90-day window, and cases 17 and 19 inverted - the fixture stopped testing the boundary
  # and started asserting the opposite of it. Deriving the date from the window keeps the boundary
  # under test at whatever the window becomes next. Still synthetic and still never regenerated
  # from the live board - that freeze is about not reading the answer off the thing under test.
  $edgeW = 'walmart-regular-' + ([datetime]'2026-07-29').AddDays(-(Get-RegularUnionDays)).ToString('yyyy-MM-dd')
  foreach ($n in @($edgeW,'walmart-regular-2026-07-29','hyvee-regular-2026-07-15','hyvee-regular-2026-07-29')) {
    '{}' | Set-Content (Join-Path $sd ('regular\' + $n + '.json')) -Encoding UTF8
  }
  try {
    # 16. MUST FIRE: board dated 07-29, clock 07-30 -> the capture the board WAS priced from stays in reach.
    '{}' | Set-Content (Join-Path $sd 'comparison-2026-07-29.json') -Encoding UTF8
    $g1 = @(Select-EngineRegularFiles $sd ([datetime]'2026-07-30') | ForEach-Object { $_.BaseName })
    if ($g1 -contains $edgeW) { Write-Output 'ok    guards as-of follows the BOARD, not the wall clock' }
    else { Write-Output 'FAIL  guards as-of re-derived from the clock - a file the board WAS priced from is out of guard 5/10 reach again'; $script:fail++ }
    # 17. CLEAN TWIN: board dated 07-30 -> that same capture is now one day PAST the window and must stay
    #     OUT. Proves the fix follows the board's own date rather than widening the window unconditionally.
    '{}' | Set-Content (Join-Path $sd 'comparison-2026-07-30.json') -Encoding UTF8
    $g2 = @(Select-EngineRegularFiles $sd ([datetime]'2026-07-30') | ForEach-Object { $_.BaseName })
    if ($g2 -notcontains $edgeW) { Write-Output 'ok    a capture outside the BOARD''s own window stays excluded' }
    else { Write-Output ('FAIL  the guards file set widened unconditionally - ' + $edgeW + ' is one day past the window and is being guarded as live'); $script:fail++ }
    # 17b. MUST FIRE (2026-09-26, PLAN-board-clock W1): a board NAMED for the 07-29 ad set but JUDGED on 07-30 records
    #     judged_on, and the guards' file set must follow what the engine judged at - the edge capture is out, exactly
    #     as for a board named 07-30. Mirroring the name here would guard a file the engine did not price from.
    Remove-Item (Join-Path $sd 'comparison-*.json') -Force
    '{"built_at":"2026-07-30T08:00:00","week_of":"2026-07-29","judged_on":"2026-07-30","comparison":[]}' | Set-Content (Join-Path $sd 'comparison-2026-07-29.json') -Encoding UTF8
    $g17b = @(Select-EngineRegularFiles $sd ([datetime]'2026-07-30') | ForEach-Object { $_.BaseName })
    if ($g17b -notcontains $edgeW) { Write-Output 'ok    guards follow the board''s recorded judged_on, not its ad-set name' }
    else { Write-Output ('FAIL  a board named 07-29 but judged 07-30 still guards ' + $edgeW + ' - the mirror read the NAME, not what the engine judged at'); $script:fail++ }
    Remove-Item (Join-Path $sd 'comparison-*.json') -Force
    '{}' | Set-Content (Join-Path $sd 'comparison-2026-07-29.json') -Encoding UTF8
    '{}' | Set-Content (Join-Path $sd 'comparison-2026-07-30.json') -Encoding UTF8
    # 18. an ad-cycling store is still newest-only whatever the as-of (unioning one would guard expired sales)
    if ($g1 -notcontains 'hyvee-regular-2026-07-15') { Write-Output 'ok    ad-cycling store stays newest-only under the board as-of' }
    else { Write-Output 'FAIL  a non-everyday store started unioning - expired sale prices would be guarded as live'; $script:fail++ }
    # 20. MUST FIRE: the founding bug. Fareway's 08-09 flyer prints "prices good August 10-15", so priced
    #     against an 08-09 board it is tomorrow's sale and must not reach a cell.
    $early = Test-AdWindowClosed ([pscustomobject]@{ ad_from='2026-08-10'; ad_to='2026-08-15' }) ([datetime]'2026-08-09')
    if ($early) { Write-Output 'ok    an ad whose window has not opened yet is refused (not-yet-live sale)' }
    else { Write-Output 'FAIL  a future-dated ad was priced onto the board - tomorrow''s sale prices publish today'; $script:fail++ }
    # 21. CLEAN TWIN: the same window on its OPENING day is live. Proves 20 is a date test, not a blanket refusal.
    if (-not (Test-AdWindowClosed ([pscustomobject]@{ ad_from='2026-08-10'; ad_to='2026-08-15' }) ([datetime]'2026-08-10'))) { Write-Output 'ok    that same ad goes live on the day its window opens' }
    else { Write-Output 'FAIL  the ad-window gate refuses a LIVE ad - every sale row would drop off the board'; $script:fail++ }
    # 22. the ad_to half still fires, and absent evidence is still not evidence (no window = never refused)
    if (Test-AdWindowClosed ([pscustomobject]@{ ad_from='2026-07-26'; ad_to='2026-08-01' }) ([datetime]'2026-08-09')) { Write-Output 'ok    an expired ad is still refused' }
    else { Write-Output 'FAIL  the expired-ad half of the window gate stopped firing'; $script:fail++ }
    if (-not (Test-AdWindowClosed ([pscustomobject]@{ deals=@() }) ([datetime]'2026-08-09'))) { Write-Output 'ok    an ad file declaring no window is never refused' }
    else { Write-Output 'FAIL  a file with no ad window was refused - the frozen bakers fixture would drop out'; $script:fail++ }
    # 19. no board on disk -> the wall clock (guard 12 hard-fails that state on its own)
    Remove-Item (Join-Path $sd 'comparison-*.json') -Force
    $g3 = @(Select-EngineRegularFiles $sd ([datetime]'2026-07-30') | ForEach-Object { $_.BaseName })
    if ($g3 -notcontains $edgeW) { Write-Output 'ok    no board on disk falls back to the wall clock' }
    else { Write-Output 'FAIL  the no-board fallback did not use the wall clock'; $script:fail++ }
  } finally { Remove-Item $sd -Recurse -Force -ErrorAction SilentlyContinue }

  # --- 20: the union WINDOW is single-sourced too ----------------------------------------------------------
  # guards.ps1 repeated the literal 14 next to this param's default, and nothing noticed if one of them moved.
  if (-not $PSBoundParameters.ContainsKey('WalmartMaxAgeDays')) {
    if ($WalmartMaxAgeDays -eq (Get-RegularUnionDays)) { Write-Output 'ok    union window single-sourced (compare-deals default == regular-fileset-lib)' }
    else { Write-Output ('FAIL  union window drift: -WalmartMaxAgeDays default is ' + $WalmartMaxAgeDays + ' but regular-fileset-lib says ' + (Get-RegularUnionDays) + ' - guards would iterate a different window than the engine'); $script:fail++ }
  }
  # Sam's unions on the same window and had no such check, so its default could drift alone.
  if (-not $PSBoundParameters.ContainsKey('SamsMaxAgeDays')) {
    if ($SamsMaxAgeDays -eq (Get-RegularUnionDays)) { Write-Output 'ok    union window single-sourced (-SamsMaxAgeDays default == regular-fileset-lib)' }
    else { Write-Output ('FAIL  union window drift: -SamsMaxAgeDays default is ' + $SamsMaxAgeDays + ' but regular-fileset-lib says ' + (Get-RegularUnionDays)); $script:fail++ }
  }
  # --- 20b: and the window must still equal the CAPTURE POLICY that justifies it ---------------------------
  # The window is only safe because the rotation promises to re-capture every term within it. If someone
  # shortens the quarter (or lengthens the window) without moving the other, rows again expire before their
  # turn comes round - the 2026-08-20 failure, where a 14-day window under a 90-day rotation had already
  # queued 100% of Walmart's cells for deletion. $null = policy unreadable, which is reported, not passed.
  $polDays = Get-PolicyCarryDaysFromText
  if ($null -eq $polDays) { Write-Output 'FAIL  capture-policy.ps1 MaxCarryDays could not be read - the union window has nothing to agree WITH'; $script:fail++ }
  elseif ($polDays -eq (Get-RegularUnionDays)) { Write-Output "ok    union window equals the capture policy ($polDays d rotation carry)" }
  else { Write-Output ('FAIL  policy drift: capture-policy.ps1 MaxCarryDays=' + $polDays + ' but the union window is ' + (Get-RegularUnionDays) + ' - everyday rows will expire before the rotation re-captures them'); $script:fail++ }

