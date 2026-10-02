# test-row-contract.ps1 - hermetic self-test of grocery\row-contract-lib.ps1 (Get-TcRowContract), the capture row
# contract of design/SPEC-capture-row-contract.md (build step 8, in SHADOW).
# WHAT IT READS: the lib and the two libraries it dot-sources (pricing-math-lib, pu-lib). Every row below is the REAL
# row text of a queue item, transcribed from candidates-2026-09-30.json or the item's own body; no board is read.
# Vocabulary (rule og-05): MUST FIRE = the founding defect is refused or repriced; MUST NOT FIRE = a legal row stays
# accepted; CLEAN TWIN = the adjacent behaviour the fix was most likely to break still works.
# gate-inputs: grocery\row-contract-lib.ps1, grocery\pricing-math-lib.ps1, grocery\pu-lib.ps1, grocery\ad-line-price-lib.ps1
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $here 'row-contract-lib.ps1')
$script:f = 0; $script:n = 0
$script:fired = @{}
function T([string]$name, [bool]$ok, [string]$got) {
  $script:n++
  if ($ok) { Write-Output "  ok    $name" } else { $script:f++; Write-Output "  FAIL  $name  (got: $got)" }
}
function RcCom([string]$id, [string]$unit, [hashtable]$decl = @{}) { $c = @{ id = $id; unit = $unit }; foreach ($k in $decl.Keys) { $c[$k] = $decl[$k] }; return $c }
function RcRow([string]$store, [string]$name, [string]$price, [string]$size, $regular = $null) {
  return [pscustomobject]@{ store = $store; name = $name; price_text = $price; size_text = $size; regular = $regular }
}
function Codes($res) { $cs = @($res.refusals | ForEach-Object { $_.code }) + @($res.reprice | ForEach-Object { $_.code }); foreach ($c in $cs) { $script:fired[$c] = $true }; return ($cs -join ',') }
function Show($res) { return ('verdict=' + $res.verdict + ' codes=' + (Codes $res) + ' pack=' + $(if ($res.pack) { [string]$res.pack.count + '/' + $res.pack.form } else { '-' }) + ' basis=' + $(if ($res.price_basis) { $res.price_basis.value } else { '-' })) }

try {
  # ---- 44c416: "fl oz" read as weight oz on an oz-unit commodity (410 of 19,860 candidates, 35 commodities, 2026-09-30)
  $cm = RcCom 'condensed-milk' 'oz'
  $row = RcRow 'Aldi' 'Baker S Corner Sweetened Condensed Milk 14 FL OZ' '$2.29' '14 fl oz'
  $res = Get-TcRowContract $row $cm; $s = Show $res
  T 'MUST FIRE  44c416 Aldi condensed milk 14 fl oz on an oz commodity with no density is KIND-VOLUME-ON-WEIGHT' (((Codes $res) -eq 'KIND-VOLUME-ON-WEIGHT') -and $res.unit_kind.value -eq 'volume') $s
  $res = Get-TcRowContract $row (RcCom 'condensed-milk' 'oz' @{ kind_equivalent = 'near-water' }); $s = Show $res
  T 'CLEAN TWIN  the same row on a commodity declaring kind_equivalent near-water is accepted, the source names the declaration' (($res.verdict -eq 'accept') -and ($res.unit_kind.source -match 'near-water')) $s
  $res = Get-TcRowContract $row (RcCom 'condensed-milk' 'oz' @{ kind_equivalent = 'syrupy' }); $s = Show $res
  T 'MUST FIRE  an unrecognised kind_equivalent value is not a density declaration' ((Codes $res) -eq 'KIND-VOLUME-ON-WEIGHT') $s
  $res = Get-TcRowContract $row $cm -KindReviewed; $s = Show $res
  T 'MUST NOT FIRE  a size string reviewed in basis-kind-allowlist.json is accepted' ($res.verdict -eq 'accept') $s
  $res = Get-TcRowContract (RcRow 'Walmart' 'Great Value Sweetened Condensed Milk, 14 oz' '$1.98' '14 oz') $cm; $s = Show $res
  T 'MUST NOT FIRE  a weight-labelled 14 oz can on the same commodity is accepted at 14 oz' (($res.verdict -eq 'accept') -and $res.size.value -eq 14 -and $res.unit_kind.value -eq 'weight') $s
  $res = Get-TcRowContract (RcRow 'Walmart' 'Great Value Olive Oil 32 oz (907 g)' '$9.98' '32 oz (907 g)') (RcCom 'olive-oil' 'floz'); $s = Show $res
  T 'MUST FIRE  a weight label (32 oz (907 g)) on a floz commodity with no density is KIND-WEIGHT-ON-VOLUME' ((Codes $res) -eq 'KIND-WEIGHT-ON-VOLUME') $s

  $res = Get-TcRowContract (RcRow "Sam's Club" "Member's Mark Olive Oil Cooking Spray, 7 oz., 2 pk." '$6.98' '14 fl oz') (RcCom 'cooking-spray' 'oz'); $s = Show $res
  T 'MUST FIRE  a fl oz size LABEL beside a name stating the same number as weight (7 oz., 2 pk. = 14) is KIND-LABELS-DISAGREE, never silently weight' (((Codes $res) -eq 'KIND-LABELS-DISAGREE') -and $res.unit_kind.value -eq 'disputed') $s
  $res = Get-TcRowContract (RcRow 'Aldi' 'Duke S Mayonnaise Real 32 OZ' '$4.47' '30 fl oz') (RcCom 'mayonnaise' 'oz'); $s = Show $res
  T 'CLEAN TWIN  a name weight that does NOT equal the size (32 OZ against 30 fl oz) settles nothing: KIND-VOLUME-ON-WEIGHT' ((Codes $res) -eq 'KIND-VOLUME-ON-WEIGHT') $s
  $res = Get-TcRowContract (RcRow 'Hy-Vee' '93% Lean 7% Fat Extra Lean Ground Beef' '$9.99' ' lbs ($9.99/lb)' 9.99) (RcCom 'ground-beef-93-7' 'lb'); $s = Show $res
  T 'MUST NOT FIRE  a per-lb rate printed in the size and equal to the price is a per-unit price (the engine''s rate-in-size branch)' (($res.verdict -eq 'accept') -and $res.price_basis.value -eq 'per-unit') $s
  $res = Get-TcRowContract (RcRow "Sam's Club" "Member's Mark Cage Free Grade AA Large White Eggs, 2 dozen" '$5.48' '2 dozen') (RcCom 'eggs' 'dozen'); $s = Show $res
  T 'MUST NOT FIRE  2 dozen eggs on the dozen commodity read 2 dozen' (($res.verdict -eq 'accept') -and $res.size.value -eq 2) $s

  # ---- 9ee1f9 (1): Hy-Vee 'Keurig coffee or cocoa, 8 or 10 ct., 12 oz., $6.99' read as pack x size (0.0582/oz)
  $line = 'Keurig coffee or cocoa, 8 or 10 ct., 12 oz., $6.99'
  $res = Get-TcRowContract (RcRow 'Hy-Vee' $line $line '') (RcCom 'coffee' 'oz'); $s = Show $res
  T 'MUST FIRE  9ee1f9 Keurig 8 or 10 ct., 12 oz. is PACK-COUNT-AMBIGUOUS, never 120 oz' ((Codes $res) -eq 'PACK-COUNT-AMBIGUOUS' -and $res.pack.form -eq 'either-or') $s
  $line = 'Folgers classic roast coffee, 12 oz., $6.99'
  $res = Get-TcRowContract (RcRow 'Hy-Vee' $line $line '') (RcCom 'coffee' 'oz'); $s = Show $res
  T 'CLEAN TWIN  a one-size Hy-Vee coffee line reads 12 oz from the line and is accepted' (($res.verdict -eq 'accept') -and $res.size.value -eq 12 -and $res.size.source -eq 'name') $s

  # ---- 9ee1f9 (2): 'Bakery-fresh large croissants, sold in a 6 ct. 5.94, $0.99 each' divided by the 6 ct (0.165/each)
  $line = 'Bakery-fresh large croissants, sold in a 6 ct. 5.94, $0.99 each'
  $res = Get-TcRowContract (RcRow 'Hy-Vee' $line $line '') (RcCom 'croissants' 'each'); $s = Show $res
  T 'MUST FIRE  9ee1f9 croissants: 6 x 0.99 = 5.94 is stated, so 0.99 is per piece and dividing again is PER-PIECE-PRICE-DIVIDED' ((($res.verdict -eq 'reprice') -and ((Codes $res) -eq 'PER-PIECE-PRICE-DIVIDED') -and $res.price_basis.value -eq 'per-piece')) $s
  $line = 'Bottled Water 24 Pack, $3.87 each'
  $res = Get-TcRowContract (RcRow 'Hy-Vee' $line $line '') (RcCom 'bottled-water' 'each'); $s = Show $res
  T 'CLEAN TWIN  Bottled Water 24 Pack, $3.87 each (no stated pack total) keeps the engine''s pack-beats-marker basis, 24' (($res.verdict -eq 'accept') -and $res.pack.count -eq 24 -and $res.price_basis.value -eq 'pack-total') $s

  # ---- 7c3a24: N-for-M deals on each-unit commodities with no stated count (30 rows, candidates-2026-09-28)
  $res = Get-TcRowContract (RcRow 'Family Fare' "Annie's Organic Shells & White Cheddar Macaroni & Cheese 6 Oz" '2 for $7.00' '6 oz' 4.69) (RcCom 'mac-and-cheese' 'each'); $s = Show $res
  T 'MUST FIRE  7c3a24 a 2 for $7.00 box with only a weight and no count on an each commodity is DEAL-COUNT-UNSTATED' ((Codes $res) -eq 'DEAL-COUNT-UNSTATED') $s
  $res = Get-TcRowContract (RcRow 'Family Fare' 'Betty Crocker Brownie Mix, Milk Chocolate 16.3 Oz' '2 for $4.00 with purchase of 2' '16.3 oz' 2.89) (RcCom 'brownie-mix' 'each' @{ weight_is_one_unit = $true }); $s = Show $res
  T 'CLEAN TWIN  the same shape on a weight_is_one_unit commodity is one unit, accepted, deal must-buy 2' (($res.verdict -eq 'accept') -and $res.pack.source -eq 'commodity.weight_is_one_unit' -and $res.deal.kind -eq 'must-buy' -and $res.deal.qty -eq 2) $s
  $res = Get-TcRowContract (RcRow 'Family Fare' 'Hass Avocados' '2 for $3.00' 'each' 1.99) (RcCom 'avocados' 'each'); $s = Show $res
  T 'MUST NOT FIRE  2 for $3.00 avocados with size each are one piece, accepted, deal n-for 2' (($res.verdict -eq 'accept') -and $res.deal.kind -eq 'n-for' -and $res.deal.qty -eq 2) $s
  $res = Get-TcRowContract (RcRow 'Family Fare' 'Pillsbury Toaster Pastries, Apple 6 Ea' '2 for $6.00' '6 ea' 3.49) (RcCom 'toaster-pastries' 'each'); $s = Show $res
  T 'CLEAN TWIN  a deal row that states its count (6 Ea) is a 6-pack, accepted (633d2b)' (($res.verdict -eq 'accept') -and $res.pack.count -eq 6) $s

  # ---- 6adf51: Get-MultibuyRefusalHalf calls a missed pack count a complete basis
  $soda = RcCom 'soda' 'floz'
  $res = Get-TcRowContract (RcRow 'Family Fare' 'Pepsi Diet Soda Cola 16.9 Fl Oz, 6 Count 6 Ea' 'Buy 2 get 1 free' '6 ea' 7.29) $soda; $s = Show $res
  T 'MUST FIRE  6adf51 Pepsi 16.9 Fl Oz, 6 Count priced on one bottle is PACK-COUNT-IGNORED (6 x 16.9 = 101.4)' ((($res.verdict -eq 'reprice') -and ((Codes $res) -eq 'PACK-COUNT-IGNORED') -and $res.pack.count -eq 6)) $s
  $res = Get-TcRowContract (RcRow 'Family Fare' 'Mr. Pibb Cherry Cola Soda Cans 12 Fl Oz' 'Buy 2 get 1 free' '12 fl oz' 10.99) $soda; $s = Show $res
  T 'MUST FIRE  6adf51 Mr. Pibb Soda Cans 12 Fl Oz at the 12-pack price, no count anywhere, is PACK-COUNT-UNSTATED' ((Codes $res) -eq 'PACK-COUNT-UNSTATED') $s
  $res = Get-TcRowContract (RcRow 'Family Fare' 'Coca Cola Soda Cans 12 Pk' 'Buy 2 get 1 free' '12 pack' 10.99) $soda; $s = Show $res
  T 'MUST FIRE  the 44 Coca Cola 12 Pk rows of 09-27 state a count and no can volume: KIND-COUNT-ON-MEASURE' ((Codes $res) -eq 'KIND-COUNT-ON-MEASURE') $s
  $res = Get-TcRowContract (RcRow "Sam's Club" 'Pepsi Cola 12 fl. oz., 30 pk.' '$16.98' '360 fl oz') $soda; $s = Show $res
  T 'CLEAN TWIN  Sam''s Pepsi 12 fl. oz., 30 pk. at 360 fl oz is the pack total by arithmetic, accepted' (($res.verdict -eq 'accept') -and $res.pack.count -eq 30 -and $res.pack.source -match 'pack total') $s
  # gr-08: an Aldi card whose size EQUALS one item proves nothing
  $water = RcCom 'bottled-water' 'floz'
  $res = Get-TcRowContract (RcRow 'Aldi' 'PurAqua Purified Water 24 Pack 16.9 FL OZ' '$3.19' '16.9 fl oz') $water; $s = Show $res
  T 'MUST FIRE  gr-08 an Aldi card sized as one item (16.9 fl oz) beside 24 Pack is PACK-BASIS-UNPROVEN' ((Codes $res) -eq 'PACK-BASIS-UNPROVEN') $s
  $wm = [pscustomobject]@{ store = 'Walmart'; item = 'Pure Life Purified Water, 16.9 fl oz, 24 Pack'; ad_price = '$4.48'; size = '16.9 fl oz'; qty_basis = "package; qty name (reproduces Walmart's unit price)" }
  $res = Get-TcRowContract $wm $water; $s = Show $res
  T 'CLEAN TWIN  a builder row whose store unit price reproduces the basis (qty_basis) is accepted from the builder shape' (($res.verdict -eq 'accept') -and $res.pack.source -match 'store unit price') $s

  # ---- 1eac5a: Sam's count PER POUND is a grade, not pieces (Test-SamsPerPieceUnit refused these correct rows)
  $lbC = RcCom 'shrimp' 'lb'
  $res = Get-TcRowContract (RcRow "Sam's Club" "Member's Mark Farm Raised Jumbo Raw Shrimp, Frozen, 21-25 ct. per pound, 2 lbs." '$16.97' '2 lb') $lbC; $s = Show $res
  T 'MUST NOT FIRE  1eac5a 21-25 ct. per pound, 2 lbs. is one 2 lb bag: accepted, pack count 1 count-per-container' (($res.verdict -eq 'accept') -and $res.pack.form -eq 'count-per-container' -and $res.pack.count -eq 1 -and $res.size.value -eq 2) $s
  $res = Get-TcRowContract (RcRow "Sam's Club" 'Royal Asia Farm Raised Shrimp Tempura, Frozen, 24 ct. per box, 2.07 lbs.' '$16.98' '2.07 lb') $lbC; $s = Show $res
  T 'MUST NOT FIRE  1eac5a 24 ct. per box, 2.07 lbs. is one box' (($res.verdict -eq 'accept') -and $res.pack.form -eq 'count-per-container') $s
  $res = Get-TcRowContract (RcRow "Sam's Club" "Member's Mark Wild Caught Skinless and Boneless Beer Battered Cod Fillets, Frozen, 11-15 ct., 2 lbs." '$18.96' '2 lb') (RcCom 'cod' 'lb'); $s = Show $res
  T 'MUST NOT FIRE  1eac5a 11-15 ct., 2 lbs. cod: the range beside the pack weight is pieces, accepted at 2 lb' (($res.verdict -eq 'accept') -and $res.size.value -eq 2) $s
  $line = 'Tyson chicken nuggets, 20-25 ct., 2 lb. bag, $7.99'
  $res = Get-TcRowContract (RcRow 'Hy-Vee' $line $line '') (RcCom 'chicken-nuggets' 'oz'); $s = Show $res
  T 'MUST FIRE  a piece-count range read out of a name as a multiplier of its weight is PACK-COUNT-AMBIGUOUS' ((Codes $res) -match 'PACK-COUNT-AMBIGUOUS') $s

  # ---- 35fdeb: garlic-bread / Fareway per-pack vs per-each
  $gb = RcCom 'garlic-bread' 'each' @{ pack_is_package = $true; weight_is_one_unit = $true }
  $res = Get-TcRowContract (RcRow 'Fareway' 'Fareway Garlic Texas Toast' '$3.99' '8 ct' '$4.49') $gb; $s = Show $res
  T 'MUST NOT FIRE  35fdeb Fareway Garlic Texas Toast 8 ct on pack_is_package is per PACKAGE, the 8 named as pieces inside' (($res.verdict -eq 'accept') -and $res.price_basis.value -eq 'per-package' -and $res.pack.count -eq 8 -and $res.pack.form -eq 'package' -and $res.deal.kind -eq 'markdown') $s
  $res = Get-TcRowContract (RcRow 'Fareway' 'Fareway Garlic Texas Toast' '$3.99' '8 ct') (RcCom 'texas-toast' 'each'); $s = Show $res
  T 'CLEAN TWIN  the same row on a commodity without pack_is_package is an 8-pack' (($res.verdict -eq 'accept') -and $res.price_basis.value -eq 'pack-total' -and $res.pack.count -eq 8) $s

  # ---- ab2257: band refusals with no basis evidence. The contract proves the basis, so the band's refusal is identity or a real price
  $res = Get-TcRowContract (RcRow 'Aldi' 'Head Shoulders Classic Clean Daily Shampoo 12.5 FL OZ' '$6.97' '12.5 fl oz') (RcCom 'shampoo' 'floz'); $s = Show $res
  T 'MUST NOT FIRE  ab2257 Aldi Head & Shoulders 12.5 fl oz: basis proven, so the band refused a product or a price, not a basis' (($res.verdict -eq 'accept') -and $res.size.value -eq 12.5 -and $res.unit_kind.value -eq 'volume') $s

  # ---- the remaining codes, one case each
  $res = Get-TcRowContract (RcRow 'Fareway' 'Fresh salsa' 'see store' '16 oz') (RcCom 'salsa' 'oz'); $s = Show $res
  T 'MUST FIRE  no money token anywhere is NO-PRICE' ((Codes $res) -eq 'NO-PRICE') $s
  $res = Get-TcRowContract (RcRow 'Family Fare' 'Dove Beauty Bar Soap Sensitive, 6 Ea' 'Buy 1 get 1 free' '6 ea') (RcCom 'bar-soap' 'each'); $s = Show $res
  T 'MUST FIRE  a buy-N-get-K row with no regular price is DEAL-NO-REGULAR' ((Codes $res) -eq 'DEAL-NO-REGULAR') $s
  $res = Get-TcRowContract (RcRow 'Fareway' 'Fresh salsa' '$3.99' '') (RcCom 'salsa' 'oz'); $s = Show $res
  T 'MUST FIRE  an oz commodity row with no amount anywhere is NO-SIZE' ((Codes $res) -eq 'NO-SIZE') $s
  $res = Get-TcRowContract (RcRow 'Fareway' 'Fresh Ground Chuck' '$4.99 lb.' '') (RcCom 'ground-chuck' 'lb'); $s = Show $res
  T 'MUST NOT FIRE  a per-lb rate with no package weight on an lb commodity is a per-unit price, not NO-SIZE' (($res.verdict -eq 'accept') -and $res.price_basis.value -eq 'per-unit') $s
  $res = Get-TcRowContract (RcRow 'Aldi' 'Benner Black Tea Bags 100 CT' '$1.49' '24 ct') (RcCom 'tea-bags' 'each'); $s = Show $res
  T 'MUST FIRE  8d2ad5 shape: name 100 CT against size 24 ct is PACK-CONFLICT' ((Codes $res) -eq 'PACK-CONFLICT') $s
  $res = Get-TcRowContract (RcRow 'Fareway' 'Deli Party Tray' '$12.99' '') (RcCom 'party-tray' 'each'); $s = Show $res
  T 'MUST FIRE  a bare package price on an each commodity, no count, is COUNT-UNSTATED' ((Codes $res) -eq 'COUNT-UNSTATED') $s
  $res = Get-TcRowContract (RcRow 'Hy-Vee' 'Hy-Vee cereal 12 oz or Kellogg''s Frosted Flakes 18 oz' '$2.99' '') (RcCom 'cereal' 'oz'); $s = Show $res
  T 'MUST FIRE  a name offering two sizes with no size field is SIZE-EITHER-OR' ((Codes $res) -eq 'SIZE-EITHER-OR') $s

  # ---- og-06: the 3% pack-total proof, exactly AT the bar and one step PAST it (4 x 25 oz = 100; 103 is 3/100, 104 is 4/100)
  $res = Get-TcRowContract (RcRow 'Walmart' 'Beans 25 oz, 4 pk' '$9.00' '103 oz') (RcCom 'beans' 'oz'); $s = Show $res
  T 'MUST NOT FIRE  AT the 3% bar: 103 oz against 4 x 25 is proven the pack total' (($res.verdict -eq 'accept') -and $res.pack.source -match 'pack total') ($s + ' src=' + $res.pack.source)
  $res = Get-TcRowContract (RcRow 'Walmart' 'Beans 25 oz, 4 pk' '$9.00' '104 oz') (RcCom 'beans' 'oz'); $s = Show $res
  T 'CLEAN TWIN  one step PAST the 3% bar (104 oz) is not proven the pack total; it is read as a package measure' (($res.verdict -eq 'accept') -and $res.pack.source -match 'package measure') ($s + ' src=' + $res.pack.source)

  # ---- every code in the lib's list fired at least once above (a code no case reaches is a refusal nobody tests)
  $codesA = Get-TcRowContractCodes; $codesB = Get-TcRowContractRepriceCodes
  $all = @($codesA) + @($codesB)
  $missing = @($all | Where-Object { -not $script:fired.ContainsKey($_) })
  T 'MUST NOT FIRE  no refusal or reprice code in the lib is left unfired by the cases above' ($missing.Count -eq 0) ($missing -join ',')
} catch { $script:f++; Write-Output ('  FAIL  threw: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.ScriptLineNumber) }
$want = 41
if ($script:n -ne $want) { $script:f++; Write-Output "  FAIL  ran $($script:n) of $want cases" }
if ($script:f) { Write-Output ("test-row-contract self-test FAIL: {0} check(s)" -f $script:f); exit 1 }
Write-Output ("test-row-contract self-test pass: {0} cases" -f $script:n)
exit 0
