<#
  validate-triage-plan.ps1 - the HANDOFF GATE between the Triage Reviewer and the Triage Developer.

  WHY THIS EXISTS (2026-07-31): the gate used to be the orchestrator eyeballing the plan, with an ad-hoc
  check script living in a scratch directory. An unversioned check nobody can re-run is not a gate - it is
  a habit, and this estate has paid for that difference more than once. The expensive stage should only
  ever start on a plan that provably carries what the developer needs.

  WHAT IT ENFORCES, and why each rule is here rather than in a prompt:
    * every OPEN queue id appears exactly once            - an alert nobody planned for is an alert nobody
                                                            triages, and the developer cannot notice a gap
                                                            it was never told about
    * evidence rows on every item                         - a classification with no quoted row is not
                                                            reviewable
    * a root cause on every item                          - the whole point of the reviewer stage
    * blast radius MEASURED AS ROUTING on code items      - the recurring error of 2026-07-31: twice in one
                                                            day, by two different agents, a rule's impact
                                                            was measured by counting NAME MATCHES instead
                                                            of post-rule ROUTING. First-match-wins means a
                                                            token can match a name and still change nothing
                                                            (something upstream already claims it), so a
                                                            match count both over- and under-predicts
    * claimed_by_earlier on any widened include           - the same lesson from the other side: an include
                                                            that cannot be reached because a lower-index
                                                            commodity claims the name
    * a named proof + rollback on code items              - a fix whose test cannot reach it is how two
                                                            same-day fixes regressed on 2026-07-29
    * a resolution note on EVERY item                     - including no-code-change ones; silence is not a
                                                            resolution
    * freshness on code items                             - what the measurement was taken against, so a
                                                            board that moved underneath becomes a checked
                                                            branch instead of a judgment call
    * the routing artifact exists when one is referenced  - the developer verifies against it instead of
                                                            re-deriving 26,000 names
    * leaves_open on every code item                      - what the root_fix does NOT close, or 'nothing'.
                                                            A gate can see that a root_fix exists, not that
                                                            it covers its root_cause: four partial class
                                                            fixes passed clean on 2026-09-09 because nothing
                                                            asked (the LEAVES_OPEN block below)
    * -Closing: every item has an outcome, and every      - a residual owned by nobody is the to-Brad list
                                                            of discovered defects ruled out on 2026-09-07

  Exit codes:  0 = plan is complete and may be handed over
               2 = plan is incomplete (message says exactly what is missing)
               3 = BLIND: no plan file, unreadable, or zero items - proved nothing, do not hand over
  -Closing re-reads the plan AFTER the developer, against grocery\triage-queue.json (or -QueueFile), with
  the same exit codes. Run it before a triage run reports itself done.
  -SelfTest runs frozen good/bad fixtures through the rules and exits (0 pass, 1 fail).
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param(
  [string]$Plan = "",
  [string[]]$OpenIds = @(),
  [switch]$SelfTest,
  [switch]$Closing,
  [string]$QueueFile = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# A [string[]] PARAM DOES NOT SURVIVE `powershell -File` (2026-08-01). Called as
# `-OpenIds 'a','b','c'` through -File, all three arrive as ONE comma-joined string, so the gate compared
# the plan against a single id that matches nothing and reported the whole plan missing - on a plan that
# was actually complete. That is the THIRD instance of this shape in two days (send-alert's -Body, the
# post-processor's -Raw), and the other two also produced a confident wrong answer rather than an error.
# A gate that can be defeated by the caller's quoting is not a gate, so normalise here instead of trusting
# every future caller to use -Command with a real array.
$OpenIds = @($OpenIds | Where-Object { $_ } | ForEach-Object { ([string]$_) -split '[,;]' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# classifications that legitimately carry no code change, so no blast radius / proof / rollback is demanded
$NO_CODE = @('no-code-change','needs-brad','superseded','needs-more-time')

# Does this item change how PRODUCTS ROUTE to commodities? That is the family whose impact can only be
# stated as routing outcomes: the rule files themselves, plus any wrong-product fix (which is a rule change
# by definition). An importer fix, a scheduled task, a logging path and a registry entry are not.
function Test-TouchesMatchingRule($Item) {
  if ([string]$Item.classification -eq 'wrong-product') { return $true }
  $files = @()
  foreach ($f in @($Item.surface_fix, $Item.root_fix)) {
    if (-not $f) { continue }
    $files += @($f.files)
    $files += [string]$f.exact_change
    $files += [string]$f.what
  }
  return (($files -join ' ') -match 'commodities\.json|category-excludes|price-bands|commodity-search')
}

function Test-Plan {
  param($Doc, [string[]]$Expect, [string]$PlanDir, [switch]$Closing, $QueueIds = @())
  # -Closing resolves a residual's owner against these. A ruling is owned by its id in open_questions_for_brad;
  # an older plan wrote those as bare strings, which carry no id and so can own nothing.
  $ruleIds = @()
  foreach ($qb in @($Doc.open_questions_for_brad)) { if ($qb -and -not ($qb -is [string]) -and [string]$qb.id) { $ruleIds += [string]$qb.id } }
  $END_STATES = @('done','deviated','blocked','bounced','superseded','needs-more-time','needs-brad')
  $problems = New-Object System.Collections.Generic.List[string]
  $items = @($Doc.items)
  if ($items.Count -eq 0) { return @{ rc = 3; problems = @('plan carries ZERO items - it proved nothing') } }

  $ids = @($items | ForEach-Object { [string]$_.queue_id })
  foreach ($e in @($Expect)) {
    if ($ids -notcontains $e) { $problems.Add("open queue id $e has NO item in the plan") }
  }
  foreach ($g in ($ids | Group-Object | Where-Object { $_.Count -gt 1 })) {
    $problems.Add("queue id $($g.Name) appears $($g.Count) times - one item per id")
  }
  if (@($Expect).Count) {
    foreach ($e in @($Expect)) { if (@($Doc.queue_ids_seen) -notcontains $e) { $problems.Add("queue_ids_seen is missing $e") } }
  }
  if (-not @($Doc.ship_sequence).Count) { $problems.Add('ship_sequence is empty - the developer needs the order') }

  foreach ($i in $items) {
    $id  = [string]$i.queue_id
    $cls = [string]$i.classification
    if (-not $cls) { $problems.Add("$id has no classification") }
    if (-not @($i.evidence).Count) { $problems.Add("$id has no evidence rows") }
    if (-not [string]$i.root_cause) { $problems.Add("$id has no root_cause") }
    if (-not [string]$i.resolution_note) { $problems.Add("$id has no resolution_note") }
    # -Closing: README rule 4, every item ends in an outcome. An item still 'planned' after the developer is
    # an item nobody finished, and until now the only thing that could notice was the orchestrator reading.
    if ($Closing -and ($END_STATES -notcontains [string]$i.status)) {
      $st0 = if ([string]$i.status) { [string]$i.status } else { 'no status' }
      $problems.Add("$id is still '$st0' at close - every item ends done, deviated, blocked, bounced, superseded, needs-more-time or needs-brad")
    }
    if ($NO_CODE -contains $cls) { continue }

    # --- code-changing items carry the anti-regression apparatus ---
    # WHICH KIND OF MEASUREMENT, THOUGH. "measured_as: routing" is the right demand for a change to a
    # MATCHING RULE, where the only honest impact statement is where products end up after
    # first-match-wins. It is meaningless for the other half of a real plan: measured on the actual
    # 2026-07-31 plan, 5 of 7 code items were infra (a logging path, a scheduled task's cadence, an
    # importer, a stores.json entry, a browser pass) where there is no routing to measure. Demanding
    # 'routing' there would force the reviewer to write a nonsense value or fail the gate - and a
    # twice-failed gate costs a whole day of triage. So: every code item still needs a MEASURED blast
    # radius, and the rule-changing ones specifically need it measured as routing.
    $br = $i.blast_radius
    if (-not $br) { $problems.Add("$id changes code but has no blast_radius") }
    else {
      if ($null -eq $br.affected_now) { $problems.Add("$id blast_radius has no affected_now count") }
      if (-not [string]$br.measured_by) { $problems.Add("$id blast_radius has no measured_by (what corpus or call sites were scanned)") }
      $ma = [string]$br.measured_as
      if (-not $ma) {
        $problems.Add("$id blast_radius has no measured_as - say what was counted (routing for a matching rule; callers / rows / cells / schedule for the rest)")
      }
      elseif ((Test-TouchesMatchingRule $i) -and $ma -ne 'routing') {
        $problems.Add("$id changes a MATCHING RULE but measured_as is '$ma' - it must be 'routing' (post-rule routing outcomes, never name/token matches; see the 2026-07-31 lesson that cost two rounds)")
      }
    }
    if (-not ($i.proof -and [string]$i.proof.guard_or_fixture)) { $problems.Add("$id has no proof.guard_or_fixture") }
    if (-not [string]$i.rollback) { $problems.Add("$id has no rollback") }
    if (-not [string]$i.freshness) { $problems.Add("$id has no freshness (what the measurement was taken against)") }

    # --- A ROOT CAUSE MUST BECOME A ROOT FIX (2026-09-03, Brad's ruling on the triage process) --------
    # root_cause has been demanded since this gate existed, but NOTHING ever checked that the plan acted
    # on it. An item could name the class one level up, ship only the instance fix, and pass clean - which
    # is exactly how a defect returns wearing a different commodity. The README already said root_fix may
    # be null "ONLY when surface_fix IS the root fix, and say so"; that was a convention nobody could
    # enforce. Now it is either a root_fix or an explicit sentence saying why none is needed.
    $hasRootFix = ($i.root_fix -and ([string]$i.root_fix.what))
    if (-not $hasRootFix -and -not [string]$i.root_fix_none_because) {
      $problems.Add("$id names a root_cause but carries no root_fix and no root_fix_none_because - say what stops the CLASS recurring, or say in one line why the surface fix already is that")
    }
    # --- A ROOT FIX SAYS WHAT IT LEAVES OPEN (2026-09-10, Brad: fix it so it never happens again) --------
    # The block above sees that a root_fix EXISTS. It cannot see whether it covers the root_cause beside it,
    # and on 2026-09-09 four items passed clean covering a slice: a95022's root_cause named any session's
    # edit to any tracked entry under out\ and its fix made the refusal legible without making it stop;
    # d3e937's named every scheduled task and repeated one of eight; 9b1f92 blocklisted one row of an
    # ad-line shape that 40 of that week's 146 Baker's rows match; 34557a's marker was scoped away from the
    # guard -SelfTest blocks where the next fixture turned up within the hour. Every residual was written
    # down, in a root_cause or a deviation, and nothing READ it, so each became a sentence for Brad instead
    # of work. A gate cannot judge coverage. It can refuse silence about it, so the item says what is left
    # in its own words, and 'nothing' is a claim with a name on it. root_fix_none_because is a coverage
    # claim too, so it does not exempt the statement.
    $lo = ([string]$i.leaves_open).Trim()
    if (-not $lo) {
      $problems.Add("$id has no leaves_open - say what part of the root_cause this fix does NOT close, with the count, or write 'nothing' (2026-09-09: four partial class fixes passed this gate because nothing asked)")
    }
    # -Closing: AN OPEN RESIDUAL HAS AN OWNER THAT RESOLVES. The reviewer is read-only and cannot mint a queue
    # item, so at handoff an honest residual is enough. By close the developer has had every tool, and a
    # residual owned by nobody is the list of discovered defects Brad ruled out on 2026-09-07. The id must
    # RESOLVE, because a plausible id nobody can find owns the work the way an unread stamp checks it.
    if ($Closing -and $lo -and ($lo -notmatch '^nothing\b') -and (@('done','deviated') -contains [string]$i.status)) {
      $fu = ([string]$i.leaves_open_followup).Trim()
      if (-not $fu) {
        $problems.Add("$id is $([string]$i.status) with an open residual and no leaves_open_followup - enqueue it through send-alert.ps1, or file it as a ruling in open_questions_for_brad, and name that id. The residual: $lo")
      } elseif ((@($QueueIds) -notcontains $fu) -and ($ruleIds -notcontains $fu)) {
        $problems.Add("$id leaves_open_followup '$fu' resolves to nothing - it is neither an id in the triage queue nor an id in open_questions_for_brad")
      }
    }
    # --- AND THE PROOF MUST REPRODUCE THE BUG --------------------------------------------------------
    # Naming a harness is not a proof. A fixture that does not FIRE on the founding bug is decorative (the
    # estate has found five structurally dead guards in a single sweep), and a must-fire with no clean twin
    # passes by being too broad - which is how a fix "works" by flagging everything. Both halves are the
    # standing guard-fixture rule here; the gate demands them instead of trusting anyone to remember.
    if ($i.proof -and -not [string]$i.proof.must_fire_case) { $problems.Add("$id proof names a harness but no must_fire_case - a fixture that cannot reproduce the founding bug proves nothing") }
    if ($i.proof -and -not [string]$i.proof.clean_twin)     { $problems.Add("$id proof has no clean_twin - a must-fire case with no twin passes by being too broad") }

    # an item that widens an include must say who currently claims each admitted name
    $widens = $false
    foreach ($f in @($i.surface_fix, $i.root_fix)) {
      if ($f -and (([string]$f.exact_change) -imatch 'include' -or ([string]$f.what) -imatch 'include')) { $widens = $true }
    }
    if ($widens -and ($null -eq $i.claimed_by_earlier)) {
      $problems.Add("$id widens an include but has no claimed_by_earlier - first-match-wins can block the admit entirely (2026-07-31 taco-sauce/hot-sauce)")
    }

    # --- CELL EFFECTS: routing is itself a proxy, and this estate has now been bitten at every layer -------
    # 2026-07-31 round 1 measured each commodity's CROWN when it should have measured each product's ROUTING.
    # The fix was to mandate measured_as: 'routing'. On 2026-08-06 that mandate was satisfied in full and a
    # cell still moved 87% the wrong way, because routing answers "which commodity does this name land in"
    # and says NOTHING about which row survives capture selection afterwards. Admitting ONE goat-milk formula
    # to baby-formula made a 1-row Sam's capture "cover" the commodity, which discarded the 20-row capture
    # behind it, and the live cell went $0.7704/oz -> $1.4445/oz. Every existing guard read clean: both rows
    # real, both prices real, the crown unmoved. THE OUTCOME IS THE CELL, NOT THE ROUTE. So a rule change now
    # has to state what happened to the PRICES, per store, or it is unmeasured no matter how good the routing
    # section looks. An empty array is a legitimate and checkable claim: "no cell moved".
    if (Test-TouchesMatchingRule $i) {
      $ce = $null; if ($br) { $ce = $br.cell_effects }
      if ($null -eq $ce) {
        $problems.Add("$id changes a MATCHING RULE but blast_radius has no cell_effects - routing alone cannot see a capture-selection eviction (2026-08-06 Sam's baby-formula, +87% with every guard green). List each commodity+store whose per-unit price moves, before and after; an empty array means 'no cell moved' and is a fine answer if it is true")
      } else {
        $n = 0
        foreach ($c in @($ce)) {
          $n++
          if (-not [string]$c.commodity) { $problems.Add("$id cell_effects[$n] has no commodity") }
          if (-not [string]$c.store) { $problems.Add("$id cell_effects[$n] has no store") }
          if ($null -eq $c.before) { $problems.Add("$id cell_effects[$n] has no before price") }
          if ($null -eq $c.after) { $problems.Add("$id cell_effects[$n] has no after price") }
        }
      }
    }
  }

  # the routing artifact, when the plan names one, has to be on disk
  $art = [string]$Doc.routing_artifact
  if ($art) {
    $p = if ([IO.Path]::IsPathRooted($art)) { $art } else { Join-Path $PlanDir $art }
    if (-not (Test-Path $p)) { $problems.Add("routing_artifact '$art' is named but not on disk at $p") }
    else {
      # POSITIVE CONTROL. A before/after simulation that returns ZERO changes is indistinguishable from a
      # simulation that never ran, and zero is the answer that ENDS an investigation ("this rule is a no-op,
      # drop it"). On 2026-08-06 the reviewer lost two full 26,013-name simulations to exactly that: PowerShell
      # variable names are case-insensitive, so `$b = Route $B $rules` destroyed the ruleset it was routing
      # against, and both runs reported a confident zero. Nothing in the artifact could have revealed it.
      # So the artifact must name a control - a row it KNOWS must move - and record that it actually moved.
      $doc2 = $null
      try { $raw2 = Read-TextFile $p; if ($raw2 -and $raw2.Trim()) { $doc2 = $raw2 | ConvertFrom-Json } } catch { $doc2 = $null }
      if (-not $doc2) { $problems.Add("routing_artifact '$art' is on disk but reads back empty or unparseable") }
      elseif ($null -eq $doc2.positive_control) {
        $problems.Add("routing_artifact '$art' has no positive_control - name one row the simulation MUST reclassify and record that it did, so a zero-change result cannot be a broken harness reporting success (2026-08-06 case-insensitive `$b/`$B)")
      } else {
        $pc = $doc2.positive_control
        if (-not [string]$pc.name) { $problems.Add("routing_artifact positive_control has no name (which row was used as the control)") }
        if (-not [string]$pc.expected) { $problems.Add("routing_artifact positive_control has no expected (what it must reclassify to)") }
        if ($pc.observed -ne $pc.expected) {
          $problems.Add("routing_artifact positive_control did NOT reproduce: expected '$([string]$pc.expected)' but observed '$([string]$pc.observed)' - the simulation behind this plan is not trustworthy")
        }
      }
    }
  }

  if ($problems.Count) { return @{ rc = 2; problems = $problems } }
  return @{ rc = 0; problems = @() }
}

if ($SelfTest) {
  $fail = 0
  # COUNTED, NEVER TYPED. This summary used to carry a literal "17" that four new cases silently made
  # wrong - the same shape as any hardcoded inventory count, and a self-test whose own summary is stale
  # is a bad advertisement for a gate that exists to catch exactly that.
  $ran = 0
  function _Case($label, $doc, $expectRc, $expectMatch) {
    $script:ran++
    $r = Test-Plan $doc @('q1') $env:TEMP
    $txt = ($r.problems -join ' | ')
    if ($r.rc -eq $expectRc -and ((-not $expectMatch) -or ($txt -match $expectMatch))) { Write-Output "ok    $label" }
    else { Write-Output ("FAIL  $label  rc=" + $r.rc + " want $expectRc; problems: " + $txt); $script:fail++ }
  }
  # a COMPLETE plan (the clean twin) - one code item with the full apparatus
  $good = [pscustomobject]@{
    queue_ids_seen = @('q1'); ship_sequence = @('step 1')
    items = @([pscustomobject]@{
      queue_id='q1'; classification='wrong-product'; evidence=@('lemons | Sam''s | soda row'); root_cause='library cannot express the class'
      blast_radius=[pscustomobject]@{ measured_as='routing'; measured_by='25,939 names'; affected_now=2
        cell_effects=@([pscustomobject]@{ commodity='lemons'; store="Sam's Club"; before=0.5413; after=0.4200 }) }
      proof=[pscustomobject]@{ guard_or_fixture='test-auditors case d2'; must_fire_case='the frozen soda row on lemons makes audit-food-category exit 2'; clean_twin="'Fresh Lemon' keeps it at exit 0" }; rollback='revert the hunk'
      freshness='measured against comparison-2026-07-30'; resolution_note='fixed'; leaves_open='nothing'
      surface_fix=[pscustomobject]@{ what='exclude the soda'; exact_change='lemons.exclude += ...' }
      root_fix=[pscustomobject]@{ what='add the beverage tokens to the food-class library so the guard hard-fails the class estate-wide'; exact_change='category-excludes.json beverage += ...'; files=@('grocery/category-excludes.json') }
    })
  }
  _Case 'complete plan passes' $good 0 $null
  # MUST-FIRE 1: the recurring 2026-07-31 error - a MATCHING RULE whose impact is counted as name matches
  $m = $good | ConvertTo-Json -Depth 9 | ConvertFrom-Json; $m.items[0].blast_radius.measured_as = 'token-matches'
  _Case 'a matching-rule change measured as token-matches is rejected' $m 2 "must be 'routing'"
  # CLEAN TWIN: an INFRA item measured honestly by its own units passes. Demanding 'routing' of a logging
  # fix or a scheduled task would force a nonsense value, and a twice-failed gate costs a day of triage.
  $infra = [pscustomobject]@{ queue_ids_seen=@('q1'); ship_sequence=@('x'); items=@([pscustomobject]@{
      queue_id='q1'; classification='infra'; evidence=@('check-ad-cycles logged: cost-flag alert threw'); root_cause='[string]$null is $null so .Trim() throws on a zero-byte file'
      blast_radius=[pscustomobject]@{ measured_as='callers'; measured_by='grep of all live .ps1 for the idiom'; affected_now=11 }
      proof=[pscustomobject]@{ guard_or_fixture='test-guards case 0'; must_fire_case='a zero-byte cost-flag file makes the old idiom throw in the harness'; clean_twin='a populated file still parses and alerts normally' }; rollback='revert the hunks'
      freshness='measured against the working tree at 2026-07-31T07:00'; resolution_note='fixed'; leaves_open='nothing'
      surface_fix=[pscustomobject]@{ what='use the null-safe idiom'; exact_change='((Get-Content $f -Raw) + $emptyString).Trim()'; files=@('grocery/check-ad-cycles.ps1') }
      root_fix=[pscustomobject]@{ what='sweep the idiom estate-wide so no other caller can throw on an empty file'; exact_change='11 call sites moved to the null-safe form'; files=@('grocery/*.ps1') } }) }
  _Case 'an infra item measured as callers passes (routing would be meaningless)' $infra 0 $null
  # MUST-FIRE 2: but an infra item with NO measure at all is still rejected
  $noMeasure = $infra | ConvertTo-Json -Depth 9 | ConvertFrom-Json; $noMeasure.items[0].blast_radius.measured_as = ''
  _Case 'a code item with no measured_as at all is rejected' $noMeasure 2 'no measured_as'
  # MUST-FIRE 2: an include widened with no claimed_by_earlier
  $w = $good | ConvertTo-Json -Depth 9 | ConvertFrom-Json; $w.items[0].surface_fix.exact_change = 'taco-sauce.include += taco bell sauce'
  _Case 'widened include without claimed_by_earlier is rejected' $w 2 'claimed_by_earlier'
  # MUST-FIRE 3: an open alert with no item at all
  $n = $good | ConvertTo-Json -Depth 9 | ConvertFrom-Json; $n.items[0].queue_id = 'other'
  _Case 'missing open queue id is rejected' $n 2 'has NO item in the plan'
  # MUST-FIRE 4: a no-code item with no resolution note (silence is not a resolution)
  $s = $good | ConvertTo-Json -Depth 9 | ConvertFrom-Json; $s.items[0].classification = 'no-code-change'; $s.items[0].resolution_note = ''
  _Case 'no-code item without a resolution_note is rejected' $s 2 'no resolution_note'
  # CLEAN TWIN: a no-code item WITH a note needs no blast radius, proof or rollback
  $ok2 = [pscustomobject]@{ queue_ids_seen=@('q1'); ship_sequence=@('x'); items=@([pscustomobject]@{
      queue_id='q1'; classification='no-code-change'; evidence=@('Hy-Vee 17 chips'); root_cause='browser store drift'; resolution_note='waits for the Wednesday agent' }) }
  _Case 'no-code item needs no blast radius/proof/rollback' $ok2 0 $null

  # MUST-FIRE 5 (2026-08-06): a MATCHING RULE change with a perfect routing section and NO cell_effects.
  # This is the founding case for the check: the 08-06 plan passed this gate with measured_as='routing' on
  # every rule item, and a Sam's cell still moved +87% because routing cannot see capture selection.
  $noCells = $good | ConvertTo-Json -Depth 9 | ConvertFrom-Json
  $noCells.items[0].blast_radius.PSObject.Properties.Remove('cell_effects')
  _Case 'a matching-rule change with no cell_effects is rejected' $noCells 2 'no cell_effects'
  # CLEAN TWIN: an EMPTY cell_effects array is a positive claim ("no cell moved") and must pass.
  $emptyCells = $good | ConvertTo-Json -Depth 9 | ConvertFrom-Json
  $emptyCells.items[0].blast_radius.cell_effects = @()
  _Case 'an empty cell_effects array is an answer, not an omission' $emptyCells 0 $null
  # CLEAN TWIN: the infra item does NOT touch a matching rule, so it is never asked for cell effects.
  _Case 'an infra item is not asked for cell_effects' $infra 0 $null
  # MUST-FIRE 6: a cell_effects entry missing its prices is not a measurement.
  $halfCells = $good | ConvertTo-Json -Depth 9 | ConvertFrom-Json
  $halfCells.items[0].blast_radius.cell_effects[0].PSObject.Properties.Remove('after')
  _Case 'a cell_effects entry with no after price is rejected' $halfCells 2 'no after price'

  # --- MUST-FIRE 7-9 (2026-09-03): the plan must CLOSE THE CLASS, not just the instance ---------------
  # Brad's ruling on the triage process: a review that fixes the issue without ensuring it cannot recur is
  # not finished. root_cause was already mandatory and was already being written well; what was missing is
  # that nothing checked the plan ACTED on it. These three pin the acting.
  $noRootFix = $good | ConvertTo-Json -Depth 9 | ConvertFrom-Json
  $noRootFix.items[0].PSObject.Properties.Remove('root_fix')
  _Case 'a code item that names a root_cause but ships no root_fix is rejected' $noRootFix 2 'no root_fix'
  # CLEAN TWIN: sometimes the surface fix genuinely IS the root fix. That is a legitimate answer and must
  # pass - but only when it is SAID, so a reader can tell it apart from an item that simply never asked.
  $saidSo = $good | ConvertTo-Json -Depth 9 | ConvertFrom-Json
  $saidSo.items[0].PSObject.Properties.Remove('root_fix')
  $saidSo.items[0] | Add-Member -NotePropertyName root_fix_none_because -NotePropertyValue 'the exclude IS the class fix: this token is the only way the beverage family can reach a produce commodity'
  _Case 'root_fix may be null when the plan says why the surface fix is the root fix' $saidSo 0 $null
  # MUST-FIRE 8: a proof that names a harness but cannot reproduce the founding bug is decorative. This
  # estate has found five structurally dead guards in one sweep; a named harness is not evidence.
  $noFire = $good | ConvertTo-Json -Depth 9 | ConvertFrom-Json
  $noFire.items[0].proof.PSObject.Properties.Remove('must_fire_case')
  _Case 'a proof with no must_fire_case is rejected' $noFire 2 'must_fire_case'
  # MUST-FIRE 9: a must-fire with no clean twin passes by being too broad - the fix that "works" by
  # flagging everything. Both halves of the fixture rule, or neither is worth anything.
  $noTwin = $good | ConvertTo-Json -Depth 9 | ConvertFrom-Json
  $noTwin.items[0].proof.PSObject.Properties.Remove('clean_twin')
  _Case 'a proof with no clean_twin is rejected' $noTwin 2 'clean_twin'

  # --- LEAVES_OPEN AND -Closing (2026-09-10) ---------------------------------------------------------
  # MUST FIRE: the founding shape, 2026-09-09 a95022 exactly as written. A root_fix present, a root_cause
  # naming a wider class than it covers, and no word about the difference. It passed this gate clean.
  $noLeft = $good | ConvertTo-Json -Depth 9 | ConvertFrom-Json
  $noLeft.items[0].PSObject.Properties.Remove('leaves_open')
  _Case 'a code item with a root_fix and no leaves_open is rejected' $noLeft 2 'no leaves_open'
  # MUST FIRE: root_fix_none_because is a claim about coverage too, so it does not buy an exemption.
  $saidNoLeft = $saidSo | ConvertTo-Json -Depth 9 | ConvertFrom-Json
  $saidNoLeft.items[0].PSObject.Properties.Remove('leaves_open')
  _Case 'root_fix_none_because does not exempt an item from saying what it leaves open' $saidNoLeft 2 'no leaves_open'
  # MUST NOT FIRE: an honest residual at HANDOFF needs no owner yet, because the reviewer cannot mint one.
  $honest = $good | ConvertTo-Json -Depth 9 | ConvertFrom-Json
  $honest.items[0].leaves_open = 'the same soda shape on the other 11 produce commodities'
  _Case 'a residual stated at handoff passes without an owner' $honest 0 $null
  # CLEAN TWIN: a no-code item is still never asked for leaves_open. The adjacent behaviour this change was
  # most likely to break, since the new rule sits right beside the no-code exit.
  _Case 'a no-code item still passes with no leaves_open at all' $ok2 0 $null

  function _CaseClose($label, $doc, $queue, $expectRc, $expectMatch) {
    $script:ran++
    $r = Test-Plan $doc @() $env:TEMP -Closing -QueueIds $queue
    $txt = ($r.problems -join ' | ')
    if ($r.rc -eq $expectRc -and ((-not $expectMatch) -or ($txt -match $expectMatch))) { Write-Output "ok    $label" }
    else { Write-Output ("FAIL  $label  rc=" + $r.rc + " want $expectRc; problems: " + $txt); $script:fail++ }
  }
  $closed = $honest | ConvertTo-Json -Depth 9 | ConvertFrom-Json
  $closed.items[0] | Add-Member -NotePropertyName status -NotePropertyValue 'deviated' -Force
  # MUST FIRE: the 2026-09-09 shape at close. Marked deviated, residual left in prose, no owner.
  _CaseClose 'at close, a deviated item with an open residual and no followup is rejected' $closed @('2026-09-10-aaaaaa') 2 'no leaves_open_followup'
  # MUST FIRE: an owner that resolves to nothing is not an owner.
  $ghost = $closed | ConvertTo-Json -Depth 9 | ConvertFrom-Json
  $ghost.items[0] | Add-Member -NotePropertyName leaves_open_followup -NotePropertyValue '2026-09-10-ffffff' -Force
  _CaseClose 'at close, a followup id found in neither the queue nor the rulings is rejected' $ghost @('2026-09-10-aaaaaa') 2 'resolves to nothing'
  # MUST FIRE: README rule 4. An item still planned after the developer was dropped, not finished.
  $dropped = $good | ConvertTo-Json -Depth 9 | ConvertFrom-Json
  $dropped.items[0] | Add-Member -NotePropertyName status -NotePropertyValue 'planned' -Force
  _CaseClose 'at close, an item still planned is reported as dropped' $dropped @() 2 'still .planned. at close'
  # MUST NOT FIRE: a residual owned by a real queue item.
  $owned = $closed | ConvertTo-Json -Depth 9 | ConvertFrom-Json
  $owned.items[0] | Add-Member -NotePropertyName leaves_open_followup -NotePropertyValue '2026-09-10-aaaaaa' -Force
  _CaseClose 'at close, a residual owned by a real queue item passes' $owned @('2026-09-10-aaaaaa') 0 $null
  # MUST NOT FIRE: a residual owned by a ruling carried on the plan itself.
  $ruled = $closed | ConvertTo-Json -Depth 9 | ConvertFrom-Json
  $ruled.items[0] | Add-Member -NotePropertyName leaves_open_followup -NotePropertyValue 'donuts-basis' -Force
  $ruled | Add-Member -NotePropertyName open_questions_for_brad -NotePropertyValue @([pscustomobject]@{ id = 'donuts-basis'; question = 'per each or per oz' }) -Force
  _CaseClose 'at close, a residual owned by a ruling in open_questions_for_brad passes' $ruled @() 0 $null
  # CLEAN TWIN: 'nothing' still closes with no followup at all. An honest full fix must not be made to
  # invent an owner, or every clean item pays for the partial ones.
  $nothingLeft = $good | ConvertTo-Json -Depth 9 | ConvertFrom-Json
  $nothingLeft.items[0] | Add-Member -NotePropertyName status -NotePropertyValue 'done' -Force
  _CaseClose 'at close, a done item whose leaves_open is nothing passes with no followup' $nothingLeft @() 0 $null

  # --- routing artifact positive control (2026-08-06 case-insensitive $b/$B) ----------------------------
  # These need a real file on disk, because the check reads the artifact rather than trusting the plan.
  $artDir = Join-Path $env:TEMP ('vtp-selftest-' + $PID); New-Item -ItemType Directory -Force -Path $artDir | Out-Null
  function _Artifact($obj) { $f = Join-Path $artDir 'art.json'; ($obj | ConvertTo-Json -Depth 8) | Set-Content $f -Encoding UTF8; return 'art.json' }
  function _CaseArt($label, $doc, $expectRc, $expectMatch) {
    $script:ran++
    $r = Test-Plan $doc @('q1') $artDir
    $txt = ($r.problems -join ' | ')
    if ($r.rc -eq $expectRc -and ((-not $expectMatch) -or ($txt -match $expectMatch))) { Write-Output "ok    $label" }
    else { Write-Output ("FAIL  $label  rc=" + $r.rc + " want $expectRc; problems: " + $txt); $script:fail++ }
  }
  # CLEAN TWIN: a control that reproduces passes.
  [void](_Artifact ([pscustomobject]@{ corpus='26,013 names'; positive_control=[pscustomobject]@{
      name='Bubs Goat Milk Infant Formula Powder With Iron, 20 oz., 2 pk.'; expected='baby-formula'; observed='baby-formula' } }))
  $withArt = $good | ConvertTo-Json -Depth 9 | ConvertFrom-Json
  $withArt | Add-Member -NotePropertyName routing_artifact -NotePropertyValue 'art.json' -Force
  _CaseArt 'a routing artifact whose positive control reproduces passes' $withArt 0 $null
  # MUST-FIRE 7: no control at all. A zero-change simulation and a broken simulation look identical.
  [void](_Artifact ([pscustomobject]@{ corpus='26,013 names' }))
  _CaseArt 'a routing artifact with no positive_control is rejected' $withArt 2 'no positive_control'
  # MUST-FIRE 8: THE REAL BUG. The control was declared and did NOT reproduce - which is exactly what a
  # destroyed ruleset looks like from the outside, and what two lost 26k-name simulations looked like.
  [void](_Artifact ([pscustomobject]@{ corpus='26,013 names'; positive_control=[pscustomobject]@{
      name='Bubs Goat Milk Infant Formula Powder With Iron, 20 oz., 2 pk.'; expected='baby-formula'; observed='<unmatched>' } }))
  _CaseArt 'a positive control that did not reproduce is rejected' $withArt 2 'did NOT reproduce'
  Remove-Item $artDir -Recurse -Force -ErrorAction SilentlyContinue
  # BLIND: zero items proves nothing
  _Case 'zero items reports BLIND (rc 3)' ([pscustomobject]@{ queue_ids_seen=@(); ship_sequence=@('x'); items=@() }) 3 'ZERO items'
  # MUST-FIRE: a comma-joined -OpenIds (what `powershell -File` does to a [string[]]) must be split, not
  # treated as one id. Before this, a COMPLETE plan was reported as missing every queue id.
  $split = @('q1,q2' | Where-Object { $_ } | ForEach-Object { ([string]$_) -split '[,;]' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $script:ran++
  if ($split.Count -eq 2 -and $split[0] -eq 'q1' -and $split[1] -eq 'q2') { Write-Output 'ok    comma-joined -OpenIds is split back into real ids' }
  else { Write-Output "FAIL  comma-joined -OpenIds not split (got $($split.Count) id(s))"; $script:fail++ }
  Write-Output ''
  if ($fail -gt 0) { Write-Output "SELF-TEST FAIL: $fail case(s) of $ran"; exit 1 }
  Write-Output "SELF-TEST PASS (all $ran plan-gate cases)"
  exit 0
}

if (-not $Plan) { Write-Output 'validate-triage-plan: BLIND - no -Plan given'; exit 3 }
if (-not (Test-Path $Plan)) { Write-Output ("validate-triage-plan: BLIND - no plan file at " + $Plan); exit 3 }
$doc = $null
try { $doc = Read-JsonFile $Plan } catch { Write-Output ("validate-triage-plan: BLIND - plan does not parse: " + $_.Exception.Message); exit 3 }
if (-not $doc) { Write-Output 'validate-triage-plan: BLIND - plan read back empty'; exit 3 }

# -Closing resolves each residual's owner against the live queue, so the queue has to be READ, not assumed:
# an unreadable queue would make every followup id resolve to nothing and fail a plan that is fine, or,
# written the other way, pass one that is not. Either is a confident wrong answer, so it is BLIND instead.
$queueIds = @()
if ($Closing) {
  if (-not $QueueFile) { $QueueFile = Join-Path $root 'triage-queue.json' }
  if (-not (Test-Path $QueueFile)) { Write-Output ("validate-triage-plan: BLIND - -Closing resolves owners against the queue and there is none at " + $QueueFile); exit 3 }
  $qDoc = $null
  try { $qDoc = Read-JsonFile $QueueFile } catch { $qDoc = $null }
  if (-not $qDoc -or -not $qDoc.PSObject.Properties['items']) { Write-Output ("validate-triage-plan: BLIND - the queue at " + $QueueFile + " reads back empty, unparseable or with no items array"); exit 3 }
  foreach ($qi in @($qDoc.items)) { if ($qi -and [string]$qi.id) { $queueIds += [string]$qi.id } }
}

$res = Test-Plan $doc $OpenIds (Split-Path $Plan -Parent) -Closing:$Closing -QueueIds $queueIds
$items = @($doc.items)
$mode = if ($Closing) { 'closing' } else { 'handoff' }
Write-Output ("validate-triage-plan: " + $Plan)
Write-Output ("  mode=" + $mode + "  round=" + $doc.round + "  items=" + $items.Count + "  ship_sequence=" + @($doc.ship_sequence).Count + "  expected ids=" + @($OpenIds).Count)
foreach ($i in $items) {
  $cls = [string]$i.classification
  $ma  = if ($i.blast_radius) { [string]$i.blast_radius.measured_as } else { '-' }
  $lo  = ([string]$i.leaves_open).Trim()
  $loTag = if (-not $lo) { '-' } elseif ($lo -match '^nothing\b') { 'nothing' } else { 'OPEN' }
  Write-Output ("  {0,-20} {1,-16} evidence={2,-3} measured_as={3,-8} leaves_open={4}" -f $i.queue_id, $cls, @($i.evidence).Count, $ma, $loTag)
}
# EVERY RESIDUAL, VERBATIM. These lines are what the orchestrator's report copies. A summary of them is how
# the 2026-09-09 report called eight items closed when four had left part of their own class open.
$residuals = @($items | Where-Object { $_ -and ([string]$_.leaves_open).Trim() -and (([string]$_.leaves_open).Trim() -notmatch '^nothing\b') })
if ($residuals.Count) {
  Write-Output ("  LEAVES OPEN: " + $residuals.Count + " of " + $items.Count + " item(s) - copy these into the report as written, never summarised:")
  foreach ($o in $residuals) {
    $owner = if (([string]$o.leaves_open_followup).Trim()) { ([string]$o.leaves_open_followup).Trim() } else { 'NO OWNER YET' }
    Write-Output ("    " + $o.queue_id + "  owner=" + $owner + "  " + ([string]$o.leaves_open).Trim())
  }
}
if ($res.rc -eq 0) {
  if ($Closing) { Write-Output '  PLAN CLOSED OK - every item has an outcome and every open residual has an owner that resolves'; exit 0 }
  Write-Output '  PLAN OK - complete, hand it to the developer'; exit 0
}
if ($Closing) { Write-Output ("  NOT CLOSED (" + @($res.problems).Count + " problem(s)) - do not report this run done until each is answered:") }
else { Write-Output ("  INCOMPLETE (" + @($res.problems).Count + " problem(s)) - send it back, do not hand a bad plan downstream:") }
foreach ($p in $res.problems) { Write-Output ("    - " + $p) }
exit $res.rc
