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
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
. (Join-Path (Split-Path $root -Parent) 'lib\guard-contract.ps1')

$cmpFile = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if (-not $cmpFile) { Write-Output 'sale-without-ad: no comparison board found'; Write-GuardComplete -Name 'sale-without-ad' -Summary 'BLIND: no board'; exit 3 }
$cmp = Read-JsonFile $cmpFile.FullName
$today = [string]$cmp.week_of

# ---- every ad row we hold, from every source, via the SHARED matcher -------------------------
# THE MATCH RULE LIVES IN ad-match-lib.ps1, not here. compare-deals needs the identical decision in
# order to INHERIT an ad's window onto an undated sale cell, and two copies of "did this cell come
# from that ad row?" would drift the way every duplicated rule in this estate has.
# The first version of this audit carried its own copy and got it wrong in a way that mattered: it
# demanded two shared distinctive words, which a terse ad line can never satisfy - "Hy-Vee butter,
# 16 oz., $2.48" reduces to the single token `butter` once the store name, the digits and the unit
# are stripped. Hy-Vee's butter therefore read as untraceable while sitting in the 3 Day Sale flyer
# at exactly the price the board was publishing. Brad found it by looking at the ad.
. (Join-Path $root 'ad-match-lib.ps1')
# -IncludeExpired: this audit asks "was it EVER advertised", which is Brad's "must of been on some
# ad PREVIOUSLY". A sale that began in last week's flyer and is still running is traceable, not
# unexplained. The engine's inheritance uses the live-only pool - see ad-match-lib's header.
$adIndex = Import-AdRows -OutDir $OutDir -BoardDate $today -IncludeExpired

# ---- product links, so a finding is reviewable ------------------------------------------------
$purl = @{}
try {
  $pd = (Read-JsonFile (Join-Path $root 'product-urls.json')).items
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
  try { foreach ($e in (Read-JsonFile $ledgerFile).items) { $prior[[string]$e.key] = $e } } catch { }
}

$found = New-Object System.Collections.Generic.List[object]
$traced = 0; $datedAlready = 0; $saleCells = 0
foreach ($c in $cmp.comparison) {
  foreach ($s in $c.stores) {
    if ([string]$s.type -ne 'sale') { continue }
    $saleCells++
    # A cell the STORE dated is not untraceable - we know when it ends, which is the whole point.
    # BUT A TTL-DATED CELL IS NOT STORE-DATED. Once the engine began stamping a 30-day TTL onto
    # undated Fareway/Walmart/Sam's markdowns, those cells started carrying ad_from/ad_to too - and a
    # date test alone would have quietly reclassified all 372 of them as "dated by the store" and
    # dropped them off this list. That would have deleted the review list at the exact moment it
    # became most useful: a TTL is our guess, and a guess is precisely what wants reviewing.
    # ad_basis says which: 'store' (its own feed), 'ad' (traced to a flyer), 'ttl' (ours).
    $basis = [string]$s.ad_basis
    $hasWindow = ([string]$s.ad_from -match '^\d{4}-\d{2}-\d{2}$' -and [string]$s.ad_to -match '^\d{4}-\d{2}-\d{2}$')
    if ($hasWindow -and $basis -ne 'ttl') { $datedAlready++; continue }
    $store = [string]$s.store
    # Price + one shared distinctive word, OR two shared words. See ad-match-lib's header for why
    # the second rule alone can never match a terse ad line.
    $hitRow = Find-AdForCell -Index $adIndex -Store $store -Item ([string]$s.item) -PriceText ([string]$s.ad)
    if ($hitRow) { $traced++; continue }
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
  ad_rows_available = (@($adIndex.Keys | Sort-Object | ForEach-Object { "$_=$($adIndex[$_].Count)" }) -join ' ')
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

