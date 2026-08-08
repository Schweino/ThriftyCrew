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
  # The house narrator, matched to the demo reel so the two reels on the same Page do not arrive in
  # two slightly different voices. Names resolve in voices.ps1; full Microsoft ids also work.
  [string] $Voice        = 'Goku',
  # Set to run the reel as a two-hander: scenes alternate between $Voice and $Voice2. $Voice keeps the
  # hook and the CTA (the brand moments book-end the reel in one voice) and the second voice takes the
  # scenes in between, so a viewer hears a conversation rather than a handover.
  [string] $Voice2       = '',
  # A jolly read is tempo and pitch as much as it is casting: the same voice at -5% reads sober and
  # at +6% with a few Hz of lift reads upbeat. Both are exposed so the delivery can be tuned without
  # changing voice, and -VoiceSamples renders at whatever is set here so a sample is what would ship.
  [int]    $RatePct      = -5,
  [int]    $PitchHz      = 0,
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

# edge-tts validates rate against ^[+-]\d+%$ and pitch against the same shape in Hz: BOTH need an
# explicit sign and a bare "6%" is rejected outright. The default -5% hid this for weeks because a
# negative number brings its own sign; the first positive value passed is the one that fails.
# Defined up here because -VoiceSamples runs well before the main voiceover loop.
$script:RateStr  = "--rate=$(if ($RatePct -ge 0) { '+' })$RatePct%"
$script:PitchArg = if ($PitchHz -ne 0) { @("--pitch=$(if ($PitchHz -gt 0) { '+' })${PitchHz}Hz") } else { @() }

# ---------------------------------------------------------------- number to speech
# Neural TTS reads "$1.63" inconsistently (sometimes "one point six three dollars"), so money is
# spelled out. Those rules live in speech.ps1 so build-demo-reel.ps1 shares them rather than keeping
# a second copy. Functions only: dot-sourcing it cannot clobber this script's params.
. (Join-Path $PSScriptRoot 'speech.ps1')

# ---------------------------------------------------------------- the narrator
# House names to Microsoft ids, once, up front: a typo fails here with a list of valid names rather
# than as an opaque refusal from the service after every frame has already rendered.
. (Join-Path $PSScriptRoot 'voices.ps1')
$Voice = Resolve-Voice $Voice
if ($Voice2) {
  # -Voice2 alternated the narrator scene by scene, which required rendering a scene at a time. That
  # is exactly the thing that made the voiceover sound synthetic (six gaps of 1.16-1.23s per reel,
  # one at every boundary), so the narration is now a single continuous read and two voices cannot
  # share one. Refusing loudly rather than silently ignoring the flag or quietly keeping the old
  # padded path alive, since a worse code path nobody notices is how the bug comes back.
  throw ("-Voice2 (two-hander) is not supported since the narration became one continuous take. " +
         "Reinstating it means rendering per scene again and taking back ~7s of dead air per reel.")
}

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

# EVERY ingredient, always, on ONE frame. Brad's rule, 2026-08-05, and it is about how the reel is
# actually used: people PAUSE AND SCREENSHOT the list to shop from it. A capped list ("+3 more on the
# page") makes that screenshot useless, and splitting across two frames is worse - a screenshot
# catches half a list and the reader does not know it. Both were tried and both are wrong.
# So the list never truncates; the TYPE scales to fit instead.
$shown = $ingredients

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
.row{display:flex;align-items:baseline;gap:22px;padding:var(--rp,26px) 0;border-bottom:2px solid $TcRule}
.row:last-child{border-bottom:0}
.row .n{flex:1 1 auto;font:400 var(--rf,46px)/1.2 Georgia,serif}
.row .a{flex:0 0 auto;font:400 var(--ra,38px)/1.2 ui-monospace,Consolas,monospace;color:$TcMut}
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
.ask{font:600 44px/1.2 Georgia,serif;letter-spacing:.14em;text-transform:uppercase;
  color:$TcGold;margin-top:40px}
.hookline{font:400 62px/1.15 Georgia,serif;color:$TcCream;margin-bottom:10px}
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
$titleClass = if ($name.Length -gt 30) { 'title long' } else { 'title' }

# 1. hook
# Leads on the BATCH total, not the per-serving price. "$1.45 a serving" is true but small and
# abstract; "14 dinners for $20.30" is the same fact in the shape that stops a thumb, because the
# viewer can picture both halves of it. Posed as a question on purpose: measured on this voice, a
# declarative sentence with a question mark rises hard (+81 Hz on the final word), while a rhetorical
# "guess what this costs?" falls flat and lands like a statement. Brad's instinct, 2026-08-08.
#
# 300px type overflows 1080 past five characters, so a longer total steps down a size rather than
# running off the frame.
$moneyClass = if ($moneyBatch.Length -gt 5) { 'money sm' } else { 'money' }
# ${speakBatch} rather than $speakBatch below: "?" is a LEGAL character in a PowerShell variable name,
# so "$speakBatch?" parses as a variable called speakBatch?, and fails at runtime rather than at parse
# time. Any interpolation immediately followed by punctuation needs the braces.
Add-Scene -Dark -Id 'hook' `
  -Vo "$(ConvertTo-Words $servings) dinners out of one batch, for ${speakBatch}? Come see." `
  -Caption "$servings dinners for $moneyBatch." `
  -Body ('<div class="eyebrow">Omaha &middot; this week</div>' +
         '<div class="hookline">' + $servings + ' dinners for</div>' +
         '<div class="' + $moneyClass + '">' + $moneyBatch + '</div>' +
         '<div class="sub">the whole batch</div>')

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
  <# Fits N rows into the frame's usable band by scaling type, so the list NEVER truncates. #>
  param($Rows)
  $n = [math]::Max(1, @($Rows).Count)
  # .body's usable band: 1920 tall, less the 200px masthead, the 300px caption and the 360px pad the
  # Facebook chrome sits over, less its own 120px bottom padding. About 940px of real estate.
  $perRow  = 940 / $n
  $rowFont = [int][math]::Max(24, [math]::Min(46, [math]::Floor($perRow * 0.60)))
  $amtFont = [int][math]::Max(20, [math]::Floor($rowFont * 0.82))
  $rowPad  = [int][math]::Max(5,  [math]::Min(26, [math]::Floor(($perRow - $rowFont * 1.2) / 2)))
  $h = ('<div class="list" style="--rf:{0}px;--ra:{1}px;--rp:{2}px">' -f $rowFont, $amtFont, $rowPad)
  foreach ($r in $Rows) {
    $h += '<div class="row"><span class="n">' + (HtmlEnc $r.Name) + '</span><span class="a">' + (HtmlEnc $r.Amount) + '</span></div>'
  }
  return $h + '</div>'
}

# 4. the list: all of it, one frame, screenshot-ready.
Add-Scene -Id 'list' `
  -Vo "The whole shopping list, priced at this week's cheapest Omaha shelf. Screenshot it." `
  -Caption 'The whole list. Screenshot it.' `
  -Body (Format-List -Rows $shown)

# 6. batch math (shown as arithmetic because cheapest_ps IS a whole-package total over 14)
Add-Scene -Id 'batch' `
  -Vo "$(ConvertTo-Words $servings) servings at $speakPs. That is $speakBatch for the whole batch." `
  -Caption "$servings &times; $moneyPs = $moneyBatch" `
  -Body ('<div class="math">' + $servings + ' servings &times; ' + $moneyPs + '<br><b>' + $moneyBatch + ' for the batch</b></div>')

# 7. comparison. NOT "14 takeout plates you never would have bought" (Brad, 2026-08-05): nobody eats
# out 14 times, so a $146 "you keep" is a number the reader knows is fake, and a fake number standing
# next to $1.57 makes the reader doubt the $1.57 too. Compare the batch to ONE plate instead, which is
# a purchase they actually make, and let the ratio carry the message.
$plates = [math]::Ceiling($batchCost / $TakeoutPlate)
$ratioLine = if ($batchCost -le $TakeoutPlate) {
  "$servings dinners for less than one plate"
} else {
  "$servings dinners for the price of $(ConvertTo-Words $plates)"
}
$ratioVo = if ($batchCost -le $TakeoutPlate) {
  "$(ConvertTo-Words $servings) dinners for less than the price of one plate."
} else {
  "$(ConvertTo-Words $servings) dinners for the price of $(ConvertTo-Words $plates) of them."
}
# The board's own value, and unlike the takeout figure this one is measured, not assumed: it is the
# gap between everyday_ps and cheapest_ps on this exact recipe this exact week.
$boardSaved = [math]::Round(($everydayPs - $cheapestPs) * $servings, 2)

Add-Scene -Id 'compare' `
  -Vo "One takeout plate runs about $(Get-MoneySpeech $TakeoutPlate). This whole batch is $speakBatch. $ratioVo" `
  -Caption "One plate out, or $servings dinners in the fridge." `
  -Body ('<div class="vs">' +
         '<div><span>One takeout plate</span><em>' + (Format-Money $TakeoutPlate) + '</em></div>' +
         '<div><span>This whole batch, ' + $servings + ' dinners</span><em class="gold">' + $moneyBatch + '</em></div>' +
         '</div><div class="save">' + $ratioLine + '</div>' +
         '<div class="fine">Plate figure assumes ' + (Format-Money $TakeoutPlate) + ', a typical Omaha lunch. Batch cost is the cheapest whole-package price across our seven-store board, week of ' + $weekOf +
         $(if ($boardSaved -gt 0) { '. Shopping the board beat everyday shelf prices by ' + (Format-Money $boardSaved) + ' on this batch' }) + '.</div>')

# 8. cta
# The site, then the ask, spoken as well as shown: a viewer watching muted needs it on screen, and a
# viewer listening needs to be told. The ask is specific rather than "engage with this post" - naming
# who to send it to gets a share in a way that asking for a share does not.
$ctaBadge = if ($isFree) { '<div class="free">Free this week</div>' } else { '' }
$ctaSite  = if ($isFree) { 'Free this week at thrifty crew dot com.' } else { 'Full recipe at thrifty crew dot com.' }
$ctaVo    = ($ctaSite + ' If this saved you money, hit like, send it to someone who feeds a family, ' +
             "and follow along for tomorrow's dinner.")
$ctaCap   = if ($isFree) { 'Free this week at thriftycrew.com' } else { 'Full recipe at thriftycrew.com' }
Add-Scene -Dark -Id 'cta' `
  -Vo $ctaVo -Caption $ctaCap `
  -Body ($ctaBadge + '<div class="url">thriftycrew.com</div>' +
         '<div class="ask">Like &middot; Share &middot; Follow</div>' +
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
  # Microsoft publishes a personality tag per voice; these are the ones tagged for warmth and energy
  # rather than authority. Lively / Cheerful / Passion / Friendly, both genders, so the pick is not
  # narrowed by an assumption about who should read it.
  $candidates = @(
    'en-US-RogerNeural',        # Lively
    'en-US-GuyNeural',          # Passion
    'en-US-BrianNeural',        # Approachable, Casual, Sincere
    'en-US-EmmaNeural',         # Cheerful, Clear, Conversational
    'en-US-AvaNeural',          # Expressive, Caring, Pleasant, Friendly
    'en-US-AriaNeural'          # Positive, Confident
  )
  foreach ($v in $candidates) {
    $mp3 = Join-Path $sampleDir "$v.mp3"
    Invoke-Tool -Exe $Python -Tag "tts-$v" -ArgList (@('-m', 'edge_tts', '--voice', $v, $script:RateStr) + $script:PitchArg + @('--text', $line, '--write-media', $mp3))
    Write-Output "  $v"
  }
  Write-Output ''
  Write-Output "Voice samples: $sampleDir"
  return
}

# ONE take for the whole reel, then the video is cut to it. Ported from build-demo-reel.ps1 on
# 2026-08-08 after the same defect was measured here: six gaps of 1.16-1.23s in a 41-second reel, one
# at every scene boundary, about seven seconds of dead air. The cause is rendering a scene at a time,
# which gives the voice a closing cadence and a cold start ten times over and then needs the seams
# padded. Reading the script straight through leaves only the voice's own ~0.44s sentence breaks.
# See reels\README.md for the measured pause table and the narration guards.

$LeadCut = 0.12
$EndHold = 0.90
$VoMp3   = Join-Path $WorkDir 'narration.mp3'

if ($NoVoice) {
  foreach ($s in $scenes) { Add-Member -InputObject $s -NotePropertyName Dur -NotePropertyValue 3.2 }
} else {
  $lineObjs = foreach ($s in $scenes) { [pscustomobject]@{ id = $s.Id; text = $s.Vo } }
  $linesFile = Join-Path $WorkDir 'lines.json'
  [System.IO.File]::WriteAllText($linesFile, (ConvertTo-Json @($lineObjs) -Depth 3),
                                 (New-Object System.Text.UTF8Encoding $false))
  # argparse eats "-5%" as a flag; "--rate=-5%" is the only form that survives.
  $ttsArgs = @((Join-Path $ReelRoot 'speak-script.py'), '--lines', $linesFile,
               '--voice', $Voice, "--rate=$(if ($RatePct -ge 0) { '+' })$RatePct%", '--out', $VoMp3)
  if ($PitchHz -ne 0) { $ttsArgs += "--pitch=$(if ($PitchHz -gt 0) { '+' })${PitchHz}Hz" }
  Invoke-Tool -Exe $Python -Tag 'tts' -ArgList $ttsArgs
  if (-not (Test-Path $VoMp3)) { throw 'speak-script.py produced no audio' }

  $timing = Get-Content "$VoMp3.timing.json" -Raw | ConvertFrom-Json
  if ($timing.drift -gt 0) {
    Write-Warning "$($timing.drift) word(s) failed to align; scene cuts may sit slightly off."
  }
  $voLen  = Get-MediaDuration $VoMp3
  $starts = @($timing.lines | ForEach-Object { [double]$_.start })
  if ($starts.Count -ne $scenes.Count) { throw 'the narration timing does not cover every scene' }

  # Cut a few frames before each line, the way an editor would: the eye should arrive before the
  # words. The last scene runs to the end of the narration plus a hold so the CTA is not yanked away.
  $cuts = New-Object System.Collections.Generic.List[double]
  foreach ($st in $starts) { $cuts.Add([math]::Max(0.0, $st - $LeadCut)) }
  $cuts.Add($voLen + $EndHold)
  for ($k = 0; $k -lt $scenes.Count; $k++) {
    $d = [math]::Round($cuts[$k + 1] - $cuts[$k], 3)
    if ($d -le 0.3) { throw "scene '$($scenes[$k].Id)' would be $d s long; the alignment is wrong" }
    Add-Member -InputObject $scenes[$k] -NotePropertyName Dur -NotePropertyValue $d
  }
}
if (-not $NoVoice) {
  $rateLabel = "$(if ($RatePct -ge 0) { '+' })$RatePct%$(if ($PitchHz -ne 0) { ", $(if ($PitchHz -gt 0) { '+' })${PitchHz}Hz" })"
  Write-Output ("Voiceover: $(Get-VoiceName $Voice) ($Voice) at $rateLabel, " +
                "one take, $([math]::Round($voLen,1))s")
}

# ---------------------------------------------------------------- video
# One self-contained clip per scene, then a stream-copy concat. Clips are SILENT: the narration is a
# single continuous file laid over the finished cut, so no scene change can gap, click or drift.

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

  $ffArgs = @('-y', '-hide_banner', '-loglevel', 'error', '-loop', '1', '-i', $s.Png,
              '-filter_complex', "[0:v]$vf[v]", '-map', '[v]', '-an',
              '-t', $s.Dur.ToString([System.Globalization.CultureInfo]::InvariantCulture),
              '-r', $fps, '-c:v', 'libx264', '-preset', 'medium', '-crf', '20',
              '-pix_fmt', 'yuv420p', $clip)

  Invoke-Tool -Exe $FFmpeg -Tag "clip-$($s.Id)" -ArgList $ffArgs
  $clipList.Add($clip)
  $i++
}

$listFile = Join-Path $WorkDir 'concat.txt'
$lines = foreach ($c in $clipList) { "file '" + $c.Replace('\', '/') + "'" }
[System.IO.File]::WriteAllLines($listFile, $lines, (New-Object System.Text.UTF8Encoding $false))

$stamp = Get-Date -Format 'yyyy-MM-dd'
$final  = Join-Path $OutDir "$stamp-$pick.mp4"
$joined = Join-Path $WorkDir 'joined.mp4'
Invoke-Tool -Exe $FFmpeg -Tag 'concat' -ArgList @(
  '-y', '-hide_banner', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', $listFile,
  '-c', 'copy', $joined)
if (-not (Test-Path $joined)) { throw 'Concat produced no output file.' }

# ---------------------------------------------------------------- audio finishing
# Same chain as build-demo-reel.ps1, and it is measured, not taste. Raw edge-tts lands at about
# -21.5 LUFS, which on a phone speaker in a feed at half volume is close to inaudible; this brings it
# to -14. It does NOT make the voice less synthetic (that is prosody, and no filter re-times a
# syllable). reels\README.md carries the full findings, including the steps that failed measurement.

$VoiceChain = @(
  'aresample=48000'
  'highpass=f=85'
  'equalizer=f=170:t=q:w=0.8:g=2.0'
  'equalizer=f=420:t=q:w=1.1:g=-1.5'
  'equalizer=f=2800:t=q:w=0.9:g=2.5'
  'acompressor=threshold=0.03:ratio=4:attack=8:release=160:makeup=3:knee=4:detection=rms'
  'alimiter=limit=0.7:attack=3:release=50:level=false'
) -join ','

function Get-LoudnessMeasurement {
  <# Pass one of two. Single-pass loudnorm targeting -14 measured -15.1, because the filter is
     guessing at content it has not heard. Measured per file, every run, never cached: a stored
     loudness figure outliving its audio is the same defect class as a stamped date outliving its
     data. Pass one costs about 0.07s. #>
  param([string]$Path, [string]$Filter)
  $tag = 'loudnorm-measure'
  $se  = Join-Path $WorkDir "$tag.err.txt"
  $chain = if ($Filter) { "$Filter," } else { '' }
  Invoke-Tool -Exe $FFmpeg -Tag $tag -ArgList @(
    '-hide_banner', '-i', $Path, '-af',
    ($chain + 'loudnorm=I=-14:TP=-1.5:LRA=7:print_format=json'), '-f', 'null', '-')
  $txt = Get-Content $se -Raw
  $m = [regex]::Match($txt, '\{[^{}]*"input_i"[\s\S]*?\}')
  if (-not $m.Success) { throw "loudnorm printed no measurement for $Path" }
  return $m.Value | ConvertFrom-Json
}

$muxArgs = @('-y', '-hide_banner', '-loglevel', 'error', '-i', $joined)
if ($NoVoice) {
  $muxArgs += @('-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo')
} else {
  $mixWav = Join-Path $WorkDir 'mix.wav'
  Invoke-Tool -Exe $FFmpeg -Tag 'mix' -ArgList @(
    '-y', '-hide_banner', '-loglevel', 'error', '-i', $VoMp3, '-af', $VoiceChain,
    '-ac', '2', '-ar', '48000', $mixWav)
  $ln = Get-LoudnessMeasurement -Path $mixWav
  # `offset` is deliberately NOT passed through: loudnorm applies it again in pass two, and the
  # double application measured -13.5 against the -14.2 you get by leaving it out.
  $muxArgs += @('-i', $mixWav, '-af',
    ('loudnorm=I=-14:TP=-1.5:LRA=7' +
     ":measured_I=$($ln.input_i):measured_TP=$($ln.input_tp)" +
     ":measured_LRA=$($ln.input_lra):measured_thresh=$($ln.input_thresh):linear=true"))
}

# 128k AAC and -1.5 dBTP, not 192k and -1.0: lossy encoding RAISES true peak, so a -1.0 target clips
# on some decoders after encoding.
$muxArgs += @('-map', '0:v', '-map', '1:a', '-c:v', 'copy', '-c:a', 'aac', '-b:a', '128k',
              '-ar', '48000', '-ac', '2', '-movflags', '+faststart')
if ($NoVoice) { $muxArgs += '-shortest' }
$muxArgs += $final
Invoke-Tool -Exe $FFmpeg -Tag 'mux' -ArgList $muxArgs

# Prove it landed. A loudness chain that silently no-ops looks exactly like one that worked.
if (-not $NoVoice) {
  $outLn = Get-LoudnessMeasurement -Path $final
  $gotLn = [double]$outLn.input_i
  Write-Output ("Loudness : $([math]::Round($gotLn,1)) LUFS integrated, " +
                "true peak $([math]::Round([double]$outLn.input_tp,1)) dBTP")
  if ([math]::Abs($gotLn - (-14.0)) -gt 1.0) {
    Write-Warning "Target was -14 LUFS but the finished file measures $([math]::Round($gotLn,1)). The audio chain did not do what it claims."
  }
}

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
