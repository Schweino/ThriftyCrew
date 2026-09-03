# audit-unit-basis-outlier.ps1 - catches a WRONG BASIS by arithmetic, when nothing in the row declares it.
#
# WHY THIS EXISTS (2026-07-31 Aldi finding, verified in-browser):
#   pull-aldi-instore.js reads each product's PRODUCT PAGE and takes its "size" field. For a multipack
#   that field is the PER-UNIT size, while the price it stores is the PACK price. PurAqua Purified Water
#   captured as size "16.9 fl oz" at $3.19, when the storefront tile says 24 x 16.9 fl oz for that price.
#
#   Guard 5 (multipack size) cannot see this. Guard 5 tests rows whose NAME states a pack count against
#   their size; here the name says "16.9 FL OZ", the size says "16.9 fl oz", and the count appears
#   NOWHERE on the captured surface. There is no declaration to contradict. The row is internally
#   consistent and completely wrong.
#
#   What IS left is arithmetic. A pack price divided by one unit's size produces a per-unit figure several
#   times every other store's for the same commodity. That is the same fingerprint as the mirror bug in
#   the board-basis notes (a per-lb rate printed in the size, a pack total as the each-size), so this
#   audit catches the whole family, not just Aldi's version of it.
#
# ADVISORY BY DESIGN, never a hard gate. Some products really are several times dearer per unit than
# their shelf-mates (organic vs conventional, a tiny jar vs a bulk tub). The job here is to put a short,
# ranked list in front of a human, not to block a publish on a heuristic.
#
#   .\audit-unit-basis-outlier.ps1                 audit the newest comparison
#   .\audit-unit-basis-outlier.ps1 -Ratio 4        change the flag threshold (default 4x the median)
#   .\audit-unit-basis-outlier.ps1 -SelfTest       frozen founding-bug fixture + clean twins
# Exit 0 = clean or advisory findings only. Exit 2 = self-test regression. Exit 3 = BLIND (nothing seen).
param([string]$CompareFile = '', [double]$Ratio = 4.0, [int]$MinStores = 4, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# THE DETECTOR, kept pure so the fixture can reach it without any data files (fix-needs-reachable-selftest).
# Returns one finding per store whose per-unit is >= $Ratio x the row's median per-unit.
# The median, not the minimum: comparing against the cheapest store would flag every ordinary premium
# brand on a row where one store runs a deep sale, which is noise, not basis error.
# Does a size string declare a pack? "24 x 16.9 fl oz", "12 pk 2.5 oz", "18 pack", "40 ct".
function Test-PackShape([string]$size) {
  if (-not $size) { return $false }
  return ($size -imatch '(^|\s)\d+\s*(x|pk|pack|ct|count)(\s|$|\d)')
}

# ---- THE OTHER TAIL (2026-08-08) -------------------------------------------------------------------------
# Find-BasisOutliers only ever looks UPWARD: it flags a row at or above $Ratio x the median, i.e. one that
# looks too EXPENSIVE. An expensive outlier is real but harmless - it never takes the cheapest slot, so it
# never reaches a reader. The damaging direction is the opposite one, and this audit was structurally blind
# to it while not being wired into the chain at all.
#
# MEASURED, the case that exposed both holes: baby-formula's crown is Walmart at $0.686/oz, taken from a
# 15.991 FL OZ ready-to-feed liquid, while the other five stores are powder canisters (48, 34, 33.2, 12.5,
# 12.4 oz). Powder makes roughly seven times its weight in prepared formula, so the cheapest-baby-formula
# verdict a reader sees is backwards. That row sits at 0.56x the median - nowhere near 4x - so no ratio
# threshold in either direction would find it without also flagging every genuine deep sale.
#
# So the rule is NOT "cheap". Cheap is what a sale looks like. The rule is that this row's size names a
# different KIND of quantity than its shelf-mates: a volume among weights, on a commodity priced by weight.
# That is a statement about the data, not an inference from a ratio, which is the same standard the
# size-shape mismatch above is held to. Magnitude does not enter into it.
function Get-MeasureKind([string]$size) {
  if (-not $size) { return 'unknown' }
  if ($size -imatch '\bfl\.?\s*oz|\bfluid\b|\bml\b|\blitre|\bliter\b|\bgal(lon)?\b|\bqt\b|\bquart\b|\bpt\b|\bpint\b') { return 'volume' }
  if ($size -imatch '\boz\b|\bounce|\blb\b|\bpound|\bg\b|\bgram|\bkg\b')                                             { return 'weight' }
  if ($size -imatch '\bct\b|\bcount\b|\beach\b|\bea\b|\bpk\b|\bpack\b|\broll')                                       { return 'count'  }
  return 'unknown'
}

# WHICH KIND OF QUANTITY THE ENGINE ACTUALLY DIVIDED BY (2026-09-03, queue 2026-09-03-83b57e).
# Pure and declared beside Get-MeasureKind so a fixture can reach it without a board. The row's `unit` field
# is the divisor compare-deals used, so this is the ONLY reference that says whether a cell's own label
# agrees with its own arithmetic. Find-MeasureKindMismatch still ELECTS the row basis from the peer label
# majority (see $major below) and the gate still fires on exactly that; this function only lets a finding
# SAY which reference it failed. Arming the gate on this reference instead takes it from hard=1 to hard=11
# in one day, which is booked as deferred work (plan-2026-09-03 deferred_findings) and is deliberately not
# done here: a gate that fails from day one is a gate that gets switched off.
function Get-UnitKind([string]$unit) {
  if (-not $unit) { return 'unknown' }
  if ($unit -imatch '^\s*(floz|fl\.?\s*oz)\s*$') { return 'volume' }
  if ($unit -imatch '^\s*(oz|lb)\s*$')           { return 'weight' }
  return 'unknown'
}

function Find-MeasureKindMismatch {
  param([object[]]$Rows, [int]$MinStores = 3)
  $out = @()
  foreach ($r in $Rows) {
    $unit = [string]$r.unit
    # only weight/volume commodities: a per-each commodity legitimately mixes shapes
    if ($unit -notmatch '^(oz|lb|floz|fl oz)$') { continue }
    # THE CROWN IS DECIDED OVER EVERY PRICED CELL, not just the ones carrying a size. Filtering first and
    # then taking the minimum reports "holds the crown" against the cheapest SIZED row, which is a different
    # question: oven-cleaner's real crown is a Hy-Vee cell with no size string, so Walmart was named as
    # holding a crown it does not hold. Only the sized rows can be CLASSIFIED, but the ranking is the row's.
    $allPriced = @($r.stores | Where-Object { [double]$_.per_unit -gt 0 })
    $priced = @($allPriced | Where-Object { $_.size })
    if (@($priced).Count -lt $MinStores) { continue }
    $kinds = @{}
    foreach ($s in $priced) { $k = Get-MeasureKind ([string]$s.size); if (-not $kinds.ContainsKey($k)) { $kinds[$k] = 0 }; $kinds[$k]++ }
    $known = @($kinds.Keys | Where-Object { $_ -ne 'unknown' })
    if (@($known).Count -lt 2) { continue }                    # everybody agrees, nothing to say
    # the majority kind is the row's basis; anything else is measured in a different currency
    $major = ($known | Sort-Object { -$kinds[$_] } | Select-Object -First 1)
    # who holds the crown? that is the only cell whose basis error changes the published answer
    $cheapest = ($allPriced | Sort-Object { [double]$_.per_unit } | Select-Object -First 1)
    $unitKind = Get-UnitKind $unit
    foreach ($s in $priced) {
      $k = Get-MeasureKind ([string]$s.size)
      if ($k -eq 'unknown' -or $k -eq $major) { continue }
      $out += [pscustomobject]@{
        id = [string]$r.id; commodity = [string]$r.commodity; unit = $unit
        store = [string]$s.store; per_unit = [double]$s.per_unit
        size = [string]$s.size; item = [string]$s.item
        kind = $k; row_kind = $major
        holds_crown = ([string]$s.store -eq [string]$cheapest.store)
        # unit_kind is the kind the ENGINE divided by; agrees_with_engine_divisor says whether this cell's
        # own label matches its own arithmetic. TRUE means the cell is right and the peer majority is what
        # accused it (the inverted-reference arm, which is what stopped the board on 2026-09-03). FALSE is
        # the real class this guard was built for: a cell divided in a currency its label does not name.
        unit_kind = $unitKind
        agrees_with_engine_divisor = ($k -eq $unitKind)
      }
    }
  }
  return ,@($out)
}

function Find-BasisOutliers {
  param([object[]]$Rows, [double]$Ratio = 4.0, [int]$MinStores = 4)
  $out = @()
  foreach ($r in $Rows) {
    $priced = @($r.stores | Where-Object { [double]$_.per_unit -gt 0 })
    if (@($priced).Count -lt $MinStores) { continue }
    $vals = @($priced | ForEach-Object { [double]$_.per_unit } | Sort-Object)
    $mid  = $vals[[int]([math]::Floor($vals.Count / 2))]
    if ($mid -le 0) { continue }
    foreach ($s in $priced) {
      $pu = [double]$s.per_unit
      $mult = $pu / $mid
      if ($mult -lt $Ratio) { continue }
      # THE STRONGEST SIGNAL IS NOT THE ARITHMETIC, IT IS THE SIZE SHAPE.
      # A first draft of this audit tried to read the pack count out of the multiple, on the theory that a
      # pack price over one unit lands on a whole multiple of the real rate. It does not: stores genuinely
      # differ on price, so the founding case came out at 20.52x for a 24-pack. Reporting "pack of 21"
      # would have been invented precision of exactly the kind this board exists to avoid.
      # What IS checkable: on the founding row every other store recorded "24 x 16.9 fl oz" and Aldi
      # recorded "16.9 fl oz". An outlier whose size carries NO pack form while its shelf-mates do is the
      # pack-price-on-a-unit-size shape, stated from the data rather than inferred from a ratio.
      $peers = @($priced | Where-Object { [string]$_.store -ne [string]$s.store })
      $peersPacked = @($peers | Where-Object { Test-PackShape ([string]$_.size) }).Count
      $selfPacked = Test-PackShape ([string]$s.size)
      $shapeMismatch = ((-not $selfPacked) -and @($peers).Count -ge 2 -and ($peersPacked / [double]@($peers).Count) -ge 0.5)
      $out += [pscustomobject]@{
        id = [string]$r.id; commodity = [string]$r.commodity; unit = [string]$r.unit
        store = [string]$s.store; per_unit = $pu; median = $mid
        mult = [math]::Round($mult, 2)
        size = [string]$s.size; item = [string]$s.item
        peers_packed = ("{0} of {1}" -f $peersPacked, @($peers).Count)
        size_shape_mismatch = $shapeMismatch
      }
    }
  }
  return ,@($out)
}

if ($SelfTest) {
  # FROZEN FIXTURES. Hand-written, never regenerated from the live board (guard-fixture rule).
  # MUST-FIRE 1 is the founding case: PurAqua at Aldi, a 24-pack price on a one-bottle size.
  $mustFire = @(
    [pscustomobject]@{ id='bottled-water'; commodity='Bottled Water'; unit='floz'; stores=@(
      [pscustomobject]@{ store='Walmart';     per_unit=0.0079; size='24 x 16.9 fl oz'; item='Great Value Water' }
      [pscustomobject]@{ store='Hy-Vee';      per_unit=0.0089; size='24 x 16.9 fl oz'; item='Hy-Vee Water' }
      [pscustomobject]@{ store="Baker's";     per_unit=0.0092; size='24 x 16.9 fl oz'; item='Kroger Water' }
      [pscustomobject]@{ store='Family Fare'; per_unit=0.0095; size='24 x 16.9 fl oz'; item='OF Water' }
      # the bug: $3.19 pack price over ONE 16.9 fl oz bottle = 0.1888/fl oz, ~21x the median
      [pscustomobject]@{ store='Aldi';        per_unit=0.1888; size='16.9 fl oz';      item='Puraqua Purified Water 16.9 FL OZ' }
    )}
  )
  # MUST-FIRE 2 is the mirror: a 12-pack popcorn price on a single 2.5 oz bag.
  $mustFire += [pscustomobject]@{ id='microwave-popcorn'; commodity='Microwave Popcorn'; unit='oz'; stores=@(
      [pscustomobject]@{ store='Walmart';     per_unit=0.150; size='12 x 2.5 oz'; item='GV Popcorn' }
      [pscustomobject]@{ store='Hy-Vee';      per_unit=0.163; size='12 x 2.5 oz'; item='Hy-Vee Popcorn' }
      [pscustomobject]@{ store="Baker's";     per_unit=0.171; size='12 x 2.5 oz'; item='Kroger Popcorn' }
      [pscustomobject]@{ store='Family Fare'; per_unit=0.180; size='12 x 2.5 oz'; item='OF Popcorn' }
      [pscustomobject]@{ store='Aldi';        per_unit=1.796; size='2.5 oz';      item='Clancy S Movie Theater Butter Microwave Popcorn 2.5 OZ' }
    )}
  # CLEAN TWINS. These must stay silent or the audit is useless noise.
  $clean = @(
    # ordinary price spread across seven stores: dearest is under 2x the median
    [pscustomobject]@{ id='whole-milk'; commodity='Milk'; unit='gallon'; stores=@(
      [pscustomobject]@{ store='Aldi'; per_unit=2.29 }, [pscustomobject]@{ store='Walmart'; per_unit=2.48 }
      [pscustomobject]@{ store='Hy-Vee'; per_unit=2.99 }, [pscustomobject]@{ store="Baker's"; per_unit=3.19 }
      [pscustomobject]@{ store='Fareway'; per_unit=3.29 }, [pscustomobject]@{ store='Family Fare'; per_unit=3.49 }
    )}
    # a genuinely premium outlier that is still under the threshold: 3.1x must NOT fire at 4x
    [pscustomobject]@{ id='olive-oil'; commodity='Olive Oil'; unit='floz'; stores=@(
      [pscustomobject]@{ store='Aldi'; per_unit=0.21 }, [pscustomobject]@{ store='Walmart'; per_unit=0.24 }
      [pscustomobject]@{ store='Hy-Vee'; per_unit=0.27 }, [pscustomobject]@{ store="Baker's"; per_unit=0.31 }
      [pscustomobject]@{ store='Fareway'; per_unit=0.84 }
    )}
    # THIN ROW: a huge multiple on only three priced stores must NOT fire - the median is not yet meaningful
    [pscustomobject]@{ id='saffron'; commodity='Saffron'; unit='oz'; stores=@(
      [pscustomobject]@{ store='Aldi'; per_unit=1.00 }, [pscustomobject]@{ store='Hy-Vee'; per_unit=1.20 }
      [pscustomobject]@{ store='Walmart'; per_unit=40.0 }
    )}
  )
  $bad = 0
  $f1 = Find-BasisOutliers -Rows $mustFire -Ratio $Ratio -MinStores $MinStores
  foreach ($id in @('bottled-water','microwave-popcorn')) {
    $hit = @($f1 | Where-Object { $_.id -eq $id -and $_.store -eq 'Aldi' })
    if (@($hit).Count -ne 1) { Write-Output ("  X MUST-FIRE: $id did not flag Aldi (found " + @($hit).Count + ")"); $bad++ ; continue }
    # the SHAPE mismatch is the assertion that matters: every peer records a pack form, this row does not
    if (-not $hit[0].size_shape_mismatch) { Write-Output ("  X MUST-FIRE: $id flagged on arithmetic but missed the size-shape tell (peers_packed=" + $hit[0].peers_packed + ", size='" + $hit[0].size + "')"); $bad++ }
  }
  $f2 = Find-BasisOutliers -Rows $clean -Ratio $Ratio -MinStores $MinStores
  if (@($f2).Count -ne 0) {
    foreach ($c in $f2) { Write-Output ("  X CLEAN TWIN fired: " + $c.commodity + " / " + $c.store + " at " + $c.mult + "x") }
    $bad += @($f2).Count
  }
  # ---- the OTHER tail: measure-kind mismatch ----
  # MUST FIRE, frozen from the live 2026-08-08 board: baby-formula's crown is a ready-to-feed LIQUID priced
  # per weight oz against five powder canisters. It sits at 0.56x the median, so no ratio rule can see it.
  $kindFire = @(
    [pscustomobject]@{ id='baby-formula'; commodity='Baby Formula'; unit='oz'; stores=@(
      [pscustomobject]@{ store='Walmart';    per_unit=0.686;  size='15.991 fl oz'; item='Similac 360 Ready-to-Feed' }
      [pscustomobject]@{ store="Sam's Club"; per_unit=0.7704; size='48 oz';        item="Member's Mark powder" }
      [pscustomobject]@{ store="Baker's";    per_unit=0.9409; size='34 oz';        item='Comforts powder' }
      [pscustomobject]@{ store='Family Fare';per_unit=1.2346; size='33.2 oz';      item='Tippy Toes powder' }
      [pscustomobject]@{ store='Hy-Vee';     per_unit=1.6776; size='12.5 oz';      item='Enfamil powder' }
      [pscustomobject]@{ store='Fareway';    per_unit=1.7734; size='12.4 oz';      item='Similac powder' }
    )}
  )
  $k1 = Find-MeasureKindMismatch -Rows $kindFire
  $kh = @($k1 | Where-Object { $_.id -eq 'baby-formula' -and $_.store -eq 'Walmart' })
  if (@($kh).Count -ne 1) { Write-Output ("  X MUST-FIRE: baby-formula did not flag Walmart's volume row (found " + @($kh).Count + ")"); $bad++ }
  else {
    if ($kh[0].kind -ne 'volume' -or $kh[0].row_kind -ne 'weight') { Write-Output ("  X MUST-FIRE: wrong kinds (" + $kh[0].kind + " vs row " + $kh[0].row_kind + ")"); $bad++ }
    # holding the crown is what makes it reach a reader - that is the field the report ranks on
    if (-not $kh[0].holds_crown) { Write-Output '  X MUST-FIRE: the mismatched row holds the crown and was not marked as such'; $bad++ }
  }
  # the EXISTING baby-formula fixture is also the CLEAN TWIN for the new reference fields: its unit is 'oz'
  # (weight) and the flagged cell is a fl oz liquid, so it is the REAL class this guard was built for and must
  # report agrees_with_engine_divisor FALSE. If this ever reads true the new field has inverted the class.
  if (@($kh).Count -eq 1) {
    if ($kh[0].unit_kind -ne 'weight') { Write-Output ("  X MUST-FIRE: baby-formula unit_kind should be weight (unit 'oz'), got '" + $kh[0].unit_kind + "'"); $bad++ }
    if ($kh[0].agrees_with_engine_divisor) { Write-Output '  X MUST-FIRE: baby-formula ready-to-feed liquid must NOT agree with its engine divisor - the new field has inverted the founding class'; $bad++ }
  }

  # ---- THE INVERTED REFERENCE (2026-09-03, queue 2026-09-03-83b57e) ----
  # FROZEN BY HAND from the real comparison-2026-09-02 teriyaki-sauce row and NEVER regenerated from the
  # board: the fix is an allowlist entry, so a regenerated fixture would encode the silence and pass by
  # finding nothing. The row's DECLARED unit is floz, but 4 of its 6 sized peers label their bottles by net
  # weight oz, so the peer-majority reference elects 'weight' and accuses the one cell whose label matches
  # the divisor compare-deals actually used. That cell holds the crown, which is why the board stopped.
  $kindInverted = @(
    [pscustomobject]@{ id='teriyaki-sauce'; commodity='Teriyaki Sauce / Marinade'; unit='floz'; stores=@(
      [pscustomobject]@{ store='Walmart';    per_unit=0.1653; size='15 fl oz'; item='Great Value Teriyaki Sauce, 15 fl oz, 1 Count' }
      [pscustomobject]@{ store="Sam's Club"; per_unit=0.1738; size='27.5 oz';  item='Kinder''s Teriyaki Marinade Sauce, 27.5 oz.' }
      [pscustomobject]@{ store="Baker's";    per_unit=0.1856; size='21.5 oz';  item='Kikkoman Gochujang Spicy Miso Teriyaki Sauce' }
      [pscustomobject]@{ store='Fareway';    per_unit=0.2181; size='16 fl oz'; item='Sweet Baby Ray''s Honey Teriyaki Sauce and Marinade' }
      [pscustomobject]@{ store='Family Fare';per_unit=0.2290; size='10 oz';    item='Teriyaki Sauce Our Family' }
      [pscustomobject]@{ store='Hy-Vee';     per_unit=0.2376; size='21 oz';    item='Soy Vay Marinade and Sauce, Less Sodium, Veri Veri Teriyaki' }
    )}
  )
  $k3 = Find-MeasureKindMismatch -Rows $kindInverted
  $ki = @($k3 | Where-Object { $_.id -eq 'teriyaki-sauce' -and $_.store -eq 'Walmart' })
  if (@($ki).Count -ne 1) { Write-Output ("  X MUST-FIRE: teriyaki-sauce did not flag Walmart's 15 fl oz crown (found " + @($ki).Count + ")"); $bad++ }
  else {
    if (-not $ki[0].holds_crown) { Write-Output '  X MUST-FIRE: the teriyaki Walmart cell holds the crown and was not marked as such'; $bad++ }
    if ($ki[0].kind -ne 'volume' -or $ki[0].row_kind -ne 'weight') { Write-Output ("  X MUST-FIRE: teriyaki kinds wrong (" + $ki[0].kind + " vs row " + $ki[0].row_kind + ")"); $bad++ }
    # THESE TWO ASSERTIONS ARE UNSATISFIABLE BEFORE THE 2026-09-03 CHANGE, which is what makes this fixture
    # able to REACH the new code rather than pass by finding nothing.
    if ($ki[0].unit_kind -ne 'volume') { Write-Output ("  X MUST-FIRE: teriyaki unit_kind should be volume (unit 'floz'), got '" + $ki[0].unit_kind + "'"); $bad++ }
    if (-not $ki[0].agrees_with_engine_divisor) { Write-Output '  X MUST-FIRE: the teriyaki Walmart cell DOES agree with its engine divisor (15 fl oz on a floz row) and must be reported as such'; $bad++ }
  }
  # THE 08-31 SHAPE, same six cells with Baker's back at 'Subway Sweet Onion Teriyaki Sauce' 16 fl oz. That
  # makes the label tally 3-3 and NO crown finding is produced, which is why the identical Walmart crown was
  # green on 08-30 and 08-31. This pins the claim that a single peer product swap flipped the gate verdict
  # while nothing about the accused cell moved.
  $kindTie = @(
    [pscustomobject]@{ id='teriyaki-sauce'; commodity='Teriyaki Sauce / Marinade'; unit='floz'; stores=@(
      [pscustomobject]@{ store='Walmart';    per_unit=0.1653; size='15 fl oz'; item='Great Value Teriyaki Sauce, 15 fl oz, 1 Count' }
      [pscustomobject]@{ store="Sam's Club"; per_unit=0.1738; size='27.5 oz';  item='Kinder''s Teriyaki Marinade Sauce, 27.5 oz.' }
      [pscustomobject]@{ store="Baker's";    per_unit=0.1856; size='16 fl oz'; item='Subway Sweet Onion Teriyaki Sauce' }
      [pscustomobject]@{ store='Fareway';    per_unit=0.2181; size='16 fl oz'; item='Sweet Baby Ray''s Honey Teriyaki Sauce and Marinade' }
      [pscustomobject]@{ store='Family Fare';per_unit=0.2290; size='10 oz';    item='Teriyaki Sauce Our Family' }
      [pscustomobject]@{ store='Hy-Vee';     per_unit=0.2376; size='21 oz';    item='Soy Vay Marinade and Sauce, Less Sodium, Veri Veri Teriyaki' }
    )}
  )
  $k4 = Find-MeasureKindMismatch -Rows $kindTie
  $kt = @($k4 | Where-Object { $_.holds_crown })
  if (@($kt).Count -ne 0) {
    foreach ($c in $kt) { Write-Output ("  X 08-31 TIE SHAPE produced a crown finding: " + $c.commodity + " / " + $c.store + " (" + $c.kind + " vs row " + $c.row_kind + ")") }
    $bad += @($kt).Count
  }

  # the ratio detector must STILL be blind to it, which is the whole reason this second rule exists
  # ASSIGN FIRST, then wrap. These finders `return ,@($out)` to keep a single finding from unrolling into a
  # bare object, and on an EMPTY result that wrapper survives: @(Find-BasisOutliers ...) counts 1, whose one
  # element is an empty array, so an inline call reads "fired" when nothing fired. Assigning unrolls the
  # wrapper first, which is why every existing call in this file goes through a variable. Cost me a red
  # self-test that was correct about the code and wrong about the fixture.
  $ratioOnKind = Find-BasisOutliers -Rows $kindFire -Ratio $Ratio -MinStores $MinStores
  if (@($ratioOnKind).Count -ne 0) {
    Write-Output ("  X the ratio rule fired on baby-formula ({0} finding(s)); the fixture no longer proves the gap it was frozen for" -f @($ratioOnKind).Count); $bad++
  }
  # CLEAN TWIN: every store measured the same way, however wide the price spread
  $kindClean = @(
    [pscustomobject]@{ id='ketchup'; commodity='Ketchup'; unit='oz'; stores=@(
      [pscustomobject]@{ store='Aldi'; per_unit=0.05; size='20 oz' }, [pscustomobject]@{ store='Walmart'; per_unit=0.06; size='32 oz' }
      [pscustomobject]@{ store='Hy-Vee'; per_unit=0.19; size='14 oz' }, [pscustomobject]@{ store='Fareway'; per_unit=0.22; size='24 oz' }
    )}
    # a per-EACH commodity legitimately mixes shapes and must never be flagged
    [pscustomobject]@{ id='paper-towels'; commodity='Paper Towels'; unit='each'; stores=@(
      [pscustomobject]@{ store='Aldi'; per_unit=1.0; size='6 rolls' }, [pscustomobject]@{ store='Walmart'; per_unit=1.1; size='12 fl oz' }
      [pscustomobject]@{ store='Hy-Vee'; per_unit=1.2; size='8 oz' }, [pscustomobject]@{ store='Fareway'; per_unit=1.3; size='2 ct' }
    )}
  )
  $k2 = Find-MeasureKindMismatch -Rows $kindClean
  if (@($k2).Count -ne 0) {
    foreach ($c in $k2) { Write-Output ("  X CLEAN TWIN fired: " + $c.commodity + " / " + $c.store + " (" + $c.kind + " vs " + $c.row_kind + ")") }
    $bad += @($k2).Count
  }

  # ---- the allowlist must be keyed to the reviewed SIZE, not to the store ----
  function TKA { param($F, $Allow)
    foreach ($a in @($Allow)) { if ($a.id -eq $F.id -and $a.store -eq $F.store -and [string]$a.size -eq [string]$F.size) { return $true } }
    return $false
  }
  $al = @([pscustomobject]@{ id='pickles'; store="Sam's Club"; size='126.8 oz' })
  $f  = [pscustomobject]@{ id='pickles'; store="Sam's Club"; size='126.8 oz' }
  if (-not (TKA $f $al)) { Write-Output '  X a reviewed mismatch was not silenced'; $bad++ }
  # the size is part of the key: a NEW size on the same cell has not been reviewed and must fire again
  $f2 = [pscustomobject]@{ id='pickles'; store="Sam's Club"; size='64 fl oz' }
  if (TKA $f2 $al) { Write-Output '  X MUST-FIRE: a DIFFERENT size on an allowlisted cell was silenced - that is a blanket per-store silence'; $bad++ }
  $f3 = [pscustomobject]@{ id='ranch-dressing'; store="Sam's Club"; size='126.8 oz' }
  if (TKA $f3 $al) { Write-Output '  X MUST-FIRE: the same size on another commodity was silenced'; $bad++ }

  if ($bad -eq 0) { Write-Output 'audit-unit-basis-outlier SELF-TEST PASS (4 must-fire, 6 clean twins, both tails, both references, allowlist keyed to the size)'; exit 0 }
  Write-Output ("audit-unit-basis-outlier SELF-TEST FAIL ($bad)"); exit 2
}

# ---- live run ----
$OutDir = Join-Path $root 'out'
if (-not $CompareFile) {
  $cmp = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $cmp) { Write-Output 'BLIND: no comparison-*.json to audit'; exit 3 }
  $CompareFile = $cmp.FullName
}
$doc = Get-Content $CompareFile -Raw | ConvertFrom-Json
$rows = @($doc.comparison)
if (-not $rows.Count) { Write-Output 'BLIND: comparison file has no rows'; exit 3 }

$findings = Find-BasisOutliers -Rows $rows -Ratio $Ratio -MinStores $MinStores
$eligible = @($rows | Where-Object { @($_.stores | Where-Object { [double]$_.per_unit -gt 0 }).Count -ge $MinStores }).Count
if ($eligible -eq 0) { Write-Output ("BLIND: no row had $MinStores+ priced stores, so no median could be formed"); exit 3 }

# rank by how integer-clean the multiple is, then by size: a near-whole multiple is the strongest signal
# that the number is a pack count rather than a genuinely dearer product.
$ranked = @($findings | Sort-Object @{e={-not $_.size_shape_mismatch}}, @{e={-$_.mult}})
Write-Output ("audit-unit-basis-outlier: $($rows.Count) rows, $eligible with $MinStores+ priced stores, $(@($findings).Count) at or above $($Ratio)x the row median")
foreach ($f in ($ranked | Select-Object -First 25)) {
  $tag = if ($f.size_shape_mismatch) { 'PACK-SHAPE MISMATCH' } else { 'wide spread      ' }
  Write-Output ("  [{0}] {1,-24} {2,-12} {3}x median  {4} vs {5}  size='{6}' (peers packed {7})  {8}" -f $tag, $f.commodity, $f.store, $f.mult, ('{0:N4}' -f $f.per_unit), ('{0:N4}' -f $f.median), $f.size, $f.peers_packed, $f.item)
}
$nearInt = @($findings | Where-Object { $_.size_shape_mismatch })
if (@($ranked).Count -gt 25) { Write-Output ("  ... and " + (@($ranked).Count - 25) + " more (nothing is truncated silently: rerun with -Ratio to widen or narrow)") }
# ---- the other tail: rows measured in a different currency from their shelf-mates ----
# The allowlist is keyed on commodity + store + the exact SIZE STRING reviewed, not on the store or the
# commodity alone. A per-store silence would switch the check off for that cell permanently, so the next,
# different mismatch there would never be seen - the same contested-flag rule the rest of the estate runs on.
$kinds = Find-MeasureKindMismatch -Rows $rows
$kindAllow = @()
$allowPath = Join-Path $root 'basis-kind-allowlist.json'
if (Test-Path $allowPath) { try { $kindAllow = @((Get-Content $allowPath -Raw | ConvertFrom-Json).allow) } catch { } }
function Test-KindAllowed { param($F, $Allow)
  foreach ($a in @($Allow)) {
    if ($a.id -eq $F.id -and $a.store -eq $F.store -and [string]$a.size -eq [string]$F.size) { return $true }
  }
  return $false
}
$kindReviewed = @($kinds | Where-Object { $_.holds_crown -and (Test-KindAllowed $_ $kindAllow) })
$kindCrown = @($kinds | Where-Object { $_.holds_crown -and -not (Test-KindAllowed $_ $kindAllow) })
Write-Output ''
Write-Output ("measure-kind mismatch: {0} priced cell(s) across {1} commodit(y/ies) are sized in a different KIND of quantity than their shelf-mates; {2} hold the crown UNREVIEWED ({3} crown-holder(s) reviewed and allowed)" -f `
  @($kinds).Count, (@($kinds | ForEach-Object { $_.id } | Sort-Object -Unique)).Count, @($kindCrown).Count, @($kindReviewed).Count)
foreach ($f in ($kindCrown | Sort-Object commodity)) {
  Write-Output ("  [CROWN ON A {0} ROW] {1,-24} {2,-12} {3} /{4}  size='{5}'  (row is priced by {6})  {7}" -f `
    $f.kind.ToUpper(), $f.commodity, $f.store, ('{0:N4}' -f $f.per_unit), $f.unit, $f.size, $f.row_kind, $f.item)
  Write-Output ("      reference: label says {0}, engine divided by {1} (unit '{2}') -> agrees_with_engine_divisor={3}{4}" -f `
    $f.kind, $f.unit_kind, $f.unit, $f.agrees_with_engine_divisor, `
    $(if ($f.agrees_with_engine_divisor) { '  <- THIS CELL AGREES WITH ITS OWN DIVISOR; it was accused by the PEER LABEL MAJORITY' } else { '' }))
}
if (@($kindCrown).Count) {
  Write-Output '  These publish the cheapest verdict from a cell measured in a different currency than the row it wins.'
  Write-Output '  Fix per commodity: exclude the mismatched FORM, split the commodity, or convert the size properly.'
}

# WHICH REFERENCE DID EACH FINDING FAIL? (2026-09-03, queue 2026-09-03-83b57e)
# The gate above elects the row basis from the PEER LABEL MAJORITY. That reference is inverted on any
# commodity whose declared unit is the minority label among its own sized cells, and on those rows the
# verdict turns on a label tally any single product swap can flip - which is exactly what stopped the board
# on 2026-09-03 (teriyaki-sauce went volume=3/weight=3 to 2-4 when Baker's cell changed product). So report
# BOTH arms, ranked, and let a reader see which one a finding is in. Reporting only; no verdict changes.
$kindDisagreesUnit = @($kinds | Where-Object { -not $_.agrees_with_engine_divisor } | Sort-Object @{e={-$_.holds_crown}}, commodity, store)
$kindAgreesUnit    = @($kinds | Where-Object {      $_.agrees_with_engine_divisor } | Sort-Object @{e={-$_.holds_crown}}, commodity, store)
Write-Output ''
Write-Output ("  reference split of all {0} kind finding(s): {1} label DISAGREES with the row's declared unit (can actually be mis-divided), {2} AGREE with the declared unit but not the peer majority (the inverted-reference arm)" -f `
  @($kinds).Count, @($kindDisagreesUnit).Count, @($kindAgreesUnit).Count)
foreach ($arm in @(
    @{ label = "LABEL DISAGREES WITH DECLARED UNIT (mis-divided candidates)"; set = $kindDisagreesUnit },
    @{ label = "AGREES WITH DECLARED UNIT, ACCUSED BY PEER MAJORITY (inverted reference)"; set = $kindAgreesUnit })) {
  $crowns = @($arm.set | Where-Object { $_.holds_crown })
  Write-Output ("  -- {0}: {1} cell(s), {2} holding a crown" -f $arm.label, @($arm.set).Count, @($crowns).Count)
  foreach ($f in ($crowns | Select-Object -First 15)) {
    Write-Output ("       {0,-26} {1,-12} {2} /{3}  size='{4}'  label={5} unit_kind={6}  {7}" -f `
      $f.commodity, $f.store, ('{0:N4}' -f $f.per_unit), $f.unit, $f.size, $f.kind, $f.unit_kind, $f.item)
  }
  if (@($crowns).Count -gt 15) { Write-Output ("       ... and " + (@($crowns).Count - 15) + " more crown-holder(s) in this arm (full list in basis-outliers.json)") }
}

$outFile = Join-Path $OutDir 'basis-outliers.json'
@{ generated = (Get-Date).ToString('s'); compare_file = (Split-Path $CompareFile -Leaf); ratio = $Ratio; min_stores = $MinStores
   findings = @($ranked); kind_mismatch = @($kinds); kind_mismatch_crown = @($kindCrown)
   kind_mismatch_label_vs_declared_unit = @($kindDisagreesUnit)
   kind_mismatch_agrees_unit_not_majority = @($kindAgreesUnit) } |
  ConvertTo-Json -Depth 6 | Set-Content $outFile -Encoding UTF8
Write-Output ("  -> $outFile   ($(@($nearInt).Count) with the pack-shape mismatch, which is the pack-price-on-a-unit-size fingerprint)")
Write-GuardComplete -Name 'unit-basis-outlier' -Summary ("ratio={0} kind={1} crown={2} reviewed={3}" -f @($findings).Count, @($kinds).Count, @($kindCrown).Count, @($kindReviewed).Count)
# EXIT 2 (hard) only for an UNREVIEWED crown mismatch, never for the ratio findings, which stay advisory as
# this file was always designed to be. The distinction is what makes it safe to gate on: a ratio outlier is a
# product that looks dear and takes nothing, while a crown held by a cell measured in a different currency is
# a wrong cheapest-verdict on the page. It is armed at ZERO today (butter's syrup and baby-formula's
# ready-to-feed were fixed at the commodity rule, the remaining six are reviewed in basis-kind-allowlist.json),
# which is this estate's stated bar for promoting a ratchet to a gate - a gate that fails from day one is a
# gate that gets switched off. A false positive costs one allowlist entry with a written reason.
exit $(if (@($kindCrown).Count) { 2 } else { 0 })
