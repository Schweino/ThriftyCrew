# stamp-live-price-fallback.ps1 - give every live price placeholder a fallback ON THE BASIS IT FILLS WITH.
#
# WHY (2026-09-21). A recipe price is a <span data-tc-live-price> the card script fills from the feed at view
# time (Brad: "If a pricing updates in the DB its automatically updated on all recipe pages"). Its TEXT is
# what a reader keeps when the feed does not load, and what a search engine reads. build-card2 can only write
# stat.cost_ps there, and stat.cost_ps is a DIFFERENT everyday: the recipe board's cell at the recipe's own
# package (costed.json), where the fill bills each line's cheapest non-sale store cell at the store's
# package. Measured on the canary that day: casserole fill 5.87 vs stat 6.20, fried rice 2.23 vs 2.00,
# birria 4.86 vs 4.58. A fallback on one basis standing in for a fill on another is a wrong number that
# looks right. So this runs THE CARD'S OWN SCRIPT (live-price-fill.js, jsdom, the bytes the page ships -
# never a reimplementation) against the canonical feed, and writes what it filled back as the fallback,
# stamped data-tc-asof = that feed's `generated`.
#
# FAILS CLOSED, per slug. A card whose script refuses the fill (a line with no everyday cell, an empty feed,
# node missing) is reported and NOT stamped; engine\build-cards.ps1 counts it as a build error, so the
# gated republish never ships it and engine\publish.ps1 refuses any span without a stamp. The live page
# keeps what it had. Exit 0 = every slug stamped, 1 = some refused, 2 = could not run at all.
#
# Usage (in-process, from engine\build-cards.ps1):  & stamp-live-price-fallback.ps1 -Slugs $slugs
# Self-test:  powershell -File meal-prep\pipeline\stamp-live-price-fallback.ps1 -SelfTest
param([string[]]$Slugs, [string]$BuiltDir = '', [string]$FeedPath = '', [string]$NodeExe = '', [string]$ReferenceFeedPath = '',
      [string]$JsdomEnv = 'C:\Codex\tools\jsdom-env', [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$SelfTestSlf = $SelfTest.IsPresent   # captured BEFORE the dot-source below: render-tokens rebinds $SelfTest
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = Split-Path -Parent $here
. (Join-Path $mp 'lib\render-tokens.ps1')
$SPAN_RE = '<span\s+data-tc-live-price\b[^>]*>[^<]*</span>'

function Resolve-TcNode { param([string]$Exe)
  if ($Exe) { return $Exe }
  $p = Get-ChildItem 'C:\Codex\tools' -Filter 'node-*-win-x64' -Directory -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
  if (-not $p) { return '' }
  return (Join-Path $p.FullName 'node.exe')
}

# One node process for the whole list. Returns slug -> the harness's result object.
function Invoke-TcLiveFill { param([string[]]$Paths, [string[]]$Names, [string]$Feed, [string]$Node, [string]$Jsdom, [string]$Mode = 'ok')
  $cards = @(); for ($i = 0; $i -lt $Names.Count; $i++) { $cards += @{ slug = $Names[$i]; htmlPath = $Paths[$i]; kind = 'body' } }
  $job = @{ jsdom = $Jsdom; feedPath = $Feed; feedMode = $Mode; waitMs = 4000; cards = $cards }
  $jp = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'tc-stamp-' + [guid]::NewGuid().ToString('N') + '.json')
  [IO.File]::WriteAllText($jp, ($job | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
  try { $lines = & $Node (Join-Path $here 'live-price-fill.js') $jp } finally { Remove-Item $jp -ErrorAction SilentlyContinue }
  $res = @{}; $complete = $false
  foreach ($l in @($lines)) {
    if ($l -match '^LIVE-PRICE-FILL-COMPLETE') { $complete = $true; continue }
    if ($l -match '^\{') { $o = $l | ConvertFrom-Json; $res[[string]$o.slug] = $o }
  }
  if (-not $complete) { throw 'live-price-fill.js did not print its completion marker - the harness died' }
  return $res
}

# Decide the one value a card filled with, or why it has none. Pure, so the self-test drives it directly.
function Get-TcStampValue { param($Result)
  if (-not $Result) { return @{ ok = $false; why = 'no result from the harness' } }
  if (-not $Result.ok) { return @{ ok = $false; why = ('harness: ' + $Result.error) } }
  $spans = @($Result.spans)
  if (-not $spans.Count) { return @{ ok = $false; why = 'card carries no live price placeholder' } }
  $vals = @($spans | ForEach-Object { [string]$_.filled } | Sort-Object -Unique)
  if ($vals -contains '') { return @{ ok = $false; why = ('the card script REFUSED the fill on ' + @($spans | Where-Object { -not $_.filled }).Count + ' of ' + $spans.Count + ' span(s): a line has no everyday cell in this feed, or the feed did not load') } }
  if ($vals.Count -ne 1) { return @{ ok = $false; why = ('spans filled with different values: ' + ($vals -join ', ')) } }
  $d = 0.0
  if (-not [double]::TryParse($vals[0], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d) -or -not ($d -gt 0)) { return @{ ok = $false; why = ('filled value ' + $vals[0] + ' is not a positive price') } }
  return @{ ok = $true; value = $vals[0] }
}

function Set-TcStampedSpans { param([string]$Html, [string]$Slug, [string]$Value, [string]$AsOf)
  $span = Format-TcLivePriceSpan -Slug $Slug -Field 'cost_ps' -Value $Value -AsOf $AsOf
  return [regex]::Replace($Html, $SPAN_RE, [System.Text.RegularExpressions.MatchEvaluator] { param($m) $span })
}

if ($SelfTestSlf) {
  $script:f = 0; $script:n = 0
  function T($m, $c, $g) { $script:n++; if ($c) { Write-Output ('ok    ' + $m) } else { Write-Output ('FAIL  ' + $m + '   got: ' + $g); $script:f++ } }
  $mk = { param($filled) [pscustomobject]@{ ok = $true; spans = @($filled | ForEach-Object { [pscustomobject]@{ filled = $_ } }) } }
  $v = Get-TcStampValue (& $mk @('5.87', '5.87', '5.87'))
  T 'CLEAN TWIN  every span filled with one value -> that value is the fallback' ($v.ok -and $v.value -eq '5.87') ($v | ConvertTo-Json -Compress)
  $v = Get-TcStampValue (& $mk @('5.87', ''))
  T 'MUST FIRE  a span the card script refused to fill is not stamped (fails closed)' (-not $v.ok -and $v.why -match 'REFUSED') $v.why
  $v = Get-TcStampValue (& $mk @('5.87', '6.20'))
  T 'MUST FIRE  two spans on one card filling differently is refused' (-not $v.ok -and $v.why -match 'different') $v.why
  $v = Get-TcStampValue ([pscustomobject]@{ ok = $true; spans = @() })
  T 'MUST FIRE  a card with no placeholder is refused' (-not $v.ok) $v.why
  $v = Get-TcStampValue (& $mk @('0.00'))
  T 'MUST FIRE  a filled value of 0.00 is refused (the bar is > 0)' (-not $v.ok) $v.why
  $v = Get-TcStampValue (& $mk @('0.01'))
  T 'AT BAR  a filled value of 0.01, one cent above the bar, is stamped' ($v.ok) $v.why
  $old = 'a <span data-tc-live-price data-tc-slug="x" data-tc-field="cost_ps" data-tc-basis="feed-everyday-whole-package" data-tc-fallback="6.20">~$6.20</span> b <span data-tc-live-price>current release price loading</span>'
  $new = Set-TcStampedSpans -Html $old -Slug 'x' -Value '5.87' -AsOf '2026-09-21T05:22:59'
  T 'CLEAN TWIN  stamping rewrites EVERY span, legacy ones included, to the filled value with its as-of' `
    (([regex]::Matches($new, 'data-tc-fallback="5\.87" data-tc-asof="2026-09-21T05:22:59">~\$5\.87</span>')).Count -eq 2 -and $new.StartsWith('a ') -and $new -match ' b ') $new

  # THE REAL SCRIPT, END TO END, when this box has node, jsdom and a built card: a feed that fails to load
  # must leave nothing stampable (MUST FIRE), and a working feed must fill (CLEAN TWIN). Hermetic otherwise.
  $node = Resolve-TcNode $NodeExe
  $card = Join-Path $mp 'db\built\turkey-wild-rice-casserole.body.html'
  # A FROZEN feed subset (the casserole's 18 bids, 2026-09-21), never the live one: a feed move must not
  # turn a push red. The card is the real built one, so the template it carries is what is exercised.
  $feed = Join-Path $here 'fixtures\live-price-feed-casserole.json'
  if ($node -and (Test-Path $node) -and (Test-Path (Join-Path $JsdomEnv 'node_modules\jsdom')) -and (Test-Path $card) -and (Test-Path $feed)) {
    $r = Invoke-TcLiveFill -Paths @($card) -Names @('turkey-wild-rice-casserole') -Feed $feed -Node $node -Jsdom $JsdomEnv -Mode 'fail'
    $v = Get-TcStampValue $r['turkey-wild-rice-casserole']
    $fb = @(@($r['turkey-wild-rice-casserole'].spans) | Where-Object { $_.text -notmatch '^~\$\d+\.\d\d$' }).Count
    T 'MUST FIRE  (real card script, jsdom) with the feed unreachable nothing is stamped, and every span still shows a price' (-not $v.ok -and $fb -eq 0) ($v.why + ' / non-price spans=' + $fb)
    $r = Invoke-TcLiveFill -Paths @($card) -Names @('turkey-wild-rice-casserole') -Feed $feed -Node $node -Jsdom $JsdomEnv -Mode 'ok'
    $v = Get-TcStampValue $r['turkey-wild-rice-casserole']
    T 'CLEAN TWIN  (real card script, jsdom) with the feed loaded every span fills with one positive value' ($v.ok) $v.why
  } else { Write-Output 'note  node/jsdom/card/feed not all present on this box: the end-to-end cases did not run (the pure cases above did)' }
  # THE FEED-AGE REFUSAL, run as the real script in a child (2026-09-23). Frozen feeds carry the founding dates: a
  # worktree seeded from 2026-09-22T08:14:34 while readers were served 2026-09-23T00:21:31.
  $ft = Join-Path ([IO.Path]::GetTempPath()) ('tc-slf-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $ft -ErrorAction Stop | Out-Null
  try {
    [IO.File]::WriteAllText((Join-Path $ft 'old.json'), '{"schema":2,"generated":"2026-09-22T08:14:34","recipes":{},"pricing_inputs":{}}')
    [IO.File]::WriteAllText((Join-Path $ft 'cur.json'), '{"schema":2,"generated":"2026-09-23T00:21:31","recipes":{},"pricing_inputs":{}}')
    $card0 = Join-Path $ft 'fixture-bowl.body.html'
    $body0 = '<p><span data-tc-live-price data-tc-slug="fixture-bowl" data-tc-field="cost_ps" data-tc-basis="feed-everyday-whole-package" data-tc-fallback="3.58">~$3.58</span></p>'
    [IO.File]::WriteAllText($card0, $body0)
    $self = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    $o1 = @(& powershell -NoProfile -File $self -Slugs 'fixture-bowl' -BuiltDir $ft -FeedPath (Join-Path $ft 'old.json') -ReferenceFeedPath (Join-Path $ft 'cur.json')); $rc1 = $LASTEXITCODE
    $t1 = $o1 -join ' | '
    T 'MUST FIRE  a day-old seeded feed (2026-09-22T08:14:34) against the served one (2026-09-23T00:21:31) refuses: exit 2, both dates named, the card untouched' `
      ($rc1 -eq 2 -and $t1 -cmatch 'STAMP: REFUSED' -and $t1 -match '2026-09-22T08:14:34' -and $t1 -match '2026-09-23T00:21:31' -and [IO.File]::ReadAllText($card0) -eq $body0) ("rc=$rc1 " + $t1)
    $o2 = @(& powershell -NoProfile -File $self -Slugs 'no-such-card' -BuiltDir $ft -FeedPath (Join-Path $ft 'cur.json') -ReferenceFeedPath (Join-Path $ft 'cur.json')); $rc2 = $LASTEXITCODE
    $t2 = $o2 -join ' | '
    T 'CLEAN TWIN  the CURRENT feed (same generated as the served one) passes the age check and goes on to stamp' `
      ($t2 -match 'is not older than' -and $t2 -cnotmatch 'STAMP: REFUSED' -and $rc2 -ne 2) ("rc=$rc2 " + $t2)
  } finally { Remove-Item $ft -Recurse -Force -ErrorAction SilentlyContinue }  if ($script:f -eq 0) { Write-Output ("stamp-live-price-fallback self-test PASS ($script:n cases)"); exit 0 } else { Write-Output ("stamp-live-price-fallback self-test FAIL ($script:f of $script:n)"); exit 1 }
}

# ---------------- the stamp ----------------
$dir = if ($BuiltDir) { $BuiltDir } else { Join-Path $mp 'db\built' }
. (Join-Path $here 'feed-freshness.ps1')   # THE canonical feed path (FEED_CANONICAL_PATH); one copy of where it lives
$feedFile = if ($FeedPath) { $FeedPath } else { $script:FEED_CANONICAL_PATH }
if (-not (Test-Path $feedFile)) { Write-Output "STAMP: CANNOT RUN - no feed at $feedFile. Nothing stamped."; exit 2 }
$asof = [string]((Get-Content $feedFile -Raw -Encoding UTF8 | ConvertFrom-Json).generated)
if ($asof -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$') { Write-Output "STAMP: CANNOT RUN - the feed's generated stamp '$asof' is not a timestamp. Nothing stamped."; exit 2 }
# NEVER STAMP FROM A FEED OLDER THAN THE ONE READERS ARE SERVED (2026-09-23). build-cards run in a worktree stamped
# fallbacks from the worktree's day-old seeded feed, so a card shipped today carried yesterday's price as its fallback
# and a data-tc-asof that looked current to every later check. The reference is the SERVED feed, else the newest
# committed public\smp-feed.json (origin/main or HEAD), read through grocery\feed-served-lib.ps1 - the one fetch path.
# -ReferenceFeedPath replaces it with a file (the self-test's seam). A feed NEWER than the served one (the daily chain
# built it and has not pushed yet) stamps; an older one refuses and names both dates; no reference at all is exit 2.
. (Join-Path (Split-Path $mp -Parent) 'grocery\feed-served-lib.ps1')
if ($ReferenceFeedPath) {
  $refDoc = $null; try { $refDoc = ([IO.File]::ReadAllText($ReferenceFeedPath)).TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { }
  $ref = [pscustomobject]@{ Doc = $refDoc; Source = ('the reference feed ' + $ReferenceFeedPath) }
} else { $ref = Get-TcServedFeedDoc -Repo (Split-Path $mp -Parent) -Refs @('origin/main', 'HEAD') }
if ($null -eq $ref.Doc) { Write-Output ("STAMP: CANNOT RUN - nothing to prove the feed at $feedFile current against: " + $ref.Source + '. Nothing stamped.'); exit 2 }
$fresh = Test-TcFeedNotOlder -Generated $asof -ReferenceGenerated ([string]$ref.Doc.generated) -ReferenceSource $ref.Source -LocalName ('the feed at ' + $feedFile)
if (-not $fresh.Ok) {
  Write-Output ('STAMP: REFUSED - ' + $fresh.Why + '. A fallback stamped from it would ship an older price than readers are served. Re-seed this checkout (ops\seed-worktree.ps1 -Target <it>) or pass -FeedPath to a current feed. Nothing stamped.')
  exit 2
}
Write-Output ('stamp-live-price-fallback: ' + $fresh.Why)
$node = Resolve-TcNode $NodeExe
if (-not $node -or -not (Test-Path $node)) { Write-Output 'STAMP: CANNOT RUN - node not found under C:\Codex\tools\node-*-win-x64 (pass -NodeExe). Nothing stamped.'; exit 2 }
if (-not (Test-Path (Join-Path $JsdomEnv 'node_modules\jsdom'))) { Write-Output "STAMP: CANNOT RUN - no jsdom under $JsdomEnv. Nothing stamped."; exit 2 }
$want = @($Slugs | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$paths = @(); $names = @()
foreach ($s in $want) { $p = Join-Path $dir ($s + '.body.html'); if (Test-Path $p) { $paths += $p; $names += $s } else { Write-Output ("  X $s :: no built card to stamp") } }
$res = if ($names.Count) { Invoke-TcLiveFill -Paths $paths -Names $names -Feed $feedFile -Node $node -Jsdom $JsdomEnv } else { @{} }
$okN = 0; $bad = @()
$utf8 = New-Object Text.UTF8Encoding($false)
for ($i = 0; $i -lt $names.Count; $i++) {
  $v = Get-TcStampValue $res[$names[$i]]
  if (-not $v.ok) { $bad += $names[$i]; Write-Output ("  X {0} :: live price not stamped - {1}" -f $names[$i], $v.why); continue }
  $html = [IO.File]::ReadAllText($paths[$i], [Text.Encoding]::UTF8)
  [IO.File]::WriteAllText($paths[$i], (Set-TcStampedSpans -Html $html -Slug $names[$i] -Value $v.value -AsOf $asof), $utf8)
  $okN++
}
Write-Output ("stamp-live-price-fallback: stamped {0} of {1} card(s) from feed {2}; {3} refused" -f $okN, $want.Count, $asof, ($want.Count - $okN))
Write-Output ("STAMP-LIVE-PRICE-FALLBACK-COMPLETE stamped={0} requested={1}" -f $okN, $want.Count)
if ($okN -ne $want.Count) { exit 1 } else { exit 0 }
