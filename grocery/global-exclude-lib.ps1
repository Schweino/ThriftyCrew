# global-exclude-lib.ps1 - the prepared/processed term list, as a PROVIDED interface.
# ---------------------------------------------------------------------------------------------------
# WHY (2026-09-09, backlog I82). This list used to live inside compare-deals.ps1, and SEVEN other files
# reached in and took it by running a regex over the engine's SOURCE TEXT and Invoke-Expression'ing the
# array literal - `audit-coverage-gaps`, `audit-household-in-food`, `audit-match-contested`,
# `audit-match-soundness`, `dead-commodity-lib`, `validate-fills` and `triage-coverage-gaps`. The
# engine even lifted it from its OWN $PSCommandPath, because its self-test block runs before the
# definition.
#
# IT IS A FUNCTION, NOT A VARIABLE, AND THAT IS LOAD-BEARING. This estate has already paid for the
# difference: a top-level $script: constant does not travel to a caller the way a function does, and
# compare-deals.ps1 carries a comment about exactly that for its whole-purchase token lists - the first
# cut of that change used variables and turned two builder suites red on rows that priced null. A
# function is a CALL, so it works identically whether the caller dot-sources this file or lifts it.
#
# NO SIDE EFFECTS ON LOAD. Adding work here re-creates the obstacle that produced the lifting.
#
# Prepared/processed/different-form terms: none of our raw staples are these, so a deal whose name
# contains one is NOT the plain commodity and is dropped. This protects accuracy on a live paid board.
# ---------------------------------------------------------------------------------------------------

function Get-TcGlobalExclude {
  @(
    'drink\s*mix','kool[\s-]?aid','probiotic','kombucha','\bdip\b','\bsauce\b','wrapped',
    '\bbake\b','\bbaked\b','seasoned','marinated','stuffed','\bkit\b','flavored','\bsoup\b',
    'helper','lunchable','smoothie','\bpudding\b','ice\s*cream','\bcreamer\b','\bfrozen\b',
    '\bcanned\b','breaded','\bsnack\b','\bmeal\b','casserole','\bwrap\b','poppers',
    'muffin','pretzel','filled','strudel','\bcake\b','drinkable','(?<!orange\s)\bjuice\b',
    '\bsoda\b','sparkling','seltzer','\bwater\b','energy\s*drink','sports\s*drink','tonic','lemonade','faygo','cocktail',
    'pop[\s-]?tart','pastr','toaster','\btart\b','cereal','granola\s*bar','fruit\s*snack',
    '\bmalt\b','spiked','\bbeer\b','\bale\b','\bgum\b','\bwine\b','liquor','vodka','whiskey','tequila','bourbon','hard\s+seltzer','\bmix\b(?!\s*(?:&|and)\s*match)',
    # 'snax' (2026-07-30): GO2snax/PRO2snax are meat+cheese+candy snack TRAYS whose names contain a real
    # commodity phrase ('Mild Cheddar Cheese', 'Red Grapes'), and the existing '\bsnack\b' token cannot match
    # 'snax'. The GO2snax tray sat band-hidden at $0.7721/oz; the weight-first pack fix re-prices it at
    # $0.1287/oz by dividing its $1.66 "each" (per-tray, Sam's unit-price feed) price across all 6 trays -
    # a wrong basis on top of the wrong product - which would make a salami/caramel tray the published
    # CHEAPEST shredded cheese. No staple ever contains 'snax' ('\bsnax\b' cannot match inside GO2snax -
    # '2' is a word char - so the token is deliberately unanchored).
    # CORRECTION (post-batch review 2026-07-30): THREE snax products exist live, not the "exactly 2" the
    # batch measured - 'Outlaw Snax Crazy Queso Flavored Tortilla Snack Chips' also sits in the Walmart
    # regular files. It changes nothing here (its name never matched any include; pinned <unmatched> in the
    # baseline), and a Snax-brand product that ever legitimately belongs to a snack commodity has the
    # relax_global escape hatch, which waives exact global tokens per commodity.
    # NOTE: 'GO2snax...' -> shredded-cheese is pinned in out\audit\match-baseline.json, so the FIRST
    # audit-match-soundness.ps1 run after this change reports it DROPPED and exits 2 (publish holds). That
    # is the audit working as designed: review the snax drops, then bless via audit-match-soundness.ps1 -Accept.
    'snax',
    # pet + baby food: no human staple is ever "dog food"/"cat litter"/"Beech Nut" - keep them out of every human
    # commodity (chicken/bacon/rice/sweet-corn were stealing dog food & baby food). The pet/baby commodities
    # relax_global exactly the token they need, so they still match their own products.
      # 'happy\s*tot' added 2026-07-28: the Stage-token exclusions stop at "Stage 1-3", so "Happy Tot Stage 4
    # Organic Pears Blueberries & Spinach Pouch" evaded every baby-food rule and kept surfacing as fresh
    # spinach (and as a contested match on other produce). The brand is baby/toddler food only, so name it.
    # 'serenity\s*kids' added 2026-08-01 (triage 2026-08-01-08b14e): the SAME evasion, one brand later.
    # "Serenity Kids Free Range Chicken & Thyme with Organic Parsnip & Beet Pouch" carries no Stage token and
    # no 'baby food' phrase, so it reached canned-beets - and estate-wide it is 10 names on produce commodities.
    # The brand is baby/toddler food only. baby-food declares this token in relax_global so its OWN 9 pouches
    # keep routing to baby-food: the first simulation without that relax EVICTED all nine, which is the
    # opposite of the fix. Never add a brand here without checking who legitimately sells under it.
    # 'cerebelly','little\s+journey','once\s+upon\s+a\s+farm','plum\s+organics' added 2026-08-06: the THIRD
    # instance of this same evasion, and the one that showed the shape of the hole. "Cerebelly 6+ Months Organic
    # Spinach Apple Sweet Potato Puree 4 Oz" matches the include of THREE produce commodities (apples, spinach,
    # sweet-potatoes) and is excluded by none, so first-match-wins handed a 4 oz baby-food jar to whichever is
    # ordered first - pricing fresh produce at a baby-food per-ounce rate. It reached none of baby-food's own
    # rules: brand not listed, age marker "6+ Months" is not "Stage 1/2", form "Puree" is not "pouches".
    # WHY THIS LIST AND NOT baby-food's include: baby-food sits at index 297 and apples at 20, so Match-Category
    # returns apples long before baby-food is ever considered. Widening baby-food's include CANNOT fix an
    # earlier commodity's theft - only a global (or per-commodity) EXCLUDE can. That is why every fix in this
    # class lands here.
    # Measured over all 28,526 estate product names before shipping: 17 routing changes, no product left a
    # commodity it legitimately belonged to. 8 were the defect itself (3 apples, 3 yogurt, 2 bananas), 8 were
    # Happy Tot / Serenity Kids pouches that were globally excluded but orphaned (<unmatched> -> baby-food),
    # and 1 was a 0.35 oz Plum Organics toddler fruit snack leaving fruit-snacks.
    # Little Journey is Aldi's baby line and also sells wipes, diapers and formula, so baby-wipes, diapers and
    # baby-formula each relax_global this token - without that they lose their own products, the same eviction
    # the serenity\s*kids note warns about.
  'dog\s+food','dog\s+treats?','dog\s+biscuits?','cat\s+food','cat\s+litter','beech[\s-]?nut','gerber','happy\s*baby','happy\s*tot','baby\s+food','serenity\s*kids','cerebelly','little\s+journey','once\s+upon\s+a\s+farm','plum\s+organics',
    # 'naan' added 2026-08-15 (board-collision fix, hunt-2026-08-15-shakedown mapping): "Marketside Tandoori
    # Style Garlic Naan Bites" held the WALMART CHEAPEST garlic cell at $0.268/each - naan bread priced as
    # fresh garlic bulbs. No commodity owns naan (zero includes match it; measured over all 31,097 estate
    # names: 13 naan products, 11 already <unmatched>), so no relax_global is needed anywhere. The other
    # mapped one, "Stonefire Original Mini Naan Bread ... for Dipping & Pizza" -> frozen-pizza, is ALSO a
    # wrong match (shelf-stable flatbread, not frozen pizza) and dropping it is intended.
    '\bnaan\b',
    # 'apple sauce' added 2026-08-30 (mangoes Walmart cell): "(6 Pack) Mott's Mango Peach Applesauce Cups,
    # 4 oz" took the WALMART CHEAPEST mangoes cell at $0.4467/each - applesauce cups priced as fresh mangoes,
    # beating the real $0.75 Fresh Red Mango. It arrived with walmart-regular-2026-08-30.json; no rule changed.
    # WHY THE EXISTING '\bsauce\b' GLOBAL DID NOT CATCH IT: "applesauce" is one word, so there is no word
    # boundary before "sauce" and the token cannot match. Only the SPACED spelling "Apple Sauce" was ever
    # globally excluded - which is why the same product name reads as excluded at Tree Top ("Apple Sauce
    # Variety Pack") and as fresh fruit at Mott's ("Mango Peach Applesauce"). One product, two spellings,
    # opposite outcomes.
    # WHY GLOBAL AND NOT A mangoes EXCLUDE: mangoes is not the only thief. -Explain applesauce over the
    # 2026-08-30 inputs shows FOUR commodities holding applesauce rows by array order alone - bananas (17),
    # watermelon (27), peaches (28), mangoes (113) - because applesauce sits at 225 and first-match-wins
    # hands the row to whichever flavour word is listed earlier. Excluding it on mangoes fixes one cell and
    # leaves three, and the next flavour Mott's ships (strawberry, caramel apple, pumpkin spice, honeycrisp
    # are all already in the estate) re-opens it somewhere else. Same shape as the baby-food class above:
    # widening applesauce's include CANNOT fix an earlier commodity's theft - only a global exclude can.
    # THE \b IS LOAD-BEARING: unanchored, 'apple\s*sauce' also matches inside "PineAPPLE SAUCE" (Golden Farms
    # Organic Pineapple Sauce is live at Sam's). That row is already blocked by '\bsauce\b' and must stay
    # the sauce commodities' problem, not applesauce's.
    # applesauce declares this exact token in relax_global so its own 353 rows keep routing to it - without
    # that this token would empty the commodity, the same eviction the serenity\s*kids note warns about.
    '\bapple\s*sauce',
    # 'sprout(?:ing)?\s+seeds?' added 2026-09-02 (triage plan-2026-09-02-2 item 2026-09-02-4dfb1d): GARDEN
    # SEED PACKETS ARE THE PRODUCE TWIN OF THE FLAVOUR-PHRASE CLASS - a seed packet's name IS the vegetable's
    # name, so "Sprouting Seed Super Sampler- Organic- 2.5 Lbs of 10 Different Delicious Sprout Seeds:
    # Alfalfa, Mung Bean, Broccoli, Green Lentil, Clover, Buckwheat, Radish, Bean Salad & More" ($67.97,
    # Walmart) matches broccoli, radishes AND dry-green-lentils. It never held a cell, but a $67.97 2.5 lb
    # bag of seed is one price move from crowning nothing and one rule change from crowning something.
    # WHY GLOBAL AND NOT PER-COMMODITY: the same shape as the baby-food and applesauce notes above. Fencing
    # it on broccoli alone re-lands it on dry-green-lentils (measured: that is exactly what the routing
    # simulation showed once broccoli released it), and the packet names 10 more vegetables after that.
    # Only a global token stops the hand-off. The per-commodity radishes fence stays as well: it catches
    # 'Radish Vegetable Seeds 5 Pack', which carries no 'sprout' token at all.
    # MEASURED over the 41,072-name corpus of plan-2026-09-02-2.routing.json: exactly ONE name matches.
    # THE SHAPE IS LOAD-BEARING: 'sprout' must be immediately followed by whitespace and 'seed(s)', so this
    # cannot touch "Go Raw Organic SPROUTED Pumpkin Seeds with Sea Salt" (sprouted, not sprouting - that row
    # is sea-salt's own '\bseeds?\b' fence) nor "Fresh Bean Sprouts", which is a real produce row.
    # No commodity needs relax_global: nothing on the board sells seed for planting.
    'sprout(?:ing)?\s+seeds?'
  )
}
