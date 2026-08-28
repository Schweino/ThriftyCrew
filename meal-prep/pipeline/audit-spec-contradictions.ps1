<#
  audit-spec-contradictions.ps1 - find recipe specs that contradict THEMSELVES.

  WHY. On 2026-07-26 five writer agents rewriting shop_smart prose kept tripping over content bugs that had
  nothing to do with their task, and wrote them up by hand in
  db\worklists\prose-data-smells-2026-07-26.md: a portion paragraph claiming 499 calories on a 541-calorie
  recipe, a head ingredient list asking for 5.5 cups of rice while the recipe costs 3.75, a chicken broth
  line that reads "0 lb", a cost sentence still quoting "28 cents" from a basis that no longer exists.
  Those were found because a human-shaped reader happened to be looking at 97 of the 513 recipes. That is
  not a detector, it is a coincidence - so this is the same reading applied to every spec, every run.

  A CONTRADICTION IS SPECIAL because it needs no outside evidence. The spec states the same fact twice and
  the two statements disagree, so one of them is wrong no matter what the source recipe says. Everything
  that DOES need outside evidence - is 308 g of garlic right for pad thai, should this dish contain
  lemongrass - is deliberately out of scope; that is a cook's judgment and it belongs in a worklist a
  person works, not in a gate.

  THE CHECKS, each one a class the writers actually hit:
    STAT-PROSE   a calorie or protein figure in intro/portion/head.description that is not stat's.
                 spec-guards already requires portion_html to CONTAIN stat.cal, which fajita passes while
                 also containing 499 - "contains the right number" and "contains no wrong ones" are
                 different questions and only the second one catches this.
    UNMEASURABLE-QTY a display or cost line asking for less than a quarter of its own unit - "0 lb",
                     "0.07 oz". A real ingredient rounded past the point any kitchen can measure it
                 by its display unit: the shopper is told to buy zero of something the recipe needs.
    STALE-MONEY  a dollar or cents figure in a NON-shop_smart prose field that is not the current
                 per-serving cost. The 2026-07-26 money strip only covered shop_smart, so cost_closing and
                 upsell still carry frozen figures from a basis that changed underneath them.
                 The $N.NN half read only cost_closing/upsell until 2026-08-07, which is how 15 slow-cooker
                 specs kept a portion line saying "$2.00 a bowl" beside a closing line saying "$4.87 a bowl".
                 It now reads all five fields spec-guards names - see spec-contradiction-lib.ps1.
    ABSURD-UNIT  a tablespoon count over 24 (a cup and a half, in tablespoons). "105 tbsp" of cilantro is
                 arithmetically true at ~1 g/tbsp and useless to a person holding a measuring spoon.
    HEAD-QTY     the head ingredient list and the costed display line state different amounts of the same
                 ingredient in the same unit.
    PHANTOM      a make_it step names a food this estate knows and the recipe's ingredient list does not
                 carry it. The mirror of UNUSED, and the only reading that can see
                 slow-cooker-dr-pepper-pulled-pork-bowls: step 2 pours a zero-sugar soda that appears in
                 no display line, no scaler row and no cost line, so the braise the recipe is NAMED for
                 cannot be made as shopped. Measured and left unshipped on 2026-08-02 because the naive
                 version gave 295 hits; the four rules in the lib (longest-match masking, surface-not-stem
                 matching, compound tails, made-in-the-step) are what made it readable. See
                 out\fidelity\engine-pass-notes.md for that measurement.
  ADVISORY (reported, never a failure): UNUSED - an ingredient the list buys and the steps never mention.
  It is the noisiest reading here because steps legitimately say "season" instead of naming salt, and a
  guard that cries wolf is one nobody reads.

  Ratchets against out\spec-contradictions-baseline.json so it can ship on a catalogue that already has
  findings: it fails when a CLASS gets worse, never on the standing count.

  Usage: .\audit-spec-contradictions.ps1 [-Baseline] [-Quiet] [-SelfTest]
#>
param([switch]$Baseline, [switch]$Quiet, [switch]$SelfTest, [switch]$IncludeArchive, [string]$Root = "")
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'lib\guard-contract.ps1')
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = if ($Root) { $Root } else { Split-Path -Parent $here }

# The matcher lives in spec-contradiction-lib.ps1, shared with repair-spec-contradictions.ps1. Two copies
# would disagree the first time either was tightened, and this audit would then certify a repair it does
# not actually describe.
. (Join-Path $here 'spec-contradiction-lib.ps1')

function Get-SpecSet([string]$mpRoot, [bool]$includeArchive) {
  <#
    THE LIVE SPEC LAYER IS db\recipes, and that distinction cost a wasted pass. engine\build-cards.ps1
    renders from db\recipes\*.json; archive\<run>\specs\ are the pre-consolidation snapshots of each run and
    nothing builds from them. Reading the archive and calling the result "the catalogue" audits 513 files
    that no shopper can see - measured on 2026-08-02, 372 of the 513 archive copies differ from their live
    twin, in exactly the fields the cost-redesign writer waves rewrote.
    -IncludeArchive is available on purpose (a contradiction in a snapshot is still a fact about that run),
    but the default is the layer that ships.
  #>
  $out = New-Object System.Collections.Generic.List[object]
  $liveDir = Join-Path $mpRoot 'db\recipes'
  if (Test-Path $liveDir) {
    foreach ($f in @(Get-ChildItem (Join-Path $liveDir '*.json') | Where-Object { $_.Name -notmatch '^(run-|recipes-)' -and $_.Name -ne '_index.json' })) {
      $out.Add([pscustomobject]@{ run = 'live'; slug = $f.BaseName; path = $f.FullName })
    }
  }
  if ($includeArchive) {
    foreach ($d in @(Get-ChildItem (Join-Path $mpRoot 'archive') -Directory -ErrorAction SilentlyContinue)) {
      $sd = Join-Path $d.FullName 'specs'
      if (-not (Test-Path $sd)) { continue }
      foreach ($f in @(Get-ChildItem (Join-Path $sd '*.json') | Where-Object { $_.Name -notmatch '^(run-|recipes-)' -and $_.Name -ne '_index.json' })) {
        $out.Add([pscustomobject]@{ run = $d.Name; slug = $f.BaseName; path = $f.FullName })
      }
    }
  }
  return $out
}
if ($SelfTest) {
  $fail = 0
  function Chk([string]$label, [bool]$cond, [string]$got) {
    if ($cond) { Write-Output ("ok    " + $label) } else { Write-Output ("FAIL  " + $label + "   got: " + $got); $script:fail++ }
  }
  # FROZEN FIXTURE - every field below is copied out of a real spec named in
  # db\worklists\prose-data-smells-2026-07-26.md, so each assertion is a bug that actually shipped.
  $bad = [pscustomobject]@{
    stat = [pscustomobject]@{ cal = 541; protein = 49; cost_ps = '3.52' }
    # fajita-chicken-rice-bowl: portion says 499 on a 541-calorie recipe (and spec-guards PASSES it,
    # because 541 also appears elsewhere in the same paragraph).
    # The trailing money clause is slow-cooker-butter-chicken-rice-bowls as it shipped: a portion line and a
    # closing line quoting DIFFERENT dollars in the SAME "a bowl" unit, which read as two fields until
    # 2026-08-07 meant only the closing one was ever checked.
    portion_html = '<p>One container is 499 cal and 49g protein. The whole batch is 541 calories a bowl, at roughly $2.00 a bowl.</p>'
    intro_html = '<p>541 calories a bowl.</p>'
    # filipino-pork-giniling: a cents figure from a basis that no longer exists.
    cost_closing_html = '<p>About <strong>$3.52 a bowl</strong>, and the fish sauce seasons the batch for 28 cents.</p>'
    upsell_html = '<p>$3.52 a bowl.</p>'
    head = [pscustomobject]@{ description = 'A 541 calorie bowl.'; recipeIngredient = @('5.5 cups dry rice', '2 lb ground beef') }
    # hong-kongstyle-baked-pork-chop-rice + turkey-keema-curry + greek-beef-and-chickpea
    ingredients_display = @('<strong>Chicken Broth (Swanson):</strong> 0 lb (42 g)', '<strong>Fresh Cilantro:</strong> 105 tbsp (105 g)', '<strong>Rice (Member''s Mark):</strong> 3.75 cups dry (700 g)')
    cost_lines = @('Chicken Broth, 0 lb: ~$0.06.')
    make_it = @('Weigh the pot.', 'Cook the rice.', 'Simmer with broth and cilantro.')
  }
  # FROZEN VOCABULARY - never read from db\ingredients.json, per the guard-fixture rule. These are the
  # names the PHANTOM cases below need in order to mean anything, including the ones that exist only to
  # be the LONGER match that must win ("Brown Sugar" over "Sugar", "Olive Oil" over "Olives").
  $vocabFx = New-FoodVocabulary @(
    'Zero-Sugar Soda', 'Soda', 'Sugar', 'Brown Sugar', 'Olives', 'Olive Oil', 'Rice', 'Rice Vinegar',
    'Potato', 'Sweet Potatoes', 'Peas', 'Frozen Green Peas', 'Cheddar Cheese, Shredded', 'Fries',
    'Salsa', 'Tomatillos', 'BBQ Sauce (Sugar Free)', 'Pork Loin', 'Salt', 'Black Pepper',
    'Paprika', 'Dried Thyme', 'Garlic Powder', 'Onion Powder',   # the composite-rider pair below needs the riders to be known foods
    'Tomato', 'Marinara Sauce',   # the constituent-rule pair - without Tomato in this vocab both its fixtures are vacuous
    'Coconut Milk', 'Coconut Oil'   # the coconut constituent pair, and the two names its over-forgiveness twin needs
  )
  $r = @(Get-SpecContradictions $bad $vocabFx)
  $cls = @($r | ForEach-Object { $_.cls })
  Chk 'MUST FIRE  STAT-PROSE  499 cal in a paragraph that also says 541' (($cls -contains 'STAT-PROSE') -and (@($r | Where-Object { $_.why -match '499' }).Count -eq 1)) (($r | ForEach-Object { $_.why }) -join ' | ')
  # ---- RX_PROTEIN AND THE DECIMAL (2026-08-27) -------------------------------------------------------
  # The leading \b sat between the '.' and the '3' of "47.3g protein", so the matcher captured the
  # FRAGMENT "3g protein" and the gate reported 'says 3g protein, stat says 47' against a correct spec.
  # It went red on chicken-rice-and-broccoli and blocked a wave that contained neither that recipe nor
  # that number, because a wave cannot publish over a red shared gate. These run against the real shared
  # lib through Get-SpecContradictions, not against a copy of the pattern - test-guards.ps1 keeps its own
  # $RX_CAL_T/$RX_BOUND_T copies, and a fixture over a copy proves nothing about the file that ships.
  function ProteinFx([string]$prose, [int]$stat) {
    $fx = [pscustomobject]@{
      stat = [pscustomobject]@{ cal = 541; protein = $stat; cost_ps = '3.52' }
      intro_html = ('<p>' + $prose + '</p>')
      head = [pscustomobject]@{ description = 'A 541 calorie bowl.'; recipeIngredient = @('2 lb ground beef') }
      make_it = @('Cook it.')
    }
    return @(Get-SpecContradictions $fx $vocabFx | Where-Object { $_.why -match 'protein' })
  }
  $pDec = ProteinFx '47.3g protein a serving.' 47
  Chk 'CLEAN TWIN a DECIMAL protein claim that agrees with the stat is silent - the fragment "3g" was the whole bug' `
    ($pDec.Count -eq 0) (($pDec | ForEach-Object { $_.why }) -join ' | ')
  $pFrag = ProteinFx 'packs 8.5 g protein a serving.' 8
  Chk 'CLEAN TWIN "8.5 g protein" reads as 8.5, never as the 5 the old pattern captured' `
    ($pFrag.Count -eq 0) (($pFrag | ForEach-Object { $_.why }) -join ' | ')
  $pStale = ProteinFx '99g protein a serving.' 47
  Chk 'MUST FIRE  a WHOLE-NUMBER protein claim that contradicts the stat still fires' `
    ($pStale.Count -ge 1) (($pStale | ForEach-Object { $_.why }) -join ' | ')
  $pStaleDec = ProteinFx '99.9g protein a serving.' 47
  Chk 'MUST FIRE  a DECIMAL protein claim that contradicts the stat fires too - the guard must not blind the check' `
    ($pStaleDec.Count -ge 1) (($pStaleDec | ForEach-Object { $_.why }) -join ' | ')

  Chk 'MUST FIRE  UNMEASURABLE-QTY a broth line that reads "0 lb"' (@($r | Where-Object { $_.cls -eq 'UNMEASURABLE-QTY' }).Count -ge 1) (($r | Where-Object { $_.cls -eq 'UNMEASURABLE-QTY' } | ForEach-Object { $_.why }) -join ' | ')
  Chk 'MUST FIRE  STALE-MONEY a "28 cents" claim in cost_closing' (@($r | Where-Object { $_.cls -eq 'STALE-MONEY' -and $_.why -match '28 cents' }).Count -eq 1) (($r | Where-Object { $_.cls -eq 'STALE-MONEY' } | ForEach-Object { $_.why }) -join ' | ')
  # THE PORTION-MONEY CASE. Live for the whole life of 15 specs because this class read two fields and the
  # portion line was not one of them. If this assertion ever goes quiet, the scope has been narrowed back.
  Chk 'MUST FIRE  STALE-MONEY portion_html quotes $2.00 on a $3.52 bowl' (@($r | Where-Object { $_.cls -eq 'STALE-MONEY' -and $_.why -match 'portion_html quotes \$2\.00' }).Count -eq 1) (($r | Where-Object { $_.cls -eq 'STALE-MONEY' } | ForEach-Object { $_.why }) -join ' | ')
  Chk 'MUST FIRE  ABSURD-UNIT 105 tbsp of cilantro' (@($r | Where-Object { $_.cls -eq 'ABSURD-UNIT' }).Count -eq 1) (($r | Where-Object { $_.cls -eq 'ABSURD-UNIT' } | ForEach-Object { $_.why }) -join ' | ')
  Chk 'MUST FIRE  HEAD-QTY    head 5.5 cups rice vs a costed 3.75 cups' (@($r | Where-Object { $_.cls -eq 'HEAD-QTY' }).Count -eq 1) (($r | Where-Object { $_.cls -eq 'HEAD-QTY' } | ForEach-Object { $_.why }) -join ' | ')
  # CLEAN TWIN - a spec that states each fact once and consistently must produce NOTHING but advisories.
  $good = [pscustomobject]@{
    stat = [pscustomobject]@{ cal = 620; protein = 41; cost_ps = '3.06' }
    # The bare "$14" is here twice on purpose: a cents-less comparison price is the ONE dollar figure reader
    # prose may carry that is not cost_ps, and now that the money read covers all five fields it has to stay
    # silent in the newly-covered ones too, not just in cost_closing where it was always allowed.
    portion_html = '<p>620 calories and 41 g of protein a container, for what a restaurant charges $14 for.</p>'
    intro_html = '<p>620 calories a bowl, and $3.06 beats the $14 takeout.</p>'
    cost_closing_html = '<p>About <strong>$3.06 a bowl</strong> for what a restaurant charges $14 for.</p>'
    upsell_html = '<p>$3.06 a bowl.</p>'
    head = [pscustomobject]@{ description = 'A 620 calorie bowl with 41 g protein.'; recipeIngredient = @('3.75 cups dry rice') }
    ingredients_display = @('<strong>Rice (Member''s Mark):</strong> 3.75 cups dry (700 g)', '<strong>Fresh Cilantro:</strong> 6.5 cups (105 g)')
    cost_lines = @('Rice, 3.75 cups: ~$1.20.')
    make_it = @('Weigh the pot.', 'Cook the rice.', 'Fold in the cilantro.')
  }
  $r2 = @(Get-SpecContradictions $good $vocabFx)
  $hard2 = @($r2 | Where-Object { $_.cls -ne 'UNUSED' })
  Chk 'CLEAN TWIN a self-consistent spec produces no findings' ($hard2.Count -eq 0) (($hard2 | ForEach-Object { $_.cls + ': ' + $_.why }) -join ' | ')
  Chk 'CLEAN TWIN a comparison price ($14 a restaurant charges) is not stale money' (@($r2 | Where-Object { $_.why -match '14' }).Count -eq 0) (($r2 | ForEach-Object { $_.why }) -join ' | ')

  # ---- UNUSED: the head-noun bug, and the over-forgiving trap that replaces it if you are careless ----
  # Both halves are real catalog shapes. The first two are what made this class 150 findings of noise;
  # the third is the failure a naive token rule would introduce, and is the reason a token only counts
  # when no OTHER ingredient in the recipe shares it.
  $unusedFx = [pscustomobject]@{
    stat = [pscustomobject]@{ cal = 600; protein = 40; cost_ps = '3.00' }
    ingredients_display = @(
      '<strong>Parmesan Cheese (Great Value):</strong> 1 oz (31 g)',
      '<strong>Boneless Skinless Chicken Breast (Member''s Mark):</strong> 5.5 lb (2495 g)',
      '<strong>Rice (Member''s Mark):</strong> 3.75 cups dry (700 g)',
      '<strong>Rice Vinegar (Nakano):</strong> 2 tbsp (30 g)',
      '<strong>Sesame Oil (Kadoya):</strong> 1 tbsp (14 g)')
    make_it = @(
      'Cube the chicken and brown it.',
      'Cook the rice.',
      'Stir in the parmesan and portion it out.')
  }
  $r2b = @(Get-SpecContradictions $unusedFx $null)
  $un = @($r2b | Where-Object { $_.cls -eq 'UNUSED' } | ForEach-Object { $_.why })
  Chk 'CLEAN TWIN "stir in the parmesan" uses Parmesan Cheese (head noun said cheese)' (@($un | Where-Object { $_ -match 'parmesan' }).Count -eq 0) ($un -join ' | ')
  Chk 'CLEAN TWIN "cube the chicken" uses Chicken Breast (head noun said breast)'      (@($un | Where-Object { $_ -match 'chicken breast' }).Count -eq 0) ($un -join ' | ')
  Chk 'MUST FIRE  UNUSED     rice vinegar is bought and only "rice" is cooked'         (@($un | Where-Object { $_ -match 'rice vinegar' }).Count -eq 1) ($un -join ' | ')
  Chk 'MUST FIRE  UNUSED     sesame oil is bought and never named at all'              (@($un | Where-Object { $_ -match 'sesame oil' }).Count -eq 1) ($un -join ' | ')
  Chk 'CLEAN TWIN plain Rice itself is not reported - the step cooks it'               (@($un | Where-Object { $_ -match "^'rice'" }).Count -eq 0) ($un -join ' | ')

  # ---- singular/plural, added 2026-08-16 after a live recipe read as never using its tomatoes ----
  $pluralFx = [pscustomobject]@{
    stat = [pscustomobject]@{ cal = 500; protein = 30; cost_ps = '2.00' }
    ingredients_display = @(
      '<strong>Cherry Tomatoes (generic):</strong> 1 cup (149 g)',
      '<strong>Boneless Skinless Chicken Breast (Member''s Mark):</strong> 2 lb (907 g)',
      '<strong>Sesame Oil (Kadoya):</strong> 1 tbsp (14 g)')
    make_it = @('Dice the tomato and set it aside.', 'Grill the chicken.')
  }
  $rp = @(Get-SpecContradictions $pluralFx $null)
  $unp = @($rp | Where-Object { $_.cls -eq 'UNUSED' } | ForEach-Object { $_.why })
  Chk 'MUST FIRE  singular "tomato" in a step USES plural "Cherry Tomatoes" (the live false positive)' (@($unp | Where-Object { $_ -match 'tomato' }).Count -eq 0) ($unp -join ' | ')
  Chk 'CLEAN TWIN a genuinely unused ingredient is STILL caught alongside it'                          (@($unp | Where-Object { $_ -match 'sesame oil' }).Count -eq 1) ($unp -join ' | ')
  Chk 'MUST FIRE  plural matching does NOT forgive "rice" via "riced" (the simile trap)'               ((Get-PluralPattern 'rice') -notmatch 'd') (Get-PluralPattern 'rice')
  Chk 'CLEAN TWIN a word ending in ss is not treated as a plural (grass, hummus)'                      ((Get-PluralPattern 'hummus') -eq [regex]::Escape('hummus')) (Get-PluralPattern 'hummus')

  # ---- PHANTOM: the founding case and its real twin -----------------------------------------------
  # FROZEN FIXTURE - the ingredient list and steps of slow-cooker-dr-pepper-pulled-pork-bowls as they
  # shipped: seven lines, not one of them a soda, and a step that pours one. Its CLEAN TWIN is a real
  # recipe too - slow-cooker-root-beer-pulled-pork-bowls, the same braise built the same way, which does
  # buy the bottle. The pair is the whole point of the class: identical prose, opposite verdicts, and
  # nothing but the ingredient list to tell them apart.
  $phantomBad = [pscustomobject]@{
    stat = [pscustomobject]@{ cal = 557; protein = 56; cost_ps = '2.38' }
    ingredients_display = @(
      '<strong>Pork Loin:</strong> 8 lb (3400 g)', '<strong>Potato (generic):</strong> 9 lb (3700 g)',
      '<strong>BBQ Sauce (Sugar Free) (Sweet Baby Ray''s):</strong> 1 bottle (360 g)',
      '<strong>Salt (Morton):</strong> for rub (8 g)', '<strong>Black Pepper (Great Value):</strong> for rub (3 g)')
    scaler = [pscustomobject]@{ ing = @(
      [pscustomobject]@{ item = 'Pork Loin'; grams = 3400 }, [pscustomobject]@{ item = 'Potato'; grams = 3700 },
      [pscustomobject]@{ item = 'BBQ Sauce (Sugar Free)'; grams = 360 },
      [pscustomobject]@{ item = 'Salt'; grams = 8 }, [pscustomobject]@{ item = 'Black Pepper'; grams = 3 }) }
    make_it = @(
      'Rub the pork loin all over with the salt and black pepper, then set it in the slow cooker.',
      'Pour the zero-sugar soda over the pork until it is about halfway up the sides.',
      'Stir in the BBQ sauce and let it warm through for a few minutes.',
      'Serve over cooked potatoes and divide into containers.')
  }
  $r3 = @(Get-SpecContradictions $phantomBad $vocabFx)
  $ph3 = @($r3 | Where-Object { $_.cls -eq 'PHANTOM' })
  Chk 'MUST FIRE  PHANTOM     step 2 pours a soda the recipe never buys' ((@($ph3 | Where-Object { $_.why -match 'Zero-Sugar Soda' }).Count -eq 1)) (($ph3 | ForEach-Object { $_.why }) -join ' | ')
  Chk 'MUST FIRE  PHANTOM     and it is the ONLY phantom in that spec' ($ph3.Count -eq 1) (($ph3 | ForEach-Object { $_.why }) -join ' | ')

  # THE TWIN. Same braise, same sentences, one extra line in the list - and the class must go silent.
  $phantomGood = [pscustomobject]@{
    stat = [pscustomobject]@{ cal = 560; protein = 59; cost_ps = '3.93' }
    ingredients_display = @(
      '<strong>Pork Loin:</strong> 8 lb (3400 g)', '<strong>Potato (generic):</strong> 10 lb (4300 g)',
      '<strong>BBQ Sauce (Sugar Free) (Sweet Baby Ray''s):</strong> 1 bottle (300 g)',
      '<strong>Zero-Sugar Soda (generic):</strong> 1 1/2 cups (355 g)',
      '<strong>Salt (Morton):</strong> 1 teaspoon (8 g)', '<strong>Black Pepper (Great Value):</strong> 1 teaspoon (4 g)')
    scaler = [pscustomobject]@{ ing = @(
      [pscustomobject]@{ item = 'Pork Loin'; grams = 3400 }, [pscustomobject]@{ item = 'Potato'; grams = 4300 },
      [pscustomobject]@{ item = 'BBQ Sauce (Sugar Free)'; grams = 300 },
      [pscustomobject]@{ item = 'Zero-Sugar Soda'; grams = 355 },
      [pscustomobject]@{ item = 'Salt'; grams = 8 }, [pscustomobject]@{ item = 'Black Pepper'; grams = 4 }) }
    make_it = @(
      'Rub the pork loin all over with the salt and black pepper, then set it in the slow cooker.',
      'Pour the zero-sugar soda over the pork until it is about halfway up the sides.',
      'Stir in the BBQ sauce and let it warm through for a few minutes.',
      'Serve over cooked potatoes and divide into containers.')
  }
  $ph4 = @(Get-SpecContradictions $phantomGood $vocabFx | Where-Object { $_.cls -eq 'PHANTOM' })
  Chk 'CLEAN TWIN the same steps over a list that DOES buy the soda are silent' ($ph4.Count -eq 0) (($ph4 | ForEach-Object { $_.why }) -join ' | ')

  # FROZEN FIXTURE (2026-08-08): the CONSTITUENT rule's founding case - baked-ziti's make_it says the
  # turkey "soaks up the tomato flavor", and the marinara IS the tomato. This sat as the live board's one
  # PHANTOM for weeks because the matcher had no idea marinara contains tomatoes. Its MUST-FIRE twin buys
  # nothing tomato-derived, so the same sentence stays a real phantom - the rule must forgive the
  # constituent, not the word.
  $phantomConstituent = [pscustomobject]@{
    stat = [pscustomobject]@{ cal = 590; protein = 45; cost_ps = '2.61' }
    ingredients_display = @('<strong>Ziti Pasta:</strong> 2 lb (908 g)', '<strong>Marinara Sauce:</strong> 2 jars (1320 g)')
    scaler = [pscustomobject]@{ ing = @([pscustomobject]@{ item = 'Ziti Pasta'; grams = 908 }, [pscustomobject]@{ item = 'Marinara Sauce'; grams = 1320 }) }
    make_it = @('Pour in the marinara sauce and simmer 5 minutes so the turkey soaks up the tomato flavor.')
  }
  $ph5 = @(Get-SpecContradictions $phantomConstituent $vocabFx | Where-Object { $_.cls -eq 'PHANTOM' })
  Chk 'CLEAN TWIN "tomato flavor" is covered by the bought MARINARA (constituent rule)' ($ph5.Count -eq 0) (($ph5 | ForEach-Object { $_.why }) -join ' | ')
  $phantomNoTomato = [pscustomobject]@{
    stat = [pscustomobject]@{ cal = 590; protein = 45; cost_ps = '2.61' }
    ingredients_display = @('<strong>Ziti Pasta:</strong> 2 lb (908 g)', '<strong>Alfredo Sauce:</strong> 2 jars (1320 g)')
    scaler = [pscustomobject]@{ ing = @([pscustomobject]@{ item = 'Ziti Pasta'; grams = 908 }, [pscustomobject]@{ item = 'Alfredo Sauce'; grams = 1320 }) }
    make_it = @('Stir in the diced tomato before serving.')
  }
  $ph6 = @(Get-SpecContradictions $phantomNoTomato $vocabFx | Where-Object { $_.cls -eq 'PHANTOM' -and $_.why -match 'omato' })
  Chk 'MUST FIRE  PHANTOM     tomato over an ALFREDO recipe is still a real phantom' ($ph6.Count -ge 1) 'constituent rule over-forgave'

  # FROZEN FIXTURE (2026-08-28): the constituent rule's SECOND live case, and the reason its keys became
  # phrases. beef-rendang-rice-bowls buys four cans of coconut milk and step 7 says the beef 'starts frying
  # in the coconut oil that separates out' - the oil is what the milk breaks into, not a fifteenth thing to
  # shop for. The finding appeared on 2026-08-28 with no change to the recipe: db\ingredients.json gained a
  # Coconut Oil row that day (f3911bff), and this class can only see a phrase the vocabulary knows.
  $phantomCoconut = [pscustomobject]@{
    stat = [pscustomobject]@{ cal = 640; protein = 44; cost_ps = '3.11' }
    ingredients_display = @('<strong>Beef Chuck Roast:</strong> 4.75 lb (2117 g)', '<strong>Coconut Milk (Thai Kitchen):</strong> 4 cans (1582 g)')
    scaler = [pscustomobject]@{ ing = @([pscustomobject]@{ item = 'Beef Chuck Roast'; grams = 2117 }, [pscustomobject]@{ item = 'Coconut Milk'; grams = 1582 }) }
    make_it = @('The liquid reduces, then breaks, and the beef starts frying in the coconut oil that separates out.')
  }
  $ph7 = @(Get-SpecContradictions $phantomCoconut $vocabFx | Where-Object { $_.cls -eq 'PHANTOM' })
  Chk 'CLEAN TWIN coconut oil is covered by the bought COCONUT MILK (constituent rule)' ($ph7.Count -eq 0) (($ph7 | ForEach-Object { $_.why }) -join ' | ')
  # THE OVER-FORGIVENESS TWIN. Keyed on the bare token 'coconut' with the bare value 'oil', the entry above
  # would forgive ANY oil in a recipe holding a can of coconut milk, because 'oil' is a token of Olive Oil
  # too. Same spec, same bought line, a different oil the recipe does not buy - it must still fire.
  $phantomCoconutOlive = [pscustomobject]@{
    stat = [pscustomobject]@{ cal = 640; protein = 44; cost_ps = '3.11' }
    ingredients_display = @('<strong>Beef Chuck Roast:</strong> 4.75 lb (2117 g)', '<strong>Coconut Milk (Thai Kitchen):</strong> 4 cans (1582 g)')
    scaler = [pscustomobject]@{ ing = @([pscustomobject]@{ item = 'Beef Chuck Roast'; grams = 2117 }, [pscustomobject]@{ item = 'Coconut Milk'; grams = 1582 }) }
    make_it = @('Finish the sauce with a spoonful of olive oil before serving.')
  }
  $ph8 = @(Get-SpecContradictions $phantomCoconutOlive $vocabFx | Where-Object { $_.cls -eq 'PHANTOM' -and $_.why -match 'Olive Oil' })
  Chk 'MUST FIRE  PHANTOM     olive oil over a coconut-milk recipe is still a real phantom' ($ph8.Count -ge 1) 'coconut constituent entry over-forgave every oil'

  # THE SAME-COMMODITY RULE (2026-08-27). Four LIVE specs - beef-birria-burrito, beef-burrito-tex-mex,
  # salsa-verde-chicken-burrito, turkey-florentine-rice-bake - say "shredded cheese" in a step while their
  # ingredient line reads "Mexican Cheese Blend". Both names carry the bid `shredded-cheese`, so the reader
  # bought exactly what the step asks for and the dish is makeable as shopped. The findings appeared the
  # day a vocabulary row named "Shredded Cheese" was added, because this class is vocabulary-driven: the
  # phrase only then became a food the matcher could see. Token coverage cannot close it - "Mexican Cheese
  # Blend" and "Shredded Cheese" share no word - and a red shared gate blocks every wave, including waves
  # containing none of these four recipes.
  $bidFx = @{ 'Shredded Cheese' = 'shredded-cheese'; 'Mexican Cheese Blend' = 'shredded-cheese'
              'Olives' = 'olives'; 'Rice' = 'rice' }
  $vocabBid = New-FoodVocabulary @('Shredded Cheese', 'Mexican Cheese Blend', 'Olives', 'Rice')
  $sameCommodity = [pscustomobject]@{
    stat = [pscustomobject]@{ cal = 590; protein = 45; cost_ps = '2.61' }
    ingredients_display = @('<strong>Mexican Cheese Blend:</strong> 9 oz (252 g)')
    scaler = [pscustomobject]@{ ing = @(
      [pscustomobject]@{ item = 'Mexican Cheese Blend'; canon = 'Mexican Cheese Blend'; grams = 252; bid = 'shredded-cheese' }) }
    make_it = @('Scatter the shredded cheese over the top and bake until it melts.')
  }
  $sc1 = @(Get-SpecContradictions $sameCommodity $vocabBid $null $bidFx | Where-Object { $_.cls -eq 'PHANTOM' })
  Chk 'MUST FIRE  PHANTOM     a step saying "shredded cheese" over a bought Mexican Cheese Blend is NOT a phantom - same commodity, one purchase' `
    ($sc1.Count -eq 0) (($sc1 | ForEach-Object { $_.why }) -join ' | ')
  # ...and the rule must not become a way to forgive a food nobody bought.
  $sc2 = [pscustomobject]@{
    stat = [pscustomobject]@{ cal = 590; protein = 45; cost_ps = '2.61' }
    ingredients_display = @('<strong>Rice:</strong> 2 lb (908 g)')
    scaler = [pscustomobject]@{ ing = @(
      [pscustomobject]@{ item = 'Rice'; canon = 'Rice'; grams = 908; bid = 'rice' }) }
    make_it = @('Scatter the shredded cheese over the top and bake until it melts.')
  }
  $scB = @(Get-SpecContradictions $sc2 $vocabBid $null $bidFx | Where-Object { $_.cls -eq 'PHANTOM' })
  Chk 'CLEAN TWIN a step naming a cheese the recipe does NOT buy is still a phantom - no line carries that bid' `
    ($scB.Count -ge 1) (($scB | ForEach-Object { $_.why }) -join ' | ')
  # ...and with no bid map at all the class behaves exactly as it did before (repair-spec-contradictions
  # reads one spec in isolation and passes none).
  $scC = @(Get-SpecContradictions $sameCommodity $vocabBid | Where-Object { $_.cls -eq 'PHANTOM' })
  Chk 'CLEAN TWIN with NO bid map the rule is inert, not accidentally on - a 2-arg caller is unchanged' `
    ($scC.Count -ge 1) (($scC | ForEach-Object { $_.why }) -join ' | ')

  # THE FOUR NOISE RULES. Each line is a false positive this matcher produced against the live catalogue
  # before the rule above it existed; without them the class gives 555 hits and gets switched off.
  $noise = [pscustomobject]@{
    stat = [pscustomobject]@{ cal = 500; protein = 40; cost_ps = '2.00' }
    ingredients_display = @(
      '<strong>Brown Sugar:</strong> 7 tbsp (94 g)', '<strong>Olive Oil:</strong> 2 tbsp (27 g)',
      '<strong>Sweet Potatoes:</strong> 3 lb (1360 g)', '<strong>Frozen Green Peas:</strong> 1 lb (454 g)',
      '<strong>Cheddar Cheese, Shredded:</strong> 8 oz (227 g)', '<strong>Rice:</strong> 3.75 cups (700 g)',
      '<strong>BBQ Sauce (Sugar Free):</strong> 1 bottle (300 g)', '<strong>Tomatillos:</strong> 1 lb (454 g)')
    scaler = [pscustomobject]@{ ing = @(
      [pscustomobject]@{ item = 'Brown Sugar'; grams = 94 }, [pscustomobject]@{ item = 'Olive Oil'; grams = 27 },
      [pscustomobject]@{ item = 'Sweet Potatoes'; grams = 1360 }, [pscustomobject]@{ item = 'Frozen Green Peas'; grams = 454 },
      [pscustomobject]@{ item = 'Cheddar Cheese, Shredded'; grams = 227 }, [pscustomobject]@{ item = 'Rice'; grams = 700 },
      [pscustomobject]@{ item = 'BBQ Sauce (Sugar Free)'; grams = 300 }, [pscustomobject]@{ item = 'Tomatillos'; grams = 454 }) }
    make_it = @(
      'Stir the brown sugar into the olive oil.',                       # longest match wins: not Sugar, not Olives
      'Peel and cube the sweet potatoes, then scatter the frozen peas.', # plural stemming: not Potato, not a missing Peas
      'Scatter on most of the cheddar cheese.',                          # the comma reading: Cheddar Cheese, Shredded
      'Add the cooked rice so it fries up instead of turning mushy.',    # surface not stem: "fries" the verb is not Fries
      'Stir in the sugar-free BBQ sauce until every strand is coated.',  # X-free is the absence of X
      'Blend the tomatillos with the garlic and most of the cilantro into a rough green salsa.', # made, verb a clause away
      'Watch it, because honey burns faster than sugar does.',           # a comparison is not an instruction
      'Splash in the rice vinegar at the end.')                          # an unknown compound is not its head word
  }
  $ph5 = @(Get-SpecContradictions $noise $vocabFx | Where-Object { $_.cls -eq 'PHANTOM' })
  Chk 'CLEAN TWIN the eight live false-positive shapes all stay silent' ($ph5.Count -eq 0) (($ph5 | ForEach-Object { $_.why }) -join ' | ')

  # ---- PHANTOM composite-rider (2026-08-24): a food named only in a buy string AFTER the colon IS bought --
  # FROZEN FIXTURE - slow-cooker-pork-loin-roast-or-pork-shoulder and stuffed-chicken-breast reached the gate
  # carrying COMPOSITE buy lines: one costed row, two foods ("3 1/2 teaspoons EACH paprika and dried thyme",
  # "1 3/4 teaspoons EACH garlic powder and onion powder"). Until $own read the WHOLE display line and the
  # scaler buy string - not just the display key before the colon - the rider (dried thyme, onion powder)
  # looked unbought and fired a phantom: 5 false findings across two slugs. The rider is genuinely bought and
  # on the reader's list, so the class must go silent on it. Its MUST-FIRE twin is IN THE SAME SPEC: a
  # zero-sugar soda that appears in no line and no buy string still fires, so the widening did not go slack.
  $phantomRider = [pscustomobject]@{
    stat = [pscustomobject]@{ cal = 600; protein = 55; cost_ps = '1.70' }
    ingredients_display = @(
      '<strong>Paprika:</strong> 3 1/2 teaspoons EACH paprika and dried thyme (8 g)',
      '<strong>Garlic Powder:</strong> 1 3/4 teaspoons EACH garlic powder and onion powder (5 g)',
      '<strong>Pork Loin:</strong> 8 lb boneless pork loin roast, trimmed (3400 g)')
    scaler = [pscustomobject]@{ ing = @(
      [pscustomobject]@{ item = 'Paprika'; canon = 'Paprika'; buy = '3 1/2 teaspoons EACH paprika and dried thyme'; grams = 8 },
      [pscustomobject]@{ item = 'Garlic Powder'; canon = 'Garlic Powder'; buy = '1 3/4 teaspoons EACH garlic powder and onion powder'; grams = 5 },
      [pscustomobject]@{ item = 'Pork Loin'; canon = 'Pork Loin'; buy = '8 lb boneless pork loin roast, trimmed'; grams = 3400 }) }
    make_it = @(
      'Mix the paprika, dried thyme, garlic powder, and onion powder into a rub and pat it onto the pork loin.',
      'Then pour the zero-sugar soda over the pork until it is halfway up the sides.')
  }
  $rider = @(Get-SpecContradictions $phantomRider $vocabFx | Where-Object { $_.cls -eq 'PHANTOM' })
  Chk 'CLEAN TWIN composite rider "dried thyme" (rides the paprika buy line) is not a phantom' (@($rider | Where-Object { $_.why -match 'Dried Thyme' }).Count -eq 0) (($rider | ForEach-Object { $_.why }) -join ' | ')
  Chk 'CLEAN TWIN composite rider "onion powder" (rides the garlic-powder buy line) is not a phantom' (@($rider | Where-Object { $_.why -match 'Onion Powder' }).Count -eq 0) (($rider | ForEach-Object { $_.why }) -join ' | ')
  Chk 'MUST FIRE  PHANTOM     a zero-sugar soda in the SAME spec (no line, no buy string) still fires' (@($rider | Where-Object { $_.why -match 'Zero-Sugar Soda' }).Count -eq 1) (($rider | ForEach-Object { $_.why }) -join ' | ')

  # ---- BUY-COVERAGE -------------------------------------------------------------------------------
  # FROZEN FIXTURE (2026-08-15) - country-captain-chicken exactly as it shipped. This spec is the founding
  # case BECAUSE this audit passed it: cost_lines called the raisin box a several-batch box while
  # shop_smart, in the same file, said it was not. Both sentences are below, unedited, so the fixture
  # fails the day the class stops reading one of them.
  # FROZEN PACKAGE MAP - never read from db\ingredients.json, per the guard-fixture rule. A fixture that
  # reads the live catalogue stops testing the bug the day someone redefines a package.
  $pkgFx = @{
    'Golden Raisins' = @{ g = 320;  label = 'box' }          # 170 g used  -> 1.88 batches
    'Chicken Broth'  = @{ g = 907;  label = '32oz carton' }  # 532 g used  -> 1.70 batches
    'Soy Sauce'      = @{ g = 444;  label = 'bottle' }       #  30 g used  -> 14.8 batches, genuinely several
    'Diced Green Chiles' = @{ g = 113; label = '4oz can' }   # 396 g used  -> needs FOUR cans
  }
  $buyBad = [pscustomobject]@{
    stat = [pscustomobject]@{ cal = 520; protein = 44; cost_ps = '2.56' }
    scaler = [pscustomobject]@{ ing = @(
      [pscustomobject]@{ item = 'Golden Raisins'; grams = 170 },
      [pscustomobject]@{ item = 'Chicken Broth';  grams = 532 },
      [pscustomobject]@{ item = 'Soy Sauce';      grams = 30 }) }
    cost_lines = @(
      'Golden Raisins, 1.25 cups: ~$2.64. <strong>Buy 1 (lasts several batches).</strong>',
      'Chicken Broth, 2.25 cups: ~$0.82. <strong>Buy 1 (lasts several batches).</strong>',
      'Soy Sauce, 2 tbsp: ~$0.18. <strong>Buy 1 (lasts several batches).</strong>')
    shop_smart = @('One box of golden raisins covers this batch and most of a second. Not several batches, but the box is not a one-and-done either.')
  }
  $bc1 = @(Get-BuyCoverageFindings $buyBad $pkgFx)
  Chk 'MUST FIRE  BUY-COVERAGE raisin box: 1.88 batches is not "several"' (@($bc1 | Where-Object { $_.why -match 'Golden Raisins' }).Count -eq 1) (($bc1 | ForEach-Object { $_.why }) -join ' | ')
  Chk 'MUST FIRE  BUY-COVERAGE broth carton: 1.70 batches is not "several"' (@($bc1 | Where-Object { $_.why -match 'Chicken Broth' }).Count -eq 1) (($bc1 | ForEach-Object { $_.why }) -join ' | ')
  Chk 'CLEAN TWIN a 14.8-batch soy bottle in the SAME spec stays silent' (@($bc1 | Where-Object { $_.why -match 'Soy Sauce' }).Count -eq 0) (($bc1 | ForEach-Object { $_.why }) -join ' | ')

  # MUST FIRE - green-chile-ground-turkey-skillet: the line states 3.5 cans and instructs Buy 1. This is
  # the shape that is a wrong INSTRUCTION rather than wrong wording, so it must be reported even though
  # the words in the parenthetical are the same ones a >= 3 batch pack would legitimately carry.
  $buyCount = [pscustomobject]@{
    stat = [pscustomobject]@{ cal = 500; protein = 40; cost_ps = '2.00' }
    scaler = [pscustomobject]@{ ing = @([pscustomobject]@{ item = 'Diced Green Chiles'; grams = 396 }) }
    cost_lines = @('Diced Green Chiles, 3.5 cans: ~$5.13. <strong>Buy 1 (lasts several batches).</strong>')
  }
  $bc2 = @(Get-BuyCoverageFindings $buyCount $pkgFx)
  Chk 'MUST FIRE  BUY-COVERAGE 3.5 cans but "Buy 1"' ($bc2.Count -eq 1 -and $bc2[0].why -match 'needs 4 4oz can') (($bc2 | ForEach-Object { $_.why }) -join ' | ')

  # CLEAN TWIN - the corrected spec. Every line now says what its package actually covers, and the class
  # must go completely silent. Without this twin the class could "pass" by firing on everything.
  $buyGood = [pscustomobject]@{
    stat = [pscustomobject]@{ cal = 520; protein = 44; cost_ps = '2.56' }
    scaler = [pscustomobject]@{ ing = @(
      [pscustomobject]@{ item = 'Golden Raisins'; grams = 170 },
      [pscustomobject]@{ item = 'Chicken Broth';  grams = 532 },
      [pscustomobject]@{ item = 'Soy Sauce';      grams = 30 }) }
    cost_lines = @(
      'Golden Raisins, 1.25 cups: ~$2.64. <strong>Buy 1 (covers about two batches).</strong>',
      'Chicken Broth, 2.25 cups: ~$0.82. <strong>Buy 1 (covers this batch with some left over).</strong>',
      'Soy Sauce, 2 tbsp: ~$0.18. <strong>Buy 1 (lasts several batches).</strong>')
  }
  $bc3 = @(Get-BuyCoverageFindings $buyGood $pkgFx)
  Chk 'CLEAN TWIN the repaired spec is silent on every line' ($bc3.Count -eq 0) (($bc3 | ForEach-Object { $_.why }) -join ' | ')

  # CLEAN TWIN - no package map (repair-spec-contradictions reads one spec in isolation). The class must
  # skip, not guess, exactly as PHANTOM does without a vocabulary.
  $bc4 = @(Get-BuyCoverageFindings $buyBad $null)
  Chk 'CLEAN TWIN no package map - the class skips rather than guesses' ($bc4.Count -eq 0) (($bc4 | ForEach-Object { $_.why }) -join ' | ')
  $bc5 = @(Get-SpecContradictions $buyBad $vocabFx | Where-Object { $_.cls -eq 'BUY-COVERAGE' })
  Chk 'CLEAN TWIN a 2-arg caller gets no BUY-COVERAGE findings' ($bc5.Count -eq 0) (($bc5 | ForEach-Object { $_.why }) -join ' | ')

  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

$specs = Get-SpecSet $mp ([bool]$IncludeArchive)

# Parse once, then read twice. PHANTOM needs the food lexicon of the WHOLE catalogue before it can judge
# any single spec: db\ingredients.json is the canonical store but a spec may name an ingredient it has not
# adopted yet, and every such gap becomes a phantom in the recipe that legitimately buys it.
$parsed = New-Object System.Collections.Generic.List[object]
foreach ($s in $specs) {
  $spec = $null
  try { $spec = Get-Content $s.path -Raw | ConvertFrom-Json } catch { continue }
  if (-not $spec.stat) { continue }
  $parsed.Add([pscustomobject]@{ run = $s.run; slug = $s.slug; spec = $spec })
}
$names = New-Object System.Collections.Generic.List[string]
# BUY-COVERAGE needs the PACKAGE a bulk item is sold in, which lives only here. Built in the same pass as
# the vocabulary so the file is read once. Only bulk rows with a real pantry package can be judged: a row
# with no package definition has no ratio to state, and the class stays quiet on it.
$pkgMap = @{}
$bidMap = @{}   # food name -> priced commodity id, for the PHANTOM same-commodity rule
$ingDb = Join-Path $mp 'db\ingredients.json'
if (Test-Path $ingDb) {
  foreach ($r in (Get-Content $ingDb -Raw | ConvertFrom-Json)) {
    $n = [string]$r.item
    if (-not $n -or $n -match '^_') { continue }
    $names.Add($n)
    if ($r.PSObject.Properties.Name -contains 'pantry_pkg_g' -and [double]$r.pantry_pkg_g -gt 0) {
      $pkgMap[$n] = @{ g = [double]$r.pantry_pkg_g; label = [string]$r.pantry_pkg_label }
    }
    if ($r.PSObject.Properties.Name -contains 'bid' -and $r.bid) { $bidMap[$n] = [string]$r.bid }
  }
}
foreach ($p in $parsed) {
  foreach ($sc in @($p.spec.scaler.ing)) {
    foreach ($v in @([string]$sc.item, [string]$sc.canon)) { if ($v) { $names.Add($v) } }
  }
}
$vocab = New-FoodVocabulary $names.ToArray()

$byClass = @{}
$rows = New-Object System.Collections.Generic.List[object]
foreach ($p in $parsed) {
  foreach ($f in (Get-SpecContradictions $p.spec $vocab $pkgMap $bidMap)) {
    $byClass[$f.cls] = 1 + [int]$byClass[$f.cls]
    $rows.Add([pscustomobject]@{ run = $p.run; slug = $p.slug; cls = $f.cls; why = $f.why })
  }
}
$outPath = Join-Path $mp 'out\spec-contradictions.json'
New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
@{ generated = 'see git'; specs = $specs.Count; by_class = $byClass; findings = @($rows.ToArray()) } | ConvertTo-Json -Depth 5 | Set-Content $outPath -Encoding UTF8

if (-not $Quiet) {
  Write-Output ("spec contradictions: {0} finding(s) across {1} spec(s)" -f $rows.Count, $specs.Count)
  foreach ($k in ($byClass.Keys | Sort-Object)) { Write-Output ("  {0,-12} {1}" -f $k, $byClass[$k]) }
  foreach ($k in @('STAT-PROSE','UNMEASURABLE-QTY','STALE-MONEY','ABSURD-UNIT','HEAD-QTY','PHANTOM','BUY-COVERAGE')) {
    $r = @($rows | Where-Object { $_.cls -eq $k })
    if ($r.Count -eq 0) { continue }
    Write-Output ("  --- $k")
    foreach ($x in ($r | Select-Object -First 12)) { Write-Output ("      {0,-46} {1}" -f $x.slug, $x.why) }
    if ($r.Count -gt 12) { Write-Output ("      ... and " + ($r.Count - 12) + " more (full list in out\spec-contradictions.json)") }
  }
}

$basePath = Join-Path $mp 'out\spec-contradictions-baseline.json'
if ($Baseline) {
  $nb = [ordered]@{}
  foreach ($k in ($byClass.Keys | Sort-Object)) { $nb[$k] = [int]$byClass[$k] }
  $nb | ConvertTo-Json -Depth 3 | Set-Content $basePath -Encoding UTF8
  Write-Output ('baseline written: ' + (($byClass.Keys | Sort-Object | ForEach-Object { "$_=$($byClass[$_])" }) -join ' '))
  Write-GuardComplete -Name 'spec-contradictions'; exit 0
}
$base = @{}
if (Test-Path $basePath) { try { $bd = Get-Content $basePath -Raw | ConvertFrom-Json; foreach ($p in $bd.PSObject.Properties) { $base[$p.Name] = [int]$p.Value } } catch {} }
$worse = @()
foreach ($k in @('STAT-PROSE','UNMEASURABLE-QTY','STALE-MONEY','ABSURD-UNIT','HEAD-QTY','PHANTOM','BUY-COVERAGE')) {
  $now = [int]$byClass[$k]
  $was = if ($base.ContainsKey($k)) { [int]$base[$k] } else { 0 }
  if ($now -gt $was) { $worse += ("{0}: {1} now, baseline {2}" -f $k, $now, $was) }
}
if ($worse.Count -gt 0) {
  Write-Output ('spec-contradictions FAIL - a class got WORSE than out\spec-contradictions-baseline.json: ' + ($worse -join ' | '))
  Write-Output '  A spec that states the same fact twice and disagrees with itself is wrong no matter what the source recipe says - one of the two numbers is on a live card.'
  Write-GuardComplete -Name 'spec-contradictions'; exit 1
}
Write-GuardComplete -Name 'spec-contradictions'; exit 0



