<#
  google-token.ps1  -  Returns a fresh Google access token for the Work account.
  Dot-source it, then call Get-GoogleAccessToken. Refreshes via the stored refresh_token
  (access tokens expire ~1hr; refresh tokens persist). Writes the new access_token back.
#>
function Get-GoogleAccessToken {
  $dir = Split-Path -Parent $PSCommandPath
  $clientFile = Join-Path $dir "google-oauth-client.json"
  $tokenFile  = Join-Path $dir "google-oauth-token.json"
  $cfg = (Get-Content $clientFile -Raw | ConvertFrom-Json).installed
  $tok = Get-Content $tokenFile -Raw | ConvertFrom-Json
  if (-not $tok.refresh_token) { throw "No refresh_token stored; re-run google-oauth-authorize.ps1" }
  $body = @{
    client_id     = $cfg.client_id
    client_secret = $cfg.client_secret
    refresh_token = $tok.refresh_token
    grant_type    = "refresh_token"
  }
  $resp = Invoke-RestMethod -Uri "https://oauth2.googleapis.com/token" -Method Post -Body $body -TimeoutSec 30
  # persist the refreshed access token (keep the refresh_token we already have)
  $tok.access_token = $resp.access_token
  $tok | ConvertTo-Json | Out-File -FilePath $tokenFile -Encoding utf8
  return $resp.access_token
}
