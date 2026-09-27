
# (u142) THE FIXTURE SANDBOX CARRIES EVERY LIBRARY, AND A MISSING OR STALE ONE IS NAMED (2026-09-11). The founding
# shape is a hand list: grocery\send-alert.ps1's sandbox copied four named libraries, and with atomic-write or
# append-line dropped every one of its 60 cases still passed. This harness copied two, into a lib\ shared by every
# run, where a dropped one could not go red at all. -Reads lib/*.ps1 so a push that adds or edits a library
# re-proves the copy.
if (Use-Unit 'u142-the-fixture-sandbox-carries-every-lib' -Reads 'lib/*.ps1') {
$u142Src = @(Get-ChildItem -LiteralPath $script:FxLibSource -Filter '*.ps1' -File)
$u142Gaps = Get-FxLibGaps $script:FxLibSource $fxLibDir
if ($u142Src.Count -gt 0 -and @($u142Gaps).Count -eq 0) { Ok ('MUST NOT FIRE this run''s fixture lib\ holds all ' + $u142Src.Count + ' lib\*.ps1 of this checkout, byte-identical') }
else { Bad ('the fixture lib\ is not this checkout''s lib\ (' + $u142Src.Count + ' source libraries): ' + (@($u142Gaps) -join '; ')) }
$u142Reach = NewFxDir 'lib-reach'
$u142ReachLib = Join-Path (Split-Path $u142Reach -Parent) 'lib'
if ([string]::Equals($u142ReachLib, $fxLibDir, [StringComparison]::OrdinalIgnoreCase)) { Ok ('CLEAN TWIN a NewFxDir directory resolves its parent lib\ to this run''s own ' + $fxLibDir) }
else { Bad ('a NewFxDir directory resolves its parent lib\ to ' + $u142ReachLib + ', not this run''s ' + $fxLibDir + ' - a fixture copy there loads whatever library that directory holds') }
Remove-Item -LiteralPath $u142Reach -Recurse -Force -ErrorAction SilentlyContinue
# A sandbox of its own, laid out the way the shared one is: <root>\lib beside <root>\fx.
$u142Root = NewFxDir 'lib-gap'
$u142Lib = Join-Path $u142Root 'lib'
$u142Fx = Join-Path $u142Root 'fx'
New-Item -ItemType Directory -Path $u142Lib, (Join-Path $u142Fx 'out') -ErrorAction Stop | Out-Null
foreach ($u142File in $u142Src) { if ($u142File.Name -ne 'json-io.ps1') { Copy-Item -LiteralPath $u142File.FullName -Destination (Join-Path $u142Lib $u142File.Name) } }
# MUST FIRE, the hand-list shape: one library dropped from the copy is named.
$u142G1 = Get-FxLibGaps $script:FxLibSource $u142Lib
if (@($u142G1).Count -eq 1 -and [string]@($u142G1)[0] -eq 'json-io.ps1 missing') { Ok 'MUST FIRE a fixture lib\ with json-io.ps1 dropped from the copy is named: json-io.ps1 missing' }
else { Bad ('a fixture lib\ with json-io.ps1 dropped was not named exactly once (' + (@($u142G1) -join '; ') + ')') }
# MUST FIRE end to end: a real guard copied into that sandbox goes red on the dropped library instead of passing.
Copy-Item -LiteralPath (Join-Path $root 'audit-cell-drops.ps1') -Destination (Join-Path $u142Fx 'audit-cell-drops.ps1')
Set-Content (Join-Path $u142Fx 'out\comparison-2026-01-01.json') '{"comparison":[{"id":"eggs","stores":[{"store":"Hy-Vee","type":"everyday","per_unit":2.50}]}]}' -Encoding UTF8
Set-Content (Join-Path $u142Fx 'out\comparison-2026-01-08.json') '{"comparison":[{"id":"eggs","stores":[{"store":"Hy-Vee","type":"everyday","per_unit":2.50}]}]}' -Encoding UTF8
$r = RunPSAt $u142Fx 'audit-cell-drops.ps1' @()
if ($r.rc -ne 0 -and $r.text -match 'json-io\.ps1') { Ok ('MUST FIRE audit-cell-drops copied beside a lib\ missing json-io.ps1 fails naming it (rc=' + $r.rc + ')') }
else { Bad ('audit-cell-drops beside a lib\ missing json-io.ps1 did not fail on it (rc=' + $r.rc + ') - a dropped library can pass silently') }
# CLEAN TWIN: the library restored, the same guard over the same boards reads ok with its examined count.
Copy-Item -LiteralPath (Join-Path $script:FxLibSource 'json-io.ps1') -Destination (Join-Path $u142Lib 'json-io.ps1')
$r = RunPSAt $u142Fx 'audit-cell-drops.ps1' @()
if ($r.rc -eq 0 -and $r.text -match '\(1 cells compared\)') { Ok 'CLEAN TWIN with json-io.ps1 restored the same copied guard reads ok with the examined count' }
else { Bad ('audit-cell-drops beside a complete lib\ did not read ok (rc=' + $r.rc + ') - the sandbox shape itself is broken, so the MUST FIRE above proves nothing') }
# MUST FIRE, the leftover shape: the library is present but holds bytes this checkout does not.
[IO.File]::AppendAllText((Join-Path $u142Lib 'json-io.ps1'), "`n# a copy another checkout left behind`n")
$u142G2 = Get-FxLibGaps $script:FxLibSource $u142Lib
if (@($u142G2).Count -eq 1 -and [string]@($u142G2)[0] -eq 'json-io.ps1 differs') { Ok 'MUST FIRE a fixture lib\ holding other bytes for json-io.ps1 is named: json-io.ps1 differs' }
else { Bad ('a fixture lib\ holding other bytes for json-io.ps1 was not named exactly once (' + (@($u142G2) -join '; ') + ')') }
Remove-Item -LiteralPath $u142Root -Recurse -Force -ErrorAction SilentlyContinue
} # u142-the-fixture-sandbox-carries-every-lib

# (a) audit-price-mode: BLIND when no mode-sensitive store file reaches the strict check (the state that
# shipped 249 delivery-priced Aldi rows on 2026-07-14), and the anchored glob ignores a non-canonical twin.
if (Use-Unit 'u024-a-audit-price-mode-blind-when-no') {
$fxApm = NewFxDir 'apm-blind'
$r = RunPS 'audit-price-mode.ps1' @('-RegularDir', $fxApm)
if ($r.rc -eq 3 -and $r.text -match 'BLIND' -and $r.text -match 'Aldi, Fareway') { Ok 'price-mode goes BLIND (exit 3) when zero mode-sensitive files reach it' }
else { Bad ('price-mode did NOT go blind on an empty regular dir (rc=' + $r.rc + ') - "OK" from zero examination is back') }
# LIVE-TWIN, DELIBERATELY (labelled 2026-09-06, PLAN-top5 area 4 §4.4). No -RegularDir, so this reads the
# real out\regular. That is what its author wanted - a machine whose live price modes are broken should go
# red here - and the label is so a red is read as "live data" rather than "this watcher went blind".
$r = RunPS 'audit-price-mode.ps1' @()
if ($r.rc -eq 0 -and $r.text -match 'PRICE-MODE AUDIT OK') { Ok 'LIVE-TWIN price-mode: live out\regular still passes with the counted OK line' }
else { Live ('LIVE-TWIN price-mode failed (rc=' + $r.rc + ') - this case reads LIVE data, so check out\regular before the code: either the live price modes are broken (page-worthy) or the edit broke the healthy path') }
$fxApmT = NewFxDir 'apm-twin'
Set-Content (Join-Path $fxApmT 'aldi-regular-2026-01-01.json') '{"store":"Aldi","price_mode":"in-store","mode_verified":"2026-01-01","items":[]}' -Encoding UTF8
Set-Content (Join-Path $fxApmT 'fareway-regular-2026-01-01.json') '{"store":"Fareway","price_mode":"in-store","mode_verified":"2026-01-01","items":[]}' -Encoding UTF8
Set-Content (Join-Path $fxApmT 'aldi-regular-2026-01-02.PARTIAL.json') '{"items":[]}' -Encoding UTF8
$r = RunPS 'audit-price-mode.ps1' @('-RegularDir', $fxApmT)
if ($r.rc -eq 0 -and $r.text -match 'OK\s+Aldi: in-store') { Ok 'price-mode anchored glob: a .PARTIAL twin cannot shadow the real capture (rc 0 AND the Aldi OK line present)' }
else { Bad ('price-mode read the non-canonical twin or went blind past it (rc=' + $r.rc + ') - the family-fare PARTIAL incident class') }
Remove-Item $fxApm, $fxApmT -Recurse -Force -ErrorAction SilentlyContinue
} # u024-a-audit-price-mode-blind-when-no

# (b) audit-walmart-fullpull: BLIND when a union store has ZERO captures in its window (used to exit 0 and
# guards printed "  ok    fullpull [Walmart]: no captures...").
if (Use-Unit 'u025-b-audit-walmart-fullpull-blind-when') {
$fxWfp = NewFxDir 'wfp-blind'
New-Item -ItemType Directory -Force (Join-Path $fxWfp 'out\regular') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $fxWfp 'out\sams') | Out-Null
$r = RunPS 'audit-walmart-fullpull.ps1' @('-GroceryRoot', $fxWfp)
if ($r.rc -eq 3 -and $r.text -match '\[Walmart\]: BLIND' -and $r.text -match "\[Sam's Club\]: BLIND") { Ok 'walmart-fullpull goes BLIND (exit 3) per store on an empty capture window' }
else { Bad ('walmart-fullpull did NOT go blind on empty windows (rc=' + $r.rc + ')') }
$fxD   = [datetime]::Today.ToString('yyyy-MM-dd')
$fxD11 = [datetime]::Today.AddDays(-11).ToString('yyyy-MM-dd')
} # u025-b-audit-walmart-fullpull-blind-when
# The clean twin needs a BOARD as well as captures: since 2026-07-30 this auditor also runs a per-CELL
# expiry watch, and a tree with no comparison-*.json is a tree where that watch can prove nothing - which
# it must say out loud (exit 1), never swallow. So the healthy fixture is captures AND a board whose every
# cell comes from today's capture.
function _WfpSeed([string]$dir, [string]$wmToday, [string]$wmOld, [string]$cmpRows) {
  Set-Content (Join-Path $dir ('out\regular\walmart-regular-' + $fxD + '.json')) ('{"pull_terms":400,"deals":[' + $wmToday + ']}') -Encoding UTF8
  if ($wmOld) { Set-Content (Join-Path $dir ('out\regular\walmart-regular-' + $fxD11 + '.json')) ('{"pull_terms":400,"deals":[' + $wmOld + ']}') -Encoding UTF8 }
  Set-Content (Join-Path $dir ('out\sams\sams-deals-' + $fxD + '.json')) '{"pull_terms":300,"deals":[{"item":"Sams Row","ad_price":"$5.00"}]}' -Encoding UTF8
  Set-Content (Join-Path $dir ('out\comparison-' + $fxD + '.json')) ('{"comparison":[' + $cmpRows + ']}') -Encoding UTF8
}
if (Use-Unit 'u025-b-audit-walmart-fullpull-blind-when') {
$fxSams  = '{"id":"sams-thing","cheapest_store":"Sam''s Club","stores":[{"store":"Sam''s Club","item":"Sams Row","ad":"$5.00"}]}'
$fxFresh = '{"id":"fresh-thing","cheapest_store":"Walmart","stores":[{"store":"Walmart","item":"Fresh Row","ad":"$9.99"}]}'
$fxOld   = '{"id":"old-thing","cheapest_store":"Walmart","stores":[{"store":"Walmart","item":"Old Row","ad":"$1.00"}]}'
_WfpSeed $fxWfp '{"item":"Fresh Row","ad_price":"$9.99"},{"item":"Old Row","ad_price":"$1.00"}' '{"item":"Old Row","ad_price":"$1.00"}' ($fxFresh + ',' + $fxOld + ',' + $fxSams)
$r = RunPS 'audit-walmart-fullpull.ps1' @('-GroceryRoot', $fxWfp)
if ($r.rc -eq 0 -and ([regex]::Matches($r.text, 'ok - newest comprehensive capture')).Count -eq 2 -and ([regex]::Matches($r.text, 'cells: ok')).Count -eq 2) { Ok 'walmart-fullpull clean twin: fresh comprehensive captures AND a board whose cells all come from them read ok for both stores' }
else { Bad ('walmart-fullpull clean twin failed (rc=' + $r.rc + '): ' + $r.text) }
Remove-Item $fxWfp -Recurse -Force -ErrorAction SilentlyContinue
} # u025-b-audit-walmart-fullpull-blind-when

# (b2) MUST FIRE - the 2026-07-30 bug this watch was written for. Watch 1 said "ok - newest comprehensive
# capture ... is 0 day(s) old" while 207 of 432 live Walmart cells (47.9%, 58 CROWNS) hung off
# walmart-regular-2026-07-18.json, 2 days from leaving the union. Frozen small, same shape: a fresh
# comprehensive capture that does NOT carry Old Row, and an 11-day-old capture that is its only source.
# The assertion names the CELLS line and requires watch 1 to still read ok, so it cannot pass on watch 1.
if (Use-Unit 'u026-b2-must-fire-the-2026-07-30-bug-this') {
$fxCell = NewFxDir 'wfp-cellexpiry'
New-Item -ItemType Directory -Force (Join-Path $fxCell 'out\regular') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $fxCell 'out\sams') | Out-Null
_WfpSeed $fxCell '{"item":"Fresh Row","ad_price":"$9.99"}' '{"item":"Old Row","ad_price":"$1.00"}' ($fxFresh + ',' + $fxOld + ',' + $fxSams)
# -WindowDays IS PINNED: these two fixtures are frozen around an 11-day-old capture that sits 2 days
# from a 14-day cliff. On 2026-08-20 the window became the capture policy's 90-day quarter and an
# 11-day-old capture stopped being anywhere near expiry, so both cases went quiet while the arithmetic
# they test was perfectly correct. The window the watch USES in production is asserted separately, in
# the window-consumer sweep below; what these two test is the countdown, so they pin it.
$r = RunPS 'audit-walmart-fullpull.ps1' @('-GroceryRoot', $fxCell, '-WindowDays', '14')
if ($r.rc -eq 1 -and $r.text -match '\[Walmart\] cells: WARNING - 1 of 2' -and $r.text -match 'CROWNS' -and $r.text -match 'ok - newest comprehensive capture walmart') { Ok 'walmart-fullpull FIRES on a board cell whose only source is about to leave the union window, while watch 1 still reads ok' }
else { Bad ('walmart-fullpull cell-expiry watch MISSED its founding bug (rc=' + $r.rc + '): ' + $r.text) }
Remove-Item $fxCell -Recurse -Force -ErrorAction SilentlyContinue
} # u026-b2-must-fire-the-2026-07-30-bug-this

# (b3) CLEAN TWIN for the percent floor. A few trailing cells are normal (a product out of stock, a term
# that returned nothing that morning) - Sam's carried 11 of them on 2026-07-29 with nothing wrong. One
# aging cell in 40 (2.5%) must stay SILENT, or the watch becomes a permanent alarm and gets ignored.
if (Use-Unit 'u027-b3-clean-twin-for-the-percent-floor') {
$fxPct = NewFxDir 'wfp-cellpct'
New-Item -ItemType Directory -Force (Join-Path $fxPct 'out\regular') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $fxPct 'out\sams') | Out-Null
$pFresh = @(); $pCmp = @()
foreach ($i in 1..39) { $pFresh += ('{"item":"Row ' + $i + '","ad_price":"$' + $i + '.00"}'); $pCmp += ('{"id":"c' + $i + '","cheapest_store":"Walmart","stores":[{"store":"Walmart","item":"Row ' + $i + '","ad":"$' + $i + '.00"}]}') }
_WfpSeed $fxPct ($pFresh -join ',') '{"item":"Old Row","ad_price":"$1.00"}' (($pCmp -join ',') + ',' + $fxOld + ',' + $fxSams)
# -WindowDays IS PINNED: these two fixtures are frozen around an 11-day-old capture that sits 2 days
# from a 14-day cliff. On 2026-08-20 the window became the capture policy's 90-day quarter and an
# 11-day-old capture stopped being anywhere near expiry, so both cases went quiet while the arithmetic
# they test was perfectly correct. The window the watch USES in production is asserted separately, in
# the window-consumer sweep below; what these two test is the countdown, so they pin it.
$r = RunPS 'audit-walmart-fullpull.ps1' @('-GroceryRoot', $fxPct, '-WindowDays', '14')
if ($r.rc -eq 0 -and $r.text -match '\[Walmart\] cells: ok - 1 of 40') { Ok 'walmart-fullpull cell watch stays SILENT at 1 aging cell in 40 (2.5%, under the 5% floor) - the trailing-cell noise floor' }
else { Bad ('walmart-fullpull cell watch cried wolf on the 2.5% noise floor (rc=' + $r.rc + '): ' + $r.text) }
Remove-Item $fxPct -Recurse -Force -ErrorAction SilentlyContinue
} # u027-b3-clean-twin-for-the-percent-floor

# (c) audit-household-in-food: BLIND at zero rows scanned (an existing-but-empty out\regular used to print
# "scanned 0 rows" + AUDIT OK + exit 0). Copy-to-temp because the script has no dir param.
if (Use-Unit 'u028-c-audit-household-in-food-blind-at') {
$fxHif = NewFxDir 'hif-blind'
# compare-deals.ps1 left this list on 2026-09-09 (backlog I82) and global-exclude-lib.ps1 replaced it:
# the audit no longer reads the engine's source at all, it dot-sources the exclude library instead.
foreach ($cf in @('audit-household-in-food.ps1','global-exclude-lib.ps1','commodities.json','categories.json')) { Copy-Item (Join-Path $root $cf) (Join-Path $fxHif $cf) }
New-Item -ItemType Directory -Force (Join-Path $fxHif 'out\regular') | Out-Null
$r = RunPSAt $fxHif 'audit-household-in-food.ps1' @()
if ($r.rc -eq 3 -and $r.text -match 'BLIND') { Ok 'household-in-food goes BLIND (exit 3) at zero rows scanned' }
else { Bad ('household-in-food did NOT go blind on an empty out\regular (rc=' + $r.rc + ')') }
Set-Content (Join-Path $fxHif 'out\regular\hyvee-regular-2026-01-01.json') '{"store":"Hy-Vee","deals":[{"item":"Bananas"}]}' -Encoding UTF8
$r = RunPSAt $fxHif 'audit-household-in-food.ps1' @()
if ($r.rc -eq 0 -and $r.text -match 'scanned 1 rows' -and $r.text -match 'AUDIT OK') { Ok 'household-in-food clean twin: one seeded row scans and passes' }
else { Bad ('household-in-food clean twin failed (rc=' + $r.rc + ')') }
Remove-Item $fxHif -Recurse -Force -ErrorAction SilentlyContinue
} # u028-c-audit-household-in-food-blind-at

# (d) audit-food-category: BLIND at zero priced cells (an empty -OutDir used to print "ok - ... (0 priced
# cells scanned)" with exit 0 - reproduced by execution before the fix).
if (Use-Unit 'u029-d-audit-food-category-blind-at-zero') {
$fxAfc = NewFxDir 'afc-blind'
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxAfc)
if ($r.rc -eq 3 -and $r.text -match 'FOOD-CLASS AUDIT BLIND') { Ok 'food-category goes BLIND (exit 3) at zero priced cells' }
else { Bad ('food-category did NOT go blind on an empty OutDir (rc=' + $r.rc + ')') }
# This case reads the LIVE board (no -OutDir) - see $HasBoard at the top. On a board-less checkout it went
# BLIND (rc=3) and read as a broken watcher; with a board present the assertion is unchanged, because a
# blind audit on a machine that HAS a board is exactly the failure this harness exists to catch.
if (-not $HasBoard) { Skip 'food-category clean twin: NO live board in grocery\out - the healthy-path case proved nothing here' }
else {
  # LIVE-TWIN, DELIBERATELY (labelled 2026-09-06, PLAN-top5 area 4 §4.4): no -OutDir, so this is the real
  # board. A red here is about the board, not about this harness.
  # The marker on the Bad line is how ops\prepush-test-auditors.ps1 knows this case may be red ON PURPOSE for a push that
  # adds a ruling (Brad, 2026-09-19): it pair-runs the named audit at the push's base and tip and accepts only that red.
  $r = RunPS 'audit-food-category.ps1' @()
  if ($r.rc -eq 0 -and $r.text -match 'priced cells scanned') { Ok 'LIVE-TWIN food-category: the live board still scans and passes' }
  else { Live ('LIVE-TWIN food-category failed (rc=' + $r.rc + ') - this case reads the LIVE board, so open the board before the code: either a live cell is miscategorised (page-worthy) or the edit broke the healthy path') }  # live-board-ruling-case audit=audit-food-category.ps1
}
Remove-Item $fxAfc -Recurse -Force -ErrorAction SilentlyContinue
} # u029-d-audit-food-category-blind-at-zero

# (d2) MUST-FIRE for the 2026-07-30 additions to category-excludes.json: the snack_carrier class and the
# beverage class's mini-cans / lemon-lime tokens. Both are founding bugs, measured live on that day's board:
# lemons was priced from "Lulu Platanitios Lemon Plantain Chips" (a snack) and limes from "Starry Mini Cans
# Lemon Lime" (a soda). Neither name carries a token the old library knew, so the blocking guard passed them.
# The rows are frozen literals here, NOT read from the board - regenerate them from live data and the bug
# they encode disappears, which is the whole [[guard-fixture-rule]] failure mode.
if (Use-Unit 'u030-d2-must-fire-for-the-2026-07-30') {
$fxSnk = NewFxDir 'afc-snack'
$snackRow = '{"week_of":"2026-07-29","comparison":[{"commodity":"Lemons","id":"lemons","unit":"each","stores":[{"store":"Sam''s Club","per_unit":0.5413,"item":"Lulu Platanitios Lemon Plantain Chips, 2.5 oz., 30 pk."}]},{"commodity":"Limes","id":"limes","unit":"each","stores":[{"store":"Sam''s Club","per_unit":0.5327,"item":"Starry Mini Cans Lemon Lime, 7.5 fl. oz., 30 pk."}]}]}'
Set-Content (Join-Path $fxSnk 'comparison-2026-07-29.json') $snackRow -Encoding UTF8
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxSnk)
if ($r.rc -eq 2 -and $r.text -match 'snack_carrier' -and $r.text -match 'beverage') {
  Ok 'food-category MUST-FIRE: a snack on lemons and a soda on limes both hard-fail (exit 2)'
} else {
  Bad ('food-category did NOT catch the plantain-chips/mini-cans rows (rc=' + $r.rc + ') - the snack_carrier class or the beverage mini-cans/lemon-lime tokens are gone from category-excludes.json')
}
# CLEAN TWIN: the same two commodities priced from real produce must stay silent, or the new tokens are
# eating legitimate cells (a guard that fails on correct data gets switched off, which is worse than no guard).
$cleanRow = '{"week_of":"2026-07-29","comparison":[{"commodity":"Lemons","id":"lemons","unit":"each","stores":[{"store":"Walmart","per_unit":0.5,"item":"Fresh Lemon"}]},{"commodity":"Limes","id":"limes","unit":"each","stores":[{"store":"Walmart","per_unit":0.25,"item":"Fresh Lime"}]}]}'
Set-Content (Join-Path $fxSnk 'comparison-2026-07-29.json') $cleanRow -Encoding UTF8
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxSnk)
if ($r.rc -eq 0) { Ok 'food-category clean twin: fresh lemon/lime rows stay silent under the new classes' }
else { Bad ('food-category flagged REAL produce (rc=' + $r.rc + ') - a new token is too broad: ' + ($r.text -replace "`n", ' ')) }
Remove-Item $fxSnk -Recurse -Force -ErrorAction SilentlyContinue
} # u030-d2-must-fire-for-the-2026-07-30

# (d3) MUST-FIRE for the frozen_dessert_brand class (2026-08-30, queue 2026-08-30-2611d3). THE FOUNDING ROW,
# frozen verbatim off the live board it was crowning: Family Fare pistachios read $0.1248/oz because the
# cheapest thing matching "pistachio" at that store was a 48 oz tub of Blue Bunny ICE CREAM at $5.99. The
# commodity ALREADY excluded ice cream, gelato, dessert, pudding, cake, cookies, truffles and chocolate by
# type word; this product's retail name carries only BRAND + FLAVOR, so every one of those fences saw
# nothing. That is why the class token is a BRAND: all 40 Blue Bunny strings in the capture corpus are
# frozen desserts. Never regenerate this row from the board - the fix removed it, so a regenerated fixture
# would encode the fix and pass by finding nothing ([[guard-fixture-rule]]).
if (Use-Unit 'u031-d3-must-fire-for-the-frozen-dessert') {
$fxBb = NewFxDir 'afc-bluebunny'
$bbRow = '{"week_of":"2026-08-30","comparison":[{"commodity":"Pistachios","id":"pistachios","unit":"oz","stores":[{"store":"Family Fare","per_unit":0.1248,"item":"Blue Bunny Premium Pistachio Almond 48 Oz"}]}]}'
Set-Content (Join-Path $fxBb 'comparison-2026-08-30.json') $bbRow -Encoding UTF8
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxBb)
if ($r.rc -eq 2 -and $r.text -match 'frozen_dessert_brand') {
  Ok 'food-category MUST-FIRE: Blue Bunny ice cream on pistachios hard-fails as frozen_dessert_brand (exit 2)'
} else {
  Bad ('food-category did NOT catch the Blue Bunny row on pistachios (rc=' + $r.rc + ') - the frozen_dessert_brand class is gone from category-excludes.json, or it is no longer applied to the Snacks scope, so a flavour-named dessert can crown a nut commodity again')
}
# CLEAN TWIN: the same brand on the commodity it legitimately IS must stay silent. If this ever fires, the
# exempt regex has been lost and the class is eating the ice-cream board.
$bbTwin = '{"week_of":"2026-08-30","comparison":[{"commodity":"Ice Cream","id":"ice-cream","unit":"floz","stores":[{"store":"Family Fare","per_unit":0.1248,"item":"Blue Bunny Premium Vanilla Bean Ice Cream, 48 fl oz"}]},{"commodity":"Popsicles","id":"popsicles","unit":"each","stores":[{"store":"Walmart","per_unit":0.25,"item":"Blue Bunny Mini Swirls Vanilla Cones, Frozen Dessert, 8 Pack"}]}]}'
Set-Content (Join-Path $fxBb 'comparison-2026-08-30.json') $bbTwin -Encoding UTF8
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxBb)
if ($r.rc -eq 0) { Ok 'food-category clean twin: Blue Bunny on ice-cream and popsicles stays silent - the brand class is exempt where the brand IS the commodity' }
else { Bad ('food-category flagged Blue Bunny on its OWN commodities (rc=' + $r.rc + ') - the frozen_dessert_brand exempt regex is missing ice-cream/popsicles: ' + ($r.text -replace "`n", ' ')) }
Remove-Item $fxBb -Recurse -Force -ErrorAction SilentlyContinue
} # u031-d3-must-fire-for-the-frozen-dessert

# (d4) MUST-FIRE for the sausage_carrier class (2026-09-02, queue 2026-09-02-1527d2). THE FOUNDING ROW,
# frozen verbatim off the live board it was holding: Family Fare's gruyere cell read $0.5825/oz because
# the cheapest thing matching "gruyere" at that store was a CHICKEN SAUSAGE flavoured with it, shelved in
# meat/sausage/smoked. gruyere's include is a bare flavour token and the whole exclude library was brand
# and type words, so nothing in it could say "this product is a sausage that lists the food as a flavour".
# Measured the same day over 33,854 corpus names: 455 carry sausage(s) and 25 route to 15 commodities that
# are not sausage - apples five times over - and the gap had been closed one per-product ruling at a time
# since 2026-08-01. Never regenerate this row from the board: the fix removed it, so a regenerated fixture
# would encode the fix and pass by finding nothing ([[guard-fixture-rule]]).
if (Use-Unit 'u032-d4-must-fire-for-the-sausage-carrier') {
$fxSc = NewFxDir 'afc-sausage'
$scRow = '{"week_of":"2026-09-02","comparison":[{"commodity":"Gruyere Cheese","id":"gruyere","unit":"oz","stores":[{"store":"Family Fare","per_unit":0.5825,"item":"Aidells Smoked Roasted Garlic & Gruyere Cheese Chicken Sausage 12 Oz"}]}]}'
Set-Content (Join-Path $fxSc 'comparison-2026-09-02.json') $scRow -Encoding UTF8
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxSc)
if ($r.rc -eq 2 -and $r.text -match 'sausage_carrier') {
  Ok 'food-category MUST-FIRE: a chicken sausage on gruyere hard-fails as sausage_carrier (exit 2)'
} else {
  Bad ('food-category did NOT catch the Aidells chicken sausage on gruyere (rc=' + $r.rc + ') - the sausage_carrier class is gone from category-excludes.json, or it is no longer applied to the Dairy scope, so a sausage that names a food as its flavour can hold that food''s cell again')
}
# CLEAN TWIN: a sausage on a commodity that IS a sausage, and a real gruyere, must both stay silent. If
# this fires, the exempt regex has been lost and the class is eating every sausage commodity on the board.
$scTwin = '{"week_of":"2026-09-02","comparison":[{"commodity":"Breakfast Sausage (pork)","id":"breakfast-sausage","unit":"lb","stores":[{"store":"Walmart","per_unit":2.89,"item":"Johnsonville Original Breakfast Sausage, 14 Links, 12 oz (Fresh)"}]},{"commodity":"Gruyere Cheese","id":"gruyere","unit":"oz","stores":[{"store":"Family Fare","per_unit":0.9988,"item":"Smoky Park Cheese, Smoked Gruyere 8 Oz"}]},{"commodity":"Kielbasa","id":"kielbasa","unit":"lb","stores":[{"store":"Sam''s Club","per_unit":2.2781,"item":"Eckrich Smoked Sausage Rope, 42 oz."}]}]}'
Set-Content (Join-Path $fxSc 'comparison-2026-09-02.json') $scTwin -Encoding UTF8
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxSc)
if ($r.rc -eq 0) { Ok 'food-category clean twin: Johnsonville on breakfast-sausage, Eckrich on kielbasa and a real Smoked Gruyere all stay silent - sausage_carrier is exempt where the commodity IS a sausage' }
else { Bad ('food-category flagged sausages on SAUSAGE commodities (rc=' + $r.rc + ') - the sausage_carrier exempt regex has lost breakfast-sausage/kielbasa: ' + ($r.text -replace "`n", ' ')) }
Remove-Item $fxSc -Recurse -Force -ErrorAction SilentlyContinue
} # u032-d4-must-fire-for-the-sausage-carrier

# (d5) MUST-FIRE for the soup_carrier and sushi_carrier classes (2026-09-11, queue 2026-09-11-3b246c). THE FOUNDING
# ROWS, frozen verbatim off the live board they were holding (comparison-2026-09-09, built 2026-09-11 08:11): Sam's
# Club's shrimp cell read $3.49/lb because the cheapest thing matching "shrimp" there was a 2-pack of SHRIMP AND CORN
# CHOWDER ($10.47 for 48 oz, exact arithmetic, not a parse bug), and Aldi's shrimp cell was a SUSHI ROLL at $7.36/lb.
# shrimp's include is the bare word and every fence it carried was a type word for a shrimp product (breaded, popcorn,
# scampi, boil), so nothing in the library could say "this is a prepared dish that names its protein". Measured over
# 22,713 corpus names (triage-plans\plan-2026-09-11.routing.json): baked into ^Meat and ^(Fruit|Vegetables)$ the two
# classes move 3 names, both of these rows plus a tomato bisque that correctly re-lands on tomato-soup. Never
# regenerate these rows from the board: the fix removed them, so a regenerated fixture would encode the fix and pass
# by finding nothing ([[guard-fixture-rule]]).
if (Use-Unit 'u140-d5-must-fire-for-the-soup-and-sushi-carriers') {
$fxSs = NewFxDir 'afc-soup-sushi'
$ssRow = '{"week_of":"2026-09-09","comparison":[{"commodity":"Shrimp (frozen, raw)","id":"shrimp","unit":"lb","stores":[{"store":"Sam''s Club","per_unit":3.49,"item":"Member''s Mark Shrimp and Corn Chowder, 24 oz., 2 pk."},{"store":"Aldi","per_unit":7.36,"item":"Fusia Shrimp Avocado Roll Sushi 11.5 OZ"}]}]}'
Set-Content (Join-Path $fxSs 'comparison-2026-09-09.json') $ssRow -Encoding UTF8
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxSs)
if ($r.rc -eq 2 -and $r.text -match 'soup_carrier' -and $r.text -match 'sushi_carrier') {
  Ok 'food-category MUST-FIRE: a shrimp chowder and a shrimp sushi roll on shrimp hard-fail as soup_carrier and sushi_carrier (exit 2)'
} else {
  Bad ('food-category did NOT catch the Sam''s chowder and the Aldi sushi roll on shrimp (rc=' + $r.rc + ') - soup_carrier or sushi_carrier is gone from category-excludes.json, or no longer applied to the Meat scope, so a prepared dish that names its protein can hold that protein''s cell again')
}
# MUST NOT FIRE: the real raw shrimp that took both cells back, and the bisque on the commodity it IS (tomato-soup sits
# outside both scoped blocks), are legal rows and the audit must stay silent on them. If this fires, a class token is
# too broad or has leaked into a block that carries soups.
# store-subset-ok: must-not-fire fixture for soup_carrier/sushi_carrier - audit-food-category judges the item NAME per cell and reads store only to match a food-class-allowlist entry, so the class verdict never branches on store
$ssLegal = '{"week_of":"2026-09-09","comparison":[{"commodity":"Shrimp (frozen, raw)","id":"shrimp","unit":"lb","stores":[{"store":"Sam''s Club","per_unit":5.82,"item":"Member''s Mark Farm Raised Jumbo Raw EZ Peel Shrimp, Frozen, 21-30 ct. per pound, 3 lbs."},{"store":"Aldi","per_unit":8.3867,"item":"Fremont Fish Market Medium EZ Peel Raw Shrimp 12 OZ"}]},{"commodity":"Tomato Soup (canned)","id":"tomato-soup","unit":"oz","stores":[{"store":"Family Fare","per_unit":0.3431,"item":"Fresh & Finest Herbed Tomato Bisque"}]}]}'
Set-Content (Join-Path $fxSs 'comparison-2026-09-09.json') $ssLegal -Encoding UTF8
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxSs)
if ($r.rc -eq 0) { Ok 'food-category MUST NOT FIRE: EZ Peel raw shrimp at Sam''s Club and Aldi and a tomato bisque on tomato-soup all stay silent - the prepared-dish classes fence only the scoped blocks' }
else { Bad ('food-category flagged REAL raw shrimp or a bisque on tomato-soup (rc=' + $r.rc + ') - a soup_carrier/sushi_carrier token is too broad or reached a block that carries soups: ' + ($r.text -replace "`n", ' ')) }
Remove-Item $fxSs -Recurse -Force -ErrorAction SilentlyContinue
} # u140-d5-must-fire-for-the-soup-and-sushi-carriers

# (d5c) MUST-FIRE for ID-SCOPED classes, category-excludes.json apply_ids (2026-09-18, queue 2026-09-18-f90ba6).
# THE FOUNDING ROW, frozen verbatim off comparison-2026-09-17 (built 2026-09-18 08:07:34), the fourth board in a
# row that guards HELD: Baker's pistachios cell was a pistachio MILK at 0.1426/oz. THIS GUARD READ OK OVER IT,
# because pistachios sits in the 'Snacks & Drinks' display bucket beside soda and coffee pods, so no category
# block could ever give it the beverage class - the guard was structurally blind to its own founding class
# there. apply_ids names the five nut ids the class reaches by ID. Never regenerate this row from the board:
# the bake excludes the beverage, so a regenerated fixture would pass by finding nothing ([[guard-fixture-rule]]).
if (Use-Unit 'u143-d5c-must-fire-for-id-scoped-classes') {
$fxIs = NewFxDir 'afc-idscope'
$isRow = '{"week_of":"2026-09-17","comparison":[{"commodity":"Pistachios","id":"pistachios","unit":"oz","stores":[{"store":"Baker''s","per_unit":0.1426,"item":"Whole Moon Pistachio Plant Beverage Whole Protein"}]}]}'
Set-Content (Join-Path $fxIs 'comparison-2026-09-17.json') $isRow -Encoding UTF8
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxIs)
if ($r.rc -eq 2 -and $r.text -match 'pistachios' -and $r.text -match 'class=beverage') {
  Ok 'food-category MUST-FIRE: the pistachio beverage on pistachios hard-fails as beverage through the id-scoped apply_ids block (exit 2)'
} else {
  Bad ('food-category did NOT catch the pistachio beverage on pistachios (rc=' + $r.rc + ') - apply_ids is gone from category-excludes.json, no longer lists pistachios, or audit-food-category stopped unioning it, so the guard is blind to a drink on a nut again: ' + ($r.text -replace "`n", ' '))
}
# MUST NOT FIRE: real pistachios (the Aldi row that takes the crown and the Baker's row that takes the cell
# after the fix), and the Gatorade protein bar on protein-bars. That last one is why variant B3 (all 21 non-drink
# snacks) was first measured and REJECTED: the bare 'gatorade' beverage token claimed Gatorade's own protein bars.
# Since 2026-09-18 (queue 2026-09-18-55b7aa, plan-2026-09-18-4) protein-bars IS in apply_ids and the token is
# gatorade(?!.*\bprotein\s+bars?\b), so this row stays silent because the token no longer claims a protein bar,
# not because the class is kept away. per_unit is read here only as > 0; the guard judges the item NAME.
# store-subset-ok: must-not-fire fixture for the id-scoped beverage class - audit-food-category judges the item NAME per cell and reads store only to match a food-class-allowlist entry, so the class verdict never branches on store
$isLegal = '{"week_of":"2026-09-17","comparison":[{"commodity":"Pistachios","id":"pistachios","unit":"oz","stores":[{"store":"Aldi","per_unit":0.4056,"item":"Southern Grove Pistachios 16 OZ"},{"store":"Baker''s","per_unit":0.4684,"item":"Simple Truth Shelled Roasted & Salted Pistachios"}]},{"commodity":"Protein Bars","id":"protein-bars","unit":"each","stores":[{"store":"Walmart","per_unit":1.0,"item":"Gatorade Chocolate Chip Protein Bar 2.8 Oz"}]}]}'
Set-Content (Join-Path $fxIs 'comparison-2026-09-17.json') $isLegal -Encoding UTF8
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxIs)
if ($r.rc -eq 0) { Ok 'food-category MUST NOT FIRE: real pistachios at Aldi and Baker''s and a Gatorade protein bar on protein-bars stay silent - the beverage class judges a drink, and its gatorade token does not claim a protein bar' }
else { Bad ('food-category flagged real pistachios or the Gatorade protein bar (rc=' + $r.rc + ') - the gatorade token claims a protein bar again, or a class token is too broad for the id-scoped block: ' + ($r.text -replace "`n", ' ')) }
Remove-Item $fxIs -Recurse -Force -ErrorAction SilentlyContinue
} # u143-d5c-must-fire-for-id-scoped-classes

# (d5d) MUST-FIRE for the WIDENED id scope (2026-09-18, queue 2026-09-18-55b7aa, triage-plans\plan-2026-09-18-4.json).
# apply_ids now reaches the 20 other non-drink 'Snacks & Drinks' commodities (chips, crackers, cookies, bars, jerky,
# cups...) as well as the five nuts. The class's bare 'gatorade' token claimed Gatorade's own protein bars, which broke
# the library rule that a token is wrong for EVERY commodity in scope, so it became gatorade(?!.*\bprotein\s+bars?\b),
# and snack_carrier gained \bprotein\s+bars?\b so Fruit, Vegetables and Meat lose no reach on a Gatorade bar.
# NO founding row exists on the 20 (0 beverage products in 134 cells of the 2026-09-18 15:46:51 board), so the
# MUST FIRE places REAL corpus names, frozen verbatim, on commodities the widening added: a Gatorade DRINK on
# protein-bars proves the narrowed token still catches a drink exactly where Gatorade's bars legitimately live, and one
# on tortilla-chips proves a plain snack id is in scope. The snack_carrier token HAS a founding row: Sam's 'Special K
# Protein Bars, Strawberry, 18 ct.' was a strawberries candidate on that board (candidates-2026-09-17) until the bake
# moved it to protein-bars. per_unit is read only as > 0. Never regenerate these rows from the board: the fix moved
# them, so a regenerated fixture would pass by finding nothing ([[guard-fixture-rule]]).
if (Use-Unit 'u143b-d5d-must-fire-for-the-widened-beverage-scope') {
$fxWs = NewFxDir 'afc-widescope'
# store-subset-ok: u143b food-class fixture board; the widened beverage-scope audit judges the product name against the commodity and never branches on which store
$wsRow = '{"week_of":"2026-09-17","comparison":[{"commodity":"Protein Bars","id":"protein-bars","unit":"each","stores":[{"store":"Family Fare","per_unit":1.0,"item":"Gatorade Advanced Rehydration Fruit Punch Thirst Quencher 28 Fl Oz"}]},{"commodity":"Tortilla Chips","id":"tortilla-chips","unit":"oz","stores":[{"store":"Baker''s","per_unit":1.0,"item":"Gatorade Cool Blue Sports Drink Bottle"}]},{"commodity":"Strawberries","id":"strawberries","unit":"lb","stores":[{"store":"Sam''s Club","per_unit":1.0,"item":"Special K Protein Bars, Strawberry, 18 ct."}]}]}'
Set-Content (Join-Path $fxWs 'comparison-2026-09-17.json') $wsRow -Encoding UTF8
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxWs)
if ($r.rc -eq 2 -and $r.text -match 'protein-bars\s+\[[^\]]*\]\s+class=beverage' -and $r.text -match 'tortilla-chips\s+\[[^\]]*\]\s+class=beverage' -and $r.text -match 'strawberries\s+\[[^\]]*\]\s+class=snack_carrier') {
  Ok 'food-category MUST-FIRE: a Gatorade drink on protein-bars and on tortilla-chips hard-fails as beverage through the widened apply_ids, and the Special K protein bar on strawberries as snack_carrier (exit 2)'
} else {
  Bad ('food-category did NOT catch a Gatorade drink on protein-bars/tortilla-chips or the Special K bar on strawberries (rc=' + $r.rc + ') - apply_ids lost the 20 snack ids, the narrowed gatorade token stopped matching a drink, or snack_carrier lost protein bars: ' + ($r.text -replace "`n", ' '))
}
# CLEAN TWIN: the OLD scope still catches both Gatorade shapes after the token was narrowed. A Gatorade drink on
# blueberries fires as beverage, and a Gatorade protein bar on strawberries (which the bare token used to catch as
# 'beverage') now fires as snack_carrier, so narrowing the token cost Fruit, Vegetables and Meat no reach.
$wsOld = '{"week_of":"2026-09-17","comparison":[{"commodity":"Blueberries","id":"blueberries","unit":"lb","stores":[{"store":"Walmart","per_unit":1.0,"item":"Gatorade Cool Blue flavor Thirst Quencher, 28 fl. oz. Bottle"}]},{"commodity":"Strawberries","id":"strawberries","unit":"lb","stores":[{"store":"Walmart","per_unit":1.0,"item":"Gatorade Chocolate Chip Protein Bar 2.8 Oz"}]}]}'
Set-Content (Join-Path $fxWs 'comparison-2026-09-17.json') $wsOld -Encoding UTF8
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxWs)
if ($r.rc -eq 2 -and $r.text -match 'blueberries\s+\[[^\]]*\]\s+class=beverage' -and $r.text -match 'strawberries\s+\[[^\]]*\]\s+class=snack_carrier') {
  Ok 'food-category CLEAN TWIN: on the old Fruit scope a Gatorade drink still fires as beverage and a Gatorade protein bar as snack_carrier (exit 2)'
} else {
  Bad ('food-category lost reach on the OLD scope after the gatorade token was narrowed (rc=' + $r.rc + '): ' + ($r.text -replace "`n", ' '))
}
# MUST NOT FIRE: real cells on ten of the twenty, frozen verbatim off the 2026-09-18 15:46:51 board (comparison-2026-09-17),
# plus the Special K bar where it now lands. If this fires, a beverage token is too broad for the snack scope.
# store-subset-ok: must-not-fire fixture for the widened beverage scope - audit-food-category judges the item NAME per cell and reads store only to match a food-class-allowlist entry, so the class verdict never branches on store
$wsLegal = '{"week_of":"2026-09-17","comparison":[{"commodity":"Beef Jerky","id":"beef-jerky","unit":"oz","stores":[{"store":"Aldi","per_unit":0.998,"item":"Original Beef Jerky"}]},{"commodity":"Cookies (packaged)","id":"cookies","unit":"oz","stores":[{"store":"Aldi","per_unit":0.1106,"item":"Benton S Family Size Iced Oatmeal Cookies 18 OZ"}]},{"commodity":"Crackers (saltine/buttery)","id":"crackers","unit":"oz","stores":[{"store":"Aldi","per_unit":0.1156,"item":"Savoritz Original Saltine Crackers"}]},{"commodity":"Fruit Cups","id":"fruit-cups","unit":"each","stores":[{"store":"Sam''s Club","per_unit":0.4575,"item":"Member''s Mark Diced Peach Cups, 4 oz., 24 ct."}]},{"commodity":"Gelatin (Jell-O)","id":"gelatin","unit":"each","stores":[{"store":"Walmart","per_unit":0.92,"item":"Great Value Cherry Gelatin Dessert, 3 oz"}]},{"commodity":"Granola Bars","id":"granola-bars","unit":"each","stores":[{"store":"Walmart","per_unit":0.1558,"item":"Great Value Chocolate Chip Chewy Granola Bars, Family Size, 0.84 oz Paper Box, 48 Count"}]},{"commodity":"Protein Bars","id":"protein-bars","unit":"each","stores":[{"store":"Fareway","per_unit":0.3817,"item":"Pure Protein Chocolate Peanut Caramel Protein Bar"},{"store":"Sam''s Club","per_unit":1.0,"item":"Special K Protein Bars, Strawberry, 18 ct."}]},{"commodity":"Pudding Cups","id":"pudding-cups","unit":"each","stores":[{"store":"Sam''s Club","per_unit":0.2411,"item":"Snack Pack Pudding Variety Pack, 3.25 oz., 36 pk."}]},{"commodity":"Toaster Pastries","id":"toaster-pastries","unit":"each","stores":[{"store":"Aldi","per_unit":0.1692,"item":"Millville Strawberry Toaster Tarts 12 CT"}]},{"commodity":"Tortilla Chips","id":"tortilla-chips","unit":"oz","stores":[{"store":"Walmart","per_unit":0.143,"item":"Mama Lupe''s White Corn Tortilla Chips, 10 Oz."}]}]}'
Set-Content (Join-Path $fxWs 'comparison-2026-09-17.json') $wsLegal -Encoding UTF8
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxWs)
if ($r.rc -eq 0) { Ok 'food-category MUST NOT FIRE: ten real snack cells off the 2026-09-18 board and the Special K bar on protein-bars stay silent under the widened beverage scope' }
else { Bad ('food-category flagged a REAL snack cell under the widened beverage scope (rc=' + $r.rc + ') - a beverage token is too broad for the snack commodities: ' + ($r.text -replace "`n", ' ')) }
Remove-Item $fxWs -Recurse -Force -ErrorAction SilentlyContinue
} # u143b-d5d-must-fire-for-the-widened-beverage-scope

# (d5e) MUST-FIRE for a PREPARED PRODUCT on a raw ingredient and a ROAST on a steak (2026-09-26, queue 2026-09-26-8deaa4).
# THE FOUNDING ROWS, frozen verbatim off comparison-2026-09-23 (built 2026-09-26 08:06): Family Fare's broccoli sale cell
# was a Michelina's frozen entree, its jarred-gravy cell a Michelina's frozen dinner, its raspberries cell Pillsbury fruit
# rolls and its sun-dried-tomatoes cell Wheat Thins; Fareway's raspberries CROWN was an AE Dairy Yolite yogurt cup;
# Baker's sirloin-steak cell a Kevin's heat-and-eat entree and Family Fare's sirloin-steak CROWN a whole sirloin tip
# subprimal. This guard read OK over every one: no class carried an entree brand, Yolite or Wheat Thins, jarred-gravy
# and sun-dried-tomatoes sit in the 'Canned & Soup' bucket beside real soups, and no class said a roast is not a steak.
# per_unit is read only as > 0. Never regenerate these rows from the board: the bake removes them, so a regenerated
# fixture would pass by finding nothing ([[guard-fixture-rule]]).
if (Use-Unit 'u143c-d5e-must-fire-for-prepared-product-and-roast-on-steak') {
$fxPp = NewFxDir 'afc-prepared'
# store-subset-ok: u143c food-class fixture board; audit-food-category judges the item NAME per cell and reads store only to match a food-class-allowlist entry
$ppRow = '{"week_of":"2026-09-23","comparison":[{"commodity":"Broccoli (fresh)","id":"broccoli","unit":"lb","stores":[{"store":"Family Fare","per_unit":2.0833,"item":"Michelina''s Beef & Broccoli 9.6 Oz"}]},{"commodity":"Jarred / Canned Gravy","id":"jarred-gravy","unit":"oz","stores":[{"store":"Family Fare","per_unit":0.1302,"item":"Michelina''s Salisbury Steak With Mashed Potatoes & Gravy 9.6 Oz"}]},{"commodity":"Raspberries","id":"raspberries","unit":"oz","stores":[{"store":"Fareway","per_unit":0.165,"item":"AE Dairy Raspberry Yolite"},{"store":"Family Fare","per_unit":0.2851,"item":"Pillsbury Poppin'' Flavor Raspberry Fruit Rolls 5 Ea"}]},{"commodity":"Sun-Dried Tomatoes","id":"sun-dried-tomatoes","unit":"oz","stores":[{"store":"Family Fare","per_unit":0.4694,"item":"Wheat Thins Sundried Tomato & Basil Snacks 8.5 Oz"}]},{"commodity":"Sirloin Steak","id":"sirloin-steak","unit":"lb","stores":[{"store":"Family Fare","per_unit":5.49,"item":"Fresh Usda Choice Whole Sirloin Tip"},{"store":"Baker''s","per_unit":9.99,"item":"Kevin''s Natural Foods Ranchero Sirloin Steak"}]},{"commodity":"Peaches","id":"peaches","unit":"lb","stores":[{"store":"Sam''s Club","per_unit":1.9967,"item":"Member''s Mark Organic Diced Peach Bowls, 4 oz., 24 pk."}]}]}'
Set-Content (Join-Path $fxPp 'comparison-2026-09-23.json') $ppRow -Encoding UTF8
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxPp)
# store-subset-ok: u143c expected findings for the fixture board above; one pattern per fixture cell, so it names exactly the stores that board holds and never branches on store
$ppWant = @('broccoli\s+\[Family Fare\s*\]\s+class=frozen_entree_carrier', 'jarred-gravy\s+\[Family Fare\s*\]\s+class=frozen_entree_carrier', 'raspberries\s+\[Fareway\s*\]\s+class=dairy_carrier', 'raspberries\s+\[Family Fare\s*\]\s+class=bakery_carrier', 'sun-dried-tomatoes\s+\[Family Fare\s*\]\s+class=snack_carrier', 'sirloin-steak\s+\[Family Fare\s*\]\s+class=whole_cut_carrier', 'sirloin-steak\s+\[Baker''s\s*\]\s+class=frozen_entree_carrier', 'peaches\s+\[Sam''s Club\s*\]\s+class=cup_bowl_carrier')
$ppMiss = @($ppWant | Where-Object { $r.text -notmatch $_ })
if ($r.rc -eq 2 -and $ppMiss.Count -eq 0) {
  Ok 'food-category MUST-FIRE: the eight founding cells (two Michelina''s, a Kevin''s entree, a Yolite, Pillsbury fruit rolls, Wheat Thins, a whole sirloin tip, Sam''s diced peach bowls) each hard-fail under their own class (exit 2)'
} else {
  Bad ('food-category missed a founding prepared-product or roast-on-steak cell (rc=' + $r.rc + '; missing ' + ($ppMiss -join ' ; ') + ') - a class token, the Fruit/Vegetables/Meat block, or the jarred-gravy/sun-dried-tomatoes or steak apply_ids entry is gone: ' + ($r.text -replace "`n", ' '))
}
# CLEAN TWIN: the real products beside them on the same board stay silent, including the two the new tokens were most
# likely to take: frozen broccoli florets on broccoli's neighbour and a chuck ROAST (whole_cut_carrier reaches steak and
# chop ids only), plus Sam's whole chuck roll case, which is a ruling (Q-2026-09-26-subprimal-case), not this class.
# store-subset-ok: clean twin for the u143c classes - the verdict never branches on store
$ppLegal = '{"week_of":"2026-09-23","comparison":[{"commodity":"Broccoli (fresh)","id":"broccoli","unit":"lb","stores":[{"store":"Aldi","per_unit":2.09,"item":"Broccoli Crowns Per LB"},{"store":"Fareway","per_unit":2.2629,"item":"Fareway Broccoli Florets"}]},{"commodity":"Jarred / Canned Gravy","id":"jarred-gravy","unit":"oz","stores":[{"store":"Walmart","per_unit":0.1956,"item":"Heinz HomeStyle Turkey Gravy Value Size, 18 oz Jar"},{"store":"Sam''s Club","per_unit":0.0912,"item":"Chef-mate Country Sausage Gravy, 105 oz."}]},{"commodity":"Raspberries","id":"raspberries","unit":"oz","stores":[{"store":"Baker''s","per_unit":0.4167,"item":"Fresh Red Raspberries - 6 OZ Clamshell"}]},{"commodity":"Sun-Dried Tomatoes","id":"sun-dried-tomatoes","unit":"oz","stores":[{"store":"Sam''s Club","per_unit":0.4158,"item":"Terra Verde Italian Sundried Tomatoes in Oil, 24 oz."}]},{"commodity":"Sirloin Steak","id":"sirloin-steak","unit":"lb","stores":[{"store":"Hy-Vee","per_unit":10.99,"item":"Hy-Vee Angus Reserve Beef Loin Boneless Sirloin Steak"}]},{"commodity":"Chuck Roast","id":"chuck-roast","unit":"lb","stores":[{"store":"Aldi","per_unit":6.99,"item":"Choice Black Angus Chuck Roast Per LB"},{"store":"Sam''s Club","per_unit":6.97,"item":"Whole Beef Chuck Roll, Case, priced per pound"}]}]}'
Set-Content (Join-Path $fxPp 'comparison-2026-09-23.json') $ppLegal -Encoding UTF8
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxPp)
if ($r.rc -eq 0) { Ok 'food-category CLEAN TWIN: real broccoli, gravy jars, raspberries, oil-packed sun-dried tomatoes, a loin sirloin steak and chuck roasts (a whole chuck roll case included) stay silent' }
else { Bad ('food-category flagged a real product beside the founding cells (rc=' + $r.rc + ') - a u143c token is too broad or whole_cut_carrier reached a roast commodity: ' + ($r.text -replace "`n", ' ')) }
Remove-Item $fxPp -Recurse -Force -ErrorAction SilentlyContinue
} # u143c-d5e-must-fire-for-prepared-product-and-roast-on-steak

# THE FRESHOP PAGER AND THE CIRCULAR PICKER (2026-09-11, queue 2026-09-10-fa6ad6). Family Fare's weekly-ad pull asked
# Freshop for limit=200&page=N; Freshop clamps limit to 100 and ignores page=, so every ad file from 09-02 to 09-09
# held the same 100 rows of a ~1,045-row circular, recorded as 1,100 deals. pull-grocery-ads.ps1 -SelfTest drives
# Get-FreshopPages, Select-FreshopCircular and Get-CircularCoverageReview (ff-price-lib.ps1) against frozen Freshop
# doubles; this unit runs it and requires the founding case and each twin BY NAME, so a deleted case cannot pass as
# a shorter green run.
if (Use-Unit 'u141-freshop-pager-and-circular-picker' -Reads 'grocery/ff-price-lib.ps1', 'grocery/pull-grocery-ads.ps1', 'grocery/check-ad-cycles.ps1') {
# THE SELF-TEST MUST END IN ITS OWN VERDICT, AND IT RUNS AGAINST A TEMP -OutDir (2026-09-11). Commit 8253ded82 put the
# suite's closing `if ($fail -eq 0) { ...; exit 0 }` on the same line as its last case, so PowerShell passed `if`, the
# condition and both blocks to _T as ARGUMENTS, no exit ran, and -SelfTest fell through into a LIVE pull of Hy-Vee, Aldi
# and Family Fare that wrote out\ads-<today>.json and exited 0. Every case name had printed and no line began FAIL, so
# this unit passed it. The verdict line is what a fall-through cannot print, and an ads file in the temp directory is
# what only a fall-through writes. The child creates its -OutDir before it reaches the self-test, so the default is the
# live grocery\out. dbd92279f fixed the child and ops\audit-keyword-arguments.ps1 blocks that one spelling; this is the
# harness half, for every other way a suite can lose its exit. Of the 46 -SelfTest call sites in this file on that day,
# this was the only one whose Ok did not require the child's own verdict line.
$pgaOut = Register-Fx (Join-Path $env:TEMP ('taudit-pga-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))
$r = RunPS 'pull-grocery-ads.ps1' @('-SelfTest', '-OutDir', $pgaOut)
$need = @('founding loop shape', 'added zero new ids', 'coverage 9.6', 'read whole: 1,045 unique in 11 requests', 'throttle on request 7', 'picker takes the weekly ad', 'pull that ERRORED')
$missing = @($need | Where-Object { $r.text -notmatch [regex]::Escape($_) })
$failLines = @(($r.text -split "`n") | Where-Object { $_ -match '^FAIL' })
$pgaVerdict = [bool]($r.text -match '(?m)^SELF-TEST PASS: \d+ case')
$pgaWrote = @(Get-ChildItem -LiteralPath $pgaOut -Filter 'ads-*.json' -File -ErrorAction SilentlyContinue)
if ($r.rc -eq 0 -and $pgaVerdict -and $pgaWrote.Count -eq 0 -and $missing.Count -eq 0 -and $failLines.Count -eq 0) { Ok 'Freshop pager: a page-ignoring endpoint throws, a short circular reads coverage 9.6 with a REVIEW line, a whole one reads 1,045 in 11 requests, a throttle keeps its 600 rows, the weekly ad beats the 2-day preview, and the self-test ends in its own verdict without pulling' }
else { Bad ('Freshop pager self-test failed, lost a case or fell through into a LIVE pull (rc=' + $r.rc + '; verdict line=' + $pgaVerdict + '; ads files written=' + $pgaWrote.Count + '; missing: ' + ($missing -join ', ') + '; ' + ($failLines -join ' | ') + ') - the Family Fare circular can be read one page deep again, or a gate run can overwrite the day''s ad capture') }
} # u141-freshop-pager-and-circular-picker

# (d5) MUST-FIRE for cheese_carrier and cracker_carrier (2026-09-04, queue 2026-09-04-2cd17a). TWO FOUNDING
# ROWS, frozen verbatim off the 09-04 Aldi capture that produced them:
#   * 'Emporium Selection Bacon Bread Cheese 6 OZ' is a BAKED CHEESE. It routed to bacon (index 4) because
#     bacon's include is a bare type word and bacon's own exclude carried 'bacon\s+cheese' - the word BREAD
#     sits between them. Its Original sibling routed to bread, a cheese in the loaf commodity.
#   * 'Savoritz Sea Salt Sourdough Pita Cracker 5 OZ' is a CRACKER. It routed to pita-bread (index 175)
#     because that commodity's hand-written exclude carried the literal plural 'crackers' and the SINGULAR
#     walked past it. The library already had the \bcrackers?\b form in snack_carrier; no bake scope reached
#     Bread & Bakery, which is why Bread now has an apply block of its own.
# Both were one `audit-match-soundness -Accept` away from being baselined as reviewed.
# NEVER REGENERATE THESE ROWS FROM THE BOARD: the fix removed them, so a regenerated fixture would encode
# the fix and pass by finding nothing ([[guard-fixture-rule]]).
if (Use-Unit 'u033-d5-must-fire-for-cheese-carrier-and') {
$fxCc = NewFxDir 'afc-carrier'
$ccRow = '{"week_of":"2026-09-02","comparison":[{"commodity":"Bacon","id":"bacon","unit":"oz","stores":[{"store":"Aldi","per_unit":0.3317,"item":"Emporium Selection Bacon Bread Cheese 6 OZ"}]},{"commodity":"Pita Bread","id":"pita-bread","unit":"oz","stores":[{"store":"Aldi","per_unit":0.498,"item":"Savoritz Sea Salt Sourdough Pita Cracker 5 OZ"}]}]}'
Set-Content (Join-Path $fxCc 'comparison-2026-09-02.json') $ccRow -Encoding UTF8
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxCc)
if ($r.rc -eq 2 -and $r.text -match 'cheese_carrier' -and $r.text -match 'cracker_carrier') {
  Ok 'food-category MUST-FIRE: a bread cheese on bacon and a pita cracker on pita-bread hard-fail, naming cheese_carrier and cracker_carrier (exit 2)'
} else {
  Bad ('food-category did NOT catch the bread-cheese/pita-cracker rows (rc=' + $r.rc + ') - cheese_carrier is gone from the ^Meat scope, or cracker_carrier is gone from the ^Bread block (and if the ^Bread block was moved BELOW the shared Dairy/Canned/... block it is unreachable: apply-category-excludes takes the FIRST matching block): ' + ($r.text -replace "`n", ' '))
}
# CLEAN TWIN: a real bacon, a real pita bread, a real bagel, and the LIVE Sam's muffins crown that the
# rejected snack_carrier-on-Bread bake would have ejected. If any of these fires, a token is too broad and
# the release has started eating the products the commodities are for.
$ccTwin = '{"week_of":"2026-09-02","comparison":[{"commodity":"Bacon","id":"bacon","unit":"oz","stores":[{"store":"Aldi","per_unit":0.3106,"item":"Appleton Farms Lower Sodium Bacon 16 OZ"}]},{"commodity":"Pita Bread","id":"pita-bread","unit":"oz","stores":[{"store":"Walmart","per_unit":0.2492,"item":"Joseph''s Flax Oat Bran & Whole Wheat Pita Bread"}]},{"commodity":"Bagels","id":"bagels","unit":"oz","stores":[{"store":"Baker''s","per_unit":0.1806,"item":"Kroger Blueberry Bagels"}]},{"commodity":"Muffins","id":"muffins","unit":"oz","stores":[{"store":"Sam''s Club","per_unit":0.1699,"item":"Entenmann''s Little Bites Chocolate Chip Muffins"}]}]}'
Set-Content (Join-Path $fxCc 'comparison-2026-09-02.json') $ccTwin -Encoding UTF8
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxCc)
if ($r.rc -eq 0) { Ok 'food-category clean twin: a real bacon, a real pita bread, a real bagel and the live Sam''s muffins crown all stay silent under the two new carrier classes' }
else { Bad ('food-category flagged REAL bread/meat products (rc=' + $r.rc + ') - cheese_carrier or cracker_carrier is too broad; the measured-and-rejected snack_carrier-on-Bread bake ejected exactly these: ' + ($r.text -replace "`n", ' ')) }
Remove-Item $fxCc -Recurse -Force -ErrorAction SilentlyContinue
} # u033-d5-must-fire-for-cheese-carrier-and

# (d5b) MUST-FIRE for steam_bag_carrier (2026-09-08, queue 2026-09-08-2e59b3). TWO FOUNDING ROWS, frozen
# verbatim off comparison-2026-09-08 and candidates-2026-09-08 - the board that was LIVE while it was wrong:
#   * 'Fareway Steamables Green Beans' is a FROZEN 12 oz microwave bag. It held Fareway's fresh-green-beans
#     cell at $1.44 / 0.75 lb = 1.92 per lb, over the fresh 'Pero Family Farms Snipped Green Beans' at 2.94.
#     The crown was Walmart at 1.6201, so CROWN-BY-CONTEST could not see it, and the name was already in the
#     accepted contested list where no run would ever flag it again.
#   * 'Green Giant Steamers Lightly Sauced Roasted Red Potatoes, Green Beans & Rosemary' routed to
#     red-potatoes at $2.99 / 10 oz = 4.784 per lb. The sanity BAND kept it off the cell, not the rule, and
#     a band is not a fix (Brad 2026-09-04: no hard-coded bands).
# Fresh per-lb produce commodities refuse a form by literal word (\bfrozen\b, \bsteam\b, \bcanned\b) but a
# branded steam-bag line carries NO form word, so it walked past every fence a Produce commodity had.
# NEVER REGENERATE THESE ROWS FROM THE BOARD: the steam_bag_carrier bake removed them the same day, so a
# regenerated fixture would encode the fix and pass by finding nothing ([[guard-fixture-rule]]).
if (Use-Unit 'u034-d5b-must-fire-for-steam-bag-carrier') {
$fxSb = NewFxDir 'afc-steambag'
$sbRow = '{"week_of":"2026-09-08","comparison":[{"commodity":"Green Beans (fresh)","id":"fresh-green-beans","unit":"lb","stores":[{"store":"Fareway","per_unit":1.92,"item":"Fareway Steamables Green Beans"}]},{"commodity":"Red Potatoes","id":"red-potatoes","unit":"lb","stores":[{"store":"Fareway","per_unit":4.784,"item":"Green Giant Steamers Lightly Sauced Roasted Red Potatoes, Green Beans & Rosemary"}]}]}'
Set-Content (Join-Path $fxSb 'comparison-2026-09-08.json') $sbRow -Encoding UTF8
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxSb)
if ($r.rc -eq 2 -and $r.text -match 'steam_bag_carrier') {
  Ok 'food-category MUST-FIRE: a frozen Steamables bag on fresh-green-beans and a Sauced Steamers bag on red-potatoes hard-fail, naming steam_bag_carrier (exit 2)'
} else {
  Bad ('food-category did NOT catch the frozen steam-bag rows on FRESH produce (rc=' + $r.rc + ') - steam_bag_carrier is gone from category-excludes.json, or it is no longer in the ^(Fruit|Vegetables)$ apply block, so a branded frozen bag with no form word in its name can hold a fresh per-lb cell again: ' + ($r.text -replace "`n", ' '))
}
# CLEAN TWIN: the same words on commodities they are RIGHT for. 'Kroger Steams in Bag Petite Carrots' is
# FRESH produce (in band at carrots, 2.6533/lb) and is why 'steams? in bag' is deliberately NOT a token;
# SteamCrisp White Shoepeg is a real CAN; and the frozen-* commodities are what a Steamfresh, a Steamables
# and a Sauced bag actually ARE, which is why the class is scoped to Fruit and Vegetables and never reaches
# the shared Dairy/Canned/.../Frozen block. Every per_unit here is read off the 2026-09-08 board or its
# candidates file. If any of these fires, the scope has slipped and the release is eating real products.
# store-subset-ok: clean-twin fixture for steam_bag_carrier - real 2026-09-08 board rows, the region under test never branches on store
$sbTwin = '{"week_of":"2026-09-08","comparison":[{"commodity":"Carrots","id":"carrots","unit":"lb","stores":[{"store":"Baker''s","per_unit":2.6533,"item":"Kroger Steams in Bag Petite Carrots"}]},{"commodity":"Canned Corn","id":"canned-corn","unit":"oz","stores":[{"store":"Baker''s","per_unit":0.2082,"item":"Green Giant SteamCrisp White Shoepeg Whole Kernel Corn"}]},{"commodity":"Frozen Peas","id":"frozen-peas","unit":"oz","stores":[{"store":"Baker''s","per_unit":0.149,"item":"Birds Eye Steamfresh Sweet Peas, Frozen Vegetables"}]},{"commodity":"Frozen Corn","id":"frozen-corn","unit":"oz","stores":[{"store":"Family Fare","per_unit":0.2398,"item":"Birds Eye Sauced Butter Super Sweet Corn 10.8 Oz"},{"store":"Fareway","per_unit":0.12,"item":"Fareway Steamables Cut Corn"}]},{"commodity":"Green Beans (fresh)","id":"fresh-green-beans","unit":"lb","stores":[{"store":"Walmart","per_unit":1.6201,"item":"Fresh Green Beans, Bag"}]},{"commodity":"Red Potatoes","id":"red-potatoes","unit":"lb","stores":[{"store":"Fareway","per_unit":0.998,"item":"Red Potato"}]}]}'
Set-Content (Join-Path $fxSb 'comparison-2026-09-08.json') $sbTwin -Encoding UTF8
$r = RunPS 'audit-food-category.ps1' @('-OutDir', $fxSb)
if ($r.rc -eq 0) { Ok 'food-category clean twin: Kroger Steams in Bag Petite Carrots on carrots, SteamCrisp White Shoepeg on canned-corn, Steamfresh and Sauced and Steamables on frozen-*, and the real fresh green bean and red potato rows all stay silent' }
else { Bad ('food-category flagged products the steam-bag words are RIGHT for (rc=' + $r.rc + ') - steam_bag_carrier has escaped the ^(Fruit|Vegetables)$ scope into the shared Dairy/Canned/.../Frozen block, or a token grew to cover "steams in bag": ' + ($r.text -replace "`n", ' ')) }
Remove-Item $fxSb -Recurse -Force -ErrorAction SilentlyContinue
} # u034-d5b-must-fire-for-steam-bag-carrier

# (d6) BAKE CURRENCY (2026-09-04, queue 2026-09-04-2cd17a). A library class ships INERT until someone runs
# apply-category-excludes.ps1: audit-food-category reads the library, but the ENGINE reads each commodity's
# own baked exclude list, so a class added to the library and never baked flags on the board while still
# letting the product win the cell. This case asserts the LIVE commodities.json is CURRENT with the library
# - i.e. a bake right now would add nothing.
# It is the same shape as the token-added-sweep-and-gate-not class, applied to the bake.
if (Use-Unit 'u035-d6-bake-currency-a-library-class') {
$fxBk = NewFxDir 'catex-currency'
# LIVE-TWIN, DELIBERATELY (labelled 2026-09-06, PLAN-top5 area 4 §4.4). The three files copied below are
# the LIVE rule files, and that is the question: is production's commodities.json currently baked from
# production's category-excludes.json? A frozen trio would prove the baker works and say nothing about the
# board. MOVED ABOVE THE COPIES 2026-09-11: ops\audit-fixture-inputs.ps1 reads a declaration from the comment
# block above a line, and began scanning this whole file that day. The other two copies carry it inline.
Copy-Item (Join-Path $root 'commodities.json')      (Join-Path $fxBk 'commodities.json')
Copy-Item (Join-Path $root 'categories.json')       (Join-Path $fxBk 'categories.json')          # LIVE-TWIN
Copy-Item (Join-Path $root 'category-excludes.json') (Join-Path $fxBk 'category-excludes.json')  # LIVE-TWIN
$r = RunPS 'apply-category-excludes.ps1' @('-Root', $fxBk, '-WhatIf')
if ($r.rc -eq 0 -and $r.text -match 'library:\s*\+0 patterns') {
  Ok 'LIVE-TWIN category-exclude bake is CURRENT: a bake over the live rule files would add 0 patterns, so every library class the guard checks is actually in the engine''s rules'
} else {
  Bad ('category-exclude bake is STALE (' + (($r.text -split "`n")[0]) + ') - a library class is not baked into commodities.json, so audit-food-category can name it while the engine still lets the product win the cell. Run grocery\apply-category-excludes.ps1 and re-run the board.')
}
# MUST FIRE: the same check over a PRE-FIX library (the two new classes deleted) must report DRIFT, or the
# case above would pass on a bake that can no longer detect anything.
# LIVE-TWIN (2026-09-11): this arm rolls back the LIVE files in memory, so it rests on cheese_carrier and the baked
# bread-cheese pattern still being in them. The comment above the copies used to say it did not rest on live state.
$bkLib = Read-JsonFile (Join-Path $root 'category-excludes.json')
$bkLib.classes.PSObject.Properties.Remove('cheese_carrier')
$bkLib.classes.PSObject.Properties.Remove('cracker_carrier')
$bkApply = @()
foreach ($a in $bkLib.apply) {
  $a.classes = @(@($a.classes) | Where-Object { $_ -ne 'cheese_carrier' -and $_ -ne 'cracker_carrier' })
  $bkApply += $a
}
$bkLib.apply = $bkApply
# a commodities.json that predates the two classes: strip the two baked patterns back out
# LIVE-TWIN: the live file, rolled back in memory (see above)
$bkCom = Read-JsonFile (Join-Path $root 'commodities.json')
foreach ($c in $bkCom) { if ($c.exclude) { $c.exclude = @(@($c.exclude) | Where-Object { $_ -ne 'bread\s+cheese' }) } }
Set-Content (Join-Path $fxBk 'commodities.json') ($bkCom | ConvertTo-Json -Depth 6) -Encoding UTF8
# the LIBRARY still carries the classes; only the baked file was rolled back - that is what DRIFT means
$r = RunPS 'apply-category-excludes.ps1' @('-Root', $fxBk, '-WhatIf')
if ($r.rc -eq 0 -and $r.text -notmatch 'library:\s*\+0 patterns') {
  Ok 'bake-currency MUST-FIRE: a commodities.json missing the baked cheese_carrier pattern is reported as drift, not as current'
} else {
  Bad 'bake-currency check cannot detect drift - it would report CURRENT over a rule file that never got the class, which is the whole failure it exists to catch'
}
Remove-Item $fxBk -Recurse -Force -ErrorAction SilentlyContinue
} # u035-d6-bake-currency-a-library-class

# (ce1) THE BAKE MUST NOT UN-PIN THE RULE FILE'S ENCODING (2026-09-02, found while shipping 1527d2).
# commodities.json expresses every non-ASCII character as a JSON \uXXXX escape and carries no BOM, and
# audit-json-encoding.ps1 lists it in ASCII_PINNED where a single non-ASCII byte is a hard finding. That
# pin is what the 2026-08-31 mojibake repair bought: a corrupted character CLASS keeps matching the plain
# spelling while silently losing the accented one, so the damage is invisible from the board.
# apply-category-excludes.ps1 is the sanctioned way to bake the library into every commodity, and its write
# was `ConvertTo-Json | Set-Content -Encoding UTF8`: ConvertTo-Json emits those characters LITERALLY and
# Set-Content prepends a BOM. Measured on a scratch copy of the live tree 2026-09-02 - a NO-OP bake ("+0
# patterns across 0 commodities") still rewrote the file into 84 non-ASCII bytes plus a BOM. The 08-31 pass
# fixed this script's READ and left its WRITE, so the guard and the tool that violates it shipped together.
# MUST-FIRE is the pre-fix writer, run over a fixture whose rule really does carry an n-tilde escape.
# The needle is built by concatenation, never written as a literal this file could match against itself.
if (Use-Unit 'u036-ce1-the-bake-must-not-un-pin-the') {
$fxCe = NewFxDir 'catex-ascii'
$ceEnye = '\u' + '00f1'   # the escape, as six ASCII characters on disk
$ceCommod = '[{"id":"pickled-jalapenos","label":"Pickled Jalapenos","unit":"oz","include":["jalape[n' + $ceEnye + ']o\\s+peppers"],"exclude":[]}]'
Set-Content (Join-Path $fxCe 'commodities.json') $ceCommod -Encoding UTF8
Set-Content (Join-Path $fxCe 'categories.json') '{"categories":[{"label":"Vegetables","commodities":["pickled-jalapenos"]}]}' -Encoding UTF8
# LIVE-TWIN (2026-09-11): the bake needs a library to run, and this is production's. The verdict is the writer's
# bytes, which an escaping writer keeps pure ASCII whatever classes the library holds.
Copy-Item (Join-Path $root 'category-excludes.json') (Join-Path $fxCe 'category-excludes.json')
$r = RunPS 'apply-category-excludes.ps1' @('-Root', $fxCe)
$ceBytes = [IO.File]::ReadAllBytes((Join-Path $fxCe 'commodities.json'))
$ceBom = ($ceBytes.Length -ge 3 -and $ceBytes[0] -eq 0xEF -and $ceBytes[1] -eq 0xBB -and $ceBytes[2] -eq 0xBF)
$ceNon = 0; foreach ($ceB in $ceBytes) { if ($ceB -gt 127) { $ceNon++ } }
if ($r.rc -eq 0 -and -not $ceBom -and $ceNon -eq 0) { Ok 'apply-category-excludes writes commodities.json back PURE ASCII with no BOM (the audit-json-encoding pin survives a bake)' }
else { Bad ('apply-category-excludes un-pinned the rule file: bom=' + $ceBom + ' non-ascii bytes=' + $ceNon + ' rc=' + $r.rc + ' - ops\run-gates.ps1 will hard-fail on audit-json-encoding, and the accented spellings have stopped matching') }
# MUST-FIRE: the writer as it stood before the fix, run over the same fixture, MUST produce the finding.
# Without this the case above could pass on a fixture that simply has no non-ASCII left to lose.
$ceSrc = Get-Content (Join-Path $root 'apply-category-excludes.ps1') -Raw
$ceOld = $ceSrc -replace '(?m)^Write-AsciiPinnedJson -Json \(\$commods \| ConvertTo-Json -Depth 6\) -Path \(Join-Path \$root ''commodities\.json''\)', '($commods | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $root ''commodities.json'') -Encoding UTF8'
if ($ceOld -eq $ceSrc) { Bad 'could not build the pre-fix writer for the must-fire case - apply-category-excludes no longer calls Write-AsciiPinnedJson, so this case proved NOTHING' }
else {
  Set-Content (Join-Path $fxCe 'commodities.json') $ceCommod -Encoding UTF8
  $ceMut = Join-Path $fxCe 'apply-category-excludes.OLD.ps1'
  Set-Content $ceMut $ceOld -Encoding UTF8
  $rm = PSChild $ceMut '-Root' $fxCe
  $ceB2 = [IO.File]::ReadAllBytes((Join-Path $fxCe 'commodities.json'))
  $ceBom2 = ($ceB2.Length -ge 3 -and $ceB2[0] -eq 0xEF -and $ceB2[1] -eq 0xBB -and $ceB2[2] -eq 0xBF)
  $ceNon2 = 0; foreach ($ceB in $ceB2) { if ($ceB -gt 127) { $ceNon2++ } }
  if ($ceBom2 -or $ceNon2 -gt 0) { Ok 'MUST-FIRE: the pre-fix writer really does un-pin the file (this case can still catch a regression)' }
  else { Bad 'MUST-FIRE inert: the pre-fix writer left the fixture pure ASCII, so the clean case above is not testing anything - re-check the fixture carries a \uXXXX escape' }
}
Remove-Item $fxCe -Recurse -Force -ErrorAction SilentlyContinue
} # u036-ce1-the-bake-must-not-un-pin-the

# (e) audit-tile-integrity: ACCURACY BLIND + exit 3 when zero links were graded (an empty product-urls used
# to certify "ACCURACY OK - every link that ships..." having examined nothing; prune-bad-links can empty the
# set on a live daily path, which is exactly when the certificate would lie).
if (Use-Unit 'u037-e-audit-tile-integrity-accuracy') {
$fxTi = NewFxDir 'ti-blind'
# The copy list is the subject's own grocery\ gate-inputs: audit-tile-integrity dot-sources link-sibling-lib.ps1
# since 2026-09-26 (queue fab315), and without it the copy threw at start-up with rc=1 on all four cases below.
foreach ($cf in @('audit-tile-integrity.ps1','pu-lib.ps1','link-sibling-lib.ps1')) { Copy-Item (Join-Path $root $cf) (Join-Path $fxTi $cf) }
New-Item -ItemType Directory -Force (Join-Path $fxTi 'out') | Out-Null
Set-Content (Join-Path $fxTi 'product-urls.json') '{"items":{}}' -Encoding UTF8
Set-Content (Join-Path $fxTi 'out\comparison-2026-01-01.json') '{"comparison":[{"id":"test-oats","unit":"oz","stores":[{"store":"Hy-Vee","per_unit":0.10,"type":"everyday","item":"Test Oats 16 oz"}]}]}' -Encoding UTF8
$r = RunPSAt $fxTi 'audit-tile-integrity.ps1' @('-OutDir', (Join-Path $fxTi 'out'))
if ($r.rc -eq 3 -and $r.text -match 'ACCURACY BLIND') { Ok 'tile-integrity goes ACCURACY BLIND (exit 3) when zero links were graded' }
else { Bad ('tile-integrity did NOT go blind with an empty product-urls (rc=' + $r.rc + ') - the empty accuracy certificate is back') }
Set-Content (Join-Path $fxTi 'product-urls.json') '{"items":{"test-oats":{"Hy-Vee":{"url":"https://example.test/oats","price":"$1.60","size":"16 oz","name":"Test Oats 16 oz"}}}}' -Encoding UTF8
$r = RunPSAt $fxTi 'audit-tile-integrity.ps1' @('-OutDir', (Join-Path $fxTi 'out'))
if ($r.rc -eq 0 -and $r.text -match 'ACCURACY OK - all 1 price-graded links') { Ok 'tile-integrity clean twin: one matching link grades and the OK line carries the count' }
else { Bad ('tile-integrity clean twin failed (rc=' + $r.rc + ')') }
# the -Baseline and -Strict paths must honor the same BLIND contract (post-batch review 2026-07-30: both
# exited 0 on the blind state, and a blind -Baseline wrote every priced tile as the coverage high-water
# mark - permanently disarming the ratchet with exit 0, during exactly the incident where someone would
# reach for -Baseline). Must-fire: blind + -Baseline refuses (rc 3, NO baseline file); blind + -Strict rc 3.
Set-Content (Join-Path $fxTi 'product-urls.json') '{"items":{}}' -Encoding UTF8
Remove-Item (Join-Path $fxTi 'out\tile-integrity-baseline.json') -Force -ErrorAction SilentlyContinue
$r = RunPSAt $fxTi 'audit-tile-integrity.ps1' @('-OutDir', (Join-Path $fxTi 'out'), '-Baseline')
if ($r.rc -eq 3 -and $r.text -match 'Baseline REFUSED' -and -not (Test-Path (Join-Path $fxTi 'out\tile-integrity-baseline.json'))) { Ok 'tile-integrity -Baseline REFUSES a blind run (rc 3, poisoned baseline never written)' }
else { Bad ('tile-integrity -Baseline accepted a BLIND run (rc=' + $r.rc + ', baseline written: ' + (Test-Path (Join-Path $fxTi 'out\tile-integrity-baseline.json')) + ') - the coverage ratchet can be silently disarmed') }
# -Strict's blind shape is the EMPTY board (zero tiles): a NO-LINK tile is a real strict violation and
# must stay exit 2, but zero-of-anything satisfies "every priced tile has a link" vacuously - that is the
# shape that must read BLIND, not achieved.
Set-Content (Join-Path $fxTi 'out\comparison-2026-01-01.json') '{"comparison":[]}' -Encoding UTF8
$r = RunPSAt $fxTi 'audit-tile-integrity.ps1' @('-OutDir', (Join-Path $fxTi 'out'), '-Strict')
if ($r.rc -eq 3) { Ok 'tile-integrity -Strict reports BLIND (rc 3) on an empty board instead of a vacuous every-tile-linked pass' }
else { Bad ('tile-integrity -Strict returned rc=' + $r.rc + ' on a blind run - the end-state claim is vacuously satisfiable again') }
Remove-Item $fxTi -Recurse -Force -ErrorAction SilentlyContinue
} # u037-e-audit-tile-integrity-accuracy

# (f) audit-cell-drops: BLIND on both silent paths - fewer than 2 dated boards, and a baseline board that
# parses to zero everyday cells (which used to print the POSITIVE "no everyday cell lost" ok line).
if (Use-Unit 'u038-f-audit-cell-drops-blind-on-both') {
$fxCd = NewFxDir 'cd-blind'
Copy-Item (Join-Path $root 'audit-cell-drops.ps1') (Join-Path $fxCd 'audit-cell-drops.ps1')
New-Item -ItemType Directory -Force (Join-Path $fxCd 'out') | Out-Null
Set-Content (Join-Path $fxCd 'out\comparison-2026-01-08.json') '{"comparison":[{"id":"eggs","stores":[{"store":"Hy-Vee","type":"everyday","per_unit":2.50}]}]}' -Encoding UTF8
$r = RunPSAt $fxCd 'audit-cell-drops.ps1' @()
if ($r.rc -eq 3 -and $r.text -match 'BLIND - only 1 dated board') { Ok 'cell-drops goes BLIND (exit 3) with a single dated board' }
else { Bad ('cell-drops did NOT go blind with one board (rc=' + $r.rc + ')') }
Set-Content (Join-Path $fxCd 'out\comparison-2026-01-01.json') '{"comparison":[]}' -Encoding UTF8
$r = RunPSAt $fxCd 'audit-cell-drops.ps1' @()
if ($r.rc -eq 3 -and $r.text -match 'compared ZERO everyday cells') { Ok 'cell-drops goes BLIND (exit 3) on an empty-comparison baseline (the false positive-ok shape)' }
else { Bad ('cell-drops printed a verdict against an EMPTY baseline board (rc=' + $r.rc + ')') }
Set-Content (Join-Path $fxCd 'out\comparison-2026-01-01.json') '{"comparison":[{"id":"eggs","stores":[{"store":"Hy-Vee","type":"everyday","per_unit":2.50}]}]}' -Encoding UTF8
$r = RunPSAt $fxCd 'audit-cell-drops.ps1' @()
if ($r.rc -eq 0 -and $r.text -match '\(1 cells compared\)') { Ok 'cell-drops clean twin: kept cell reads ok with the examined count' }
else { Bad ('cell-drops clean twin failed (rc=' + $r.rc + ')') }
Set-Content (Join-Path $fxCd 'out\comparison-2026-01-08.json') '{"comparison":[]}' -Encoding UTF8
$r = RunPSAt $fxCd 'audit-cell-drops.ps1' @()
if ($r.rc -eq 1) { Ok 'cell-drops still detects a real drop (exit 1) - the founding Fareway-chicken shape' }
else { Bad ('cell-drops lost its drop detection (rc=' + $r.rc + ')') }
Remove-Item $fxCd -Recurse -Force -ErrorAction SilentlyContinue
} # u038-f-audit-cell-drops-blind-on-both

# (g) audit-name-drift: BLIND at zero cells tested; three consumers read its count=0 JSON as a positive
# clean result, so a blind write must at least page.
if (Use-Unit 'u039-g-audit-name-drift-blind-at-zero') {
$fxNd = NewFxDir 'nd-blind'
Copy-Item (Join-Path $root 'audit-name-drift.ps1') (Join-Path $fxNd 'audit-name-drift.ps1')
New-Item -ItemType Directory -Force (Join-Path $fxNd 'out') | Out-Null
# FROZEN commodities.json for the fixture. audit-name-drift subtracts every commodity id/label word from
# its learned brand lexicon (so "Carrot" is never treated as a manufacturer), which makes this file a REAL
# dependency of the script, not scenery. It was added to audit-name-drift on 2026-08-21 and the fixtures
# were not grown with it, so every name-drift case died on a raw Get-Content throw before reaching a
# verdict - five red tests that looked like a name-drift regression and were fixture rot.
Set-Content (Join-Path $fxNd 'commodities.json') '[{"id":"eggs","label":"Eggs"}]' -Encoding UTF8
Set-Content (Join-Path $fxNd 'product-urls.json') '{"items":{}}' -Encoding UTF8
Set-Content (Join-Path $fxNd 'out\comparison-2026-01-01.json') '{"comparison":[{"id":"eggs","stores":[{"store":"Hy-Vee","item":"Grade A Eggs 12 ct"}]}]}' -Encoding UTF8
$r = RunPSAt $fxNd 'audit-name-drift.ps1' @()
$ndJson = try { Read-JsonFile (Join-Path $fxNd 'out\name-drift.json') } catch { $null }
if ($r.rc -eq 3 -and $r.text -match 'BLIND' -and $ndJson -and [int]$ndJson.examined -eq 0) { Ok 'name-drift goes BLIND (exit 3) at zero cells and its JSON carries examined=0' }
else { Bad ('name-drift did NOT go blind with an empty product-urls (rc=' + $r.rc + ')') }
Set-Content (Join-Path $fxNd 'product-urls.json') '{"items":{"eggs":{"Hy-Vee":{"url":"https://example.test/eggs","price":"$2.50","size":"12 ct","name":"Grade A Eggs 12 ct"}}}}' -Encoding UTF8
$r = RunPSAt $fxNd 'audit-name-drift.ps1' @()
$ndJson = try { Read-JsonFile (Join-Path $fxNd 'out\name-drift.json') } catch { $null }
if ($r.rc -eq 0 -and $r.text -match '0 of 1 cells tested' -and $ndJson -and [int]$ndJson.examined -eq 1) { Ok 'name-drift clean twin: one matching link is examined and reported' }
else { Bad ('name-drift clean twin failed (rc=' + $r.rc + ')') }
Remove-Item $fxNd -Recurse -Force -ErrorAction SilentlyContinue
} # u039-g-audit-name-drift-blind-at-zero

# (g2) audit-name-drift: RULE-RELEASED (2026-09-22, queue 2026-09-22-e9aed3). The founding row, frozen: after
# mexican-chorizo-fresh gained `\bbeef\b` the Walmart cell priced "Cacique Pork Chorizo, 9 oz (Refrigerated)" while
# its link still opened "Cacique Beef Chorizo 12oz". Brand and "chorizo" are shared and 2.00 vs 2.68/lb is under
# the factor rule, so no link check saw it live. The Baker's pork links link is the clean twin.
if (Use-Unit 'u039r-audit-name-drift-rule-released') {
$fxNr = NewFxDir 'nd-released'
foreach ($f in @('audit-name-drift.ps1', 'global-exclude-lib.ps1', 'commodity-rules-lib.ps1')) { Copy-Item (Join-Path $root $f) (Join-Path $fxNr $f) }
New-Item -ItemType Directory -Force (Join-Path $fxNr 'out') | Out-Null
Set-Content (Join-Path $fxNr 'commodities.json') '[{"id":"mexican-chorizo-fresh","label":"Mexican Chorizo (Fresh)","include":["\\bchorizo\\b"],"exclude":["\\b(?:spanish|cured|smoked)\\b","\\bbeef\\b"]}]' -Encoding UTF8
Set-Content (Join-Path $fxNr 'out\comparison-2026-01-01.json') '{"comparison":[{"id":"mexican-chorizo-fresh","unit":"lb","stores":[{"store":"Walmart","item":"Cacique Pork Chorizo, 9 oz (Refrigerated)","per_unit":2.6786,"type":"everyday"},{"store":"Baker''s","item":"Kroger Mercado Chorizo Sausage Pork Links","per_unit":3.5467,"type":"everyday"}]}]}' -Encoding UTF8
Set-Content (Join-Path $fxNr 'product-urls.json') '{"items":{"mexican-chorizo-fresh":{"Walmart":{"url":"https://www.walmart.com/ip/10451933","price":"1.5","size":"0.75 lb","name":"Cacique Beef Chorizo 12oz"},"Baker''s":{"url":"https://www.bakersplus.com/p/kroger-mercado-chorizo-sausage-pork-links/0001111062555","price":"$3.99","size":"5 pk 3.6 oz","name":"Kroger Mercado Chorizo Sausage Pork Links"}}}}' -Encoding UTF8
$r = RunPSAt $fxNr 'audit-name-drift.ps1' @()
$ndJson = try { Read-JsonFile (Join-Path $fxNr 'out\name-drift.json') } catch { $null }
$wm = @(@($ndJson.flags) | Where-Object { $_ -and [string]$_.store -eq 'Walmart' })
$bk = @(@($ndJson.flags) | Where-Object { $_ -and [string]$_.store -eq "Baker's" })
if ($r.rc -eq 0 -and $wm.Count -eq 1 -and [string]$wm[0].reason -eq 'rule-released') { Ok 'MUST FIRE: name-drift flags the Walmart chorizo link to the beef product its own \bbeef\b exclude released (rule-released)' }
else { Bad ('name-drift did NOT flag the released beef chorizo link (rc=' + $r.rc + ', walmart flags=' + $wm.Count + ')') }
if ($ndJson -and [int]$ndJson.examined -eq 2 -and $bk.Count -eq 0) { Ok "CLEAN TWIN: the Baker's pork chorizo link is examined (2 of 2) and stays unflagged" }
else { Bad ("name-drift flagged or skipped the Baker's pork twin (examined=" + $(if ($ndJson) { $ndJson.examined } else { 'none' }) + ', flags=' + $bk.Count + ')') }
Remove-Item $fxNr -Recurse -Force -ErrorAction SilentlyContinue
} # u039r-audit-name-drift-rule-released

# (g2) audit-name-drift MUST be able to see a RECIPE-BOARD cell. Founding bug (2026-07-30): it read
# out\comparison-*.json only, so guards.ps1 guard 3's WRONG-PRODUCT clause - which looks a pin up in
# name-drift.json by id|store - could not fire for ANY pin, because all 16 pins in board-price-overrides.json
# are recipe-board-only ids. MUST-FIRE: a wrong-product link on a recipe-only id is flagged AND its id|store
# lands in examined_cells (the key guard 3 reads). CLEAN TWIN: the same fixture with a matching link name stays
# silent while the cell is still IN scope - the union must add coverage, not noise. Third assertion: an id on
# BOTH boards is scanned ONCE (the staple row wins), because the two boards carry different unit bases and one
# link cannot be judged against both. Frozen synthetic data - never regenerated from the live board.
if (Use-Unit 'u040-g2-audit-name-drift-must-be-able-to') {
$fxNdU = NewFxDir 'nd-union'
Copy-Item (Join-Path $root 'audit-name-drift.ps1') (Join-Path $fxNdU 'audit-name-drift.ps1')
New-Item -ItemType Directory -Force (Join-Path $fxNdU 'out') | Out-Null
# Same frozen dependency as the nd-blind fixture above. The three ids here are the ones this fixture's
# boards actually use, so the food-word subtraction is genuinely exercised rather than merely satisfied:
# without "paprika" among the food words, a one-product lexicon could learn it as a brand and the CLEAN
# TWIN below would flag a link that matches byte-for-byte.
Set-Content (Join-Path $fxNdU 'commodities.json') '[{"id":"eggs","label":"Eggs"},{"id":"shared-oats","label":"Oats"},{"id":"pinned-paprika","label":"Paprika"}]' -Encoding UTF8
Set-Content (Join-Path $fxNdU 'out\comparison-2026-01-01.json') '{"comparison":[{"id":"eggs","unit":"dozen","stores":[{"store":"Hy-Vee","per_unit":2.50,"type":"everyday","item":"Grade A Eggs 12 ct"}]},{"id":"shared-oats","unit":"oz","stores":[{"store":"Hy-Vee","per_unit":0.10,"type":"everyday","item":"Quaker Oats 42 oz"}]}]}' -Encoding UTF8
Set-Content (Join-Path $fxNdU 'out\recipe-board.json') '{"comparison":[{"id":"pinned-paprika","unit":"oz","stores":[{"store":"Hy-Vee","per_unit":0.99,"type":"everyday","item":"Simply Organic Smoked Paprika 2.72 oz"}]},{"id":"shared-oats","unit":"oz","stores":[{"store":"Hy-Vee","per_unit":0.10,"type":"everyday","item":"Bobs Redmill Steelcut Groats 24 oz"}]}]}' -Encoding UTF8
$ndUPu = '{"items":{"eggs":{"Hy-Vee":{"url":"https://example.test/eggs","price":"$2.50","size":"12 ct","name":"Grade A Eggs 12 ct"}},"shared-oats":{"Hy-Vee":{"url":"https://example.test/oats","price":"$4.20","size":"42 oz","name":"Quaker Oats 42 oz"}},"pinned-paprika":{"Hy-Vee":{"url":"https://example.test/p","price":"$2.69","size":"2.72 oz","name":"{LINK}"}}}}'
Set-Content (Join-Path $fxNdU 'product-urls.json') ($ndUPu -replace '\{LINK\}','Badia Garlic Powder') -Encoding UTF8
$r = RunPSAt $fxNdU 'audit-name-drift.ps1' @()
$ndU = try { Read-JsonFile (Join-Path $fxNdU 'out\name-drift.json') } catch { $null }
$ndUCells = @($ndU.examined_cells)
if ($r.rc -eq 0 -and $ndU -and [int]$ndU.count -eq 1 -and @($ndU.flags)[0].id -eq 'pinned-paprika' -and ($ndUCells -contains 'pinned-paprika|Hy-Vee')) {
  Ok 'name-drift MUST-FIRE: a wrong-product link on a RECIPE-board-only id is flagged and recorded in examined_cells (guard 3 can arm)'
} else {
  Bad ('name-drift did NOT flag the recipe-board-only wrong product (rc=' + $r.rc + ', count=' + [int]$ndU.count + ', examined_cells lists pinned-paprika: ' + ($ndUCells -contains 'pinned-paprika|Hy-Vee') + ') - guard 3''s WRONG-PRODUCT clause is unfirable again')
}
if (@($ndUCells | Where-Object { $_ -eq 'shared-oats|Hy-Vee' }).Count -eq 1) { Ok 'name-drift scans a two-board id ONCE (staple row wins; the recipe row''s different unit basis is not re-judged against the same link)' }
else { Bad ('name-drift recorded ' + @($ndUCells | Where-Object { $_ -eq 'shared-oats|Hy-Vee' }).Count + ' scans of the colliding id (expected 1) - either examined_cells is missing entirely, or one link is being judged against two different unit bases') }
Set-Content (Join-Path $fxNdU 'product-urls.json') ($ndUPu -replace '\{LINK\}','Simply Organic Smoked Paprika 2.72 oz') -Encoding UTF8
$r = RunPSAt $fxNdU 'audit-name-drift.ps1' @()
$ndU = try { Read-JsonFile (Join-Path $fxNdU 'out\name-drift.json') } catch { $null }
if ($r.rc -eq 0 -and $ndU -and [int]$ndU.count -eq 0 -and (@($ndU.examined_cells) -contains 'pinned-paprika|Hy-Vee')) {
  Ok 'name-drift CLEAN TWIN: the recipe cell is in scope and a matching link stays unflagged (the union adds coverage, not noise)'
} else {
  Bad ('name-drift clean twin failed (rc=' + $r.rc + ', count=' + [int]$ndU.count + ') - the union is manufacturing flags')
}
Remove-Item $fxNdU -Recurse -Force -ErrorAction SilentlyContinue
} # u040-g2-audit-name-drift-must-be-able-to

# (g3) audit-name-drift MUST catch SAME BRAND, DIFFERENT PRODUCT. Founding bug (2026-08-30): the Sam's
# frozen-fruit cell. The board priced "Member's Mark Natural Sliced Strawberries, Frozen, 4 lbs." at
# 12.47c/oz; the link named "Member's Mark Triple Berry Blend, Frozen, 64 oz." at 16.34c/oz - a different
# product, sitting in the same capture. Every clause here was satisfied: the token test matched on the house
# brand once $stop had removed strawberries/frozen/natural/lbs, form-flip could not fire (both say frozen),
# count mismatch could not fire (neither states a count), and brand mismatch correctly stayed silent because
# it IS the same brand. name-drift reported the cell clean and generate-board-overrides pinned the published
# price to the wrong product's per-unit.
# TWO defects, and the fixture holds both. The lexicon: a bare possessive "s" used to occupy a token slot, so
# "Membrix's Marque X" tokenised membrix(0)/s(1)/marque(2) and `marque` was NEVER counted as leading anywhere
# in the corpus - it never became a brand, so it survived into the identity comparison as though it were a
# food word and the two names SHARED it. The rule: strip the brand off both names and require they still
# share something. Hence the possessive brand below - a fixture spelled "Membrix Marque" would pass with the
# lexicon fix reverted.
# CLEAN TWIN: the same cell with a link naming the same product stays silent, because a false flag here is not
# free - generate-board-overrides refuses to pin any cell name-drift flags, so noise silently blocks good
# corrections. Frozen synthetic data - never regenerated from the live board.
if (Use-Unit 'u041-g3-audit-name-drift-must-catch-same') {
$fxNdP = NewFxDir 'nd-product'
Copy-Item (Join-Path $root 'audit-name-drift.ps1') (Join-Path $fxNdP 'audit-name-drift.ps1')
New-Item -ItemType Directory -Force (Join-Path $fxNdP 'out\regular') | Out-Null
Set-Content (Join-Path $fxNdP 'commodities.json') '[{"id":"frozen-fruit","label":"Frozen Fruit"}]' -Encoding UTF8
# A SYNTHETIC CORPUS BIG ENOUGH TO ARM THE CLAUSE. Both brand-aware rules gate on $brandActive
# ($BRAND.Count -ge 100), so a two-name fixture would test nothing but the disabled path - the shape of a
# guard that "passes" because it never ran. 119 filler brands + the one under test = 121 learned brands.
# Each brand gets 6 names carrying all 6 filler words in rotated order, so every filler lands in a lead slot
# exactly once in six (ratio 0.17, nowhere near the 0.80 bar) while each brand leads 6 of 6. That keeps the
# lexicon honest: the fillers must NOT be learned as brands or the identity sets below would be emptied.
$ndPFill  = @('alpha','bravo','charlie','delta','echo','foxtrot')
$ndPNames = New-Object System.Collections.Generic.List[string]
foreach ($ndPBrand in (@(1..119 | ForEach-Object { 'zebrand' + $_.ToString('000') }) + @("Membrix's Marque"))) {
  for ($k = 0; $k -lt 6; $k++) {
    $rot = @(); for ($j = 0; $j -lt 6; $j++) { $rot += $ndPFill[($j + $k) % 6] }
    $ndPNames.Add($ndPBrand + ' ' + ($rot -join ' '))
  }
}
Set-Content (Join-Path $fxNdP 'out\regular\lex-regular-2026-01-01.json') (@{ store = 'Lex'; deals = @($ndPNames | ForEach-Object { @{ item = $_ } }) } | ConvertTo-Json -Depth 4) -Encoding UTF8
Set-Content (Join-Path $fxNdP 'out\comparison-2026-01-01.json') '{"comparison":[{"id":"frozen-fruit","unit":"oz","stores":[{"store":"Sam''s Club","per_unit":0.1247,"type":"everyday","item":"Membrix''s Marque Natural Sliced Strawberries, Frozen, 4 lbs."}]}]}' -Encoding UTF8
$ndPPu = '{"items":{"frozen-fruit":{"Sam''s Club":{"url":"https://example.test/ff","price":"$10.46","size":"64 oz","name":"{LINK}"}}}}'
Set-Content (Join-Path $fxNdP 'product-urls.json') ($ndPPu -replace '\{LINK\}',"Membrix's Marque Triple Berry Blend, Frozen, 64 oz.") -Encoding UTF8
$r = RunPSAt $fxNdP 'audit-name-drift.ps1' @()
$ndP = try { Read-JsonFile (Join-Path $fxNdP 'out\name-drift.json') } catch { $null }
if ($r.rc -eq 0 -and $ndP -and [int]$ndP.count -eq 1 -and @($ndP.flags)[0].reason -eq 'product-mismatch' -and @($ndP.flags)[0].id -eq 'frozen-fruit') {
  Ok 'name-drift MUST-FIRE: same brand, different product is flagged product-mismatch (the pin that published Triple Berry over Sliced Strawberries cannot be minted)'
} else {
  Bad ('name-drift did NOT flag same-brand-different-product (rc=' + $r.rc + ', count=' + [int]$ndP.count + ', reason=' + @($ndP.flags)[0].reason + ') - either the identity rule is gone or a possessive is eating the second brand word again, and a wrong-product link can pin a price over the board')
}
Set-Content (Join-Path $fxNdP 'product-urls.json') ($ndPPu -replace '\{LINK\}',"Membrix's Marque Natural Sliced Strawberries, Frozen, 4 lbs.") -Encoding UTF8
$r = RunPSAt $fxNdP 'audit-name-drift.ps1' @()
$ndP = try { Read-JsonFile (Join-Path $fxNdP 'out\name-drift.json') } catch { $null }
if ($r.rc -eq 0 -and $ndP -and [int]$ndP.count -eq 0 -and [int]$ndP.examined -eq 1) {
  Ok 'name-drift CLEAN TWIN: a link naming the SAME product stays unflagged (the identity rule adds coverage, not noise that would block good pins)'
} else {
  Bad ('name-drift product-identity clean twin failed (rc=' + $r.rc + ', count=' + [int]$ndP.count + ', examined=' + [int]$ndP.examined + ') - the identity rule is manufacturing flags, which silently blocks legitimate price corrections')
}
Remove-Item $fxNdP -Recurse -Force -ErrorAction SilentlyContinue
} # u041-g3-audit-name-drift-must-catch-same

# (g4) generate-board-overrides' BOARD-CONFIRMED-FRESH gate must read the files the ENGINE priced from.
# Founding bug (2026-08-30): the gate kept a private store -> filename map sending Sam's to
# out\regular\sams-regular-*.json. Sam's has NO out\regular file - the club catalogue is CAPTCHA-walled and
# its everyday prices come only from out\sams\sams-deals-*.json - but two orphan sams-regular files from
# July/August were still lying there, so the gate opened them, matched nothing, raised no alarm (its zero-rows
# warning was estate-wide and six other stores kept the total non-zero) and FAILED OPEN for every Sam's cell.
# The pin it then wrote moved frozen-fruit from the board's own 12.47c/oz to a different product's 16.34c/oz.
# MUST-FIRE: the board's exact item at its exact price sits in out\sams, so the gate refuses the pin - and the
# decoy sams-regular file below is the founding condition, because with the old map that decoy is ALL the gate
# would open and the pin would be written. CLEAN TWIN: the same board cell with the item ABSENT from the Sam's
# feed is a genuinely stale number, and the pin must still be written - a gate that refuses everything is as
# broken as one that refuses nothing, it just fails in the quiet direction. Frozen synthetic data.
if (Use-Unit 'u042-g4-generate-board-overrides-board') {
$fxGbo = NewFxDir 'gbo-samsfeed'
foreach ($gboDep in @('generate-board-overrides.ps1','pu-lib.ps1','regular-fileset-lib.ps1')) { Copy-Item (Join-Path $root $gboDep) (Join-Path $fxGbo $gboDep) }
New-Item -ItemType Directory -Force (Join-Path $fxGbo 'out\sams') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $fxGbo 'out\regular') | Out-Null
Set-Content (Join-Path $fxGbo 'out\comparison-2026-01-01.json') '{"comparison":[{"id":"frozen-fruit","unit":"oz","stores":[{"store":"Sam''s Club","per_unit":0.1247,"type":"everyday","item":"Members Mark Sliced Strawberries, Frozen, 4 lbs.","ad":"$7.98","size":"4 lb"}]}]}' -Encoding UTF8
Set-Content (Join-Path $fxGbo 'product-urls.json') '{"items":{"frozen-fruit":{"Sam''s Club":{"url":"https://example.test/tb","price":"$10.46","size":"64 oz","name":"Members Mark Triple Berry Blend, Frozen, 64 oz."}}}}' -Encoding UTF8
Set-Content (Join-Path $fxGbo 'out\name-drift.json') '{"generated":"2026-01-01","count":0,"examined":1,"examined_cells":["frozen-fruit|Sam''s Club"],"flags":[]}' -Encoding UTF8
# THE DECOY. An orphan out\regular file for a store whose prices do not live there - exactly the two files
# still sitting in the live tree on the morning this broke. It must not be what the gate believes.
Set-Content (Join-Path $fxGbo 'out\regular\sams-regular-2026-01-01.json') '{"store":"Sam''s Club","captured":"2026-01-01","deals":[{"store":"Sam''s Club","item":"Members Mark Paper Towels, 12 ct.","ad_price":"$19.98","size":"12 ct","as_of":"2026-01-01"}]}' -Encoding UTF8
$gboSams = '{"store":"Sam''s Club","captured":"2026-01-01","deals":[{{ROWS}}]}'
$gboBoardRow = '{"store":"Sam''s Club","item":"Members Mark Sliced Strawberries, Frozen, 4 lbs.","ad_price":"$7.98","size":"4 lb","as_of":"2026-01-01"}'
$gboLinkRow  = '{"store":"Sam''s Club","item":"Members Mark Triple Berry Blend, Frozen, 64 oz.","ad_price":"$10.46","size":"64 oz","as_of":"2026-01-01"}'
Set-Content (Join-Path $fxGbo 'out\sams\sams-deals-2026-01-01.json') ($gboSams -replace '\{\{ROWS\}\}',($gboBoardRow + ',' + $gboLinkRow)) -Encoding UTF8
$r = RunPSAt $fxGbo 'generate-board-overrides.ps1' @()
$gbo = try { Read-JsonFile (Join-Path $fxGbo 'board-price-overrides.json') } catch { $null }
if ($gbo -and [int]$gbo.count -eq 0 -and $r.text -match 'board-CONFIRMED-FRESH, pin REFUSED' -and $r.text -match 'frozen-fruit') {
  Ok 'board-confirmed-fresh MUST-FIRE: the gate reads out\sams (the engine''s Sam''s input) and refuses to pin a different product over a price the store''s own pull confirms'
} else {
  Bad ('board-confirmed-fresh did NOT refuse the Sam''s pin (count=' + [int]$gbo.count + ') - the gate is reading a fileset the board never priced from and is failing OPEN for that store')
}
Set-Content (Join-Path $fxGbo 'out\sams\sams-deals-2026-01-01.json') ($gboSams -replace '\{\{ROWS\}\}',$gboLinkRow) -Encoding UTF8
$r = RunPSAt $fxGbo 'generate-board-overrides.ps1' @()
$gbo = try { Read-JsonFile (Join-Path $fxGbo 'board-price-overrides.json') } catch { $null }
if ($gbo -and [int]$gbo.count -eq 1 -and [math]::Abs([double](@($gbo.cells)[0].per_unit) - 0.1634) -lt 0.0005) {
  Ok 'board-confirmed-fresh CLEAN TWIN: a board number the store''s own pull does NOT carry is still corrected (the gate refuses, it does not veto)'
} else {
  Bad ('board-confirmed-fresh clean twin failed (count=' + [int]$gbo.count + ') - the gate has stopped letting legitimate stale-board corrections through')
}
Remove-Item $fxGbo -Recurse -Force -ErrorAction SilentlyContinue
} # u042-g4-generate-board-overrides-board

# (h) audit-links: BLIND when zero of the stored links matched a board id/store (a schema break in either
# input used to print "audited N links: 0 price-match, 0 MISMATCH, 0 uncomputable" - flag-free JSON included).
if (Use-Unit 'u043-h-audit-links-blind-when-zero-of-the') {
$fxAl = NewFxDir 'al-blind'
Copy-Item (Join-Path $root 'audit-links.ps1') (Join-Path $fxAl 'audit-links.ps1')
New-Item -ItemType Directory -Force (Join-Path $fxAl 'out') | Out-Null
Set-Content (Join-Path $fxAl 'out\comparison-2026-01-01.json') '{"comparison":[{"id":"eggs","unit":"dozen","stores":[{"store":"Hy-Vee","per_unit":2.50}]}]}' -Encoding UTF8
Set-Content (Join-Path $fxAl 'product-urls.json') '{"items":{"zzz-not-on-board":{"Hy-Vee":{"url":"https://example.test/z","price":"$5.00","size":"dozen","name":"Z"}}}}' -Encoding UTF8
$r = RunPSAt $fxAl 'audit-links.ps1' @()
if ($r.rc -eq 3 -and $r.text -match 'examined ZERO of 1 links') { Ok 'audit-links goes BLIND (exit 3) when no link matches the board' }
else { Bad ('audit-links did NOT go blind with zero matchable links (rc=' + $r.rc + ')') }
Set-Content (Join-Path $fxAl 'product-urls.json') '{"items":{"eggs":{"Hy-Vee":{"url":"https://example.test/eggs","price":"$2.50","size":"dozen","name":"Eggs"}}}}' -Encoding UTF8
$r = RunPSAt $fxAl 'audit-links.ps1' @()
if ($r.rc -eq 0 -and $r.text -match 'audited 1 of 1 links') { Ok 'audit-links clean twin: one computable link audits with the honest of-total summary' }
else { Bad ('audit-links clean twin failed (rc=' + $r.rc + ')') }
Remove-Item $fxAl -Recurse -Force -ErrorAction SilentlyContinue
} # u043-h-audit-links-blind-when-zero-of-the

# (i) audit-coverage-gaps: BLIND only at TOTAL blindness (zero raw products for EVERY store); a partial
# blind day is reported per-store in the JSON + qualified line but keeps exit 0/2 (a real finding must win).
if (Use-Unit 'u044-i-audit-coverage-gaps-blind-only-at') {
$fxCg = NewFxDir 'cg-blind'
$fxCgBoard = Join-Path $fxCg 'fix-board.json'
Set-Content $fxCgBoard '{"comparison":[{"id":"bananas","stores":[]}]}' -Encoding UTF8
$r = RunPS 'audit-coverage-gaps.ps1' @('-OutDir', $fxCg, '-CompareFile', $fxCgBoard)
$cgJson = try { Read-JsonFile (Join-Path $fxCg 'coverage-gaps.json') } catch { $null }
if ($r.rc -eq 3 -and $r.text -match 'BLIND - ZERO raw products' -and $cgJson -and @($cgJson.stores_not_scanned).Count -eq 7) { Ok 'coverage-gaps goes BLIND (exit 3) at total blindness and names all 7 unscanned stores in its JSON' }
else { Bad ('coverage-gaps did NOT go blind with zero raw products (rc=' + $r.rc + ')') }
Set-Content (Join-Path $fxCg 'ads-2026-01-01.json') '{"deals":[{"store":"Hy-Vee","item":"zzzz"},{"store":"Aldi","item":"zzzz"},{"store":"Family Fare","item":"zzzz"},{"store":"Fareway","item":"zzzz"},{"store":"Baker''s","item":"zzzz"},{"store":"Sam''s Club","item":"zzzz"},{"store":"Walmart","item":"zzzz"}]}' -Encoding UTF8
$r = RunPS 'audit-coverage-gaps.ps1' @('-OutDir', $fxCg, '-CompareFile', $fxCgBoard)
if ($r.rc -eq 0 -and $r.text -match 'coverage-gaps: none - every store') { Ok 'coverage-gaps clean twin: all 7 stores seeded reads the plain none line' }
else { Bad ('coverage-gaps clean twin failed (rc=' + $r.rc + ')') }
Remove-Item $fxCg -Recurse -Force -ErrorAction SilentlyContinue
} # u044-i-audit-coverage-gaps-blind-only-at

# (j) guards' advisory wrappers: a child exiting non-0/non-1 must land in WARN, never in the ok Say line
# (the bare else used to relabel any unrecognised exit - including the new exit 3 - as "  ok"). The chain
# below is a copy of the post-edit wrapper shape; the source asserts pin guards.ps1 to it.
if (Use-Unit 'u045-j-guards-advisory-wrappers-a-child') {
$fxGw = NewFxDir 'gw-child'
Set-Content (Join-Path $fxGw 'exit5.ps1') 'exit 5' -Encoding UTF8
Set-Content (Join-Path $fxGw 'exit0.ps1') 'Write-Output "fine"; exit 0' -Encoding UTF8
$fxGwWarn = New-Object System.Collections.ArrayList
$fxGwOk = New-Object System.Collections.ArrayList
foreach ($fxChild in @('exit5.ps1','exit0.ps1')) {
  try {
    $null = PSChild (Join-Path $fxGw $fxChild)
    if ($LASTEXITCODE -eq 0) { [void]$fxGwOk.Add($fxChild) }
    elseif ($LASTEXITCODE -eq 3) { [void]$fxGwWarn.Add($fxChild + ':blind') }
    else { [void]$fxGwWarn.Add($fxChild) }
  } catch { [void]$fxGwWarn.Add($fxChild + ':catch') }
}
if ($fxGwWarn -contains 'exit5.ps1' -and $fxGwOk -notcontains 'exit5.ps1' -and $fxGwOk -contains 'exit0.ps1' -and $fxGwWarn.Count -eq 1) { Ok 'wrapper chain: exit 5 lands in warn (not ok), exit 0 lands in ok' }
else { Bad ('wrapper chain misroutes exit codes: warn=[' + ($fxGwWarn -join ',') + '] ok=[' + ($fxGwOk -join ',') + ']') }
Remove-Item $fxGw -Recurse -Force -ErrorAction SilentlyContinue
$gSrc = Get-Content (Join-Path $root 'guards.ps1') -Raw
if (([regex]::Matches($gSrc, 'elseif \(\$LASTEXITCODE -eq 3\)')).Count -ge 2 -and $gSrc -match 'is MISSING - the allowlist-rot check scanned ZERO entries') { Ok 'guards.ps1 keeps both advisory-wrapper exit-3 branches and the missing-allowlist warn' }
else { Bad 'guards.ps1 lost an advisory-wrapper exit-3 branch or the missing-allowlist warn - a blind child prints ok again' }
} # u045-j-guards-advisory-wrappers-a-child

# (k) the direct callers keep their blind branches (source asserts - house precedent for caller plumbing;
# the behavioral exit-3s are covered by the producer fixtures above).
if (Use-Unit 'u046-k-the-direct-callers-keep-their') {
$cacSrc = Get-Content (Join-Path $root 'check-ad-cycles.ps1') -Raw
} # u046-k-the-direct-callers-keep-their

# ---- THE LAST MILE: what the pipeline computes must reach a reader, and only if it passed ------------
# Two founding bugs, both 2026-08-22, both invisible to every other check in this file.
# (1) The 2026-08-20 cutover to the TC tasks left the commit+push behind in run-daily-local.ps1. The
#     chain rebuilt public\board.json every morning and nothing shipped it: last pipeline commit was
#     08-18 while every guard read green, because "published" was measured between two LOCAL files.
# (2) The publish stage that fixed (1) staged public\** unconditionally - so a board guards had BLOCKED
#     still shipped its feed to the edge, and the 07:00 ad run, which builds nothing, pushed whatever a
#     session had left mid-edit in meal-prep\.
# These are source asserts because the plumbing is the bug: the behaviour only appears on a real run,
# and by then it is a live wrong price. Same precedent as the guard-caller asserts above.
if (Use-Unit 'u047-the-last-mile-what-the-pipeline') {
$crSrc = Get-Content (Join-Path $root 'capture-run.ps1') -Raw
} # u047-the-last-mile-what-the-pipeline
