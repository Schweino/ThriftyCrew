<#
build-demo-reel.ps1 - a vertical Facebook Reel that shows how a Thrifty Crew recipe page WORKS.

WHY THIS EXISTS
  The daily reel (build-reel.ps1) sells a recipe: here is dinner, here is what it costs. Nobody who
  watches it learns that the page itself is a tool. The serving control, the three pricing tabs and
  the "already have it, untick it" checkboxes are the whole reason a membership is worth a dollar,
  and they are invisible from the outside. This reel is the product demo: real page, real taps, real
  numbers moving on screen.

PIPELINE
  capture-demo.py drives the LIVE page in headless Chrome and photographs each beat, writing
  demo-manifest.json with the frames AND every figure visible in them
    -> this script writes the narration FROM that manifest (never from memory of the page)
    -> Chrome renders the text cards and the frame furniture
    -> edge-tts speaks it
    -> ffmpeg composites, cuts and concatenates a 1080x1920 H.264/AAC MP4

  So the words, the captions and the pixels all trace to one capture of one page at one moment. If
  the card changes, the video changes with it or the capture fails. There is no third place where a
  number could be typed in by hand and quietly go stale.

THE FRAME (1080x1920)
     0 - 120   masthead
   120 - 1370  the phone screen, 1080x1250, exactly what capture-demo.py shoots
  1370 - 1620  caption band: the text description that introduces each new thing
  1620 - 1920  dead space, because Facebook's own UI sits over the bottom of a Reel

MUSIC
  Not baked in by default, and that is deliberate. Facebook's composer has a licensed library right
  in the upload flow; a track mixed in here has to be cleared by us instead, and the penalty for
  getting it wrong is a muted video or a copyright strike on the page. Use -Music only with a track
  you can point at a licence for (see MUSIC.md), and prefer Facebook's own library.

USAGE
  .\build-demo-reel.ps1                          # this week's #1 free recipe
  .\build-demo-reel.ps1 -Slug chicken-fried-rice-skillet
  .\build-demo-reel.ps1 -NoVoice                 # silent cut with fixed beats
  .\build-demo-reel.ps1 -SkipCapture             # rebuild the video from the frames already shot
  .\build-demo-reel.ps1 -Music ..\assets\bed.mp3 # only with a licence you can point at
#>
[CmdletBinding()]
param(
  [string] $Slug,
  # The house narrator, matched to the daily reel so both videos on the Page sound like one person.
  # Brad picked goku-podcast (Azure Dragon HD, Andrew3) on 2026-08-08. It IGNORES -RatePct: HD voices
  # do not support <prosody> and set their own pace. Names resolve in voices.ps1.
  [string] $Voice     = 'goku-podcast',
  # Measured: this voice at +0% runs 168 words per minute, which is news-anchor fast (audiobook and
  # podcast narration sits nearer 150). -8% puts it at about 156 wpm, conversational.
  # Do NOT fine-tune this in 1% steps. The engine's response is genuinely non-monotonic at that
  # granularity (-1% measured SLOWER than -3%, repeatably), because the rate hint re-plans pauses.
  # Move in 5% increments or leave it alone. -VoiceSamples renders at whatever is set here.
  [int]    $RatePct   = -8,
  [int]    $PitchHz   = 0,
  [int]    $SmallServings = 6,
  [string] $Music,
  [double] $MusicGain = 0.09,
  [string] $OutDir,
  [switch] $NoVoice,
  [switch] $SkipCapture,
  [switch] $KeepFrames,
  [switch] $VoiceSamples
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ReelRoot = $PSScriptRoot
$Income   = Split-Path $ReelRoot -Parent
if (-not $OutDir) { $OutDir = Join-Path $ReelRoot 'out' }
$WorkDir  = Join-Path $OutDir '.demo-work'
$ShotDir  = Join-Path $WorkDir 'shots'

. (Join-Path $Income 'lib\design-tokens.ps1')
. (Join-Path $ReelRoot 'speech.ps1')
. (Join-Path $ReelRoot 'voices.ps1')

# Resolve the narrator's name to a Microsoft id once, up front, so a typo fails here with a list of
# valid names rather than three minutes later as an opaque refusal from the TTS service.
$Voice = Resolve-Voice $Voice

# ---------------------------------------------------------------- tools

function Resolve-Tool {
  param([string]$Name, [string[]]$Probe)
  foreach ($p in $Probe) { if ($p -and (Test-Path $p)) { return $p } }
  $c = Get-Command $Name -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
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

# edge-tts validates rate and pitch against ^[+-]\d+(%|Hz)$: a bare "6%" is rejected, so the sign is
# always written out even when it is positive.
$script:RateStr  = "--rate=$(if ($RatePct -ge 0) { '+' })$RatePct%"
$script:PitchArg = if ($PitchHz -ne 0) { @("--pitch=$(if ($PitchHz -gt 0) { '+' })${PitchHz}Hz") } else { @() }

function ConvertTo-CmdArg {
  # Start-Process -ArgumentList <array> does NOT quote members containing spaces in PS 5.1: the
  # narration arrives at the child as a dozen separate argv entries. Quote them ourselves.
  param([string]$A)
  if ($A -eq '') { return '""' }
  if ($A -notmatch '[\s"]') { return $A }
  $e = [regex]::Replace($A, '(\\*)"', '$1$1\"')
  $e = [regex]::Replace($e, '(\\+)$', '$1$1')
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
    $tail = (Get-Content $se -ErrorAction SilentlyContinue | Select-Object -Last 15) -join "`n"
    throw "$Tag failed (exit $($p.ExitCode)):`n$tail"
  }
}

function Get-MediaDuration {
  param([string]$Path)
  $out = & $FFprobe -v error -show_entries format=duration -of csv=p=0 $Path
  $d = 0.0
  if (-not [double]::TryParse(([string]$out).Trim(), [ref]$d)) { throw "ffprobe could not read a duration from $Path" }
  return $d
}

function HtmlEnc { param([string]$S) [System.Net.WebUtility]::HtmlEncode($S) }

function Get-SpokenLine {
  <# The narration is assembled from fragments, and a spelled-out number ("twenty seven forty six")
     lands lowercase wherever a sentence happens to start with money. Harmless to the voice, but the
     script file is the artifact a person reads to check the wording, so fix the sentence case in the
     one place both the voice and the file are fed from. #>
  param([string]$Vo)
  $t = [System.Net.WebUtility]::HtmlDecode(($Vo -replace '<[^>]+>', ' ')) -replace '\s+', ' '
  $t = $t.Trim()
  if (-not $t) { return $t }
  $t = $t.Substring(0, 1).ToUpper() + $t.Substring(1)
  return [regex]::Replace($t, '([.!?]\s+)([a-z])', { $args[0].Groups[1].Value + $args[0].Groups[2].Value.ToUpper() })
}

function Get-Prop {
  # StrictMode turns a missing JSON field into a runtime error three functions away from the cause.
  # Ask for facts by name and get an honest empty back.
  param($Obj, [string]$Name)
  if ($null -eq $Obj) { return $null }
  $p = $Obj.PSObject.Properties[$Name]
  if ($null -eq $p) { return $null }
  return $p.Value
}

function ConvertTo-Amount {
  param([string]$Money)
  $t = ($Money -replace '[$,]', '').Trim()
  $d = 0.0
  if (-not [double]::TryParse($t, [ref]$d)) { throw "not a money string: '$Money'" }
  return $d
}

# ---------------------------------------------------------------- capture

if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$manifestPath = Join-Path $ShotDir 'demo-manifest.json'
if ($SkipCapture) {
  if (-not (Test-Path $manifestPath)) { throw "-SkipCapture needs an earlier capture at $manifestPath" }
  Write-Output "Reusing frames in $ShotDir"
} else {
  # A fresh directory every run. Frames left from a previous recipe are the kind of leftover that
  # silently ships: the manifest names its own files, but a half-overwritten folder makes any
  # eyeball check of "what did we shoot" a lie.
  if (Test-Path $ShotDir) { Remove-Item $ShotDir -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $ShotDir | Out-Null
  Write-Output 'Capturing the live page...'
  $capArgs = @((Join-Path $ReelRoot 'capture-demo.py'), '--out', $ShotDir,
               '--small-servings', "$SmallServings")
  if ($Slug) { $capArgs += @('--slug', $Slug) }
  Invoke-Tool -Exe $Python -Tag 'capture' -ArgList $capArgs
  if (-not (Test-Path $manifestPath)) { throw 'capture-demo.py produced no manifest' }
}

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$facts    = $manifest.facts
$shots    = @{}
foreach ($s in $manifest.scenes) { $shots[$s.id] = $s }

$name      = $facts.name
$servings  = [int]$facts.servings
$small     = [int]$facts.small_servings
$total     = $facts.total
$perServ   = $facts.per_serving
$untickTot = $facts.untick_total
$kitchen   = Get-Prop $facts 'kitchen_total'
$weekOf    = $facts.week_of
$isFree    = [bool]$facts.is_free
$protein   = Get-Prop $facts 'protein_g'

$everydayTot = $facts.tab_totals.everyday.total
$cheapestTot = $facts.tab_totals.cheapest.total
$boardGap    = [math]::Round((ConvertTo-Amount $everydayTot) - (ConvertTo-Amount $cheapestTot), 2)

# The card prints its own "saves $X versus everyday" line. If our subtraction and its sentence
# disagree, one of them is wrong and neither should be narrated. Cross-check, do not paper over.
$saveLine = Get-Prop $facts 'ct_save'
if ($saveLine -and $saveLine -match '\$([0-9]+\.[0-9]{2})') {
  $claimed = [double]$Matches[1]
  if ([math]::Abs($claimed - $boardGap) -gt 0.02) {
    throw ("The card says it saves `$$claimed versus everyday, but its own two totals differ by " +
           "`$$boardGap ($everydayTot vs $cheapestTot). Refusing to narrate either number.")
  }
}

Write-Output ''
Write-Output "Recipe   : $name ($($facts.slug))"
Write-Output "Totals   : $total customized / $everydayTot everyday / $cheapestTot cheapest"
Write-Output "Unticked : $($facts.unticked.Count) items -> $untickTot"
Write-Output "Board wk : $weekOf$(if (-not $isFree) { '  (NOT in the free rotation)' })"

# ---------------------------------------------------------------- look

$css = @"
*{margin:0;padding:0;box-sizing:border-box}
body{width:1080px;height:1920px;overflow:hidden;-webkit-font-smoothing:antialiased}
/* padding-top keeps the wordmark clear of the Ken Burns crop on the text cards: zoompan trims about
   28px off each edge at the zoom used below, which is enough to shave the top of a centred cap. */
.mast{height:120px;display:flex;align-items:center;justify-content:center;padding-top:12px;
  font:700 34px/1 Georgia,serif;letter-spacing:.30em;text-transform:uppercase}
.stage{height:1500px;display:flex;flex-direction:column;align-items:center;justify-content:center;
  text-align:center;padding:0 96px}
.hole{height:1250px;background:$TcInkDeep}
.cap{height:250px;display:flex;flex-direction:column;align-items:center;justify-content:center;
  text-align:center;padding:0 64px;background:$TcInkDeep;border-top:3px solid rgba(226,164,60,.35)}
.pad{height:300px;background:$TcInkDeep}
.eyebrow{font:600 30px/1 Georgia,serif;letter-spacing:.26em;text-transform:uppercase;
  color:$TcGold;margin-bottom:18px}
.line{font:700 62px/1.18 Georgia,serif;color:$TcCream}
.line.long{font-size:52px}
.line em{font-style:normal;color:$TcGold}
.big{font:700 104px/1.12 Georgia,serif;letter-spacing:-.015em}
.big.long{font-size:82px}
.big em{font-style:normal;color:$TcGold}
.sub{font:400 44px/1.4 Georgia,serif;margin-top:38px;opacity:.82}
.url{font:700 84px/1.2 Georgia,serif;color:$TcCream;margin-top:44px}
.free{display:inline-block;border:3px solid $TcGold;color:$TcGold;border-radius:999px;
  padding:18px 44px;font:600 34px/1 Georgia,serif;letter-spacing:.14em;text-transform:uppercase}
.stamp{font:400 28px/1.4 Georgia,serif;color:#9a9182;margin-top:34px}
/* A card is one full-bleed surface. The navy .pad only means something on a screen scene, where it
   marks the strip Facebook's UI covers; on a card it just reads as a stripe across the bottom. */
body.dark{background:$TcInkDeep;color:$TcCream}
body.dark .mast{color:$TcGold}
body.paper{background:$TcPaper;color:$TcInk}
body.paper .mast{color:$TcGoldInk}
body.paper .pad{background:$TcPaper}
body.paper .big em{color:$TcGoldInk}
body.furn{background:$TcInkDeep;color:$TcCream}
body.furn .mast{color:$TcGold}
"@

$scenes = New-Object System.Collections.Generic.List[object]

function Add-Card {
  <# A full-frame text card. These are the transitions: each one names the thing about to be shown,
     so a viewer scrubbing with the sound off still follows the demo.

     -Beat asks for the longest pause the engine can produce (0.61s against a sentence's usual 0.40s)
     AFTER this line. Use it on a line that should land before the next thing starts, and use it
     twice at most: a pause everywhere is just a slow read. #>
  param([string]$Id, [string]$Vo, [string]$Shell, [string]$Eyebrow, [string]$Big, [string]$Sub,
        [switch]$Beat)
  $cls = if ($Big.Length -gt 26) { 'big long' } else { 'big' }
  $body = ''
  if ($Eyebrow) { $body += '<div class="eyebrow">' + $Eyebrow + '</div>' }
  $body += '<div class="' + $cls + '">' + $Big + '</div>'
  if ($Sub) { $body += '<div class="sub">' + $Sub + '</div>' }
  $html = @"
<!doctype html><html lang="en"><head><meta charset="utf-8"><style>$css</style></head>
<body class="$Shell"><div class="mast">Thrifty Crew</div><div class="stage">$body</div>
<div class="pad"></div></body></html>
"@
  $scenes.Add([pscustomobject]@{ Id = $Id; Kind = 'card'; Vo = $Vo; Html = $html; Beat = [bool]$Beat })
}

function Add-Screen {
  <# A beat shot on the live page. $ShotId names a scene in the capture manifest; the caption band
     is rendered here so the words under the screen come from the same run as the pixels in it. #>
  param([string]$Id, [string]$Vo, [string]$ShotId, [string]$Eyebrow, [string]$Caption, [switch]$Beat)
  if (-not $shots.ContainsKey($ShotId)) { throw "The capture has no scene '$ShotId'" }
  $cls = if ($Caption.Length -gt 46) { 'line long' } else { 'line' }
  $html = @"
<!doctype html><html lang="en"><head><meta charset="utf-8"><style>$css</style></head>
<body class="furn"><div class="mast">Thrifty Crew</div><div class="hole"></div>
<div class="cap"><div class="eyebrow">$Eyebrow</div><div class="$cls">$Caption</div></div>
<div class="pad"></div></body></html>
"@
  $scenes.Add([pscustomobject]@{ Id = $Id; Kind = 'screen'; Vo = $Vo; Html = $html
                                 Shot = $shots[$ShotId]; Beat = [bool]$Beat })
}

# ---------------------------------------------------------------- the script
# Every figure below is read out of the manifest. Nothing here is typed from memory of the page.

$speakPer      = Get-MoneySpeech (ConvertTo-Amount $perServ)
$speakEveryday = Get-MoneySpeech (ConvertTo-Amount $everydayTot)
$speakCheapest = Get-MoneySpeech (ConvertTo-Amount $cheapestTot)
$speakGap      = Get-MoneySpeech $boardGap
$speakUntick   = Get-MoneySpeech (ConvertTo-Amount $untickTot)
$servWords     = ConvertTo-Words $servings
$smallWords    = ConvertTo-Words $small

# Written to be SPOKEN, which is a different job from written copy. Contractions, one idea per
# sentence, and a leading word before a number ("That's twenty seven forty six") because a sentence
# that opens on a spelled-out figure lands flat. Lists get an "and" before the last item: without it
# a neural voice reads the run as a data dump, with it the intonation resolves like a person's.

Add-Card -Id 'hook' -Shell 'dark' `
  -Big 'Every recipe<br>prices <em>itself</em>.' `
  -Sub 'Not a photo. A working page.' `
  -Vo "Every recipe on Thrifty Crew comes with a price tag that actually works. Here's what it does."

$introCap = "$perServ a serving &middot; $servings servings" + $(if ($protein) { " &middot; ${protein}g protein" })
Add-Screen -Id 'intro' -ShotId 'intro' -Eyebrow 'The page' -Caption $introCap `
  -Vo "$name. That's $servWords servings out of one batch, at $speakPer a plate on this week's store prices."

Add-Card -Id 'step1' -Shell 'paper' -Eyebrow 'Step one' `
  -Big 'Make it<br>your size.' `
  -Vo 'First, make it your size.'

Add-Screen -Id 'size' -ShotId 'size' -Eyebrow 'Step one' `
  -Caption "Tap it to $small. The whole page follows." `
  -Vo ("Cooking for two instead of a crowd? Tap it down to $smallWords, and the whole page follows. " +
       'Every ingredient, every gram, every dollar.')

Add-Card -Id 'step2' -Shell 'paper' -Eyebrow 'Step two' `
  -Big 'What this<br>batch <em>costs</em>.' `
  -Vo 'Second, what the batch really costs.'

Add-Screen -Id 'tabs' -ShotId 'tabs' -Eyebrow 'Step two' `
  -Caption 'Whole packages. Real shelf prices.' `
  -Vo ('These are whole packages, the way you actually buy them, priced at real stores. ' +
       'Three tabs: everyday cost, this week&#39;s cheapest, and your own.')

Add-Screen -Id 'totals' -ShotId 'totals' -Eyebrow 'Step two' `
  -Caption "$everydayTot everyday &rarr; <em>$cheapestTot</em> cheapest" `
  -Vo ("That's $speakEveryday at everyday prices, or $speakCheapest if you buy each thing where " +
       "it's cheapest. Same food, $speakGap apart.")

# The one deliberate hold in the reel. "The one people miss" is the line that has to land before the
# payoff starts, and 0.61s is the longest pause this engine will produce from text.
Add-Card -Id 'step3' -Shell 'paper' -Eyebrow 'Step three' -Beat `
  -Big 'Already have it?<br><em>Uncheck it.</em>' `
  -Vo 'And third, the one people miss.'

# "Soy sauce, brown sugar, sesame oil, black pepper and salt" reads aloud; the Title Case the card
# uses for labels does not, so speech gets its own casing and its own final "and".
$untickSpoken = @($facts.unticked | ForEach-Object { $_.name.ToLower() })
$untickPhrase = if ($untickSpoken.Count -gt 1) {
  ($untickSpoken[0..($untickSpoken.Count - 2)] -join ', ') + ' and ' + $untickSpoken[-1]
} else { $untickSpoken[0] }

$untickCap = "$total &rarr; <em>$untickTot</em>" + $(if ($kitchen) { " &middot; $kitchen already yours" })
Add-Screen -Id 'untick' -ShotId 'untick' -Eyebrow 'Step three' -Caption $untickCap -Beat `
  -Vo ("$untickPhrase are already in your cupboard. Untick them, and the total becomes what you " +
       "still have to spend. That's $servWords dinners for $speakUntick.")

$ctaVo = if ($isFree) { "And this one's free this week, at thrifty crew dot com." }
         else         { 'Full recipe at thrifty crew dot com.' }
Add-Card -Id 'cta' -Shell 'dark' -Big 'thriftycrew.com' `
  -Sub $(if ($isFree) { '<span class="free">Free this week</span>' }
         else         { 'Every recipe on the site works like this' }) `
  -Vo $ctaVo

# ---------------------------------------------------------------- voice samples

if ($VoiceSamples) {
  # The WHOLE narration in each candidate, not a stock sentence. A voice that sounds fine reading one
  # line can still be wrong over seventy seconds, and the thing being judged is the seventy seconds.
  $sampleDir = Join-Path $OutDir 'demo-voice-samples'
  New-Item -ItemType Directory -Force -Path $sampleDir | Out-Null
  $lineObjs = foreach ($s in $scenes) {
    [pscustomobject]@{ id = $s.Id; text = (Get-SpokenLine $s.Vo); beat = $s.Beat }
  }
  $linesFile = Join-Path $WorkDir 'lines.json'
  [System.IO.File]::WriteAllText($linesFile, (ConvertTo-Json @($lineObjs) -Depth 3),
                                 (New-Object System.Text.UTF8Encoding $false))
  # Everyone on the roster, named, so a sample file is identifiable without decoding a Microsoft id.
  foreach ($nm in ($script:TcVoiceAliases.Keys | Sort-Object)) {
    $v   = Resolve-Voice $nm
    $mp3 = Join-Path $sampleDir ((Get-Culture).TextInfo.ToTitleCase($nm) + '.mp3')
    # Routed per voice: the roster now spans two engines, and hardcoding one of them here would
    # fail on exactly the voices most worth auditioning.
    Invoke-Tool -Exe $Python -Tag "sample-$nm" -ArgList @(
      (Get-SpeakerScript -VoiceId $v -ReelRoot $ReelRoot), '--lines', $linesFile, '--voice', $v,
      "--rate=$(if ($RatePct -ge 0) { '+' })$RatePct%", '--out', $mp3)
    Write-Output ("  {0,-14} {1,-32} {2,5}s" -f (Get-VoiceName $v), $v, [math]::Round((Get-MediaDuration $mp3), 1))
  }
  Write-Output ''
  Write-Output "Voice samples: $sampleDir"
  return
}

# ---------------------------------------------------------------- render the frames

Write-Output ''
Write-Output "Rendering $($scenes.Count) scene frames..."
foreach ($s in $scenes) {
  $htmlPath = Join-Path $WorkDir "$($s.Id).html"
  $pngPath  = Join-Path $WorkDir "$($s.Id).png"
  [System.IO.File]::WriteAllText($htmlPath, $s.Html, (New-Object System.Text.UTF8Encoding $false))
  $url = 'file:///' + $htmlPath.Replace('\', '/')
  Invoke-Tool -Exe $Chrome -Tag "chrome-$($s.Id)" -ArgList @(
    '--headless=new', '--disable-gpu', '--hide-scrollbars',
    "--screenshot=$pngPath", '--window-size=1080,1920', $url)
  if (-not (Test-Path $pngPath)) { throw "Chrome produced no frame for scene '$($s.Id)'." }
  Add-Member -InputObject $s -NotePropertyName Png -NotePropertyValue $pngPath
}

# ---------------------------------------------------------------- voiceover
# ONE take for the whole reel, then the video is cut to it. The obvious way round (speak each scene,
# pad it, staple the clips together) is what makes AI voiceover sound like AI: ten separate
# utterances means ten closing cadences and ten cold starts, and the seams need padding on top.
# Measured on the first cut of this reel: nine gaps of 1.30-1.34s, one per scene boundary, against
# 0.43-0.45s for the voice's own sentence breaks in a continuous read. Same words, nine seconds
# shorter, and it stops sounding like a machine reading a list of sentences.
#
# LeadCut cuts the picture a few frames before the line it belongs to, which is ordinary editing
# practice: the eye should arrive before the words do.

$LeadCut = 0.12
$EndHold = 0.90
$VoMp3   = Join-Path $WorkDir 'narration.mp3'

if ($NoVoice) {
  foreach ($s in $scenes) {
    Add-Member -InputObject $s -NotePropertyName Dur -NotePropertyValue 3.4
  }
} else {
  $lineObjs = foreach ($s in $scenes) {
    [pscustomobject]@{ id = $s.Id; text = (Get-SpokenLine $s.Vo); beat = $s.Beat }
  }
  $linesFile = Join-Path $WorkDir 'lines.json'
  [System.IO.File]::WriteAllText($linesFile, (ConvertTo-Json @($lineObjs) -Depth 3),
                                 (New-Object System.Text.UTF8Encoding $false))
  # Two engines, one interface: Dragon HD voices come from Azure, everything else from the free
  # edge-tts endpoint. Both take the same arguments and emit the same timing file, because the
  # alignment and the guards live in narration.py rather than in either of them.
  $speaker = Get-SpeakerScript -VoiceId $Voice -ReelRoot $ReelRoot
  # argparse eats "-3%" as a flag; "--rate=-3%" is the only form that survives.
  $ttsArgs = @($speaker, '--lines', $linesFile,
               '--voice', $Voice, "--rate=$(if ($RatePct -ge 0) { '+' })$RatePct%", '--out', $VoMp3)
  if ($PitchHz -ne 0) { $ttsArgs += "--pitch=$(if ($PitchHz -gt 0) { '+' })${PitchHz}Hz" }
  Invoke-Tool -Exe $Python -Tag 'tts' -ArgList $ttsArgs
  if (-not (Test-Path $VoMp3)) { throw "$(Split-Path $speaker -Leaf) produced no audio" }

  $timing = Get-Content "$VoMp3.timing.json" -Raw | ConvertFrom-Json
  if ($timing.drift -gt 0) {
    Write-Warning "$($timing.drift) word(s) failed to align; scene cuts may sit slightly off."
  }
  $voLen = Get-MediaDuration $VoMp3
  $starts = @($timing.lines | ForEach-Object { [double]$_.start })
  if ($starts.Count -ne $scenes.Count) { throw 'the narration timing does not cover every scene' }

  # Cut points, then durations between them. The last scene runs to the end of the narration plus a
  # hold so the closing card is not yanked off the moment the voice stops.
  $cuts = New-Object System.Collections.Generic.List[double]
  foreach ($st in $starts) { $cuts.Add([math]::Max(0.0, $st - $LeadCut)) }
  $cuts.Add($voLen + $EndHold)
  for ($k = 0; $k -lt $scenes.Count; $k++) {
    $d = [math]::Round($cuts[$k + 1] - $cuts[$k], 3)
    if ($d -le 0.3) { throw "scene '$($scenes[$k].Id)' would be $d s long; the alignment is wrong" }
    Add-Member -InputObject $scenes[$k] -NotePropertyName Dur -NotePropertyValue $d
  }
  Write-Output ("Voiceover: $(Get-VoiceName $Voice) ($Voice) at $(if ($RatePct -ge 0) { '+' })$RatePct%, " +
                "one take, $([math]::Round($voLen,1))s")
}

# ---------------------------------------------------------------- video

$fps      = 30
$ScreenY  = 120
$ScreenH  = 1250
$clipList = New-Object System.Collections.Generic.List[string]

function Write-FrameList {
  <# ffconcat timing for a stack of stills. The action frames keep the pace the capture recorded and
     the LAST frame absorbs whatever the narration needs on top, so the beat always ends on the
     finished state rather than mid-tap. If the narration is shorter than the action, every hold
     shrinks proportionally instead of the tail being cut off. #>
  param($Frames, [double]$Total, [string]$Path)
  $holds = @($Frames | ForEach-Object { [double]$_.hold })
  $sum   = ($holds | Measure-Object -Sum).Sum
  if ($sum -le 0) { throw 'frame list has no duration' }
  if ($Total -gt $sum) {
    $holds[$holds.Count - 1] += ($Total - $sum)
  } else {
    $scale = $Total / $sum
    for ($i = 0; $i -lt $holds.Count; $i++) { $holds[$i] = $holds[$i] * $scale }
  }
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('ffconcat version 1.0')
  for ($i = 0; $i -lt $Frames.Count; $i++) {
    $lines.Add("file '" + ([string]$Frames[$i].png).Replace('\', '/') + "'")
    $lines.Add('duration ' + $holds[$i].ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture))
  }
  # The concat demuxer drops the final entry's duration unless the file is named once more.
  $lines.Add("file '" + ([string]$Frames[$Frames.Count - 1].png).Replace('\', '/') + "'")
  [System.IO.File]::WriteAllLines($Path, $lines, (New-Object System.Text.UTF8Encoding $false))
}

# Clips are SILENT. The narration is one continuous file laid over the finished cut, so there is no
# audio seam at a scene change to gap, click or drift out of sync.
$i = 0
foreach ($s in $scenes) {
  $clip   = Join-Path $WorkDir ("clip-{0:d2}-{1}.mp4" -f $i, $s.Id)
  $durStr = $s.Dur.ToString([System.Globalization.CultureInfo]::InvariantCulture)
  $ffArgs = @('-y', '-hide_banner', '-loglevel', 'error')

  if ($s.Kind -eq 'card') {
    # Ken Burns, alternating direction so consecutive cards do not feel like one long push.
    # Commas inside the z= expression are protected by the single quotes. Do NOT also backslash
    # them: ffmpeg unescapes once, so quoting AND escaping leaves a literal backslash behind.
    $frames = [int][math]::Ceiling($s.Dur * $fps)
    $zoom   = if ($i % 2 -eq 0) { 'min(1+0.0004*on,1.028)' } else { 'max(1.028-0.0004*on,1.0)' }
    $vf     = "scale=1620:2880,zoompan=z='$zoom':d=$frames" +
              ":x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=1080x1920:fps=$fps,format=yuv420p"
    $ffArgs += @('-loop', '1', '-i', $s.Png)
    $vChain  = "[0:v]$vf[v]"
  }
  elseif ($s.Shot.kind -eq 'pan') {
    # One tall capture scrolled through the window: 30fps of real pan, where a stack of stills of
    # the same content would read as a slideshow.
    $srcH  = [int]([double]$s.Shot.src_h_css * $manifest.window.dsf)
    $range = [math]::Max(0, $srcH - $ScreenH)
    $ffArgs += @('-loop', '1', '-i', $s.Png, '-loop', '1', '-i', $s.Shot.png)
    $vChain = "[1:v]fps=$fps,crop=1080:${ScreenH}:0:'min(${range}*t/${durStr},${range})',setsar=1[scr];" +
              "[0:v][scr]overlay=0:$ScreenY,format=yuv420p[v]"
  }
  else {
    $listFile = Join-Path $WorkDir "frames-$($s.Id).txt"
    Write-FrameList -Frames $s.Shot.frames -Total $s.Dur -Path $listFile
    $ffArgs += @('-loop', '1', '-i', $s.Png, '-f', 'concat', '-safe', '0', '-i', $listFile)
    $vChain = "[1:v]fps=$fps,scale=1080:${ScreenH},setsar=1[scr];" +
              "[0:v][scr]overlay=0:${ScreenY}:eof_action=repeat,format=yuv420p[v]"
  }

  $ffArgs += @('-filter_complex', $vChain, '-map', '[v]', '-an',
               '-t', $durStr, '-r', $fps, '-c:v', 'libx264', '-preset', 'medium', '-crf', '20',
               '-pix_fmt', 'yuv420p', $clip)
  Invoke-Tool -Exe $FFmpeg -Tag "clip-$($s.Id)" -ArgList $ffArgs
  $clipList.Add($clip)
  $i++
}

$concatList = Join-Path $WorkDir 'concat.txt'
$lines = foreach ($c in $clipList) { "file '" + $c.Replace('\', '/') + "'" }
[System.IO.File]::WriteAllLines($concatList, $lines, (New-Object System.Text.UTF8Encoding $false))

$stamp = Get-Date -Format 'yyyy-MM-dd'
$final = Join-Path $OutDir "$stamp-how-it-works-$($facts.slug).mp4"
$joined = Join-Path $WorkDir 'joined.mp4'
Invoke-Tool -Exe $FFmpeg -Tag 'concat' -ArgList @(
  '-y', '-hide_banner', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', $concatList,
  '-c', 'copy', $joined)
if (-not (Test-Path $joined)) { throw 'Concat produced no output file.' }

# ---------------------------------------------------------------- audio finishing
# Audio goes on LAST, in one piece, over the whole cut.
#
# What this chain is and is not for. It does NOT make the voice sound less synthetic: that tell lives
# in prosody, in where a speaker leans in and how they time a phrase, and no filter re-times a
# syllable. Measured proof that it cannot: the narration's loudness range is 3.0 LU, the content
# itself is flat, and compression makes that measurably flatter, not less.
#
# What it IS for is the reel being audible. Raw edge-tts comes out at -21.5 LUFS, which on a phone
# speaker in a noisy feed at half volume is somewhere between quiet and inaudible. Everything below
# was measured on this exact voice reading this exact script; the steps that did not survive
# measurement (de-essing, synthetic room tone, fake reverb, micro-modulation, sub-boost) are not here.

$VoiceChain = @(
  'aresample=48000'                                     # 24k source: resample once, up front
  'highpass=f=85'                                       # energy no phone speaker reproduces
  'equalizer=f=170:t=q:w=0.8:g=2.0'                     # warmth, pays off on earbuds only
  'equalizer=f=420:t=q:w=1.1:g=-1.5'                    # take out the boxiness
  'equalizer=f=2800:t=q:w=0.9:g=2.5'                    # presence: +0.7dB in the intelligibility band
  'acompressor=threshold=0.03:ratio=4:attack=8:release=160:makeup=3:knee=4:detection=rms'
  'alimiter=limit=0.7:attack=3:release=50:level=false'  # gain staging, so loudnorm is not left clamping
) -join ','

function Get-LoudnessMeasurement {
  <# loudnorm pass one. Two passes is not belt and braces: single-pass targeting -14 LUFS measured
     -15.1, because the filter is guessing at content it has not heard yet. Pass one costs about
     0.07s on a 65-second file, so there is no reason to accept the miss.

     The measurement is taken per FILE, every run, never cached. A stored loudness figure outliving
     the audio it described is the same defect class as a stamped date outliving its data. #>
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

# 1. Mix the finished audio bed (voice, plus music under it if there is any), unnormalised.
$mixWav = Join-Path $WorkDir 'mix.wav'
if ($NoVoice) {
  Invoke-Tool -Exe $FFmpeg -Tag 'mix' -ArgList @(
    '-y', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo',
    '-t', (Get-MediaDuration $joined).ToString([System.Globalization.CultureInfo]::InvariantCulture),
    '-ac', '2', $mixWav)
} else {
  $mixArgs = @('-y', '-hide_banner', '-loglevel', 'error', '-i', $VoMp3)
  if ($Music) {
    if (-not (Test-Path $Music)) { throw "Music file not found: $Music" }
    $len  = Get-MediaDuration $joined
    $fade = [math]::Max(0.5, $len - 2.5)
    $gain = $MusicGain.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $st   = $fade.ToString('0.##', [System.Globalization.CultureInfo]::InvariantCulture)
    $mixArgs += @('-stream_loop', '-1', '-i', $Music, '-filter_complex',
      ("[0:a]$VoiceChain[v];" +
       "[1:a]volume=$gain,afade=t=in:st=0:d=1.2,afade=t=out:st=${st}:d=2.2[m];" +
       '[v][m]amix=inputs=2:duration=first:dropout_transition=0[a]'), '-map', '[a]')
  } else {
    $mixArgs += @('-af', $VoiceChain)
  }
  $mixArgs += @('-ac', '2', '-ar', '48000', $mixWav)
  Invoke-Tool -Exe $FFmpeg -Tag 'mix' -ArgList $mixArgs
}

# 2. Measure the FINISHED mix, not the bare voice: music under it moves the integrated loudness, so
#    normalising the voice first and then adding music would land off target.
$muxArgs = @('-y', '-hide_banner', '-loglevel', 'error', '-i', $joined, '-i', $mixWav)
if ($NoVoice) {
  $aFilter = $null
} else {
  $ln = Get-LoudnessMeasurement -Path $mixWav
  # `offset` is deliberately NOT passed through. loudnorm applies it again in pass two, and the
  # double application measured -13.5 against the -14.2 you get by leaving it out.
  $aFilter = ('loudnorm=I=-14:TP=-1.5:LRA=7' +
              ":measured_I=$($ln.input_i):measured_TP=$($ln.input_tp)" +
              ":measured_LRA=$($ln.input_lra):measured_thresh=$($ln.input_thresh):linear=true")
  $muxArgs += @('-af', $aFilter)
}

# 128k AAC, not 192k, and -1.5 dBTP rather than -1.0: lossy encoding RAISES true peak (measured
# -1.5 in, -1.2 out at 128k, -0.4 at 64k), so a -1.0 target clips on some decoders after encoding.
$muxArgs += @('-map', '0:v', '-map', '1:a', '-c:v', 'copy', '-c:a', 'aac', '-b:a', '128k',
              '-ar', '48000', '-ac', '2', '-movflags', '+faststart')
if ($NoVoice) { $muxArgs += '-shortest' }
$muxArgs += $final
Invoke-Tool -Exe $FFmpeg -Tag 'mux' -ArgList $muxArgs

# 3. Prove it landed. A loudness chain that silently no-ops looks exactly like one that worked, and
#    at least one filter in this family (anoisesrc via -af) does precisely that.
if (-not $NoVoice) {
  $out = Get-LoudnessMeasurement -Path $final
  $got = [double]$out.input_i
  Write-Output ("Loudness : $([math]::Round($got,1)) LUFS integrated, " +
                "true peak $([math]::Round([double]$out.input_tp,1)) dBTP")
  if ([math]::Abs($got - (-14.0)) -gt 1.0) {
    Write-Warning "Target was -14 LUFS but the finished file measures $([math]::Round($got,1)). The audio chain did not do what it claims."
  }
}

$totalDur = Get-MediaDuration $final
if ($totalDur -gt 90) {
  Write-Warning "Reel is $([math]::Round($totalDur,1))s. Facebook Reels caps at 90s: trim a beat."
}

# ---------------------------------------------------------------- caption

$captionText = @"
Every Thrifty Crew recipe is a working page, not a picture of one.

Set your own serving count and the whole recipe rewrites: ingredients, grams, cost. Price the batch three ways, everyday or at this week's cheapest shelf prices. Then untick what is already in your cupboard and the total becomes what you actually still need to spend.

$name, $servings servings: $total at this week's cheapest prices, $untickTot once $(if ($kitchen) { "$kitchen of " })pantry staples come off. Board week of $weekOf.

$(if ($isFree) { "This one is free this week at thriftycrew.com" } else { "Full recipe at thriftycrew.com" })

#mealprep #groceryhaul #budgetmeals #frugalliving #mealprepsunday #thriftycrew
"@
$captionFile = Join-Path $OutDir "$stamp-how-it-works-$($facts.slug).txt"
[System.IO.File]::WriteAllText($captionFile, $captionText, (New-Object System.Text.UTF8Encoding $false))

# The narration, in one readable file. Watching a 73-second video to check a wording change is a
# slow way to review a script, and every line here was assembled from the manifest rather than
# written by hand, so it is worth being able to read the result.
$scriptLines = New-Object System.Collections.Generic.List[string]
$scriptLines.Add("$name  |  captured $($facts.captured_at)  |  board week $weekOf")
$scriptLines.Add("$($facts.url)")
$scriptLines.Add('')
foreach ($s in $scenes) {
  $scriptLines.Add(("{0,-8} {1,5}s  {2}" -f $s.Id, $s.Dur, (Get-SpokenLine $s.Vo)))
}
$scriptFile = Join-Path $OutDir "$stamp-how-it-works-$($facts.slug)-script.txt"
[System.IO.File]::WriteAllLines($scriptFile, $scriptLines, (New-Object System.Text.UTF8Encoding $false))

if (-not $KeepFrames) {
  Get-ChildItem $WorkDir -File | Where-Object { $_.Extension -in '.mp4', '.png', '.html', '.mp3', '.txt' } |
    Remove-Item -Force -ErrorAction SilentlyContinue
}

Write-Output ''
Write-Output "Reel    : $final"
Write-Output "Length  : $([math]::Round($totalDur,1))s"
Write-Output "Size    : $([math]::Round((Get-Item $final).Length / 1MB, 1)) MB"
Write-Output "Caption : $captionFile"
Write-Output "Script  : $scriptFile"
if (-not $Music) {
  Write-Output ''
  Write-Output 'No music track baked in. Add one in the Facebook composer from their licensed'
  Write-Output 'library, or see reels\MUSIC.md for free sources you can clear yourself.'
}
