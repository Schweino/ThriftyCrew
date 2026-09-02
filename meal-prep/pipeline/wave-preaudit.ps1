# wave-preaudit.ps1 - the MECHANICAL half of a wave audit, done by code so the auditor can spend its
# context on judgment.
#
# WHY THIS EXISTS (2026-08-23, PLAN-recipe-hunter-v3 S8 / F3 / D1). The wave-2 NO-GO report - the real
# artifact, still on disk at runs\hunt-2026-08-15-lowcarb-100\waves\wave-2.audit.md - is roughly 80%
# deterministic recomputation: 10/10 macro recomputes from food-macros-db, 10/10 cost reconciliations to
# the cent against db\costed.json, 10 card rebuilds to a scratch dir with a byte-level structural compare,
# protein derivation by construction plus update-recipes-db -DryRun, a voice sweep, and a walk of the
# publish-path gates. Every one of those is ALREADY a script in this pipeline. The auditor re-performed
# them inside a Fable context window, and the audit was 31% of the shakedown's bill. Its actual judgment
# residue - the spinach form-flip, the wrong-price-class call, one Worcestershire condition question - was
# a small fraction of the report.
#
# So this runs the arithmetic and hands the auditor a machine report. It does NOT audit. It cannot issue a
# GO; the recipe-batch-auditor remains the authority, keeps the right to re-derive anything it distrusts,
# and its waves\wave-<k>.audit.md is still the only artifact wave-publish P1/P1b reads. This report is an
# INPUT to that judgment, never a substitute for it.
#
# THE SECOND REASON IT EXISTS is cheap re-audits. A recipe-local repair used to cost a full auditor pass;
# now it costs `-Slugs <the repaired one>` (seconds) plus a scoped sign-off, which is what makes the
# estate's "repair the named recipes and re-audit" instruction affordable enough to actually follow.
#
# EXIT CODES (PLAN v3 section 4.5, the battery convention):
#     0  clean      every check passed
#     1  findings   the machine report IS still written; read it
#     2  could-not-run   missing input, unparseable manifest, no reference card
# EXIT 2 IS A BLOCKED STAGE, NEVER A PASS. Could-not-look is never a clean bill - mechanized here rather
# than left to a reader's discipline. Note this differs from lib\guard-contract.ps1's older 0/1/2/3
# vocabulary (where 2 = hard finding and 3 = could-not-evaluate); v3 section 4.5 fixed ONE convention for
# every new battery and this is it. The completion marker still comes from guard-contract, because
# "did it finish" and "what did it find" are different questions and this estate has conflated them
# at least five times.
#
# Usage:
#   .\wave-preaudit.ps1 -RunDir <run> -Wave 2                     whole wave
#   .\wave-preaudit.ps1 -RunDir <run> -Wave 2 -Slugs a,b          scoped re-audit after a repair
#   .\wave-preaudit.ps1 -RunDir <run> -Wave 2 -SkipLive           no network (the feed-liveness probe)
#   .\wave-preaudit.ps1 -SelfTest                                 frozen fixtures, must-fire + clean twin
param(
  [string]$RunDir = '',
  [int]$Wave = 0,
  [string[]]$Slugs = @(),
  [string]$OutFile = '',
  [string]$ReferenceCard = '',
  [switch]$Json,
  [switch]$SkipLive,
  [switch]$SkipShared,
  [switch]$SelfTest,
  # T6 (2026-08-25). The SPEC STORE, seamable on its own. -Root moves the whole meal-prep tree, which
  # is far too blunt for a drill that wants scratch SPECS beside the live food DB and costed rows.
  # Measured on lf1: the wave-1 auditor reported "the certified spec is the stale 2026-08-16
  # lowcarb-100 build" because this script read db\recipes while the drill was pointed elsewhere
  # through --specs. Empty means the live store, so every existing caller is unchanged.
  [string]$SpecsDir = '',
  [string]$Root = ''
)
$ErrorActionPreference = 'Stop'
# Capture switches BEFORE dot-sourcing anything: in PS 5.1 a dot-sourced param() block binds in THIS
# scope and would reset them (lib\guard-contract.ps1's header records the measured case).
$runSelfTest = [bool]$SelfTest; $runJson = [bool]$Json
$runSkipLive = [bool]$SkipLive; $runSkipShared = [bool]$SkipShared

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = if ($Root) { $Root } else { Split-Path -Parent $here }
$repo = Split-Path -Parent $mp
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $here 'feed-endpoint-lib.ps1')
. (Join-Path $here 'macro-recompute-lib.ps1')   # Get-MacroRecompute - the ONE per-serving arithmetic
# CODE, so it hangs off THIS FILE's location - NOT off $mp. -Root repoints the DATA root, and the
# -SelfTest drill deliberately runs one case against a root that does not exist to prove the tool
# fails cleanly on missing inputs. Routed through $mp, that case died at this dot-source instead,
# so a missing-DATA fixture reported a missing-CODE error (measured 2026-08-27). guard-contract is
# root-relative for the older reason that the drill stages a copy of it; nothing new should be.
. (Join-Path (Split-Path -Parent $here) 'lib\dash-sweep.ps1')   # DASH_SWEEP_SKIP - ONE skip list, shared with build-v2-spec
. (Join-Path (Split-Path -Parent $here) 'lib\package-cost-lib.ps1')   # Get-ScalerGpu / Get-ScalerBasisMismatch - ONE copy of the data-block basis rule

$UTF8 = New-Object Text.UTF8Encoding($false)

# ===================================================================================================
# THRESHOLDS. Named here so a reader never has to find them in the middle of a loop, and so a change is
# a visible diff. PLAN v3 section 4.5 fixes the ones it names; the rest are recorded there too.
# ===================================================================================================
# Macro recompute: the same tolerance build-v2-spec.ps1 enforces at write time (5 cal), extended to the
# three gram macros at 2 g, which is the protein tolerance that guard already used. Matching the build
# guard is deliberate: a spec that passed the build must pass this, or one of the two is lying.
$script:MACRO_CAL_TOL  = 5.0
$script:MACRO_GRAM_TOL = 2.0
# Money reconciliation is to the cent, so half a cent is the comparison epsilon.
$script:CENT = 0.005
# The house batch size. A spec that is not 14 servings is not a defect this battery rules on, but the
# macro recompute has to divide by SOMETHING and silently guessing 14 on a 12-serving spec would invent
# a drift; it divides by the spec's own servings and reports the number it used.
$script:HOUSE_SERVINGS = 14

# ===================================================================================================
# PURE PREDICATES - so every founding case can be pinned without a live file, a spec, or a network.
# ===================================================================================================

function New-Check {
  <# The one shape every check returns, per PLAN v3 section 4.5. `numbers` carries the figures the
     auditor would otherwise have to recompute to believe the verdict; `detail` is the sentence. #>
  param([string]$Check, [bool]$Pass, $Numbers = $null, [string]$Detail = '')
  return [ordered]@{
    check   = $Check
    verdict = $(if ($Pass) { 'pass' } else { 'fail' })
    numbers = $(if ($null -eq $Numbers) { [ordered]@{} } else { $Numbers })
    detail  = $Detail
  }
}

# Get-MacroRecompute MOVED 2026-08-24 to macro-recompute-lib.ps1 (dot-sourced above), because D8's
# build-intake-skeleton.ps1 needs the identical arithmetic and a fourth copy of it is the
# two-copies-of-the-same-math trap this estate already has a scar from. Behaviour is unchanged and
# this file's own fixtures still prove it - they are the reason this copy was the one that moved.

function Test-MacroDrift {
  <# Which of the four macros drift past tolerance. Returns the list of complaints, empty when clean. #>
  param($Computed, $Stat, [double]$CalTol, [double]$GramTol)
  $out = New-Object System.Collections.Generic.List[string]
  $pairs = @(
    @{ k = 'cal';     s = 'cal';     tol = $CalTol;  unit = 'cal' },
    @{ k = 'protein'; s = 'protein'; tol = $GramTol; unit = 'g protein' },
    @{ k = 'carbs';   s = 'carbs';   tol = $GramTol; unit = 'g carbs' },
    @{ k = 'fat';     s = 'fat';     tol = $GramTol; unit = 'g fat' }
  )
  foreach ($p in $pairs) {
    $c = [double]$Computed[$p.k]
    $v = [double]$Stat.($p.s)
    if ([Math]::Abs($c - $v) -gt $p.tol) {
      $out.Add(("{0}: recompute {1} vs stat {2} (drift {3:N1}, tolerance {4})" -f $p.unit, $c, $v, [Math]::Abs($c - $v), $p.tol))
    }
  }
  return , @($out)
}

function Test-WidgetCountBasis {
  <#
    DOES THE CARD'S COST WIDGET BUY WHAT THE CARD'S COST LINE SAYS TO BUY? (2026-09-02, queue
    2026-09-02-corn04.)

    The card carries two package counts. The static "Buy 4 cans" line is the engine's, computed as
    ceil(grams/pkg_g - 0.02). The widget, the print list and the store picker all compute their own from
    the baked data block as ceil((grams/gpu) / packageBasis). Those agree only when grams, pkg_g and gpu
    are on ONE basis, and for every canned line they were not: grams and pkg_g went DRAINED when the
    engine learned a drained yield, gpu stayed the ingredient row's GROSS grams per feed unit. 88 of 105
    same-package drained lines bought short across 76 live cards, and no gate could see it - build-card2
    checked ceil(grams/pkg_g) == buy_n, and the gpu cancels out of that expression.

    So this asks the question that does NOT cancel:

      (a) COUNT   the block's own count must equal the engine's Buy N at base, and must track the engine
                  rule at every serving count the control offers (2..42). Cheap, and it catches a card
                  built against a package the engine has since moved off.
      (b) PACKAGE the block's authored fallback package, pkg_g/gpu, must be the package a shopper picks
                  up: db\ingredients.json's buy_pkg_g/gpu for that item. THIS is the half that fires.
                  street corn's block worked out at a 10.51 oz can. The can is 15.24 oz.

    Only lines with a real BUY package are asked. A bulk staple's block carries its pantry container, not
    its buy package, and a label-priced line has no ingredients.json package to compare against - both
    are skipped rather than guessed at, because a check that invents a reference is a check that cries
    wolf. Returns the list of complaints, empty when clean.

    $Lines is one joined record per block line:
      item, grams, gpu, pkg_g   from the built data block (the bytes the browser reads)
      buy_n                     from db\costed.json - the number the static line prints
      ing_gpu, ing_buy_pkg_g    from db\ingredients.json - an INDEPENDENT statement of the package
  #>
  param($Lines, [int]$Base = 14, [int]$MinServ = 2, [int]$MaxServ = 42)
  $out = New-Object System.Collections.Generic.List[string]
  # NO @() AROUND $Lines. This file already pins the reason in its own fixtures: @() on a
  # List[object] THROWS in PS 5.1 ("Argument types do not match"), and it threw here on the first
  # drill. Callers hand over an array (.ToArray() on a list); a bare foreach handles both.
  if ($null -eq $Lines) { return , @() }
  foreach ($l in $Lines) {
    $grams = [double]$l.grams; $gpu = [double]$l.gpu; $pkgG = [double]$l.pkg_g
    if ($pkgG -le 0 -or $gpu -le 0) { continue }          # covered line, or a line the widget cannot price
    if ($null -eq $l.buy_n) { continue }                  # no engine count to compare against
    $buyN = [int]$l.buy_n
    # (a) at base, and across the whole range of the serving control
    $basis = $pkgG / $gpu
    for ($nn = $MinServ; $nn -le $MaxServ; $nn++) {
      $g = $grams * $nn / $Base
      $kBlock  = [int][Math]::Max(1, [Math]::Ceiling(($g / $gpu) / $basis - 0.02))
      $kEngine = [int][Math]::Max(1, [Math]::Ceiling($g / $pkgG - 0.02))
      if ($kBlock -ne $kEngine) {
        $out.Add(("{0}: at {1} servings the widget buys {2} package(s), the engine rule {3} (grams {4}, gpu {5}, pkg_g {6})" -f $l.item, $nn, $kBlock, $kEngine, $grams, $gpu, $pkgG))
        break
      }
      if ($nn -eq $Base -and $kEngine -ne $buyN) {
        $out.Add(("{0}: the cost line says buy {1}, but ceil({2} g / {3} g - 0.02) is {4} - this card is stale against db\costed.json" -f $l.item, $buyN, $grams, $pkgG, $kEngine))
        break
      }
    }
    # (b) the fallback package must be a package that exists
    $ingGpu = [double]$l.ing_gpu; $ingPkg = [double]$l.ing_buy_pkg_g
    if ($ingGpu -gt 0 -and $ingPkg -gt 0) {
      $bad = Get-ScalerBasisMismatch $pkgG $gpu $ingPkg $ingGpu
      if ($null -ne $bad) {
        $out.Add(("{0}: the block's fallback package is {1:N2} units but the item's package is {2:N2} units ({3:P2} off) - gpu is on the wrong basis, so every count the widget, the print list and the store picker show is derived from a package that does not exist" -f $l.item, $bad.fallback, $bad.physical, $bad.rel))
      }
    }
  }
  return , @($out)
}

function Test-CostEngineConsistency {
  <#
    Is the ENGINE ROW internally coherent? This asks nothing about the spec and nothing about today's
    prices, so it is true whenever it is run - which is why it is a separate check from the spec
    comparison below. Every clause here is one the wave-2 auditor performed by hand:
      * the per-line util costs sum to the batch total (a dropped line shows up nowhere else)
      * per-serving is the batch over the servings, both tiers
      * first run is the true batch plus the pantry add
      * the tiers are ordered: batch <= true <= first run
      * lines_unpriced is zero  (cost-recipes prices an unbid line at $0.00 WITHOUT failing)
      * no non-optional line costs nothing WITHOUT pricing evidence (a sub-cent pinch is legitimate)
  #>
  param($Row, [int]$Servings, [double]$Tol)
  $p = New-Object System.Collections.Generic.List[string]
  $lines = @($Row.lines)
  $sum = 0.0; foreach ($l in $lines) { $sum += [double]$l.util_cost }
  $sum = [Math]::Round($sum, 2)
  $batch = [double]$Row.cost_batch
  if ([Math]::Abs($sum - $batch) -gt $Tol) { $p.Add(("line utils sum to {0:N2} but cost_batch is {1:N2}" -f $sum, $batch)) }
  $n = [Math]::Max(1, $Servings)
  $psExp = [Math]::Round($batch / $n, 2)
  if ([Math]::Abs($psExp - [double]$Row.cost_per_serving) -gt $Tol) {
    $p.Add(("cost_per_serving {0} is not cost_batch/{1} = {2:N2}" -f $Row.cost_per_serving, $n, $psExp))
  }
  $trueB = [double]$Row.cost_batch_true
  $psTExp = [Math]::Round($trueB / $n, 2)
  if ([Math]::Abs($psTExp - [double]$Row.cost_per_serving_true) -gt $Tol) {
    $p.Add(("cost_per_serving_true {0} is not cost_batch_true/{1} = {2:N2}" -f $Row.cost_per_serving_true, $n, $psTExp))
  }
  $frExp = [Math]::Round($trueB + [double]$Row.cost_pantry_add, 2)
  if ([Math]::Abs($frExp - [double]$Row.cost_first_run) -gt $Tol) {
    $p.Add(("cost_first_run {0} is not cost_batch_true + cost_pantry_add = {1:N2}" -f $Row.cost_first_run, $frExp))
  }
  if ($batch -gt $trueB + $Tol) { $p.Add(("tiers out of order: cost_batch {0:N2} exceeds cost_batch_true {1:N2}" -f $batch, $trueB)) }
  if ($trueB -gt [double]$Row.cost_first_run + $Tol) { $p.Add(("tiers out of order: cost_batch_true {0:N2} exceeds cost_first_run {1:N2}" -f $trueB, [double]$Row.cost_first_run)) }
  if ([int]$Row.lines_unpriced -ne 0) {
    $p.Add(("lines_unpriced is {0} - the published cost EXCLUDES an ingredient the reader must buy" -f $Row.lines_unpriced))
  }
  foreach ($l in $lines) {
    if ([double]$l.util_cost -gt 0) { continue }
    # A zero util_cost is only a defect when the line is UNPRICED. A 1-3 g pinch of salt or sugar on a
    # real board basis costs a fraction of a cent and the engine cent-floors it to $0.00 - three
    # consecutive wave audits (hunt-2026-08-27-highprotein waves 9, 10 and 13) re-derived that same
    # false positive BY HAND before this clause was narrowed on 2026-08-29, and ten live costed.json
    # lines carry the identical shape. So the test is the PRICING EVIDENCE, not the number: a basis,
    # and at least one of buy_cost / starter_cost. A line missing either still fires - that is the
    # genuinely unpriced case this clause was written for. A negative util cost is never explicable.
    $hasBasis = -not [string]::IsNullOrWhiteSpace([string]$l.basis)
    $hasCost  = (-not [string]::IsNullOrWhiteSpace([string]$l.buy_cost)) -or (-not [string]::IsNullOrWhiteSpace([string]$l.starter_cost))
    if ([double]$l.util_cost -lt 0 -or -not ($hasBasis -and $hasCost)) {
      $p.Add(("'{0}' costs nothing ({1})" -f [string]$l.item, [double]$l.util_cost))
    }
  }
  return , @($p)
}

function Test-CostSpecVsEngine {
  <#
    Does the SPEC print the numbers the engine computed? Six fields, to the cent.
    A drift here means the card ships a price the current board no longer supports. The usual cause is
    age, not a defect - db\costed.json is regenerated whenever grocery prices move, and a spec built last
    week keeps its build-time figures until a recost pass rewrites them - so the caller records both
    mtimes alongside this and the FIX is recost-spec-cost-block.ps1, not a rebuild. It is still a
    finding: a wave about to publish must not print a stale price.
  #>
  param($Spec, $Row, [double]$Tol)
  $p = New-Object System.Collections.Generic.List[string]
  foreach ($f in @('cost_batch', 'cost_batch_true', 'cost_per_serving', 'cost_per_serving_true', 'cost_pantry_add', 'cost_first_run')) {
    $sv = [double]$Spec.$f
    $ev = [double]$Row.$f
    if ([Math]::Abs($sv - $ev) -gt $Tol) { $p.Add(("{0}: spec {1} vs engine {2}" -f $f, $sv, $ev)) }
  }
  return , @($p)
}

# THE PROTEIN REGEX IS A COPY, AND THE SELF-TEST KNOWS IT. Get-ProteinCat in meal-prep\build-hub-grid.ps1
# is the estate's reading of "which protein is this dish" and every site surface uses it. A second copy
# here would drift the first time either is tightened - the exact shape spec-contradiction-lib.ps1 exists
# to prevent - so the fixture below asserts these four patterns against that file's source text. Tighten
# one and the other goes red on the next run.
$script:PROTEIN_TURKEY  = 'turkey'
$script:PROTEIN_CHICKEN = 'chicken'
$script:PROTEIN_BEEF    = 'ground beef|beef|steak|chuck|sirloin|brisket|\bkofta\b|meatball'
$script:PROTEIN_BEEF_NOT = 'turkey|chicken|pork'
$script:PROTEIN_PORK    = 'pork|sausage|chorizo|bacon|\bham\b|prosciutto|pancetta|kielbasa|carnitas|\bribs?\b'

function Get-ProteinByGrams {
  <#
    The heaviest protein family by grams, which is what "protein derivation by construction" means: the
    spec's protein field is a claim about the dish, and the dish's ingredient grams either back it or do
    not. Returns @{ cat; grams; tally } with cat $null when nothing classified - Bratwurst is the recorded
    miss (build-hub-grid's own comment names it), and a null there is honestly reported, never guessed.
  #>
  param($Rows)
  $tally = [ordered]@{ chicken = 0.0; turkey = 0.0; beef = 0.0; pork = 0.0 }
  foreach ($r in @($Rows)) {
    $n = ([string]$r.item).ToLower()
    $g = [double]$r.grams
    $cat = $null
    if ($n -match $script:PROTEIN_TURKEY) { $cat = 'turkey' }
    elseif ($n -match $script:PROTEIN_CHICKEN) { $cat = 'chicken' }
    elseif ($n -match $script:PROTEIN_BEEF -and $n -notmatch $script:PROTEIN_BEEF_NOT) { $cat = 'beef' }
    elseif ($n -match $script:PROTEIN_PORK) { $cat = 'pork' }
    if ($cat) { $tally[$cat] = [double]$tally[$cat] + $g }
  }
  $best = $null; $bestG = 0.0
  foreach ($k in @($tally.Keys)) { if ([double]$tally[$k] -gt $bestG) { $bestG = [double]$tally[$k]; $best = $k } }
  return [ordered]@{ cat = $best; grams = [Math]::Round($bestG, 0); tally = $tally }
}

function Get-DashHits {
  <#
    The em/en dash sweep, over every string in the object - collecting instead of throwing so one
    report can name them all. Brad's rule is absolute and it is checked at three layers on purpose;
    this is the layer that can tell the auditor which field.

    IT SKIPS THE BAN LIST, AND THE SKIP LIST IS SHARED (2026-08-27). `forbidden_prose_terms` is the
    intake's list of characters the writer may NOT use, and an em dash is its first entry in every
    recipe that carries one. Sweeping it reports a spec for containing the very character it bans.
    build-v2-spec had exactly this defect and it REFUSED three recipes outright; the fix there moved
    the walk into lib/dash-sweep.ps1 - and THIS second copy was missed, so the same false positive
    returned one layer up, on wave 1 of hunt-2026-08-27-highprotein, against two specs with zero
    dashes in any reader-facing string. The wave auditor caught it and wrote: "or every spec that
    correctly bans dashes will fail forever".

    So both layers now read ONE skip list, $script:DASH_SWEEP_SKIP, dot-sourced from that lib. A
    guard duplicated across two files is a guard that will disagree with itself - and fixing one copy
    while leaving the other is precisely how this one got here.
  #>
  param($Obj, [int]$Cap = 12)
  $hits = New-Object System.Collections.Generic.List[string]
  $q = New-Object System.Collections.Generic.Queue[object]
  $q.Enqueue($Obj)
  while ($q.Count -gt 0 -and $hits.Count -lt $Cap) {
    $v = $q.Dequeue()
    if ($null -eq $v) { continue }
    if ($v -is [string]) {
      if ($v -match [char]0x2014) { $hits.Add('EM DASH: ' + $v.Substring(0, [Math]::Min(70, $v.Length))) }
      elseif ($v -match [char]0x2013) { $hits.Add('EN DASH: ' + $v.Substring(0, [Math]::Min(70, $v.Length))) }
      continue
    }
    if ($v -is [System.Collections.IDictionary]) {
      foreach ($k in @($v.Keys)) { if ($script:DASH_SWEEP_SKIP -notcontains [string]$k) { $q.Enqueue($v[$k]) } }
      continue
    }
    if ($v -is [System.Collections.IEnumerable]) { foreach ($vv in $v) { $q.Enqueue($vv) }; continue }
    if ($v -is [psobject] -and $v.PSObject.Properties.Count -gt 0) {
      foreach ($p in $v.PSObject.Properties) { if ($script:DASH_SWEEP_SKIP -notcontains [string]$p.Name) { $q.Enqueue($p.Value) } }
    }
  }
  return , @($hits)
}

function Get-CardMarkers {
  <# The structural skeleton of a rendered card: its smp-* class vocabulary and its non-step ids. #>
  param([string]$Html)
  $cls = New-Object System.Collections.Generic.HashSet[string]
  foreach ($m in [regex]::Matches($Html, 'class="([^"]+)"')) {
    foreach ($c in ($m.Groups[1].Value -split '\s+')) { if ($c -like 'smp-*') { [void]$cls.Add($c) } }
  }
  $ids = New-Object System.Collections.Generic.HashSet[string]
  foreach ($m in [regex]::Matches($Html, 'id="([A-Za-z0-9\-_]+)"')) {
    $v = $m.Groups[1].Value
    if ($v -notmatch '^step\d+$') { [void]$ids.Add($v) }
  }
  return [ordered]@{ classes = $cls; ids = $ids }
}

function Get-CardStructuralGaps {
  <#
    Byte-level structural compare against a KNOWN-GOOD card. Measured 2026-08-23 over all 570 live cards:
    64 smp-* classes and 4 ids (smp-ing / smp-cost / smp-make / smp-portion) are universal, and the only
    variable pair is smp-credit / smp-credit-eyebrow, which a card carries when the recipe has a source
    credit. Every hunted recipe has one, so the reference card is chosen WITH a credit and a rebuild that
    lost it is a finding rather than an exemption.
    Comparing marker SETS rather than a frozen list is what keeps this from rotting: change the template
    and the reference changes with it, so the check follows the template instead of expiring against it.
  #>
  param([string]$Rebuilt, [string]$Reference, [int]$StepCount)
  $gaps = New-Object System.Collections.Generic.List[string]
  $r = Get-CardMarkers $Rebuilt
  $g = Get-CardMarkers $Reference
  $missCls = @(@($g.classes) | Where-Object { -not $r.classes.Contains($_) } | Sort-Object)
  $missIds = @(@($g.ids) | Where-Object { -not $r.ids.Contains($_) } | Sort-Object)
  if ($missCls.Count) { $gaps.Add(("the rebuild is missing {0} structural class(es) the reference card carries: {1}" -f $missCls.Count, ($missCls -join ', '))) }
  if ($missIds.Count) { $gaps.Add(("the rebuild is missing anchor id(s): " + ($missIds -join ', '))) }
  if ($StepCount -gt 0) {
    $steps = @([regex]::Matches($Rebuilt, 'id="step(\d+)"') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique)
    $want = @(1..$StepCount)
    $missSteps = @($want | Where-Object { $steps -notcontains $_ })
    if ($missSteps.Count) { $gaps.Add(("the make-it steps have no anchor id for step(s) {0} - the JSON-LD points at those anchors" -f ($missSteps -join ', '))) }
  }
  if ($Rebuilt.IndexOf([char]0x2014) -ge 0) { $gaps.Add('the rebuilt card contains an EM DASH byte') }
  if ($Rebuilt.IndexOf([char]0x2013) -ge 0) { $gaps.Add('the rebuilt card contains an EN DASH byte') }
  return , @($gaps)
}

function Get-DryRunNullIds {
  <#
    update-recipes-db -DryRun prints one line naming where every item_id came from. A null id is a row the
    meal-plan-builder's grocery merge cannot join, which is what "protein derivation + -DryRun" is really
    checking. Returns -1 when the line is absent, which the caller must treat as could-not-look.
  #>
  param($Lines)
  foreach ($l in @($Lines)) {
    $m = [regex]::Match([string]$l, 'no id \(null\)\s+(\d+)\s+rows')
    if ($m.Success) { return [int]$m.Groups[1].Value }
  }
  return -1
}

function Get-SharedVerdict {
  <#
    A child gate is clean only when BOTH answers agree: rc 0 AND its own completion marker. The estate has
    been bitten five separate times by conflating them - a detector that dies mid-run is silent, because
    "no findings" and "never ran" look identical from outside. Same reading wave-publish's Invoke-Gate
    uses; kept here because this battery runs the gates concurrently and needs the verdict per child.
  #>
  param([int]$Rc, $Lines, [string]$Marker)
  if ($Rc -eq 0 -and $Marker -and -not (Test-GuardComplete $Lines $Marker)) {
    return @{ pass = $false; why = ("exited 0 but never printed {0}-COMPLETE, so it did not finish" -f $Marker.ToUpper()) }
  }
  if ($Rc -ne 0) { return @{ pass = $false; why = ("exited {0}" -f $Rc) } }
  return @{ pass = $true; why = '' }
}

# ===================================================================================================
# SELF-TEST - every check's founding case, must-fire first, clean twin beside it.
# ===================================================================================================
if ($runSelfTest) {
  $f = 0
  function T($msg, $cond, $got) { if ($cond) { Write-Output ("ok    " + $msg) } else { Write-Output ("FAIL  " + $msg + "   got: " + $got); $script:f++ } }

  # ---- macro recompute ----------------------------------------------------------------------------
  $db = @{
    'Ground Beef' = [pscustomobject]@{ serving_grams = 112; calories = 280; protein_g = 19; carbs_g = 0; fat_g = 22 }
    'Rice'        = [pscustomobject]@{ serving_grams = 45;  calories = 160; protein_g = 3;  carbs_g = 36; fat_g = 0 }
  }
  $rows = @([pscustomobject]@{ item = 'Ground Beef'; grams = 1568 }, [pscustomobject]@{ item = 'Rice'; grams = 630 })
  $rc = Get-MacroRecompute $rows $db 14
  # 1568/112 = 14 servings of beef -> 3920 cal; 630/45 = 14 -> 2240 cal; /14 servings = 440 cal
  T 'the recompute is the build guard''s arithmetic (grams/serving_grams, then /servings)' `
    ($rc.cal -eq 440 -and $rc.protein -eq 22 -and $rc.carbs -eq 36 -and $rc.fat -eq 22) ("cal=$($rc.cal) p=$($rc.protein) c=$($rc.carbs) f=$($rc.fat)")

  # THE FOUNDING CASE, frozen: a spec whose stat no longer matches its own grams. The wave-2 auditor
  # recomputed all ten by hand to find the one that mattered; this is that arithmetic, mechanized.
  $statBad  = [pscustomobject]@{ cal = 520; protein = 22; carbs = 36; fat = 22 }
  $statGood = [pscustomobject]@{ cal = 441; protein = 22; carbs = 36; fat = 22 }
  # EVERY PREDICATE RESULT BELOW IS ASSIGNED BARE, and that is load-bearing, not style. These functions
  # return `,@(...)` so a single finding cannot unroll on output; wrapping THAT call in @() re-wraps the
  # whole array into ONE element, so .Count reads 1 for two findings and - the dangerous half - 1 for
  # ZERO findings, while -join renders it as the literal 'System.Object[]'. wave-publish.ps1 carries the
  # same warning over Get-StaleAuditProblems; it still cost this file seven red fixtures on 2026-08-23.
  # Measured 0/1/2 findings both ways.
  $dBad = Test-MacroDrift $rc $statBad $script:MACRO_CAL_TOL $script:MACRO_GRAM_TOL
  T 'MUST FIRE  a stat calorie figure 80 over its own recompute is caught' ($dBad.Count -ge 1) ($dBad -join ' | ')
  $dGood = Test-MacroDrift $rc $statGood $script:MACRO_CAL_TOL $script:MACRO_GRAM_TOL
  T 'CLEAN TWIN a 1-cal rounding seam is inside tolerance and stays quiet' ($dGood.Count -eq 0) ($dGood -join ' | ')
  # the gram macros were NOT checked before v3; the wave-2 report recomputed all four and this is why
  $statCarb = [pscustomobject]@{ cal = 441; protein = 22; carbs = 90; fat = 22 }
  $dCarb = Test-MacroDrift $rc $statCarb $script:MACRO_CAL_TOL $script:MACRO_GRAM_TOL
  T 'MUST FIRE  a CARB drift is caught, not just calories and protein' ($dCarb.Count -ge 1) ($dCarb -join ' | ')
  $rcMiss = Get-MacroRecompute (@($rows) + @([pscustomobject]@{ item = 'Sumac'; grams = 62 })) $db 14
  T 'MUST FIRE  an ingredient with no food-DB row is NAMED, never silently skipped' `
    (@($rcMiss.missing) -contains 'Sumac') ('missing=' + (@($rcMiss.missing) -join ','))

  # ---- cost ---------------------------------------------------------------------------------------
  # A real row, keto-cheeseburger-skillet's shape, reduced to three lines that sum exactly.
  function NewRow($batch, $true_, $ps, $psT, $pantry, $first, $unpriced, $utils) {
    $ls = @(); $i = 0
    foreach ($u in $utils) { $i++; $ls += [pscustomobject]@{ item = "Line$i"; util_cost = $u } }
    return [pscustomobject]@{ cost_batch = $batch; cost_batch_true = $true_; cost_per_serving = $ps
      cost_per_serving_true = $psT; cost_pantry_add = $pantry; cost_first_run = $first
      lines_unpriced = $unpriced; lines = $ls }
  }
  $good = NewRow 24.25 31.56 1.73 2.25 5.67 37.23 0 @(17.31, 5.47, 1.47)
  $pGood = Test-CostEngineConsistency $good 14 $script:CENT
  T 'CLEAN TWIN a coherent engine row reports nothing' ($pGood.Count -eq 0) ($pGood -join ' | ')
  # THE FOUNDING CASE, frozen from 2026-08-16: sheet-pan-smoked-sausage-broccoli-cheddar published at
  # $2.12 for the batch and $0.15 a serving with 3 lb of andouille in it, because the cost engine dropped
  # two lines. Every "could it be priced" gate passed; only the arithmetic was absurd.
  $dropped = NewRow 24.25 31.56 1.73 2.25 5.67 37.23 0 @(17.31, 1.47)
  $pDrop = Test-CostEngineConsistency $dropped 14 $script:CENT
  T 'MUST FIRE  line utils that do not sum to the batch total are caught (a dropped cost line)' `
    ($pDrop.Count -ge 1) ($pDrop -join ' | ')
  $unpriced = NewRow 24.25 31.56 1.73 2.25 5.67 37.23 1 @(17.31, 5.47, 1.47)
  $pUnpriced = Test-CostEngineConsistency $unpriced 14 $script:CENT
  T 'MUST FIRE  lines_unpriced above zero is caught (cost-recipes prices an unbid line at $0.00)' `
    (($pUnpriced -join ' ') -match 'lines_unpriced') ($pUnpriced -join ' | ')
  # The zero-cost clause has TWO cardinalities and the fixtures below pin both, because between
  # 2026-08-16 and 2026-08-29 it only had one and produced a false positive in three consecutive
  # wave audits. A $0.00 line is a defect when nothing PRICED it; it is arithmetic when a real basis
  # and a real package price cent-floor a 1-3 g pinch to zero.
  $zero = NewRow 24.25 31.56 1.73 2.25 5.67 37.23 0 @(17.31, 5.47, 1.47, 0)
  $pZero = Test-CostEngineConsistency $zero 14 $script:CENT
  T 'MUST FIRE  a zero-cost line with NO basis and no package price is named (genuinely unpriced)' `
    (($pZero -join ' ') -match 'costs nothing') ($pZero -join ' | ')
  # basis present, but neither buy_cost nor starter_cost - nothing priced it, so it still fires
  $zeroNoCost = NewRow 24.25 31.56 1.73 2.25 5.67 37.23 0 @(17.31, 5.47, 1.47)
  $zeroNoCost.lines += [pscustomobject]@{ item = 'Sumac'; grams = 4; util_cost = 0
    basis = 'board:sumac:walmart'; carriage = 'CARRIED'; buy_cost = $null; starter_cost = $null }
  $pZeroNC = Test-CostEngineConsistency $zeroNoCost 14 $script:CENT
  T 'MUST FIRE  a zero-cost line with a basis but NO buy_cost and NO starter_cost is named' `
    (($pZeroNC -join ' ') -match "'Sumac' costs nothing") ($pZeroNC -join ' | ')
  # THE 2026-08-29 CASE, frozen from blackened-chicken-with-mango-salsa: 1 g of salt off
  # board:salt:walmart, a 26oz/737g canister at $0.94, is $0.0013 - a real price the cent rounds away.
  # Waves 9, 10 and 13 of hunt-2026-08-27-highprotein each cleared this by hand before the fix.
  $pinch = NewRow 24.25 31.56 1.73 2.25 5.67 37.23 0 @(17.31, 5.47, 1.47)
  $pinch.lines += [pscustomobject]@{ item = 'Salt'; grams = 1; util_cost = 0
    basis = 'board:salt:walmart'; carriage = 'CARRIED'; bulk = $true; buy_cost = $null
    starter_n = 1; starter_cost = 0.94; starter_pkg = '26oz canister'; starter_pkg_g = 737 }
  $pPinch = Test-CostEngineConsistency $pinch 14 $script:CENT
  T 'CLEAN TWIN a fully priced sub-cent pinch that rounds to $0.00 is NOT a finding' `
    ($pPinch.Count -eq 0) ($pPinch -join ' | ')
  $badTier = NewRow 40.00 31.56 2.86 2.25 5.67 37.23 0 @(40.00)
  $pTier = Test-CostEngineConsistency $badTier 14 $script:CENT
  T 'MUST FIRE  tiers out of order (batch above true) are caught' `
    (($pTier -join ' ') -match 'out of order') ($pTier -join ' | ')

  $specGood = [pscustomobject]@{ cost_batch = 24.25; cost_batch_true = 31.56; cost_per_serving = 1.73
    cost_per_serving_true = 2.25; cost_pantry_add = 5.67; cost_first_run = 37.23 }
  $pFresh = Test-CostSpecVsEngine $specGood $good $script:CENT
  T 'CLEAN TWIN a spec printing the engine''s own numbers reconciles' ($pFresh.Count -eq 0) ($pFresh -join ' | ')
  $specStale = [pscustomobject]@{ cost_batch = 19.32; cost_batch_true = 23.51; cost_per_serving = 1.38
    cost_per_serving_true = 1.68; cost_pantry_add = 5.67; cost_first_run = 24.83 }
  $pStale = Test-CostSpecVsEngine $specStale $good $script:CENT
  T 'MUST FIRE  a spec printing a stale price is caught to the cent' ($pStale.Count -ge 4) ('count=' + $pStale.Count)
  $specPenny = [pscustomobject]@{ cost_batch = 24.25; cost_batch_true = 31.56; cost_per_serving = 1.73
    cost_per_serving_true = 2.25; cost_pantry_add = 5.67; cost_first_run = 37.234 }
  $pPenny = Test-CostSpecVsEngine $specPenny $good $script:CENT
  T 'a sub-cent rounding seam does not trip the reconciliation' ($pPenny.Count -eq 0) ($pPenny -join ' | ')

  # ---- widget count basis (2026-09-02, queue 2026-09-02-corn04) -------------------------------------
  # FROZEN from the block street-corn-chicken-rice-bowls was carrying when the defect was found: grams
  # and pkg_g on the DRAINED basis, gpu on the GROSS one, against a 432 g can. NEVER regenerate these
  # from db\built - the moment the renderer is fixed no live card carries them, and a regenerated
  # fixture would pass by finding nothing.
  function WcbLine($item, $grams, $gpu, $pkgG, $buyN, $ingGpu, $ingPkg) {
    return [pscustomobject]@{ item = $item; grams = $grams; gpu = $gpu; pkg_g = $pkgG; buy_n = $buyN
                              ing_gpu = $ingGpu; ing_buy_pkg_g = $ingPkg }
  }
  $cornShipped = WcbLine 'Sweet Whole Kernel Corn' 1148 28.35 298 4 28.3495 432
  # ASSIGNED BARE, like every other predicate result in this file: Test-WidgetCountBasis returns
  # `,@(...)` so a single finding cannot unroll on output, and wrapping THAT call in @() re-wraps the
  # whole array into ONE element - .Count then reads 1 for two findings and, the dangerous half, 1 for
  # ZERO. This file has paid for that trap once already (Get-StaleAuditProblems, seven red fixtures).
  $wShipped = Test-WidgetCountBasis @($cornShipped)
  T 'MUST FIRE  street corn''s shipped block is refused: its fallback package is a 10.51 oz can and the can is 15.24 oz' `
    ($wShipped.Count -ge 1 -and ($wShipped -join ' ') -match 'fallback package') ($wShipped -join ' | ')
  # ...AND THE COUNT HALF STAYS SILENT ON IT, which is the whole reason half (b) exists. gpu cancels out
  # of ceil((g/gpu)/(pkg_g/gpu)), so a count comparison can never see a wrong gpu. Pinned so nobody
  # "simplifies" this check down to the half that cannot fire.
  T 'MUST FIRE  ...and the COUNT half is blind to it, so (b) is not redundant' `
    ($wShipped.Count -eq 1) ('findings=' + $wShipped.Count + ' :: ' + ($wShipped -join ' | '))
  # THE FIXED BLOCK: same line, gpu on its own basis. Silent.
  $cornFixed = WcbLine 'Sweet Whole Kernel Corn' 1148 19.5563 298 4 28.3495 432
  $wFixed = Test-WidgetCountBasis @($cornFixed)
  T 'CLEAN TWIN the same line with gpu on this line''s basis passes at every serving count 2..42' `
    ($wFixed.Count -eq 0) ($wFixed -join ' | ')
  # THE STALE CARD: a correct basis, but a cost line that says 3 where the block's own package says 4.
  $cornStale = WcbLine 'Sweet Whole Kernel Corn' 1148 19.5563 298 3 28.3495 432
  $wStale = Test-WidgetCountBasis @($cornStale)
  T 'MUST FIRE  a card whose cost line says buy 3 where its own package math says 4 is caught' `
    ($wStale.Count -ge 1 -and ($wStale -join ' ') -match 'stale against') ($wStale -join ' | ')
  # NON-DRAINED LINES MUST BE SILENT, or the check is only reporting the drained flag. Refried Beans:
  # a 454 g package that is its own gross weight.
  $refried = WcbLine 'Refried Beans' 454 28.3495 454 1 28.3495 454
  $wRefried = Test-WidgetCountBasis @($refried)
  T 'CLEAN TWIN a non-drained line is silent, so the check is not just re-reporting "this item drains"' `
    ($wRefried.Count -eq 0) ($wRefried -join ' | ')
  # A LABEL-PRICED LINE HAS NO ingredients.json PACKAGE. Half (b) must skip rather than invent a
  # reference; half (a) still applies.
  $labelled = WcbLine 'Chili Crisp' 180 28.3495 190 1 0 0
  $wLabelled = Test-WidgetCountBasis @($labelled)
  T 'CLEAN TWIN a label-priced line with no ingredients package is skipped by (b), not guessed at' `
    ($wLabelled.Count -eq 0) ($wLabelled -join ' | ')
  # A COVERED LINE CARRIES pkg_g 0 AND MUST NOT DIVIDE BY IT.
  $covered = WcbLine 'Lemon Zest' 5 28.3495 0 $null 28.3495 0
  $wCovered = Test-WidgetCountBasis @($covered)
  T 'CLEAN TWIN a covered line (no package) is skipped without dividing by zero' `
    ($wCovered.Count -eq 0) ($wCovered -join ' | ')

  # ---- protein derivation -------------------------------------------------------------------------
  $beefy = @([pscustomobject]@{ item = '80/20 Ground Beef'; grams = 1588 }, [pscustomobject]@{ item = 'Hickory Smoked Bacon'; grams = 168 })
  $pd = Get-ProteinByGrams $beefy
  T 'CLEAN TWIN a beef dish garnished with bacon derives as BEEF, by grams' ($pd.cat -eq 'beef') $pd.cat
  $porky = @([pscustomobject]@{ item = 'Andouille Sausage'; grams = 1360 }, [pscustomobject]@{ item = 'Yellow Onion'; grams = 200 })
  T 'CLEAN TWIN an andouille dish derives as PORK' ((Get-ProteinByGrams $porky).cat -eq 'pork') (Get-ProteinByGrams $porky).cat
  T 'MUST FIRE  a dish with no classifiable protein returns null, it does not guess' `
    ($null -eq (Get-ProteinByGrams @([pscustomobject]@{ item = 'Bratwurst'; grams = 900 })).cat) 'guessed a category'

  # THE LOCKSTEP FIXTURE. build-hub-grid.ps1's Get-ProteinCat is the estate's copy of this reading and
  # every site surface uses it. If it is tightened and this file is not, the two disagree silently - so
  # this asserts the patterns against that file's source text. Red here means: go copy the change over.
  $hubPath = Join-Path $mp 'build-hub-grid.ps1'
  if (Test-Path $hubPath) {
    $hub = [IO.File]::ReadAllText($hubPath, [Text.Encoding]::UTF8)
    T 'LOCKSTEP  the beef pattern still matches build-hub-grid.ps1''s Get-ProteinCat' `
      ($hub.Contains($script:PROTEIN_BEEF)) 'build-hub-grid''s beef pattern has moved - copy it over'
    T 'LOCKSTEP  the pork pattern still matches build-hub-grid.ps1''s Get-ProteinCat' `
      ($hub.Contains($script:PROTEIN_PORK)) 'build-hub-grid''s pork pattern has moved - copy it over'
  } else {
    T 'LOCKSTEP  build-hub-grid.ps1 is readable so the protein patterns can be compared' $false 'not found'
  }

  # ---- voice sweep --------------------------------------------------------------------------------
  $dEm = Get-DashHits ([pscustomobject]@{ prose = @('a fine line' + [char]0x2014 + ' and then some') })
  T 'MUST FIRE  an em dash anywhere in the spec is found' ($dEm.Count -eq 1) ('count=' + $dEm.Count)
  $dEn = Get-DashHits ([pscustomobject]@{ a = @{ b = ('range 4' + [char]0x2013 + '6') } })
  T 'MUST FIRE  an en dash nested two levels down is found too' ($dEn.Count -eq 1) ('count=' + $dEn.Count)
  $dTwo = Get-DashHits ([pscustomobject]@{ a = ('x' + [char]0x2014 + 'y'); b = ('p' + [char]0x2014 + 'q') })
  T 'MUST FIRE  two dashes count as TWO, not as one joined blob' ($dTwo.Count -eq 2) ('count=' + $dTwo.Count)
  $dNone = Get-DashHits ([pscustomobject]@{ prose = 'a low-carb, high-protein dinner' })
  T 'CLEAN TWIN ordinary prose with hyphens is silent, and counts ZERO' ($dNone.Count -eq 0) ('count=' + $dNone.Count)

  # THE BAN LIST IS NOT SPEC TEXT (wave 1 of hunt-2026-08-27-highprotein). `forbidden_prose_terms` is
  # the intake's list of characters the writer may NOT use, and an em dash is its first entry; sweeping
  # it reported the spec for carrying the very character it bans. build-v2-spec had the same defect and
  # REFUSED three recipes outright; that fix moved the walk to lib\dash-sweep.ps1 and MISSED this second
  # copy, so the false positive came back one layer up against two specs with no reader-facing dash.
  # The skip list is now dot-sourced, so these two fixtures and build-v2-spec's guard ONE list.
  # [string], not [char]. `$v -is [string]` is FALSE for a bare [char], so a char em dash falls through
  # every branch of the walk and is dropped in SILENCE - which made the first cut of these two fixtures
  # pass with the skip torn out. The intake's terms are strings; the fixture has to be one too.
  $emc = [string][char]0x2014
  $dBan = Get-DashHits ([pscustomobject]@{ forbidden_prose_terms = @($emc, 'delicious'); prose = 'clean prose' })
  T 'CLEAN TWIN the ban list naming the em dash is NOT swept as spec text' ($dBan.Count -eq 0) ('count=' + $dBan.Count + ' ' + ($dBan -join ' | '))
  $dBanHash = Get-DashHits (@{ forbidden_prose_terms = @($emc); prose = 'clean prose' })
  T 'CLEAN TWIN the skip holds on a hashtable spec too, not just a psobject' ($dBanHash.Count -eq 0) ('count=' + $dBanHash.Count)
  # and the half that proves the skip is a SKIP and not an off switch:
  $dBanReal = Get-DashHits ([pscustomobject]@{ forbidden_prose_terms = @($emc); prose = ('a real' + $emc + 'dash a reader would see') })
  T 'MUST FIRE  a real dash in prose still fires in a spec that ALSO carries the ban list' `
    ($dBanReal.Count -eq 1 -and ($dBanReal -join ' ') -match 'a reader would see') ('count=' + $dBanReal.Count + ' ' + ($dBanReal -join ' | '))
  T 'the skip list is the SHARED one, dot-sourced - not a second copy that can drift' `
    ($script:DASH_SWEEP_SKIP -contains 'forbidden_prose_terms' -and @($script:DASH_SWEEP_SKIP).Count -eq 1) `
    ('skip=' + (@($script:DASH_SWEEP_SKIP) -join ','))

  # ---- card structural compare --------------------------------------------------------------------
  $refCard = '<div class="smp-ing" id="smp-ing"></div><div class="smp-cost" id="smp-cost"></div>' +
             '<div class="smp-credit"></div><ol><li id="step1">a</li><li id="step2">b</li></ol>'
  $gSame = Get-CardStructuralGaps $refCard $refCard 2
  T 'CLEAN TWIN an identical rebuild has no structural gap' ($gSame.Count -eq 0) ($gSame -join ' | ')
  # THE FOUNDING CASE: the wave-2 auditor byte-compared four rebuilt cards against the live al-pastor card
  # precisely to catch a renderer that quietly stopped emitting a section.
  $mutated = $refCard -replace '<div class="smp-credit"></div>', ''
  $gCredit = Get-CardStructuralGaps $mutated $refCard 2
  T 'MUST FIRE  a rebuild that lost the source-credit block is caught' `
    (($gCredit -join ' ') -match 'smp-credit') ($gCredit -join ' | ')
  $noAnchor = $refCard -replace 'id="step2"', 'class="nostep"'
  $gStep = Get-CardStructuralGaps $noAnchor $refCard 2
  T 'MUST FIRE  a make-it step with no anchor id is caught (the JSON-LD points at those anchors)' `
    (($gStep -join ' ') -match 'step\(s\) 2') ($gStep -join ' | ')
  $dashCard = $refCard + ('<p>a' + [char]0x2014 + 'b</p>')
  $gDash = Get-CardStructuralGaps $dashCard $refCard 2
  T 'MUST FIRE  an em dash byte in the rendered card is caught' `
    (($gDash -join ' ') -match 'EM DASH') ($gDash -join ' | ')

  # ---- dry-run + shared-gate readings ---------------------------------------------------------------
  T 'the -DryRun null-id count is read off its own line' `
    ((Get-DryRunNullIds @('item_id source: ingredient-map 82 rows | scaler-bid fallback 16 rows | no id (null) 0 rows')) -eq 0) 'misread the line'
  T 'MUST FIRE  three null ids are read as three, not as clean' `
    ((Get-DryRunNullIds @('item_id source: ingredient-map 5 rows | scaler-bid fallback 1 rows | no id (null) 3 rows')) -eq 3) 'misread a non-zero count'
  T 'MUST FIRE  a -DryRun that never printed the line is could-not-look (-1), not zero' `
    ((Get-DryRunNullIds @('nothing to add')) -eq -1) 'read an absent line as clean'
  T 'CLEAN TWIN a gate that exited 0 and printed its marker is clean' `
    ((Get-SharedVerdict 0 @('working', 'STORE-INTEGRITY-COMPLETE hard=0') 'store-integrity').pass) 'refused a clean gate'
  # the guard-contract founding case, one level up: 176 lines of PASS and then death
  T 'MUST FIRE  a gate that exited 0 without its marker did not finish, so it is not clean' `
    (-not (Get-SharedVerdict 0 @('PASS one', 'PASS two') 'store-integrity').pass) 'accepted a crashed gate'
  T 'MUST FIRE  a gate that exited 1 is not clean' `
    (-not (Get-SharedVerdict 1 @('AUDIT-VOCAB-INTEGRITY-COMPLETE 3 findings') 'audit-vocab-integrity').pass) 'accepted a findings exit'

  # ---- the report contract --------------------------------------------------------------------------
  $c = New-Check 'macro-recompute' $false ([ordered]@{ cal = 440 }) 'drifted'
  T 'a check renders as {check, verdict, numbers, detail} exactly' `
    ($c.check -eq 'macro-recompute' -and $c.verdict -eq 'fail' -and $c.numbers.cal -eq 440 -and $c.detail -eq 'drifted') (($c | ConvertTo-Json -Compress))
  T 'a passing check says pass, not true' ((New-Check 'x' $true).verdict -eq 'pass') (New-Check 'x' $true).verdict

  # THE TWO PS 5.1 TRAPS THAT TOOK THE FIRST LIVE RUN DOWN, frozen. Both are invisible to a fixture over
  # pure functions - they only appear when a check result is COLLECTED - so they are pinned here on the
  # exact shapes this script uses: a List[object] of New-Check results, and an ordered dictionary of them.
  $lst = New-Object System.Collections.Generic.List[object]
  $lst.Add((New-Check 'a' $true))
  $lst.Add((New-Check 'b' $false))
  $arrOk = $false; $arrCount = -1
  try { $tmp = $lst.ToArray(); $arrCount = $tmp.Count; $arrOk = $true } catch { $arrOk = $false }
  T '.ToArray() converts a List[object] of check results (@() on it throws in PS 5.1)' `
    ($arrOk -and $arrCount -eq 2) ("ok=$arrOk count=$arrCount")
  $atThrew = $false
  try { $null = @($lst) } catch { $atThrew = $true }
  T 'MUST FIRE  @() on that same list still throws, so the .ToArray() above is not decoration' `
    $atThrew 'PS no longer throws here - re-read the trap comment before simplifying it away'
  $od = [ordered]@{}
  $odOk = $false
  try { $od.Add('slug-one', $lst.ToArray()); $odOk = ($od['slug-one'].Count -eq 2) } catch { $odOk = $false }
  T 'an ordered dictionary holds a slug''s checks and reads them back' $odOk ("ok=$odOk")

  # =================================================================================================
  # END-TO-END DRILL. The fixtures above pin the PREDICATES; these pin the SCRIPT, because two of the
  # three defects this file shipped with on its first day (an OrderedDictionary indexer and an @() over a
  # List[object]) were invisible to every pure-function fixture and only appeared once real check results
  # were collected. Each case builds a scratch meal-prep root under TEMP, runs this script as a CHILD
  # process against it, and reads back the exit code and the report it wrote. Nothing live is touched.
  # -SkipShared/-SkipLive keep the drill off the catalog gates and off the network, which is why the
  # clean-wave case asserts on the SLUG checks in the report rather than on the exit code: a report that
  # skipped the shared gates deliberately cannot read as clean.
  # =================================================================================================
  $T = Join-Path $env:TEMP ("wave-preaudit-drill-" + $PID)
  if (Test-Path $T) { Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue }
  $dMp   = Join-Path $T 'meal-prep'
  $dRun  = Join-Path $T 'run'
  $dSlug = 'keto-cheeseburger-skillet'
  $srcSpec = Join-Path $mp ("db\recipes\{0}.json" -f $dSlug)
  $srcCost = Join-Path $mp 'db\costed.json'
  $srcFood = Join-Path $mp 'food-macros-db.json'
  $srcIng  = Join-Path $mp 'db\ingredients.json'
  $srcRef  = Join-Path $mp 'db\built\al-pastor-pork-taco-bowl-with-cilantro-lime-rice.body.html'
  $canDrill = ((Test-Path $srcSpec) -and (Test-Path $srcCost) -and (Test-Path $srcFood) -and (Test-Path $srcIng) -and (Test-Path $srcRef))
  if (-not $canDrill) {
    T 'END-TO-END the drill inputs exist (a live spec, costed.json, the food DB, a reference card)' $false 'one of them is missing - the drill could not run, which is not a pass'
  } else {
    New-Item -ItemType Directory -Force (Join-Path $dMp 'db\recipes') | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $dRun 'waves') | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $T 'lib') | Out-Null
    # $repo is derived as the parent of the root, and guard-contract lives there. The drill root needs
    # its own copy or the child cannot even start - which would itself read as a failure, correctly.
    Copy-Item (Join-Path $repo 'lib\guard-contract.ps1') (Join-Path $T 'lib\guard-contract.ps1') -Force
    Copy-Item $srcCost (Join-Path $dMp 'db\costed.json') -Force
    Copy-Item $srcFood (Join-Path $dMp 'food-macros-db.json') -Force
    # widget-count-basis check (b) reads db\ingredients.json as its INDEPENDENT statement of each item's
    # package, and a missing required input is a BLOCK, not a skip - so the drill root carries it too.
    Copy-Item $srcIng (Join-Path $dMp 'db\ingredients.json') -Force
    $pristine = [IO.File]::ReadAllText($srcSpec, [Text.Encoding]::UTF8)
    $dSpecPath = Join-Path $dMp ("db\recipes\{0}.json" -f $dSlug)
    [IO.File]::WriteAllText($dSpecPath, $pristine, $UTF8)
    $manPathD = Join-Path $dRun 'waves\wave-1.json'
    [IO.File]::WriteAllText($manPathD, ('{"wave":1,"run":"drill","batch":"drill-w1","slugs":["' + $dSlug + '"]}'), $UTF8)

    $selfPath = $PSCommandPath
    # Every switch is passed exactly once - PowerShell refuses a duplicated parameter outright, and a
    # drill that dies on its own argument list would report a false MUST-FIRE.
    function RunDrill([string]$root, [string]$refCard, [string[]]$extra) {
      $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $selfPath, '-RunDir', $dRun, '-Wave', '1',
             '-Root', $root, '-SkipShared', '-SkipLive', '-ReferenceCard', $refCard) + $extra
      $out = & powershell @a 2>&1
      return [pscustomobject]@{ rc = $LASTEXITCODE; lines = @($out | ForEach-Object { [string]$_ }) }
    }
    function ReadDrillReport() {
      $rp = Join-Path $dRun 'waves\wave-1.preaudit.json'
      if (-not (Test-Path $rp)) { return $null }
      return (([IO.File]::ReadAllText($rp, [Text.Encoding]::UTF8)) | ConvertFrom-Json)
    }
    function DrillCheck($rep, [string]$name) {
      if ($null -eq $rep) { return $null }
      $arr = $rep.slug_checks.$dSlug
      return @($arr | Where-Object { $_.check -eq $name })[0]
    }

    # ---- MUST FIRE: a RELATIVE -RunDir is resolved before the Start-Job fan-out -------------------
    # Start-Job's process does not inherit this one's working directory, so a relative -RunDir - what
    # every hand-run supplies - reaches the shared-gate jobs as a path they cannot resolve. That is
    # the "battery failure is a HARNESS defect" both the wave-10 and wave-11 audits diagnosed and
    # worked around by hand. The drill runs with -SkipShared, so it cannot observe the jobs
    # themselves; it observes the thing they depend on, which the report now records.
    function RunDrillFrom([string]$cwd, [string]$relRoot, [string]$refCard) {
      Push-Location $cwd
      try {
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $selfPath, '-RunDir', $relRoot,
               '-Wave', '1', '-Root', $dMp, '-SkipShared', '-SkipLive', '-ReferenceCard', $refCard)
        $out = & powershell @a 2>&1
        return [pscustomobject]@{ rc = $LASTEXITCODE; lines = @($out | ForEach-Object { [string]$_ }) }
      } finally { Pop-Location }
    }
    $rRel = RunDrillFrom (Split-Path $dRun -Parent) (Split-Path $dRun -Leaf) $srcRef
    $repRel = ReadDrillReport
    $recorded = if ($null -ne $repRel) { [string]$repRel.inputs.run_dir } else { '' }
    T 'END-TO-END MUST FIRE a RELATIVE -RunDir is resolved to an absolute path, or the shared-gate jobs cannot see it' `
      ($null -ne $repRel -and $recorded -and [IO.Path]::IsPathRooted($recorded)) ("run_dir recorded as '" + $recorded + "'")

    # ---- CLEAN TWIN: an untouched live spec passes every per-slug check ----------------------------
    $r1 = RunDrill $dMp $srcRef @()
    $rep1 = ReadDrillReport
    $slugFails = @()
    if ($null -ne $rep1) { $slugFails = @($rep1.slug_checks.$dSlug | Where-Object { $_.verdict -eq 'fail' }) }
    T 'END-TO-END CLEAN TWIN a live, unmodified spec passes every per-slug check' `
      ($null -ne $rep1 -and $slugFails.Count -eq 0) (($slugFails | ForEach-Object { $_.check + ': ' + $_.detail }) -join ' | ')
    T 'END-TO-END the report carries the section 4.5 shape (slug_checks / shared_checks / summary)' `
      ($null -ne $rep1 -and $null -ne $rep1.slug_checks -and $null -ne $rep1.shared_checks -and $null -ne $rep1.summary) 'a key is missing'
    T 'END-TO-END a run that SKIPPED the shared gates cannot read as clean' `
      ($r1.rc -ne 0) ("rc=" + $r1.rc)

    # ---- MUST FIRE: a broken macro recompute --------------------------------------------------------
    # The founding shape of the wave-2 audit's category 1: the stat says one thing, the spec's own grams
    # times the food DB say another. 300 calories is far outside the 5-cal tolerance and far inside the
    # range a real drift lands in.
    $broken = $pristine -replace '"cal":\s*\d+', '"cal":  9999'
    [IO.File]::WriteAllText($dSpecPath, $broken, $UTF8)
    $r2 = RunDrill $dMp $srcRef @()
    $mc = DrillCheck (ReadDrillReport) 'macro-recompute'
    T 'END-TO-END MUST FIRE a spec whose stat calories left its own recompute is caught' `
      ($null -ne $mc -and $mc.verdict -eq 'fail') ("verdict=" + $(if ($mc) { $mc.verdict } else { 'no check' }))
    T 'END-TO-END MUST FIRE and the report carries BOTH numbers, so the auditor need not recompute' `
      ($null -ne $mc -and $mc.numbers.stat.cal -eq 9999 -and $mc.numbers.recompute.cal -gt 0) `
      $(if ($mc) { ("stat=" + $mc.numbers.stat.cal + " recompute=" + $mc.numbers.recompute.cal) } else { 'no check' })
    T 'END-TO-END MUST FIRE a findings run exits 1, and the machine report is still written' `
      ($r2.rc -eq 1 -and (Test-Path (Join-Path $dRun 'waves\wave-1.preaudit.json'))) ("rc=" + $r2.rc)
    [IO.File]::WriteAllText($dSpecPath, $pristine, $UTF8)

    # ---- MUST FIRE: a card rebuild that no longer matches a known-good card -------------------------
    # The wave-2 auditor byte-compared four rebuilt cards against the live al-pastor card to catch a
    # renderer that quietly stopped emitting a section. Here the REFERENCE carries a marker the rebuild
    # cannot have, which is the same comparison run from the other side.
    $mutatedRef = Join-Path $T 'mutated-reference.body.html'
    [IO.File]::WriteAllText($mutatedRef, ([IO.File]::ReadAllText($srcRef, [Text.Encoding]::UTF8) + '<div class="smp-drill-only-marker"></div>'), $UTF8)
    $r3 = RunDrill $dMp $mutatedRef @()
    $cr = DrillCheck (ReadDrillReport) 'card-rebuild'
    T 'END-TO-END MUST FIRE a rebuilt card missing a structural class the reference carries is caught' `
      ($null -ne $cr -and $cr.verdict -eq 'fail' -and $cr.detail -match 'smp-drill-only-marker') `
      $(if ($cr) { $cr.detail } else { 'no check' })

    # ---- MUST FIRE: could-not-run is exit 2, and exit 2 is never clean ------------------------------
    Remove-Item $manPathD -Force
    $r4 = RunDrill $dMp $srcRef @()
    T 'END-TO-END MUST FIRE a missing wave manifest exits 2, not 0' ($r4.rc -eq 2) ("rc=" + $r4.rc)
    T 'END-TO-END MUST FIRE and it SAYS blocked, so a reader cannot mistake it for a quiet pass' `
      ((($r4.lines) -join ' ') -match 'BLOCKED') (($r4.lines | Select-Object -Last 3) -join ' / ')
    [IO.File]::WriteAllText($manPathD, ('{"wave":1,"run":"drill","batch":"drill-w1","slugs":["' + $dSlug + '"]}'), $UTF8)

    $r5 = RunDrill $dMp $srcRef @('-Slugs', 'a-slug-this-wave-never-listed')
    T 'END-TO-END MUST FIRE a scoped re-audit naming a slug outside the wave exits 2, never a narrow pass' `
      ($r5.rc -eq 2) ("rc=" + $r5.rc)

    $r6 = RunDrill (Join-Path $T 'no-such-root') $srcRef @()
    T 'END-TO-END MUST FIRE a missing required input (no costed.json, no food DB) exits 2' `
      ($r6.rc -eq 2) ("rc=" + $r6.rc)

    Remove-Item $T -Recurse -Force -ErrorAction SilentlyContinue
  }

  if ($f -eq 0) { Write-Output 'wave-preaudit SELF-TEST PASS'; exit 0 } else { Write-Output "wave-preaudit SELF-TEST FAIL: $f case(s)"; exit 1 }
}

# ===================================================================================================
# THE RUN
# ===================================================================================================
function Read-JsonFile { param([string]$P) return (([IO.File]::ReadAllText($P, [Text.Encoding]::UTF8) -replace "^\xEF\xBB\xBF", '' -replace "^﻿", '') | ConvertFrom-Json) }

$script:blocked = New-Object System.Collections.Generic.List[string]
function Block { param([string]$M) Write-Output ("wave-preaudit: BLOCKED - " + $M); $script:blocked.Add($M) }

if (-not $RunDir -or $Wave -le 0) {
  Block 'usage: -RunDir <run folder> -Wave <k>   (or -SelfTest)'
  Write-GuardComplete -Name 'wave-preaudit' -Summary 'blocked: no run dir or wave'
  exit 2
}
if (-not (Test-Path $RunDir)) { Block ("run dir not found: " + $RunDir); Write-GuardComplete -Name 'wave-preaudit' -Summary 'blocked: no run dir'; exit 2 }

# ---- ABSOLUTE-IZE BEFORE ANYTHING REACHES Start-Job (2026-08-28) --------------------------------
# Start-Job runs its scriptblock in a NEW PowerShell process, and that process does NOT inherit this
# one's working directory. So a RELATIVE -RunDir - which every hand-run and every relative call site
# supplies - resolves against some other folder inside the job, and the shared-gate fan-out below
# fails on paths that are perfectly correct out here.
#
# IT FAILED AS A HARNESS DEFECT, WHICH IS WHY IT SURVIVED TWO AUDITS. The wave-11 and wave-10 audits
# both hit it, both diagnosed it as "the battery failure is the HARNESS, not the recipe", and both
# re-derived the result by hand with absolute paths (RC=0). A gate that fails for its own reasons
# teaches a wave nothing and costs an auditor a manual re-run every time.
#
# Resolved ONCE, here, so every path Join-Path builds from it downstream - the manifest, the slug
# list, OutFile, the card scratch root - is absolute by construction rather than by remembering.
$RunDir = (Resolve-Path -LiteralPath $RunDir).ProviderPath

$manPath = Join-Path $RunDir ("waves\wave-{0}.json" -f $Wave)
if (-not (Test-Path $manPath)) {
  Block ("no wave manifest at {0} - close the wave first (hunt-run.ps1 -WaveClose)" -f $manPath)
  Write-GuardComplete -Name 'wave-preaudit' -Summary 'blocked: no manifest'
  exit 2
}
$man = $null
try { $man = Read-JsonFile $manPath } catch { Block ("the wave manifest does not parse: " + $_.Exception.Message) }
if ($null -eq $man) { Write-GuardComplete -Name 'wave-preaudit' -Summary 'blocked: unparseable manifest'; exit 2 }

$waveSlugs = @(@($man.slugs) | ForEach-Object { [string]$_ } | Where-Object { $_ })
if (-not $waveSlugs.Count) { Block 'the wave manifest lists no slugs'; Write-GuardComplete -Name 'wave-preaudit' -Summary 'blocked: empty manifest'; exit 2 }

$scope = 'whole-wave'
$target = $waveSlugs
if ($Slugs -and @($Slugs).Count) {
  $asked = @(@($Slugs) | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $foreign = @($asked | Where-Object { $waveSlugs -notcontains $_ })
  if ($foreign.Count) {
    # A scope this wave does not contain is a could-not-run, not a narrow pass. Certifying a slug the
    # manifest never listed is exactly the mislabel that cost the wave-2 audit its verification time.
    Block ("these slugs are not in wave {0}: {1}" -f $Wave, ($foreign -join ', '))
    Write-GuardComplete -Name 'wave-preaudit' -Summary 'blocked: scope outside the wave'
    exit 2
  }
  $target = $asked
  $scope = ('scoped: ' + ($asked -join ', '))
}

if (-not $OutFile) { $OutFile = Join-Path $RunDir ("waves\wave-{0}.preaudit.json" -f $Wave) }
if (-not $ReferenceCard) { $ReferenceCard = Join-Path $mp 'db\built\al-pastor-pork-taco-bowl-with-cilantro-lime-rice.body.html' }

$recipesDir = if ($SpecsDir) { $SpecsDir } else { Join-Path $mp 'db\recipes' }
$costedPath = Join-Path $mp 'db\costed.json'
$foodDbPath = Join-Path $mp 'food-macros-db.json'

foreach ($need in @($costedPath, $foodDbPath, $ReferenceCard)) {
  if (-not (Test-Path $need)) { Block ("required input missing: " + $need) }
}
if ($script:blocked.Count) { Write-GuardComplete -Name 'wave-preaudit' -Summary 'blocked: missing input'; exit 2 }

$startedAt = Get-Date
Write-Output ("wave-preaudit: {0}  wave {1}  {2} recipe(s)   [{3}]" -f ([string]$man.run), $Wave, $target.Count, $scope)

$foodDb = @{}
try { foreach ($i in @((Read-JsonFile $foodDbPath).items)) { $foodDb[[string]$i.item] = $i } }
catch { Block ("food-macros-db does not parse: " + $_.Exception.Message) }
$costedRows = @{}
try { foreach ($r in @(Read-JsonFile $costedPath)) { $costedRows[[string]$r.slug] = $r } }
catch { Block ("db\costed.json does not parse: " + $_.Exception.Message) }
# THE INDEPENDENT STATEMENT OF EACH ITEM'S PACKAGE, for widget-count-basis check (b). Deliberately not
# the costed row: the whole point of (b) is to compare the block's implied package against a source the
# block was not derived from.
$ingRows = @{}
$ingPath = Join-Path $mp 'db\ingredients.json'
if (Test-Path $ingPath) {
  try { foreach ($r in @(Read-JsonFile $ingPath)) { $ingRows[[string]$r.item] = $r } }
  catch { Block ("db\ingredients.json does not parse: " + $_.Exception.Message) }
} else { Block ("required input missing: " + $ingPath) }
if ($script:blocked.Count) { Write-GuardComplete -Name 'wave-preaudit' -Summary 'blocked: unparseable input'; exit 2 }

$refHtml = [IO.File]::ReadAllText($ReferenceCard, [Text.Encoding]::UTF8)
$costedMtime = (Get-Item $costedPath).LastWriteTime

# ---- the SHARED checks, fanned out ----------------------------------------------------------------
# These are the whole-catalog gates plus the two endpoint probes. They run ONCE per wave, not per slug -
# running audit-spec-contradictions ten times over the same 570 specs is ten times the same answer - and
# they run CONCURRENTLY, because audit-spec-contradictions alone is 14 s of the battery's ~15 s and the
# others are free beside it. The per-slug checks below are deliberately NOT fanned out: they are JSON
# arithmetic plus a card render, and build-card2.ps1's process-global costed cache makes the second
# render 0.05 s against 0.8 s for the first, so a process per slug would pay the 5.8 MB parse eight times
# and finish slower. Measured 2026-08-23, both ways.
$slugArg = ($target -join ',')
$sharedSpec = @(
  @{ name = 'audit-spec-contradictions'; script = (Join-Path $here 'audit-spec-contradictions.ps1'); args = @('-Quiet');                    marker = 'spec-contradictions' },
  @{ name = 'audit-store-integrity';     script = (Join-Path $here 'audit-store-integrity.ps1');     args = @();                            marker = 'store-integrity' },
  @{ name = 'audit-vocab-integrity';     script = (Join-Path $here 'audit-vocab-integrity.ps1');     args = @('-Slugs', $slugArg);          marker = 'audit-vocab-integrity' },
  @{ name = 'audit-unbid-ingredients';   script = (Join-Path $here 'audit-unbid-ingredients.ps1');   args = @('-Slugs', $slugArg);          marker = 'audit-unbid-ingredients' },
  @{ name = 'audit-cost-plausibility';   script = (Join-Path $here 'audit-cost-plausibility.ps1');   args = @('-Slugs', $slugArg);          marker = 'audit-cost-plausibility' },
  # THE FOURTH QUESTION, and the one that was missing on 2026-08-16 (wired in 2026-08-25). The three
  # gates above all ask whether a price COULD be found, and all three passed on
  # slow-cooker-boneless-beef-short-ribs while it sat one audit away from publishing at $0.30 a serving
  # against a real $6.30 - seven pounds of short ribs, the entire protein, priced correctly by the
  # engine and simply absent from the spec's cost block. Nobody asked whether the spec's cost block
  # still agreed with the engine row it was rendered from. It had no production caller at all until
  # now, which is why audit-guard-contract reported it DEAD: a guard nobody runs is not a guard.
  @{ name = 'audit-cost-line-coverage';  script = (Join-Path $here 'audit-cost-line-coverage.ps1');  args = @('-Slugs', $slugArg);          marker = 'audit-cost-line-coverage' }
)

$sharedChecks = New-Object System.Collections.Generic.List[object]
if ($runSkipShared) {
  # Offered ONLY for the fixture drill. A report that skipped the shared gates must say so where the
  # auditor cannot miss it, because a wave certified without them was never really checked.
  $sharedChecks.Add((New-Check 'shared-checks' $false ([ordered]@{ skipped = $true }) '-SkipShared was passed: the catalog gates, the recipes-db dry run and the P8 probes did NOT run. This report cannot support a GO.'))
} else {
  $jobs = @()
  foreach ($s in $sharedSpec) {
    if (-not (Test-Path $s.script)) {
      $sharedChecks.Add((New-Check $s.name $false ([ordered]@{}) ('gate script missing: ' + $s.script)))
      continue
    }
    $jobs += @{ spec = $s; job = (Start-Job -ScriptBlock {
        param($p, $a)
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $p @a 2>&1
        [pscustomobject]@{ rc = $LASTEXITCODE; lines = @($out | ForEach-Object { [string]$_ }) }
      } -ArgumentList $s.script, $s.args) }
  }
  # the recipes-db dry run rides along in the same fan-out: it is the "protein derivation by
  # construction" half of the audit's category 4 and it needs the same wall-clock slot
  $slugListPath = Join-Path $RunDir ("waves\wave-{0}.preaudit-slugs.txt" -f $Wave)
  [IO.File]::WriteAllText($slugListPath, ((@($target) -join "`r`n") + "`r`n"), $UTF8)
  $dryJob = Start-Job -ScriptBlock {
    param($p, $run, $specs, $list, $label)
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $p -RunDir $run -SpecsDir $specs -SpecList $list -RunLabel $label -DryRun 2>&1
    [pscustomobject]@{ rc = $LASTEXITCODE; lines = @($out | ForEach-Object { [string]$_ }) }
  } -ArgumentList (Join-Path $here 'update-recipes-db.ps1'), $RunDir, $recipesDir, $slugListPath, ([string]$man.batch)

  foreach ($j in $jobs) {
    $r = Receive-Job -Job $j.job -Wait -AutoRemoveJob
    $v = Get-SharedVerdict ([int]$r.rc) $r.lines $j.spec.marker
    $tail = @($r.lines | Where-Object { $_.Trim() } | Select-Object -Last 6)
    $sharedChecks.Add((New-Check $j.spec.name $v.pass ([ordered]@{ rc = [int]$r.rc }) `
      $(if ($v.pass) { 'clean: ' + (@($tail) | Select-Object -Last 1) } else { ("{0} is not clean ({1}). Fix it through the owning stage - never weaken a gate to pass a wave. Tail: {2}" -f $j.spec.name, $v.why, ($tail -join ' // ')) })))
  }

  $dr = Receive-Job -Job $dryJob -Wait -AutoRemoveJob
  $nulls = Get-DryRunNullIds $dr.lines
  $dryOk = ([int]$dr.rc -eq 0 -and $nulls -eq 0)
  # THE PROBE'S OWN OUTPUT, when it fails. This check said only "could not look" and threw the
  # child's output away, so on waves 3, 6 and 8 two separate auditors had to re-run update-recipes-db
  # by hand to find out why - and BOTH then mis-diagnosed it, reporting that the probe invokes the
  # script bare and it wants <RunDir>\specs-ready.txt. It does not: this call passes -SpecList, and
  # update-recipes-db line 112 takes $SpecList verbatim and never consults specs-ready.txt. The real
  # rc-1 cause is still unknown, because it only appears when there are rows to BUILD (once the slugs
  # are already in recipes-db the script short-circuits with "nothing to add" and exits 0), and by
  # the time anyone looks the wave has published. So the tail rides on the finding: the next
  # occurrence will name its own cause instead of costing a re-run and earning a wrong answer.
  $dryTail = @($dr.lines | Where-Object { $_.Trim() } | Select-Object -Last 4)
  $sharedChecks.Add((New-Check 'recipes-db-dryrun' $dryOk ([ordered]@{ rc = [int]$dr.rc; null_item_ids = $nulls }) `
    $(if ($dryOk) { 'update-recipes-db -DryRun builds every row with an item_id on all of them' }
      elseif ($nulls -lt 0) { 'update-recipes-db -DryRun never printed its item_id source line, so the null-id count could not be read. Could-not-look is not a clean bill. Its own last lines: ' + (($dryTail -join ' // ')) }
      else { ("update-recipes-db -DryRun: rc {0}, {1} row(s) with a null item_id - the grocery merge cannot join those. Tail: {2}" -f $dr.rc, $nulls, ($dryTail -join ' // ')) })))

  # ---- P8: the serveability probes ----------------------------------------------------------------
  $tplPath = Join-Path $here 'tpl2-scaler-prefix.html'
  $cardFeedUrl = ''
  if (-not (Test-Path $tplPath)) {
    $sharedChecks.Add((New-Check 'p8-endpoint-provenance' $false ([ordered]@{}) ("no card template at {0} - cannot tell what feed the cards will fetch" -f $tplPath)))
  } else {
    $cardFeedUrl = Get-CardFeedUrl ([IO.File]::ReadAllText($tplPath, [Text.Encoding]::UTF8))
    $producible = Test-FeedUrlProducible $cardFeedUrl $script:PRODUCIBLE_FEEDS
    $guardUrl = ''
    $fcPath = Join-Path $here 'feed-covers-published.ps1'
    if (Test-Path $fcPath) { $guardUrl = Get-GuardFeedUrl ([IO.File]::ReadAllText($fcPath, [Text.Encoding]::UTF8)) }
    $agree = (-not $guardUrl) -or ($guardUrl -eq $cardFeedUrl)
    $ok = ($producible -and $agree)
    $sharedChecks.Add((New-Check 'p8-endpoint-provenance' $ok ([ordered]@{ card_feed = $cardFeedUrl; guard_feed = $guardUrl; producible = $producible }) `
      $(if ($ok) { "the cards fetch a feed this estate produces, and feed-covers-published validates the same one" }
        elseif (-not $producible) { ("the cards fetch prices from '{0}', which is NOT an endpoint this estate produces (producible: {1}). Repoint the template; do NOT add the URL to the allowlist to unblock." -f $cardFeedUrl, ($script:PRODUCIBLE_FEEDS -join ', ')) }
        else { ("feed-covers-published.ps1 validates '{0}' but the cards fetch '{1}' - that guard's green light means nothing" -f $guardUrl, $cardFeedUrl) })))
  }
  if ($runSkipLive) {
    $sharedChecks.Add((New-Check 'p8-feed-liveness' $false ([ordered]@{ skipped = $true }) '-SkipLive was passed: the feed was NOT probed. A producible URL that is DOWN still ships a broken page, so this report cannot support a GO on its own.'))
  } elseif (-not $cardFeedUrl) {
    $sharedChecks.Add((New-Check 'p8-feed-liveness' $false ([ordered]@{}) 'no card feed URL to probe'))
  } else {
    $liveOk = $false; $why = ''; $nRecipes = 0; $gen = ''
    try {
      . (Join-Path $repo 'lib\ghost-lib.ps1')
      $feedDoc = Invoke-GhostApi -Uri $cardFeedUrl -TimeoutSec 40
      if ($null -eq $feedDoc -or $null -eq $feedDoc.recipes -or $null -eq $feedDoc.ingredients) {
        $why = 'answered, but the body is not the price feed (no recipes/ingredients map). A 200 that is not the feed is still a broken card.'
      } else {
        $liveOk = $true
        $nRecipes = @($feedDoc.recipes.PSObject.Properties).Count
        $gen = [string]$feedDoc.generated
      }
    } catch { $why = ('could not be fetched: ' + $_.Exception.Message) }
    $sharedChecks.Add((New-Check 'p8-feed-liveness' $liveOk ([ordered]@{ url = $cardFeedUrl; feed_recipes = $nRecipes; generated = $gen }) `
      $(if ($liveOk) { ("200 + parseable ({0} recipes, generated {1})" -f $nRecipes, $gen) } else { ("the card price source {0} {1}" -f $cardFeedUrl, $why) })))
  }
}

# ---- the PER-SLUG checks ---------------------------------------------------------------------------
$scratchRoot = Join-Path $RunDir ("waves\wave-{0}.preaudit-cards" -f $Wave)
if (Test-Path $scratchRoot) { Remove-Item $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $scratchRoot | Out-Null
$global:__tcCostedCache = @{}      # build-card2 fills it on the first parse; sharing it is the whole point

# TWO PS 5.1 TRAPS LIVE ON THE NEXT FEW LINES, both measured on 2026-08-23 after every pure-predicate
# fixture was already green - which is exactly the class of defect a fixture over pure functions cannot
# see, so they are pinned in the self-test as well.
#   1. `@($list)` where $list is a List[object] holding DICTIONARIES throws "Argument types do not
#      match". The array subexpression reaches into the element and hits OrderedDictionary's ambiguous
#      [int]/[object] indexer. `.ToArray()` is the conversion that works; a plain @() array built with
#      += works too. It is not the ordered dictionary being ASSIGNED that breaks - it is the @().
#   2. Assigning through an OrderedDictionary's indexer is fine, but .Add(key, value) says what is meant
#      and refuses a duplicate key, which for a slug list is the behaviour we want.
$slugChecks = [ordered]@{}
foreach ($slug in $target) {
  $checks = New-Object System.Collections.Generic.List[object]
  $specPath = Join-Path $recipesDir ("{0}.json" -f $slug)
  if (-not (Test-Path $specPath)) {
    # No spec is a P4 refusal, and there is nothing here to recompute. It is reported per slug rather than
    # exiting 2, so one absent spec cannot hide the other nine recipes' verdicts from the auditor.
    $checks.Add((New-Check 'spec-present' $false ([ordered]@{}) ("no v2 spec at db\recipes\{0}.json - wave-publish P4 would refuse this wave" -f $slug)))
    $slugChecks.Add($slug, $checks.ToArray()); continue
  }
  $spec = $null
  try { $spec = Read-JsonFile $specPath } catch {
    $checks.Add((New-Check 'spec-present' $false ([ordered]@{}) ("the spec does not parse: " + $_.Exception.Message)))
    $slugChecks.Add($slug, @($checks)); continue
  }
  $checks.Add((New-Check 'spec-present' $true ([ordered]@{ mtime = (Get-Item $specPath).LastWriteTime.ToString('s') }) 'spec present and parses'))

  $servings = 0; if ($spec.PSObject.Properties.Name -contains 'servings') { $servings = [int]$spec.servings }
  if ($servings -le 0) { $servings = $script:HOUSE_SERVINGS }

  # --- macro recompute ---
  $gramRows = @($spec.ingredients_grams)
  if (-not $gramRows.Count) {
    $checks.Add((New-Check 'macro-recompute' $false ([ordered]@{}) 'the spec carries no ingredients_grams, so its macros cannot be recomputed at all'))
  } else {
    $rcm = Get-MacroRecompute $gramRows $foodDb $servings
    $drift = Test-MacroDrift $rcm $spec.stat $script:MACRO_CAL_TOL $script:MACRO_GRAM_TOL
    $miss = @($rcm.missing)
    $ok = (-not $miss.Count -and -not $drift.Count)
    $checks.Add((New-Check 'macro-recompute' $ok ([ordered]@{
        servings = $servings
        recompute = [ordered]@{ cal = $rcm.cal; protein = $rcm.protein; carbs = $rcm.carbs; fat = $rcm.fat }
        stat      = [ordered]@{ cal = [double]$spec.stat.cal; protein = [double]$spec.stat.protein; carbs = [double]$spec.stat.carbs; fat = [double]$spec.stat.fat }
        missing_fooddb_rows = $miss
      }) `
      $(if ($ok) { ("all four macros recompute from food-macros-db within tolerance ({0} cal, {1} g)" -f $script:MACRO_CAL_TOL, $script:MACRO_GRAM_TOL) }
        elseif ($miss.Count) { ("these ingredients have no food-macros-db row, so the recompute is incomplete: " + ($miss -join ', ')) }
        else { ($drift -join '; ') })))
  }

  # --- cost ---
  if (-not $costedRows.ContainsKey($slug)) {
    $checks.Add((New-Check 'cost-engine-consistency' $false ([ordered]@{}) 'no row for this slug in db\costed.json - the cost engine has never priced it'))
    $checks.Add((New-Check 'cost-reconcile' $false ([ordered]@{}) 'no engine row to reconcile the spec against'))
  } else {
    $row = $costedRows[$slug]
    $ecp = Test-CostEngineConsistency $row $servings $script:CENT
    $checks.Add((New-Check 'cost-engine-consistency' ($ecp.Count -eq 0) ([ordered]@{
        cost_batch = [double]$row.cost_batch; cost_batch_true = [double]$row.cost_batch_true
        cost_per_serving = [double]$row.cost_per_serving; cost_first_run = [double]$row.cost_first_run
        lines = @($row.lines).Count; lines_unpriced = [int]$row.lines_unpriced
      }) `
      $(if ($ecp.Count -eq 0) { 'the engine row is internally coherent: utils sum to the batch, both per-serving tiers derive, first run is true + pantry, nothing unpriced' } else { ($ecp -join '; ') })))

    $scp = Test-CostSpecVsEngine $spec $row $script:CENT
    $specMtime = (Get-Item $specPath).LastWriteTime
    $aged = ($costedMtime -gt $specMtime)
    $checks.Add((New-Check 'cost-reconcile' ($scp.Count -eq 0) ([ordered]@{
        spec_mtime = $specMtime.ToString('s'); costed_mtime = $costedMtime.ToString('s')
        costed_is_newer_than_spec = $aged
      }) `
      $(if ($scp.Count -eq 0) { 'every spec cost field matches its engine row to the cent' }
        else { ("{0}{1} The fix is recost-spec-cost-block.ps1, not a rebuild, and a wave must not publish a stale price." -f ($scp -join '; '), `
            $(if ($aged) { (" db\costed.json was rewritten at {0}, after this spec's {1}, so grocery prices moving is the likely cause." -f $costedMtime.ToString('s'), $specMtime.ToString('s')) }
              else { (" This spec's mtime ({0}) is at or after costed.json's ({1}), so price age is not the whole story - something wrote the spec without re-syncing its cost block, or a later edit touched other fields. The mtimes narrow it; they do not settle it." -f $specMtime.ToString('s'), $costedMtime.ToString('s')) })) })))
  }

  # --- protein derivation ---
  $pd = Get-ProteinByGrams $gramRows
  $claimed = ([string]$spec.protein).ToLower().Trim()
  $claimedFamily = $claimed -replace '^ground\s+', ''      # 'ground beef' and 'beef' are one family
  $pOk = ($null -ne $pd.cat -and $pd.cat -eq $claimedFamily)
  $checks.Add((New-Check 'protein-derivation' $pOk ([ordered]@{ claimed = $claimed; derived = $pd.cat; derived_grams = $pd.grams; tally = $pd.tally }) `
    $(if ($pOk) { ("the spec's protein field matches its heaviest protein ingredient by grams ({0}, {1} g)" -f $pd.cat, $pd.grams) }
      elseif ($null -eq $pd.cat) { "no ingredient classified into a protein family, so this claim could not be derived either way - rule it yourself (build-hub-grid's own note records Bratwurst as the miss)" }
      else { ("the spec claims '{0}' but the heaviest protein by grams is {1} ({2} g)" -f $claimed, $pd.cat, $pd.grams) })))

  # --- voice sweep ---
  $dh = Get-DashHits $spec
  $checks.Add((New-Check 'voice-sweep' ($dh.Count -eq 0) ([ordered]@{ hits = $dh.Count }) `
    $(if ($dh.Count -eq 0) { 'no em or en dash anywhere in the spec' } else { ($dh -join ' | ') })))

  # --- card rebuild + structural compare ---
  $slugScratch = Join-Path $scratchRoot $slug
  New-Item -ItemType Directory -Force $slugScratch | Out-Null
  $built = $false; $buildErr = ''
  try {
    & (Join-Path $here 'build-card2.ps1') -SpecFile $specPath -CostedFile $costedPath -OutDir $slugScratch *>$null
    $built = $true
  } catch { $buildErr = $_.Exception.Message }
  $bodyPath = Join-Path $slugScratch ("{0}.body.html" -f $slug)
  $headPath = Join-Path $slugScratch ("{0}.head.html" -f $slug)
  if (-not $built -or -not (Test-Path $bodyPath)) {
    $checks.Add((New-Check 'card-rebuild' $false ([ordered]@{ scratch = $slugScratch }) ("build-card2.ps1 could not render this spec: " + $(if ($buildErr) { $buildErr } else { 'no body html was written' }))))
  } else {
    $body = [IO.File]::ReadAllText($bodyPath, [Text.Encoding]::UTF8)
    $stepCount = @($spec.make_it).Count
    $gaps = Get-CardStructuralGaps $body $refHtml $stepCount
    $ldOk = $true; $ldWhy = ''
    if (Test-Path $headPath) {
      $head = [IO.File]::ReadAllText($headPath, [Text.Encoding]::UTF8)
      $m = [regex]::Match($head, '(?s)<script type="application/ld\+json">(.*?)</script>')
      if (-not $m.Success) { $ldOk = $false; $ldWhy = 'the head carries no JSON-LD block' }
      else {
        try { $ld = $m.Groups[1].Value | ConvertFrom-Json; if ([string]$ld.'@type' -ne 'Recipe') { $ldOk = $false; $ldWhy = ("the JSON-LD @type is '{0}', not Recipe" -f $ld.'@type') } }
        catch { $ldOk = $false; $ldWhy = 'the JSON-LD does not parse: ' + $_.Exception.Message }
      }
    } else { $ldOk = $false; $ldWhy = 'no head html was written' }
    if (-not $ldOk) { $gaps = @(@($gaps) + @($ldWhy)) }
    $checks.Add((New-Check 'card-rebuild' (@($gaps).Count -eq 0) ([ordered]@{
        scratch = $slugScratch; body_bytes = $body.Length; make_it_steps = $stepCount
        reference = (Split-Path $ReferenceCard -Leaf)
      }) `
      $(if (@($gaps).Count -eq 0) { ("rebuilt to a scratch dir and structurally identical to {0}: every smp-* class and anchor id present, {1} step anchors, no dash bytes, JSON-LD parses as a Recipe" -f (Split-Path $ReferenceCard -Leaf), $stepCount) } else { (@($gaps) -join ' | ') })))

    # ---- widget-count-basis: does the rebuilt card's WIDGET buy what its COST LINE says to buy? ----
    # Read out of the card that was just rendered, not out of db\built, so a wave is refused before it
    # publishes rather than after. The typed script tag is the anchor: the template's own JS contains
    # the bare class name, so searching for that would match the code instead of the payload.
    $blockRe = [regex]'(?s)<script type="application/json" class="smp-sc-data">(.*?)</script>'
    $bm = $blockRe.Match($body)
    if (-not $bm.Success) {
      $checks.Add((New-Check 'widget-count-basis' $false ([ordered]@{}) 'the rebuilt card carries no smp-sc-data block, so the widget has no numbers to check'))
    } else {
      $blockOk = $true; $wcb = @(); $wcbLines = 0; $wcbSkipped = 0
      try { $blockDoc = $bm.Groups[1].Value | ConvertFrom-Json } catch { $blockOk = $false }
      if (-not $blockOk) {
        $checks.Add((New-Check 'widget-count-basis' $false ([ordered]@{}) 'the smp-sc-data block does not parse as JSON'))
      } else {
        $cRow = $costedRows[$slug]
        $cLines = @{}
        if ($cRow) { foreach ($cl in @($cRow.lines)) { $cLines[[string]$cl.item] = $cl } }
        $scaler = @($spec.scaler.ing)
        $bIng = @($blockDoc.ing)
        $joined = New-Object System.Collections.Generic.List[object]
        for ($bi = 0; $bi -lt $bIng.Count; $bi++) {
          $it = $bIng[$bi]
          # build-card2 emits one block line per scaler line, in order, so the index IS the join. Name
          # matching would be wrong on every canon'd line, where the costed row is keyed by the canon.
          $sk = if ($bi -lt $scaler.Count) { $scaler[$bi] } else { $null }
          $key = if ($null -ne $sk -and ($sk.PSObject.Properties.Name -contains 'canon') -and $sk.canon) { [string]$sk.canon } elseif ($null -ne $sk) { [string]$sk.item } else { [string]$it.item }
          $cl = $cLines[$key]
          # only lines the engine gave a real BUY package: a bulk staple's block carries its pantry
          # container and a covered line carries none, and neither has a buy count to compare against.
          if ($null -eq $cl -or $null -eq $cl.pkg_g -or [double]$cl.pkg_g -le 0) { $wcbSkipped++; continue }
          $ir = $ingRows[$key]
          $wcbLines++
          [void]$joined.Add([pscustomobject]@{
            item  = [string]$it.item; grams = [double]$it.grams
            gpu   = $(if ($it.PSObject.Properties.Name -contains 'gpu') { [double]$it.gpu } else { 0.0 })
            pkg_g = [double]$it.pkg_g; buy_n = [int]$cl.buy_n
            ing_gpu         = $(if ($null -ne $ir -and $ir.gpu) { [double]$ir.gpu } else { 0.0 })
            ing_buy_pkg_g   = $(if ($null -ne $ir -and $ir.buy_pkg_g) { [double]$ir.buy_pkg_g } else { 0.0 })
          })
        }
        # .ToArray(), never @($joined): @() on a List[object] throws in PS 5.1, which is exactly how
        # this check died on its first drill run.
        $wcb = Test-WidgetCountBasis ($joined.ToArray())
        $checks.Add((New-Check 'widget-count-basis' (@($wcb).Count -eq 0) ([ordered]@{
            lines_checked = $wcbLines; lines_skipped = $wcbSkipped; findings = @($wcb).Count
          }) `
          $(if (@($wcb).Count -eq 0) { ("the widget, the print list and the store picker buy exactly what the cost line says on all {0} package line(s), at every serving count from 2 to 42, and every fallback package is the real one ({1} bulk/covered line(s) have no buy package to check)" -f $wcbLines, $wcbSkipped) } else { (@($wcb) -join ' | ') })))
      }
    }
  }

  $slugChecks.Add($slug, $checks.ToArray())
}

# ---- the report -------------------------------------------------------------------------------------
$failCount = 0; $checkCount = 0
$sharedArr = $sharedChecks.ToArray()
foreach ($k in @($slugChecks.Keys)) { foreach ($c in $slugChecks[$k]) { $checkCount++; if ($c.verdict -eq 'fail') { $failCount++ } } }
foreach ($c in $sharedArr) { $checkCount++; if ($c.verdict -eq 'fail') { $failCount++ } }

$report = [ordered]@{
  battery      = 'wave-preaudit'
  version      = 1
  run          = [string]$man.run
  wave         = $Wave
  batch        = [string]$man.batch
  scope        = $scope
  generated    = (Get-Date).ToString('s')
  elapsed_sec  = [Math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
  wave_slugs   = @($waveSlugs)
  slugs        = @($target)
  inputs       = [ordered]@{
    # THE RESOLVED RunDir, recorded because the Start-Job fan-out depends on it being absolute and
    # nothing else in this report would show whether it is. A relative value here means the shared
    # gates ran against a path their job process could not see.
    run_dir        = $RunDir
    costed_mtime   = $costedMtime.ToString('s')
    reference_card = $ReferenceCard
    food_db        = $foodDbPath
  }
  slug_checks   = $slugChecks
  shared_checks = $sharedArr
  summary       = [ordered]@{ slugs = $target.Count; checks = $checkCount; failed = $failCount }
  # Said plainly so nobody reads a green battery as a green wave. Every one of these is the auditor's,
  # and the auditor may re-derive anything above it as well.
  not_checked  = @(
    'mapping soundness and the precedents behind a substitution',
    'price-class plausibility (is this the right FORM of the ingredient)',
    'cross-recipe checks and dish identity',
    'condition questions the run has not ruled on',
    'stat.cost_ps basis - wave-publish E2 re-anchors and hard-verifies it per slug at publish time',
    'whether the wave manifest, the ledger and the recipe states tell one story - wave-publish P2/P3'
  )
}

New-Item -ItemType Directory -Force (Split-Path $OutFile -Parent) | Out-Null
[IO.File]::WriteAllText($OutFile, ($report | ConvertTo-Json -Depth 12), $UTF8)

Write-Output ''
foreach ($k in @($slugChecks.Keys)) {
  $bad = @($slugChecks[$k] | Where-Object { $_.verdict -eq 'fail' })
  if ($bad.Count) {
    Write-Output ("  X {0}" -f $k)
    foreach ($c in $bad) { Write-Output ("      {0,-24} {1}" -f $c.check, $c.detail) }
  } else {
    Write-Output ("  ok {0,-52} {1} check(s) pass" -f $k, @($slugChecks[$k]).Count)
  }
}
Write-Output ''
foreach ($c in $sharedArr) {
  if ($c.verdict -eq 'fail') { Write-Output ("  X  {0,-28} {1}" -f $c.check, $c.detail) }
  else { Write-Output ("  ok {0,-28} {1}" -f $c.check, $c.detail) }
}
Write-Output ''
Write-Output ("report -> {0}" -f $OutFile)
if ($runJson) { Write-Output ($report | ConvertTo-Json -Depth 12) }

$summary = ("wave {0} scope={1} slugs={2} checks={3} failed={4} in {5}s" -f $Wave, $(if ($scope -eq 'whole-wave') { 'whole-wave' } else { 'scoped' }), $target.Count, $checkCount, $failCount, $report.elapsed_sec)
Write-GuardComplete -Name 'wave-preaudit' -Summary $summary
if ($failCount -gt 0) { exit 1 }
exit 0
