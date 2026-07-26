# build-specs-orig.ps1 - assemble v2 specs for the 113 originals from harvest.json + recipes-costed.json.
# ingredients_display is REGENERATED in the v2 format (the old grams-first display is discarded); prose is
# the harvested prose; cost_ps/costPerServing = everyday_ps (cost_first_run/14). Writes orig\specs\<slug>.json.
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp = Split-Path -Parent $here
$OGIMG='https://storage.ghost.io/c/4b/5b/4b5b2999-07b7-4733-88cc-1bc0e25912c6/content/images/2026/07/tc-og-1200x630.png'
$h = Get-Content (Join-Path $here 'harvest.json') -Raw | ConvertFrom-Json
$costed = Get-Content (Join-Path $here 'recipes-costed.json') -Raw | ConvertFrom-Json
$cbySlug=@{}; foreach($c in $costed){ $cbySlug[$c.slug]=$c }
$dbm=@{}; (Get-Content (Join-Path $mp 'food-macros-db.json') -Raw | ConvertFrom-Json).items | ForEach-Object { $dbm[$_.item]=$_ }
. (Join-Path $mp 'lib\json-db-io.ps1')

function DispName([string]$item){
  $d=$dbm[$item]; $brand=''
  if($d -and $d.brand -and $d.brand -notmatch '^fresh$|store'){ $brand=' ('+(($d.brand -split '/')[0].Trim())+')' }
  $item + $brand
}
function JEsc([string]$s){ if($null -eq $s){ '' } else { $s } }

New-Item -ItemType Directory -Force (Join-Path $here 'specs') | Out-Null
$built=0; $skipped=@()
foreach($r in $h){
  $c = $cbySlug[$r.slug]; if(-not $c){ $skipped += "$($r.slug): no costed"; continue }
  $everyday = [math]::Round([double]$c.cost_first_run/14,2)
  # ingredients_display + scaler.ing (v2), in harvest order
  $disp=@(); $scIng=@()
  foreach($i in $r.ing){
    if([double]$i.grams -le 0){ continue }
    $dn = DispName $i.item
    $disp += ('<strong>' + $dn + ':</strong> ' + $i.buy + ' (' + [int]$i.grams + ' g)')
    $se = [ordered]@{ item=$i.item; grams=[int]$i.grams; buy=[string]$i.buy }
    if($i.bid){ $se.bid=[string]$i.bid; $se.gpu=('{0:0.000}' -f [double]$i.gpu) }
    $scIng += $se
  }
  $intro = JEsc $r.intro_html
  if(-not $intro){ $intro = JEsc $r.head.description }   # fajita has no intro paragraph
  # recipeIngredient from scaler (buy + item)
  $recIng = @($r.ing | Where-Object { [double]$_.grams -gt 0 } | ForEach-Object { ($_.buy + ' ' + $_.item).Trim() } | Select-Object -First 6)
  $upsell = JEsc $r.upsell_html
  if(-not $upsell){ $upsell = 'A hearty dinner for about $' + ('{0:0.00}' -f $everyday) + ' a bowl (at everyday cost). This is one of many. Members get every recipe in the Meal Prep section, plus the full library of money lessons, calculators, and tools, all for $1 a month.' }
  $spec = [ordered]@{
    name=$r.name; slug=$r.slug; cuisine=(JEsc $r.cuisine); protein=(JEsc $r.protein); visibility=(JEsc $r.visibility)
    source_url=''; source_site=''; manual_balance=$false; tuning=@()
    stat=[ordered]@{ cal=[int]$r.stat.cal; protein=[int]$r.stat.protein; carbs=[int]$r.stat.carbs; fat=[int]$r.stat.fat; cost_ps=('{0:0.00}' -f $everyday) }
    intro_html=$intro
    ingredients_display=@($disp)
    cost_note_html='Real Omaha store prices from our weekly grocery board (2026). They still swing by store and by what is on sale.'
    cost_closing_html=(JEsc $r.cost_closing_html)
    shop_smart=@($r.shop_smart)
    make_it=@($r.make_it)
    portion_html=(JEsc $r.portion_html)
    credit_html=(JEsc $r.credit_html)
    upsell_html=$upsell
    cost_batch=[double]$c.cost_batch; cost_batch_true=[double]$c.cost_batch_true; cost_per_serving=[double]$c.cost_per_serving
    cost_per_serving_true=[double]$c.cost_per_serving_true; cost_pantry_add=[double]$c.cost_pantry_add; cost_first_run=[double]$c.cost_first_run
    scaler=[ordered]@{ cost=('{0:0.00}' -f [double]$c.cost_batch_true); ing=@($scIng) }
    head=[ordered]@{
      description=(JEsc $r.head.description); keywords=(JEsc $r.head.keywords)
      costPerServing=$everyday
      recipeIngredient=@($recIng); steps=@($r.head.steps); step_names=@()
      image=$OGIMG; prepTime='PT20M'; cookTime='PT45M'; totalTime='PT1H5M'
    }
  }
  # single spec object; ConvertTo-Json escapes < as <, matching the r100/r300 spec format
  $json = ($spec | ConvertTo-Json -Depth 12)
  [IO.File]::WriteAllText((Join-Path $here ('specs\' + $r.slug + '.json')), $json, (New-Object Text.UTF8Encoding($false)))
  $built++
}
Write-Output ("built {0} specs; skipped {1}" -f $built, $skipped.Count)
$skipped | ForEach-Object { Write-Output ("  SKIP "+$_) }