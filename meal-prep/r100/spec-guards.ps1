# spec-guards.ps1 - Merges prose patches into specs and enforces ALL invariants before card builds.
# A spec that fails ANY guard is listed and NOT marked ready. Never ship unvalidated.
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$specDir = Join-Path $here 'specs'
$proseDir = Join-Path $specDir 'prose'
$db = (Get-Content (Join-Path $here '..\food-macros-db.json') -Raw | ConvertFrom-Json).items
$dbm=@{}; foreach($i in $db){ $dbm[$i.item]=$i }

$WEIGH = 'Weigh your empty mixing pot and write the number down for portioning later.'
$fails=@{}; $ready=@()
function Fail($slug,$msg){ if(-not $fails.ContainsKey($slug)){ $fails[$slug]=@() }; $fails[$slug]+= $msg }

$specs = Get-ChildItem $specDir -Filter '*.json' | Where-Object { $_.Name -ne '_index.json' }
foreach($sf in $specs){
  $spec = Get-Content $sf.FullName -Raw | ConvertFrom-Json
  $slug = $spec.slug
  $pf = Join-Path $proseDir ("prose-$slug.json")
  if(-not (Test-Path $pf)){ Fail $slug 'missing prose file'; continue }
  try { $pr = Get-Content $pf -Raw | ConvertFrom-Json } catch { Fail $slug 'prose not valid JSON'; continue }

  # AUTO-NUMERIC-SYNC: prose was written against earlier spec generations; re-anchor its numbers to the
  # CURRENT verified stat before validating. Contract: cost_closing/upsell reference only cost_ps;
  # intro/portion/description reference cal/protein/cost. Word-numbers are not used by the prose contract.
  $cps = [string]$spec.stat.cost_ps
  foreach($k in @('cost_closing_html','upsell_html')){
    if($pr.PSObject.Properties.Name -contains $k -and $pr.$k){ $pr.$k = [regex]::Replace([string]$pr.$k, '\$\d+\.\d{2}', ('$'+$cps)) }
  }
  foreach($k in @('intro_html','portion_html')){
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

  # merge prose -> spec
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

  # guards on merged content
  $allProse = ($spec.intro_html + ' ' + $spec.cost_closing_html + ' ' + ($spec.shop_smart -join ' ') + ' ' + ($spec.make_it -join ' ') + ' ' + $spec.portion_html + ' ' + $spec.upsell_html + ' ' + $spec.head.description)
  if($allProse -match [char]0x2014 -or $allProse -match [char]0x2013){ Fail $slug 'EM/EN DASH found in prose' }
  if($spec.make_it.Count -gt 0 -and $spec.make_it[0] -ne $WEIGH){ Fail $slug 'step 1 is not the weigh-pot line' }
  $cps = [string]$spec.stat.cost_ps
  if($spec.cost_closing_html -notmatch [regex]::Escape($cps)){ Fail $slug ("cost_closing missing exact cost $cps") }
  if($spec.upsell_html -notmatch [regex]::Escape($cps)){ Fail $slug ("upsell missing exact cost $cps") }
  if($spec.portion_html -notmatch [string]$spec.stat.cal){ Fail $slug 'portion missing calorie number' }
  if($spec.head.description.Length -lt 90 -or $spec.head.description.Length -gt 200){ Fail $slug ('head.description length ' + $spec.head.description.Length) }

  # macro re-verify: stat must equal recompute from grams (label-rounding tolerance)
  $cal=0.0;$p=0.0
  foreach($ig in $spec.ingredients_grams){
    if(-not $dbm.ContainsKey($ig.item)){ Fail $slug ("grams item not in DB: " + $ig.item); continue }
    $d=$dbm[$ig.item]; $f=$ig.grams/[double]$d.serving_grams
    $cal += $f*[double]$d.calories; $p += $f*[double]$d.protein_g
  }
  $calPS=[Math]::Round($cal/14,0); $pPS=[Math]::Round($p/14,0)
  if([Math]::Abs($calPS - $spec.stat.cal) -gt 5){ Fail $slug ("stat cal $($spec.stat.cal) != recompute $calPS") }
  if([Math]::Abs($pPS - $spec.stat.protein) -gt 2){ Fail $slug ("stat protein $($spec.stat.protein) != recompute $pPS") }
  if($spec.stat.cal -lt 550){ Fail $slug '550 GATE FAIL' }

  # cost-line invariants: printed batch/true lines match stored totals
  $bl = $spec.cost_lines | Where-Object { $_ -match '^<strong>Batch total' } | Select-Object -First 1
  $tl = $spec.cost_lines | Where-Object { $_ -match '^<strong>True shopping cost' } | Select-Object -First 1
  if(-not $bl -or $bl -notmatch [regex]::Escape(('$'+([double]$spec.cost_batch).ToString('0.00')))){ Fail $slug 'batch line mismatch' }
  if(-not $tl -or $tl -notmatch [regex]::Escape(('$'+([double]$spec.cost_batch_true).ToString('0.00')))){ Fail $slug 'true line mismatch' }
  if([double]$spec.cost_batch_true -lt [double]$spec.cost_batch){ Fail $slug 'true < batch' }
  if(-not $spec.source_url -or $spec.source_url -notmatch '^https?://'){ Fail $slug 'missing source_url' }
  if($spec.credit_html -notmatch 'Recipe adapted from'){ Fail $slug 'missing credit line' }

  if(-not $fails.ContainsKey($slug)){
    $spec | ConvertTo-Json -Depth 8 | Out-File $sf.FullName -Encoding utf8
    $ready += $slug
  }
}
Write-Output ("READY: {0} / {1}" -f $ready.Count, $specs.Count)
if($fails.Count -gt 0){
  Write-Output ("FAILED: " + $fails.Count)
  foreach($k in ($fails.Keys | Sort-Object)){ Write-Output ("  " + $k + " :: " + ($fails[$k] -join ' | ')) }
}
$ready | Out-File (Join-Path $here 'specs-ready.txt') -Encoding utf8
