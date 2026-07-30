<#
  audit-food-category.ps1 - BLOCKING guard: no FOOD commodity may publish a cell whose matched product is a
  wrong-CLASS product (beverage / baby food / pet / household / flavored bakery carrier / flavored dairy /
  candy). This is the guard the blueberries bug proved we needed: Family Fare blueberries went LIVE priced as a
  "Bai Brasilia Blueberry Antioxidant BEVERAGE" and nothing caught it - audit-household-in-food only knows
  household products, and the factor guard only sees link disagreement. A wrong-class match is usually CHEAPER
  than the real item, so it wins the cheapest slot and looks like a great deal. That is a wrong product on the
  board, which is worse than no product.

  Reads the SAME library as apply-category-excludes.ps1 and build-vet-sheet.ps1 (category-excludes.json), so the
  guard, the baked-in excludes, and the review sheet can never disagree about what "wrong class" means.

  Scope: every priced cell (everyday AND sale) in the newest comparison + recipe-board. Commodity class scoping
  comes from categories.json (a commodity in Pet/Baby/Household/Personal Care is never scanned - its category IS
  its class). Recipe-board ids that aren't in categories.json get the universal classes only (every recipe
  ingredient is edible, so babyfood/pet/household tokens are always wrong there).

  food-class-allowlist.json is the reviewed-exception valve ([{id,store,pattern,reason}]) so a judged-legitimate
  name can never deadlock the daily publish. Exit 0 = clean, 2 = wrong-class match found (do not publish),
  3 = BLIND (zero priced cells scanned - the guard proved nothing).
#>
param([string]$OutDir = "")
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }

$lib = Get-Content (Join-Path $root 'category-excludes.json') -Raw | ConvertFrom-Json
$cat = @{}
foreach ($c in (Get-Content (Join-Path $root 'categories.json') -Raw | ConvertFrom-Json).categories) {
  foreach ($id in @($c.commodities)) { $cat[[string]$id] = [string]$c.label }
}
$allow = @()
$af = Join-Path $root 'food-class-allowlist.json'
# NOTE: assign the parse result and let foreach unwrap it - @(pipe | ConvertFrom-Json) NESTS a JSON array in
# PS 5.1 (one element = the whole array), which would make every allowlist entry invisible once populated.
if (Test-Path $af) { $parsedAllow = Get-Content $af -Raw | ConvertFrom-Json; foreach ($a in $parsedAllow) { $allow += $a } }

function ClassesFor([string]$label) {
  if (-not $label) { return @($lib.universal_for_unknown) }
  foreach ($a in $lib.apply) { if ($label -match [string]$a.categories) { return @($a.classes) } }
  return @()   # Household / Personal Care / Baby / Pet: the category IS the class - never scanned
}

$files = @()
$cmpF = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if ($cmpF) { $files += $cmpF.FullName }
$rb = Join-Path $OutDir 'recipe-board.json'
if (Test-Path $rb) { $files += $rb }

$find = New-Object System.Collections.Generic.List[object]
$scanned = 0
foreach ($f in $files) {
  foreach ($it in (Get-Content $f -Raw | ConvertFrom-Json).comparison) {
    $id = [string]$it.id
    $classes = ClassesFor $cat[$id]
    if (-not $classes -or @($classes).Count -eq 0) { continue }
    foreach ($s in $it.stores) {
      if ([double]$s.per_unit -le 0) { continue }
      $nm = [string]$s.item
      if (-not $nm) { continue }
      $scanned++
      foreach ($cl in $classes) {
        $ex = [string]$lib.exempt.$cl
        if ($ex -and ($id -match $ex)) { continue }
        foreach ($pat in @($lib.classes.$cl)) {
          if ($nm -imatch $pat) {
            $skip = $false
            foreach ($al in $allow) {
              if (([string]$al.id -eq $id) -and ([string]$al.store -eq [string]$s.store) -and ((-not $al.pattern) -or ($nm -imatch [string]$al.pattern))) { $skip = $true; break }
            }
            if (-not $skip) { $find.Add([pscustomobject]@{ id=$id; store=[string]$s.store; class=$cl; pattern=$pat; item=$nm }) }
            break   # one finding per class per cell is enough
          }
        }
      }
    }
  }
}

if ($find.Count) {
  Write-Output ("FOOD-CLASS AUDIT FAILED: " + $find.Count + " cell(s) publish a wrong-class product:")
  foreach ($x in $find) { Write-Output ("  BUG  {0,-22} [{1,-12}] class={2,-14} '{3}'" -f $x.id, $x.store, $x.class, $x.item) }
  Write-Output "Fix the match (include/exclude in commodities.json + re-run compare-deals), or add a REVIEWED exception to food-class-allowlist.json."
  exit 2
}
if ($scanned -eq 0) {
  $seen = if (@($files).Count) { ((@($files) | ForEach-Object { Split-Path $_ -Leaf }) -join ', ') } else { '(none)' }
  Write-Output ("FOOD-CLASS AUDIT BLIND: examined ZERO priced cells. Board files read: " + $seen + " from '" + $OutDir + "'. Either no comparison-*.json/recipe-board.json was found (:45 swallows a missing dir with -ErrorAction SilentlyContinue), or the newest-by-NAME pick has an empty or renamed .comparison array (a stray non-dated comparison-*.json outranks every dated board). The blueberries-as-Bai-beverage guard checked nothing - unknown is not a pass.")
  exit 3
}
Write-Output ("ok - no food commodity matched a beverage/baby-food/pet/household/bakery-carrier/dairy-carrier/candy product ($scanned priced cells scanned)")
exit 0
