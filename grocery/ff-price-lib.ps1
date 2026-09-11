<#
  ff-price-lib.ps1 - the ONE rule for turning a Freshop product row into the price a shopper pays today.

  WHY IT IS A LIB. Two callers now read Freshop: pull-regular-familyfare.ps1 (the 3-hourly sweep that feeds
  the board) and probe-ingredient.ps1 (the Recipe Hunter's targeted single-term probe). Both have to make
  the same call about the same field, and a second inline copy is how a corrected rule ships to one caller
  and not the other. This file is the authority; callers dot-source it.

  THE TWO RULES, BOTH PAID FOR IN PRODUCTION:

  1. READ `price`, NOT `base_price`. base_price is the REGULAR price; price is what the store charges today.
     Reading base_price first is the bug that had the board publishing Hy-Vee sirloin at $13.99/lb while
     Omaha #01 charged $11.99, and Baker's chicken breast at $2.89/lb against a real $2.29. Freshop happened
     to return the two fields identical for all 375 Family Fare products sampled 2026-07-14, so it was
     harmless - and a loaded gun. The day Freshop populates a markdown into `price`, the old order quietly
     publishes the regular price and nothing downstream catches it.

  2. A MULTI-BUY OFFER IS NOT A PRICE. DROP IT, DO NOT FLIP IT. Freshop returns offers as text: "4 for
     $5.00". Stripping non-digits yields "45.00", so the row publishes at $45. Measured 2026-07-31: 28 of
     3,856 Family Fare rows carried a price built exactly that way, and one was LIVE ON THE BOARD -
     ground-cloves at Family Fare, 1.25 oz, ad $45, which the engine correctly divided into $36.00/oz
     against a real cheapest of $1.09/oz. No price band, no guard and no audit blinked, because $45 for a
     spice jar is absurd but not arithmetically impossible.
     Freshop's own row says base_price=5.0 and unit_price=1.25, so the OFFER costs $5.00 and one jar inside
     it works out at $1.25. Neither number says what ONE jar costs a shopper who does not buy four, and
     "4 for $5.00" is very often must-buy-four. Two readings, no way to choose: the honest output is NO ROW.
     If a later pass proves Family Fare honours the single price, read unit_price here and require
     n * unit_price to reconcile with base_price before trusting it. Do not simply divide.

  Returns $null when the row must be dropped. $null means "no honest price", never "free".

  Usage:
    . ff-price-lib.ps1
    $p = Get-FfPrice $item        # $null = drop this row
    .\ff-price-lib.ps1 -FfPriceSelfTest

  THE SWITCH IS NOT CALLED -SelfTest, AND THAT IS DELIBERATE (2026-08-15).
  Dot-sourcing runs the dot-sourced file's param() block IN THE CALLER'S SCOPE. A lib declaring
  `param([switch]$SelfTest)` therefore RESETS the caller's own $SelfTest to $false the moment it is
  dot-sourced. That is not theoretical: adding this lib to pull-regular-familyfare.ps1 silently disarmed
  that script's `if ($SelfTest)` guard, so `pull-regular-familyfare.ps1 -SelfTest` skipped its hermetic
  self-test and ran a LIVE Freshop pull instead - burning the term budget and looking, from the outside,
  like a self-test that simply printed a lot. Any name a caller might also use is unsafe here; this one is
  namespaced so it cannot collide.
#>
param([switch]$FfPriceSelfTest)

function Get-FfPrice($Item) {
  if (-not $Item) { return $null }
  $priceText = [string]$Item.price
  # rule 2: multi-buy offer text is not a unit price
  if ($priceText -and $priceText.Contains(' for ')) { return $null }
  # rule 1: current price wins; regular price is the fallback, never the default
  $cur = 0.0;  [void][double]::TryParse(($priceText -replace '[^0-9.]', ''), [ref]$cur)
  $base = 0.0; [void][double]::TryParse((([string]$Item.base_price) -replace '[^0-9.]', ''), [ref]$base)
  $val = $cur
  if ($val -le 0) { $val = $base }
  if ($val -le 0) { return $null }
  return [double]$val
}

# ---- 3. A FRESHOP PAGE IS ONLY PROGRESS IF IT BRINGS NEW IDS (2026-09-11, queue 2026-09-10-fa6ad6) ------------
# Both Freshop callers planned their pages from their own `limit` and `page=` and took a 200 carrying a correct
# `total` as a complete read. Freshop CLAMPS limit to 100 on /products and IGNORES page= and offset=; skip= is the
# pager. So pull-grocery-ads.ps1 asked limit=200&page=1..11, got the same 100 circular rows eleven times and
# recorded 1,100 verified Family Fare deals on every ad file from 09-02 to 09-09 (100 unique each), while 945 of
# the 1,045 weekly-ad rows (90.4%) never reached the board. Probed live 2026-09-11 10:15, 3 requests: skip=100
# returned 100 rows, none of them among the 100 the estate held.
# Get-FreshopPages walks skip= at the page size Freshop honours, dedupes by id, and cannot report a repeated page
# as progress: a page that adds ZERO new ids THROWS, because that is the founding bug and a loop that keeps going
# turns duplicates into deals. A request that FAILS (Freshop answers its throttle as HTTP 400 carrying
# error_code 429, measured near request 67 in one window) STOPS the walk and returns what was read with the
# status: a partial ad is real prices with a loud count, never a refusal. -Fetch lets a frozen double stand in
# for the network; -DelayMs keeps live pacing at or above 2.5 s between calls.
function Get-FreshopErrorText($ErrorRecord) {
  $code = ''; $body = ''
  try { $resp = $ErrorRecord.Exception.Response; if ($resp) { $code = [string][int]$resp.StatusCode } } catch { }
  try { if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { $body = [string]$ErrorRecord.ErrorDetails.Message } } catch { }
  $head = ''; if ($code) { $head = 'HTTP ' + $code }
  return ((@($head, $body, [string]$ErrorRecord.Exception.Message) -join ' ') -replace '\s+', ' ').Trim()
}
function Get-FreshopPages {
  param(
    [Parameter(Mandatory)][string]$Uri,
    [int]$PageSize = 100,
    [int]$MaxRequests = 15,
    [int]$DelayMs = 3000,
    [scriptblock]$Fetch = $null,
    [hashtable]$Headers = @{ 'User-Agent' = 'Mozilla/5.0' }
  )
  $rows = New-Object System.Collections.Generic.List[object]
  $seen = @{}
  $total = -1; $requests = 0; $stop = ''; $status = ''
  $sep = '?'; if ($Uri.Contains('?')) { $sep = '&' }
  while ($true) {
    if ($requests -ge $MaxRequests) { $stop = 'max-requests'; break }
    $skip = $requests * $PageSize
    $u = $Uri + $sep + 'limit=' + $PageSize + '&skip=' + $skip
    if ($requests -gt 0 -and $DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
    $requests++
    $resp = $null
    try {
      if ($Fetch) { $resp = & $Fetch $u } else { $resp = Invoke-RestMethod -Uri $u -Headers $Headers -TimeoutSec 30 }
    } catch {
      $status = Get-FreshopErrorText $_
      $stop = 'request-failed'
      break
    }
    if ($null -ne $resp -and $null -ne $resp.total) { $total = [int]$resp.total }
    $items = @()
    if ($null -ne $resp -and $null -ne $resp.items) { $items = @($resp.items) }
    if ($items.Count -eq 0) { $stop = 'empty-page'; break }
    $added = 0
    foreach ($it in $items) {
      if ($null -eq $it) { continue }
      $key = [string]$it.id
      if (-not $key) { $key = 'name:' + [string]$it.name + '|' + [string]$it.size }
      if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $rows.Add($it); $added++ }
    }
    if ($added -eq 0) { throw ('Get-FreshopPages: the page at skip=' + $skip + ' added zero new ids (' + $items.Count + ' row(s), every one already read) - the endpoint is not honouring skip=, and a repeated page is not progress') }
    if ($total -ge 0 -and $rows.Count -ge $total) { $stop = 'complete'; break }
  }
  $cov = $null; if ($total -gt 0) { $cov = [math]::Round(100.0 * $rows.Count / $total, 1) }
  return [pscustomobject]@{ rows = $rows.ToArray(); unique = $rows.Count; total = $total; requests = $requests; stop = $stop; status = $status; coverage_pct = $cov }
}

# ---- 4. THE WEEKLY AD IS THE CURRENT CIRCULAR WITH THE WIDEST WINDOW (2026-09-11, queue 2026-09-10-fa6ad6) ----
# /1/circulars listed TWO current circulars on 2026-09-11, 'Week's Ad Preview' 09-11..09-12 FIRST and 'Current Ad'
# 09-06..09-12 second, and pull-grocery-ads.ps1 took Select-Object -First 1, so the next pull could read the 2-day
# preview as the week's ad. Every current circular goes to the log; the pick is the widest window, the earliest
# start on a tie. Dates parse exactly as pull-grocery-ads' Test-Current parses them.
function Select-FreshopCircular {
  param($Circulars, [datetime]$Today)
  $cur = New-Object System.Collections.Generic.List[object]
  foreach ($c in @($Circulars)) {
    if ($null -eq $c) { continue }
    try { $f = ([DateTimeOffset]::Parse([string]$c.start_date)).Date; $t = ([DateTimeOffset]::Parse([string]$c.finish_date)).Date } catch { continue }
    if ($Today.Date -lt $f -or $Today.Date -gt $t) { continue }
    $cur.Add([pscustomobject]@{ circular = $c; days = ($t - $f).TotalDays; start = $f; id = [string]$c.id; name = [string]$c.name; window = ($f.ToString('yyyy-MM-dd') + '..' + $t.ToString('yyyy-MM-dd')) })
  }
  $pick = $null
  foreach ($x in $cur) { if ($null -eq $pick -or $x.days -gt $pick.days -or ($x.days -eq $pick.days -and $x.start -lt $pick.start)) { $pick = $x } }
  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($x in $cur) { $mark = ''; if ($null -ne $pick -and $x.id -eq $pick.id) { $mark = ' PICKED' }; $parts.Add("'" + $x.name + "' " + $x.window + ' id=' + $x.id + $mark) }
  $chosen = $null; if ($null -ne $pick) { $chosen = $pick.circular }
  return [pscustomobject]@{ pick = $chosen; current = $cur.Count; log = ($parts.ToArray() -join '; ') }
}

# ---- 5. A SHORT OR FAILED CIRCULAR READ SPEAKS (2026-09-11, queue 2026-09-10-fa6ad6) ----------------------------
# check-ad-cycles reads today's verification records through this and adds a REVIEW line to its summary for a store
# whose circular walk read fewer unique rows than the store's own total, or a Family Fare pull that ERRORED (the
# pager throws when Freshop stops honouring skip=). The rows read still ship; nothing may read a short ad as whole.
function Get-CircularCoverageReview {
  param($Verification)
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($v in @($Verification)) {
    if ($null -eq $v) { continue }
    $store = [string]$v.store
    if ($store -eq 'Family Fare' -and ([string]$v.status) -like 'ERROR*') { $lines.Add('REVIEW    Family Fare circular pull ERRORED, so no Family Fare ad row reached today''s board: ' + [string]$v.status); continue }
    $names = @($v.PSObject.Properties | ForEach-Object { $_.Name })
    if ($names -notcontains 'ad_total') { continue }
    $tot = 0; [void][int]::TryParse([string]$v.ad_total, [ref]$tot)
    $uni = 0; [void][int]::TryParse([string]$v.ad_unique, [ref]$uni)
    if ($tot -le 0 -or $uni -ge $tot) { continue }
    $pct = [math]::Round(100.0 * $uni / $tot, 1)
    $lines.Add('REVIEW    ' + $store + ' circular read ' + $uni + ' of ' + $tot + ' rows (' + $pct + '% coverage; the walk stopped: ' + [string]$v.ad_pager_stop + ') - the rows read still ship, the rest of the ad is missing from today''s board')
  }
  return $lines.ToArray()
}
if ($FfPriceSelfTest) {
  $bad = 0
  function T($label, $got, $want) {
    $ok = ($null -eq $want -and $null -eq $got) -or ($null -ne $want -and $null -ne $got -and [math]::Abs($got - $want) -lt 0.0001)
    if (-not $ok) { Write-Output ("  X {0}: got {1}, want {2}" -f $label, $(if ($null -eq $got) { 'null' } else { $got }), $(if ($null -eq $want) { 'null' } else { $want })); $script:bad++ }
  }
  # MUST-FIRE: the founding bug, frozen. ground-cloves @ Family Fare, live on the board at $45.
  T 'multi-buy "4 for $5.00" is dropped' (Get-FfPrice ([pscustomobject]@{ price = '4 for $5.00'; base_price = 5.0 })) $null
  T 'multi-buy "3 for $5.00" is dropped' (Get-FfPrice ([pscustomobject]@{ price = '3 for $5.00'; base_price = 5.0 })) $null
  T 'multi-buy "2 for $3.00" is dropped' (Get-FfPrice ([pscustomobject]@{ price = '2 for $3.00'; base_price = 3.0 })) $null
  # CLEAN TWINS: ordinary rows still price
  T 'plain current price'      (Get-FfPrice ([pscustomobject]@{ price = '$3.59'; base_price = 3.59 })) 3.59
  T 'current beats regular'    (Get-FfPrice ([pscustomobject]@{ price = '$2.29'; base_price = 2.89 })) 2.29
  T 'falls back to base'       (Get-FfPrice ([pscustomobject]@{ price = '';      base_price = 4.19 })) 4.19
  T 'numeric price field'      (Get-FfPrice ([pscustomobject]@{ price = 5.0;     base_price = 6.0  })) 5.0
  # no honest price is null, not zero
  T 'no price at all -> null'  (Get-FfPrice ([pscustomobject]@{ price = ''; base_price = 0 })) $null
  T 'null item -> null'        (Get-FfPrice $null) $null
  if ($bad -eq 0) { Write-Output 'ff-price-lib SELF-TEST PASS (multi-buy dropped, current beats regular, no-price is null)'; exit 0 }
  Write-Output ("ff-price-lib SELF-TEST FAIL ({0} problem(s))" -f $bad); exit 1
}
