# ghost-lib.ps1 - THE single Ghost Admin API helper for the whole income estate. Dot-source it:
#   . (Join-Path <repo-root> 'lib\ghost-lib.ps1')
# Exists because the JWT-minting function was copy-pasted 50+ times across grocery + meal-prep scripts
# (2026-07-26 estate audit) - every Ghost API fix had to be found and fixed N times. New code uses this;
# converted scripts keep their local function NAME as a one-line delegate so call sites never change.
#
# Get-GhostJWT -Key 'id:secrethex'   -> a 5-minute admin JWT (aud /admin/)
# Get-GhostKey [-Root <repo-root>]   -> reads the estate's key: $env:GHOST_ADMIN_KEY, else
#                                       meal-prep\.ghostkey under the given root (default: this lib's repo)
$script:GhostApiUrl = 'https://map-to-success.ghost.io'

function Get-GhostKey([string]$Root = '') {
  if ($env:GHOST_ADMIN_KEY) { return $env:GHOST_ADMIN_KEY }
  if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
  $kf = Join-Path $Root 'meal-prep\.ghostkey'
  if (Test-Path $kf) { return (Get-Content $kf -Raw).Trim() }
  throw 'Ghost admin key missing: set $env:GHOST_ADMIN_KEY or create meal-prep\.ghostkey'
}

function Get-GhostJWT([Parameter(Mandatory)][string]$Key) {
  $id, $secret = $Key -split ':'
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $b64 = { param($b) [Convert]::ToBase64String($b).TrimEnd('=').Replace('+','-').Replace('/','_') }
  $h  = '{"alg":"HS256","typ":"JWT","kid":"' + $id + '"}'
  $pl = '{"iat":' + $now + ',"exp":' + ($now + 300) + ',"aud":"/admin/"}'
  $si = (& $b64 ([Text.Encoding]::UTF8.GetBytes($h))) + '.' + (& $b64 ([Text.Encoding]::UTF8.GetBytes($pl)))
  $sb = New-Object byte[] ($secret.Length / 2)
  for ($i = 0; $i -lt $sb.Length; $i++) { $sb[$i] = [Convert]::ToByte($secret.Substring($i * 2, 2), 16) }
  $hm = New-Object System.Security.Cryptography.HMACSHA256 (,$sb)
  return $si + '.' + (& $b64 ($hm.ComputeHash([Text.Encoding]::UTF8.GetBytes($si))))
}

# Wrap a body html string as the standard lexical single-html-card JSON (NEVER use ?source=html - it
# strips scripts; this is the documented publish method for every scripted page/post on the site).
function Get-GhostLexical([Parameter(Mandatory)][string]$Html) {
  $lexObj = @{ root = [ordered]@{ children = @([ordered]@{ type='html'; version=1; html=$Html }); direction=$null; format=''; indent=0; type='root'; version=1 } }
  return (ConvertTo-Json $lexObj -Depth 12 -Compress)
}

# Invoke-GhostApi - THE resilient HTTP call for every Ghost/HTTP request in the estate.
# Exists because ~13 automation-path Invoke-RestMethod/WebRequest calls had NO -TimeoutSec, so a stalled
# Ghost socket blocked the whole daily chain forever (the 2026-07-26 25-minute-hang incidents), and NOTHING
# anywhere retried a 429/503 (Ghost Pro 503s intermittently; the grocery board needed a bolted-on 20-min
# retry loop). This wraps both:
#   -Rest (default): parsed-JSON return (Invoke-RestMethod)  |  -Web: raw response (Invoke-WebRequest, .Content)
# It ALWAYS applies a timeout and retries 429/5xx/timeout with exponential backoff + jitter. It NEVER retries
# a 4xx other than 429 (a 404/401/400 is not transient) - those rethrow immediately so callers can still
# distinguish "genuinely new post" (404) from "transient error" (retried, then thrown). The delays are fixed
# (no Get-Random - that is unavailable in workflow scripts and needless here) using the attempt index as jitter.
# ---- E1: the safety layer for irreversible writes. TWO MECHANISMS, EACH WITH ITS OWN SWITCH. --------
#
# They solve DIFFERENT problems and are not rival designs (design\E1-comparison.md scored them as
# rivals, which was the wrong frame):
#
#   STAGING   $env:TC_STAGE_WRITES   a mutating call is QUEUED, not sent, and something approves it
#                                    first. Answers "do not let a wrong page go live at all."
#   JOURNAL   $env:TC_WRITE_JOURNAL  a mutating call goes out as it always did, with its INVERSE
#                                    captured first. Answers "get a wrong page back quickly."
#
# A lock and a spare key. BOTH ARE OFF BY DEFAULT, independently, so all 29 callers keep today's
# behaviour until something arms one.
#
# THE ORDER OF THE TWO GATES BELOW IS LOAD-BEARING AND IS NOT A STYLE CHOICE. Staging is checked FIRST.
# A staged call never goes out, so there is nothing to reverse and it must leave NO journal entry. Get
# this backwards and the journal fills with before-images of writes that never happened - a drawer full
# of records of things that did not occur, which is worse than no drawer, because the reverter would
# then offer to "restore" a resource that was never touched. ops\review-staged.ps1's self-test asserts
# exactly this with both switches armed at once.
#
# WHY THIS SEAM. A PUT to the Ghost admin API is the only genuinely irreversible thing this estate
# does. Every named LOCAL target is tracked, so git is already the undo log there
# (design\E1-safety-layer-brief.md section 1). NEITHER MECHANISM COVERS R2, which does not go through
# this function - that is a separate seam and separate work, and E1 is not done without it.
#
# NO param() BLOCK IS ADDED TO THIS FILE, DELIBERATELY. It is dot-sourced by 29 scripts, and
# lib\guard-contract.ps1 documents what happens when a dot-sourced file declares one: PS 5.1 runs it in
# the CALLER's scope, and that silently disarmed the -SelfTest of every guard that dot-sourced it. The
# self-tests live in the two ops scripts and reach these functions by dot-sourcing.

function Test-TcMutatingMethod {
  <# GET is a read: it is never staged and never journalled. Reads outnumbering writes is the design. #>
  param([string]$Method)
  return (@('PUT', 'POST', 'DELETE', 'PATCH') -contains ([string]$Method).ToUpper())
}

function Get-TcStageQueue {
  <# ENV VARS rather than sentinel files for both switches: the ~07:00 bot commits the whole tree, and
     a committed sentinel would arm the layer for everybody, on every machine, silently. #>
  if ($env:TC_STAGE_WRITES) { return $env:TC_STAGE_WRITES }
  return $null
}

function Get-TcWriteJournal {
  if ($env:TC_WRITE_JOURNAL) { return $env:TC_WRITE_JOURNAL }
  return $null
}

function Add-TcStagedCall {
  <# Serialise the intended request and return WITHOUT sending it.

     THE RETURN VALUE IS THE HONEST COST OF STAGING AND IS NOT DISGUISED. A staged write did not
     happen, so there is no server response. A caller that reads a field off it - a new post id, an
     updated_at for the next PUT - gets an object that does not carry it, and SHOULD fail rather than
     proceed on invented data. Nothing here fabricates an id. Measured on the live chain: all three
     mutating calls (publish.ps1:273 PUT, :276 POST, wave-publish.ps1:1116 PUT) discard their response
     with | Out-Null, so this costs the publish chain nothing today. The one real interaction is
     publish.ps1:285, which GETs the public page AFTER the PUT to confirm it shipped and will report a
     failure when nothing shipped - which is arguably correct, since nothing did. #>
  param([string]$Queue, [string]$Method, [string]$Uri, [hashtable]$Headers, $Body)
  $dir = Split-Path $Queue -Parent
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $entry = [ordered]@{
    id       = ([guid]::NewGuid().ToString('N').Substring(0, 12))
    staged   = (Get-Date).ToString('o')
    method   = ([string]$Method).ToUpper()
    uri      = $Uri
    # HEADERS BY NAME ONLY. Authorization carries a live admin JWT; writing it to a queue file would
    # put a working credential on disk with no owner. -Apply re-mints one from the estate's key.
    header_names = @($Headers.Keys | Sort-Object)
    body     = $(if ($null -eq $Body) { $null } elseif ($Body -is [byte[]]) { "(byte[] length $($Body.Length))" } else { [string]$Body })
    caller   = $(try { (Get-PSCallStack | Where-Object { $_.ScriptName -and $_.ScriptName -notlike '*ghost-lib.ps1' } | Select-Object -Last 1).ScriptName } catch { '' })
  }
  # JSON Lines: one line per call, so a crashed run leaves every call BEFORE the crash intact. A single
  # JSON array rewritten per append loses the lot if the process dies mid-write.
  [IO.File]::AppendAllText($Queue, (ConvertTo-Json $entry -Depth 6 -Compress) + "`n", (New-Object System.Text.UTF8Encoding($false)))
  return ([pscustomobject]@{
    __tc_staged = $true
    __tc_id     = $entry.id
    __tc_note   = 'STAGED, NOT SENT. This request is queued in ' + $Queue + '. There is no server response, so any field you were about to read off this object does not exist. Run ops\review-staged.ps1 to apply or discard.'
  })
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

function New-TcJournalEntry {
  <# `before` is the whole value of the journal and also its weak point. Three ways it can be absent,
     and they are NOT interchangeable - a reverter that treats them alike will "restore" a resource to
     nothing:
       captured - the state immediately before the write; the inverse is a PUT of it
       created  - the GET 404'd, so the resource did not exist and the inverse is a DELETE
       unknown  - the GET failed some other way, so there IS no inverse and none must be run #>
  param([string]$Method, [string]$Uri, $Body, [string]$BeforeState, $Before)
  return ([ordered]@{
    id      = ([guid]::NewGuid().ToString('N').Substring(0, 12))
    at      = (Get-Date).ToString('o')
    method  = ([string]$Method).ToUpper()
    uri     = $Uri
    # NO HEADERS AT ALL. A journal sits on disk far longer than the five minutes an admin JWT lives.
    request = $(if ($null -eq $Body) { $null } elseif ($Body -is [byte[]]) { "(byte[] length $($Body.Length))" } else { [string]$Body })
    before_state = $BeforeState
    before  = $Before
    caller  = $(try { (Get-PSCallStack | Where-Object { $_.ScriptName -and $_.ScriptName -notlike '*ghost-lib.ps1' } | Select-Object -Last 1).ScriptName } catch { '' })
  })
}

function Write-TcJournalEntry {
  param([string]$Journal, $Entry)
  $dir = Split-Path $Journal -Parent
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  # Written BEFORE the call goes out, so a call that dies mid-flight still leaves a record of what was
  # attempted - the case an after-the-fact log cannot cover.
  [IO.File]::AppendAllText($Journal, (ConvertTo-Json $Entry -Depth 12 -Compress) + "`n", (New-Object System.Text.UTF8Encoding($false)))
}
function Invoke-GhostApi {
  param(
    [string]$Method = 'GET',
    [Parameter(Mandatory)][string]$Uri,
    [hashtable]$Headers = @{},
    $Body = $null,                 # string or byte[]; passed through untouched
    [int]$TimeoutSec = 30,
    [int]$MaxRetries = 3,          # total attempts = 1 + MaxRetries
    [switch]$Web,                  # Invoke-WebRequest (raw response) instead of Invoke-RestMethod (parsed)
    [switch]$BasicParsing          # only meaningful with -Web
  )
  # ---- E1 GATE 1 of 2: STAGING, AND IT MUST COME FIRST. --------------------------------------------
  # A staged call never goes out, so there is nothing to reverse and it must leave NO journal entry.
  # Checking the journal first would fill it with before-images of writes that never happened.
  $__tcQ = Get-TcStageQueue
  if ($__tcQ -and (Test-TcMutatingMethod $Method)) {
    return (Add-TcStagedCall -Queue $__tcQ -Method $Method -Uri $Uri -Headers $Headers -Body $Body)
  }
  # ---- E1 GATE 2 of 2: JOURNAL. We are actually about to send, so capture the inverse first. --------
  $__tcJ = Get-TcWriteJournal
  if ($__tcJ -and (Test-TcMutatingMethod $Method)) {
    $__before = $null; $__state = 'unknown'
    try {
      # A GET is not mutating, so this re-entry cannot recurse into either gate.
      $__before = Invoke-GhostApi -Method 'GET' -Uri $Uri -Headers $Headers -TimeoutSec $TimeoutSec -MaxRetries 1
      $__state = 'captured'
    } catch {
      $__code = 0
      $__r = $_.Exception.Response
      if ($__r -and ($__r.PSObject.Properties['StatusCode'])) { try { $__code = [int]$__r.StatusCode } catch { $__code = 0 } }
      # A 404 is not a failure to read prior state, it IS the prior state: the resource did not exist,
      # so the inverse is a DELETE and never a PUT. Conflating them restores a resource to nothing.
      if ($__code -eq 404) { $__state = 'created' } else { $__state = 'unknown' }
    }
    Write-TcJournalEntry -Journal $__tcJ -Entry (New-TcJournalEntry -Method $Method -Uri $Uri -Body $Body -BeforeState $__state -Before $__before)
  }
  $attempt = 0
  while ($true) {
    try {
      $callArgs = @{ Method = $Method; Uri = $Uri; Headers = $Headers; TimeoutSec = $TimeoutSec }
      if ($null -ne $Body) { $callArgs['Body'] = $Body }
      if ($Web) { if ($BasicParsing) { $callArgs['UseBasicParsing'] = $true }; return Invoke-WebRequest @callArgs }
      return Invoke-RestMethod @callArgs
    } catch {
      $code = 0
      $resp = $_.Exception.Response
      if ($resp -and ($resp.PSObject.Properties['StatusCode'])) { try { $code = [int]$resp.StatusCode } catch { $code = 0 } }
      $isTimeout = ($_.Exception -is [System.Net.WebException]) -and ($_.Exception.Status -eq [System.Net.WebExceptionStatus]::Timeout)
      $transient = $isTimeout -or ($code -eq 429) -or ($code -ge 500 -and $code -le 599) -or ($code -eq 0)
      # $code -eq 0 covers DNS/connection-reset/socket errors with no HTTP status (also transient).
      # A definite non-429 4xx (404/401/400/403) is NOT transient - rethrow now.
      if ((-not $transient) -or ($attempt -ge $MaxRetries)) { throw }
      $attempt++
      $delay = [math]::Min(30, [math]::Pow(2, $attempt))   # 2s, 4s, 8s...
      Start-Sleep -Seconds $delay
    }
  }
}