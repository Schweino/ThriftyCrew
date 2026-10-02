<#
  store-department-lib.ps1 - the SECOND identity signal of step 9 (design/PLAN-zero-alert-days-remainder-2026-09-24.md,
  "Two independent signals must agree for a crown"): what a store's own capture says a product's department is,
  translated into aisle-lib.ps1's one department vocabulary.

  The declaration is DATA, in grocery/store-department-map.json: which file and field carry each store's category, and
  how each store word maps to a department. The EXPECTED departments for a commodity are aisle-lib.ps1's reviewed
  tables, asked through Test-AisleAllowed, so the estate keeps one expected set. Read by
  audit-store-category-share.ps1 (coverage) and audit-crown-identity-shadow.ps1 (the shadow on crowns).

  NO param() BLOCK AND NO $root, ON PURPOSE (aisle-lib.ps1's header has the reason): every path is an argument.
  Verdicts: 'agree' (a store department is allowed for the commodity), 'disagree' (the store named departments and
  none is allowed), 'no-signal' (the store named nothing usable, or the commodity has no expected set). A no-signal is
  a could-not-look: counted, never agree and never a failure.
#>
. (Join-Path $PSScriptRoot 'aisle-lib.ps1')   # Test-AisleAllowed, Get-AisleDept, Get-AisleCategoryMap; it loads lib\json-io.ps1

function Read-StoreDeptMap([string]$Root) { return (Read-JsonFile (Join-Path $Root 'store-department-map.json')) }

# The newest file for each glob the store declares. The glob is relative to the grocery root.
function Get-StoreDeptFiles([string]$Root, $Cfg) {
  $out = @()
  foreach ($g in @($Cfg.files)) {
    if (-not $g) { continue }
    $f = Get-ChildItem (Join-Path $Root ([string]$g)) -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if ($f) { $out += $f }
  }
  return ,$out
}

# One row's store words -> the departments they map to. raw is what the store wrote; depts is empty for no signal.
function Get-RowStoreDepts($Cfg, $Row) {
  $field = [string]$Cfg.field
  $raw = ''
  if ($field) { $raw = ([string]$Row.$field).Trim() }
  if (-not $raw -and $Cfg.url_field) { $raw = Get-AisleDept ([string]$Row.([string]$Cfg.url_field)) }
  $depts = New-Object System.Collections.Generic.List[string]
  if (-not $raw) { return [pscustomobject]@{ raw = ''; depts = @() } }
  $parts = @($raw)
  if ($Cfg.split) { $parts = @($raw -split [regex]::Escape([string]$Cfg.split) | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
  foreach ($p in $parts) {
    $d = ''
    if ($Cfg.identity) { $d = $p.ToLower() }
    elseif ($Cfg.map -and $Cfg.map.PSObject.Properties[$p]) { $d = [string]$Cfg.map.$p }
    if ($d -and -not $depts.Contains($d)) { [void]$depts.Add($d) }
  }
  return [pscustomobject]@{ raw = $raw; depts = $depts.ToArray() }
}

function Get-StoreRowKey([string]$s) { return (([string]$s) -replace '\s+', ' ').Trim().ToLower() }

# Per store: rows indexed by name and by the product id the board's link carries. Only rows with a signal are kept,
# so a lookup that finds nothing and a row the store named nothing for read the same: no-signal.
function New-StoreDeptIndex([string]$Root, $Map) {
  $ix = @{}
  foreach ($sp in $Map.stores.PSObject.Properties) {
    $cfg = $sp.Value
    $e = @{ by_name = @{}; by_id = @{}; files = @(); rows = 0 }
    $sfiles = Get-StoreDeptFiles $Root $cfg   # assign, then wrap: an inline @() reads a comma-returned array as ONE element
    foreach ($f in @($sfiles)) {
      $e.files += $f.Name
      if (-not $cfg.field -and -not $cfg.url_field) { continue }
      $doc = Read-JsonFile $f.FullName
      foreach ($r in @($doc.deals)) {
        if ($null -eq $r) { continue }
        $e.rows++
        $sig = Get-RowStoreDepts $cfg $r
        if (-not $sig.raw) { continue }
        $nm = Get-StoreRowKey ([string]$r.item); if ($nm) { $e.by_name[$nm] = $sig }
        foreach ($k in 'product_id', 'item_id') { $id = [string]$r.$k; if ($id) { $e.by_id[$id] = $sig } }
      }
    }
    $ix[[string]$sp.Name] = $e
  }
  # Family Fare Weekly Ad lines: the flyer-link evidence's resolved product, keyed by the ad line and the product name.
  $ff = $Map.stores.'Family Fare'
  if ($ff -and $ff.evidence -and $ix.ContainsKey('Family Fare')) {
    $ev = Get-ChildItem (Join-Path $Root ([string]$ff.evidence)) -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if ($ev) { Add-FlyerEvidence $ix['Family Fare'] $ev.FullName }
  }
  return $ix
}

function Add-FlyerEvidence($Entry, [string]$Path) {
  $Entry.files += (Split-Path $Path -Leaf)
  if (-not $Entry.ContainsKey('by_line')) { $Entry.by_line = @{} }
  foreach ($ln in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
    if (-not $ln.Trim()) { continue }
    $r = $ln | ConvertFrom-Json
    if ([string]$r.kind -ne 'candidate') { continue }
    $d = Get-AisleDept ([string]$r.canonical_url)
    if (-not $d) { continue }
    $sig = [pscustomobject]@{ raw = $d; depts = @($d) }
    $lk = Get-StoreRowKey ([string]$r.line)
    # A line resolved to several candidates keeps every department it touched: the store named all of them.
    if ($lk) {
      if ($Entry.by_line.ContainsKey($lk)) {
        $old = $Entry.by_line[$lk]
        if (@($old.depts) -notcontains $d) { $Entry.by_line[$lk] = [pscustomobject]@{ raw = ($old.raw + ' | ' + $d); depts = @(@($old.depts) + $d) } }
      } else { $Entry.by_line[$lk] = $sig }
    }
    $pid0 = [string]$r.product_id; if ($pid0) { $Entry.by_id[$pid0] = $sig }
  }
}

# A board cell -> its store signal and where it came from. via: link | id | name | ad-line | none
function Get-CellStoreSignal($Index, $Map, [string]$Store, [string]$Item, [string]$Link) {
  $none = [pscustomobject]@{ raw = ''; depts = @(); via = 'none' }
  $cfg = $Map.stores.$Store
  if (-not $cfg -or -not $Index.ContainsKey($Store)) { return $none }
  $e = $Index[$Store]
  if ($cfg.url_field -and $Link) {
    $d = Get-AisleDept $Link
    if ($d) { return [pscustomobject]@{ raw = $d; depts = @($d); via = 'link' } }
  }
  $id = ''
  if ($Link) {
    $pat = if ($cfg.id_pattern) { [string]$cfg.id_pattern } else { '/(?:ip|p)/(?:[^/]+/)?(\d+)' }
    $m = [regex]::Match($Link, $pat); if ($m.Success) { $id = $m.Groups[1].Value }
  }
  if ($id -and $e.by_id.ContainsKey($id)) { $s = $e.by_id[$id]; return [pscustomobject]@{ raw = $s.raw; depts = @($s.depts); via = 'id' } }
  $nk = Get-StoreRowKey $Item
  if ($nk -and $e.ContainsKey('by_line') -and $e.by_line.ContainsKey($nk)) { $s = $e.by_line[$nk]; return [pscustomobject]@{ raw = $s.raw; depts = @($s.depts); via = 'ad-line' } }
  if ($nk -and $e.by_name.ContainsKey($nk)) { $s = $e.by_name[$nk]; return [pscustomobject]@{ raw = $s.raw; depts = @($s.depts); via = 'name' } }
  return $none
}

# The comparison of the two signals. One allowed department is agreement, because a multi-tag store (Baker's) files a
# product under several tags and the one that matches is the store saying yes.
function Get-SecondSignalVerdict($CatMap, [string]$CommodityId, $Depts) {
  $ds = @($Depts | Where-Object { $_ })
  if ($ds.Count -eq 0) { return [pscustomobject]@{ verdict = 'no-signal'; reason = 'the store named no usable department for this row' } }
  $blocked = @()
  foreach ($d in $ds) {
    $v = Test-AisleAllowed -CatMap $CatMap -CommodityId $CommodityId -Dept $d
    if ($v.verdict -eq 'ALLOW') { return [pscustomobject]@{ verdict = 'agree'; reason = $v.reason } }
    if ($v.verdict -eq 'BLIND') { return [pscustomobject]@{ verdict = 'no-signal'; reason = $v.reason } }
    $blocked += $v.reason
  }
  return [pscustomobject]@{ verdict = 'disagree'; reason = ($blocked -join '; ') }
}
