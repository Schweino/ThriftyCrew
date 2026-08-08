<#
  import-instacart-batch.ps1 - generalized importer for Instacart storefront captures (Aldi, Fareway) in the
  id\t name~~price~~size | ... format. Instacart tiles jam badge text ("Best seller","Store choice"), estimated
  by-weight pricing ("per pound$899/lb"), and sale "Original Price: $X.XX" into the name field, and often omit
  a clean size - all cleaned/guarded here. compare-deals matches by rule. price_mode must be IN-STORE (Aldi OLA
  42 / Fareway In-Store) - Pickup/Delivery are marked up. Usage:
    .\import-instacart-batch.ps1 -Store Fareway -Raw out\staples500\fareway-batch1-raw.txt -SourceLabel "Fareway Omaha In-Store shelf price (batch capture)"
#>
param([string]$Store, [string]$Raw, [string]$SourceLabel = "", [string]$ModeVerified = "", [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
# -Store is REQUIRED for a real run but must NOT be declared Mandatory (2026-08-08). PowerShell prompts for a
# missing mandatory parameter, so `-SelfTest` alone could never be invoked: it died with
# MissingMandatoryParameter on any non-interactive runner. This file's self-test therefore existed and had
# never once run - the "a fix needs a reachable self-test" class, found the day a change-time gate was added
# and 4 of 80 self-tests turned out to be unreachable for exactly this reason. Enforced explicitly instead.
if (-not $SelfTest -and -not $Store) { throw '-Store is required (Store and -Raw)' }
$root = $PSScriptRoot
$today = (Get-Date).ToString('yyyy-MM-dd')
$regDir = Join-Path $root 'out\regular'
if (-not $SourceLabel) { $SourceLabel = "$Store In-Store shelf price (batch capture)" }
$prefix = switch ($Store) { 'Aldi' {'aldi-regular'} 'Fareway' {'fareway-regular'} default { ($Store.ToLower() -replace '[^a-z0-9]', '') + '-regular' } }

# ---- THE MODE GATE (2026-07-30). Aldi and Fareway are Instacart storefronts whose DEFAULT session serves a
# marked-up DELIVERY price. build-fareway-regular.ps1 was rewritten on 2026-07-15 to demand -ModeVerified for
# exactly this reason (a delivery-priced extract stamped in-store put 320 marked-up cells on the board). This
# importer defeated that gate two ways, both reproduced in a sandbox on 2026-07-30 against the shipped file:
#   NO-PREV path : wrote price_mode='in-store' with NO mode_verified. compare-deals.ps1:737 then DROPS the whole
#                  file - fail-safe, but it silently deletes the store from the board.
#   MERGE path   : copies the PREVIOUS file's envelope, so a batch capture with no mode proof at all inherits
#                  the storefront capture's proof. Seeding a prior Fareway file stamped mode_verified='2026-07-27'
#                  and importing the batch capture produced fareway-regular-2026-07-30.json carrying
#                  price_mode='in-store' mode_verified='2026-07-27' - a proof that belongs to a different
#                  capture, which both compare-deals and audit-price-mode accept.
# Fail CLOSED: a mode-sensitive store needs its OWN proof or the import does not happen.
$IB_MODE_SENSITIVE = @('Aldi', 'Fareway')
function Test-IbModeProof([string]$store, [string]$modeVerified, $sensitive) {
  if (@($sensitive) -notcontains $store) { return @{ ok = $true; verified = $modeVerified } }
  if ($modeVerified -match '^\d{4}-\d{2}-\d{2}$') { return @{ ok = $true; verified = $modeVerified } }
  return @{ ok = $false; why = ($store + " is an Instacart storefront whose delivery catalog is MARKED UP. Pass -ModeVerified <yyyy-MM-dd> naming the day THIS capture set In-Store fulfilment. Without it these rows inherit another capture's mode proof.") }
}

# ---- REPLACE-by-identity merge, LIFTED from import-walmart-batch.ps1 (backlog item 19, commit ba242914).
# One merge, one home: ADD-only on an item|size key kept BOTH a corrected row and the row it corrects, and the
# ranker then handed the cell to whichever was cheaper. The lifted version also nulls EVERY stale sibling of an
# identity, not just the first slot (the hole fixed in 5020b853) - re-implementing it here would re-fork it.
# IDENTITY IS THIS STORE'S, THE ALGORITHM IS SHARED. An Instacart capture carries no item_id, so this file
# cannot use import-walmart-batch's Get-RowKey (id, else the NAME alone) unchanged:
#   - NAME alone would let a batch row supersede rows THIS SCRIPT NEVER WROTE. The Fareway/Aldi regular files
#     are mostly storefront-builder rows (fareway 747, aldi 1664 on 2026-07-30) and two real sizes can share a
#     truncated capture name - aldi-regular-2026-07-29.json holds 2 such groups today ("Season s Choice Steamed
#     Cut Green Beans 12 oz" at 10 oz AND 15 oz; "L Oven Fresh Hot Dog Buns 12 oz" at 12 oz AND 11 oz).
#   - item|SIZE alone reproduces the ADD-only bug for the case that matters: a row whose SIZE was corrected is a
#     different key, so the wrong row it corrects stays live and rank-eligible.
# So: A ROW IS SUPERSEDED ONLY BY ITS OWN WRITER. Rows this importer wrote are keyed by NAME (a re-import
# corrects them, size change included); every other row is keyed by item|size and is therefore never replaced.
# Get-RowKey is defined HERE, BEFORE the lift, and must never be added to the lift list - the self-test fails
# if someone does.
$IB_ME = 'import-instacart-batch.ps1'
function Get-RowKey($r) {
  $mine = (([string]$r.written_by) -eq $IB_ME) -or (([string]$r.source_ad) -eq $SourceLabel)
  if ($mine) { return ('mine:' + ([string]$r.item).ToLower()) }
  return ('other:' + (([string]$r.item) + '|' + ([string]$r.size)).ToLower())
}
$ibImp = Get-Content (Join-Path $root 'import-walmart-batch.ps1') -Raw
foreach ($fn in @('Merge-IwbRows')) {
  $m = [regex]::Match($ibImp, "(?ms)^function\s+$([regex]::Escape($fn))\s*\(.*?^\}")
  if (-not $m.Success) { throw "import-instacart-batch: could not lift $fn from import-walmart-batch.ps1" }
  Invoke-Expression $m.Value
}

if ($SelfTest) {
  # Pure computation, no writes. Frozen synthetic fixtures - never regenerated from the live board.
  $fail = 0
  # MUST-FIRE: the founding bug. A mode-sensitive store imported with no capture-time mode proof.
  $m1 = Test-IbModeProof 'Fareway' '' $IB_MODE_SENSITIVE
  if (-not $m1.ok) { Write-Output 'ok    MUST-FIRE: Fareway with no -ModeVerified is refused (the 2026-07-15 delivery-price class)' }
  else { Write-Output 'FAIL  a mode-sensitive store imported with no mode proof - the price-mode gate is blind again'; $fail++ }
  $m2 = Test-IbModeProof 'Aldi' 'verified by hand' $IB_MODE_SENSITIVE
  if (-not $m2.ok) { Write-Output 'ok    MUST-FIRE: free text is not a mode proof (only a yyyy-MM-dd capture date is)' }
  else { Write-Output 'FAIL  free text accepted as a mode proof - this is the "source prose is not a guarantee" bug audit-price-mode exists to kill'; $fail++ }
  # CLEAN TWIN: a real proof passes, and a store with no fulfilment toggle was never gated.
  $t1 = Test-IbModeProof 'Fareway' '2026-07-30' $IB_MODE_SENSITIVE
  if ($t1.ok -and $t1.verified -eq '2026-07-30') { Write-Output 'ok    CLEAN TWIN: a dated -ModeVerified passes and is carried onto the file' }
  else { Write-Output 'FAIL  a proven in-store capture was refused'; $fail++ }
  $t2 = Test-IbModeProof "Baker's" '' $IB_MODE_SENSITIVE
  if ($t2.ok) { Write-Output 'ok    CLEAN TWIN: a store with no delivery/in-store split is not gated' }
  else { Write-Output 'FAIL  gated a store that has no fulfilment toggle'; $fail++ }
  # MUST-FIRE: the founding ADD-only bug. A re-import that CORRECTS A SIZE must not leave the row it corrects
  # alive - under the shipped item|size ADD-only key it did, and the ranker then took whichever was cheaper.
  $mineLbl = $SourceLabel
  $prevRows = @(
    [pscustomobject]@{ item = "Libby's Pumpkin 100% Pure Pumpkin29 oz"; size = '29 oz WRONG'; ad_price = '$3.98'; written_by = $IB_ME; source_ad = $mineLbl },
    [pscustomobject]@{ item = "Libby's Pumpkin 100% Pure Pumpkin29 oz"; size = '15 oz';       ad_price = '$3.98'; written_by = $IB_ME; source_ad = $mineLbl },
    [pscustomobject]@{ item = 'Storefront Row';                        size = '1 oz';         ad_price = '$1.00'; source_ad = 'shop.fareway.com' }
  )
  $newRow = [pscustomobject]@{ item = "Libby's Pumpkin 100% Pure Pumpkin29 oz"; size = '29 oz'; ad_price = '$3.98'; written_by = $IB_ME; source_ad = $mineLbl }
  $mr = Merge-IwbRows $prevRows @($newRow)
  $lib = @($mr.merged | Where-Object { $_.item -match 'Libby' })
  if ($mr.merged.Count -eq 2 -and $lib.Count -eq 1 -and $lib[0].size -eq '29 oz' -and $mr.replaced -eq 1 -and $mr.added -eq 0) { Write-Output 'ok    MUST-FIRE: a corrected row supersedes EVERY row this writer previously wrote for that item (size change included)' }
  else { Write-Output ("FAIL  merge is ADD-only again or left a stale sibling (total=$($mr.merged.Count) libby=$($lib.Count) repl=$($mr.replaced) add=$($mr.added))"); $fail++ }
  # CLEAN TWIN 1: another writer's row is NEVER superseded - a batch import must not eat the storefront builder's
  # rows. Two real sizes can share a truncated capture name (aldi-regular-2026-07-29.json holds 2 such groups).
  $others = @(
    [pscustomobject]@{ item = 'Season s Choice Steamed Cut Green Beans 12 oz'; size = '10 oz'; ad_price = '$1.09'; source_ad = 'everyday shelf price' },
    [pscustomobject]@{ item = 'Season s Choice Steamed Cut Green Beans 12 oz'; size = '15 oz'; ad_price = '$1.49'; source_ad = 'everyday shelf price' }
  )
  $mr3 = Merge-IwbRows $others @()
  if ($mr3.merged.Count -eq 2 -and $mr3.replaced -eq 0 -and $mr3.added -eq 0) { Write-Output 'ok    CLEAN TWIN: two real sizes sharing one storefront name both survive (identity is item|size for rows this writer did not write)' }
  else { Write-Output ("FAIL  collapsed two real sizes of another writer's rows (total=$($mr3.merged.Count))"); $fail++ }
  # CLEAN TWIN 2: a bare re-run with nothing to correct must not drop or duplicate anything.
  $mr2 = Merge-IwbRows $prevRows @()
  if ($mr2.merged.Count -eq 3 -and $mr2.added -eq 0 -and $mr2.replaced -eq 0) { Write-Output 'ok    CLEAN TWIN: uncorrected rows are preserved (no silent drops on a bare re-run)' }
  else { Write-Output "FAIL  merge altered rows with no corrections (total=$($mr2.merged.Count))"; $fail++ }
  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

$ibMode = Test-IbModeProof $Store $ModeVerified $IB_MODE_SENSITIVE
if (-not $ibMode.ok) { throw ('import-instacart-batch: ' + $ibMode.why) }

function CleanName([string]$n) {
  $n = $n -replace '(?i)^\s*(Best\s*seller|Store\s*choice|New\b|Popular|Low\s*fat|Low\s*carb|Low\s*sodium|Keto\s*diet|No\s*sugar\s*added|High\s*protein|Fan\s*favorite|Sugar\s*free)+', ''
  $n = $n -replace '(?i)(?:per\s+(?:package|pound|lb)|each)\s*(?:\(estimated\))?\s*\$\d+(?:\.\d+)?\s*(?:each|/\s*pkg|/\s*lb)?\s*(?:\(est\.?\))?', ''
  $n = $n -replace '(?i)Original\s+Price:\s*\$\d+(?:\.\d+)?(?:\$[\d.]+)?(?:\d+%\s*off)?', ''
  $n = $n -replace '\$\d+(?:\.\d+)?\s*/\s*(?:lb|pkg|oz|ea|each)\b', ''
  $n = $n -replace '\$\d+(?:\.\d+)?', ''
  $n = $n -replace '\d+%\s*off', ''
  $n = ($n -replace '\s+', ' ').Trim()
  return $n
}
function GetSize([string]$field, [string]$name) {
  if ($field -and $field.Trim()) { return $field.Trim() }
  $m = [regex]::Match($name, '(\d+(?:\.\d+)?)\s*(fl\s*oz|floz|oz|lb|ct)\b', 'IgnoreCase')
  if ($m.Success) { return ($m.Groups[1].Value + ' ' + (($m.Groups[2].Value.ToLower()) -replace '\s+', ' ')) }
  return ''
}
# a name is garbage if it has no run of >=3 letters (e.g. leftover "Original Price" junk stripped to symbols)
function GoodName([string]$n) { return ($n -and $n.Length -ge 3 -and ($n -match '[A-Za-z]{3,}')) }

# READ THE CAPTURE AS UTF-8, AND REPAIR ANYTHING ALREADY MANGLED UPSTREAM.
# A browser Blob download is UTF-8; PowerShell 5.1's Get-Content defaults to the system ANSI codepage
# (Windows-1252 here), so a bare read corrupts every non-ASCII byte and then the row is SAVED that way - the
# damage is baked into the bytes, so reading correctly later does not undo it. That shipped 16 mangled board
# rows on 2026-07-29, 6 of them CROWNS ("Member(junk)s Mark Wildflower Pure Premium Honey" was the first thing
# a shopper read on the honey row). capture-lib.ps1 fixed the four live builders; these four batch importers
# were missed, so the next staples expansion would have re-introduced it.
# Measured on the staged batch files: walmart 50 of 50 lines corrupted by the default read, bakers 40 of 50,
# aldi 2 of 49, fareway 2 of 50. Walmart hits EVERY line because its unit price carries a cent glyph - so the
# corruption lands in the PRICE field, not just the name.
# Repair-Mojibake is applied per LINE rather than per parsed name: it is a no-op on clean text (it fires only
# on a mojibake signature that round-trips through a THROWING UTF-8 decoder), so this is uniform across all
# four importers and cannot damage good data.
. (Join-Path $PSScriptRoot 'capture-lib.ps1')
$lines = @(Get-Content (Join-Path $root $Raw) -Encoding UTF8) | ForEach-Object { Repair-Mojibake $_ }
$rows = New-Object System.Collections.ArrayList; $seen = @{}; $skip = 0
foreach ($ln in $lines) {
  if (-not ($ln -match "`t")) { continue }
  $prodStr = ($ln -split "`t", 2)[1]
  foreach ($p in ($prodStr -split '\|')) {
    $f = $p -split '~~'
    if ($f.Count -lt 2) { continue }
    $nm = CleanName ([string]$f[0])
    $price = 0.0; [void][double]::TryParse((([string]$f[1]) -replace '[^0-9.]', ''), [ref]$price)
    $sizeF = ''; if ($f.Count -ge 3) { $sizeF = [string]$f[2] }
    $size = GetSize $sizeF $nm
    if ($price -le 0 -or -not (GoodName $nm) -or -not $size) { $skip++; continue }
    $key = ($nm + '|' + $size).ToLower(); if ($seen.ContainsKey($key)) { continue }; $seen[$key] = $true
    [void]$rows.Add([ordered]@{ store = $Store; item = $nm; ad_price = ('$' + $price); size = $size; regular = $price; current_price = $price; source_ad = $SourceLabel; as_of = $today; written_by = 'import-instacart-batch.ps1'; mode_verified = $ModeVerified })
  }
}

$prev = Get-ChildItem (Join-Path $regDir ($prefix + '-*.json')) -EA SilentlyContinue | Where-Object { $_.BaseName -match ('^' + $prefix + '-\d{4}-\d{2}-\d{2}$') } | Sort-Object Name -Descending | Select-Object -First 1
$doc = $null
if ($prev) { $doc = Get-Content $prev.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
$mres = Merge-IwbRows @(if ($doc) { @($doc.deals) } else { @() }) @($rows | ForEach-Object { [pscustomobject]$_ })
$merged = $mres.merged; $added = $mres.added; $replaced = $mres.replaced
$outFile = Join-Path $regDir ($prefix + "-$today.json")
if ($doc) { $doc.deals = $merged.ToArray(); if ($doc.PSObject.Properties['deal_count']) { $doc.deal_count = $merged.Count } else { $doc | Add-Member deal_count $merged.Count -Force }; ($doc | ConvertTo-Json -Depth 6) | Set-Content $outFile -Encoding UTF8 }
else { ([ordered]@{ store = $Store; week_of = $today; price_type = 'everyday'; price_mode = 'in-store'; mode_verified = $ModeVerified; deal_count = $merged.Count; deals = $merged.ToArray() } | ConvertTo-Json -Depth 6) | Set-Content $outFile -Encoding UTF8 }
Write-Output ("$Store : parsed $($rows.Count) sized rows ($skip skipped noise/no-size), $added added / $replaced replaced, total $($merged.Count) -> $(Split-Path $outFile -Leaf)")
