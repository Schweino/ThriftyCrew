<#
  google-oauth-authorize.ps1
  One-time interactive OAuth flow for the Work Google account.
  Opens the consent screen in your browser, catches the redirect locally,
  exchanges the code for tokens, and saves them to google-oauth-token.json.
  Re-run any time to re-authorize (e.g. if you revoke access).
#>
$ErrorActionPreference = "Stop"
$clientFile = "$PSScriptRoot\google-oauth-client.json"
$tokenFile  = "$PSScriptRoot\google-oauth-token.json"

$cfg = (Get-Content $clientFile -Raw | ConvertFrom-Json).installed
$clientId = $cfg.client_id
$clientSecret = $cfg.client_secret
$redirectUri = "http://localhost:8722/"

$scopes = @(
  "https://www.googleapis.com/auth/drive",
  "https://www.googleapis.com/auth/spreadsheets",
  "https://www.googleapis.com/auth/gmail.send"
) -join " "

$state = [guid]::NewGuid().ToString("N")
$authUrl = "https://accounts.google.com/o/oauth2/v2/auth" +
  "?client_id=$clientId" +
  "&redirect_uri=$([uri]::EscapeDataString($redirectUri))" +
  "&response_type=code" +
  "&scope=$([uri]::EscapeDataString($scopes))" +
  "&access_type=offline" +
  "&prompt=consent" +
  "&state=$state"

Write-Host "Opening browser for Google sign-in..." -ForegroundColor Cyan
Write-Host "Sign in with your WORK Google account and click Allow." -ForegroundColor Yellow

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($redirectUri)
$listener.Start()

Start-Process $authUrl

Write-Host "Waiting for authorization..." -ForegroundColor Cyan
$context = $listener.GetContext()
$req = $context.Request
$query = [System.Web.HttpUtility]::ParseQueryString($req.Url.Query)
$code = $query["code"]
$returnedState = $query["state"]

$resp = $context.Response
$html = "<html><body><h2>You're authorized. You can close this tab and go back to Claude.</h2></body></html>"
$buffer = [Text.Encoding]::UTF8.GetBytes($html)
$resp.ContentLength64 = $buffer.Length
$resp.OutputStream.Write($buffer, 0, $buffer.Length)
$resp.OutputStream.Close()
$listener.Stop()

if (-not $code) { throw "No authorization code received. Query was: $($req.Url.Query)" }
if ($returnedState -ne $state) { throw "State mismatch - possible tampering, aborting." }

Write-Host "Got authorization code, exchanging for tokens..." -ForegroundColor Cyan

$tokenBody = @{
  code          = $code
  client_id     = $clientId
  client_secret = $clientSecret
  redirect_uri  = $redirectUri
  grant_type    = "authorization_code"
}
$tokenResp = Invoke-RestMethod -Uri "https://oauth2.googleapis.com/token" -Method Post -Body $tokenBody

if (-not $tokenResp.refresh_token) {
  Write-Host "WARNING: No refresh_token returned. This happens if you've authorized before without revoking." -ForegroundColor Yellow
  Write-Host "Go to https://myaccount.google.com/permissions , remove access for this app, and re-run this script." -ForegroundColor Yellow
}

$tokenResp | ConvertTo-Json | Out-File -FilePath $tokenFile -Encoding utf8
Write-Host "SUCCESS. Tokens saved to $tokenFile" -ForegroundColor Green
