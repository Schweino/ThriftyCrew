<#
  pull-fareway-ads.ps1 - Fareway's weekly + monthly ad, fully server-side (NO browser, no bot wall - unlike
  Baker's). Fareway hosts its Omaha ad as page JPGs on its own CDN with the SALE DATES ENCODED IN THE FILENAME
  (OmahaGroup_weekly_MMDDYYYY_MMDDYYYY-N.jpg), so the pull self-updates and self-verifies week to week.

  Enforces the same TWO HARD GATES as pull-grocery-ads.ps1:
    OMAHA   - the image path must be the OmahaGroup ad group (store 043 = Omaha).
    CURRENT - today must fall inside the ad's valid_from..valid_to (parsed from the filename).
  Fail either -> that ad is BLOCKED and no pages are downloaded (nothing wrong-city / stale can leak through).

  Downloads each page JPG to out\fareway\<weekly|monthly>\ and writes out\fareway\fareway-ad-manifest-<date>.json
  { generated, weekly:{from,to,pages,dir,blocked}, monthly:{...} } for the vision-read step to consume.
  The store storefront (shop.fareway.com) is the everyday+sale price source; these ad images are the SALE
  supplement (some ad promos aren't shown online).
#>
param([string]$OutDir = "", [string]$Today = "")
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$fwDir = Join-Path $OutDir 'fareway'
New-Item -ItemType Directory -Force -Path $fwDir | Out-Null
$asof = if ($Today) { [datetime]::ParseExact($Today,'yyyy-MM-dd',$null) } else { (Get-Date).Date }
$asofS = $asof.ToString('yyyy-MM-dd')
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'

function Get-AdPages([string]$kind) {
  # kind = 'weekly' or 'monthly'
  $url = "https://www.fareway.com/stores/043/ad/$kind`?embedded"
  $res = [ordered]@{ from=''; to=''; pages=0; dir=''; blocked=$true; reason='' }
  try { $html = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -Headers @{'User-Agent'=$ua}).Content }
  catch { $res.reason = "fetch failed: $($_.Exception.Message)"; return $res }
  # image paths: /media/stores/adGroups/NN/OmahaGroup_<kind>_MMDDYYYY_MMDDYYYY-N.jpg
  $rx = "/media/stores/adGroups/\d+/OmahaGroup_${kind}_(\d{8})_(\d{8})-(\d+)\.jpg"
  $matches = [regex]::Matches($html, $rx)
  if ($matches.Count -eq 0) { $res.reason = 'no OmahaGroup ad images found (wrong city or ad markup changed)'; return $res }
  $fromRaw = $matches[0].Groups[1].Value; $toRaw = $matches[0].Groups[2].Value
  $from = [datetime]::ParseExact($fromRaw,'MMddyyyy',$null); $to = [datetime]::ParseExact($toRaw,'MMddyyyy',$null)
  $res.from = $from.ToString('yyyy-MM-dd'); $res.to = $to.ToString('yyyy-MM-dd')
  # CURRENT gate: today within [from, to]
  if ($asof -lt $from -or $asof -gt $to) { $res.reason = "not current (ad $($res.from)..$($res.to), today $asofS)"; return $res }
  # distinct page paths, ordered by page number
  $paths = @{}
  foreach ($m in $matches) { $paths[[int]$m.Groups[3].Value] = $m.Value }
  $ordered = $paths.GetEnumerator() | Sort-Object Name
  $dir = Join-Path $fwDir $kind
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $ok = 0
  foreach ($p in $ordered) {
    $u = 'https://www.fareway.com' + $p.Value
    $o = Join-Path $dir ("$kind-$($p.Name).jpg")
    try { Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 40 -Headers @{'User-Agent'=$ua} -OutFile $o
          if ((Get-Item $o).Length -gt 5000) { $ok++ } } catch {}
  }
  $res.pages = $ok; $res.dir = $dir; $res.blocked = $false; $res.reason = "OK ($ok pages)"
  return $res
}

$weekly  = Get-AdPages 'weekly'
$monthly = Get-AdPages 'monthly'
$manifest = [ordered]@{ generated=$asofS; store='Fareway'; ad_group='OmahaGroup (043)'; weekly=$weekly; monthly=$monthly }
$manifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $fwDir "fareway-ad-manifest-$asofS.json") -Encoding UTF8

Write-Output ("Fareway weekly : " + $(if ($weekly.blocked) { 'BLOCKED - ' + $weekly.reason } else { "$($weekly.pages) pages  $($weekly.from)..$($weekly.to)" }))
Write-Output ("Fareway monthly: " + $(if ($monthly.blocked) { 'BLOCKED - ' + $monthly.reason } else { "$($monthly.pages) pages  $($monthly.from)..$($monthly.to)" }))
