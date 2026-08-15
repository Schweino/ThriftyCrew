# Fold the agent-collected store data (staples100 *-agent.json) into the engine:
# per-store regular/deals files + url-inputs. Idempotent-ish (skips duplicate item names).
$ErrorActionPreference = 'Stop'
$root = 'C:\Codex\ThriftyCrew\grocery'
$s100 = Join-Path $root 'out\staples100'
$today = '2026-07-12'

function Add-Reg([string]$file, [string]$store, $rows, [string]$src) {
  if (Test-Path $file) { $doc = Get-Content $file -Raw | ConvertFrom-Json }
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
    [pscustomobject]@{ id = [string]$_.id; url = $u; price = [string]$_.price; size = [string]$_.size; name = [string]$_.name }
  })
}

# ---- ALDI ----
$aldi = Get-Content (Join-Path $s100 'aldi-agent.json') -Raw | ConvertFrom-Json
$af = Get-ChildItem (Join-Path $root 'out\regular\aldi-regular-*.json') | Sort-Object Name -Descending | Select-Object -First 1
$aNew = Join-Path $root ('out\regular\aldi-regular-' + $today + '.json')
if ($af -and $af.Name -ne ('aldi-regular-' + $today + '.json')) { Copy-Item $af.FullName $aNew -Force }
$n = Add-Reg $aNew 'Aldi' $aldi 'aldi.us (OLA 42 Omaha, staples100)'
ConvertTo-Json (UrlRows $aldi 'https://www.aldi.us') -Depth 4 | Set-Content (Join-Path $root 'out\url-inputs\store-aldi6-urls.json') -Encoding UTF8
Write-Output ("Aldi: +$n entries, " + @($aldi).Count + " links")

# ---- HY-VEE (everyday price; a lower 'sale' also goes to extra-deals) ----
$hy = Get-Content (Join-Path $s100 'hyvee-agent.json') -Raw | ConvertFrom-Json
$hf = Join-Path $root ('out\regular\hyvee-regular-' + $today + '.json')
$n = Add-Reg $hf 'Hy-Vee' $hy 'Aisles Online (Omaha #1, staples100)'
ConvertTo-Json (UrlRows $hy 'https://www.hy-vee.com') -Depth 4 | Set-Content (Join-Path $root 'out\url-inputs\store-hyvee10-urls.json') -Encoding UTF8
$ef = Join-Path $root ('out\extra-deals-' + $today + '.json')
$ex = Get-Content $ef -Raw | ConvertFrom-Json
$exN = 0
foreach ($r in $hy) {
  if ($r.sale -and "$($r.sale)" -ne '' -and ([double]$r.sale) -lt ([double]$r.price)) {
    $ex.deals += [pscustomobject]@{ store = 'Hy-Vee'; item = [string]$r.name; ad_price = ('$' + $r.sale); size = [string]$r.size; regular = ('$' + $r.price); source_ad = 'Aisles Online markdown (staples100)' }
    $exN++
  }
}
$ex | ConvertTo-Json -Depth 5 | Set-Content $ef -Encoding UTF8
Write-Output ("Hy-Vee: +$n entries, " + @($hy).Count + " links, $exN markdowns -> extra-deals")

# ---- FAREWAY (append raw shop rows; build-fareway-regular consumes) ----
$fw = Get-Content (Join-Path $s100 'fareway-agent.json') -Raw | ConvertFrom-Json
$sf = Join-Path $root 'out\fareway\fareway-shop-verify.json'
$shop = @(Get-Content $sf -Raw | ConvertFrom-Json)
$haveIds = @{}; foreach ($s in $shop) { $haveIds[[string]$s.id] = $true }
$fN = 0
foreach ($r in $fw) {
  if ($haveIds.ContainsKey([string]$r.id)) { continue }
  $shop += ,([pscustomobject]@{ id = [string]$r.id; name = [string]$r.name; price = [string]$r.price; per = $(if ([string]$r.size -eq 'lb') { 'pound' } else { '' }); orig = [string]$r.orig; unit = ''; size = [string]$r.size; url = [string]$r.url })
  $fN++
}
ConvertTo-Json @($shop) -Depth 4 | Set-Content $sf -Encoding UTF8
Write-Output ("Fareway: +$fN raw shop rows (build-fareway-regular next)")

# ---- SAM'S (everyday deals file) ----
$sams = Get-Content (Join-Path $s100 'sams-agent.json') -Raw | ConvertFrom-Json
$smF = Get-ChildItem (Join-Path $root 'out\sams\sams-deals-*.json') | Sort-Object Name -Descending | Select-Object -First 1
$sm = Get-Content $smF.FullName -Raw | ConvertFrom-Json
$have = @{}; foreach ($d in $sm.deals) { $have[[string]$d.item] = $true }
$n = 0
foreach ($r in $sams) {
  if ($have.ContainsKey([string]$r.name)) { continue }
  $sm.deals += [pscustomobject]@{ store = "Sam's Club"; item = [string]$r.name; ad_price = ('$' + $r.price); size = [string]$r.size; regular = $null; source_ad = 'samsclub.com (Omaha, staples100)' }
  $n++
}
$sm | ConvertTo-Json -Depth 6 | Set-Content $smF.FullName -Encoding UTF8
ConvertTo-Json (UrlRows $sams 'https://www.samsclub.com') -Depth 4 | Set-Content (Join-Path $root 'out\url-inputs\store-sams7-urls.json') -Encoding UTF8
Write-Output ("Sam's: +$n entries (" + $smF.Name + "), " + @($sams).Count + " links")

# ---- BAKER'S ----
$bk = Get-Content (Join-Path $s100 'bakers-agent.json') -Raw | ConvertFrom-Json
$bf = Get-ChildItem (Join-Path $root 'out\regular\bakers-regular-*.json') | Sort-Object Name -Descending | Select-Object -First 1
$bNew = Join-Path $root ('out\regular\bakers-regular-' + $today + '.json')
if ($bf -and $bf.Name -ne ('bakers-regular-' + $today + '.json')) { Copy-Item $bf.FullName $bNew -Force }
$n = Add-Reg $bNew "Baker's" $bk 'bakersplus.com everyday (Saddlecreek, staples100)'
ConvertTo-Json (UrlRows $bk 'https://www.bakersplus.com') -Depth 4 | Set-Content (Join-Path $root 'out\url-inputs\store-bakers6-urls.json') -Encoding UTF8
Write-Output ("Baker's: +$n entries, " + @($bk).Count + " links (21 blocked ids fill via agents)")

