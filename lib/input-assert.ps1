# input-assert.ps1 - a scheduled stage asserts its inputs before it does any work.
# ---------------------------------------------------------------------------------------------------
# WHY (2026-09-09, backlog I45 rung 2). Two scars, both on the SCHEDULED chain: an 08:30 stage that ran
# inside its predecessor's 08:12-08:43 window and consumed a half-written file, and a watchdog named
# 0930 that actually fires at 10:30. `chain-idle.ps1` takes a named mutex and prevents OVERLAP - "a
# fixed clock gap is an assumption while the mutex is a fact" - but it does not sequence, and it cannot
# tell "stage one failed" from "stage one has not run".
#
# RUNG 1 DELIBERATELY NARROWED THIS. 172 first-party .ps1 consume another stage's output and 97 of them
# defend nothing, but an assertion added to 97 consumers would be a large change for a risk that has
# fired twice, and a gate over it would be red on day one. **The five scheduled entry points are the
# whole surface that matters**, because a scheduled task is the only consumer nobody is watching.
#
# THREE OUTCOMES, AND COLLAPSING ANY TWO OF THEM IS THE BUG THIS EXISTS TO PREVENT:
#
#   FRESH    the input exists and is inside its window. Proceed.
#   STALE    it exists and is older than its window. The producer ran and then stopped, or failed
#            quietly. This is a finding.
#   MISSING  it is not there at all. **NOT the same as stale, and never the same as fresh.** A worktree
#            and a clean checkout have no board, so "missing" is routinely a could-not-evaluate rather
#            than a fault - and treating it as fresh is precisely the confident wrong zero this estate
#            keeps paying for.
#
# AND A FOURTH, ONLY FOR AN INPUT WHOSE CALLER DECLARES A CONTENT CLOCK (2026-09-10):
#
#   UNREADABLE  the file exists but the newest record inside it could not be read. Could-not-evaluate,
#               never FRESH - a fresh mtime alone is the false green the content clock was added to end.
#
# THE FILE CLOCK IS NOT THE CONTENT CLOCK (2026-09-10). graph\pipeline\nightly.ps1 asserted
# graph\sqlite\graph.db with this file for its first night and every night after, and read FRESH on all
# of them, while price_observations held 26,740 rows dated 2026-07-14 to 2026-08-21 and nothing newer.
# The file was written every morning by a structure-only import, so its mtime said "something opened
# this database" and nothing about whether a price had arrived. A caller that can read the newest record
# now passes it as -NewestRecord with -NewestRecordWhat naming it, and EITHER clock past its window is
# STALE. Naming the record is what turns the check on, so every existing caller behaves exactly as before.
#
# EXIT 3, NOT EXIT 1. A stage that cannot verify its input has NOT failed and has NOT passed: it could
# not evaluate. `.claude\rules\ops-and-gates.md` is explicit that 3 is never a pass, and a stage that
# stops at 3 with a spoken reason is recoverable, where one that proceeds on a stale input writes a
# wrong number into a live board.
#
# THE WINDOW IS DERIVED FROM THE SCHEDULE, NEVER GUESSED. A daily producer gets 24 h plus slack; the
# caller passes the slack it can defend. A bound invented at the call site is the same class of error
# as a threshold imported from a course reading.
#
# SCOPE OF A CLEAN REPORT: UNSOUND. FRESH means the file's mtime, and the newest record the caller read
# out of it, are inside their windows - never that the content is right, and never that every part of it
# moved. A caller that reads its newest record across several sources gets FRESH while one of them stopped.
# ---------------------------------------------------------------------------------------------------

function ConvertTo-TcRecordTime {
  <# A record's timestamp as a [datetime], or $null if it cannot be read. PURE.

     A DATE-ONLY stamp reads as the END of that day, 23:59:59. price_observations.observed_at is a
     capture DATE; read as midnight, a capture made this morning would already count as up to a day old,
     so date granularity alone could make a healthy day read stale. Read as the end of its day it can only
     err toward fresh, by at most 24 h, and the caller's window has to allow for that - nightly.ps1's
     says so where it sets it. #>
  param([string]$Stamp)
  $s = ([string]$Stamp).Trim()
  if (-not $s) { return $null }
  $inv = [Globalization.CultureInfo]::InvariantCulture
  $d = [datetime]::MinValue
  if ($s -match '^\d{4}-\d{2}-\d{2}$') {
    if ([datetime]::TryParseExact($s, 'yyyy-MM-dd', $inv, [Globalization.DateTimeStyles]::None, [ref]$d)) {
      return $d.Date.AddDays(1).AddSeconds(-1)
    }
    return $null
  }
  if ($s -match '^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}') {
    if ([datetime]::TryParse($s, $inv, [Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }
  }
  return $null
}

function Get-TcStampFromLines {
  <# The value of KEY= on the LAST line that starts with MARKER as a whole word, or '' if none. PURE.

     A whole word, so `NEWEST-OBSERVATION` does not also match the `NEWEST-OBSERVATION-COMPLETE` line a
     reader prints after it - that line carries no key, and reading it last would blank a good stamp. #>
  param([object[]]$Lines, [string]$Marker, [string]$Key)
  $val = ''
  $lead = '^' + [regex]::Escape($Marker) + '(\s|$)'
  $pick = '(?:^|\s)' + [regex]::Escape($Key) + '=(\S*)'
  foreach ($l in @($Lines)) {
    $t = [string]$l
    if (-not [regex]::IsMatch($t, $lead)) { continue }
    $m = [regex]::Match($t, $pick)
    $val = if ($m.Success) { $m.Groups[1].Value } else { '' }
  }
  return $val
}

function Get-TcInputState {
  <# The pure predicate. Returns 'MISSING', 'STALE', 'UNREADABLE' or 'FRESH' for one input, given the clock.

     Pure on purpose: the fixtures drive the same code the live path runs, with no file system and no
     wall clock, so the distinctions can be frozen. -CheckRecords is the caller declaring a content clock;
     without it the record arguments are ignored and the answer is the file clock's alone. #>
  param(
    [string]$Path,
    [datetime]$Now,
    [datetime]$WrittenAt,
    [double]$MaxAgeHours,
    [bool]$Exists = $true,
    [bool]$CheckRecords = $false,
    [object]$NewestRecordAt = $null,
    [double]$RecordMaxAgeHours = -1                  # -1 means "the same window as the file"
  )
  if (-not $Exists) { return 'MISSING' }
  if ($MaxAgeHours -le 0) { return 'FRESH' }          # 0 or less means "do not age-check this input"
  $age = ($Now - $WrittenAt).TotalHours
  if ($age -gt $MaxAgeHours) { return 'STALE' }
  if ($CheckRecords) {
    if (-not ($NewestRecordAt -is [datetime])) { return 'UNREADABLE' }
    $win = if ($RecordMaxAgeHours -gt 0) { $RecordMaxAgeHours } else { $MaxAgeHours }
    if (($Now - [datetime]$NewestRecordAt).TotalHours -gt $win) { return 'STALE' }
  }
  return 'FRESH'
}

function Test-TcInput {
  <# One input against the live file system. Returns a report object; never throws, never exits.

     The caller decides what to do, because a missing board is fatal to a pricing stage and routine in
     a worktree, and only the caller knows which it is. #>
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Producer,   # WHICH stage writes this. Named so a failure says who to look at.
    [double]$MaxAgeHours = 26.0,                     # a daily producer plus two hours of slack
    [string]$NewestRecord = '',                      # the newest record's stamp, as the caller read it out of the file
    [string]$NewestRecordWhat = '',                  # WHAT that stamp is. Naming it turns the content check ON.
    [double]$RecordMaxAgeHours = -1
  )
  $now = Get-Date
  $exists = Test-Path -LiteralPath $Path
  $written = if ($exists) { (Get-Item -LiteralPath $Path).LastWriteTime } else { [datetime]::MinValue }
  $check = [bool]$NewestRecordWhat
  $recAt = ConvertTo-TcRecordTime -Stamp $NewestRecord
  $state = Get-TcInputState -Path $Path -Now $now -WrittenAt $written -MaxAgeHours $MaxAgeHours -Exists $exists `
             -CheckRecords $check -NewestRecordAt $recAt -RecordMaxAgeHours $RecordMaxAgeHours
  $ageH = if ($exists) { [math]::Round(($now - $written).TotalHours, 1) } else { $null }
  $recWin = if ($RecordMaxAgeHours -gt 0) { $RecordMaxAgeHours } else { $MaxAgeHours }
  $recAgeH = if ($recAt -is [datetime]) { [math]::Round([math]::Max(0, ($now - $recAt).TotalHours), 1) } else { $null }
  $clock = ''
  if ($state -eq 'STALE') { $clock = if ($ageH -gt $MaxAgeHours) { 'file' } else { 'records' } }
  return [pscustomobject]@{
    Path = $Path; Producer = $Producer; State = $state; AgeHours = $ageH; MaxAgeHours = $MaxAgeHours
    NewestRecord = $NewestRecord; RecordAgeHours = $recAgeH; RecordMaxAgeHours = $(if ($check) { $recWin } else { $null })
    StaleClock = $clock
    Message = switch ($state) {
      'MISSING'    { "$Path is ABSENT. Its producer is $Producer. Missing is not stale and is not fresh - a worktree or a clean checkout has no board, so this is could-not-evaluate rather than a fault." }
      'UNREADABLE' { "$Path was written $ageH h ago, but its $NewestRecordWhat could not be read (got '$NewestRecord'). Its producer is $Producer. A fresh mtime alone is not a fresh input, so this is could-not-evaluate." }
      'STALE'      {
        if ($clock -eq 'file') { "$Path is $ageH h old, past its $MaxAgeHours h window. Its producer is $Producer, which means that stage ran and then stopped, or failed quietly." }
        else { "$Path was written $ageH h ago, inside its $MaxAgeHours h window, BUT its $NewestRecordWhat is $NewestRecord, $recAgeH h old, past its $recWin h window. A fresh file over old content: something keeps writing the file and nothing is adding records. Its producer is $Producer." }
      }
      default      {
        $base = "$Path is $ageH h old, inside its $MaxAgeHours h window (producer: $Producer)."
        if ($check) { $base + " Its $NewestRecordWhat is $NewestRecord, inside its $recWin h window." } else { $base }
      }
    }
  }
}

function Assert-TcInputs {
  <# Assert a whole input set for one scheduled stage. Prints every input with its verdict and returns
     the exit code the caller should use: 0 all fresh, 3 anything missing, stale or unreadable.

     WHY IT RETURNS RATHER THAN EXITS: a library that exits cannot be tested, and a stage may have its
     own cleanup to do. The caller writes `exit (Assert-TcInputs ...)`, which keeps the decision at the
     call site where it can be read. #>
  param(
    [Parameter(Mandatory=$true)][string]$Stage,
    [Parameter(Mandatory=$true)][object[]]$Inputs    # each: @{ Path=; Producer=; MaxAgeHours=; and optionally NewestRecord=; NewestRecordWhat=; RecordMaxAgeHours= }
  )
  $reports = @()
  foreach ($i in @($Inputs)) {
    if ($null -eq $i) { continue }
    $one = @{ Path = [string]$i.Path; Producer = [string]$i.Producer }
    $one.MaxAgeHours = if ($i.ContainsKey('MaxAgeHours')) { [double]$i.MaxAgeHours } else { 26.0 }
    if ($i.ContainsKey('NewestRecordWhat')) { $one.NewestRecordWhat = [string]$i.NewestRecordWhat; $one.NewestRecord = [string]$i.NewestRecord }
    if ($i.ContainsKey('RecordMaxAgeHours')) { $one.RecordMaxAgeHours = [double]$i.RecordMaxAgeHours }
    $reports += (Test-TcInput @one)
  }
  # WRITE-HOST, NOT WRITE-OUTPUT, AND THIS IS NOT A STYLE CHOICE. `Write-Output` inside a function
  # becomes part of that function's RETURN VALUE, so `Assert-TcInputs` returned its own report lines
  # with the exit code buried at the end of them and `$rc -eq 0` was false while everything was fresh.
  # Caught by this file's own must-not-fire on the first run. Write-Host still lands in stdout when the
  # process is redirected to a file, which is how every scheduled stage here is logged, so nothing is
  # lost. The estate has a memory for this exact shape.
  $bad = @($reports | Where-Object { $_.State -ne 'FRESH' })
  Write-Host ("input-assert [{0}]: {1} of {2} input(s) fresh" -f $Stage, ($reports.Count - $bad.Count), $reports.Count)
  foreach ($r in $reports) {
    Write-Host ("  {0,-10} {1}" -f $r.State, $r.Message)
  }
  if ($bad.Count -gt 0) {
    Write-Host ("  COULD NOT EVALUATE: {0} input(s) are missing, stale or unreadable, so this stage has NOT run and has NOT failed." -f $bad.Count)
    Write-Host '  Exit 3 is never a pass. Fix the producer, or say why this input is allowed to be old.'
    return 3
  }
  return 0
}

# ---- self-test -------------------------------------------------------------------------------------
# Guarded so dot-sourcing a caller never triggers it, the same shape lib\guard-contract.ps1 uses.
$__iaSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')
if ($__iaSelfTest) {
  $f = 0
  $n = 0
  function T($m, $c, $g) { $script:n++; if ($c) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $g); $script:f++ } }

  $now = [datetime]'2026-09-09T10:00:00'

  # MUST FIRE - the founding scar. A producer that ran yesterday and stopped leaves a file that EXISTS,
  # which is exactly why "the file is there" was never a sufficient check.
  T 'MUST FIRE  an input older than its window is STALE, not fresh' `
    ((Get-TcInputState -Now $now -WrittenAt $now.AddHours(-30) -MaxAgeHours 26) -eq 'STALE') `
    (Get-TcInputState -Now $now -WrittenAt $now.AddHours(-30) -MaxAgeHours 26)

  # MUST FIRE - the distinction the whole file exists for.
  T 'MUST FIRE  an ABSENT input is MISSING, never STALE and never FRESH' `
    ((Get-TcInputState -Now $now -WrittenAt ([datetime]::MinValue) -MaxAgeHours 26 -Exists $false) -eq 'MISSING') `
    (Get-TcInputState -Now $now -WrittenAt ([datetime]::MinValue) -MaxAgeHours 26 -Exists $false)

  # MUST NOT FIRE - an input written this morning is fine, or the chain stops every day.
  T 'MUST NOT FIRE  an input inside its window is FRESH' `
    ((Get-TcInputState -Now $now -WrittenAt $now.AddHours(-2) -MaxAgeHours 26) -eq 'FRESH') `
    (Get-TcInputState -Now $now -WrittenAt $now.AddHours(-2) -MaxAgeHours 26)

  # MUST NOT FIRE - the boundary is where it says it is. An input exactly AT the window holds.
  T 'MUST NOT FIRE  an input exactly at the window is still FRESH' `
    ((Get-TcInputState -Now $now -WrittenAt $now.AddHours(-26) -MaxAgeHours 26) -eq 'FRESH') `
    (Get-TcInputState -Now $now -WrittenAt $now.AddHours(-26) -MaxAgeHours 26)
  T 'MUST FIRE  one second past the window is STALE, so the boundary is real' `
    ((Get-TcInputState -Now $now -WrittenAt $now.AddHours(-26).AddSeconds(-1) -MaxAgeHours 26) -eq 'STALE') `
    (Get-TcInputState -Now $now -WrittenAt $now.AddHours(-26).AddSeconds(-1) -MaxAgeHours 26)

  # MUST NOT FIRE - an explicit 0 means "do not age-check", for an input that legitimately never moves.
  T 'MUST NOT FIRE  MaxAgeHours 0 disables the age check rather than failing everything' `
    ((Get-TcInputState -Now $now -WrittenAt $now.AddYears(-3) -MaxAgeHours 0) -eq 'FRESH') `
    (Get-TcInputState -Now $now -WrittenAt $now.AddYears(-3) -MaxAgeHours 0)

  # MUST FIRE - a MISSING input is missing even when the age check is disabled. Turning off staleness
  # must not turn off existence, or `-MaxAgeHours 0` becomes a way to silence the whole assertion.
  T 'MUST FIRE  MaxAgeHours 0 does NOT excuse an absent file' `
    ((Get-TcInputState -Now $now -WrittenAt $now -MaxAgeHours 0 -Exists $false) -eq 'MISSING') `
    (Get-TcInputState -Now $now -WrittenAt $now -MaxAgeHours 0 -Exists $false)

  # ---- the content clock (2026-09-10) -------------------------------------------------------------
  # MUST FIRE, THE FOUNDING CASE, PURE. graph.db written two hours before the 21:30 nightly, its newest
  # observation 2026-08-21. Every night from 2026-08-22 to 2026-09-09 this read FRESH on the file alone.
  $night = [datetime]'2026-09-10T21:30:00'
  $frozenAt = ConvertTo-TcRecordTime -Stamp '2026-08-21'
  $st = Get-TcInputState -Now $night -WrittenAt $night.AddHours(-2) -MaxAgeHours 26 -CheckRecords $true -NewestRecordAt $frozenAt -RecordMaxAgeHours 36
  T 'MUST FIRE  a FRESH file whose newest record is 2026-08-21 is STALE (the founding case)' ($st -eq 'STALE') $st

  # CLEAN TWIN: the file clock still works when the records are fresh - the content check must not
  # have replaced it on its way in.
  $st = Get-TcInputState -Now $night -WrittenAt $night.AddHours(-40) -MaxAgeHours 26 -CheckRecords $true -NewestRecordAt (ConvertTo-TcRecordTime -Stamp '2026-09-10') -RecordMaxAgeHours 36
  T 'CLEAN TWIN  a STALE file is still STALE when its records are fresh' ($st -eq 'STALE') $st

  # MUST NOT FIRE, THE WINDOW'S WORST HEALTHY CASE. The import runs at ~08:15 before that day's regular
  # captures land, so the newest regular record is yesterday's, and the latest reader is the 05:30
  # catch-up: end of 2026-09-09 to 05:30 on the 11th is 29.5 h.
  $st = Get-TcInputState -Now ([datetime]'2026-09-11T05:30:00') -WrittenAt ([datetime]'2026-09-10T08:15:00') -MaxAgeHours 26 `
          -CheckRecords $true -NewestRecordAt (ConvertTo-TcRecordTime -Stamp '2026-09-09') -RecordMaxAgeHours 36
  T 'MUST NOT FIRE  yesterday''s date read at the 05:30 catch-up is FRESH inside 36 h' ($st -eq 'FRESH') $st
  # MUST FIRE: one missed import day, read at 21:30, is 45.5 h and fires.
  $st = Get-TcInputState -Now $night -WrittenAt $night.AddHours(-3) -MaxAgeHours 26 -CheckRecords $true -NewestRecordAt (ConvertTo-TcRecordTime -Stamp '2026-09-08') -RecordMaxAgeHours 36
  T 'MUST FIRE  a newest record from two days back is STALE at 21:30' ($st -eq 'STALE') $st

  # MUST FIRE: a declared content clock that could not be read is UNREADABLE, never FRESH.
  $st = Get-TcInputState -Now $night -WrittenAt $night.AddHours(-1) -MaxAgeHours 26 -CheckRecords $true -NewestRecordAt $null -RecordMaxAgeHours 36
  T 'MUST FIRE  a declared content clock with no readable stamp is UNREADABLE' ($st -eq 'UNREADABLE') $st
  # CLEAN TWIN: a caller that declares no content clock gets the file clock's answer, exactly as before.
  $st = Get-TcInputState -Now $night -WrittenAt $night.AddHours(-1) -MaxAgeHours 26 -NewestRecordAt $null
  T 'CLEAN TWIN  no declared content clock still answers FRESH on a fresh file' ($st -eq 'FRESH') $st

  # The stamp reader.
  $d = ConvertTo-TcRecordTime -Stamp '2026-09-09'
  T 'CLEAN TWIN  a date-only stamp reads as the END of its day' ($d -eq [datetime]'2026-09-09T23:59:59') ([string]$d)
  $d = ConvertTo-TcRecordTime -Stamp '2026-09-09T08:15:00'
  T 'CLEAN TWIN  a stamp with a time keeps its time' ($d -eq [datetime]'2026-09-09T08:15:00') ([string]$d)
  T 'MUST FIRE  a stamp that is not a date reads as nothing' ($null -eq (ConvertTo-TcRecordTime -Stamp 'observed')) 'parsed'
  T 'MUST FIRE  an impossible date reads as nothing' ($null -eq (ConvertTo-TcRecordTime -Stamp '2026-13-45')) 'parsed'

  # The line reader, over the exact shape graph\pipeline\newest_observation.py prints.
  $readerOut = @('lane regular newest=2026-08-21 rows=26740',
                 'NEWEST-OBSERVATION observed_at=2026-08-21 rows=26740 future_rows=0',
                 'NEWEST-OBSERVATION-COMPLETE rc=0')
  $v = Get-TcStampFromLines -Lines $readerOut -Marker 'NEWEST-OBSERVATION' -Key 'observed_at'
  T 'MUST FIRE  the key line is read, and the COMPLETE line after it does not blank the stamp' ($v -eq '2026-08-21') $v
  $unread = @('could not read the observation clock: no database', 'NEWEST-OBSERVATION observed_at= rows=0 future_rows=0', 'NEWEST-OBSERVATION-COMPLETE rc=3')
  $v = Get-TcStampFromLines -Lines $unread -Marker 'NEWEST-OBSERVATION' -Key 'observed_at'
  T 'MUST FIRE  a could-not-read line yields an empty stamp' ($v -eq '') $v
  $v = Get-TcStampFromLines -Lines @('some other tool output') -Marker 'NEWEST-OBSERVATION' -Key 'observed_at'
  T 'MUST FIRE  output with no key line yields an empty stamp' ($v -eq '') $v

  # The live wrapper, against real files.
  $tmp = Join-Path $env:TEMP ('ia-selftest-' + [guid]::NewGuid().ToString('N') + '.txt')
  try {
    Set-Content -LiteralPath $tmp -Value 'x' -Encoding UTF8
    $r = Test-TcInput -Path $tmp -Producer 'the self-test' -MaxAgeHours 26
    T 'a file written just now reports FRESH through the live path' ($r.State -eq 'FRESH') $r.State
    T 'and its message names the PRODUCER, so a failure says who to look at' `
      ($r.Message -match 'the self-test') $r.Message
    $rc = Assert-TcInputs -Stage 'probe' -Inputs @(@{ Path = $tmp; Producer = 'the self-test' })
    T 'MUST NOT FIRE  an all-fresh input set returns 0' ($rc -eq 0) ([string]$rc)
    $rc2 = Assert-TcInputs -Stage 'probe' -Inputs @(@{ Path = ($tmp + '.nope'); Producer = 'nobody' })
    T 'MUST FIRE  a missing input returns 3 (could-not-evaluate), never 1 and never 0' ($rc2 -eq 3) ([string]$rc2)

    # MUST FIRE, THE FOUNDING CASE THROUGH THE LIVE PATH: a file written seconds ago, a newest record
    # twenty days old. The report must say which clock is stale, or a reader goes looking at the file.
    $old = (Get-Date).AddDays(-20).ToString('yyyy-MM-dd')
    $r = Test-TcInput -Path $tmp -Producer 'the self-test' -MaxAgeHours 26 -NewestRecord $old -NewestRecordWhat 'newest price_observations.observed_at' -RecordMaxAgeHours 36
    T 'MUST FIRE  a file written just now over a 20-day-old newest record is STALE through the live path' ($r.State -eq 'STALE') $r.State
    T 'and the report names the RECORDS as the stale clock, not the file' ($r.StaleClock -eq 'records' -and $r.Message -match 'nothing is adding records') ($r.StaleClock + ' / ' + $r.Message)
    $rc4 = Assert-TcInputs -Stage 'probe' -Inputs @(@{ Path = $tmp; Producer = 'the self-test'; NewestRecord = $old; NewestRecordWhat = 'newest price_observations.observed_at'; RecordMaxAgeHours = 36.0 })
    T 'MUST FIRE  Assert-TcInputs carries the content clock through and returns 3' ($rc4 -eq 3) ([string]$rc4)
    $rc5 = Assert-TcInputs -Stage 'probe' -Inputs @(@{ Path = $tmp; Producer = 'the self-test'; NewestRecord = (Get-Date).ToString('yyyy-MM-dd'); NewestRecordWhat = 'newest price_observations.observed_at'; RecordMaxAgeHours = 36.0 })
    T 'MUST NOT FIRE  the same file with a record dated today returns 0' ($rc5 -eq 0) ([string]$rc5)
    $rc6 = Assert-TcInputs -Stage 'probe' -Inputs @(@{ Path = $tmp; Producer = 'the self-test'; NewestRecord = ''; NewestRecordWhat = 'newest price_observations.observed_at' })
    T 'MUST FIRE  a declared clock the caller could not read returns 3, never 0' ($rc6 -eq 3) ([string]$rc6)
  } finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  }

  # CLEAN TWIN - the adjacent behaviour a three-way return was most likely to break: a set with one bad
  # input still REPORTS the good ones, so a reader sees the whole picture rather than the first failure.
  $tmp2 = Join-Path $env:TEMP ('ia-selftest2-' + [guid]::NewGuid().ToString('N') + '.txt')
  try {
    Set-Content -LiteralPath $tmp2 -Value 'x' -Encoding UTF8
    $rc3 = Assert-TcInputs -Stage 'probe' -Inputs @(
      @{ Path = $tmp2; Producer = 'good' }, @{ Path = ($tmp2 + '.nope'); Producer = 'bad' })
    T 'CLEAN TWIN  a mixed set still returns a clean 3 - the report goes to the host, not into the return value' `
      ($rc3 -eq 3) ([string]$rc3)
    T 'MUST FIRE  the return value is an INT, not the report lines' ($rc3 -is [int]) ($rc3.GetType().Name)
  } finally {
    Remove-Item $tmp2 -Force -ErrorAction SilentlyContinue
  }

  if ($f -eq 0) { Write-Output ("input-assert SELF-TEST PASS: $n case(s) resolved - led by the founding content-clock case (a fresh graph.db over a 2026-08-21 newest observation is STALE), MISSING never STALE and never FRESH, the window boundary in both directions, and the must-fire that the return value is an INT rather than the report lines"); exit 0 }
  Write-Output ("input-assert SELF-TEST FAIL: $f of $n case(s)"); exit 2
}
