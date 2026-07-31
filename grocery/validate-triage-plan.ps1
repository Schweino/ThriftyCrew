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

  Exit codes:  0 = plan is complete and may be handed over
               2 = plan is incomplete (message says exactly what is missing)
               3 = BLIND: no plan file, unreadable, or zero items - proved nothing, do not hand over
  -SelfTest runs frozen good/bad fixtures through the rules and exits (0 pass, 1 fail).
#>
param(
  [string]$Plan = "",
  [string[]]$OpenIds = @(),
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

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
  param($Doc, [string[]]$Expect, [string]$PlanDir)
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

    # an item that widens an include must say who currently claims each admitted name
    $widens = $false
    foreach ($f in @($i.surface_fix, $i.root_fix)) {
      if ($f -and (([string]$f.exact_change) -imatch 'include' -or ([string]$f.what) -imatch 'include')) { $widens = $true }
    }
    if ($widens -and ($null -eq $i.claimed_by_earlier)) {
      $problems.Add("$id widens an include but has no claimed_by_earlier - first-match-wins can block the admit entirely (2026-07-31 taco-sauce/hot-sauce)")
    }
  }

  # the routing artifact, when the plan names one, has to be on disk
  $art = [string]$Doc.routing_artifact
  if ($art) {
    $p = if ([IO.Path]::IsPathRooted($art)) { $art } else { Join-Path $PlanDir $art }
    if (-not (Test-Path $p)) { $problems.Add("routing_artifact '$art' is named but not on disk at $p") }
  }

  if ($problems.Count) { return @{ rc = 2; problems = $problems } }
  return @{ rc = 0; problems = @() }
}

if ($SelfTest) {
  $fail = 0
  function _Case($label, $doc, $expectRc, $expectMatch) {
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
      blast_radius=[pscustomobject]@{ measured_as='routing'; measured_by='25,939 names'; affected_now=2 }
      proof=[pscustomobject]@{ guard_or_fixture='test-auditors case d2' }; rollback='revert the hunk'
      freshness='measured against comparison-2026-07-30'; resolution_note='fixed'
      surface_fix=[pscustomobject]@{ what='exclude the soda'; exact_change='lemons.exclude += ...' }
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
      proof=[pscustomobject]@{ guard_or_fixture='test-guards case 0' }; rollback='revert the hunks'
      freshness='measured against the working tree at 2026-07-31T07:00'; resolution_note='fixed'
      surface_fix=[pscustomobject]@{ what='use the null-safe idiom'; exact_change='((Get-Content $f -Raw) + $emptyString).Trim()'; files=@('grocery/check-ad-cycles.ps1') } }) }
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
  # BLIND: zero items proves nothing
  _Case 'zero items reports BLIND (rc 3)' ([pscustomobject]@{ queue_ids_seen=@(); ship_sequence=@('x'); items=@() }) 3 'ZERO items'
  Write-Output ''
  if ($fail -gt 0) { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
  Write-Output 'SELF-TEST PASS (all 7 plan-gate cases)'
  exit 0
}

if (-not $Plan) { Write-Output 'validate-triage-plan: BLIND - no -Plan given'; exit 3 }
if (-not (Test-Path $Plan)) { Write-Output ("validate-triage-plan: BLIND - no plan file at " + $Plan); exit 3 }
$doc = $null
try { $doc = Get-Content $Plan -Raw | ConvertFrom-Json } catch { Write-Output ("validate-triage-plan: BLIND - plan does not parse: " + $_.Exception.Message); exit 3 }
if (-not $doc) { Write-Output 'validate-triage-plan: BLIND - plan read back empty'; exit 3 }

$res = Test-Plan $doc $OpenIds (Split-Path $Plan -Parent)
$items = @($doc.items)
Write-Output ("validate-triage-plan: " + $Plan)
Write-Output ("  round=" + $doc.round + "  items=" + $items.Count + "  ship_sequence=" + @($doc.ship_sequence).Count + "  expected ids=" + @($OpenIds).Count)
foreach ($i in $items) {
  $cls = [string]$i.classification
  $ma  = if ($i.blast_radius) { [string]$i.blast_radius.measured_as } else { '-' }
  Write-Output ("  {0,-20} {1,-16} evidence={2,-3} measured_as={3}" -f $i.queue_id, $cls, @($i.evidence).Count, $ma)
}
if ($res.rc -eq 0) { Write-Output '  PLAN OK - complete, hand it to the developer'; exit 0 }
Write-Output ("  INCOMPLETE (" + @($res.problems).Count + " problem(s)) - send it back, do not hand a bad plan downstream:")
foreach ($p in $res.problems) { Write-Output ("    - " + $p) }
exit $res.rc
