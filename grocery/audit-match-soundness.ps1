<#
  audit-match-soundness.ps1 - STANDING guard for the commodity MATCHING logic (the class of bug the
  2026-07-13 audit found: a WRONG product silently landing in a commodity, or a rule change quietly
  moving/dropping an existing product). None of the other guards catch this.

  It rebuilds every store product's commodity assignment with an engine-FAITHFUL replica of
  compare-deals Match-Category, then:
    * REGRESSION: compares to a committed known-good baseline (out\audit\match-baseline.json). Any product
      NAME that used to map to commodity A and now maps to B (MOVED) or to nothing (DROPPED) is a
      rule-change effect a human must review. Exit 2 (so publish HOLDS) if there are un-accepted changes.
    * SOUNDNESS: flags products where >1 commodity's include is eligible (order-dependence / theft risk)
      that are not already in the baseline's reviewed contested list. Advisory.
    * SELF-CHECK: asserts this matcher still agrees with the real engine's candidates-*.json (0
      disagreements). If it drifts, it says so instead of trusting itself.

  Modes:  (default)  report + exit 2 on un-accepted regressions, else 0
          -Accept    bless the CURRENT state as the new baseline (run after an intended rule change)
          -Alert     send-alert.ps1 once per NEW issue-set (signature de-dup) - for the daily pipeline
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$Accept, [switch]$Alert, [string]$OutDir = "",
  # -ForceAccept: bless the baseline EVEN OVER outstanding DROP verdicts. The gate below exists because
  # -Accept used to be a rubber stamp: on 2026-07-29 it baselined "Smithfield ... Pork Loin Filet -> bacon"
  # and "Member's Mark Broccoli Normandy -> broccoli" AFTER the verify pass had already rejected both, which
  # made them permanently invisible to this audit - and they published as crowns. Forcing must be a loud,
  # deliberate act, never the default.
  [switch]$ForceAccept,
  # -SelfTest: this guard had NONE until 2026-09-05, which is why the drift check could count seven
  # disagreements and name none of them for a whole day without anything noticing.
  [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
# Alerts go out through Send-Alert (alert-lib.ps1), never as `powershell -File send-alert.ps1 -Body $long`:
# Windows refuses to start a process whose command line passes 32767 chars, so an oversized body did not
# arrive truncated - it did not arrive at all, and the launch error read like the CHECK had crashed. Three
# consecutive guard-blind days went unpaged that way on 2026-08-03/04/05. See alert-lib.ps1.
. (Join-Path $root 'alert-lib.ps1')

function Get-DriftRows {
  <#
    WHERE THIS MATCHER AND THE ENGINE DISAGREE, BY NAME - not just how many.

    Pure, and a parameter rather than a file read, so the rule can be driven by a fixture instead of
    by whatever candidates-*.json happens to be on disk. It was inline and counted only: on
    2026-09-05 it reported "matcher disagrees with the engine on 7 products - investigate" and gave
    the reader nothing to investigate WITH, and naming them from outside would have meant a second
    copy of Get-Eligible, which is the rule this estate keeps in exactly one file.

    `<unmatched>` counts as a disagreement on purpose: a product the engine assigned to a commodity
    and this matcher now assigns to nothing is precisely the rule improvement (or regression) worth
    seeing - all seven on 2026-09-05 were that shape, and all seven were the matcher being RIGHT
    against a candidates file from the previous board week.
  #>
  param($Names, $Commodities)
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($cm in @($Commodities)) {
    foreach ($cd in @($cm.candidates)) {
      $nm = [string]$cd.name
      if ($Names.ContainsKey($nm) -and [string]$Names[$nm] -ne [string]$cm.id) {
        $out.Add([pscustomobject]@{ name = $nm; engine = [string]$cm.id; matcher = [string]$Names[$nm] })
      }
    }
  }
  return $out
}


function Get-CellNames {
  <#
    The product NAME on EVERY store cell of a comparison - not only the cheapest one - mapped to a
    readable description of the cell it holds and whether that cell is the crown.

    Was Get-CrownNames until 2026-09-08 (queue 2026-09-08-2e59b3), and the crown-only reader was SILENT
    on the founding case of that round: 'Fareway Steamables Green Beans', a frozen 12 oz microwave bag,
    held Fareway's fresh-green-beans cell at 1.92/lb while the CROWN sat at Walmart on 1.6201/lb. A
    wrong product does not have to be the cheapest in Omaha to be wrong on the board; it only has to
    hold a cell a reader will price a shop from. Reading cheapest_store made that half of the class
    invisible, and it is the half that had already been accepted into the baseline.

    A PARAMETER rather than a file read, so the CELL-BY-CONTEST cases in -SelfTest can be driven by a
    frozen board slice. The whole point of the class is a wrong product that HELD a cell, and the
    exclude that ships the same day removes that product from today's board - so a check that could
    only read live data could never fire, which is the defect this estate keeps paying for (see
    grocery\test-capture-builders.ps1's BLIND branch).

    A CROWN WINS A TIE: one product name can sit on several rows or stores. If any of them is the
    crown, the entry records the crown, because that is the more expensive finding and the one the
    2026-09-07 BELVITA case is about.
  #>
  param($Comparison)
  $out = @{}
  foreach ($r in @($Comparison)) {
    $cs = [string]$r.cheapest_store
    foreach ($s in @($r.stores)) {
      $itm = [string]$s.item
      if (-not $itm) { continue }
      $isCrown = ([bool]$cs -and ([string]$s.store -eq $cs))
      if ($out.ContainsKey($itm) -and $out[$itm].crown -and -not $isCrown) { continue }
      $out[$itm] = [pscustomobject]@{
        text  = ([string]$r.id + ' @ ' + [string]$s.store + ' ' + [string]$s.per_unit + '/' + [string]$r.unit)
        crown = [bool]$isCrown
      }
    }
  }
  return $out
}
function Select-CellByContest {
  # The intersection, as its own function so both the fixture and the live path drive the SHIPPED rule.
  param($NewContest, $CellNames)
  return @(@($NewContest) | Where-Object { $CellNames.ContainsKey([string]$_) })
}

function Get-ContestTag {
  <#
    A CONTESTED NAME THAT DESCRIBES ITSELF (2026-09-08, queue 2026-09-08-2e59b3).

    A new-contested finding used to be a bare product name, so the reviewer had to open two other files
    to learn what was even being claimed. This prints the contest chain with each commodity's UNIT and
    tags the shape that has cost real money here: a FORM contest, where the rules disagree about what
    KIND of thing the product is rather than which brand of it.

    FORM = the winner's unit differs from a loser's (a per-lb fresh commodity beating a per-oz canned
    one), OR a loser id is canned-* / frozen-* while the winner's is not. That is the exact shape of
    'Fareway Steamables Green Beans' (fresh-green-beans lb > canned-green-beans oz) and of the Green
    Giant Steamers bag (red-potatoes lb > fresh-green-beans lb > canned-green-beans oz).

    NOT FORM is the ordinary multi-product ad-line class ('Hy-Vee rice, quinoa or Israeli-style
    couscous'), where two same-unit commodities both read a word in one advertisement.
  #>
  param([string]$Chain, $Units)
  $ids = @(@($Chain -split '\s*>\s*') | Where-Object { $_ })
  $u = @{}
  if ($Units) { foreach ($k in @($Units.Keys)) { $u[[string]$k] = [string]$Units[$k] } }
  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($id in $ids) {
    $un = [string]$u[[string]$id]
    if ($un) { [void]$parts.Add([string]$id + ' (' + $un + ')') } else { [void]$parts.Add([string]$id) }
  }
  $form = $false
  if ($ids.Count -gt 1) {
    $wid = [string]$ids[0]
    $wu = [string]$u[$wid]
    $winnerIsFormId = ($wid -match '^(?:canned|frozen)-')
    foreach ($lid in $ids[1..($ids.Count - 1)]) {
      $lu = [string]$u[[string]$lid]
      if ($wu -and $lu -and ($wu -ne $lu)) { $form = $true; break }
      if ((-not $winnerIsFormId) -and ([string]$lid -match '^(?:canned|frozen)-')) { $form = $true; break }
    }
  }
  return [pscustomobject]@{ chain = ($parts -join ' > '); form = $form }
}

function Get-CandidateBasis {
  <#
    THE ENGINE'S OWN VERDICT on a contested name, read out of the newest candidates-*.json rather than
    recomputed: OUT-OF-BAND, UNPRICED, or 'size X' with the unit price the board would publish.

    This is the discriminator that separates a latent wrong product from a live one. A frozen bag that
    the sanity band censors costs nothing today and everything the day the fresh row behind it is
    absent (Brad 2026-09-04: no hard-coded bands, so the band is not a fix). A frozen bag the engine
    priced IN BAND is money that is wrong on the board right now.

    A PARAMETER, not a file read, so the fixture can freeze a candidates slice.
  #>
  param([string]$Name, [string]$Commodity, $CandCommodities)
  foreach ($cm in @($CandCommodities)) {
    if ([string]$cm.id -ne $Commodity) { continue }
    $seen = New-Object System.Collections.Generic.List[string]
    foreach ($cd in @($cm.candidates)) {
      if ([string]$cd.name -ne $Name) { continue }
      $b = [string]$cd.basis
      if (-not $b) { $b = 'UNPRICED' }
      if ($null -ne $cd.unit_price -and ([string]$cd.unit_price) -ne '') { $b = $b + ' = ' + [string]$cd.unit_price + '/' + [string]$cm.unit }
      if (-not $seen.Contains($b)) { [void]$seen.Add($b) }
    }
    if ($seen.Count) { return ($seen -join ' ; ') }
  }
  return 'not in the newest candidates file'
}

function New-SoundnessAlertBody {
  <#
    THE ALERT BODY, AS A FUNCTION (2026-09-08, queue 2026-09-08-2e59b3).

    It was inline, and it built the email out of the dropped, moved and drift lines ONLY. The
    new-contested NAMES printed to the console and never reached the reader: the 2026-09-08 alert said
    'new-contested=1' and the only way to learn WHICH product was to open ad-cycle-log.txt or
    match-sweep-cache.json. A finding whose subject is a product, delivered without the product, is a
    notification that work exists rather than a description of it.

    Pure and parameterised so -SelfTest can assert the name is in the body without sending mail.
  #>
  param($Report)
  $L = New-Object System.Collections.Generic.List[string]
  $nc = @($Report.new_contested)
  [void]$L.Add('Matching soundness found changes:')
  [void]$L.Add("MOVED=$(@($Report.moved).Count) DROPPED=$(@($Report.dropped).Count) new-contested=$($nc.Count) drift=$([int]$Report.drift_vs_engine)")
  [void]$L.Add('')
  foreach ($d in @($Report.dropped)) { [void]$L.Add("DROPPED $($d.from): $($d.name)") }
  foreach ($mv in @($Report.moved)) { [void]$L.Add("MOVED $($mv.from)->$($mv.to): $($mv.name)") }
  foreach ($dr in (@($Report.drift_products) | Select-Object -First 25)) { [void]$L.Add("DRIFT engine=$($dr.engine) matcher=$($dr.matcher): $($dr.name)") }
  foreach ($n in $nc) {
    $tag = ''
    if ($n.form) { $tag = ' [FORM]' }
    [void]$L.Add("NEW-CONTESTED$tag $($n.name)")
    [void]$L.Add("    chain   : $($n.chain)")
    [void]$L.Add("    engine  : $($n.verdict)")
    if ([string]$n.cell) {
      $lbl = 'CELL'
      if ($n.crown) { $lbl = 'CROWN' }
      [void]$L.Add("    holds a $lbl : $($n.cell)")
    }
  }
  foreach ($cb in @($Report.cell_by_contest)) {
    $lbl = 'CELL'
    if ($cb.crown) { $lbl = 'CROWN' }
    [void]$L.Add("$lbl-BY-CONTEST $($cb.name)  cell $($cb.cell)  claimed by: $($cb.claimed_by)")
  }
  [void]$L.Add('')
  [void]$L.Add('Review, then accept with: audit-match-soundness.ps1 -Accept')
  return ($L -join "`n")
}

function Merge-BaselineCarryForward {
  <#
    A NAME THE STORE DID NOT LIST TODAY IS NOT A NAME THE RULES STOPPED CLAIMING (2026-09-08, queue
    2026-09-08-2e59b3).

    -Accept used to snapshot exactly what today's sweep saw, so a product a store simply did not list
    today fell out of the baseline entirely - and it fell out SILENTLY, because the MOVED/DROPPED diff
    skips names absent from today's sweep. Both halves of that were paid for on 2026-09-07: 12 reviewed
    CONTESTED entries were erased by ABSENCE (reviewed status lost, not reviewed away) and 750 names
    lost their MOVED/DROPPED coverage, so a route change on any of them would have been invisible. One
    of the 12 came back the next morning and fired as 'new-contested' - a reviewed contest re-firing as
    new is a capture flicker wearing the costume of a finding, and it cost a whole triage round.

    So a name the old baseline knew and today's sweep did not see is RETAINED, with a last_seen date.
    Names seen today take today's route and today's date. An entry absent for more than MaxAbsentDays
    expires, because this map is protection against a FLICKER and not a permanent archive.

    An OLD-FORMAT baseline (no last_seen map) reads every entry as last seen on its own generated date.
    An entry whose date cannot be parsed is KEPT, never expired: losing reviewed state is the failure
    this function exists to prevent, so every uncertain case falls to retention.

    Pure - the previous baseline arrives as an object and the reference date as a string - so -SelfTest
    drives the shipped rule instead of a copy of it.
  #>
  param($TodayNames, $TodayContest, $PrevBaseline, [string]$Today, [int]$MaxAbsentDays = 30)
  $outNames = @{}; foreach ($kv in $TodayNames.GetEnumerator()) { $outNames[[string]$kv.Key] = [string]$kv.Value }
  $outContest = @{}; foreach ($kv in $TodayContest.GetEnumerator()) { $outContest[[string]$kv.Key] = $true }
  $lastSeen = @{}; foreach ($k in @($outNames.Keys)) { $lastSeen[[string]$k] = $Today }
  $carriedNames = 0; $carriedContest = 0; $expired = 0
  $ref = [datetime]::MinValue
  if (-not [datetime]::TryParse($Today, [ref]$ref)) { $ref = Get-Date }
  $cutoff = $ref.AddDays(-1 * $MaxAbsentDays)
  if ($PrevBaseline -and $PrevBaseline.names) {
    $prevSeen = @{}
    if ($PrevBaseline.PSObject.Properties.Match('last_seen').Count -and $PrevBaseline.last_seen) {
      foreach ($p in $PrevBaseline.last_seen.PSObject.Properties) { $prevSeen[$p.Name] = [string]$p.Value }
    }
    $prevGen = [string]$PrevBaseline.generated
    if ($prevGen.Length -gt 10) { $prevGen = $prevGen.Substring(0, 10) }
    $prevContest = @{}; foreach ($x in @($PrevBaseline.contested)) { $prevContest[[string]$x] = $true }
    foreach ($p in $PrevBaseline.names.PSObject.Properties) {
      $nm = [string]$p.Name
      if ($outNames.ContainsKey($nm)) { continue }   # seen today: today's route and today's date win
      $ls = $prevGen
      if ($prevSeen.ContainsKey($nm)) { $ls = [string]$prevSeen[$nm] }
      $dt = [datetime]::MinValue
      if ([datetime]::TryParse($ls, [ref]$dt) -and $dt -lt $cutoff) { $expired++; continue }
      $outNames[$nm] = [string]$p.Value
      $lastSeen[$nm] = $ls
      $carriedNames++
      if ($prevContest.ContainsKey($nm)) { $outContest[$nm] = $true; $carriedContest++ }
    }
  }
  return [pscustomobject]@{ names = $outNames; contested = $outContest; last_seen = $lastSeen
                            carried_names = $carriedNames; carried_contested = $carriedContest; expired = $expired }
}
if ($SelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  $names = @{ 'Honey Boy Pink Salmon' = 'canned-salmon'; 'Sue Bee Honey' = 'honey'
              'Steak Tips With Gravy' = '<unmatched>' }
  $cands = @(
    [pscustomobject]@{ id = 'honey'; candidates = @(
      [pscustomobject]@{ name = 'Honey Boy Pink Salmon' }, [pscustomobject]@{ name = 'Sue Bee Honey' }) },
    [pscustomobject]@{ id = 'jarred-gravy'; candidates = @(
      [pscustomobject]@{ name = 'Steak Tips With Gravy' }) })
  $rows = Get-DriftRows $names $cands
  T 'MUST FIRE  a drift is NAMED, with both opinions - the count alone is what made 7 uninvestigable' `
    (@($rows).Count -eq 2 -and (@($rows | Where-Object { $_.name -eq 'Honey Boy Pink Salmon' -and $_.engine -eq 'honey' -and $_.matcher -eq 'canned-salmon' }).Count -eq 1)) `
    (($rows | ForEach-Object { $_.name + ':' + $_.engine + '->' + $_.matcher }) -join ' | ')
  T 'MUST FIRE  a product the matcher now leaves UNMATCHED is a disagreement, not a pass - that is the rule-improvement shape, and all 7 on 2026-09-05 were it' `
    (@($rows | Where-Object { $_.matcher -eq '<unmatched>' }).Count -eq 1) `
    (($rows | ForEach-Object { $_.matcher }) -join ',')
  T 'CLEAN TWIN a product both sides agree on is NOT reported' `
    (@($rows | Where-Object { $_.name -eq 'Sue Bee Honey' }).Count -eq 0) 'agreed product was reported as drift'
  T 'CLEAN TWIN a product the engine names that this matcher never saw is not a disagreement - it is silence, and silence is not evidence' `
    ((Get-DriftRows @{} $cands).Count -eq 0) 'an unseen product counted as drift'
  T 'MUST FIRE  the report and the console both carry the NAMES, not just the count' `
    (((Get-Content $PSCommandPath -Raw) -match ('drift_' + 'products')) -and ((Get-Content $PSCommandPath -Raw) -match ('DRIFT    engine says'))) `
    'the names are collected and then never rendered'
  # ---- CROWN-BY-CONTEST (2026-09-07, queue 2026-09-07-0b232c) ----------------------------------------
  # FROZEN BOARD SLICE, transcribed from comparison-2026-09-06 - the board that was LIVE while it was
  # wrong. 'BELVITA Breakfast Bar Biscuit Sandwiches, Dark Chocolate Creme 8.8 oz' is a biscuit snack
  # bar. It held the breakfast-sandwiches CROWN at Fareway at $3.98 / 5 ct = 0.796/each - the cheapest
  # breakfast sandwich in Omaha - for a week, riding the ordinary accept-all new-contested review line
  # beside nine harmless multi-product ad lines. A contested name is where a wrong product enters; one
  # that wins a crown is the expensive case and now pages on its own.
  # NEVER REGENERATE THIS FROM THE LIVE BOARD: the exclude that shipped the same day removes the row, so
  # a regenerated fixture would have nothing to find and this case would pass by finding nothing.
  $cbcBoard = @(
    [pscustomobject]@{ id='breakfast-sandwiches'; unit='each'; cheapest_store='Fareway'; stores=@(
      [pscustomobject]@{ store='Fareway';    per_unit=0.796;  item='BELVITA Breakfast Bar Biscuit Sandwiches, Dark Chocolate Creme 8.8 oz' },
      [pscustomobject]@{ store='Sam''s Club'; per_unit=0.9775; item='Jimmy Dean Sausage, Egg, and Cheese Croissant Sandwiches, Frozen, 12ct.' }) },
    [pscustomobject]@{ id='raspberries'; unit='oz'; cheapest_store='Aldi'; stores=@(
      [pscustomobject]@{ store='Aldi';   per_unit=0.3113; item='Fresh Raspberries 6 Oz' },
      [pscustomobject]@{ store='Hy-Vee'; per_unit=0.6133; item='Fresh raspberries or blackberries, 6 oz. pkg., $3.68' }) })
  $cbcCrowns = Get-CellNames $cbcBoard
  $cbcContest = @('BELVITA Breakfast Bar Biscuit Sandwiches, Dark Chocolate Creme 8.8 oz',
                  'Fresh raspberries or blackberries, 6 oz. pkg., $3.68',
                  'Hy-Vee rice, quinoa or Israeli-style couscous,')
  $cbcHit = @(Select-CellByContest $cbcContest $cbcCrowns)
  T 'MUST FIRE  a NEW contested name that HOLDS A CROWN is its own class (the BELVITA biscuit bar at 0.796/each, Fareway)' `
    (($cbcHit -contains 'BELVITA Breakfast Bar Biscuit Sandwiches, Dark Chocolate Creme 8.8 oz')) (($cbcHit -join ' | '))
  T 'MUST FIRE  the finding names the CELL it crowns, not just the product' `
    ($cbcCrowns['BELVITA Breakfast Bar Biscuit Sandwiches, Dark Chocolate Creme 8.8 oz'].text -eq 'breakfast-sandwiches @ Fareway 0.796/each') `
    ([string]$cbcCrowns['BELVITA Breakfast Bar Biscuit Sandwiches, Dark Chocolate Creme 8.8 oz'].text)
  T 'CLEAN TWIN  the BELVITA crown case still reads as a CROWN under the generalised cell reader, not demoted to a plain cell' `
    ($cbcCrowns['BELVITA Breakfast Bar Biscuit Sandwiches, Dark Chocolate Creme 8.8 oz'].crown -eq $true) `
    ([string]$cbcCrowns['BELVITA Breakfast Bar Biscuit Sandwiches, Dark Chocolate Creme 8.8 oz'].crown)
  T 'MUST FIRE  a contested name holding a NON-crown cell is reported too, flagged crown=false - the crown-only reader was SILENT here, and that is the 2026-09-08 founding gap' `
    (($cbcHit -contains 'Fresh raspberries or blackberries, 6 oz. pkg., $3.68') -and $cbcCrowns['Fresh raspberries or blackberries, 6 oz. pkg., $3.68'].crown -eq $false) `
    (($cbcHit -join ' | '))
  T 'MUST NOT FIRE  a contested name with no board cell at all is neither a crown nor a cell' `
    (-not ($cbcHit -contains 'Hy-Vee rice, quinoa or Israeli-style couscous,')) (($cbcHit -join ' | '))
  T 'CLEAN TWIN  the cell reader still finds the other commodity''s crown, so it reads the WHOLE board' `
    ($cbcCrowns.ContainsKey('Fresh Raspberries 6 Oz') -and $cbcCrowns['Fresh Raspberries 6 Oz'].crown -eq $true -and $cbcCrowns.Count -eq 4) ([string]$cbcCrowns.Count)
  T 'CLEAN TWIN  an empty contested set yields 0 findings, not the PS 5.1 @($null) count of 1' `
    ((@(Select-CellByContest @() $cbcCrowns)).Count -eq 0) ([string](@(Select-CellByContest @() $cbcCrowns)).Count)
  # ---- CELL-BY-CONTEST, THE FOUNDING SLICE (2026-09-08, queue 2026-09-08-2e59b3) ---------------------
  # FROZEN BOARD SLICE, transcribed from comparison-2026-09-08 - the board that was LIVE while it was
  # wrong. 'Fareway Steamables Green Beans' is a FROZEN 12 oz microwave bag; it held Fareway's
  # fresh-green-beans cell at $1.44 / 0.75 lb = 1.92 per lb, over the fresh 'Pero Family Farms Snipped
  # Green Beans' at 2.94 per lb. The CROWN was Walmart at 1.6201, so CROWN-BY-CONTEST could not see it,
  # and the name was already in the accepted contested list where no run would ever flag it again.
  # NEVER REGENERATE THIS FROM THE LIVE BOARD: the steam_bag_carrier exclude that shipped the same day
  # takes the row off the board, so a regenerated fixture would have nothing to find.
  $fgbBoard = @(
    [pscustomobject]@{ id='fresh-green-beans'; unit='lb'; cheapest_store='Walmart'; stores=@(
      [pscustomobject]@{ store='Walmart'; per_unit=1.6201; item='Fresh Green Beans, Bag' },
      [pscustomobject]@{ store='Fareway'; per_unit=1.92;   item='Fareway Steamables Green Beans' }) })
  $fgbCells = Get-CellNames $fgbBoard
  $fgbHit = @(Select-CellByContest @('Fareway Steamables Green Beans') $fgbCells)
  T 'MUST FIRE  the frozen bag holding the FARE WAY cell is reported, with the cell it holds' `
    ($fgbHit.Count -eq 1 -and $fgbCells['Fareway Steamables Green Beans'].text -eq 'fresh-green-beans @ Fareway 1.92/lb') `
    ([string]$fgbCells['Fareway Steamables Green Beans'].text)
  T 'MUST FIRE  it is reported as crown=false, which is exactly why the crown-only reader was silent on it' `
    ($fgbCells['Fareway Steamables Green Beans'].crown -eq $false) ([string]$fgbCells['Fareway Steamables Green Beans'].crown)
  # ---- FORM TAG + THE ENGINE'S OWN VERDICT ----------------------------------------------------------
  $ftUnits = @{ 'red-potatoes'='lb'; 'fresh-green-beans'='lb'; 'canned-green-beans'='oz'; 'hot-sauce'='oz'
                'taco-sauce'='oz'; 'sweet-potatoes'='lb'; 'frozen-sweet-potatoes'='lb' }
  $ftA = Get-ContestTag 'red-potatoes > fresh-green-beans > canned-green-beans' $ftUnits
  T 'MUST FIRE  a chain whose winner is per-lb and whose loser is per-oz is tagged FORM (the Green Giant Steamers bag)' `
    ($ftA.form -eq $true) ([string]$ftA.form)
  T 'MUST FIRE  the chain prints each commodity''s UNIT, so the reader is not sent to commodities.json to learn the shape' `
    ($ftA.chain -eq 'red-potatoes (lb) > fresh-green-beans (lb) > canned-green-beans (oz)') ([string]$ftA.chain)
  $ftB = Get-ContestTag 'sweet-potatoes > frozen-sweet-potatoes' $ftUnits
  T 'MUST FIRE  a SAME-UNIT chain whose loser id is frozen-* while the winner is not is still FORM' `
    ($ftB.form -eq $true) ([string]$ftB.form)
  $ftC = Get-ContestTag 'hot-sauce > taco-sauce' $ftUnits
  T 'MUST NOT FIRE  two same-unit commodities neither of which is canned-/frozen- is the ordinary ad-line class, NOT FORM' `
    ($ftC.form -eq $false) ([string]$ftC.form)
  T 'CLEAN TWIN  a single-commodity chain (no contest at all) is not FORM and still renders its unit' `
    (((Get-ContestTag 'red-potatoes' $ftUnits).form -eq $false) -and ((Get-ContestTag 'red-potatoes' $ftUnits).chain -eq 'red-potatoes (lb)')) `
    ([string](Get-ContestTag 'red-potatoes' $ftUnits).chain)
  # FROZEN CANDIDATES SLICE, transcribed from candidates-2026-09-08.json. The band, not the rule, is
  # what kept the Green Giant Steamers bag off the red-potatoes cell, and a reviewer cannot tell that
  # from the name alone.
  $ftCands = @(
    [pscustomobject]@{ id='red-potatoes'; unit='lb'; candidates=@(
      [pscustomobject]@{ store='Fareway'; name='Green Giant Steamers Lightly Sauced Roasted Red Potatoes, Green Beans & Rosemary'; size_text='10 oz'; price_text='$2.99'; basis='OUT-OF-BAND'; unit_price=$null },
      [pscustomobject]@{ store='Fareway'; name='Red Potato'; size_text='5 lb'; price_text='$4.99'; basis='size 5 lb'; unit_price=0.998 }) },
    [pscustomobject]@{ id='fresh-green-beans'; unit='lb'; candidates=@(
      [pscustomobject]@{ store='Fareway'; name='Fareway Steamables Green Beans'; size_text='12 oz'; price_text='$1.44'; basis='size 0.75 lb'; unit_price=1.92 }) })
  T 'MUST FIRE  a censored row carries the engine''s OUT-OF-BAND verdict, so latent is distinguishable from live' `
    ((Get-CandidateBasis 'Green Giant Steamers Lightly Sauced Roasted Red Potatoes, Green Beans & Rosemary' 'red-potatoes' $ftCands) -eq 'OUT-OF-BAND') `
    (Get-CandidateBasis 'Green Giant Steamers Lightly Sauced Roasted Red Potatoes, Green Beans & Rosemary' 'red-potatoes' $ftCands)
  T 'MUST FIRE  a row the engine PRICED carries its basis and unit price - that is money wrong on the board today' `
    ((Get-CandidateBasis 'Fareway Steamables Green Beans' 'fresh-green-beans' $ftCands) -eq 'size 0.75 lb = 1.92/lb') `
    (Get-CandidateBasis 'Fareway Steamables Green Beans' 'fresh-green-beans' $ftCands)
  T 'CLEAN TWIN  a name the candidates file does not carry says so instead of inventing a verdict' `
    ((Get-CandidateBasis 'Nothing Like This' 'red-potatoes' $ftCands) -eq 'not in the newest candidates file') `
    (Get-CandidateBasis 'Nothing Like This' 'red-potatoes' $ftCands)
  # ---- THE ALERT BODY CARRIES THE NAME --------------------------------------------------------------
  $abReport = [ordered]@{ generated='2026-09-08 10:00'; drift_vs_engine=0; drift_products=@(); moved=@(); dropped=@()
    new_contested=@([pscustomobject]@{ name='Green Giant Steamers Lightly Sauced Roasted Red Potatoes, Green Beans & Rosemary'
                                       chain='red-potatoes (lb) > fresh-green-beans (lb) > canned-green-beans (oz)'; form=$true
                                       winner='red-potatoes'; verdict='OUT-OF-BAND'; cell=''; crown=$false })
    cell_by_contest=@() }
  $abBody = New-SoundnessAlertBody $abReport
  T 'MUST FIRE  the alert body built for new-contested=1 CONTAINS the product name (the 2026-09-08 email carried only the count)' `
    ($abBody -like '*Green Giant Steamers Lightly Sauced Roasted Red Potatoes, Green Beans & Rosemary*') $abBody
  T 'MUST FIRE  the alert body carries the FORM tag and the engine verdict beside the name' `
    (($abBody -like '*[[]FORM]*') -and ($abBody -like '*OUT-OF-BAND*')) $abBody
  # -cnotlike, CASE-SENSITIVELY: the counts line already says 'new-contested=0' in lower case, so a
  # case-insensitive needle matches the summary and this twin can never fail. It is the entry LINES
  # (upper case) whose absence is being asserted.
  $abEmpty = New-SoundnessAlertBody ([ordered]@{ generated='x'; drift_vs_engine=0; drift_products=@(); moved=@(); dropped=@(); new_contested=@(); cell_by_contest=@() })
  T 'CLEAN TWIN  a report with no new-contested produces no NEW-CONTESTED entry lines but still carries its counts line, so ordinary alerts are unchanged' `
    (($abEmpty -cnotlike '*NEW-CONTESTED*') -and ($abEmpty -like '*new-contested=0*') -and ($abEmpty -like '*audit-match-soundness.ps1 -Accept*')) $abEmpty
  # ---- BASELINE CARRY-FORWARD -----------------------------------------------------------------------
  # Shapes match a real baseline read back through ConvertFrom-Json: names is an OBJECT, contested an array.
  $cfPrev = [pscustomobject]@{ generated='2026-09-07 15:38'; rules_hash='abc'
    names=[pscustomobject]@{ 'Kept Absent Product'='canned-peas'; 'Stale Absent Product'='honey'; 'Present Product'='honey' }
    contested=@('Kept Absent Product') }
  $cfToday = @{ 'Present Product'='honey'; 'New Product'='jam' }
  $cfPrev | Add-Member -NotePropertyName last_seen -NotePropertyValue ([pscustomobject]@{ 'Stale Absent Product'='2026-08-08' })
  $cf = Merge-BaselineCarryForward $cfToday @{} $cfPrev '2026-09-08' 30
  T 'MUST FIRE  a name in the old baseline and absent from today''s sweep is RETAINED, not erased (11 reviewed entries were lost this way on 2026-09-07)' `
    ($cf.names.ContainsKey('Kept Absent Product') -and $cf.names['Kept Absent Product'] -eq 'canned-peas') `
    (($cf.names.Keys | Sort-Object) -join ',')
  T 'MUST FIRE  its reviewed CONTESTED status is retained too, so a one-day capture flicker cannot re-fire it as new-contested' `
    ($cf.contested.ContainsKey('Kept Absent Product') -and $cf.carried_contested -eq 1) ([string]$cf.carried_contested)
  T 'MUST FIRE  an old-format entry with no last_seen inherits the baseline''s own generated date' `
    ($cf.last_seen['Kept Absent Product'] -eq '2026-09-07') ([string]$cf.last_seen['Kept Absent Product'])
  T 'MUST FIRE  an entry absent for 31 days EXPIRES - this is flicker protection, not a permanent archive' `
    ((-not $cf.names.ContainsKey('Stale Absent Product')) -and $cf.expired -eq 1) ([string]$cf.expired)
  T 'CLEAN TWIN  a name present today keeps TODAY''s route and today''s last_seen' `
    ($cf.names['Present Product'] -eq 'honey' -and $cf.last_seen['Present Product'] -eq '2026-09-08') ([string]$cf.last_seen['Present Product'])
  T 'CLEAN TWIN  a name new today is in the baseline with today''s date' `
    ($cf.names['New Product'] -eq 'jam' -and $cf.last_seen['New Product'] -eq '2026-09-08') ([string]$cf.last_seen['New Product'])
  $cf2 = Merge-BaselineCarryForward @{ 'A'='honey'; 'B'='jam' } @{ 'B'=$true } ([pscustomobject]@{ generated='2026-09-07 15:38'; names=[pscustomobject]@{ 'A'='honey'; 'B'='jam' }; contested=@('B') }) '2026-09-08' 30
  T 'CLEAN TWIN  an -Accept with NO absent names writes names and contested identical to today''s sweep, so an ordinary accept is what it always was' `
    ($cf2.names.Count -eq 2 -and $cf2.contested.Count -eq 1 -and $cf2.carried_names -eq 0 -and $cf2.expired -eq 0) `
    ("names=$($cf2.names.Count) contested=$($cf2.contested.Count) carried=$($cf2.carried_names) expired=$($cf2.expired)")
  T 'CLEAN TWIN  no previous baseline at all is not a crash and carries nothing' `
    (((Merge-BaselineCarryForward @{ 'A'='honey' } @{} $null '2026-09-08' 30).names.Count -eq 1)) `
    ([string](Merge-BaselineCarryForward @{ 'A'='honey' } @{} $null '2026-09-08' 30).names.Count)
  if ($bad -eq 0) { Write-Output 'match-soundness SELF-TEST PASS'; exit 0 }
  Write-Output ("match-soundness SELF-TEST FAIL: $bad case(s)"); exit 2
}

if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$audDir = Join-Path $OutDir 'audit'
if (-not (Test-Path $audDir)) { New-Item -ItemType Directory -Path $audDir | Out-Null }
$baseF = Join-Path $audDir 'match-baseline.json'

# ---- faithful matcher (mirrors compare-deals Match-Category) ----
$tmp = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $root 'commodities.json'))); $commods = @($tmp)
# THE EXCLUDE LIST IS A LIBRARY NOW (2026-09-09, backlog I82). This used to cut the array literal out of
# compare-deals.ps1's source with a regex and scrape the quoted tokens back out of it line by line. That
# lift had NO failure branch: a reformat of the engine would have left $GLOBAL empty and this audit would
# have gone on comparing itself to an engine it no longer mirrors, at exit 0. The refusal below is the half
# that was missing, and it is kept now that the parse itself is gone.
. (Join-Path $root 'global-exclude-lib.ps1')
$gexList = Get-TcGlobalExclude
$GLOBAL = @($gexList)
# NULL OR EMPTY, NOT 'FEWER THAN TWO'. @($null).Count is 1 in PowerShell, which is why this used
# to read -lt 2 - and that also refused the one-token lists the match-soundness fixtures drive on
# purpose. Name the two states being rejected rather than using a count as a proxy for them.
if ($null -eq $gexList -or $GLOBAL.Count -lt 1) {
  # Exit-Guard, NOT a bare exit: a verdict that leaves without the completion marker is indistinguishable
  # from a crash, and audit-guard-contract caught this exact line as HALF-COVERED the run it was written.
  Write-Output 'match-soundness: FATAL - the global exclude list is empty or unreadable, so this audit cannot mirror the engine'
  Exit-Guard -Name 'match-soundness' -Summary 'BLIND: the exclude list came back empty' -Code 2
}
function Get-Eligible([string]$name) {
  $n = $name.ToLower(); $gh = @(); foreach ($g in $GLOBAL) { try { if ($n -match $g) { $gh += $g } } catch {} }
  $elig = @()
  foreach ($c in $commods) {
    $hit = $false; foreach ($inc in $c.include) { try { if ($n -match $inc) { $hit = $true; break } } catch {} }
    if (-not $hit) { continue }
    if ($gh.Count) { $rx = @($c.relax_global | Where-Object { $_ }); $blk = $false; foreach ($g in $gh) { if ($rx -notcontains $g) { $blk = $true; break } }; if ($blk) { continue } }
    $bad = $false; foreach ($e in $c.exclude) { try { if ($n -match $e) { $bad = $true; break } } catch {} }
    if ($bad) { continue }
    $elig += [string]$c.id
  }
  return $elig
}

# ---- gather every raw product (same inputs compare-deals reads) ----
$names = @{}   # name -> commodity ('<unmatched>' if none)
$contest = @{} # name -> "a > b > c" when >1 eligible
function Ingest([string]$item) {
  if (-not $item -or $names.ContainsKey($item)) { return }
  $e = @(Get-Eligible $item)   # @() forces array: a single-eligible result must NOT unroll to a scalar string (then $e[0] would be its first CHARACTER)
  $names[$item] = if ($e.Count) { [string]$e[0] } else { '<unmatched>' }
  if ($e.Count -gt 1) { $contest[$item] = ($e -join ' > ') }
}
# The FEED SELECTION happens once, here, and is the SINGLE source of truth for both the sweep below and the
# fingerprint that guards it. Deriving the hash from a second, hand-maintained file list is exactly how a
# cache key silently stops covering an input it is supposed to cover.
$feedFiles = New-Object System.Collections.Generic.List[object]
Get-ChildItem (Join-Path $OutDir 'regular\*.json') -EA SilentlyContinue | Group-Object { ($_.BaseName -replace '-regular-.*$', '') } | ForEach-Object {
  [void]$feedFiles.Add(($_.Group | Sort-Object Name -Descending | Select-Object -First 1))
}
$adsF = Get-ChildItem (Join-Path $OutDir 'ads-*.json') -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if ($adsF) { [void]$feedFiles.Add($adsF) }
foreach ($pat in @('bakers\bakers-deals-*.json', 'sams\sams-deals-*.json', 'fareway\fareway-deals-*.json')) {
  $df = Get-ChildItem (Join-Path $OutDir $pat) -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  if ($df) { [void]$feedFiles.Add($df) }
}

# ---- INPUT FINGERPRINT ----------------------------------------------------------------------------------
# The Ingest sweep below is 97% of this script's runtime (measured 2026-07-30: 51.5s of a 53.0s run) and it is
# a PURE FUNCTION of a closed input set, so re-deriving it on byte-identical inputs is wasted wall clock in
# the publish critical path - and this script is the gate the agent waits on to learn whether publish HOLDs.
# The hash covers every file that can change $names/$contest:
#   * THIS SCRIPT and the lib it dot-sources. A cache keyed on data but not on code is a gate that can never
#     arm after a logic change: edit the matcher, get yesterday's answer back.
#   * commodities.json, compare-deals.ps1 and global-exclude-lib.ps1. The exclude list moved out of the
#     engine on 2026-09-09 (backlog I82), so the library is hashed too; compare-deals stays in the key
#     because the matcher above mirrors ITS Match-Category, and over-keying costs at most an extra miss
#     while under-keying returns a WRONG answer.
#   * every feed file actually selected above (not a re-listed guess at them).
# Deliberately NOT in the key, because they are never served from cache: candidates-*.json (the self-check
# below always re-runs live, so the matcher-vs-engine assertion can never be skipped) and match-baseline.json
# + verify-verdicts-*.json (the baseline diff and the -Accept verdict gate always run live).
$msCacheF = Join-Path $audDir 'match-sweep-cache.json'
$fpFiles = New-Object System.Collections.Generic.List[string]
$selfF = if ($PSCommandPath) { $PSCommandPath } else { Join-Path $root 'audit-match-soundness.ps1' }
foreach ($sf in @($selfF, (Join-Path $root 'verdict-lib.ps1'), (Join-Path $root 'commodities.json'), (Join-Path $root 'compare-deals.ps1'), (Join-Path $root 'global-exclude-lib.ps1'))) { [void]$fpFiles.Add([string]$sf) }
foreach ($ffi in $feedFiles) { [void]$fpFiles.Add([string]$ffi.FullName) }
$fp = ''
try {
  $fpSha = [Security.Cryptography.SHA1]::Create()
  $fpAcc = New-Object Text.StringBuilder
  foreach ($fpp in ($fpFiles | Sort-Object)) {
    $fps = [IO.File]::OpenRead($fpp); try { $fph = $fpSha.ComputeHash($fps) } finally { $fps.Dispose() }
    [void]$fpAcc.Append($fpp).Append('=').Append([BitConverter]::ToString($fph).Replace('-', '')).Append(';')
  }
  $fp = [BitConverter]::ToString($fpSha.ComputeHash([Text.Encoding]::UTF8.GetBytes($fpAcc.ToString()))).Replace('-', '')
} catch { $fp = '' }   # could not hash an input => cannot prove it unchanged => no cache, run the real sweep

# CACHE READ. Skipped entirely for -Accept/-ForceAccept: those WRITE the baseline out of $names and a wrong
# $names there is permanent and invisible afterwards. Any doubt at all - no stamp, unreadable stamp, a stamp
# whose '' parses to $null WITHOUT throwing, a count that does not survive the round trip - falls through to
# the real sweep, because a skip that cannot prove its inputs are unchanged must run the real thing.
$msHit = $false
if ($fp -and -not $Accept -and -not $ForceAccept -and (Test-Path $msCacheF)) {
  try {
    $cj = ConvertFrom-Json ([IO.File]::ReadAllText($msCacheF))
    if ($cj -and ([string]$cj.fp) -eq $fp -and ([int]$cj.count) -gt 0) {
      $nk = @($cj.names_k); $nv = @($cj.names_v); $ck = @($cj.contest_k); $cv = @($cj.contest_v)
      if ($nk.Count -eq ([int]$cj.count) -and $nv.Count -eq $nk.Count -and $ck.Count -eq $cv.Count) {
        for ($i = 0; $i -lt $nk.Count; $i++) { $names[[string]$nk[$i]] = [string]$nv[$i] }
        for ($i = 0; $i -lt $ck.Count; $i++) { $contest[[string]$ck[$i]] = [string]$cv[$i] }
        # names are stored as PARALLEL ARRAYS, never as JSON object keys: PSObject property names are
        # case-INSENSITIVE, so two products differing only in case would silently merge on reload. The count
        # check below is the belt to that braces - a map that did not survive the round trip is discarded.
        if ($names.Count -eq ([int]$cj.count) -and $contest.Count -eq $ck.Count) { $msHit = $true }
      }
    }
  } catch { }
  if (-not $msHit) { $names = @{}; $contest = @{} }
}

if (-not $msHit) {
  foreach ($ffr in $feedFiles) { foreach ($d in (ConvertFrom-Json ([IO.File]::ReadAllText($ffr.FullName))).deals) { Ingest ([string]$d.item) } }
  # Never cache an EMPTY sweep. A stamp saying "0 products, all clear" would let a run that read nothing be
  # served back forever as a clean bill of health.
  if ($fp -and $names.Count -gt 0 -and -not $Accept -and -not $ForceAccept) {
    try {
      $nkL = New-Object System.Collections.Generic.List[string]; $nvL = New-Object System.Collections.Generic.List[string]
      foreach ($kv in $names.GetEnumerator()) { [void]$nkL.Add([string]$kv.Key); [void]$nvL.Add([string]$kv.Value) }
      $ckL = New-Object System.Collections.Generic.List[string]; $cvL = New-Object System.Collections.Generic.List[string]
      foreach ($kv in $contest.GetEnumerator()) { [void]$ckL.Add([string]$kv.Key); [void]$cvL.Add([string]$kv.Value) }
      Set-Content $msCacheF -Value ([ordered]@{ fp = $fp; count = $names.Count; names_k = $nkL.ToArray(); names_v = $nvL.ToArray(); contest_k = $ckL.ToArray(); contest_v = $cvL.ToArray() } | ConvertTo-Json -Depth 4 -Compress) -Encoding UTF8
    } catch { }
  }
}

# ---- SELF-CHECK: matcher vs the engine's candidates (must be 0 disagreements) ----
$drift = 0
# NAME THEM, DO NOT JUST COUNT THEM (2026-09-05). This check counted disagreements and then told the
# reader to "investigate compare-deals vs commodities.json" without saying WHICH products - so the one
# thing needed to investigate was the one thing it withheld. On 2026-09-05 it reported 7 and nobody
# could act on it: naming them from outside would mean a second copy of Get-Eligible, which is the
# rule this estate deliberately keeps in one file. The count is unchanged; only the legibility is.
$driftRows = New-Object System.Collections.Generic.List[object]
$candCommods = @()
try {
  $candF = Get-ChildItem (Join-Path $OutDir 'candidates-*.json') | Sort-Object Name -Descending | Select-Object -First 1
  if ($candF) {
    # READ ONCE. The same parsed candidates drive the drift check here and the per-new-contested band
    # verdict below; this file is the largest thing this script opens.
    $candCommods = @((ConvertFrom-Json ([IO.File]::ReadAllText($candF.FullName))).commodities)
    # WRAPPED AT THE CALL SITE. PowerShell unrolls a List returned from a function, so a single-row
    # result arrives as a bare PSCustomObject and .Count/.ToArray() are gone. Assign then wrap.
    $driftRows = @(Get-DriftRows $names $candCommods)
    $drift = $driftRows.Count
  }
} catch {}

# ---- BLIND GUARD: a check that examined NOTHING must say so ----------------------------------------------
# With every feed missing this script used to print "MOVED=0  DROPPED=0" and exit 0 - a clean bill of health
# over zero products - because the report loop only walks names it actually ingested. Worse, -Accept in that
# state rewrote the baseline as an EMPTY map (measured 2026-07-30: 18,123 names / 1.70 MB -> 0 names / 129
# bytes, "baseline ACCEPTED (0 product names)", exit 0). match-baseline.json is a TRACKED file, so that empty
# map commits, and every later run diffs against nothing and reports all-clear forever.
# Exit 3 is the estate's could-not-evaluate code. On today's real inputs $names.Count is 18,123, so this can
# only fire on a genuinely empty read - no cry-wolf on a healthy run.
if ($names.Count -eq 0) {
  Write-Output 'match-soundness: BLIND - ZERO products were ingested, so nothing this run proves about any commodity matching. This is NOT a clean board: check out\regular\, out\ads-*.json and the per-store deals files.'
  if ($Accept -or $ForceAccept) { Write-Output 'ACCEPT REFUSED - baselining an empty sweep would erase the reviewed baseline and blind this audit permanently.' }
  exit 3
}

# ---- ACCEPT: write current as baseline ----
if ($Accept -or $ForceAccept) {
  # ---- THE VERDICT GATE: -Accept must not bless a mapping a DROP verdict already rejected ----
  # -Accept snapshots name -> commodity wholesale, and everything in the snapshot becomes invisible to this
  # audit forever after (it is a CHANGE detector). So one careless accept converts "judged wrong last week"
  # into "reviewed and correct". That happened: bacon/Sam's and broccoli/Sam's were dropped by the verify pass
  # in THREE separate weeks, got baselined anyway, and sailed through publish as crowns on 2026-07-29.
  #
  # WHICH ITEM a verdict judged comes from Get-VerdictIdentity in verdict-lib: the entry's own 'item' field
  # first, the name quoted in its reason only as a fallback. This gate used to read the quote ONLY, and that
  # premise expired on 2026-08-05 when verdict files started carrying a structured item field:
  #  * FALSE BLOCK - the 2026-08-15 garlic verdict judged 'Marketside Tandoori Style Garlic Naan Bites,
  #    7.05 oz, 15 Count' while its reason quotes the flavour word 'Garlic'. Key garlic|garlic resolved to
  #    Aldi's real Garlic and this gate refused -Accept naming an innocent product (and, from the verdict's
  #    own store field, the wrong store). A false block is how people learn to reach for -ForceAccept.
  #  * SILENT UNDER-BLOCK - a quote can capture a SIZE ('169 FL OZ') or a reordered name ('red butter
  #    lettuce' vs the feed's 'Lettuce Red Butter'), matching no feed name at all, so a reviewed DROP was
  #    never enforced and nothing said so.
  # Two hard-won details survive in the fallback:
  #  * The closing quote is only a closing quote when followed by space/punctuation/end. Product names carry
  #    apostrophes ("Member's Mark ..."), and a naive [^']+ capture truncates at the possessive - which fails
  #    SILENT (the truncated name matches nothing, the drop is skipped, the gate under-blocks on exactly the
  #    Member's Mark rows the founding bug was about).
  #  * Matching is on a NORMALISED name (lowercase, alphanumerics only), because the feed and the reason
  #    spell the same product with and without commas ("Pinto Beans, 12 lbs." vs "Pinto Beans 12 lbs.").
  # A verdict with NO identity at all (no item field, no recoverable quote - 352 of 407 stored entries, all
  # pre-2026-08-05) is skipped rather than guessed at.
  # LATEST WORD WINS: files are walked oldest -> newest, so a later verdict on the same (commodity, item)
  # overrides an earlier one - a drop that was re-reviewed and kept stops blocking.
  # Normalisation + quote recovery live in verdict-lib.ps1, SHARED with verify-apply's suppression logic.
  # Both must agree on what "the same item" means, or a product suppressed by one is invisible to the other.
  . (Join-Path $root 'verdict-lib.ps1')
  function NormName2([string]$s) { return (Get-VerdictNorm $s) }
  $verdictByKey = @{}   # "<commodity>|<normalised item>" -> latest verdict info
  foreach ($vf in (Get-ChildItem (Join-Path $OutDir 'verify-verdicts-*.json') -EA SilentlyContinue | Sort-Object Name)) {
    try { $vj = ConvertFrom-Json ([IO.File]::ReadAllText($vf.FullName)) } catch { continue }
    foreach ($vc in @($vj.verdicts)) {
      foreach ($ve in @($vc.entries)) {
        $vident = Get-VerdictIdentity $ve
        if (-not $vident) { continue }
        $vkey = ([string]$vc.id) + '|' + (NormName2 $vident)
        $verdictByKey[$vkey] = @{ keep = ($ve.keep -ne $false); week = [string]$vj.week_of; store = [string]$ve.store; judged = $vident }
      }
    }
  }
  $normToNames = @{}
  foreach ($nk in $names.Keys) {
    $nn = NormName2 $nk
    if (-not $normToNames.ContainsKey($nn)) { $normToNames[$nn] = New-Object System.Collections.ArrayList }
    [void]$normToNames[$nn].Add($nk)
  }
  $blocked = New-Object System.Collections.ArrayList
  foreach ($kv in $verdictByKey.GetEnumerator()) {
    if ($kv.Value.keep) { continue }
    $vid, $nitem = $kv.Key -split '\|', 2
    if (-not $normToNames.ContainsKey($nitem)) { continue }         # product gone from every feed
    foreach ($actual in $normToNames[$nitem]) {
      # outstanding = the judged item STILL maps to the very commodity it was dropped from. If the rules have
      # since moved it elsewhere (or to <unmatched>), the verdict was honoured and there is nothing to block.
      if ([string]$names[$actual] -eq $vid) {
        [void]$blocked.Add([pscustomobject]@{ commodity = $vid; item = $actual; store = $kv.Value.store; week = $kv.Value.week })
      }
    }
  }
  if ($blocked.Count -gt 0 -and -not $ForceAccept) {
    Write-Output ("match-soundness: ACCEPT REFUSED - $($blocked.Count) mapping(s) an outstanding DROP verdict already judged WRONG would be blessed into the baseline and become invisible to this audit:")
    foreach ($b in ($blocked | Sort-Object commodity)) { Write-Output ("  [{0}] '{1}'  (dropped {2}, {3})" -f $b.commodity, $b.item, $b.week, $b.store) }
    Write-Output 'Fix the rules so these products stop matching (add an exclude), or re-review the verdict. If the VERDICT is the thing that is wrong, -ForceAccept overrides - loudly and on your judgment.'
    Exit-Guard -Name 'match-soundness' -Code 2
  }
  if ($blocked.Count -gt 0) {
    Write-Output ("match-soundness: FORCE-ACCEPT overriding $($blocked.Count) outstanding DROP verdict(s):")
    foreach ($b in ($blocked | Sort-Object commodity)) { Write-Output ("  [{0}] '{1}'  (dropped {2}, {3})" -f $b.commodity, $b.item, $b.week, $b.store) }
  }
  # RECORD WHICH RULES THIS BASELINE WAS ACCEPTED AGAINST (2026-09-07, Brad ruling 8). Until today the
  # baseline carried only a timestamp, so 'was this reviewed against the rules that are about to ship?'
  # was unanswerable and nobody could gate on it. On 2026-09-06 commit b28788fa changed six commodities'
  # rules at 05:45 with no -Accept and no guards; the board stopped three hours later and three of that
  # day's nine alerts were its footprint. Get-IdentityRulesHash is the SAME hash the identity table and
  # guard 13 key on, so one number answers it for all three.
  # DEFENSIVELY, because this file is COPIED into a temp directory by two test-auditors fixtures and a
  # copied script does not keep its dependencies (verify-bulk-edit's defect 4, and it fired here on the
  # first cut of this line). A missing lib records an EMPTY hash, which the commit gate then refuses -
  # fail-closed - rather than throwing halfway through writing the baseline.
  $rulesHash = ''
  $idLib = Join-Path $root 'identity-lib.ps1'
  if (Test-Path -LiteralPath $idLib) {
    try { . $idLib; $rulesHash = Get-IdentityRulesHash -GroceryRoot $root } catch { $rulesHash = '' }
  }
  # ---- CARRY THE ABSENT FORWARD (2026-09-08, queue 2026-09-08-2e59b3) ------------------------------
  # See Merge-BaselineCarryForward. A snapshot of only what today's sweep saw erases the reviewed state
  # of every product a store simply did not list today, and it erases it silently. Names seen today are
  # unaffected; this only ADDS back what was already reviewed.
  $prevBase = $null
  if (Test-Path $baseF) { try { $prevBase = ConvertFrom-Json ([IO.File]::ReadAllText($baseF)) } catch { $prevBase = $null } }
  $cf = Merge-BaselineCarryForward $names $contest $prevBase (Get-Date -Format 'yyyy-MM-dd') 30
  $obj = [ordered]@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); rules_hash = $rulesHash; names = $cf.names
                     contested = @($cf.contested.Keys | Sort-Object); last_seen = $cf.last_seen }
  Set-Content $baseF -Value ($obj | ConvertTo-Json -Depth 4) -Encoding UTF8
  Write-Output ("match-soundness: baseline ACCEPTED ($($cf.names.Count) product names, $($cf.contested.Count) contested) at rules_hash $rulesHash. drift-vs-engine=$drift")
  Write-Output ("  of those, $($names.Count) names and $($contest.Count) contested were SEEN TODAY; $($cf.carried_names) name(s) and $($cf.carried_contested) contested entry(ies) were CARRIED FORWARD as absent-not-gone; $($cf.expired) expired after 30 days absent")
  Exit-Guard -Name 'match-soundness' -Code 0
}

if (-not (Test-Path $baseF)) { Write-Output 'match-soundness: NO baseline yet - run with -Accept to establish one. (skipping gate)'; Write-GuardComplete -Name 'match-soundness'; exit 0 }
$base = ConvertFrom-Json ([IO.File]::ReadAllText($baseF))
$baseNames = @{}; foreach ($p in $base.names.PSObject.Properties) { $baseNames[$p.Name] = [string]$p.Value }
$baseContest = @{}; foreach ($x in @($base.contested)) { $baseContest[[string]$x] = $true }

$moved = New-Object System.Collections.Generic.List[object]
$dropped = New-Object System.Collections.Generic.List[object]
foreach ($nm in $baseNames.Keys) {
  if (-not $names.ContainsKey($nm)) { continue }   # product no longer pulled this week - not a regression
  $b = $baseNames[$nm]; $a = $names[$nm]
  if ($b -eq $a) { continue }
  if ($a -eq '<unmatched>') { $dropped.Add([pscustomobject]@{ name = $nm; from = $b }) }
  elseif ($b -ne '<unmatched>') { $moved.Add([pscustomobject]@{ name = $nm; from = $b; to = $a }) }
}
$newContest = @($contest.Keys | Where-Object { -not $baseContest.ContainsKey($_) } | Sort-Object)

# ---- CELL-BY-CONTEST (2026-09-07 as CROWN, widened to any cell 2026-09-08) -----------------------------
# queue 2026-09-07-0b232c, then 2026-09-08-2e59b3.
# A CONTESTED name is a name two rules both admit, resolved by array position. That makes new-contested the
# exact place a wrong product enters the estate - and on 2026-09-07 it did. 'BELVITA Breakfast Bar Biscuit
# Sandwiches, Dark Chocolate Creme 8.8 oz' is a biscuit snack bar; breakfast-sandwiches' pattern reads
# 'sandwiches' and nothing reads 'bar'. It took the breakfast-sandwiches CROWN at Fareway ($3.98 / 5 ct =
# 0.796/each), was the cheapest breakfast sandwich in Omaha for a week, and rode the ordinary accept-all
# review line the whole time, indistinguishable from nine harmless multi-product ad lines.
# ONE DAY LATER the same class arrived NOT holding a crown: 'Fareway Steamables Green Beans', a frozen 12
# oz microwave bag, held Fareway's fresh-green-beans cell at 1.92/lb while Walmart crowned it at 1.6201,
# so a reader shopping Fareway priced green beans off a frozen bag and the crown-only reader was silent.
# A wrong product only has to hold a CELL to cost a reader money, so the discriminator is any store's
# item, with crown recorded as a flag rather than as the entry condition.
# ADVISORY (exit 1) UNTIL BRAD RULES on promoting it to guards - the estate's standing rule is that a gate
# which is red on day one is a gate people learn to ignore, and this one has not run a clean week yet.
# The reader is the board itself, not a re-derivation: a name holds a cell if it is the item on a store
# column of the current comparison.
# ONE implementation, driven by the frozen fixture in -SelfTest and by this live path - see Get-CellNames.
$cellNames = @{}
try {
  $msCmpF = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Desc | Select-Object -First 1
  if ($msCmpF) { $cellNames = Get-CellNames ((ConvertFrom-Json ([IO.File]::ReadAllText($msCmpF.FullName))).comparison) }
} catch { }
$cellContest = @(Select-CellByContest $newContest $cellNames)

# ---- EVERY NEW-CONTESTED NAME DESCRIBES ITSELF (2026-09-08, queue 2026-09-08-2e59b3) -------------------
# A bare name told the reviewer nothing, so 'accept them all' was the cheap read and a wrong product rode
# it. Each name now carries its contest chain WITH UNITS, a FORM tag, the engine's own band verdict for the
# winning commodity, and the cell it holds if it holds one. See Get-ContestTag / Get-CandidateBasis.
$unitById = @{}
foreach ($c in $commods) { $unitById[[string]$c.id] = [string]$c.unit }
$newContestRows = New-Object System.Collections.Generic.List[object]
foreach ($nc in $newContest) {
  $chain = [string]$contest[[string]$nc]
  $tag = Get-ContestTag $chain $unitById
  $winner = [string](@(@($chain -split '\s*>\s*') | Where-Object { $_ })[0])
  $cellTxt = ''; $isCrown = $false
  if ($cellNames.ContainsKey([string]$nc)) { $cellTxt = [string]$cellNames[[string]$nc].text; $isCrown = [bool]$cellNames[[string]$nc].crown }
  [void]$newContestRows.Add([pscustomobject]@{ name = [string]$nc; chain = $tag.chain; form = $tag.form; winner = $winner
                                               verdict = (Get-CandidateBasis ([string]$nc) $winner $candCommods)
                                               cell = $cellTxt; crown = $isCrown })
}
# ASSIGN, THEN WRAP - and one statement per row rather than a pipeline inside a hashtable literal, so a
# failure names the row it happened on instead of the whole [ordered]@{} construction.
$cellContestRows = New-Object System.Collections.Generic.List[object]
foreach ($cbn in $cellContest) {
  $ce = $cellNames[[string]$cbn]
  [void]$cellContestRows.Add([pscustomobject]@{ name = [string]$cbn; cell = [string]$ce.text; crown = [bool]$ce.crown; claimed_by = [string]$contest[[string]$cbn] })
}
# BUILT AS ONE [ordered]@{} LITERAL, never key-by-key through $report['k'] = @(...). PS 5.1 binds that
# indexer to OrderedDictionary's this[int] overload once the dictionary is non-empty and the value is an
# object[], and throws "Argument types do not match" from Array.SetValue - a terminating error under
# EAP=Stop that killed this script before it printed a single line, so it looked like a crash rather than
# a typed-assignment fault. Reproduced standalone 2026-09-08; the literal form has always been fine.
$report = [ordered]@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); drift_vs_engine = $drift; drift_products = $driftRows; moved = $moved; dropped = $dropped
                      new_contested = $newContestRows; new_contested_names = $newContest; cell_by_contest = $cellContestRows }
Set-Content (Join-Path $audDir 'soundness-report.json') -Value ($report | ConvertTo-Json -Depth 4) -Encoding UTF8

$regr = $moved.Count + $dropped.Count
Write-Output ("match-soundness: MOVED=$($moved.Count)  DROPPED=$($dropped.Count)  new-contested=$($newContest.Count)  drift-vs-engine=$drift")
if ($drift -gt 0) {
  Write-Output ("  WARNING: matcher disagrees with the engine on $drift products - this guard may be stale; investigate compare-deals vs commodities.json.")
  foreach ($dr in ($driftRows | Select-Object -First 25)) { Write-Output ("  DRIFT    engine says $($dr.engine)  /  this matcher says $($dr.matcher)   '$($dr.name)'") }
  if ($driftRows.Count -gt 25) { Write-Output ("  ...and $($driftRows.Count - 25) more, all of them in out\audit\soundness-report.json") }
}
foreach ($d in $dropped) { Write-Output ("  DROPPED  $($d.from)  ->  <unmatched>   '$($d.name)'") }
foreach ($mv in $moved)  { Write-Output ("  MOVED    $($mv.from) -> $($mv.to)   '$($mv.name)'") }
if ($newContest.Count) {
  Write-Output ("  new-contested (order-dependence to review): " + (($newContest | Select-Object -First 25) -join ' | '))
  foreach ($ncr in ($newContestRows | Select-Object -First 25)) {
    $ncTag = ''
    if ($ncr.form) { $ncTag = '  [FORM]' }
    Write-Output ("    NEW-CONTESTED$ncTag '" + $ncr.name + "'")
    Write-Output ("      chain  : " + $ncr.chain)
    Write-Output ("      engine : " + $ncr.verdict)
    if ($ncr.cell) {
      $ncLbl = 'CELL'
      if ($ncr.crown) { $ncLbl = 'CROWN' }
      Write-Output ("      holds a $ncLbl : " + $ncr.cell)
    }
  }
}
foreach ($cbc in $cellContest) {
  $cbcLbl = 'CELL'
  if ($cellNames[[string]$cbc].crown) { $cbcLbl = 'CROWN' }
  Write-Output ("  $cbcLbl-BY-CONTEST  a NEW contested name is holding a $cbcLbl : '" + $cbc + "'  cell " + $cellNames[[string]$cbc].text + "  claimed by: " + $contest[[string]$cbc] + " - two rules both admit this name and array order picked the winner; if the winner is the wrong product then a reader prices a shop off it (the 2026-09-07 BELVITA crown, and the 2026-09-08 Fareway Steamables cell the crown-only reader could not see)")
}

if ($Alert -and ($regr -gt 0 -or $newContest.Count -gt 0 -or $drift -gt 0)) {
  $sig = ([string]$drift + '|' + (($dropped | ForEach-Object { $_.name }) -join ';') + '|' + (($moved | ForEach-Object { $_.name }) -join ';') + '|' + ($newContest -join ';'))
  $sigHash = [BitConverter]::ToString((New-Object Security.Cryptography.SHA256Managed).ComputeHash([Text.Encoding]::UTF8.GetBytes($sig))).Replace('-', '').Substring(0, 16)
  $sigF = Join-Path $audDir 'soundness-alert-sig.txt'
  $last = if (Test-Path $sigF) { (Get-Content $sigF -Raw).Trim() } else { '' }
  if ($sigHash -ne $last) {
    # ONE body builder, driven by the report object, so the email and the console cannot disagree and
    # -SelfTest can assert what the reader will actually receive. See New-SoundnessAlertBody.
    $body = New-SoundnessAlertBody $report
    try { Send-Alert -Subject "Grocery matching soundness - review needed" -Body $body | Out-Null; Set-Content $sigF -Value $sigHash -Encoding UTF8 } catch {}
  }
}
# regressions (moved/dropped of an existing product) HOLD the publish until reviewed+accepted
# EXIT: 2 stays the REGRESSION verdict (a moved/dropped product holds the publish). CELL-BY-CONTEST is
# ADVISORY at 1 - a new class gets a clean week before it can hold a board, and the 2026-09-08 plan's
# do_not_touch keeps it out of guards until Brad rules (open question 1: 7 contested names held cells on
# 2026-09-08, 6 of them genuine fresh produce, so as a HOLD it would page on about six benign names per
# full re-baseline). The verdict line above is the thing to read either way.
if ($regr -gt 0) { Write-GuardComplete -Name 'match-soundness'; exit 2 }
if ($cellContest.Count -gt 0) { Write-Output ('match-soundness: ' + $cellContest.Count + ' CELL-BY-CONTEST finding(s) (CROWN or plain cell, tagged above) - ADVISORY, review the names above before accepting'); Write-GuardComplete -Name 'match-soundness'; exit 1 }
Exit-Guard -Name 'match-soundness' -Code 0
