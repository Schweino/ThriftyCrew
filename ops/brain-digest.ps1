<#
  brain-digest.ps1 - one morning page: what the night moved, what went red, and what is waiting.

  WS 5d of design\PLAN-brain-v2-2026-09-09.md.

  WHY IT EXISTS. Every judgement queue in this system drains only when Brad happens to sit down
  at it. Measured 2026-09-09: the graph's Stage 1 has produced 60 alias proposals since 08-21 and
  Stage 2 has no scheduler; the gold scoreboard was 19 days stale; the nightly pass had gone RED
  and told nobody. None of that is a hard problem - it is that nothing puts the queues in front
  of a person once a day with their ages on them.

  *** EVERY QUEUE GETS A FLOOR, AND THE FLOOR IS THE POINT. *** `.claude\rules\ops-and-gates.md`,
  backlog I80: every threshold in this estate is an UPPER bound, so not one of them can fire on
  nothing happening. A queue nobody drains produces no alert of any kind - it just gets older. So
  each row here carries the age of its OLDEST unruled item and the number of days at which that
  is a problem, and the digest says which rows are over.

  *** IT NEVER BLOCKS AND NEVER RULES. *** It reads, it mails, it exits 0 even when every queue
  is overdue. Accepting a draft, ruling on a cluster, clearing a hold: all a person's call. A
  digest that could block would be a gate, and a gate on a judgement queue is a gate that is red
  on day one for as long as somebody is on holiday.

  *** COST-IF-UNDRAINED IS WRITTEN DOWN PER QUEUE. *** A row whose consequence nobody can state
  is a row nobody will act on, and the estate already writes this for its watched files
  (grocery\expected-automations.json's queues block). Same discipline.

  SCOPE OF A CLEAN REPORT: UNSOUND. A queue whose tool cannot run is reported as UNKNOWN, never
  as empty. "Nothing waiting" and "the thing that counts what is waiting is broken" are the same
  bytes without that distinction, and telling them apart is most of what this estate's machinery
  is for.

  EXIT CODES: 0 always, unless -SelfTest fails. Overdue queues are the CONTENT, not the verdict.
#>
[CmdletBinding()]
param([switch]$SelfTest, [switch]$Alert, [switch]$Quiet)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\event-bus.ps1')
# A HIDDEN SCHEDULED TASK OWES A RUN RECORD (backlog E29, gated by
# ops\audit-run-log-claims.ps1). A digest that died at 06:45 and wrote nothing would be
# indistinguishable from a quiet morning - which is the failure this page exists to end.
. (Join-Path $repo 'grocery\run-log-lib.ps1')

$SKILLS = Join-Path $env:USERPROFILE '.claude\skills'
$CLAUDE = Join-Path $env:USERPROFILE '.claude'
$PY = 'C:\Codex\Python312\python.exe'

function Get-QueueRow {
  <# One queue's state. Returns @{ Name; Count; AgeDays; Floor; Cost; Known }.
     `Known=$false` means the counter could not run, which is NOT the same as zero. #>
  param([string]$Name, [int]$Floor, [string]$Cost, [scriptblock]$Count)
  $row = @{ Name = $Name; Count = 0; AgeDays = -1; Floor = $Floor; Cost = $Cost; Known = $false }
  try {
    $r = & $Count
    if ($null -ne $r) {
      $row.Count = [int]$r.Count
      $row.AgeDays = [double]$r.AgeDays
      $row.Known = $true
    }
  } catch { }
  return $row
}

function Get-JsonlAge {
  <# @{ Count; AgeDays } over a .jsonl, by a predicate and a timestamp field.
     A file that is absent returns 0 items and age -1, never a fresh age. #>
  param([string]$Path, [scriptblock]$Where, [string]$TsField = 't')
  $n = 0; $oldest = 0
  if (-not (Test-Path -LiteralPath $Path)) { return @{ Count = 0; AgeDays = -1 } }
  foreach ($line in [IO.File]::ReadAllLines($Path)) {
    if (-not "$line".Trim()) { continue }
    $d = $null
    try { $d = $line | ConvertFrom-Json } catch { continue }
    if (-not $d) { continue }
    if ($Where -and -not (& $Where $d)) { continue }
    $n++
    $t = 0
    try { $t = [int]$d.$TsField } catch { $t = 0 }
    if ($t -gt 0 -and ($oldest -eq 0 -or $t -lt $oldest)) { $oldest = $t }
  }
  $age = -1
  if ($oldest -gt 0) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $age = [math]::Round(($now - $oldest) / 86400.0, 1)
  }
  return @{ Count = $n; AgeDays = $age }
}

function Get-SleepNight {
  <# What last night's pass did. @{ When; Red; Failed; Steps; Text } #>
  param([string]$Path)
  $o = @{ When = 'never'; Red = $false; Failed = 0; Steps = 0; Text = '' }
  if (-not (Test-Path -LiteralPath $Path)) { return $o }
  $txt = [IO.File]::ReadAllText($Path)
  $o.Text = $txt
  $m = [regex]::Match($txt, '# Recall sleep, ([0-9\-]+ [0-9:]+)')
  if ($m.Success) { $o.When = $m.Groups[1].Value }
  $o.Red = $txt.Contains('A STEP FAILED')
  $rows = [regex]::Matches($txt, '(?m)^\| [a-z][^|]*\| (\d+) \|')
  $o.Steps = $rows.Count
  foreach ($r in $rows) { if ([int]$r.Groups[1].Value -ne 0) { $o.Failed++ } }
  return $o
}

function Format-Digest {
  <# The page, as text. PURE - takes the gathered state, returns the string, so the
     fixtures can drive the wording without a filesystem or a mailer. #>
  param($Night, $Queues, [string]$Weakest, $Events, [string[]]$Estate = @())
  $out = New-Object Collections.Generic.List[string]
  $out.Add("BRAIN DIGEST - $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
  $out.Add('')
  $out.Add("LAST NIGHT")
  if ($Night.When -eq 'never') {
    $out.Add("  the nightly pass has NEVER run on this machine. That is not a quiet night.")
  } else {
    $verdict = if ($Night.Red) { "RED - $($Night.Failed) of $($Night.Steps) step(s) failed" }
               else { "green, $($Night.Steps) step(s)" }
    $out.Add("  $($Night.When)  $verdict")
  }
  $out.Add('')
  $out.Add("WEAKEST LINK")
  $out.Add("  $Weakest")
  $out.Add('')
  # WS 11 (2026-09-10): the estate half of the loop, every stage with its floor, from ops\brain-report.ps1.
  if (@($Estate).Count) {
    foreach ($l in @($Estate)) { $out.Add("  $l") }
    $out.Add('')
  }
  $out.Add("WAITING FOR A RULING")
  $out.Add('  ' + ('{0,-26} {1,6} {2,9} {3,7}  {4}' -f 'queue', 'items', 'oldest', 'floor', 'state'))
  $over = 0
  foreach ($q in $Queues) {
    if (-not $q.Known) {
      $out.Add('  ' + ('{0,-26} {1,6} {2,9} {3,7}  {4}' -f $q.Name, '?', '?', "$($q.Floor)d", 'UNKNOWN - the counter could not run'))
      continue
    }
    $ageTxt = if ($q.AgeDays -lt 0) { '-' } else { "$($q.AgeDays)d" }
    $state = 'ok'
    if ($q.Count -gt 0 -and $q.AgeDays -gt $q.Floor) { $state = 'OVERDUE'; $over++ }
    elseif ($q.Count -eq 0) { $state = 'empty' }
    $out.Add('  ' + ('{0,-26} {1,6} {2,9} {3,7}  {4}' -f $q.Name, $q.Count, $ageTxt, "$($q.Floor)d", $state))
  }
  $out.Add('')
  foreach ($q in $Queues) {
    if ($q.Known -and $q.Count -gt 0 -and $q.AgeDays -gt $q.Floor) {
      $out.Add("  OVERDUE: $($q.Name) - $($q.Cost)")
    }
  }
  if ($over -eq 0) { $out.Add('  Nothing is over its floor.') }
  $out.Add('')
  $out.Add("EVENTS IN THE LAST DAY")
  if (-not $Events -or $Events.Count -eq 0) {
    $out.Add('  none on the bus')
  } else {
    $kinds = @{}
    foreach ($e in $Events) {
      $k = [string]$e.kind
      if (-not $kinds.ContainsKey($k)) { $kinds[$k] = 0 }
      $kinds[$k] = $kinds[$k] + 1
    }
    # DOUBLE PARENTHESES, AND THEY ARE LOAD-BEARING. `$out.Add("..." -f $k, $n)` parses the
    # comma as the METHOD CALL's argument separator, so Add receives two arguments and -f
    # receives one - "Index (zero based) must be greater than or equal to zero". It crashed the
    # first live run to see a non-empty bus; the selftest had only ever passed an empty event
    # list. Same family as the estate rule that a concatenated fixture is three arguments.
    foreach ($k in ($kinds.Keys | Sort-Object)) { $out.Add(("  {0,-22} {1}" -f $k, $kinds[$k])) }
  }
  $out.Add('')
  $out.Add('SCOPE: a queue whose counter could not run reads UNKNOWN, never empty. Nothing here')
  $out.Add('is a ruling and nothing here blocks - the digest asks, a person answers.')
  return ($out -join "`n")
}

# ---------------------------------------------------------------------------
if ($SelfTest) {
  $fails = @(); $ran = @()
  function Case {
    param([string]$Label, [string]$Name, [bool]$Ok, [string]$Detail = '')
    $script:ran += $Name
    if (-not $Ok) { $script:fails += "$Label $Name" }
    '  {0,-14} {1,-58} {2}' -f $Label, $Name, $(if ($Ok) { 'ok' } else { "FAIL $Detail" })
  }

  $night = @{ When = '2026-09-09 04:37'; Red = $true; Failed = 2; Steps = 14; Text = '' }
  $qs = @(
    @{ Name = 'forgetting'; Count = 3; AgeDays = 9.0; Floor = 7; Cost = 'retrieval gets worse'; Known = $true }
    @{ Name = 'clusters';   Count = 0; AgeDays = -1;  Floor = 14; Cost = 'memories stay episodic'; Known = $true }
    @{ Name = 'proposals';  Count = 5; AgeDays = 2.0; Floor = 14; Cost = 'aliases go unpromoted'; Known = $true }
    @{ Name = 'broken';     Count = 0; AgeDays = -1;  Floor = 7;  Cost = 'x'; Known = $false }
  )
  $txt = Format-Digest -Night $night -Queues $qs -Weakest 'learn, with 0 events' -Events @()

  # MUST FIRE: the three things a person has to be able to read off this page.
  Case 'MUST FIRE' 'a RED night is named as red, with its counts' `
    ($txt -match 'RED - 2 of 14') $txt
  Case 'MUST FIRE' 'a queue past its floor is marked OVERDUE' `
    ($txt -match 'forgetting\s+3\s+9d\s+7d\s+OVERDUE')
  Case 'MUST FIRE' 'an overdue queue prints what it COSTS to leave it' `
    ($txt -match 'OVERDUE: forgetting - retrieval gets worse')
  Case 'MUST FIRE' 'the weakest link is on the page' ($txt -match 'learn, with 0 events')

  # MUST NOT FIRE: the three ways this could mislead.
  Case 'MUST NOT FIRE' 'a queue INSIDE its floor is not overdue' `
    (-not ($txt -match 'OVERDUE: proposals'))
  Case 'MUST NOT FIRE' 'an EMPTY queue is empty, never overdue' `
    ($txt -match 'clusters\s+0\s+-\s+14d\s+empty')
  Case 'MUST FIRE' 'a counter that could not run reads UNKNOWN, never empty' `
    ($txt -match 'broken\s+\?\s+\?\s+7d\s+UNKNOWN')

  # CLEAN TWIN: a clean morning still produces a readable page.
  $clean = Format-Digest -Night @{ When = '2026-09-10 04:35'; Red = $false; Failed = 0; Steps = 26 } `
    -Queues @(@{ Name = 'forgetting'; Count = 0; AgeDays = -1; Floor = 7; Cost = 'x'; Known = $true }) `
    -Weakest 'nothing is starving' -Events @()
  Case 'CLEAN TWIN' 'a green night with empty queues says so plainly' `
    (($clean -match 'green, 26') -and ($clean -match 'Nothing is over its floor'))
  Case 'CLEAN TWIN' 'a never-run pass is not reported as a quiet night' `
    ((Format-Digest -Night @{ When = 'never'; Red = $false; Failed = 0; Steps = 0 } -Queues @() `
        -Weakest 'x' -Events @()) -match 'NEVER run')

  # MUST FIRE: a NON-EMPTY event list renders. `[ADDED 2026-09-10]` Every fixture above passed
  # `-Events @()`, so the events loop had never executed, and the first live run to meet a real
  # row on the bus crashed on `$out.Add("..." -f $k, $n)` - the comma split the METHOD call's
  # arguments. A selftest that only ever exercises the empty branch cannot see the other one.
  $ev = @([pscustomobject]@{ kind = 'gate-red' }, [pscustomobject]@{ kind = 'gate-red' },
          [pscustomobject]@{ kind = 'chain-complete' })
  $threwEv = $false; $evTxt = ''
  try { $evTxt = Format-Digest -Night $night -Queues @() -Weakest 'x' -Events $ev } catch { $threwEv = $true }
  Case 'MUST FIRE' 'a non-empty event list renders without throwing' (-not $threwEv) "$($Error[0])"
  Case 'MUST FIRE' 'each event kind is counted on its own line' `
    (($evTxt -match 'gate-red\s+2') -and ($evTxt -match 'chain-complete\s+1')) $evTxt

  # CLEAN TWIN (WS 11): the estate page renders in the digest under the weakest link.
  $estTxt = Format-Digest -Night $night -Queues @() -Weakest 'x' -Events @() -Estate @('THE ESTATE HALF OF THE LOOP', 'perceive    RED    0 bus event(s)')
  Case 'CLEAN TWIN' 'the estate half renders its stages in the digest' `
    (($estTxt -match 'THE ESTATE HALF OF THE LOOP') -and ($estTxt -match 'perceive\s+RED')) $estTxt

  # CLEAN TWIN: the jsonl reader tells absent from fresh.
  $tmp = Join-Path $env:TEMP ("digest-selftest-{0}.jsonl" -f $PID)
  Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
  $a = Get-JsonlAge -Path $tmp -Where { $true }
  Case 'CLEAN TWIN' 'an absent file is 0 items and age -1, never age 0' `
    ($a.Count -eq 0 -and $a.AgeDays -eq -1) ("n=$($a.Count) age=$($a.AgeDays)")
  $old = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - (10 * 86400)
  Set-Content -LiteralPath $tmp -Encoding utf8 -Value @(
    ('{"t": ' + $old + ', "keep": true}'), '{"t": 0, "keep": false}', 'not json')
  $b = Get-JsonlAge -Path $tmp -Where { param($d) $d.keep -eq $true }
  Case 'CLEAN TWIN' 'the predicate filters and the oldest kept row sets the age' `
    ($b.Count -eq 1 -and $b.AgeDays -ge 9.5) ("n=$($b.Count) age=$($b.AgeDays)")
  Case 'CLEAN TWIN' 'a torn line is skipped rather than fatal' ($b.Count -eq 1)
  Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue

  ''
  if ($fails.Count -gt 0) {
    "brain-digest selftest: $($fails.Count) FAILED of $($ran.Count)"
    $fails | ForEach-Object { "  $_" }
    Exit-Guard -Name 'BRAIN-DIGEST-SELFTEST' -Code 1 -Summary "failed=$($fails.Count) of $($ran.Count)"
  }
  "brain-digest selftest: $($ran.Count) of $($ran.Count) cases pass"
  Exit-Guard -Name 'BRAIN-DIGEST-SELFTEST' -Code 0 -Summary "cases=$($ran.Count)"
}

$script:RunLog = if ($SelfTest) { $null } else {
  Start-RunLog -Name 'brain-digest' -OutDir (Join-Path $repo 'ops\out') }
try {
Invoke-Guard -Name 'BRAIN-DIGEST' -Body {
  $night = Get-SleepNight -Path (Join-Path $CLAUDE 'recall-sleep-latest.md')

  # THE WEAKEST LINK comes from recall-brain.py, which owns that judgement. Reading it
  # rather than re-deriving it is deliberate: two files computing the same verdict is one
  # of them being wrong the day the other changes.
  $weakest = 'UNKNOWN - recall-brain.py could not run, which is not "nothing is starving"'
  try {
    # --with-estate (WS 11): one weakest link across the personal store AND the estate, where a RED floor
    # outranks a quiet stage. recall-brain.py owns that ranking; this reads its line.
    $b = & $PY (Join-Path $SKILLS 'recall-brain.py') --with-estate 2>$null
    $line = @($b | Where-Object { "$_" -match '^WEAKEST LINK' })
    if ($line.Count) { $weakest = ("$($line[0])" -replace '^WEAKEST LINK:\s*', '') }
  } catch { }

  # EVERY QUEUE, ITS FLOOR, AND WHAT LEAVING IT COSTS.
  $queues = @()
  $queues += Get-QueueRow -Name 'forgetting candidates' -Floor 7 `
    -Cost 'every unretired section competes in every search. BM25 at 1,118 sections measured 3 points worse at right-domain than at 1,043 - more sections retrieve WORSE.' `
    -Count {
      $o = & $PY (Join-Path $SKILLS 'recall-forget.py') 2>$null
      $m = [regex]::Match(($o -join "`n"), 'UNRULED (\d+)')
      if (-not $m.Success) { return $null }
      @{ Count = [int]$m.Groups[1].Value; AgeDays = 0 }
    }
  $queues += Get-QueueRow -Name 'memory clusters' -Floor 14 `
    -Cost 'the memory store stays 156 dated incidents. Five separate CRLF memories remain five memories forever instead of one paragraph plus four pointers.' `
    -Count {
      # The line is `CLUSTERS: 17, of which UNRULED 0` - the same shape recall-forget
      # prints. The first draft of this matched `(\d+) unruled`, which appears nowhere
      # in that output, so the queue read UNKNOWN and the digest correctly refused to
      # call it empty. That refusal is why the bug was visible at all.
      $o = & $PY (Join-Path $SKILLS 'recall-consolidate.py') 2>$null
      $m = [regex]::Match(($o -join "`n"), 'UNRULED\s+(\d+)')
      if (-not $m.Success) { return $null }
      @{ Count = [int]$m.Groups[1].Value; AgeDays = 0 }
    }
  $queues += Get-QueueRow -Name 'graph alias proposals' -Floor 14 `
    -Cost 'Stage 1 produces nightly and Stage 2 has no scheduler. 60 proposals have waited since 2026-08-21; every one is an alias the board is not using.' `
    -Count {
      # THROUGH GRAPH'S FRONT DOOR, NOT ITS STATE FILES. The first version read
      # graph\learning\proposals.json directly and ops\audit-cross-module-reach.ps1
      # called it a new reach into graph's internals, which it was. It also hit
      # @($null).Count being 1 on the way and reported 0 waiting while 60 had waited
      # since 2026-08-21. A script graph owns now does the counting, returns NULL for a
      # file it could not read, and this treats null as UNKNOWN rather than as empty.
      $js = & $PY (Join-Path $repo 'graph\learning\learning_status.py') --json 2>$null
      if ($LASTEXITCODE -ne 0 -or -not $js) { return $null }
      $st = ($js -join "`n") | ConvertFrom-Json
      if ($null -eq $st.proposals_pending) { return $null }
      $age = if ($null -eq $st.proposals_oldest_days) { -1 } else { [double]$st.proposals_oldest_days }
      @{ Count = [int]$st.proposals_pending; AgeDays = $age }
    }
  $queues += Get-QueueRow -Name 'failure classes UNKNOWN' -Floor 7 `
    -Cost 'a signature recurring across sessions that no reflex, no draft and nothing in the store names. Nobody is even able to ask about it yet.' `
    -Count {
      $p = Join-Path $CLAUDE 'recall-classes.jsonl'
      $a = Get-JsonlAge -Path $p -Where { param($d) $d.status -eq 'UNKNOWN-TO-THE-ESTATE' }
      if ($a.Count -eq 0 -and -not (Test-Path -LiteralPath $p)) { return $null }
      @{ Count = $a.Count; AgeDays = 0 }
    }
  # WS 10a: a gate that keeps going red with nothing durable following it. A REPORT that never fails
  # anything - see ops\audit-gate-followthrough.ps1 for why a ratchet on this proxy would have been red
  # on day one against a gate working correctly. The digest is where a candidate reaches a person.
  $queues += Get-QueueRow -Name 'recurring red gates' -Floor 7 `
    -Cost 'CLAUDE.md says a recurring defect earns a memory, a gate or a command rather than another repair. A gate red again and again with nothing committed that names it is that rule going unkept, visibly.' `
    -Count {
      $fo = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'ops\audit-gate-followthrough.ps1') -Json
      $jl = @($fo | Where-Object { "$_" -match '^followthrough-json: ' })
      if (-not $jl.Count) { return $null }
      $fj = ("$($jl[0])" -replace '^followthrough-json: ', '') | ConvertFrom-Json
      if (-not $fj.known) { return $null }
      $age = -1
      if ($fj.oldest_first_red) {
        try { $age = [math]::Round(([DateTime]::UtcNow - [DateTime]::Parse($fj.oldest_first_red).ToUniversalTime()).TotalDays, 1) } catch { $age = -1 }
      }
      @{ Count = [int]$fj.candidates; AgeDays = $age }
    }
  $queues += Get-QueueRow -Name 'open triage items' -Floor 4 `
    -Cost 'an alert nobody has judged cannot feed the precision that decides re-arm timing. 14 alert types sat at "too few to state a precision".' `
    -Count {
      $p = Join-Path $repo 'grocery\triage-queue.json'
      if (-not (Test-Path -LiteralPath $p)) { return $null }
      $d = [IO.File]::ReadAllText($p) | ConvertFrom-Json
      $open = @(@($d.items) | Where-Object { $_.status -ne 'resolved' })
      @{ Count = $open.Count; AgeDays = 0 }
    }
  # WS 10f (2026-09-10): an INCIDENT draft waits for a person to write its root cause. The trigger WRITES
  # only in -Alert mode - the 06:45 task - so a digest run by hand opens nothing and only counts.
  $queues += Get-QueueRow -Name 'incident drafts open' -Floor 7 `
    -Cost 'the estate wrote one postmortem in its whole life. A draft nobody finishes is a timeline with no root cause, and the next recurrence opens the same draft again.' `
    -Count {
      $itArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $repo 'ops\incident-trigger.ps1'), '-Json')
      if ($Alert) { $itArgs += '-Write' }
      $io = & powershell @itArgs
      $jl = @($io | Where-Object { "$_" -match '^incident-json: ' })
      if (-not $jl.Count) { return $null }
      $ij = ("$($jl[0])" -replace '^incident-json: ', '') | ConvertFrom-Json
      @{ Count = [int]$ij.drafts_open; AgeDays = 0 }
    }
  # WS 10e (2026-09-10): a detector reading the same non-zero mark for 30 days may have stopped looking.
  $queues += Get-QueueRow -Name 'detectors flat 30 days' -Floor 7 `
    -Cost 'a detector returning the same non-zero number every day for a month has a backlog nobody works or has stopped finding new cases, and both read as health.' `
    -Count {
      $ro = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'ops\report-ratchet-trends.ps1') -Json
      $jl = @($ro | Where-Object { "$_" -match '^ratchet-trends-json: ' })
      if (-not $jl.Count) { return $null }
      $rj = ("$($jl[0])" -replace '^ratchet-trends-json: ', '') | ConvertFrom-Json
      if (-not $rj.known) { return $null }
      @{ Count = [int]$rj.stopped_looking; AgeDays = 0 }
    }

  # THE ESTATE HALF (WS 11). ops\brain-report.ps1 reads and never writes, so a RED floor becomes an event HERE,
  # in the scheduled -Alert run, and only here - a digest run by hand reports and writes nothing.
  $estatePage = @()
  $estateRed = @()
  try {
    $erOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'ops\brain-report.ps1') -Json
    $erLines = @($erOut)
    $cut = -1
    for ($i = 0; $i -lt $erLines.Count; $i++) { if ("$($erLines[$i])" -like 'SCOPE OF A CLEAN REPORT*') { $cut = $i; break } }
    if ($cut -gt 0) { $estatePage = @($erLines[0..($cut - 1)] | Where-Object { "$_".Trim() }) }
    $ej = @($erLines | Where-Object { "$_" -like 'brain-report-json: *' })
    if ($ej.Count) {
      $ed = ("$($ej[$ej.Count - 1])".Substring('brain-report-json: '.Length)) | ConvertFrom-Json
      $estateRed = @(@($ed.stages) | Where-Object { $_.floor -eq 'RED' })
    }
  } catch { $estatePage = @('ESTATE HALF UNKNOWN - ops\brain-report.ps1 could not run, which is not an estate with nothing wrong') }
  if ($Alert) {
    foreach ($rs in $estateRed) {
      $null = Write-TcEvent -Kind 'learning-stage-red' -Producer 'ops\brain-digest.ps1' -Data @{ stage = [string]$rs.stage; why = [string]$rs.why }
    }
  }

  $since = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 86400
  $evRaw = Read-TcEvents -SinceEpoch $since
  $events = @($evRaw)

  $text = Format-Digest -Night $night -Queues $queues -Weakest $weakest -Events $events -Estate $estatePage
  if (-not $Quiet) { $text }

  if ($Alert) {
    # ONE MAIL, THROUGH THE ESTATE'S OWN CHANNEL, so its once-per-day suppression and its
    # queue both apply. The subject is STABLE - send-alert derives the suppression key
    # from it with digits stripped - so a varying count must not appear in it.
    try {
      $alert = Join-Path $repo 'grocery\send-alert.ps1'
      if (Test-Path -LiteralPath $alert) {
        $bodyFile = Join-Path $repo 'ops\out\brain-digest-body.txt'
        $dir = Split-Path -Parent $bodyFile
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force $dir }
        [IO.File]::WriteAllText($bodyFile, $text, (New-Object Text.UTF8Encoding($false)))
        & $alert -Subject 'Brain digest: the night, the weakest link, and what is waiting' `
          -BodyFile $bodyFile -Emitter 'ops\brain-digest.ps1' -Force
      }
    } catch { }
  }

  $overdue = @($queues | Where-Object { $_.Known -and $_.Count -gt 0 -and $_.AgeDays -gt $_.Floor })
  $unknown = @($queues | Where-Object { -not $_.Known })
  Exit-Guard -Name 'BRAIN-DIGEST' -Code 0 `
    -Summary ("queues={0} overdue={1} unknown={2} night={3}" -f $queues.Count, $overdue.Count,
              $unknown.Count, $(if ($night.Red) { 'red' } else { 'green' }))
}
} finally {
  # A CRASH MUST NOT BE RECORDED AS rc=0. `[CORRECTED 2026-09-10]` This passed a literal 0, and
  # on the first live run with a non-empty event bus the body threw a format error while the
  # transcript closed with "finished rc=0" - the one record whose job is to say a hidden run
  # died, saying it was fine. $script:TcGuardMarkerWritten is set by lib\guard-contract.ps1
  # only when Exit-Guard writes the completion marker, so its absence means the body never
  # finished. Stop-RunLog tolerates a $null path; logging must never fail the run.
  $rcLog = if ($script:TcGuardMarkerWritten) { 0 } else { 1 }
  Stop-RunLog -ExitCode $rcLog -Path $script:RunLog
}
