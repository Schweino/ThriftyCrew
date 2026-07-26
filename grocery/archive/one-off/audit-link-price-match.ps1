<#
  audit-link-price-match.ps1 - For EVERY priced board cell that has a stored "See item" URL, compute the linked
  product's per-unit (same LinkPU math the builder uses) and compare it to the price shown on the board. A large
  gap means the link points at a DIFFERENT product/size than the price represents (e.g. board = Aldi in-store
  $2.29 family pack, link = aldi.us $3.29 per-lb tray). Prints every mismatch, grouped by store, worst first.
  This is the "re-evaluate everything" tool: run it after any product-urls change; drive the mismatch count to 0.
#>
param([double]$Tol = 0.30, [string]$OutDir = "")
$ErrorActionPreference='Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
# --- exact copy of build-deals-page.ps1 LinkPU ---
function LinkPU([string]$size, [string]$unit, [double]$price, [string]$name = '') {
  $s = ([string]$size).ToLower().Trim()
  $up = [regex]::Match($s, '\$?\s*([0-9]+(?:\.[0-9]+)?)\s*/\s*(fl\s*oz|floz|oz|lb|ea|each|ct|count)')
  if ($up.Success) { $v=[double]$up.Groups[1].Value; $un=($up.Groups[2].Value -replace '\s','') -replace 'fl',''; switch ($unit) { 'lb'{if($un -eq 'lb'){return $v}; if($un -eq 'oz'){return $v*16}} 'oz'{if($un -eq 'oz'){return $v}; if($un -eq 'lb'){return $v/16}} 'floz'{if($un -match 'oz'){return $v}; if($un -eq 'lb'){return $v/16}} 'each'{if($un -match '^(ea|each|ct|count)$'){return $v}; return $price} 'dozen'{if($un -match '^(ea|each|ct|count)$'){return $v*12}; return $price} } }
  if ($price -le 0) { return $null }
  $q = [regex]::Match($s, '([0-9]+(?:\.[0-9]+)?)\s*(fl\s*oz|floz|oz|lbs?|ct|count|ea|pk|gal|dozen|doz)')
  $n = if ($q.Success) { [double]$q.Groups[1].Value } else { $null }
  $un = if ($q.Success) { ($q.Groups[2].Value -replace '\s','') -replace 'fl','' } else { '' }
  if (-not $q.Success) { $bu=[regex]::Match($s,'\b(lbs?|gal|gallon|dozen|doz|each|ea)\b'); if ($bu.Success) { $n=1; $un=$bu.Groups[1].Value -replace '^gallon$','gal' -replace '^doz$','dozen' } }
  $pk = [regex]::Match($s, '([0-9]+)\s*(pk|pack)\b'); if ($pk.Success -and $n -and ($un -match '^(oz|lbs?|gal)$')) { $n = $n * [double]$pk.Groups[1].Value }
  # MULTIPACK IN THE NAME: a link whose size is just "each" but whose NAME says "24 Pack" is 24 items,
  # not 1. Without this the whole pack price is published as the per-item price (Fareway bottled water
  # went out at $3.87 EACH). Only for 'each' commodities, and only when the size carries no count.
  if ($unit -eq 'each' -and $name -and (($null -eq $n) -or ($n -eq 1))) {
    $pn = [regex]::Match(([string]$name).ToLower(), '([0-9]+)\s*(?:pk\b|pack\b|ct\b|count\b)')
    if ($pn.Success) {
      $cnt = [double]$pn.Groups[1].Value
      if ($cnt -gt 1) { return $price / $cnt }
    }
  }
  switch ($unit) {
    'lb'    { if ($un -match '^lbs?$' -and $n) { return $price/$n }; if ($un -eq 'oz' -and $n) { return $price/($n/16) }; return $null }
    'oz'    { if ($un -eq 'oz' -and $n) { return $price/$n }; if ($un -match '^lbs?$' -and $n) { return $price/(16*$n) }; if ($un -eq 'gal' -and $n) { return $price/(128*$n) }; return $null }
    'floz'  { if ($un -match 'oz' -and $n) { return $price/$n }; if ($un -eq 'gal' -and $n) { return $price/(128*$n) }; return $null }
    'each'  { if ($un -match '^(ct|count|ea|pk)$' -and $n) { return $price/$n }; if ($un -match '^(dozen|doz)$') { return $price/12 }; if ($n -eq 1) { return $price }; return $null }
    'dozen' { if ($un -match '^(dozen|doz)$') { return $price }; if ($un -match '^(ct|count|ea)$' -and $n) { return $price/($n/12) }; if ($n -eq 1) { return $price }; return $null }
    'gallon'{ if ($un -eq 'gal' -and $n) { return $price/$n }; if ($n -eq 1) { return $price }; return $null }
    default { return $null }
  }
  return $null
}
$cmpF = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
$all = @((Get-Content $cmpF -Raw | ConvertFrom-Json).comparison)
$riF = Join-Path $OutDir 'recipe-board.json'
if (Test-Path $riF) { $all += @((Get-Content $riF -Raw | ConvertFrom-Json).comparison) }
$pd = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items
$mm = New-Object System.Collections.Generic.List[object]
foreach ($it in $all) { $id=[string]$it.id; $unit=[string]$it.unit
  foreach ($s in $it.stores) { $st=[string]$s.store; $b=[double]$s.per_unit
    $e = $pd.$id.$st
    if (-not ($e -and $e.url)) { continue }
    $sp=0.0; [void][double]::TryParse((([string]$e.price) -replace '[^0-9.]',''), [ref]$sp)
    $lpu = LinkPU ([string]$e.size) $unit $sp ([string]$e.name)
    if ($null -eq $lpu -or $b -le 0) { continue }
    $d = [math]::Abs($lpu-$b)/$b
    if ($d -gt $Tol) { $mm.Add([pscustomobject]@{ id=$id; store=$st; unit=$unit; board=[math]::Round($b,3); linkpu=[math]::Round($lpu,3); off=[math]::Round($d*100); price=$e.price; size=$e.size; name=$e.name }) }
  } }
"LINK/PRICE MISMATCHES (>$([int]($Tol*100))% off), $($mm.Count) cells:"
foreach ($g in ($mm | Group-Object store | Sort-Object Count -Descending)) { "  {0,-14} {1}" -f $g.Name,$g.Count }
"`nworst first:"
$mm | Sort-Object off -Descending | ForEach-Object { "{0,-26} {1,-13} board={2,-7} link={3,-7} ({4}% off) {5} | {6}" -f $_.id,$_.store,$_.board,$_.linkpu,$_.off,$_.size,$_.name }
($mm | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $OutDir 'link-price-mismatch.json') -Encoding UTF8


