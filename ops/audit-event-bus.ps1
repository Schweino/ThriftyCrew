<#
  audit-event-bus.ps1 - every declared producer still writes to the bus, and the bus is not dead.

  WS 1b of design\PLAN-brain-v2-2026-09-09.md.

  WHY A DECLARED TABLE RATHER THAN A GREP. A producer that stops writing looks exactly like an
  estate where nothing happened, and the whole point of the bus is to notice things. So the
  producers are named here, and each row says which event it owes and what its absence would
  mean. A grep for Write-TcEvent would pass on the day somebody deleted the call and the line
  that used to make it.

  TWO CHECKS, AND THE SECOND IS THE ONE THIS ESTATE KEEPS LEARNING IT NEEDS:

    1. WIRING (static, hermetic). Every declared producer file exists and still carries a
       Write-TcEvent call for the kind it owes. This is the half that runs in run-gates.
    2. THE FLOOR (data). A bus with nothing in it for FLOOR_DAYS while the estate was demonstrably
       working is a DEAD BUS, not a quiet one. `.claude\rules\ops-and-gates.md`, backlog I80:
       every threshold here is an upper bound, so not one of them can fire on nothing happening.
       This is deliberately a check that fires on ABSENCE.

  WHY THE FLOOR IS A WARNING AND NOT A HARD FAIL. A bus can be legitimately empty - a fresh
  checkout, a machine that was off, a day nobody pushed. Failing on that would be red on day one
  and would teach people to ignore it. It goes red only when the bus is empty AND the session
  digest shows sessions ran, which is the state that cannot innocently coexist.

  SCOPE OF A CLEAN REPORT: UNSOUND about behaviour, SOUND about wiring. It proves the CALL is in
  the file; it cannot prove the call is on a path that executes. A producer whose Write-TcEvent
  sits behind a condition that is never true passes this and writes nothing, which is what check
  2 exists to catch from the other end.

  EXIT CODES (lib\guard-contract.ps1): 0 clean, 2 hard finding, 3 could-not-evaluate.

  Self-test: powershell -File ops\audit-event-bus.ps1 -SelfTest
#>
[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\event-bus.ps1')

# A bus with no rows for this long, while sessions ran, is dead rather than quiet.
$FLOOR_DAYS = 3

# EVERY PRODUCER, ITS EVENT, AND WHAT ITS SILENCE WOULD COST. The third column is the part
# worth writing: a row nobody can say the consequence of is a row nobody will fix.
$PRODUCERS = @(
  [pscustomobject]@{
    File = 'ops\run-gates.ps1'; Kind = 'gate-red'
    Cost = 'a red gate would leave no record at all. There is no gate-failure history anywhere else in the estate, so "which gate fails most" and "did this failure ever get a fixture" are both unanswerable.'
  }
  [pscustomobject]@{
    File = 'grocery\triage-close.ps1'; Kind = 'alert-closed'
    Cost = 'alert precision would keep being computed from a file nobody joins to anything. 14 alert types sat at "too few to state a precision" with no way to see the queue draining.'
  }
  [pscustomobject]@{
    File = 'ops\brain-digest.ps1'; Kind = 'learning-stage-red'
    Cost = 'a learning stage whose producer STOPPED would be a line in one morning mail and then gone. The bus is the only place "which stage keeps going red" can be counted later, and every threshold elsewhere is an upper bound that cannot fire on nothing happening.'
  }
  [pscustomobject]@{
    File = 'grocery\check-ad-cycles.ps1'; Kind = 'chain-complete'
    Cost = 'THE HEARTBEAT, and without it the floor below is not a floor. The other two producers fire only on TROUBLE - a red gate, a closed alert - so a healthy estate would write nothing and an empty bus could not be told apart from a dead one. This is the event that fires when things go right.'
  }
)

function Test-ProducerWired {
  <# [] when the producer is wired, else the findings. Pure: takes the source text. #>
  param([string]$Rel, [string]$Source, [string]$Kind, [bool]$Exists)
  $findings = @()
  if (-not $Exists) {
    $findings += ("{0}: declared as the producer of '{1}' and the file is not in the tree" -f $Rel, $Kind)
    return ,$findings
  }
  # Needles by concatenation, so this file is not its own match and cannot be scanned into
  # passing. `.claude\rules\ops-and-gates.md`: a self-test that greps its own source cannot fail.
  $call = 'Write-Tc' + 'Event'
  if (-not $Source.Contains($call)) {
    $findings += ("{0}: declared as the producer of '{1}' and carries no {2} call - the event is owed and nothing writes it" -f $Rel, $Kind, $call)
  }
  if ($Source -notmatch [regex]::Escape("'" + $Kind + "'")) {
    $findings += ("{0}: carries a bus call but never names the kind '{1}' it owes" -f $Rel, $Kind)
  }
  $dot = '. (Join-Path'
  if (-not ($Source.Contains($dot) -and $Source -match 'event-bus\.ps1')) {
    $findings += ("{0}: names the bus but does not dot-source lib\event-bus.ps1, so the call cannot resolve" -f $Rel)
  }
  return ,$findings
}

function Get-BusAge {
  <# @{ Rows=<int>; NewestEpoch=<int>; AgeDays=<double or -1> }. -1 means no rows at all. #>
  param([string]$Path = '')
  # ASSIGN, THEN WRAP. Read-TcEvents returns `,$out` so an empty log arrives as @(@()),
  # whose Count is 1 - an absent bus would read as one row and the floor would never fire.
  $read = Read-TcEvents -Path $Path
  $rows = @($read)
  if ($rows.Count -eq 0) { return @{ Rows = 0; NewestEpoch = 0; AgeDays = -1 } }
  $newest = 0
  foreach ($r in $rows) { if ([int]$r.t -gt $newest) { $newest = [int]$r.t } }
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  return @{ Rows = $rows.Count; NewestEpoch = $newest
            AgeDays = [math]::Round(($now - $newest) / 86400.0, 2) }
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

  $good = @'
. (Join-Path $repo 'lib\event-bus.ps1')
$null = Write-TcEvent -Kind 'gate-red' -Producer 'ops\run-gates.ps1' -Data @{ gate = 'x' }
'@
  # MUST FIRE: the four ways a producer can owe an event and not write it.
  Case 'MUST FIRE' 'a declared producer that is missing from the tree is a finding' `
    ($( $r = Test-ProducerWired -Rel 'ops\gone.ps1' -Source '' -Kind 'gate-red' -Exists $false; @($r).Count ) -ge 1)
  Case 'MUST FIRE' 'a producer with no bus call at all is a finding' `
    ($( $r = Test-ProducerWired -Rel 'ops\x.ps1' -Source 'Write-Output "hi"' -Kind 'gate-red' -Exists $true; @($r).Count ) -ge 1)
  $wrongKind = $good.Replace("'gate-red'", "'something-else'")
  Case 'MUST FIRE' 'a producer that writes a DIFFERENT kind than it owes is a finding' `
    ($( $r = Test-ProducerWired -Rel 'ops\x.ps1' -Source $wrongKind -Kind 'gate-red' -Exists $true; @($r).Count ) -ge 1)
  $noDot = "`$null = Write-TcEvent -Kind 'gate-red' -Producer 'x' -Data @{}"
  Case 'MUST FIRE' 'a bus call with no dot-source cannot resolve, and is a finding' `
    ($( $r = Test-ProducerWired -Rel 'ops\x.ps1' -Source $noDot -Kind 'gate-red' -Exists $true; @($r).Count ) -ge 1)

  # MUST NOT FIRE: a correctly wired producer is silent, or the gate is red on day one.
  Case 'MUST NOT FIRE' 'a correctly wired producer yields no finding' `
    ($( $r = Test-ProducerWired -Rel 'ops\run-gates.ps1' -Source $good -Kind 'gate-red' -Exists $true; @($r).Count ) -eq 0) `
    ((Test-ProducerWired -Rel 'ops\run-gates.ps1' -Source $good -Kind 'gate-red' -Exists $true) -join '; ')

  # CLEAN TWIN: the writer round-trips, and refuses to let a producer forge the reserved fields.
  $tmp = Join-Path $env:TEMP ("event-bus-selftest-{0}.jsonl" -f $PID)
  Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
  $okWrite = Write-TcEvent -Kind 'selftest' -Producer 'ops\audit-event-bus.ps1' `
    -Data @{ note = 'hello'; kind = 'FORGED'; t = 1 } -Path $tmp
  $backRaw = Read-TcEvents -Path $tmp
  $back = @($backRaw)
  Case 'CLEAN TWIN' 'an event round-trips through write and read' `
    ($okWrite -and $back.Count -eq 1 -and $back[0].note -eq 'hello') ("rows=" + $back.Count)
  Case 'MUST NOT FIRE' 'a producer cannot overwrite the reserved kind or timestamp' `
    ($back.Count -eq 1 -and $back[0].kind -eq 'selftest' -and [int]$back[0].t -gt 1) `
    ("kind=" + $back[0].kind + " t=" + $back[0].t)
  # CLEAN TWIN: a torn line is skipped rather than fatal - the bus is appended to while read.
  Add-Content -LiteralPath $tmp -Value '{not json at all' -Encoding utf8
  Case 'CLEAN TWIN' 'a torn line is skipped, and the good rows still read' `
    ($( $t = Read-TcEvents -Path $tmp; @($t).Count ) -eq 1)
  Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue

  # MUST NOT FIRE: the writer never throws, whatever it is handed. This is the property
  # that makes it safe to put inside a gate and a publish chain.
  $threw = $false
  try {
    $null = Write-TcEvent -Kind 'x' -Producer 'y' -Data @{ a = 1 } -Path 'Q:\no\such\place\x.jsonl'
  } catch { $threw = $true }
  Case 'MUST NOT FIRE' 'an unwritable path returns false and does NOT throw' (-not $threw)

  # CLEAN TWIN: an absent bus reads as zero rows and age -1, never as fresh.
  $age = Get-BusAge -Path (Join-Path $env:TEMP ("no-such-bus-{0}.jsonl" -f $PID))
  Case 'CLEAN TWIN' 'an absent bus is 0 rows and age -1, never age 0' `
    ($age.Rows -eq 0 -and $age.AgeDays -eq -1) ("rows=" + $age.Rows + " age=" + $age.AgeDays)

  ''
  if ($fails.Count -gt 0) {
    "audit-event-bus selftest: $($fails.Count) FAILED of $($ran.Count)"
    $fails | ForEach-Object { "  $_" }
    Exit-Guard -Name 'EVENT-BUS-SELFTEST' -Code 1 -Summary "failed=$($fails.Count) of $($ran.Count)"
  }
  "audit-event-bus selftest: $($ran.Count) of $($ran.Count) cases pass"
  Exit-Guard -Name 'EVENT-BUS-SELFTEST' -Code 0 -Summary "cases=$($ran.Count)"
}

Invoke-Guard -Name 'EVENT-BUS' -Body {
  $findings = @()
  'event bus, declared producers:'
  foreach ($p in $PRODUCERS) {
    $full = Join-Path $repo $p.File
    $exists = Test-Path -LiteralPath $full
    $src = if ($exists) { [IO.File]::ReadAllText($full) } else { '' }
    $fRaw = Test-ProducerWired -Rel $p.File -Source $src -Kind $p.Kind -Exists $exists
    $f = @($fRaw)
    if ($f.Count -eq 0) {
      '  ok      {0,-32} owes {1}' -f $p.File, $p.Kind
    } else {
      '  FAIL    {0,-32} owes {1}' -f $p.File, $p.Kind
      foreach ($x in $f) { '            ' + $x }
      '            cost if silent: ' + $p.Cost
      $findings += $f
    }
  }

  ''
  $age = Get-BusAge
  $busPath = Get-TcEventBusPath
  if ($age.Rows -eq 0) {
    'the bus itself: EMPTY (0 rows) at {0}' -f $busPath
    # THE FLOOR. An empty bus is only a finding when the estate was demonstrably running,
    # which is what the session digest can answer and nothing else can.
    $digest = Join-Path (Split-Path -Parent $repo) 'ThriftyCrew\ops\out\events.jsonl'
    $sessions = 0
    $sd = Join-Path $env:USERPROFILE '.claude\recall-session-digest.jsonl'
    if (Test-Path -LiteralPath $sd) {
      $sessions = @([IO.File]::ReadAllLines($sd) | Where-Object { "$_".Trim() }).Count
    }
    # A BUS THAT HAS NEVER HELD A ROW IS NEW, NOT DEAD, AND SAYING OTHERWISE WOULD MAKE THIS
    # GATE RED ON DAY ONE - which `.claude\rules\ops-and-gates.md` forbids, because a gate
    # that is red the moment it ships teaches people to ignore red. The heartbeat producer
    # (`chain-complete`) writes once a day, so this state resolves itself on the next daily
    # chain; until then it is printed, loudly, and passes.
    #
    # It cannot hide forever: the age of THIS FILE is how long the wiring has existed, and
    # the line below says it. A bus still empty a week after the audit shipped is a real
    # finding, and the number to argue with is right there.
    $wiredDays = 0
    try {
      $wiredDays = [math]::Round(((Get-Date) - (Get-Item -LiteralPath $PSCommandPath).LastWriteTime).TotalDays, 1)
    } catch { }
    '  {0} session(s) are on record in the digest; this wiring is {1} day(s) old.' -f $sessions, $wiredDays
    if ($wiredDays -gt (2 * $FLOOR_DAYS)) {
      '  DEAD BUS: {0} day(s) of wiring and not one event. Some producer never fired.' -f $wiredDays
      $findings += ("the event bus is EMPTY {0} day(s) after the wiring landed, over the {1}-day patience. The heartbeat producer writes once per daily chain, so this cannot be a quiet estate - a producer is not running." -f $wiredDays, (2 * $FLOOR_DAYS))
    } else {
      '  NOT a finding yet: the heartbeat producer writes once per daily chain, so a bus this'
      '  new is expected to be empty. It becomes a finding after {0} day(s).' -f (2 * $FLOOR_DAYS)
    }
  } else {
    'the bus itself: {0} row(s), newest {1} day(s) old, at {2}' -f $age.Rows, $age.AgeDays, $busPath
    if ($age.AgeDays -gt $FLOOR_DAYS) {
      '  STALE: nothing has been written for more than {0} day(s).' -f $FLOOR_DAYS
      $findings += ("the newest event on the bus is {0} day(s) old, over the {1}-day floor. Every other threshold in this estate is an upper bound and cannot fire on nothing happening; this one can, and it just did." -f $age.AgeDays, $FLOOR_DAYS)
    }
    $kinds = @{}
    $allEv = Read-TcEvents
    foreach ($r in @($allEv)) {
      $k = [string]$r.kind
      if (-not $kinds.ContainsKey($k)) { $kinds[$k] = 0 }
      $kinds[$k] = $kinds[$k] + 1
    }
    foreach ($k in ($kinds.Keys | Sort-Object)) { '    {0,-24} {1}' -f $k, $kinds[$k] }
  }

  ''
  'SCOPE OF A CLEAN REPORT: SOUND about wiring, UNSOUND about behaviour. It proves the call is'
  'in the file; it cannot prove the call sits on a path that runs.'
  if ($findings.Count -gt 0) {
    'EVENT BUS AUDIT FAILED: {0} finding(s) over {1} declared producer(s).' -f $findings.Count, $PRODUCERS.Count
    Exit-Guard -Name 'EVENT-BUS' -Code 2 -Summary "producers=$($PRODUCERS.Count) findings=$($findings.Count)"
  }
  'event-bus: PASSED - {0} declared producer(s) wired, bus has {1} row(s).' -f $PRODUCERS.Count, $age.Rows
  Exit-Guard -Name 'EVENT-BUS' -Code 0 -Summary "producers=$($PRODUCERS.Count) rows=$($age.Rows) findings=0"
}
