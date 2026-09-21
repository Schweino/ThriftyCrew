# monitor-live-recipe-prices.ps1 - THE LIVE MONITOR for recipe prices (2026-09-21, Brad: "The recipe pages
# should be fetching the pricing from our database ... If a pricing updates in the DB its automatically updated
# on all recipe pages." / "Be thorough so this can't ever 'break' again.").
#
# WHY A LIVE CHECK. The build gate (lib\price-literal-gate.ps1) and the feed contract
# (audit-live-price-contract.ps1) read what we BUILT. Neither can see a page that is already live, and this
# estate has 21 recorded incidents of a guard reading green while its defect shipped. So this fetches the live
# pages and runs THE PAGE'S OWN SCRIPT - the bytes Ghost serves, through live-price-fill.js in jsdom, never a
# reimplementation - against the DEPLOYED feed.
#
# PER PAGE, the public half (anonymous fetch, cache-busted) and the members half (the Admin API's rendered
# html, which is what Ghost serves a member; a paid post's placeholders behind the paywall are invisible to
# an anonymous fetch):
#   M1  the post's script requested the feed                          (else: MISSING SCRIPT)
#   M2  no money literal in the post outside a placeholder, and every placeholder carries slug/field/basis
#       and a stamped fallback (the build gate, run on the live bytes)
#   M3  with the feed loaded, EVERY placeholder filled (data-tc-filled), all with one value
#   M4  that value equals the receipt's Everyday tab on the same page: grand total / servings, to within one
#       cent. The receipt rounds its grand total to cents BEFORE a reader could divide it, so the quotient
#       may differ from the span by at most one cent at a rounding boundary and never by two.
#   M5  the members half carries as many placeholders as the built card's members half (the fill reached it)
# A page still on the pre-2026-09-21 card is LEGACY: its fill depends on site-wide code injection, so M3/M4
# cannot be judged on the post alone. Counted and named, and a finding only once db\live-price-rollout.json
# reaches stage "catalogue". M2's literal half still applies to it.
#
# SAMPLE: the rollout's canary every day, plus a rotating window of the published catalogue (-Sample, default
# 12) that advances by one window a day, so 577 pages are all visited about every 48 days. The run prints
# both counts and the denominator. -Slugs overrides.
# PAGES on a real mismatch, a missing script or a missing feed, through grocery\send-alert.ps1 (registered
# in grocery\alert-registry.json). A monitor that cannot look (no node, Ghost unreachable) says BLIND, exit 3.
# Exit: 0 clean, 1 findings, 3 could not evaluate. Last line: LIVE-RECIPE-PRICES-COMPLETE.
# Self-test: powershell -File meal-prep\pipeline\monitor-live-recipe-prices.ps1 -SelfTest
param([string]$Slugs = '', [int]$Sample = 12, [switch]$NoAlert, [string]$NodeExe = '',
      [string]$JsdomEnv = 'C:\Codex\tools\jsdom-env', [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$SelfTestMlp = $SelfTest.IsPresent; $mlpSlugs = $Slugs      # before the dot-sources rebind them
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
. (Join-Path $mp 'lib\price-literal-gate.ps1')
. (Join-Path $repo 'lib\guard-contract.ps1')
$FEED_URL = 'https://feed.thriftycrew.com/smp-feed.json'
$SITE = 'https://www.thriftycrew.com'

function Resolve-MlpNode { param([string]$Exe)
  if ($Exe) { return $Exe }
  $p = Get-ChildItem 'C:\Codex\tools' -Filter 'node-*-win-x64' -Directory -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
  if ($p) { return (Join-Path $p.FullName 'node.exe') } else { return '' }
}

function Invoke-MlpHarness { param([object[]]$Cards, [string]$Feed, [string]$Node, [string]$Jsdom, [string]$Mode = 'ok')
  $job = @{ jsdom = $Jsdom; feedPath = $Feed; feedMode = $Mode; waitMs = 4000; cards = $Cards }
  $jp = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'tc-mlp-' + [guid]::NewGuid().ToString('N') + '.json')
  [IO.File]::WriteAllText($jp, ($job | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
  try { $lines = & $Node (Join-Path $here 'live-price-fill.js') $jp } finally { Remove-Item $jp -ErrorAction SilentlyContinue }
  $res = @{}; $done = $false
  foreach ($l in @($lines)) { if ($l -match '^LIVE-PRICE-FILL-COMPLETE') { $done = $true } elseif ($l -match '^\{') { $o = $l | ConvertFrom-Json; $res[[string]$o.key] = $o } }
  if (-not $done) { throw 'live-price-fill.js died before its completion marker' }
  return $res
}

# THE VERDICT for one half of one page. Pure: the self-test drives it with the exact shapes the harness emits.
# $R = harness result, $PostHtml = the post bytes it ran, $ExpectSpans = placeholders the built card has in
# this half (-1 = do not check). Returns @{ legacy; findings }.
function Get-MlpVerdict { param($R, [string]$PostHtml, [string]$Slug, [string]$Half, [int]$ExpectSpans = -1, [bool]$LegacyIsFinding)
  $f = @()
  if (-not $R -or -not $R.ok) { return @{ legacy = $false; findings = @("$Half : the page could not be run (" + $(if ($R) { $R.error } else { 'no result' }) + ')') } }
  if (-not $R.feedRequested) { $f += "$Half : MISSING SCRIPT - the post never requested $FEED_URL" }
  $spans = @($R.spans)
  $named = @($spans | Where-Object { $_.field })
  $legacy = ($spans.Count -gt 0 -and $named.Count -lt $spans.Count)
  $lit = Test-TcBuiltPriceLiterals -Body $PostHtml -Slug $Slug -RequireAsOf:(-not $legacy)
  if ($legacy) { $lit = @($lit | Where-Object { $_ -notmatch '^placeholder:' }) }
  foreach ($x in $lit) { $f += ("$Half : " + $x) }
  if ($ExpectSpans -ge 0 -and $spans.Count -ne $ExpectSpans) { $f += ("$Half : " + $spans.Count + ' placeholder(s) on the live page, ' + $ExpectSpans + ' in the built card') }
  if ($legacy) {
    if ($LegacyIsFinding) { $f += "$Half : LEGACY placeholder after the rollout reached the catalogue" }
    return @{ legacy = $true; findings = $f }
  }
  if (-not $spans.Count) { return @{ legacy = $false; findings = $f } }
  $unfilled = @($spans | Where-Object { -not $_.filled })
  if ($unfilled.Count) { $f += ("$Half : " + $unfilled.Count + ' of ' + $spans.Count + ' placeholder(s) did NOT fill from the loaded feed (showing "' + $unfilled[0].text + '")'); return @{ legacy = $false; findings = $f } }
  $vals = @($spans | ForEach-Object { [string]$_.filled } | Sort-Object -Unique)
  if ($vals.Count -ne 1) { $f += ("$Half : placeholders filled with different values: " + ($vals -join ', ')); return @{ legacy = $false; findings = $f } }
  $spanCents = [int][math]::Round([double]$vals[0] * 100)
  $t = $R.everydayTab
  if (-not $t -or -not $t.clicked -or $null -eq $t.grand -or -not ([int]$t.servings -gt 0)) {
    if ($Half -eq 'public') { return @{ legacy = $false; findings = $f } }   # the receipt sits behind the paywall
    $f += "$Half : the Everyday tab could not be read, so the fill has nothing to be checked against"
  } else {
    $tabCents = [int][math]::Round([double]$t.grand * 100 / [int]$t.servings)
    if ([math]::Abs($spanCents - $tabCents) -gt 1) { $f += ("$Half : MISMATCH - the prose says ~$" + $vals[0] + ' a serving but the Everyday tab on the same page says ' + $t.grandText + ' / ' + $t.servings + ' = ' + ('{0:0.00}' -f ($tabCents / 100.0))) }
  }
  return @{ legacy = $false; findings = $f }
}

if ($SelfTestMlp) {
  $script:fl = 0; $script:n = 0
  function T($m, $c, $g) { $script:n++; if ($c) { Write-Output ('ok    ' + $m) } else { Write-Output ('FAIL  ' + $m + '   got: ' + $g); $script:fl++ } }
  $sp = Format-TcLivePriceSpan -Slug 'bowl' -Value '5.00' -AsOf '2026-09-21T05:22:59'
  $post = '<p>' + $sp + '</p><!--TC-PAYWALL--><p>' + $sp + '</p>'
  $mk = { param($filled, $grand, $serv, $req = $true, $field = 'cost_ps')
    [pscustomobject]@{ ok = $true; feedRequested = $req; everydayTab = [pscustomobject]@{ clicked = $true; grand = $grand; grandText = ('$' + $grand); servings = $serv }
      spans = @($filled | ForEach-Object { [pscustomobject]@{ field = $field; filled = $_; text = $(if ($_) { '~$' + $_ } else { '~$5.00' }) } }) } }
  $v = Get-MlpVerdict (& $mk @('5.00', '5.00') 70.00 14) $post 'bowl' 'members' 2 $true
  T 'MUST NOT FIRE  two placeholders filled at 5.00 against an Everyday tab of $70.00 / 14' ($v.findings.Count -eq 0) ($v.findings -join ' | ')
  $v = Get-MlpVerdict (& $mk @('5.01', '5.01') 70.00 14) $post 'bowl' 'members' 2 $true
  T 'AT BAR  a fill ONE cent off the tab (5.01 vs 70.00/14 = 5.00) is rounding, not a mismatch' ($v.findings.Count -eq 0) ($v.findings -join ' | ')
  $v = Get-MlpVerdict (& $mk @('5.02', '5.02') 70.00 14) $post 'bowl' 'members' 2 $true
  T 'MUST FIRE  a fill TWO cents off the tab, one step past the bar, is a MISMATCH' (($v.findings -join ' ') -match 'MISMATCH') ($v.findings -join ' | ')
  $v = Get-MlpVerdict (& $mk @('6.20', '6.20') 70.00 14) $post 'bowl' 'members' 2 $true
  T 'MUST FIRE  the founding shape: the prose says one price and the page''s own receipt says another' (($v.findings -join ' ') -match 'MISMATCH') ($v.findings -join ' | ')
  $v = Get-MlpVerdict (& $mk @('5.00', '5.00') 70.00 14 $false) $post 'bowl' 'members' 2 $true
  T 'MUST FIRE  a post whose script never requested the feed (MISSING SCRIPT)' (($v.findings -join ' ') -match 'MISSING SCRIPT') ($v.findings -join ' | ')
  $v = Get-MlpVerdict (& $mk @('', '') 70.00 14) $post 'bowl' 'members' 2 $true
  T 'MUST FIRE  placeholders that did not fill from a loaded feed' (($v.findings -join ' ') -match 'did NOT fill') ($v.findings -join ' | ')
  $v = Get-MlpVerdict (& $mk @('5.00', '5.00') 70.00 14) ($post + '<p>Fourteen servings at about $2.40 each.</p>') 'bowl' 'members' 2 $true
  T 'MUST FIRE  a frozen "$2.40 each" sentence on the live post' (($v.findings -join ' ') -match '2\.40') ($v.findings -join ' | ')
  $v = Get-MlpVerdict (& $mk @('5.00') 70.00 14) $post 'bowl' 'members' 2 $true
  T 'MUST FIRE  the members half shows fewer placeholders than the built card (the fill did not reach it)' (($v.findings -join ' ') -match 'in the built card') ($v.findings -join ' | ')
  $legR = [pscustomobject]@{ ok = $true; feedRequested = $true; everydayTab = $null; spans = @([pscustomobject]@{ field = $null; filled = $null; text = 'current price loading' }) }
  $v = Get-MlpVerdict $legR '<p><span data-tc-live-price>current price loading</span></p>' 'bowl' 'public' -1 $false
  T 'MUST NOT FIRE  a legacy page while the rollout is at the canary (counted as legacy)' ($v.legacy -and $v.findings.Count -eq 0) ($v.findings -join ' | ')
  $v = Get-MlpVerdict $legR '<p><span data-tc-live-price>current price loading</span></p>' 'bowl' 'public' -1 $true
  T 'MUST FIRE  the same legacy page once the rollout reached the catalogue' ($v.findings.Count -eq 1) ($v.findings -join ' | ')

  # END TO END through the REAL card script: the built casserole card and the FROZEN feed subset
  # (fixtures\live-price-feed-casserole.json), so the daily feed cannot move this suite.
  $node = Resolve-MlpNode $NodeExe
  $card = Join-Path $mp 'db\built\turkey-wild-rice-casserole.body.html'
  $fx = Join-Path $here 'fixtures\live-price-feed-casserole.json'
  if ($node -and (Test-Path $node) -and (Test-Path (Join-Path $JsdomEnv 'node_modules\jsdom')) -and (Test-Path $card) -and ([IO.File]::ReadAllText($card) -match 'data-tc-asof=')) {
    $html = [IO.File]::ReadAllText($card, [Text.Encoding]::UTF8)
    $res = Invoke-MlpHarness -Cards @(@{ key = 'c'; slug = 'turkey-wild-rice-casserole'; htmlPath = $card; kind = 'body' }) -Feed $fx -Node $node -Jsdom $JsdomEnv
    $v = Get-MlpVerdict $res['c'] $html 'turkey-wild-rice-casserole' 'members' -1 $true
    T 'MUST NOT FIRE  (real script) the built casserole fills from the frozen feed and agrees with its own Everyday tab' ($v.findings.Count -eq 0 -and @($res['c'].spans).Count -ge 1) ($v.findings -join ' | ')
    $res = Invoke-MlpHarness -Cards @(@{ key = 'c'; slug = 'turkey-wild-rice-casserole'; htmlPath = $card; kind = 'body' }) -Feed $fx -Node $node -Jsdom $JsdomEnv -Mode 'fail'
    $txt = @(@($res['c'].spans) | ForEach-Object { $_.text })
    T 'CLEAN TWIN  (real script) with NO feed every placeholder still shows a price (its fallback), never a blank, NaN, undefined or $0.00' `
      (@($txt | Where-Object { $_ -notmatch '^~\$\d+\.\d\d$' -or $_ -eq '~$0.00' }).Count -eq 0 -and $txt.Count -ge 1) ($txt -join ', ')
    $v = Get-MlpVerdict $res['c'] $html 'turkey-wild-rice-casserole' 'members' -1 $true
    T 'MUST FIRE  (real script) the monitor reports the unfilled placeholders when the feed does not load' (($v.findings -join ' ') -match 'did NOT fill') ($v.findings -join ' | ')
  } else { Write-Output 'note  node/jsdom/stamped casserole card not all present: the three end-to-end cases did not run (the pure cases above did)' }
  if ($script:fl -eq 0) { Write-Output ("monitor-live-recipe-prices self-test PASS ($script:n cases)"); exit 0 } else { Write-Output ("monitor-live-recipe-prices self-test FAIL ($script:fl of $script:n)"); exit 1 }
}

# ---------------- the monitor ----------------
. (Join-Path $repo 'lib\ghost-lib.ps1')
$alertLib = Join-Path $repo 'grocery\alert-lib.ps1'
function Send-MlpPage { param([string]$Subject, [string]$Body)
  if ($NoAlert) { Write-Output ('(alert suppressed by -NoAlert) ' + $Subject); return }
  try { . $alertLib; Send-Alert -Subject $Subject -Body $Body -What 'LIVE-RECIPE-PRICES' } catch { Write-Output ('ALERT COULD NOT BE SENT: ' + $_.Exception.Message) }
}
$node = Resolve-MlpNode $NodeExe
if (-not $node -or -not (Test-Path $node) -or -not (Test-Path (Join-Path $JsdomEnv 'node_modules\jsdom'))) {
  Write-Output 'LIVE-RECIPE-PRICES: BLIND - node or jsdom missing (C:\Codex\tools)'
  Send-MlpPage 'Live recipe price monitor could not look' 'node or jsdom is missing under C:\Codex\tools, so no live recipe page was checked today.'
  Exit-Guard -Name 'live-recipe-prices' -Summary 'pages=0 blind=node' -Code 3
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('tc-mlp-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Force $tmp | Out-Null
try {
  # the DEPLOYED feed, cache-busted so an edge copy cannot answer for it
  $feedFile = Join-Path $tmp 'feed.json'
  try {
    $fr = Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri ($FEED_URL + '?tcmon=' + [DateTime]::UtcNow.Ticks)
    [IO.File]::WriteAllText($feedFile, $fr.Content, (New-Object Text.UTF8Encoding($false)))
    $feed = $fr.Content | ConvertFrom-Json
    if (-not $feed.pricing_inputs -or -not $feed.generated) { throw 'the feed parsed but carries no pricing_inputs or no generated stamp' }
  } catch {
    Write-Output ('LIVE-RECIPE-PRICES: MISSING FEED - ' + $_.Exception.Message)
    Send-MlpPage 'Live recipe prices: the feed is missing' ("Every recipe page fetches $FEED_URL at view time, and it could not be read: " + $_.Exception.Message + "`nEvery live price placeholder is showing its build-time fallback.")
    Exit-Guard -Name 'live-recipe-prices' -Summary 'pages=0 feed=missing' -Code 1
  }
  $roll = $null; try { $roll = Get-Content (Join-Path $mp 'db\live-price-rollout.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
  $legacyIsFinding = ($roll -and [string]$roll.stage -eq 'catalogue')
  $pub = Get-Content (Join-Path $mp 'db\published-hashes.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $published = @($pub.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
  $want = @($mlpSlugs -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  if (-not $want.Count) {
    $canary = if ($roll -and $roll.canary) { @($roll.canary) } else { @() }
    $day = [int]([DateTime]::Today - [DateTime]'2026-09-21').TotalDays
    $start = if ($published.Count) { ($day * $Sample) % $published.Count } else { 0 }
    $window = @(); for ($i = 0; $i -lt [math]::Min($Sample, $published.Count); $i++) { $window += $published[($start + $i) % $published.Count] }
    $want = @(@($canary) + $window | Select-Object -Unique)
    Write-Output ("sample: {0} canary + {1} rotating (window starts at {2} of {3} published; the whole catalogue is visited every {4} days)" -f $canary.Count, $window.Count, $start, $published.Count, [math]::Ceiling($published.Count / [math]::Max(1, $Sample)))
  }
  $key = Get-GhostKey
  $cards = @(); $meta = @{}
  foreach ($s in $want) {
    $pf = Join-Path $tmp ($s + '.page.html')
    try { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -Uri ("$SITE/$s/?tcmon=" + [DateTime]::UtcNow.Ticks); [IO.File]::WriteAllText($pf, $r.Content, (New-Object Text.UTF8Encoding($false))) }
    catch { $meta[$s] = @{ err = ('public page did not load: ' + $_.Exception.Message) }; continue }
    $cards += @{ key = ($s + '|public'); slug = $s; htmlPath = $pf; kind = 'page'; dumpPost = (Join-Path $tmp ($s + '.public.post.html')) }
    $mf = Join-Path $tmp ($s + '.members.html')
    try {
      $jwt = Get-GhostJWT -Key $key
      $p = (Invoke-GhostApi -Uri ("https://map-to-success.ghost.io/ghost/api/admin/posts/slug/$s/?formats=html&fields=html,visibility") -Headers @{ Authorization = "Ghost $jwt"; 'Accept-Version' = (Get-GhostAcceptVersion) }).posts[0]
      [IO.File]::WriteAllText($mf, [string]$p.html, (New-Object Text.UTF8Encoding($false)))
      $cards += @{ key = ($s + '|members'); slug = $s; htmlPath = $mf; kind = 'body' }
      $meta[$s] = @{ visibility = [string]$p.visibility }
    } catch { $meta[$s] = @{ err = ('members html could not be read from the Admin API: ' + $_.Exception.Message) } }
  }
  $res = if ($cards.Count) { Invoke-MlpHarness -Cards $cards -Feed $feedFile -Node $node -Jsdom $JsdomEnv } else { @{} }
  $findings = @(); $legacyN = 0; $okN = 0; $blind = @()
  foreach ($s in $want) {
    if ($meta[$s] -and $meta[$s].err) { $blind += ("$s : " + $meta[$s].err); continue }
    $built = Join-Path $mp "db\built\$s.body.html"
    $expMembers = -1
    if (Test-Path $built) { $bh = [IO.File]::ReadAllText($built, [Text.Encoding]::UTF8); $expMembers = ([regex]::Matches($bh, '<span data-tc-live-price')).Count }
    $pubPost = Join-Path $tmp ($s + '.public.post.html')
    $vp = Get-MlpVerdict $res[$s + '|public'] $(if (Test-Path $pubPost) { [IO.File]::ReadAllText($pubPost, [Text.Encoding]::UTF8) } else { '' }) $s 'public' -1 $legacyIsFinding
    $vm = Get-MlpVerdict $res[$s + '|members'] ([IO.File]::ReadAllText((Join-Path $tmp ($s + '.members.html')), [Text.Encoding]::UTF8)) $s 'members' $expMembers $legacyIsFinding
    if ($vp.legacy -or $vm.legacy) { $legacyN++ }
    $all = @($vp.findings) + @($vm.findings)
    if ($all.Count) { foreach ($x in $all) { $findings += ("$s  $x") } } else { $okN++ }
    $fv = @(@($res[$s + '|members'].spans) | ForEach-Object { $_.filled } | Where-Object { $_ } | Select-Object -Unique)
    Write-Output ("  {0,-44} {1,-7} {2}  members={3} filled={4}" -f $s, $meta[$s].visibility, $(if ($vm.legacy) { 'LEGACY' } elseif ($all.Count) { 'FINDING' } else { 'ok' }), @($res[$s + '|members'].spans).Count, ($fv -join ','))
  }
  foreach ($x in $findings) { Write-Output ('FINDING  ' + $x) }
  foreach ($x in $blind) { Write-Output ('BLIND    ' + $x) }
  Write-Output ("live-recipe-prices: {0} page(s) checked against the deployed feed (generated {1}): {2} clean, {3} legacy ({4}), {5} finding(s), {6} could not be read" -f $want.Count, $feed.generated, $okN, $legacyN, $(if ($legacyIsFinding) { 'a finding' } else { 'counted only, rollout at ' + $(if ($roll) { $roll.stage } else { 'UNREADABLE' }) }), $findings.Count, $blind.Count)
  if ($findings.Count) { Send-MlpPage 'Live recipe prices: a live page does not match the feed' ("monitor-live-recipe-prices.ps1 checked $($want.Count) live recipe page(s) against the deployed feed (generated $($feed.generated)).`n`n" + ($findings -join "`n")) }
  elseif ($blind.Count) { Send-MlpPage 'Live recipe price monitor could not look' ($blind -join "`n") }
  $code = if ($findings.Count) { 1 } elseif ($blind.Count) { 3 } else { 0 }
  Exit-Guard -Name 'live-recipe-prices' -Summary ("pages={0} clean={1} legacy={2} findings={3} blind={4} feed={5}" -f $want.Count, $okN, $legacyN, $findings.Count, $blind.Count, $feed.generated) -Code $code
} finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
