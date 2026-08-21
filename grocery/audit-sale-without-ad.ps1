<#
  audit-sale-without-ad.ps1 - every cell we publish as a SALE that we cannot trace to an ad.

  BRAD'S RULE (2026-08-21): "if an item has a sale price, it MUST of been on some ad previously...
  If you have an example of an item showing a 'sale price' but not on any ad, give me some item URLs
  for me to review." And then: "Items that we show on 'sale' but no matching 'ad' keep note of."

  WHY A LEDGER AND NOT A ONE-OFF LIST. A sale we cannot trace is not automatically wrong - a store
  can cut a shelf price without putting it in the flyer, and Fareway's own product page says exactly
  that (on_sale: true, retailer: false, promotionGroupId: null). But it is the one class we cannot
  DATE, so it is also the class that cannot expire on its own, and under a 90-day carry that is how a
  finished sale keeps publishing. Counting them once tells you today's number; keeping the note tells
  you WHICH ones have been unexplained for weeks, which is the actual signal.

  FIRST_SEEN IS WRITTEN ONCE AND NEVER RE-STAMPED, the same discipline as rollback-ttl-lib: an
  age that resets every run measures nothing. days_unexplained is what makes a long-lived untraceable
  sale visible, and it can only be honest if the anchor holds still.

  WHAT COUNTS AS "AN AD". Every ad source the estate actually has, not just the server feed:
      out\ads-<date>.json                Hy-Vee (three concurrent flyers), Aldi, Family Fare
      out\fareway\fareway-deals-*.json   Fareway weekly + monthly, vision-read from the JPGs
      out\bakers\bakers-deals-*.json     Baker's flyer, vision-read
  Comparing Fareway against ads-*.json alone compares it against ZERO rows and reports every Fareway
  sale as untraceable - which is exactly the mistake this script exists to stop anyone repeating.

  MATCHING IS DELIBERATELY GENEROUS. A false "found in the ad" costs nothing here (the cell is dated
  from the ad anyway); a false "not in any ad" puts a real item on Brad's review list and wastes his
  time. So two shared distinctive words is enough, and the stop-list drops the words every ad row
  carries ("fresh", "select varieties", the store's own name).

  Advisory, never blocking: this reports a question, not a defect.
  Usage: audit-sale-without-ad.ps1 [-OutDir <dir>] [-Quiet]
#>
param([string]$OutDir = '', [switch]$Quiet)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
. (Join-Path (Split-Path $root -Parent) 'lib\guard-contract.ps1')

$cmpFile = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if (-not $cmpFile) { Write-Output 'sale-without-ad: no comparison board found'; Write-GuardComplete -Name 'sale-without-ad' -Summary 'BLIND: no board'; exit 3 }
$cmp = Get-Content $cmpFile.FullName -Raw | ConvertFrom-Json
$today = [string]$cmp.week_of

# ---- every ad row we hold, from every source ------------------------------------------------
$adRows = New-Object System.Collections.Generic.List[object]
$adsFile = Get-ChildItem (Join-Path $OutDir 'ads-*.json') -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if ($adsFile) { foreach ($d in (Get-Content $adsFile.FullName -Raw | ConvertFrom-Json).deals) { [void]$adRows.Add([pscustomobject]@{ store=[string]$d.store; item=[string]$d.item }) } }
foreach ($lane in @('fareway','bakers')) {
  $dir = Join-Path $OutDir $lane
  if (-not (Test-Path $dir)) { continue }
  foreach ($f in (Get-ChildItem (Join-Path $dir '*-deals-*.json') -EA SilentlyContinue)) {
    try { $doc = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
    foreach ($d in @($doc.deals)) { [void]$adRows.Add([pscustomobject]@{ store=([string]$d.store); item=[string]$d.item }) }
  }
}
$adByStore = @{}
foreach ($a in $adRows) { if (-not $a.store) { continue }; if (-not $adByStore.ContainsKey($a.store)) { $adByStore[$a.store] = New-Object System.Collections.Generic.List[object] }; [void]$adByStore[$a.store].Add($a.item) }

$STOP = @('fresh','hyvee','fareway','with','from','each','pack','size','count','select','varieties','assorted','your','choice','when','more','less','spend','save','kroger','simply','great','value')
function Get-Toks([string]$s) {
  $t = ($s -replace '[^A-Za-z0-9 ]',' ').ToLower() -split '\s+'
  return @($t | Where-Object { $_.Length -gt 3 -and $STOP -notcontains $_ })
}
$adTok = @{}
foreach ($k in $adByStore.Keys) {
  # -ArgumentList (,$arr) IS LOAD-BEARING in PS 5.1: New-Object UNROLLS an array argument into
  # separate constructor parameters, so a 3-token name looks for a HashSet ctor taking 3 args and
  # throws. The unary comma wraps it back into a single argument. Same family as the @() traps this
  # estate keeps hitting.
  # HashSet<string> has several one-argument constructors (IEnumerable<string>, IEqualityComparer,
  # int capacity) and PS 5.1 cannot pick between them from a [string[]], so New-Object reports
  # "multiple ambiguous overloads". Construct it empty and fill it - unambiguous, and the intent is
  # clearer than a cast that happens to bind.
  $adTok[$k] = @($adByStore[$k] | ForEach-Object {
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($w in (Get-Toks $_)) { [void]$set.Add($w) }
    ,$set
  })
}

# ---- product links, so a finding is reviewable ------------------------------------------------
$purl = @{}
try {
  $pd = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items
  foreach ($p in $pd.PSObject.Properties) {
    foreach ($sp in $p.Value.PSObject.Properties) {
      if ($sp.Name -eq 'commodity' -or -not $sp.Value.url) { continue }
      $purl[([string]$p.Name + '|' + [string]$sp.Name)] = [string]$sp.Value.url
    }
  }
} catch { }

# ---- prior ledger, for first_seen continuity ---------------------------------------------------
$ledgerFile = Join-Path $root 'sale-without-ad.json'
$prior = @{}
if (Test-Path $ledgerFile) {
  try { foreach ($e in (Get-Content $ledgerFile -Raw | ConvertFrom-Json).items) { $prior[[string]$e.key] = $e } } catch { }
}

$found = New-Object System.Collections.Generic.List[object]
$traced = 0; $datedAlready = 0; $saleCells = 0
foreach ($c in $cmp.comparison) {
  foreach ($s in $c.stores) {
    if ([string]$s.type -ne 'sale') { continue }
    $saleCells++
    # A cell the STORE dated is not untraceable - we know when it ends, which is the whole point.
    if ([string]$s.ad_from -match '^\d{4}-\d{2}-\d{2}$' -and [string]$s.ad_to -match '^\d{4}-\d{2}-\d{2}$') { $datedAlready++; continue }
    $store = [string]$s.store
    $ut = Get-Toks ([string]$s.item)
    if (-not $ut.Count) { continue }
    $need = if ($ut.Count -ge 3) { 2 } else { 1 }
    $hit = $false
    if ($adTok.ContainsKey($store)) {
      foreach ($set in $adTok[$store]) {
        $n = 0; foreach ($w in $ut) { if ($set.Contains($w)) { $n++; if ($n -ge $need) { break } } }
        if ($n -ge $need) { $hit = $true; break }
      }
    }
    if ($hit) { $traced++; continue }
    $key = "$store|$($c.id)"
    $fseen = if ($prior.ContainsKey($key) -and $prior[$key].first_seen) { [string]$prior[$key].first_seen } else { $today }
    $days = 0
    try { $days = [int]((([datetime]$today) - ([datetime]$fseen)).TotalDays) } catch { }
    # [pscustomobject], not [ordered]: Group-Object and Sort-Object read PROPERTIES, and an ordered
    # dictionary has none - it groups everything under one blank key and reports the whole set as a
    # single nameless bucket, which is what the first run of this printed.
    [void]$found.Add([pscustomobject][ordered]@{
      key = $key; id = [string]$c.id; store = $store; item = [string]$s.item
      price = [string]$s.ad; per_unit = $s.per_unit; unit = [string]$c.unit
      url = $(if ($purl.ContainsKey("$($c.id)|$store")) { $purl["$($c.id)|$store"] } else { '' })
      first_seen = $fseen; last_seen = $today; days_unexplained = $days
    })
  }
}

$doc = [ordered]@{
  updated = (Get-Date).ToString('s'); board = $cmpFile.Name; week_of = $today
  note = 'Cells published as a SALE that match no row in any ad we hold. Not automatically wrong - a store may cut a shelf price without advertising it (Fareway''s own product page reports on_sale:true with retailer:false and no promotionGroupId) - but this is the class we cannot DATE, so it is the class that cannot expire on its own. first_seen is written once and never re-stamped; days_unexplained is only meaningful because of that.'
  sale_cells = $saleCells; dated_by_the_store = $datedAlready; traced_to_an_ad = $traced; untraceable = $found.Count
  ad_rows_available = (@($adByStore.Keys | ForEach-Object { "$_=$($adByStore[$_].Count)" }) -join ' ')
  items = @($found | Sort-Object -Property @{e={$_.days_unexplained}; Descending=$true}, @{e={$_.store}}, @{e={$_.id}})
}
$tmp = "$ledgerFile.tmp"
[IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
Move-Item -LiteralPath $tmp -Destination $ledgerFile -Force

if (-not $Quiet) {
  Write-Output ("sale-without-ad  -  " + $today)
  Write-Output ("  sale cells " + $saleCells + " | dated by the store " + $datedAlready + " | traced to an ad " + $traced + " | UNTRACEABLE " + $found.Count)
  Write-Output ("  ad rows held: " + $doc.ad_rows_available)
  foreach ($g in ($found | Group-Object store | Sort-Object Count -Descending)) {
    Write-Output ("   {0,-13} {1}" -f $g.Name, $g.Count)
  }
  $old = @($found | Where-Object { $_.days_unexplained -ge 7 })
  if ($old.Count) {
    Write-Output ''
    Write-Output ("  UNEXPLAINED FOR A WEEK OR MORE (" + $old.Count + ") - a sale nobody can date, still publishing:")
    foreach ($o in ($old | Select-Object -First 12)) { Write-Output ("   {0,3}d  {1,-13} {2,-26} {3}" -f $o.days_unexplained, $o.store, $o.id, $o.url) }
  }
  Write-Output ("  -> " + $ledgerFile)
}
Write-GuardComplete -Name 'sale-without-ad' -Summary "sale=$saleCells traced=$traced untraceable=$($found.Count)"
exit 0
