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
    'Tomato', 'Marinara Sauce'   # the constituent-rule pair - without Tomato in this vocab both its fixtures are vacuous
  )
  $r = @(Get-SpecContradictions $bad $vocabFx)
  $cls = @($r | ForEach-Object { $_.cls })
  Chk 'MUST FIRE  STAT-PROSE  499 cal in a paragraph that also says 541' (($cls -contains 'STAT-PROSE') -and (@($r | Where-Object { $_.why -match '499' }).Count -eq 1)) (($r | ForEach-Object { $_.why }) -join ' | ')
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
$ingDb = Join-Path $mp 'db\ingredients.json'
if (Test-Path $ingDb) {
  foreach ($r in (Get-Content $ingDb -Raw | ConvertFrom-Json)) {
    $n = [string]$r.item
    if ($n -and $n -notmatch '^_') { $names.Add($n) }
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
  foreach ($f in (Get-SpecContradictions $p.spec $vocab)) {
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
  foreach ($k in @('STAT-PROSE','UNMEASURABLE-QTY','STALE-MONEY','ABSURD-UNIT','HEAD-QTY','PHANTOM')) {
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
foreach ($k in @('STAT-PROSE','UNMEASURABLE-QTY','STALE-MONEY','ABSURD-UNIT','HEAD-QTY','PHANTOM')) {
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


