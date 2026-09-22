# build-intakes.ps1 - the four pre-engine recipe posts as engine intakes (2026-09-22, Brad's ruling A of 2026-09-21:
# rebuild /free-chicken-alfredo/ and the three old recipe posts whose titles carry a price as ENGINE recipes priced by
# the pipeline, same slug, same story and voice, no dollar figure in any title).
#
# WHAT IS KEPT from each old post: the ingredient list and its grams (the recipe itself), the method, and the story.
# WHAT IS NOT: every typed price (the old "Estimated Cost" sections) and every hand-stated macro. Macros here are
# recomputed from meal-prep\food-macros-db.json (label rows) over the kept grams; build-v2-spec.ps1 re-verifies them
# against its own recompute and prices every line from the board through engine\cost-recipes.ps1.
# Brad's deep-freezer story stays as his experience; its per-pound figures are told without a dollar sign because the
# renderer rewrites every "$N" in prose and the build gate allows exactly two membership phrases.
# Usage: powershell -File meal-prep\runs\legacy-rebuild-2026-09-22\build-intakes.ps1   (writes intake\<slug>.json)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$mp = Split-Path -Parent (Split-Path -Parent $here)
$db = Get-Content (Join-Path $mp 'food-macros-db.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$rows = @{}; foreach ($r in $db.items) { $rows[[string]$r.item] = $r }
function Get-Macros { param([object[]]$Ing)
  $c = 0.0; $p = 0.0; $cb = 0.0; $f = 0.0
  foreach ($i in $Ing) {
    $r = $rows[[string]$i.item]; if (-not $r) { throw ("food DB has no row '" + $i.item + "' - a STOP for this recipe") }
    $k = [double]$i.grams / [double]$r.serving_grams
    $c += $k * [double]$r.calories; $p += $k * [double]$r.protein_g; $cb += $k * [double]$r.carbs_g; $f += $k * [double]$r.fat_g
  }
  return [ordered]@{ calories = [int][math]::Round($c / 14); protein_g = [int][math]::Round($p / 14); carbs_g = [int][math]::Round($cb / 14); fat_g = [int][math]::Round($f / 14) }
}
$upsellTail = 'This is one of many. Members get every recipe in the Meal Prep section, plus the full 52-week library of money, work, and life lessons. All for $1 a month.'
$credit = 'One of our own recipes, first posted in June 2026 and rebuilt on live Omaha store pricing.'
$recipes = @(
  [ordered]@{ name = 'Budget Chicken Alfredo Meal Prep'; slug = 'free-chicken-alfredo'; protein = 'chicken'; cuisine = 'Italian-American'; visibility = 'public'
    ingredients = @(
      [ordered]@{ item = 'Boneless Skinless Chicken Breast'; grams = 2311 },
      [ordered]@{ item = 'Cottage Cheese'; grams = 678 },
      [ordered]@{ item = 'Alfredo Sauce'; grams = 1362 },
      [ordered]@{ item = 'High Protein Pasta'; grams = 784; display_name = 'Protein Rotini Pasta' },
      [ordered]@{ item = 'Broccoli Florets'; grams = 1190 })
    prose = [ordered]@{
      intro_html = 'A freezer-friendly, high-protein batch, and about two weeks of dinners from one cook session. Chicken, protein rotini, broccoli and a creamy alfredo with a quiet trick in it: blended cottage cheese, which bumps the protein up without changing the taste. It comes in at about <strong>${{cost_ps}}</strong> a serving (at everyday cost), with <strong>{{cal}} calories and {{protein}} grams of protein</strong> in every container.'
      shop_smart = @(
        'Buy chicken when it is on sale, then freeze it. Stores drop chicken to a sale price at random. We once grabbed 50 lbs on sale, a full dollar a pound under our usual price, and loaded up the deep freezer. That one buy saved us fifty bucks. At about 5 lbs per batch, 50 lbs makes 10 batches. That is 140 portions, or about 70 nights of dinner for two.',
        'Go store-brand on the alfredo sauce. It is a fraction of the name-brand price, and if it tastes a little bland, just season it up.',
        'Pasta is flexible. We use Barilla Protein pasta for the macros here, but store-brand pasta is dirt cheap. Just know your macros will shift a little if you swap.',
        'Buy cottage cheese in the big tubs and compare price per ounce across stores, and check your local weekly ads too. Price per ounce is the number that actually tells you the deal.')
      make_it = @(
        'Weigh your empty pot first. Put the largest pot you will use to mix everything on your large scale and write down its weight. You need that number at the end to portion accurately.',
        'Boil the rotini in that pot until al dente, drain, and set it aside.',
        'Cube and cook the chicken breast. Season it however you like: salt, pepper, garlic, Italian seasoning, a little cayenne if you want heat. No wrong answer here, so go with what your taste buds love.',
        'Blend the cottage cheese until smooth, then stir it into the alfredo sauce and warm it through. The cottage cheese bumps the protein up without changing the creamy taste.',
        'Steam or roast the broccoli.',
        'Combine everything back in the pot and stir to coat.')
      portion_html = 'Set the full pot on your large scale and subtract the empty-pot weight you wrote down in step 1. That is your total food weight. Divide it by 14, then scoop that amount into each glass container. Every meal lands at <strong>{{cal}} calories and {{protein}} grams of protein</strong>.'
      cost_closing_html = 'That is about <strong>${{cost_ps}}</strong> a meal (at everyday cost). Put it next to a single takeout dinner and it is not close.'
      upsell_html = ('Like cooking two weeks of dinners for about <strong>${{cost_ps}}</strong> a plate (at everyday cost)? ' + $upsellTail)
      credit_html = $credit }
    head = [ordered]@{ description = 'Budget chicken alfredo meal prep: chicken, protein rotini, broccoli and a cottage cheese alfredo, 14 servings. {{cal}} calories, {{protein}}g protein, about ${{cost_ps}} (at everyday cost).'
      keywords = 'chicken alfredo meal prep, budget meal prep, high protein pasta, cottage cheese alfredo, freezer meal prep'; image = ''; prepTime = 'PT20M'; cookTime = 'PT30M'; totalTime = 'PT50M'
      steps = @('Weigh the empty pot and write the number down.', 'Boil the rotini until al dente and drain.', 'Cube, season and cook the chicken breast.', 'Blend the cottage cheese smooth and stir it into the warmed alfredo sauce.', 'Steam or roast the broccoli.', 'Combine everything, weigh the full pot, subtract the pot and divide by 14.') } },
  [ordered]@{ name = 'Slow-Cooker BBQ Chicken Meal Prep'; slug = 'shredded-bbq-chicken-sammies'; protein = 'chicken'; cuisine = 'American'; visibility = 'paid'
    ingredients = @(
      [ordered]@{ item = 'Boneless Skinless Chicken Breast'; grams = 2267 },
      [ordered]@{ item = 'BBQ Sauce (Sugar Free)'; grams = 1536 },
      [ordered]@{ item = 'Fries'; grams = 5950; display_name = 'Crinkle-Cut Fries' })
    prose = [ordered]@{
      intro_html = 'Shredded BBQ chicken sandwiches with a pile of crinkle-cut fries, made the lazy way: the slow cooker does the work. The chicken freezes and reheats great, and the fries bake fresh when you eat. It comes in at about <strong>${{cost_ps}}</strong> a serving (at everyday cost) for the chicken and fries, with <strong>{{cal}} calories and {{protein}} grams of protein</strong>.'
      shop_smart = @(
        'Buy chicken on sale and freeze it. Same play as always: bulk family packs when it is marked down.',
        'Buy the big bag of fries. The larger bag is almost always the better deal per pound, and fries keep great in the freezer. Compare the price per pound on the shelf tag.',
        'Pick your BBQ sauce by the label. The one in this recipe keeps the calories down; a regular store-brand bottle is usually cheaper and adds calories.',
        'Buns are your choice, and they are not counted in the macros or the cost here. We use Bettergoods Keto buns, but get whatever is cost-effective for you.')
      make_it = @(
        'Season the chicken breast to your liking.',
        'Add the seasoned chicken to your slow cooker and cook on HIGH for 4 hours.',
        'Shred the cooked chicken and drain off any excess liquid.',
        'Mix the BBQ sauce into the shredded chicken until it is evenly coated.',
        'Bake the crinkle-cut fries per the bag.',
        'Pile the BBQ chicken onto a bun and serve with the fries.')
      portion_html = 'Weigh the finished BBQ chicken and divide by 14 for your per-sandwich meat portion. Split the fries the same way, by weight, and bake each portion fresh when you eat. Together that is <strong>{{cal}} calories and {{protein}} grams of protein</strong> a plate, before the bun.'
      cost_closing_html = 'About <strong>${{cost_ps}}</strong> a plate (at everyday cost) for the chicken and the fries. The bun is on you.'
      upsell_html = ('BBQ chicken sandwiches and fries for about <strong>${{cost_ps}}</strong> a plate (at everyday cost). ' + $upsellTail)
      credit_html = $credit }
    head = [ordered]@{ description = 'Slow-cooker BBQ chicken meal prep: shredded BBQ chicken with crinkle-cut fries, 14 servings. {{cal}} calories, {{protein}}g protein, about ${{cost_ps}} (at everyday cost).'
      keywords = 'bbq chicken meal prep, slow cooker chicken, shredded chicken sandwiches, budget meal prep, high protein'; image = ''; prepTime = 'PT15M'; cookTime = 'PT4H'; totalTime = 'PT4H15M'
      steps = @('Season the chicken breast.', 'Slow cook on HIGH for 4 hours.', 'Shred and drain the chicken.', 'Mix in the BBQ sauce.', 'Bake the fries per the bag.', 'Weigh and divide the chicken and fries by 14.') } },
  [ordered]@{ name = 'Beef Protein Pasta Meal Prep'; slug = 'beef-protein-pasta'; protein = 'beef'; cuisine = 'Italian-American'; visibility = 'paid'
    ingredients = @(
      [ordered]@{ item = '93/7 Ground Beef'; grams = 2712 },
      [ordered]@{ item = 'Traditional Pasta Sauce'; grams = 2040 },
      [ordered]@{ item = 'High Protein Pasta'; grams = 784; display_name = 'Protein Penne Pasta' },
      [ordered]@{ item = 'Cottage Cheese'; grams = 678 })
    prose = [ordered]@{
      intro_html = '93/7 ground beef, protein penne and a pasta sauce blended with cottage cheese until it turns creamy. It eats like a rich meat sauce and carries a lot of protein for the money. It comes in at about <strong>${{cost_ps}}</strong> a serving (at everyday cost), with <strong>{{cal}} calories and {{protein}} grams of protein</strong>.'
      shop_smart = @(
        'Watch for ground beef sales and stock the freezer. 93/7 ground beef is one of the pricier proteins, so grab the big family packs when your store marks it down and freeze what you will not use that week. If you spot a great deal on 80/20, go for it, but know it adds calories and fat and takes a little protein away.',
        'Store-brand pasta sauce is the move. It costs a fraction of the name brands. Punch it up with garlic, Italian seasoning, or a pinch of red pepper.',
        'Pasta is flexible. We use Barilla Protein penne for the macros here, but store-brand penne is dirt cheap. Your macros will shift a little if you swap.',
        'Buy cottage cheese in the big tubs and compare price per ounce across stores, and scan your local weekly ads too.')
      make_it = @(
        'Weigh your empty pot first and write down the number. You need it to portion at the end.',
        'Boil the penne until al dente, drain, and set it aside.',
        'Brown the ground beef and drain the excess fat. Season it to your liking: salt, pepper, garlic, Italian seasoning, a little red pepper if you want heat.',
        'Make the sauce: blend the pasta sauce with the cottage cheese until smooth and creamy, then warm it through. Depending on your blender, you may need two batches.',
        'Combine the beef, sauce and penne back in the pot and stir to coat.')
      portion_html = 'Set the full pot on your large scale, subtract the empty-pot weight you wrote down in step 1, and divide by 14. Scoop that amount into each glass container. Every meal lands at <strong>{{cal}} calories and {{protein}} grams of protein</strong>.'
      cost_closing_html = 'About <strong>${{cost_ps}}</strong> a container (at everyday cost) for a meat-sauce pasta with {{protein}} grams of protein in it.'
      upsell_html = ('A creamy beef pasta for about <strong>${{cost_ps}}</strong> a container (at everyday cost). ' + $upsellTail)
      credit_html = $credit }
    head = [ordered]@{ description = 'Beef protein pasta meal prep: 93/7 ground beef, protein penne and a cottage cheese pasta sauce, 14 servings. {{cal}} calories, {{protein}}g protein, about ${{cost_ps}} (at everyday cost).'
      keywords = 'beef pasta meal prep, protein pasta, cottage cheese pasta sauce, ground beef meal prep, budget meal prep'; image = ''; prepTime = 'PT15M'; cookTime = 'PT30M'; totalTime = 'PT45M'
      steps = @('Weigh the empty pot and write the number down.', 'Boil the penne until al dente and drain.', 'Brown, drain and season the ground beef.', 'Blend the pasta sauce with the cottage cheese and warm it.', 'Combine everything, weigh the full pot, subtract the pot and divide by 14.') } },
  [ordered]@{ name = 'Chicken Marinara Meal Prep'; slug = 'chicken-marinara-pasta'; protein = 'chicken'; cuisine = 'Italian-American'; visibility = 'paid'
    ingredients = @(
      [ordered]@{ item = 'Boneless Skinless Chicken Breast'; grams = 2267 },
      [ordered]@{ item = 'High Protein Pasta'; grams = 784; display_name = 'Protein Penne Pasta' },
      [ordered]@{ item = 'Marinara Sauce'; grams = 2608 },
      [ordered]@{ item = 'Fat Free Cottage Cheese'; grams = 226 },
      [ordered]@{ item = 'Turkey Pepperoni'; grams = 426 },
      [ordered]@{ item = 'Reduced Fat Mozzarella'; grams = 453 })
    prose = [ordered]@{
      intro_html = 'Chicken, protein penne and marinara, finished with melted mozzarella and turkey pepperoni so it eats like a pizza pasta. A little blended cottage cheese in the sauce adds protein you will never taste. It comes in at about <strong>${{cost_ps}}</strong> a serving (at everyday cost), with <strong>{{cal}} calories and {{protein}} grams of protein</strong>.'
      shop_smart = @(
        'Buy chicken on sale and freeze it. Same play as always: grab bulk family packs when it is marked down.',
        'Store-brand marinara is the move. It costs a fraction of the name brands. Season it up if it needs a lift.',
        'Watch for turkey pepperoni deals. It is the priciest add-on here, so stock up when it is on sale. It keeps a while.',
        'Buy cheese in bulk and compare price per ounce on mozzarella and cottage cheese, and scan your local ads too.')
      make_it = @(
        'Weigh your empty pot first and write down the number. You need it to portion at the end.',
        'Boil the penne until al dente, drain, and set it aside.',
        'Cube and cook the chicken breast. Season it to your liking: salt, pepper, garlic, Italian seasoning.',
        'Make the sauce: blend the cottage cheese into the marinara until smooth, then warm it through.',
        'Combine the chicken, sauce and penne in the pot and stir to coat.',
        'Stir in the shredded mozzarella and turkey pepperoni until the cheese melts through. No broiling needed.')
      portion_html = 'Set the full pot on your large scale, subtract the empty-pot weight you wrote down in step 1, and divide by 14. Scoop that amount into each glass container. Every meal lands at <strong>{{cal}} calories and {{protein}} grams of protein</strong>.'
      cost_closing_html = 'About <strong>${{cost_ps}}</strong> a container (at everyday cost) for a pizza pasta with {{protein}} grams of protein in it.'
      upsell_html = ('A cheesy chicken marinara for about <strong>${{cost_ps}}</strong> a container (at everyday cost). ' + $upsellTail)
      credit_html = $credit }
    head = [ordered]@{ description = 'Chicken marinara meal prep: chicken, protein penne, marinara, mozzarella and turkey pepperoni, 14 servings. {{cal}} calories, {{protein}}g protein, about ${{cost_ps}} (at everyday cost).'
      keywords = 'chicken marinara meal prep, pizza pasta, protein pasta, high protein meal prep, budget meal prep'; image = ''; prepTime = 'PT15M'; cookTime = 'PT30M'; totalTime = 'PT45M'
      steps = @('Weigh the empty pot and write the number down.', 'Boil the penne until al dente and drain.', 'Cube, season and cook the chicken breast.', 'Blend the cottage cheese into the marinara and warm it.', 'Combine chicken, sauce and penne, then stir in the mozzarella and pepperoni.', 'Weigh the full pot, subtract the pot and divide by 14.') } }
)
$outDir = Join-Path $here 'intake'; New-Item -ItemType Directory -Force $outDir | Out-Null
foreach ($r in $recipes) {
  $r['source_url'] = 'https://www.thriftycrew.com/' + $r.slug + '/'
  $r['source_site'] = 'thriftycrew.com'
  $r['macros_per_serving'] = Get-Macros $r.ingredients
  $r['writer_notes'] = @('LEGACY REBUILD (ruling A, 2026-09-21): pre-engine post rebuilt at its own URL; grams and method kept from the 2026-06/07 post, every typed price and hand-stated macro dropped.')
  [IO.File]::WriteAllText((Join-Path $outDir ($r.slug + '.json')), ($r | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
  "{0,-30} {1}" -f $r.slug, (($r.macros_per_serving.GetEnumerator() | ForEach-Object { $_.Key + '=' + $_.Value }) -join ' ')
}
