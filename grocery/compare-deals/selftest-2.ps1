  # --- 21-24: a stale out\regular capture must not out-rank the store's own live feed ---------------------
  # FROZEN FOUNDING BUG (2026-07-30). out\regular\sams-regular-2026-07-14.json is a 60-row hand-promotion
  # that NOTHING refreshes. It loaded date-less, so Select-FreshestCaptureRows could never filter it, and
  # "cheapest row per store" handed 5 board cells to a 16-day-old price - including the ONIONS verdict,
  # published as Sam's $0.737/lb while Sam's own 2026-07-29 feed says $0.8267/lb and Aldi was cheapest at
  # $0.7967/lb. Synthetic and FROZEN: the pair below is the real founding case, never re-read from the board.
  # These compose the REAL loader decision with the REAL ranker filter, so neither can quietly stop being used.
  function _Eq($label, $got, $want) {
    if (("" + $got) -eq ("" + $want)) { Write-Output "ok    $label" }
    else { Write-Output ("FAIL  $label  got '" + $got + "' want '" + $want + "'"); $script:fail++ }
  }
  function _Row($n,$up,$sd) { [pscustomobject]@{ name=$n; unit_price=$up; src_date=$sd } }
  # 21. MUST FIRE: the Sam's out\regular capture carries its own capture date.
  _Eq "Sam's out\regular capture is dated" (Get-RegularSrcDate "Sam's Club" 'sams-regular-2026-07-14') '2026-07-14'
  # 22. MUST FIRE: dated, the 07-14 onions row LOSES to the 07-29 feed even though it is the cheaper number.
  $onion = @(Select-FreshestCaptureRows @(
    (_Row 'Yellow Onions, 10 lbs.' 0.737  (Get-RegularSrcDate "Sam's Club" 'sams-regular-2026-07-14')),
    (_Row 'Sweet Onions, 6 lbs.'   0.8267 '2026-07-29')
  ) | Sort-Object unit_price | Select-Object -First 1)
  _Eq "stale Sam's capture loses to today's feed" $onion.name 'Sweet Onions, 6 lbs.'
  # 23. CLEAN TWIN: a store whose out\regular file is its ONLY everyday source stays date-less, so its rows
  #     survive beside a newer weekly-AD row. Dating Baker's here would filter its whole everyday catalogue.
  _Eq "Baker's out\regular stays date-less" (Get-RegularSrcDate "Baker's" 'bakers-regular-2026-07-30') ''
  $bk = @(Select-FreshestCaptureRows @(
    (_Row 'Kroger 80/20 Ground Beef Roll 3 LB' 5.99 (Get-RegularSrcDate "Baker's" 'bakers-regular-2026-07-30')),
    (_Row "Baker's weekly ad row"              6.49 '2026-07-30')
  ))
  _Eq 'a single-source everyday store is never filtered out' $bk.Count 2
  # 24. CLEAN TWIN: with no fresher capture the stale rows are still the only Sam's price we have and must
  #     stay on the board - this fix corrects a stale-LOW, it must never silently drop coverage.
  $only = @(Select-FreshestCaptureRows @(
    (_Row "Member's Mark Whole Pork Tenderloins, Cryovac" 2.98 (Get-RegularSrcDate "Sam's Club" 'sams-regular-2026-07-14'))
  ))
  _Eq 'sole stale capture still prices its commodity' $only.Count 1

  # --- 25-27: a file of MIXED age must not lend its date to the rows it merely carries -------------------
  # FROZEN FOUNDING BUG (2026-08-02). refresh-sams-verified.ps1 re-prices the hand-verified Sam's rows a
  # fresh capture confirms and carries the rest unchanged, so out\regular\sams-regular-2026-08-01.json holds
  # 20 rows dated 08-01 and 40 still dated 07-26. Get-RegularSrcDate dates by FILENAME, so all 60 claimed
  # 08-01 and the carried ones out-ranked Sam's real 07-29 feed. Measured on the board that produced this
  # fix: sandwich-bags flipped from the 580-ct Ziploc at $0.0168/ea to a 300-ct SNACK bag at $0.0309/ea,
  # 84% dearer and re-verified by nobody. Guard 4 caught it at 0.54x against the stored link.
  _Eq 'a carried row keeps its OWN older date, not the file''s' (Get-RowSrcDate "Sam's Club" ([pscustomobject]@{ as_of = '2026-07-26' }) '2026-08-01') '2026-07-26'
  $mixed = @(Select-FreshestCaptureRows @(
    (_Row 'Ziploc Snack Bags'                  0.0309 (Get-RowSrcDate "Sam's Club" ([pscustomobject]@{ as_of = '2026-07-26' }) '2026-08-01')),
    (_Row 'Ziploc Brand Sandwich Bags, 580 ct' 0.0168 '2026-07-29')
  ) | Sort-Object unit_price | Select-Object -First 1)
  _Eq 'the real feed still wins over a merely-carried row' $mixed.name 'Ziploc Brand Sandwich Bags, 580 ct'

  # --- 25-28: COVERAGE DEPTH. A capture only displaces an older one if it knows at least as much. -------
  # FROZEN FOUNDING BUG (2026-08-06). Sam's baby-formula: sams-deals-2026-08-05 held ONE formula row (Bubs
  # Goat Milk, $1.4445/oz) and sams-deals-2026-07-29 held twenty-plus including Member's Mark Advantage
  # Premium at $0.7704/oz. Under "newest wins outright" the 1-row capture took the commodity and the live
  # cell jumped +87%, with every price, basis and crown guard reading green because both rows are real.
  # 58 cells estate-wide. Synthetic and FROZEN, never re-read from the board.
  # 25. MUST FIRE: the richer OLDER capture stays eligible, so the cheap real row still prices the cell.
  $formula = @(Select-FreshestCaptureRows @(
    (_Row 'Bubs Goat Milk Infant Formula Powder With Iron, 20 oz., 2 pk.' 1.4445 '2026-08-05'),
    (_Row "Member's Mark, Advantage Premium, Infant Formula, 48 oz." 0.7704 '2026-07-29'),
    (_Row "Member's Mark, Infant Premium, Infant Formula, 48 oz."     0.8017 '2026-07-29'),
    (_Row "Member's Mark Sensitivity Premium Baby Formula, 48 oz."    0.8329 '2026-07-29')
  ) | Sort-Object unit_price | Select-Object -First 1)
  _Eq 'a 1-row capture does not evict a 3-row one' $formula.name "Member's Mark, Advantage Premium, Infant Formula, 48 oz."
  # 26. CLEAN TWIN, AND IT IS THE ONIONS BUG ITSELF: when the newer capture is RICHER it still displaces the
  #     older one outright. If this ever flips, the depth rule has been written as "cheapest in the window"
  #     and case 22 above is being argued with. The stale-LOW $0.737 must stay dead.
  $onionDepth = @(Select-FreshestCaptureRows @(
    (_Row 'Yellow Onions, 10 lbs.'   0.737  '2026-07-14'),
    (_Row 'Sweet Onions, 6 lbs.'     0.8267 '2026-07-29'),
    (_Row 'Red Onions, 5 lbs.'       0.9100 '2026-07-29'),
    (_Row 'Vidalia Onions, 10 lbs.'  0.9500 '2026-07-29')
  ) | Sort-Object unit_price | Select-Object -First 1)
  _Eq 'a RICHER newer capture still evicts the stale-low' $onionDepth.name 'Sweet Onions, 6 lbs.'
  # 27. TIES GO TO THE FRESHER CAPTURE. Equal coverage means the newer one is strictly better information,
  #     and this is the shape of case 22's real data (1 row vs 1 row), so it must not regress.
  $tie = @(Select-FreshestCaptureRows @(
    (_Row 'Old Yellow Onions, 10 lbs.' 0.737  '2026-07-14'),
    (_Row 'New Sweet Onions, 6 lbs.'   0.8267 '2026-07-29')
  ) | Sort-Object unit_price | Select-Object -First 1)
  _Eq 'equal coverage still goes to the newer capture' $tie.name 'New Sweet Onions, 6 lbs.'
  # 28. CLEAN TWIN: a thinner newer capture that is also CHEAPER still wins on price. Keeping the richer
  #     capture eligible must never mean preferring it - it competes, it does not outrank.
  $cheapThin = @(Select-FreshestCaptureRows @(
    (_Row "Member's Mark Butter, 4 lb."   2.98 '2026-08-05'),
    (_Row 'Land O Lakes Butter, 2 lb.'    4.15 '2026-07-29'),
    (_Row 'Kerrygold Butter, 1 lb.'       6.20 '2026-07-29')
  ) | Sort-Object unit_price | Select-Object -First 1)
  _Eq 'a thin but genuinely cheaper capture still wins' $cheapThin.name "Member's Mark Butter, 4 lb."
  # 28b. MUST FIRE - THE FROZEN CHERRIES CASE (2026-08-21). One product, split into its everyday half and
  #      its sale half, must not present as a two-product capture. This is the real data: Walmart item id
  #      46491694 in the 2026-07-14 capture, against the single row the 2026-08-11 capture holds.
  #      Under row-counting the July capture scored 2 against August's 1, survived, and its $2.50/lb sale
  #      won the cell while Walmart was charging $6.97/lb - a price 38 days dead, one cent off the crown.
  $splitInflated = @(Select-FreshestCaptureRows @(
    (_Row 'Fresh Red Cherries'               2.5000 '2026-07-14'),   # the SAME product, sale half
    (_Row 'Fresh Red Cherries'               4.9600 '2026-07-14'),   # ...and everyday half
    (_Row 'Fresh Red Cherries, 2.25 lb Bag'  6.9689 '2026-08-11')
  ) | Sort-Object unit_price | Select-Object -First 1)
  _Eq 'a split one-product capture does not out-depth a live one' $splitInflated.name 'Fresh Red Cherries, 2.25 lb Bag'
  # 28c. CLEAN TWIN for 28b, and it is the guard against over-correcting into "distinct is per capture-wide
  #      name". TWO GENUINELY DIFFERENT products in the older capture still out-depth the newer single row -
  #      the baby-formula fix must survive the cherries fix. Same prices as 28b so the only variable is
  #      whether the older capture's two rows name one product or two.
  $twoRealProducts = @(Select-FreshestCaptureRows @(
    (_Row 'Fresh Red Cherries'               2.5000 '2026-07-14'),
    (_Row 'Rainier Cherries, 2 lb Bag'       4.9600 '2026-07-14'),
    (_Row 'Fresh Red Cherries, 2.25 lb Bag'  6.9689 '2026-08-11')
  ) | Sort-Object unit_price | Select-Object -First 1)
  _Eq 'two REAL products still out-depth a newer single row' $twoRealProducts.name 'Fresh Red Cherries'

  # --- 29-31: SAME PRODUCT, TWO CAPTURES. The older row of a product loses to its own newer row. --------
  # FROZEN FOUNDING BUG (2026-09-05). The union is name-keyed, so one product captured twice presents as
  # two independent candidates and cheapest-per-store takes the older one whenever the price went up.
  # Measured on comparison-2026-09-02: 18 cells (7 crowns) priced from a capture the same product's newer
  # capture contradicted. Rows below are copied verbatim from candidates-2026-09-02.json (name, per-unit,
  # capture date); each capture is a real SUBSET chosen to preserve the depth relation that made both
  # captures eligible, which is the whole point - if the depth rule had already evicted the older capture
  # these cases would pass without the supersession running at all.
  function _RowK($n,$up,$sd,$k) { [pscustomobject]@{ name=$n; unit_price=$up; src_date=$sd; prod_key=$k } }
  # 29. MUST FIRE - THE 60-CHARACTER TRUNCATION. Walmart's July batch captures cut every name at exactly 60
  #     chars and carry no item_id, so the full-name row of the SAME product can never supersede it by name.
  #     Live cell: vegetable-broth/Walmart published $0.0399/floz from 2026-07-18 while the same Great Value
  #     carton's 2026-08-31 row says $0.0469. 132 of the 152 distinct truncated July names have a full-name
  #     twin in a newer capture.
  $truncName = 'Great Value Gluten-Free Vegetable Broth, 32 oz Carton, Shelf'
  _Eq 'the July batch name is exactly 60 characters' $truncName.Length 60
  # THE item_id FIELDS ARE PART OF THE FIXTURE, and they are what makes this case bite. The July batch rows
  # carry NO id and their newer full-name twins DO, so an identity that PREFERS the id and falls back to the
  # name puts the pair in two different groups and supersedes nothing. That is exactly how the first cut of
  # this rule shipped a no-op: the board rebuilt, every exact-name twin moved, and vegetable-broth quietly
  # went on pricing from 2026-07-18. Identity has to be the union of both relations, not a preference.
  $vbPool = @(
    (_RowK 'Pacific Foods Low Sodium Organic Vegetable Broth, 32 oz Carton'                   0.1069 '2026-09-01' '15529703'),
    (_RowK 'Great Value Gluten-Free Vegetable Broth, 32 oz Carton, Shelf-Stable, No Allergens' 0.0469 '2026-08-31' '54258473'),
    (_RowK 'Great Value Organic Gluten-Free Vegetable Broth, 32 oz Carton (Shelf-Stable)'      0.0619 '2026-08-31' '396785612'),
    (_RowK 'Swanson Vegetable Broth, 32 oz Carton'                                             0.0709 '2026-08-31' '21296165'),
    (_RowK $truncName                                                                          0.0399 '2026-07-18' ''),
    (_RowK 'Great Value Organic Gluten-Free Vegetable Broth, 32 oz Carto'                      0.0621 '2026-07-18' ''),
    (_RowK 'Pacific Foods Low Sodium Organic Vegetable Broth, 32 oz Cart'                      0.1060 '2026-07-18' '')
  )
  $vbBefore = @($vbPool | Sort-Object unit_price | Select-Object -First 1)
  _Eq 'before: the truncated July row is the cheapest row in the pool' $vbBefore.name $truncName
  $vb = @(Select-FreshestCaptureRows $vbPool | Sort-Object unit_price | Select-Object -First 1)
  _Eq 'a 60-char name is superseded by its unique longer twin' $vb.name 'Great Value Gluten-Free Vegetable Broth, 32 oz Carton, Shelf-Stable, No Allergens'
  _Eq 'and the cell prices at the NEWER number' $vb.unit_price 0.0469
  # 30. MUST FIRE - THE EXACT-NAME TWIN. shower-cleaner/Walmart published $0.0544/floz from 2026-08-11 while
  #     the identical name in the 2026-08-31 capture says $0.0619. Real subset: 08-31 (depth 3) and 08-11
  #     (depth 3) both out-depth the newest 09-03 capture (depth 2), so both are eligible and only the
  #     supersession can decide this.
  $scPool = @(
    (_Row 'Scrubbing Bubbles Foaming Bleach Bathroom Shower & Tub Cleaner Spray, Mold & Mildew Stain Remover, 32 oz' 0.1241 '2026-09-03'),
    (_Row 'Clorox Bleach Foamer Bathroom and Shower Cleaner Spray, Crisp Lemon, 30 fl oz'                            0.1760 '2026-09-03'),
    (_Row 'Great Value Bathroom Cleaner with Bleach, 32 fl oz'                                                       0.0619 '2026-08-31'),
    (_Row 'Comet Bathroom Cleaner Spray, Lemon, 32 oz'                                                               0.1241 '2026-08-31'),
    (_Row 'Great Value Lemon Scent Foaming Bathroom Cleaner, 22 oz'                                                  0.1700 '2026-08-31'),
    (_Row 'Great Value Bathroom Cleaner with Bleach, 32 fl oz'                                                       0.0544 '2026-08-11'),
    (_Row 'Clorox Plus Tilex Daily Shower Cleaner and Bathroom Spray, 32 fl oz'                                      0.1303 '2026-08-11'),
    (_Row 'Zep Foaming Tub and Tile Cleaner, Morning Rain Scent, 32 fl oz'                                           0.1325 '2026-08-11')
  )
  $scBefore = @($scPool | Sort-Object unit_price | Select-Object -First 1)
  _Eq 'before: the 08-11 row is the cheapest row in the pool' $scBefore.unit_price 0.0544
  $sc = @(Select-FreshestCaptureRows $scPool | Sort-Object unit_price | Select-Object -First 1)
  _Eq 'the same exact name from an older capture is superseded' $sc.unit_price 0.0619
  # 30b. MUST FIRE - A STORE ID BEATS A RENAME. Walmart re-words a listing between captures, so name equality
  #      alone would leave the stale row standing. Same item_id, two names, two dates: only the newer prices.
  $renamed = @(Select-FreshestCaptureRows @(
    (_RowK 'Mina Harissa Mild Sauce, Homestyle Moroccan Red Pepper Haris' 0.845 '2026-07-18' '773599552'),
    (_RowK 'Mina Harissa Mild Sauce, Homestyle Moroccan Red Pepper Harissa Paste, 10 oz' 0.891 '2026-08-31' '773599552'),
    (_RowK 'Simply Organic Harissa, 3.2 Oz' 3.3200 '2026-08-31' '589728561')
  ))
  _Eq 'an item_id twin collapses to the newer row' $renamed.Count 2
  _Eq 'and the surviving twin is the newer one' @($renamed | Where-Object { $_.prod_key -eq '773599552' })[0].unit_price 0.891
  # 31. CLEAN TWINS. Nothing below may move, or the rule is deleting real prices rather than stale ones.
  #     (a) two DIFFERENT products of the same brand across captures both stay, and the depth rule still
  #         keeps the deeper older capture - cases 25-28 must survive this change untouched.
  $knorr = @(Select-FreshestCaptureRows @(
    (_Row 'Knorr Chicken Flavor Bouillon Cubes, 3.1 oz, 8 Pack Box' 0.3484 '2026-09-04'),
    (_Row 'Knorr Shelf Stable Granulated Chicken Bouillon, 32 oz Jar' 0.1681 '2026-08-31'),
    (_Row 'Knorr Beef Flavor Bouillon Cubes, 8 Count'                0.3481 '2026-08-31'),
    (_Row 'Maggi Granulated Chicken Flavor Bouillon Powder, 16 oz'   0.2013 '2026-08-31')
  ) | Sort-Object unit_price | Select-Object -First 1)
  _Eq 'two different products across captures both stay eligible' $knorr.name 'Knorr Shelf Stable Granulated Chicken Bouillon, 32 oz Jar'
  #     (b) AN AMBIGUOUS TRUNCATION IS NOT AN IDENTITY. When two longer names both start with the 60-char
  #         one, the truncation cannot prove which product it was and the row must survive. Guessing here
  #         would delete a real cheapest price on a coincidence of prefixes.
  $ambigTrunc = 'Great Value Organic Gluten-Free Vegetable Broth, 32 oz Carto'
  _Eq 'the ambiguous truncation is also exactly 60 characters' $ambigTrunc.Length 60
  $ambigPool = @(
    (_Row 'Great Value Organic Gluten-Free Vegetable Broth, 32 oz Carton (Shelf-Stable)' 0.0619 '2026-08-31'),
    (_Row 'Great Value Organic Gluten-Free Vegetable Broth, 32 oz Cartons, 4 Pack'       0.0700 '2026-08-31'),
    (_Row 'Swanson Vegetable Broth, 32 oz Carton'                                        0.0709 '2026-08-31'),
    (_Row $ambigTrunc                                                                    0.0621 '2026-07-18'),
    (_Row 'Pacific Foods Low Sodium Organic Vegetable Broth, 32 oz Cart'                 0.1060 '2026-07-18'),
    (_Row 'Swanson Organic Vegetable Broth, 32 oz Carton'                                0.0890 '2026-07-18'),
    (_Row 'Kitchen Basics Original Vegetable Stock, 32 oz Carton'                        0.0950 '2026-07-18')
  )
  # The older capture must be DEEPER (4 distinct vs 3), or the depth rule evicts it and this case passes
  # without the ambiguity ever being tested. Asserting the survivor count pins that.
  $ambigRows = @(Select-FreshestCaptureRows $ambigPool)
  _Eq 'both captures are eligible, so the ambiguity is what is under test' $ambigRows.Count 7
  _Eq 'an ambiguous 60-char prefix is NOT superseded' @($ambigRows | Where-Object { $_.name -eq $ambigTrunc }).Count 1

  # 32. MUST FIRE - DEPTH CHOSE THE PRODUCTS, RECENCY MUST PRICE THEM (2026-09-05). Frozen from lettuce at
  #     Sam's Club, where the board published 1.0367 while the SAME product had been seen twelve days later
  #     at 0.81. The depth rule is right to keep 07-17 (2 products) over the 1-row captures around it - that
  #     is a coverage judgement. But it was also deciding the PRICE, and it has nothing to say about that.
  #     The 09-01 row is the newest sighting and carries NO usable price (the sanity band refused it), so a
  #     rule that only looks for a strictly NEWER price finds nothing and leaves the stale number standing.
  $lettuce = @(Select-FreshestCaptureRows @(
    (_Row 'Romaine Hearts, 6 ct.'    $null  '2026-09-01'),
    (_Row 'Iceberg Lettuce, 2 heads' 1.23   '2026-08-23'),
    (_Row 'Romaine Hearts, 6 ct.'    0.81   '2026-07-29'),
    (_Row 'Romaine Hearts, 6 ct.'    1.0367 '2026-07-17'),
    (_Row 'Iceberg Lettuce, 2 heads' 1.485  '2026-07-17')
  ))
  $romaine = @($lettuce | Where-Object { $_.name -eq 'Romaine Hearts, 6 ct.' })
  _Eq 'the romaine row is priced from its most recent USABLE sighting, not the capture depth kept' $romaine[0].unit_price 0.81
  _Eq 'and exactly one romaine row survives - this re-prices, it never duplicates' $romaine.Count 1

  # 33. CLEAN TWIN - IT MUST NOT RESURRECT A THIN CAPTURE. This is the 2026-08-06 founding bug of the depth
  #     rule itself (a 1-row Sam's capture evicting a 20-row one, +87% on baby formula). Re-pricing may
  #     change what a kept row COSTS; it must never change WHICH products are eligible. The thin newer
  #     capture holds a product the deep older one does not, and that product must stay out.
  $thin = @(Select-FreshestCaptureRows @(
    (_Row 'Bubs Goat Milk Infant Formula' 1.4445 '2026-08-05'),
    (_Row "Member's Mark Infant Formula"  0.7704 '2026-07-29'),
    (_Row 'Enfamil NeuroPro Infant Formula' 0.9100 '2026-07-29'),
    (_Row 'Similac 360 Total Care Formula'  0.8800 '2026-07-29')
  ))
  # THE NEWEST CAPTURE IS ALWAYS ELIGIBLE - that was never the 2026-08-06 bug. The bug was the newest
  # capture winning OUTRIGHT and discarding the deeper older one, so the fix kept BOTH. The invariant
  # re-pricing must not break is therefore not 'the thin row is absent' (it is present, by design) but
  # 'the thin row still cannot WIN, and re-pricing did not quietly change what it costs'.
  # Written after the first cut of this fixture asserted the wrong thing and failed - the assertion was
  # wrong about the design, not the code, and correcting a false expectation is not weakening a test.
  $bubs = @($thin | Where-Object { $_.name -eq 'Bubs Goat Milk Infant Formula' })
  _Eq 'the thin capture row is eligible, exactly as the depth rule has always allowed' $bubs.Count 1
  _Eq 'and re-pricing left its price untouched - there is no newer sighting of it' $bubs[0].unit_price 1.4445
  _Eq 'and the deep older capture still prices the cell' (@($thin | Sort-Object unit_price | Select-Object -First 1).unit_price) 0.7704

  # 34. CLEAN TWIN - A NEWER SIGHTING WITH NO USABLE PRICE IS NOT A PRICE. If could-not-price were allowed
  #     to win, a band-refused row would blank a real cell, which is strictly worse than a stale one.
  $blank = @(Select-FreshestCaptureRows @(
    (_Row 'Solo Product, 1 ct.' $null  '2026-09-01'),
    (_Row 'Solo Product, 1 ct.' 0.5000 '2026-08-01')
  ))
  _Eq 'a priceless newest sighting falls back to the newest USABLE one' $blank[0].unit_price 0.5
  #     (b2) TRANSITIVITY. A three-capture chain - a truncated July name, its full-name twin carrying an id,
  #          and a later capture of that id under a re-worded name - is ONE product, and only the newest
  #          may price. If the grouping were pairwise rather than transitive, the July row would survive
  #          behind the rename.
  $chain = @(Select-FreshestCaptureRows @(
    (_RowK 'Knorr Select Vegetable Base, Shelf Stable Granulated Bouillon Reformulated' 0.7000 '2026-09-01' '198431752'),
    (_RowK 'Knorr Select Vegetable Base, Shelf Stable Granulated Bouillon, 1.82 pounds' 0.6169 '2026-08-31' '198431752'),
    (_RowK 'Knorr Select Vegetable Base, Shelf Stable Granulated Bouillo'               0.0813 '2026-07-18' ''),
    (_RowK 'Maggi Granulated Chicken Flavor Bouillon Powder, 16 oz'                     0.2013 '2026-07-18' '9911'),
    (_RowK 'Knorr Beef Flavor Bouillon Cubes, 8 Count'                                  0.3481 '2026-07-18' '9912')
  ))
  _Eq 'a truncated name, its id-bearing twin and a rename collapse to ONE product' (
    @($chain | Where-Object { $_.name -like 'Knorr Select*' }).Count) 1
  _Eq 'and the survivor is the newest of the chain' (
    @($chain | Where-Object { $_.name -like 'Knorr Select*' })[0].src_date) '2026-09-01'
  #     (c) DIFFERENT ids, similar names: two real products, two rows. The id key must not fold them.
  $twoIds = @(Select-FreshestCaptureRows @(
    (_RowK 'Great Value Curry Powder, 2 oz'         1.06 '2026-08-11' '111'),
    (_RowK 'Great Value Organic Curry Powder, 1.8 oz' 2.4222 '2026-08-11' '222')
  ))
  _Eq 'different ids stay two rows' $twoIds.Count 2
  #     (d) A ROW WITH NO CAPTURE DATE IS NEVER SUPERSEDED. Every non-Walmart, non-Sam's store loads
  #         date-less; folding those by name would let one store's ad row delete its own everyday row.
  $undated = @(Select-FreshestCaptureRows @(
    (_Row 'Fareway Sausage Gravy' 0.1053 ''),
    (_Row 'Fareway Sausage Gravy' 0.1200 ''),
    (_Row 'Chef-mate Country Sausage Gravy, 105 oz.' 0.0912 '2026-09-04')
  ))
  _Eq 'undated rows are never superseded by each other' $undated.Count 3
  # CLEAN TWIN: the direction that must NOT work. A row claiming to be FRESHER than the file it lives in is
  # the as_of laundering fixed in the Fareway builder the same day; taking its word would let a stale price
  # out-rank a live one, which is the exact failure this whole family of fixes exists to prevent.
  _Eq 'a row claiming to be FRESHER than its file is ignored' (Get-RowSrcDate "Sam's Club" ([pscustomobject]@{ as_of = '2026-08-05' }) '2026-08-01') '2026-08-01'
  # MUST FIRE: A PROMOTED FILE IS NOT A CAPTURE (2026-08-21). hunter-*-regular-<date>.json holds a
  # handful of hand-looked-up prices, but the freshness ranker reads "newest capture" as an authority
  # about COVERAGE. Dated, a nine-row file became Walmart's newest capture at depth 1 for every
  # commodity it touched, which re-admitted five weeks of superseded captures: bouillon/Walmart went
  # from 0.1681 to a 2026-07-18 vegetable base at 0.0813, and tile-integrity hard-failed it at 2.07x.
  # Undated, these rows behave like every non-Walmart store's - always eligible, competing on price,
  # never displacing a real capture and never admitting one.
  _Eq 'a hunter- promoted file is UNDATED, so it cannot become the newest capture' (Get-RegularSrcDate 'Walmart' 'hunter-walmart-regular-2026-08-16') ''
  _Eq 'a hunter- Sam''s file is undated too' (Get-RegularSrcDate "Sam's Club" 'hunter-samsclub-regular-2026-08-16') ''
  # CLEAN TWIN: a REAL Walmart capture must still be dated, or the ranker loses its ordering entirely
  # and the onions bug walks straight back in.
  _Eq 'a real walmart capture is still dated' (Get-RegularSrcDate 'Walmart' 'walmart-regular-2026-08-11') '2026-08-11'
  # CLEAN TWIN: Walmart is deliberately OUT of scope. Its 14-day union carries rows forward with their
  # original as_of, so re-dating them changes which capture owns a commodity - measured live on 2026-08-02 as
  # three cells landing at ~2x their own link. Pinned here so nobody widens the rule without redoing that work.
  _Eq 'Walmart rows still take the FILE date (its union owns their ordering)' (Get-RowSrcDate 'Walmart' ([pscustomobject]@{ as_of = '2026-07-18' }) '2026-08-01') '2026-08-01'

  # --- 28-40: ROUTING fixtures for the 2026-08-06 rule edits (triage plan-2026-08-06) ---------------------
  # A rule change's whole effect is WHERE A PRODUCT ENDS UP after first-match-wins, so these run the REAL
  # Match-Category over the REAL commodities.json rather than asserting a regex in isolation. Match-Category
  # and $GLOBAL_EXCLUDE are defined AFTER this block exits, so they are extracted from this script's own
  # source and evaluated here - the same trick the 'snax' case above uses, and for the same reason: a
  # transcribed copy would pass whether or not the engine still does this.
  # MUST-FIRE / CLEAN-TWIN pairs, every name a REAL captured row:
  #   R1 oat-milk needed a word boundary  - 'oat milk' matches inside 'GOAT milk'
  #   R2 eggs ate an Aldi breakfast PIZZA it could never price per dozen
  #   R3 canned-green-beans claimed FRESH steam-in-bag beans
  #   R4 whipped-cream's adjacency could not cross the word Dairy
  #   R5 frozen-lasagna's blanket 'pasta' exclude (aimed at dry noodle boxes) ate a real frozen lasagna
  #   R6 acorn-squash could not read the store's 'Acorn/Table Queen Squash' naming
  #   R7 storage-bags is labelled (gallon) and had no size guard at all - a PINT cell was live at Fareway
  $cdSelfSrc = Get-Content $__cdHostPath -Raw
  $mcSrc = [regex]::Match($cdSelfSrc, '(?s)\r?\nfunction Get-MatchTexts.*?\r?\n\}\r?\nfunction Match-Category.*?\r?\n  return \$null\r?\n\}')
  # $GLOBAL_EXCLUDE comes from the library now (I82); only Match-Category is still lifted from source,
  # because it IS defined after this block and is not a shared concern. The assertion that the fixtures
  # examined something REAL is unchanged: if either half is missing, they examined nothing and say so.
  . (Join-Path $__cdHostDir 'global-exclude-lib.ps1')
  # ASSIGN, THEN WRAP. `@(Get-TcGlobalExclude).Count` is the documented trap: a comma-returned array
  # reads as ONE element, so an empty list would score 1 and this check would pass on nothing.
  $gexList = Get-TcGlobalExclude
  $gexOk = @($gexList).Count -gt 1
  if (-not $mcSrc.Success -or -not $gexOk) {
    Write-Output 'FAIL  could not load Match-Category / GLOBAL_EXCLUDE - the routing fixtures EXAMINED NOTHING'; $script:fail++
  } else {
    $GLOBAL_EXCLUDE = Get-TcGlobalExclude
    Invoke-Expression $mcSrc.Value
    function _Route($label, $name, $want) {
      $c = Match-Category $name
      $got = if ($c) { [string]$c.id } else { '<unmatched>' }
      if ($got -eq $want) { Write-Output ("ok    route: $label -> $got") }
      else { Write-Output ("FAIL  route: $label -> got '$got' want '$want'  [" + $name + ']'); $script:fail++ }
    }
    # MUST-FIRE (each of these routes WRONG on the pre-2026-08-06 rules)
    _Route 'R1 goat-milk formula reaches baby-formula' "Bubs Goat Milk Infant Formula Powder With Iron, 20 oz., 2 pk." 'baby-formula'
    _Route 'R1 evaporated goat milk leaves oat-milk'   'Meyenberg Evaporated Vitamin D Goat Milk Unsweetened, 12 fl oz' '<unmatched>'
    _Route 'R2 breakfast pizza leaves eggs'            'Breakfast Best Sausage Egg Cheese Breakfast Pizza 2pk 112 OZ' 'frozen-pizza'
    _Route 'R3 fresh steam-bag beans leave canned'     "Member's Mark Extra Fine Whole Green Beans 16 oz. steam bags, 5 ct." '<unmatched>'
    _Route 'R4 whipped DAIRY topping is admitted'      'Friendly Farms Whipped Dairy Topping 13 FL OZ' 'whipped-cream'
    _Route 'R5 Stouffers Party Size Pasta (Frozen)'    "Stouffer's Classic Lasagna with Meat and Sauce, Party Size Pasta, Frozen Meals, 90 oz (Frozen)" 'frozen-lasagna'
    _Route 'R6 store slash-naming acorn squash'        'Acorn/Table Queen Squash' 'acorn-squash'
    # R19 (2026-09-06, queue 2026-09-06-796030): a store's own SHELF NAME for a product the board already
    # prices. Kroger calls its 16 oz French bread a 'French Loaf' and the include library could not say so;
    # Walmart lists Ortega's taco sauce as 'Taco and Enchilada Chili Sauce', which the include could not see
    # AND which the bare 'enchilada' exclude would have killed even after a widening - the 2026-07-31
    # hot-sauce lesson from the exclude side. Both route to <unmatched> on the pre-2026-09-06 rules, so
    # neither case can pass until the tokens land.
    _Route 'R19 Kroger French Loaf reaches french-bread'  'Private Selection French Loaf Sliced' 'french-bread'
    _Route 'R19 the unsliced loaf routes the same way'    'Private Selection French Loaf' 'french-bread'
    _Route 'R19 Ortega taco-and-enchilada is taco sauce'  'Ortega Original Thick and Smooth Medium Taco and Enchilada Chili Sauce, Kosher, 8 oz' 'taco-sauce'
    _Route 'R19 ...and the 16 oz jar of the same'         'Ortega Original Thick and Smooth Mild Taco and Enchilada Chili Sauce, Kosher, 16 oz' 'taco-sauce'
    # CLEAN TWINS for R19: the narrowed exclude must still refuse a REAL enchilada sauce, and the two names
    # that already worked must not move. If the enchilada twin ever routes to taco-sauce the narrowing went
    # too far and the board is pricing enchilada sauce as taco sauce.
    _Route 'R19 twin: a real enchilada sauce is NOT taco sauce' 'Ortega Mild Red Enchilada Sauce 10 oz' 'enchilada-sauce'
    _Route 'R19 twin: plain taco sauce unchanged'         'Great Value Taco Sauce Mild Gluten Free Paleo Keto Bottle, 16 oz' 'taco-sauce'
    _Route 'R19 twin: plain french bread unchanged'       'Fresh & Finest French Bread' 'french-bread'
    # R7's quart case expected '<unmatched>' when it shipped, because quart bags had NO home - being
    # excluded from the gallon commodity meant falling off the board entirely. R14 below gives them one,
    # so the expectation moves from "nowhere" to "the quart commodity". The ASSERTION is unchanged and is
    # the one that matters: a quart bag must never be priced as a gallon bag.
    _Route 'R7 QUART bags leave the (gallon) commodity' 'Boulder Quart Slider Storage Bags 40 CT' 'quart-storage-bags'
    _Route 'R7 PINT bags leave the (gallon) commodity'  'Bright Essentials Freezer Bags, Zipper, Pint Size' '<unmatched>'
    # HALF GALLON, added by the developer the same day: with only quart+pint excluded, the Sam's cell moved
    # from a QUART box to a HALF GALLON box ($0.0764/each) while Sam's own true gallon box sat at $0.0792 -
    # the same misleading comparison one size down. Measured over the 14-day corpus: exactly 2 names carry
    # 'half gallon' into this commodity (this one and a Baker's Kroger slider that loses to its own store's
    # gallon box anyway), so the whole cost is Sam's cell moving 3.7% up to a like-for-like gallon price.
    _Route 'R7 HALF-GALLON bags leave it too'           "Ziploc Brand Half Gallon Freezer Storage Bags, Expandable Bottom, Grip 'n Seal Technology, 160 ct." '<unmatched>'
    _Route 'a plain GALLON Ziploc box still routes'     'Ziploc Brand Gallon Storage Bags, Stay Open Design, Easy to Fill, 208 ct.' 'storage-bags'
    # CLEAN TWINS (a token too broad shows up here, not on the board)
    _Route 'real oat milk still routes'                'Planet Oat Original Oatmilk, 52 oz' 'oat-milk'
    _Route 'Aldi oat milk still routes'                'Friendly Farms Original Oatmilk 64 FL OZ' 'oat-milk'
    _Route 'a real dozen of eggs still routes'         'Goldhen Grade A Large Eggs 12 CT' 'eggs'
    _Route 'canned cut green beans still route'        'Del Monte Fancy Cut Green Beans, 101 oz.' 'canned-green-beans'
    _Route 'plain whipped topping still routes'        'Kroger Original Whipped Topping' 'whipped-cream'
    # R5's twin, in two halves. First a REAL captured row: a dry box is claimed by lasagna-noodles (index 201)
    # long before frozen-lasagna (252), so it can never become a frozen dinner. Then a SYNTHETIC name that
    # actually isolates the guard - it reaches frozen-lasagna's include, carries 'pasta', and carries NO frozen
    # marker, so the exclude must still bite. Measured 2026-08-06: every real dry lasagna-pasta row in the
    # corpus is claimed by pasta / brown-rice / lasagna-noodles first, so only a synthetic row can reach here.
    _Route 'a DRY lasagna box lands on lasagna-noodles' 'Great Value Lasagna Pasta, 16 oz' 'lasagna-noodles'
    _Route 'pasta still excludes when NOT frozen'       'Store Brand Lasagna with Meat Sauce, Pasta, 38 oz' '<unmatched>'
    _Route 'a GALLON bag box still routes'             'Great Value Freezer Guard Double Zipper Gallon Freezer Bag, 80 Count' 'storage-bags'
    _Route 'the Aldi crown bag row is untouched'       'Boulder Twin Lock Storage Bags 40 CT' 'storage-bags'

    # --- R8-R13, 2026-08-06 second pass: SIX WRONG PRODUCTS THAT WERE LIVE ON THE BOARD --------------------
    # Found by audit-capture-eviction.ps1 on the day it was written, not by any existing guard. All six had
    # been matching their commodity for a long time and losing on price, so nothing ever surfaced them. Then
    # the resumed partial Walmart pull of 2026-08-06 landed a capture holding ONE row for each of these
    # commodities, that capture won the commodity outright under Select-FreshestCaptureRows, and the wrong
    # product became the cell. A latent routing bug and a thin capture are individually survivable; together
    # they put shredded CARROTS on the oranges row at $3.09/lb.
    # Each exclude was measured against every candidate row in the live corpus first: 9 rows leave in total,
    # all nine wrong products, and no store loses coverage (every one falls through to a correct cheaper row).
    _Route 'R8 shredded orange CARROTS leave oranges'  'Fresh Shredded Orange Carrots, 10 Oz Bag' 'carrots'
    _Route 'R9 garlic parmesan SEASONING leaves cheese' 'Weber Garlic Parmesan Seasoning, Gluten Free, 4.3 oz' '<unmatched>'
    _Route 'R9 Sams parmesan pepper seasoning too'     "Member's Mark Parmesan Pepper Seasoning, 7.5 oz." '<unmatched>'
    _Route 'R10 the SEASONING brand named Cookies'     'Cookies Flavor Enhancer All Purpose Seasoning & Rub, 8 oz' '<unmatched>'
    _Route 'R11 worcestershire SEASONING is not sauce' 'Grill Mates Kosher Cracked Peppercorn & Worcestershire Seasoning, 2.75 oz Bottle' '<unmatched>'
    _Route 'R12 teriyaki BEEF BITES are not sauce'     "Jack Link's 100% Beef Teriyaki Tender Bites 10Ounce Resealable Bag" '<unmatched>'
    _Route 'R12 the Bakers teriyaki beef sticks too'   "Jack Link's x MrBeast Teriyaki Beef Sticks, 9.20 ounce, 10 count of .92 oz meat sticks" '<unmatched>'
    _Route 'R13 jarred BRUSCHETTA is not fresh tomato' 'Cara Mia Tomato Bruschetta, 14.8 oz. Jar' '<unmatched>'
    # CLEAN TWINS: the real product of each of the six must be untouched, or a token is too broad.
    _Route 'R8 twin: real navel oranges still route'   'Fresh Navel Oranges, 4 lb Bag' 'oranges'
    _Route 'R9 twin: real grated parmesan still routes' 'Great Value Grated Parmesan Cheese, 16 oz Bottle' 'parmesan'
    _Route 'R10 twin: real cookies still route'        'Great Value Classic Chocolate Chip Cookies, 18.2 oz' 'cookies'
    _Route 'R11 twin: real worcestershire still routes' 'Great Value Worcestershire Sauce, 10 fl oz' 'worcestershire'
    _Route 'R12 twin: real teriyaki sauce still routes' 'Great Value Teriyaki Sauce, 15 fl oz, 1 Count' 'teriyaki-sauce'
    _Route 'R13 twin: fresh tomatoes still route'      'Fresh Beefsteak Tomatoes, Each' 'tomatoes'

    # --- R14, 2026-08-06: BAGS SPLIT BY SIZE (Brad's call) ----------------------------------------------
    # storage-bags was one commodity labelled "(gallon)" that excluded every other size, so quart bags had
    # no home at all - 8 real products across Aldi, Sam's and Walmart priced nothing. Now gallon / quart /
    # sandwich are three commodities. Measured over the 14-day corpus first: 95 distinct bag names, 44
    # gallon, 35 sandwich, 7 quart, 4 half-gallon, 1 pint.
    # THE TRAP IS THE COMBO PACK. Sam's sells "Gallon & Quart" and "Variety Pack" boxes whose count mixes
    # sizes, so they can price NEITHER per-gallon-bag nor per-quart-bag honestly - the count is a blend and
    # any per-bag figure invents a split that is not on the label. Both sides exclude them on purpose, which
    # is why half-gallon and pint also stay unmatched rather than being folded into the nearest size.
    _Route 'R14 Aldi quart bags get a home'            'Boulder Quart Slider Storage Bags 40 CT' 'quart-storage-bags'
    _Route 'R14 Sams quart bags too'                   'Ziploc Brand Quart Storage Bags, Stay Open Design, Easy to Fill, 216 ct.' 'quart-storage-bags'
    _Route 'R14 quart wording can be mid-name'         "Ziploc Freezer Quart Food Storage Bags, School Supplies, Stay Open Design, Grip 'n Seal Technology, Zipper, 100 Count" 'quart-storage-bags'
    # MUST-FIRE: the mixed-size boxes belong to NEITHER size.
    _Route 'R14 a GALLON+QUART combo box is neither'   'Ziploc Brand Gallon & Quart  Storage Bags, Stay Open Design, Easy to Fill, 204 ct.' '<unmatched>'
    _Route 'R14 a VARIETY pack is neither'             'Ziploc Gallon Quart Freezer and Storage Slider Bags Variety Pack, Power Shield Technology, 149 ct.' '<unmatched>'
    _Route 'R14 half gallon still has no home'         'Kroger Slider Half Gallon Freezer Storage Bags' '<unmatched>'
    # CLEAN TWINS: the other two sizes are untouched by the new commodity.
    _Route 'R14 twin: gallon still routes'             'Bright Essentials Storage Bags, Double Zipper, 20 Gallon' 'storage-bags'
    _Route 'R14 twin: the Aldi gallon crown is safe'   'Boulder Twin Lock Storage Bags 40 CT' 'storage-bags'
    _Route 'R14 twin: sandwich bags still route'       'Great Value Sandwich Bags, 180 Count' 'sandwich-bags'
    # R15: the loose 'zipper bags?' include is GONE. Measured over 27,659 corpus names it admitted exactly
    # ONE product and that product was dried fruit - every real bag row is caught by the storage/freezer/
    # slider tokens. A food package described by its packaging is not a storage bag.
    _Route 'R15 dried fruit in a zipper bag is not a bag' 'Sun-Maid Dried Mangos 15oz Resealable Stand-Up Zipper Bag' '<unmatched>'
    # 2026-09-26 (queue 2026-09-26-177835): zucchini now excludes 'dehydrated', a ruled move frozen in
    # plan-2026-09-26-2.routing.json (before zucchini, after none). The case still proves the pouch is not a bag.
    _Route 'R15 a mylar food pouch is not a quart bag'  'Dehydrated Zucchini, 1 Full Quart Mylar Bag' '<unmatched>'

    # --- R16, 2026-08-06: WOOD POLISH IS NOT CITRUS -----------------------------------------------------
    # audit-household-in-food HARD-FAILED the publish on the full Walmart re-pull: Pledge "Orange Enhancing"
    # wood polish was landing in the EDIBLE commodity 'oranges'. The gap was a disarmed sibling, not a new
    # class - 'lemons' has excluded 'polish' for a while and 'oranges'/'limes' never got the same guard, so
    # the defence existed and simply was not applied across the family. Measured over the 14-day corpus:
    # 7 rows leave oranges, all seven wood-care products, zero real fruit; limes loses nothing today and is
    # guarded anyway so the family stops depending on which citrus a brand happens to scent this season.
    # 'pledge' is carried alongside 'polish' because one row is "Pledge Wood Oil ... Orange Scent" with no
    # word "polish" in it at all - the brand token is what makes the class complete.
    # Both land in furniture-polish, which is their real home - releasing them from a fruit commodity does
    # not orphan them, it lets the household commodity that was always right for them finally claim them.
    _Route 'R16 orange-scented wood polish is not fruit' 'Pledge Expert Care, Wood Polish Shines and Protects, Orange Enhancing, Aerosol, 9.7 oz., Pack of 3' 'furniture-polish'
    _Route 'R16 Pledge wood OIL has no word polish'      'Pledge Wood Oil, Expert Care, Trigger Spray - Moisturizes & Revives with Orange Scent, 16 oz' 'furniture-polish'
    _Route 'R16 twin: real navel oranges are untouched'  'Fresh Navel Oranges, 4 lb Bag' 'oranges'
    _Route 'R16 twin: real limes are untouched'          'Fresh Limes, Each' 'limes'

    # --- R17, 2026-08-06: INFANT PUREE NAMING TWO VEGETABLES IS NOT PRODUCE ------------------------------
    # THE FOUNDING BUG: "Cerebelly 6+ Months Organic Spinach Apple Sweet Potato Puree 4 Oz" matched the
    # include of THREE produce commodities (apples \bapple(s)?\b, spinach, sweet-potatoes) and was excluded
    # by none, so first-match-wins gave a 4 oz baby-food jar to whichever sorts first and priced fresh
    # produce at a baby-food per-ounce rate. audit-match-soundness flagged it 'new-contested' and it was then
    # ACCEPTED into the baseline as part of an unrelated tortilla move, so it would never have re-surfaced.
    # THE SHAPE: this is the third instance (happy\s*tot 07-28, serenity\s*kids 08-01). Every one is a
    # baby/toddler brand whose name happens to list the produce inside it. baby-food sits at index 297 and
    # apples at 20, so widening baby-food's include can never win the race - the fix has to be an EXCLUDE,
    # which is why all three live in $GLOBAL_EXCLUDE.
    # Measured over all 28,526 estate names before shipping: 17 routing changes, nothing left a commodity it
    # belonged to. The simulation also caught a defect in the FIX - carrying the brand token into baby-food's
    # include dragged in "Little Journey Gentle Baby Wash Shampoo", so baby-food now excludes personal-care
    # forms. That row is the clean twin below.
    _Route 'R17 the founding Cerebelly jar leaves produce' 'Cerebelly 6+ Months Organic Spinach Apple Sweet Potato Puree 4 Oz' 'baby-food'
    _Route 'R17 Aldi Little Journey puree leaves apples'   'Little Journey Apple Sweet Potato Puree 4 OZ' 'baby-food'
    _Route 'R17 a toddler pouch leaves apples'             'Once Upon A Farm No Added Sugar Apple, Sweet Potato & Spinach Toddler Tractor Wheels 5 Ea' 'baby-food'
    _Route 'R17 infant yogurt cup leaves yogurt'           'Little Journey Apple Banana Peach Yogurt 4 OZ' 'baby-food'
    _Route 'R17 infant puree leaves bananas'               'Little Journey Apple Blueberry Banana Puree 4 OZ' 'baby-food'
    # These two were globally excluded but had no home - the include widening is what recovers them.
    _Route 'R17 Happy Tot pouch is no longer orphaned'     'Happy Tot Stage 4 Organic Pears Blueberries & Spinach Pouch' 'baby-food'
    _Route 'R17 Serenity Kids pouch is no longer orphaned' 'Serenity Kids Free Range Chicken & Thyme with Organic Parsnip & Beet Pouch, 3.5oz' 'baby-food'
    # CLEAN TWINS. The first is the fix's own near-miss; the rest prove the brand tokens did not evict the
    # commodities that legitimately sell these brands (the eviction the serenity\s*kids note warns about).
    _Route 'R17 twin: the brand SHAMPOO is not baby food'  'Little Journey Gentle Baby Wash Shampoo With Oatmeal Extract 16 FL OZ' '<unmatched>'
    _Route 'R17 twin: Little Journey wipes keep their cell' 'Little Journey Sensitive Baby Wipes 192 CT' 'baby-wipes'
    _Route 'R17 twin: Little Journey diapers keep theirs'  'Little Journey Size 4 Club Pack Diapers 82 CT' 'diapers'
    _Route 'R17 twin: real apples are untouched'           'Fresh Gala Apples, 3 lb Bag' 'apples'
    _Route 'R17 twin: real spinach is untouched'           'Fresh Baby Spinach, 10 oz Clamshell' 'spinach'
    _Route 'R17 twin: real sweet potatoes are untouched'   'Sweet Potatoes, 3 lb Bag' 'sweet-potatoes'
    _Route 'R17 twin: real yogurt is untouched'            'Great Value Plain Greek Yogurt, 32 oz' 'yogurt'

    # --- R18, 2026-08-30: APPLESAUCE IS ONE WORD, SO '\bsauce\b' NEVER SAW IT ----------------------------
    # THE FOUNDING BUG: "(6 Pack) Mott's Mango Peach Applesauce Cups, 4 oz" held the WALMART CHEAPEST
    # mangoes cell at $0.4467/each, beating the real $0.75 Fresh Red Mango. Nothing in the rules changed -
    # the row simply arrived in walmart-regular-2026-08-30.json, and every rule that should have stopped it
    # was already looking at the wrong spelling. '\bsauce\b' has been global since the beginning and
    # mangoes carries its own '\bsauces?\b'; BOTH need a word boundary before "sauce", and "applesauce" has
    # none. So the identical product reads as excluded when a store spells it "Apple Sauce" (Tree Top) and
    # as fresh fruit when a store spells it "Applesauce" (Mott's).
    # THE SHAPE: applesauce sits at 225 and every flavour word it names sits earlier, so first-match-wins
    # gives the row to the flavour, not the food. Measured on the 2026-08-30 inputs, FOUR commodities were
    # holding applesauce rows: bananas (17), watermelon (27), peaches (28), mangoes (113). A mangoes-only
    # exclude fixes one cell of four and re-opens on the next flavour Mott's ships. Hence the global token.
    # Measured before shipping: exactly ONE board cell moved (mangoes/Walmart 0.4467 -> 0.75), applesauce
    # went 353 -> 362 rows, and audit-match-soundness reported one MOVED, which is this.
    _Route 'R18 the founding applesauce cup leaves mangoes' "(6 Pack) Mott's Mango Peach Applesauce Cups, 4 oz" 'applesauce'
    _Route 'R18 flavoured applesauce leaves watermelon'    "Musselman's Watermelon Applesauce, 3.17oz, 10 Count" 'applesauce'
    _Route 'R18 flavoured applesauce leaves peaches'       'GoGo squeeZ FruitZ & VeggieZ Dino Pear Peach Carrot Applesauce Pouches, 3.2 oz (16 Pack)' 'applesauce'
    _Route 'R18 flavoured applesauce leaves bananas'       'GoGo squeeZ Toy Story 5 No Sugar Added Banana Strawberry Applesauce Variety Pouches, 3.2 oz' 'applesauce'
    # CLEAN TWINS. The first is the cell the bug took, and the one number a reader would check. The next two
    # are the eviction this token could have caused - applesauce relaxes it, in BOTH spellings. The last is
    # the \b: unanchored, this token would swallow "PineAPPLE SAUCE" and hand it to applesauce.
    _Route 'R18 twin: the real mango keeps its cell'       'Fresh Red Mango' 'mangoes'
    _Route 'R18 twin: plain applesauce keeps its commodity' 'Great Value Unsweetened Applesauce, 46 oz Jar' 'applesauce'
    _Route 'R18 twin: the SPACED spelling still routes'    'Tree Top Apple Sauce Pouches, No Sugar Added, 3.2 Oz, 12 Count' 'applesauce'
    _Route 'R18 twin: pineapple sauce is not applesauce'   '12 ct 3.17 oz Golden Farms Organic Pineapple Sauce, Unsweetened, 3.17 oz., 12 pk.' '<unmatched>'

    # --- R20, 2026-09-19: A SCENT IS A FOOD WORD ON A THING NOBODY EATS (board-wrong-cells-0919) -----------
    # THE FOUNDING BUG: "Dawn Ultra Strawberry Field Scent" (Family Fare weekly ad, $6.49 / 38 oz) held Family
    # Fare's STRAWBERRIES cell at 0.1708/oz from the 2026-09-13 board on. strawberries' include claims it and
    # sits before dish-soap, so first-match-wins priced dish soap as fruit. No rule changed; the product arrived.
    # The fix is the global '\bscent(?:s|ed)?\b', relaxed by every non-food commodity. Measured over 50,954
    # corpus names before shipping: 8 names moved, every one a scented non-food product leaving a food row.
    _Route 'R20 MUST FIRE the Dawn soap leaves strawberries'  'Dawn Ultra Strawberry Field Scent' 'dish-soap'
    _Route 'R20 MUST FIRE a scented sanitizer leaves apples'  'Germ-X Subtle Green Apple Scented Hand Sanitizer, Vitamin E & Plant-Based Alcohol, {8 fl oz}' 'hand-sanitizer'
    _Route 'R20 MUST FIRE a shave gel leaves raspberries'     'Skintimate Signature Scents Shave Gel for Women Moisturizing Raspberry Rain Scent' 'shaving-cream'
    _Route 'R20 MUST FIRE a tanning oil leaves coconut-oil'   'Hawaiian Tropic Dark Tanning Oil Iconic Tropical Scent With Coconut Oil Enhances Tan + Moisturizes' '<unmatched>'
    # CLEAN TWINS: the relax_global half. A scented product a non-food commodity owns keeps its cell, and the
    # real fruit is untouched - the eviction the serenity\s*kids note warns about, checked in both directions.
    _Route 'R20 twin: scented wipes keep their cell'          'Kroger Lemon Scent Disinfecting Wipes' 'disinfecting-wipes'
    _Route 'R20 twin: scented dish soap keeps its cell'       'Kroger Ultra Concentrated Liquid Dish Soap Clean Scent' 'dish-soap'
    _Route 'R20 twin: real strawberries are untouched'        'Fresh Strawberries' 'strawberries'
    # --- R21, 2026-09-18: THE SAME CLASS SPELLED WITHOUT 'scent' (backlog I215 + I217) --------------------
    # Once audit-household-in-food read the ad files, the seeded 2026-09-17/18 inputs held these four in food
    # cells, verbatim: a Family Fare ad row naming Dawn by brand alone, and three Baker's regular rows. The
    # styling gel held Baker's coconut-oil cell at 0.2806/oz on the published board. Global token
    # '(?:\bdawn\b|nail\s+polish|styling\s+gel)', relaxed by every non-food commodity beside the scent one.
    _Route 'R21 MUST FIRE a Dawn ad row leaves lemons'        'Dawn Plat Ba Clean Lemon' '<unmatched>'
    _Route 'R21 MUST FIRE a styling gel leaves coconut-oil'   'Eco Style Coconut Oil Styling Gel' '<unmatched>'
    _Route 'R21 MUST FIRE a nail polish leaves canned-beets'  'Sally Hansen Miracle Gel Nail Polish 474 Can''t Beet Royalty' '<unmatched>'
    _Route 'R21 MUST FIRE a nail polish leaves dried-thyme'   'Sally Hansen Nail Polish - Thyme Off' '<unmatched>'
    # CLEAN TWINS: the relax_global half (Dawn's own soap and sponge rows stay where they belong) and the food
    # half (real coconut oil and real lemons still route).
    _Route 'R21 twin: a Dawn dish soap keeps dish-soap'       'Dawn Platinum EZ- Squeeze Liquid Dish Soap, Lemon, 3 ct., 61.5 fl. oz.' 'dish-soap'
    _Route 'R21 twin: a Dawn sponge keeps sponges'            'Dawn Foam Sponge, Non-Scratch, Blue, 2-Pack' 'sponges'
    _Route 'R21 twin: real coconut oil still routes'          'Kroger Pure Refined Coconut Oil' 'coconut-oil'
    _Route 'R21 twin: real lemons still route'                'Fresh Lemons' 'lemons'
  }

  # ---- 29. EITHER/OR ADS (2026-08-29). One price, two different packages, size field "each". Reading a
  # size out of that name is a coin flip weighted toward the bigger package, so the row must go UNPRICED.
  # The founding pair are both real crowns off comparison-2026-08-26.
  function _Amb($label, $name, $want) {
    $got = [bool](Test-NameOffersTwoSizes $name)
    if ($got -eq $want) { Write-Output ("ok    $label") } else { Write-Output ("FAIL  $label  got $got want $want"); $script:fail++ }
  }
  _Amb 'either/or: the ice-cream crown is ambiguous'   'Kroger Ice Cream 48 fl oz or Private Selection Ice Cream 16 fl oz' $true
  _Amb 'either/or: the popsicles crown is ambiguous'   'Kroger Freezer Pops 36 ct or Budget Saver Twin Ice Pops 12-18 ct' $true
  _Amb 'either/or: two weights across the or'          'Eckrich Smoked Sausage 12-14 oz or Prime Fresh Lunch Meat 7-8 oz' $true
  # MUST NOT FIRE - these stay priceable, or the refusal is a coverage bug wearing a safety badge
  _Amb 'one size shared across an or is NOT ambiguous' 'Orange or Apple Juice 64 fl oz' $false
  _Amb 'matching sizes across an or are NOT ambiguous' 'Coca-Cola 12 pk or Pepsi 12 pk' $false
  _Amb 'an ordinary single-size name is NOT ambiguous' 'Kroger Ice Cream 48 fl oz' $false
  _Amb 'a name with no "or" is NOT ambiguous'          'Private Selection Double Vanilla Ice Cream Tub 48 oz' $false
  _Amb 'the word "original" does not contain an "or"'  'Original Ranch Dressing 16 fl oz' $false
  # REAL PRODUCTION DATA, and the case the first version got WRONG. thriftycrew-11 scanned all 415 rows of
  # the 2026-08-29 Walmart capture: these are the only two "or" names in it, and the "or" joins two
  # DESCRIPTIONS ("Pie Filling Or Topping"), not two packages. The first version refused the second one -
  # it read "2 pk" against "21 oz" as a disagreement. Different unit families are not an alternative.
  _Amb 'an "or" joining descriptions, sizes after it'  'Lucky Leaf Premium Strawberry Rhubarb Pie Filling Or Topping, 21 oz Can (2 Pack)' $false
  _Amb 'same row, pack count moved to the FRONT'       '( 2 Pack ) Lucky Leaf Premium Strawberry Rhubarb Pie Filling Or Topping, 21 oz Can' $false
  _Amb 'a pack count against a weight is not a choice' 'Something 2 pk or Other Thing 21 oz' $false
  # --- 'each' is a size too (2026-08-31, queue 2026-08-31-8018b5) ------------------------------------------
  # THE FOUNDING ROW, verbatim off the live board: $3.48 buys a 3-count romaine pack OR one cauliflower, and
  # the name fallback took "3 ct" and published cauliflower at $1.16 - the crown, and a real $3.48.
  _Amb 'either/or: a pack count against a bare "each"' 'Bud by Dole romaine hearts 3 ct. pkg. or cauliflower each, $3.48' $true
  _Amb 'either/or: "each" reaches the pk family too'   'Something 3 pk or Other Thing each' $true
  # MUST NOT FIRE. 'each' only speaks when the OTHER side states a count, so these stay priceable.
  _Amb 'a lone "sold each" is not an alternative'      'Fresh Cauliflower or Broccoli Crown, sold each' $false
  _Amb '"each" on BOTH sides agrees, so not ambiguous' 'Romaine Hearts each or Cauliflower each' $false
  _Amb '"each" against a WEIGHT is not a choice'       'Something 21 oz or Other Thing each' $false
  _Amb '"each" with no "or" is not ambiguous'          'Fresh Whole Cauliflower, each' $false
  # 'each' must not be read out of the middle of a word ("peaches", "teach", "reach") - that would refuse
  # half the produce aisle.
  _Amb 'the word "peaches" does not contain an "each"' 'Peaches 3 ct or Nectarines 3 ct' $false
  # AND THE REFUSAL MUST REACH THE PRICE, which took three tries to get right and is the point of the test.
  # Refusing the COUNT does not make this row unpriceable: the ad states $3.48 for one cauliflower, and the
  # per-each marker says exactly that. So the right answer is 3.48, NOT null and emphatically not 3.48/3.
  # Both shapes are pinned, because Hy-Vee passes the whole ad line as price_text AND as name, and the
  # count used to be read from either.
  _Near 'cauliflower either/or prices per-each, not /3' (Get-UnitPrice (_D 'Bud by Dole romaine hearts 3 ct. pkg. or cauliflower each, $3.48' 'Bud by Dole romaine hearts 3 ct. pkg. or cauliflower each, $3.48' $null '') (_C 'each')).unit_price 3.48 0.005
  _Near 'same row, clean price_text, still per-each'   (Get-UnitPrice (_D '$3.48' 'Bud by Dole romaine hearts 3 ct. pkg. or cauliflower each, $3.48' $null '') (_C 'each')).unit_price 3.48 0.005
  # CLEAN TWIN: the pack count still beats the per-each marker when the name is NOT ambiguous. This is the
  # 2026-08-22 bottled-water lesson and it must survive the refusal above.
  _Near 'unambiguous pack count still beats per-each'  (Get-UnitPrice (_D '$3.87 each' 'Bottled Water 24 Pack' $null '') (_C 'each')).unit_price 0.1613 0.0005
  # AND THE REFUSAL MUST REACH THE PRICE, or it is decoration. Both branches of Get-UnitPrice, with the
  # size field unusable ("each") exactly as the real rows have it.
  _Null 'either/or ice cream is UNPRICED (volume)'  (Get-UnitPrice (_D '$1.99' 'Kroger Ice Cream 48 fl oz or Private Selection Ice Cream 16 fl oz' $null 'each') (_C 'floz'))
  _Null 'either/or freezer pops is UNPRICED (each)' (Get-UnitPrice (_D '$2.99' 'Kroger Freezer Pops 36 ct or Budget Saver Twin Ice Pops 12-18 ct' $null '') (_C 'each'))
  # CLEAN TWIN: an unambiguous name in the same shape still prices off its name, so the fallback survives.
  _Near 'single-size name still prices from the name' (Get-UnitPrice (_D '$1.99' 'Kroger Ice Cream 48 fl oz' $null 'each') (_C 'floz')).unit_price 0.0415 0.0005

  # ---- 30. THE LIFT MUST BE CLOSED (2026-08-29; mechanism changed 2026-09-09, backlog I82). Three
  # scripts - build-walmart-deals.ps1, build-sams-deals.ps1, import-walmart-batch.ps1 - used to pull named
  # functions out of this file AS SOURCE TEXT and Invoke-Expression them, each from its own hand-maintained
  # list. Adding Test-NameOffersTwoSizes and updating only ONE list left the other two lifting a
  # Get-UnitPrice whose helper did not exist: the lift succeeded, load was clean, and it died at CALL time.
  # The functions live in pricing-math-lib.ps1 now and all three dot-source it, so this section asserts
  # that they do and that the library is closed under calling. The lift still live - import-walmart-batch
  # cutting Build-Row out of build-walmart-deals - is checked by ops\audit-lift-completeness.ps1.
  # A NAME IN A COMMENT IS NOT A CALL. The first version of this check flagged all three lifters because
  # Get-UnitPrice's prose mentions Get-MatchTexts ("the engine strips it in Get-MatchTexts for exactly...").
  # A checker that cannot tell a call from a sentence would have had three files edited to satisfy it, so
  # strip line comments - keeping quoted segments, which may legitimately contain '#' - before scanning.
  function _StripComments([string]$src) {
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in ($src -split "`r?`n")) {
      $out.Add([regex]::Replace($line, "('[^']*')|(`"[^`"]*`")|#.*", {
        param($m) if ($m.Groups[1].Success -or $m.Groups[2].Success) { $m.Value } else { '' } }))
    }
    return ($out -join "`n")
  }
  # This file's pieces (grocery\compare-deals\) read back in place, so every engine function is still seen here.
  . (Join-Path (Split-Path -Parent $__cdHostDir) 'lib\selftest-lib.ps1')
  $engineText = Expand-SelfTestPointers -Text (Get-Content $__cdHostPath -Raw -Encoding UTF8) -Path $__cdHostPath
  $engineFns = @([regex]::Matches($engineText, '(?m)^function\s+([A-Za-z][\w-]*)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
  $lifters = @('build-walmart-deals.ps1', 'build-sams-deals.ps1', 'import-walmart-batch.ps1')
  foreach ($lf in $lifters) {
    $lp = Join-Path (Split-Path -Parent $__cdHostPath) $lf
    if (-not (Test-Path $lp)) { Write-Output ("FAIL  lift-closure: $lf is missing"); $script:fail++; continue }
    $lsrc = Get-Content $lp -Raw -Encoding UTF8
    # the list that is lifted FROM compare-deals: the foreach whose throw names this file
    # THE MECHANISM CHANGED ON 2026-09-09 (backlog I82) AND SO DID THIS CHECK, but the QUESTION is the
    # same one: can a builder call a pricing function whose callee is not present, and die at CALL
    # time? It used to lift function bodies by regex off a hand-maintained name list, so the check was
    # "does the list name every callee". The functions live in pricing-math-lib.ps1 now and the
    # builders dot-source it, so the equivalent - and strictly stronger - question is whether the
    # LIBRARY is closed under calling: a dot-source brings the whole file, so the only way to reach a
    # missing callee is for the library itself to call outward.
    if ($lsrc -match "(?ms)foreach\s*\(\s*\`$fn\s+in\s+@\([^)]*\).*?compare-deals\.ps1") {
      Write-Output ("FAIL  lift-closure: $lf still LIFTS from compare-deals.ps1 by regex - it should dot-source pricing-math-lib.ps1 (I82)")
      $script:fail++; continue
    }
    if ($lsrc -notmatch "pricing-math-lib\.ps1") {
      Write-Output ("FAIL  lift-closure: $lf neither lifts nor dot-sources the pricing math - it cannot price anything")
      $script:fail++; continue
    }
    Write-Output ("ok    lift-closure: $lf dot-sources pricing-math-lib.ps1 instead of cutting functions out of source")
  }

  # THE LIBRARY MUST BE CLOSED UNDER CALLING. This is the assertion that replaces the per-lifter list
  # check, and it is one check instead of three because the library is one file for all of them.
  $__pml = Join-Path (Split-Path -Parent $__cdHostPath) 'pricing-math-lib.ps1'
  if (-not (Test-Path $__pml)) { Write-Output 'FAIL  lift-closure: pricing-math-lib.ps1 is missing'; $script:fail++ }
  else {
    $libText = Get-Content $__pml -Raw -Encoding UTF8
    $libFns  = @([regex]::Matches($libText, '(?m)^function\s+([A-Za-z][\w-]*)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $outward = @()
    foreach ($fn in $libFns) {
      $bm = [regex]::Match($libText, "(?ms)^function\s+$([regex]::Escape($fn))\s*\(.*?^\}")
      if (-not $bm.Success) { continue }
      $body = _StripComments $bm.Value
      foreach ($cand in $engineFns) {
        if ($libFns -contains $cand) { continue }        # inside the library: fine
        if ($body -match ("(?<![\w-])" + [regex]::Escape($cand) + "(?![\w-])")) { $outward += ("$fn calls $cand") }
      }
    }
    $outward = @($outward | Sort-Object -Unique)
    if ($outward.Count -eq 0) {
      Write-Output ("ok    lift-closure: pricing-math-lib.ps1 is CLOSED - none of its $($libFns.Count) function(s) calls an engine function outside it")
    } else {
      Write-Output ("FAIL  lift-closure: pricing-math-lib.ps1 calls OUTWARD to a function a dot-sourcing builder will not have - " + ($outward -join '; ') + " (it will die at CALL time, not load time)")
      $script:fail++
    }
  }

  # ---- NATIVE UNIT PRICE: the store's own per-unit number, onto the row (queue 2026-09-04-def37c) ----
  # Driven in the SAME ORDER the engine runs it: parse at ingest (Get-DisplayedUnitPrice, which sees the
  # capture row), resolve at emit (Resolve-NativeUnitPrice, which sees the commodity's unit). A test that
  # exercised only one half could not reach the family gate, which is the half that decides whether a
  # number is emitted at all.
  Write-Output ('-'*54)
  function _Native($label, $row, $commodityUnit, $wantPrice, $wantUnit) {
    $p = Get-DisplayedUnitPrice $row
    $r = if ($p) { Resolve-NativeUnitPrice $p.Value $p.Unit $commodityUnit } else { $null }
    if ($null -eq $wantPrice) {
      if ($null -eq $r) { Write-Output ("ok    native: $label -> no native field (correct)") }
      else { Write-Output ("FAIL  native: $label should emit NOTHING, got " + $r.price + '/' + $r.unit); $script:fail++ }
      return
    }
    if ($null -eq $r) { Write-Output ("FAIL  native: $label got <null>, want $wantPrice/$wantUnit"); $script:fail++; return }
    if ([math]::Abs([double]$r.price - [double]$wantPrice) -le 0.0000005 -and [string]$r.unit -eq [string]$wantUnit) {
      Write-Output ("ok    native: $label = " + $r.price + '/' + $r.unit)
    } else { Write-Output ("FAIL  native: $label got " + $r.price + '/' + $r.unit + ", want $wantPrice/$wantUnit"); $script:fail++ }
  }
  # THE FOUNDING ROW, verbatim from out\sams\sams-deals-2026-07-29.json.
  _Native "Sam's oats '`$0.05/oz' on an oz commodity" ([pscustomobject]@{ sams_unit_price = '$0.05/oz' }) 'oz' 0.05 'oz'
  # Walmart writes cents with the CENT SIGN; built from the code point, never typed as a literal (a typed
  # non-ASCII needle has arrived mangled in this estate before).
  _Native "Walmart '12.4 <cent>/fl oz' on a floz commodity" ([pscustomobject]@{ wm_unit_price = ('12.4 ' + [char]0x00A2 + '/fl oz') }) 'floz' 0.124 'floz'
  _Native "Walmart '12.4 cents/fl oz' spelled out, on a floz commodity" ([pscustomobject]@{ wm_unit_price = '12.4 cents/fl oz' }) 'floz' 0.124 'floz'
  # MUST NOT EMIT: the store priced per EACH and the commodity is priced per OUNCE. Different question,
  # not a disagreement - this is the Hummus $0.35/ea shape, and emitting it would page a false mismatch.
  _Native "Sam's '`$0.35/ea' on an oz commodity" ([pscustomobject]@{ sams_unit_price = '$0.35/ea' }) 'oz' $null $null
  _Native "Walmart '`$0.80/oz' on an each commodity" ([pscustomobject]@{ wm_unit_price = '$0.80/oz' }) 'each' $null $null
  # fl oz is NOT oz. Tested explicitly because 'fl oz' contains 'oz' and an oz-first token test reads a
  # per-volume price as a per-weight one.
  _Native "'`$1.12/fl oz' on an OZ commodity is not comparable" ([pscustomobject]@{ wm_unit_price = '$1.12/fl oz' }) 'oz' $null $null
  _Native "Sam's short form '`$0.14/foz' on a floz commodity" ([pscustomobject]@{ sams_unit_price = '$0.14/foz' }) 'floz' 0.14 'floz'
  # lb against an oz commodity is the SAME measure, and converts exactly.
  _Native "'`$7.15/lb' on an oz commodity converts /16" ([pscustomobject]@{ wm_unit_price = '$7.15/lb' }) 'oz' 0.446875 'oz'
  _Native "'`$0.75/lb' on an lb commodity is taken as-is" ([pscustomobject]@{ sams_unit_price = '$0.75/lb' }) 'lb' 0.75 'lb'
  _Native "'`$1.73/count' on an each commodity" ([pscustomobject]@{ wm_unit_price = '$1.73/count' }) 'each' 1.73 'each'
  # A row with no unit-price field at all emits nothing - most stores (Aldi, Baker's, Fareway, FF, Hy-Vee).
  _Native 'a row with no unit-price field' ([pscustomobject]@{ item = 'Whatever' }) 'oz' $null $null
  # An unreadable unit is an ABSTENTION, never a guess that the units agree.
  _Native "an unrecognised unit '`$2.00/sq ft' on an oz commodity" ([pscustomobject]@{ unit_price = '$2.00/sq ft' }) 'oz' $null $null
  if ((ConvertTo-DisplayedUnitToken '37.3 c/fl oz') -eq 'floz') { Write-Output 'ok    native: fl oz is tokenised before oz' }
  else { Write-Output 'FAIL  native: fl oz tokenised as ' + (ConvertTo-DisplayedUnitToken '37.3 c/fl oz'); $script:fail++ }

  Write-Output ('-'*54)
  # THE FORMAT-LAYER COUNTER (2026-09-07, backlog E5). Single-quoted literals: built by concatenation
  # these would be three positional arguments and the case would run on a fragment.
  function _T($label, $cond, $got) { if ($cond) { Write-Output ("ok    " + $label) } else { Write-Output ("FAIL  " + $label + "  got: " + $got); $script:fail++ } }
  $script:NamelessRows = 0; $script:NamelessRowsByStore = @{}
  $null = Add-TcNamelessRow 'Aldi'
  $null = Add-TcNamelessRow 'Aldi'
  $n3 = Add-TcNamelessRow 'Hy-Vee'
  _T 'MUST FIRE  a nameless row is COUNTED instead of vanishing - the one silent drop in this engine' ($n3 -eq 3) ([string]$n3)
  _T 'MUST FIRE  the count is PER STORE, because three across seven stores is noise and three from one store is a capture shape that moved' `
    ((Format-TcNamelessByStore $script:NamelessRowsByStore) -eq 'Aldi=2,Hy-Vee=1') (Format-TcNamelessByStore $script:NamelessRowsByStore)
  $script:NamelessRowsByStore = @{}
  _T 'MUST NOT FIRE  no nameless rows reports an empty string, never a null that breaks the health block' `
    ((Format-TcNamelessByStore $script:NamelessRowsByStore) -eq '') ('[' + (Format-TcNamelessByStore $script:NamelessRowsByStore) + ']')
  _T 'MUST NOT FIRE  a null hashtable is empty, not a throw - the shape a lifted caller hands it' `
    ((Format-TcNamelessByStore $null) -eq '') 'threw or returned non-empty'
  $script:NamelessRows = $null; $script:NamelessRowsByStore = $null
  _T 'CLEAN TWIN an UNINITIALISED counter starts at 1, because a $script: variable does not travel with a lifted function' `
    ((Add-TcNamelessRow 'Walmart') -eq 1) 'a lifted call would have thrown or miscounted'
  _T 'CLEAN TWIN a row with no store is attributed rather than dropped from the breakdown' `
    ((Format-TcNamelessByStore $script:NamelessRowsByStore) -like '*Walmart=1*') (Format-TcNamelessByStore $script:NamelessRowsByStore)
  $script:NamelessRows = 0; $script:NamelessRowsByStore = @{}

  # ---- THE INGEST SEAM: what the supplement loop hands Add-Norm for a two-product flyer line ----------
  # (2026-09-11, queue 2026-09-10-582032.) Frozen from bakers-deals-2026-09-09, built the way the loader
  # builds it: split the item, then take each part's size the way the loader takes it. The assertion is the
  # exact NAME + SIZE + split_from triple that reaches Add-Norm, because that triple is what decides which
  # commodity the row routes to and what the engine divides by.
  if (-not (Get-Command Get-AdLineParts -ErrorAction SilentlyContinue)) { . (Join-Path $__cdHostDir 'pricing-math-lib.ps1') }
  $ingestCases = @(
    # MUST FIRE - the founding line. Before this, ONE row reached Add-Norm named for the cereal and sized by
    # the orange juice: $4.49 / 46 fl oz = $0.0976/oz, published as the cheapest cereal in Omaha.
    # want is 'name @@ size' per emitted row - FLAT strings on purpose: @(@('a','b')) collapses to @('a','b')
    # in PS 5.1, so a nested one-row fixture would silently compare the first CHARACTER of each field.
    @{ item='Simply Orange Juice, 46 fl oz or Post Large Size Cereal, 13.5-20.5 oz'; size='46 fl oz'
       want=@('Simply Orange Juice, 46 fl oz @@ 46 fl oz','Post Large Size Cereal, 13.5-20.5 oz @@ 13.5-20.5 oz') }
    # MUST FIRE - the line holding a Baker's cell today. Same price, same per-unit, the bacon's own name.
    @{ item='Farmland Bacon, 12-16 oz or Oscar Mayer Beef Franks, 15 oz'; size='12-16 oz'
       want=@('Farmland Bacon, 12-16 oz @@ 12-16 oz','Oscar Mayer Beef Franks, 15 oz @@ 15 oz') }
    # MUST FIRE - the transcriber sized the SECOND product, so a per-part size cannot just take the first
    @{ item='Nature Valley Bars, 5-12 ct or Pepperidge Farm Goldfish, 4.8-8 oz'; size='4.8-8 oz'
       want=@('Nature Valley Bars, 5-12 ct @@ 5-12 ct','Pepperidge Farm Goldfish, 4.8-8 oz @@ 4.8-8 oz') }
    # CLEAN TWIN - a single-product line still reaches Add-Norm as ONE row with the FILE's size and no
    # split_from, exactly as it did before any of this existed
    @{ item='Kroger Pasta Sauce, 24 oz'; size='24 oz'; want=@('Kroger Pasta Sauce, 24 oz @@ 24 oz') }
    # MUST FIRE (Brad, Q-adline-two-products, 2026-09-22: 'Split per product') - a size-less alternation names TWO
    # products at one size: one row each, both at the file's size. Until the ruling this line was kept whole.
    @{ item='Raspberries or Blackberries'; size='6 oz'; want=@('Raspberries @@ 6 oz','Blackberries @@ 6 oz') }
    # MUST FIRE - the three founding Hy-Vee lines of the ruling, frozen from coverage-gaps.json 2026-09-22
    @{ item='Old Orchard Organic 100% apple or grape juice, 64 fl. oz., 2/ $7.00'; size=''
       want=@('Old Orchard Organic 100% apple juice, 64 fl. oz., 2/ $7.00 @@ ','Old Orchard Organic 100% grape juice, 64 fl. oz., 2/ $7.00 @@ ') }
    @{ item='Alexia fries, tots or onion rings, 13.5 to 28 oz., $5.89'; size=''
       want=@('Alexia fries, 13.5 to 28 oz., $5.89 @@ ','Alexia tots, 13.5 to 28 oz., $5.89 @@ ','Alexia onion rings, 13.5 to 28 oz., $5.89 @@ ') }
    @{ item='Hy-Vee party cheese or cheese dip, .50 off with digital coupon, $2.99'; size=''
       want=@('Hy-Vee party cheese, .50 off with digital coupon, $2.99 @@ ','Hy-Vee cheese dip, .50 off with digital coupon, $2.99 @@ ') }
    # CLEAN TWIN - two SIZES of one product stay ONE row (batch 2 prices the smaller size)
    @{ item='Xtra laundry detergent, 56 or 67.5 oz.'; size='56 or 67.5 oz'; want=@('Xtra laundry detergent, 56 or 67.5 oz. @@ 56 or 67.5 oz') }
    # MUST NOT FIRE - a product list with a size inside it ('A size, B size') stays whole: the loose split that made
    # a wrong coffee crown out of 'ice coffee 50.7 oz.' is still refused
    @{ item='Hy-Vee ice coffee 50.7 oz. or cold brew, $4.99'; size=''; want=@('Hy-Vee ice coffee 50.7 oz. or cold brew, $4.99 @@ ') }
    # MUST NOT FIRE - two BRANDS with no lower-case product noun ('Pepsi or Mountain Dew') never become 'Pepsi Dew': a one-word
    # part is a fragment, so the line stays whole (measured on the Fareway soda cell, 2026-09-22)
    @{ item='Pepsi or Mountain Dew'; size='2 L'; want=@('Pepsi or Mountain Dew @@ 2 L') }
    # MUST FIRE - a second brand names its own product; a short first brand borrows the lower-case noun
    @{ item='Lean Cuisine or Stouffer''s entree, 8.5 to 12 oz., $2.77'; size=''; want=@('Lean Cuisine entree, 8.5 to 12 oz., $2.77 @@ ','Stouffer''s entree, 8.5 to 12 oz., $2.77 @@ ') }
    # MUST NOT FIRE - frozen from Aldi's weekly ad (2026-09-16 to 2026-09-22): a short L beside a title-case R whose last
    # word may be the shared noun. Split, it emitted 'VitaLife Turmeric' and a wellness shot took the ground-turmeric cell.
    @{ item='VitaLife Turmeric or Ginger Shot'; size='2 oz.'; want=@('VitaLife Turmeric or Ginger Shot @@ 2 oz.') }
    # MUST NOT FIRE - the same undecidable shape at Fareway (2026-09-21 ad): 'Rotella''s Vienna' lacks the 'Bread' it shares
    @{ item='Rotella''s Vienna or Honey Wheat Bread'; size=''; want=@('Rotella''s Vienna or Honey Wheat Bread @@ ') }
  )
  foreach ($ic in $ingestCases) {
    $parts = Get-AdLineParts ([string]$ic.item) ([string]$ic.size)
    $parts = @($parts)
    $sfx = if ($parts.Count -gt 1) { [string]$ic.item } else { '' }
    $emitted = @()
    foreach ($ap in $parts) {
      $psz = if ($parts.Count -gt 1) { [string]$ap.size } else { [string]$ic.size }
      $emitted += ([string]$ap.name + ' @@ ' + [string]$psz)
    }
    $ok = ($emitted.Count -eq @($ic.want).Count)
    if ($ok) { for ($i = 0; $i -lt $emitted.Count; $i++) { if ([string]$emitted[$i] -ne [string]$ic.want[$i]) { $ok = $false } } }
    # split_from is set when and only when the line was split - it is what tells Get-UnitPrice this row's
    # size is its own, and what keeps the refusal from firing on a part
    if ($ok -and (($parts.Count -gt 1) -ne [bool]$sfx)) { $ok = $false }
    if ($ok) { Write-Output ("  ok  ingest[" + $emitted.Count + "] " + $ic.item) }
    else {
      $script:fail++
      Write-Output ("  FAIL ingest " + $ic.item)
      Write-Output ("       want: " + (($ic.want | ForEach-Object { "'" + $_ + "'" }) -join ' | '))
      Write-Output ("       got : " + (($emitted | ForEach-Object { "'" + $_ + "'" }) -join ' | '))
    }
  }
  # MUST FIRE - the fail-closed complement. A two-size line the strict rule leaves WHOLE (Hy-Vee's shape)
  # must come back UNPRICED from the generic size division rather than priced by one of its two sizes.
  $hv = [pscustomobject]@{ name='Sparkling Ice Sparkling Water, 6 pk. bottles 17 fl. oz. or 10 pk. mini cans 7.5 fl. oz., $6.99'; price_text='$6.99'; size_text='17 fl oz'; regular=$null }
  $hvGot = Get-UnitPrice $hv ([pscustomobject]@{ unit='floz' })
  if ($null -ne $hvGot) { $script:fail++; Write-Output ("  FAIL refusal: a two-size line that cannot be split was priced at " + $hvGot.unit_price + " [" + $hvGot.basis + "] instead of being refused") }
  else { Write-Output '  ok  refusal: an unsplittable two-size line returns null rather than picking one of its sizes' }
  # CLEAN TWIN - the SAME shape once it carries split_from prices normally off its own size
  $hv2 = [pscustomobject]@{ name='Post Large Size Cereal, 13.5-20.5 oz'; price_text='$4.49'; size_text='13.5-20.5 oz'; regular=$null; split_from='Simply Orange Juice, 46 fl oz or Post Large Size Cereal, 13.5-20.5 oz' }
  $hv2Got = Get-UnitPrice $hv2 ([pscustomobject]@{ unit='oz' })
  if ($null -eq $hv2Got -or [math]::Abs([double]$hv2Got.unit_price - 0.3326) -gt 0.0005) {
    # 0.3326 = $4.49 / 13.5 oz since 2026-09-22 (plan-2026-09-22-5): an 'A-B oz' size reads its SMALLER size now; it was 0.219 at 20.5 oz
    $script:fail++; Write-Output ("  FAIL split part: want 0.3326/oz, got " + $(if ($null -eq $hv2Got) { 'null' } else { $hv2Got.unit_price }))
  } else { Write-Output '  ok  split part: the cereal half prices 4.49 / 20.5 oz = 0.219/oz and can never be 0.0976' }

  # ---- ADD-NORM TAKES NAMED PARAMETERS ONLY (2026-09-19, backlog I191) ------------------------------------
  # Add-Norm is defined below this block, so the REAL definition is taken from this file's own AST and run -
  # parsed and executed, never grepped - against a private row list.
  # Parsed as it READS, pieces in place (Expand-SelfTestPointers, loaded above): Add-Norm lives in compare-deals\.
  $anFile = [System.Management.Automation.Language.Parser]::ParseInput((Expand-SelfTestPointers -Text ([IO.File]::ReadAllText($__cdHostPath)) -Path $__cdHostPath), [ref]$null, [ref]$null)
  $anDef = $anFile.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Add-Norm' }, $true)
  $deals = New-Object System.Collections.Generic.List[object]
  $anRan = 0
  if (-not $anDef) { $script:fail++; Write-Output '  FAIL add-norm: no Add-Norm definition found in this file - nothing below could be asserted' }
  else {
    ${function:Add-Norm} = $anDef.Body.GetScriptBlock()
    # MUST FIRE - a positional call. The founding shape: 16 slots padded with '' and $null, where one slip
    # printed a plausible row with a field in the wrong column and nothing threw.
    $anRan++; $anErr = ''
    try { Add-Norm 'Aldi' 'Whole Milk' '$3.19' '1 gal' $null 'fixture' 'sale' '' '' '' '' 'P1' } catch { $anErr = $_.FullyQualifiedErrorId }
    if ($anErr -like 'PositionalParameterNotFound*' -and $deals.Count -eq 0) { Write-Output '  ok  MUST FIRE add-norm: a positional call throws and emits no row' }
    else { $script:fail++; Write-Output ("  FAIL MUST FIRE add-norm: a positional call was accepted (error='" + $anErr + "', rows=" + $deals.Count + ')') }
    # MUST FIRE - a misspelt name. On a simple function it would land in $args and the field would stay blank.
    $deals.Clear(); $anRan++; $anErr = ''
    try { Add-Norm -Store 'Aldi' -Name 'Whole Milk' -PriceText '$3.19' -ProdId 'P1' } catch { $anErr = $_.FullyQualifiedErrorId }
    if ($anErr -like 'NamedParameterNotFound*' -and $deals.Count -eq 0) { Write-Output '  ok  MUST FIRE add-norm: a misspelt parameter name throws and emits no row' }
    else { $script:fail++; Write-Output ("  FAIL MUST FIRE add-norm: a misspelt -ProdId was accepted (error='" + $anErr + "', rows=" + $deals.Count + ')') }
    # CLEAN TWIN - every one of the 16 fields, passed by name, lands in its own column. Distinct values, so a
    # swap of any two reads as a wrong value rather than an agreeing one.
    $deals.Clear(); $anRan++
    $anSrc = [pscustomobject]@{ item = 'fixture row' }
    Add-Norm -Store 'Aldi' -Name 'Whole Milk' -PriceText '$3.19' -SizeText '1 gal' -Regular '$3.49' -SourceAd 'fixture-ad' `
      -PriceType 'everyday' -SrcDate '2026-09-01' -AdFrom '2026-09-02' -AdTo '2099-09-03' -AdBasis 'ttl' -ProductId 'P1' `
      -Fulfillment 'in-store' -SrcFile 'aldi-regular-2026-09-01' -SrcRow $anSrc -SplitFrom 'whole line'
    $anWant = [ordered]@{ store = 'Aldi'; name = 'Whole Milk'; price_text = '$3.19'; size_text = '1 gal'; regular = '$3.49'; source_ad = 'fixture-ad'
      price_type = 'everyday'; src_date = '2026-09-01'; ad_from = '2026-09-02'; ad_to = '2099-09-03'; ad_basis = 'ttl'; product_id = 'P1'
      fulfillment = 'in-store'; src_file = 'aldi-regular-2026-09-01'; split_from = 'whole line' }
    $anBad = @()
    if ($deals.Count -ne 1) { $anBad += ('rows=' + $deals.Count) }
    else { foreach ($k in $anWant.Keys) { if (-not [string]::Equals([string]$deals[0].$k, [string]$anWant[$k], [StringComparison]::Ordinal)) { $anBad += ($k + "='" + $deals[0].$k + "'") } } }
    if (-not $anBad.Count) { Write-Output '  ok  CLEAN TWIN add-norm: a named call puts each of the 15 carried fields in its own column' }
    else { $script:fail++; Write-Output ('  FAIL CLEAN TWIN add-norm: wrong column(s): ' + ($anBad -join ', ')) }
  }
  # MUST FIRE / MUST NOT FIRE - no call site hands Add-Norm an AUTOMATIC variable. The founding slip was the
  # supplement loop's -ProductId $pid: $pid is this process's id, reading it never throws, and every Sam's and
  # Fareway ad row carried the build's PID as its store product id. Read from the AST, so the fixture text
  # below is a string to this file and never a call.
  $anAuto = @('pid', 'args', 'input', 'this', 'myinvocation', 'pscmdlet', 'psboundparameters', 'host', 'home')
  $anScan = {
    param($Ast)
    $hits = @()
    foreach ($c in $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-Norm' }, $true)) {
      foreach ($v in $c.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        if ($anAuto -contains ([string]$v.VariablePath.UserPath).ToLowerInvariant()) { $hits += ('line ' + $v.Extent.StartLineNumber + ' $' + $v.VariablePath.UserPath) }
      }
    }
    , $hits
  }
  $anRan++
  $anFix = [System.Management.Automation.Language.Parser]::ParseInput(('Add-Norm -Store $d.store -Name $pn' + ' -ProductId $' + 'pid -SrcRow $d'), [ref]$null, [ref]$null)
  $anHits = & $anScan $anFix
  if (@($anHits).Count -eq 1) { Write-Output '  ok  MUST FIRE add-norm: a call passing the automatic $pid is found' }
  else { $script:fail++; Write-Output ('  FAIL MUST FIRE add-norm: the automatic-variable scan found ' + @($anHits).Count + ' hit(s) in the $pid fixture, want 1') }
  $anRan++
  $anHits = & $anScan $anFile
  $anCalls = @($anFile.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-Norm' }, $true)).Count
  if (@($anHits).Count -eq 0 -and $anCalls -ge 9) { Write-Output ('  ok  MUST NOT FIRE add-norm: none of this file''s ' + $anCalls + ' Add-Norm calls passes an automatic variable') }
  else { $script:fail++; Write-Output ('  FAIL MUST NOT FIRE add-norm: calls=' + $anCalls + ' (want at least 9); automatic variables passed: ' + (@($anHits) -join '; ')) }
  if ($anRan -ne 5) { $script:fail++; Write-Output ("  FAIL add-norm: ran $anRan of 5 cases") }
  Remove-Item function:Add-Norm -ErrorAction SilentlyContinue

  if ($script:fail -eq 0) { Write-Output 'SELF-TEST PASS  (all multibuy / BOGO cases correct, plus the format-layer nameless-row counter)'; exit 0 }
  else { Write-Output ("SELF-TEST FAIL: $script:fail case(s)"); exit 1 }
