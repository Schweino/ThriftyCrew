<#
  pull-grocery-ads.ps1 - Pulls CURRENT weekly-ad data for the 3 server-side Omaha stores:
    Hy-Vee (Flipp SFML), Aldi (Flipp flyerkit JSON), Family Fare (Freshop circular API).
  Baker's is browser-assisted - see pull-bakers.ps1.

  TWO HARD GATES per store, BOTH must pass before any deals are accepted:
    1) OMAHA   - the ad's store/postal must resolve to the expected Omaha store (city Omaha + 68xxx zip).
    2) CURRENT - today must fall inside the ad's valid_from..valid_to (no stale / no next-week-only).
  Fail either => that store returns ZERO deals and is flagged BLOCKED. Nothing wrong-city or stale gets through.

  Usage:  powershell -ExecutionPolicy Bypass -File pull-grocery-ads.ps1
  Output: .\out\ads-YYYY-MM-DD.json + a verification table.
#>
param([string]$OutDir = "$PSScriptRoot\out")
$ErrorActionPreference = 'Stop'
$UA = @{ 'User-Agent' = 'Mozilla/5.0' }
$TODAY = (Get-Date).Date
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force $OutDir | Out-Null }

$EXPECT = @{
  hyvee       = @{ collection = '1465'; zip = '68106' }
  aldi        = @{ merchant_store_code = '446-048'; token = '29d9bfdcf546dc601c10c64ed1e932f5' }
  family_fare = @{ app_key = 'family_fare'; store_id = '6401' }
}
function Test-OmahaZip([string]$zip) { return ($zip -match '^68[01]\d\d$') }
function Test-Current($from, $to) {
  try { $f = ([DateTimeOffset]::Parse([string]$from)).Date; $t = ([DateTimeOffset]::Parse([string]$to)).Date; return ($TODAY -ge $f -and $TODAY -le $t) } catch { return $false }
}
# Flipp/Wishabi JSON: Invoke-RestMethod mangles it -> fetch raw bytes, UTF8-decode, ConvertFrom-Json
function Get-FlippJson([string]$url) {
  $resp = Invoke-WebRequest -Uri $url -Headers $UA -UseBasicParsing -TimeoutSec 40
  $raw = $resp.Content; if ($raw -is [byte[]]) { $raw = [System.Text.Encoding]::UTF8.GetString($raw) }
  return ($raw | ConvertFrom-Json)
}

$report = New-Object System.Collections.Generic.List[object]
$allDeals = New-Object System.Collections.Generic.List[object]
function Add-Result($store, $ident, $zip, $from, $to, $okOmaha, $okCurrent, $deals) {
  $status = if ($okOmaha -and $okCurrent) { 'PASS' } else { 'BLOCKED' }
  $report.Add([ordered]@{ store=$store; identity=$ident; zip=$zip; ad_from=$from; ad_to=$to; omaha=[bool]$okOmaha; current=[bool]$okCurrent; deals=(@($deals).Count); status=$status })
  if ($status -eq 'PASS') { foreach ($d in $deals) { $d.store = $store; $allDeals.Add($d) } }
}

# Flipp item-detail lookup: when an SFML label's size segment is blank, the real size lives in the
# item-detail API keyed by the area's item-id (e.g. Pepsi "$4.99" -> "6 pk. bottles 16.9 fl. oz. or 10 pk. mini cans 7.5 fl. oz.").
$HVSizeCache = @{}
function Get-FlippSize($id) {
  if (-not $id) { return '' }
  if ($HVSizeCache.ContainsKey($id)) { return $HVSizeCache[$id] }
  $sz = ''
  try {
    $r = Invoke-WebRequest -Uri "https://backflipp.wishabi.com/flipp/items/$id" -Headers $UA -UseBasicParsing -TimeoutSec 20
    $raw = $r.Content; if ($raw -is [byte[]]) { $raw = [System.Text.Encoding]::UTF8.GetString($raw) }
    $j = $raw | ConvertFrom-Json
    $it = if ($j.item) { $j.item } else { $j }
    if ($it.description) { $sz = ([string]$it.description -replace "`n", ' ' -replace '\s+', ' ').Trim() }
  } catch {}
  $HVSizeCache[$id] = $sz
  return $sz
}

# ============================ HY-VEE (Flipp SFML) ============================
function Pull-HyVee {
  try {
    $list = Invoke-RestMethod -Uri "https://www.hy-vee.com/deals/api/digital-flyers/$($EXPECT.hyvee.collection)" -Headers $UA -TimeoutSec 30
    foreach ($f in $list) {
      $zip = [string]$f.postal_code
      $okOmaha = (Test-OmahaZip $zip)
      $okCurrent = (Test-Current $f.valid_from $f.valid_to)
      $deals = @()
      if ($okOmaha -and $okCurrent -and $f.storefront_payload_url) {
        $resp = Invoke-WebRequest -Uri $f.storefront_payload_url -Headers $UA -UseBasicParsing -TimeoutSec 40
        $b = $resp.Content
        $raw = if ($b -is [byte[]]) { if ($b.Length -ge 2 -and $b[0] -eq 31 -and $b[1] -eq 139) { $ms=New-Object IO.MemoryStream(,$b); $gz=New-Object IO.Compression.GzipStream($ms,[IO.Compression.CompressionMode]::Decompress); $sr=New-Object IO.StreamReader($gz,[Text.Encoding]::UTF8); $s=$sr.ReadToEnd(); $sr.Close(); $s } else { [Text.Encoding]::UTF8.GetString($b) } } else { [string]$b }
        [xml]$x = $raw
        $seen = @{}
        foreach ($a in $x.SelectNodes("//*[local-name()='area']")) {
          $l = $a.GetAttribute('label'); if (-not $l) { continue }
          # blank size segment ("name, , $price") -> backfill the real size from the item-detail API before the collapse
          if ($l -match ',\s*,') {
            $sz = Get-FlippSize $a.GetAttribute('item-id')
            if ($sz) { $safe = $sz.Replace('$','$$'); $l = $l -replace ',\s*,', (', ' + $safe + ', ') }
          }
          $l = ($l -replace ',\s*,', ',' -replace '\s+', ' ').Trim()
          # STAMP THE FLYER'S OWN WINDOW ON EVERY DEAL (2026-08-21, Brad: "We MUST log ad dates and
          # pricing. non negotioble."). Hy-Vee runs SEVERAL FLYERS AT ONCE and they do not share a
          # window - measured today: 'Weekly Ad' 08-17..08-23 (444 deals), monthly 08-03..08-30 (216),
          # '3 Day Sale' 08-21..08-23 (26). This loop is already PER FLYER so $f carries the right
          # dates for the rows it emits; they were simply discarded. Without them every consumer falls
          # back to the ONE store-level window in ad-schedule.json, which retires the 216 monthly deals
          # on 08-23 instead of 08-30 - seven days early, while the ad is still running.
          if ($l.Length -gt 5 -and -not $seen.ContainsKey($l)) { $seen[$l]=$true; $deals += [ordered]@{ item=$l; source_ad=[string]$f.external_display_name; ad_from=($f.valid_from -replace 'T.*',''); ad_to=($f.valid_to -replace 'T.*','') } }
        }
      }
      Add-Result 'Hy-Vee' ("ad='"+$f.external_display_name+"'") $zip ($f.valid_from -replace 'T.*','') ($f.valid_to -replace 'T.*','') $okOmaha $okCurrent $deals
    }
  } catch { $report.Add([ordered]@{ store='Hy-Vee'; identity='ERROR'; zip=''; ad_from=''; ad_to=''; omaha=$false; current=$false; deals=0; status=('ERROR: '+$_.Exception.Message) }) }
}

# ============================ ALDI (Flipp flyerkit) ============================
function Pull-Aldi {
  try {
    $tok = $EXPECT.aldi.token
    $stores = Get-FlippJson "https://dam.flippenterprise.net/flyerkit/stores/aldi?access_token=$tok&postal_code=68106"
    $store = $stores | Where-Object { $_.merchant_store_code -eq $EXPECT.aldi.merchant_store_code } | Select-Object -First 1
    if (-not $store) { $store = $stores | Where-Object { ([string]$_.city -match '(?i)omaha') -and ($_.province -eq 'NE') } | Select-Object -First 1 }
    $code = [string]$store.merchant_store_code; $city = [string]$store.city; $zip = [string]$store.postal_code; $prov = [string]$store.province
    $okOmaha = ($city -match '(?i)omaha') -and ($prov -eq 'NE') -and (Test-OmahaZip $zip) -and $code
    $pubs = Get-FlippJson "https://dam.flippenterprise.net/flyerkit/publications/aldi?locale=en&access_token=$tok&postal_code=68106&store_code=$code"
    $curFrom=''; $curTo=''; $deals=@(); $okCurrent=$false
    foreach ($p in $pubs) {
      $prods = Get-FlippJson "https://dam.flippenterprise.net/flyerkit/publication/$($p.id)/products?display_type=all&locale=en&access_token=$tok"
      if (-not $prods -or $prods.Count -eq 0) { continue }
      if (Test-Current $prods[0].valid_from $prods[0].valid_to) {
        $okCurrent=$true; $curFrom=$prods[0].valid_from; $curTo=$prods[0].valid_to
        # PER-ITEM WINDOWS, NOT THE PUBLICATION'S (2026-08-21). flyerkit returns valid_from/valid_to on
        # EVERY product - all 108 carried 2026-08-19..2026-08-25 today - and this loop read
        # $prods[0].valid_from purely to test the ad was current, then built the rows without it.
        # original_price is on the item too, so an ad row can now state what it was cut FROM.
        foreach ($it in $prods) { $price = ((""+$it.pre_price_text+' $'+$it.price_text+' '+$it.post_price_text) -replace '\s+',' ').Trim(); $deals += [ordered]@{ item=$it.name; size=$it.description; ad_price=$price; source_ad='Weekly Ad'; ad_from=([string]$it.valid_from -replace 'T.*',''); ad_to=([string]$it.valid_to -replace 'T.*',''); regular=$it.original_price } }
        break
      }
    }
    Add-Result 'Aldi' ("code=$code $city,$prov") $zip $curFrom $curTo $okOmaha $okCurrent $deals
  } catch { $report.Add([ordered]@{ store='Aldi'; identity='ERROR'; zip=''; ad_from=''; ad_to=''; omaha=$false; current=$false; deals=0; status=('ERROR: '+$_.Exception.Message) }) }
}

# ============================ FAMILY FARE (Freshop circular) ============================
function Pull-FamilyFare {
  try {
    $ak = $EXPECT.family_fare.app_key; $sid = $EXPECT.family_fare.store_id; $b = 'https://api.freshop.ncrcloud.com/1'
    $tok = $null
    foreach ($tu in @("https://api.freshop.ncrcloud.com/2/sessions?app_key=$ak","$b/sessions?app_key=$ak")) { try { $ts = Invoke-RestMethod -Uri $tu -Method Post -Headers $UA -TimeoutSec 20; if ($ts.token) { $tok = $ts.token; break } } catch {} }
    $tq = if ($tok) { "&token=$tok" } else { "" }
    $store = Invoke-RestMethod -Uri "$b/stores/$sid`?app_key=$ak$tq" -Headers $UA -TimeoutSec 25
    $city = [string]$store.city; $zip = [string]$store.postal_code
    $okOmaha = ($city -match '(?i)omaha') -and (Test-OmahaZip $zip)
    $circ = Invoke-RestMethod -Uri "$b/circulars?app_key=$ak&store_id=$sid$tq&limit=5" -Headers $UA -TimeoutSec 25
    $clist = $circ.items; if (-not $clist) { $clist = $circ }
    $cur = $clist | Where-Object { (Test-Current $_.start_date $_.finish_date) } | Select-Object -First 1
    $okCurrent = [bool]$cur
    $deals = @()
    if ($okOmaha -and $okCurrent) {
      $page = 1; $total = 999999; $collected = 0
      do {
        $r = Invoke-RestMethod -Uri "$b/products?app_key=$ak&store_id=$sid$tq&circular_id=$($cur.id)&limit=200&page=$page&fields=name,size,base_price,sale_price" -Headers $UA -TimeoutSec 30
        if ($r.total) { $total = [int]$r.total }
        $its = $r.items
          # THE CIRCULAR'S WINDOW, ON EVERY ROW IT PRODUCED (2026-08-21). $cur is the circular these
          # products were fetched FOR (circular_id=$($cur.id)), and it carries start_date/finish_date -
          # 2026-08-16..2026-08-22 today. Emitting rows without it forces every consumer back to the
          # store-level ad window, which is the defect that retires Hy-Vee's monthly deals a week early.
          foreach ($it in $its) { $deals += [ordered]@{ item=$it.name; size=$it.size; regular=$it.base_price; ad_price=$it.sale_price; source_ad='Weekly Ad'; ad_from=([string]$cur.start_date -replace 'T.*',''); ad_to=([string]$cur.finish_date -replace 'T.*','') } }
        $collected += @($its).Count; $page++
      } while (@($its).Count -gt 0 -and $collected -lt $total -and $page -le 25)
    }
    $from = if ($cur) { $cur.start_date } else { '' }; $to = if ($cur) { $cur.finish_date } else { '' }
    Add-Result 'Family Fare' ("store_id=$sid $city") $zip ($from -replace 'T.*','') ($to -replace 'T.*','') $okOmaha $okCurrent $deals
  } catch { $report.Add([ordered]@{ store='Family Fare'; identity='ERROR'; zip=''; ad_from=''; ad_to=''; omaha=$false; current=$false; deals=0; status=('ERROR: '+$_.Exception.Message) }) }
}

Write-Output ("Today: "+$TODAY.ToString('yyyy-MM-dd')+"  -  pulling current Omaha weekly ads...")
Pull-HyVee; Pull-Aldi; Pull-FamilyFare
Write-Output ""
Write-Output ("{0,-12} {1,-22} {2,-7} {3,-11} {4,-11} {5,-6} {6,-8} {7,-6} {8}" -f 'STORE','IDENTITY','ZIP','AD FROM','AD TO','OMAHA','CURRENT','DEALS','STATUS')
foreach ($r in $report) { Write-Output ("{0,-12} {1,-22} {2,-7} {3,-11} {4,-11} {5,-6} {6,-8} {7,-6} {8}" -f $r.store, ([string]$r.identity).Substring(0,[math]::Min(22,([string]$r.identity).Length)), $r.zip, $r.ad_from, $r.ad_to, $r.omaha, $r.current, $r.deals, $r.status) }
$passStores = @($report | Where-Object { $_.status -eq 'PASS' } | ForEach-Object { $_.store } | Select-Object -Unique)
$out = [ordered]@{ pulled_at=(Get-Date).ToString('s'); today=$TODAY.ToString('yyyy-MM-dd'); verification=$report; deal_count=$allDeals.Count; deals=$allDeals }
$file = Join-Path $OutDir ("ads-"+$TODAY.ToString('yyyy-MM-dd')+".json")
($out | ConvertTo-Json -Depth 6) | Set-Content $file -Encoding UTF8
Write-Output ""
Write-Output ("VERIFIED stores: "+(($passStores) -join ', ')+"   total verified deals: "+$allDeals.Count)
Write-Output ("Saved: "+$file)
