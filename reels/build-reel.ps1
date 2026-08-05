<#
build-reel.ps1 - one vertical Facebook Reel a day, generated from live recipe data.

WHY THIS EXISTS
  A daily reel hand-built in Canva or Clipchamp is 20+ minutes of design work, every day, forever.
  That job dies in three weeks. This builds the same reel from the data that already ships to the
  site, so the numbers on screen are the numbers on the page, and the daily cost is zero minutes.

PIPELINE
  pick recipe -> build 8 HTML scenes -> headless Chrome screenshots -> edge-tts voiceover
  -> ffmpeg (Ken Burns per scene, hard cuts) -> 1080x1920 H.264/AAC MP4 ready to upload.

THE NUMBER ON SCREEN (this is load-bearing, not taste)
  A recipe spec carries FIVE plausible per-serving figures and they disagree by 3x. Getting this
  wrong ships a real price in the wrong basis, which is the worst defect class this estate has
  (see board-basis-ambiguity). The rule, from pipeline/compute-v2-perserving.ps1:
    everyday_ps  = sum(ceil(grams/pkg_g) * pkg_p) / 14      the "at everyday cost" stat
    cheapest_ps  = sum(k * (pkg_g/gpu) * feed.cheapest) / 14 THE HEADLINE BASIS (2026-07-26 redesign)
  The reel headlines cheapest_ps and labels it "cheapest across the Omaha board this week", which is
  what it is. spec.stat.cost_ps is the EVERYDAY basis and must never be labelled "cheapest".
  Both come from pipeline/v2-perserving.json, never from the spec's loose cost_* fields.

  Because cheapest_ps is a whole-package total over 14, `14 x cheapest_ps` IS the batch cost.
  The reel shows that multiplication on screen rather than quoting an unverified batch field.

HONESTY
  The takeout comparison is arithmetic on a stated assumption, and the assumption is printed on the
  frame. Prices are a snapshot, so every reel is stamped with the board week it was built from.

USAGE
  .\build-reel.ps1                          # today's pick, full reel
  .\build-reel.ps1 -Slug chicken-fried-rice-skillet
  .\build-reel.ps1 -VoiceSamples            # one mp3 per candidate voice, then exit
  .\build-reel.ps1 -NoVoice                 # silent cut, fixed beats (no network needed)
  .\build-reel.ps1 -WhatIfPick              # print the pick and exit
#>
[CmdletBinding()]
param(
  [string] $Slug,
  [string] $Voice        = 'en-US-AndrewNeural',
  [int]    $RatePct      = -5,
  [double] $TakeoutPlate = 12.0,
  [string] $OutDir,
  [switch] $NoVoice,
  [switch] $KeepFrames,
  [switch] $VoiceSamples,
  [switch] $WhatIfPick
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ReelRoot = $PSScriptRoot
$Income   = Split-Path $ReelRoot -Parent
$MealPrep = Join-Path $Income 'meal-prep'
if (-not $OutDir) { $OutDir = Join-Path $ReelRoot 'out' }
$WorkDir  = Join-Path $OutDir '.work'
$StateFile = Join-Path $ReelRoot 'reel-state.json'

. (Join-Path $Income 'lib\design-tokens.ps1')

# ---------------------------------------------------------------- tools

function Resolve-Tool {
  param([string]$Name, [string[]]$Probe)
  # Explicit paths win over PATH: `python` on PATH is the Microsoft Store alias stub, which is not
  # a Python at all and fails with a Store advert on first use.
  foreach ($p in $Probe) { if ($p -and (Test-Path $p)) { return $p } }
  $c = Get-Command $Name -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  # winget drops ffmpeg under Packages\ but only aliases it onto PATH after a shell restart
  $wg = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
  if (Test-Path $wg) {
    $hit = Get-ChildItem $wg -Filter "$Name.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { return $hit.FullName }
  }
  throw "Could not find $Name. Install it, or add it to PATH."
}

$Chrome  = Resolve-Tool 'chrome'  @('C:\Program Files\Google\Chrome\Application\chrome.exe',
                                    'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe')
$FFmpeg  = Resolve-Tool 'ffmpeg'  @()
$FFprobe = Resolve-Tool 'ffprobe' @()
$Python  = Resolve-Tool 'python'  @('C:\Codex\Python312\python.exe')

# ---------------------------------------------------------------- number to speech
# Neural TTS reads "$1.63" inconsistently (sometimes "one point six three dollars"). Spell it.

$script:Ones = @('zero','one','two','three','four','five','six','seven','eight','nine','ten',
                 'eleven','twelve','thirteen','fourteen','fifteen','sixteen','seventeen','eighteen','nineteen')
$script:Tens = @('','','twenty','thirty','forty','fifty','sixty','seventy','eighty','ninety')

function ConvertTo-Words {
  param([int]$N)
  if ($N -lt 0)   { return 'minus ' + (ConvertTo-Words ([math]::Abs($N))) }
  if ($N -lt 20)  { return $script:Ones[$N] }
  if ($N -lt 100) {
    $t = $script:Tens[[math]::Floor($N / 10)]
    $r = $N % 10
    if ($r -eq 0) { return $t }
    return "$t $($script:Ones[$r])"
  }
  if ($N -lt 1000) {
    $h = "$($script:Ones[[math]::Floor($N / 100)]) hundred"
    $r = $N % 100
    if ($r -eq 0) { return $h }
    return "$h $(ConvertTo-Words $r)"
  }
  $k = "$(ConvertTo-Words ([math]::Floor($N / 1000))) thousand"
  $r = $N % 1000
  if ($r -eq 0) { return $k }
  return "$k $(ConvertTo-Words $r)"
}

function Get-MoneySpeech {
  # How a person actually says money out loud: "a dollar sixty three", "twenty two eighty two".
  param([double]$Amount)
  $cents   = [int][math]::Round($Amount * 100)
  $dollars = [math]::Floor($cents / 100)
  $rem     = $cents % 100
  if ($rem -eq 0)      { if ($dollars -eq 1) { return 'one dollar' } ; return "$(ConvertTo-Words $dollars) dollars" }
  if ($dollars -eq 0)  { return "$(ConvertTo-Words $rem) cents" }
  $centWords = if ($rem -lt 10) { "oh $(ConvertTo-Words $rem)" } else { ConvertTo-Words $rem }
  if ($dollars -eq 1)  { return "a dollar $centWords" }
  return "$(ConvertTo-Words $dollars) $centWords"
}

function Format-Money { param([double]$A) '$' + $A.ToString('0.00') }

# ---------------------------------------------------------------- data

$psFile = Join-Path $MealPrep 'pipeline\v2-perserving.json'
$frFile = Join-Path $MealPrep 'free-rotation.json'
foreach ($f in @($psFile, $frFile)) { if (-not (Test-Path $f)) { throw "Missing required source: $f" } }

# @(x | ConvertFrom-Json) does not unroll a JSON array in PS5.1 - assign first, then index.
$perServing = Get-Content $psFile -Raw | ConvertFrom-Json
$rotation   = Get-Content $frFile -Raw | ConvertFrom-Json

# The daily chain (grocery\run-daily-local.ps1 -> check-ad-cycles) rewrites v2-perserving.json each
# morning, finishing 09:08-09:18 across the last four days. This runs at 10:00, but do not TRUST the
# clock: if the pipeline failed or ran long, the headline price is yesterday's. Say so rather than
# refusing, because a stale board price is still a real price and the reel stamps its own board week.
$psAge = (Get-Date).Date - (Get-Item $psFile).LastWriteTime.Date
if ($psAge.Days -ge 1) {
  Write-Warning ("v2-perserving.json is {0} day(s) old (last written {1:yyyy-MM-dd HH:mm}). The daily price refresh may not have run. Prices below are from that date, not today." -f $psAge.Days, (Get-Item $psFile).LastWriteTime)
}

$psBySlug = @{}
foreach ($row in $perServing) { $psBySlug[[string]$row.slug] = $row }

$freeSlugs = @()
foreach ($f in $rotation.free) { $freeSlugs += [string]$f.slug }

# ---------------------------------------------------------------- pick
# Free-rotation recipes only. A reel that lands on a paywall converts nothing; these 20 pages are
# open all week, and rotate-free-dinners.ps1 refreshes the pool every Wednesday.

$state = if (Test-Path $StateFile) { Get-Content $StateFile -Raw | ConvertFrom-Json }
         else { [pscustomobject]@{ readme = 'Reels already published, newest last. build-reel.ps1 avoids repeats until the pool is exhausted.'; used = @() } }

$usedSlugs = @()
foreach ($u in $state.used) { $usedSlugs += [string]$u.slug }

if ($Slug) {
  $pick = $Slug
} else {
  $fresh = @($freeSlugs | Where-Object { $usedSlugs -notcontains $_ })
  if ($fresh.Count -eq 0) {
    Write-Output 'All free recipes used this cycle. Starting over.'
    $fresh = $freeSlugs
  }
  # cheapest first: the strongest hook goes out first
  $pick = @($fresh | Sort-Object @{ e = { [double]$psBySlug[$_].cheapest_ps } }, @{ e = { $_ } })[0]
}

$specFile = Join-Path $MealPrep "db\recipes\$pick.json"
if (-not (Test-Path $specFile)) { throw "No recipe spec for '$pick' at $specFile" }
if (-not $psBySlug.ContainsKey($pick)) { throw "'$pick' has no row in v2-perserving.json - cannot price it honestly." }

$spec = Get-Content $specFile -Raw | ConvertFrom-Json
$ps   = $psBySlug[$pick]

$cheapestPs = [double]$ps.cheapest_ps
$everydayPs = [double]$ps.everyday_ps
$proteinG   = [int]$ps.protein_g
$calories   = [int]$spec.stat.cal          # spec.stat fields deserialize as strings - cast every one
$servings   = 14
$batchCost  = [math]::Round($cheapestPs * $servings, 2)
$isFree     = $freeSlugs -contains $pick
$name       = [string]$spec.name
$cuisine    = if ($spec.PSObject.Properties.Name -contains 'cuisine' -and $spec.cuisine) { [string]$spec.cuisine } else { '' }
$weekOf     = [string]$rotation.week_of

if ($cheapestPs -le 0) { throw "cheapest_ps for '$pick' is $cheapestPs - refusing to build a reel around a zero price." }

Write-Output "Recipe   : $name  ($pick)"
Write-Output "Headline : $(Format-Money $cheapestPs)/serving (cheapest basis, board week $weekOf)"
Write-Output "Everyday : $(Format-Money $everydayPs)/serving"
Write-Output "Batch    : $servings x $(Format-Money $cheapestPs) = $(Format-Money $batchCost)"
Write-Output "Free now : $isFree"
if ($WhatIfPick) { return }

# ---------------------------------------------------------------- ingredients

function Remove-TrailingParenthetical {
  # "Sauerkraut (generic canned (USDA))" -> "Sauerkraut". A regex cannot do this: the group is
  # BALANCED but nested, so \([^()]*\)$ never matches (the string ends "))") and a greedy
  # \(.*\)$ would eat a legitimate mid-name group. Scan back with a depth counter instead.
  param([string]$S)
  $t = $S.Trim()
  while ($t.EndsWith(')')) {
    $depth = 0
    $cut = -1
    for ($i = $t.Length - 1; $i -ge 0; $i--) {
      if ($t[$i] -eq ')') { $depth++ }
      elseif ($t[$i] -eq '(') {
        $depth--
        if ($depth -eq 0) { $cut = $i; break }
      }
    }
    if ($cut -le 0) { break }   # unbalanced, or the whole name is parenthesised: leave it alone
    $t = $t.Substring(0, $cut).Trim()
  }
  return $t
}

function Format-ShopperWeight {
  param([double]$Grams)
  if ($Grams -ge 227) { return [math]::Round($Grams / 453.59237, 1).ToString('0.#') + ' lb' }
  return [math]::Round($Grams / 28.349523, 1).ToString('0.#') + ' oz'
}

function Get-IngredientLines {
  param($Spec)
  $out = @()
  foreach ($raw in $Spec.ingredients_display) {
    # "<strong>93/7 Ground Beef (Member's Mark):</strong> 6 lb (2450 g)"
    # [regex]::Match, not -match: the automatic $Matches is a documented clobber hazard here.
    $m = [regex]::Match([string]$raw, '^\s*<strong>(?<n>.+?):\s*</strong>\s*(?<a>.*)$')
    if (-not $m.Success) { continue }
    $n = $m.Groups['n'].Value -replace '<[^>]+>', ''
    $a = $m.Groups['a'].Value -replace '<[^>]+>', ''

    $n = Remove-TrailingParenthetical $n   # drop the brand, the reel needs short lines

    $grams = 0.0
    $gm = [regex]::Match($a, '\(\s*(?<g>[\d.,]+)\s*g\s*\)\s*$')
    if ($gm.Success) { [void][double]::TryParse(($gm.Groups['g'].Value -replace ',', ''), [ref]$grams) }
    $a = ($a -replace '\s*\(\s*[\d.,]+\s*g\s*\)\s*$', '').Trim()   # drop the gram restatement

    # FIXED AT SOURCE 2026-08-04, kept as a belt-and-braces net. 661 lines used to carry a UNITLESS
    # buy amount ("18.4" meaning 18.4 potatoes), which reads as a typo once the grams are stripped off.
    # The cause was FriendlyAmt's each branch returning a bare count; the specs now carry the noun
    # (pipeline\repair-unitless-buy.ps1) and spec-guards fails any import that reintroduces one, so this
    # currently fires ZERO times across all 6,999 lines. It stays because it costs nothing and it is the
    # same test the guard applies - if it ever fires again, the guard upstream has been bypassed.
    if ($a -notmatch '[A-Za-z]' -and $grams -gt 0) { $a = Format-ShopperWeight $grams }

    if ($n) { $out += [pscustomobject]@{ Name = $n; Amount = $a } }
  }
  return $out
}

$ingredients = @(Get-IngredientLines -Spec $spec)
if ($ingredients.Count -lt 2) { throw "Parsed only $($ingredients.Count) ingredients from '$pick' - the display format changed; fix the parser before shipping a reel." }

# Show the first six in the spec's own order and send the rest to the page. Specs are authored
# headline-ingredient first and seasonings last, so splitting a long list across two frames reliably
# produced a second frame reading "Black Pepper, Red Pepper Flakes, Parmesan, Salt" under a caption
# saying "nothing fancy" - a whole scene of a daily reel spent on spices. The cap is not hiding
# anything: the overflow count is printed and the full list is on the page the reel drives to.
$maxShown = 6
$shown    = @($ingredients | Select-Object -First $maxShown)
$overflow = $ingredients.Count - $shown.Count

# ---------------------------------------------------------------- scene HTML

$css = @"
*{margin:0;padding:0;box-sizing:border-box}
html,body{width:1080px;height:1920px;overflow:hidden}
body{font-family:Georgia,'Times New Roman',serif;-webkit-font-smoothing:antialiased}
.f{position:absolute;inset:0;display:flex;flex-direction:column;padding:0 84px}
.paper{background:$TcPaper;color:$TcInk}
.dark{background:$TcInkDeep;color:$TcCream}
.mark{height:200px;display:flex;align-items:center;justify-content:center;
  font:600 27px/1 Georgia,serif;letter-spacing:.42em;text-transform:uppercase;color:$TcGoldInk}
.dark .mark{color:$TcGold}
.body{flex:1 1 auto;display:flex;flex-direction:column;justify-content:center;
  align-items:center;text-align:center;padding-bottom:120px}
.cap{height:300px;display:flex;align-items:flex-start;justify-content:center;padding-top:34px}
.cap span{font:400 43px/1.32 Georgia,serif;color:$TcMut;max-width:900px;text-align:center}
.dark .cap span{color:#cfc6b4}
.pad{height:360px}
.eyebrow{font:600 30px/1 Georgia,serif;letter-spacing:.3em;text-transform:uppercase;
  color:$TcGoldInk;margin-bottom:44px}
.dark .eyebrow{color:$TcGold}
.money{font:700 300px/.9 Georgia,serif;color:$TcGold;letter-spacing:-.03em}
.money.sm{font-size:190px}
.sub{font:400 50px/1.25 Georgia,serif;margin-top:26px;color:$TcCream}
.paper .sub{color:$TcMut}
.title{font:700 92px/1.1 Georgia,serif;letter-spacing:-.02em}
.title.long{font-size:74px}
.dek{font:400 44px/1.3 Georgia,serif;color:$TcMut;margin-top:34px}
.tiles{display:flex;gap:34px;width:100%;justify-content:center}
.tile{flex:1 1 0;background:$TcCream;border:2px solid $TcRule;border-radius:22px;padding:52px 18px}
.tile b{display:block;font:700 96px/1 Georgia,serif;color:$TcInk}
.tile b.gold{color:$TcGold}
.tile i{display:block;font:400 30px/1.2 Georgia,serif;font-style:normal;color:$TcMut;
  margin-top:18px;letter-spacing:.06em;text-transform:uppercase}
.list{width:100%;text-align:left}
.row{display:flex;align-items:baseline;gap:22px;padding:26px 0;border-bottom:2px solid $TcRule}
.row:last-child{border-bottom:0}
.row .n{flex:1 1 auto;font:400 46px/1.2 Georgia,serif}
.row .a{flex:0 0 auto;font:400 38px/1.2 ui-monospace,Consolas,monospace;color:$TcMut}
.more{font:400 34px/1.2 Georgia,serif;color:$TcMut;padding-top:28px;text-align:center}
.math{font:400 62px/1.5 Georgia,serif;color:$TcMut}
.math b{font-weight:700;color:$TcGold}
.vs{display:flex;flex-direction:column;gap:30px;width:100%}
.vs div{display:flex;justify-content:space-between;align-items:baseline;
  border-bottom:2px solid $TcRule;padding-bottom:24px}
.vs span{font:400 48px/1.2 Georgia,serif;color:$TcMut}
.vs em{font:700 78px/1 Georgia,serif;font-style:normal;color:$TcInk}
.vs em.gold{color:$TcGold}
.save{font:700 88px/1.1 Georgia,serif;color:$TcGreen;margin-top:46px}
.fine{font:400 27px/1.3 Georgia,serif;color:$TcMut;margin-top:34px;letter-spacing:.02em}
.dark .fine{color:#9a9182}
.free{display:inline-block;border:3px solid $TcGold;color:$TcGold;border-radius:999px;
  padding:20px 46px;font:600 40px/1 Georgia,serif;letter-spacing:.14em;text-transform:uppercase}
.url{font:700 66px/1.2 Georgia,serif;color:$TcCream;margin-top:52px}
.stamp{font:400 26px/1.3 Georgia,serif;color:#9a9182;margin-top:38px}
"@

$scenes = New-Object System.Collections.Generic.List[object]

function Add-Scene {
  param([string]$Id, [string]$Vo, [string]$Caption, [string]$Body, [switch]$Dark)
  $shell = if ($Dark) { 'dark' } else { 'paper' }
  $html = @"
<!doctype html><html lang="en"><head><meta charset="utf-8"><style>$css</style></head>
<body class="$shell"><div class="f">
<div class="mark">Thrifty Crew</div>
<div class="body">$Body</div>
<div class="cap"><span>$Caption</span></div>
<div class="pad"></div>
</div></body></html>
"@
  $scenes.Add([pscustomobject]@{ Id = $Id; Vo = $Vo; Html = $html })
}

function HtmlEnc { param([string]$S) [System.Net.WebUtility]::HtmlEncode($S) }

$moneyPs    = Format-Money $cheapestPs
$moneyBatch = Format-Money $batchCost
$speakPs    = Get-MoneySpeech $cheapestPs
$speakBatch = Get-MoneySpeech $batchCost
$takeout    = [math]::Round($TakeoutPlate * $servings, 2)
$saved      = [math]::Round($takeout - $batchCost, 2)
$titleClass = if ($name.Length -gt 30) { 'title long' } else { 'title' }

# 1. hook
Add-Scene -Dark -Id 'hook' `
  -Vo "$speakPs a serving. Here is what that buys you." `
  -Caption "$moneyPs a serving." `
  -Body ('<div class="eyebrow">Omaha &middot; this week</div><div class="money">' + $moneyPs + '</div><div class="sub">per serving</div>')

# 2. title
$dek = if ($cuisine) { "$cuisine &middot; $servings servings" } else { "$servings servings" }
Add-Scene -Id 'title' `
  -Vo "$name. One batch, $(ConvertTo-Words $servings) dinners." `
  -Caption (HtmlEnc $name) `
  -Body ('<div class="' + $titleClass + '">' + (HtmlEnc $name) + '</div><div class="dek">' + $dek + '</div>')

# 3. macros
Add-Scene -Id 'macros' `
  -Vo "$(ConvertTo-Words $proteinG) grams of protein, $(ConvertTo-Words $calories) calories a bowl." `
  -Caption "${proteinG}g protein &middot; $calories calories" `
  -Body ('<div class="tiles">' +
         '<div class="tile"><b>' + $proteinG + 'g</b><i>protein</i></div>' +
         '<div class="tile"><b>' + $calories + '</b><i>calories</i></div>' +
         '<div class="tile"><b class="gold">' + $moneyPs + '</b><i>a serving</i></div>' +
         '</div>')

function Format-List {
  param($Rows, [int]$More)
  $h = '<div class="list">'
  foreach ($r in $Rows) {
    $h += '<div class="row"><span class="n">' + (HtmlEnc $r.Name) + '</span><span class="a">' + (HtmlEnc $r.Amount) + '</span></div>'
  }
  $h += '</div>'
  if ($More -gt 0) { $h += '<div class="more">+ ' + $More + ' more on the page</div>' }
  return $h
}

# 4. the list, one frame.
$listVo = if ($overflow -gt 0) {
  "The big stuff, priced at this week's cheapest Omaha shelf. $(ConvertTo-Words $overflow) more on the page."
} else {
  "The whole shopping list, priced at this week's cheapest Omaha shelf. Nothing fancy."
}
Add-Scene -Id 'list' `
  -Vo $listVo `
  -Caption 'The shopping list' `
  -Body (Format-List -Rows $shown -More $overflow)

# 6. batch math (shown as arithmetic because cheapest_ps IS a whole-package total over 14)
Add-Scene -Id 'batch' `
  -Vo "$(ConvertTo-Words $servings) servings at $speakPs. That is $speakBatch for the whole batch." `
  -Caption "$servings &times; $moneyPs = $moneyBatch" `
  -Body ('<div class="math">' + $servings + ' servings &times; ' + $moneyPs + '<br><b>' + $moneyBatch + ' for the batch</b></div>')

# 7. comparison (assumption printed on the frame)
Add-Scene -Id 'compare' `
  -Vo "Buy the same $(ConvertTo-Words $servings) dinners out at $(Get-MoneySpeech $TakeoutPlate) a plate and you have spent $(Get-MoneySpeech $takeout). One recipe, one week, $(Get-MoneySpeech $saved) back in your pocket." `
  -Caption "One recipe. $(Format-Money $saved) back." `
  -Body ('<div class="vs">' +
         '<div><span>Takeout, ' + $servings + ' plates</span><em>' + (Format-Money $takeout) + '</em></div>' +
         '<div><span>This batch</span><em class="gold">' + $moneyBatch + '</em></div>' +
         '</div><div class="save">You keep ' + (Format-Money $saved) + '</div>' +
         '<div class="fine">Takeout figure assumes ' + (Format-Money $TakeoutPlate) + ' a plate. Batch cost is the cheapest whole-package price across our Omaha board, week of ' + $weekOf + '.</div>')

# 8. cta
$ctaBadge = if ($isFree) { '<div class="free">Free this week</div>' } else { '' }
$ctaVo    = if ($isFree) { 'Free this week at thrifty crew dot com.' } else { 'Full recipe at thrifty crew dot com.' }
$ctaCap   = if ($isFree) { 'Free this week at thriftycrew.com' } else { 'Full recipe at thriftycrew.com' }
Add-Scene -Dark -Id 'cta' `
  -Vo $ctaVo -Caption $ctaCap `
  -Body ($ctaBadge + '<div class="url">thriftycrew.com</div>' +
         '<div class="stamp">Real shelf prices, seven Omaha stores, updated weekly.</div>')

# ---------------------------------------------------------------- render

if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $WorkDir, $OutDir | Out-Null

function ConvertTo-CmdArg {
  # Start-Process -ArgumentList <array> does NOT quote members containing spaces in PS5.1: the
  # voiceover line arrives at the child as a dozen separate argv entries. Quote them ourselves.
  param([string]$A)
  if ($A -eq '') { return '""' }
  if ($A -notmatch '[\s"]') { return $A }
  $e = [regex]::Replace($A, '(\\*)"', '$1$1\"')   # double the backslashes that precede a quote
  $e = [regex]::Replace($e, '(\\+)$', '$1$1')     # and those that would escape the closing quote
  return '"' + $e + '"'
}

function Invoke-Tool {
  param([string]$Exe, [string[]]$ArgList, [string]$Tag)
  $so = Join-Path $WorkDir "$Tag.out.txt"
  $se = Join-Path $WorkDir "$Tag.err.txt"
  $line = ($ArgList | ForEach-Object { ConvertTo-CmdArg $_ }) -join ' '
  $p = Start-Process -FilePath $Exe -ArgumentList $line -Wait -PassThru -NoNewWindow `
                     -RedirectStandardOutput $so -RedirectStandardError $se
  if ($p.ExitCode -ne 0) {
    $tail = (Get-Content $se -ErrorAction SilentlyContinue | Select-Object -Last 12) -join "`n"
    throw "$Tag failed (exit $($p.ExitCode)):`n$tail"
  }
}

Write-Output ''
Write-Output "Rendering $($scenes.Count) scenes..."
foreach ($s in $scenes) {
  $htmlPath = Join-Path $WorkDir "$($s.Id).html"
  $pngPath  = Join-Path $WorkDir "$($s.Id).png"
  # UTF8 with BOM would show as stray characters; the meta charset covers the no-BOM case.
  [System.IO.File]::WriteAllText($htmlPath, $s.Html, (New-Object System.Text.UTF8Encoding $false))
  $url = 'file:///' + $htmlPath.Replace('\', '/')
  Invoke-Tool -Exe $Chrome -Tag "chrome-$($s.Id)" -ArgList @(
    '--headless=new', '--disable-gpu', '--hide-scrollbars',
    "--screenshot=$pngPath", '--window-size=1080,1920', $url)
  if (-not (Test-Path $pngPath)) { throw "Chrome produced no frame for scene '$($s.Id)'." }
  Add-Member -InputObject $s -NotePropertyName Png -NotePropertyValue $pngPath
}

# ---------------------------------------------------------------- voiceover

function Get-MediaDuration {
  param([string]$Path)
  $out = & $FFprobe -v error -show_entries format=duration -of csv=p=0 $Path
  $d = 0.0
  if (-not [double]::TryParse(([string]$out).Trim(), [ref]$d)) { throw "ffprobe could not read a duration from $Path" }
  return $d
}

if ($VoiceSamples) {
  $sampleDir = Join-Path $OutDir 'voice-samples'
  New-Item -ItemType Directory -Force -Path $sampleDir | Out-Null
  $line = "$speakPs a serving. $name. $(ConvertTo-Words $proteinG) grams of protein a bowl. Free this week at thrifty crew dot com."
  foreach ($v in @('en-US-AndrewNeural', 'en-US-BrianNeural', 'en-US-ChristopherNeural', 'en-US-GuyNeural', 'en-US-SteffanNeural')) {
    $mp3 = Join-Path $sampleDir "$v.mp3"
    Invoke-Tool -Exe $Python -Tag "tts-$v" -ArgList @('-m', 'edge_tts', '--voice', $v, "--rate=$RatePct%", '--text', $line, '--write-media', $mp3)
    Write-Output "  $v"
  }
  Write-Output ''
  Write-Output "Voice samples: $sampleDir"
  return
}

$LeadIn = 0.20
$TailPad = 0.45

foreach ($s in $scenes) {
  if ($NoVoice) {
    Add-Member -InputObject $s -NotePropertyName Mp3 -NotePropertyValue $null
    Add-Member -InputObject $s -NotePropertyName Dur -NotePropertyValue 3.2
    continue
  }
  $mp3 = Join-Path $WorkDir "$($s.Id).mp3"
  Invoke-Tool -Exe $Python -Tag "tts-$($s.Id)" -ArgList @(
    '-m', 'edge_tts', '--voice', $Voice, "--rate=$RatePct%", '--text', $s.Vo, '--write-media', $mp3)
  if (-not (Test-Path $mp3)) { throw "edge-tts produced no audio for scene '$($s.Id)'." }
  $d = Get-MediaDuration $mp3
  Add-Member -InputObject $s -NotePropertyName Mp3 -NotePropertyValue $mp3
  Add-Member -InputObject $s -NotePropertyName Dur -NotePropertyValue ([math]::Round($LeadIn + $d + $TailPad, 2))
}
if (-not $NoVoice) { Write-Output "Voiceover: $Voice at $RatePct%" }

# ---------------------------------------------------------------- video
# One self-contained clip per scene, then a stream-copy concat. Encoding each scene to its exact
# duration keeps audio and video locked together; a single xfade graph would drift them apart.

$fps = 30
$clipList = New-Object System.Collections.Generic.List[string]
$i = 0
foreach ($s in $scenes) {
  $frames = [int][math]::Ceiling($s.Dur * $fps)
  # Upscale before zoompan: zooming a 1:1 still visibly stair-steps.
  # Commas inside the z= expression are protected by the single quotes. Do NOT also backslash them:
  # ffmpeg unescapes once, so quoting AND escaping leaves a literal backslash and the expression dies.
  $zoom = if ($i % 2 -eq 0) { 'min(1+0.00075*on,1.10)' } else { 'max(1.10-0.00075*on,1.0)' }
  $vf = "scale=1620:2880,zoompan=z='$zoom':d=$frames" +
        ":x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=1080x1920:fps=$fps,format=yuv420p"
  $clip = Join-Path $WorkDir ("clip-{0:d2}-{1}.mp4" -f $i, $s.Id)
  $delayMs = [int]($LeadIn * 1000)

  $ffArgs = @('-y', '-hide_banner', '-loglevel', 'error', '-loop', '1', '-i', $s.Png)
  if ($s.Mp3) {
    $ffArgs += @('-i', $s.Mp3, '-filter_complex', "[0:v]$vf[v];[1:a]adelay=$delayMs|$delayMs,apad[a]",
                 '-map', '[v]', '-map', '[a]')
  } else {
    $ffArgs += @('-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo',
                 '-filter_complex', "[0:v]$vf[v]", '-map', '[v]', '-map', '1:a')
  }
  $ffArgs += @('-t', $s.Dur.ToString([System.Globalization.CultureInfo]::InvariantCulture),
               '-r', $fps, '-c:v', 'libx264', '-preset', 'medium', '-crf', '20',
               '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '192k', '-ar', '48000', '-ac', '2', $clip)

  Invoke-Tool -Exe $FFmpeg -Tag "clip-$($s.Id)" -ArgList $ffArgs
  $clipList.Add($clip)
  $i++
}

$listFile = Join-Path $WorkDir 'concat.txt'
$lines = foreach ($c in $clipList) { "file '" + $c.Replace('\', '/') + "'" }
[System.IO.File]::WriteAllLines($listFile, $lines, (New-Object System.Text.UTF8Encoding $false))

$stamp = Get-Date -Format 'yyyy-MM-dd'
$final = Join-Path $OutDir "$stamp-$pick.mp4"
Invoke-Tool -Exe $FFmpeg -Tag 'concat' -ArgList @(
  '-y', '-hide_banner', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', $listFile,
  '-c', 'copy', '-movflags', '+faststart', $final)

if (-not (Test-Path $final)) { throw 'Concat produced no output file.' }
$totalDur = Get-MediaDuration $final
if ($totalDur -gt 90) { Write-Warning "Reel is $([math]::Round($totalDur,1))s. Facebook Reels caps at 90s." }

# ---------------------------------------------------------------- caption + state

$hashtags = '#omaha #mealprep #groceryhaul #budgetmeals #frugalliving #thriftycrew'
$caption = @"
$name for $moneyPs a serving.

$servings servings out of one batch, $(Format-Money $batchCost) total, ${proteinG}g of protein a bowl. Priced at the cheapest whole-package price across seven Omaha stores, week of $weekOf.

$(if ($isFree) { "Full recipe is free this week at thriftycrew.com" } else { "Full recipe at thriftycrew.com" })

$hashtags
"@
$captionFile = Join-Path $OutDir "$stamp-$pick.txt"
[System.IO.File]::WriteAllText($captionFile, $caption, (New-Object System.Text.UTF8Encoding $false))

$used = @($state.used) + @([pscustomobject]@{ slug = $pick; date = $stamp; per_serving = $cheapestPs; week_of = $weekOf })
$newState = [pscustomobject]@{
  readme = 'Reels already published, newest last. build-reel.ps1 avoids repeats until the pool is exhausted.'
  used   = $used
}
[System.IO.File]::WriteAllText($StateFile, ($newState | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))

if (-not $KeepFrames) { Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }

Write-Output ''
Write-Output "Reel    : $final"
Write-Output "Length  : $([math]::Round($totalDur,1))s"
Write-Output "Size    : $([math]::Round((Get-Item $final).Length / 1MB, 1)) MB"
Write-Output "Caption : $captionFile"
