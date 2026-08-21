<#
  test-price-table.ps1 - frozen fixtures for the WIDE price table.

  THE THREE PROMISES BRAD CALLED NON-NEGOTIABLE, one fixture each, each able to FAIL:
      1. "Ad pricing never enters the 'every day' pricing value"
      2. "every day pricing value can't 'replace' ad pricing"
      3. "Ad pricing must be null if its not on ad"

  Promise 3 is the one that does the work. Once ad_to is on the row a finished sale expires by
  arithmetic, so under the 90-day carry it falls off by itself instead of publishing for a quarter
  waiting for the rotation to come back round. If that fixture ever goes green-by-vacuum - because the
  filter moved, or because ad_to stopped being carried - the table silently becomes a place where old
  sales live forever, and it will look completely normal.

  Run: test-price-table.ps1        (exit 0 clean, 1 on any failure)
#>
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path (Split-Path $root -Parent) 'lib\guard-contract.ps1')
. (Join-Path $root 'capture-depth-lib.ps1')
. (Join-Path $root 'price-table-lib.ps1')

$fail = 0
function Ok($m) { Write-Output "ok    $m" }
function Bad($m) { Write-Output "FAIL  $m"; $script:fail++ }
function PtRow($store, $up, $type, $name, [string]$from = '', [string]$to = '', [string]$basis = '', [string]$src = '') {
  [pscustomobject]@{ store = $store; unit_price = $up; price_type = $type; name = $name; size_text = ''
    price_text = ('$' + $up); src_date = ''; ad_from = $from; ad_to = $to; ad_basis = $basis
    source_ad = $src; membership = $false }
}
# NOTE: the helper is PtRow, not R. `R` is the built-in alias for Invoke-History, so a fixture file
# that defines a function called R dies with "a positional parameter cannot be found that accepts
# argument 1.99" - a message that points nowhere near the real cause. Same family as $PID being
# read-only, which pull-regular-hyvee already warns about.
$TODAY = '2026-08-21'

# 1. BRAD'S POTATOES, verbatim from his message. Everyday 1.99, on sale 0.99 for a week.
$r = Build-PriceTableRow -Id 'potatoes' -Commodity 'Potatoes' -Unit 'lb' -Today $TODAY -Rows @(
  (PtRow 'Hy-Vee' 1.99 'everyday' 'Russet Potatoes 5 lb'),
  (PtRow 'Hy-Vee' 0.99 'sale'     'Russet Potatoes 5 lb' '2026-08-19' '2026-08-25' 'ad')
)
$c = $r.stores['Hy-Vee']
if ($c.everyday -eq 1.99 -and $c.ad -eq 0.99 -and $c.shown -eq 0.99 -and $c.shown_kind -eq 'ad') {
  Ok 'the potatoes row: everyday 1.99 and ad 0.99 both stored, page shows 0.99'
} else { Bad ("the potatoes row is wrong: everyday=$($c.everyday) ad=$($c.ad) shown=$($c.shown)") }

# 2. MUST FIRE - PROMISE 3. The SAME row one day after the sale ends. ad must be NULL and the page must
#    go back to 1.99 with no re-capture, purely from ad_to. This is Brad's "the ad price needs to null
#    out and... the potatoes go back to showing 1.99lb".
$r = Build-PriceTableRow -Id 'potatoes' -Commodity 'Potatoes' -Unit 'lb' -Today '2026-08-26' -Rows @(
  (PtRow 'Hy-Vee' 1.99 'everyday' 'Russet Potatoes 5 lb'),
  (PtRow 'Hy-Vee' 0.99 'sale'     'Russet Potatoes 5 lb' '2026-08-19' '2026-08-25' 'ad')
)
$c = $r.stores['Hy-Vee']
if ($null -eq $c.ad -and $c.shown -eq 1.99 -and $c.shown_kind -eq 'everyday') {
  Ok 'a CLOSED sale nulls the ad column and the everyday price returns by arithmetic'
} else { Bad ("an expired sale survived: ad=$($c.ad) shown=$($c.shown) kind=$($c.shown_kind) - a finished sale will publish until the rotation returns, which under a 90-day carry is a quarter") }

# 3. NULL, NOT ZERO. A zero would win every cheaper-of comparison it took part in, and would read as
#    "this item is free" to anything that does not check the type.
if ($null -eq $c.ad -and $c.ad -isnot [double]) { Ok 'a nulled ad column is $null, never 0' }
else { Bad 'the nulled ad column is not $null - a 0 here wins every cheaper-of comparison it enters' }

# 4. MUST FIRE - PROMISE 1. A store seen ONLY on sale must NOT have that price filed as its everyday
#    price. This is the direction that would never be noticed: the number is real and the cell looks
#    populated, but the board would claim the store charges the sale price all the time.
$r = Build-PriceTableRow -Id 'butter' -Commodity 'Butter' -Unit 'lb' -Today $TODAY -Rows @(
  (PtRow 'Aldi' 2.48 'sale' 'Hy-Vee butter 16 oz' '2026-08-21' '2026-08-23' 'ad')
)
$c = $r.stores['Aldi']
if ($null -eq $c.everyday -and $c.ad -eq 2.48) { Ok 'a sale-only store keeps a NULL everyday price (ad never becomes everyday)' }
else { Bad ("an ad price leaked into the everyday column: everyday=$($c.everyday)") }

# 5. MUST FIRE - PROMISE 2. The mirror. A store seen only at its everyday price must have a NULL ad,
#    even when that everyday price is a deep cut. Filing it as an ad would give a permanent price a
#    fake expiry, and it would then vanish on a date nobody set.
$r = Build-PriceTableRow -Id 'rice' -Commodity 'Rice' -Unit 'lb' -Today $TODAY -Rows @(
  (PtRow 'Walmart' 0.42 'everyday' 'Great Value Long Grain Rice 20 lb')
)
$c = $r.stores['Walmart']
if ($null -eq $c.ad -and $c.everyday -eq 0.42) { Ok 'an everyday-only store keeps a NULL ad (everyday never becomes an ad)' }
else { Bad ("an everyday price leaked into the ad column: ad=$($c.ad) window=$($c.ad_from)..$($c.ad_to)") }

# 6. THE SPLIT IS BY price_type, NOT BY WHICH IS CHEAPER. Here the "ad" is DEARER than the everyday
#    price - a real shape on the live board (Hy-Vee red potatoes, everyday 0.798 against an ad 1.29 on
#    a different pack). Both must still be stored under their own kind, and the page shows the cheaper.
#    Deciding the split by price instead would file the everyday price as the ad and quietly give a
#    permanent price an expiry date.
$r = Build-PriceTableRow -Id 'red-potatoes' -Commodity 'Red Potatoes' -Unit 'lb' -Today $TODAY -Rows @(
  (PtRow 'Hy-Vee' 0.798 'everyday' 'Red Potatoes 5 lb'),
  (PtRow 'Hy-Vee' 1.29  'sale'     'Red Potatoes 3 lb bag' '2026-08-17' '2026-08-23' 'ad')
)
$c = $r.stores['Hy-Vee']
if ($c.everyday -eq 0.798 -and $c.ad -eq 1.29 -and $c.shown -eq 0.798 -and $c.shown_kind -eq 'everyday') {
  Ok 'an ad DEARER than the everyday price is still stored as the ad, and the cheaper one is shown'
} else { Bad ("a dearer ad was mis-split: everyday=$($c.everyday) ad=$($c.ad) shown=$($c.shown)") }

# 7. A WINDOW THAT HAS NOT OPENED YET IS NOT LIVE. A flyer captured early must not price the board
#    before it starts - the mirror of the expiry rule, and the one nobody thinks to test.
$r = Build-PriceTableRow -Id 'eggs' -Commodity 'Eggs' -Unit 'dozen' -Today $TODAY -Rows @(
  (PtRow 'Baker''s' 2.99 'everyday' 'Kroger Large Eggs'),
  (PtRow 'Baker''s' 1.49 'sale'     'Kroger Large Eggs' '2026-08-24' '2026-08-30' 'ad')
)
$c = $r.stores["Baker's"]
if ($null -eq $c.ad -and $c.shown -eq 2.99) { Ok 'an ad that has not started yet does not price the board' }
else { Bad ("a future ad priced the board today: ad=$($c.ad) from=$($c.ad_from)") }

# 8. AN UNDATED MARKDOWN IS NOT EXPIRED. Absent evidence is not evidence - a Fareway markdown with no
#    published window is governed by its 30-day TTL, not by being silently dropped here.
$r = Build-PriceTableRow -Id 'chips' -Commodity 'Chips' -Unit 'oz' -Today $TODAY -Rows @(
  (PtRow 'Fareway' 0.27 'everyday' 'Lay''s Classic'),
  (PtRow 'Fareway' 0.19 'sale'     'Lay''s Classic' '' '' '')
)
$c = $r.stores['Fareway']
if ($c.ad -eq 0.19 -and $c.shown -eq 0.19) { Ok 'an UNDATED markdown still prices (absent evidence is not evidence of expiry)' }
else { Bad ("an undated markdown was dropped as if expired: ad=$($c.ad)") }

# 9. THE ELIGIBILITY RULE IS THE BOARD'S, NOT A COPY. A stale capture that the ranker would discard
#    must not reach the table either - otherwise the table prices a cell the board refused to.
#    Same shape as the frozen cherries case in compare-deals: one product split into two halves in an
#    old capture must not out-depth a live one.
$rows = @(
  (PtRow 'Walmart' 2.50 'sale'     'Fresh Red Cherries'),
  (PtRow 'Walmart' 4.96 'everyday' 'Fresh Red Cherries'),
  (PtRow 'Walmart' 6.97 'everyday' 'Fresh Red Cherries, 2.25 lb Bag')
)
$rows[0].src_date = '2026-07-14'; $rows[1].src_date = '2026-07-14'; $rows[2].src_date = '2026-08-11'
$r = Build-PriceTableRow -Id 'cherries' -Commodity 'Cherries' -Unit 'lb' -Today $TODAY -Rows $rows
$c = $r.stores['Walmart']
if ($c.everyday -eq 6.97 -and $null -eq $c.ad) { Ok 'the table uses the board''s own capture-eligibility rule (stale split capture excluded)' }
else { Bad ("the table admitted a capture the ranker discards: everyday=$($c.everyday) ad=$($c.ad) - the table and the board can now disagree") }

# 10. MUST FIRE - the parity check itself must be able to SEE a disagreement. A parity check that
#     cannot fail is the most dangerous object in this estate: it makes "derived from the same rows"
#     read as "verified", which is the difference this whole harness exists to keep.
$tbl = @( (Build-PriceTableRow -Id 'x' -Commodity 'X' -Unit 'lb' -Today $TODAY -Rows @( (PtRow 'Aldi' 1.00 'everyday' 'X') )) )
$cmpGood = [pscustomobject]@{ comparison = @([pscustomobject]@{ id = 'x'; stores = @([pscustomobject]@{ store = 'Aldi'; per_unit = 1.00 }) }) }
$cmpBad = [pscustomobject]@{ comparison = @([pscustomobject]@{ id = 'x'; stores = @([pscustomobject]@{ store = 'Aldi'; per_unit = 2.00 }) }) }
if (-not (@(Test-PriceTableParity -Table $tbl -Comparison $cmpGood)).Count) { Ok 'parity is silent when the table and board agree' }
else { Bad 'parity fired on an agreeing pair' }
$b = @(Test-PriceTableParity -Table $tbl -Comparison $cmpBad)
if ($b.Count -eq 1 -and $b[0].kind -eq 'price') { Ok 'parity FIRES when the table disagrees with the board' }
else { Bad 'parity could not see a 2x disagreement - it is decorative' }

# 11. Parity sees a cell the board publishes and the table lost, not just a mismatched price. A table
#     that silently drops cells would otherwise pass by having nothing to disagree about.
$cmpExtra = [pscustomobject]@{ comparison = @([pscustomobject]@{ id = 'x'; stores = @(
  [pscustomobject]@{ store = 'Aldi'; per_unit = 1.00 }, [pscustomobject]@{ store = 'Fareway'; per_unit = 3.00 }) }) }
$b = @(Test-PriceTableParity -Table $tbl -Comparison $cmpExtra)
if ($b.Count -eq 1 -and $b[0].kind -eq 'board-only') { Ok 'parity FIRES on a board cell the table has no row for' }
else { Bad 'a dropped cell passed parity - the table can shrink silently' }

# 12. The CSV is a rendering, and must carry the null through as an EMPTY field rather than a zero.
$csv = ConvertTo-PriceTableCsv -Table @( (Build-PriceTableRow -Id 'rice' -Commodity 'Rice' -Unit 'lb' -Today $TODAY -Rows @( (PtRow 'Walmart' 0.42 'everyday' 'GV Rice') )) ) -StoreOrder @('Walmart')
$dataLine = @($csv -split "`n")[1]
if ($dataLine -eq 'rice,Rice,lb,0.42,,,,0.42') { Ok 'the CSV renders a null ad as an empty field, not a 0' }
else { Bad "the CSV row is not what it should be: '$dataLine'" }

Write-Output ("PRICE-TABLE " + $(if ($fail) { "FAILED ($fail)" } else { 'PASSED' }))
Write-GuardComplete -Name 'price-table' -Summary "failed=$fail"
exit $(if ($fail) { 1 } else { 0 })
