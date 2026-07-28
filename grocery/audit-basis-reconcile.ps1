<#
  audit-basis-reconcile.ps1 - reconciles what WE publish against what the STORE ITSELF publishes as the
  unit price, in the same basis. The proof tier of the basis-error defense (2026-07-28).

  WHY THIS EXISTS
  The board's worst failures are not missing prices, they are REAL prices in the WRONG BASIS: the number
  is genuine, the parse is confident, and only the arithmetic is off - so bands, freshness and factor-rails
  on the CAPTURE side all pass. Two shipped live in one week: Hy-Vee's per-pound rate divided by the package
  weight (corned beef brisket published $3.15/lb against a real $8.99), and a Sam's 3-pack whose 29 oz TOTAL
  was multiplied into an 87 oz each-size (cheapest furniture polish in Omaha at a third of its real price).
  A basis error moves a price by a FACTOR, which is exactly what wins the "cheapest store" verdict, so this
  class lands preferentially on the number a shopper acts on.

  WHAT IT CHECKS
  A store's own unit price is an INDEPENDENT statement of the exact quantity the board computes, and we get
  it from two places:
    - a captured FIELD: Walmart (wm_unit_price, ~1330 rows) and Sam's Club (sams_unit_price, all rows);
    - PRINTED IN THE SIZE TEXT: Hy-Vee's random-weight rows read "2.85 lbs ($8.99/lb)". This is the only
      unit price the browser stores hand us, and reading it is what makes the guard cover Hy-Vee - it is
      the source that catches the corned-beef-brisket bug (ours $3.15/lb vs their own printed $8.99).
  When our per-unit and theirs disagree by a FACTOR, one of the two is wrong and a human has to say which.

  Rounding: stores quantize to whole cents, so on a sub-cent item ($0.0053/cotton swab vs their "$0.01/ea")
  the rounding IS the entire disagreement. Anything inside half a cent is treated as agreement.

  IT DOES NOT ASSUME THE STORE IS RIGHT. Walmart's own unit price is provably wrong sometimes (the
  DERIVED-SIZE lesson: the product NAME wins), so a finding means "these two disagree by a factor, decide",
  never "publish the store's number". Reviewed disagreements go in basis-reconcile-allowlist.json with the
  reason, the same way coverage-gap-allowlist.json works.

  Advisory by default so a store's own bad unit price cannot block the board; -Strict exits 2 for wiring
  into a gate once the allowlist has settled.

  COVERAGE (be honest about it): ~300 of ~3460 priced cells are checkable today, because only Walmart, Sam's
  and Hy-Vee's weighted rows state a unit price at all. Baker's, Family Fare, Fareway and Aldi captures
  record none, so their cells get no proof check. Recording current_price/unit_price at capture time for
  those stores is the single change that would widen this guard the most - see the Kroger API and Freshop
  feeds, which both carry one we are not keeping. The pack-count heuristic in audit-pack-basis.ps1 is the
  companion tier that needs no store cooperation.

  Usage: audit-basis-reconcile.ps1 [-CompareFile <path>] [-Factor 1.5] [-Strict]
#>
param([string]$CompareFile = "", [double]$Factor = 1.5, [switch]$Strict)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$OutDir = Join-Path $root 'out'
if (-not $CompareFile) {
  $CompareFile = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
}

# local unit conversion (kept small and self-contained on purpose: this audit must still run if
# compare-deals.ps1 is mid-edit, since a broken engine is exactly when you want the reconciler)
function ToUnit([double]$num, [string]$token, [string]$unit) {
  $t = $token.ToLower().Trim().TrimEnd('.')
  switch ($unit) {
    'lb'     { if ($t -match '^(lb|lbs|pound|pounds)$') { return $num }
               if ($t -match '^(oz|ounce|ounces)$')     { return $num * 16.0 }   # $/oz -> $/lb
               return $null }
    'oz'     { if ($t -match '^(oz|ounce|ounces|fl\s*oz|floz)$') { return $num }
               if ($t -match '^(lb|lbs|pound|pounds)$')          { return $num / 16.0 }
               return $null }
    'floz'   { if ($t -match '^(fl\s*oz|floz|oz|ounce|ounces)$') { return $num }
               if ($t -match '^(gal|gallon|gallons)$')           { return $num / 128.0 }
               if ($t -match '^(qt|quart|quarts)$')              { return $num / 32.0 }
               return $null }
    'gallon' { if ($t -match '^(gal|gallon|gallons)$')           { return $num }
               if ($t -match '^(fl\s*oz|floz|oz|ounce|ounces)$') { return $num * 128.0 }
               return $null }
    'each'   { if ($t -match '^(ea|each|ct|count|pk|pack)$')     { return $num }
               return $null }
    'dozen'  { if ($t -match '^(dozen|doz)$')                    { return $num }
               if ($t -match '^(ea|each|ct|count)$')             { return $num * 12.0 }
               return $null }
  }
  return $null
}
function NormName([string]$s) { return (($s -replace '[^a-zA-Z0-9]', '').ToLower()) }

# ---- index every store-published unit price we have, by store + normalized item name ----
$storeUnit = @{}
$fieldByStore = @{ 'Walmart' = 'wm_unit_price'; "Sam's Club" = 'sams_unit_price' }
$scanned = 0
$srcFiles = @()
$srcFiles += @(Get-ChildItem (Join-Path $OutDir 'regular\*-regular-*.json') -ErrorAction SilentlyContinue)
$srcFiles += @(Get-ChildItem (Join-Path $OutDir '*\*-deals-*.json') -ErrorAction SilentlyContinue)
# newest first, so the "first non-empty wins" rule below keeps the freshest reading of a product
$srcFiles = @($srcFiles | Sort-Object Name -Descending)
foreach ($f in $srcFiles) {
  try { $d = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
  foreach ($r in @(if ($d.deals) { $d.deals } else { $d })) {
    $st = [string]$r.store
    if (-not $fieldByStore.ContainsKey($st)) { continue }
    $fld = $fieldByStore[$st]
    if (-not $r.PSObject.Properties[$fld]) { continue }
    $up = [string]$r.$fld
    if (-not $up) { continue }
    $k = $st + '|' + (NormName ([string]$r.item))
    # newest file wins; Get-ChildItem order is not guaranteed, so prefer the first non-empty and let the
    # per-cell price check below catch a stale one (a stale unit price on the SAME product is still the
    # same basis, which is all this audit reads it for)
    if (-not $storeUnit.ContainsKey($k)) { $storeUnit[$k] = @{ raw = $up; file = $f.Name }; $scanned++ }
  }
}

# ---- reviewed disagreements ----
$allow = @{}
$alf = Join-Path $root 'basis-reconcile-allowlist.json'
if (Test-Path $alf) {
  try { foreach ($a in (Get-Content $alf -Raw | ConvertFrom-Json).allow) { $allow[([string]$a.store + '|' + (NormName ([string]$a.item)))] = [string]$a.why } } catch {}
}

$doc = Get-Content $CompareFile -Raw | ConvertFrom-Json
$findings = @(); $checked = 0; $allowed = 0
foreach ($r in $doc.comparison) {
  $unit = [string]$r.unit
  foreach ($s in $r.stores) {
    $pu = [double]$s.per_unit
    if ($pu -le 0) { continue }
    $k = [string]$s.store + '|' + (NormName ([string]$s.item))
    $their = $null; $says = ''; $src = ''
    if ($storeUnit.ContainsKey($k)) {
      $m = [regex]::Match($storeUnit[$k].raw, '\$?\s*([\d.]+)\s*/\s*([a-zA-Z\s]+)')
      if ($m.Success) {
        $their = ToUnit ([double]$m.Groups[1].Value) ($m.Groups[2].Value) $unit
        $says = $storeUnit[$k].raw; $src = $storeUnit[$k].file
      }
    }
    # A store also declares its unit price by PRINTING it in the size text - Hy-Vee's random-weight rows read
    # "2.85 lbs ($8.99/lb)". That is the same independent statement as a wm_unit_price field, just inline, and
    # it is the ONLY unit price the four browser stores give us. Reading it here is what extends this guard to
    # Hy-Vee, whose per-lb-rate bug published corned beef brisket at $3.15/lb against a real $8.99.
    if ($their -eq $null) {
      $em = [regex]::Match([string]$s.size, '\(\s*\$\s*([\d.]+)\s*/\s*(lb|lbs|oz|floz|fl\s*oz|ea|each|ct)\.?\s*\)')
      if ($em.Success) {
        $their = ToUnit ([double]$em.Groups[1].Value) ($em.Groups[2].Value) $unit
        $says = '$' + $em.Groups[1].Value + '/' + $em.Groups[2].Value; $src = 'printed in the size text'
      }
    }
    if ($their -eq $null -or $their -le 0) { continue }
    $checked++
    if ($allow.ContainsKey($k)) { $allowed++; continue }
    # Stores quantize their published unit price to whole cents, so on a sub-cent item ($0.0053/swab) the
    # rounding IS the whole disagreement. Anything inside half a cent is indistinguishable, not a conflict.
    if ([math]::Abs($pu - $their) -le 0.005) { continue }
    $fac = $pu / $their
    if ($fac -lt $Factor -and $fac -gt (1.0/$Factor)) { continue }
    # name the transform when the factor is a clean integer - that is the signature of a pack-count or
    # weight basis slip, and it tells triage exactly where to look
    $hint = ''
    foreach ($n in 2,3,4,5,6,8,10,12,16,20,24) {
      if ([math]::Abs($fac - $n) -lt 0.02)     { $hint = "we are exactly ${n}x their number (a pack count applied that should not be, or a size read $n times too small)"; break }
      if ([math]::Abs($fac - (1.0/$n)) -lt 0.005) { $hint = "we are exactly 1/${n} of their number (a pack count multiplied into the size that was already a total)"; break }
    }
    $findings += [pscustomobject]@{
      id = [string]$r.id; commodity = [string]$r.commodity; store = [string]$s.store; unit = $unit
      ours = [math]::Round($pu,4); theirs = [math]::Round($their,4); factor = [math]::Round($fac,3)
      store_says = $says; our_basis = [string]$s.basis; ad = [string]$s.ad; size = [string]$s.size
      hint = $hint; item = [string]$s.item; source = $src
    }
  }
}

$rep = Join-Path $OutDir 'basis-reconcile.json'
([pscustomobject]@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); compare_file = (Split-Path $CompareFile -Leaf)
                    unit_prices_indexed = $scanned; cells_checked = $checked; allowlisted = $allowed
                    factor_threshold = $Factor; finding_count = $findings.Count; findings = $findings } |
  ConvertTo-Json -Depth 5) | Set-Content $rep -Encoding UTF8

Write-Output ("basis-reconcile: checked $checked cell(s) against the store's own unit price ($scanned indexed, $allowed allowlisted)")
if ($findings.Count -eq 0) { Write-Output '  ok - every checkable cell agrees with the store within the factor rail'; exit 0 }
Write-Output ("  " + $findings.Count + " cell(s) disagree with the STORE'S OWN unit price by a factor - one of the two is wrong:")
foreach ($f in ($findings | Sort-Object { -[math]::Abs([math]::Log($_.factor)) })) {
  Write-Output ("  {0,-24} {1,-11} ours {2}/{3}  vs store {4}  (x{5}) | basis '{6}' | {7}" -f `
    $f.id, $f.store, $f.ours, $f.unit, $f.store_says, $f.factor, $f.our_basis, $f.item)
  if ($f.hint) { Write-Output ("      -> " + $f.hint) }
}
Write-Output ("  report: " + $rep)
Write-Output '  Decide per cell: fix the data/parse, or record the store''s own number as wrong in basis-reconcile-allowlist.json with the reason.'
if ($Strict) { exit 2 }
exit 0
