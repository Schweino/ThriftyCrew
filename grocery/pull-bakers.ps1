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

  THIRD GATE, added 2026-08-09: COMPLETE + CLEAN. Pages stage in out\bakers\pages.staging and swap in only
  when every intended page arrived; out\bakers\ is cleared of page-NN.jpg first, so an ad with FEWER pages
  than the last one cannot leave the expired ad's extra pages behind for the vision read to pick up. The
  clear is scoped to parsed page-NN.jpg names - bakers-deals-*.json, urls.txt and meta.json are untouched.
  See adpages-lib.ps1 for the contract and the Fareway incident that produced it. VISION-READ THE PAGES
  meta.json LISTS, not a bare page-*.jpg glob; ad-window.json in the folder names the window they belong to.

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
$base = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $base 'out\bakers' }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force $OutDir | Out-Null }
. (Join-Path $base 'adpages-lib.ps1')

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
# keep only distinct high-res page images (drop dupes / low-res); prefer the largest imwidth per uuid.
# ORDER IS FIRST-SEEN, NOT HASHTABLE ORDER. page-NN used to be numbered by $byUuid.Keys enumeration, which
# PowerShell does not guarantee and does not sort - so page-01.jpg was whichever uuid the hash happened to
# hand back first, and the page numbers carried no relation to the flyer's actual order. The capture list
# comes off the network log in page order, so honour that.
$order = @()
$byUuid = @{}
foreach ($u in $urls) {
  if ($u -match '/anonymous/([0-9a-f\-]+)\.jpg') {
    $uuid = $Matches[1]
    $w = 0; if ($u -match 'imwidth=(\d+)') { $w = [int]$Matches[1] }
    if (-not $byUuid.ContainsKey($uuid)) { $order += $uuid; $byUuid[$uuid] = @{ url=$u; w=$w } }
    elseif ($w -gt $byUuid[$uuid].w)     { $byUuid[$uuid] = @{ url=$u; w=$w } }
  }
}
if ($order.Count -eq 0) { Write-Output "No przone flyer image URLs supplied. Capture them in the browser (read_network_requests urlPattern=przone)."; exit 1 }

# STAGE, then swap (see adpages-lib.ps1). Downloading straight into $OutDir is what let an expired ad's
# extra pages survive a shorter new ad on the Fareway side; Baker's has the identical shape.
$staging = New-AdStagingDir (Join-Path $OutDir 'pages.staging')
$i = 0
foreach ($k in $order) {
  $i++
  $name = ("page-{0:D2}.jpg" -f $i)
  try { Invoke-WebRequest -Uri $byUuid[$k].url -OutFile (Join-Path $staging $name) -Headers $UA -UseBasicParsing -TimeoutSec 40 }
  catch { Write-Output ("  page $i download FAIL: "+$_.Exception.Message) }
}
$inst = Install-AdPages -Dir $OutDir -Staging $staging -Prefix 'page' -Expected (1..$order.Count) `
                        -Stamp @{ from=$AdFrom; to=$AdTo; store=$StoreLabel; pulled=(Get-Date).ToString('yyyy-MM-dd') }
$onDisk = @(@((Get-AdPageMap -Dir $OutDir -Prefix 'page').Keys) | Sort-Object)
$stamp = Read-AdWindowStamp -Dir $OutDir
$meta = [ordered]@{
  pulled_at=(Get-Date).ToString('s'); store=$StoreLabel; ad_from=$AdFrom; ad_to=$AdTo
  omaha=$okOmaha; current=$okCurrent
  ad_pages=$order.Count                       # pages the capture offered
  pages=@($(if ($inst.ok) { $onDisk | ForEach-Object { Join-Path $OutDir ("page-{0:D2}.jpg" -f $_) } } else { @() }))
  installed=$inst.ok
  on_disk=$onDisk.Count                       # what a glob of this folder will actually find
  on_disk_from=$(if ($stamp) { [string]$stamp.from } else { '' })
  on_disk_to=$(if ($stamp) { [string]$stamp.to } else { '' })
  reason=$inst.reason
}
($meta | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $OutDir 'meta.json') -Encoding UTF8
Write-Output ""
if (-not $inst.ok) {
  Write-Output ("PAGES NOT INSTALLED: " + $inst.reason)
  if ($onDisk.Count -gt 0) {
    $w = if ($meta.on_disk_from) { "$($meta.on_disk_from)..$($meta.on_disk_to)" } else { 'unknown window (pulled before ad-window.json existed)' }
    Write-Output ("  WARNING: $($onDisk.Count) page(s) remain in $OutDir from $w - do NOT vision-read them as current.")
  }
  Write-Output ("Re-capture the przone URLs and re-run. meta.json records installed=false.")
  exit 2
}
Write-Output ("VERIFIED Omaha + current. Installed "+$inst.installed+" flyer pages to "+$OutDir+" (folder cleared first)")
Write-Output ("Next: vision-read the pages meta.json lists to extract deals. Window stamped in ad-window.json")
