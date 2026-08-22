<#
  reanchor-rollback-ledger.ps1 - one-off (re-runnable, idempotent) migration of rollback-first-seen.json to
  Brad's 2026-08-22 ruling: the 30-day TTL runs from DETECTION, and detection is the CAPTURE that first
  showed the cut price (the row's as_of), not the day the ledger first processed the row.

  WHAT IT DOES, AND ONLY THIS:
    1. Copies the ledger to rollback-first-seen.pre-reanchor-<today>.json beside it (never overwritten if present; named so .gitignore's *.backup-*.json does not drop it from history).
    2. Reads the SAME out\regular file set the engine prices from (Select-RegularFileSet: newest file for
       Fareway, the 90-day union for Walmart / Sam's), and for every ledger entry finds rows with the same
       store + item id, the same rolled-back price (within half a cent) AND a discount signal on the row
       (marked_down, or base_price / regular above the price - the same signal price-split-lib reads).
    3. Where the earliest such row's as_of is EARLIER than the entry's first_seen, moves first_seen back to
       it. Nothing else on the entry changes. Entries with no provably-earlier row are left exactly as they
       were - "do not rewrite existing first_seen except where the row's as_of is provably earlier".
  It never advances an anchor, never invents one, and never touches last_seen or price_changed.

  Usage:  reanchor-rollback-ledger.ps1 [-WhatIf]        (prints the per-entry moves either way)
#>
param([switch]$WhatIf, [string]$Root = '', [string]$OutDir = '', [string]$Today = '')
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path } }
if (-not $OutDir) { $OutDir = Join-Path $Root 'out' }
if (-not $Today) { $Today = (Get-Date).ToString('yyyy-MM-dd') }
. (Join-Path $Root 'regular-fileset-lib.ps1')

$ledgerPath = Join-Path $Root 'rollback-first-seen.json'
if (-not (Test-Path $ledgerPath)) { Write-Output "no ledger at $ledgerPath - nothing to do"; exit 0 }
$doc = ConvertFrom-Json ([IO.File]::ReadAllText($ledgerPath))

# the engine's file set, not "every file": an entry is re-anchored only from captures the board actually reads
$regs = Get-ChildItem (Join-Path $OutDir 'regular\*-regular-*.json') -ErrorAction SilentlyContinue
$files = @(Select-RegularFileSet $regs ([datetime]$Today) (Get-RegularUnionDays))

function Get-Num($v) { if ($null -eq $v) { return $null }; $t = ([string]$v) -replace '[^0-9.]', ''; if ($t -match '^\d*\.?\d+$') { return [double]$t }; return $null }

# earliest discounted sighting per (store|item_id|price)
$earliest = @{}
foreach ($f in $files) {
  $d = $null; try { $d = ConvertFrom-Json ([IO.File]::ReadAllText($f.FullName)) } catch { continue }
  $fileDate = if ($f.BaseName -match '(\d{4}-\d{2}-\d{2})$') { $Matches[1] } else { '' }
  foreach ($r in @($d.deals)) {
    $store = [string]$r.store
    $id = ''
    if ($r.item_id) { $id = [string]$r.item_id } elseif ($r.sams_item_id) { $id = [string]$r.sams_item_id }
    elseif ($r.product_id) { $id = [string]$r.product_id } elseif ([string]$r.link_url -match '/products/(\d+)') { $id = $Matches[1] }
    if (-not $store -or -not $id) { continue }
    $cur = Get-Num $r.ad_price
    if ($null -eq $cur) { continue }
    $was = Get-Num $r.base_price
    if ($null -eq $was -and $store -eq 'Fareway') {
      $szl = ([string]$r.size).Trim().ToLower()
      if ($szl -notmatch '^(lb|lbs|pound|pounds|oz|ounce|ounces|kg|g|gram|grams)$') { $was = Get-Num $r.regular }
    }
    $signal = ([bool]$r.marked_down) -or ($null -ne $was -and $was -gt ($cur + 0.005))
    if (-not $signal) { continue }
    $asOf = if ([string]$r.as_of -match '^\d{4}-\d{2}-\d{2}$') { [string]$r.as_of } else { $fileDate }
    if (-not $asOf -or $asOf -gt $Today) { continue }
    $k = "$store|$id|" + ('{0:N2}' -f $cur)
    if (-not $earliest.ContainsKey($k) -or $asOf -lt $earliest[$k]) { $earliest[$k] = $asOf }
  }
}

$moved = 0; $kept = 0; $noRow = 0
foreach ($e in @($doc.entries)) {
  $k = "$($e.store)|$($e.item_id)|" + ('{0:N2}' -f [double]$e.price)
  if (-not $earliest.ContainsKey($k)) { $noRow++; continue }
  $rowAsOf = $earliest[$k]
  if ($rowAsOf -lt [string]$e.first_seen) {
    Write-Output ("  {0,-28} {1,10} first_seen {2} -> {3}  (capture as_of is provably earlier)" -f $e.key, ('{0:N2}' -f [double]$e.price), $e.first_seen, $rowAsOf)
    $e.first_seen = $rowAsOf; $moved++
  } else { $kept++ }
}
Write-Output ("re-anchored {0} entr(y/ies); {1} already anchored at or before their capture; {2} had no matching discounted row in the engine's file set (left untouched)" -f $moved, $kept, $noRow)

if ($WhatIf -or $moved -eq 0) { Write-Output 'no write (WhatIf or nothing to move)'; exit 0 }
$backup = Join-Path $Root ("rollback-first-seen.pre-reanchor-{0}.json" -f $Today)
if (-not (Test-Path $backup)) { Copy-Item -LiteralPath $ledgerPath -Destination $backup }
$doc.updated = (Get-Date).ToString('s')
$doc | Add-Member -NotePropertyName reanchored -NotePropertyValue ("{0}: first_seen moved back to the capture's as_of on {1} entries per Brad's 2026-08-22 ruling (TTL from DETECTION = the capture). Backup beside this file: {2}" -f $Today, $moved, (Split-Path $backup -Leaf)) -Force
$tmp = "$ledgerPath.tmp"
[IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
Move-Item -LiteralPath $tmp -Destination $ledgerPath -Force
Write-Output "wrote $ledgerPath (backup: $backup)"
