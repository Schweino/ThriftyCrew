<#
  brain-report.ps1 - the estate half of the brain on one page: every learning stage, its live number,
  the file that owns it, and a floor that goes RED when its producer stops.

  WS 11 of design\PLAN-brain-v2-2026-09-09.md.

  WHY. ~/.claude/skills/recall-brain.py shows the personal store's loop on one page and names the stage
  that is starving. The estate had health-heartbeat.ps1 for scheduled TASKS and nothing for LEARNING, and
  its learning stages had no floors - which is how 60 alias proposals sat for 20 days, the review packet
  froze at 2026-08-21, and graph.db perceived no capture for 20 days while its input check read green.

  SAME CONTRACT AS recall-brain.py.
    * IT READS AND NEVER WRITES. Every figure comes through the front door of the file that owns it -
      a script it RUNS, never a state file behind it (ops\audit-cross-module-reach.ps1) - and every one
      of those is called in a mode that cannot write: learning_status --json, verdict_expiry --json,
      scorecard_query (mode=ro), tune-alert-rearm -DryRun, audit-conclusion-currency -ReportOnly and
      incident-trigger without -Write. The six run in parallel (lib\parallel-run.ps1).
    * A STAGE WITH NO DATA SAYS NO EVIDENCE, NEVER ok.
    * EVERY STAGE HAS A FLOOR, IN THIS FILE. ops-and-gates.md, backlog I80: every threshold here is an
      UPPER bound, so none of them can fire on nothing happening. A floor is the one property no upper
      bound supplies. A RED stage is content: ops\brain-digest.ps1 turns it into a line in the morning
      mail and an event on the bus; this file never does either.

  WEAKEST LINK: a RED stage first, in loop order; otherwise the stage with the least evidence flowing.
  The incident stage is a queue, not a flow, and never competes.

  SCOPE OF A CLEAN REPORT: UNSOUND. A green floor says the stage's producer wrote something inside its
  window, never that what it wrote was right. Ten floors are not a proof of learning.

  -Json prints `brain-report-json: {...}` before the completion marker, for recall-brain.py --with-estate
  and ops\brain-digest.ps1.

  EXIT 0 always - a RED stage is content. 3 when not one source could run.
#>
[CmdletBinding()]
param([switch]$SelfTest, [switch]$Json)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\event-bus.ps1')
. (Join-Path $repo 'lib\parallel-run.ps1')

$PY = 'C:\Codex\Python312\python.exe'
$PSEXE = 'powershell'

# THE FLOORS. First plausible values, NOT a sweep - each is the producer's own cadence plus slack, and
# each is registered in docs\CONTROL-CONSTANTS.md.
$script:FLOOR = @{
  BusSilentDays      = 3     # audit-event-bus.ps1's own FLOOR_DAYS: the chain-complete heartbeat is daily
  ObservationsDays   = 3     # the daily capture chain feeds graph.db
  ProposalNewestDays = 7     # Stage 1 runs nightly
  PacketDays         = 2     # nightly 5b rebuilds the packet
  ApplyDays          = 30    # applying is a person's act; a month with patches waiting is the floor
  ScoreStaleDays     = 2     # nightly 5d re-scores when an input moved
  NightlyDays        = 2     # the nightly chain itself
  ClosesDays         = 7     # tune-alert-rearm reports closes in 7 days
  RecheckDays        = 2     # the watchdog records a hold recheck daily
}

function Get-JsonLine {
  <# The JSON after a `prefix:` line, or the whole output parsed when there is no prefix. $null on failure. #>
  param($Out, [string]$Prefix = '')
  try {
    if ($Prefix) {
      $l = @(@($Out) | Where-Object { "$_" -like "$Prefix*" })
      if (-not $l.Count) { return $null }
      return (("$($l[$l.Count - 1])").Substring($Prefix.Length).Trim() | ConvertFrom-Json)
    }
    $t = (@($Out) -join "`n").Trim()
    if (-not $t) { return $null }
    $i = $t.LastIndexOf("`n{")
    if ($t.StartsWith('{')) { return ($t | ConvertFrom-Json) }
    if ($i -ge 0) { return ($t.Substring($i + 1) | ConvertFrom-Json) }
    return $null
  } catch { return $null }
}

function Get-AgeDays {
  param([string]$Iso, [datetime]$Now)
  if (-not $Iso) { return $null }
  try { return [math]::Round(($Now - [datetime]$Iso).TotalDays, 1) } catch { return $null }
}

function New-Stage {
  param([string]$Stage, [string]$Does, [string]$Owner, [string]$Live, [int]$Evidence, [string]$Floor, [string]$Why = '')
  return [pscustomobject]@{ stage = $Stage; does = $Does; owner = $Owner; live = $Live; evidence = $Evidence; floor = $Floor; why = $Why }
}

function Get-EstateStages {
  <# The ten stages from the gathered sources. PURE: $S holds each source's parsed JSON or $null. #>
  param([hashtable]$S, [int]$Bus24, [int]$Bus72, [datetime]$Now)
  $F = $script:FLOOR
  $st = New-Object System.Collections.Generic.List[object]
  $ls = $S.learning; $ve = $S.expiry; $sc = $S.scorecard; $tu = $S.tuning; $cc = $S.conclusions; $it = $S.incidents

  # perceive
  $obsAge = if ($ve) { $ve.observations_newest_age_days } else { $null }
  $live = "$Bus24 bus event(s) in 24h; graph observations newest " + $(if ($ve) { "$($ve.observations_newest) ($obsAge d)" } else { 'UNKNOWN' })
  $floor = 'ok'; $why = ''
  if ($Bus72 -eq 0) { $floor = 'RED'; $why = "the event bus has been silent $($F.BusSilentDays) days" }
  elseif ($null -ne $obsAge -and [double]$obsAge -gt $F.ObservationsDays) { $floor = 'RED'; $why = "graph.db has perceived no capture for $obsAge days" }
  [void]$st.Add((New-Stage 'perceive' 'an estate event or a capture reaches the graph' 'lib\event-bus.ps1, graph\learning\verdict_expiry.py' $live $Bus24 $floor $why))

  # propose
  if ($ls) {
    $live = "$($ls.proposals_pending) pending, oldest $($ls.proposals_oldest_days) d; $($ls.proposals_new_7d) new in 7 d, newest $($ls.proposals_newest_days) d"
    $floor = 'ok'; $why = ''
    if ($null -eq $ls.proposals_newest_days -or [double]$ls.proposals_newest_days -gt $F.ProposalNewestDays) { $floor = 'RED'; $why = "Stage 1 has proposed nothing for more than $($F.ProposalNewestDays) days" }
    [void]$st.Add((New-Stage 'propose' 'Stage 1 turns misses into alias proposals' 'graph\learning\learning_status.py' $live ([int]$ls.proposals_new_7d) $floor $why))
  } else { [void]$st.Add((New-Stage 'propose' 'Stage 1 turns misses into alias proposals' 'graph\learning\learning_status.py' 'UNKNOWN - learning_status.py could not run' 0 'NO EVIDENCE')) }

  # review
  if ($ls) {
    $age = $ls.review_packet_age_days
    $live = "review packet $age d old, $($ls.review_packet_proposals) proposal(s)"
    $ev = if ($null -ne $age -and [double]$age -le $F.PacketDays) { [int]$ls.review_packet_proposals } else { 0 }
    $floor = 'ok'; $why = ''
    if ($null -eq $age -or [double]$age -gt $F.PacketDays) { $floor = 'RED'; $why = "the review packet is $age days old; the nightly rebuilds it" }
    [void]$st.Add((New-Stage 'review' 'the packet a reviewer rules on' 'graph\learning\stage2_review.py --emit-packet' $live $ev $floor $why))
  } else { [void]$st.Add((New-Stage 'review' 'the packet a reviewer rules on' 'graph\learning\stage2_review.py --emit-packet' 'UNKNOWN' 0 'NO EVIDENCE')) }

  # apply
  if ($ls) {
    $age = $ls.patches_last_applied_age_days
    $live = "$($ls.patches_unapplied) unapplied; last applied $age d ago; $($ls.patches_applied_30d) in 30 d"
    $floor = 'ok'; $why = ''
    if ([int]$ls.patches_unapplied -gt 0 -and ($null -eq $age -or [double]$age -gt $F.ApplyDays)) { $floor = 'RED'; $why = "$($ls.patches_unapplied) approved patch(es) wait and nothing was applied in $($F.ApplyDays) days" }
    [void]$st.Add((New-Stage 'apply' 'an approved patch reaches the catalog' 'graph\learning\stage2_review.py --apply' $live ([int]$ls.patches_applied_30d) $floor $why))
  } else { [void]$st.Add((New-Stage 'apply' 'an approved patch reaches the catalog' 'graph\learning\stage2_review.py --apply' 'UNKNOWN' 0 'NO EVIDENCE')) }

  # score
  if ($ls) {
    $stale = $ls.eval_days_stale_vs_inputs
    $live = "scoreboard $stale d stale against its inputs; $($ls.eval_runs_7d) run(s) in 7 d"
    $floor = 'ok'; $why = ''
    if ($null -eq $stale -or [double]$stale -gt $F.ScoreStaleDays) { $floor = 'RED'; $why = "the gold scoreboard is $stale days behind its inputs" }
    [void]$st.Add((New-Stage 'score' 'the gold set grades the resolver' 'graph\eval\score.py' $live ([int]$ls.eval_runs_7d) $floor $why))
  } else { [void]$st.Add((New-Stage 'score' 'the gold set grades the resolver' 'graph\eval\score.py' 'UNKNOWN' 0 'NO EVIDENCE')) }

  # generalise
  # The nightly block lives under local_lane in scorecard_query.py's output. The first live run read it at the
  # top level, found nothing, and reported NO EVIDENCE for a chain that had run the night before.
  if ($sc -and $sc.local_lane -and $sc.local_lane.nightly) {
    $n = $sc.local_lane.nightly
    $at = [string]$n.at
    $nAge = Get-AgeDays -Iso $at -Now $Now
    $states = @{}
    if ($n.stages) { foreach ($p in $n.stages.PSObject.Properties) { $states[$p.Name] = [string]$p.Value } }
    $la = if ($states.ContainsKey('lint-adjacency')) { $states['lint-adjacency'] } else { 'not in that run' }
    $rf = if ($states.ContainsKey('rejection-families')) { $states['rejection-families'] } else { 'not in that run' }
    $ev = @(@($la, $rf) | Where-Object { $_ -in @('OK', 'SKIP') }).Count
    $live = "nightly $at ($nAge d): lint-adjacency $la, rejection-families $rf"
    $floor = 'ok'; $why = ''
    if ([string]$n.state -ne 'ran' -or $null -eq $nAge -or [double]$nAge -gt $F.NightlyDays) { $floor = 'RED'; $why = "the nightly chain has not run for $nAge days" }
    [void]$st.Add((New-Stage 'generalise' 'misses become families and near-misses' 'graph\pipeline\nightly.ps1 5e-5f' $live $ev $floor $why))
  } else { [void]$st.Add((New-Stage 'generalise' 'misses become families and near-misses' 'graph\pipeline\nightly.ps1 5e-5f' 'UNKNOWN - scorecard_query.py could not run' 0 'NO EVIDENCE')) }

  # correct
  if ($tu -and $tu.known) {
    $live = "$($tu.closes_7d) judged close(s) in 7 d; $($tu.types_at_bar) of $($tu.types) type(s) at the 5-case bar"
    $floor = 'ok'; $why = ''
    if ([int]$tu.closes_7d -eq 0) { $floor = 'RED'; $why = "no alert was closed with a disposition in $($F.ClosesDays) days, so no precision can move" }
    [void]$st.Add((New-Stage 'correct' 'a closed alert says whether it was right' 'grocery\triage-close.ps1' $live ([int]$tu.closes_7d) $floor $why))
  } else { [void]$st.Add((New-Stage 'correct' 'a closed alert says whether it was right' 'grocery\triage-close.ps1' 'UNKNOWN - the triage queue could not be read' 0 'NO EVIDENCE')) }

  # tune
  if ($tu -and $tu.known) {
    $live = "$($tu.moves_30d) re-arm move(s) in 30 d; now $($tu.moved) moved, $($tu.refused) refused, $($tu.stale) stale"
    [void]$st.Add((New-Stage 'tune' 'precision moves an alert''s re-arm window' 'grocery\tune-alert-rearm.ps1' $live ([int]$tu.moves_30d) 'ok' ''))
  } else { [void]$st.Add((New-Stage 'tune' 'precision moves an alert''s re-arm window' 'grocery\tune-alert-rearm.ps1' 'UNKNOWN - the actuator could not read its queue' 0 'RED' 'the re-arm actuator cannot read the triage queue')) }

  # forget
  $parts = @(); $floor = 'ok'; $why = ''; $ev = 0
  if ($ls) {
    $parts += ("holds: longest inert streak {0} of 30, {1} clear proposal(s), newest recheck {2} d" -f $ls.holds_longest_inert_streak, $ls.holds_clear_proposed, $ls.holds_recheck_newest_days)
    $ev = [int]$ls.holds_recheck_days
    if ($null -eq $ls.holds_recheck_newest_days -or [double]$ls.holds_recheck_newest_days -gt $F.RecheckDays) { $floor = 'RED'; $why = "no hold recheck recorded in $($F.RecheckDays) days" }
  }
  if ($ve) { $parts += ("verdicts: {0} expired of {1}, {2} decision date(s), first expiry {3}" -f $ve.expired_total, $ve.total, $ve.distinct_dates, $ve.first_expiry) }
  if ($cc -and $cc.known) { $parts += ("conclusions: {0} of {1} unqualified" -f $cc.unqualified, $cc.docs) }
  if (-not $parts.Count) { [void]$st.Add((New-Stage 'forget' 'holds, verdicts and conclusions expire on evidence' 'promote_aliases.py, verdict_expiry.py, audit-conclusion-currency.ps1' 'UNKNOWN' 0 'NO EVIDENCE')) }
  else { [void]$st.Add((New-Stage 'forget' 'holds, verdicts and conclusions expire on evidence' 'promote_aliases.py, verdict_expiry.py, audit-conclusion-currency.ps1' ($parts -join '; ') $ev $floor $why)) }

  # incidents - a queue, not a flow: evidence -1, never the weakest link
  if ($it -and $it.known) {
    [void]$st.Add((New-Stage 'incidents' 'three of the same failure opens a record' 'ops\incident-trigger.ps1' ("{0} draft(s) open; {1} trigger(s) now" -f $it.drafts_open, $it.triggers) -1 'ok' ''))
  } else { [void]$st.Add((New-Stage 'incidents' 'three of the same failure opens a record' 'ops\incident-trigger.ps1' 'UNKNOWN' -1 'RED' 'the incident trigger could not run')) }
  $a = $st.ToArray()
  return ,$a
}

function Get-WeakestLink {
  param($Stages)
  $red = @(@($Stages) | Where-Object { $_.floor -eq 'RED' })
  if ($red.Count) { return ("{0} - RED: {1}" -f $red[0].stage, $red[0].why) }
  $scored = @(@($Stages) | Where-Object { $_.evidence -ge 0 -and $_.floor -ne 'NO EVIDENCE' } | Sort-Object evidence)
  if ($scored.Count) { return ("{0}, with {1} flowing" -f $scored[0].stage, $scored[0].evidence) }
  return 'NO EVIDENCE - no stage could be read'
}

function Format-EstateReport {
  param($Stages, [string]$Weakest)
  $L = New-Object System.Collections.Generic.List[string]
  [void]$L.Add('THE ESTATE HALF OF THE LOOP - every learning stage, its live number, its owner, and its floor.')
  [void]$L.Add('')
  [void]$L.Add(('{0,-11} {1,-12} {2}' -f 'stage', 'floor', 'live'))
  [void]$L.Add(('-' * 108))
  foreach ($s in @($Stages)) {
    [void]$L.Add(('{0,-11} {1,-12} {2}' -f $s.stage, $s.floor, $s.live))
    $note = if ($s.why) { "$($s.owner) - $($s.why)" } else { $s.owner }
    [void]$L.Add(('{0,-11} {1,-12}   ({2})' -f '', '', $note))
  }
  [void]$L.Add('')
  [void]$L.Add("WEAKEST LINK (estate): $Weakest")
  return $L.ToArray()
}

if ($SelfTest) {
  $ran = New-Object System.Collections.Generic.List[string]
  $fails = New-Object System.Collections.Generic.List[string]
  function Case([string]$Label, [string]$Name, [bool]$Ok, [string]$Detail = '') {
    [void]$ran.Add($Name)
    if (-not $Ok) { [void]$fails.Add("$Label $Name") }
    Write-Output ("  {0,-14} {1,-66} {2}" -f $Label, $Name, $(if ($Ok) { 'ok' } else { "FAIL $Detail" }))
  }
  $now = [datetime]'2026-09-10T06:00:00'
  function Healthy {
    return @{
      learning = [pscustomobject]@{ proposals_pending = 4; proposals_oldest_days = 3.0; proposals_new_7d = 6; proposals_newest_days = 0.4
                                    review_packet_age_days = 0.3; review_packet_proposals = 4; patches_unapplied = 0; patches_last_applied_age_days = 5.0
                                    patches_applied_30d = 2; eval_days_stale_vs_inputs = 0.0; eval_runs_7d = 3; holds_longest_inert_streak = 4
                                    holds_clear_proposed = 0; holds_recheck_newest_days = 0.2; holds_recheck_days = 9 }
      expiry = [pscustomobject]@{ observations_newest = '2026-09-09'; observations_newest_age_days = 1; expired_total = 0; total = 4141; distinct_dates = 3; first_expiry = '2026-11-19T01:37:15' }
      scorecard = [pscustomobject]@{ local_lane = [pscustomobject]@{ nightly = [pscustomobject]@{ state = 'ran'; at = '2026-09-09T21:30:01'; stages = [pscustomobject]@{ 'lint-adjacency' = 'OK'; 'rejection-families' = 'SKIP' } } } }
      tuning = [pscustomobject]@{ known = $true; types = 18; moved = 0; refused = 0; stale = 0; moves_30d = 1; closes_7d = 5; types_at_bar = 1 }
      conclusions = [pscustomobject]@{ known = $true; docs = 13; unqualified = 4 }
      incidents = [pscustomobject]@{ known = $true; drafts_open = 0; triggers = 0 }
    }
  }
  function StageOf($stages, [string]$name) { return @(@($stages) | Where-Object { $_.stage -eq $name })[0] }

  $h = Healthy
  $hs = Get-EstateStages -S $h -Bus24 12 -Bus72 40 -Now $now
  Case 'MUST NOT FIRE' 'a healthy estate has no RED stage' (@(@($hs) | Where-Object { $_.floor -ne 'ok' }).Count -eq 0) ((@($hs) | Where-Object { $_.floor -ne 'ok' } | ForEach-Object { $_.stage }) -join ',')
  Case 'CLEAN TWIN' 'it reports ten stages in loop order' ((@($hs) | ForEach-Object { $_.stage }) -join ',' -eq 'perceive,propose,review,apply,score,generalise,correct,tune,forget,incidents') ((@($hs) | ForEach-Object { $_.stage }) -join ',')

  $s1 = Get-EstateStages -S (Healthy) -Bus24 0 -Bus72 0 -Now $now
  Case 'MUST FIRE' 'perceive: a bus silent for three days is RED' ((StageOf $s1 'perceive').floor -eq 'RED')
  $h2 = Healthy; $h2.expiry.observations_newest = '2026-08-21'; $h2.expiry.observations_newest_age_days = 20
  $s2 = Get-EstateStages -S $h2 -Bus24 12 -Bus72 40 -Now $now
  Case 'MUST FIRE' 'perceive: graph observations 20 days old are RED (the 2026-09-10 finding)' ((StageOf $s2 'perceive').floor -eq 'RED' -and (StageOf $s2 'perceive').why -match '20 days')
  $h3 = Healthy; $h3.learning.proposals_newest_days = 9.0
  Case 'MUST FIRE' 'propose: nothing proposed for 9 days is RED' ((StageOf (Get-EstateStages -S $h3 -Bus24 1 -Bus72 1 -Now $now) 'propose').floor -eq 'RED')
  $h4 = Healthy; $h4.learning.review_packet_age_days = 20.1
  Case 'MUST FIRE' 'review: a 20-day-old packet is RED' ((StageOf (Get-EstateStages -S $h4 -Bus24 1 -Bus72 1 -Now $now) 'review').floor -eq 'RED')
  $h5 = Healthy; $h5.learning.patches_unapplied = 27; $h5.learning.patches_last_applied_age_days = 31.0
  Case 'MUST FIRE' 'apply: patches waiting with nothing applied in 30 days is RED' ((StageOf (Get-EstateStages -S $h5 -Bus24 1 -Bus72 1 -Now $now) 'apply').floor -eq 'RED')
  $h6 = Healthy; $h6.learning.eval_days_stale_vs_inputs = 19.1
  Case 'MUST FIRE' 'score: a scoreboard 19 days behind its inputs is RED' ((StageOf (Get-EstateStages -S $h6 -Bus24 1 -Bus72 1 -Now $now) 'score').floor -eq 'RED')
  $h7 = Healthy; $h7.scorecard.local_lane.nightly.at = '2026-09-06T21:30:00'
  Case 'MUST FIRE' 'generalise: a nightly chain three days quiet is RED' ((StageOf (Get-EstateStages -S $h7 -Bus24 1 -Bus72 1 -Now $now) 'generalise').floor -eq 'RED')
  $h8 = Healthy; $h8.tuning.closes_7d = 0
  Case 'MUST FIRE' 'correct: no judged close in 7 days is RED' ((StageOf (Get-EstateStages -S $h8 -Bus24 1 -Bus72 1 -Now $now) 'correct').floor -eq 'RED')
  $h9 = Healthy; $h9.tuning = $null
  Case 'MUST FIRE' 'tune: an actuator that cannot read its queue is RED' ((StageOf (Get-EstateStages -S $h9 -Bus24 1 -Bus72 1 -Now $now) 'tune').floor -eq 'RED')
  $h10 = Healthy; $h10.learning.holds_recheck_newest_days = 5.0
  Case 'MUST FIRE' 'forget: no hold recheck recorded for 5 days is RED' ((StageOf (Get-EstateStages -S $h10 -Bus24 1 -Bus72 1 -Now $now) 'forget').floor -eq 'RED')
  $h11 = Healthy; $h11.incidents = $null
  Case 'MUST FIRE' 'incidents: a trigger that could not run is RED' ((StageOf (Get-EstateStages -S $h11 -Bus24 1 -Bus72 1 -Now $now) 'incidents').floor -eq 'RED')

  $h12 = Healthy; $h12.learning = $null
  $s12 = Get-EstateStages -S $h12 -Bus24 1 -Bus72 1 -Now $now
  Case 'MUST NOT FIRE' 'a source that could not run reads NO EVIDENCE, never ok' ((StageOf $s12 'propose').floor -eq 'NO EVIDENCE' -and (StageOf $s12 'score').floor -eq 'NO EVIDENCE')

  $w1 = Get-WeakestLink -Stages $hs
  # tune at 1, derived from the fixture: perceive 12, propose 6, review 4, apply 2, score 3, generalise 2,
  # correct 5, tune 1, forget 9. The first draft expected generalise, which was my reading, not the code.
  Case 'CLEAN TWIN' 'with no RED stage, the least evidence flowing is the weakest link' ($w1 -eq 'tune, with 1 flowing') $w1
  $w2 = Get-WeakestLink -Stages $s2
  Case 'CLEAN TWIN' 'a RED stage outranks a stage with less evidence' ($w2 -like 'perceive - RED:*') $w2
  $onlyInc = @((New-Stage 'incidents' 'x' 'o' 'l' -1 'ok'), (New-Stage 'tune' 'x' 'o' 'l' 7 'ok'))
  Case 'MUST NOT FIRE' 'the incident queue never wins the weakest link' ((Get-WeakestLink -Stages $onlyInc) -eq 'tune, with 7 flowing') (Get-WeakestLink -Stages $onlyInc)
  $src = [IO.File]::ReadAllText($MyInvocation.MyCommand.Path)
  # Needle by concatenation, so this case can never find its own spelling. The first draft built six dashes
  # against a comment of eight, found nothing, and threw on Substring(-1) - a guard that crashed instead of failing.
  $liveAt = $src.LastIndexOf('# ----' + '---- live')
  Case 'CLEAN TWIN' 'the live section this case inspects is found' ($liveAt -gt 0) "$liveAt"
  $live = if ($liveAt -gt 0) { $src.Substring($liveAt) } else { '' }
  $writers = @('WriteAll' + 'Text', 'Set-' + 'Content', 'Out-' + 'File', 'Add-' + 'Content', 'Write-' + 'TcEvent', '-Wr' + 'ite', '-Acc' + 'ept')
  $hits = @($writers | Where-Object { $live.Contains($_) })
  Case 'MUST NOT FIRE' 'the reading path writes nothing and calls no source in a writing mode' ($liveAt -gt 0 -and $hits.Count -eq 0) ($hits -join ',')

  Write-Output ''
  if ($fails.Count) {
    Write-Output ("brain-report selftest: {0} FAILED of {1}" -f $fails.Count, $ran.Count)
    $fails | ForEach-Object { Write-Output "  $_" }
    Exit-Guard -Name 'ESTATE-BRAIN-REPORT-SELFTEST' -Code 1 -Summary "failed=$($fails.Count) cases=$($ran.Count)"
  }
  Write-Output ("brain-report selftest: {0} of {0} cases pass" -f $ran.Count)
  Exit-Guard -Name 'ESTATE-BRAIN-REPORT-SELFTEST' -Code 0 -Summary "cases=$($ran.Count)"
}

# -------- live
$sw = [Diagnostics.Stopwatch]::StartNew()
$now = Get-Date
$since = $now.AddDays(-7).ToString('yyyy-MM-dd')
$jobs = @(
  [pscustomobject]@{ Exe = $PY; ArgList = @((Join-Path $repo 'graph\learning\learning_status.py'), '--json') }
  [pscustomobject]@{ Exe = $PY; ArgList = @((Join-Path $repo 'graph\learning\verdict_expiry.py'), '--json') }
  [pscustomobject]@{ Exe = $PY; ArgList = @((Join-Path $repo 'graph\pipeline\scorecard_query.py'), '--since', $since) }
  [pscustomobject]@{ Exe = $PSEXE; ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $repo 'grocery\tune-alert-rearm.ps1'), '-Json', '-DryRun') }
  [pscustomobject]@{ Exe = $PSEXE; ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $repo 'ops\audit-conclusion-currency.ps1'), '-Json', '-ReportOnly') }
  [pscustomobject]@{ Exe = $PSEXE; ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $repo 'ops\incident-trigger.ps1'), '-Json') }
)
$resR = Invoke-TcParallel -Jobs $jobs -Concurrency 6 -TimeoutSec 60
$res = @($resR)
$S = @{
  learning    = $(if ($res[0].ExitCode -eq 0) { Get-JsonLine -Out $res[0].Out } else { $null })
  expiry      = $(if ($res[1].ExitCode -eq 0) { Get-JsonLine -Out $res[1].Out } else { $null })
  scorecard   = $(if ($res[2].ExitCode -eq 0) { Get-JsonLine -Out $res[2].Out } else { $null })
  tuning      = Get-JsonLine -Out $res[3].Out -Prefix 'alert-tuning-json:'
  conclusions = Get-JsonLine -Out $res[4].Out -Prefix 'conclusion-currency-json:'
  incidents   = Get-JsonLine -Out $res[5].Out -Prefix 'incident-json:'
}
$nowE = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$b72R = Read-TcEvents -SinceEpoch ($nowE - 3 * 86400)
$b72 = @($b72R)
$b24 = @($b72 | Where-Object { [long]$_.t -ge ($nowE - 86400) })
$stR = Get-EstateStages -S $S -Bus24 $b24.Count -Bus72 $b72.Count -Now $now
$stages = @($stR)
$weakest = Get-WeakestLink -Stages $stages
$known = @($S.Values | Where-Object { $null -ne $_ }).Count
$red = @($stages | Where-Object { $_.floor -eq 'RED' }).Count
$pageR = Format-EstateReport -Stages $stages -Weakest $weakest
foreach ($l in @($pageR)) { Write-Output $l }
Write-Output ''
Write-Output ("SCOPE OF A CLEAN REPORT: UNSOUND. A green floor says a producer wrote something inside its window, never that it was right. {0} of 6 sources read in {1:N1}s." -f $known, $sw.Elapsed.TotalSeconds)
if ($Json) {
  $doc = [ordered]@{ weakest = $weakest; red = $red; sources = $known; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); stages = @($stages) }
  'brain-report-json: ' + ($doc | ConvertTo-Json -Depth 5 -Compress)
}
$code = if ($known -eq 0) { 3 } else { 0 }
Exit-Guard -Name 'ESTATE-BRAIN-REPORT' -Code $code -Summary ("stages={0} red={1} sources={2} seconds={3:N1}" -f $stages.Count, $red, $known, $sw.Elapsed.TotalSeconds)
