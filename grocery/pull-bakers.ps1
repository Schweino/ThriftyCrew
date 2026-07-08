<#
  pull-bakers.ps1 - Baker's (Kroger) is browser-assisted + image-based (Kroger is Akamai bot-protected;
  the flyer PAGES are open JPGs on kroger-images-prod.przone.net which is NOT bot-gated).

  FLOW (the browser discovery step is done by the agent, then this script verifies + downloads):
    1) AGENT in Chrome: open https://www.bakersplus.com/weeklyad. Confirm an OMAHA store is set (the header
       shows "Pickup at <store> | <address>"; the target is Saddlecreek / 888 S Saddle Creek Rd, Omaha).
       Read the ad date range shown ("July 1 - 7") and capture the flyer page image URLs via
       read_network_requests urlPattern=przone (the /anonymous/{uuid}.jpg?...&imwidth=2400 ones).
    2) Run THIS script with the captured store label, date range, and image URLs.
       It re-verifies BOTH hard gates and only then downloads the pages:
         OMAHA   - StoreLabel must match the expected Omaha Baker's store.
         CURRENT - today must fall inside AdFrom..AdTo.
    3) AGENT vision-reads the downloaded page JPGs to extract deals + prices.

  Example:
    .\pull-bakers.ps1 -StoreLabel "Pickup at Saddlecreek | 888 S Saddle Creek Rd" `
                      -AdFrom 2026-07-01 -AdTo 2026-07-07 -UrlsFile .\out\bakers\urls.txt
#>
param(
  [Parameter(Mandatory=$true)][string]$StoreLabel,
  [Parameter(Mandatory=$true)][string]$AdFrom,
  [Parameter(Mandatory=$true)][string]$AdTo,
  [string]$UrlsFile,
  [string[]]$ImageUrls,
  [string]$ExpectedStorePattern = '(?i)saddle ?creek|omaha',   # the Omaha Baker's we target
  [string]$OutDir = ""
)
$ErrorActionPreference = 'Stop'
$UA = @{ 'User-Agent' = 'Mozilla/5.0' }
$TODAY = (Get-Date).Date
# $PSScriptRoot is unreliable inside a param() default under -File; resolve here in the body where it is set.
if (-not $OutDir) { $base = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }; $OutDir = Join-Path $base 'out\bakers' }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force $OutDir | Out-Null }

# ---- HARD GATE 1: OMAHA ----
$okOmaha = ($StoreLabel -match $ExpectedStorePattern)
# ---- HARD GATE 2: CURRENT WEEK ----
$okCurrent = $false
try { $f = ([datetime]::Parse($AdFrom)).Date; $t = ([datetime]::Parse($AdTo)).Date; $okCurrent = ($TODAY -ge $f -and $TODAY -le $t) } catch {}

Write-Output ("Baker's verification  ->  store='"+$StoreLabel+"'  ad="+$AdFrom+".."+$AdTo+"  today="+$TODAY.ToString('yyyy-MM-dd'))
Write-Output ("  OMAHA gate:   "+$okOmaha)
Write-Output ("  CURRENT gate: "+$okCurrent)
if (-not ($okOmaha -and $okCurrent)) {
  Write-Output ("BLOCKED: not "+(@(if(-not $okOmaha){'an Omaha store'}; if(-not $okCurrent){'the current week'}) -join ' / ')+". No pages downloaded.")
  exit 1
}

# ---- both gates pass: download the flyer pages ----
$urls = @()
if ($UrlsFile -and (Test-Path $UrlsFile)) { $urls += (Get-Content $UrlsFile | Where-Object { $_ -match 'przone|http' }) }
if ($ImageUrls) { $urls += $ImageUrls }
# keep only distinct high-res page images (drop dupes / low-res); prefer the largest imwidth per uuid
$byUuid = @{}
foreach ($u in $urls) {
  if ($u -match '/anonymous/([0-9a-f\-]+)\.jpg') {
    $uuid = $Matches[1]
    $w = 0; if ($u -match 'imwidth=(\d+)') { $w = [int]$Matches[1] }
    if (-not $byUuid.ContainsKey($uuid) -or $w -gt $byUuid[$uuid].w) { $byUuid[$uuid] = @{ url=$u; w=$w } }
  }
}
if ($byUuid.Count -eq 0) { Write-Output "No przone flyer image URLs supplied. Capture them in the browser (read_network_requests urlPattern=przone)."; exit 1 }

$i = 0; $saved = @()
foreach ($k in $byUuid.Keys) {
  $i++; $out = Join-Path $OutDir ("page-{0:D2}.jpg" -f $i)
  try { Invoke-WebRequest -Uri $byUuid[$k].url -OutFile $out -Headers $UA -UseBasicParsing -TimeoutSec 40; $saved += $out } catch { Write-Output ("  page $i download FAIL: "+$_.Exception.Message) }
}
$meta = [ordered]@{ pulled_at=(Get-Date).ToString('s'); store=$StoreLabel; ad_from=$AdFrom; ad_to=$AdTo; omaha=$okOmaha; current=$okCurrent; pages=$saved }
($meta | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $OutDir 'meta.json') -Encoding UTF8
Write-Output ""
Write-Output ("VERIFIED Omaha + current. Downloaded "+$saved.Count+" flyer pages to "+$OutDir)
Write-Output ("Next: vision-read page-*.jpg to extract deals. Meta saved to meta.json")
