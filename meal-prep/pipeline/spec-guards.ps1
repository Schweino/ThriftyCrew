# spec-guards.ps1 (pipeline, run-agnostic - promoted 2026-07-27 from archive\r300; every guard
# UNCHANGED, hardcoded r300 paths became parameters defaulting under -RunDir).
#
# spec-guards.ps1 (R300) - Validates spec files and enforces EVERY invariant before any card build.
# A spec that fails ANY guard is listed and NOT marked ready. Never ship unvalidated.
#
# TWO MODES:
#   -Skeleton   structure + numbers only. Prose files are not required (they land later at
#               specs\prose\prose-<slug>.json). Writes specs-skeleton-ok.txt.
#   (default)   full mode: merges prose into the spec, re-anchors prose numbers to the current stat,
#               then runs the skeleton guards PLUS every prose guard. Writes specs-ready.txt.
#
# PORT OF r100\spec-guards.ps1. Deltas:
#   * skeleton mode (r100 had none - prose and structure were validated in one pass)
#   * printed cost lines are re-parsed and summed: contributions must equal the printed TRUE cost
#     EXACTLY, utilizations must equal the printed BATCH cost exactly (r100 only spot-checked the
#     two total lines; the per-line sum was trusted from the builder)
#   * stat is checked against recipes-computed.json per-serving as well as against a DB recompute
#   * protein floor (>=25 g), display-line format lint, scaler/grams alignment, credit-line contents
#   * em/en dash sweep covers EVERY string in the spec, not just the prose fields
#   * forbidden_prose_terms (e.g. never say "cornstarch" on the japchae card) enforced in prose
#     AND in the machine-built display/cost lines
#   * post-sync verification: after the auto numeric sync, any remaining $D.DD / calorie / protein
#     figure in prose must equal the current stat (r100 synced but never re-verified)
#   -WriteReady  full mode only: actually emit specs-ready.txt, the list publish-r300 -All consumes.
#                Without it a full run writes specs-full-ok.txt instead, so validation passes cannot
#                arm a publish before the stage-6 auditor GO.
param([Parameter(Mandatory=$true)][string]$RunDir,
      [string]$SpecsDir,       # default <RunDir>\specs
      [string]$ProseDir,       # default <SpecsDir>\prose
      [string]$ComputedFile,   # default <RunDir>\recipes-computed.json
      [string]$FoodDbFile,     # default <meal-prep>\food-macros-db.json
      [string]$RecipesDbFile,  # default <meal-prep>\recipes-db.json
      [string]$RunSlugsFile,   # default <RunDir>\run-slugs.txt (optional; post-publish regen exemption)
      [string]$OutDir,         # default <RunDir> (where the ok/ready lists are written)
      [string]$ManifestFile,   # default <meal-prep>\pipeline\v2-perserving.json (everyday_ps basis)
      [switch]$Skeleton,[switch]$WriteReady)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path     # ...\meal-prep\pipeline
$mp = Split-Path -Parent $here
if(-not (Test-Path $RunDir)){ throw ("RunDir not found: $RunDir") }
if(-not $SpecsDir){      $SpecsDir      = Join-Path $RunDir 'specs' }
if(-not $ProseDir){      $ProseDir      = Join-Path $SpecsDir 'prose' }
if(-not $ComputedFile){  $ComputedFile  = Join-Path $RunDir 'recipes-computed.json' }
if(-not $FoodDbFile){    $FoodDbFile    = Join-Path $mp 'food-macros-db.json' }
if(-not $RecipesDbFile){ $RecipesDbFile = Join-Path $mp 'recipes-db.json' }
if(-not $RunSlugsFile){  $RunSlugsFile  = Join-Path $RunDir 'run-slugs.txt' }
if(-not $OutDir){        $OutDir        = $RunDir }
if(-not $ManifestFile){  $ManifestFile  = Join-Path $here 'v2-perserving.json' }
. (Join-Path $here 'guard-lib.ps1')   # shared, reusable guard predicates (prose-ingredient drift, stale superlative)
# everyday_ps per slug (2026-07-26 cost redesign): stat.cost_ps / head.costPerServing may legitimately
# carry the manifest's everyday whole-package basis instead of cost_batch/14 (see basis check below)
$manPs=@{}
if(Test-Path $ManifestFile){
  foreach($e in (Get-Content $ManifestFile -Raw -Encoding utf8 | ConvertFrom-Json)){
    if($e.PSObject.Properties.Name -contains 'everyday_ps' -and $null -ne $e.everyday_ps){ $manPs[[string]$e.slug]=[double]$e.everyday_ps }
  }
}
$specDir = $SpecsDir
$proseDir = $ProseDir
$db = (Get-Content $FoodDbFile -Raw | ConvertFrom-Json).items
$dbm=@{}; foreach($i in $db){ $dbm[$i.item]=$i }
$computed = Get-Content $ComputedFile -Raw | ConvertFrom-Json
$compIdx=@{}; foreach($r in $computed){ $compIdx[[string]$r.slug]=$r }
# the single recipe genuinely at protein rank #1 - the only one allowed an unscoped batch-primacy claim
$rank1Slug = ($computed | Sort-Object { [double]$_.per_serving.protein_g } -Descending | Select-Object -First 1).slug
$liveSlugs=@{}
foreach($m in [regex]::Matches([IO.File]::ReadAllText($RecipesDbFile), '"slug"\s*:\s*"([^"]+)"')){ $liveSlugs[$m.Groups[1].Value]=1 }
$runSlugs=@{}
$runManifest = $RunSlugsFile
if(Test-Path $runManifest){ foreach($s in (Get-Content $runManifest)){ if($s){ $runSlugs[$s.Trim()]=1 } } }

$WEIGH = 'Weigh your empty mixing pot and write the number down for portioning later.'
$fails=@{}; $ready=@()
function Fail($slug,$msg){ if(-not $fails.ContainsKey($slug)){ $fails[$slug]=@() }; $fails[$slug]+= $msg }

# every string inside an arbitrary spec object (for the dash sweep + forbidden-term sweep)
function Get-Strings($o){
  $out=New-Object System.Collections.Generic.List[string]
  function Walk($v){
    if($null -eq $v){ return }
    if($v -is [string]){ $out.Add($v); return }
    if($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])){ foreach($x in $v){ Walk $x }; return }
    if($v -is [psobject] -and $v.PSObject.Properties.Count -gt 0){ foreach($p in $v.PSObject.Properties){ Walk $p.Value }; return }
  }
  Walk $o
  return $out
}

$specs = Get-ChildItem $specDir -Filter '*.json' | Where-Object { $_.Name -ne '_index.json' }
$slugSeen=@{}
foreach($sf in $specs){
  $spec = $null
  try { $spec = Get-Content $sf.FullName -Raw | ConvertFrom-Json } catch { Fail $sf.BaseName 'spec is not valid JSON'; continue }
  $slug = [string]$spec.slug

  # ---------- identity ----------
  if($slug -ne $sf.BaseName){ Fail $sf.BaseName ("slug '$slug' != filename") }
  if($slugSeen.ContainsKey($slug)){ Fail $slug 'duplicate slug across spec files' }
  $slugSeen[$slug]=1
  # Post-publish regen: this run's own rows are in recipes-db now. run-slugs.txt (the immutable
  # run manifest, written from selected.json) exempts exactly those from the live-collision gate.
  if($liveSlugs.ContainsKey($slug) -and -not $runSlugs.ContainsKey($slug)){ Fail $slug 'slug collides with a LIVE recipe' }
  foreach($k in @('name','slug','cuisine','protein','servings','visibility','source_url','source_site','stat','ingredients_display','cost_lines','credit_html','scaler','head','ingredients_grams')){
    if($spec.PSObject.Properties.Name -notcontains $k){ Fail $slug ("missing field: $k") }
  }
  if($spec.servings -ne 14){ Fail $slug ('servings != 14 (' + $spec.servings + ')') }
  if($spec.visibility -ne 'paid'){ Fail $slug 'visibility != paid' }
  if(-not $spec.name){ Fail $slug 'empty name' }

  # ---------- prose merge (full mode only) ----------
  if(-not $Skeleton){
    $pf = Join-Path $proseDir ("prose-$slug.json")
    if(-not (Test-Path $pf)){ Fail $slug 'missing prose file'; continue }
    $pr = $null
    try { $pr = Get-Content $pf -Raw | ConvertFrom-Json } catch { Fail $slug 'prose not valid JSON'; continue }

    # AUTO-NUMERIC-SYNC: prose is written against a spec generation that may predate a re-cost.
    # Contract: cost_closing/upsell reference ONLY cost_ps; intro/portion/description reference
    # cal/protein/cost. Word-numbers are not part of the prose contract.
    # R300: cal/protein are re-anchored in ALL FOUR prose fields, not just intro/portion. Writers do put
    # a protein figure in the closing line ("a meatball sub with 51 grams of protein in it"), and a spec
    # regenerated after a re-cost must not ship a stale macro just because r100's contract said that
    # field only quoted the price.
    $cps = [string]$spec.stat.cost_ps
    foreach($k in @('intro_html','portion_html','cost_closing_html','upsell_html')){
      if($pr.PSObject.Properties.Name -contains $k -and $pr.$k){
        $t=[string]$pr.$k
        $t = [regex]::Replace($t, '\$\d+\.\d{2}', ('$'+$cps))
        $t = [regex]::Replace($t, '\b\d{3,4}\s+calories', ([string]$spec.stat.cal + ' calories'))
        $t = [regex]::Replace($t, '\b\d{1,3}\s*(g|grams)\s+of\s+protein', ([string]$spec.stat.protein + ' grams of protein'))
        $t = [regex]::Replace($t, '\b\d{1,3}g\s+protein', ([string]$spec.stat.protein + 'g protein'))
        $t = [regex]::Replace($t, '\b\d{1,3}\s+grams\s+of\s+protein', ([string]$spec.stat.protein + ' grams of protein'))
        $pr.$k = $t
      }
    }
    if($pr.head -and $pr.head.description){
      $t=[string]$pr.head.description
      $t = [regex]::Replace($t, '\$\d+\.\d{2}', ('$'+$cps))
      $t = [regex]::Replace($t, '\b\d{3,4}\s+cal(ories)?\b', ([string]$spec.stat.cal + ' calories'))
      $t = [regex]::Replace($t, '\b\d{1,3}g\s+protein', ([string]$spec.stat.protein + 'g protein'))
      $pr.head.description = $t
    }

    foreach($k in @('intro_html','cost_closing_html','portion_html','upsell_html')){
      if($pr.PSObject.Properties.Name -contains $k -and $pr.$k){ $spec.$k = [string]$pr.$k } else { Fail $slug ("prose field empty: $k") }
    }
    if($pr.shop_smart -and $pr.shop_smart.Count -ge 2){ $spec.shop_smart = @($pr.shop_smart) } else { Fail $slug 'shop_smart <2 bullets' }
    if($pr.make_it -and $pr.make_it.Count -ge 5){ $spec.make_it = @($pr.make_it) } else { Fail $slug 'make_it <5 steps' }
    if($pr.head){
      foreach($k in @('description','keywords','prepTime','cookTime','totalTime')){
        if($pr.head.$k){ $spec.head.$k = [string]$pr.head.$k } else { Fail $slug ("head field empty: $k") }
      }
      if($pr.head.recipeIngredient -and $pr.head.recipeIngredient.Count -ge 3){ $spec.head.recipeIngredient = @($pr.head.recipeIngredient) } else { Fail $slug 'head.recipeIngredient <3' }
      if($pr.head.steps -and $pr.head.steps.Count -ge 3){ $spec.head.steps = @($pr.head.steps) } else { Fail $slug 'head.steps <3' }
    } else { Fail $slug 'no head prose' }

    # ---------- prose guards ----------
    if($spec.make_it.Count -gt 0 -and $spec.make_it[0] -ne $WEIGH){ Fail $slug 'step 1 is not the weigh-pot line' }
    if($spec.cost_closing_html -notmatch [regex]::Escape($cps)){ Fail $slug ("cost_closing missing exact cost $cps") }
    if($spec.upsell_html -notmatch [regex]::Escape($cps)){ Fail $slug ("upsell missing exact cost $cps") }
    if($spec.portion_html -notmatch [string]$spec.stat.cal){ Fail $slug 'portion missing calorie number' }
    if($spec.head.description.Length -lt 90 -or $spec.head.description.Length -gt 200){ Fail $slug ('head.description length ' + $spec.head.description.Length) }
    if($spec.head.prepTime -notmatch '^PT' -or $spec.head.cookTime -notmatch '^PT' -or $spec.head.totalTime -notmatch '^PT'){ Fail $slug 'prep/cook/total time not ISO8601 (PT..)' }

    # POST-SYNC NUMERIC VERIFICATION: nothing stale may survive the sync
    $proseFields = @{ 'intro_html'=$spec.intro_html; 'portion_html'=$spec.portion_html; 'cost_closing_html'=$spec.cost_closing_html; 'upsell_html'=$spec.upsell_html; 'head.description'=$spec.head.description }
    foreach($fk in $proseFields.Keys){
      $txt = [string]$proseFields[$fk]
      if(-not $txt){ continue }
      foreach($m in [regex]::Matches($txt,'\$(\d+\.\d{2})')){ if($m.Groups[1].Value -ne $cps){ Fail $slug ("$fk quotes `$$($m.Groups[1].Value), stat cost_ps is `$$cps") } }
      foreach($m in [regex]::Matches($txt,'(\d{3,4})\s+cal(?:orie|ories)?\b')){ if([int]$m.Groups[1].Value -ne [int]$spec.stat.cal){ Fail $slug ("$fk quotes $($m.Groups[1].Value) calories, stat is $($spec.stat.cal)") } }
      foreach($m in [regex]::Matches($txt,'(\d{1,3})\s*(?:g|grams)(?: of)? protein')){ if([int]$m.Groups[1].Value -ne [int]$spec.stat.protein){ Fail $slug ("$fk quotes $($m.Groups[1].Value)g protein, stat is $($spec.stat.protein)") } }
    }
    # steps must not restate a stale price either
    foreach($s in @($spec.shop_smart) + @($spec.make_it)){
      foreach($m in [regex]::Matches([string]$s,'\$(\d+\.\d{2})\s*(?:a|per)\s*(?:bowl|serving)')){ if($m.Groups[1].Value -ne $cps){ Fail $slug ("a bullet quotes `$$($m.Groups[1].Value) per serving, stat is `$$cps") } }
    }
  }

  # ---------- stat vs engine vs DB recompute ----------
  $cmp = $compIdx[$slug]
  if(-not $cmp){ Fail $slug 'no recipes-computed row for this slug' }
  else {
    if([int]$cmp.per_serving.calories -ne [int]$spec.stat.cal){ Fail $slug ("stat cal $($spec.stat.cal) != computed $([int]$cmp.per_serving.calories)") }
    if([int][Math]::Round($cmp.per_serving.protein_g,0) -ne [int]$spec.stat.protein){ Fail $slug ("stat protein $($spec.stat.protein) != computed $([int][Math]::Round($cmp.per_serving.protein_g,0))") }
    if([int][Math]::Round($cmp.per_serving.carbs_g,0) -ne [int]$spec.stat.carbs){ Fail $slug 'stat carbs != computed' }
    if([int][Math]::Round($cmp.per_serving.fat_g,0) -ne [int]$spec.stat.fat){ Fail $slug 'stat fat != computed' }
  }
  $cal=0.0;$p=0.0
  foreach($ig in $spec.ingredients_grams){
    if(-not $dbm.ContainsKey($ig.item)){ Fail $slug ("grams item not in DB: " + $ig.item); continue }
    $d=$dbm[$ig.item]; $f=$ig.grams/[double]$d.serving_grams
    $cal += $f*[double]$d.calories; $p += $f*[double]$d.protein_g
  }
  $calPS=[Math]::Round($cal/14,0); $pPS=[Math]::Round($p/14,0)
  if([Math]::Abs($calPS - $spec.stat.cal) -gt 5){ Fail $slug ("stat cal $($spec.stat.cal) != DB recompute $calPS") }
  if([Math]::Abs($pPS - $spec.stat.protein) -gt 2){ Fail $slug ("stat protein $($spec.stat.protein) != DB recompute $pPS") }
  if($spec.stat.cal -lt 550){ Fail $slug '550 GATE FAIL' }
  if($spec.stat.protein -lt 25){ Fail $slug ('PROTEIN FLOOR FAIL (' + $spec.stat.protein + 'g)') }
  # BASIS CHECK (v2 redesign 2026-07-26): stat.cost_ps is EITHER the build-time batch/14 (a fresh
  # skeleton, pre-reanchor) OR the manifest everyday_ps (a re-anchored live spec). Anything else is
  # stale. head.costPerServing must always agree with stat.cost_ps (they are stamped together).
  $psOk = @( ([double]$spec.cost_per_serving) )
  if($manPs.ContainsKey($slug)){ $psOk += $manPs[$slug] }
  $psVal = [double]$spec.stat.cost_ps
  if(-not ($psOk | Where-Object { [Math]::Abs($_ - $psVal) -le 0.005 })){ Fail $slug ("stat.cost_ps $($spec.stat.cost_ps) is neither cost_per_serving ($($spec.cost_per_serving)) nor manifest everyday_ps" + $(if($manPs.ContainsKey($slug)){ " ($($manPs[$slug]))" } else { ' (no manifest row)' })) }
  if([Math]::Abs([double]$spec.head.costPerServing - $psVal) -gt 0.005){ Fail $slug 'head.costPerServing != stat.cost_ps' }

  # ---------- ingredient display lint ----------
  if(@($spec.ingredients_display).Count -lt 3){ Fail $slug 'ingredients_display <3 lines' }
  foreach($li in $spec.ingredients_display){
    if($li -notmatch '^<strong>[^<]+:</strong> .+ \(\d+ g\)$'){ Fail $slug ("display line malformed: " + $li) }
    if($li -match '\(0 g\)$'){ Fail $slug ("zero-gram display line: " + $li) }
    if($li -match ':</strong> 0(\.0+)? '){ Fail $slug ("display amount rounds to zero: " + $li) }
    # nobody buys cups of meat or leafy bulk produce
    if($li -match '(?i)<strong>(Turkey Breast|Chicken Livers|Diced Ham|Corned Beef|Kale|Spinach|Mushrooms|Cabbage|Broccoli|Brussels|Green Beans|Snow Peas)[^<]*:</strong> [\d.]+ cups'){ Fail $slug ("weight-class item displayed in cups: " + $li) }
  }
  foreach($ig in $spec.ingredients_grams){ if([int]$ig.grams -le 0){ Fail $slug ('zero-gram ingredient row: ' + $ig.item) } }

  # ---------- prose-ingredient drift (recipeIngredient must name only real meats) ----------
  # An ingredient SWAP can leave the old meat's name in the writer's prose while the machine ingredient
  # list is correct - the cassoulet Italian-sausage bug, plus 5 breast->thigh / ground->sliced swaps
  # that shipped stale. The numeric auto-sync re-anchors cal/protein/cost but NEVER ingredient names.
  # head.recipeIngredient is the reader-facing + JSON-LD ingredient list, so every specific meat/cut it
  # names must actually be in the dish. Scoped to recipeIngredient ONLY on purpose: intro/description
  # legitimately carry substitution framing ("the classic version uses pork belly, but shoulder...")
  # and title echoes, which must NOT trip this. (Verified: this scope catches every real drift in the
  # 300 and false-positives on zero of the intentional cases.)
  if($spec.head.recipeIngredient){
    $ingNames = @($spec.ingredients_grams | ForEach-Object { [string]$_.item }) + @($spec.scaler.ing | ForEach-Object { [string]$_.item })
    foreach($mk in (Get-ProseIngredientDrift -RecipeIngredientLines @($spec.head.recipeIngredient) -IngredientNames $ingNames)){
      Fail $slug ("recipeIngredient names '$mk' but no such ingredient in the dish (stale prose after an ingredient swap?)")
    }
  }

  # ---------- cost lines: printed numbers must reconcile EXACTLY ----------
  $bl = $spec.cost_lines | Where-Object { $_ -match '^<strong>Batch total' } | Select-Object -First 1
  $tl = $spec.cost_lines | Where-Object { $_ -match '^<strong>True shopping cost' } | Select-Object -First 1
  $sl = $spec.cost_lines | Where-Object { $_ -match '^<strong>Starting with an empty pantry' } | Select-Object -First 1
  if(-not $bl -or $bl -notmatch [regex]::Escape(('$'+([double]$spec.cost_batch).ToString('0.00')))){ Fail $slug 'batch line mismatch' }
  if(-not $bl -or $bl -notmatch [regex]::Escape(('$'+([double]$spec.cost_per_serving).ToString('0.00')))){ Fail $slug 'batch line per-serving mismatch' }
  if(-not $tl -or $tl -notmatch [regex]::Escape(('$'+([double]$spec.cost_batch_true).ToString('0.00')))){ Fail $slug 'true line mismatch' }
  if(-not $tl -or $tl -notmatch [regex]::Escape(('$'+([double]$spec.cost_per_serving_true).ToString('0.00')))){ Fail $slug 'true line per-serving mismatch' }
  if([double]$spec.cost_batch_true -lt [double]$spec.cost_batch){ Fail $slug 'true < batch' }
  if([Math]::Abs([double]$spec.cost_per_serving - [Math]::Round([double]$spec.cost_batch/14,2)) -gt 0.005){ Fail $slug 'cost_per_serving != batch/14' }
  if([Math]::Abs([double]$spec.cost_per_serving_true - [Math]::Round([double]$spec.cost_batch_true/14,2)) -gt 0.005){ Fail $slug 'cost_per_serving_true != true/14' }
  $pa=[double]$spec.cost_pantry_add; $fr=[double]$spec.cost_first_run
  if($pa -gt 0){
    if(-not $sl){ Fail $slug 'starter line missing' }
    elseif($sl -notmatch [regex]::Escape(('$'+$pa.ToString('0.00'))) -or $sl -notmatch [regex]::Escape(('$'+$fr.ToString('0.00')))){ Fail $slug 'starter line numbers mismatch' }
    if([Math]::Abs($fr - ([double]$spec.cost_batch_true + $pa)) -gt 0.005){ Fail $slug ('first_run != true+add (' + $fr + ' vs ' + ([double]$spec.cost_batch_true+$pa) + ')') }
    if($fr -lt [double]$spec.cost_batch_true){ Fail $slug 'first_run < true' }
  } elseif($sl){ Fail $slug 'starter line present but pantry_add=0' }
  # re-parse every ingredient line: utilizations sum to BATCH, buy contributions sum to TRUE
  $sumU=0.0; $sumT=0.0; $parsed=0
  foreach($li in $spec.cost_lines){
    if($li -match '^<strong>(Batch total|True shopping cost|Starting with an empty pantry)'){ continue }
    $mu = [regex]::Match([string]$li,'~\$(\d+\.\d{2})')
    if(-not $mu.Success){ Fail $slug ("cost line without a ~`$ amount: " + $li); continue }
    $u = [double]$mu.Groups[1].Value
    $sumU += $u; $parsed++
    $mb = [regex]::Match([string]$li,'<strong>Buy \d+ [^:<]*: \$(\d+\.\d{2})\.</strong>')
    if($mb.Success){ $sumT += [double]$mb.Groups[1].Value }
    elseif($li -match '<strong>Buy 1 \(lasts several batches\)\.</strong>' -or $li -match '<strong>Buy as needed\.</strong>' -or $li -match '<strong>From jars you keep on hand\.</strong>' -or $li -match '<strong>Pantry staple; this batch alone uses about \d+ [^<]+\.</strong>'){ $sumT += $u }
    else { Fail $slug ("cost line has no recognizable Buy instruction: " + $li) }
  }
  if($parsed -lt 1){ Fail $slug 'no ingredient cost lines' }
  # the pantry fold is "jars you keep on hand" - a big number there means a real ingredient got
  # mis-bucketed or is mispriced (gumbo carried $22.31 of "Italian Seasoning")
  $pantryLine = $spec.cost_lines | Where-Object { $_ -match '^Pantry seasonings' } | Select-Object -First 1
  if($pantryLine){
    $mp = [regex]::Match([string]$pantryLine,'~\$(\d+\.\d{2})')
    if($mp.Success -and [double]$mp.Groups[1].Value -gt 5.00){ Fail $slug ('pantry seasonings line is $' + $mp.Groups[1].Value + ' (>$5.00 - mis-bucketed or mispriced item)') }
    if($pantryLine -match '(?i)broth|stock|\bmilk\b'){ Fail $slug 'non-seasoning item folded into the pantry line' }
  }
  # BASIS CHECK: when the amount and the package are quoted in the same unit, the Buy count must cover
  # the amount. Catches drained-vs-net can drift ("5.6 cans ... Buy 4 cans") and any future twin.
  foreach($li in $spec.cost_lines){
    $mm = [regex]::Match([string]$li,'^[^,]+, ([\d.]+) (can|cans|head|heads|bunch|bunches)(?: dry)?: ~\$\d+\.\d{2}\. <strong>Buy (\d+) ([^:<]*)')
    if(-not $mm.Success){ continue }
    $amt=[double]$mm.Groups[1].Value; $unit=$mm.Groups[2].Value -replace 's$',''; $n=[int]$mm.Groups[3].Value; $lbl=$mm.Groups[4].Value
    if($lbl -notmatch ('(?i)' + [regex]::Escape($unit))){ continue }   # different unit basis, not comparable
    $need=[Math]::Ceiling($amt-0.02); if($need -lt 1){ $need=1 }
    if($n -lt $need){ Fail $slug ("BUY UNDERCOUNT: needs $amt $unit but says Buy $n :: " + $li) }
  }
  # a recipe whose true cost equals its batch cost bought nothing in whole packages - legitimate only
  # when there are no package lines at all (exact-pound meat is a coincidence worth a human look)
  $pkgLines = @($spec.cost_lines | Where-Object { $_ -match '<strong>Buy \d+ [^:<]*: \$\d+\.\d{2}\.</strong>' }).Count
  if([double]$spec.cost_batch_true -eq [double]$spec.cost_batch -and $pkgLines -gt 0){
    # VERIFY-class only: a human-reviewed accept in guard-accepts.json {slug: reason} downgrades this
    # one check to a warning. No other guard consults the accepts file.
    $acceptFile = Join-Path $RunDir 'guard-accepts.json'
    $accepted = $false
    if(Test-Path $acceptFile){
      $acc = Get-Content $acceptFile -Raw | ConvertFrom-Json
      if($acc.PSObject.Properties[$slug]){ $accepted = $true
        Write-Output ("  ACCEPTED-VERIFY $slug :: " + [string]$acc.$slug) }
    }
    if(-not $accepted){
      Fail $slug ("VERIFY: true cost == batch cost with $pkgLines package line(s) - exact-package coincidence or a rounding bug")
    }
  }
  if([Math]::Abs([Math]::Round($sumU,2) - [double]$spec.cost_batch) -gt 0.005){ Fail $slug ("printed utilizations sum $([Math]::Round($sumU,2)) != cost_batch $($spec.cost_batch)") }
  if([Math]::Abs([Math]::Round($sumT,2) - [double]$spec.cost_batch_true) -gt 0.005){ Fail $slug ("printed Buy amounts sum $([Math]::Round($sumT,2)) != cost_batch_true $($spec.cost_batch_true)") }

  # ---------- scaler ----------
  if([string]$spec.scaler.cost -ne ([double]$spec.cost_batch_true).ToString('0.00')){ Fail $slug 'scaler.cost != cost_batch_true' }
  $sing=@($spec.scaler.ing); $grams=@($spec.ingredients_grams)
  if($sing.Count -ne $grams.Count){ Fail $slug ('scaler ing count ' + $sing.Count + ' != ingredients_grams ' + $grams.Count) }
  else {
    for($i=0;$i -lt $sing.Count;$i++){
      # scaler.item is reader-facing (may be a display override); scaler.canon is the machine identity
      $canon = if($sing[$i].PSObject.Properties.Name -contains 'canon' -and $sing[$i].canon){ [string]$sing[$i].canon } else { [string]$sing[$i].item }
      if($canon -ne $grams[$i].item){ Fail $slug ('scaler/grams item mismatch at ' + $i); break }
      # a renamed item must use the SAME name the rest of the card uses (one page, one name)
      if($sing[$i].item -ne $canon){
        $shown = (@($spec.ingredients_display) + @($spec.cost_lines)) -join ' '
        if($shown -notmatch [regex]::Escape([string]$sing[$i].item)){ Fail $slug ('scaler renames "' + $canon + '" to "' + $sing[$i].item + '" but the card never uses that name') }
      }
      if([int]$sing[$i].grams -ne [int]$grams[$i].grams){ Fail $slug ('scaler/grams gram mismatch on ' + $sing[$i].item); break }
      if(-not $sing[$i].buy){ Fail $slug ('scaler buy empty on ' + $sing[$i].item) }
      if($sing[$i].buy -match '(^|\s)0(\s|$)'){ Fail $slug ('scaler buy amount rounds to zero on ' + $sing[$i].item) }
      if($sing[$i].PSObject.Properties.Name -contains 'bid'){
        if(-not $sing[$i].bid){ Fail $slug ('empty bid on ' + $sing[$i].item) }
        if([string]$sing[$i].gpu -notmatch '^\d+\.\d{3}$'){ Fail $slug ('gpu not formatted on ' + $sing[$i].item) }
        if([double]$sing[$i].gpu -le 0){ Fail $slug ('gpu <= 0 on ' + $sing[$i].item) }
      }
    }
  }

  # ---------- credit + source ----------
  if(-not $spec.source_url -or $spec.source_url -notmatch '^https?://'){ Fail $slug 'missing source_url' }
  if(-not $spec.source_site){ Fail $slug 'missing source_site' }
  if($spec.credit_html -notmatch 'Recipe adapted from'){ Fail $slug 'missing credit line' }
  if($spec.credit_html -notmatch [regex]::Escape([string]$spec.source_url)){ Fail $slug 'credit line does not carry source_url' }
  if($spec.credit_html -notmatch [regex]::Escape([string]$spec.source_site)){ Fail $slug 'credit line does not carry source_site' }
  if($spec.credit_html -notmatch 'target="_blank" rel="noopener"'){ Fail $slug 'credit link missing target/rel' }

  # ---------- dashes + forbidden terms (whole spec) ----------
  $allStr = Get-Strings $spec
  foreach($s in $allStr){
    if($s -match [char]0x2014){ Fail $slug 'EM DASH found'; break }
  }
  foreach($s in $allStr){
    if($s -match [char]0x2013){ Fail $slug 'EN DASH found'; break }
  }
  # forbidden terms are about what a READER sees. writer_notes (which quote the canonical name on
  # purpose) and forbidden_prose_terms itself are authoring metadata and are excluded, or the sweep
  # would match its own instruction text.
  $readerStr = @()
  $readerStr += [string]$spec.name
  $readerStr += @($spec.ingredients_display) + @($spec.cost_lines) + @($spec.shop_smart) + @($spec.make_it)
  $readerStr += @([string]$spec.intro_html, [string]$spec.cost_note_html, [string]$spec.cost_closing_html, [string]$spec.portion_html, [string]$spec.credit_html, [string]$spec.upsell_html)
  $readerStr += @([string]$spec.head.description, [string]$spec.head.keywords) + @($spec.head.recipeIngredient) + @($spec.head.steps)
  foreach($bad in @($spec.forbidden_prose_terms)){
    if(-not $bad){ continue }
    foreach($s in $readerStr){
      if(-not $s){ continue }
      if($s -match ('(?i)' + [regex]::Escape([string]$bad))){ Fail $slug ("forbidden term '" + $bad + "' present: " + $s.Substring(0,[Math]::Min(80,$s.Length))); break }
    }
  }

  # ---------- stale superlative-protein claim ----------
  # The fix-pass re-costing changed protein numbers; the auto-sync re-anchors NUMBERS but not CLAIMS,
  # so a prose "the highest/most/biggest protein in the batch" can outlive its truth (turkey-taco was
  # claiming it at rank #58). Only the actual protein rank-#1 recipe may assert unscoped batch-primacy.
  # Scoped claims ("highest protein SOUP", "in the BEEF half") are exempt - a subset noun in the gap
  # means it is a subset claim, which the guard cannot verify and does not police.
  if(-not $Skeleton){
    foreach($claim in (Get-StaleSuperlativeClaims -ReaderStrings $readerStr -IsRank1 ($slug -eq $rank1Slug))){
      Fail $slug ("stale superlative: '$claim' but this is not the batch protein rank #1 ($rank1Slug)")
    }
  }

  if(-not $fails.ContainsKey($slug)){
    if(-not $Skeleton){ $spec | ConvertTo-Json -Depth 8 | Out-File $sf.FullName -Encoding utf8 }
    $ready += $slug
  }
}
$mode = if($Skeleton){ 'SKELETON' } else { 'FULL' }
Write-Output ("[$mode] READY: {0} / {1}" -f $ready.Count, $specs.Count)
if($fails.Count -gt 0){
  Write-Output ("FAILED: " + $fails.Count)
  foreach($k in ($fails.Keys | Sort-Object)){ Write-Output ("  " + $k + " :: " + ($fails[$k] -join ' | ')) }
}
$outFile = if($Skeleton){ 'specs-skeleton-ok.txt' } elseif($WriteReady){ 'specs-ready.txt' } else { 'specs-full-ok.txt' }
$ready | Out-File (Join-Path $OutDir $outFile) -Encoding utf8
Write-Output ("wrote " + $outFile)
if(-not $Skeleton -and -not $WriteReady){ Write-Output 'specs-ready.txt NOT written (pass -WriteReady after the auditor GO)' }
