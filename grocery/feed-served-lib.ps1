<#
  feed-served-lib.ps1 - IS THE BOARD A POST WILL NAME ALREADY SERVED, BYTE FOR BYTE? (2026-09-23)

  Self-test:   powershell -File grocery\feed-served-lib.ps1 -SelfTest

  WHY. The board post embeds `https://feed.thriftycrew.com/board.json?v=<v>`, where <v> is the first ten hex digits of
  the SHA-1 of the board.json bytes build-deals-page wrote (build-deals-page.ps1, $bhash). public\board.json reaches
  readers only when a commit lands and the edge deploys it. On the night of 2026-09-22/23 an agent ran
  publish-deals-page.ps1 BY HAND before its push landed: the live post at /omaha-grocery-prices/ named
  board.json?v=780837d352 while feed.thriftycrew.com served 34d164ae13, so readers got the new post over the old board.
  Batch 2 (queue 2026-09-22-81d955) had ordered the DAILY chain (check-ad-cycles -DeferPost, then capture-run publishes
  after the edge serves the data), and a hand run went round it. .claude\rules\ops-and-gates.md: write the POINTED-TO
  object before the object that points to it.

  SO THE CHECK LIVES IN THE PUBLISHER, where every caller meets it: publish-deals-page.ps1 asks Test-TcBoardServed
  before its first Ghost write and HOLDS (exit 2) unless the version the post will name is the version the edge serves.
  The daily chain's -DeferPost road reaches the same check, because capture-run publishes through publish-deals-page.

  THE ANSWER HAS FOUR VALUES, and only one publishes:
    served       the edge's board.json hashes to the post's v. Publish.
    not-served   the edge answered with a different board. Hold: the post would point at a board readers cannot get.
    unreachable  the edge could not be read. Hold, NAMING THE CAUSE: a could-not-look is never a pass.
    no-version   the post names no board version at all, so nothing can be compared. Hold.
  Compared as BYTES (lib\git-blob-lib.ps1 Get-ResponseBytes), never as a decoded string: memo compare-bytes-not-decodings.
  The fetch carries a unique query so the edge cache is not what answers (the feed is served with max-age=1800).
#>
# No param() block: dot-sourced by publish-deals-page, whose own -SelfTest a param() here would reset (the rule
# lib\git-blob-lib.ps1 states). The switch is read off $args, and only when this file is RUN.
$__fslSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\git-blob-lib.ps1')

$script:TcFeedBoardUrlRx = 'https://feed\.thriftycrew\.com/board\.json\?v=([0-9a-f]{10})\b'

function Get-TcPostBoardVersions {
  <# Every distinct board version the rendered post names, in order. Pure over text. #>
  param([string]$Html)
  $out = [Collections.Generic.List[string]]::new()
  foreach ($m in [regex]::Matches([string]$Html, $script:TcFeedBoardUrlRx)) {
    $v = $m.Groups[1].Value
    if (-not $out.Contains($v)) { $out.Add($v) }
  }
  return , $out.ToArray()
}

function Get-TcBoardVersionOfBytes {
  <# The v= build-deals-page stamps for these exact bytes: SHA-1, hex, lower case, first ten digits. #>
  param([byte[]]$Bytes)
  if ($null -eq $Bytes) { return '' }
  $sha = [Security.Cryptography.SHA1]::Create()
  try { return (([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').Substring(0, 10).ToLowerInvariant()) }
  finally { $sha.Dispose() }
}

function Invoke-TcFeedFetch {
  <# ONE served file from feed.thriftycrew.com as raw bytes, fetched past the edge cache. THE fetch path for anything
     the feed Worker serves (board.json, smp-feed.json): a second one would drift from this one. Throws on any failure;
     the caller names it. #>
  param([string]$Name = 'board.json', [string]$BaseUrl = 'https://feed.thriftycrew.com', [int]$TimeoutSec = 45)
  $resp = Invoke-WebRequest -Uri ($BaseUrl.TrimEnd('/') + '/' + $Name + '?served-check=' + [guid]::NewGuid().ToString('N')) -UseBasicParsing -TimeoutSec $TimeoutSec
  $b = Get-ResponseBytes $resp
  if ($null -eq $b -or $b.Length -eq 0) { throw 'the feed answered with an empty body' }
  return , $b
}

function Invoke-TcFeedBoardFetch {
  <# The served board.json as raw bytes, fetched past the edge cache. Throws on any failure; the caller names it. #>
  param([string]$BaseUrl = 'https://feed.thriftycrew.com', [int]$TimeoutSec = 45)
  $b = Invoke-TcFeedFetch -Name 'board.json' -BaseUrl $BaseUrl -TimeoutSec $TimeoutSec
  return , $b
}

function Get-TcServedFeedDoc {
  <# THE SERVED smp-feed.json, parsed, else the newest COMMITTED public/smp-feed.json among -Refs (newest by its own
     `generated`). Doc is $null when none could be read; Source names which one was used, or why none was. $Fetch returns
     the served bytes or throws, and $ReadRef returns a ref's file text or $null: both are parameters so a self-test
     drives every branch with no network and no git. (2026-09-23: export-feed's shrink check and the fallback stamp
     both read the served feed; before this each carried its own fetch.) #>
  param([string]$Repo, [string[]]$Refs = @('HEAD'), [scriptblock]$Fetch = $null, [scriptblock]$ReadRef = $null, [string]$Url = 'https://feed.thriftycrew.com/smp-feed.json')
  if (-not $Fetch) { $Fetch = { Invoke-TcFeedFetch -Name 'smp-feed.json' -TimeoutSec 20 } }
  if (-not $ReadRef) {
    $ReadRef = { param($ref)
      # git's stderr must not become a terminating throw under a caller's EAP=Stop (ops-and-gates: a catch around a native
      # redirect is not a guard), so the preference is lowered as its own statement around the call.
      $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
      try { $lines = @(& git -C $Repo show ($ref + ':public/smp-feed.json') 2>$null); $rc = $LASTEXITCODE } finally { $ErrorActionPreference = $prevEap }
      if ($rc -eq 0 -and $lines.Count) { $lines -join "`n" } else { $null } }
  }
  $why = ''
  try {
    $b = & $Fetch
    if ($null -eq $b) { throw 'the fetch returned nothing' }
    $t = [Text.Encoding]::UTF8.GetString([byte[]]$b).TrimStart([char]0xFEFF)
    return [pscustomobject]@{ Doc = ($t | ConvertFrom-Json); Source = ('the served feed ' + $Url) }
  } catch { $why = $_.Exception.Message }
  $best = $null; $bestRef = ''
  foreach ($ref in $Refs) {
    try {
      $txt = & $ReadRef $ref
      if (-not $txt) { continue }
      $d = ([string]$txt).TrimStart([char]0xFEFF) | ConvertFrom-Json
      if ($null -eq $best -or [string]::CompareOrdinal([string]$d.generated, [string]$best.generated) -gt 0) { $best = $d; $bestRef = $ref }
    } catch { $why += ('; ' + $ref + ': ' + $_.Exception.Message) }
  }
  if ($null -ne $best) { return [pscustomobject]@{ Doc = $best; Source = ('the last committed ' + $bestRef + ':public/smp-feed.json, because the served feed could not be read (' + $why + ')') } }
  return [pscustomobject]@{ Doc = $null; Source = ('neither the served feed (' + $why + ') nor ' + ($Refs -join '/') + ':public/smp-feed.json could be read') }
}

function Test-TcFeedNotOlder {
  <# May a step that WRITES a price from feed $Generated go ahead, when readers are served (or main last committed) a
     feed generated $ReferenceGenerated? Only when the local feed is not older: a stamp from a day-old seeded feed writes
     a day-old price as the fallback of a card that ships today. Both dates are named in Why. Pure. Equal is not older. #>
  param([string]$Generated, [string]$ReferenceGenerated, [string]$ReferenceSource, [string]$LocalName = 'the local feed')
  $rx = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$'
  if ($Generated -notmatch $rx) { return [pscustomobject]@{ Ok = $false; Why = ($LocalName + ' carries no generated stamp (' + $Generated + '), so its age cannot be compared') } }
  if ($ReferenceGenerated -notmatch $rx) { return [pscustomobject]@{ Ok = $false; Why = ($ReferenceSource + ' carries no generated stamp (' + $ReferenceGenerated + '), so the local feed cannot be shown current') } }
  if ([string]::CompareOrdinal($Generated, $ReferenceGenerated) -lt 0) {
    return [pscustomobject]@{ Ok = $false; Why = ($LocalName + ' was generated ' + $Generated + ', OLDER than ' + $ReferenceSource + ' generated ' + $ReferenceGenerated) }
  }
  return [pscustomobject]@{ Ok = $true; Why = ($LocalName + ' generated ' + $Generated + ' is not older than ' + $ReferenceSource + ' generated ' + $ReferenceGenerated) }
}

function Test-TcBoardServed {
  <# Decide whether a post whose rendered html is $Html may be published now. $Fetch returns the served board.json
     bytes or throws; it is a parameter so the self-test drives every branch without a network. A throw is retried
     $Attempts times $DelaySec apart, because a deploy that is landing answers late; a DIFFERENT board is never
     retried, because waiting cannot make this post's board the one being served. #>
  param([string]$Html, [scriptblock]$Fetch, [int]$Attempts = 3, [int]$DelaySec = 5)
  $vs = Get-TcPostBoardVersions -Html $Html
  if ($vs.Count -ne 1) {
    $why = if ($vs.Count -eq 0) { 'the rendered post names no feed.thriftycrew.com/board.json?v= version, so there is nothing to compare with what readers are served' } else { ('the rendered post names ' + $vs.Count + ' different board versions (' + ($vs -join ', ') + '), so no one served board can match it') }
    return [pscustomobject]@{ Ok = $false; Verdict = 'no-version'; Version = ($vs -join ','); Served = ''; Why = $why }
  }
  $v = $vs[0]
  $bytes = $null; $err = ''
  for ($i = 1; $i -le [Math]::Max(1, $Attempts); $i++) {
    try { $bytes = & $Fetch; $err = ''; break } catch { $err = $_.Exception.Message; if ($i -lt $Attempts -and $DelaySec -gt 0) { Start-Sleep -Seconds $DelaySec } }
  }
  if ($err -or $null -eq $bytes) {
    if (-not $err) { $err = 'the fetch returned nothing' }
    return [pscustomobject]@{ Ok = $false; Verdict = 'unreachable'; Version = $v; Served = ''; Why = ('could not read the served board from feed.thriftycrew.com (' + $err + ')') }
  }
  $served = Get-TcBoardVersionOfBytes -Bytes ([byte[]]$bytes)
  if (-not [string]::Equals($served, $v, [StringComparison]::Ordinal)) {
    return [pscustomobject]@{ Ok = $false; Verdict = 'not-served'; Version = $v; Served = $served; Why = ('the post names board.json?v=' + $v + ' but feed.thriftycrew.com serves v=' + $served) }
  }
  return [pscustomobject]@{ Ok = $true; Verdict = 'served'; Version = $v; Served = $served; Why = '' }
}

if ($__fslSelfTest) {
  $f = 0; $n = 0
  function FsT([string]$m, [bool]$c, [string]$got = '') {
    $script:n++
    if ($c) { Write-Output ('ok    ' + $m) } else { Write-Output ('FAIL  ' + $m + '   got: ' + $got); $script:f++ }
  }
  $ErrorActionPreference = 'Stop'
  try {
    # FROZEN SYNTHETIC BOARDS. The two versions of the founding night are real (780837d352 posted, 34d164ae13 served);
    # these bytes are stand-ins whose v is computed here, never read off a live board.
    $boardNew = [Text.Encoding]::UTF8.GetBytes('{"milk":"<div>new board</div>"}')
    $boardOld = [Text.Encoding]::UTF8.GetBytes('{"milk":"<div>old board</div>"}')
    $vNew = Get-TcBoardVersionOfBytes -Bytes $boardNew
    $vOld = Get-TcBoardVersionOfBytes -Bytes $boardOld
    $postNew = "<script>var u='https://feed.thriftycrew.com/board.json?v=" + $vNew + "';</script>"
    FsT 'CLEAN TWIN  the version is the first ten hex digits of the SHA-1 of the bytes, the way build-deals-page stamps it' `
      ($vNew.Length -eq 10 -and $vNew -match '^[0-9a-f]{10}$' -and $vNew -ne $vOld) ("new={0} old={1}" -f $vNew, $vOld)
    $r1 = Test-TcBoardServed -Html $postNew -Fetch { , $boardOld } -DelaySec 0
    FsT 'MUST FIRE  a post naming a board the edge does NOT serve is refused, and says which v it named and which is served (the 2026-09-23 780837d352-over-34d164ae13 shape)' `
      ((-not $r1.Ok) -and $r1.Verdict -eq 'not-served' -and $r1.Why -match $vNew -and $r1.Why -match $vOld) ("ok={0} verdict={1} why={2}" -f $r1.Ok, $r1.Verdict, $r1.Why)
    $r2 = Test-TcBoardServed -Html $postNew -Fetch { , $boardNew } -DelaySec 0
    FsT 'CLEAN TWIN  a post naming the board the edge serves byte for byte publishes' ($r2.Ok -and $r2.Verdict -eq 'served') ("ok={0} verdict={1} why={2}" -f $r2.Ok, $r2.Verdict, $r2.Why)
    $calls = 0
    $r3 = Test-TcBoardServed -Html $postNew -Fetch { $script:calls++; throw 'The remote name could not be resolved: feed.thriftycrew.com' } -Attempts 2 -DelaySec 0
    FsT 'MUST FIRE  a feed that cannot be reached is a REFUSAL that names its cause, never a pass' `
      ((-not $r3.Ok) -and $r3.Verdict -eq 'unreachable' -and $r3.Why -match 'could not be resolved') ("ok={0} verdict={1} why={2}" -f $r3.Ok, $r3.Verdict, $r3.Why)
    $r3b = Test-TcBoardServed -Html $postNew -Fetch { $null } -Attempts 1 -DelaySec 0
    FsT 'MUST FIRE  a fetch that returns nothing is unreachable, not an empty board that happens to hash' `
      ((-not $r3b.Ok) -and $r3b.Verdict -eq 'unreachable') ("ok={0} verdict={1}" -f $r3b.Ok, $r3b.Verdict)
    $flaky = @{ n = 0 }
    $r4 = Test-TcBoardServed -Html $postNew -Fetch { $flaky.n++; if ($flaky.n -lt 2) { throw 'timed out' }; , $boardNew } -Attempts 3 -DelaySec 0
    FsT 'CLEAN TWIN  a read that fails once and then answers with the served board publishes - a deploy landing late is waited out' `
      ($r4.Ok -and $flaky.n -eq 2) ("ok={0} tries={1}" -f $r4.Ok, $flaky.n)
    $stale = @{ n = 0 }
    $r5 = Test-TcBoardServed -Html $postNew -Fetch { $stale.n++; , $boardOld } -Attempts 3 -DelaySec 0
    FsT 'MUST FIRE  a DIFFERENT served board is refused on the first answer and never retried into a pass' `
      ((-not $r5.Ok) -and $stale.n -eq 1) ("ok={0} fetches={1}" -f $r5.Ok, $stale.n)
    $r6 = Test-TcBoardServed -Html '<p>no board url here</p>' -Fetch { , $boardNew } -DelaySec 0
    FsT 'MUST FIRE  a post that names no board version is refused, because nothing can be compared' ((-not $r6.Ok) -and $r6.Verdict -eq 'no-version') ("ok={0} verdict={1}" -f $r6.Ok, $r6.Verdict)
    $two = $postNew + "<a href='https://feed.thriftycrew.com/board.json?v=" + $vOld + "'>"
    $r7 = Test-TcBoardServed -Html $two -Fetch { , $boardNew } -DelaySec 0
    FsT 'MUST FIRE  a post naming TWO board versions is refused: at most one of them can be the served board' ((-not $r7.Ok) -and $r7.Verdict -eq 'no-version') ("ok={0} verdict={1}" -f $r7.Ok, $r7.Verdict)
    $bom = [byte[]](@([byte]0xEF, [byte]0xBB, [byte]0xBF) + $boardNew)
    $r8 = Test-TcBoardServed -Html $postNew -Fetch { , $bom } -DelaySec 0
    FsT 'MUST FIRE  the comparison is on BYTES: the same text served with a BOM is a different board, never decoded into a match' ((-not $r8.Ok) -and $r8.Verdict -eq 'not-served') ("ok={0} verdict={1}" -f $r8.Ok, $r8.Verdict)
    # THE STAMP'S FRESHNESS RULE (2026-09-23): a worktree's day-old seeded feed must not stamp today's cards.
    $a1 = Test-TcFeedNotOlder -Generated '2026-09-22T08:14:34' -ReferenceGenerated '2026-09-23T00:21:31' -ReferenceSource 'the served feed' -LocalName 'the seeded feed'
    FsT 'MUST FIRE  a day-old seeded feed (2026-09-22T08:14:34) against the served one (2026-09-23T00:21:31) refuses, naming BOTH dates' `
      ((-not $a1.Ok) -and $a1.Why -match '2026-09-22T08:14:34' -and $a1.Why -match '2026-09-23T00:21:31') $a1.Why
    $a2 = Test-TcFeedNotOlder -Generated '2026-09-23T00:21:31' -ReferenceGenerated '2026-09-23T00:21:31' -ReferenceSource 'the served feed'
    FsT 'CLEAN TWIN  AT the bar: the feed readers are served, byte-for-byte current (same generated), stamps' ($a2.Ok) $a2.Why
    $a3 = Test-TcFeedNotOlder -Generated '2026-09-23T00:21:30' -ReferenceGenerated '2026-09-23T00:21:31' -ReferenceSource 'the served feed'
    FsT 'MUST FIRE  one second PAST the bar (older by 1 s) refuses' (-not $a3.Ok) $a3.Why
    $a4 = Test-TcFeedNotOlder -Generated '2026-09-23T08:00:00' -ReferenceGenerated '2026-09-23T00:21:31' -ReferenceSource 'the served feed'
    FsT 'CLEAN TWIN  a feed the chain built today, newer than the served one (not pushed yet), stamps' ($a4.Ok) $a4.Why
    $a5 = Test-TcFeedNotOlder -Generated '' -ReferenceGenerated '2026-09-23T00:21:31' -ReferenceSource 'the served feed'
    FsT 'MUST FIRE  a local feed with no generated stamp cannot be shown current and refuses' (-not $a5.Ok) $a5.Why
    $servedBytes = [Text.Encoding]::UTF8.GetBytes('{"generated":"2026-09-23T00:21:31"}')
    $d1 = Get-TcServedFeedDoc -Repo '.' -Fetch { , $servedBytes } -ReadRef { param($r) throw 'git must not be read when the served feed answers' }
    FsT 'CLEAN TWIN  the served feed is read first when it answers' ($d1.Doc.generated -eq '2026-09-23T00:21:31' -and $d1.Source -match '^the served feed') $d1.Source
    # named refTexts, NOT refs: a scriptblock reads $refs by dynamic scope and would get the function's -Refs parameter
    $refTexts = @{ 'origin/main' = '{"generated":"2026-09-23T00:21:31"}'; 'HEAD' = '{"generated":"2026-09-22T08:14:34"}' }
    $d2 = Get-TcServedFeedDoc -Repo '.' -Refs @('HEAD', 'origin/main') -Fetch { throw 'The remote name could not be resolved' } -ReadRef { param($r) $refTexts[$r] }
    FsT 'MUST FIRE  with the edge unreachable, the NEWEST committed feed (origin/main, not a stale HEAD) is the reference, and the cause is named' `
      ($d2.Doc.generated -eq '2026-09-23T00:21:31' -and $d2.Source -match 'origin/main' -and $d2.Source -match 'could not be resolved') $d2.Source
    $d3 = Get-TcServedFeedDoc -Repo '.' -Refs @('HEAD') -Fetch { throw 'offline' } -ReadRef { param($r) $null }
    FsT 'MUST FIRE  with neither the edge nor a commit readable, Doc is null and Source says why - never an empty feed' ($null -eq $d3.Doc -and $d3.Source -match 'neither') $d3.Source  } catch {
    $f++; Write-Output ('FAIL  the self-test threw: ' + $_.Exception.Message)
  }
  if ($n -lt 18) { $f++; Write-Output ("FAIL  only {0} of 18 cases ran" -f $n) }
  if ($f) { Write-Output ("feed-served-lib SELF-TEST FAIL: {0} of {1} case(s)" -f $f, $n); exit 1 }
  Write-Output ("feed-served-lib SELF-TEST PASS: {0} cases - led by a post naming an unserved board being refused, a served board publishing, and an unreachable feed refusing with its cause" -f $n)
  exit 0
}
