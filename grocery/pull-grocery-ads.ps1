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
param([string]$OutDir = "$PSScriptRoot\out", [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$UA = @{ 'User-Agent' = 'Mozilla/5.0' }
$TODAY = (Get-Date).Date
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force $OutDir | Out-Null }

$EXPECT = @{
  hyvee       = @{ collection = '' }   # the store's own id, set below from hyvee-store-lib (HY-VEE STORE)
  aldi        = @{ merchant_store_code = '446-048'; token = '29d9bfdcf546dc601c10c64ed1e932f5' }
  family_fare = @{ app_key = 'family_fare'; store_id = '6401' }
}
function Test-OmahaZip([string]$zip) { return ($zip -match '^68[01]\d\d$') }

# HY-VEE STORE, FROM THE ONE PLACE THAT KNOWS IT (2026-09-10). This file requested flyer collection 1465 as a
# literal, and hyvee-store-lib recorded as an ASSUMPTION whether a flyer collection id is a Hy-Vee storeId.
# PROVEN read-only that day: each id returns its own store's postal code (1465 -> 68106, 1466 -> 68137, 1467 ->
# 68164, 1470 -> 68114), stores in other markets return different flyers (1464 -> 66061 Olathe, 1400 -> 56258
# Marshall, 1600 -> 61282 Silvis) and invalid ids return none. So the flyer follows the storeId the board speaks
# for. Every Omaha id returned the SAME two flyers that day, so nothing on the board moved; what this removes is
# the day Hy-Vee splits Omaha ads and a literal quietly pairs Omaha #01's ad with Omaha #02's shelf prices.
# The Hy-Vee gate also requires the flyer's postal_code to equal the identity's flyer_postal_code (stores.json), so
# another Omaha store's flyer is refused rather than passed by the any-68xxx Omaha check.
. (Join-Path $PSScriptRoot 'hyvee-store-lib.ps1')
function Resolve-HyVeeFlyerCollection([string]$Root) {
  # @(collection, label, error, flyer postal code). A registry that disagrees with the library blocks Hy-Vee, never the other stores.
  $drift = Test-HyVeeStoreDrift -Root $Root
  if ($drift) { return @('', '', [string]$drift, '') }
  $s = Get-HyVeeStore -Root $Root
  return @([string]$s.store_id, [string]$s.label, '', [string]$s.flyer_postal_code)
}
function Test-HyVeeFlyerStore([string]$zip, [string]$expected) {
  # The flyer must be THIS store's. An identity with no code refuses: an open gate is the defect this closes.
  if (-not $expected) { return $false }
  return [string]::Equals(([string]$zip).Trim(), $expected.Trim(), [StringComparison]::Ordinal)
}
$HVFLYER = Resolve-HyVeeFlyerCollection $PSScriptRoot
$EXPECT.hyvee.collection = [string]$HVFLYER[0]
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
  if (-not $EXPECT.hyvee.collection) {
    $report.Add([ordered]@{ store='Hy-Vee'; identity='STORE'; zip=''; ad_from=''; ad_to=''; omaha=$false; current=$false; deals=0; status=('BLOCKED: '+[string]$HVFLYER[2]) })
    return
  }
  try {
    $list = Invoke-RestMethod -Uri "https://www.hy-vee.com/deals/api/digital-flyers/$($EXPECT.hyvee.collection)" -Headers $UA -TimeoutSec 30
    foreach ($f in $list) {
      $zip = [string]$f.postal_code
      $okOmaha = (Test-OmahaZip $zip) -and (Test-HyVeeFlyerStore $zip ([string]$HVFLYER[3]))
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
. (Join-Path $PSScriptRoot 'ff-price-lib.ps1')   # Get-FreshopPages, Select-FreshopCircular: the skip= pager and the widest-window picker (2026-09-11)
function Pull-FamilyFare {
  try {
    $pg = $null; $sel = $null
    $ak = $EXPECT.family_fare.app_key; $sid = $EXPECT.family_fare.store_id; $b = 'https://api.freshop.ncrcloud.com/1'
    $tok = $null
    foreach ($tu in @("https://api.freshop.ncrcloud.com/2/sessions?app_key=$ak","$b/sessions?app_key=$ak")) { try { $ts = Invoke-RestMethod -Uri $tu -Method Post -Headers $UA -TimeoutSec 20; if ($ts.token) { $tok = $ts.token; break } } catch {} }
    $tq = if ($tok) { "&token=$tok" } else { "" }
    $store = Invoke-RestMethod -Uri "$b/stores/$sid`?app_key=$ak$tq" -Headers $UA -TimeoutSec 25
    $city = [string]$store.city; $zip = [string]$store.postal_code
    $okOmaha = ($city -match '(?i)omaha') -and (Test-OmahaZip $zip)
    $circ = Invoke-RestMethod -Uri "$b/circulars?app_key=$ak&store_id=$sid$tq&limit=5" -Headers $UA -TimeoutSec 25
    $clist = $circ.items; if (-not $clist) { $clist = $circ }
    # THE WIDEST CURRENT WINDOW, NOT THE FIRST LISTED (2026-09-11, queue 2026-09-10-fa6ad6): the 2-day 'Week's Ad
    # Preview' is listed before the weekly ad while both are current. Select-FreshopCircular logs every current one.
    $sel = Select-FreshopCircular -Circulars $clist -Today $TODAY
    $cur = $sel.pick
    if ($sel.log) { Write-Output ('Family Fare circulars current today: ' + $sel.log) }
    $okCurrent = [bool]$cur
    $deals = @()
    if ($okOmaha -and $okCurrent) {
      # PAGED WITH skip= AT 100, NOT page= AT 200 (2026-09-11, queue 2026-09-10-fa6ad6). Freshop clamps limit to 100
      # and ignores page=, so the old loop read the SAME 100 rows eleven times and reported them as 1,100 deals while
      # 945 of the circular's 1,045 rows never arrived. Get-FreshopPages (ff-price-lib.ps1) walks skip=, dedupes by
      # id, throws on a page that brings no new id, and stops on the first failed request keeping what it read.
      # 15 requests is the cap: 11 reads a 1,045-row circular, and the old loop already spent 11 on one page.
      $pg = Get-FreshopPages -Uri "$b/products?app_key=$ak&store_id=$sid$tq&circular_id=$($cur.id)&fields=id,name,size,base_price,sale_price" -PageSize 100 -MaxRequests 15 -DelayMs 3000 -Headers $UA
      # THE CIRCULAR'S WINDOW, ON EVERY ROW IT PRODUCED (2026-08-21). $cur is the circular these products were
      # fetched FOR, and it carries start_date/finish_date. Emitting rows without it forces every consumer back to
      # the store-level ad window, which is the defect that retires Hy-Vee's monthly deals a week early.
      foreach ($it in $pg.rows) { $deals += [ordered]@{ item=$it.name; size=$it.size; regular=$it.base_price; ad_price=$it.sale_price; source_ad='Weekly Ad'; ad_from=([string]$cur.start_date -replace 'T.*',''); ad_to=([string]$cur.finish_date -replace 'T.*','') } }
      Write-Output ('Family Fare circular walk: deals=' + $pg.unique + ' coverage=' + $pg.unique + '/' + $pg.total + ' requests=' + $pg.requests + ' stop=' + $pg.stop + $(if ($pg.status) { ' status=' + $pg.status } else { '' }))
    }
    $from = if ($cur) { $cur.start_date } else { '' }; $to = if ($cur) { $cur.finish_date } else { '' }
    Add-Result 'Family Fare' ("store_id=$sid $city") $zip ($from -replace 'T.*','') ($to -replace 'T.*','') $okOmaha $okCurrent $deals
    # COVERAGE ON THE RECORD (2026-09-11, queue 2026-09-10-fa6ad6): what the walk read against what the store says it
    # has, so check-ad-cycles can speak on a short read (Get-CircularCoverageReview) instead of trusting a count.
    if ($pg) { $rec = $report[$report.Count - 1]; $rec['ad_unique'] = $pg.unique; $rec['ad_total'] = $pg.total; $rec['coverage'] = ([string]$pg.unique + '/' + [string]$pg.total); $rec['ad_pager_stop'] = $pg.stop; $rec['ad_requests'] = $pg.requests; $rec['circular'] = [string]$cur.name }
    if ($sel) { $report[$report.Count - 1]['circulars_current'] = [string]$sel.log }
  } catch { $report.Add([ordered]@{ store='Family Fare'; identity='ERROR'; zip=''; ad_from=''; ad_to=''; omaha=$false; current=$false; deals=0; status=('ERROR: '+$_.Exception.Message) }) }
}

if ($SelfTest) {
  # Pure: no network and no store writes. The flyer store must come from hyvee-store-lib, and a registry that
  # disagrees with the library must block Hy-Vee alone. Registries under test are written to a temp folder.
  $fail = 0; $n = 0
  function _T([string]$label, [bool]$cond) { $script:n++; if ($cond) { Write-Output "ok    $label" } else { Write-Output "FAIL  $label"; $script:fail++ } }
  $s = Get-HyVeeStore -Root $PSScriptRoot
  _T 'MUST FIRE  the Hy-Vee flyer collection is the store hyvee-store-lib names, a positive id' (([string]$EXPECT.hyvee.collection -eq [string]$s.store_id) -and ([int]$EXPECT.hyvee.collection -gt 0))
  $src = [IO.File]::ReadAllText($PSCommandPath)
  $retired = 'digital-flyers/' + '14' + '65'
  $literal = "collection = '" + '14' + "65'"
  _T 'MUST NOT FIRE  no flyer request in this file names the retired Omaha #01 id' ((-not $src.Contains($retired)) -and (-not $src.Contains($literal)))
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('pga-selftest-' + [guid]::NewGuid().ToString('N'))
  $split = Join-Path $tmp 'split'; $agree = Join-Path $tmp 'agree'
  New-Item -ItemType Directory -Force $split, $agree | Out-Null
  try {
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $split 'stores.json'), '{"stores":[{"name":"Hy-Vee","store_identity":{"store_id":1465,"location_id":"adcb2ae1-f440-4512-bfe8-9624832c72a9","label":"Omaha #01"}}]}', $utf8)
    [IO.File]::WriteAllText((Join-Path $agree 'stores.json'), '{"stores":[{"name":"Hy-Vee","store_identity":{"store_id":1466,"location_id":"09e8f4f0-e614-4b86-9285-c9c3dbff0d85","label":"Omaha #02","flyer_postal_code":"68137"}}]}', $utf8)
    $postal = Join-Path $tmp 'postal'; New-Item -ItemType Directory -Force $postal | Out-Null
    [IO.File]::WriteAllText((Join-Path $postal 'stores.json'), '{"stores":[{"name":"Hy-Vee","store_identity":{"store_id":1466,"location_id":"09e8f4f0-e614-4b86-9285-c9c3dbff0d85","label":"Omaha #02","flyer_postal_code":"68106"}}]}', $utf8)
    $r = Resolve-HyVeeFlyerCollection $split
    _T 'MUST FIRE  a registry that disagrees with hyvee-store-lib yields no collection and names the disagreement' (([string]$r[0] -eq '') -and ([string]$r[2] -match 'DISAGREES'))
    $r2 = Resolve-HyVeeFlyerCollection $agree
    _T 'CLEAN TWIN  a registry that agrees resolves its store id (1466), label and flyer postal code (68137) with no error' (([string]$r2[0] -eq '1466') -and ([string]$r2[1] -eq 'Omaha #02') -and ([string]$r2[2] -eq '') -and ([string]$r2[3] -eq '68137'))
    $r3 = Resolve-HyVeeFlyerCollection $postal
    _T 'MUST FIRE  a registry that disagrees on flyer_postal_code yields no collection and names the field' (([string]$r3[0] -eq '') -and ([string]$r3[2] -match 'flyer_postal_code'))
  } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  _T "CLEAN TWIN  the Omaha gate still passes Omaha #02's flyer zip (68137)" (Test-OmahaZip '68137')
  _T 'MUST NOT FIRE  the Omaha gate refuses a flyer zip from another market (66061, Olathe KS)' (-not (Test-OmahaZip '66061'))
  _T 'MUST FIRE  the Hy-Vee gate refuses a flyer from another Omaha store (68106) under Omaha #02 (68137)' (-not (Test-HyVeeFlyerStore '68106' '68137'))
  _T 'CLEAN TWIN  the Hy-Vee gate passes the flyer from the store it asked for (68137)' (Test-HyVeeFlyerStore '68137' '68137')
  _T 'MUST FIRE  with no expected postal code the Hy-Vee gate refuses rather than passing every Omaha flyer' (-not (Test-HyVeeFlyerStore '68137' ''))
  _T 'MUST FIRE  the live identity carries a flyer postal code, so the Hy-Vee gate cannot run open' ([string]$HVFLYER[3] -match '^68\d{3}$')
  # ---- FRESHOP PAGER, CIRCULAR PICKER, COVERAGE REVIEW (2026-09-11, queue 2026-09-10-fa6ad6) -----------------------
  # Frozen Freshop doubles, never the network. The founding double answers every request with the SAME first 100 rows
  # whatever page= or skip= says, as Freshop answered page= from 09-02 to 09-09; the honest double pages on skip=.
  function New-FfDouble([int]$Distinct, [int]$Total, [bool]$HonourSkip, [int]$FailOnRequest) {
    $st = @{ n = 0 }
    return {
      param($u)
      $st.n++
      if ($FailOnRequest -gt 0 -and $st.n -ge $FailOnRequest) { throw 'HTTP 400 {"error_code":429,"error":"Too Many Requests"}' }
      $skip = 0; $m = [regex]::Match([string]$u, '[?&]skip=(\d+)'); if ($HonourSkip -and $m.Success) { $skip = [int]$m.Groups[1].Value }
      $lim = 100; $lm = [regex]::Match([string]$u, '[?&]limit=(\d+)'); if ($lm.Success) { $lim = [Math]::Min(100, [int]$lm.Groups[1].Value) }
      $items = New-Object System.Collections.Generic.List[object]
      for ($i = $skip; $i -lt [Math]::Min($Distinct, $skip + $lim); $i++) { $items.Add([pscustomobject]@{ id = [string](1000 + $i); name = ('Product ' + $i); size = '1 Ea'; base_price = 2.0; sale_price = '$1.50' }) }
      return [pscustomobject]@{ total = $Total; items = $items.ToArray() }
    }.GetNewClosure()
  }
  $oldD = New-FfDouble 1045 1045 $false 0; $rowsOld = 0; $idsOld = @{}
  for ($pgN = 1; $pgN -le 11; $pgN++) { $respOld = & $oldD ('https://x/1/products?limit=200&page=' + $pgN); foreach ($it in $respOld.items) { $rowsOld++; $idsOld[[string]$it.id] = 1 } }
  _T 'MUST FIRE  the founding loop shape (limit=200&page=1..11) over a Freshop that ignores page= reads 1,100 rows from 100 unique ids' (($rowsOld -eq 1100) -and ($idsOld.Count -eq 100))
  $threw = ''; try { [void](Get-FreshopPages -Uri 'https://x/1/products?circular_id=1' -PageSize 100 -MaxRequests 15 -DelayMs 0 -Fetch (New-FfDouble 1045 1045 $false 0)) } catch { $threw = $_.Exception.Message }
  _T 'MUST FIRE  the pager over an endpoint that ignores skip= throws "added zero new ids" rather than counting a repeated page as progress' ($threw -match 'added zero new ids')
  $short = Get-FreshopPages -Uri 'https://x/1/products?circular_id=1' -PageSize 100 -MaxRequests 15 -DelayMs 0 -Fetch (New-FfDouble 100 1045 $true 0)
  _T 'MUST FIRE  a circular that stops at 100 of a stated 1,045 reports unique=100 total=1045 coverage 9.6 stop=empty-page' (($short.unique -eq 100) -and ($short.total -eq 1045) -and ($short.coverage_pct -eq 9.6) -and ($short.stop -eq 'empty-page'))
  $revShort = Get-CircularCoverageReview -Verification @([pscustomobject]@{ store = 'Family Fare'; status = 'PASS'; ad_unique = 100; ad_total = 1045; ad_pager_stop = 'empty-page' })
  _T 'MUST FIRE  the check-ad-cycles review names the short read: Family Fare circular read 100 of 1045' ((@($revShort) -join ' ') -match 'Family Fare circular read 100 of 1045')
  $full = Get-FreshopPages -Uri 'https://x/1/products?circular_id=1' -PageSize 100 -MaxRequests 15 -DelayMs 0 -Fetch (New-FfDouble 1045 1045 $true 0)
  _T 'CLEAN TWIN  a 1,045-row circular that pages on skip= is read whole: 1,045 unique in 11 requests, coverage 100, stop=complete' (($full.unique -eq 1045) -and ($full.requests -eq 11) -and ($full.coverage_pct -eq 100) -and ($full.stop -eq 'complete'))
  $revFull = Get-CircularCoverageReview -Verification @([pscustomobject]@{ store = 'Family Fare'; status = 'PASS'; ad_unique = 1045; ad_total = 1045; ad_pager_stop = 'complete' })
  _T 'MUST NOT FIRE  a complete circular read adds no REVIEW line' (@($revFull | Where-Object { $_ }).Count -eq 0)
  $thr = $null; $thrErr = ''; try { $thr = Get-FreshopPages -Uri 'https://x/1/products?circular_id=1' -PageSize 100 -MaxRequests 15 -DelayMs 0 -Fetch (New-FfDouble 1045 1045 $true 7) } catch { $thrErr = $_.Exception.Message }
  _T 'CLEAN TWIN  a throttle on request 7 (HTTP 400, error_code 429) stops the walk without throwing and keeps the 600 rows read, naming the status' (($thrErr -eq '') -and ($null -ne $thr) -and ($thr.unique -eq 600) -and ($thr.total -eq 1045) -and ($thr.stop -eq 'request-failed') -and ($thr.status -match '429'))
  $circs = @(
    [pscustomobject]@{ id = '3981377556770213679'; name = 'Week''s Ad Preview'; start_date = '2026-09-11T00:00:00-05:00'; finish_date = '2026-09-12T23:59:59-05:00' },
    [pscustomobject]@{ id = '3977578314389802074'; name = 'Current Ad'; start_date = '2026-09-06T00:00:00-05:00'; finish_date = '2026-09-12T23:59:59-05:00' }
  )
  $selT = Select-FreshopCircular -Circulars $circs -Today ([datetime]'2026-09-11')
  _T 'MUST FIRE  given the 2-day preview listed FIRST and the weekly ad second, as /1/circulars answered on 2026-09-11, the picker takes the weekly ad and logs both' (($null -ne $selT.pick) -and ([string]$selT.pick.id -eq '3977578314389802074') -and ($selT.current -eq 2) -and ($selT.log -match 'Preview') -and ($selT.log -match 'Current Ad.*PICKED'))
  $noneT = Select-FreshopCircular -Circulars @($circs[1]) -Today ([datetime]'2026-09-20')
  _T 'MUST NOT FIRE  with no circular current on the day there is no pick, so the store stays BLOCKED as not current' ($null -eq $noneT.pick)
  $revErr = Get-CircularCoverageReview -Verification @([pscustomobject]@{ store = 'Family Fare'; status = 'ERROR: Get-FreshopPages: the page at skip=100 added zero new ids'; deals = 0 })
  _T 'MUST FIRE  a Family Fare pull that ERRORED adds a REVIEW line rather than passing silently beside two PASS stores' ((@($revErr) -join ' ') -match 'Family Fare circular pull ERRORED')
  if ($fail -eq 0) { Write-Output "SELF-TEST PASS: $n case(s)"; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail of $n case(s)"; exit 1 }
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
