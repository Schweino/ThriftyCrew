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

  WHY A RATCHET AND NOT A HARD GATE ON DAY ONE: there are hundreds of violations today, almost all needing a
  paced per-store browser pass to fix. A gate that fails from the first run is a gate somebody switches off. So
  this writes a BASELINE (out\tile-integrity-baseline.json) and fails only when a store gets WORSE. The number
  can only go down. Drive it to zero, then flip -Strict on and it becomes the hard invariant Brad asked for.

  Exit: 0 = no store regressed (or -Strict and zero violations). 2 = a store got worse (or -Strict with any).
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
foreach ($k in $tiles.Keys) { $report.by_store[$k] = @{ tiles = $tiles[$k]; violations = $(if ($bad.ContainsKey($k)) { $bad[$k] } else { 0 }) } }
($report | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $OutDir 'tile-integrity.json') -Encoding UTF8

if (-not $Quiet) {
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
if ($Strict) {
  if ($rows.Count -gt 0) { Write-Output ''; Write-Output ("tile-integrity: STRICT - " + $rows.Count + " tile(s) violate price==item==link. Board NOT safe to publish."); exit 2 }
  Write-Output 'tile-integrity: STRICT - every priced tile has a link, the right product, and a matching price.'
  exit 0
}
if (Test-Path $blF) {
  $bl = (Get-Content $blF -Raw | ConvertFrom-Json).by_store
  $worse = @()
  foreach ($k in ($tiles.Keys | Sort-Object)) {
    $now = if ($bad.ContainsKey($k)) { $bad[$k] } else { 0 }
    $was = if ($bl.PSObject.Properties[$k]) { [int]$bl.$k.violations } else { $null }
    if ($null -ne $was -and $now -gt $was) { $worse += ("  " + $k + ": " + $was + " -> " + $now + "  (+" + ($now - $was) + ")") }
  }
  if ($worse.Count) {
    Write-Output ''
    Write-Output 'tile-integrity: FAIL - a store got WORSE than its baseline. The ratchet only turns one way.'
    $worse | ForEach-Object { Write-Output $_ }
    exit 2
  }
  Write-Output ''
  Write-Output 'tile-integrity: OK - no store regressed against the baseline.'
}
exit 0
