<#
  audit-links.ps1 - Accuracy QA for the product-URL layer.
  A "See item" link is only correct if the linked PRODUCT's price matches the BOARD price shown next to it
  (the board price is usually the store's cheapest/budget brand, so a link to a different brand of the same
  commodity shows a different price on click - the eggs bug). This computes each link's per-unit price from
  its stored {price,size} in the board's unit, compares to the board per-unit, and flags divergences.
  Output: out\link-audit.json + a printed table. Reason:
    mismatch(NN%) - link product per-unit is >tol from the board per-unit (probably the wrong SKU/brand)
    uncomputable  - couldn't parse a per-unit from the stored size (needs an eyeball)
  Run standalone anytime; resolve-worklist.ps1 uses the same LinkPerUnit for its weekly 'mismatch' reason.
#>
param([double]$Tolerance = 0.15)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$outDir = Join-Path $root 'out'

# A commodity can appear in BOTH the weekly board and the recipe board with DIFFERENT units
# (e.g. butter is $/lb weekly and cent/oz in recipes) - the SAME price, expressed two ways. So keep
# every (unit, per_unit) occurrence per id/store; a link is correct if it matches ANY of them.
# board: id -> store -> @( @{unit; pu}, ... )
$board = @{}
$cmpFile = (Get-ChildItem (Join-Path $outDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
$srcs = @((Get-Content $cmpFile -Raw | ConvertFrom-Json).comparison)
$riFile = Join-Path $outDir 'recipe-board.json'
if (Test-Path $riFile) { $srcs += @((Get-Content $riFile -Raw | ConvertFrom-Json).comparison) }
foreach ($it in $srcs) {
  $id = [string]$it.id
  if (-not $board.ContainsKey($id)) { $board[$id] = @{} }
  foreach ($s in $it.stores) {
    $st = [string]$s.store
    if (-not $board[$id].ContainsKey($st)) { $board[$id][$st] = @() }
    $board[$id][$st] += @{ unit=[string]$it.unit; pu=[double]$s.per_unit }
  }
}

# Compute a link product's per-unit price in the board's $unit from {price,size}.
# size may be a UNIT-PRICE string ("$2.74/lb","$0.28/oz") or a QUANTITY ("16 oz","3 lb","12 ct","dozen","2 ea").
function LinkPerUnit([string]$size, [string]$unit, [double]$price) {
  $s = ([string]$size).ToLower().Trim()
  # (a) explicit unit-price string wins
  $up = [regex]::Match($s, '\$?\s*([0-9]+(?:\.[0-9]+)?)\s*/\s*(fl\s*oz|floz|oz|lb|ea|each|ct|count)')
  if ($up.Success) {
    $v = [double]$up.Groups[1].Value; $un = ($up.Groups[2].Value -replace '\s','') -replace 'fl',''
    switch ($unit) {
      'lb'     { if ($un -eq 'lb') { return $v }; if ($un -eq 'oz') { return $v*16 } }
      'oz'     { if ($un -eq 'oz') { return $v }; if ($un -eq 'lb') { return $v/16 } }
      'floz'   { if ($un -match 'oz') { return $v }; if ($un -eq 'lb') { return $v/16 } }
      'each'   { return $price }
      'dozen'  { return $price }
    }
  }
  if ($price -le 0) { return $null }
  # (b) quantity parse
  $q = [regex]::Match($s, '([0-9]+(?:\.[0-9]+)?)\s*(fl\s*oz|floz|oz|lbs?|ct|count|ea|pk|gal|dozen|doz)')
  $n = if ($q.Success) { [double]$q.Groups[1].Value } else { $null }
  $un = if ($q.Success) { ($q.Groups[2].Value -replace '\s','') } else { '' }
  $un = $un -replace 'fl',''
  # bare-unit size ("lb","per lb","gallon","dozen","each") = one of that unit -> per-unit = the price itself
  if (-not $q.Success) { $bu = [regex]::Match($s, '\b(lbs?|gal|gallon|dozen|doz|each|ea)\b'); if ($bu.Success) { $n = 1; $un = $bu.Groups[1].Value -replace '^gallon$','gal' -replace '^doz$','dozen' } }   # anchored: unanchored 'doz'->'dozen' corrupts 'dozen' into 'dozenen'
  # multipack: "40 oz 2 pk" = 80 oz total
  $pk = [regex]::Match($s, '([0-9]+)\s*(pk|pack)\b')
  if ($pk.Success -and $n -and ($un -match '^(oz|lbs?|gal)$')) { $n = $n * [double]$pk.Groups[1].Value }
  switch ($unit) {
    'lb'    { if ($un -match '^lbs?$') { if ($n) { return $price/$n } }; if ($un -eq 'oz') { if ($n) { return $price/($n/16) } }; return $null }
    'oz'    { if ($un -eq 'oz') { if ($n) { return $price/$n } }; if ($un -match '^lbs?$') { if ($n) { return $price/(16*$n) } }; if ($un -eq 'gal') { if ($n) { return $price/(128*$n) } }; return $null }
    'floz'  { if ($un -match 'oz') { if ($n) { return $price/$n } }; if ($un -eq 'gal') { if ($n) { return $price/(128*$n) } }; return $null }
    'each'  { if ($un -match '^(ct|count|ea|pk)$') { if ($n) { return $price/$n } }; if ($un -match '^(dozen|doz)$') { return $price/12 }; if ($s -match 'each' -or $s -eq '' -or $s -eq '1 ct') { return $price }; return $null }
    'dozen' { if ($un -match '^(dozen|doz)$') { return $price }; if ($un -match '^(ct|count|ea)$') { if ($n) { return $price/($n/12) } }; return $null }
    'gallon'{ if ($un -eq 'gal') { if ($n) { return $price/$n } }; return $null }
    default { return $null }
  }
  return $null
}

$pf = Join-Path $root 'product-urls.json'
$pd = Get-Content $pf -Raw | ConvertFrom-Json
$flags = @(); $ok = 0; $tot = 0; $skipped = 0
foreach ($p in $pd.items.PSObject.Properties) {
  $id = [string]$p.Name
  foreach ($sp in $p.Value.PSObject.Properties) {
    if ($sp.Name -eq 'commodity') { continue }
    $store = [string]$sp.Name; $lnk = $sp.Value
    if (-not $lnk.url) { continue }
    $tot++
    if (-not $board.ContainsKey($id) -or -not $board[$id].ContainsKey($store)) { $skipped++; continue }
    $occ = @($board[$id][$store])
    # try to match ANY board occurrence (weekly and/or recipe unit); keep the smallest delta seen
    $best = $null; $bestBpu = $null; $bestUnit = $null; $bestLpu = $null; $anyComputable = $false
    foreach ($o in $occ) {
      $bpu = [double]$o.pu; if ($bpu -le 0) { continue }
      # link prices are stored as display strings ("$7.54") by some resolvers - strip before casting,
      # exactly as prune-bad-links does. A hard [double] cast here crashed the whole audit on the first
      # $-prefixed price, which silently un-audited every link after it.
      $lp = 0.0; [void][double]::TryParse((([string]$lnk.price) -replace '[^0-9.]',''), [ref]$lp)
      if ($lp -le 0) { continue }
      $lpu = LinkPerUnit ([string]$lnk.size) ([string]$o.unit) ($lp)
      if ($null -eq $lpu) { continue }
      $anyComputable = $true
      $d = [math]::Abs($lpu - $bpu) / $bpu
      if ($null -eq $best -or $d -lt $best) { $best = $d; $bestBpu = $bpu; $bestUnit = [string]$o.unit; $bestLpu = $lpu }
    }
    if (-not $anyComputable) {
      $flags += [pscustomobject]@{ id=$id; store=$store; reason='uncomputable'; delta=$null; board_pu=($occ[0].pu); unit=($occ[0].unit); link_price=$lnk.price; size=[string]$lnk.size; name=[string]$lnk.name }
      continue
    }
    if ($best -gt $Tolerance) {
      $flags += [pscustomobject]@{ id=$id; store=$store; reason=('mismatch(' + [math]::Round($best*100) + '%)'); delta=[math]::Round($best,3); board_pu=$bestBpu; unit=$bestUnit; link_pu=[math]::Round($bestLpu,4); link_price=$lnk.price; size=[string]$lnk.size; name=[string]$lnk.name }
    } else { $ok++ }
  }
}
$mism = @($flags | Where-Object { $_.reason -like 'mismatch*' })
$unc  = @($flags | Where-Object { $_.reason -eq 'uncomputable' })
$out = [ordered]@{ generated=(Get-Date -Format 'yyyy-MM-dd'); tolerance=$Tolerance; total_links=$tot; examined=($tot - $skipped); skipped=$skipped; ok=$ok; mismatch=$mism.Count; uncomputable=$unc.Count; flags=$flags }
$out | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $outDir 'link-audit.json') -Encoding UTF8
Write-Output ("audited " + ($tot - $skipped) + " of $tot links: $ok price-match, " + $mism.Count + " MISMATCH, " + $unc.Count + " uncomputable ($skipped not on the board, unchecked)")
Write-Output "--- MISMATCHES (link price does not match the board price shown) ---"
$mism | Sort-Object { -$_.delta } | ForEach-Object { Write-Output ("  {0,-16} {1,-12} board={2,-7} link_pu={3,-7} `${4,-6} {5} | {6}" -f $_.id, $_.store, $_.board_pu, $_.link_pu, $_.link_price, ('['+$_.size+']'), $_.name) }
if (($tot - $skipped) -eq 0) {
  Write-Output ("audit-links: BLIND - examined ZERO of $tot links; not one link matched a board id/store (check that the comparison file still exposes .comparison and product-urls.json still exposes .items). The link-audit.json just written proves nothing.")
  exit 3
}
