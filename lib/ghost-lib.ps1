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
# ---- E1 v2: UNDO LOG. The call goes out as it always did, and its inverse is captured first. --------
# OFF BY DEFAULT. Nothing changes until $env:TC_WRITE_JOURNAL names a journal file, so all 29 callers
# keep their current behaviour until something deliberately arms this.
#
# WHY HERE AND NOWHERE ELSE. A PUT to the Ghost admin API is the only genuinely irreversible thing this
# estate does; every named LOCAL target is tracked, so git is already the undo log there
# (design\E1-safety-layer-brief.md section 1).
#
# THE BET, AND IT IS THE OPPOSITE OF THE e1-staging BRANCH: an agent that can undo its own mistake
# recovers in seconds, and one that cannot needs a human who may be asleep. Nothing about control flow
# changes - the call really executes and the caller gets the real response - so this can be switched on
# for a chain that round-trips a response, which staging cannot.
#
# WHAT IT BUYS AND WHAT IT DOES NOT: it RECOVERS, it does not PREVENT. The wrong page was live for the
# interval, and on a live paid site a reader may have seen it. There is no honest way to make an undo
# log fix that, and this file does not pretend otherwise.
#
# NO param() BLOCK IS ADDED TO THIS FILE, DELIBERATELY - lib\guard-contract.ps1 documents what happens
# when a dot-sourced file declares one (PS 5.1 runs it in the CALLER's scope, silently disarming their
# switches). The self-test lives in ops\revert-ghost-write.ps1.

function Test-TcMutatingMethod {
  <# GET is a read: it needs no before-image and gets no journal entry. #>
  param([string]$Method)
  return (@('PUT', 'POST', 'DELETE', 'PATCH') -contains ([string]$Method).ToUpper())
}

function Get-TcWriteJournal {
  <# ENV VAR, not a sentinel file: the ~07:00 bot commits the whole tree, and a committed sentinel
     would arm journalling for everybody. #>
  if ($env:TC_WRITE_JOURNAL) { return $env:TC_WRITE_JOURNAL }
  return $null
}

function New-TcJournalEntry {
  <# Build one journal record. Pure and separate from the I/O so the self-test can drive it.

     `before` IS THE WHOLE VALUE OF THIS DESIGN AND IT IS ALSO ITS WEAK POINT. It is the state the
     resource was in immediately before the call, fetched with a GET. Three ways it can be absent, and
     they are NOT interchangeable - a reverter that treats them alike will cheerfully "restore" a
     resource to nothing:
       created  - the GET 404'd, so the resource did not exist and the inverse is a DELETE, not a PUT
       unknown  - the GET failed for some other reason, so the inverse is UNKNOWN and must not be run
       n/a      - a method with no meaningful inverse
     Compare with the e1-staging branch, which never needs a before-image because nothing has happened
     yet - it pays a review pass instead of a GET, and it cannot be wrong about prior state. #>
  param([string]$Method, [string]$Uri, $Body, [string]$BeforeState, $Before)
  return ([ordered]@{
    id      = ([guid]::NewGuid().ToString('N').Substring(0, 12))
    at      = (Get-Date).ToString('o')
    method  = ([string]$Method).ToUpper()
    uri     = $Uri
    # NO HEADERS. The Authorization header carries a live admin JWT and a journal is a file that sits
    # on disk far longer than the five minutes that token lives.
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
  # JSON Lines, and the entry is written BEFORE the call goes out. If the process dies mid-call the
  # journal still names what was attempted, which is the case an after-the-fact log cannot cover.
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
  # E1 v2 JOURNAL. Capture the inverse BEFORE the call goes out, then execute exactly as before.
  $__tcJ = Get-TcWriteJournal
  if ($__tcJ -and (Test-TcMutatingMethod $Method)) {
    $__before = $null; $__state = 'unknown'
    try {
      # A GET is not mutating, so this re-entry cannot recurse into this branch.
      $__before = Invoke-GhostApi -Method 'GET' -Uri $Uri -Headers $Headers -TimeoutSec $TimeoutSec -MaxRetries 1
      $__state = 'captured'
    } catch {
      $__code = 0
      $__r = $_.Exception.Response
      if ($__r -and ($__r.PSObject.Properties['StatusCode'])) { try { $__code = [int]$__r.StatusCode } catch { $__code = 0 } }
      # A 404 is not a failure to read prior state, it IS the prior state: the resource did not exist,
      # so the inverse of this call is a DELETE and never a PUT. Conflating the two is how an undo log
      # restores a resource to nothing.
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