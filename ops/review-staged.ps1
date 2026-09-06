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

function Get-TcQueueConcerns {
  <# The whole argument for staging over an undo log lives in this function: it looks at the SET.
     An undo log sees one call at a time and cannot ask any of these questions.

     CALLERS MUST ASSIGN THE RESULT BEFORE WRAPPING IT. `,@($c)` is required so a SINGLE concern comes
     back as an array rather than unrolling to a bare string - but the same comma makes `@(callsite)`
     read an EMPTY result as ONE element (the empty array), so an inline
     `@(Get-TcQueueConcerns ...).Count` returns 1 when there are no concerns at all. Measured here
     2026-09-06: `$r = Get-TcQueueConcerns ...; @($r).Count` gives 0 and `@(Get-TcQueueConcerns ...).Count`
     gives 1, same input. That is [[ps-json-array-collapse]] in a third guise, and in the live path it
     would have printed a CONCERNS header over an empty list and exited 2 on a clean queue. #>
  param([object[]]$Entries)
  $c = @()
  $mutating = @($Entries | Where-Object { Test-TcMutatingMethod $_.method })
  $dupes = @($mutating | Group-Object -Property uri | Where-Object { $_.Count -gt 1 })
  foreach ($d in $dupes) {
    $c += ("{0} calls target the same uri ({1}) - the later one wins and the earlier is wasted, or they disagree" -f $d.Count, $d.Name)
  }
  $deletes = @($mutating | Where-Object { $_.method -eq 'DELETE' })
  if ($deletes.Count) { $c += ("{0} DELETE call(s) queued - a delete has no restore in this design, only a re-create" -f $deletes.Count) }
  $callers = @($Entries | ForEach-Object { $_.caller } | Where-Object { $_ } | Sort-Object -Unique)
  if ($callers.Count -gt 1) { $c += ("{0} different scripts contributed to this queue - confirm they were meant to run together" -f $callers.Count) }
  return ,@($c)
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0
  function T($m, $cond, $got) { if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }

  # --- the gate itself: which verbs close it
  T 'MUST FIRE  PUT is mutating and is staged'    (Test-TcMutatingMethod 'PUT')    'not mutating'
  T 'MUST FIRE  POST is mutating and is staged'   (Test-TcMutatingMethod 'POST')   'not mutating'
  T 'MUST FIRE  DELETE is mutating and is staged' (Test-TcMutatingMethod 'DELETE') 'not mutating'
  T 'MUST FIRE  a lower-case verb still stages'   (Test-TcMutatingMethod 'put')    'case-sensitive gate leaks a write'
  T 'CLEAN TWIN GET is a read and executes immediately'  (-not (Test-TcMutatingMethod 'GET'))  'a read was staged'
  T 'CLEAN TWIN HEAD is a read and executes immediately' (-not (Test-TcMutatingMethod 'HEAD')) 'a read was staged'

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
    T 'the entry records the method and uri' (($q.Entries[0].method -eq 'PUT') -and ($q.Entries[0].uri -like 'https://invalid.invalid/*')) 'method/uri lost'
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
  T 'CLEAN TWIN one PUT from one caller raises nothing' (@($cleanCon).Count -eq 0) (@($cleanCon) -join ' | ')

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: the staging gate, off-by-default, credential redaction, queue round-trip, a half-parsing queue, and the three set-level concerns'
  exit 0
}

# ------------------------------------------------------------------------------------- live run
if (-not $Queue) { $Queue = $(if ($env:TC_STAGE_WRITES) { $env:TC_STAGE_WRITES } else { Join-Path $repo 'ops\staged-writes.jsonl' }) }
if (-not (Test-Path -LiteralPath $Queue)) {
  Write-Output ("review-staged: nothing queued ({0} does not exist). Staging is armed by setting TC_STAGE_WRITES before a run; an empty queue after an ARMED run means nothing tried to write." -f $Queue)
  Write-GuardComplete -Name 'review-staged' -Summary 'queued=0'
  exit 0
}
$parsed = Read-TcQueue -Lines ([IO.File]::ReadAllLines($Queue))
if ($parsed.Bad.Count) {
  Write-Output ("REVIEW-STAGED COULD NOT EVALUATE: {0} queue line(s) will not parse ({1}). Some intended write is invisible to this review, so applying now would send an unknown subset." -f $parsed.Bad.Count, ($parsed.Bad -join ', '))
  Write-GuardComplete -Name 'review-staged' -Summary ("blind=badlines-" + $parsed.Bad.Count)
  exit 3
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
  Write-GuardComplete -Name 'review-staged' -Summary ("discarded=" + $entries.Count)
  exit 0
}
if (-not $Apply) {
  Write-Output ''
  Write-Output ("review-staged: {0} call(s) are WAITING and nothing has been sent. Re-run with -Apply to send them, or -Discard to throw them away." -f $entries.Count)
  Write-GuardComplete -Name 'review-staged' -Summary ("queued={0} concerns={1}" -f $entries.Count, $concerns.Count)
  exit $(if ($concerns.Count) { 2 } else { 0 })
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
    $null = Invoke-GhostApi -Method $e.method -Uri $e.uri -Headers $h -Body $e.body
    $sent++
    Write-Output ("  sent   [{0}] {1} {2}" -f $e.id, $e.method, $e.uri)
  } catch {
    $failed += $e.id
    Write-Output ("  FAILED [{0}] {1} {2} - {3}" -f $e.id, $e.method, $e.uri, $_.Exception.Message)
  }
}
if ($failed.Count) {
  Write-Output ("review-staged: FAILED - {0} of {1} call(s) sent, {2} failed ({3}). The queue is LEFT IN PLACE so nothing is lost; re-running -Apply would resend the ones that already succeeded, so edit the queue before retrying." -f $sent, $entries.Count, $failed.Count, ($failed -join ', '))
  Write-GuardComplete -Name 'review-staged' -Summary ("sent={0} failed={1}" -f $sent, $failed.Count)
  exit 2
}
Remove-Item -LiteralPath $Queue -Force
Write-Output ("review-staged: APPLIED - all {0} call(s) sent, queue cleared." -f $sent)
Write-GuardComplete -Name 'review-staged' -Summary ("sent=" + $sent)
exit 0
