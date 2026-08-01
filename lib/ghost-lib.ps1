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