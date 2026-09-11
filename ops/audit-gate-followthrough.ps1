<#
  audit-gate-followthrough.ps1 - a gate that keeps going red: did anything durable follow?

  WS 10a of design\PLAN-brain-v2-2026-09-09.md.

  WHY IT EXISTS. CLAUDE.md says, as a standing rule for anything that ships, "when a defect recurs, the
  durable fix is a memory, a gate or a command - not just the repair." Until 2026-09-09 a red gate left
  NO RECORD at all - a terminal line and a blocked push - so the rule was a habit nobody could audit.
  ops\run-gates.ps1 now writes a `gate-red` event to the bus (WS 1b). This reads those events back and
  asks the one question the rule is about: a gate red more than once inside the window - has anything
  been committed since that touches the gate, or whose message names it?

  *** A REPORT, NOT A RATCHET, AND THAT DEPARTS FROM THE PLAN FOR A MEASURED REASON. *** The plan asked
  for a ratchet on "RED WITHOUT A FIXTURE". On the day this was written the bus already held two red
  events naming ops\audit-cross-module-reach.ps1, and both were the gate working correctly: each time it
  caught a NEW file carrying a path literal, and each time the fix belonged in that file, not in the
  gate. A ratchet on this proxy would have been red on day one against correct behaviour, which is the
  pattern `.claude\rules\ops-and-gates.md` forbids because it teaches people to ignore red. The proxy
  cannot tell "the gate caught the same class again" from "the gate is flaky" - so it names CANDIDATES
  for a person, in the morning digest, and never fails anything.

  WHAT A CANDIDATE IS NOT. It is not a defect in the gate. Repeated red on one gate is exactly what a
  gate is for; the question is only whether the RECURRING CLASS behind it has earned something more
  durable than a series of one-off repairs - a reflex row, a memory, a sharper message in the gate.

  SCOPE OF A CLEAN REPORT: UNSOUND. It sees only reds that reached the bus (a --no-verify push writes
  none, and a gate run with the bus unwritable writes none), and "a commit names the gate" is a proxy
  for "something durable followed" that a person has to judge.

  EXIT CODES: 0 always (a report), 3 when -Json cannot read the bus at all. -Json prints one
  `followthrough-json:` line before the completion marker, for ops\brain-digest.ps1.
#>
[CmdletBinding()]
param([switch]$SelfTest, [switch]$Json, [int]$WindowDays = 14)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\event-bus.ps1')

# More than once is a recurrence; once is an event. Two-way, first plausible value, and it only ever
# decides what gets PRINTED, so a wrong value costs a line a person reads.
$MIN_REDS = 2

function Get-GateReds {
  <# @{ <gate> = @{ Reds; Days; FirstT } } over gate-red events inside the window. PURE.
     A gate named twice in ONE event counts once: run-gates lists a gate in both its discovery and its
     static pass, so the raw list repeats names, and counting those would invent a recurrence. #>
  param($Events, [long]$NowEpoch, [int]$WindowDays)
  $since = $NowEpoch - ($WindowDays * 86400)
  $out = @{}
  foreach ($e in @($Events)) {
    if (-not $e -or [string]$e.kind -ne 'gate-red') { continue }
    $t = 0L; try { $t = [long]$e.t } catch { $t = 0L }
    if ($t -lt $since) { continue }
    $seen = @{}
    foreach ($g in @($e.gates)) {
      $name = [string]$g
      if (-not $name -or $seen.ContainsKey($name)) { continue }
      $seen[$name] = $true
      if (-not $out.ContainsKey($name)) { $out[$name] = @{ Reds = 0; Days = @{}; FirstT = $t } }
      $out[$name].Reds++
      $out[$name].Days[[DateTimeOffset]::FromUnixTimeSeconds($t).UtcDateTime.ToString('yyyy-MM-dd')] = $true
      if ($t -lt $out[$name].FirstT) { $out[$name].FirstT = $t }
    }
  }
  return $out
}

function Get-FollowupCommits {
  <# [hash] committed since $SinceIso that touch the gate file or name it in the message. #>
  param([string]$Gate, [string]$SinceIso, [string]$Root)
  $hashes = @{}
  # 'Continue' around the redirects: under 'Stop' one git stderr line threw into the catch below and the gate read
  # as having no follow-up commits at all (grocery\test-native-stderr-eap.ps1).
  $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    $a = @(& git -C $Root log ("--since=" + $SinceIso) --format=%h -- $Gate 2>$null)
    foreach ($h in $a) { if ("$h".Trim()) { $hashes["$h".Trim()] = $true } }
    $leaf = [IO.Path]::GetFileNameWithoutExtension($Gate)
    $b = @(& git -C $Root log ("--since=" + $SinceIso) --format=%h ("--grep=" + $leaf) 2>$null)
    foreach ($h in $b) { if ("$h".Trim()) { $hashes["$h".Trim()] = $true } }
  } catch { } finally { $ErrorActionPreference = $prevEap }
  return ,@($hashes.Keys)
}

function Get-Candidates {
  <# [@{ Gate; Reds; Days; FirstIso; Followups }] for gates red at least $MIN_REDS times. PURE apart
     from the injected $Followup scriptblock, so the fixtures never touch git. #>
  param($Reds, [scriptblock]$Followup)
  $out = @()
  foreach ($g in ($Reds.Keys | Sort-Object)) {
    $r = $Reds[$g]
    if ($r.Reds -lt $MIN_REDS) { continue }
    $iso = [DateTimeOffset]::FromUnixTimeSeconds([long]$r.FirstT).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $fuRaw = & $Followup $g $iso
    $fu = @($fuRaw)
    $out += @{ Gate = $g; Reds = $r.Reds; Days = $r.Days.Count; FirstIso = $iso; Followups = $fu }
  }
  return ,$out
}

if ($SelfTest) {
  $fails = @(); $ran = @()
  function Case {
    param([string]$Label, [string]$Name, [bool]$Ok, [string]$Detail = '')
    $script:ran += $Name
    if (-not $Ok) { $script:fails += "$Label $Name" }
    '  {0,-14} {1,-58} {2}' -f $Label, $Name, $(if ($Ok) { 'ok' } else { "FAIL $Detail" })
  }
  $now = 1789100000L
  $ev = @(
    [pscustomobject]@{ kind = 'gate-red'; t = ($now - 3600); gates = @('ops\a.ps1', 'ops\a.ps1', 'ops\b.ps1') }
    [pscustomobject]@{ kind = 'gate-red'; t = ($now - 1800); gates = @('ops\a.ps1') }
    [pscustomobject]@{ kind = 'gate-red'; t = ($now - (40 * 86400)); gates = @('ops\c.ps1', 'ops\c.ps1') }
    [pscustomobject]@{ kind = 'gate-red'; t = ($now - (41 * 86400)); gates = @('ops\c.ps1') }
    [pscustomobject]@{ kind = 'chain-complete'; t = ($now - 60) }
  )
  $reds = Get-GateReds -Events $ev -NowEpoch $now -WindowDays 14
  Case 'MUST FIRE' 'a gate red in two events inside the window counts 2' ($reds['ops\a.ps1'].Reds -eq 2) ("a=" + $reds['ops\a.ps1'].Reds)
  Case 'MUST NOT FIRE' 'a gate named twice in ONE event counts once' ($reds['ops\b.ps1'].Reds -eq 1)
  Case 'MUST NOT FIRE' 'reds older than the window are not counted' (-not $reds.ContainsKey('ops\c.ps1'))
  Case 'MUST NOT FIRE' 'a non-red event contributes nothing' ($reds.Count -eq 2) ("n=" + $reds.Count)

  $none = { param($g, $iso) @() }
  $candRaw = Get-Candidates -Reds $reds -Followup $none
  $cand = @($candRaw)
  Case 'MUST FIRE' 'a twice-red gate with no follow-up is a CANDIDATE' `
    (($cand.Count -eq 1) -and ($cand[0].Gate -eq 'ops\a.ps1') -and (@($cand[0].Followups).Count -eq 0)) ("n=" + $cand.Count)
  Case 'MUST NOT FIRE' 'a once-red gate is never a candidate' (-not ($cand | Where-Object { $_.Gate -eq 'ops\b.ps1' }))
  $some = { param($g, $iso) @('abc1234') }
  $c2Raw = Get-Candidates -Reds $reds -Followup $some
  $c2 = @($c2Raw)
  Case 'CLEAN TWIN' 'a follow-up commit is reported alongside, not hidden' `
    (($c2.Count -eq 1) -and (@($c2[0].Followups) -contains 'abc1234'))
  Case 'CLEAN TWIN' 'the first-red time renders as UTC with a Z' ($cand[0].FirstIso -match 'Z$') $cand[0].FirstIso
  $emptyRaw = Get-GateReds -Events @() -NowEpoch $now -WindowDays 14
  # MUST NOT FIRE, not CLEAN TWIN: it asserts that nothing was found. Mislabelled on the first write and
  # caught by ops\audit-fixture-vocabulary.ps1 at the pre-push gate - CLEAN TWIN is reserved for an
  # adjacent behaviour that still WORKS, a positive assertion.
  Case 'MUST NOT FIRE' 'an empty bus yields no reds, never a crash' ($emptyRaw.Count -eq 0)
  ''
  if ($fails.Count) {
    "audit-gate-followthrough selftest: $($fails.Count) FAILED of $($ran.Count)"
    $fails | ForEach-Object { "  $_" }
    Exit-Guard -Name 'GATE-FOLLOWTHROUGH-SELFTEST' -Code 1 -Summary "failed=$($fails.Count) of $($ran.Count)"
  }
  "audit-gate-followthrough selftest: $($ran.Count) of $($ran.Count) cases pass"
  Exit-Guard -Name 'GATE-FOLLOWTHROUGH-SELFTEST' -Code 0 -Summary "cases=$($ran.Count)"
}

Invoke-Guard -Name 'GATE-FOLLOWTHROUGH' -Body {
  $busPath = Get-TcEventBusPath
  if (-not (Test-Path -LiteralPath $busPath)) {
    'gate-followthrough: NO EVIDENCE - the event bus does not exist yet, so no red gate has been recorded.'
    'That is an empty record, not a clean one.'
    if ($Json) { 'followthrough-json: {"known": false, "candidates": 0, "gates_red": 0}' }
    Exit-Guard -Name 'GATE-FOLLOWTHROUGH' -Code $(if ($Json) { 0 } else { 0 }) -Summary 'evidence=none'
  }
  $evRaw = Read-TcEvents
  $events = @($evRaw)
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $reds = Get-GateReds -Events $events -NowEpoch $now -WindowDays $WindowDays
  $fu = { param($g, $iso) Get-FollowupCommits -Gate $g -SinceIso $iso -Root $repo }
  $candRaw = Get-Candidates -Reds $reds -Followup $fu
  $cand = @($candRaw)
  $bare = @($cand | Where-Object { @($_.Followups).Count -eq 0 })

  "gate-followthrough: $($events.Count) bus event(s), $($reds.Count) gate(s) red in the last $WindowDays day(s), $($cand.Count) red at least $MIN_REDS times."
  foreach ($c in $cand) {
    $f = @($c.Followups)
    $state = if ($f.Count) { "followed by $($f.Count) commit(s): $($f -join ', ')" } else { 'NOTHING committed since that touches or names it' }
    '  {0,-40} red {1}x over {2} day(s) since {3}; {4}' -f $c.Gate, $c.Reds, $c.Days, $c.FirstIso, $state
  }
  if ($bare.Count) {
    ''
    '  A candidate is NOT a broken gate. It is a recurring red whose class has not yet earned anything'
    '  more durable than a series of one-off repairs. Worth a look: does it deserve a reflex row, a'
    '  memory, or a sharper message in the gate itself?'
  }
  ''
  'SCOPE OF A CLEAN REPORT: UNSOUND. A --no-verify push writes no red, and "a commit names the gate" is a proxy a person judges.'
  if ($Json) {
    $obj = @{ known = $true; candidates = $bare.Count; gates_red = $reds.Count; recurring = $cand.Count
              oldest_first_red = $(if ($bare.Count) { ($bare | Sort-Object FirstIso | Select-Object -Last 1).FirstIso } else { $null }) }
    'followthrough-json: ' + ($obj | ConvertTo-Json -Compress)
  }
  Exit-Guard -Name 'GATE-FOLLOWTHROUGH' -Code 0 -Summary ("reds={0} recurring={1} candidates={2}" -f $reds.Count, $cand.Count, $bare.Count)
}
