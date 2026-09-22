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

  # 4b. THE CONFIRMED PULL-DROP VICTIMS (2026-09-07, queue 2026-09-07-72756b) -----------------------
  #     audit-ff-carry's alert said confirmed victims 'lead the next window's slice automatically'.
  #     Nothing read out\ff-carry-report.json, so they led nothing: the two found on 2026-09-07 were
  #     due in 33 and 58 windows of a 90-day rotation. These are the two REAL victims from that report,
  #     frozen - jarred-gravy via 'turkey gravy jar' (term index 383 of 602) and 15-bean-soup-mix via
  #     '15 bean soup mix' (index 552).
  $vNow = [datetime]'2026-09-07T09:00:00'
  $vRep = [pscustomobject]@{ generated = '2026-09-07T08:08:44'; empty_terms = 40
    confirmed_victims = @(
      [pscustomobject]@{ commodity = 'jarred-gravy';     product = 'Heinz Home Style Turkey Gravy, 12 Oz Jar'; term = 'turkey gravy jar' },
      [pscustomobject]@{ commodity = '15-bean-soup-mix'; product = "Hurst's Hambeens 15 Bean Soup Mix 20 Oz"; term = '15 bean soup mix' }) }
  $vFresh = Get-FfVictimTerms -Report $vRep -MaxAgeHours 48 -Now $vNow
  if (@($vFresh.terms).Count -eq 2 -and $vFresh.terms[0] -eq 'turkey gravy jar' -and $vFresh.terms[1] -eq '15 bean soup mix') {
    Ok "MUST-FIRE: a fresh carry report promotes both confirmed victims, in the order reported [$($vFresh.terms -join ', ')]"
  } else { Bad "victims not promoted from a fresh report: [$(@($vFresh.terms) -join ', ')] ($($vFresh.reason))" }
  #     ...and they must reach the FRONT of a real slice through the same helper the expiries use.
  $vAll = @(@([pscustomobject]@{ term = 'apples'; id = 'apples' }, [pscustomobject]@{ term = 'bacon'; id = 'bacon' }) +
            @([pscustomobject]@{ term = 'turkey gravy jar'; id = 'jarred-gravy' }, [pscustomobject]@{ term = '15 bean soup mix'; id = '15-bean-soup-mix' }))
  $vSl = Select-ExpiryFirstSlice -Items $vAll -Expiring @($vFresh.terms) -KeyOf { param($t) @($t.term) } -Budget 0 -CursorStart 0
  $vGot = @($vSl.Items | ForEach-Object { $_.term })
  if ($vSl.Prepended -eq 2 -and $vGot[0] -eq 'turkey gravy jar' -and $vGot[1] -eq '15 bean soup mix' -and $vGot.Count -eq $vAll.Count) {
    Ok "MUST-FIRE: both victim terms lead the slice and nothing is dropped: [$($vGot -join ', ')]"
  } else { Bad "victims did not lead the slice: prepended=$($vSl.Prepended) [$($vGot -join ', ')]" }
  #     CLEAN TWIN: a report from 72 h ago changes nothing. Once a victim is captured the next report
  #     drops it; if the audit STOPS running the file freezes, and a frozen report must not pin the
  #     front of every future slice forever.
  $vStale = Get-FfVictimTerms -Report $vRep -MaxAgeHours 48 -Now ([datetime]'2026-09-10T09:00:00')
  if (@($vStale.terms).Count -eq 0 -and $vStale.reason -match 'stale') { Ok "CLEAN-TWIN: a 72 h old carry report promotes nothing ($($vStale.reason))" }
  else { Bad "a stale report still promoted [$(@($vStale.terms) -join ', ')]" }
  #     CLEAN TWIN: an EMPTY victims array changes nothing - and must count 0, not the PS 5.1 @($null) 1.
  $vEmpty = Get-FfVictimTerms -Report ([pscustomobject]@{ generated = '2026-09-07T08:08:44'; confirmed_victims = @() }) -MaxAgeHours 48 -Now $vNow
  if (@($vEmpty.terms).Count -eq 0) { Ok 'CLEAN-TWIN: an empty confirmed_victims array promotes nothing (and does not count 1)' }
  else { Bad "an empty victims array promoted [$(@($vEmpty.terms) -join ', ')]" }
  #     MUST-FIRE: an UNDATED report is refused. An age that cannot be read is not an age of zero.
  $vNoStamp = Get-FfVictimTerms -Report ([pscustomobject]@{ confirmed_victims = @([pscustomobject]@{ term = 'turkey gravy jar' }) }) -MaxAgeHours 48 -Now $vNow
  if (@($vNoStamp.terms).Count -eq 0 -and $vNoStamp.reason -match 'generated') { Ok 'MUST-FIRE: a report with no readable generated stamp promotes nothing - blind is not fresh' }
  else { Bad "an undated report promoted [$(@($vNoStamp.terms) -join ', ')] ($($vNoStamp.reason))" }
  #     MUST-FIRE: the promise is gone from the alert text. The sentence that reassured a reader about a
  #     mechanism that did not exist is the other half of this defect.
  $ffcAlertSrc = Get-Content (Join-Path $root 'audit-ff-carry.ps1') -Raw
  if ($ffcAlertSrc -notmatch "lead the next window's slice automatically") { Ok 'MUST-FIRE: audit-ff-carry no longer claims victims lead the slice automatically' }
  else { Bad 'audit-ff-carry still promises a consumer in its alert text' }
  if ($ffcAlertSrc -match 'read from out') { Ok 'the alert now describes the consumer that actually exists' }
  else { Bad 'the alert text does not name the real mechanism' }
  #     ...and the PULLER really calls it. A pure function nothing invokes is the write-only report again.
  $ffPullSrc = Get-Content (Join-Path $root 'pull-regular-familyfare.ps1') -Raw
  if ($ffPullSrc -match 'Get-FfVictimTerms') { Ok 'pull-regular-familyfare READS the carry report - the consumer the alert promised now exists' }
  else { Bad 'nothing in the Family Fare puller calls Get-FfVictimTerms - the report is write-only again' }
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

  # 9. THE HY-VEE PRODUCT CURSOR ADVANCES ON WHAT THE RUN *ASKED*, not on what it managed to write.
  #    THE DEADLOCK (live 2026-08-20 -> 2026-08-22): the budget collapsed the everyday file, the
  #    THROTTLE-WIPEOUT guard quarantined it and exited 2 before the cursor commit, so the cursor was
  #    never created; every run re-took products 0-6, all seven of which carry no product link, and the
  #    lane reported "0 refreshed, 7 not re-verified" every day while the prices sat frozen.
  if ((Test-HyVeeCursorAdvance -Attempted 0 -Answered 0 -SliceSize 7 -SliceUnaskable 7).Advance) {
    Ok 'a slice with nothing to ask advances past itself rather than re-picking the same products forever'
  } else { Bad 'the 7-unlinked-products deadlock is still a deadlock' }
  if ((Test-HyVeeCursorAdvance -Attempted 18 -Answered 4 -SliceSize 18 -SliceUnaskable 14).Advance) {
    Ok 'a run the store answered advances, whatever happens to the write afterwards'
  } else { Bad 'a run that asked and was answered did not earn its advance' }
  if (-not (Test-HyVeeCursorAdvance -Attempted 18 -Answered 0 -SliceSize 18 -SliceUnaskable 0).Advance) {
    Ok 'a dead or throttled endpoint does NOT burn the slice (the Family Fare lesson of 2026-08-20)'
  } else { Bad 'a slice was burned by a run that fetched nothing - the cursor ran ahead of the capture' }
  if (-not (Test-HyVeeCursorAdvance -Attempted 0 -Answered 0 -SliceSize 18 -SliceUnaskable 2).Advance) {
    Ok 'an askable slice we never got to (wall-clock cap) is still owed its turn'
  } else { Bad 'the cursor skipped products that were never asked about' }
  # The term cursor still refuses Hy-Vee outright: two cursors, two namespaces, one set of rules.
  $hvTerm = Step-CaptureCursor -Store 'Hy-Vee' -Today '2026-08-22' -OutDir (Join-Path $tmp 'out')
  if (-not $hvTerm.Advanced -and $hvTerm.Reason -match 'product id') { Ok 'Hy-Vee still gets no TERM cursor - it rotates by product id and has its own file' }
  else { Bad "the term cursor accepted Hy-Vee: $($hvTerm.Reason)" }

  # 10. THE COUPLING IS WRITTEN DOWN where the list is consumed (build-sale-windows prunes the day after refresh_on)
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
  # ---- A STANDING RULING'S OWED TERMS LEAD THE WALMART WORKLIST (2026-09-12) ----------------------
  # THE FOUNDING BUG: Brad's 2026-08-28 store-drift ruling named 23 terms priced at the wrong store and
  # said to put them at the head of the first clean Walmart worklist. Nothing carried that anywhere -
  # the list lived in a JSON file and in the 09:00 runbook - so a fortnight later 15 were still owed
  # and the only thing standing between them and being forgotten was whoever read those two documents.
  # Get-WalmartRulingOwed derives what is still owed, and Get-CaptureWorklist leads with it.
  # The cases that matter most are the two NEGATIVES: a file that cannot name its store must discharge
  # nothing, and an attestation dated after the capture format learned to speak must not be accepted.
  $wmOut = Join-Path $tmp 'out'
  $wmRule = Join-Path $wmOut 'walmart-store-ruling-2026-08-28.json'
  $wmReg = Join-Path $wmOut 'regular'
  $wmTerms = @('bacon', 'bread', 'butter', 'rice')
  [IO.File]::WriteAllText($wmRule, (@{ ruled = '2026-08-28'; terms_to_recapture_first = $wmTerms } | ConvertTo-Json -Depth 4))
  [IO.File]::WriteAllText((Join-Path $tmp 'stores.json'), (@{ stores = @(
      @{ name = 'Walmart'; store_identity = @{ store_id = 5361; postal_code = '68137'; label = 'Omaha L St Supercenter' } }) } | ConvertTo-Json -Depth 5))
  function WmRegular([string]$date, [string]$source, [string[]]$terms) {
    if (-not (Test-Path $script:wmReg)) { New-Item -ItemType Directory -Path $script:wmReg -Force | Out-Null }
    $deals = @($terms | ForEach-Object { @{ item = 'Thing'; found_by_term = $_ } })
    [IO.File]::WriteAllText((Join-Path $script:wmReg ("walmart-regular-$date.json")),
      (@{ store = 'Walmart'; week_of = $date; source = $source; deals = $deals } | ConvertTo-Json -Depth 5))
  }
  $wmProven = 'walmart.com in-page __NEXT_DATA__ priceDetails.priceLines (storeId 5361 Omaha L St Supercenter 68137, read from the capture); built by build-walmart-deals.ps1'
  $wmWaived = 'walmart.com in-page __NEXT_DATA__ priceDetails.priceLines (store NOT RECORDED in the capture - it predates the #tc-store line, built under -WaiveMissingStoreLine); built by build-walmart-deals.ps1'

  # A. BLIND is not a discharge. With no out\regular to read, nothing can be proven recaptured, and the
  #    honest answer is "all of them, and here is why I cannot tell" - never "none owed".
  #    IN ITS OWN EMPTY OUT DIRECTORY, because the cases above this one have already created a
  #    regular\ in the shared root - the first version of this case read blind=False for that reason,
  #    which is a fixture that could not fire rather than a bug in the code it was aimed at.
  $wmBlindOut = Join-Path $tmp 'blind-out'
  New-Item -ItemType Directory -Path $wmBlindOut -Force | Out-Null
  Copy-Item -LiteralPath $wmRule -Destination (Join-Path $wmBlindOut 'walmart-store-ruling-2026-08-28.json')
  $rA = Get-WalmartRulingOwed -OutDir $wmBlindOut
  if ($rA.Blind -and @($rA.Owed).Count -eq 4 -and $rA.Why -match 'already been recaptured') {
    Ok 'a checkout with no built files says BLIND and reports every ruling term as owed, rather than discharging them'
  } else { Bad ("blind case: blind=$($rA.Blind) owed=$(@($rA.Owed).Count) why=[$($rA.Why)]") }

  # B. MUST FIRE - the ruling's terms LEAD the Walmart worklist, ahead of the rotation.
  New-Item -ItemType Directory -Path $wmReg -Force | Out-Null
  $rB = Get-WalmartRulingOwed -OutDir $wmOut
  $wlB = Get-CaptureWorklist -Store 'Walmart' -Today '2026-09-13' -OutDir $wmOut
  $tB = @($wlB.Terms | ForEach-Object { $_.term })
  if (-not $rB.Blind -and $rB.Sanctioned -eq '5361' -and @($tB).Count -ge 4 -and (@($tB[0..3]) -join ',') -eq ($wmTerms -join ',')) {
    Ok "MUST FIRE  the ruling's owed terms lead the Walmart worklist: [$(@($tB) -join ', ')]"
  } else { Bad ("ruling terms did not lead the worklist: blind=$($rB.Blind) sanctioned=$($rB.Sanctioned) terms=[$(@($tB) -join ', ')]") }

  # C. A file that NAMES the sanctioned store discharges exactly the terms it carries.
  WmRegular '2026-09-01' $wmProven @('bacon')
  $rC = Get-WalmartRulingOwed -OutDir $wmOut
  if (@($rC.Proven) -contains 'bacon' -and @($rC.Owed).Count -eq 3 -and @($rC.Owed) -notcontains 'bacon') {
    Ok 'a built file that names the sanctioned store discharges its terms, with no hand edit anywhere'
  } else { Bad ("proven=[$(@($rC.Proven) -join ',')] owed=[$(@($rC.Owed) -join ',')]") }

  # D. MUST NOT FIRE - and this is the case the whole design turns on. A file built under
  #    -WaiveMissingStoreLine SAYS the store was not recorded, so it proves nothing about the basis of
  #    its rows however carefully somebody checked the store by hand. If this ever discharges a term,
  #    the ruling closes itself on evidence that does not exist.
  WmRegular '2026-09-02' $wmWaived @('bread')
  $rD = Get-WalmartRulingOwed -OutDir $wmOut
  if (@($rD.Owed) -contains 'bread' -and @($rD.Proven) -notcontains 'bread') {
    Ok 'MUST NOT FIRE  a file whose stamp says the store was NOT RECORDED discharges nothing'
  } else { Bad ("a store-less file discharged a term: proven=[$(@($rD.Proven) -join ',')] owed=[$(@($rD.Owed) -join ',')]") }

  # E. MUST NOT FIRE - a capture from BEFORE the ruling cannot discharge it. Those are the very rows
  #    the ruling exists to replace.
  WmRegular '2026-08-01' $wmProven @('butter')
  $rE = Get-WalmartRulingOwed -OutDir $wmOut
  if (@($rE.Owed) -contains 'butter') { Ok 'MUST NOT FIRE  a file built before the ruling was made does not discharge it' }
  else { Bad ("a pre-ruling file discharged a term: owed=[$(@($rE.Owed) -join ',')]") }

  # F. THE ATTESTATION IS CLOSED BY CONSTRUCTION. A hand attestation is accepted only for a capture
  #    taken on or before the day the format learned to name its store; a later one is not, because
  #    from that day a capture proves its own store and trust is no longer needed.
  [IO.File]::WriteAllText($wmRule, (@{ ruled = '2026-08-28'; terms_to_recapture_first = $wmTerms
      recaptured_at_l_st = [ordered]@{ '2026-09-12' = @('butter'); '2026-09-20' = @('rice'); note = 'prose, not a date' } } | ConvertTo-Json -Depth 5))
  $rF = Get-WalmartRulingOwed -OutDir $wmOut
  if (@($rF.Attested) -contains 'butter' -and @($rF.Owed) -notcontains 'butter' -and @($rF.Owed) -contains 'rice') {
    Ok 'an attestation from before the store line is accepted; one dated after it is NOT, and a prose key is not a date'
  } else { Bad ("attested=[$(@($rF.Attested) -join ',')] owed=[$(@($rF.Owed) -join ',')]") }

  # G. THE ROTATION KEEPS ITS DRIP, AND THE CAP HOLDS. The ruling's terms come out of the allowance the
  #    expiries get (cap minus rotation), never out of the rotation - advancing the cursor over terms a
  #    prepend displaced is the starvation bug Select-ExpiryFirstSlice's own header describes.
  #    THE CAP IS DERIVED FROM WHAT IS ACTUALLY OWED HERE, not from a number typed in: the cases above
  #    discharge terms, so a hard-coded "3 owed" read deferred=0 and failed for the fixture's own
  #    arithmetic rather than for anything in the code. Set the cap to rotation + (owed - 1) and
  #    exactly one owed term must be left for tomorrow.
  $wmCapWas = $script:StoreCallCap['Walmart'].cap
  try {
    $rG = Get-WalmartRulingOwed -OutDir $wmOut
    $owedG = @($rG.Owed).Count
    if ($owedG -lt 2) { Bad "the cap case needs at least 2 owed terms to have one deferred; it has $owedG" }
    else {
      $capG = 1 + ($owedG - 1)                     # rotation is 1 over a 12-term catalogue
      $script:StoreCallCap['Walmart'].cap = $capG
      $wlG = Get-CaptureWorklist -Store 'Walmart' -Today '2026-09-13' -OutDir $wmOut
      $tG = @($wlG.Terms | ForEach-Object { $_.term })
      if (@($tG).Count -le $capG -and @($wlG.RulingTerms).Count -eq ($owedG - 1) -and $wlG.RulingDeferred -eq 1 -and
          @($wlG.RotationTerms).Count -eq 1 -and $wlG.CursorNext -eq (($wlG.CursorStart + 1) % $wlG.TotalTerms)) {
        Ok "the cap holds over the whole slice (took $(@($tG).Count) of cap $capG with $owedG owed, 1 deferred) and the rotation keeps its full drip, so the cursor cannot advance over a term nobody asked for"
      } else { Bad ("cap/drip: cap=$capG owed=$owedG terms=$(@($tG).Count) ruling=$(@($wlG.RulingTerms).Count) deferred=$($wlG.RulingDeferred) rotation=$(@($wlG.RotationTerms).Count) cursor $($wlG.CursorStart)->$($wlG.CursorNext)") }
    }
  } finally { $script:StoreCallCap['Walmart'].cap = $wmCapWas }

  # H. MUST NOT FIRE - no other store is touched by a Walmart ruling.
  $wlH = Get-CaptureWorklist -Store 'Family Fare' -Today '2026-08-22' -OutDir $wmOut
  if (@($wlH.RulingTerms).Count -eq 0 -and $wlH.RulingTotal -eq 0) { Ok 'MUST NOT FIRE  a Walmart ruling prepends nothing to another store''s worklist' }
  else { Bad ("Family Fare picked up ruling terms: $(@($wlH.RulingTerms | ForEach-Object { $_.term }) -join ',')") }

  # I. AND IT GOES QUIET. A discharged ruling - every term proven - prepends nothing, and so does a
  #    checkout with no ruling file at all. This is what makes it a mechanism rather than a permanent
  #    23-term tax on the worklist.
  WmRegular '2026-09-03' $wmProven $wmTerms
  $rI = Get-WalmartRulingOwed -OutDir $wmOut
  $wlI = Get-CaptureWorklist -Store 'Walmart' -Today '2026-09-13' -OutDir $wmOut
  if (@($rI.Owed).Count -eq 0 -and @($wlI.RulingTerms).Count -eq 0 -and @($wlI.Terms).Count -eq @($wlI.RotationTerms).Count) {
    Ok 'a fully discharged ruling prepends nothing - the worklist is exactly the rotation again'
  } else { Bad ("a discharged ruling still prepends: owed=[$(@($rI.Owed) -join ',')] ruling=$(@($wlI.RulingTerms).Count)") }
  Remove-Item -LiteralPath $wmRule -Force
  $rJ = Get-WalmartRulingOwed -OutDir $wmOut
  $wlJ = Get-CaptureWorklist -Store 'Walmart' -Today '2026-09-13' -OutDir $wmOut
  if (-not $rJ.Blind -and @($rJ.Owed).Count -eq 0 -and @($wlJ.RulingTerms).Count -eq 0) {
    Ok 'a checkout with no ruling file at all owes nothing and does not throw'
  } else { Bad ("no-ruling case: blind=$($rJ.Blind) owed=$(@($rJ.Owed).Count) ruling=$(@($wlJ.RulingTerms).Count)") }

  # ---- BAKER'S WEEKLY AD TERMS (2026-09-18, design\PLAN-bakers-weekly-ad-feed-2026-09-18.md) ------------------
  # The ad list for 2026-09-16..09-22 routes three terms over two commodities (shredded-cheese carries two).
  # Owed = those terms minus receipts (capture_terms success/empty) in a bakers-regular file written INSIDE the
  # window. The shapes below are the lane's own: bakers-regular-<date>.json with week_of and capture_terms.
  $bkOut = Join-Path $tmp 'bk-out'
  New-Item -ItemType Directory -Path (Join-Path $bkOut 'bakers') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $bkOut 'regular') -Force | Out-Null
  $bkList = [ordered]@{ store = "Baker's"; ad_id = '79d2baa2-eec6-4a91-9ffa-51c1c46fd2a4'; ad_from = '2026-09-16'; ad_to = '2026-09-22'
                        terms = @([ordered]@{ id = 'apples'; term = 'apples' }, [ordered]@{ id = 'shredded-cheese'; term = 'shredded cheese' },
                                  [ordered]@{ id = 'shredded-cheese'; term = 'shredded cheddar' }) }
  [IO.File]::WriteAllText((Join-Path $bkOut 'bakers\bakers-ad-list-2026-09-16.json'), ($bkList | ConvertTo-Json -Depth 5))
  function BkRegular([string]$name, [string]$weekOf, [object[]]$receipts) {
    $doc = [ordered]@{ store = "Baker's"; week_of = $weekOf; rotation_mode = 'rotation'; pull_terms = 1; capture_terms = $receipts; deal_count = 0; deals = @() }
    [IO.File]::WriteAllText((Join-Path $bkOut ('regular\bakers-regular-' + $name + '.json')), ($doc | ConvertTo-Json -Depth 6))
  }
  function BkReceipt([string]$id, [string]$term, [string]$outcome) { [ordered]@{ term_key = $id; term = $term; ordinal = 0; outcome = $outcome; row_count = 3 } }
  $bkPlan0 = Get-CapturePlan -Store "Baker's" -Today '2026-09-18'
  $bkAll = @(Get-AllTerms)
  $noAd = Get-BakersAskPlan -AllTerms $bkAll -Plan $bkPlan0 -CursorStart 0 -AdOwed @()

  # K. MUST FIRE - a current list with nothing asked owes every routed term, and they lead the ask list whole-
  #    commodity, while the rotation keeps its drip: the cursor lands exactly where it would with no ad at all.
  $oK = Get-BakersAdOwed -OutDir $bkOut -Date '2026-09-18'
  $aK = Get-BakersAskPlan -AllTerms $bkAll -Plan $bkPlan0 -CursorStart 0 -AdOwed @($oK.Owed)
  $tK = @($aK.Terms | ForEach-Object { $_.term })
  if ($oK.HasList -and @($oK.Owed).Count -eq 3 -and $tK[0] -eq 'apples' -and ($tK[1..2] -contains 'shredded cheese') -and ($tK[1..2] -contains 'shredded cheddar') -and
      $aK.CursorNext -eq $noAd.CursorNext -and @($aK.Slice.Items).Count -eq @($noAd.Slice.Items).Count) {
    Ok "MUST FIRE  the weekly ad's 3 owed terms lead Baker's asks [$($tK -join ', ')] and the cursor still lands on #$($aK.CursorNext), the same as with no ad"
  } else { Bad ("ad lead: hasList=$($oK.HasList) owed=$(@($oK.Owed).Count) asks=[$($tK -join ',')] cursor $($aK.CursorNext) vs $($noAd.CursorNext)") }
  $wlK = Get-CaptureWorklist -Store "Baker's" -Today '2026-09-18' -OutDir $bkOut
  $wtK = @($wlK.Terms | ForEach-Object { $_.term })
  if (@($wlK.AdTerms).Count -eq 3 -and $wtK[0] -eq 'apples' -and $wlK.AdList -eq 'bakers-ad-list-2026-09-16.json') { Ok 'MUST FIRE  the Baker''s worklist file carries the owed terms as ad_terms at the head of terms' }
  else { Bad ("worklist ad_terms=$(@($wlK.AdTerms).Count) terms=[$($wtK -join ',')] list=$($wlK.AdList)") }

  # L. MUST FIRE - receipts that do not prove an ask INSIDE this window discharge nothing: a file from before the
  #    window, a targeted merge named inside it that still carries an older file's receipts (week_of 09-14), and
  #    a 'blocked' receipt (the request failed twice) are all still owed.
  BkRegular '2026-09-14' '2026-09-14' @((BkReceipt 'apples' 'apples' 'success'))
  BkRegular '2026-09-17' '2026-09-14' @((BkReceipt 'apples' 'apples' 'success'), (BkReceipt 'shredded-cheese' 'shredded cheese' 'success'))
  BkRegular '2026-09-18' '2026-09-18' @((BkReceipt 'shredded-cheese' 'shredded cheddar' 'blocked'), (BkReceipt 'apples' 'apples' 'not_asked'))
  $oL = Get-BakersAdOwed -OutDir $bkOut -Date '2026-09-18'
  $sL = Get-BakersAdCaptureState -OutDir $bkOut -Date '2026-09-18'
  if (@($oL.Owed).Count -eq 3 -and -not $sL.Captured -and $sL.HasList -and $sL.Owed -eq 3) { Ok 'MUST FIRE  a pre-window receipt, a targeted merge carrying old receipts, a blocked and a not_asked receipt discharge nothing; the ad is NOT captured' }
  else { Bad ("owed=$(@($oL.Owed).Count) [$(@($oL.Owed) -join ',')] captured=$($sL.Captured)") }

  # M. MUST FIRE - no list for the day is its own state (it pages downstream), and owes nothing to ask.
  $sM = Get-BakersAdCaptureState -OutDir $bkOut -Date '2026-09-24'
  $oM = Get-BakersAdOwed -OutDir $bkOut -Date '2026-09-24'
  if (-not $sM.Captured -and -not $sM.HasList -and @($oM.Owed).Count -eq 0 -and $sM.Why -match 'no Baker''s ad list covers 2026-09-24') { Ok 'MUST FIRE  a day no ad list covers is NOT captured, and says which day' }
  else { Bad ("no-list: captured=$($sM.Captured) hasList=$($sM.HasList) why=$($sM.Why)") }

  # N. THE CAP HOLDS AND AN EXPIRY THE AD DISPLACED IS NOT MARKED. With Baker's cap at rotation + 1 the allowance
  #    is ONE term: apples fits, shredded-cheese (two terms) waits for tomorrow, and a Baker's sale expiry gives way
  #    to the ad - it is not in ExpiringKept, which is all the lane passes to Set-SaleExpiryProcessed.
  $bkCapWas = $script:StoreCallCap["Baker's"].cap
  $swBk = @{ windows = @(@{ store = "Baker's"; id = 'butter'; sale_end = '2026-09-17'; refresh_on = '2026-09-18' }) }
  $swPath = Join-Path $tmp 'sale-windows.json'
  $swWas = [IO.File]::ReadAllText($swPath)
  try {
    [IO.File]::WriteAllText($swPath, ($swBk | ConvertTo-Json -Depth 4))
    $script:StoreCallCap["Baker's"].cap = $bkPlan0.RotationTerms + 1
    $pN = Get-CapturePlan -Store "Baker's" -Today '2026-09-18'
    $aN = Get-BakersAskPlan -AllTerms $bkAll -Plan $pN -CursorStart 0 -AdOwed @($oL.Owed)
    $tN = @($aN.Terms | ForEach-Object { $_.term })
    if (@($pN.SaleExpiries) -contains 'butter' -and @($aN.AdTerms).Count -eq 1 -and $aN.AdDeferred -eq 1 -and $aN.ExpiryDeferredByAd -eq 1 -and
        @($aN.ExpiringKept).Count -eq 0 -and $tN -notcontains 'butter' -and $aN.CursorNext -eq $noAd.CursorNext -and @($tN).Count -le $pN.CallCap) {
      Ok "the cap holds (asked $(@($tN).Count) of cap $($pN.CallCap)), the 2-term commodity waits, and the displaced butter expiry is NOT marked processed"
    } else { Bad ("cap: expiries=[$(@($pN.SaleExpiries) -join ',')] ad=$(@($aN.AdTerms).Count) deferred=$($aN.AdDeferred) expDef=$($aN.ExpiryDeferredByAd) kept=[$(@($aN.ExpiringKept) -join ',')] asks=[$($tN -join ',')]") }
  } finally {
    $script:StoreCallCap["Baker's"].cap = $bkCapWas
    [IO.File]::WriteAllText($swPath, $swWas)
  }

  # O. CLEAN TWIN - the plan's own: on a non-ad day with the current list already asked (a rotation file written
  #    inside the window whose receipts cover every routed term, one of them 'empty'), Baker's asks are exactly the
  #    normal rotation drip again, and the ad is captured.
  BkRegular '2026-09-19' '2026-09-19' @((BkReceipt 'apples' 'apples' 'success'), (BkReceipt 'shredded-cheese' 'shredded cheese' 'empty'), (BkReceipt 'shredded-cheese' 'shredded cheddar' 'success'))
  $oO = Get-BakersAdOwed -OutDir $bkOut -Date '2026-09-20'
  $aO = Get-BakersAskPlan -AllTerms $bkAll -Plan (Get-CapturePlan -Store "Baker's" -Today '2026-09-20') -CursorStart 0 -AdOwed @($oO.Owed)
  $sO = Get-BakersAdCaptureState -OutDir $bkOut -Date '2026-09-20'
  $wlO = Get-CaptureWorklist -Store "Baker's" -Today '2026-09-20' -OutDir $bkOut
  if (@($oO.Owed).Count -eq 0 -and @($aO.AdTerms).Count -eq 0 -and @($aO.Terms).Count -eq $bkPlan0.RotationTerms -and $sO.Captured -and
      @($wlO.AdTerms).Count -eq 0 -and @($wlO.Terms).Count -eq @($wlO.RotationTerms).Count) {
    Ok "CLEAN TWIN  once every routed term has a receipt inside the window, Baker's asks are the normal $($bkPlan0.RotationTerms)-term rotation and the ad reads CAPTURED"
  } else { Bad ("asked list: owed=$(@($oO.Owed).Count) adTerms=$(@($aO.AdTerms).Count) terms=$(@($aO.Terms).Count) captured=$($sO.Captured) why=$($sO.Why)") }

  # P. MUST NOT FIRE - the ad prepends nothing to any other store's worklist.
  $wlP = Get-CaptureWorklist -Store 'Family Fare' -Today '2026-09-18' -OutDir $bkOut
  if (@($wlP.AdTerms).Count -eq 0 -and $wlP.AdTotal -eq 0) { Ok 'MUST NOT FIRE  a Baker''s ad list prepends nothing to another store''s worklist' }
  else { Bad ("Family Fare picked up ad terms: $(@($wlP.AdTerms | ForEach-Object { $_.term }) -join ',')") }

  # Q. MUST FIRE - THE WRITER AND ITS READERS AGREE (2026-09-18). 7e1c7d94e dropped `terms` and `commodities` from
  #    Write-CaptureWorklist, and pull-browser-stores.py, which reads exactly those two, read every worklist from
  #    09-13 on as "nothing owed today": Fareway and Sam's captured nothing for four chain runs. So the file this
  #    writer emits is read back through the driver's OWN readers (read_worklist_pairs for the navigate lane,
  #    read_worklist for the sweep lane), in a child python, and must return every (term, commodity) pair
  #    Get-CaptureWorklist chose, in order. Family Fare carries the two-term commodity and its sale expiry.
  $py = 'C:\Codex\Python312\python.exe'
  $driverPy = Join-Path $root 'pull-browser-stores.py'
  if (-not (Test-Path -LiteralPath $py)) { Bad "round-trip: no python at $py, so the writer/reader contract was NOT checked" }
  else {
    $rtProbe = Join-Path $tmp 'rt-probe.py'
    $rtLines = @(
      'import importlib.util, json, sys',
      'spec = importlib.util.spec_from_file_location("pbs", sys.argv[1])',
      'm = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)',
      'm.ROOT = sys.argv[2]',
      'out = {}',
      'for key in sys.argv[4:]:',
      '    try:',
      '        pairs, why = m.read_worklist_pairs(key, sys.argv[3])',
      '        terms, why2 = m.read_worklist(key, sys.argv[3])',
      '        out[key] = {"pairs": [list(p) for p in (pairs or [])], "terms": terms or [], "why": why or why2 or ""}',
      '    except m.WorklistUnreadable as e:',
      '        out[key] = {"pairs": [], "terms": [], "why": "UNREADABLE " + str(e)}',
      'print(json.dumps(out))'
    )
    [IO.File]::WriteAllText($rtProbe, ($rtLines -join "`n"), (New-Object Text.UTF8Encoding($false)))
    # store-subset-ok: rotation-probe store-to-slug table; the probe drives Get-CaptureWorklist per store and never branches on which store
    $rtStores = [ordered]@{ 'Fareway' = 'fareway'; "Sam's Club" = 'samsclub'; 'Family Fare' = 'familyfare' }
    # A sale expiry per store, so each list is longer than one pair and Fareway's carries both terms of ONE
    # commodity: a reader that paired by the wrong index could not pass on a single pair.
    $swRt = @{ windows = @(@{ store = 'Fareway';     id = 'shredded-cheese'; sale_end = '2026-08-29'; refresh_on = '2026-08-30' },
                           @{ store = "Sam's Club";  id = 'butter';          sale_end = '2026-08-29'; refresh_on = '2026-08-30' },
                           @{ store = 'Family Fare'; id = 'rice';            sale_end = '2026-08-29'; refresh_on = '2026-08-30' }) }
    $swPathRt = Join-Path $tmp 'sale-windows.json'
    $swWasRt = [IO.File]::ReadAllText($swPathRt)
    $want = @{}
    try {
      [IO.File]::WriteAllText($swPathRt, ($swRt | ConvertTo-Json -Depth 4))
      foreach ($s in $rtStores.Keys) {
        $wlQ = Get-CaptureWorklist -Store $s -Today '2026-08-30' -OutDir (Join-Path $tmp 'out')
        $want[$rtStores[$s]] = @($wlQ.Terms | ForEach-Object { "$($_.term)=$($_.id)" })
        $null = Write-CaptureWorklist -Store $s -Today '2026-08-30' -OutDir (Join-Path $tmp 'out')
      }
    } finally { [IO.File]::WriteAllText($swPathRt, $swWasRt) }
    if (@($want['fareway']) -notcontains 'shredded cheese=shredded-cheese' -or @($want['fareway']) -notcontains 'shredded cheddar=shredded-cheese') {
      Bad "round-trip fixture: Fareway's list lost its two-term commodity, so the pairing is no longer tested: [$(@($want['fareway']) -join ', ')]"
    }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $rtRaw = & $py $rtProbe $driverPy $tmp '2026-08-30' @($rtStores.Values); $rtRc = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prevEap }
    $rtDoc = $null
    try { $rtDoc = (@($rtRaw) -join "`n") | ConvertFrom-Json } catch { }
    if ($rtRc -ne 0 -or -not $rtDoc) { Bad "round-trip: the driver's readers could not be run (rc=$rtRc): $(@($rtRaw) -join ' | ')" }
    else {
      foreach ($k in @($rtStores.Values)) {
        $r = $rtDoc.$k
        $gotPairs = @(@($r.pairs) | Where-Object { $_ } | ForEach-Object { "$($_[0])=$($_[1])" })
        $gotTerms = @(@($r.terms) | Where-Object { $_ })
        $w = @($want[$k])
        if ($w.Count -gt 0 -and ($gotPairs -join '|') -ceq ($w -join '|') -and $gotTerms.Count -eq $w.Count) {
          Ok "MUST FIRE  a $k worklist written by Write-CaptureWorklist reads back through the driver as the same $($w.Count) (term, commodity) pairs, in order"
        } else { Bad ("round-trip $k : wrote $($w.Count) [$($w -join ', ')] read $($gotPairs.Count) [$($gotPairs -join ', ')] why=$($r.why)") }
      }
    }
  }

  # ---- THE CAPACITY INVARIANT (2026-09-19, design\PLAN-board-accuracy-2026-09-19.md) --------------------------------
  # From 2026-08-20 the rotation took 86 days to come round while nothing stopped a price being published at any age,
  # and the 2026-09-17 board verified at 36 defects in 100. These cases make that a push-time refusal.
  # LIVE: the REAL term list (read from this checkout's commodity-search.json, never the temp fixture) must fit every
  # store's cap inside RotationDays, and RotationDays must sit inside the publish limit.
  $liveCs = Join-Path $root 'commodity-search.json'
  $liveN = 0
  foreach ($p in (ConvertFrom-Json ([IO.File]::ReadAllText($liveCs))).terms.PSObject.Properties) { if ($p.Value -is [array]) { $liveN += @($p.Value).Count } else { $liveN++ } }
  # EVERY store in the LIVE stores.json (2026-09-19, queue 2026-09-19-405c73): the six-name literal here mirrored the lib's
  # and left out Hy-Vee. A product-id store is counted in its own unit from this checkout's newest regular file.
  $liveStores = Get-CapacityStores -Root $root
  $liveCounts = @{}
  foreach ($s in $liveStores) {
    if ($script:StoreCallCap.ContainsKey($s) -and [string]$script:StoreCallCap[$s].unit -eq 'product ids') { $liveCounts[$s] = Get-StoreRotationUnitCount -Store $s -Root $root }
    else { $liveCounts[$s] = $liveN }
  }
  $liveCap = @(Test-CaptureCapacity -Stores $liveStores -TermCounts $liveCounts)
  $liveBad = @($liveCap | Where-Object { $_.Ok -eq $false })
  $liveBlind = @($liveCap | Where-Object { $_.Measured -eq $false })
  foreach ($lb in $liveBlind) { Write-Output ("  SKIP  LIVE capacity " + $lb.Store + ": " + $lb.Why) }
  if ($liveN -gt 0 -and $liveStores.Count -gt 0 -and $liveCap.Count -eq $liveStores.Count -and $liveBad.Count -eq 0) {
    Ok ("LIVE  every store in stores.json (" + $liveStores.Count + ") re-reads its rotation inside RotationDays=$($script:RotationDays) (publish limit $($script:MaxPublishAgeDays)), " + $liveBlind.Count + " unmeasured: " + (($liveCap | ForEach-Object { "$($_.Store) $($_.NeedPerRun)/$($_.Cap) of $($_.Terms)" }) -join ', '))
  } else { Bad ("LIVE capacity: $($liveBad.Count) of $($liveCap.Count) store(s) (stores.json has $($liveStores.Count)) cannot be re-read in time: " + (($liveBad | ForEach-Object { "$($_.Store): $($_.Why)" }) -join ' | ')) }

  # BRAD'S STANDING RULE, ASSERTED ON THE LIVE VALUES (2026-09-19): an everyday price is re-read about once every
  # 90 days at every store, so the rotation and the publish limit ARE the quarter. A session shortened both to 14
  # that day without the rule in front of it and Brad reversed it; this case makes the next shortening fail at push.
  if ($script:RotationDays -eq $script:QuarterDays -and $script:MaxPublishAgeDays -eq $script:QuarterDays) {
    Ok "LIVE  RotationDays ($($script:RotationDays)) and MaxPublishAgeDays ($($script:MaxPublishAgeDays)) are the quarter ($($script:QuarterDays)), Brad's standing everyday-price rule"
  } else { Bad "LIVE  RotationDays=$($script:RotationDays) MaxPublishAgeDays=$($script:MaxPublishAgeDays), but Brad's standing rule makes both the quarter ($($script:QuarterDays)): an everyday price is re-read about once every 90 days. Changing that is his decision, not a diff." }

  # The capacity MECHANICS below run in a FIXTURE regime of 14 days on both constants, so their arithmetic (at the
  # bar, one past it, runs per window) stays exactly as written whatever the live window is. Both are restored.
  $rdSave = $script:RotationDays
  $mpSave = $script:MaxPublishAgeDays
  try {
    $script:MaxPublishAgeDays = 14
    # MUST FIRE: a rotation slower than the publish limit (90 against 14) is refused by name.
    $script:RotationDays = 90
    $old = @(Test-CaptureCapacity -Stores @('Walmart') -TermCounts @{ 'Walmart' = 602 })
    if (-not $old[0].Ok -and $old[0].Why -match 'exceeds MaxPublishAgeDays') { Ok "MUST FIRE  the 2026-08-20 regime (RotationDays 90, publish limit $($script:MaxPublishAgeDays)) is refused: $($old[0].Why)" }
    else { Bad "the 90-day rotation was accepted against a $($script:MaxPublishAgeDays)-day publish limit (ok=$($old[0].Ok) why='$($old[0].Why)')" }
    $script:RotationDays = 14
    # AT THE BAR (cap 45, 14 days): 630 terms is exactly 45 a run and passes. ONE TERM PAST IT, 631 is 46 and fails.
    $at = @(Test-CaptureCapacity -Stores @('Walmart') -TermCounts @{ 'Walmart' = 630 })
    if ($at[0].Ok -and $at[0].NeedPerRun -eq 45 -and $at[0].Cap -eq 45) { Ok 'MUST NOT FIRE  at the bar: 630 terms / 14 days = 45 a run against the Walmart cap of 45 is accepted' }
    else { Bad "at the bar: need=$($at[0].NeedPerRun) cap=$($at[0].Cap) ok=$($at[0].Ok) (want 45/45 accepted)" }
    $past = @(Test-CaptureCapacity -Stores @('Walmart') -TermCounts @{ 'Walmart' = 631 })
    if (-not $past[0].Ok -and $past[0].NeedPerRun -eq 46) { Ok 'MUST FIRE  one term past the bar: 631 terms / 14 days = 46 a run over the Walmart cap of 45 is refused' }
    else { Bad "past the bar: need=$($past[0].NeedPerRun) ok=$($past[0].Ok) (want 46 refused)" }
    # CLEAN TWIN: a per-window limit is covered across its runs. Family Fare's 40 a window cannot take 43 in one run,
    # and 3 runs a day make it 15 a run. Get-CapturePlan asks for the per-run figure.
    $ff = @(Test-CaptureCapacity -Stores @('Family Fare') -TermCounts @{ 'Family Fare' = 602 })
    if ($ff[0].Ok -and $ff[0].RunsPerDay -eq 3 -and $ff[0].NeedPerRun -eq 15) { Ok 'CLEAN TWIN  Family Fare covers 602 terms in 14 days at 15 a run across 3 runs, inside its measured 40 a window' }
    else { Bad "Family Fare runs: runs=$($ff[0].RunsPerDay) need=$($ff[0].NeedPerRun) ok=$($ff[0].Ok) (want 3 runs, 15 a run)" }
    # THE BROWSER ROSTER IS DERIVED (queue 2026-09-19-405c73): the live stores.json's browser surfaces are exactly the
    # four stores capture-watchdog used to name by hand.
    $liveBrowser = Get-BrowserSurfaceStores -Root $root
    if ((@($liveBrowser | Sort-Object) -join ',') -eq "Aldi,Fareway,Sam's Club,Walmart") { Ok ('LIVE  stores.json browser surfaces are exactly Aldi, Fareway, Sam''s Club, Walmart (' + $liveBrowser.Count + ')') }
    else { Bad ('LIVE browser surfaces drifted: [' + ($liveBrowser -join ',') + '] - capture-watchdog''s same-morning check now drives from this list') }
    # HY-VEE IN ITS OWN UNIT (2026-09-19, queue 2026-09-19-405c73). Cap 120 product ids a run, 14 days: 1,680 is
    # exactly 120 and passes; ONE PRODUCT PAST IT, 1,694 (14 x 120 + 14) needs 121 and is refused.
    $hvAt = @(Test-CaptureCapacity -Stores @('Hy-Vee') -TermCounts @{ 'Hy-Vee' = 1680 })
    if ($hvAt[0].Ok -and $hvAt[0].NeedPerRun -eq 120 -and $hvAt[0].Cap -eq 120) { Ok 'MUST NOT FIRE  at the bar: 1,680 Hy-Vee product ids / 14 days = 120 a run against its cap of 120 is accepted' }
    else { Bad "Hy-Vee at the bar: need=$($hvAt[0].NeedPerRun) cap=$($hvAt[0].Cap) ok=$($hvAt[0].Ok) (want 120/120 accepted)" }
    $hvPast = @(Test-CaptureCapacity -Stores @('Hy-Vee') -TermCounts @{ 'Hy-Vee' = 1694 })
    if ($hvPast[0].Ok -eq $false -and $hvPast[0].NeedPerRun -eq 121 -and $hvPast[0].Why -match 'product ids') { Ok 'MUST FIRE  past the bar: 1,694 Hy-Vee product ids / 14 days = 121 a run over its cap of 120 is refused, in product ids' }
    else { Bad "Hy-Vee past the bar: need=$($hvPast[0].NeedPerRun) ok=$($hvPast[0].Ok) why='$($hvPast[0].Why)' (want 121 refused)" }
    $hvBlind = @(Test-CaptureCapacity -Stores @('Hy-Vee') -TermCounts @{ 'Hy-Vee' = -1 })
    if ($null -eq $hvBlind[0].Ok -and $hvBlind[0].Measured -eq $false) { Ok 'MUST FIRE  an unreadable product-id count is UNMEASURED, never read as ok' }
    else { Bad "Hy-Vee unmeasured read as ok=$($hvBlind[0].Ok)" }
  } finally { $script:RotationDays = $rdSave; $script:MaxPublishAgeDays = $mpSave }

  # ---- THE FULL RECAPTURE (2026-09-19): every term, capped at the store's largest clean run on record ------------
  $fOut = Join-Path $tmp 'out'
  $fNorm = ConvertFrom-Json ([IO.File]::ReadAllText((Write-CaptureWorklist -Store 'Walmart' -Today '2026-08-30' -OutDir $fOut)))
  $fFull = ConvertFrom-Json ([IO.File]::ReadAllText((Write-CaptureWorklist -Store 'Walmart' -Today '2026-08-30' -OutDir $fOut -Full)))
  $fAll = @(Get-AllTerms).Count   # 13: twelve commodities, shredded-cheese carrying two terms
  if ($fAll -eq 13 -and @($fFull.terms).Count -eq $fAll -and [bool]$fFull.full_recapture -and @($fFull.commodities).Count -eq $fAll) { Ok "MUST FIRE  -Full asks for every one of the $fAll fixture terms, with commodities in step, and says it is a full recapture" }
  else { Bad "full worklist: terms=$(@($fFull.terms).Count) commodities=$(@($fFull.commodities).Count) full=$($fFull.full_recapture) (want $fAll/$fAll/true, all terms 13)" }
  if (-not [bool]$fNorm.full_recapture -and @($fNorm.terms).Count -lt $fAll) { Ok "CLEAN TWIN  the normal worklist is still the drip ($(@($fNorm.terms).Count) term(s)) and does not claim to be full" }
  else { Bad "normal worklist changed: terms=$(@($fNorm.terms).Count) full=$($fNorm.full_recapture)" }
  $fcSave = $script:FullRunCap['Walmart']
  try {
    $script:FullRunCap['Walmart'] = 5
    $fCap = ConvertFrom-Json ([IO.File]::ReadAllText((Write-CaptureWorklist -Store 'Walmart' -Today '2026-08-30' -OutDir $fOut -Full)))
    if (@($fCap.terms).Count -eq 5 -and [int]$fCap.call_cap -eq 5) { Ok 'MUST FIRE  a full recapture never asks past the store''s clean-run cap (cap 5: exactly 5 terms)' }
    else { Bad "full cap: terms=$(@($fCap.terms).Count) call_cap=$($fCap.call_cap) (want 5/5)" }
  } finally { $script:FullRunCap['Walmart'] = $fcSave }

  # ---- BRAD'S CHROME FIRST, THE SCRIPT DRIVER AS FALLBACK (2026-09-19) ------------------------------------------
  $bcDir = Join-Path $tmp 'bc'; [void][IO.Directory]::CreateDirectory($bcDir)
  $bcSams = Join-Path $bcDir 'sams.csv'; [IO.File]::WriteAllText($bcSams, "#tc-store store=`"Omaha`" read=`"page`" rows=1`nq|n|lp|up|id|was|ful`neggs|Large Eggs|`$2.38|`$0.20|1||PICKUP@8146`n")
  $bcFw = Join-Path $bcDir 'fw.jsonl'; [IO.File]::WriteAllText($bcFw, '')
  $bcHdr = Join-Path $bcDir 'hdr.csv'; [IO.File]::WriteAllText($bcHdr, "#tc-store store=`"Omaha`" read=`"page`" rows=0`nq|n|lp|up|id|was|ful`n")
  $bc = Get-BrowserStoresToDrive -Stores @("Sam's Club", 'Fareway', 'Walmart') -CaptureFiles @{ "Sam's Club" = $bcSams; 'Fareway' = $bcFw; 'Walmart' = (Join-Path $bcDir 'none.csv') }
  if ((@($bc.AlreadyCaptured) -join ',') -eq "Sam's Club" -and (@($bc.Drive) -join ',') -eq 'Fareway,Walmart') { Ok 'MUST FIRE  a store Brad''s Chrome already captured today is NOT driven again; an empty file and a missing file are driven' }
  else { Bad "browser fallback: captured=[$(@($bc.AlreadyCaptured) -join ',')] drive=[$(@($bc.Drive) -join ',')]" }
  $bc2 = Get-BrowserStoresToDrive -Stores @("Sam's Club") -CaptureFiles @{ "Sam's Club" = $bcHdr }
  if ((@($bc2.Drive) -join ',') -eq "Sam's Club") { Ok 'MUST FIRE  a capture holding only its store line and header is not a landed capture, so the fallback still drives it' }
  else { Bad "header-only capture counted as landed: drive=[$(@($bc2.Drive) -join ',')]" }

  # ---- AN UNTRACKED FILE IN THE REBASE'S WAY (2026-09-19): git's own words, frozen from that morning -----------
  $rbMsg = @('error: The following untracked working tree files would be overwritten by checkout:', "`tshared/paired/report.json", "`tgrocery/out/x.json", 'Please move or remove them before you switch branches.', 'Aborting')
  $rbB0 = Get-RebaseUntrackedBlockers $rbMsg; $rbB = @($rbB0)
  if ($rbB.Count -eq 2 -and $rbB[0] -eq 'shared/paired/report.json' -and $rbB[1] -eq 'grocery/out/x.json') { Ok 'MUST FIRE  the untracked files git names as blocking the rebase are read out exactly (the 2026-09-19 dedup report)' }
  else { Bad "untracked blockers read as [$($rbB -join ', ')]" }
  $rbC0 = Get-RebaseUntrackedBlockers @('CONFLICT (content): Merge conflict in grocery/x.json', 'error: could not apply abc123... msg'); $rbC = @($rbC0)
  if ($rbC.Count -eq 0) { Ok 'MUST NOT FIRE  an ordinary content conflict names no untracked blocker, so nothing is moved' }
  else { Bad "content conflict read as blockers [$($rbC -join ', ')]" }

  # ---- SALE FALLBACKS ARE OWED IN THE STORE'S OWN PLAN (2026-09-22, plan-2026-09-22-9, queue 2026-09-19-c9f0f3) ----
  # Frozen from c9f0f3's body: clam-chowder and vegetable-soup on sale at Family Fare with no everyday twin, owner NONE,
  # 6 days unworked. Its own synthetic root, so nothing above leaks in: 13 one-term commodities (rotation 1 a run).
  $sfRoot = Join-Path $tmp 'sfb'; $sfOut = Join-Path $sfRoot 'out'; [void][IO.Directory]::CreateDirectory($sfOut)
  $sfTerms = [ordered]@{}; foreach ($c in @('apples','bacon','bananas','bread','butter','carrots','eggs','flour','milk','onions','rice','clam-chowder','vegetable-soup')) { $sfTerms[$c] = $c }
  [IO.File]::WriteAllText((Join-Path $sfRoot 'commodity-search.json'), (@{ terms = $sfTerms } | ConvertTo-Json -Depth 4))
  [IO.File]::WriteAllText((Join-Path $sfRoot 'sale-windows.json'), (@{ windows = @(
      @{ store = 'Family Fare'; id = 'apples'; sale_end = '2026-09-18'; refresh_on = '2026-09-19' },
      @{ store = 'Family Fare'; id = 'bacon';  sale_end = '2026-09-18'; refresh_on = '2026-09-19' }) } | ConvertTo-Json -Depth 4))
  $sfGapsF = Join-Path $sfOut 'sale-fallback-gaps.json'
  $sfGaps2 = '{"gaps":[{"commodity":"clam-chowder","store":"Family Fare","first_seen":"2026-09-13"},{"commodity":"vegetable-soup","store":"Family Fare","first_seen":"2026-09-13"},{"commodity":"canned-pumpkin","store":"Hy-Vee","first_seen":"2026-09-02"}]}'
  [IO.File]::WriteAllText($sfGapsF, $sfGaps2)
  $sfRootWas = $script:PolicyRoot; $sfCapWas = $script:StoreCallCap['Family Fare']
  try {
    $script:PolicyRoot = $sfRoot
    $script:StoreCallCap['Family Fare'] = @{ cap = 40; basis = 'fixture'; unit = 'search terms' }
    $sfP = Get-CapturePlan -Store 'Family Fare' -Today '2026-09-19' -OutDir $sfOut
    if ((@($sfP.SaleFallbacks) -contains 'vegetable-soup') -and (@($sfP.SaleFallbacks) -contains 'clam-chowder') -and (@($sfP.SaleExpiries).Count -eq 2) -and $sfP.TermBudget -eq ($sfP.RotationTerms + 4)) { Ok 'MUST FIRE  vegetable-soup @ Family Fare, on sale with no everyday twin, is OWED in Get-CapturePlan(Family Fare).SaleFallbacks (c9f0f3), and the budget counts it' }
    else { Bad "fallbacks not owed: fb=[$(@($sfP.SaleFallbacks) -join ',')] exp=[$(@($sfP.SaleExpiries) -join ',')] budget=$($sfP.TermBudget)" }
    if (@($sfP.SaleFallbacks) -notcontains 'canned-pumpkin') { Ok 'MUST NOT FIRE  a Hy-Vee gap is never owed by the Family Fare plan' } else { Bad 'the Family Fare plan took a Hy-Vee gap' }
    # AT THE BAR: cap 3 = rotation 1 + an allowance of exactly the 2 expiries -> 0 fallbacks. ONE PAST: cap 4 -> exactly 1.
    $script:StoreCallCap['Family Fare'] = @{ cap = 3; basis = 'fixture'; unit = 'search terms' }
    $sfAt = Get-CapturePlan -Store 'Family Fare' -Today '2026-09-19' -OutDir $sfOut
    $script:StoreCallCap['Family Fare'] = @{ cap = 4; basis = 'fixture'; unit = 'search terms' }
    $sfPast = Get-CapturePlan -Store 'Family Fare' -Today '2026-09-19' -OutDir $sfOut
    if (@($sfAt.SaleFallbacks).Count -eq 0 -and @($sfAt.SaleExpiries).Count -eq 2 -and @($sfPast.SaleFallbacks).Count -eq 1 -and @($sfPast.SaleExpiries).Count -eq 2 -and $sfPast.SaleFallbackDeferred -eq 1) { Ok 'MUST FIRE  AT THE BAR (allowance = the 2 expiries, cap 3) 0 fallbacks are asked; ONE PAST it (cap 4) exactly 1, and both expiries keep their slots' }
    else { Bad "the bar: at fb=$(@($sfAt.SaleFallbacks).Count) exp=$(@($sfAt.SaleExpiries).Count); past fb=$(@($sfPast.SaleFallbacks).Count) exp=$(@($sfPast.SaleExpiries).Count) deferred=$($sfPast.SaleFallbackDeferred)" }
    # least-recently-asked first: a LANDED ask of clam-chowder puts vegetable-soup at the head; a blind run marks nothing
    $sfBlind = Set-SaleFallbackAsked -Store 'Family Fare' -Today '2026-09-19' -OutDir $sfOut -Ids @('clam-chowder') -Landed $false -AllowReplay
    $sfMk = Set-SaleFallbackAsked -Store 'Family Fare' -Today '2026-09-19' -OutDir $sfOut -Ids @('clam-chowder', 'bananas') -Landed $true -AllowReplay
    $sfNext = Get-CapturePlan -Store 'Family Fare' -Today '2026-09-20' -OutDir $sfOut
    if ($sfBlind.Marked -eq 0 -and $sfMk.Marked -eq 1 -and (@($sfMk.Ids) -join ',') -eq 'clam-chowder' -and @($sfNext.SaleFallbacks)[0] -eq 'vegetable-soup') { Ok 'CLEAN TWIN  only a LANDED ask is recorded, only for an id the plan owed (not bananas), and the asked fallback goes behind the unasked one next day' }
    else { Bad "ask ledger: blind=$($sfBlind.Marked) marked=$($sfMk.Marked) [$(@($sfMk.Ids) -join ',')] next=[$(@($sfNext.SaleFallbacks) -join ',')]" }
    # a gap whose everyday twin landed leaves the report, and so the plan, the next day
    [IO.File]::WriteAllText($sfGapsF, '{"gaps":[{"commodity":"clam-chowder","store":"Family Fare","first_seen":"2026-09-13"}]}')
    $sfGone = Get-CapturePlan -Store 'Family Fare' -Today '2026-09-20' -OutDir $sfOut
    if ((@($sfGone.SaleFallbackPending) -join ',') -eq 'clam-chowder') { Ok 'CLEAN TWIN  a gap whose everyday twin landed leaves SaleFallbacks the next day' } else { Bad "a cleared gap stayed owed: [$(@($sfGone.SaleFallbackPending) -join ',')]" }
    Remove-Item -LiteralPath $sfGapsF -Force
    $sfNone = Get-CapturePlan -Store 'Family Fare' -Today '2026-09-20' -OutDir $sfOut
    if ($sfNone.SaleFallbackBlind -and @($sfNone.SaleFallbacks).Count -eq 0 -and @($sfNone.SaleExpiries).Count -eq 2) { Ok 'CLEAN TWIN  no gaps file: the plan says BLIND, owes no fallback, and its expiries are unchanged' } else { Bad "no gaps file: blind=$($sfNone.SaleFallbackBlind) fb=$(@($sfNone.SaleFallbacks).Count) exp=$(@($sfNone.SaleExpiries).Count)" }
    # Baker's ask plan: the fallbacks take only what the kept expiries left of the allowance
    $sfAll = @(@('apples','bacon','bread') | ForEach-Object { [pscustomobject]@{ id = $_; term = $_ } })
    $sfBkAt = Get-BakersAskPlan -AllTerms $sfAll -Plan ([pscustomobject]@{ CallCap = 2; RotationTerms = 1; SaleExpiries = @('apples'); SaleFallbacks = @('bacon') }) -CursorStart 0
    $sfBkPast = Get-BakersAskPlan -AllTerms $sfAll -Plan ([pscustomobject]@{ CallCap = 3; RotationTerms = 1; SaleExpiries = @('apples'); SaleFallbacks = @('bacon', 'bread') }) -CursorStart 0
    if (@($sfBkAt.FallbackKept).Count -eq 0 -and (@($sfBkAt.ExpiringKept) -join ',') -eq 'apples' -and (@($sfBkPast.FallbackKept) -join ',') -eq 'bacon' -and (@($sfBkPast.ExpiringKept) -join ',') -eq 'apples') { Ok 'MUST FIRE  Baker''s AT THE BAR (allowance 1 = the expiry) asks no fallback; ONE PAST it asks exactly bacon, and the expiry is never displaced' }
    else { Bad "Baker's fallbacks: at=[$(@($sfBkAt.FallbackKept) -join ',')] exp=[$(@($sfBkAt.ExpiringKept) -join ',')]; past=[$(@($sfBkPast.FallbackKept) -join ',')]" }
    # BAKER'S ROTATES ITS FALLBACKS THROUGH THE SAME ASK RECORD (coordinator, 2026-09-22). Two owed Baker's gaps, a
    # room of ONE fallback a run; 'rice' is one Baker's never finds. The plan and Get-BakersAskPlan are the lane's own.
    [IO.File]::WriteAllText((Join-Path $sfOut 'sale-fallback-gaps.json'), '{"gaps":[{"commodity":"rice","store":"Baker''s","first_seen":"2026-09-10"},{"commodity":"onions","store":"Baker''s","first_seen":"2026-09-12"}]}')
    $bkCapWas = $script:StoreCallCap["Baker's"]
    try {
      $script:StoreCallCap["Baker's"] = @{ cap = 2; basis = 'fixture'; unit = 'search terms' }   # rotation 1 + room for 1
      $bkAllT = @(@('rice','onions','milk') | ForEach-Object { [pscustomobject]@{ id = $_; term = $_ } })
      $bkP1 = Get-CapturePlan -Store "Baker's" -Today '2026-09-20' -OutDir $sfOut
      $bkA1 = Get-BakersAskPlan -AllTerms $bkAllT -Plan $bkP1 -CursorStart 2
      # MUST FIRE: with no ask recorded, the never-found 'rice' is still first the next day - it would hold the head forever
      $bkP2no = Get-CapturePlan -Store "Baker's" -Today '2026-09-21' -OutDir $sfOut
      if ((@($bkA1.FallbackKept) -join ',') -eq 'rice' -and (@($bkP2no.SaleFallbacks) -join ',') -eq 'rice') { Ok 'MUST FIRE  Baker''s: without the ask record, the never-found fallback (rice) stays first the next day' }
      else { Bad "Baker's without a record: kept=[$(@($bkA1.FallbackKept) -join ',')] next=[$(@($bkP2no.SaleFallbacks) -join ',')]" }
      # CLEAN TWIN: the lane records what its ask plan kept, through the same Set-SaleFallbackAsked, and the next owed item is asked
      $bkMk = Set-SaleFallbackAsked -Store "Baker's" -Today '2026-09-20' -OutDir $sfOut -Landed $true -Ids @($bkA1.FallbackKept) -AllowReplay
      $bkP2 = Get-CapturePlan -Store "Baker's" -Today '2026-09-21' -OutDir $sfOut
      $bkA2 = Get-BakersAskPlan -AllTerms $bkAllT -Plan $bkP2 -CursorStart 2
      if ($bkMk.Marked -eq 1 -and (@($bkA2.FallbackKept) -join ',') -eq 'onions') { Ok 'CLEAN TWIN  Baker''s: with the ask recorded, the next run asks the next owed fallback (onions)' }
      else { Bad "Baker's with a record: marked=$($bkMk.Marked) next kept=[$(@($bkA2.FallbackKept) -join ',')]" }
      # and the lane really writes that record from its ask plan (needle built by concatenation, never a self-grep)
      $bkSrc = [IO.File]::ReadAllText((Join-Path $root 'pull-regular-bakers-api.ps1'))
      $bkNeedle = 'Set-SaleFallback' + 'Asked -Store "Baker''s"'
      if ($bkSrc.Contains($bkNeedle) -and $bkSrc.Contains('BkAsk.' + 'FallbackKept')) { Ok 'MUST FIRE  pull-regular-bakers-api records the fallbacks its ask plan kept through Set-SaleFallbackAsked' }
      else { Bad 'pull-regular-bakers-api no longer records its asked fallbacks - a never-found Baker''s fallback holds the head of the owed order again' }
    } finally { $script:StoreCallCap["Baker's"] = $bkCapWas }
  } finally { $script:PolicyRoot = $sfRootWas; $script:StoreCallCap['Family Fare'] = $sfCapWas }
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

Write-Output ("CAPTURE-POLICY " + $(if ($fail) { "FAILED ($fail)" } else { 'PASSED' }))
exit $(if ($fail) { 1 } else { 0 })
