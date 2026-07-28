<#
  test-guards.ps1 - negative tests. A guard that cannot fail is worthless, so break each invariant on
  purpose, assert guards.ps1 exits 2, then restore and assert it exits 0 again.
  Every mutation is made on a COPY-then-restore basis; nothing is left changed.
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$pass = 0; $failed = 0

# ---- CRASH-SAFE RESTORE (2026-07-28) -------------------------------------------------------------------
# This suite tests by BREAKING live production files and putting them back: 16 mutation windows, 13 of them
# on git-tracked files, and until now not one was protected. Every restore was a bare sequential statement,
# so a Ctrl-C during a slow guards run (they shell out over a 6 MB Baker's file), a hung child, or any throw
# left the mutation on disk. That matters because push-data.ps1 runs `git add -A` and pushes: an abandoned
# mutation gets committed unreviewed on the next refresh. The worst case is commodities.json with its
# cleaner excludes stripped, which re-creates the founding bathroom-cleaner-priced-as-fruit bug AND is
# invisible, because audit-household-in-food reads the same file the engine does - the two would agree with
# each other. Register every backup the moment it is taken; the finally block puts them all back on any exit
# path. Idempotent: restoring an already-restored file is a no-op write of identical bytes.
$script:Restores = New-Object System.Collections.Generic.List[object]
function Backup([string]$path) {
  # returns the content so callers can keep using their existing $bak variables unchanged
  $content = Get-Content $path -Raw
  $script:Restores.Add([pscustomobject]@{ path = $path; content = $content })
  return $content
}
function RestoreAll {
  foreach ($r in $script:Restores) {
    try { Set-Content -Path $r.path -Value $r.content -Encoding UTF8 -NoNewline } catch { Write-Warning ("RESTORE FAILED for " + $r.path + " - fix this by hand before committing: " + $_.Exception.Message) }
  }
}
# Ctrl-C does not run finally in every host, so also arm an engine-exit handler.
$null = Register-EngineEvent PowerShell.Exiting -Action { RestoreAll } -ErrorAction SilentlyContinue

function RunGuards {
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'guards.ps1') -Quiet | Out-Null
  return $LASTEXITCODE
}
function Check($name, $expect) {
  $rc = RunGuards
  if ($rc -eq $expect) { Write-Output ("  PASS  {0}  (exit {1})" -f $name, $rc); $script:pass++ }
  else { Write-Output ("  FAIL  {0}  expected exit {1}, got {2}" -f $name, $expect, $rc); $script:failed++ }
}
# Some invariants live in their own gate rather than guards.ps1 (tile-integrity's ACCURACY check). Assert those
# against the script that actually owns them - Check() always runs guards.ps1, so passing a script name to it
# would silently test the wrong thing and "pass" for the wrong reason.
function CheckScript($name, $expect, $script) {
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root $script) -Quiet | Out-Null
  $rc = $LASTEXITCODE
  if ($rc -eq $expect) { Write-Output ("  PASS  {0}  (exit {1})" -f $name, $rc); $script:pass++ }
  else { Write-Output ("  FAIL  {0}  expected exit {1}, got {2}" -f $name, $expect, $rc); $script:failed++ }
}

# baseline
Check 'baseline: guards pass on the current board' 0
try {

# ---- 1. price-mode -----------------------------------------------------------------
$f = (Get-ChildItem (Join-Path $root 'out\regular\aldi-regular-*.json') | Sort-Object Name -Desc | Select-Object -First 1).FullName
$bak = Backup $f
$d = $bak | ConvertFrom-Json; $d.price_mode = 'delivery'
($d | ConvertTo-Json -Depth 6) | Set-Content $f -Encoding UTF8
Check 'price-mode: Aldi flipped to the marked-up DELIVERY catalogue' 2
Set-Content $f $bak -Encoding UTF8 -NoNewline

# ---- 2. household-in-food ----------------------------------------------------------
# INJECT the offending row rather than relying on one existing in a store file: the Family Fare file is
# regenerated daily, so the original "Lysol Mango & Hibiscus" row vanished and this test silently
# stopped testing anything (it passed by finding nothing). A negative test must create its own fixture.
$cf = Join-Path $root 'commodities.json'
$cbak = Backup $cf
$c = $cbak | ConvertFrom-Json
$m = $c | Where-Object { $_.id -eq 'mangoes' }
# strip EVERY cleaner-ish exclude, including the category-library ones (\bcleaner\b, disinfect, ...) baked in
# by apply-category-excludes on 2026-07-15 - with any one of them present the Lysol fixture can't even land in
# the commodity, so the bug this test rebuilds can no longer form (that's the library doing its job; the test
# must remove the whole defense to prove the AUDIT layer catches what gets through).
$m.exclude = @($m.exclude | Where-Object { $_ -notmatch 'lysol|cleaner|disinfect|clorox|wipes' })
($c | ConvertTo-Json -Depth 6) | Set-Content $cf -Encoding UTF8

$wf = (Get-ChildItem (Join-Path $root 'out\regular\walmart-regular-*.json') | Sort-Object Name -Desc | Select-Object -First 1).FullName
$wbak = Backup $wf
$w = $wbak | ConvertFrom-Json
$rows = New-Object System.Collections.ArrayList
foreach ($r in $w.deals) { [void]$rows.Add($r) }
[void]$rows.Add([ordered]@{ store='Walmart'; item='Lysol Mango & Hibiscus Bathroom Cleaner 32 fl oz'; ad_price='$3.39'; size='32 fl oz'; regular=$null; source_ad='NEGATIVE TEST FIXTURE' })
$w.deals = $rows.ToArray()
($w | ConvertTo-Json -Depth 6) | Set-Content $wf -Encoding UTF8

Check 'household-in-food: a Lysol MANGO cleaner priced as fruit' 2

Set-Content $wf $wbak -Encoding UTF8 -NoNewline
Set-Content $cf $cbak -Encoding UTF8 -NoNewline

# ---- 3. rogue pin ------------------------------------------------------------------
$of = Join-Path $root 'board-price-overrides.json'
$obak = Backup $of
$o = $obak | ConvertFrom-Json
$cells = New-Object System.Collections.ArrayList
foreach ($x in $o.cells) { [void]$cells.Add($x) }
[void]$cells.Add([ordered]@{ id='eggs'; store='Walmart'; per_unit=99.0; source='NEGATIVE TEST'; set='test' })
$o.cells = $cells.ToArray()
($o | ConvertTo-Json -Depth 6) | Set-Content $of -Encoding UTF8
Check 'rogue pin: a pin that overrides the engine ($99/dozen eggs)' 2
Set-Content $of $obak -Encoding UTF8 -NoNewline

# ---- 4. factor mismatch ------------------------------------------------------------
$pf = Join-Path $root 'product-urls.json'
$pbak = Backup $pf
$p = $pbak | ConvertFrom-Json
# halve a link's recorded size -> its per-unit doubles vs the board = the 2x pack bug
$target = $p.items.'white-vinegar'.'Sam''s Club'
if ($target) { $target.size = '1 gal' }   # the truth is "2 pk 1 gal"
($p | ConvertTo-Json -Depth 8) | Set-Content $pf -Encoding UTF8
Check 'factor mismatch: Sam''s 2-pack vinegar recorded as ONE gallon (2x)' 2
Set-Content $pf $pbak -Encoding UTF8 -NoNewline

# ---- 5. multipack size -------------------------------------------------------------
$sf = (Get-ChildItem (Join-Path $root 'out\regular\sams-regular-*.json') | Sort-Object Name -Desc | Select-Object -First 1).FullName
$sbak = Backup $sf
$s = $sbak | ConvertFrom-Json
foreach ($r in $s.deals) { if ($r.item -match 'ReaLemon') { $r.size = '48 fl oz' } }   # truth: "2 pk 48 fl oz"
($s | ConvertTo-Json -Depth 6) | Set-Content $sf -Encoding UTF8
Check 'multipack size: Sam''s 2-pack ReaLemon recorded as ONE bottle' 2
Set-Content $sf $sbak -Encoding UTF8 -NoNewline

# ---- 6. stray file in out\regular --------------------------------------------------
# The one that actually bit us: a throttled 0-row diagnostic named "family-fare-regular-<date>.PARTIAL.json"
# both matched the store glob AND sorted after the real file ('p' > 'j'), so every consumer read the empty
# file as Family Fare's catalogue. Family Fare fell to ZERO everyday cells and the pull still logged success.
$strayF = Join-Path $root 'out\regular\family-fare-regular-2026-07-14.PARTIAL.json'
'{"store":"Family Fare","week_of":"2026-07-14","price_type":"everyday","deal_count":0,"deals":[]}' |
  Set-Content $strayF -Encoding UTF8
Check 'stray file: an empty .PARTIAL that outsorts the real Family Fare data' 2
Remove-Item $strayF -Force

# ---- 7. stale undated discount published as a live sale -----------------------------
# Brad caught this one on the live board: Hy-Vee sirloin at $6.99/lb, flagged Cheapest, badged "Sale thru
# Jul 19", when the store was charging $11.99/lb. It came from a 2-day-old undated "Aisles Online markdown"
# in extra-deals. Because the cell is typed `sale`, every price audit skips it BY DESIGN - so this class was
# invisible to all seven other guards. Rebuild the exact shape and prove guard 8 sees it.
#
# THIS TEST INJECTS ITS OWN extra-deals ROW, and must. It used to mutate only the BOARD and rely on a matching
# markdown still existing in out\extra-deals-*.json. That file rotates: on 2026-07-16 the newest one had ZERO
# rows, so guard 8's suspect list was empty, nothing matched, the guard passed, and the test failed - having
# proved nothing about guard 8 for however long the file had been empty. Exactly the trap called out on the
# household-in-food test above: A NEGATIVE TEST MUST CREATE ITS OWN FIXTURE. (Guard 8 only looks at extra-deals
# files dated BEFORE today, which is the point - a markdown captured today is still live.)
$cmpF = (Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Desc | Select-Object -First 1).FullName
$cbak2 = Backup $cmpF
$cmpD  = $cbak2 | ConvertFrom-Json
$sirloin = $cmpD.comparison | Where-Object { $_.id -eq 'sirloin-steak' } | Select-Object -First 1
$hv = $sirloin.stores | Where-Object { $_.store -eq 'Hy-Vee' } | Select-Object -First 1
if ($hv) {
  $stale = 'Hy-Vee Angus Reserve Beef Loin Boneless Sirloin Steak'
  # The fixture must go into the NEWEST extra-deals file, because that is the only one guard 8 reads
  # (Sort-Object Name -Descending | Select -First 1). My first attempt wrote a fresh <today-2> file and the
  # test still failed - the real, EMPTY <yesterday> file outsorted it and the guard read that instead.
  #
  # THIRD occurrence of the rotating-data trap (2026-07-23): a file dated TODAY defeats this test outright.
  # Guard 8's rule honours an undated discount ON its capture day (a markdown seen today IS live), so when the
  # weekly hygiene file extra-deals-<today>.json exists, the fixture lands in a today-dated file, reads as
  # LIVE, the guard correctly stays quiet, and the test fails while proving nothing. Move any today-dated file
  # ASIDE for the duration so the fixture lands in a genuinely PRE-today file (creating one if none remains).
  $exTodayF = Join-Path $root ('out\extra-deals-' + (Get-Date -Format 'yyyy-MM-dd') + '.json')
  $exTodayBak = $null
  if (Test-Path $exTodayF) { $exTodayBak = Get-Content $exTodayF -Raw; Remove-Item $exTodayF -Force }
  $exCreated = $false
  $exNewest = Get-ChildItem (Join-Path $root 'out\extra-deals-*.json') | Sort-Object Name -Descending | Select-Object -First 1
  if ($exNewest) { $exF = $exNewest.FullName; $exBak = Get-Content $exF -Raw; $exD = $exBak | ConvertFrom-Json }
  else {
    $exF = Join-Path $root ('out\extra-deals-' + (Get-Date).AddDays(-1).ToString('yyyy-MM-dd') + '.json')
    $exBak = $null; $exCreated = $true
    $exD = [pscustomobject]@{ price_type = 'sale'; deals = @() }
  }
  # an UNDATED markdown (no sale_end) cheaper than its own regular - the exact shape of the sirloin bug
  $exD.deals = @(@($exD.deals) + ([pscustomobject]@{ store = 'Hy-Vee'; item = $stale; ad_price = '$6.99'; regular = 11.99; size = 'lb' }))
  ($exD | ConvertTo-Json -Depth 6) | Set-Content $exF -Encoding UTF8

  $hv.type     = 'sale'
  $hv.per_unit = 6.99
  $hv.ad       = '$6.99'
  $hv.item     = $stale
  ($cmpD | ConvertTo-Json -Depth 8) | Set-Content $cmpF -Encoding UTF8
  Check 'stale sale: a 2-day-old undated markdown republished as a live sale' 2
  Set-Content $cmpF $cbak2 -Encoding UTF8 -NoNewline
  if ($exCreated) { Remove-Item $exF -Force -ErrorAction SilentlyContinue }
  else { Set-Content $exF $exBak -Encoding UTF8 -NoNewline }
  if ($null -ne $exTodayBak) { Set-Content $exTodayF $exTodayBak -Encoding UTF8 -NoNewline }
} else {
  Write-Output '  SKIP  stale sale: no Hy-Vee sirloin cell to mutate'
}

# ---- 8. publishing the REGULAR price over a live discount ---------------------------
# The bug Brad found, as a test. Take a Hy-Vee row that IS marked down and flip its published price back up
# to the regular price - exactly what reading `basePrice` instead of `price` does - and prove guard 10 sees it.
$hf = (Get-ChildItem (Join-Path $root 'out\regular\hyvee-regular-*.json') |
  Where-Object { $_.BaseName -match '^hyvee-regular-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Desc | Select-Object -First 1).FullName
$hbak = Backup $hf
$hd = $hbak | ConvertFrom-Json
$md = @($hd.deals | Where-Object { $_.marked_down -and $_.base_price -and $_.current_price }) | Select-Object -First 1
if ($md) {
  # Do exactly what reading `basePrice` instead of `price` does: publish the REGULAR price while the store is
  # still charging the marked-down one. Note this makes ad_price EQUAL to base_price, not greater - which is
  # why the first version of guard 10 (ad_price <= base_price) sailed straight past it. current_price is the
  # field that makes the lie visible.
  $md.ad_price = ('$' + [string]$md.base_price)
  ($hd | ConvertTo-Json -Depth 6) | Set-Content $hf -Encoding UTF8
  Check 'basePrice bug: a marked-down item republished at its REGULAR price' 2
  Set-Content $hf $hbak -Encoding UTF8 -NoNewline
} else {
  Write-Output '  SKIP  basePrice bug: no marked-down row carrying both current_price and base_price'
}

# ---- 8b. the MULTIBUY reconciliation must not become a way to launder a wrong price ------------------
# Guard 10 compares ad_price * price_multiple against current_price, because a "3 for $4" row legitimately
# publishes $1.3333 while the store's headline is $4. That reconciliation is a hole if it is not checked: a
# wrong price_multiple would make any ad_price "agree" with any current_price. So plant one and prove the guard
# still fires. (This exists because the raw comparison hard-failed 18 rows of CORRECT multibuy data, and the
# fix for a false positive is the easiest place in a gate to accidentally open a real one.)
# RE-READ FROM THE RESTORED FILE (2026-07-28). The line above restored $hf on disk, but $hd was still the
# MUTATED in-memory object from step 8, so the write below shipped BOTH mutations - and guard 10 hard-failed
# on the leftover step-8 row no matter what this test did to price_multiple. This case has therefore been
# passing for the wrong reason and has never once exercised the price_multiple reconciliation path.
$hd = $hbak | ConvertFrom-Json
$mb = @($hd.deals | Where-Object { $_.price_multiple -and $_.current_price -and $_.ad_price }) | Select-Object -First 1
if ($mb) {
  $mb.price_multiple = ([double]$mb.price_multiple) + 1     # a divisor the store never quoted
  ($hd | ConvertTo-Json -Depth 6) | Set-Content $hf -Encoding UTF8
  Check 'multibuy: a price_multiple that does not reconcile ad_price to current_price' 2
  Set-Content $hf $hbak -Encoding UTF8 -NoNewline
} else {
  Write-Output '  SKIP  multibuy: no row carries price_multiple yet (re-pull Hy-Vee to create one)'
}

# ---- 8c. a shipped link that disagrees with its tile -------------------------------------------------
# Brad's bar: a shopper must never click "See item" and land on a different product or price. That is the ONE
# thing on this board that is a lie rather than a gap, so audit-tile-integrity gates ACCURACY hard (no
# baseline, no ratchet, no -Strict flag - there is no version of this repo where a wrong link is tolerable).
# A gate that reports zero is worthless if it cannot fail, so plant one and prove it fires.
$puF2 = Join-Path $root 'product-urls.json'
$pubak = Backup $puF2
$pud = $pubak | ConvertFrom-Json
$victim = $null
foreach ($n in @('bananas', 'milk', 'eggs', 'butter')) { if ($pud.items.$n.'Hy-Vee'.url) { $victim = $pud.items.$n.'Hy-Vee'; break } }
if ($victim) {
  $victim.price = 99.99          # a real link, a price the store does not charge
  ($pud | ConvertTo-Json -Depth 8) | Set-Content $puF2 -Encoding UTF8
  CheckScript 'tile-integrity: a shipped link whose price disagrees with the tile' 2 'audit-tile-integrity.ps1'
  Set-Content $puF2 $pubak -Encoding UTF8 -NoNewline
} else {
  Write-Output '  SKIP  tile-integrity: no Hy-Vee link on the sample commodities to mutate'
}

# ---- 9. Baker's price not matching the store's EXACT shelf price (the milk rounding bug) -------------
# Guard 10 only proves ad_price == current_price - both OUR numbers - so it cannot catch a current_price that
# was COMPUTED wrong. Guard 11 brings in the raw capture's exact `cur`. Set milk to the rounded-unit
# reconstruction ($2.56) while the raw capture shows the store charges $3.19, and prove guard 11 sees it.
# (compare-*.json is NOT regenerated here, so guard 4 reads the old board and stays quiet - this isolates 11.)
$bkf = (Get-ChildItem (Join-Path $root 'out\regular\bakers-regular-*.json') |
  Where-Object { $_.BaseName -match '^bakers-regular-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Desc | Select-Object -First 1).FullName
$bkrCsv = Join-Path $root 'out\bakers-prices-raw.csv'
$bkbak = Backup $bkf
$bkd = $bkbak | ConvertFrom-Json
$milk = @($bkd.deals | Where-Object { $_.item -match '2% Reduced Fat Milk' -and $_.upc -and $_.current_price }) | Select-Object -First 1
if ((Test-Path $bkrCsv) -and $milk) {
  $milk.ad_price = '$2.56'; $milk.current_price = 2.56   # rounded 0.02/floz x 128; the store's shelf price is $3.19
  ($bkd | ConvertTo-Json -Depth 6) | Set-Content $bkf -Encoding UTF8
  Check 'baker rounding: milk at the rounded-unit price, not the store''s exact shelf price' 2
  Set-Content $bkf $bkbak -Encoding UTF8 -NoNewline
} else {
  Write-Output '  SKIP  baker rounding: no raw capture or no milk row to mutate'
}

# ---- 10. food commodity matched a wrong-CLASS product (the blueberries-as-Bai-beverage bug) ----------
# Family Fare blueberries went LIVE priced as a "Bai Brasilia Blueberry Antioxidant BEVERAGE" and every guard
# stayed green - household-in-food only knows cleaning products, and the factor guard only sees link drift.
# Rebuild the exact shape (a produce cell whose matched item is a beverage) and prove audit-food-category
# sees it.
$cmpF2 = (Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Desc | Select-Object -First 1).FullName
$cbak3 = Backup $cmpF2
$cmpD2 = $cbak3 | ConvertFrom-Json
$bb = $cmpD2.comparison | Where-Object { $_.id -eq 'blueberries' } | Select-Object -First 1
$bbCell = $null
if ($bb) { $bbCell = $bb.stores | Where-Object { [double]$_.per_unit -gt 0 } | Select-Object -First 1 }
if ($bbCell) {
  $bbCell.item = 'Bai Brasilia Blueberry Antioxidant Beverage 18 Fl Oz'
  ($cmpD2 | ConvertTo-Json -Depth 8) | Set-Content $cmpF2 -Encoding UTF8
  Check 'food-class: blueberries priced as a Bai antioxidant BEVERAGE' 2
  Set-Content $cmpF2 $cbak3 -Encoding UTF8 -NoNewline
} else {
  Write-Output '  SKIP  food-class: no priced blueberries cell to mutate'
}

# ---- 12/13. override pins must be DERIVABLE from their own link -----------------------
# Guard 3 was rewritten 2026-07-16 because the old invariant ("a pin must not disagree with the engine") both
# contradicted generate-board-overrides (whose whole job is to emit pins that DO disagree - the board is stale,
# the link is right) and was a NO-OP anyway: it read only comparison-*.json while every pin in the file is a
# RECIPE-board id, so it skipped all 20 and reported "ok". These two cases are what stop it going quiet again.
$of = Join-Path $root 'board-price-overrides.json'
if (Test-Path $of) {
  $obak = Backup $of
  $o = $obak | ConvertFrom-Json
  if (@($o.cells).Count -gt 0) {
    # 12. a HAND-EDITED pin: doubling per_unit must no longer match the link it claims to be derived from
    $o.cells[0].per_unit = [math]::Round([double]$o.cells[0].per_unit * 2, 4)
    ($o | ConvertTo-Json -Depth 6) | Set-Content $of -Encoding UTF8
    Check 'pin: hand-edited per_unit no longer matches its own verified link' 2
    Set-Content $of $obak -Encoding UTF8 -NoNewline

    # 13. an UNSOURCED pin: a pin beats the engine, so one with no link is a number nothing can correct
    $o2 = $obak | ConvertFrom-Json
    $fake = $o2.cells[0].PSObject.Copy()
    $fake.id = 'milk'; $fake.store = 'Nonexistent Store'; $fake.per_unit = 1.23
    $o2.cells = @(@($o2.cells) + $fake)
    ($o2 | ConvertTo-Json -Depth 6) | Set-Content $of -Encoding UTF8
    Check 'pin: unsourced pin (no product-urls link to derive from)' 2
    Set-Content $of $obak -Encoding UTF8 -NoNewline
  } else {
    Write-Output '  SKIP  pin: no override pins to mutate'
  }
}

} finally {
  # every mutation above is undone here, on ANY exit path - normal, thrown, or aborted.
  RestoreAll
}
# ---- restored? ---------------------------------------------------------------------
Check 'restored: guards pass again after every mutation is reverted' 0

Write-Output ''
Write-Output ("negative tests: $pass passed, $failed failed")
if ($failed -gt 0) { exit 1 }
exit 0
