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
# EXIT 3, NOT EXIT 1. A stage that cannot verify its input has NOT failed and has NOT passed: it could
# not evaluate. `.claude\rules\ops-and-gates.md` is explicit that 3 is never a pass, and a stage that
# stops at 3 with a spoken reason is recoverable, where one that proceeds on a stale input writes a
# wrong number into a live board.
#
# THE WINDOW IS DERIVED FROM THE SCHEDULE, NEVER GUESSED. A daily producer gets 24 h plus slack; the
# caller passes the slack it can defend. A bound invented at the call site is the same class of error
# as a threshold imported from a course reading.
# ---------------------------------------------------------------------------------------------------

function Get-TcInputState {
  <# The pure predicate. Returns 'MISSING', 'STALE' or 'FRESH' for one input, given the clock.

     Pure on purpose: the fixtures drive the same code the live path runs, with no file system and no
     wall clock, so the three-way distinction can be frozen. #>
  param(
    [string]$Path,
    [datetime]$Now,
    [datetime]$WrittenAt,
    [double]$MaxAgeHours,
    [bool]$Exists = $true
  )
  if (-not $Exists) { return 'MISSING' }
  if ($MaxAgeHours -le 0) { return 'FRESH' }          # 0 or less means "do not age-check this input"
  $age = ($Now - $WrittenAt).TotalHours
  if ($age -gt $MaxAgeHours) { return 'STALE' }
  return 'FRESH'
}

function Test-TcInput {
  <# One input against the live file system. Returns a report object; never throws, never exits.

     The caller decides what to do, because a missing board is fatal to a pricing stage and routine in
     a worktree, and only the caller knows which it is. #>
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Producer,   # WHICH stage writes this. Named so a failure says who to look at.
    [double]$MaxAgeHours = 26.0                      # a daily producer plus two hours of slack
  )
  $exists = Test-Path -LiteralPath $Path
  $written = if ($exists) { (Get-Item -LiteralPath $Path).LastWriteTime } else { [datetime]::MinValue }
  $state = Get-TcInputState -Path $Path -Now (Get-Date) -WrittenAt $written -MaxAgeHours $MaxAgeHours -Exists $exists
  $ageH = if ($exists) { [math]::Round(((Get-Date) - $written).TotalHours, 1) } else { $null }
  return [pscustomobject]@{
    Path = $Path; Producer = $Producer; State = $state; AgeHours = $ageH; MaxAgeHours = $MaxAgeHours
    Message = switch ($state) {
      'MISSING' { "$Path is ABSENT. Its producer is $Producer. Missing is not stale and is not fresh - a worktree or a clean checkout has no board, so this is could-not-evaluate rather than a fault." }
      'STALE'   { "$Path is $ageH h old, past its $MaxAgeHours h window. Its producer is $Producer, which means that stage ran and then stopped, or failed quietly." }
      default   { "$Path is $ageH h old, inside its $MaxAgeHours h window (producer: $Producer)." }
    }
  }
}

function Assert-TcInputs {
  <# Assert a whole input set for one scheduled stage. Prints every input with its verdict and returns
     the exit code the caller should use: 0 all fresh, 3 anything missing or stale.

     WHY IT RETURNS RATHER THAN EXITS: a library that exits cannot be tested, and a stage may have its
     own cleanup to do. The caller writes `exit (Assert-TcInputs ...)`, which keeps the decision at the
     call site where it can be read. #>
  param(
    [Parameter(Mandatory=$true)][string]$Stage,
    [Parameter(Mandatory=$true)][object[]]$Inputs    # each: @{ Path=; Producer=; MaxAgeHours= }
  )
  $reports = @()
  foreach ($i in @($Inputs)) {
    if ($null -eq $i) { continue }
    $max = if ($i.ContainsKey('MaxAgeHours')) { [double]$i.MaxAgeHours } else { 26.0 }
    $reports += (Test-TcInput -Path ([string]$i.Path) -Producer ([string]$i.Producer) -MaxAgeHours $max)
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
    Write-Host ("  {0,-8} {1}" -f $r.State, $r.Message)
  }
  if ($bad.Count -gt 0) {
    Write-Host ("  COULD NOT EVALUATE: {0} input(s) are missing or stale, so this stage has NOT run and has NOT failed." -f $bad.Count)
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
  function T($m, $c, $g) { if ($c) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $g); $script:f++ } }

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

  if ($f -eq 0) { Write-Output 'input-assert SELF-TEST PASS: 13 case(s) resolved - led by the three-way distinction (MISSING is never STALE and never FRESH), the window boundary in both directions, and the must-fire that the return value is an INT rather than the report lines'; exit 0 }
  Write-Output ("input-assert SELF-TEST FAIL: $f case(s)"); exit 2
}
