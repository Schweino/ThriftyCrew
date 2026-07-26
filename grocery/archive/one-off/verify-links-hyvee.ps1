<#
  verify-links-hyvee.ps1 - OPEN every stored Hy-Vee link and prove it shows the product we claim.

  WHY THIS EXISTS. Two blind spots meet on Hy-Vee links:

   1. THE URL IS CONSTRUCTED, NOT OBSERVED. resolve-hyvee-links builds
      /aisles-online/p/<id>/<slug> from a search result rather than reading a canonical URL off the store. That
      is the same move that nearly shipped 4 dead Family Fare links (I invented
      familyfaresupermarkets.com/product/<id>; the real shape is shopfamilyfare.com/shop/<cat>/<slug>/p/<id>).
      A constructed URL is a hypothesis until something opens it.

   2. THE STORED NAME IS OUR OWN. resolve-hyvee-links deliberately saves the BOARD's product name as the link's
      name ("so matching stays stable"). Defensible - but it means every later name check compares our name to
      our name and can only ever pass. The audit cannot see drift it is structurally blind to. Same shape as
      the two-copies-of-the-same-math blind spot that let 185 cells go unchecked while the guard reported clean.

  AND YOU CANNOT USE THE STATUS CODE. A completely bogus id (999999999) returns HTTP 200 with a rendered "not
  found" page - the same trap as Walmart's PerimeterX 200 challenge page. Watch what was PARSED, not what was
  fetched. The honest marker is __NEXT_DATA__ props.pageProps.notFound === true; a real product page instead
  carries canonicalUrl + kebabProductName and the store's own name in <title>.

  So this fetches each link and reports:
    DEAD          notFound=true - the link opens nothing. It must not ship.
    NAME-DRIFT    the store's own <title> does not match the board's item name.
    OK            opens a real product whose name agrees with the board.
    UNKNOWN       could not fetch/parse (never counted as OK - unknown is not a pass).

  Read-only. Writes out\hyvee-link-verify.json. Exit 2 if any DEAD link is found.
#>
param([string]$OutDir = "", [int]$Limit = 0, [int]$PaceMs = 700)
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }

$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148 Safari/537.36'
$pu = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items

# PowerShell 5.1's Invoke-WebRequest THROWS on 308 Permanent Redirect instead of following it (the underlying
# HttpWebRequest predates 308). Hy-Vee 308s whenever our constructed slug is not its canonical slug - which is
# most of them, since resolve-hyvee-links builds the slug from the product description rather than reading it
# off the store. Those links are FINE: a browser follows the redirect and the shopper lands on the product.
# Letting the throw stand would have reported the entire catalogue as UNKNOWN and told us nothing.
function Get-Page([string]$u) {
  try { return (Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 25 -Headers @{'User-Agent' = $UA }) }
  catch {
    $resp = $_.Exception.Response
    if ($resp -and ([int]$resp.StatusCode -in @(301, 302, 307, 308))) {
      $loc = [string]$resp.Headers['Location']
      if ($loc) {
        if ($loc -notmatch '^https?://') { $loc = 'https://www.hy-vee.com' + $loc }
        return (Invoke-WebRequest -Uri $loc -UseBasicParsing -TimeoutSec 25 -Headers @{'User-Agent' = $UA })
      }
    }
    throw
  }
}

function Norm([string]$s) { return (([string]$s).ToLower() -replace '[^a-z0-9 ]', ' ' -replace '\s+', ' ').Trim() }

$targets = @()
foreach ($idp in $pu.PSObject.Properties) {
  $l = $idp.Value.'Hy-Vee'
  if ($l -and $l.url) { $targets += [pscustomobject]@{ id = $idp.Name; url = [string]$l.url; name = [string]$l.name } }
}
if ($Limit -gt 0) { $targets = @($targets | Select-Object -First $Limit) }
Write-Output ("Hy-Vee links to open: " + $targets.Count)

$rows = New-Object System.Collections.Generic.List[object]
$dead = 0; $drift = 0; $ok = 0; $unk = 0
foreach ($t in $targets) {
  $verdict = 'UNKNOWN'; $storeName = ''; $detail = ''
  try {
    $r = Get-Page $t.url
    $c = $r.Content
    $m = [regex]::Match($c, '(?s)<script id="__NEXT_DATA__"[^>]*>(.*?)</script>')
    if (-not $m.Success) { $detail = 'no __NEXT_DATA__ in response' }
    else {
      $j = ConvertFrom-Json $m.Groups[1].Value
      if ($j.props.pageProps.notFound -eq $true) { $verdict = 'DEAD'; $detail = 'pageProps.notFound=true (HTTP 200 anyway)' }
      else {
        # the store's OWN name for this product - independent of anything we stored
        $storeName = ([regex]::Match($c, '(?s)<title[^>]*>(.*?)</title>').Groups[1].Value -replace '\s*\|\s*Hy-Vee.*$', '').Trim()
        if (-not $storeName) { $detail = 'page parsed but carries no title' }
        else {
          $a = @((Norm $t.name) -split ' ' | Where-Object { $_.Length -ge 3 -and $_ -notmatch '^\d' })
          $b = Norm $storeName
          $hit = 0; foreach ($w in $a) { if ($b -match [regex]::Escape($w)) { $hit++ } }
          $sc = if ($a.Count) { $hit / $a.Count } else { 0 }
          if ($sc -ge 0.6) { $verdict = 'OK'; $detail = ('name agrees ' + [math]::Round($sc * 100) + '%') }
          else { $verdict = 'NAME-DRIFT'; $detail = ('board says "' + $t.name + '" but the page is "' + $storeName + '" (' + [math]::Round($sc * 100) + '%)') }
        }
      }
    }
  }
  catch { $detail = ('fetch failed: ' + $_.Exception.Message) }
  switch ($verdict) { 'DEAD' { $dead++ } 'NAME-DRIFT' { $drift++ } 'OK' { $ok++ } default { $unk++ } }
  if ($verdict -ne 'OK') { Write-Output ('  ' + $verdict.PadRight(12) + $t.id.PadRight(24) + $detail) }
  $rows.Add([pscustomobject]@{ id = $t.id; verdict = $verdict; board_name = $t.name; store_name = $storeName; detail = $detail; url = $t.url })
  Start-Sleep -Milliseconds $PaceMs
}

(@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); opened = $targets.Count; ok = $ok; dead = $dead; name_drift = $drift; unknown = $unk; rows = $rows } |
  ConvertTo-Json -Depth 5) | Set-Content (Join-Path $OutDir 'hyvee-link-verify.json') -Encoding UTF8

Write-Output ''
Write-Output ("opened " + $targets.Count + ":  OK " + $ok + " | DEAD " + $dead + " | NAME-DRIFT " + $drift + " | UNKNOWN " + $unk)
if ($dead -gt 0) { Write-Output ''; Write-Output ("verify-links-hyvee: FAIL - " + $dead + " link(s) open nothing. They must not ship."); exit 2 }
exit 0
