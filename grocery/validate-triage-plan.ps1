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
  the same exit codes. Run it before a triage run reports itself done. A residual's owner is a queue id, a
  ruling id in open_questions_for_brad, or watch:<repo-relative path> for a residual whose
  leaves_open_occurrences is 0 (2026-09-10).
  BOTH MODES READ THE QUEUE (2026-09-10, Brad's ruling 5, RETURNS ARE FAILURES). An item whose queue type was
  already closed as resolved inside the 30-day window is a RETURN, and that status comes from the QUEUE, never
  from the plan, so a plan that omits the fields cannot escape. A RETURN code item must carry prior_closes
  (every prior id), prevention.source/what/exact_change, and proof.fixture_occurrences (every prior id plus
  its own); twice returned, a source made only of rule or exclusion data is refused. An unreadable queue is
  BLIND (exit 3) in handoff mode exactly as in -Closing. The rule itself is grocery\triage-return-lib.ps1.
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

. (Join-Path $root 'triage-return-lib.ps1')   # Get-TriageReturnPriors: the one copy of the RETURN rule (ruling 5)

# Rule or exclusion DATA. Twice returned, a prevention whose source is only these is refused: an exclude stops
# one product, and the type came back twice because the next product of the same shape was not in it.
$DATA_ONLY_SOURCES = @('grocery/commodities.json', 'grocery/category-excludes.json', 'grocery/known-wrong.json',
                       'grocery/price-bands.json', 'grocery/commodity-search.json')

# The queue, read the same way for both modes. ok=$false is BLIND to the caller, never an empty queue.
function Read-GateQueue {
  param([string]$Path)
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @{ ok = $false; why = "there is no queue at $Path"; items = @() } }
  $qDoc = $null
  try { $qDoc = Read-JsonFile $Path } catch { $qDoc = $null }
  if (-not $qDoc -or -not $qDoc.PSObject.Properties['items']) { return @{ ok = $false; why = "the queue at $Path reads back empty, unparseable or with no items array"; items = @() } }
  return @{ ok = $true; why = ''; items = @($qDoc.items | Where-Object { $_ }) }
}

function Test-Plan {
  param($Doc, [string[]]$Expect, [string]$PlanDir, [switch]$Closing, $QueueIds = @(), [string]$RepoRoot = '',
        $QueueItems = $null, [datetime]$Now = [datetime]::MinValue)
  if ($Now -eq [datetime]::MinValue) { $Now = Get-Date }
  $returns = New-Object System.Collections.Generic.List[string]
  # a watch:<path> owner resolves against the repo this gate lives in unless a caller (the self-test) names one
  if (-not $RepoRoot) { $RepoRoot = Split-Path $root -Parent }
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
    # --- RETURNS ARE FAILURES (2026-09-10, Brad's ruling 5) ---------------------------------------------------
    # FOUNDING MEASUREMENT: over 2026-08-22..09-10, 25 alert types fired on 3 or more days and ALL 25 came back
    # after a close. Those closes carried root causes, and most carried root fixes, and the classes came back
    # anyway, because the fix landed on the instance's rule (an exclude, a band) while whatever PRODUCED the class
    # (a capture builder, the ingest parser, the rule schema, the emitting check) was untouched. So an item whose
    # TYPE the queue shows closed before names that source, every prior close, and a fixture from all of them.
    # RETURN status is read from the QUEUE and never from the plan: a field a plan may simply omit is no gate.
    if ($null -ne $QueueItems) {
      $qItem = $null
      foreach ($qi in @($QueueItems)) { if ($qi -and [string]$qi.id -eq $id) { $qItem = $qi; break } }
      $priors = @()
      if ($qItem) { $pr0 = Get-TriageReturnPriors $QueueItems $qItem $Now; $priors = @($pr0) }
      $exempt = (@('superseded', 'needs-brad', 'needs-more-time') -contains $cls)
      $pnb = ([string]$i.prevention_none_because).Trim()
      if ($priors.Count -gt 0) { [void]$returns.Add($id) }
      if ($priors.Count -gt 0 -and -not $exempt -and -not ($cls -eq 'no-code-change' -and $pnb)) {
        $retTxt = "$id is a RETURN (type '" + ([string]$qItem.type).Trim() + "' was closed " + $priors.Count + " time(s) in 30 days: " + ($priors -join ', ') + ")"
        $pc = @(@($i.prior_closes) | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
        if ($pc.Count -eq 0) {
          $problems.Add("$retTxt and carries no prior_closes - list every earlier close of this type, checked against the queue: " + ($priors -join ', '))
        } else {
          $missPc = @($priors | Where-Object { $pc -notcontains $_ })
          if ($missPc.Count) { $problems.Add("$id prior_closes is missing " + ($missPc -join ', ') + " - the queue holds " + $priors.Count + " prior close(s) of this type in 30 days and a RETURN names every one (ruling 5)") }
        }
        $pv = $i.prevention
        if (-not $pv -or ($pv -is [string])) {
          $hint = if ($cls -eq 'no-code-change') { " A no-code-change RETURN may instead carry prevention_none_because in one line: a by-design alert that keeps returning is Phase 2's recalibration work (design/PLAN-zero-alert-days-2026-09-10.md), not a code fix." } else { ' prevention_none_because is accepted only on a no-code-change item.' }
          $problems.Add("$retTxt and carries no prevention - name the upstream producer of the class in prevention.source (a capture builder, the ingest parser, the rule schema, the emitting check), with what and exact_change. A fix that did not hold is fixed at its source (Brad's ruling 5, 2026-09-10)." + $hint)
        } else {
          # a path, optionally followed by prose: the leading token is what is compared
          $src = @(@($pv.source) | Where-Object { $_ } | ForEach-Object { ([string]$_) -split '[,;]' } | ForEach-Object { ($_.Trim() -replace '\s.*$', '') } | Where-Object { $_ })
          if ($src.Count -eq 0) { $problems.Add("$id prevention has no source - the repo path(s) of the upstream producer of the class (a capture builder, the ingest parser, the rule schema, the emitting check)") }
          if (-not ([string]$pv.what).Trim()) { $problems.Add("$id prevention has no what - what the change at the source stops") }
          if (-not ([string]$pv.exact_change).Trim()) { $problems.Add("$id prevention has no exact_change") }
          if ($priors.Count -ge 2 -and $src.Count -gt 0) {
            $nonData = @($src | Where-Object { $DATA_ONLY_SOURCES -notcontains ((($_ -replace '\\', '/') -replace '^\./', '').ToLowerInvariant()) })
            if ($nonData.Count -eq 0) {
              $problems.Add("$id has come back after " + $priors.Count + " closes and prevention.source is only rule or exclusion data (" + ($src -join ', ') + ") - for a type that has returned twice a rule or an exclude alone does not satisfy ruling 5; name the producer that lets the class in (a capture builder, the ingest parser, the rule schema, the emitting check)")
            }
          }
        }
        $fo = New-Object System.Collections.Generic.List[string]
        if ($i.proof) {
          foreach ($o in @($i.proof.fixture_occurrences)) {
            if (-not $o) { continue }
            if ($o -is [string]) { [void]$fo.Add($o) }
            else { foreach ($k in @('queue_id', 'id')) { if ($o.PSObject.Properties[$k] -and [string]$o.$k) { [void]$fo.Add([string]$o.$k) } } }
          }
        }
        $needFo = @($priors) + @($id)
        if ($fo.Count -eq 0) {
          $problems.Add("$retTxt and has no proof.fixture_occurrences - a RETURN's fixture is built from EVERY occurrence, not only today's: " + ($needFo -join ', '))
        } else {
          $missFo = @($needFo | Where-Object { $need = $_; (@($fo | Where-Object { ([string]$_).IndexOf($need, [StringComparison]::Ordinal) -ge 0 })).Count -eq 0 })
          if ($missFo.Count) { $problems.Add("$id proof.fixture_occurrences does not cover " + ($missFo -join ', ') + " - the fixture reproduces every prior close plus this one") }
        }
      }
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
        $problems.Add("$id is $([string]$i.status) with an open residual and no leaves_open_followup - enqueue it through send-alert.ps1 -Lane weekly, file it as a ruling in open_questions_for_brad, or, if it has NEVER happened, name the check that pages on its first occurrence as watch:<repo-relative path>. The residual: $lo")
      } elseif ($fu -match '^watch:\s*(.+)$') {
        # A WATCH OWNS ONLY WHAT HAS NEVER HAPPENED (2026-09-10, Brad, after a 1.35M-token triage day). That
        # day's run minted six residual queue items to satisfy the owner rule above, two of them stating
        # their own count as zero ("0 known occurrences", "0 occurrences in the 20 logged days"), and every
        # one became tomorrow's triage work at full price. A class that has never happened needs something
        # that NOTICES its first occurrence, not a queue item that re-reads the design every morning. So a
        # residual may be owned by an existing check, named by repo-relative path, but only when the item
        # records leaves_open_occurrences = 0. A count nobody wrote is not zero, and a class that has already
        # happened is live work that goes to the queue. The gate can see that the check EXISTS; it cannot
        # see that the check would fire on this class, so that claim is the plan author's to sign.
        $wPath = $Matches[1].Trim()
        $occN = -1
        if ($i.PSObject.Properties['leaves_open_occurrences'] -and ([string]$i.leaves_open_occurrences) -match '^\s*\d+\s*$') {
          $occN = [int]([string]$i.leaves_open_occurrences)
        }
        if ($occN -lt 0) {
          $problems.Add("$id is owned by '$fu' but carries no leaves_open_occurrences count - a watch owns only a residual measured at 0 occurrences, and a count nobody wrote is not zero")
        } elseif ($occN -gt 0) {
          $problems.Add("$id is owned by '$fu' but records $occN occurrence(s) - a class that has already happened needs a queue item (send-alert.ps1 -Lane weekly) or a ruling, not a watch")
        }
        if ([IO.Path]::IsPathRooted($wPath)) {
          $problems.Add("$id leaves_open_followup '$fu' must name a repo-relative path, so the check it trusts is one the repo versions")
        } elseif (-not $RepoRoot -or -not (Test-Path -LiteralPath (Join-Path $RepoRoot $wPath) -PathType Leaf)) {
          $problems.Add("$id leaves_open_followup '$fu' resolves to nothing - no check exists at that repo path")
        }
      } elseif ((@($QueueIds) -notcontains $fu) -and ($ruleIds -notcontains $fu)) {
        $problems.Add("$id leaves_open_followup '$fu' resolves to nothing - it is neither an id in the triage queue, an id in open_questions_for_brad, nor a watch:<repo-relative path>")
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

  if ($problems.Count) { return @{ rc = 2; problems = $problems; returns = $returns } }
  return @{ rc = 0; problems = @(); returns = $returns }
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

  # --- A WATCH OWNS ONLY WHAT HAS NEVER HAPPENED (2026-09-10) -------------------------------------------
  # A sandbox repo holding one real check, so the path test reads a file instead of trusting the plan.
  $wRoot = Join-Path $env:TEMP ('vtp-watch-' + $PID)
  New-Item -ItemType Directory -Force -Path (Join-Path $wRoot 'grocery') | Out-Null
  Set-Content -LiteralPath (Join-Path $wRoot 'grocery\audit-watch-fixture.ps1') -Value '# a check that pages on the first occurrence' -Encoding UTF8
  function _CaseWatch($label, $doc, $expectRc, $expectMatch) {
    $script:ran++
    $r = Test-Plan $doc @() $env:TEMP -Closing -QueueIds @('2026-09-10-aaaaaa') -RepoRoot $wRoot
    $txt = ($r.problems -join ' | ')
    if ($r.rc -eq $expectRc -and ((-not $expectMatch) -or ($txt -match $expectMatch))) { Write-Output "ok    $label" }
    else { Write-Output ("FAIL  $label  rc=" + $r.rc + " want $expectRc; problems: " + $txt); $script:fail++ }
  }
  try {
    $watched = $closed | ConvertTo-Json -Depth 9 | ConvertFrom-Json
    $watched.items[0] | Add-Member -NotePropertyName leaves_open_followup -NotePropertyValue 'watch:grocery/audit-watch-fixture.ps1' -Force
    $watched.items[0] | Add-Member -NotePropertyName leaves_open_occurrences -NotePropertyValue 0 -Force
    # MUST NOT FIRE: a residual measured at 0 occurrences, owned by a check that exists, needs no queue item.
    _CaseWatch 'at close, a zero-occurrence residual owned by an existing check passes' $watched 0 $null
    # MUST FIRE: the class has already happened, so it is live work and a watch is the wrong owner.
    $happened = $watched | ConvertTo-Json -Depth 9 | ConvertFrom-Json
    $happened.items[0].leaves_open_occurrences = 2
    _CaseWatch 'at close, a watch over a residual that has happened twice is rejected' $happened 2 'records 2 occurrence'
    # MUST FIRE: no count at all. A count nobody wrote is not zero.
    $uncounted = $watched | ConvertTo-Json -Depth 9 | ConvertFrom-Json
    $uncounted.items[0].PSObject.Properties.Remove('leaves_open_occurrences')
    _CaseWatch 'at close, a watch with no leaves_open_occurrences is rejected' $uncounted 2 'no leaves_open_occurrences'
    # MUST FIRE: a watch naming a check that does not exist owns nothing.
    $ghostWatch = $watched | ConvertTo-Json -Depth 9 | ConvertFrom-Json
    $ghostWatch.items[0].leaves_open_followup = 'watch:grocery/no-such-check.ps1'
    _CaseWatch 'at close, a watch naming a check that does not exist is rejected' $ghostWatch 2 'no check exists'
    # MUST FIRE: an absolute path points at a check the repo does not version.
    $rootedWatch = $watched | ConvertTo-Json -Depth 9 | ConvertFrom-Json
    $rootedWatch.items[0].leaves_open_followup = 'watch:' + (Join-Path $wRoot 'grocery\audit-watch-fixture.ps1')
    _CaseWatch 'at close, a watch naming an absolute path is rejected' $rootedWatch 2 'repo-relative'
    # CLEAN TWIN: a queue-id owner still resolves exactly as before, beside the new watch branch.
    _CaseWatch 'CLEAN TWIN at close, a residual owned by a real queue item still passes' $owned 0 $null
  } finally { Remove-Item -LiteralPath $wRoot -Recurse -Force -ErrorAction SilentlyContinue }

  # --- RETURNS ARE FAILURES (2026-09-10, Brad's ruling 5) ----------------------------------------------------
  # Founding measurement: 25 types fired on 3+ days over 2026-08-22..09-10 and all 25 came back after a close.
  # Every case hands Test-Plan a QUEUE, because RETURN status is the queue's to say and never the plan's.
  $retNow = [datetime]'2026-09-10T09:00:00'
  $rt = 'grocery guards failed board not published'
  $qP1 = [pscustomobject]@{ id = '2026-09-01-aaaaa1'; type = $rt; ts = '2026-09-01T08:15:00'; status = 'resolved' }
  $qP2 = [pscustomobject]@{ id = '2026-09-05-aaaaa2'; type = $rt; ts = '2026-09-05T08:15:00'; status = 'resolved' }
  $qCur = [pscustomobject]@{ id = 'q1'; type = $rt; ts = '2026-09-10T08:15:00'; status = 'open' }
  $qFirst = [pscustomobject]@{ id = 'q1'; type = 'grocery a type never closed before'; ts = '2026-09-10T08:15:00'; status = 'open' }
  $twice = @($qP1, $qP2, $qCur); $once = @($qP2, $qCur); $firstTime = @($qP1, $qP2, $qFirst)
  function _CaseRet($label, $doc, $queue, $expectRc, $expectMatch, [bool]$expectReturn) {
    $script:ran++
    $r = Test-Plan $doc @('q1') $env:TEMP -QueueItems $queue -Now $retNow
    $txt = ($r.problems -join ' | ')
    $isRet = (@($r.returns | Where-Object { $_ }) -contains 'q1')
    if ($r.rc -eq $expectRc -and $isRet -eq $expectReturn -and ((-not $expectMatch) -or ($txt -match $expectMatch))) { Write-Output "ok    $label" }
    else { Write-Output ("FAIL  $label  rc=" + $r.rc + " want $expectRc; return=" + $isRet + " want " + $expectReturn + "; problems: " + $txt); $script:fail++ }
  }
  $fullRet = $good | ConvertTo-Json -Depth 9 | ConvertFrom-Json
  $fullRet.items[0] | Add-Member -NotePropertyName prior_closes -NotePropertyValue @('2026-09-01-aaaaa1', '2026-09-05-aaaaa2') -Force
  $fullRet.items[0] | Add-Member -NotePropertyName prevention -NotePropertyValue ([pscustomobject]@{ source = @('grocery/ingest-row-contract.ps1'); what = 'the capture refuses a row whose size was derived, before any rule sees it'; exact_change = 'every row declares size_kind and size_source; a derived size is never divided on' }) -Force
  $fullRet.items[0].proof | Add-Member -NotePropertyName fixture_occurrences -NotePropertyValue @('2026-09-01-aaaaa1', '2026-09-05-aaaaa2', 'q1') -Force
  # CLEAN TWIN: a complete RETURN item is recognised as a RETURN from the queue and passes.
  _CaseRet 'CLEAN TWIN a complete RETURN item is recognised from the queue and passes the gate' $fullRet $twice 0 $null $true
  # MUST FIRE: a RETURN code item with no prevention.
  $noPrev = $fullRet | ConvertTo-Json -Depth 9 | ConvertFrom-Json
  $noPrev.items[0].PSObject.Properties.Remove('prevention')
  _CaseRet 'MUST FIRE a RETURN code item with no prevention is rejected' $noPrev $once 2 'carries no prevention' $true
  # MUST FIRE: prior_closes misses one of the queue's prior closes, and the message names it.
  $missOne = $fullRet | ConvertTo-Json -Depth 9 | ConvertFrom-Json
  $missOne.items[0].prior_closes = @('2026-09-05-aaaaa2')
  _CaseRet 'MUST FIRE prior_closes missing one of the queue''s prior ids names the missing id' $missOne $twice 2 'prior_closes is missing 2026-09-01-aaaaa1' $true
  # MUST FIRE: twice returned, and the prevention is only a rule file.
  $ruleOnly = $fullRet | ConvertTo-Json -Depth 9 | ConvertFrom-Json
  $ruleOnly.items[0].prevention.source = @('grocery/commodities.json')
  _CaseRet 'MUST FIRE a twice-returned item whose prevention source is only grocery/commodities.json is rejected' $ruleOnly $twice 2 'only rule or exclusion data' $true
  # MUST NOT FIRE: the same rule-file source once returned. The data-only refusal starts at two prior closes.
  _CaseRet 'MUST NOT FIRE a once-returned item may name a rule file as its prevention source' $ruleOnly $once 0 $null $true
  # MUST FIRE: the plan omits every RETURN field, and the queue still makes it a RETURN.
  _CaseRet 'MUST FIRE a plan that omits every RETURN field is still a RETURN because the queue says so' $good $twice 2 'is a RETURN' $true
  # MUST FIRE: a fixture built from the prior closes but not today's occurrence.
  $noCur = $fullRet | ConvertTo-Json -Depth 9 | ConvertFrom-Json
  $noCur.items[0].proof.fixture_occurrences = @('2026-09-01-aaaaa1', '2026-09-05-aaaaa2')
  _CaseRet 'MUST FIRE fixture_occurrences that leave out the current occurrence are rejected' $noCur $twice 2 'does not cover q1' $true
  # MUST FIRE: prevention_none_because does not excuse a code item.
  $codeNone = $good | ConvertTo-Json -Depth 9 | ConvertFrom-Json
  $codeNone.items[0] | Add-Member -NotePropertyName prevention_none_because -NotePropertyValue 'the exclude is enough' -Force
  _CaseRet 'MUST FIRE prevention_none_because does not excuse a RETURN code item' $codeNone $once 2 'accepted only on a no-code-change' $true
  # MUST NOT FIRE: a first-time item, beside closes of another type, is asked for nothing new.
  _CaseRet 'MUST NOT FIRE a first-time item is not asked for any RETURN field' $good $firstTime 0 $null $false
  # MUST FIRE: a no-code-change RETURN with neither answer, and the message names Phase 2.
  _CaseRet 'MUST FIRE a no-code-change RETURN with no prevention_none_because is rejected, naming Phase 2' $ok2 $once 2 'Phase 2' $true
  # MUST NOT FIRE: a by-design RETURN says so in one line.
  $byDesign = $ok2 | ConvertTo-Json -Depth 9 | ConvertFrom-Json
  $byDesign.items[0] | Add-Member -NotePropertyName prevention_none_because -NotePropertyValue 'by design: it re-fires on a real stale store, and recalibrating it is Phase 2 work' -Force
  _CaseRet 'MUST NOT FIRE a no-code-change RETURN carrying prevention_none_because passes' $byDesign $once 0 $null $true
  # MUST NOT FIRE: needs-more-time is exempt; its queue id stays open and the next run meets the rule.
  $parkedRet = $ok2 | ConvertTo-Json -Depth 9 | ConvertFrom-Json
  $parkedRet.items[0].classification = 'needs-more-time'
  _CaseRet 'MUST NOT FIRE a needs-more-time RETURN is exempt' $parkedRet $twice 0 $null $true
  # BLIND: handoff mode now reads the queue, so an unreadable one is exit 3 and never a pass with no RETURNs.
  $bDir = Join-Path $env:TEMP ('vtp-blind-' + $PID)
  New-Item -ItemType Directory -Force -Path $bDir | Out-Null
  try {
    $u8 = New-Object Text.UTF8Encoding($false)
    $bPlan = Join-Path $bDir 'plan.json'; $bQueue = Join-Path $bDir 'queue.json'; $okQueue = Join-Path $bDir 'queue-ok.json'
    [IO.File]::WriteAllText($bPlan, ($good | ConvertTo-Json -Depth 9), $u8)
    [IO.File]::WriteAllText($bQueue, '{ "items": [ { "id": "q1", "type"', $u8)
    [IO.File]::WriteAllText($okQueue, '{ "items": [ { "id": "q1", "type": "t", "ts": "2026-09-10T08:15:00", "status": "open" } ] }', $u8)
    $script:ran++
    $gqB = Read-GateQueue $bQueue
    $bOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Plan $bPlan -QueueFile $bQueue
    $bRc = $LASTEXITCODE
    if ((-not $gqB.ok) -and $bRc -eq 3 -and (($bOut -join ' ') -match 'BLIND')) { Write-Output 'ok    MUST FIRE handoff mode on an unreadable queue is BLIND (exit 3)' }
    else { Write-Output ("FAIL  MUST FIRE handoff mode on an unreadable queue is BLIND  rc=$bRc ok=" + $gqB.ok + "; " + ($bOut -join ' ')); $script:fail++ }
    $script:ran++
    $gqM = Read-GateQueue (Join-Path $bDir 'no-such-queue.json')
    if (-not $gqM.ok) { Write-Output 'ok    MUST FIRE a missing queue reads as not ok, never as an empty one' } else { Write-Output 'FAIL  a missing queue read as ok'; $script:fail++ }
    $script:ran++
    $gqO = Read-GateQueue $okQueue
    if ($gqO.ok -and @($gqO.items).Count -eq 1 -and [string]@($gqO.items)[0].id -eq 'q1') { Write-Output 'ok    CLEAN TWIN a readable queue returns its one item' } else { Write-Output ("FAIL  a readable queue did not return its item: ok=" + $gqO.ok); $script:fail++ }
  } finally { Remove-Item -LiteralPath $bDir -Recurse -Force -ErrorAction SilentlyContinue }

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
# BOTH MODES since 2026-09-10 (ruling 5): handoff derives RETURN items from the queue, so an unreadable queue there
# would silently exempt every RETURN. That is the same confident wrong answer, so it gets the same BLIND.
if (-not $QueueFile) { $QueueFile = Join-Path $root 'triage-queue.json' }
$gq = Read-GateQueue $QueueFile
if (-not $gq.ok) { Write-Output ("validate-triage-plan: BLIND - both modes read the queue (-Closing resolves owners against it, handoff derives RETURN items from it) and " + $gq.why); exit 3 }
$queueItems = @($gq.items)
$queueIds = @()
foreach ($qi in $queueItems) { if ($qi -and [string]$qi.id) { $queueIds += [string]$qi.id } }

$res = Test-Plan $doc $OpenIds (Split-Path $Plan -Parent) -Closing:$Closing -QueueIds $queueIds -QueueItems $queueItems -Now (Get-Date)
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
$retIds = @($res.returns | Where-Object { $_ })
if ($retIds.Count) {
  Write-Output ("  RETURNS: " + $retIds.Count + " of " + $items.Count + " item(s) are a type triage already closed in the last 30 days, read from the queue (ruling 5): " + ($retIds -join ', '))
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
