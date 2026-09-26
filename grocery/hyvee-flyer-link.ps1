<#
  hyvee-flyer-link.ps1 - SHADOW run of the Hy-Vee flyer-line linker (design/PLAN-flyer-line-product-link-2026-09-26.md).

  For every Hy-Vee flyer LINE on the board (the cells Test-TcFlyerLineNamesNoProduct marks unverifiable), propose
  candidates (Hy-Vee's search at the ruled store, plus the Hy-Vee product id product-urls.json holds for the
  commodity), read each ONCE through the same persisted GraphQL document pull-regular-hyvee.ps1 sends, and decide the
  link with hyvee-flyer-link-lib.ps1. Writes ONLY its own file, grocery/out/hyvee/flyer-links-<date>.jsonl: one row per
  (line, candidate) with the read, and one 'line' row per line with the decision. Every row carries mode=shadow.
  It writes no board, no cell, no ledger and no verdict, and nothing reads its file to change one.

  OFF SWITCH: stores.json -> Hy-Vee -> flyer_link. 'off' (or absent) exits 0 having asked nothing; 'live' is refused.
  Sessionless API, paced: -PaceMs between every request (default 1200).
  -CollectOnly   write the reads with no decision (so labels can be written before the linker runs on them).
  -EvidenceIn    decide from an earlier file's reads, with no network at all.
  Last line: FLYER-LINK-COMPLETE lines=N linked=M candidates=K read_ok=R.
#>
[CmdletBinding()]
param(
  [string]$Board = '',
  [string]$Out = '',
  [string]$EvidenceIn = '',
  [switch]$CollectOnly,
  [int]$PageSize = 8,
  [int]$PaceMs = 1200
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
. (Join-Path (Split-Path $root -Parent) 'lib\json-io.ps1')
. (Join-Path $root 'pu-lib.ps1')
. (Join-Path $root 'match-lib.ps1')
. (Join-Path $root 'global-exclude-lib.ps1')
. (Join-Path $root 'flag-verify-lib.ps1')
. (Join-Path $root 'hyvee-flyer-link-lib.ps1')
. (Join-Path $root 'hyvee-store-lib.ps1')

$mode = Get-TcFlyerLinkMode (Read-JsonFile (Join-Path $root 'stores.json'))
if ($mode -eq 'off') { Write-Output 'hyvee-flyer-link: stores.json Hy-Vee flyer_link is off - nothing asked, nothing written'; Write-Output 'FLYER-LINK-COMPLETE lines=0 linked=0 candidates=0 read_ok=0 mode=off'; exit 0 }

if (-not $Board) {
  $b = Get-ChildItem (Join-Path $root 'out') -Filter 'comparison-*.json' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
  if ($null -eq $b) { Write-Output 'hyvee-flyer-link: BLIND - no comparison board in this checkout'; exit 3 }
  $Board = $b.FullName
}
$today = (Get-Date).ToString('yyyy-MM-dd')
if (-not $Out) { $Out = Join-Path $root ('out\hyvee\flyer-links-' + $today + '.jsonl') }

# ---- the flyer lines ------------------------------------------------------------------------------------------------
$boardObj = Read-JsonFile $Board
$lines = New-Object System.Collections.Generic.List[object]
foreach ($c in @($boardObj.comparison)) {
  foreach ($s in @($c.stores)) {
    if ([string]$s.store -ne 'Hy-Vee' -or [string]$s.type -ne 'sale') { continue }
    $claim = [pscustomobject]@{ row_type = 'sale'; as_of = [string]$s.as_of; item = [string]$s.item }
    if (-not (Test-TcFlyerLineNamesNoProduct $claim)) { continue }
    $lines.Add([pscustomobject]@{ commodity = [string]$c.id; unit = [string]$c.unit; item = [string]$s.item; per_unit = [double]$s.per_unit; ad_from = [string]$s.ad_from; ad_to = [string]$s.ad_to })
  }
}
Write-Output ('hyvee-flyer-link: mode=' + $mode + ', board ' + (Split-Path $Board -Leaf) + ', ' + $lines.Count + ' flyer line(s)')

# ---- the reads: from the network, or from an earlier file -----------------------------------------------------------
$cands = @{}   # key: commodity|item -> list of candidate objects
if ($EvidenceIn) {
  foreach ($ln in [IO.File]::ReadAllLines($EvidenceIn, [Text.Encoding]::UTF8)) {
    if (-not $ln.Trim()) { continue }
    $r = $ln | ConvertFrom-Json
    if ([string]$r.kind -ne 'candidate') { continue }
    $k = [string]$r.commodity + '|' + [string]$r.line
    if (-not $cands.ContainsKey($k)) { $cands[$k] = New-Object System.Collections.Generic.List[object] }
    $cands[$k].Add($r)
  }
} else {
  $st = Get-HyVeeStore -Root $root
  $qFile = Join-Path $root 'hyvee\query-b64.txt'
  $QUERY = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(((Get-Content $qFile -Raw -Encoding UTF8) -replace '\s', '')))
  $UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148 Safari/537.36'
  $GQ = 'https://www.hy-vee.com/aisles-online/api/graphql/two-legged/getProductDetailsWithPrice'
  $SE = 'https://www.hy-vee.com/aisles-online/api/search/products'
  $GH = @{ 'content-type' = 'application/json'; 'x-operation-name' = 'getProductDetailsWithPrice'; 'apollographql-client-name' = 'aisles-online-web'; 'User-Agent' = $UA }
  $urls = Read-JsonFile (Join-Path $root 'product-urls.json')
  $commodities = Read-JsonFile (Join-Path $root 'commodities.json')
  $judge = New-TcIdentityJudge -Commodities $commodities -GlobalExclude ([string[]]@(Get-TcGlobalExclude))
  $readCache = @{}
  $searchFail = 0; $readThrew = 0

  function Invoke-HflSearch([string]$Term) {
    $h = @{ 'content-type' = 'application/json'; 'User-Agent' = $UA; 'x-hy-vee-correlation-id' = [guid]::NewGuid().ToString() }
    $body = @{ pageNumber = 1; pageSize = $PageSize; searchFilters = @(); searchTerm = $Term; sortDirection = 'RELEVANCE'; storeId = [int]$st.store_id; pageViewId = [guid]::NewGuid().ToString() } | ConvertTo-Json -Compress
    Start-Sleep -Milliseconds $PaceMs
    try { $res = Invoke-RestMethod -Uri $SE -Method Post -Headers $h -Body $body -TimeoutSec 25; return @($res.results) } catch { $script:searchFail++; return $null }
  }
  function Invoke-HflRead([int]$ProductId) {
    if ($readCache.ContainsKey($ProductId)) { return $readCache[$ProductId] }
    $body = @{ operationName = 'getProductDetailsWithPrice'; query = $QUERY; variables = @{ productId = $ProductId; storeId = [int]$st.store_id; locationIds = @([string]$st.location_id); pickupLocationHasLocker = $false; retailItemEnabled = $true; targeted = $false; foodHealthScoreEnabled = $false } } | ConvertTo-Json -Depth 6 -Compress
    Start-Sleep -Milliseconds $PaceMs
    $resp = $null; $err = ''
    try { $resp = Invoke-RestMethod -Uri $GQ -Method Post -Headers $GH -Body $body -TimeoutSec 20 } catch { $err = $_.Exception.Message; $script:readThrew++ }
    $oc = Resolve-TcHflOutcome $resp $err ([int]$st.store_id)
    $readCache[$ProductId] = [pscustomobject]@{ resp = $resp; oc = $oc }
    return $readCache[$ProductId]
  }
  function Resolve-TcHflOutcome($Response, [string]$LastError, [int]$TargetStoreId) {
    # The same four outcomes as pull-regular-hyvee.ps1's Resolve-HyVeeLookupOutcome (answered/other-store/empty/threw).
    if ($LastError -or $null -eq $Response) { return [pscustomobject]@{ outcome = 'threw'; offer = $null } }
    $all = @($Response.data.storeProducts.storeProducts)
    $hit = @($all | Where-Object { $null -ne $_ -and [int]$_.storeId -eq $TargetStoreId }) | Select-Object -First 1
    if ($hit) { return [pscustomobject]@{ outcome = 'answered'; offer = $hit } }
    $real = @($all | Where-Object { $null -ne $_ })
    if ($real.Count -gt 0) { return [pscustomobject]@{ outcome = 'other-store'; offer = $null } }
    return [pscustomobject]@{ outcome = 'empty'; offer = $null }
  }

  foreach ($L in $lines) {
    $parsed = ConvertFrom-TcFlyerLine $L.item
    $k = $L.commodity + '|' + $L.item
    $cands[$k] = New-Object System.Collections.Generic.List[object]
    $prop = [ordered]@{}   # product id -> { via, search hit }
    $family = ($L.item -split ',')[0]
    foreach ($alt in @($family -split '\s+or\s+')) {
      $term = (($alt -replace '(\d+(?:\.\d+)?|\.\d+)\s*(fl\.?\s*oz|oz|lbs?|ct|pk|ml)\.?', ' ') -replace '\s+', ' ').Trim()
      if (-not $term) { continue }
      $hits = Invoke-HflSearch $term
      foreach ($h in @($hits)) {
        if ($null -eq $h -or [string]$h.type -ne 'PRODUCT') { continue }
        $id = [string]$h.id
        if ($id -and -not $prop.Contains($id)) { $prop[$id] = [pscustomobject]@{ via = ('search: ' + $term); hit = $h } }
      }
    }
    $pu = $urls.items.PSObject.Properties[$L.commodity]
    if ($pu -and $pu.Value.PSObject.Properties['Hy-Vee']) {
      $m = [regex]::Match([string]$pu.Value.'Hy-Vee'.url, '/p/(\d+)/')
      if ($m.Success -and -not $prop.Contains($m.Groups[1].Value)) { $prop[$m.Groups[1].Value] = [pscustomobject]@{ via = 'product-urls.json'; hit = $null } }
    }
    foreach ($id in @($prop.Keys)) {
      $rd = Invoke-HflRead ([int]$id)
      $h = $prop[$id].hit
      $gname = if ($rd.resp -and $rd.resp.data.product) { [string]$rd.resp.data.product.item.description } else { '' }
      $gsize = if ($rd.resp -and $rd.resp.data.product) { ([string]$rd.resp.data.product.size).Trim() } else { '' }
      $name = if ($gname) { $gname } elseif ($h) { [string]$h.description } else { '' }
      $size = if ($gsize) { $gsize } elseif ($h) { [string]$h.unitOfMeasure } else { '' }
      $o = $rd.oc.offer
      $idv = (Test-TcStoreNameIdentity $judge $L.commodity @($name)).verdict
      $cands[$k].Add([pscustomobject][ordered]@{
        kind = 'candidate'; mode = $mode; read_day = $today; commodity = $L.commodity; line = $L.item; product_id = $id; via = $prop[$id].via
        name = $name; size_field = $size; read_outcome = $rd.oc.outcome; read_ok = ($rd.oc.outcome -eq 'answered')
        on_sale = if ($o) { [bool]$o.onSale } else { $false }; price = if ($o) { [double]$o.price } else { $null }
        price_multiple = if ($o) { [int]$o.priceMultiple } else { $null }; base_price = if ($o) { [double]$o.basePrice } else { $null }
        is_weighted = if ($o) { [bool]$o.isWeighted } else { $null }; identity = $idv
        search_name = if ($h) { [string]$h.description } else { '' }; search_uom = if ($h) { [string]$h.unitOfMeasure } else { '' }
        search_base = if ($h) { $h.pricing.basePriceValue } else { $null }; search_tag = if ($h) { $h.pricing.tagPriceValue } else { $null }
      })
    }
  }
  Write-Output ('hyvee-flyer-link: searches that failed ' + $searchFail + ', reads that threw ' + $readThrew + ', distinct products read ' + $readCache.Count)
}

# ---- decide (unless -CollectOnly) and write -----------------------------------------------------------------------
$dir = Split-Path $Out -Parent
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
$sb = New-Object System.Text.StringBuilder
$nLinked = 0; $nCand = 0; $nRead = 0
foreach ($L in $lines) {
  $k = $L.commodity + '|' + $L.item
  $cs = if ($cands.ContainsKey($k)) { $cands[$k].ToArray() } else { @() }
  foreach ($c in $cs) { $nCand++; if ($c.read_ok) { $nRead++ }; [void]$sb.Append(($c | ConvertTo-Json -Compress -Depth 4)).Append("`n") }
  if ($CollectOnly) { continue }
  $parsed = ConvertFrom-TcFlyerLine $L.item
  $res = Resolve-TcFlyerLink -Line $parsed -Candidates $cs -CellPerUnit $L.per_unit -Unit $L.unit
  if ($res.linked) { $nLinked++ }
  $row = [ordered]@{ kind = 'line'; mode = $mode; commodity = $L.commodity; line = $L.item; unit = $L.unit; cell_per_unit = $L.per_unit
    ad_from = $L.ad_from; ad_to = $L.ad_to; linked = $res.linked; reason = $res.reason; candidates = @($cs).Count; decisions = @($res.rows) }
  [void]$sb.Append(([pscustomobject]$row | ConvertTo-Json -Compress -Depth 5)).Append("`n")
}
[IO.File]::WriteAllText($Out, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
Write-Output ('hyvee-flyer-link: wrote ' + $Out)
Write-Output ('FLYER-LINK-COMPLETE lines=' + $lines.Count + ' linked=' + $(if ($CollectOnly) { 'not-decided' } else { $nLinked }) + ' candidates=' + $nCand + ' read_ok=' + $nRead + ' mode=' + $mode)
exit 0
