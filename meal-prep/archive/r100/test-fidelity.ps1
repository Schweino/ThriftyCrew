# test-fidelity.ps1 - PROOF that build-card.ps1 reproduces the live card format exactly.
# Parses the live hot-honey card (prose + scaler data + head) into a spec, re-renders it in legacy
# mode (old domain/author, no credit line), and byte-compares (after CRLF->LF normalization, since
# our fetch artifacts went through Out-File; Ghost itself stores LF).
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
function NL([string]$s){ ($s -replace "`r`n","`n") }

$prose = NL ([IO.File]::ReadAllText((Join-Path $here 'live-prose.html'), [Text.Encoding]::UTF8))
$dataRaw = NL ([IO.File]::ReadAllText((Join-Path $here 'live-scaler-data.json'), [Text.Encoding]::UTF8))
$headRaw = NL ([IO.File]::ReadAllText((Join-Path $here '..\_sample-recipe-head.html'), [Text.Encoding]::UTF8))

$lines = $prose -split "`n"
$idx = 0
function Expect([string]$pat){
  $script:idx | Out-Null
  while($script:idx -lt $lines.Count -and $lines[$script:idx].Trim() -eq ''){ $script:idx++ }
  $ln = $lines[$script:idx]
  if($ln -notmatch $pat){ throw ("parse fail at line {0}: expected /{1}/ got: {2}" -f $script:idx, $pat, $ln) }
  $script:idx++
  return $Matches
}
function CollectList([string]$closeTag){
  $items=@()
  while($lines[$script:idx].Trim() -ne $closeTag){
    $ln = $lines[$script:idx]
    if($ln -match '^<li>(.*)</li>$'){ $items += $Matches[1] } else { throw ("bad list line: " + $ln) }
    $script:idx++
  }
  $script:idx++
  return ,$items
}

$m = Expect '^<p><strong>Makes 14 servings &middot; ~(\d+) cal &middot; (\d+)g protein &middot; (\d+)g carbs &middot; (\d+)g fat &middot; ~\$([\d.]+) per serving\.</strong></p>$'
$stat = @{ cal=[int]$m[1]; protein=[int]$m[2]; carbs=[int]$m[3]; fat=[int]$m[4]; cost_ps=$m[5] }
$m = Expect '^<p>(.*)</p>$'; $intro = $m[1]
[void](Expect '^<h2>Ingredients</h2>$'); [void](Expect '^<ul>$')
$ingDisplay = CollectList '</ul>'
[void](Expect '^<h2>Estimated Everyday Cost</h2>$')
$m = Expect '^<p><em>(.*)</em></p>$'; $costNote = $m[1]
[void](Expect '^<ul>$')
$costLines = CollectList '</ul>'
$m = Expect '^<p>(.*)</p>$'; $costClosing = $m[1]
[void](Expect '^<h2>Shop Smart</h2>$'); [void](Expect '^<ul>$')
$shopSmart = CollectList '</ul>'
[void](Expect '^<h2>Make It</h2>$'); [void](Expect '^<ol>$')
$makeIt = CollectList '</ol>'
[void](Expect '^<h2>Portion It</h2>$')
$m = Expect '^<p>(.*)</p>$'; $portion = $m[1]
[void](Expect '^<hr>$')
$m = Expect '^<p><em>(.*)</em></p>$'; $upsell = $m[1]

# scaler data
if($dataRaw -notmatch '"cost":([0-9.]+),'){ throw 'no cost' }
$costRaw = $Matches[1]
$ing=@()
$rx = [regex]'\{"item":"((?:[^"\\]|\\.)*)","grams":(\d+),"buy":"((?:[^"\\]|\\.)*)"(?:,"bid":"([^"]*)","gpu":([0-9.]+))?\}'
foreach($mm in $rx.Matches($dataRaw)){
  $e = [ordered]@{ item=$mm.Groups[1].Value.Replace('\"','"'); grams=[int]$mm.Groups[2].Value; buy=$mm.Groups[3].Value.Replace('\"','"') }
  if($mm.Groups[4].Success){ $e.bid=$mm.Groups[4].Value; $e.gpu=$mm.Groups[5].Value }
  $ing += [pscustomobject]$e
}

# head
$scripts = [regex]::Matches($headRaw, '<script type="application/ld\+json">\s*(.*?)\s*</script>', 'Singleline')
if($scripts.Count -lt 2){ throw ('head parse: ' + $scripts.Count + ' scripts') }
$rec = $scripts[0].Groups[1].Value | ConvertFrom-Json
$steps=@(); $stepNames=@()
foreach($s in $rec.recipeInstructions){ $steps += $s.text; $stepNames += $s.name }

$spec = [ordered]@{
  name=$rec.name; slug='hot-honey-chicken-bowls'; cuisine=$rec.recipeCuisine
  stat=$stat; intro_html=$intro; ingredients_display=$ingDisplay
  cost_note_html=$costNote; cost_lines=$costLines; cost_closing_html=$costClosing
  shop_smart=$shopSmart; make_it=$makeIt; portion_html=$portion; upsell_html=$upsell
  scaler=[ordered]@{ cost=$costRaw; ing=$ing }
  head=[ordered]@{
    description=$rec.description; keywords=$rec.keywords; image=$rec.image
    prepTime=$rec.prepTime; cookTime=$rec.cookTime; totalTime=$rec.totalTime
    costPerServing=$rec.costPerServing
    recipeIngredient=@($rec.recipeIngredient); steps=$steps; step_names=$stepNames
  }
}
$specPath = Join-Path $here 'spec-fidelity-hot-honey.json'
$spec | ConvertTo-Json -Depth 8 | Out-File $specPath -Encoding utf8

# render legacy
& (Join-Path $here 'build-card.ps1') -SpecFile $specPath -OutDir (Join-Path $here 'fidelity-out') `
  -SiteBase 'https://www.simplemoneyplaybook.com' -Author 'Simple Money Playbook' | Out-Null

$builtBody = NL ([IO.File]::ReadAllText((Join-Path $here 'fidelity-out\hot-honey-chicken-bowls.body.html'), [Text.Encoding]::UTF8))
$builtHead = NL ([IO.File]::ReadAllText((Join-Path $here 'fidelity-out\hot-honey-chicken-bowls.head.html'), [Text.Encoding]::UTF8))

# expected body = scaler prefix+data+suffix + "\n" + prose  (reconstruct from live pieces)
$tplPrefix = NL ([IO.File]::ReadAllText((Join-Path $here 'tpl-scaler-prefix.html'), [Text.Encoding]::UTF8))
$tplSuffix = NL ([IO.File]::ReadAllText((Join-Path $here 'tpl-scaler-suffix.html'), [Text.Encoding]::UTF8))
$expectedBody = $tplPrefix + $dataRaw + $tplSuffix + "`n" + $prose

function FirstDiff([string]$a,[string]$b){
  $n=[Math]::Min($a.Length,$b.Length)
  for($i=0;$i -lt $n;$i++){ if($a[$i] -ne $b[$i]){ return $i } }
  if($a.Length -ne $b.Length){ return $n }
  return -1
}
$d1 = FirstDiff $builtBody $expectedBody
$d2 = FirstDiff $builtHead ($headRaw.TrimEnd()+"`n")
if($d1 -lt 0){ Write-Output 'BODY: EXACT MATCH' } else {
  Write-Output ("BODY DIFF at char {0}:" -f $d1)
  Write-Output ("  built:    ..." + $builtBody.Substring([Math]::Max(0,$d1-60), [Math]::Min(120, $builtBody.Length-[Math]::Max(0,$d1-60))))
  Write-Output ("  expected: ..." + $expectedBody.Substring([Math]::Max(0,$d1-60), [Math]::Min(120, $expectedBody.Length-[Math]::Max(0,$d1-60))))
}
if($d2 -lt 0){ Write-Output 'HEAD: EXACT MATCH' } else {
  $exp2 = $headRaw.TrimEnd()+"`n"
  Write-Output ("HEAD DIFF at char {0}:" -f $d2)
  Write-Output ("  built:    ..." + $builtHead.Substring([Math]::Max(0,$d2-60), [Math]::Min(120, $builtHead.Length-[Math]::Max(0,$d2-60))))
  Write-Output ("  expected: ..." + $exp2.Substring([Math]::Max(0,$d2-60), [Math]::Min(120, $exp2.Length-[Math]::Max(0,$d2-60))))
}
