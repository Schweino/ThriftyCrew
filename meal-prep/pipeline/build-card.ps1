# build-card.ps1 - Renders a recipe card (body HTML + head JSON-LD) in the EXACT live format.
# The scaler widget is assembled from template bytes extracted from a live card (extract-templates.ps1),
# never retyped. Prose is assembled with the exact line/blank-line pattern of the live cards.
# Fidelity is proven by test-fidelity.ps1 (parse live card -> render -> byte compare).
param(
  [Parameter(Mandatory=$true)][string]$SpecFile,
  [Parameter(Mandatory=$true)][string]$OutDir,
  [string]$SiteBase = 'https://www.thriftycrew.com',
  [string]$Author = 'Thrifty Crew'
)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$spec = Get-Content $SpecFile -Raw | ConvertFrom-Json
$utf8 = New-Object Text.UTF8Encoding($false)

# ---------- scaler data JSON (exact number/string formatting, key order fixed) ----------
function JsonStr([string]$s){
  $sb = New-Object Text.StringBuilder
  foreach($ch in $s.ToCharArray()){
    switch($ch){
      '"'  { [void]$sb.Append('\"') }
      '\' { [void]$sb.Append('\\') }
      default {
        if([int]$ch -lt 32){ [void]$sb.AppendFormat('\u{0:x4}',[int]$ch) } else { [void]$sb.Append($ch) }
      }
    }
  }
  $sb.ToString()
}
$ingParts = @()
foreach($ing in $spec.scaler.ing){
  $p = '{"item":"' + (JsonStr $ing.item) + '","grams":' + [int]$ing.grams + ',"buy":"' + (JsonStr $ing.buy) + '"'
  if($ing.PSObject.Properties.Name -contains 'bid' -and $ing.bid){
    $p += ',"bid":"' + (JsonStr $ing.bid) + '","gpu":' + $ing.gpu   # gpu stored as pre-formatted string, e.g. "453.592"
  }
  $p += '}'
  $ingParts += $p
}
$scalerData = '{"slug":"' + $spec.slug + '","base":14,"cost":' + $spec.scaler.cost + ',"ing":[' + ($ingParts -join ',') + ']}'

$prefix = [IO.File]::ReadAllText((Join-Path $here 'tpl-scaler-prefix.html'), [Text.Encoding]::UTF8)
$suffix = [IO.File]::ReadAllText((Join-Path $here 'tpl-scaler-suffix.html'), [Text.Encoding]::UTF8)
$scalerBlock = $prefix + $scalerData + $suffix

# ---------- prose (exact live line pattern) ----------
$L = New-Object System.Collections.Generic.List[string]
$st = $spec.stat
$L.Add(('<p><strong>Makes 14 servings &middot; ~{0} cal &middot; {1}g protein &middot; {2}g carbs &middot; {3}g fat &middot; ~${4} per serving.</strong></p>' -f $st.cal,$st.protein,$st.carbs,$st.fat,$st.cost_ps))
$L.Add('')
$L.Add('<p>' + $spec.intro_html + '</p>')
$L.Add('')
$L.Add('<h2>Ingredients</h2>')
$L.Add('<ul>')
foreach($li in $spec.ingredients_display){ $L.Add('<li>' + $li + '</li>') }
$L.Add('</ul>')
$L.Add('')
$L.Add('<h2>Estimated Everyday Cost</h2>')
$L.Add('<p><em>' + $spec.cost_note_html + '</em></p>')
$L.Add('<ul>')
foreach($li in $spec.cost_lines){ $L.Add('<li>' + $li + '</li>') }
$L.Add('</ul>')
$L.Add('<p>' + $spec.cost_closing_html + '</p>')
$L.Add('')
$L.Add('<h2>Shop Smart</h2>')
$L.Add('<ul>')
foreach($li in $spec.shop_smart){ $L.Add('<li>' + $li + '</li>') }
$L.Add('</ul>')
$L.Add('')
$L.Add('<h2>Make It</h2>')
$L.Add('<ol>')
foreach($li in $spec.make_it){ $L.Add('<li>' + $li + '</li>') }
$L.Add('</ol>')
$L.Add('')
$L.Add('<h2>Portion It</h2>')
$L.Add('<p>' + $spec.portion_html + '</p>')
$L.Add('')
if($spec.PSObject.Properties.Name -contains 'credit_html' -and $spec.credit_html){
  $L.Add('<p><em>' + $spec.credit_html + '</em></p>')
  $L.Add('')
}
$L.Add('<hr>')
$L.Add('<p><em>' + $spec.upsell_html + '</em></p>')
$prose = $L -join "`n"

$body = $scalerBlock + "`n" + $prose

# ---------- head JSON-LD (PS5.1 ConvertTo-Json formatting matches the live heads) ----------
$slugUrl = "$SiteBase/$($spec.slug)/"
$steps = @()
$i = 0
foreach($sTxt in $spec.head.steps){
  $i++
  $nm = $sTxt
  if($spec.head.PSObject.Properties.Name -contains 'step_names' -and $spec.head.step_names -and $spec.head.step_names.Count -ge $i -and $spec.head.step_names[$i-1]){ $nm = $spec.head.step_names[$i-1] }
  $steps += [ordered]@{ '@type'='HowToStep'; text=$sTxt; name=$nm; url=("{0}#step{1}" -f $slugUrl,$i) }
}
$recipe = [ordered]@{
  '@context' = 'https://schema.org'
  '@type'    = 'Recipe'
  name        = $spec.name
  description = $spec.head.description
  author      = [ordered]@{ '@type'='Organization'; name=$Author }
  recipeCategory = 'Meal Prep'
  recipeCuisine  = $spec.cuisine
  recipeYield    = '14 servings'
  costPerServing = [double]$spec.head.costPerServing
  keywords       = $spec.head.keywords
  nutrition      = [ordered]@{
    '@type'='NutritionInformation'; servingSize='1 bowl'
    calories = ('{0} calories' -f $st.cal)
    proteinContent = ('{0} g' -f $st.protein)
    carbohydrateContent = ('{0} g' -f $st.carbs)
    fatContent = ('{0} g' -f $st.fat)
  }
  recipeIngredient   = @($spec.head.recipeIngredient)
  recipeInstructions = @($steps)
  image    = $spec.head.image
  prepTime = $spec.head.prepTime
  cookTime = $spec.head.cookTime
  totalTime= $spec.head.totalTime
}
$recipeJson = $recipe | ConvertTo-Json -Depth 8
$paywall = [ordered]@{ '@context'='https://schema.org'; '@type'='Article'; isAccessibleForFree=$false;
  hasPart=[ordered]@{ '@type'='WebPageElement'; isAccessibleForFree=$false; cssSelector='.gh-content' };
  mainEntityOfPage=$slugUrl; headline=$spec.name }
$paywallJson = $paywall | ConvertTo-Json -Depth 6 -Compress
$head = "<script type=`"application/ld+json`">`n" + $recipeJson + "`n</script>`n<script type=`"application/ld+json`">`n" + $paywallJson + "`n</script>`n"

# ---------- write ----------
if(-not (Test-Path $OutDir)){ New-Item -ItemType Directory -Force $OutDir | Out-Null }
[IO.File]::WriteAllText((Join-Path $OutDir ($spec.slug + '.body.html')), $body, $utf8)
[IO.File]::WriteAllText((Join-Path $OutDir ($spec.slug + '.head.html')), $head, $utf8)
Write-Output ("built {0}: body={1}B head={2}B" -f $spec.slug, $body.Length, $head.Length)
