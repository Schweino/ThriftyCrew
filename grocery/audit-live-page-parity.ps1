<#
  audit-live-page-parity.ps1 - DOES EACH LIVE PAGE SAY WHAT ITS SHIPPED DATA SAYS? (2026-09-26, queue 2026-09-23-80f302,
  and 2026-09-25-22b1e8 pulled forward)

  Self-test:   powershell -NoProfile -File grocery\audit-live-page-parity.ps1 -SelfTest

  WHY. Every check before this one looked at a publish from INSIDE the run that made it. The board post is written only by
  publish-deals-page, only after its data is served (feed-served-lib.ps1), and capture-run pages when that publish returns
  non-zero. None of them asks, afterwards, whether the LIVE post and the SERVED board still agree, so every road that ships
  data without the post following it was silent:
    - 2026-09-24's second capture-run built board a14a8c805c and held the post because its push did not land. The commit
      landed LATER, carried by another push, and nothing publishes a post for a push it did not make. From then the live
      post at /omaha-grocery-prices/ named board.json?v=780837d352 (its 2026-09-23 05:20 UTC publish) while
      feed.thriftycrew.com served a14a8c805c. Measured 2026-09-26 10:40: still true, two days on, and no page had fired
      (the 09-24 and 09-25 runs printed "POST HELD", which pages nothing, and the post deferral expires at midnight).
    - /omaha-price-tracker/ reads "the week of Sep 2, 2026" (updated 2026-09-05) while out\trend\index.html was built for
      "the week of Sep 22, 2026". Its publisher rides only the weekly trend branch, and a failure there prints inside
      publish-deals-page's output, which capture-run filters out of its log (queue 2026-09-25-22b1e8).
  So the question is asked from OUTSIDE, of the live pages, on every capture-run: the same comparison whichever road broke it.

  THE TWO ARMS.
    board-post  The live post's feed.thriftycrew.com/board.json?v=<v> against the SHA-1 of the board.json the feed serves
                (Test-TcBoardServed in feed-served-lib.ps1: the SAME rule publish-deals-page holds on, so there is one
                definition of "the post names the served board"). A differing board is DIVERGED.
    tracker     The live tracker's "week of <date>" against the one out\trend\index.html (the page build-trend-index built
                for publish-trend-index to post) carries. A different week is DIVERGED: a built page that never went live.
  Each arm is read up to -Attempts times, -DelaySec apart, when it is not in parity, because Ghost's page cache and the
  feed's edge can each lag a write by a minute or two. Parity on any read settles it.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 both arms in parity, 2 an arm DIVERGED (a hard finding), 3 an arm could
  not be read and none diverged (could-not-evaluate, never a pass). Read the verdict LINES, not the number.
  SCOPE OF A CLEAN REPORT: SOUND for the two pages it reads (the post names exactly the served board; the tracker names the
  built week), and says nothing about any other page. A finding is COMPLETE: a differing version or week IS the defect.
#>
# Self-test: pure fixtures over Test-TcBoardServed (via Get-TcPostParity) and Test-TcTrackerWeekParity, with every fetch a
# seam; no network, no Ghost, no board.
# gate-inputs: grocery\audit-live-page-parity.ps1, grocery\feed-served-lib.ps1, lib\git-blob-lib.ps1, lib\guard-contract.ps1
# gate-inputs-text: grocery\capture-run.ps1
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param(
  [switch]$SelfTest,
  [int]$Attempts = 3,
  [int]$DelaySec = 60,
  [string]$PostUrl = 'https://www.thriftycrew.com/omaha-grocery-prices/',
  [string]$TrackerUrl = 'https://www.thriftycrew.com/omaha-price-tracker/',
  [string]$BuiltTrackerFile = ''
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $here 'feed-served-lib.ps1')

$script:TcTrackerWeekRx = '(?i)\bweek of ([A-Z][a-z]{2,8}\.? \d{1,2}, \d{4})'

function Get-TcTrackerWeekLabels {
  <# Every distinct "week of <Mon d, yyyy>" label in the html, in order. Pure over text. #>
  param([string]$Html)
  $out = [Collections.Generic.List[string]]::new()
  foreach ($m in [regex]::Matches([string]$Html, $script:TcTrackerWeekRx)) {
    $v = ($m.Groups[1].Value -replace '\.', '')
    if (-not $out.Contains($v)) { $out.Add($v) }
  }
  return , $out.ToArray()
}

function Test-TcTrackerWeekParity {
  <# Pure. Does the LIVE tracker quote the week the BUILT tracker page quotes? Blind when either side names no week or
     more than one, because then no single week can be compared. #>
  param([string]$LiveHtml, [string]$BuiltHtml)
  $live = Get-TcTrackerWeekLabels -Html $LiveHtml
  $built = Get-TcTrackerWeekLabels -Html $BuiltHtml
  if ($built.Count -ne 1) { return [pscustomobject]@{ Verdict = 'blind'; Live = ($live -join ' | '); Built = ($built -join ' | '); Why = ('the built tracker page names ' + $built.Count + ' "week of" labels, so there is no one week to expect') } }
  if ($live.Count -ne 1) { return [pscustomobject]@{ Verdict = 'blind'; Live = ($live -join ' | '); Built = $built[0]; Why = ('the live tracker names ' + $live.Count + ' "week of" labels, so there is no one week to compare') } }
  if ([string]::Equals($live[0], $built[0], [StringComparison]::Ordinal)) { return [pscustomobject]@{ Verdict = 'parity'; Live = $live[0]; Built = $built[0]; Why = ('both quote the week of ' + $live[0]) } }
  $gap = ''
  try {
    $fmt = [string[]]@('MMM d, yyyy', 'MMMM d, yyyy')
    $dl = [datetime]::ParseExact($live[0], $fmt, [Globalization.CultureInfo]::InvariantCulture, 'None')
    $db = [datetime]::ParseExact($built[0], $fmt, [Globalization.CultureInfo]::InvariantCulture, 'None')
    $gap = (', ' + [math]::Abs(($db - $dl).Days) + ' day(s) apart')
  } catch { $gap = '' }
  return [pscustomobject]@{ Verdict = 'diverged'; Live = $live[0]; Built = $built[0]; Why = ('the live tracker quotes the week of ' + $live[0] + ' and the built page quotes the week of ' + $built[0] + $gap) }
}

function Get-TcPostParity {
  <# The board-post arm over already-fetched text. $ServedFetch returns the served board.json bytes or throws. Maps
     Test-TcBoardServed's answer onto this audit's vocabulary: served -> parity, not-served -> diverged, the rest -> blind. #>
  param([string]$LiveHtml, [scriptblock]$ServedFetch)
  $r = Test-TcBoardServed -Html $LiveHtml -Fetch $ServedFetch -Attempts 1 -DelaySec 0
  $verdict = switch ([string]$r.Verdict) {
    'served'      { 'parity' }
    'not-served'  { 'diverged' }
    'unreachable' { 'blind' }
    'no-version'  { 'blind' }
    default       { throw ('unknown Test-TcBoardServed verdict: ' + [string]$r.Verdict) }
  }
  $why = if ($verdict -eq 'parity') { ('the live post names board.json?v=' + $r.Version + ' and the feed serves exactly that board') } elseif ($verdict -eq 'diverged') { ('the live post names board.json?v=' + $r.Version + ' but feed.thriftycrew.com serves v=' + $r.Served + ': readers get a post built from a board that is no longer served') } else { ('the live post: ' + $r.Why) }
  return [pscustomobject]@{ Verdict = $verdict; Live = [string]$r.Version; Built = [string]$r.Served; Why = $why }
}

function Invoke-TcArmWithRetry {
  <# Run one arm up to $Attempts times, $DelaySec apart, until it reads parity. A fetch that throws is that attempt's
     blind verdict. Returns the LAST verdict, with the attempt count, so a lag that clears reads parity. #>
  param([scriptblock]$Arm, [int]$Attempts, [int]$DelaySec, [scriptblock]$Sleep = { param($s) Start-Sleep -Seconds $s })
  $last = $null
  $n = [Math]::Max(1, $Attempts)
  for ($i = 1; $i -le $n; $i++) {
    try { $last = & $Arm } catch { $last = [pscustomobject]@{ Verdict = 'blind'; Live = ''; Built = ''; Why = ('could not read: ' + $_.Exception.Message) } }
    $last | Add-Member -NotePropertyName Attempts -NotePropertyValue $i -Force
    if ($last.Verdict -eq 'parity') { break }
    if ($i -lt $n -and $DelaySec -gt 0) { & $Sleep $DelaySec }
  }
  return $last
}

function Get-TcLivePageParityExit {
  <# Pure. Any diverged arm is 2; else any blind arm is 3; else 0. #>
  param([object[]]$Results)
  $vs = @($Results | ForEach-Object { [string]$_.Verdict })
  if ($vs -contains 'diverged') { return 2 }
  if ($vs.Count -eq 0 -or ($vs -contains 'blind')) { return 3 }
  return 0
}

function Invoke-TcLiveHtmlFetch {
  <# One live page as text, fetched past Ghost's page cache with a unique query. Throws on any failure. #>
  param([string]$Url, [int]$TimeoutSec = 60)
  $resp = Invoke-WebRequest -Uri ($Url + '?parity-check=' + [guid]::NewGuid().ToString('N')) -UseBasicParsing -TimeoutSec $TimeoutSec
  $b = Get-ResponseBytes $resp
  if ($null -eq $b -or $b.Length -eq 0) { throw ('the page answered with an empty body: ' + $Url) }
  return ([Text.Encoding]::UTF8.GetString([byte[]]$b))
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $script:f = 0; $script:n = 0
  function T($m, $cond, $got) { $script:n++; if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }
  try {
    $ErrorActionPreference = 'Stop'
    # Stand-in board bytes (the real boards are ~1 MB): what matters is only that the post's v= is or is not their SHA-1.
    $servedBytes = [Text.Encoding]::UTF8.GetBytes('{"week_of":"2026-09-23","stand-in":"the board feed.thriftycrew.com serves"}')
    $servedV = Get-TcBoardVersionOfBytes -Bytes $servedBytes
    # THE FOUNDING CASE, frozen from the live post read 2026-09-26: it names v=780837d352 (its 2026-09-23 publish).
    $postFounding = "<script>var u='https://feed.thriftycrew.com/board.json?v=780837d352';</script>"
    $postCurrent = "<script>var u='https://feed.thriftycrew.com/board.json?v=" + $servedV + "';</script>"

    $p1 = Get-TcPostParity -LiveHtml $postFounding -ServedFetch { , $servedBytes }
    T 'MUST FIRE  the 2026-09-26 board post: live post names v=780837d352, the feed serves another board -> diverged' ($p1.Verdict -eq 'diverged') ($p1.Verdict + ' ' + $p1.Why)
    T 'MUST FIRE  ...and the finding names both versions' (($p1.Why -like '*780837d352*') -and ($p1.Why -like ('*' + $servedV + '*'))) $p1.Why
    $p2 = Get-TcPostParity -LiveHtml $postCurrent -ServedFetch { , $servedBytes }
    T 'CLEAN TWIN a live post naming the served board is parity' ($p2.Verdict -eq 'parity') ($p2.Verdict + ' ' + $p2.Why)
    $p3 = Get-TcPostParity -LiveHtml $postCurrent -ServedFetch { throw 'The remote name could not be resolved: feed.thriftycrew.com' }
    T 'MUST FIRE  an unreadable feed is blind, never parity' ($p3.Verdict -eq 'blind') ($p3.Verdict + ' ' + $p3.Why)
    $p4 = Get-TcPostParity -LiveHtml '<p>a page with no board url</p>' -ServedFetch { , $servedBytes }
    T 'MUST FIRE  a live post naming no board version is blind, never parity' ($p4.Verdict -eq 'blind') ($p4.Verdict + ' ' + $p4.Why)

    # Tracker arm, frozen from the live read 2026-09-26 and the built out\trend\index.html of 2026-09-22.
    $liveTracker = '<p>Prices below are from the week of Sep 2, 2026.</p>'
    $builtTracker = '<p>Prices below are from the week of Sep 22, 2026.</p>'
    $t1 = Test-TcTrackerWeekParity -LiveHtml $liveTracker -BuiltHtml $builtTracker
    T 'MUST FIRE  the 2026-09-26 tracker: live week of Sep 2, 2026 against built week of Sep 22, 2026 -> diverged' ($t1.Verdict -eq 'diverged') ($t1.Verdict + ' ' + $t1.Why)
    T 'MUST FIRE  ...and it says how far apart (20 days)' ($t1.Why -like '*20 day(s) apart*') $t1.Why
    $t2 = Test-TcTrackerWeekParity -LiveHtml $builtTracker -BuiltHtml $builtTracker
    T 'CLEAN TWIN the live tracker quoting the built week is parity' ($t2.Verdict -eq 'parity') ($t2.Verdict + ' ' + $t2.Why)
    $t3 = Test-TcTrackerWeekParity -LiveHtml '<p>no week here</p>' -BuiltHtml $builtTracker
    T 'MUST FIRE  a live tracker naming no week is blind, never parity' ($t3.Verdict -eq 'blind') ($t3.Verdict + ' ' + $t3.Why)
    $t4 = Test-TcTrackerWeekParity -LiveHtml $builtTracker -BuiltHtml ''
    T 'MUST FIRE  a missing built page is blind, never parity' ($t4.Verdict -eq 'blind') ($t4.Verdict + ' ' + $t4.Why)
    $t5 = Test-TcTrackerWeekParity -LiveHtml ($liveTracker + $builtTracker) -BuiltHtml $builtTracker
    T 'MUST FIRE  a live tracker quoting two weeks is blind, never parity' ($t5.Verdict -eq 'blind') ($t5.Verdict + ' ' + $t5.Why)
    $t6 = Test-TcTrackerWeekParity -LiveHtml '<p>the week of Sept. 22, 2026</p>' -BuiltHtml $builtTracker
    T 'CLEAN TWIN a label that differs from the built one only by spelling is still a mismatch and does not throw' ($t6.Verdict -eq 'diverged') ($t6.Verdict + ' ' + $t6.Why)

    # Retry: a lag that clears on the second read settles as parity; a divergence that persists is reported after every attempt.
    $script:lag = 0; $script:slept = 0
    $lagArm = { $script:lag++; if ($script:lag -lt 2) { Get-TcPostParity -LiveHtml $postFounding -ServedFetch { , $servedBytes } } else { Get-TcPostParity -LiveHtml $postCurrent -ServedFetch { , $servedBytes } } }
    $r1 = Invoke-TcArmWithRetry -Arm $lagArm -Attempts 3 -DelaySec 7 -Sleep { param($s) $script:slept += $s }
    T 'CLEAN TWIN a Ghost cache lag that clears on the 2nd read settles as parity after 2 attempts and one wait' (($r1.Verdict -eq 'parity') -and ($r1.Attempts -eq 2) -and ($script:slept -eq 7)) ($r1.Verdict + ' attempts=' + $r1.Attempts + ' slept=' + $script:slept)
    $script:slept = 0
    $r2 = Invoke-TcArmWithRetry -Arm { Get-TcPostParity -LiveHtml $postFounding -ServedFetch { , $servedBytes } } -Attempts 3 -DelaySec 5 -Sleep { param($s) $script:slept += $s }
    T 'MUST FIRE  a divergence that persists across all 3 attempts is reported diverged, with 2 waits between them' (($r2.Verdict -eq 'diverged') -and ($r2.Attempts -eq 3) -and ($script:slept -eq 10)) ($r2.Verdict + ' attempts=' + $r2.Attempts + ' slept=' + $script:slept)
    $r3 = Invoke-TcArmWithRetry -Arm { throw 'timed out' } -Attempts 2 -DelaySec 0
    T 'MUST FIRE  an arm whose fetch throws every time is blind, never parity' ($r3.Verdict -eq 'blind') ($r3.Verdict + ' ' + $r3.Why)

    # Exit mapping.
    $par = [pscustomobject]@{ Verdict = 'parity' }; $div = [pscustomobject]@{ Verdict = 'diverged' }; $bl = [pscustomobject]@{ Verdict = 'blind' }
    T 'CLEAN TWIN both arms in parity exit 0' ((Get-TcLivePageParityExit -Results @($par, $par)) -eq 0) (Get-TcLivePageParityExit -Results @($par, $par))
    T 'MUST FIRE  one diverged arm exits 2 even when the other is blind' ((Get-TcLivePageParityExit -Results @($bl, $div)) -eq 2) (Get-TcLivePageParityExit -Results @($bl, $div))
    T 'MUST FIRE  a blind arm with no divergence exits 3, never 0' ((Get-TcLivePageParityExit -Results @($par, $bl)) -eq 3) (Get-TcLivePageParityExit -Results @($par, $bl))
    T 'MUST FIRE  no results at all exit 3, never 0' ((Get-TcLivePageParityExit -Results @()) -eq 3) 'n/a'

    # Wiring: capture-run runs this audit on every run, after the post decision, and pages a divergence.
    $cr = [IO.File]::ReadAllText((Join-Path $here 'capture-run.ps1'))
    $callNeedle = 'audit-live-page-' + 'parity.ps1'
    $subjNeedle = 'Grocery page does not match ' + 'its shipped data'
    $iCall = $cr.IndexOf($callNeedle); $iDefer = $cr.IndexOf('$postDecision = Get-DeferredPostDecision')
    T 'CLEAN TWIN capture-run calls this audit AFTER the deferred-post decision (so a same-run publish is read, not raced)' (($iCall -gt 0) -and ($iDefer -gt 0) -and ($iCall -gt $iDefer)) ("call@" + $iCall + " defer@" + $iDefer)
    T 'CLEAN TWIN capture-run pages the divergence under its registered subject' ($cr.IndexOf($subjNeedle) -gt 0) 'subject not found'
  } catch {
    $script:f++; Write-Output ('FAIL  self-test threw: ' + $_.Exception.Message)
  }
  if ($script:f) { Write-Output ("live-page-parity SELF-TEST FAIL: {0} of {1} check(s)" -f $script:f, $script:n); exit 1 }
  Write-Output ("live-page-parity SELF-TEST PASS: {0} of {0} checks (the frozen 2026-09-26 board post and tracker, both blind halves of each arm, the retry, the exit map, the capture-run wiring)" -f $script:n)
  exit 0
}

# ------------------------------------------------------------------------------------- live run
if (-not $BuiltTrackerFile) { $BuiltTrackerFile = Join-Path $here 'out\trend\index.html' }
$results = @()

$post = Invoke-TcArmWithRetry -Attempts $Attempts -DelaySec $DelaySec -Arm {
  $html = Invoke-TcLiveHtmlFetch -Url $PostUrl
  Get-TcPostParity -LiveHtml $html -ServedFetch { Invoke-TcFeedBoardFetch }
}
$post | Add-Member -NotePropertyName Arm -NotePropertyValue 'board-post' -Force
$results += $post

$builtHtml = ''
if (Test-Path -LiteralPath $BuiltTrackerFile) { $builtHtml = [IO.File]::ReadAllText($BuiltTrackerFile, [Text.Encoding]::UTF8) }
$trk = Invoke-TcArmWithRetry -Attempts $Attempts -DelaySec $DelaySec -Arm {
  $html = Invoke-TcLiveHtmlFetch -Url $TrackerUrl
  Test-TcTrackerWeekParity -LiveHtml $html -BuiltHtml $builtHtml
}
$trk | Add-Member -NotePropertyName Arm -NotePropertyValue 'tracker' -Force
$results += $trk

$repair = @{
  'board-post' = 'Repair: publish the post from the board the feed serves, through grocery\publish-deals-page.ps1 after the push lands (it re-checks that the board is served before writing).'
  'tracker'    = 'Repair: publish out\trend\index.html through grocery\publish-trend-index.ps1 (it rides publish-deals-page only on a new board week).'
}
foreach ($r in $results) {
  switch ([string]$r.Verdict) {
    'parity'   { Write-Output ('live-page-parity ' + $r.Arm + ': PARITY - ' + $r.Why + ' (attempts=' + $r.Attempts + ')') }
    'diverged' { Write-Output ('LIVE-PAGE-PARITY DIVERGED ' + $r.Arm + ': ' + $r.Why + ' (after ' + $r.Attempts + ' read(s)). ' + $repair[[string]$r.Arm]) }
    'blind'    { Write-Output ('LIVE-PAGE-PARITY BLIND ' + $r.Arm + ': ' + $r.Why + ' (after ' + $r.Attempts + ' read(s)). Unknown is not a pass.') }
    default    { throw ('unknown arm verdict: ' + [string]$r.Verdict) }
  }
}
$code = Get-TcLivePageParityExit -Results $results
$summary = ('pages=2 diverged={0} blind={1}' -f @($results | Where-Object { $_.Verdict -eq 'diverged' }).Count, @($results | Where-Object { $_.Verdict -eq 'blind' }).Count)
Exit-Guard -Name 'live-page-parity' -Summary $summary -Code $code
