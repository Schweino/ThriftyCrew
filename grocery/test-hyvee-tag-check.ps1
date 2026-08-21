<#
  test-hyvee-tag-check.ps1 - frozen fixtures for the Hy-Vee shelf-tag cross-check and store identity.

  THE FOUNDING BUG THIS MUST BE ABLE TO FAIL ON (2026-08-21). Brad opened Morton & Bassett Black Sesame
  Seed on his own Omaha #01 page, saw $9.99, and asked where $5.31 came from. The board had published
  $5.31 as a 47% markdown off $9.99 and every existing guard was green: real productId 40112, real store,
  onSale true, basePrice 9.99, arithmetic reproducing. The store's own retail record said tagPrice 9.99,
  ecommerceTagPrice 9.99, memberTagPrice null. Nothing in the estate could see it, because every guard
  reads the same storeProducts.price the puller does.

  The must-fire fixture below is that exact row. Its clean twins are the ones that make the check safe to
  keep: a REAL promotion (price below basePrice but AT the tag) must stay silent, or this refuses every
  sale Hy-Vee runs and the board loses its cheapest cells.

  Run: test-hyvee-tag-check.ps1     (exit 0 clean, 1 on any failure)
#>
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path (Split-Path $root -Parent) 'lib\guard-contract.ps1')
. (Join-Path $root 'hyvee-store-lib.ps1')

$fail = 0
function Ok($m) { Write-Output "ok    $m" }
function Bad($m) { Write-Output "FAIL  $m"; $script:fail++ }

# Test-HyVeeTagAgreement lives inside the puller, which runs a live pull when dot-sourced. Lift just that
# function out by parsing the file - the fixture then exercises the REAL text of the real decision rather
# than a transcription of it (fix-needs-reachable-selftest: two same-day fixes in this estate regressed
# because their self-test could not reach the new code).
$src = Get-Content (Join-Path $root 'pull-regular-hyvee.ps1') -Raw
$tokens = $null; $perr = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$tokens, [ref]$perr)
$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-HyVeeTagAgreement' }, $true)
if (-not $fn) {
  Bad 'Test-HyVeeTagAgreement is GONE from pull-regular-hyvee.ps1 - the shelf-tag cross-check has been removed and a price below the store tag can publish again'
  Write-Output 'HYVEE-TAG-CHECK FAILED (1)'
  Write-GuardComplete -Name 'hyvee-tag-check' -Summary 'failed=1 (function missing)'
  exit 1
}
. ([scriptblock]::Create($fn.Extent.Text))

# 1. MUST FIRE - the frozen sesame-seed row, exactly as the API returned it.
$r = Test-HyVeeTagAgreement -Price 5.31 -Mult 1 -TagPrice 9.99 -EcomTagPrice 9.99 -TagQty 1
if ($r) { Ok "the frozen `$5.31-against-a-`$9.99-tag row is refused" } else { Bad 'the founding bug PASSED - a price 47% below the shelf tag was allowed to publish' }

# 2. MUST FIRE - its sibling, the poultry seasoning, same brand same day.
$r = Test-HyVeeTagAgreement -Price 5.81 -Mult 1 -TagPrice 9.99 -EcomTagPrice 9.99 -TagQty 1
if ($r) { Ok 'the second frozen below-tag row is refused' } else { Bad 'the poultry-seasoning row PASSED' }

# 3. CLEAN TWIN, AND IT IS THE ONE THAT MATTERS. A genuine promotion is BELOW basePrice but AT the tag,
#    because the tag is what the shelf says today including the promotion. Cherries at Omaha #01: price
#    5.99, basePrice 6.99, tag 5.99. If this ever fires, the check has been written as "refuse anything
#    under the regular price" and Hy-Vee loses every sale cell it legitimately wins.
$r = Test-HyVeeTagAgreement -Price 5.99 -Mult 1 -TagPrice 5.99 -EcomTagPrice 5.99 -TagQty 1
if (-not $r) { Ok 'a REAL promotion (below basePrice, at the tag) is left alone' } else { Bad "a real promotion was refused - the check is reading basePrice, not the tag: $r" }

# 4. CLEAN TWIN: priced ABOVE the tag is allowed through. Deliberate asymmetry - too dear makes us look
#    expensive, too cheap is a promise the till breaks. Silently "fixing" this direction would also start
#    rewriting prices, which this function must never do.
$r = Test-HyVeeTagAgreement -Price 7.49 -Mult 1 -TagPrice 6.99 -EcomTagPrice 6.99 -TagQty 1
if (-not $r) { Ok 'a price ABOVE the tag is allowed (the asymmetry is deliberate)' } else { Bad 'a price above the tag was refused - that is not the failure mode this guards' }

# 5. CLEAN TWIN: no tag in the response means nothing to compare. Absence is not agreement and it is not
#    disagreement either - `fallback tests absence, not function`.
$r = Test-HyVeeTagAgreement -Price 3.00 -Mult 1 -TagPrice $null -EcomTagPrice $null -TagQty $null
if (-not $r) { Ok 'a row with no shelf tag is not judged at all' } else { Bad 'a row with no tag was refused on a comparison that could not be made' }

# 6. CLEAN TWIN: MULTIBUY BASES MUST MATCH. "3 for $4" has price 4 / multiple 3 while the tag may state a
#    single unit. Comparing 4 against 1.33 is the two-different-bases mistake guard 10 exists for, and it
#    would refuse a pile of perfectly good multibuy rows.
$r = Test-HyVeeTagAgreement -Price 4.00 -Mult 3 -TagPrice 1.49 -EcomTagPrice 1.49 -TagQty 1
if (-not $r) { Ok 'a multibuy total is not compared against a single-unit tag' } else { Bad "a multibuy row was judged across two different bases: $r" }

# 7. MUST FIRE - but a multibuy whose bases DO match is still checked. Otherwise "set a multiple" becomes
#    the way to escape this rule, which is the re-listing-escape shape.
$r = Test-HyVeeTagAgreement -Price 4.00 -Mult 3 -TagPrice 9.00 -EcomTagPrice 9.00 -TagQty 3
if ($r) { Ok 'a multibuy on the SAME basis is still checked against the tag' } else { Bad 'a below-tag multibuy escaped by carrying a multiple' }

# 8. ecommerceTagPrice WINS when both are present - it is the one the Aisles Online page renders, and the
#    page is what a reader will hold us to.
$r = Test-HyVeeTagAgreement -Price 5.31 -Mult 1 -TagPrice 5.31 -EcomTagPrice 9.99 -TagQty 1
if ($r) { Ok 'ecommerceTagPrice is preferred over tagPrice when the two differ' } else { Bad 'the check fell back to tagPrice while ecommerceTagPrice disagreed' }

# ---- the store identity itself -----------------------------------------------------------------------
# 9. Both identifiers resolve, and they are the pair Brad ruled for.
$s = Get-HyVeeStore -Root $root
if ([int]$s.store_id -eq 1466 -and [string]$s.location_id -eq '09e8f4f0-e614-4b86-9285-c9c3dbff0d85') {
  Ok "the board speaks for $($s.label) (storeId $($s.store_id) + its matching pickup location)"
} else { Bad "the Hy-Vee identity is not Brad's ruling: storeId=$($s.store_id) loc=$($s.location_id)" }

# 10. MUST FIRE ON DRIFT. The registry and the library must name the same store. A split identity pairs
#     one store's price with another store's shelf tag, which is precisely what manufactured 11 false
#     disagreements on the day this was written.
$d = Test-HyVeeStoreDrift -Root $root
if (-not $d) { Ok 'stores.json and hyvee-store-lib name the same store' } else { Bad $d }

# 11. The source label is DERIVED, so a row can never claim a store the query did not ask.
$lbl = Get-HyVeeSourceLabel -Root $root
if ($lbl -match "storeId $($s.store_id)" -and $lbl -match [regex]::Escape($s.label)) { Ok "row source label derives from the identity ('$lbl')" }
else { Bad "the source label does not match the identity it should be built from: '$lbl'" }

# 12. NO PRODUCTION CALLER MAY STILL HARD-CODE THE OLD STORE. This is the check that makes the switch real
#     rather than partial - the identity was in six files, and a board built from a blend of two stores is
#     wrong in a way no price guard can see.
$stale = @()
foreach ($f in (Get-ChildItem (Join-Path $root '*.ps1') -File)) {
  if ($f.Name -in @('hyvee-store-lib.ps1', 'test-hyvee-tag-check.ps1', 'probe-price-fields.ps1')) { continue }
  $t = Get-Content $f.FullName -Raw
  # A comment recounting the history is fine; a live storeId/location literal is not.
  foreach ($line in ($t -split "`n")) {
    $l = $line.Trim()
    if ($l.StartsWith('#')) { continue }
    if ($l -match 'adcb2ae1-f440-4512-bfe8-9624832c72a9' -or $l -match '\bstoreId\s*=\s*1465\b' -or $l -match '\$HStore\s*=\s*1465\b') {
      $stale += ($f.Name + ': ' + $l.Substring(0, [Math]::Min(96, $l.Length)))
    }
  }
}
if (-not $stale.Count) { Ok 'no production script still hard-codes the retired Omaha #01 identity' }
else { foreach ($x in $stale) { Bad ("still pinned to the RETIRED Omaha #01 identity - " + $x) } }

Write-Output ("HYVEE-TAG-CHECK " + $(if ($fail) { "FAILED ($fail)" } else { 'PASSED' }))
Write-GuardComplete -Name 'hyvee-tag-check' -Summary "failed=$fail"
exit $(if ($fail) { 1 } else { 0 })
