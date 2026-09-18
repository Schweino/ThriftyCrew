<#
  audit-household-in-food.ps1

  Bug class found 2026-07-14: "Lysol Mango & Hibiscus Bathroom Cleaner" was matching the MANGOES
  commodity, because household products are routinely named after the fruit/herb used as their SCENT
  ("Lemon Scent Furniture Polish", "Lavender Floor Cleaner", "Orange Degreaser"). A cleaner landing in
  a produce row is always wrong and is invisible to a per-unit sanity band.

  This sweeps EVERY row of EVERY store regular file: any product whose name is unmistakably a
  household/cleaning item but which resolves to a commodity OUTSIDE the Household category is a bug.

  This is guard 2 in guards.ps1, a HARD check: exit 2 holds the board. So a finding here is not
  advisory, and widening what it reads or which words it knows can hold a board that was publishing.

  -SelfTest (2026-09-18, backlog I217) runs frozen fixtures against a temp tree and a fixture
  commodity list, never the live out\ files. Until then the script had no self-test at all, so a word
  dropped from the signal or a file family dropped from the sweep could not go red anywhere.

  SCOPE OF A CLEAN REPORT: unsound. It sees only names that spell one of $HOUSEHOLD_SIGNAL's words, in
  the files Get-HifInputFiles returns, so a clean report proves nothing about a product named some
  other way or a row arriving by another file. A finding is real: the name spells a non-food word AND
  the engine's own matcher puts it in an edible commodity.
#>
[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = $PSScriptRoot

# THE EXCLUDE LIST IS A LIBRARY NOW (2026-09-09, backlog I82). This used to regex an array
# literal out of compare-deals.ps1's source and Invoke-Expression it. Same list, same rule -
# no copy, no drift - but a dot-source cannot pick up a partial block or a renamed variable.
. (Join-Path $root 'global-exclude-lib.ps1')
$GLOBAL_EXCLUDE = Get-TcGlobalExclude
$commodities = Read-JsonFile (Join-Path $root 'commodities.json')
$cats = (Read-JsonFile (Join-Path $root 'categories.json')).categories
# A cleaning product legitimately belongs in ANY non-edible category, not just Household
# (a "Tongue Cleaner Toothbrush" correctly lands in Personal Care). Only an EDIBLE commodity
# claiming a cleaning product is a bug.
$NONFOOD = @('Household','Personal Care','Baby','Pet')
$nonFoodIds = @($cats | Where-Object { $NONFOOD -contains $_.label } | ForEach-Object { $_.commodities } )

function Match-Category($name) {
  $n = $name.ToLower()
  $ghits = @(); foreach ($g in $GLOBAL_EXCLUDE) { if ($n -match $g) { $ghits += $g } }
  foreach ($c in $commodities) {
    $hit = $false
    foreach ($inc in $c.include) { if ($n -match $inc) { $hit = $true; break } }
    if (-not $hit) { continue }
    if ($ghits.Count) {
      $relax = @($c.relax_global | Where-Object { $_ })
      $blocked = $false
      foreach ($g in $ghits) { if ($relax -notcontains $g) { $blocked = $true; break } }
      if ($blocked) { continue }
    }
    $bad = $false
    foreach ($exc in $c.exclude) { if ($n -match $exc) { $bad = $true; break } }
    if ($bad) { continue }
    return $c.id
  }
  return $null
}

# names that can only be a household/cleaning product
$HOUSEHOLD_SIGNAL = '(?i)(cleaner|detergent|\bbleach\b|disinfect|degreaser|furniture\s+polish|air\s+freshener|insecticide|roach|drain\s+opener|laundry|dish\s*soap|fabric\s+softener|dryer\s+sheet|toilet|scrubbing\s+bubbles|\blysol\b|\bdrano\b|\bpledge\b|\bwindex\b|\bclorox\b|\bfebreze\b|\bswiffer\b|\bcomet\b|\bajax\b)'

# The files the sweep reads, under a root, so the self-test can point it at a temp tree.
function Get-HifInputFiles([string]$Root) {
  $files = @()
  foreach ($f in Get-ChildItem (Join-Path $Root 'out\regular\*-regular-*.json') -ErrorAction SilentlyContinue) {
    # only the newest file per store is what compare-deals actually reads
    $prefix = ($f.BaseName -replace '-regular-.*$', '')
    $newest = Get-ChildItem (Join-Path $Root ('out\regular\' + $prefix + '-regular-*.json')) |
              Sort-Object Name -Descending | Select-Object -First 1
    if ($f.FullName -ne $newest.FullName) { continue }
    $files += $f
  }
  return ,$files
}

# One pass over the files. Returns the rows scanned and one finding per cleaning product in an EDIBLE
# commodity; it prints nothing, so the self-test can read the answer instead of parsing text.
function Invoke-HifSweep([string]$Root) {
  $found = @(); $n = 0
  $inputs = Get-HifInputFiles $Root
  foreach ($f in @($inputs)) {
    $doc = Read-JsonFile $f.FullName
    foreach ($d in $doc.deals) {
      $name = [string]$d.item
      if (-not $name) { continue }
      $n++
      if ($name -notmatch $HOUSEHOLD_SIGNAL) { continue }
      $owner = Match-Category $name
      if (-not $owner) { continue }                       # unmatched = harmless, it just never lands
      if ($nonFoodIds -contains $owner) { continue }      # correctly in a non-edible category
      $st = [string]$doc.store; if (-not $st) { $st = [string]$d.store }
      $found += [pscustomobject]@{ store = $st; name = $name; owner = $owner; file = $f.Name }
    }
  }
  return [pscustomobject]@{ scanned = $n; findings = $found }
}

if ($SelfTest) {
  # Fixtures only: a temp tree per run and a fixture commodity list, so no live board file is read and
  # a change to commodities.json cannot quietly turn a case into one that can no longer form.
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('hif-st-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
  $pass = 0; $fail = 0; $ran = 0; $EXPECTED = 6   # a literal list knows its own number
  function Check([string]$label, [bool]$ok) {
    $script:ran++
    if ($ok) { $script:pass++; Write-Output ('  ok    ' + $label) } else { $script:fail++; Write-Output ('  FAIL  ' + $label) }
  }
  function Write-HifFixture([string]$rel, $rows, [string]$store) {
    $p = Join-Path $tmp $rel
    New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) | Out-Null
    $doc = [ordered]@{ deals = @($rows | ForEach-Object { [ordered]@{ item = $_; store = $store } }) }
    if ($store) { $doc.store = $store }
    [IO.File]::WriteAllText($p, ($doc | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
  }
  try {
    # array order matters and is the founding shape: a fruit rule ahead of the soap rule claims the soap
    $script:GLOBAL_EXCLUDE = @()
    $script:commodities = @(
      [pscustomobject]@{ id = 'mangoes';        include = @('mango');     exclude = @(); relax_global = @() },
      [pscustomobject]@{ id = 'strawberries';   include = @('strawberr'); exclude = @(); relax_global = @() },
      [pscustomobject]@{ id = 'apples';         include = @('\bapples?\b'); exclude = @(); relax_global = @() },
      [pscustomobject]@{ id = 'crescent-rolls'; include = @('crescent');  exclude = @(); relax_global = @() },
      [pscustomobject]@{ id = 'cleaner';        include = @('cleaner');   exclude = @(); relax_global = @() },
      [pscustomobject]@{ id = 'dish-soap';      include = @('dish\s*soap', '\bdawn\b'); exclude = @(); relax_global = @() }
    )
    $script:nonFoodIds = @('cleaner', 'dish-soap')

    Write-HifFixture 'out\regular\walmart-regular-2026-01-01.json' @('Lysol Mango Cleaner OLD FILE') 'Walmart'
    Write-HifFixture 'out\regular\walmart-regular-2026-01-02.json' @(
      'Lysol Mango & Hibiscus Bathroom Cleaner 32 fl oz',
      'Fresh Mangoes',
      'Pillsbury Original Crescent Rolls 8 ct',
      'Lysol Lemon Bathroom Cleaner'
    ) 'Walmart'
    $r = Invoke-HifSweep $tmp
    $mango = @($r.findings | Where-Object { $_.name -like 'Lysol Mango & Hibiscus*' })

    Check 'MUST FIRE: a Lysol MANGO cleaner in a regular file is flagged in the edible commodity mangoes' ($mango.Count -eq 1 -and $mango[0].owner -eq 'mangoes')
    Check 'CLEAN TWIN: a real food row (Fresh Mangoes) is scanned and still routes to mangoes' ($r.scanned -eq 4 -and (Match-Category 'Fresh Mangoes') -eq 'mangoes')
    Check 'MUST NOT FIRE: a food word that CONTAINS a household word (Crescent holds scent) is not flagged' (@($r.findings | Where-Object { $_.name -like '*Crescent*' }).Count -eq 0)
    Check 'MUST NOT FIRE: a cleaner that lands in a NON-food commodity is not flagged' (@($r.findings | Where-Object { $_.name -like 'Lysol Lemon*' }).Count -eq 0)
    Check 'MUST NOT FIRE: an older file for the same store is not read (newest per store only)' (@($r.findings | Where-Object { $_.name -like '*OLD FILE*' }).Count -eq 0)
    Check 'exactly one finding over the fixture tree' (@($r.findings).Count -eq 1)
  } catch {
    $fail++; Write-Output ('  FAIL  the self-test threw: ' + $_.Exception.Message)
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($ran -ne $EXPECTED) { $fail++; Write-Output ("  FAIL  ran $ran of $EXPECTED cases - a case did not run") }
  Write-Output ''
  if ($fail -eq 0) { Write-Output ("audit-household-in-food self-test PASS ($pass of $EXPECTED cases)"); exit 0 }
  Write-Output ("audit-household-in-food self-test FAIL ($fail failure(s), $pass of $EXPECTED passed)"); exit 1
}

$res = Invoke-HifSweep $root
$scanned = $res.scanned
$bugs = @($res.findings).Count
foreach ($b in @($res.findings)) {
  Write-Output ("  BUG  [{0}] '{1}'" -f $b.store, $b.name)
  Write-Output ("        -> lands in EDIBLE commodity '{0}'" -f $b.owner)
}
Write-Output ''
Write-Output ("scanned $scanned rows")
if ($scanned -eq 0) {
  Write-Output 'HOUSEHOLD-IN-FOOD AUDIT BLIND: examined ZERO rows - out\regular matched no canonical store file, or every newest-per-store pick carried no .deals rows (a puller renaming the deals array is the guard-11 failure mode). The cleaner-in-a-food-commodity invariant was NOT tested this run. Unknown is not a pass.'
  exit 3
}
if ($bugs -eq 0) { Write-Output 'HOUSEHOLD-IN-FOOD AUDIT OK: no cleaning product is sitting in a food commodity.'; exit 0 }
Write-Output ("HOUSEHOLD-IN-FOOD AUDIT FAILED: $bugs row(s). Board NOT safe to publish."); exit 2

