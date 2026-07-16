<#
  audit-tile-integrity.ps1 - BRAD'S INVARIANT, as one number.

    "There should be no tile that has a price and item name and no link, and the price and item name need to
     match the link 100%."

  Every PRICED tile must satisfy all three:
     LINKED   it has a See-item link at all
     SAME-PRODUCT  the link opens the product the board named (not a different brand/size/form)
     SAME-PRICE    the link's per-unit equals the board's per-unit

  Until now this was spread across three audits with three scopes - consistency-report (no_link + mismatch),
  name-drift (wrong product), guard 4 (factor). Three numbers nobody could hold to one bar. This is the single
  score, per store, with every violation named.

  TWO DIFFERENT PROMISES, TWO DIFFERENT GATES. Lumping these into one number hid the thing that matters:

    ACCURACY  (WRONG-PRODUCT, PRICE-MISMATCH, LINK-UNPRICEABLE, LINK-NO-PRICE)
              A link that ships opens something other than what we advertised. This LIES to a shopper - they
              click "See item", land on a different product or price, and conclude the board inflates deals.
              It is never acceptable and it is fixable without anyone's browser, by REMOVING the link.
              -> HARD GATE. Must be zero. prune-bad-links keeps it there.

    COVERAGE  (NO-LINK)
              A tile shows a price with no "See item" link. Incomplete, not dishonest: the price is still the
              store's own, verified by guards 9/10. Closing these needs paced per-store browser passes.
              -> RATCHET against out\tile-integrity-baseline.json. May only go down.

  A wrong link is strictly worse than no link, so ACCURACY is bought by spending COVERAGE, and this split is
  what lets that trade be made deliberately instead of accidentally. Before the split, pruning a bad link made
  the single score look WORSE - the gate actively discouraged the honest fix.

  Exit: 0 = accuracy clean and no store regressed on coverage. 2 = ANY accuracy violation, or coverage regressed.
#>
param(
  [string]$OutDir = "",
  [switch]$Baseline,   # write the current counts as the high-water mark
  [switch]$Strict,     # ANY violation fails - the end state
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
. (Join-Path $root 'pu-lib.ps1')   # the SAME per-unit math the page publishes with

$cmpF = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1)
$cmp = (Get-Content $cmpF.FullName -Raw | ConvertFrom-Json).comparison
$pu = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items
$drift = @{}
$ndF = Join-Path $OutDir 'name-drift.json'
if (Test-Path $ndF) { foreach ($d in (Get-Content $ndF -Raw | ConvertFrom-Json).flags) { $drift[([string]$d.id + '|' + [string]$d.store)] = [string]$d.reason } }

$rows = New-Object System.Collections.Generic.List[object]
foreach ($r in $cmp) {
  $id = [string]$r.id; $unit = [string]$r.unit
  foreach ($s in $r.stores) {
    $st = [string]$s.store
    $bpu = [double]$s.per_unit
    if ($bpu -le 0) { continue }                      # not a priced tile
    $lnk = $pu.$id.$st
    if (-not $lnk -or -not $lnk.url) {
      $rows.Add([pscustomobject]@{ id = $id; store = $st; fault = 'NO-LINK'; detail = 'priced tile with no See-item link'; board = [string]$s.item; link = '' }); continue
    }
    if ($drift.ContainsKey($id + '|' + $st)) {
      $rows.Add([pscustomobject]@{ id = $id; store = $st; fault = 'WRONG-PRODUCT'; detail = $drift[$id + '|' + $st]; board = [string]$s.item; link = [string]$lnk.name }); continue
    }
    # price agreement: a SALE cell is legitimately below its link's shelf price, so only EVERYDAY cells are held
    # to price equality. (That exemption is also how the stale-markdown bug hid - guard 8 covers that class.)
    if (([string]$s.type) -ne 'everyday') { continue }
    $sp = 0.0; [void][double]::TryParse((([string]$lnk.price) -replace '[^0-9.]', ''), [ref]$sp)
    if ($sp -le 0) {
      $rows.Add([pscustomobject]@{ id = $id; store = $st; fault = 'LINK-NO-PRICE'; detail = 'link carries no price to compare'; board = [string]$s.item; link = [string]$lnk.name }); continue
    }
    $lpu = Get-LinkPerUnit -size ([string]$lnk.size) -unit $unit -price $sp -name ([string]$lnk.name)
    if ($null -eq $lpu -or $lpu -le 0) {
      $rows.Add([pscustomobject]@{ id = $id; store = $st; fault = 'LINK-UNPRICEABLE'; detail = ('link size "' + [string]$lnk.size + '" gives no per-unit in ' + $unit); board = [string]$s.item; link = [string]$lnk.name }); continue
    }
    $off = [math]::Abs($lpu - $bpu) / $lpu
    # half a cent absolute OR 2% - a store's own cent-rounded unit price is not a mismatch
    if ($off -gt 0.02 -and [math]::Abs($lpu - $bpu) -gt 0.005) {
      $rows.Add([pscustomobject]@{ id = $id; store = $st; fault = 'PRICE-MISMATCH'; detail = ('board $' + [math]::Round($bpu, 4) + ' vs link $' + [math]::Round($lpu, 4) + '  (' + [math]::Round($off * 100, 1) + '% off)'); board = [string]$s.item; link = [string]$lnk.name })
    }
  }
}

# priced tiles per store, for the score
$tiles = @{}
foreach ($r in $cmp) { foreach ($s in $r.stores) { if ([double]$s.per_unit -gt 0) { $k = [string]$s.store; if (-not $tiles.ContainsKey($k)) { $tiles[$k] = 0 }; $tiles[$k]++ } } }
$bad = @{}
foreach ($x in $rows) { if (-not $bad.ContainsKey($x.store)) { $bad[$x.store] = 0 }; $bad[$x.store]++ }

$report = [ordered]@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); board = $cmpF.Name; total_tiles = ($tiles.Values | Measure-Object -Sum).Sum; violations = $rows.Count; by_store = @{}; rows = $rows }
# record COVERAGE per store as well as total violations: the ratchet below compares coverage only, because
# pruning a wrong link (the correct fix) RAISES a store's no-link count and a combined ratchet would fail it.
$covPerStore = @{}
foreach ($x in $rows) { if ($x.fault -eq 'NO-LINK') { if (-not $covPerStore.ContainsKey($x.store)) { $covPerStore[$x.store] = 0 }; $covPerStore[$x.store]++ } }
foreach ($k in $tiles.Keys) {
  $report.by_store[$k] = @{
    tiles      = $tiles[$k]
    violations = $(if ($bad.ContainsKey($k)) { $bad[$k] } else { 0 })
    coverage   = $(if ($covPerStore.ContainsKey($k)) { $covPerStore[$k] } else { 0 })
  }
}
($report | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $OutDir 'tile-integrity.json') -Encoding UTF8

$ACC = @('WRONG-PRODUCT', 'PRICE-MISMATCH', 'LINK-UNPRICEABLE', 'LINK-NO-PRICE')
$accRows = @($rows | Where-Object { $ACC -contains $_.fault })
$covRows = @($rows | Where-Object { $_.fault -eq 'NO-LINK' })
$report['accuracy_violations'] = $accRows.Count
$report['coverage_violations'] = $covRows.Count
($report | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $OutDir 'tile-integrity.json') -Encoding UTF8

if (-not $Quiet) {
  $linked = $report.total_tiles - $covRows.Count
  Write-Output ("ACCURACY  " + $accRows.Count + " of " + $linked + " LINKED tiles show a link that disagrees with the price/product  <- must be ZERO; a wrong link lies to a shopper")
  Write-Output ("COVERAGE  " + $covRows.Count + " of " + $report.total_tiles + " priced tiles have no See-item link at all       <- incomplete, not dishonest; needs browser passes")
  Write-Output ''
  Write-Output ("tile-integrity: " + $rows.Count + " violation(s) of " + $report.total_tiles + " priced tiles   (" + [math]::Round(100 - ($rows.Count / [math]::Max(1, $report.total_tiles) * 100), 1) + "% clean)")
  Write-Output ''
  Write-Output ("{0,-14}{1,8}{2,12}{3,10}   {4}" -f 'store', 'tiles', 'violations', 'clean%', 'worst fault')
  foreach ($k in ($tiles.Keys | Sort-Object)) {
    $b = if ($bad.ContainsKey($k)) { $bad[$k] } else { 0 }
    $w = @($rows | Where-Object { $_.store -eq $k } | Group-Object fault | Sort-Object Count -Descending | Select-Object -First 1)
    $wt = if ($w.Count) { $w[0].Name + ' x' + $w[0].Count } else { '-' }
    Write-Output ("{0,-14}{1,8}{2,12}{3,10}   {4}" -f $k, $tiles[$k], $b, ([math]::Round(100 - ($b / [math]::Max(1, $tiles[$k]) * 100), 1)), $wt)
  }
  Write-Output ''
  $rows | Group-Object fault | Sort-Object Count -Descending | ForEach-Object { Write-Output ("  {0,-18}{1}" -f $_.Name, $_.Count) }
}

$blF = Join-Path $OutDir 'tile-integrity-baseline.json'
if ($Baseline) {
  (@{ set = (Get-Date -Format 'yyyy-MM-dd HH:mm'); by_store = $report.by_store } | ConvertTo-Json -Depth 5) | Set-Content $blF -Encoding UTF8
  Write-Output ''
  Write-Output ("baseline written: " + $rows.Count + " violation(s). From here the number may only go DOWN.")
  exit 0
}
# ---- ACCURACY: a hard gate, always. Not baselined, not ratcheted, not -Strict-gated. -----------------------
# A shipped link that opens the wrong product/price is never acceptable and never needs a browser to fix:
# prune-bad-links removes it and the tile falls back to an honest price-with-no-link. There is no version of
# this repo where a wrong link is tolerable, so there is no baseline to grandfather one in.
$fail2 = $false
if ($accRows.Count -gt 0) {
  Write-Output ''
  Write-Output ("tile-integrity: FAIL - " + $accRows.Count + " LINKED tile(s) disagree with the product/price they advertise.")
  Write-Output '  A wrong link is worse than no link: the shopper clicks, sees something else, and concludes the'
  Write-Output '  board inflates its deals. Run prune-bad-links.ps1 to drop them - that is always available and'
  Write-Output '  needs no browser.'
  foreach ($x in ($accRows | Select-Object -First 10)) { Write-Output ('    ' + $x.fault.PadRight(18) + ($x.id + ' | ' + $x.store).PadRight(34) + $x.detail) }
  $fail2 = $true
}
else { Write-Output ''; Write-Output 'tile-integrity: ACCURACY OK - every link that ships opens the product the board names, at the price it shows.' }

# ---- COVERAGE: ratchets down. Closing these needs paced per-store browser passes. --------------------------
if ($Strict) {
  if ($covRows.Count -gt 0) { Write-Output ("tile-integrity: STRICT - " + $covRows.Count + " priced tile(s) still have no link."); exit 2 }
  Write-Output 'tile-integrity: STRICT - every priced tile also has a verified link.'
  exit $(if ($fail2) { 2 } else { 0 })
}
if (Test-Path $blF) {
  $bl = (Get-Content $blF -Raw | ConvertFrom-Json).by_store
  $worse = @()
  # compare COVERAGE only. Accuracy is gated above, and pruning a bad link (the right fix) RAISES a store's
  # no-link count - the old combined ratchet would have failed the very act of removing a lie.
  $covByStore = @{}
  foreach ($x in $covRows) { if (-not $covByStore.ContainsKey($x.store)) { $covByStore[$x.store] = 0 }; $covByStore[$x.store]++ }
  foreach ($k in ($tiles.Keys | Sort-Object)) {
    $now = if ($covByStore.ContainsKey($k)) { $covByStore[$k] } else { 0 }
    $was = if ($bl.PSObject.Properties[$k] -and $null -ne $bl.$k.coverage) { [int]$bl.$k.coverage } else { $null }
    if ($null -ne $was -and $now -gt $was) { $worse += ("  " + $k + ": " + $was + " -> " + $now + "  (+" + ($now - $was) + ")") }
  }
  if ($worse.Count) {
    Write-Output ''
    Write-Output 'tile-integrity: FAIL - a store got WORSE on COVERAGE than its baseline. The ratchet only turns one way.'
    $worse | ForEach-Object { Write-Output $_ }
    exit 2
  }
  Write-Output 'tile-integrity: COVERAGE OK - no store regressed against the baseline.'
}
exit $(if ($fail2) { 2 } else { 0 })
