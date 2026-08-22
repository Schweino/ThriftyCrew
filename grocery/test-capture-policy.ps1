<#
  test-capture-policy.ps1 - frozen fixtures for the sale-expiry re-price in capture-policy-lib.ps1.

  THE FOUNDING BUG (2026-08-22): Get-CapturePlan returned SaleExpiries and a TermBudget of rotation +
  expiries, and both headless lanes read the budget and ignored the list - the extra slot went to
  whatever sat at the rotation cursor, and the item whose sale had just ended waited its quarter.
  Brad's rule: "reprice whenever an ad price / sale price / rollback price / instant-savings price
  drops off." The MUST-FIRE below builds the slice the OLD way (cursor + budget) and shows the expiring
  term is absent; the fix (Select-ExpiryFirstSlice) puts it first.

  Synthetic policy root in TEMP: a 12-term commodity-search.json and a sale-windows.json with one
  window whose refresh_on is the day after it ends. Never reads the live policy files.

  Run: test-capture-policy.ps1        (exit 0 clean, 1 on any failure)
#>
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $root 'capture-policy-lib.ps1')
$fail = 0
function Ok($m) { Write-Output "ok    $m" }
function Bad($m) { Write-Output "FAIL  $m"; $script:fail++ }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('cappol-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $tmp 'out') -Force | Out-Null
try {
  # 12 commodities in a stable order; 'shredded-cheese' carries TWO terms (the array form)
  $terms = [ordered]@{}
  foreach ($c in @('apples','bacon','bananas','bread','butter','carrots','eggs','flour','milk','onions','rice')) { $terms[$c] = $c }
  $terms['shredded-cheese'] = @('shredded cheese', 'shredded cheddar')
  [IO.File]::WriteAllText((Join-Path $tmp 'commodity-search.json'), (@{ terms = $terms } | ConvertTo-Json -Depth 4))
  # one sale ending 2026-08-21 -> refresh_on 2026-08-22 (build-sale-windows: refresh_on = sale_end + 1)
  $sw = @{ windows = @(@{ store = 'Family Fare'; id = 'shredded-cheese'; sale_end = '2026-08-21'; refresh_on = '2026-08-22' },
                      @{ store = 'Hy-Vee';      id = 'butter';          sale_end = '2026-08-21'; refresh_on = '2026-08-22' }) }
  [IO.File]::WriteAllText((Join-Path $tmp 'sale-windows.json'), ($sw | ConvertTo-Json -Depth 4))
  $script:PolicyRoot = $tmp      # point the lib at the synthetic root (it reads every policy file from here)

  # 1. the plan lists the expiry on the day AFTER the window ends, and not the day before
  $p = Get-CapturePlan -Store 'Family Fare' -Today '2026-08-22'
  if (@($p.SaleExpiries) -contains 'shredded-cheese' -and $p.TermBudget -eq ($p.RotationTerms + 1)) { Ok "plan lists shredded-cheese as expiring on refresh_on (budget = rotation $($p.RotationTerms) + 1)" }
  else { Bad "plan did not list the expiry / budget wrong: $($p.SaleExpiries -join ',') budget=$($p.TermBudget)" }
  $p0 = Get-CapturePlan -Store 'Family Fare' -Today '2026-08-21'
  if (@($p0.SaleExpiries).Count -eq 0) { Ok 'the day the sale is still running lists no expiry' } else { Bad 'an expiry was listed while the sale was still live' }

  # 2. the worklist resolves the id to BOTH of its terms
  $wl = Get-CaptureWorklist -Store 'Family Fare' -Today '2026-08-22' -OutDir (Join-Path $tmp 'out')
  $st = @($wl.SaleTerms | ForEach-Object { $_.term })
  if (($st -contains 'shredded cheese') -and ($st -contains 'shredded cheddar')) { Ok 'worklist SaleTerms carries every term of the expiring commodity' } else { Bad "SaleTerms = $($st -join ',')" }

  # 3. MUST-FIRE: the OLD lane behaviour - a bigger budget taken from the cursor - does NOT reach the expiry.
  #    Cursor at 0, rotation 1 + 1 expiry = 2 terms: 'apples','bacon'. shredded-cheese sits at #11/#12.
  $all = @(Get-AllTerms)
  $old = @(); for ($k = 0; $k -lt $p.TermBudget; $k++) { $old += $all[$k % $all.Count].term }
  if ($old -notcontains 'shredded cheese' -and $old -notcontains 'shredded cheddar') { Ok "MUST-FIRE reproduced: budget-only slicing took [$($old -join ', ')] and never re-priced the expiring item" }
  else { Bad 'the founding bug did not reproduce - the fixture no longer tests anything' }

  # 4. THE FIX: expiring terms first, then the rotation from the cursor, inside the same budget.
  $sl = Select-ExpiryFirstSlice -Items $all -Expiring @($p.SaleExpiries) -KeyOf { param($t) $t.id } -Budget $p.TermBudget -CursorStart 0
  $got = @($sl.Items | ForEach-Object { $_.term })
  if ($got[0] -eq 'shredded cheese' -and $got[1] -eq 'shredded cheddar') { Ok "expiring commodity's terms are at the FRONT of the slice: [$($got -join ', ')]" }
  else { Bad "expiry not at the front: [$($got -join ', ')]" }
  if ($sl.Prepended -eq 2 -and $sl.Items.Count -eq $p.TermBudget -and $sl.CursorNext -eq ($p.TermBudget - 2)) { Ok "slice honours the budget ($($p.TermBudget)) and the cursor advances only by the rotation positions walked ($($sl.CursorNext))" }
  else { Bad "prepended=$($sl.Prepended) count=$($sl.Items.Count) cursorNext=$($sl.CursorNext)" }

  # 5. an expiring item that ALSO sits inside the rotation window is taken once, not twice
  $sl2 = Select-ExpiryFirstSlice -Items $all -Expiring @('apples') -KeyOf { param($t) $t.id } -Budget 3 -CursorStart 0
  $g2 = @($sl2.Items | ForEach-Object { $_.term })
  if ($g2.Count -eq 3 -and (@($g2 | Where-Object { $_ -eq 'apples' }).Count -eq 1) -and $g2[0] -eq 'apples') { Ok "an expiry inside the rotation window is not duplicated: [$($g2 -join ', ')]" } else { Bad "dup/miss: [$($g2 -join ', ')]" }

  # 6. unbudgeted (Family Fare's shape: the buy loop counts the budget) simply reorders - nothing is lost
  $sl3 = Select-ExpiryFirstSlice -Items $all -Expiring @('milk') -KeyOf { param($t) $t.id } -Budget 0 -CursorStart 5
  $g3 = @($sl3.Items | ForEach-Object { $_.term })
  if ($g3.Count -eq $all.Count -and $g3[0] -eq 'milk' -and $g3[1] -eq 'carrots') { Ok 'unbudgeted: expiry first, then the full rotation from the cursor, nothing dropped' } else { Bad "unbudgeted order: [$($g3 -join ', ')]" }

  # 7. no expiries -> exactly the rotation slice the lane always took (no behaviour change on a quiet day)
  $sl4 = Select-ExpiryFirstSlice -Items $all -Expiring @() -KeyOf { param($t) $t.id } -Budget 2 -CursorStart 10
  $g4 = @($sl4.Items | ForEach-Object { $_.term })
  if ($g4.Count -eq 2 -and $g4[0] -eq 'rice' -and $g4[1] -eq 'shredded cheese' -and $sl4.CursorNext -eq 12) { Ok 'no expiries: plain rotation slice (13 terms, cursor 10 -> #10,#11), cursor advances by the budget to 12' } else { Bad "quiet-day slice: [$($g4 -join ', ')] next=$($sl4.CursorNext)" }

  # 8. the Hy-Vee shape: products keyed by commodity id, an item with no id answers by name
  $prods = @([pscustomobject]@{ name='Hy-Vee Milk'; cid='milk' }, [pscustomobject]@{ name='Hy-Vee Butter'; cid='' }, [pscustomobject]@{ name='Hy-Vee Eggs'; cid='eggs' })
  $names = @{ 'hy-vee butter' = 'butter' }
  $hp = Get-CapturePlan -Store 'Hy-Vee' -Today '2026-08-22'
  $sl5 = Select-ExpiryFirstSlice -Items $prods -Expiring @($hp.SaleExpiries) -Budget 1 -CursorStart 0 -KeyOf { param($w) $ks = @(); if ($w.cid) { $ks += $w.cid }; $nk = $w.name.ToLower(); if ($names.ContainsKey($nk)) { $ks += $names[$nk] }; $ks }
  if ($sl5.Items.Count -eq 1 -and $sl5.Items[0].name -eq 'Hy-Vee Butter') { Ok 'Hy-Vee: a link-less product is found for its expiring commodity by name and takes the only slot' } else { Bad "Hy-Vee slice: $(@($sl5.Items | ForEach-Object { $_.name }) -join ', ')" }

  # 9. THE COUPLING IS WRITTEN DOWN where the list is consumed (build-sale-windows prunes the day after refresh_on)
  $libText = Get-Content (Join-Path $root 'capture-policy-lib.ps1') -Raw
  if ($libText -match 'build-sale-windows\.ps1[\s\S]{0,400}refresh_on' ) { Ok 'capture-policy-lib documents the build-sale-windows prune that bounds SaleExpiries' } else { Bad 'the prune coupling is not documented beside its consumer' }

  # =========================================================================
  # THE 2026-08-23 DEFECT: AN EXPIRY BACKLOG THAT BREACHES ITS OWN BUDGET
  #
  # Select-ExpiryFirstSlice added EVERY expiring item in a first loop with no budget test -
  # only the rotation loop afterwards checked $Budget - so the slice was (all expiries) +
  # (rotation up to budget) and taken.Count could exceed the budget outright. On 2026-08-22
  # the live sale-windows.json held 130 entries with refresh_on 2026-08-23 (Fareway 111,
  # Family Fare 19) and 104 more on 08-24 (Hy-Vee). Family Fare's Freshop search answers
  # HTTP 400 / {"error_code":429} past roughly 40 calls in a window, so that morning's run
  # would have asked for ~19x its normal day and throttled the whole store.
  #
  # And the half that makes capping SAFE: build-sale-windows.ps1 used to prune a window the
  # day after refresh_on, by date alone, so every expiry the cap deferred was deleted
  # unprocessed and its SALE price kept publishing for up to a quarter. The prune is now
  # driven by repriced_for, written only after a landed capture.
  # =========================================================================

  # 10. MUST-FIRE: 130 expiries, budget 7 -> the slice must be 7, not 130.
  $many = @(); for ($i = 1; $i -le 130; $i++) { $many += [pscustomobject]@{ id = ('c{0:000}' -f $i); term = ('t{0:000}' -f $i) } }
  $manyIds = @($many | ForEach-Object { $_.id })
  $slBig = Select-ExpiryFirstSlice -Items $many -Expiring $manyIds -KeyOf { param($t) $t.id } -Budget 7 -CursorStart 0
  if (@($slBig.Items).Count -eq 7) { Ok '130 expiries with a budget of 7 yield a 7-item slice (the cap applies to the expiries too)' }
  else { Bad ("the expiry loop breached its own budget: " + @($slBig.Items).Count + " items for a budget of 7 - this is the 2026-08-23 throttle") }
  if ([int]$slBig.ExpiryDropped -eq 123) { Ok '123 expiries are reported as deferred, not silently swallowed' } else { Bad ("ExpiryDropped = $($slBig.ExpiryDropped), expected 123") }

  # 11. OLDEST OWED FIRST. The cap must take the longest-owed re-price, whatever its id sorts
  #     like, or a backlog starves from the back for the rest of the quarter.
  $swOld = @{ windows = @(
      @{ store = 'Family Fare'; id = 'zzz-oldest'; sale_end = '2026-08-09'; refresh_on = '2026-08-10' },
      @{ store = 'Family Fare'; id = 'aaa-middle'; sale_end = '2026-08-19'; refresh_on = '2026-08-20' },
      @{ store = 'Family Fare'; id = 'mmm-newest'; sale_end = '2026-08-21'; refresh_on = '2026-08-22' }) }
  [IO.File]::WriteAllText((Join-Path $tmp 'sale-windows.json'), ($swOld | ConvertTo-Json -Depth 4))
  $capSave = $script:StoreCallCap['Family Fare']
  $script:StoreCallCap['Family Fare'] = @{ cap = 2; basis = 'fixture'; unit = 'search terms' }  # rotation 1 + 1 expiry
  $pOld = Get-CapturePlan -Store 'Family Fare' -Today '2026-08-22'
  if (@($pOld.SaleExpiries).Count -eq 1 -and @($pOld.SaleExpiries)[0] -eq 'zzz-oldest') { Ok 'oldest-first: the one slot goes to the expiry owed since 2026-08-10, not to the alphabetical or newest one' }
  else { Bad ("oldest-first broken: took [" + (@($pOld.SaleExpiries) -join ', ') + "]") }
  if ($pOld.ExpiryDeferred -eq 2 -and $pOld.ExpiryOldest -eq '2026-08-10' -and @($pOld.ExpiryPending).Count -eq 3) { Ok "the 2 deferred expiries are still reported as OWED (backlog 3, oldest $($pOld.ExpiryOldest))" }
  else { Bad "backlog not reported: deferred=$($pOld.ExpiryDeferred) oldest=$($pOld.ExpiryOldest) pending=$(@($pOld.ExpiryPending).Count)" }

  # 12. THE WHOLE SLICE respects the cap: expiries first, rotation fills the rest, total = cap.
  $script:StoreCallCap['Family Fare'] = @{ cap = 7; basis = 'fixture'; unit = 'search terms' }
  [IO.File]::WriteAllText((Join-Path $tmp 'sale-windows.json'), (@{ windows = @($many | ForEach-Object { @{ store = 'Family Fare'; id = $_.id; sale_end = '2026-08-21'; refresh_on = '2026-08-22' } }) } | ConvertTo-Json -Depth 4))
  $pCap = Get-CapturePlan -Store 'Family Fare' -Today '2026-08-22'
  if ($pCap.TermBudget -eq 7 -and @($pCap.SaleExpiries).Count -eq 6 -and $pCap.RotationTerms -eq 1 -and $pCap.ExpiryDeferred -eq 124) {
    Ok 'a 130-deep backlog against a cap of 7 plans 6 expiries + 1 rotation = 7 (the rotation drip is never fully starved)'
  } else { Bad "capped plan wrong: budget=$($pCap.TermBudget) expiries=$(@($pCap.SaleExpiries).Count) rotation=$($pCap.RotationTerms) deferred=$($pCap.ExpiryDeferred)" }

  # 13. A QUIET DAY IS UNCHANGED. Two expiries under a cap of 40 must still plan rotation + 2,
  #     exactly the number the old uncapped formula produced.
  $script:StoreCallCap['Family Fare'] = @{ cap = 40; basis = 'fixture'; unit = 'search terms' }
  [IO.File]::WriteAllText((Join-Path $tmp 'sale-windows.json'), (@{ windows = @(
      @{ store = 'Family Fare'; id = 'shredded-cheese'; sale_end = '2026-08-21'; refresh_on = '2026-08-22' },
      @{ store = 'Family Fare'; id = 'butter';          sale_end = '2026-08-21'; refresh_on = '2026-08-22' }) } | ConvertTo-Json -Depth 4))
  $pQuiet = Get-CapturePlan -Store 'Family Fare' -Today '2026-08-22'
  if ($pQuiet.TermBudget -eq ($pQuiet.RotationTerms + 2) -and $pQuiet.ExpiryDeferred -eq 0 -and (@($pQuiet.SaleExpiries) -contains 'butter') -and (@($pQuiet.SaleExpiries) -contains 'shredded-cheese')) {
    Ok "few expiries under the cap: behaviour unchanged (budget $($pQuiet.TermBudget) = rotation $($pQuiet.RotationTerms) + 2, nothing deferred)"
  } else { Bad "quiet day changed: budget=$($pQuiet.TermBudget) rotation=$($pQuiet.RotationTerms) deferred=$($pQuiet.ExpiryDeferred) [$(@($pQuiet.SaleExpiries) -join ', ')]" }

  # 14. A RUN THAT FETCHED NOTHING LOSES NOTHING. No everyday file on disk -> Test-CaptureLanded
  #     is false -> nothing is marked processed -> the expiries are still owed tomorrow.
  [IO.File]::WriteAllText((Join-Path $tmp 'stores.json'), (@{ stores = @(@{ name = 'Family Fare'; regular_prefix = 'family-fare' }) } | ConvertTo-Json -Depth 4))
  $outT = Join-Path $tmp 'out'
  $mkNone = Set-SaleExpiryProcessed -Store 'Family Fare' -Today '2026-08-22' -OutDir $outT -AllowReplay
  if ($mkNone.Marked -eq 0) { Ok "a run with no landed rows marked nothing ($($mkNone.Reason))" } else { Bad "a blind run retired $($mkNone.Marked) re-price(s)" }
  $pNext = Get-CapturePlan -Store 'Family Fare' -Today '2026-08-23'
  if (@($pNext.SaleExpiries).Count -eq 2) { Ok 'both expiries are still owed the next day after a blind run' } else { Bad "expiries lost after a blind run: [$(@($pNext.SaleExpiries) -join ', ')]" }

  # 15. A LANDED run records exactly what it was asked for, and only that.
  New-Item -ItemType Directory -Path (Join-Path $outT 'regular') -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $outT 'regular\family-fare-regular-2026-08-22.json'), (@{ deals = @(@{ item = 'x'; regular = 1.0 }) } | ConvertTo-Json -Depth 4))
  $mkSome = Set-SaleExpiryProcessed -Store 'Family Fare' -Today '2026-08-22' -OutDir $outT -AllowReplay
  if ($mkSome.Marked -eq 2) { Ok 'a landed run recorded both re-prices (repriced_for = the refresh_on it satisfied)' } else { Bad "landed run marked $($mkSome.Marked), expected 2 - $($mkSome.Reason)" }
  $pAfter = Get-CapturePlan -Store 'Family Fare' -Today '2026-08-23'
  if (@($pAfter.SaleExpiries).Count -eq 0) { Ok 'a recorded re-price is no longer owed' } else { Bad "recorded re-prices came back: [$(@($pAfter.SaleExpiries) -join ', ')]" }
  $script:StoreCallCap['Family Fare'] = $capSave

  # 16. THE PRUNE ITSELF. build-sale-windows must keep an UNPROCESSED expiry the day after its
  #     refresh_on and drop only the processed one. This is the dangerous half: capping the
  #     slice while the builder still pruned by date would have deleted 124 owed re-prices on
  #     2026-08-24 and left their sale prices publishing until each item's next quarterly slot.
  $bw = Join-Path $tmp 'bw'; New-Item -ItemType Directory -Path $bw -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $bw 'sched.json'), (@{ stores = @(@{ store = 'Family Fare'; current = @{ from = '2026-08-17'; to = '2026-08-23' } }) } | ConvertTo-Json -Depth 4))
  [IO.File]::WriteAllText((Join-Path $bw 'cmp.json'), (@{ comparison = @() } | ConvertTo-Json -Depth 4))
  $swFile = Join-Path $bw 'sale-windows.json'
  [IO.File]::WriteAllText($swFile, (@{ windows = @(
      @{ id = 'owed-item'; commodity = 'Owed'; store = 'Family Fare'; refresh_on = '2026-08-23'; sale_start = '2026-08-17'; sale_end = '2026-08-22'; status = 'active'; repriced_on = ''; repriced_for = '' },
      @{ id = 'done-item'; commodity = 'Done'; store = 'Family Fare'; refresh_on = '2026-08-23'; sale_start = '2026-08-17'; sale_end = '2026-08-22'; status = 'active'; repriced_on = '2026-08-23'; repriced_for = '2026-08-23' }) } | ConvertTo-Json -Depth 5))
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'build-sale-windows.ps1') `
      -AsOf '2026-08-24' -LogFile $swFile -ComparisonFile (Join-Path $bw 'cmp.json') `
      -ScheduleFile (Join-Path $bw 'sched.json') -OutDir $bw | Out-Null
  $after = ConvertFrom-Json ([IO.File]::ReadAllText($swFile))
  $ids = @($after.windows | ForEach-Object { [string]$_.id })
  if ($ids -contains 'owed-item') { Ok 'the day AFTER refresh_on, an unprocessed expiry survives the rebuild instead of being pruned by date' }
  else { Bad 'THE DANGEROUS HALF: an unprocessed expiry was pruned the day after refresh_on - its sale price now publishes until the next quarterly rotation' }
  if ($ids -notcontains 'done-item') { Ok 'a recorded re-price IS pruned once its refresh_on is past (the ledger still drains)' }
  else { Bad 'a processed window was kept - the ledger would grow without bound' }
  $owed = @($after.windows | Where-Object { [string]$_.id -eq 'owed-item' })
  if (@($owed).Count -eq 1 -and [string]$owed[0].status -eq 'reprice-owed') { Ok "the surviving entry is labelled 'reprice-owed' so a stale sale price is visible, not silent" }
  else { Bad ("survivor status = '" + (@($owed | ForEach-Object { $_.status }) -join ',') + "', expected reprice-owed") }
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

Write-Output ("CAPTURE-POLICY " + $(if ($fail) { "FAILED ($fail)" } else { 'PASSED' }))
exit $(if ($fail) { 1 } else { 0 })
