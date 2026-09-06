<#
  revert-ghost-write.ps1 - replay the inverse of a journalled Ghost write.

  E1 v2 (UNDO LOG). The bet: an agent that can undo its own mistake recovers in seconds; one that
  cannot needs a human who may be asleep. So the call executes exactly as it does today - the caller
  gets the real response and nothing about control flow changes - and the inverse is captured first.

  THE ARGUMENT FOR THIS DESIGN OVER STAGING: it costs the callers nothing. A staged write is not a
  write, so any chain that reads a field off the response has to be taught about staging before it can
  be switched on. This branch can be armed on the publish chain today. And an AGENT MAY CALL THIS
  ITSELF - recovery is a move it can choose, not something only a human can do afterwards.

  THE COST, STATED RATHER THAN HIDDEN: it RECOVERS, it does not PREVENT. The wrong page was live for
  the interval between the write and the revert, and on a live paid site a reader may have seen it.
  There is no honest way for an undo log to fix that, and the e1-staging branch does fix it. Weigh that
  against the adoption cost above; that trade IS the decision.

  Usage:
    $env:TC_WRITE_JOURNAL = 'ops\ghost-journal.jsonl'   # arm it, then run the publish chain
    powershell -File ops\revert-ghost-write.ps1                    # list what can be reverted
    powershell -File ops\revert-ghost-write.ps1 -Id <id>           # revert one entry
    powershell -File ops\revert-ghost-write.ps1 -Id <id> -WhatIf   # rehearse, send nothing

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 findings, 3 could-not-evaluate.
  Read the verdict LINE, not the number (backlog E2).
#>
param(
  [string]$Journal = '',
  [string]$Id = '',
  [switch]$WhatIf,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ghost-lib.ps1')

function Get-TcInverse {
  <# THE HEART OF THIS DESIGN, and the place it can be dangerously wrong.

     Three before_states that a careless reverter would treat alike, and the third is the one that
     matters: an entry whose prior state could not be read has NO KNOWN INVERSE, and running a PUT with
     a null body would blank the resource. "Could not look" must not settle the question
     ([[a-could-not-look-must-not-settle-the-question]]), so it returns a refusal, not a guess.

       captured -> PUT the before-image back
       created  -> the resource did not exist, so the inverse is DELETE
       unknown  -> REFUSE. There is no inverse and there is no safe default. #>
  param($Entry)
  $st = [string]$Entry.before_state
  if ($st -eq 'captured') {
    if ($null -eq $Entry.before) {
      return ([pscustomobject]@{ Action = 'REFUSE'; Method = ''; Body = $null; Why = 'before_state says captured but the before-image is null - the journal disagrees with itself, so nothing here is trustworthy enough to send' })
    }
    return ([pscustomobject]@{ Action = 'PUT'; Method = 'PUT'; Body = (ConvertTo-Json $Entry.before -Depth 12 -Compress); Why = 'restore the state the resource was in immediately before the write' })
  }
  if ($st -eq 'created') {
    return ([pscustomobject]@{ Action = 'DELETE'; Method = 'DELETE'; Body = $null; Why = 'the GET before the write returned 404, so the resource did not exist and the inverse of creating it is deleting it' })
  }
  return ([pscustomobject]@{ Action = 'REFUSE'; Method = ''; Body = $null; Why = ("before_state is '" + $st + "', so the prior state was never read. There is no inverse and no safe default - a PUT here would overwrite live content with a guess.") })
}

function Read-TcJournal {
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

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0
  function T($m, $cond, $got) { if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }

  T 'MUST FIRE  PUT is journalled'    (Test-TcMutatingMethod 'PUT')    'not mutating'
  T 'MUST FIRE  DELETE is journalled' (Test-TcMutatingMethod 'DELETE') 'not mutating'
  T 'MUST FIRE  a lower-case verb is journalled' (Test-TcMutatingMethod 'put') 'case-sensitive gate misses a write'
  T 'CLEAN TWIN a GET needs no before-image' (-not (Test-TcMutatingMethod 'GET')) 'a read was journalled'

  $saved = $env:TC_WRITE_JOURNAL
  $env:TC_WRITE_JOURNAL = $null
  T 'MUST FIRE  journalling is OFF unless TC_WRITE_JOURNAL is set' ($null -eq (Get-TcWriteJournal)) 'armed with no env var'
  $env:TC_WRITE_JOURNAL = $saved

  # --- THE THREE BEFORE-STATES. The third is the one that decides whether this design is safe.
  $inv1 = Get-TcInverse -Entry ([pscustomobject]@{ before_state = 'captured'; before = [pscustomobject]@{ posts = @(1) } })
  T 'MUST FIRE  a captured before-image inverts to a PUT' ($inv1.Action -eq 'PUT') $inv1.Action
  T 'the PUT carries the before-image as its body' ($inv1.Body -like '*posts*') $inv1.Body

  $inv2 = Get-TcInverse -Entry ([pscustomobject]@{ before_state = 'created'; before = $null })
  T 'MUST FIRE  a 404 before the write inverts to a DELETE, never a PUT' ($inv2.Action -eq 'DELETE') $inv2.Action

  $inv3 = Get-TcInverse -Entry ([pscustomobject]@{ before_state = 'unknown'; before = $null })
  T 'MUST FIRE  an unreadable prior state REFUSES rather than guessing' ($inv3.Action -eq 'REFUSE') $inv3.Action
  T 'the refusal says why, so a could-not-look does not settle the question' ($inv3.Why -like '*no safe default*') $inv3.Why

  # The journal disagreeing with itself is its own case: claiming captured with a null image must not
  # become a PUT of nothing. This is the failure that would blank a live post.
  $inv4 = Get-TcInverse -Entry ([pscustomobject]@{ before_state = 'captured'; before = $null })
  T 'MUST FIRE  captured-but-null REFUSES rather than PUTting a null body' ($inv4.Action -eq 'REFUSE') $inv4.Action

  # --- the journal round-trips, and a real write is captured before it goes out
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("tcjrnl-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".jsonl")
  try {
    $e = New-TcJournalEntry -Method 'PUT' -Uri 'https://h/ghost/api/admin/posts/abc/' -Body '{"posts":[{"title":"new"}]}' -BeforeState 'captured' -Before ([pscustomobject]@{ posts = @([pscustomobject]@{ title = 'old' }) })
    Write-TcJournalEntry -Journal $tmp -Entry $e
    $j = Read-TcJournal -Lines ([IO.File]::ReadAllLines($tmp))
    T 'the journal round-trips to one entry' ($j.Entries.Count -eq 1) ("Count=" + $j.Entries.Count)
    T 'MUST FIRE  the before-image survives the round trip' ($j.Entries[0].before.posts[0].title -eq 'old') 'the before-image was lost, so the entry is unrevertable'
    $raw = [IO.File]::ReadAllText($tmp)
    # SECURITY: a journal sits on disk far longer than the five minutes an admin JWT lives.
    T 'MUST FIRE  the journal records NO headers, so no credential reaches disk' (-not ($raw -match 'Authorization')) 'a header block was journalled'
  } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }

  $j2 = Read-TcJournal -Lines @('{"method":"PUT"}', 'not json', '')
  T 'MUST FIRE  an unparseable journal line is REPORTED, not skipped' ($j2.Bad.Count -eq 1) ("Bad=" + $j2.Bad.Count)

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: the journal gate, off-by-default, all four before-state inversions including both refusals, round-trip with the before-image, credential redaction, and a half-parsing journal'
  exit 0
}

# ------------------------------------------------------------------------------------- live run
if (-not $Journal) { $Journal = $(if ($env:TC_WRITE_JOURNAL) { $env:TC_WRITE_JOURNAL } else { Join-Path $repo 'ops\ghost-journal.jsonl' }) }
if (-not (Test-Path -LiteralPath $Journal)) {
  Write-Output ("revert-ghost-write: no journal at {0}. Journalling is armed by setting TC_WRITE_JOURNAL before a run; nothing can be reverted that was not journalled." -f $Journal)
  Write-GuardComplete -Name 'revert-ghost-write' -Summary 'entries=0'
  exit 0
}
$parsed = Read-TcJournal -Lines ([IO.File]::ReadAllLines($Journal))
if ($parsed.Bad.Count) {
  Write-Output ("REVERT-GHOST-WRITE COULD NOT EVALUATE: {0} journal line(s) will not parse ({1}). Some write is invisible here, so the journal cannot be trusted to be complete." -f $parsed.Bad.Count, ($parsed.Bad -join ', '))
  Write-GuardComplete -Name 'revert-ghost-write' -Summary ("blind=badlines-" + $parsed.Bad.Count)
  exit 3
}
$entries = @($parsed.Entries)

if (-not $Id) {
  Write-Output ("revert-ghost-write: {0} journalled write(s) in {1}" -f $entries.Count, $Journal)
  $refusals = 0
  foreach ($e in $entries) {
    $inv = Get-TcInverse -Entry $e
    if ($inv.Action -eq 'REFUSE') { $refusals++ }
    Write-Output ("  [{0}] {1,-6} {2}" -f $e.id, $e.method, $e.uri)
    Write-Output ("           inverse: {0}  - {1}" -f $inv.Action, $inv.Why)
  }
  Write-Output ''
  if ($refusals) {
    Write-Output ("revert-ghost-write: {0} of {1} entr(ies) have NO SAFE INVERSE and would be refused. Those writes are not recoverable by this tool; that is the honest limit of an undo log, not a bug in it." -f $refusals, $entries.Count)
    Write-GuardComplete -Name 'revert-ghost-write' -Summary ("entries={0} unrevertable={1}" -f $entries.Count, $refusals)
    exit 2
  }
  Write-Output ("revert-ghost-write: all {0} entr(ies) have a computable inverse. Re-run with -Id <id> to apply one." -f $entries.Count)
  Write-GuardComplete -Name 'revert-ghost-write' -Summary ("entries={0} unrevertable=0" -f $entries.Count)
  exit 0
}

$entry = @($entries | Where-Object { $_.id -eq $Id })
if (-not $entry.Count) {
  Write-Output ("REVERT-GHOST-WRITE COULD NOT EVALUATE: no journal entry with id '{0}'." -f $Id)
  Write-GuardComplete -Name 'revert-ghost-write' -Summary 'blind=no-such-id'
  exit 3
}
$entry = $entry[0]
$inv = Get-TcInverse -Entry $entry
Write-Output ("revert-ghost-write: [{0}] {1} {2}" -f $entry.id, $entry.method, $entry.uri)
Write-Output ("  inverse: {0} - {1}" -f $inv.Action, $inv.Why)
if ($inv.Action -eq 'REFUSE') {
  Write-Output '  REFUSED. Nothing was sent. Restore this one by hand, from the Ghost admin UI or a backup.'
  Write-GuardComplete -Name 'revert-ghost-write' -Summary 'refused=1'
  exit 2
}
if ($WhatIf) {
  Write-Output ("  WOULD send {0} to {1}" -f $inv.Method, $entry.uri)
  Write-GuardComplete -Name 'revert-ghost-write' -Summary 'whatif=1'
  exit 0
}
# The journal stores no credential, so the token is minted here.
$h = @{ Authorization = ('Ghost ' + (Get-GhostJWT -Key (Get-GhostKey -Root $repo))); 'Content-Type' = 'application/json' }
# The revert must not itself be journalled into the same file - that would make the journal a record of
# undos as well as writes, and a second revert of the revert would restore the mistake.
$savedJ = $env:TC_WRITE_JOURNAL
$env:TC_WRITE_JOURNAL = $null
try {
  $null = Invoke-GhostApi -Method $inv.Method -Uri $entry.uri -Headers $h -Body $inv.Body
  Write-Output ("revert-ghost-write: REVERTED - {0} sent to {1}. The resource is back to its pre-write state; it was live and wrong for the interval in between, which this design cannot undo." -f $inv.Method, $entry.uri)
  Write-GuardComplete -Name 'revert-ghost-write' -Summary ("reverted=" + $entry.id)
  exit 0
} catch {
  Write-Output ("revert-ghost-write: FAILED - the inverse could not be sent: {0}. The resource is still in its post-write state." -f $_.Exception.Message)
  Write-GuardComplete -Name 'revert-ghost-write' -Summary 'revert-failed=1'
  exit 2
} finally { $env:TC_WRITE_JOURNAL = $savedJ }
