<#
  add-review-acks-2026-07-31.ps1 - record the reviewed price flags from plan-2026-07-31.json items fa3102
  (13 flags, 2026-07-30) and 17f5d4 (9 flags, 2026-07-31) in out\review-ack.json.

  An ack is how a REVIEWED flag goes quiet. It is not how a flag gets ignored: every entry below names the
  store, the product, the size, the price and the arithmetic that makes the flagged number correct, and every
  one carries an EXPIRY (2026-08-14) so the flag re-arms if nobody looks again. check-ad-cycles treats an ack
  with no expiry, or an unparseable one, as already expired - by design.

  NOT ACKED, because they were real bugs and are fixed in this same change:
    SANITY|Achiote Paste|wow      - Walmart's "/ea" unit price on a 12 x 3.5 oz pack is per OUNCE; the derived
                                    42 shipped as a COUNT and published $4.64/oz for a $0.3867/oz paste.
                                    Fixed in build-walmart-deals.ps1 Build-Row + the row re-healed.
    SANITY|Spinach (fresh)|outlier - the "51% below runner-up" was frozen Pictsweet chopped spinach holding
                                    the FRESH spinach crown. Fixed by the commodities.json brand exclude.
  A flag that is right is acked. A flag that is right about something being WRONG is fixed.
#>
param([switch]$Apply)
$ErrorActionPreference = 'Stop'
$path = 'C:\Codex\ThriftyCrew\grocery\out\review-ack.json'
$expires = '2026-08-14'

# key -> reason (the evidence that makes the flagged number correct)
$adds = [ordered]@{
  # ---- 2026-07-30 alert (fa3102): 10 real-economics SANITY flags
  'SANITY|Coleslaw Mix|outlier'                    = "REAL BULK ECONOMICS. Sam's Club coleslaw 2 lb bag \$2.34 = \$0.0731/oz against Baker's \$0.16/oz. A club-size 32 oz bag against grocery-size 14 oz bags is the whole point of the store; the arithmetic reproduces exactly. Verified against the winning row in comparison-2026-07-30."
  'SANITY|Dog Treats|outlier'                      = "REAL BULK ECONOMICS. Sam's Club Milk-Bone 15 lb box \$13.98 = \$0.0582/oz against Baker's \$0.18/oz. A 240 oz box versus retail 24-36 oz boxes. Arithmetic exact; verified against the winning row in comparison-2026-07-30."
  'SANITY|Dried Cranberries|outlier'               = "REAL BULK ECONOMICS. Sam's Club Craisins 48 oz \$7.62 = \$0.1588/oz against Baker's \$0.26/oz. Standard club-pack spread on a shelf-stable dried fruit. Verified against the winning row in comparison-2026-07-30."
  'SANITY|Floor Cleaner|outlier'                   = "REAL BULK ECONOMICS. Sam's Club Member's Mark floor cleaner 1 gallon \$6.98 = \$0.0545/fl oz against Walmart \$0.14. A gallon jug against 32-64 oz retail bottles. Verified against the winning row in comparison-2026-07-30."
  'SANITY|Glass Cleaner|outlier'                   = "REAL STORE-BRAND SPREAD. Walmart Great Value glass cleaner 32 fl oz \$1.74 = \$0.0544/fl oz against Fareway \$0.09. Store brand against national brand on a commodity cleaner; no parse involved, the size is on the bottle. Verified against the winning row in comparison-2026-07-30."
  'SANITY|Gochujang (Korean Chili Paste)|outlier'  = "REAL STORE-BRAND SPREAD. Walmart bettergoods gochujang 12.5 oz \$3.26 = \$0.2608/oz against Hy-Vee \$0.42. Walmart's own new premium line undercutting imported jars is expected. Verified against the winning row in comparison-2026-07-30."
  'SANITY|Ground Cinnamon|wow'                     = "REAL REPRICE, NOT A PARSE. The cheapest moved 0.27 -> 0.42/oz because Sam's Club repriced its bulk cinnamon to \$0.4433/oz, which handed the crown to Aldi Stonemill 2.37 oz \$0.99 = \$0.4177/oz. Both numbers read off their raw rows; the move is the market, not the math."
  'SANITY|Microwave Popcorn|outlier'               = "REAL BULK ECONOMICS, and proven by the store's own per-each price. Sam's Club Orville Redenbacher's Movie Butter 1.5 oz., 36 pk. \$9.48, sams_unit_price \$0.26/ea, and 0.26 x 36 = 9.36 reproduces the line price - so \$9.48 IS the 36-pack total and \$0.26/each is correct 36-pack economics against Walmart's \$0.41. Same row and same proof as the PACKBASIS flag on this product."
  'SANITY|Peanuts|outlier'                         = "REAL BULK ECONOMICS. Sam's Club in-shell peanuts 5 lb \$5.98 = \$0.0748/oz against Aldi \$0.14. An 80 oz bag against retail 16 oz bags. Verified against the winning row in comparison-2026-07-30."
  'SANITY|Pickles (dill)|outlier'                  = "REAL BULK ECONOMICS, corroborated across stores. Sam's Club Mt. Olive dill pickles 1 gallon \$6.34 = \$0.0495/oz against Baker's \$0.09. Walmart's own 128 fl oz Mt. Olive at \$0.0623/oz corroborates the gallon basis, so this is jug-versus-jar, not a size parse."

  # ---- 2026-07-30 alert (fa3102): both PACKBASIS flags, each proven by the store's OWN per-each price
  'PACKBASIS|hummus|Sam''s Club'                   = "CORRECT PACK BASIS, proven by Sam's own arithmetic. 'Member's Mark Classic Hummus Singles 2.5 oz., 16 ct.' \$5.58 carries sams_unit_price \$0.35/ea, and 16 x 0.35 = 5.60 reproduces the line price - so \$5.58 IS the 16-pack total, 40 oz of hummus, and \$0.1395/oz is real bulk economics rather than a pack count multiplied into the size. The audit was right to hold it for review; the review says the number is sound."
  'PACKBASIS|microwave-popcorn|Sam''s Club'        = "CORRECT PACK BASIS, proven by Sam's own arithmetic. 'Orville Redenbacher's Movie Butter, 1.5 oz., 36 pk.' \$9.48 carries a \$0.26/ea unit price, and 0.26 x 36 = 9.36 reproduces the line price - so \$9.48 IS the 36-pack total and the per-bag basis is right. Held for review correctly; reviewed and sound."

  # ---- 2026-07-31 alert (17f5d4): 8 real-economics SANITY flags
  'SANITY|Baby Wipes|wow'                          = "REAL, and the arithmetic is exact. Sam's Club Pampers 924 ct \$18.48 = \$0.02/wipe. The 44% 'move' is rounding noise on a two-cent unit (0.01 -> 0.02 displayed), not a price event. Verified against the winning row in comparison-2026-07-30."
  'SANITY|Dill Weed (dried)|wow'                   = "REAL, caused by a capture change rather than a price change. Last week's cheaper Walmart jar left the capture, so the crown fell to Great Value dill weed 0.75 oz \$2.18 = \$2.9067/oz. That arithmetic is exact. The board is right; the previous week's cheaper row is simply no longer available to it."
  'SANITY|Drain Cleaner|wow'                       = "REAL STORE-BRAND PRICE. Walmart Great Value drain cleaner 80 fl oz \$5.77 = \$0.0721/fl oz. Size is on the bottle, arithmetic exact. Verified against the winning row in comparison-2026-07-30."
  'SANITY|Honeydew Melon|wow'                      = "REAL, a lapsed sale. Baker's whole honeydew is \$2.99 each at regular price; last week's \$1.49 was a sale that expired. The board correctly shows the regular price now. Verified against the winning row in comparison-2026-07-30."
  'SANITY|Onion Soup Mix (dry packets)|outlier'    = "REAL STORE-BRAND SPREAD, same package shape both sides. Family Fare 'Beefy Onion Soup Mix Our Family (2 Ct)' 2.2 oz \$1.29 = \$0.5864/oz against Hy-Vee's IDENTICAL 2.2 oz shape at \$1.99. Identical sizes, different brands - a pure store-brand spread with no basis difference to misread."
  'SANITY|Steak Sauce (A.1. style)|wow'            = "REAL, corroborated twice. Aldi Burman's steak sauce 10 oz \$1.99 = \$0.199/oz, corroborated by That's Smart at \$2.78 and by A.1. 2-pack \$8.68/30 oz. The -50% move is Aldi's store brand entering the cell, not a parse."
  'SANITY|Toothbrushes|wow'                        = "REAL, caused by a capture change. Walmart Reach 2 ct \$1.00 = \$0.50/each; last week's \$0.17/each 6-pack left the capture. Arithmetic exact on the row that remains."
  'SANITY|Vegetable / Vegetable Beef Soup (canned)|wow' = "REAL, and corroborated by two other stores. Walmart Progresso 19 oz \$2.48 = \$0.1305/oz, with Fareway and Hy-Vee both at \$0.1319/oz. Three stores within 1% of each other is not a parse error."
}

$text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
$doc = $text | ConvertFrom-Json
$have = @{}
foreach ($a in @($doc.acks)) { if ($a.key) { $have[[string]$a.key] = $true } }

$new = @()
foreach ($k in $adds.Keys) {
  if ($have.ContainsKey($k)) { Write-Output ("  skip (already acked): " + $k); continue }
  $new += [pscustomobject][ordered]@{ key = $k; reason = $adds[$k]; expires = $expires }
  Write-Output ("  ack " + $k)
}
Write-Output ("adding " + $new.Count + " ack(s) to " + @($doc.acks).Count + " existing, all expiring " + $expires)
if (-not $Apply) { Write-Output 'DRY RUN - pass -Apply to write.'; exit 0 }

$doc.acks = @(@($doc.acks) + $new)
$json = ($doc | ConvertTo-Json -Depth 12)
$null = $json | ConvertFrom-Json      # parse gate
[IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("wrote " + $path + " (" + @($doc.acks).Count + " acks)")
