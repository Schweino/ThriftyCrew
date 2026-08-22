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
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

Write-Output ("CAPTURE-POLICY " + $(if ($fail) { "FAILED ($fail)" } else { 'PASSED' }))
exit $(if ($fail) { 1 } else { 0 })
