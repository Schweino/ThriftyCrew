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
    - DERIVED FROM THE STORE'S OWN PACKAGE WEIGHT: Kroger returns no unit price at all (pull-regular-bakers
      -api.ps1 says so in its own header), but it does return itemInformation.netWeight. Package price over
      the store's stated package weight IS a per-unit price, and it is independent of every size string WE
      parse, so it gives Baker's - the largest store on the board - a proof check it has never had. The
      resolver already uses netWeight to settle the "4 ct / 16 oz" ambiguity at CAPTURE time, but the
      shipped cell is not the captured row: carry-forward, an override or a board merge can move the size
      or price downstream. Two guardrails, both mirroring the resolver: skip soldBy=WEIGHT rows, whose
      netWeight is the random tray weight (Tyson breast reads 22.56 lb), and skip volume commodities,
      because netWeight is MASS and comparing it to fl oz would flag every dense or light liquid.
  When our per-unit and theirs disagree by a FACTOR, one of the two is wrong and a human has to say which.

  Rounding: stores quantize to whole cents, so on a sub-cent item ($0.0053/cotton swab vs their "$0.01/ea")
  the rounding IS the entire disagreement. Anything inside half a cent is treated as agreement.

  IT DOES NOT ASSUME THE STORE IS RIGHT. Walmart's own unit price is provably wrong sometimes (the
  DERIVED-SIZE lesson: the product NAME wins), so a finding means "these two disagree by a factor, decide",
  never "publish the store's number". Reviewed disagreements go in basis-reconcile-allowlist.json with the
  reason, the same way coverage-gap-allowlist.json works.

  Advisory by default so a store's own bad unit price cannot block the board; -Strict exits 2 for wiring
  into a gate once the allowlist has settled.

  COVERAGE (be honest about it): Walmart, Sam's, Hy-Vee's weighted rows and now Baker's packaged goods are
  checkable. Family Fare, Fareway and Aldi are NOT, and cannot be from their APIs: Freshop exposes a field
  named unit_price, but it returns a COPY OF THE ITEM PRICE (a 16 oz jar at $2.29 reports "2.29", not
  "0.143"). Capturing that would be worse than capturing nothing - all ~2750 of their cells would "agree"
  with us by construction and this guard would report clean while checking nothing. A check is only worth
  anything when the number is genuinely independent of our own arithmetic. Their real per-unit price is on
  the shelf tag in the storefront DOM, so it is browser-capture work, not an API field.
  The pack-count heuristic in audit-pack-basis.ps1 is the companion tier that needs no store cooperation.

  Usage: audit-basis-reconcile.ps1 [-CompareFile <path>] [-Factor 1.5] [-Strict]
#>
# -ReportDir: where basis-reconcile.json is written. Defaults to out\, which is the live daily behaviour and
# is unchanged. It exists so a FIXTURE run can park its report beside its fixture instead of overwriting the
# live one: test-auditors passes fixture boards via -CompareFile but the report path was hardcoded, so every
# harness run replaced the real board's reconciliation with a fixture's.
param([string]$CompareFile = "", [string]$RawDir = "", [double]$Factor = 1.5, [switch]$Strict, [string]$ReportDir = "")
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
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
# Kroger's itemInformation.netWeight arrives as "0.5 [lb_av]" / "12 [oz_av]" / "1.2 [kg]". Returns ounces.
function NetOz([string]$raw) {
  if (-not $raw) { return $null }
  $m = [regex]::Match($raw, '([0-9]+(?:\.[0-9]+)?)\s*\[\s*(lb_av|oz_av|kg|g)\s*\]')
  if (-not $m.Success) { return $null }
  $v = [double]$m.Groups[1].Value
  switch ($m.Groups[2].Value) {
    'lb_av' { return $v * 16.0 }
    'oz_av' { return $v }
    'kg'    { return $v * 35.274 }
    'g'     { return $v / 28.3495 }
  }
  return $null
}

# ---- index every store-published unit price we have, by store + normalized item name ----
$storeUnit = @{}
$fieldByStore = @{ 'Walmart' = 'wm_unit_price'; "Sam's Club" = 'sams_unit_price' }
$scanned = 0
# -RawDir points the store-capture scan somewhere else, so test-auditors can exercise the cross-file join
# (Baker's netWeight) against a frozen fixture instead of live captures. Defaults to the real out\ dir.
$RawRoot = if ($RawDir) { $RawDir } else { $OutDir }
$srcFiles = @()
$srcFiles += @(Get-ChildItem (Join-Path $RawRoot 'regular\*-regular-*.json') -ErrorAction SilentlyContinue)
$srcFiles += @(Get-ChildItem (Join-Path $RawRoot '*\*-deals-*.json') -ErrorAction SilentlyContinue)
# newest first, so the "first non-empty wins" rule below keeps the freshest reading of a product
$srcFiles = @($srcFiles | Sort-Object Name -Descending)
foreach ($f in $srcFiles) {
  try { $d = Read-JsonFile $f.FullName } catch { continue }
  foreach ($r in @(if ($d.deals) { $d.deals } else { $d })) {
    $st = [string]$r.store
    if (-not $fieldByStore.ContainsKey($st)) { continue }
    $fld = $fieldByStore[$st]
    if (-not $r.PSObject.Properties[$fld]) { continue }
    $up = [string]$r.$fld
    if (-not $up) { continue }
    $k = $st + '|' + (NormName ([string]$r.item))
    # A NAME IS NOT A KEY. Stores sell the single and the multipack under one identical name - "Kroger Brown
    # Gravy Mix" is both a 0.87 oz packet and a 4 ct / 0.87 oz box, and Sam's listed the same Pledge 3-pack
    # twice. Keeping only the first match compared a multipack cell against the single's numbers and invented
    # a clean 4x "disagreement" out of two perfectly correct rows. Keep them ALL and disambiguate by size at
    # lookup time; when that cannot separate them, check nothing rather than guess.
    if (-not $storeUnit.ContainsKey($k)) { $storeUnit[$k] = New-Object System.Collections.ArrayList }
    [void]$storeUnit[$k].Add(@{ raw = $up; file = $f.Name; size = (NormName ([string]$r.size)) })
    $scanned++
  }
}

# ---- Baker's has NO unit price (Kroger's API does not return one - see pull-regular-bakers-api.ps1's own
# header). What it does return is itemInformation.netWeight, the store's own statement of what the package
# weighs, which is independent of every size string WE parse. Package weight + package price is a per-unit
# price, so it slots in here as a third source and gives the estate's largest store (6,800+ rows) a proof
# check it has never had. Only for PACKAGED goods: on a per-pound card soldBy=WEIGHT and netWeight is the
# random tray weight (Tyson breast reads 22.56 lb), so it is meaningless - the same rule the size resolver
# applies. Only for MASS commodities too: netWeight is mass, and using it on a fl-oz commodity would compare
# weight against volume and flag every dense or light liquid.
$bakersWeight = @{}
foreach ($f in $srcFiles) {
  if ($f.Name -notmatch '^bakers-') { continue }
  try { $d = Read-JsonFile $f.FullName } catch { continue }
  foreach ($r in @(if ($d.deals) { $d.deals } else { $d })) {
    if (-not $r.PSObject.Properties['net_weight']) { continue }
    $nz = NetOz ([string]$r.net_weight)
    if ($nz -eq $null -or $nz -le 0) { continue }
    if (([string]$r.sold_by) -eq 'WEIGHT') { continue }
    $k = "Baker's|" + (NormName ([string]$r.item))
    if (-not $bakersWeight.ContainsKey($k)) { $bakersWeight[$k] = New-Object System.Collections.ArrayList }
    [void]$bakersWeight[$k].Add(@{ oz = $nz; raw = [string]$r.net_weight; file = $f.Name; size = (NormName ([string]$r.size)) })
  }
}

# ---- reviewed disagreements ----
$allow = @{}
$alf = Join-Path $root 'basis-reconcile-allowlist.json'
if (Test-Path $alf) {
  try { foreach ($a in (Read-JsonFile $alf).allow) { $allow[([string]$a.store + '|' + (NormName ([string]$a.item)))] = [string]$a.why } } catch {}
}

# Pick the ONE capture row that matches this board cell. Unique name -> use it. Several rows under one name
# -> the cell's own size must single one out. Anything else returns $null and the cell is simply not checked:
# a guard that guesses which product it is looking at is worse than a guard that admits it cannot tell.
function PickRow($list, [string]$cellSize) {
  $rows = @($list)
  if ($rows.Count -eq 0) { return $null }
  if ($rows.Count -eq 1) { return $rows[0] }
  $sz = NormName $cellSize
  $hit = @($rows | Where-Object { $_.size -eq $sz })
  if ($hit.Count -eq 1) { return $hit[0] }
  return $null
}

$doc = Read-JsonFile $CompareFile
$findings = @(); $checked = 0; $allowed = 0
foreach ($r in $doc.comparison) {
  $unit = [string]$r.unit
  foreach ($s in $r.stores) {
    $pu = [double]$s.per_unit
    if ($pu -le 0) { continue }
    $k = [string]$s.store + '|' + (NormName ([string]$s.item))
    $their = $null; $says = ''; $src = ''
    if ($storeUnit.ContainsKey($k)) {
      $pick = PickRow $storeUnit[$k] ([string]$s.size)
      if ($pick) {
        $m = [regex]::Match($pick.raw, '\$?\s*([\d.]+)\s*/\s*([a-zA-Z\s]+)')
        if ($m.Success) {
          $their = ToUnit ([double]$m.Groups[1].Value) ($m.Groups[2].Value) $unit
          $says = $pick.raw; $src = $pick.file
        }
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
    # Baker's: price-per-package-weight, from Kroger's own netWeight. Mass commodities only, and only a plain
    # "$X" ad price - a multibuy string is not a package price and would compare two different things.
    # ONLY for the ambiguous compound shape ("4 pk 16 oz"), never for a plain single-quantity label.
    # Measured on 6,857 live Kroger rows 2026-07-28: trusting netWeight on ordinary labels produced 32
    # findings and it was WRONG in every case anyone could adjudicate - the product name backed us 4 times
    # out of 4 (apples "5 Pound" vs netWeight 3 lb; blackberries "6 OZ" vs 1 lb; clementines "5 lb Bag" vs
    # 1 lb; minced garlic "8 oz" vs TEN POUNDS), and the rest were drained or per-item weights (a 12 oz tuna
    # can reporting its 5 oz drained weight). The size resolver in pull-regular-bakers-api.ps1 already knew
    # this: it uses netWeight ONLY to choose between two readings of a compound shape, demands tolerance AND
    # separation, and refuses on a dead heat. This audit ignored that and got the noise it deserved.
    # So: a single-quantity label is unambiguous and the label wins. netWeight speaks only where the shape
    # is genuinely ambiguous, which is the Kerrygold class this check exists for.
    $compound = ([string]$s.size) -match '^\s*\d+(?:\.\d+)?\s*[- ]?\s*(?:ct|count|pk|packs?)\D+\d+(?:\.\d+)?\s*(?:oz|ounce|ounces|lbs?|pound)\b'
    if ($their -eq $null -and $compound -and $bakersWeight.ContainsKey($k) -and ($unit -eq 'oz' -or $unit -eq 'lb')) {
      $am = [regex]::Match([string]$s.ad, '^\s*\$?([\d.]+)\s*$')
      $bw = PickRow $bakersWeight[$k] ([string]$s.size)
      if ($am.Success -and $bw) {
        $pkg = [double]$am.Groups[1].Value
        $nz = [double]$bw.oz
        if ($pkg -gt 0 -and $nz -gt 0) {
          $their = if ($unit -eq 'oz') { $pkg / $nz } else { $pkg / ($nz / 16.0) }
          $says = '$' + $pkg + ' per its own netWeight ' + $bw.raw
          $src  = $bw.file + ' (netWeight)'
        }
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

$rep = Join-Path $(if ($ReportDir) { $ReportDir } else { $OutDir }) 'basis-reconcile.json'
([pscustomobject]@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); compare_file = (Split-Path $CompareFile -Leaf)
                    unit_prices_indexed = $scanned; cells_checked = $checked; allowlisted = $allowed
                    factor_threshold = $Factor; finding_count = $findings.Count; findings = $findings } |
  ConvertTo-Json -Depth 5) | Set-Content $rep -Encoding UTF8

Write-Output ("basis-reconcile: checked $checked cell(s) against the store's own unit price ($scanned indexed, $allowed allowlisted)")
if ($findings.Count -eq 0) {
  Write-Output '  ok - every checkable cell agrees with the store within the factor rail'
  Write-GuardComplete -Name 'basis-reconcile' -Summary ("checked={0} findings=0" -f $checked)
  exit 0
}
Write-Output ("  " + $findings.Count + " cell(s) disagree with the STORE'S OWN unit price by a factor - one of the two is wrong:")
foreach ($f in ($findings | Sort-Object { -[math]::Abs([math]::Log($_.factor)) })) {
  Write-Output ("  {0,-24} {1,-11} ours {2}/{3}  vs store {4}  (x{5}) | basis '{6}' | {7}" -f `
    $f.id, $f.store, $f.ours, $f.unit, $f.store_says, $f.factor, $f.our_basis, $f.item)
  if ($f.hint) { Write-Output ("      -> " + $f.hint) }
}
Write-Output ("  report: " + $rep)
Write-Output '  Decide per cell: fix the data/parse, or record the store''s own number as wrong in basis-reconcile-allowlist.json with the reason.'
Write-GuardComplete -Name 'basis-reconcile' -Summary ("checked={0} findings={1}" -f $checked, $findings.Count)
if ($Strict) { exit 2 }
exit 0
