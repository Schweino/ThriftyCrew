<#
  ruled-step-lib.ps1 - a RULED BUILD STEP as the owner of a family of recurring alerts.

  WHY (design/PLAN-weekly-root-families-2026-10-02.md Phase 1, Brad's ruling D3 A, 2026-10-02). Steps 8, 9 and 11
  of design/PLAN-zero-alert-days-remainder-2026-09-24.md were ruled on 2026-09-10 and none had moved 22 days later,
  while triage minted 81 residual items in 15 days, most of them symptoms those steps prevent, against a weekly lane
  that works about 4 a week. Two things follow, and this file is the one copy of both:
    1. A residual whose family a ruled, unbuilt step already owns is recorded against that step
       (leaves_open_followup: "step:<plan>#<label>") instead of minted as a queue item. Test-StepOwner decides
       whether such an owner resolves: the plan exists, its Status reads RULED or under way (ops/plan_citation.py's
       rule, asked through --plan-state, never copied here), its heading for that label exists, and the heading
       does not carry '[DONE'.
    2. A ruled step that is not under way 14 days after its ruling, while alerts it prevents keep arriving, pages
       once a week (grocery/audit-alert-census.ps1). That is the detective action this program lacked.

  THE MAP is grocery/ruled-steps.json: each step's ref, ruling date, the files whose existence shows its build
  started, and the census types it prevents. A type belongs to ONE step, so a total over steps never counts an
  alert twice.

  ATTRIBUTION reads three sources, each over the same window:
    - census rows (grocery/out/alert-census.jsonl) whose type starts with one of the step's type prefixes;
    - queue items closed with disposition owned-by-step whose notes name 'step:<ref>' (Phase 1 step 2 re-homes);
    - triage plan items (grocery/triage-plans/plan-<date>*.json) whose leaves_open_followup is 'step:<ref>' (the
      residuals D3 stops minting).
  WHEN THE PRODUCER STOPS (rule og-13): if alerts were raised in the last 7 days and NO step had one attributed, the
  attribution is broken (a renamed type, a moved file), not the program quiet. Get-RuledStepBlind says so, and the
  census prints BLIND and pages it, never a clean line.

  SCOPE OF A CLEAN REPORT: UNSOUND. A step with no type prefixes, or a family whose alerts arrive under a type
  nobody mapped, is never attributed anything, so it can never read stalled. COMPLETE for what it reports: a stalled
  step is one the map says is ruled, whose evidence files do not exist, past 14 days, with attributed alerts.
  Self-test: powershell -NoProfile -File grocery\test-ruled-step-lib.ps1
#>

$script:RuledStepStallDays = 14   # Brad's plan text: "not under way 14 days after its ruling". At 14 it fires.
$script:RuledStepBlindDays = 7    # og-13: 7 days of raised alerts with nothing attributed is a broken attribution

function Read-RuledSteps {
  <# The map, or why it cannot be read. Never throws. #>
  param([string]$File)
  if (-not $File -or -not (Test-Path -LiteralPath $File -PathType Leaf)) { return [pscustomobject]@{ ok = $false; steps = @(); why = "no step map at $File" } }
  # [IO.File] resolves a relative path against the PROCESS directory, not PowerShell's location, so a relative -File
  # read another checkout's copy (or none) and attributed 0 while Test-Path above said the file was there.
  $File = (Resolve-Path -LiteralPath $File).ProviderPath
  try { $doc = [IO.File]::ReadAllText($File) | ConvertFrom-Json } catch { return [pscustomobject]@{ ok = $false; steps = @(); why = "step map unreadable: $($_.Exception.Message)" } }
  if (-not $doc -or -not $doc.PSObject.Properties['steps']) { return [pscustomobject]@{ ok = $false; steps = @(); why = 'step map has no steps array' } }
  $steps = @($doc.steps | Where-Object { $_ })
  foreach ($s in $steps) {
    if (-not ([string]$s.ref -match '^[^#]+#.+$')) { return [pscustomobject]@{ ok = $false; steps = @(); why = "step ref '$([string]$s.ref)' is not <plan>#<label>" } }
    $d = [datetime]::MinValue
    if (-not [datetime]::TryParseExact([string]$s.ruled, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$d)) { return [pscustomobject]@{ ok = $false; steps = @(); why = "step $([string]$s.ref) has no ruled date in YYYY-MM-DD" } }
  }
  return [pscustomobject]@{ ok = $true; steps = $steps; why = '' }
}

function ConvertTo-StepLabel([string]$Text) {
  <# A heading's leading label ('Phase 5', 'R18', '8') -> its ref form ('phase-5', 'r18', '8'). #>
  return (($Text.Trim().ToLowerInvariant()) -replace '\s+', '-')
}

function Get-PlanStepHeading {
  <# The heading line in a plan whose label is $Label, or $null. A label is the heading's text up to its first '.'
     or ':' followed by a space ('### 8. Ruling 2' -> '8'; '### Stage 2: enforce' -> 'stage-2'). #>
  param([string]$PlanText, [string]$Label)
  $want = ConvertTo-StepLabel $Label
  foreach ($line in ($PlanText -split "`r?`n")) {
    if ($line -match '^#{2,4}\s+(.+?)[.:]\s') {
      if ((ConvertTo-StepLabel $Matches[1]) -eq $want) { return $line }
    }
  }
  return $null
}

function Get-PlanStateFromCitation {
  <# ops/plan_citation.py --plan-state: 'under-way', 'finished', 'not-yet', 'unclassified', 'no-status', 'missing',
     or 'unknown' when the child could not answer. The one copy of the Status rule is in that file. #>
  param([string]$PlanFull, [string]$RepoRoot)
  $py = 'C:\Codex\Python312\python.exe'
  $script = Join-Path $RepoRoot 'ops\plan_citation.py'
  if (-not (Test-Path -LiteralPath $script)) { return 'unknown' }
  if (-not (Get-Command Invoke-Native -ErrorAction SilentlyContinue)) { . (Join-Path $RepoRoot 'grocery\native-lib.ps1') }
  $r = Invoke-Native $py $script --plan-state $PlanFull
  $line = @($r.Output | Where-Object { [string]$_ -match '^PLAN-STATE ' } | Select-Object -Last 1)
  if ($line.Count -eq 0) { return 'unknown' }
  if ([string]$line[0] -match '^PLAN-STATE (\S+)') { return $Matches[1] }
  return 'unknown'
}

function Test-StepOwner {
  <# '' when 'step:<plan>#<label>' names a step that may own a residual, else why not.
     $StateOf: scriptblock (planFull) -> plan state; defaults to Get-PlanStateFromCitation. #>
  param([string]$Owner, [string]$RepoRoot, [scriptblock]$StateOf = $null)
  if (-not ($Owner -match '^step:\s*([^#]+)#(.+)$')) { return "'$Owner' is not step:<repo-relative plan>#<step label>" }
  $plan = $Matches[1].Trim(); $label = $Matches[2].Trim()
  if ([IO.Path]::IsPathRooted($plan)) { return "step owner '$Owner' must name a repo-relative plan, so the step it trusts is one the repo versions" }
  $full = Join-Path $RepoRoot $plan
  if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return "step owner '$Owner' resolves to nothing - no plan at $plan" }
  $full = (Resolve-Path -LiteralPath $full).ProviderPath   # [IO.File] below reads relative to the process, not PS
  $state = if ($StateOf) { & $StateOf $full } else { Get-PlanStateFromCitation $full $RepoRoot }
  if ($state -ne 'under-way') {
    $say = switch ($state) {
      'finished'     { 'its Status reads DONE (or another finished word): a finished plan owns no new work' }
      'not-yet'      { 'its Status reads PROPOSED (or another not-yet word): an unruled step owns nothing' }
      'no-status'    { 'it has no Status line, so nothing says it is ruled' }
      'unclassified' { 'its Status line carries no status word ops/plan_citation.py knows' }
      'missing'      { 'the plan could not be read' }
      'unknown'      { 'ops/plan_citation.py --plan-state could not answer, so the ruling is unproven' }
      default        { throw "unknown plan state: $state" }
    }
    return "step owner '$Owner' is refused - $say. Only a plan whose Status reads RULED or under way may own a residual."
  }
  $heading = Get-PlanStepHeading ([IO.File]::ReadAllText($full)) $label
  if (-not $heading) { return "step owner '$Owner' names no step - $plan has no heading labelled '$label' (a label is the heading text before its first '.' or ':')" }
  if ($heading -match '\[DONE') { return "step owner '$Owner' is refused - the step's heading reads [DONE: a finished step owns no new work, so this residual is live work for the queue" }
  return ''
}

function Test-RuledStepUnderWay {
  <# True when any of the step's evidence files exists under $RepoRoot. #>
  param($Step, [string]$RepoRoot)
  foreach ($f in @($Step.under_way_evidence)) {
    if ([string]$f -and (Test-Path -LiteralPath (Join-Path $RepoRoot ([string]$f)) -PathType Leaf)) { return $true }
  }
  return $false
}

function Test-RuledStepTypeMatch {
  param($Step, [string]$Type)
  foreach ($p in @($Step.type_prefixes)) { if ([string]$p -and $Type.StartsWith([string]$p, [StringComparison]::Ordinal)) { return $true } }
  return $false
}

function Get-RuledStepAttribution {
  <# Pure. Per step: census alerts, owned-by-step closes and triage-plan step owners inside the $Days ending $Today.
     $PlanItems: objects { date = 'YYYY-MM-DD'; leaves_open_followup = '...' } read from triage plans by the caller. #>
  param($Steps, $CensusRows, $QueueItems, $PlanItems, [datetime]$Today, [int]$Days)
  $start = $Today.AddDays(-($Days - 1)).ToString('yyyy-MM-dd'); $end = $Today.ToString('yyyy-MM-dd')
  $inWin = { param([string]$d) ($d.Length -ge 10) -and ($d.Substring(0, 10) -ge $start) -and ($d.Substring(0, 10) -le $end) }
  $total = 0
  foreach ($r in @($CensusRows)) { if ($r -and (& $inWin ([string]$r.date))) { $total += [int]$r.alerts } }
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($s in @($Steps)) {
    $ref = [string]$s.ref; $census = 0; $owned = 0; $planOwned = 0
    foreach ($r in @($CensusRows)) {
      if ($r -and (& $inWin ([string]$r.date)) -and (Test-RuledStepTypeMatch $s ([string]$r.type))) { $census += [int]$r.alerts }
    }
    foreach ($q in @($QueueItems)) {
      if (-not $q -or [string]$q.disposition -ne 'owned-by-step') { continue }
      if (-not (& $inWin ([string]$q.resolved_ts))) { continue }
      if (([string]$q.notes).IndexOf('step:' + $ref, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $owned++ }
    }
    foreach ($p in @($PlanItems)) {
      if (-not $p -or -not (& $inWin ([string]$p.date))) { continue }
      $fu = ([string]$p.leaves_open_followup).Trim() -replace '^step:\s*', 'step:'
      if ([string]::Equals($fu, 'step:' + $ref, [StringComparison]::OrdinalIgnoreCase)) { $planOwned++ }
    }
    $out.Add([pscustomobject]@{ ref = $ref; census = $census; owned = $owned; plan_owned = $planOwned; attributed = ($census + $owned + $planOwned) })
  }
  return [pscustomobject]@{ start = $start; end = $end; total_alerts = $total; steps = $out.ToArray() }
}

function Get-RuledStepVerdicts {
  <# Pure apart from the evidence-file check. One row per step: days since ruling, under way, attributed, stalled. #>
  param($Steps, $Attribution, [datetime]$Today, [string]$RepoRoot)
  $byRef = @{}; foreach ($a in @($Attribution.steps)) { $byRef[[string]$a.ref] = $a }
  foreach ($s in @($Steps)) {
    $ruled = [datetime]::ParseExact([string]$s.ruled, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $days = [int]($Today.Date - $ruled.Date).TotalDays
    $uw = Test-RuledStepUnderWay $s $RepoRoot
    $a = $byRef[[string]$s.ref]; $n = if ($a) { [int]$a.attributed } else { 0 }
    [pscustomobject]@{
      ref = [string]$s.ref; family = [string]$s.family; ruled = [string]$s.ruled; days = $days; under_way = $uw
      attributed = $n; census = $(if ($a) { $a.census } else { 0 }); owned = $(if ($a) { $a.owned + $a.plan_owned } else { 0 })
      stalled = ((-not $uw) -and ($days -ge $script:RuledStepStallDays) -and ($n -gt 0))
    }
  }
}

function Get-RuledStepBlind {
  <# og-13. '' when attribution is plausibly working, else why it reads BLIND: alerts were raised in the last 7 days
     and no step had any attributed. #>
  param($Steps, $CensusRows, [datetime]$Today)
  $a = Get-RuledStepAttribution $Steps $CensusRows @() @() $Today $script:RuledStepBlindDays
  $att = 0; foreach ($s in @($a.steps)) { $att += [int]$s.census }
  if ($a.total_alerts -gt 0 -and $att -eq 0) {
    return ("{0} alert(s) were raised {1}..{2} and the census attributed 0 to every ruled step: a type was renamed or the map no longer matches, so a stalled step cannot be seen" -f $a.total_alerts, $a.start, $a.end)
  }
  return ''
}

function Read-TriagePlanStepOwners {
  <# Triage plan items whose leaves_open_followup is a step owner, dated by the plan's file name. #>
  param([string]$PlanDir)
  $out = New-Object System.Collections.Generic.List[object]
  if (-not $PlanDir -or -not (Test-Path -LiteralPath $PlanDir)) { return , $out.ToArray() }
  foreach ($f in @(Get-ChildItem -LiteralPath $PlanDir -Filter 'plan-*.json' -File)) {
    if (-not ($f.Name -match '^plan-(\d{4}-\d{2}-\d{2})')) { continue }
    $d = $Matches[1]
    $txt = [IO.File]::ReadAllText($f.FullName)
    if ($txt.IndexOf('"step:', [StringComparison]::Ordinal) -lt 0) { continue }
    try { $doc = $txt | ConvertFrom-Json } catch { continue }
    $items = $doc.items
    foreach ($i in @($items)) {
      if ($i -and ([string]$i.leaves_open_followup) -match '^\s*step:') { $out.Add([pscustomobject]@{ date = $d; leaves_open_followup = [string]$i.leaves_open_followup; queue_id = [string]$i.queue_id }) }
    }
  }
  return , $out.ToArray()
}
