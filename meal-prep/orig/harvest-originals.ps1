# harvest-originals.ps1 - pull the 113 ORIGINAL (pre-r100/r300) recipe cards from Ghost and extract
# everything needed to rebuild them as v2 cards. Writes orig\harvest.json (one entry per slug):
#   scaler.ing (item/grams/buy/bid/gpu from the old scaler payload), macros (recipes-db per_serving),
#   servings, and the harvested prose (intro/cost_closing/shop_smart/make_it/portion/credit/upsell) +
#   head (description/keywords/steps from the old JSON-LD). ingredients_display is NOT harvested (the old
#   grams-first format is incompatible) - it is regenerated in the v2 format at spec-build time.
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp = Split-Path -Parent $here
$adminKey=(Get-Content (Join-Path $mp '.ghostkey') -Raw).Trim()
$api='https://map-to-success.ghost.io'
function JWT { $p=$adminKey -split ':'; $sb=New-Object byte[] ($p[1].Length/2); for($i=0;$i -lt $sb.Length;$i++){ $sb[$i]=[Convert]::ToByte($p[1].Substring($i*2,2),16) }; $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); $h='{"alg":"HS256","typ":"JWT","kid":"'+$p[0]+'"}'; $pl='{"iat":'+$now+',"exp":'+($now+300)+',"aud":"/admin/"}'; $b={param($b)[Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_')}; $si=(& $b ([Text.Encoding]::UTF8.GetBytes($h)))+'.'+(& $b ([Text.Encoding]::UTF8.GetBytes($pl))); $hm=New-Object System.Security.Cryptography.HMACSHA256 (,$sb); $si+'.'+(& $b ($hm.ComputeHash([Text.Encoding]::UTF8.GetBytes($si)))) }

# 113 slugs = recipes-db minus r100/r300
$db=(Get-Content (Join-Path $mp 'recipes-db.json') -Raw | ConvertFrom-Json).recipes
$known=@{}; (Get-ChildItem (Join-Path $mp 'r100\specs\*.json'),(Join-Path $mp 'r300\specs\*.json') | Where-Object BaseName -ne '_index').BaseName | ForEach-Object { $known[$_]=1 }
$orig = @($db | Where-Object { $_.slug -and -not $known.ContainsKey($_.slug) })
Write-Output ("originals to harvest: {0}" -f $orig.Count)

function Grab($html,$pat){ $m=[regex]::Match($html,$pat,'Singleline'); if($m.Success){ $m.Groups[1].Value.Trim() } else { '' } }
function LiList($block){ [regex]::Matches($block,'<li>(.*?)</li>','Singleline') | ForEach-Object { $_.Groups[1].Value.Trim() } }

$out=@()
$fail=@()
foreach($r in $orig){
  $slug=$r.slug
  try{
    $jwt=JWT
    $post=(Invoke-RestMethod -Uri "$api/ghost/api/admin/posts/slug/$slug/?formats=html&fields=id,title,slug,html,codeinjection_head,custom_excerpt,meta_description,visibility" -Headers @{Authorization="Ghost $jwt";'Accept-Version'='v5.0'} -TimeoutSec 40).posts[0]
    $html=[string]$post.html
    # scaler payload
    $sm=[regex]::Match($html,'smp-sc-data[^>]*>(\{.*?\})</script>','Singleline')
    if(-not $sm.Success){ $fail += "$slug :: no scaler payload"; continue }
    $scaler=$sm.Groups[1].Value | ConvertFrom-Json
    # prose
    $intro = Grab $html '</strong></p>\s*<p>(.*?)</p>\s*<h2>\s*Ingredients'
    $shopBlock = Grab $html '<h2>\s*Shop Smart\s*</h2>\s*<ul>(.*?)</ul>'
    $makeBlock = Grab $html '<h2>\s*Make it\s*</h2>\s*<ol>(.*?)</ol>'
    if(-not $makeBlock){ $makeBlock = Grab $html '<h2>\s*Make It\s*</h2>\s*<ol>(.*?)</ol>' }
    $portion = Grab $html '<h2>\s*Portion it\s*</h2>\s*<p>(.*?)</p>'
    if(-not $portion){ $portion = Grab $html '<h2>\s*Portion It\s*</h2>\s*<p>(.*?)</p>' }
    # cost closing = last <p> before <h2>Shop Smart
    $costSeg = Grab $html '</ul>\s*(.*?)<h2>\s*Shop Smart'
    $closeM = [regex]::Matches($costSeg,'<p>(.*?)</p>','Singleline')
    $costClose = if($closeM.Count){ $closeM[$closeM.Count-1].Groups[1].Value.Trim() } else { '' }
    # credit + upsell: after Portion it. credit = a <p><em>...adapted/recipe from...</em></p>; upsell = last <p><em>
    $tail = ''
    $pm = [regex]::Match($html,'<h2>\s*Portion','Singleline'); if($pm.Success){ $tail = $html.Substring($pm.Index) }
    $emAll = [regex]::Matches($tail,'<p><em>(.*?)</em></p>','Singleline') | ForEach-Object { $_.Groups[1].Value.Trim() }
    $credit = @($emAll | Where-Object { $_ -match 'adapted from|recipe from|inspired by' }) | Select-Object -First 1
    $upsell = @($emAll | Where-Object { $_ -match 'month|Members|Meal Prep section|subscrib' }) | Select-Object -Last 1
    # head JSON-LD (Recipe) from codeinjection_head
    $desc=''; $kw=''; $steps=@()
    $ci=[string]$post.codeinjection_head
    $ldM=[regex]::Match($ci,'<script type="application/ld\+json">\s*(\{.*?\})\s*</script>','Singleline')
    if($ldM.Success){ try{ $ld=$ldM.Groups[1].Value | ConvertFrom-Json; if($ld.'@type' -eq 'Recipe'){ $desc=[string]$ld.description; $kw=[string]$ld.keywords; $steps=@($ld.recipeInstructions | ForEach-Object { [string]$_.text }) } }catch{} }
    if(-not $desc){ $desc=[string]$post.meta_description; if(-not $desc){ $desc=[string]$post.custom_excerpt } }

    $out += [pscustomobject]@{
      slug=$slug; name=[string]$post.title; visibility=[string]$post.visibility
      protein=[string]$r.protein; cuisine=[string]$r.cuisine
      servings=[int]$r.servings
      stat=[pscustomobject]@{ cal=[int]$r.per_serving.calories; protein=[int]$r.per_serving.protein_g; carbs=[int]$r.per_serving.carbs_g; fat=[int]$r.per_serving.fat_g }
      ing=@($scaler.ing)
      intro_html=$intro; cost_closing_html=$costClose; shop_smart=@(LiList $shopBlock)
      make_it=@(LiList $makeBlock); portion_html=$portion; credit_html=$credit; upsell_html=$upsell
      head=[pscustomobject]@{ description=$desc; keywords=$kw; steps=@($steps) }
    }
  } catch { $fail += ("$slug :: " + $_.Exception.Message) }
}
. (Join-Path $mp 'lib\json-db-io.ps1')
Save-JsonArray -Array $out -Path (Join-Path $here 'harvest.json') -Depth 8 | Out-Null
Write-Output ("harvested {0} / {1}" -f $out.Count, $orig.Count)
# quick completeness audit
$miss = $out | Where-Object { -not $_.intro_html -or -not $_.make_it.Count -or -not $_.shop_smart.Count -or -not $_.portion_html -or -not $_.upsell_html }
Write-Output ("entries missing a prose field: {0}" -f @($miss).Count)
$miss | Select-Object -First 15 | ForEach-Object { Write-Output ("  {0}: intro={1} make={2} shop={3} portion={4} upsell={5} credit={6}" -f $_.slug,[bool]$_.intro_html,$_.make_it.Count,$_.shop_smart.Count,[bool]$_.portion_html,[bool]$_.upsell_html,[bool]$_.credit_html) }
if($fail.Count){ Write-Output "FAILURES:"; $fail | ForEach-Object { Write-Output ("  "+$_) } }