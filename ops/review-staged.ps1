<#
  review-staged.ps1 - drain the staged-write queue: show every queued Ghost call, then apply or discard.

  E1 v1 (STAGING). The bet this design makes: reads execute immediately, writes queue, and a review pass
  stands between an agent and the only genuinely irreversible thing this estate does. See
  design\E1-safety-layer-brief.md - the local targets are all tracked, so git is already the undo log
  there, and the surviving exposure is a PUT to the Ghost admin API on a live paid site.

  THE ARGUMENT FOR THIS DESIGN OVER AN UNDO LOG: the problem is usually in the COMBINATION, not in any
  single call. A reviewer looking at the whole queue can see that a wave is about to publish eleven
  posts when the batch was ten, or that two calls target the same slug. Nothing at the level of one
  call can see that, and an undo log by construction only ever sees one call at a time.

  THE COST, STATED RATHER THAN HIDDEN: a staged write is not a write. Any caller that reads a field off
  the response - a new post id, an updated_at to send with the next PUT - gets an object that does not
  carry it. ghost-lib's Add-TcStagedCall deliberately does not fabricate one, so such a caller FAILS
  instead of proceeding on invented data. That is the right failure, and it is still a failure: this
  design cannot be switched on for a chain that round-trips a response without that chain being taught
  about staging first. The e1-undo-log branch pays nothing here and buys less.

  Usage:
    $env:TC_STAGE_WRITES = 'ops\staged-writes.jsonl'   # arm it, then run the publish chain
    powershell -File ops\review-staged.ps1                       # list what is queued
    powershell -File ops\review-staged.ps1 -Apply                # send them, oldest first
    powershell -File ops\review-staged.ps1 -Discard              # throw the queue away

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 findings, 3 could-not-evaluate.
  Read the verdict LINE, not the number (backlog E2).
#>
param(
  [string]$Queue = '',
  [switch]$Apply,
  [switch]$Discard,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ghost-lib.ps1')

function Read-TcQueue {
  <# Pure: parse JSON Lines into entries, and report the bad lines rather than skipping them silently.
     A queue file that half-parses is the worst case for this design - it means some intended write is
     invisible to the reviewer while looking like the queue was read. #>
  param([string[]]$Lines)
  $ok = @(); $bad = @()
  $i = 0
  foreach ($l in @($Lines)) {
    $i++
    if (-not $l -or -not $l.Trim()) { continue }
    try { $ok += ($l | ConvertFrom-Json) } catch { $bad += ("line $i") }
  }
  return ,([pscustomobject]@{ Entries = @($ok); Bad = @($bad) })
}

# Get-TcQueueConcerns LIVES IN lib\ghost-lib.ps1, which this file already dot-sources.
# It moved there 2026-09-06 when ops\drain-staged.ps1 needed it too: that script cannot
# dot-source THIS one, because review-staged declares a param() block and PS 5.1 runs a
# dot-sourced param block in the caller's scope (lib\guard-contract.ps1 documents the
# damage). Two callers, one implementation - do not add a local copy back.

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0
  function T($m, $cond, $got) { if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }

  # --- the gate itself: which verbs close it
  T 'MUST FIRE  PUT is mutating and is staged'    (Test-TcMutatingMethod 'PUT')    'not mutating'
  T 'MUST FIRE  POST is mutating and is staged'   (Test-TcMutatingMethod 'POST')   'not mutating'
  T 'MUST FIRE  DELETE is mutating and is staged' (Test-TcMutatingMethod 'DELETE') 'not mutating'
  T 'MUST FIRE  a lower-case verb still stages'   (Test-TcMutatingMethod 'put')    'case-sensitive gate leaks a write'
  T 'MUST NOT FIRE GET is a read and executes immediately'  (-not (Test-TcMutatingMethod 'GET'))  'a read was staged'
  T 'MUST NOT FIRE HEAD is a read and executes immediately' (-not (Test-TcMutatingMethod 'HEAD')) 'a read was staged'

  # --- OFF BY DEFAULT. If this ever fails, arming has leaked and all 29 callers changed behaviour.
  $saved = $env:TC_STAGE_WRITES
  $env:TC_STAGE_WRITES = $null
  T 'MUST FIRE  staging is OFF unless TC_STAGE_WRITES is set' ($null -eq (Get-TcStageQueue)) 'armed with no env var'
  $env:TC_STAGE_WRITES = 'X:\somewhere\q.jsonl'
  T 'the env var arms it' ((Get-TcStageQueue) -eq 'X:\somewhere\q.jsonl') (Get-TcStageQueue)
  $env:TC_STAGE_WRITES = $saved

  # --- the queue round-trips, and a real staged call never sends
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("tcstage-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".jsonl")
  try {
    # THE LOAD-BEARING CASE. A uri that would 404 loudly if it were actually sent: if staging ever stops
    # short-circuiting, this call reaches the network and the test fails by throwing rather than by
    # asserting. That is deliberate - "it did not send" is otherwise unfalsifiable from inside a unit test.
    $r = Add-TcStagedCall -Queue $tmp -Method 'PUT' -Uri 'https://invalid.invalid/ghost/api/admin/posts/zzz/' -Headers @{ Authorization = 'Ghost SECRET-JWT'; 'Content-Type' = 'application/json' } -Body '{"posts":[{"title":"x"}]}'
    T 'MUST FIRE  a staged call returns the staged marker, not a response' ($r.__tc_staged -eq $true) ($r | ConvertTo-Json -Compress)
    T 'MUST FIRE  a staged call fabricates no id field' ($null -eq $r.PSObject.Properties['id']) 'an id was invented'
    $q = Read-TcQueue -Lines ([IO.File]::ReadAllLines($tmp))
    T 'the queue round-trips to one entry' ($q.Entries.Count -eq 1) ("Count=" + $q.Entries.Count)
    # THE MARKER'S ONE READING (2026-09-07, backlog E1). Test-TcStaged decides, at two publishers,
    # whether a slug is reported as SHIPPED or as STILL LIVE. Pinned here rather than at the call
    # sites because an inline property test could only have been asserted by a self-test grepping its
    # own source, which cannot fail. [[selftest-greps-its-own-source]]
    T 'MUST FIRE  a staged result reads as staged' (Test-TcStaged ([pscustomobject]@{ __tc_staged = $true })) 'a queued write would be reported as sent'
    T 'MUST NOT FIRE  THE ONE THAT MATTERS - a real Ghost response has no such property and must read NOT staged, or a run that SENT everything reports it all queued' `
      (-not (Test-TcStaged ([pscustomobject]@{ posts = @(1) }))) 'a live response read as staged'
    T 'MUST NOT FIRE  $null - a variable left unset by a throw is not a staged write' `
      (-not (Test-TcStaged $null)) 'null read as staged'
    T 'CLEAN TWIN the property present but FALSE reads as not staged, so the flag means what it says' `
      (-not (Test-TcStaged ([pscustomobject]@{ __tc_staged = $false }))) 'a false flag read as true'

    T 'the entry records the method and uri' (($q.Entries[0].method -eq 'PUT') -and ($q.Entries[0].uri -like 'https://invalid.invalid/*')) 'method/uri lost'

    # THE BYTE[] ROUND-TRIP, WHICH IS THE ONLY SHAPE THE LIVE CHAIN ACTUALLY STAGES (2026-09-07).
    # publish.ps1:277 and :280 and wave-publish.ps1:1163 all pass [Text.Encoding]::UTF8.GetBytes(...).
    # Until today that branch stored the STRING "(byte[] length N)" and -Apply replayed it with
    # -Body $e.body, so approving a staged write would have sent that description to Ghost as the post
    # body. Every case above stages a STRING, which round-trips fine and hid it completely - a
    # mechanism tested only on the shape it never sees in production.
    $btmp = Join-Path ([IO.Path]::GetTempPath()) ('staged-bytes-' + [guid]::NewGuid().ToString('N') + '.jsonl')
    try {
      $origJson = '{"posts":[{"title":"byte round trip"}]}'
      $null = Add-TcStagedCall -Queue $btmp -Method 'PUT' -Uri 'https://invalid.invalid/ghost/api/admin/posts/bbb/' -Headers @{} -Body ([Text.Encoding]::UTF8.GetBytes($origJson))
      $bq = Read-TcQueue -Lines ([IO.File]::ReadAllLines($btmp))
      $be = $bq.Entries[0]
      T 'MUST FIRE  a byte[] body is stored as base64, not as a description of itself' ([string]$be.body_b64 -ne '' -and [string]$be.body -notlike '*byte`[`]*') ("body=" + [string]$be.body + " b64len=" + ([string]$be.body_b64).Length)
      $round = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$be.body_b64))
      T 'MUST FIRE  the staged bytes restore to the EXACT body that was going to be sent' ($round -eq $origJson) $round
      T 'the byte length is recorded beside them' ([int]$be.body_bytes -eq [Text.Encoding]::UTF8.GetByteCount($origJson)) ([string]$be.body_bytes)
    } finally { Remove-Item $btmp -Force -ErrorAction SilentlyContinue }
    # SECURITY: the Authorization header carries a live admin JWT and must never reach the queue file.
    $raw = [IO.File]::ReadAllText($tmp)
    T 'MUST FIRE  the queue file holds NO credential, only header NAMES' (-not ($raw -match 'SECRET-JWT')) 'a live admin JWT was written to disk'
    T 'the header names are still recorded' (@($q.Entries[0].header_names) -contains 'Authorization') 'header names lost'
  } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }

  # --- a half-parsing queue must be reported, never silently skipped
  $q2 = Read-TcQueue -Lines @('{"method":"PUT","uri":"a"}', 'this is not json', '', '{"method":"GET","uri":"b"}')
  T 'MUST FIRE  an unparseable queue line is REPORTED, not skipped' ($q2.Bad.Count -eq 1) ("Bad=" + $q2.Bad.Count)
  T 'the parseable lines still come through' ($q2.Entries.Count -eq 2) ("Entries=" + $q2.Entries.Count)

  # --- the set-level concerns: this is what an undo log structurally cannot do
  $set = @(
    [pscustomobject]@{ method = 'PUT'; uri = 'https://h/posts/a/'; caller = 'wave-publish.ps1' },
    [pscustomobject]@{ method = 'PUT'; uri = 'https://h/posts/a/'; caller = 'wave-publish.ps1' },
    [pscustomobject]@{ method = 'DELETE'; uri = 'https://h/posts/b/'; caller = 'other.ps1' }
  )
  $con = Get-TcQueueConcerns -Entries $set
  T 'MUST FIRE  two calls on one uri are flagged' (@($con | Where-Object { $_ -like '*same uri*' }).Count -eq 1) ($con -join ' | ')
  T 'MUST FIRE  a queued DELETE is flagged as unrestorable' (@($con | Where-Object { $_ -like '*DELETE*' }).Count -eq 1) ($con -join ' | ')
  T 'MUST FIRE  a queue spanning two scripts is flagged' (@($con | Where-Object { $_ -like '*different scripts*' }).Count -eq 1) ($con -join ' | ')
  $clean = @([pscustomobject]@{ method = 'PUT'; uri = 'https://h/posts/a/'; caller = 'wave-publish.ps1' })
  # ASSIGN THEN WRAP. `@(Get-TcQueueConcerns ...)` inline reports Count=1 on an EMPTY result - see the
  # note on that function. Written the wrong way first, and this clean twin is what caught it.
  $cleanCon = Get-TcQueueConcerns -Entries $clean
  T 'MUST NOT FIRE one PUT from one caller raises nothing' (@($cleanCon).Count -eq 0) (@($cleanCon) -join ' | ')

  # --- A POST CREATES, so a queue of different creates on ONE collection uri is not a duplicate (2026-09-19).
  # Keyed on uri alone, the three new lessons' queue (three POSTs to /posts/?source=html, one per lesson)
  # read "3 calls target the same uri" with nothing wrong in it. The duplicate that matters for a POST is the
  # SAME body queued twice, which would create the same post twice, and that must still fire.
  $postUri = 'https://h/ghost/api/admin/posts/?source=html'
  $threeCreates = @(
    [pscustomobject]@{ method = 'POST'; uri = $postUri; body_b64 = 'QUFB'; caller = 'stage.ps1' },
    [pscustomobject]@{ method = 'POST'; uri = $postUri; body_b64 = 'QkJC'; caller = 'stage.ps1' },
    [pscustomobject]@{ method = 'POST'; uri = $postUri; body_b64 = 'Q0ND'; caller = 'stage.ps1' }
  )
  $conCreates = Get-TcQueueConcerns -Entries $threeCreates
  T 'MUST NOT FIRE three POSTs to one collection uri with three DIFFERENT bodies raise nothing - they create three things' (@($conCreates).Count -eq 0) (@($conCreates) -join ' | ')
  $sameCreate = @(
    [pscustomobject]@{ method = 'POST'; uri = $postUri; body_b64 = 'QUFB'; caller = 'stage.ps1' },
    [pscustomobject]@{ method = 'POST'; uri = $postUri; body_b64 = 'QUFB'; caller = 'stage.ps1' }
  )
  $conSame = Get-TcQueueConcerns -Entries $sameCreate
  T 'MUST FIRE  the SAME POST body queued twice is flagged, because it would create the same post twice' (@($conSame | Where-Object { $_ -like '*SAME body*' }).Count -eq 1) (@($conSame) -join ' | ')
  $sameText = @(
    [pscustomobject]@{ method = 'POST'; uri = $postUri; body = '{"posts":[{"title":"a"}]}'; caller = 'stage.ps1' },
    [pscustomobject]@{ method = 'POST'; uri = $postUri; body = '{"posts":[{"title":"a"}]}'; caller = 'stage.ps1' }
  )
  $conText = Get-TcQueueConcerns -Entries $sameText
  T 'MUST FIRE  the same STRING body POSTed twice is flagged too, not only a byte[] one' (@($conText | Where-Object { $_ -like '*SAME body*' }).Count -eq 1) (@($conText) -join ' | ')
  $twoPuts = @(
    [pscustomobject]@{ method = 'PUT'; uri = 'https://h/posts/a/'; body_b64 = 'QUFB'; caller = 'stage.ps1' },
    [pscustomobject]@{ method = 'PUT'; uri = 'https://h/posts/a/'; body_b64 = 'QkJC'; caller = 'stage.ps1' }
  )
  $conPuts = Get-TcQueueConcerns -Entries $twoPuts
  T 'CLEAN TWIN two PUTs to ONE post are still flagged when their bodies DIFFER - a PUT names one resource, so the body never splits it' (@($conPuts | Where-Object { $_ -like '*same uri*' }).Count -eq 1) (@($conPuts) -join ' | ')

  # --- THE COMPOSITION CASE. The one thing having BOTH mechanisms can get wrong, and the reason the
  # order of the two gates in ghost-lib is load-bearing rather than stylistic.
  #
  # Staging is checked FIRST. A staged call never goes out, so there is nothing to reverse and it must
  # leave NO journal entry. Reverse the two gates and the journal fills with before-images of writes
  # that never happened - and revert-ghost-write would then cheerfully offer to "restore" a resource
  # nothing ever touched. That is worse than having no journal at all.
  $sq = $env:TC_STAGE_WRITES; $sj = $env:TC_WRITE_JOURNAL
  $bq = Join-Path ([IO.Path]::GetTempPath()) ("tcboth-q-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".jsonl")
  $bj = Join-Path ([IO.Path]::GetTempPath()) ("tcboth-j-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".jsonl")
  try {
    # BOTH ARMED AT ONCE, which is the configuration this case exists for.
    $env:TC_STAGE_WRITES = $bq
    $env:TC_WRITE_JOURNAL = $bj
    # invalid.invalid again: if staging ever stops winning, the journal's before-GET reaches the network
    # and this fails by throwing rather than by asserting.
    $rb = Invoke-GhostApi -Method 'PUT' -Uri 'https://invalid.invalid/ghost/api/admin/posts/zzz/' -Headers @{ Authorization = 'Ghost SECRET-JWT' } -Body '{"posts":[{"title":"x"}]}'
    T 'MUST FIRE  with BOTH armed, the call is STAGED' ($rb.__tc_staged -eq $true) ($rb | ConvertTo-Json -Compress)
    T 'MUST FIRE  a staged call leaves NO journal entry - staging wins, and nothing that did not happen is recorded' `
      (-not (Test-Path -LiteralPath $bj)) 'a journal entry was written for a call that never went out'
    T 'the staged call did reach the QUEUE' ((Test-Path -LiteralPath $bq) -and (@([IO.File]::ReadAllLines($bq)) | Where-Object { $_.Trim() }).Count -eq 1) 'the queue is empty or over-full'

    # CLEAN TWIN: with only the journal armed, a mutating call is NOT staged and DOES journal. Without
    # this, the case above would pass just as well if the journal were broken outright.
    $env:TC_STAGE_WRITES = $null
    try { $null = Invoke-GhostApi -Method 'PUT' -Uri 'https://invalid.invalid/ghost/api/admin/posts/yyy/' -Headers @{} -Body '{}' -MaxRetries 0 -TimeoutSec 5 } catch { }
    T 'CLEAN TWIN with staging OFF the journal DOES record the write, so the case above is not passing vacuously' `
      ((Test-Path -LiteralPath $bj) -and (@([IO.File]::ReadAllLines($bj)) | Where-Object { $_.Trim() }).Count -eq 1) 'the journal recorded nothing with staging off'
  } finally {
    $env:TC_STAGE_WRITES = $sq; $env:TC_WRITE_JOURNAL = $sj
    foreach ($x in @($bq, $bj)) { if (Test-Path -LiteralPath $x) { Remove-Item -LiteralPath $x -Force } }
  }

  # --- WHICH METHODS INVOKE-GHOSTAPI REPLAYS (2026-09-19, backlog I198). A POST creates, and with
  # ?newsletter= it MAILS THE LIST, so a POST whose reply was lost must not be sent again. The transport
  # and the backoff sleep are seams in ghost-lib; these cases redefine both, so no case reaches a network.
  $origTransport = ${function:Invoke-TcGhostTransport}; $origWait = ${function:Wait-TcGhostRetry}
  $sq2 = $env:TC_STAGE_WRITES; $sj2 = $env:TC_WRITE_JOURNAL
  $script:ghostCalls = 0; $script:ghostPlan = @()
  function Invoke-TcGhostTransport { param([hashtable]$CallArgs, [switch]$Web)
    $i = $script:ghostCalls; $script:ghostCalls++
    $step = if ($i -lt $script:ghostPlan.Count) { $script:ghostPlan[$i] } else { $script:ghostPlan[-1] }
    if ($step -is [Exception]) { throw $step }
    return $step }
  function Wait-TcGhostRetry { param([int]$Seconds) }
  function New-StubTimeout { return (New-Object System.Net.WebException('The operation has timed out', [System.Net.WebExceptionStatus]::Timeout)) }
  function New-Stub503 { $x = New-Object System.Exception 'The remote server returned an error: (503) Server Unavailable.'; $x | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 503 }); return $x }
  function New-StubRefused { return (New-Object System.Net.WebException('Unable to connect to the remote server', [System.Net.WebExceptionStatus]::ConnectFailure)) }
  function Invoke-Stubbed([string]$Method, [object[]]$Plan) {
    $script:ghostCalls = 0; $script:ghostPlan = $Plan; $threw = $false; $res = $null
    try { $res = Invoke-GhostApi -Method $Method -Uri 'https://invalid.invalid/ghost/api/admin/posts/' -Headers @{} -Body '{}' -MaxRetries 3 } catch { $threw = $true }
    return [pscustomobject]@{ Calls = $script:ghostCalls; Threw = $threw; Result = $res }
  }
  try {
    $env:TC_STAGE_WRITES = $null; $env:TC_WRITE_JOURNAL = $null
    $r = Invoke-Stubbed 'POST' @((New-StubTimeout))
    T 'MUST FIRE  a POST that times out is attempted EXACTLY ONCE and thrown (Ghost may already have mailed the list)' (($r.Calls -eq 1) -and $r.Threw) ("calls=" + $r.Calls + " threw=" + $r.Threw)
    $r = Invoke-Stubbed 'POST' @((New-Stub503))
    T 'MUST FIRE  a POST answered 503 is attempted exactly once (a 5xx can follow the effect)' (($r.Calls -eq 1) -and $r.Threw) ("calls=" + $r.Calls + " threw=" + $r.Threw)
    $r = Invoke-Stubbed 'POST' @((New-StubRefused), [pscustomobject]@{ posts = @('created') })
    T 'CLEAN TWIN a POST whose connection was REFUSED is still retried, and the retry lands' (($r.Calls -eq 2) -and -not $r.Threw -and ($r.Result.posts[0] -eq 'created')) ("calls=" + $r.Calls + " threw=" + $r.Threw)
    $r = Invoke-Stubbed 'GET' @((New-StubTimeout))
    T 'CLEAN TWIN a GET that times out is still retried, 1 + MaxRetries = 4 attempts' (($r.Calls -eq 4) -and $r.Threw) ("calls=" + $r.Calls + " threw=" + $r.Threw)
    $r = Invoke-Stubbed 'GET' @((New-StubTimeout), [pscustomobject]@{ posts = @('read') })
    T 'CLEAN TWIN a GET that times out once then answers returns the answer' (($r.Calls -eq 2) -and -not $r.Threw -and ($r.Result.posts[0] -eq 'read')) ("calls=" + $r.Calls + " threw=" + $r.Threw)
    $r = Invoke-Stubbed 'PUT' @((New-Stub503))
    T 'CLEAN TWIN a PUT answered 503 keeps the old retry (updated_at makes a replay a 409, never a second write)' (($r.Calls -eq 4) -and $r.Threw) ("calls=" + $r.Calls + " threw=" + $r.Threw)
    T 'MUST NOT FIRE a timeout is not proof the request went unsent' (-not (Test-TcGhostNeverSent (New-StubTimeout))) 'a timeout read as never-sent'
    T 'MUST NOT FIRE a bare exception carrying a 503 is not proof either' (-not (Test-TcGhostNeverSent (New-Stub503))) 'a 503 read as never-sent'
    T 'MUST FIRE  an unresolvable name IS proof' (Test-TcGhostNeverSent (New-Object System.Net.WebException('x', [System.Net.WebExceptionStatus]::NameResolutionFailure))) 'NameResolutionFailure not read as never-sent'
    # A STUBBED TRANSPORT IS NEVER JOURNALLED (2026-09-18, backlog I231). On this box TC_WRITE_JOURNAL is set
    # in the USER environment to the main checkout's live journal, so a test that forgot to clear it would
    # record a stubbed write that never reached Ghost. Armed here at a temp journal, as the environment arms it.
    $j231 = Join-Path ([IO.Path]::GetTempPath()) ('tcj231-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.jsonl')
    try {
      $env:TC_WRITE_JOURNAL = $j231
      $r = Invoke-Stubbed 'PUT' @([pscustomobject]@{ posts = @('put') })
      T 'MUST FIRE  with the journal ARMED and the transport STUBBED, a PUT writes NO journal entry and sends no before-GET' ((-not (Test-Path -LiteralPath $j231)) -and ($r.Calls -eq 1) -and -not $r.Threw) ("journal=" + (Test-Path -LiteralPath $j231) + " calls=" + $r.Calls + " threw=" + $r.Threw)
      T 'MUST FIRE  a redefined transport is recognised as a stub' (-not (Test-TcGhostTransportIsReal)) 'a stub read as the real transport'
    } finally {
      $env:TC_WRITE_JOURNAL = $null
      if (Test-Path -LiteralPath $j231) { Remove-Item -LiteralPath $j231 -Force }
    }
  } finally {
    Set-Item -Path function:Invoke-TcGhostTransport -Value $origTransport
    Set-Item -Path function:Wait-TcGhostRetry -Value $origWait
    $env:TC_STAGE_WRITES = $sq2; $env:TC_WRITE_JOURNAL = $sj2
  }
  T 'CLEAN TWIN the restored original transport reads as REAL again, so a restored seam still journals real writes' (Test-TcGhostTransportIsReal) 'the restored original read as a stub'

  # --- ONE ACCEPT-VERSION, AND IT IS v6.0 (Brad's ruling 2026-09-19, backlog I230). Every live caller builds its
  # header as 'Accept-Version' = (Get-GhostAcceptVersion); the stubbed transport below records what would have
  # gone out, so no case reaches a network. The needles are built by concatenation so this file cannot match
  # itself ([[selftest-greps-its-own-source]]).
  $origT3 = ${function:Invoke-TcGhostTransport}; $sq3 = $env:TC_STAGE_WRITES; $sj3 = $env:TC_WRITE_JOURNAL
  $script:sentVersion = '<none>'
  function Invoke-TcGhostTransport { param([hashtable]$CallArgs, [switch]$Web)
    $script:sentVersion = [string]$CallArgs['Headers']['Accept-Version']
    return [pscustomobject]@{ posts = @('v') } }
  try {
    $env:TC_STAGE_WRITES = $null; $env:TC_WRITE_JOURNAL = $null
    [void](Invoke-GhostApi -Method 'GET' -Uri 'https://invalid.invalid/ghost/api/admin/site/' -Headers @{ Authorization = 'Ghost stub'; 'Accept-Version' = (Get-GhostAcceptVersion) })
    T 'MUST FIRE  a header built the way every live caller builds it SENDS Accept-Version v6.0' ([string]::Equals($script:sentVersion, 'v6.0', [StringComparison]::Ordinal)) $script:sentVersion
  } finally {
    Set-Item -Path function:Invoke-TcGhostTransport -Value $origT3
    $env:TC_STAGE_WRITES = $sq3; $env:TC_WRITE_JOURNAL = $sj3
  }
  $avName = "'Accept-" + "Version'"
  $avLiteral = [regex]("(?i)" + [regex]::Escape($avName) + "\s*=\s*'v\d")
  $avJsLiteral = [regex]('(?i)"Accept-' + 'Version"\s*:\s*"v\d')
  $avSample = $avName + " = 'v" + "5.0'"
  T 'MUST FIRE  the literal-version detector sees a hand-written version in a header' ($avLiteral.IsMatch($avSample)) $avSample
  T 'MUST NOT FIRE the detector is silent on the one-place form' (-not $avLiteral.IsMatch($avName + ' = (Get-GhostAcceptVersion)')) 'the function form read as a literal'
  $repoRoot = Split-Path -Parent $PSScriptRoot
  $avFiles = @(& git -C $repoRoot ls-files -- '*.ps1')
  $avLive = @($avFiles | Where-Object { $_ -notmatch '(^|/)archive/' })
  $avHits = @()
  foreach ($rel in $avLive) {
    $full = Join-Path $repoRoot ($rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $full)) { continue }
    if ($avLiteral.IsMatch([IO.File]::ReadAllText($full))) { $avHits += $rel }
  }
  T ('MUST NOT FIRE no tracked live .ps1 writes its own Accept-Version: 0 hand-written versions over ' + $avLive.Count + ' files (archive excluded)') (($avLive.Count -gt 100) -and ($avHits.Count -eq 0)) (($avHits -join ', ') + ' scanned=' + $avLive.Count)
  $wjs = Join-Path $repoRoot 'worker\index.js'
  $wtext = if (Test-Path -LiteralPath $wjs) { [IO.File]::ReadAllText($wjs) } else { '' }
  $wm = [regex]::Match($wtext, 'GHOST_ACCEPT_VERSION\s*=\s*"([^"]+)"')
  T 'CLEAN TWIN the worker (a separate runtime) asks for the same version as ghost-lib, through its one constant' ($wm.Success -and [string]::Equals($wm.Groups[1].Value, (Get-GhostAcceptVersion), [StringComparison]::Ordinal)) ("worker=" + $wm.Groups[1].Value + " lib=" + (Get-GhostAcceptVersion))
  T 'MUST NOT FIRE the worker writes no version literal into its header' (-not $avJsLiteral.IsMatch($wtext)) 'a literal version in worker\index.js'

  # --- A PAGED READ ENDS ON OUR COUNT, NOT ON GHOST'S SAY-SO (2026-09-19, backlog I197). grocery\ghost-export.ps1
  # followed meta.pagination.next until Ghost stopped sending one, so a next that repeated or rewound looped forever.
  # Every $Fetch here is a stub, so no case reaches a network. The stub itself refuses past 50 calls: a neutered
  # loop must END and read red with its call count, never hang the suite into run-gates' job timeout.
  function New-PagedStub([object[]]$NextByPage) {
    $script:pagedCalls = 0
    $script:pagedNext = $NextByPage
    return {
      param($page)
      $script:pagedCalls++
      if ($script:pagedCalls -gt 50) { throw 'stub: fetched past 50 pages - the loop did not stop' }
      $nx = if ($page -le $script:pagedNext.Count) { $script:pagedNext[$page - 1] } else { $script:pagedNext[-1] }
      [pscustomobject]@{ posts = @('p' + $page); meta = [pscustomobject]@{ pagination = [pscustomobject]@{ page = $page; next = $nx } } }
    }
  }
  function Invoke-PagedCase([scriptblock]$Fetch, [int]$Max) {
    $threw = ''; $res = $null
    try { $res = Invoke-TcGhostPaged -Fetch $Fetch -MaxPages $Max } catch { $threw = $_.Exception.Message }
    return [pscustomobject]@{ Calls = $script:pagedCalls; Threw = $threw; Pages = @($res).Count; Items = (@($res) | ForEach-Object { $_.posts }) -join ',' }
  }
  # Every page answers next=1: page 1 names itself as the next page.
  $pc = Invoke-PagedCase (New-PagedStub @(1)) 1000
  T 'MUST FIRE  a next that REPEATS the page just read is refused after ONE fetch, not followed forever' (($pc.Calls -eq 1) -and ($pc.Threw -like '*did not advance*')) ("calls=" + $pc.Calls + " threw=" + $pc.Threw)
  # Page 1 says 2, page 2 rewinds to 1.
  $pc = Invoke-PagedCase (New-PagedStub @(2, 1)) 1000
  T 'MUST FIRE  a next that REWINDS is refused on the page that rewound' (($pc.Calls -eq 2) -and ($pc.Threw -like '*did not advance*')) ("calls=" + $pc.Calls + " threw=" + $pc.Threw)
  # Always advancing, never ending: next = page + 1 on every page.
  $adv = @(); for ($k = 2; $k -le 60; $k++) { $adv += $k }
  $pc = Invoke-PagedCase (New-PagedStub $adv) 5
  T 'MUST FIRE  a next that advances forever stops at the page cap and THROWS rather than returning a partial list' (($pc.Calls -eq 5) -and ($pc.Threw -like '*the cap*')) ("calls=" + $pc.Calls + " threw=" + $pc.Threw)
  $pc = Invoke-PagedCase (New-PagedStub @(2, 3, $null)) 1000
  T 'CLEAN TWIN three pages ending in an empty next are all read, in order, with no throw' (($pc.Calls -eq 3) -and -not $pc.Threw -and ($pc.Items -eq 'p1,p2,p3')) ("calls=" + $pc.Calls + " items=" + $pc.Items + " threw=" + $pc.Threw)
  $pc = Invoke-PagedCase (New-PagedStub @(2, 3, $null)) 3
  T 'CLEAN TWIN a list exactly as long as the cap is read whole - the cap refuses a FOURTH page, never the third' (($pc.Calls -eq 3) -and -not $pc.Threw -and ($pc.Pages -eq 3)) ("calls=" + $pc.Calls + " pages=" + $pc.Pages + " threw=" + $pc.Threw)
  $pc = Invoke-PagedCase { param($page) $script:pagedCalls = 1; [pscustomobject]@{ posts = @('only') } } 1000
  T 'CLEAN TWIN a response with no pagination block at all is one page, read once' (($pc.Pages -eq 1) -and -not $pc.Threw -and ($pc.Items -eq 'only')) ("pages=" + $pc.Pages + " items=" + $pc.Items + " threw=" + $pc.Threw)

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: the staging gate, off-by-default, credential redaction, queue round-trip, a half-parsing queue, the three set-level concerns, the composition case (staging wins over the journal, with a clean twin proving the journal still works), which methods Invoke-GhostApi replays (a POST only when provably unsent), the one Accept-Version (v6.0, sent by every live caller and the worker), and a paged read that ends on its own count'
  exit 0
}

# ------------------------------------------------------------------------------------- live run
if (-not $Queue) { $Queue = $(if ($env:TC_STAGE_WRITES) { $env:TC_STAGE_WRITES } else { Join-Path $repo 'ops\staged-writes.jsonl' }) }
if (-not (Test-Path -LiteralPath $Queue)) {
  Write-Output ("review-staged: nothing queued ({0} does not exist). Staging is armed by setting TC_STAGE_WRITES before a run; an empty queue after an ARMED run means nothing tried to write." -f $Queue)
  Exit-Guard -Name 'review-staged' -Summary 'queued=0' -Code 0
}
$parsed = Read-TcQueue -Lines ([IO.File]::ReadAllLines($Queue))
if ($parsed.Bad.Count) {
  Write-Output ("REVIEW-STAGED COULD NOT EVALUATE: {0} queue line(s) will not parse ({1}). Some intended write is invisible to this review, so applying now would send an unknown subset." -f $parsed.Bad.Count, ($parsed.Bad -join ', '))
  Exit-Guard -Name 'review-staged' -Summary ("blind=badlines-" + $parsed.Bad.Count) -Code 3
}
$entries = @($parsed.Entries)
Write-Output ("review-staged: {0} call(s) queued in {1}" -f $entries.Count, $Queue)
foreach ($e in $entries) {
  Write-Output ("  [{0}] {1,-6} {2}" -f $e.id, $e.method, $e.uri)
  Write-Output ("           from {0}" -f $(if ($e.caller) { $e.caller } else { '(caller unknown)' }))
  if ($e.body) {
    $b = [string]$e.body
    Write-Output ("           body {0}" -f $(if ($b.Length -gt 300) { $b.Substring(0, 300) + ' ...(' + $b.Length + ' chars)' } else { $b }))
  }
}
$concerns = Get-TcQueueConcerns -Entries $entries   # ASSIGN THEN WRAP: @(call) would report 1 concern when there are none
$concerns = @($concerns)
if ($concerns.Count) {
  Write-Output ''
  Write-Output '  CONCERNS ACROSS THE SET (the thing a per-call undo log cannot see):'
  foreach ($c in $concerns) { Write-Output ("    ! " + $c) }
}

if ($Discard) {
  Remove-Item -LiteralPath $Queue -Force
  Write-Output ("review-staged: DISCARDED - {0} call(s) thrown away, nothing was sent." -f $entries.Count)
  Exit-Guard -Name 'review-staged' -Summary ("discarded=" + $entries.Count) -Code 0
}
if (-not $Apply) {
  Write-Output ''
  Write-Output ("review-staged: {0} call(s) are WAITING and nothing has been sent. Re-run with -Apply to send them, or -Discard to throw them away." -f $entries.Count)
  Exit-Guard -Name 'review-staged' -Summary ("queued={0} concerns={1}" -f $entries.Count, $concerns.Count) -Code $(if ($concerns.Count) { 2 } else { 0 })
}

# --- apply. The queue is drained oldest first, and the JWT is re-minted here rather than replayed:
# the one captured at stage time was five-minute and is long dead, which is exactly why it was not stored.
$key = Get-GhostKey -Root $repo
$sent = 0; $failed = @()
foreach ($e in $entries) {
  $h = @{ Authorization = ('Ghost ' + (Get-GhostJWT -Key $key)) }
  if (@($e.header_names) -contains 'Content-Type') { $h['Content-Type'] = 'application/json' }
  try {
    # TC_STAGE_WRITES must be OFF for this process or the apply would re-stage its own queue forever.
    $env:TC_STAGE_WRITES = $null
    # RESTORE THE ORIGINAL BYTES (2026-09-07). A byte[] body is staged as base64 because recording it
    # as "(byte[] length N)" and replaying THAT is what this line used to do - it would have sent the
    # description to Ghost as the post body.
    $replayBody = $e.body
    if ($e.PSObject.Properties['body_b64'] -and $e.body_b64) { $replayBody = [Convert]::FromBase64String([string]$e.body_b64) }
    $null = Invoke-GhostApi -Method $e.method -Uri $e.uri -Headers $h -Body $replayBody
    $sent++
    Write-Output ("  sent   [{0}] {1} {2}" -f $e.id, $e.method, $e.uri)
  } catch {
    $failed += $e.id
    Write-Output ("  FAILED [{0}] {1} {2} - {3}" -f $e.id, $e.method, $e.uri, $_.Exception.Message)
  }
}
if ($failed.Count) {
  Write-Output ("review-staged: FAILED - {0} of {1} call(s) sent, {2} failed ({3}). The queue is LEFT IN PLACE so nothing is lost; re-running -Apply would resend the ones that already succeeded, so edit the queue before retrying." -f $sent, $entries.Count, $failed.Count, ($failed -join ', '))
  Exit-Guard -Name 'review-staged' -Summary ("sent={0} failed={1}" -f $sent, $failed.Count) -Code 2
}
Remove-Item -LiteralPath $Queue -Force
Write-Output ("review-staged: APPLIED - all {0} call(s) sent, queue cleared." -f $sent)
Exit-Guard -Name 'review-staged' -Summary ("sent=" + $sent) -Code 0
