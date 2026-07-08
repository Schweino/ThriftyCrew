<#
  apply-full-audit.ps1 - Applies the full 113-recipe source-verification sweep.
  Dry-run by default; pass -Apply to write. Encodes an explicit decision for every one of the
  118 distinct missing-ingredient names the 12 audit agents reported (map to an existing priced
  commodity / mint a new Family-Fare-priced commodity / add now + price later via store backfill /
  skip as an intentional recipe adaptation). Additive only: never removes an existing ingredient,
  never adds a duplicate. Recomputes cost_batch(_true)/cost_per_serving(_true) by the added grams.
#>
param([switch]$Apply)
$ErrorActionPreference = 'Stop'
$mp = 'C:\Codex\income\meal-prep'
$g  = 'C:\Codex\income\grocery'
$SP = 'C:\Users\Owner\AppData\Local\Temp\claude\C--Codex\f3644374-5e4d-4c5e-a7e6-7ac3b89873f9\scratchpad'

# ---- DECISION TABLE ----------------------------------------------------------------
# action: map=existing priced board id ; mint=new FF-priced commodity ; unpriced=add now, price via backfill ; skip
$DEF = @(
  # ---- map to already-priced commodities (recipe board or staples board) ----
  @{names=@('salt');display='Salt';board='salt';gpu=28.3495;unit='oz';action='map'},
  @{names=@('black pepper');display='Black Pepper';board='black-pepper';gpu=28.3495;unit='oz';action='map'},
  @{names=@('garlic');display='Garlic';board='garlic';gpu=50;unit='each';action='map'},
  @{names=@('olive oil');display='Olive Oil';board='olive-oil';gpu=28;unit='floz';action='map'},
  @{names=@('ground cumin','cumin');display='Ground Cumin';board='ground-cumin';gpu=28.3495;unit='oz';action='map'},
  @{names=@('garlic powder');display='Garlic Powder';board='garlic-powder';gpu=28.3495;unit='oz';action='map'},
  @{names=@('chicken broth');display='Chicken Broth';board='chicken-broth';gpu=29.57;unit='floz';action='map'},
  @{names=@('dried oregano','oregano');display='Dried Oregano';board='dried-oregano';gpu=28.3495;unit='oz';action='map'},
  @{names=@('yellow onion','onion');display='Yellow Onion';board='onions';gpu=453.592;unit='lb';action='map'},
  @{names=@('paprika');display='Paprika';board='paprika';gpu=28.3495;unit='oz';action='map'},
  @{names=@('chili powder','kashmiri red chili powder');display='Chili Powder';board='chili-powder';gpu=28.3495;unit='oz';action='map'},
  @{names=@('ginger');display='Ginger';board='ginger';gpu=453.592;unit='lb';action='map'},
  @{names=@('cornstarch');display='Cornstarch';board='cornstarch';gpu=28.3495;unit='oz';action='map'},
  @{names=@('butter');display='Butter';board='butter';gpu=453.592;unit='lb';action='map'},
  @{names=@('onion powder');display='Onion Powder';board='onion-powder';gpu=28.3495;unit='oz';action='map'},
  @{names=@('rice vinegar','rice wine vinegar');display='Rice Vinegar';board='rice-vinegar';gpu=29.57;unit='floz';action='map'},
  @{names=@('sesame oil');display='Sesame Oil';board='sesame-oil';gpu=28.3495;unit='oz';action='map'},
  @{names=@('tomato paste');display='Tomato Paste';board='tomato-paste';gpu=28.3495;unit='oz';action='map'},
  @{names=@('garam masala');display='Garam Masala';board='garam-masala';gpu=28.3495;unit='oz';action='map'},
  @{names=@('brown sugar');display='Brown Sugar';board='brown-sugar';gpu=28.3495;unit='oz';action='map'},
  @{names=@('italian seasoning');display='Italian Seasoning';board='italian-seasoning';gpu=28.3495;unit='oz';action='map'},
  @{names=@('bay leaves','bay leaf');display='Bay Leaves';board='bay-leaves';gpu=28.3495;unit='oz';action='map'},
  @{names=@('soy sauce');display='Soy Sauce';board='soy-sauce';gpu=28.3495;unit='oz';action='map'},
  @{names=@('jalapeno','jalapeno peppers','thai red chili');display='Jalapeno';board='jalapeno';gpu=453.592;unit='lb';action='map'},
  @{names=@('ketchup');display='Ketchup';board='ketchup';gpu=28.3495;unit='oz';action='map'},
  @{names=@('beef broth');display='Beef Broth';board='beef-broth';gpu=29.57;unit='floz';action='map'},
  @{names=@('balsamic vinegar');display='Balsamic Vinegar';board='balsamic-vinegar';gpu=28.3495;unit='oz';action='map'},
  @{names=@('lime juice');display='Lime Juice';board='limes';gpu=30;unit='each';action='map'},
  @{names=@('diced green chiles');display='Diced Green Chiles';board='diced-green-chiles';gpu=28.3495;unit='oz';action='map'},
  @{names=@('hoisin sauce');display='Hoisin Sauce';board='hoisin-sauce';gpu=28.3495;unit='oz';action='map'},
  @{names=@('enchilada sauce');display='Enchilada Sauce';board='enchilada-sauce';gpu=28.3495;unit='oz';action='map'},
  @{names=@('white vinegar');display='White Vinegar';board='white-vinegar';gpu=28.3495;unit='oz';action='map'},
  @{names=@('curry powder');display='Curry Powder';board='curry-powder';gpu=28.3495;unit='oz';action='map'},
  @{names=@('taco seasoning');display='Taco Seasoning';board='taco-seasoning';gpu=28.3495;unit='oz';action='map'},
  @{names=@('roasted red peppers');display='Roasted Red Peppers';board='roasted-red-peppers';gpu=28.3495;unit='oz';action='map'},
  @{names=@('salsa');display='Salsa';board='salsa';gpu=28.3495;unit='oz';action='map'},
  @{names=@('red bell pepper');display='Red Bell Pepper';board='red-bell-pepper';gpu=120;unit='each';action='map'},
  @{names=@('fresh cilantro','cilantro');display='Fresh Cilantro';board='fresh-cilantro';gpu=57;unit='each';action='map'},
  @{names=@('corn tortillas');display='Corn Tortillas';board='corn-tortillas';gpu=30;unit='each';action='map'},
  # ---- map to staples-board commodities (fully multi-store already) ----
  @{names=@('egg','eggs');display='Eggs';board='eggs';gpu=600;unit='dozen';action='map'},
  @{names=@('turkey bacon');display='Turkey Bacon';board='bacon';gpu=453.592;unit='lb';action='map'},
  @{names=@('green olives');display='Green Olives';board='olives';gpu=28.3495;unit='oz';action='map'},
  @{names=@('plain yogurt');display='Plain Yogurt';board='greek-yogurt';gpu=28.3495;unit='oz';action='map'},
  @{names=@('mustard');display='Dijon Mustard';board='dijon-mustard';gpu=28.3495;unit='oz';action='map'},
  @{names=@('bell pepper');display='Green Bell Pepper';board='green-bell-pepper';gpu=120;unit='each';action='map'},
  @{names=@('carrot');display='Carrots';board='shredded-carrots';gpu=28.3495;unit='oz';action='map'},
  @{names=@('spinach');display='Spinach';board='frozen-chopped-spinach';gpu=28.3495;unit='oz';action='map'},
  @{names=@('shallots');display='Shallots';board='onions';gpu=453.592;unit='lb';action='map'},
  @{names=@('orange zest');display='Orange Zest';board='orange-juice';gpu=31;unit='floz';action='map'},
  @{names=@('green chile sauce');display='Green Chile Sauce';board='salsa-verde';gpu=28.3495;unit='oz';action='map'},
  # ---- MINT new Family-Fare-priced commodities ----
  @{names=@('red pepper flakes','crushed red pepper flakes','crushed red pepper','dried chili flakes');display='Red Pepper Flakes';board='red-pepper-flakes';gpu=28.3495;unit='oz';action='mint';price=1.9933;size='1.5 oz';product='Our Family Red Pepper, Crushed 1.5 Oz';url='https://www.shopfamilyfare.com/shop/pantry/mixes_spices_seasoning/spices/our_family_red_pepper_crushed_1_5_oz/p/7081493';cat='Spices & Baking'},
  @{names=@('ground ginger');display='Ground Ginger';board='ground-ginger';gpu=28.3495;unit='oz';action='mint';price=2.8063;size='1.6 oz';product='Full Circle Market Ground Ginger 1.6 Oz';url='https://www.shopfamilyfare.com/shop/pantry/mixes_spices_seasoning/spices/full_circle_market_ground_ginger_1_6_oz/p/599157';cat='Spices & Baking'},
  @{names=@('dried thyme','thyme','ground thyme');display='Dried Thyme';board='dried-thyme';gpu=28.3495;unit='oz';action='mint';price=3.3333;size='1.5 oz';product='Spice Supreme Thyme Leaves 1.5 Oz';url='https://www.shopfamilyfare.com/shop/seasonal_special_occasion/trial_sizes_store/spice_supreme_thyme_leaves/p/2400931';cat='Spices & Baking'},
  @{names=@('smoked paprika');display='Smoked Paprika';board='smoked-paprika';gpu=28.3495;unit='oz';action='mint';price=0.9986;size='7 oz';product="Sugar 'N Spice Smoked Paprika 7 Oz";url='https://www.shopfamilyfare.com/shop/fresh_fruits_vegetables/fresh_spices_herbs/sugar_n_spice_smoked_paprika/p/1564405684715649387';cat='Spices & Baking'},
  @{names=@('ground coriander','coriander');display='Ground Coriander';board='ground-coriander';gpu=28.3495;unit='oz';action='mint';price=3.2071;size='1.4 oz';product='Full Circle Market Ground Coriander 1.4 Oz';url='https://www.shopfamilyfare.com/shop/pantry/mixes_spices_seasoning/herbs/full_circle_market_ground_coriander_1_4_oz/p/570375';cat='Spices & Baking'},
  @{names=@('cayenne pepper');display='Cayenne Pepper';board='cayenne-pepper';gpu=28.3495;unit='oz';action='mint';price=1.8663;size='1.87 oz';product="Lawry's Ground Cayenne Pepper 1.87 Oz";url='https://www.shopfamilyfare.com/shop/pantry/mixes_spices_seasoning/spices/lawry_s_ground_cayenne_pepper_1_87_oz/p/1564405684713605868';cat='Spices & Baking'},
  @{names=@('cinnamon','ground cinnamon');display='Ground Cinnamon';board='ground-cinnamon';gpu=28.3495;unit='oz';action='mint';price=0.676;size='2.5 oz';product="That's Smart! Ground Cinnamon 2.5 Oz";url='https://www.shopfamilyfare.com/shop/pantry/mixes_spices_seasoning/spices/that_s_smart_ground_cinnamon/p/1564405684704741127';cat='Spices & Baking'},
  @{names=@('dried basil');display='Dried Basil';board='dried-basil';gpu=28.3495;unit='oz';action='mint';price=4.8226;size='0.62 oz';product='Our Family Basil Leaves 0.62 Oz';url='https://www.shopfamilyfare.com/shop/pantry/mixes_spices_seasoning/herbs/our_family_basil_leaves_0_62_oz/p/1564405684702629729';cat='Spices & Baking'},
  @{names=@('dried dill','fresh dill');display='Dried Dill';board='dried-dill';gpu=28.3495;unit='oz';action='mint';price=4.4464;size='0.56 oz';product='Our Family Dill Weed 0.56 Oz';url='https://www.shopfamilyfare.com/shop/pantry/mixes_spices_seasoning/herbs/our_family_dill_weed_0_56_oz/p/1564405684702629730';cat='Spices & Baking'},
  @{names=@('ground nutmeg');display='Ground Nutmeg';board='ground-nutmeg';gpu=28.3495;unit='oz';action='mint';price=3.0613;size='2.12 oz';product='Our Family Nutmeg, Ground 2.12 Oz';url='https://www.shopfamilyfare.com/shop/pantry/mixes_spices_seasoning/spices/our_family_nutmeg_ground_2_12_oz/p/7194337';cat='Spices & Baking'},
  @{names=@('turmeric','ground turmeric');display='Ground Turmeric';board='ground-turmeric';gpu=28.3495;unit='oz';action='mint';price=1.345;size='2 oz';product="Sugar 'N Spice Turmeric Ground 2 Oz";url='https://www.shopfamilyfare.com/shop/fresh_fruits_vegetables/fresh_spices_herbs/sugar_n_spice_turmeric_ground_pp/p/1564405684701720785';cat='Spices & Baking'},
  @{names=@('ground allspice');display='Ground Allspice';board='ground-allspice';gpu=28.3495;unit='oz';action='mint';price=3.3167;size='0.6 oz';product="Tone's Allspice, Ground 0.6 Oz";url='https://www.shopfamilyfare.com/shop/pantry/mixes_spices_seasoning/spices/tone_s_allspice_ground_0_6_oz/p/235148';cat='Spices & Baking'},
  @{names=@('rosemary');display='Dried Rosemary';board='dried-rosemary';gpu=28.3495;unit='oz';action='mint';price=9.3387;size='0.62 oz';product='Mc Cormick Whole Rosemary Leaves 0.62 Oz';url='https://www.shopfamilyfare.com/shop/pantry/mixes_spices_seasoning/herbs/mc_cormick_whole_rosemary_leaves_0_62_oz/p/1564405684703136649';cat='Spices & Baking'},
  @{names=@('dried parsley');display='Dried Parsley';board='dried-parsley';gpu=28.3495;unit='oz';action='mint';price=5.58;size='0.5 oz';product='Mc Cormick Parsley Flakes 0.5 Oz';url='https://www.shopfamilyfare.com/shop/pantry/mixes_spices_seasoning/herbs/mc_cormick_parsley_flakes_0_5_oz/p/34845';cat='Spices & Baking'},
  @{names=@('celery salt');display='Celery Salt';board='celery-salt';gpu=28.3495;unit='oz';action='mint';price=0.4158;size='12 oz';product="Dan's Pantry Celery Salt 12 Oz";url='https://www.shopfamilyfare.com/shop/fresh_fruits_vegetables/fresh_spices_herbs/dan_s_pantry_celery_salt/p/5782384';cat='Spices & Baking'},
  @{names=@('au jus gravy mix');display='Au Jus Gravy Mix';board='au-jus-gravy-mix';gpu=28.3495;unit='oz';action='mint';price=1.09;size='1 oz';product='Our Family Au Jus Gravy Mix 1 Oz';url='https://www.shopfamilyfare.com/shop/pantry/mixes_spices_seasoning/mixes_for_sauces_gravies/our_family_au_jus_gravy_mix_1_oz/p/1564405684715672213';cat='Sauces & Condiments'},
  @{names=@('worcestershire sauce');display='Worcestershire Sauce';board='worcestershire-sauce';gpu=29.57;unit='floz';action='mint';price=0.169;size='10 fl oz';product='Our Family Worcestershire Sauce 10 Fl Oz';url='https://www.shopfamilyfare.com/shop/pantry/condiments_dressing/other_sauce/our_family_worcestershire_sauce_10_fl_oz/p/7081427';cat='Sauces & Condiments'},
  @{names=@('apple cider vinegar');display='Apple Cider Vinegar';board='apple-cider-vinegar';gpu=29.57;unit='floz';action='mint';price=0.1119;size='16 fl oz';product='Apple Cider Vinegar Our Family 16 Fl Oz';url='https://www.shopfamilyfare.com/shop/pantry/mixes_spices_seasoning/cooking_wines_vinegars/apple_cider_vinegar_our_family/p/7081446';cat='Sauces & Condiments'},
  @{names=@('white wine vinegar');display='White Wine Vinegar';board='white-wine-vinegar';gpu=29.57;unit='floz';action='mint';price=0.2825;size='12 fl oz';product='Holland House White Wine Vinegar 12 Fl Oz';url='https://www.shopfamilyfare.com/shop/pantry/mixes_spices_seasoning/cooking_wines_vinegars/holland_house_white_wine_vinegar_12_fl_oz/p/40495';cat='Sauces & Condiments'},
  @{names=@('fish sauce');display='Fish Sauce';board='fish-sauce';gpu=29.57;unit='floz';action='mint';price=0.9601;size='6.76 fl oz';product='Thai Gluten Free Premium Fish Sauce 6.76 Fl Oz';url='https://www.shopfamilyfare.com/shop/pantry/condiments_dressing/asian_sauce/thai_gluten_free_premium_fish_sauce_6_76_fl_oz/p/6826';cat='Sauces & Condiments'},
  @{names=@('sweet chili sauce');display='Sweet Chili Sauce';board='sweet-chili-sauce';gpu=29.57;unit='floz';action='mint';price=0.3193;size='15 oz';product='La Choy Sauce, Sweet Chili 15 Oz';url='https://www.shopfamilyfare.com/shop/pantry/condiments_dressing/asian_sauce/la_choy_sauce_sweet_chili_15_oz/p/1564405684704769747';cat='Sauces & Condiments'},
  @{names=@('sriracha');display='Sriracha';board='sriracha';gpu=29.57;unit='floz';action='mint';price=0.3524;size='17 oz';product='Tuong Ot Sriracha Hot Chili Sauce 17 Oz';url='https://www.shopfamilyfare.com/shop/pantry/condiments_dressing/hot_sauce/tuong_ot_sriracha_hot_chili_sauce_17_oz/p/19740';cat='Sauces & Condiments'},
  @{names=@('oil','cooking oil','vegetable oil');display='Vegetable Oil';board='vegetable-oil';gpu=28;unit='floz';action='mint';price=0.1248;size='40 oz';product='Our Family Vegetable Oil 100% Pure 40 Oz';url='https://www.shopfamilyfare.com/shop/pantry/baking/oils_sprays/our_family_vegetable_oil_100_pure/p/1564405684714575888';cat='Oils'},
  @{names=@('apple cider');display='Apple Cider';board='apple-cider';gpu=29.57;unit='floz';action='mint';price=0.067;size='64 fl oz';product='Our Family Apple Cider Juice 64 Fl Oz';url='https://www.shopfamilyfare.com/shop/beverages/fruit_vegetable_beverages/apple_cider/our_family_apple_cider_juice_64_fl_oz/p/8092393';cat='Beverages'},
  @{names=@('pineapple juice');display='Pineapple Juice';board='pineapple-juice';gpu=29.57;unit='floz';action='mint';price=0.1302;size='46 oz';product='Dole 100% Juice, Pineapple 46 Fl Oz';url='https://www.shopfamilyfare.com/shop/beverages/fruit_vegetable_beverages/other_juice/dole_100_juice_pineapple_46_fl_oz/p/26657';cat='Beverages'},
  @{names=@('half and half');display='Half and Half';board='half-and-half';gpu=29.57;unit='floz';action='mint';price=0.1369;size='16 fl oz';product='Our Family Half And Half 16 Fl Oz';url='https://www.shopfamilyfare.com/shop/dairy/cream_half_half/our_family_half_and_half_16_fl_oz/p/7081137';cat='Dairy & Cheese'},
  @{names=@('lemon juice');display='Lemon Juice';board='lemon-juice';gpu=29.57;unit='floz';action='mint';price=0.1247;size='32 fl oz';product='Our Family Lemon 100% Juice 32 Fl Oz';url='https://www.shopfamilyfare.com/shop/beverages/fruit_vegetable_beverages/lemon_lime/our_family_lemon_100_juice_32_fl_oz/p/6786892';cat='Beverages'},
  @{names=@('condensed french onion soup');display='Condensed French Onion Soup';board='condensed-french-onion-soup';gpu=298;unit='each';action='mint';price=1.99;size='10.5 oz';product="Campbell's French Onion Soup 10.5 Oz";url='https://www.shopfamilyfare.com/shop/pantry/broth_soups_stews_chili/condensed_soups/campbell_s_french_onion_soup_10_500_oz/p/33857';cat='Canned & Jarred'},
  @{names=@('celery');display='Celery';board='celery';gpu=450;unit='each';action='mint';price=2.49;size='1 ea';product='Fresh Celery';url='https://www.shopfamilyfare.com/shop/fresh_fruits_vegetables/celery/fresh_celery/p/2311267';cat='Produce'},
  @{names=@('green onions');display='Green Onions';board='green-onions';gpu=100;unit='each';action='mint';price=1.29;size='1 ct';product='Fresh Green Onions/Scallions';url='https://www.shopfamilyfare.com/shop/fresh_fruits_vegetables/onions/fresh_green_onions_scallions/p/111459';cat='Produce'},
  @{names=@('cucumber');display='Cucumber';board='cucumber';gpu=300;unit='each';action='mint';price=0.89;size='1 ea';product='Fresh Cucumbers';url='https://www.shopfamilyfare.com/shop/fresh_fruits_vegetables/other_vegetables/fresh_cucumbers/p/12432';cat='Produce'},
  @{names=@('cheddar cheese');display='Cheddar Cheese';board='cheddar-cheese';gpu=28.3495;unit='oz';action='mint';price=0.3238;size='8 oz';product='Our Family Natural Medium Cheddar Cheese 8 Oz';url='https://www.shopfamilyfare.com/shop/deli/cheese/blocks_wedges/our_family_natural_medium_cheddar_cheese_8_oz/p/6787418';cat='Dairy & Cheese'},
  @{names=@('mozzarella cheese');display='Mozzarella Cheese';board='mozzarella-cheese';gpu=28.3495;unit='oz';action='mint';price=0.2494;size='16 oz';product='Our Family Low Moisture Part Skim Mozzarella 16 Oz';url='https://www.shopfamilyfare.com/shop/deli/cheese/blocks_wedges/our_family_low_moisture_part_skim_natural_mozzarella_cheese_16_oz/p/7081803';cat='Dairy & Cheese'},
  @{names=@('feta cheese');display='Feta Cheese';board='feta-cheese';gpu=28.3495;unit='oz';action='mint';price=0.8113;size='8 oz';product='Culinary Tours Feta Chunk Cheese 8 Oz';url='https://www.shopfamilyfare.com/shop/deli/cheese/artisan_specialty/culinary_tours_feta_chunk_cheese/p/1564405684711368503';cat='Dairy & Cheese'},
  @{names=@('gruyere or swiss cheese');display='Swiss Cheese';board='swiss-cheese';gpu=28.3495;unit='oz';action='mint';price=0.3238;size='8 oz';product='Our Family Natural Swiss Cheese 8 Oz';url='https://www.shopfamilyfare.com/shop/deli/cheese/blocks_wedges/our_family_natural_swiss_cheese_8_oz/p/7081814';cat='Dairy & Cheese'},
  @{names=@('all-purpose flour','flour');display='All-Purpose Flour';board='all-purpose-flour';gpu=28.3495;unit='oz';action='mint';price=0.0374;size='5 lb';product='Our Family All Purpose Flour, Unbleached 5 Lb';url='https://www.shopfamilyfare.com/shop/pantry/baking/flour/our_family_all_purpose_flour_unbleached_5_lb/p/7081510';cat='Spices & Baking'},
  @{names=@('sugar');display='Sugar';board='sugar';gpu=28.3495;unit='oz';action='mint';price=0.0903;size='32 oz';product='Our Family Sugar, Granulated 32 Oz';url='https://www.shopfamilyfare.com/shop/pantry/baking/sweeteners/our_family_sugar_granulated_32_oz/p/6787181';cat='Spices & Baking'},
  @{names=@('panko breadcrumbs','italian breadcrumbs');display='Panko Breadcrumbs';board='breadcrumbs';gpu=28.3495;unit='oz';action='mint';price=0.3488;size='8 oz';product='Our Family Bread Crumbs, Panko, Plain 8 Oz';url='https://www.shopfamilyfare.com/shop/pantry/baking/other_baking_necessities/our_family_bread_crumbs_panko_plain_8_oz/p/1564405684711668357';cat='Spices & Baking'},
  @{names=@('frozen peas','peas');display='Frozen Peas';board='frozen-peas';gpu=28.3495;unit='oz';action='mint';price=0.1158;size='12 oz';product='Our Family Green Peas, Sweet, Frozen 12 Oz';url='https://www.shopfamilyfare.com/shop/freezer/frozen_vegetables/other_vegetables/our_family_green_peas_sweet_fresh_frozen_12_oz/p/1564405684703626585';cat='Frozen'},
  # ---- add now, price later via multi-store backfill (FF has no priceable listing) ----
  @{names=@('five-spice powder');display='Five-Spice Powder';board='five-spice-powder';gpu=28.3495;unit='oz';action='unpriced'},
  @{names=@('mint');display='Fresh Mint';board='fresh-mint';gpu=20;unit='each';action='unpriced'},
  @{names=@('capers');display='Capers';board='capers';gpu=29.57;unit='floz';action='unpriced'},
  # ---- SKIP: intentional recipe adaptations / unavailable specialty / alcohol ----
  @{names=@('cauliflower rice');display='';board='';action='skip'},
  @{names=@('red wine');display='';board='';action='skip'},
  @{names=@('kasoori methi (dried fenugreek leaves)','kasoori methi');display='';board='';action='skip'}
)

# ---- build lookup: reported-name-lower -> DEF record ----
$RES = @{}
foreach ($d in $DEF) { foreach ($n in $d.names) { $RES[$n.ToLower().Trim()] = $d } }

# ---- load current data ----
$feed = Get-Content 'C:\Codex\income\public\smp-feed.json' -Raw | ConvertFrom-Json
$doc  = Get-Content (Join-Path $mp 'recipes-db.json') -Raw | ConvertFrom-Json
$cons = Get-Content (Join-Path $SP 'audit2-consolidated.json') -Raw | ConvertFrom-Json

function PriceFor($d) {
  if ($d.action -eq 'mint') { return [double]$d.price }
  if ($d.action -eq 'unpriced') { return 0.0 }
  $e = $feed.ingredients.($d.board)
  if ($e) { return [double]$e.cheapest }
  return 0.0
}

# ---- per-(recipe,item) overrides ----
# skip items the agents flagged as belonging to a DIVERGENT source (our recipe is intentionally different)
$skipPair = @{}
$skipPair['ground-beef-stroganoff-pasta|cheddar cheese'] = $true   # source was a cheddar version; ours is mushroom
$skipPair['ground-beef-stroganoff-pasta|frozen peas'] = $true      # same divergent source
# correct a few clearly-inflated agent gram estimates
$gramsOverride = @{}
$gramsOverride['slow-cooker-french-onion-chicken-bowls|condensed french onion soup'] = 600   # 2 cans

# ---- resolve every reported missing item; collect unhandled ----
$bySlug = @{}; foreach ($r in $doc.recipes) { $bySlug[[string]$r.slug] = $r }
$unhandled = @{}
$plannedAdds = @{}   # slug -> list of @{display,board,grams,buy,cost,action}
$mintNeeded = @{}    # board -> DEF (mint only)
$totalAdds = 0
foreach ($rr in $cons.recipes) {
  $slug = [string]$rr.slug
  if (-not $rr.missing) { continue }
  $recipe = $bySlug[$slug]
  if (-not $recipe) { continue }
  $existing = @{}; foreach ($i in $recipe.ingredients) { $existing[([string]$i.item).ToLower().Trim()] = $true }
  foreach ($m in $rr.missing) {
    $nm = ([string]$m.item).ToLower().Trim()
    if (-not $nm) { continue }
    if (-not $RES.ContainsKey($nm)) { if (-not $unhandled.ContainsKey($nm)) { $unhandled[$nm]=0 }; $unhandled[$nm]++; continue }
    $d = $RES[$nm]
    if ($d.action -eq 'skip') { continue }
    if ($existing.ContainsKey($d.display.ToLower())) { continue }   # recipe already has it
    $pairKey = $slug + '|' + $d.display.ToLower()
    if ($skipPair.ContainsKey($pairKey)) { continue }
    $grams = 0; if ($m.grams_est) { $grams = [double]$m.grams_est }
    if ($gramsOverride.ContainsKey($pairKey)) { $grams = $gramsOverride[$pairKey] }
    if ($grams -le 0) { $grams = 6 }   # floor for spices with no estimate
    $buy = ''; if ($m.source_qty) { $buy = [string]$m.source_qty }
    if (-not $buy) { $buy = '1' }
    $price = PriceFor $d
    $cost = 0.0; if ($price -gt 0 -and $d.gpu -gt 0) { $cost = [math]::Round(($grams / $d.gpu) * $price, 2) }
    if (-not $plannedAdds.ContainsKey($slug)) { $plannedAdds[$slug] = [System.Collections.Generic.List[object]]::new() }
    # avoid double-adding same board to same recipe within this run
    $dup = $false; foreach ($p in $plannedAdds[$slug]) { if ($p.board -eq $d.board) { $dup = $true; break } }
    if ($dup) { continue }
    $plannedAdds[$slug].Add([pscustomobject]@{ display=$d.display; board=$d.board; grams=$grams; buy=$buy; cost=$cost; action=$d.action })
    $existing[$d.display.ToLower()] = $true
    if ($d.action -eq 'mint') { $mintNeeded[$d.board] = $d }
    $totalAdds++
  }
}

# ---- REPORT ----
Write-Output ('=============== FULL-AUDIT APPLY ' + $(if($Apply){'(APPLY)'}else{'(DRY RUN)'}) + ' ===============')
Write-Output ('recipes receiving additions: ' + $plannedAdds.Keys.Count)
Write-Output ('total ingredient additions:  ' + $totalAdds)
Write-Output ('new commodities to MINT:      ' + $mintNeeded.Keys.Count)
Write-Output ('unpriced-add commodities:     five-spice-powder, fresh-mint, capers (priced later via store backfill)')
Write-Output ''
if ($unhandled.Keys.Count -gt 0) {
  Write-Output ('*** UNHANDLED reported names (NOT added - review): ' + $unhandled.Keys.Count + ' ***')
  foreach ($k in ($unhandled.Keys | Sort-Object)) { Write-Output ('    ! ' + $k + ' x' + $unhandled[$k]) }
  Write-Output ''
}
$totalCost = 0.0
foreach ($p in $plannedAdds.Values) { foreach ($a in $p) { $totalCost += $a.cost } }
Write-Output ('total everyday-cost added across all recipes: $' + [math]::Round($totalCost,2))
Write-Output ''
Write-Output '--- per-recipe additions ---'
foreach ($slug in ($plannedAdds.Keys | Sort-Object)) {
  $adds = $plannedAdds[$slug]
  $items = ($adds | ForEach-Object { $_.display + '(' + $_.grams + 'g $' + $_.cost + ')' }) -join ', '
  Write-Output ('  ' + $slug + '  [+' + $adds.Count + ']  ' + $items)
}

if (-not $Apply) { Write-Output ''; Write-Output 'DRY RUN - no files written. Re-run with -Apply to commit.'; return }

# =================== APPLY ===================
# 1) mint commodities into recipe-board-everyday + product-urls
$bevF = Join-Path $g 'out\recipe-board-everyday.json'
$bev = Get-Content $bevF -Raw | ConvertFrom-Json
$bevIds = @{}; foreach ($r in $bev.comparison) { $bevIds[[string]$r.id] = $true }
$puF = Join-Path $g 'product-urls.json'
$pu = Get-Content $puF -Raw | ConvertFrom-Json
$minted = 0
foreach ($board in $mintNeeded.Keys) {
  $d = $mintNeeded[$board]
  if ($bevIds.ContainsKey($board)) { continue }
  $store = [pscustomobject]@{ store='Family Fare'; per_unit=$d.price; unit=$d.unit; type='everyday'; bulk=$false; membership=$false; item=$d.product; size=$d.size }
  $row = [pscustomobject]@{ id=$board; commodity=$d.display; unit=$d.unit; category=$d.cat; cheapest_store='Family Fare'; cheapest_price=$d.price; cheapest_type='everyday'; stores=@($store) }
  $bev.comparison = @($bev.comparison) + $row
  if (-not $pu.items.PSObject.Properties[$board]) { $pu.items | Add-Member -NotePropertyName $board -NotePropertyValue ([pscustomobject]@{ commodity=$d.display }) }
  $pu.items.$board | Add-Member -NotePropertyName 'Family Fare' -NotePropertyValue ([pscustomobject]@{ url=$d.url; price=$d.price; size=$d.size; name=$d.product }) -Force
  $minted++
}
($bev | ConvertTo-Json -Depth 8) | Set-Content $bevF -Encoding UTF8
($pu | ConvertTo-Json -Depth 6) | Set-Content $puF -Encoding UTF8
Write-Output ("minted " + $minted + " new board commodities")

# 2) ingredient-map: UPSERT display -> board for every non-skip DEF (also corrects pre-existing
#    gpu bugs, e.g. Butter was oz/28.3495 against a per-lb price; Fresh Cilantro gpu 28 -> 57).
$mapF = Join-Path $mp 'ingredient-map.json'
$map = Get-Content $mapF -Raw | ConvertFrom-Json
$mapList = [System.Collections.Generic.List[object]]::new(); foreach ($m in $map.mappings) { $mapList.Add($m) }
$idxByDisplay = @{}; for ($i=0; $i -lt $mapList.Count; $i++) { $idxByDisplay[([string]$mapList[$i].item).ToLower()] = $i }
$mapAdded = 0; $mapFixed = 0
foreach ($d in $DEF) {
  if ($d.action -eq 'skip') { continue }
  $k = $d.display.ToLower()
  if ($idxByDisplay.ContainsKey($k)) {
    $ex = $mapList[$idxByDisplay[$k]]
    if ([string]$ex.board_id -ne $d.board -or [double]$ex.grams_per_unit -ne [double]$d.gpu -or [string]$ex.unit -ne $d.unit) {
      $ex.board_id = $d.board; $ex.grams_per_unit = $d.gpu; $ex.unit = $d.unit
      $mapFixed++
    }
  } else {
    $mapList.Add([pscustomobject]@{ item=$d.display; board_id=$d.board; board='recipe'; grams_per_unit=$d.gpu; unit=$d.unit })
    $idxByDisplay[$k] = $mapList.Count - 1
    $mapAdded++
  }
}
$map.mappings = $mapList.ToArray()
($map | ConvertTo-Json -Depth 6) | Set-Content $mapF -Encoding UTF8
Write-Output ("ingredient-map: +" + $mapAdded + " new, " + $mapFixed + " corrected (total " + $map.mappings.Count + ")")

# 3) apply additions to recipes-db + recompute cost
$applied = 0
foreach ($slug in $plannedAdds.Keys) {
  $recipe = $bySlug[$slug]
  $adds = $plannedAdds[$slug]
  $delta = 0.0
  foreach ($a in $adds) {
    $recipe.ingredients = @($recipe.ingredients) + @([pscustomobject]@{ item=$a.display; grams=$a.grams; buy=$a.buy })
    $recipe.grocery_list = @($recipe.grocery_list) + @($a.buy + ' ' + $a.display)
    $delta += $a.cost
    $applied++
  }
  if ($recipe.PSObject.Properties['cost_batch']) { $recipe.cost_batch = [math]::Round([double]$recipe.cost_batch + $delta, 2) }
  if ($recipe.PSObject.Properties['cost_batch_true']) { $recipe.cost_batch_true = [math]::Round([double]$recipe.cost_batch_true + $delta, 2) }
  $batch = [double]$recipe.cost_batch; if ($recipe.PSObject.Properties['cost_batch_true'] -and $recipe.cost_batch_true) { $batch = [double]$recipe.cost_batch_true }
  $per = $null; if ($recipe.servings) { $per = [math]::Round($batch / [int]$recipe.servings, 2) }
  if ($recipe.PSObject.Properties['cost_per_serving']) { $recipe.cost_per_serving = $per }
  if ($recipe.PSObject.Properties['cost_per_serving_true']) { $recipe.cost_per_serving_true = $per }
}
($doc | ConvertTo-Json -Depth 10) | Set-Content (Join-Path $mp 'recipes-db.json') -Encoding UTF8
Write-Output ("applied " + $applied + " ingredient additions across " + $plannedAdds.Keys.Count + " recipes")
Write-Output 'DONE.'
