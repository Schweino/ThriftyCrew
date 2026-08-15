# Fold the staples300 agent data into the engine (same pattern as staples100 process-agents, PS5.1-safe).
$ErrorActionPreference = 'Stop'
$root = 'C:\Codex\ThriftyCrew\grocery'
$s3 = Join-Path $root 'out\staples300'
$today = '2026-07-13'

function LoadJson([string]$p) { $t = ConvertFrom-Json ([IO.File]::ReadAllText($p)); return @($t) }
function Add-Reg([string]$file, [string]$store, $rows, [string]$src) {
  if (Test-Path $file) { $doc = ConvertFrom-Json ([IO.File]::ReadAllText($file)) }
  else { $doc = [pscustomobject]@{ store = $store; week_of = $today; price_type = 'everyday'; deals = @() } }
  $have = @{}; foreach ($d in $doc.deals) { $have[[string]$d.item] = $true }
  $n = 0
  foreach ($r in $rows) {
    if ($have.ContainsKey([string]$r.name)) { continue }
    $doc.deals += [pscustomobject]@{ store = $store; item = [string]$r.name; ad_price = ('$' + $r.price); size = [string]$r.size; regular = $null; source_ad = $src }
    $n++
  }
  $doc | ConvertTo-Json -Depth 6 | Set-Content $file -Encoding UTF8
  return $n
}
function UrlRows($rows, [string]$base) {
  @($rows | Where-Object { $_.url } | ForEach-Object {
    $u = [string]$_.url; if ($u -notmatch '^https?://') { $u = $base + $u }
    [pscustomobject]@{ id = [string]$_.id; url = $u; price = [string]$_.price; size = [string]$_.size; name = [string]$_.name } })
}

# ---- FAMILY FARE: union yesterday's 473-item file (in git) with the throttled 380-item rerun ----
$ffFile = Join-Path $root 'out\regular\family-fare-regular-2026-07-12.json'
Push-Location (Split-Path $root -Parent)
$gitOld = git show '54326b9:grocery/out/regular/family-fare-regular-2026-07-12.json' 2>$null
Pop-Location
if ($gitOld) {
  $old = ConvertFrom-Json ($gitOld -join "`n")
  $cur = ConvertFrom-Json ([IO.File]::ReadAllText($ffFile))
  $have = @{}; foreach ($d in $cur.deals) { $have[[string]$d.item + '|' + [string]$d.size] = $true }
  $add = 0
  foreach ($d in $old.deals) { $k = [string]$d.item + '|' + [string]$d.size; if (-not $have.ContainsKey($k)) { $cur.deals += $d; $add++ } }
  $cur | ConvertTo-Json -Depth 6 | Set-Content $ffFile -Encoding UTF8
  Write-Output ("FF union: +$add from git copy -> " + @($cur.deals).Count + " deals")
} else { Write-Output 'FF union: git copy unavailable, skipped' }

# ---- WALMART ----
$w = LoadJson (Join-Path $s3 'walmart-agent.json')
$wf = Join-Path $root 'out\regular\walmart-regular-2026-07-12.json'
$n = Add-Reg $wf 'Walmart' $w 'walmart.com (Omaha, staples300)'
ConvertTo-Json (UrlRows $w 'https://www.walmart.com') -Depth 4 | Set-Content (Join-Path $root 'out\url-inputs\store-walmart8-urls.json') -Encoding UTF8
Write-Output ("Walmart: +$n, " + @($w).Count + " links")

# ---- FAREWAY (append raw shop rows; regular regenerates) ----
$fw = LoadJson (Join-Path $s3 'fareway-agent.json')
$sf = Join-Path $root 'out\fareway\fareway-shop-verify.json'
$tmp = ConvertFrom-Json ([IO.File]::ReadAllText($sf)); $shop = @($tmp)
$haveIds = @{}; foreach ($s in $shop) { $haveIds[[string]$s.id] = $true }
$fN = 0
foreach ($r in $fw) {
  if ($haveIds.ContainsKey([string]$r.id)) { continue }
  $shop += ,([pscustomobject]@{ id = [string]$r.id; name = [string]$r.name; price = [string]$r.price; per = $(if ([string]$r.size -eq 'lb') { 'pound' } else { '' }); orig = [string]$r.orig; unit = ''; size = [string]$r.size; url = [string]$r.url })
  $fN++
}
ConvertTo-Json @($shop) -Depth 4 | Set-Content $sf -Encoding UTF8
Write-Output ("Fareway: +$fN shop rows -> " + @($shop).Count)

# ---- HY-VEE (+ markdowns to extra-deals) ----
$hy = LoadJson (Join-Path $s3 'hyvee-agent.json')
$hf = Join-Path $root 'out\regular\hyvee-regular-2026-07-12.json'
$n = Add-Reg $hf 'Hy-Vee' $hy 'Aisles Online (Omaha #1, staples300)'
ConvertTo-Json (UrlRows $hy 'https://www.hy-vee.com') -Depth 4 | Set-Content (Join-Path $root 'out\url-inputs\store-hyvee11-urls.json') -Encoding UTF8
$ef = Join-Path $root 'out\extra-deals-2026-07-12.json'
$ex = ConvertFrom-Json ([IO.File]::ReadAllText($ef))
$exN = 0
foreach ($r in $hy) {
  if ($r.sale -and "$($r.sale)" -ne '' -and ([double]$r.sale) -lt ([double]$r.price)) {
    $ex.deals += [pscustomobject]@{ store = 'Hy-Vee'; item = [string]$r.name; ad_price = ('$' + $r.sale); size = [string]$r.size; regular = ('$' + $r.price); source_ad = 'Aisles Online markdown (staples300)' }
    $exN++
  }
}
$ex | ConvertTo-Json -Depth 5 | Set-Content $ef -Encoding UTF8
Write-Output ("Hy-Vee: +$n, " + @($hy).Count + " links, $exN markdowns")

# ---- ALDI ----
$al = LoadJson (Join-Path $s3 'aldi-agent.json')
$af = Join-Path $root 'out\regular\aldi-regular-2026-07-12.json'
$n = Add-Reg $af 'Aldi' $al 'aldi.us (OLA 42 Omaha, staples300)'
ConvertTo-Json (UrlRows $al 'https://www.aldi.us') -Depth 4 | Set-Content (Join-Path $root 'out\url-inputs\store-aldi7-urls.json') -Encoding UTF8
Write-Output ("Aldi: +$n, " + @($al).Count + " links")

# ---- SAM'S ----
$sm2 = LoadJson (Join-Path $s3 'sams-agent.json')
$smF = Get-ChildItem (Join-Path $root 'out\sams\sams-deals-*.json') | Sort-Object Name -Descending | Select-Object -First 1
$sm = ConvertFrom-Json ([IO.File]::ReadAllText($smF.FullName))
$have = @{}; foreach ($d in $sm.deals) { $have[[string]$d.item] = $true }
$n = 0
foreach ($r in $sm2) {
  if ($have.ContainsKey([string]$r.name)) { continue }
  $sm.deals += [pscustomobject]@{ store = "Sam's Club"; item = [string]$r.name; ad_price = ('$' + $r.price); size = [string]$r.size; regular = $null; source_ad = 'samsclub.com (Omaha, staples300)' }
  $n++
}
$sm | ConvertTo-Json -Depth 6 | Set-Content $smF.FullName -Encoding UTF8
ConvertTo-Json (UrlRows $sm2 'https://www.samsclub.com') -Depth 4 | Set-Content (Join-Path $root 'out\url-inputs\store-sams8-urls.json') -Encoding UTF8
Write-Output ("Sam's: +$n, " + @($sm2).Count + " links")

# ---- BAKER'S ----
$bk = LoadJson (Join-Path $s3 'bakers-agent.json')
$bf = Join-Path $root 'out\regular\bakers-regular-2026-07-12.json'
$n = Add-Reg $bf "Baker's" $bk 'bakersplus.com everyday (Saddlecreek, staples300)'
ConvertTo-Json (UrlRows $bk 'https://www.bakersplus.com') -Depth 4 | Set-Content (Join-Path $root 'out\url-inputs\store-bakers7-urls.json') -Encoding UTF8
Write-Output ("Baker's: +$n, " + @($bk).Count + " links")
