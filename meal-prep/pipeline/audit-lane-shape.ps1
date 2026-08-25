# audit-lane-shape.ps1 - did the Recipe Hunter run its lanes in the SHAPE the design specifies?
#
# WHY THIS EXISTS (2026-08-15). A session built the hunt orchestration from
# .claude\skills\recipe-hunter\SKILL.md alone instead of design\PLAN-recipe-hunter-v2-2026-08-15.md
# section 2.4, and made PRICING a per-recipe pipeline stage.
#
# The PRICE lane is not a per-recipe stage. It is a SINGLETON QUEUE DRAINER that takes up to 10 absent
# terms ACROSS recipes, because grocery\ingredient-queue.ps1 is keyed by TERM and not by recipe. Driving
# it per recipe costs twice:
#   1. it discards the queue's cross-recipe dedup - two recipes that both want harissa price harissa twice;
#   2. it opens the pricer's seven store sessions once per RECIPE instead of once per 10-term batch, which
#      is the sweep shape that walled Walmart at 55 of 526 terms and Sam's at 205.
# The MAP lane has the same shape at a smaller size: section S4 says micro-batches of up to 5 recipes.
#
# WHAT MADE IT INVISIBLE. Every artifact the run left behind - the state files, the ingredient queue, the
# wave manifests, the ledger - records the RESULT of the work. Not one of them records the SHAPE of the
# work, so a run that priced 9 terms in 8 sessions and a run that priced them in 1 leave byte-identical
# evidence. SKILL.md and its frontmatter were corrected the same day, but a correction with no mechanical
# check behind it is documentation, and this estate has a pile of documentation that used to be a rule.
#
# So hunt-run.ps1 -Lane now writes `<RunDir>\lane-log.jsonl`, one append-only line per agent invocation,
# and this script judges it. It reads the lane log, the run's state files, and (when available) the
# ingredient queue, and reports the lane shape the run ACTUALLY used against the shape the plan specifies.
#
# Exit codes follow the estate contract: 0 clean, 1 findings, 2 hard error, 3 could-not-evaluate.
# The last line is LANE-SHAPE-COMPLETE per lib\guard-contract.ps1, so a crash cannot read as a clean run.
#
# Usage:
#   .\audit-lane-shape.ps1 -RunDir C:\Codex\ThriftyCrew\meal-prep\runs\hunt-2026-08-15 [-Json]
#   .\audit-lane-shape.ps1 -SelfTest
param(
  [switch]$SelfTest,
  [string]$RunDir = '',
  [string]$QueueScript = '',
  [switch]$Json
)
$ErrorActionPreference = 'Stop'

# Capture every switch BEFORE dot-sourcing anything: a dot-sourced script's param() block runs in THIS
# scope, and a lib declaring [switch]$SelfTest silently resets ours to $false. That trap made
# migrate-prose-tokens' first -SelfTest run execute the LIVE path.
$runSelfTest = [bool]$SelfTest; $runJson = [bool]$Json

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here                      # ...\meal-prep
$repo = Split-Path -Parent $mp                        # ...\income
. (Join-Path $repo 'lib\guard-contract.ps1')

# ---------------------------------------------------------------------------------------------------
# THE PLAN'S NUMBERS, in one place. price=10 is section 2.4; map=5 is stage S4. A lane with no declared
# ceiling is counted and printed but never shape-judged - inventing a ceiling for it here would be this
# script making up a rule the design never made.
# ---------------------------------------------------------------------------------------------------
$script:LANE_BATCH = @{ 'price' = 10; 'map' = 5 }

# WHOSE INVOCATIONS THE BATCH SIZE IS ABOUT (added 2026-08-25).
#
# A LANE NAME IS NOT A STAGE. Both shape-judged lanes now file several kinds of line under one lane:
# `map` carries the MAPPER's micro-batches, the REGISTRAR's per-term gates and the MECHANICAL
# pre-resolve pass; `price` carries the PRICER's batches and the mechanical pre-pass. The plan numbers
# are about one stage each - S4's micro-batch of 5 is five recipes to ONE MAPPER, and 2.4's batch of
# 10 is ten terms to ONE PRICER - so shaping the whole lane measures a mixed population.
#
# Measured on hunt-2026-08-24-v3-phase6b: the map lane read as 22 invocations for 12 items and fired
# BOTH map-lane-not-batched and map-lane-duplicate-items over 9 slugs, every one of which was a slug
# that took a pre-resolve, a mapper and a registrar. Not one of those was real. It is the same defect
# class the 2026-08-24 pairing fix addressed, one level up: counting things that are not the thing.
#
# A registrar gate is not a mapper batch that failed to batch, and refusing to say so would leave the
# two real findings this script exists for buried under nine false ones - which is how a gate gets
# turned off.
$script:LANE_JUDGE = @{ 'price' = 'pricer'; 'map' = 'mapper' }
# Kept in step with hunt-run.ps1's write-side vocabulary ON PURPOSE, and drift is a FINDING rather than a
# silent skip: a lane hunt-run will happily record but this script does not know is a lane whose shape
# nobody is judging, which is how the founding bug hid in the first place.
$script:LANE_KNOWN = @('hunt', 'select', 'extract', 'map', 'price', 'write', 'qa', 'audit', 'publish', 'review')

# ===================================================================================================
# PURE PREDICATES. Everything that decides a finding lives here, takes plain objects, and touches no
# disk, so the self-test's fixtures are the real judge and not a mock of it.
# ===================================================================================================

# ONE INVOCATION IS ONE INVOCATION, however many lines it wrote.
#
# ADDED 2026-08-24 (PLAN-recipe-hunter-v3 D9's drain drill, measured). hunt-run.ps1 -Lane grew an
# `event` field on 2026-08-16 so a stage could stamp BOTH ends and its duration could finally be
# measured. This audit never learned about it. It counted every line as an invocation, so from that
# day forward it read every dispatch as two and every item as a duplicate - which means
# `<lane>-lane-duplicate-items` has fired by construction on every paired log since, and every
# invocation count it printed was doubled.
#
# Measured on a lane log the D9 daemon wrote: 4 dispatches, 8 lines, and the audit reported 2 map
# and 6 price "invocations" with all four price terms flagged as repeats. Not one of those was real.
#
# A start and an end line share lane + label + item list. Collapse them, preferring the END line
# because it is the one carrying the token stamp. A line with no `event` at all is an older
# unpaired line and stands on its own, which is what keeps this readable against historical logs.
function Get-Invocations {
  param($Lines)
  # PS 5.1: an EMPTY array arriving through an if-expression or a pipeline arrives as $null, and
  # `foreach ($l in @($null))` iterates ONCE over $null - so an empty lane would count as one
  # invocation and the `price-lane-unlogged` catch would never fire on the run that needs it.
  # Caught 2026-08-25 by the new zero-lane CLEAN TWIN, which is what a clean twin is for.
  if ($null -eq $Lines) { return @() }
  $out = @(); $seen = @{}
  foreach ($l in @($Lines)) {
    $ev = [string]$l.event
    if (-not $ev) { $out += $l; continue }
    $key = ('{0}|{1}|{2}' -f [string]$l.lane, [string]$l.label, ((@($l.items) | ForEach-Object { [string]$_ }) -join "`u{1}"))
    if ($seen.ContainsKey($key)) {
      # the pair's second half: keep the END line, which carries the tokens
      if ($ev -eq 'end') { $out[$seen[$key]] = $l }
      continue
    }
    $seen[$key] = $out.Count
    $out += $l
  }
  return @($out)
}

# HOW MANY INVOCATIONS, EVERYWHERE THIS SCRIPT PRINTS A NUMBER (added 2026-08-25).
#
# The 2026-08-24 fix taught the SHAPE-JUDGED lanes to collapse start/end pairs and stopped there.
# Three places kept counting raw LINES and calling them invocations: the headline total, the -Json
# `invocations` field, and the counted-not-judged lanes - which are extract, qa, select, write and
# audit, i.e. most of the run. Measured on hunt-2026-08-24-v3-phase6b: the header said 161 lane
# invocations over a log holding 72, and printed extract 24, write 22, audit 14, qa 10, select 8
# where 12, 11, 8, 5 and 4 invocations exist. Every one of those numbers was exactly doubled except
# where an unpaired line survived. Thursday's wide run is measured with this instrument, so a
# doubled count is a doubled cost story.
function Get-InvocationCount {
  param($Lines, [string]$Lane = '')
  $sel = @($Lines)
  if ($Lane) { $sel = @($sel | Where-Object { [string]$_.lane -eq $Lane }) }
  return @(Get-Invocations $sel).Count
}

# Narrow a lane's invocations to the STAGE the batch size is about.
#
# A LINE WITH NO `by` AT ALL IS AN OLD LINE and is kept, because the field arrived after some of the
# logs this script still reads. If NOTHING in the lane carries a `by`, the whole lane is a historical
# log and every line stands - filtering there would judge a real run as having made no invocations,
# which is the vacuity failure this file already refuses elsewhere.
function Select-JudgeInvocations {
  param($Invocations, [string]$Stage)
  $inv = @($Invocations)
  if (-not $Stage -or -not $inv.Count) { return $inv }
  $withBy = @($inv | Where-Object { [string]$_.by })
  if (-not $withBy.Count) { return $inv }
  return @($inv | Where-Object { (-not [string]$_.by) -or ([string]$_.by -eq $Stage) })
}

# The headline: how many invocations did this lane take, against how many the batch size needed?
function Get-BatchShape {
  param($Invocations, [int]$BatchSize)
  $inv = @($Invocations)
  $all = @()
  foreach ($i in $inv) { foreach ($t in @($i.items)) { $t = [string]$t; if ($t) { $all += $t } } }
  $distinct = @($all | Sort-Object -Unique)
  $n = $inv.Count
  # ceil(items / batch) - the fewest invocations that could have done this work. This is the number the
  # design promises, and the one the run is measured against.
  $floor = if ($distinct.Count) { [int][Math]::Ceiling($distinct.Count / [double]$BatchSize) } else { 0 }
  # mean is over TOTAL items taken, not distinct: it answers "how much did each invocation actually carry",
  # which is the question about shape. distinct drives the floor, because that is the work that had to happen.
  $mean = if ($n) { [Math]::Round($all.Count / [double]$n, 2) } else { 0 }
  # a term that appears in TWO invocations was priced twice - the cross-recipe dedup the queue exists to
  # provide, thrown away. This is per-recipe pricing's most direct fingerprint.
  $repeated = @($all | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { [string]$_.Name } | Sort-Object)

  # THE RULE, and why each clause is there:
  #   n >= 3        - two invocations for two items is a stream draining as terms arrive, not a shape defect.
  #                   Small-n noise must not fire a gate, or the gate gets turned off.
  #   n > floor     - a run that used no more invocations than the work required is correct by definition.
  #   mean < half   - the discriminator. A drainer that legitimately runs several times still fills its
  #                   batches (4 invocations of 5 terms each is fine); per-recipe driving cannot, because a
  #                   recipe has 1-3 absent terms. Half the batch size separates the two without guessing.
  $fires = ($n -ge 3 -and $n -gt $floor -and $mean -lt ($BatchSize / 2.0))
  return [pscustomobject]@{
    invocations = $n; items = $all.Count; distinct = $distinct.Count; batch_size = $BatchSize
    floor = $floor; mean_per_invocation = $mean; repeated = @($repeated); fires = $fires
  }
}

# The corroborating fingerprint: did every invocation stay inside ONE recipe? A true queue drainer batches
# across recipes whenever more than one recipe is waiting, so an all-singleton lane over several recipes is
# a per-recipe pipeline wearing the lane's name.
function Get-PerRecipeSignature {
  param($Invocations, $Owners)
  $inv = @($Invocations)
  $perInv = @()
  foreach ($i in $inv) {
    $r = @()
    foreach ($t in @($i.items)) {
      $key = [string]$t
      if ($Owners -and $Owners.ContainsKey($key)) { $r += @($Owners[$key] | ForEach-Object { [string]$_ }) }
    }
    $perInv += , @($r | Sort-Object -Unique)
  }
  # invocations whose terms we can attribute at all. An unattributable invocation proves nothing either way
  # and must not be counted as evidence FOR the defect.
  $known = @($perInv | Where-Object { @($_).Count -ge 1 })
  $recipes = @($perInv | ForEach-Object { @($_) } | Where-Object { $_ } | Sort-Object -Unique)
  $crossed = @($known | Where-Object { @($_).Count -gt 1 })
  $allSingle = ($known.Count -ge 1 -and $crossed.Count -eq 0)
  # THREE recipes each getting their own pricer session is not a coincidence of arrival times; TWO can be,
  # so two is reported and not ruled on. Never convict on evidence that has an innocent reading.
  $fires = ($allSingle -and $recipes.Count -ge 3 -and $inv.Count -ge $recipes.Count)
  $suspect = ($allSingle -and $recipes.Count -eq 2 -and $inv.Count -ge 2)
  return [pscustomobject]@{
    attributed = $known.Count; recipes_touched = $recipes.Count; crossed_invocations = $crossed.Count
    every_invocation_single_recipe = $allSingle; fires = $fires; suspect = $suspect
    recipes = @($recipes)
  }
}

# ===================================================================================================
# IO
# ===================================================================================================
function Read-LaneLog {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return @() }
  $out = @()
  foreach ($ln in @([IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8))) {
    $t = ([string]$ln -replace "^﻿", '').Trim()
    if (-not $t) { continue }
    try { $out += ($t | ConvertFrom-Json) }
    catch { throw ("audit-lane-shape: lane-log.jsonl has an unparseable line: " + $t) }
  }
  return @($out)
}

function Read-StateEntries {
  param([string]$Dir)
  $sd = Join-Path $Dir 'state'
  if (-not (Test-Path $sd)) { return @() }
  $out = @()
  foreach ($f in @(Get-ChildItem (Join-Path $sd '*.json') -File)) {
    $raw = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) -replace "^﻿", ''
    $out += ($raw | ConvertFrom-Json)
  }
  return @($out)
}

# term -> the run's OWN recipes that asked for it. Built from the state files rather than from the queue,
# because the queue is global across runs and this audit judges one run.
function Get-TermOwners {
  param($Entries)
  $map = @{}
  foreach ($e in @($Entries)) {
    foreach ($t in @($e.terms)) {
      if ([bool]$t.optional) { continue }
      $k = [string]$t.term
      if (-not $k) { continue }
      if (-not $map.ContainsKey($k)) { $map[$k] = @() }
      $map[$k] = @(@($map[$k]) + [string]$e.slug | Sort-Object -Unique)
    }
  }
  return $map
}

# Did a recipe ever sit in `pricing`? Read from history, because a recipe that has since been priced,
# parked or rejected no longer says so in its current state - and the question is whether the run PRICED.
function Test-EverPriced {
  param($Entry)
  if ([string]$Entry.state -eq 'pricing') { return $true }
  foreach ($h in @($Entry.history)) { if ([string]$h.state -eq 'pricing') { return $true } }
  return $false
}

# ===================================================================================================
# SELF-TEST. Per the estate's guard-fixture rule (v2.1 section 8): every check ships its must-fire
# founding-bug fixture and its clean twin in the same commit as the check. Hermetic.
# ===================================================================================================
if ($runSelfTest) {
  $f = 0
  function T($m, $c, $g) { if ($c) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $g); $script:f++ } }
  # $invRows, never $invocations or $items: this script declares no such parameter today, but hunt-run's
  # $terms/$Terms collision (case-insensitive variable names silently binding a fixture to a TYPED param)
  # cost that file a whole self-test run, and the fix there was a naming rule, not a one-off rename.
  function Inv($label, $itemList) { return [pscustomobject]@{ lane = 'price'; label = $label; items = @($itemList); count = @($itemList).Count } }

  # ---- FIXTURE 1. THE FOUNDING BUG, frozen: 2026-08-15, the price lane driven per recipe. Nine absent
  # terms across nine recipes, taken one recipe at a time, is eight pricer invocations where one 10-term
  # batch was the whole job - and eight sets of seven store sessions instead of one.
  $perRecipe = @(
    (Inv 'chicken-florentine'          @('mascarpone')),
    (Inv 'loco-moco'                   @('kewpie mayo')),
    (Inv 'country-captain-chicken'     @('mango chutney')),
    (Inv 'pork-lo-mein'                @('shaoxing wine')),
    (Inv 'chinese-beef-and-broccoli'   @('oyster sauce')),
    (Inv 'marry-me-chicken'            @('sun dried tomato')),
    (Inv 'mississippi-pot-roast'       @('pepperoncini')),
    (Inv 'chicken-fricassee'           @('creme fraiche', 'tarragon'))
  )
  $b1 = Get-BatchShape $perRecipe 10
  T 'MUST FIRE  8 pricer invocations for 9 terms is a per-recipe price lane' $b1.fires ("fires=" + $b1.fires)
  T '   and it says how few would have done (ceil(9/10) = 1)' ($b1.floor -eq 1 -and $b1.distinct -eq 9) ("floor=" + $b1.floor + " distinct=" + $b1.distinct)
  T '   and it names the mean batch it actually took' ($b1.mean_per_invocation -lt 2) $b1.mean_per_invocation

  # ---- CLEAN TWIN. The same nine terms, drained as the singleton lane is supposed to drain them.
  $batched = @((Inv 'batch 1' @('mascarpone', 'kewpie mayo', 'mango chutney', 'shaoxing wine', 'oyster sauce',
                                'sun dried tomato', 'pepperoncini', 'creme fraiche', 'tarragon')))
  $b2 = Get-BatchShape $batched 10
  T 'CLEAN TWIN 1 invocation for the same 9 terms is clean' (-not $b2.fires) ("fires=" + $b2.fires)
  T '   and it used exactly the floor' ($b2.invocations -eq $b2.floor) ("n=" + $b2.invocations + " floor=" + $b2.floor)

  # ---- FIXTURE 2. THE GATE MUST NOT FIRE ON A LANE DOING ITS JOB. A streamed run drains repeatedly as
  # terms arrive; that is the design, not a defect. Full batches never fire however many there are.
  $honest = @((Inv 'b1' @(1..10 | ForEach-Object { "t$_" })), (Inv 'b2' @(11..20 | ForEach-Object { "t$_" })),
              (Inv 'b3' @(21..30 | ForEach-Object { "t$_" })), (Inv 'b4' @(31..40 | ForEach-Object { "t$_" })))
  T 'CLEAN TWIN four FULL 10-term batches never fire, however many rounds' (-not (Get-BatchShape $honest 10).fires) 'fired on a correct drainer'
  $halfish = @((Inv 'b1' @('a', 'b', 'c', 'd', 'e')), (Inv 'b2' @('f', 'g', 'h', 'i', 'j')),
               (Inv 'b3' @('k', 'l', 'm', 'n', 'o')), (Inv 'b4' @('p', 'q', 'r', 's', 't')))
  T 'CLEAN TWIN half-full batches as terms trickle in do not fire either' (-not (Get-BatchShape $halfish 10).fires) 'fired on a trickling drainer'
  T 'CLEAN TWIN two invocations for two terms is stream timing, not a shape defect' `
    (-not (Get-BatchShape @((Inv 'b1' @('a')), (Inv 'b2' @('b'))) 10).fires) 'fired on small-n noise'
  T 'CLEAN TWIN a run that never priced is not a finding' (-not (Get-BatchShape @() 10).fires) 'fired on an empty lane'

  # ---- FIXTURE 3. LOST CROSS-RECIPE DEDUP. The queue is keyed by TERM precisely so a shared ingredient is
  # priced once. Per-recipe driving prices it once per recipe, and that is visible without any threshold.
  $shared = @((Inv 'r1' @('harissa', 'couscous')), (Inv 'r2' @('harissa', 'preserved lemon')))
  T 'MUST FIRE  a term priced in two invocations shows the dedup was discarded' `
    (@((Get-BatchShape $shared 10).repeated) -contains 'harissa') (@((Get-BatchShape $shared 10).repeated) -join ',')
  T 'CLEAN TWIN one batch carrying both recipes prices harissa once' `
    ((@((Get-BatchShape @((Inv 'b1' @('harissa', 'couscous', 'preserved lemon'))) 10).repeated)).Count -eq 0) 'reported a repeat that is not there'

  # ---- FIXTURE 3b. START/END PAIRS ARE ONE INVOCATION (added 2026-08-24, D9's drain drill).
  # This audit read every LINE as an invocation, and hunt-run.ps1 has stamped both ends of every
  # dispatch since 2026-08-16. So from that day it counted every invocation twice and reported every
  # item as a duplicate - `<lane>-lane-duplicate-items` fired by construction, on every paired log,
  # and the counts it printed were doubled. Measured on a D9 lane log: 4 dispatches, 8 lines, read
  # as 2 map and 6 price invocations with all four price terms flagged as repeats. None of it real.
  function PairInv([string]$Label, $Items, [string]$Event, [int]$In) {
    return [pscustomobject]@{ lane = 'price'; label = $Label; items = @($Items); count = @($Items).Count
                              by = 'pricer'; event = $Event; in = $In; out = 224 }
  }
  $paired = @((PairInv 'batch 1' @('harissa', 'couscous') 'start' -1),
              (PairInv 'batch 1' @('harissa', 'couscous') 'end' 15470),
              (PairInv 'batch 2' @('sumac', 'zaatar') 'start' -1),
              (PairInv 'batch 2' @('sumac', 'zaatar') 'end' 15470))
  $collapsed = @(Get-Invocations $paired)
  T 'MUST FIRE  a start/end PAIR is ONE invocation, not two' ($collapsed.Count -eq 2) ("got " + $collapsed.Count)
  T 'MUST FIRE  and the END line is the survivor, because it is the one carrying the token stamp' `
    ((@($collapsed | Where-Object { [int]$_.in -eq 15470 })).Count -eq 2) `
    (@($collapsed | ForEach-Object { [string]$_.in }) -join ',')
  T 'MUST FIRE  a paired log reports NO duplicate items - an item in its own start and end line was
        never priced twice' `
    ((@((Get-BatchShape $collapsed 10).repeated)).Count -eq 0) `
    (@((Get-BatchShape $collapsed 10).repeated) -join ',')
  T '   and the raw lines, uncollapsed, are exactly what used to fire it' `
    ((@((Get-BatchShape $paired 10).repeated)).Count -eq 4) `
    (@((Get-BatchShape $paired 10).repeated) -join ',')
  T 'CLEAN TWIN an OLD unpaired line (no event field) still counts as its own invocation' `
    ((@(Get-Invocations @((Inv 'b1' @('a')), (Inv 'b2' @('b'))))).Count -eq 2) 'collapsed two real invocations'
  T 'CLEAN TWIN two DIFFERENT batches that happen to share a label are not collapsed into one' `
    ((@(Get-Invocations @((PairInv 'batch 1' @('a') 'start' -1), (PairInv 'batch 1' @('b') 'start' -1)))).Count -eq 2) `
    'collapsed two invocations that carried different items'

  # ---- FIXTURE 3c. THE COUNTS THIS SCRIPT PRINTS ARE INVOCATIONS TOO (added 2026-08-25).
  # 3b taught the shape-judged lanes to collapse pairs. The headline total, the -Json field and the
  # counted-not-judged lanes were left counting raw lines, which is most of what a reader actually
  # looks at. Measured on hunt-2026-08-24-v3-phase6b before this fix: header 161 for a 72-invocation
  # log, extract 24 for 12.
  # NEUTER PROOF, run 2026-08-25: point Get-InvocationCount back at @($Lines).Count (or at the raw
  # Where-Object counts the three call sites used) and the two MUST FIRE cases below go red at
  # exactly double, while the CLEAN TWIN on unpaired lines stays green - which is the whole point,
  # an old log must still read correctly.
  function XInv([string]$Lane, [string]$Label, $Items, [string]$Event) {
    return [pscustomobject]@{ lane = $Lane; label = $Label; items = @($Items); count = @($Items).Count
                              by = 'local'; event = $Event; in = 0; out = 0 }
  }
  $mixed = @((XInv 'extract' 'local rung 1' @('slug-a') 'start'), (XInv 'extract' 'local rung 1' @('slug-a') 'end'),
             (XInv 'extract' 'local rung 1' @('slug-b') 'start'), (XInv 'extract' 'local rung 1' @('slug-b') 'end'),
             (XInv 'extract' 'local rung 2' @('slug-c') 'start'), (XInv 'extract' 'local rung 2' @('slug-c') 'end'),
             (XInv 'qa' 'slug-a' @('slug-a') 'start'), (XInv 'qa' 'slug-a' @('slug-a') 'end'))
  T 'MUST FIRE  a counted-not-judged lane counts INVOCATIONS, not lines - 6 extract lines are 3 invocations' `
    ((Get-InvocationCount $mixed 'extract') -eq 3) ("got " + (Get-InvocationCount $mixed 'extract'))
  T 'MUST FIRE  and the headline total is invocations across every lane - 8 lines are 4 invocations' `
    ((Get-InvocationCount $mixed) -eq 4) ("got " + (Get-InvocationCount $mixed))
  T '   and the raw line counts, uncollapsed, are exactly the doubled numbers this replaces' `
    ((@($mixed | Where-Object { [string]$_.lane -eq 'extract' }).Count -eq 6) -and (@($mixed).Count -eq 8)) `
    'the fixture is not reproducing the defect it fixes'
  T 'CLEAN TWIN an OLD unpaired log (no event field) still counts every line, because each line IS an invocation' `
    ((Get-InvocationCount @((Inv 'b1' @('a')), (Inv 'b2' @('b')), (Inv 'b3' @('c')))) -eq 3) `
    ('got ' + (Get-InvocationCount @((Inv 'b1' @('a')), (Inv 'b2' @('b')), (Inv 'b3' @('c')))))
  T 'MUST FIRE  Get-Invocations over $null is ZERO invocations, not one - PS 5.1 iterates once over
        $null, and a phantom invocation is what would let price-lane-unlogged pass on the run it exists for' `
    ((@(Get-Invocations $null)).Count -eq 0) ('got ' + (@(Get-Invocations $null)).Count)
  T 'CLEAN TWIN a lane with no lines at all counts zero, so the map-lane-unlogged catch still fires' `
    ((Get-InvocationCount $mixed 'map') -eq 0) ('got ' + (Get-InvocationCount $mixed 'map'))

  # ---- FIXTURE 3d. A LANE NAME IS NOT A STAGE (added 2026-08-25).
  # The map lane files mapper batches, registrar gates and the mechanical pre-resolve under one lane
  # name. Judging the whole lane against S4's micro-batch of 5 measures a mixed population, and on 6b
  # it fired map-lane-duplicate-items over 9 slugs, every one of which had simply taken a pre-resolve,
  # a mapper and a registrar. NEUTER PROOF, run 2026-08-25: make Select-JudgeInvocations return its
  # input unchanged and the two MUST FIRE cases below go red, reporting 5 invocations and 3 repeats.
  function ByInv([string]$Lane, [string]$Label, $Items, [string]$By) {
    return [pscustomobject]@{ lane = $Lane; label = $Label; items = @($Items); count = @($Items).Count
                              by = $By; event = 'end'; in = 0; out = 0 }
  }
  $mapMixed = @((ByInv 'map' 'map-preresolve' @('r1', 'r2', 'r3') 'mechanical'),
                (ByInv 'map' 'map:3x' @('r1', 'r2', 'r3') 'mapper'),
                (ByInv 'map' 'registrar:goat-cheese' @('r1') 'registrar'),
                (ByInv 'map' 'registrar:harissa' @('r2') 'registrar'),
                (ByInv 'map' 'map-preresolve verify' @('r3') 'mechanical'))
  $judged = @(Select-JudgeInvocations $mapMixed 'mapper')
  T 'MUST FIRE  only the MAPPER''s own batches are judged against S4''s micro-batch of 5 - a registrar
        gate is not a mapper batch that failed to batch' `
    ($judged.Count -eq 1) ("judged " + $judged.Count + " of " + $mapMixed.Count)
  T 'MUST FIRE  and the mixed lane no longer reports every slug as a duplicate - on 6b that fired
        over 9 slugs and not one of them was real' `
    ((@((Get-BatchShape $judged 5).repeated)).Count -eq 0) `
    (@((Get-BatchShape $mapMixed 5).repeated) -join ', ')
  T '   and the raw mixed lane, unfiltered, is exactly the false finding this replaces' `
    ((@((Get-BatchShape $mapMixed 5).repeated)).Count -eq 3) `
    (@((Get-BatchShape $mapMixed 5).repeated) -join ', ')
  T 'CLEAN TWIN the price lane narrows to the PRICER, so the mechanical pre-pass is not a price batch' `
    ((@(Select-JudgeInvocations @((ByInv 'price' 'pre-pass batch 1' @('a', 'b') 'pre-pass'),
                                  (ByInv 'price' 'queue batch 1' @('a', 'b', 'c') 'pricer'),
                                  (ByInv 'price' 'pre-pass batch 2' @('c') 'pre-pass')) 'pricer')).Count -eq 1) `
    'kept a pre-pass as a pricer invocation'
  T 'CLEAN TWIN an OLD log where NO line carries `by` keeps every line - filtering a historical log
        would report a real run as having made no invocations at all' `
    ((@(Select-JudgeInvocations @((Inv 'b1' @('a')), (Inv 'b2' @('b')), (Inv 'b3' @('c'))) 'pricer')).Count -eq 3) `
    'filtered a historical log into silence'
  T 'CLEAN TWIN a MIXED-era log keeps its unattributed lines alongside the judged stage' `
    ((@(Select-JudgeInvocations @((Inv 'old' @('a')), (ByInv 'price' 'b' @('b') 'pricer'),
                                  (ByInv 'price' 'c' @('c') 'pre-pass')) 'pricer')).Count -eq 2) `
    'dropped an unattributed line that predates the field'

  # ---- FIXTURE 4. THE PER-RECIPE FINGERPRINT, independent of any threshold. Every invocation confined to
  # a single recipe while several recipes were waiting is the defect itself, not a symptom of it.
  $owners = @{ 'mascarpone' = @('chicken-florentine'); 'kewpie mayo' = @('loco-moco')
               'mango chutney' = @('country-captain-chicken'); 'shaoxing wine' = @('pork-lo-mein')
               'oyster sauce' = @('chinese-beef-and-broccoli'); 'sun dried tomato' = @('marry-me-chicken')
               'pepperoncini' = @('mississippi-pot-roast')
               'creme fraiche' = @('chicken-fricassee'); 'tarragon' = @('chicken-fricassee') }
  $s1 = Get-PerRecipeSignature $perRecipe $owners
  T 'MUST FIRE  every invocation confined to one recipe, across 8 recipes' $s1.fires ("fires=" + $s1.fires)
  T '   and it counts the recipes it saw' ($s1.recipes_touched -eq 8) $s1.recipes_touched
  $s2 = Get-PerRecipeSignature $batched $owners
  T 'CLEAN TWIN one batch spanning 8 recipes is the shape the lane is for' `
    ((-not $s2.fires) -and $s2.crossed_invocations -eq 1) ("fires=" + $s2.fires + " crossed=" + $s2.crossed_invocations)
  # never convict on evidence with an innocent reading: two recipes CAN arrive far enough apart to drain
  # separately, so two is reported and not ruled on.
  $s3 = Get-PerRecipeSignature @((Inv 'r1' @('harissa')), (Inv 'r2' @('gochujang'))) @{ 'harissa' = @('a'); 'gochujang' = @('b') }
  T 'CLEAN TWIN two single-recipe invocations are flagged as suspect, never as a finding' `
    ((-not $s3.fires) -and $s3.suspect) ("fires=" + $s3.fires + " suspect=" + $s3.suspect)
  # an unattributable invocation is not evidence FOR the defect
  T 'terms with no known owner do not convict anyone' `
    (-not (Get-PerRecipeSignature $perRecipe @{}).fires) 'convicted on no evidence'

  # ---- FIXTURE 5. THE MAP LANE, same idea at S4's size of 5. Driving the mapper one recipe at a time
  # pays its per-invocation overhead nine times for work that fits in two micro-batches.
  function MInv($label, $itemList) { return [pscustomobject]@{ lane = 'map'; label = $label; items = @($itemList); count = @($itemList).Count } }
  $mapPerRecipe = @(1..9 | ForEach-Object { MInv "recipe-$_" @("slug-$_") })
  $m1 = Get-BatchShape $mapPerRecipe 5
  T 'MUST FIRE  9 mapper invocations for 9 recipes is a per-recipe map lane' $m1.fires ("fires=" + $m1.fires)
  T '   and ceil(9/5) = 2 micro-batches would have done it' ($m1.floor -eq 2) $m1.floor
  $mapBatched = @((MInv 'micro-batch 1' @('slug-1', 'slug-2', 'slug-3', 'slug-4', 'slug-5')),
                  (MInv 'micro-batch 2' @('slug-6', 'slug-7', 'slug-8', 'slug-9')))
  T 'CLEAN TWIN two micro-batches of 5 and 4 are clean' (-not (Get-BatchShape $mapBatched 5).fires) 'fired on correct micro-batching'

  # ---- FIXTURE 6. VOCABULARY DRIFT. hunt-run refuses an unknown lane on the write side; if the two lists
  # ever part company, an unjudged lane must be a FINDING here and not a silent skip. An unwatched lane is
  # how the founding bug lived through a whole run in the first place.
  T 'MUST FIRE  a lane this audit does not know is not silently skipped' `
    (@($script:LANE_KNOWN) -notcontains 'pricer') 'accepted an unknown lane'
  T 'CLEAN TWIN both shape-judged lanes carry the plan numbers (price 10 = 2.4, map 5 = S4)' `
    ($script:LANE_BATCH['price'] -eq 10 -and $script:LANE_BATCH['map'] -eq 5) 'plan numbers drifted'

  # ---- FIXTURE 7. END TO END over a real run dir, because the pure predicates cannot catch a reader that
  # mis-parses the file. Two temp runs, identical except for the lane log.
  function New-ProbeRun {
    param([string]$Root, $LaneLines)
    New-Item -ItemType Directory -Force (Join-Path $Root 'state') | Out-Null
    $enc = New-Object System.Text.UTF8Encoding($false)
    $i = 0
    foreach ($slug in @('a', 'b', 'c')) {
      $i++
      $e = [pscustomobject]@{ slug = $slug; state = 'priced'; terms = @([pscustomobject]@{ term = "term-$i"; optional = $false })
                              history = @([pscustomobject]@{ state = 'pricing'; at = '2026-08-15T09:00:00'; by = 'mapper'; detail = '' },
                                          [pscustomobject]@{ state = 'priced';  at = '2026-08-15T10:00:00'; by = 'derive'; detail = '' }) }
      [IO.File]::WriteAllText((Join-Path $Root ("state\$slug.json")), ($e | ConvertTo-Json -Depth 8), $enc)
    }
    if ($null -ne $LaneLines) {
      [IO.File]::WriteAllText((Join-Path $Root 'lane-log.jsonl'), ((@($LaneLines) -join "`r`n") + "`r`n"), $enc)
    }
  }
  $tmpRoot = Join-Path $env:TEMP ('laneshape-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    $dirty = Join-Path $tmpRoot 'dirty'; $clean = Join-Path $tmpRoot 'clean'; $silent = Join-Path $tmpRoot 'silent'
    New-ProbeRun $dirty @(
      '{"at":"2026-08-15T09:10:00","lane":"price","label":"a","count":1,"items":["term-1"]}',
      '{"at":"2026-08-15T09:20:00","lane":"price","label":"b","count":1,"items":["term-2"]}',
      '{"at":"2026-08-15T09:30:00","lane":"price","label":"c","count":1,"items":["term-3"]}')
    New-ProbeRun $clean @('{"at":"2026-08-15T09:10:00","lane":"price","label":"batch 1","count":3,"items":["term-1","term-2","term-3"]}')
    New-ProbeRun $silent $null

    $me = $PSCommandPath
    function RunProbe($dir) {
      $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $me -RunDir $dir -Json 2>&1
      $txt = (@($o | ForEach-Object { [string]$_ }) -join "`n")
      return [pscustomobject]@{ code = $LASTEXITCODE; text = $txt }
    }
    $rd = RunProbe $dirty
    T 'MUST FIRE  end to end, a per-recipe price lane in a real run dir exits 1' ($rd.code -eq 1) ("exit " + $rd.code + " :: " + $rd.text)
    T '   and it names the lane in its findings' ($rd.text -match 'price-lane-not-batched') $rd.text
    $rc = RunProbe $clean
    T 'CLEAN TWIN end to end, the batched twin exits 0' ($rc.code -eq 0) ("exit " + $rc.code + " :: " + $rc.text)
    # THE NON-COMPLIANCE CATCH. An orchestrator that simply never records its lanes must not pass: a run
    # that priced and left no lane log is a run whose shape cannot be audited, and could-not-look is never
    # a clean bill. Without this case the whole check is opt-in, which is the same as documentation.
    $rs = RunProbe $silent
    T 'MUST FIRE  a run that priced but logged no lane invocation is a finding, not a pass' ($rs.code -eq 1) ("exit " + $rs.code + " :: " + $rs.text)
    T '   and it says so by name' ($rs.text -match 'price-lane-unlogged') $rs.text
    T 'the guard-contract marker is present on every one of those runs' `
      ((Test-GuardComplete ($rd.text -split "`n") 'lane-shape') -and (Test-GuardComplete ($rc.text -split "`n") 'lane-shape')) 'missing LANE-SHAPE-COMPLETE'
  } finally { Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }

  if ($f -eq 0) { Write-Output 'audit-lane-shape SELF-TEST PASS'; exit 0 }
  Write-Output ("audit-lane-shape SELF-TEST FAIL: {0} case(s)" -f $f); exit 1
}

# ===================================================================================================
# LIVE
# ===================================================================================================
if (-not $RunDir) { Write-Output 'audit-lane-shape: -RunDir is required'; exit 2 }
if (-not (Test-Path $RunDir)) { Write-Output ("audit-lane-shape: no such run dir '{0}'" -f $RunDir); exit 2 }
if (-not $QueueScript) { $QueueScript = Join-Path $repo 'grocery\ingredient-queue.ps1' }

$log = @(Read-LaneLog (Join-Path $RunDir 'lane-log.jsonl'))
$entries = @(Read-StateEntries $RunDir)
$owners = Get-TermOwners $entries
$everPriced = @($entries | Where-Object { Test-EverPriced $_ })

$findings = @(); $warnings = @(); $lanes = @()

# The lane vocabulary must not have drifted apart from hunt-run's write side.
$seenLanes = @(@($log | ForEach-Object { [string]$_.lane }) | Where-Object { $_ } | Sort-Object -Unique)
foreach ($l in $seenLanes) {
  if (@($script:LANE_KNOWN) -notcontains $l) {
    $findings += [pscustomobject]@{ code = 'unknown-lane'; lane = $l
      detail = ("the lane log records lane '{0}', which this audit does not know how to judge. Either hunt-run.ps1 and this script have drifted apart, or a stage is filing its invocations where nothing looks." -f $l) }
  }
}

foreach ($l in @($script:LANE_BATCH.Keys | Sort-Object)) {
  $size = [int]$script:LANE_BATCH[$l]
  $inv = @(Get-Invocations @($log | Where-Object { [string]$_.lane -eq $l }))
  $inv = @(Select-JudgeInvocations $inv ([string]$script:LANE_JUDGE[$l]))
  $shape = Get-BatchShape $inv $size
  $sig = if ($l -eq 'price') { Get-PerRecipeSignature $inv $owners } else { $null }
  $lanes += [pscustomobject]@{ lane = $l; shape = $shape; signature = $sig }

  if ($shape.fires) {
    $findings += [pscustomobject]@{ code = ("{0}-lane-not-batched" -f $l); lane = $l
      detail = ("{0} invocation(s) for {1} distinct item(s) at batch size {2}. {3} would have done it, and each invocation carried {4} on average. The {5} lane is a batch drainer, not a per-recipe stage." -f
                $shape.invocations, $shape.distinct, $size, $shape.floor, $shape.mean_per_invocation, $l) }
  }
  if (@($shape.repeated).Count) {
    $findings += [pscustomobject]@{ code = ("{0}-lane-duplicate-items" -f $l); lane = $l
      detail = ("{0} item(s) went to the {1} lane more than once: {2}. ingredient-queue.ps1 is keyed by TERM so a shared ingredient is priced ONCE; a repeat means the cross-recipe dedup was discarded." -f
                @($shape.repeated).Count, $l, (@($shape.repeated) -join ', ')) }
  }
  if ($sig -and $sig.fires) {
    $findings += [pscustomobject]@{ code = 'price-lane-per-recipe'; lane = $l
      detail = ("every attributable pricer invocation stayed inside a single recipe, across {0} recipes. The singleton lane batches terms ACROSS recipes; this is a per-recipe pipeline stage wearing the lane's name." -f $sig.recipes_touched) }
  }
  elseif ($sig -and $sig.suspect) {
    $warnings += [pscustomobject]@{ code = 'price-lane-per-recipe-suspect'; lane = $l
      detail = ("each pricer invocation covered one recipe, but only {0} recipes were involved - which two recipes arriving far enough apart would also look like. Not ruled on." -f $sig.recipes_touched) }
  }
}

# THE NON-COMPLIANCE CATCH. An orchestrator that never calls -Lane must not pass by leaving no evidence.
$priceInv = @(Select-JudgeInvocations `
    @(Get-Invocations @($log | Where-Object { [string]$_.lane -eq 'price' })) 'pricer')
if ($everPriced.Count -and -not $priceInv.Count) {
  $findings += [pscustomobject]@{ code = 'price-lane-unlogged'; lane = 'price'
    detail = ("{0} recipe(s) went through the pricing state and the lane log records ZERO pricer invocations. The run's lane shape cannot be audited at all, and could-not-look is never a clean bill. Record each invocation with hunt-run.ps1 -Lane -LaneName price -Items '<terms>'." -f $everPriced.Count) }
}
elseif ($priceInv.Count) {
  # a partial log: terms this run sent to pricing that no invocation claims. Reported, not ruled on - the
  # queue answers across runs, so a term can legitimately have been priced before this run started.
  $logged = @{}
  foreach ($i in $priceInv) { foreach ($t in @($i.items)) { $logged[[string]$t] = $true } }
  $missing = @(@($owners.Keys) | Where-Object { -not $logged.ContainsKey($_) } | Sort-Object)
  if ($missing.Count) {
    $warnings += [pscustomobject]@{ code = 'price-lane-partial-log'; lane = 'price'
      detail = ("{0} blocking term(s) belong to this run's recipes but appear in no pricer invocation: {1}. Either they resolved from the board or an earlier run, or the lane log is incomplete." -f
                $missing.Count, (@($missing | Select-Object -First 12) -join ', ')) }
  }
}
$mapped = @($entries | Where-Object { @($_.history | ForEach-Object { [string]$_.state }) -contains 'mapped' })
$mapInv = @(Select-JudgeInvocations `
    @(Get-Invocations @($log | Where-Object { [string]$_.lane -eq 'map' })) 'mapper')
if ($mapped.Count -and -not $mapInv.Count) {
  $warnings += [pscustomobject]@{ code = 'map-lane-unlogged'; lane = 'map'
    detail = ("{0} recipe(s) were mapped and the lane log records no mapper invocation, so the S4 micro-batch shape cannot be judged." -f $mapped.Count) }
}

if ($runJson) {
  ([pscustomobject]@{
    run = (Split-Path $RunDir -Leaf); invocations = (Get-InvocationCount $log); recipes = $entries.Count
    lanes = @($lanes); findings = @($findings); warnings = @($warnings)
  } | ConvertTo-Json -Depth 10)
  Write-GuardComplete -Name 'lane-shape' -Summary ("findings={0} warnings={1}" -f $findings.Count, $warnings.Count)
  exit $(if ($findings.Count) { 1 } else { 0 })
}

Write-Output ("audit-lane-shape: {0}   {1} lane invocation(s) over {2} recipe(s)" -f (Split-Path $RunDir -Leaf), (Get-InvocationCount $log), $entries.Count)
Write-Output ''
foreach ($x in $lanes) {
  $s = $x.shape
  Write-Output ("  {0,-6} {1,3} {6} invocation(s)   {2,3} distinct item(s)   floor ceil({2}/{3}) = {4}   mean {5}/invocation" -f
                $x.lane, $s.invocations, $s.distinct, $s.batch_size, $s.floor, $s.mean_per_invocation,
                [string]$script:LANE_JUDGE[[string]$x.lane])
}
foreach ($l in @($seenLanes | Where-Object { -not $script:LANE_BATCH.ContainsKey($_) })) {
  Write-Output ("  {0,-6} {1,3} invocation(s)   (no batch size declared in the plan - counted, not judged)" -f
                $l, (Get-InvocationCount $log $l))
}
Write-Output ''
if ($findings.Count) {
  Write-Output ("  FINDINGS  {0}" -f $findings.Count)
  foreach ($x in $findings) { Write-Output ("    [{0}] {1}" -f $x.code, $x.detail) }
  Write-Output ''
}
if ($warnings.Count) {
  Write-Output ("  NOTES     {0}" -f $warnings.Count)
  foreach ($x in $warnings) { Write-Output ("    [{0}] {1}" -f $x.code, $x.detail) }
  Write-Output ''
}
if (-not $findings.Count) { Write-Output '  lane shape matches the design.' }
Write-GuardComplete -Name 'lane-shape' -Summary ("findings={0} warnings={1}" -f $findings.Count, $warnings.Count)
exit $(if ($findings.Count) { 1 } else { 0 })
