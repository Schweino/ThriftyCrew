<#
  push-ledger.ps1 - one durable row per push attempt on this box: how long it waited for the machine-wide push lock,
  and whether the remote moved WHILE IT WAITED.

  Dot-source:  . (Join-Path $repoRoot 'lib\push-ledger.ps1')
  Self-test:   powershell -File lib\push-ledger.ps1 -SelfTest
  Report:      powershell -File ops\probe-push-convergence.ps1

  WHY THIS EXISTS (2026-09-12). The push path has been rebuilt three times in two days - the lock (e73f3d940), the
  lock moved off the checks (a6e724f36), the gate moved out of the lock (4ae8376f4) - and every single verdict on
  whether it worked was archaeology: somebody read %TEMP%\tc-prepush-*.log by hand, or counted "cannot lock ref"
  lines out of scratch files. That evidence is WORSE than it looks. ops\hooks\pre-push deletes its gate log on the
  path where the gate PASSED, so the logs that survive are the refusals and the runs still in flight: measured this
  morning, 240 retained logs of which 54 said blind=push-cannot-land and 46 said blind=no-gate-worker-slot, and
  NOTHING in that pile is a push that landed. A population that drops its successes cannot answer "how often does a
  push wait and then find the remote moved" - it can only answer "of the pushes that failed, how did they fail",
  which is measurement.md's abstention rule wearing a bigger coat.

  So the wait and the staleness are recorded at the moment they happen, by the two places that know them:
  ops\hold-push-lock.ps1 (every push through the hook) and ops\push-main.ps1 (a wrapper push, which also knows
  whether it had to rebase and what it landed). One row each, appended, never rewritten.

  WHAT A ROW IS FOR, and what it is not. It is a MEASUREMENT, not a control: nothing reads it to decide anything,
  no gate has a threshold on it, and a run that cannot write one carries on exactly as it did before. That is
  deliberate - ops-and-gates.md forbids a gate that is red on day one, and a bar on push waits would be red on the
  first busy morning and teach --no-verify.

  IT NEVER THROWS INTO A PUSH. Write-TcPushRow returns Written / Reason and swallows everything, because the caller
  is a pre-push hook's background holder: a ledger that could refuse a push would be a worse defect than the one it
  exists to measure. The estate's rule about blind fallbacks applies and is answered - the return value SAYS it did
  not write and why, and the self-test has a case that reads it, so a silent failure has somewhere to be seen.

  A COULD-NOT-READ IS NEVER A "DID NOT MOVE". A row whose base or grant sha is missing is counted UNKNOWN by
  Measure-TcPushRows and is kept out of the moved rate's numerator AND its denominator, which is the only honest
  place for it ([[a-could-not-look-must-not-settle-the-question]]).

  WHERE IT LIVES: %LOCALAPPDATA%\ThriftyCrew\push-ledger\pushes-<yyyy-MM-dd>.jsonl, one file per day, machine-wide
  and OUTSIDE every checkout - so it can never dirty a tree a gate is about to judge, and every worktree on this box
  writes to the one record. Several pushes append at once, so the append goes through lib\append-line.ps1 rather
  than Add-Content, which loses lines under concurrency (measured: 13 of 200 with two appenders).

  SCOPE OF A CLEAN REPORT: a row proves what ONE push observed. The file is not a census of pushes - a checkout
  older than this change writes nothing, --no-verify writes nothing, and a machine that is not this one writes
  nothing - so every rate derived from it carries the row count as its denominator and says what it cannot see.

  NO param() BLOCK: dot-sourced under PS 5.1 a param() block runs in the CALLER's scope (lib\guard-contract.ps1).
#>
$__pldSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')
. (Join-Path $PSScriptRoot 'append-line.ps1')

$script:TcPushLedgerRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ThriftyCrew\push-ledger'

function Get-TcPushLedgerPath {
  <# Today's ledger file. A fixture passes its own -Root, or sets TC_PUSH_LEDGER_ROOT for the whole suite.

     THE SUITE-WIDE REDIRECT IS NOT A CONVENIENCE, it is the only thing that keeps the measurement honest, and it
     was added because this file's own first live run found the damage (2026-09-12): every self-test case that
     called into the push path WITHOUT passing -LedgerRoot wrote a FIXTURE row into the production ledger. The first
     report off this box read "the remote MOVED while the push waited in 2 of 7", and some of those seven were
     temp-clone pushes from a self-test. A measurement whose corpus contains its own fixtures is worse than no
     measurement - the estate's rule is that when code under test writes a real path BY DEFAULT, the default is
     redirected SUITE-WIDE rather than per fixture, because the fixture that forgets is exactly the one that does
     the damage. Each suite also asserts that no row carrying its own pid reached the production file. #>
  param([string]$Root = '', [datetime]$Now = [datetime]::Now)
  $r = $Root
  if (-not $r) { $r = [string]$env:TC_PUSH_LEDGER_ROOT }
  if (-not $r) { $r = $script:TcPushLedgerRoot }
  return (Join-Path $r ('pushes-' + $Now.ToString('yyyy-MM-dd') + '.jsonl'))
}

function New-TcPushRowText {
  <# The row, as one line of JSON. PURE - it runs no git and touches no disk, so every field combination has a case.

     BaseSha is refs/remotes/origin/<branch> as it stood when this push started waiting, GrantSha the same ref when
     the lock was granted. Both are read from the SHARED .git on this box, which every landing from this box updates
     ("update by push" in the reflog), so a difference between them is a landing that happened under this push's
     feet. Either one empty means the ref could not be read, and that is UNKNOWN, never "it did not move". #>
  param(
    [string]$Event,
    [double]$WaitMs = -1,
    [string]$State = '',
    [string]$BaseSha = '',
    [string]$GrantSha = '',
    [string]$Outcome = '',
    [string]$Checkout = '',
    [datetime]$Now = [datetime]::UtcNow
  )
  $row = [ordered]@{
    ts       = $Now.ToString('yyyy-MM-ddTHH:mm:ssZ')
    pid      = $PID
    event    = [string]$Event
    waitMs   = [math]::Round([double]$WaitMs)
    state    = [string]$State
    base     = [string]$BaseSha
    grant    = [string]$GrantSha
    outcome  = [string]$Outcome
    checkout = [string]$Checkout
  }
  # -Compress keeps a row to one line, which is what makes the file appendable and readable line by line.
  return (ConvertTo-Json ([pscustomobject]$row) -Compress)
}

function Read-TcPushRows {
  <# Every row in a ledger file, parsed. A line that will not parse is RETURNED as a malformed marker rather than
     dropped, because a parser that quietly skips what it cannot read reports a clean count over nothing. #>
  param([string]$Path)
  $rows = [Collections.Generic.List[object]]::new()
  if (-not (Test-Path -LiteralPath $Path)) { return @() }
  $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
  foreach ($ln in $lines) {
    $t = [string]$ln
    if (-not $t.Trim()) { continue }
    $o = $null
    try { $o = $t | ConvertFrom-Json } catch { $o = $null }
    if ($null -eq $o) { $rows.Add([pscustomobject]@{ malformed = $true; text = $t }); continue }
    $rows.Add($o)
  }
  return $rows.ToArray()
}

function Get-TcPushPercentile {
  <# NEAREST RANK over an already-sorted array: the smallest value at or above the given fraction of the samples.
     Stated because the other plausible index - floor((n-1)*p), which is linear interpolation's lower neighbour -
     reads the SECOND of three values as a p90, and a percentile that cannot reach the top of a small sample is the
     wrong one for a distribution whose tail is the thing being measured. Returns -1 for no samples, never 0, so a
     reader cannot mistake an empty distribution for a fast one. #>
  param($Sorted, [double]$Fraction)
  # $null FIRST: @($null).Count is 1 under PowerShell, so wrapping before this test would score an absent sample set
  # as one sample and return $null as a percentile ([[ps-null-count-is-one]]).
  if ($null -eq $Sorted) { return -1 }
  $a = @($Sorted)
  if (-not $a.Count) { return -1 }
  $idx = [int][math]::Ceiling($Fraction * $a.Count) - 1
  if ($idx -lt 0) { $idx = 0 }
  if ($idx -ge $a.Count) { $idx = $a.Count - 1 }
  return $a[$idx]
}

function Measure-TcPushRows {
  <# The distribution, from rows. PURE.

     EVERY RATE CARRIES ITS DENOMINATOR (measurement.md), and there are THREE different ones here, which is the
     whole reason this is a function rather than a couple of counts:
       Rows        - every row read, malformed ones included.
       Waited      - rows that actually queued (waitMs > 0). A push that took the lock at once waited for nobody and
                     tells you nothing about contention, so it is not in the wait distribution.
       Comparable  - rows carrying BOTH shas. Only these can say whether the remote moved; the rest are Unknown. #>
  param($Rows)
  $all = @($Rows)
  $malformed = @($all | Where-Object { $_.PSObject.Properties['malformed'] }).Count
  $good = @($all | Where-Object { -not $_.PSObject.Properties['malformed'] })
  $waits = @($good | Where-Object { $null -ne $_.waitMs -and [double]$_.waitMs -gt 0 } | ForEach-Object { [double]$_.waitMs })
  $waits = @($waits | Sort-Object)
  $comparable = @($good | Where-Object { [string]$_.base -and [string]$_.grant })
  $moved = @($comparable | Where-Object { -not [string]::Equals([string]$_.base, [string]$_.grant, [StringComparison]::Ordinal) })
  # Of the pushes that BOTH waited and can be compared: the quantity the brief asked for, and the one that decides
  # whether retrying can ever converge.
  $movedWhileWaiting = @($moved | Where-Object { $null -ne $_.waitMs -and [double]$_.waitMs -gt 0 })
  $waitedComparable = @($comparable | Where-Object { $null -ne $_.waitMs -and [double]$_.waitMs -gt 0 })
  return [pscustomobject]@{
    Rows              = $all.Count
    Malformed         = $malformed
    Waited            = $waits.Count
    WaitMedianMs      = (Get-TcPushPercentile $waits 0.5)
    WaitP90Ms         = (Get-TcPushPercentile $waits 0.9)
    WaitMaxMs         = (Get-TcPushPercentile $waits 1.0)
    Comparable        = $comparable.Count
    Unknown           = ($good.Count - $comparable.Count)
    Moved             = $moved.Count
    WaitedComparable  = $waitedComparable.Count
    MovedWhileWaiting = $movedWhileWaiting.Count
  }
}

function Get-TcPushLedgerRefSha {
  <# One ref, read from a checkout, as a sha or ''. The ONE git caller in this file, and it runs through the process
     API rather than the call operator so no stderr redirect is needed: under EAP=Stop a native child's first stderr
     line is a terminating throw, and a catch around it throws the answer away (ops-and-gates.md). '' is a
     could-not-read and its caller must treat it as UNKNOWN. #>
  param([string]$Dir, [string]$Ref)
  try {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.Arguments = ('-C "' + $Dir + '" rev-parse --verify --quiet ' + $Ref)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    try {
      $o = $p.StandardOutput.ReadToEndAsync()
      $e = $p.StandardError.ReadToEndAsync()
      $null = $e.Result
      if (-not $p.WaitForExit(15000)) { return '' }
      if ($p.ExitCode -ne 0) { return '' }
      $sha = ([string]$o.Result).Trim()
      if ($sha -match '^[0-9a-f]{7,40}$') { return $sha }
      return ''
    } finally { $p.Dispose() }
  } catch {
    return ''
  }
}

function Write-TcPushRow {
  <# Append one row. Returns Written / Reason / Path and NEVER throws: the caller is a push, and a ledger must not be
     able to refuse one. A failure is reported in Reason so a case can read it - a fallback nobody can see is the
     blind kind this estate has a rule about. #>
  param(
    [string]$Event,
    [double]$WaitMs = -1,
    [string]$State = '',
    [string]$BaseSha = '',
    [string]$GrantSha = '',
    [string]$Outcome = '',
    [string]$Checkout = '',
    [string]$Root = ''
  )
  $path = ''
  try {
    $path = Get-TcPushLedgerPath -Root $Root
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -ErrorAction Stop $dir }
    $text = New-TcPushRowText -Event $Event -WaitMs $WaitMs -State $State -BaseSha $BaseSha -GrantSha $GrantSha `
      -Outcome $Outcome -Checkout $Checkout
    $null = Add-TcLine -Path $path -Text $text
    return [pscustomobject]@{ Written = $true; Reason = ''; Path = $path }
  } catch {
    return [pscustomobject]@{ Written = $false; Reason = [string]$_.Exception.Message; Path = $path }
  }
}

if ($__pldSelfTest) {
  $f = 0; $cases = 0
  $kMF = 'MUST' + ' FIRE'; $kMNF = 'MUST' + ' NOT FIRE'; $kCT = 'CLEAN' + ' TWIN'
  function T($m, $cond, $got) {
    $script:cases++
    if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ }
  }
  # A UNIQUE DIRECTORY PER RUN: run-gates runs every self-test and pre-push runs run-gates, so concurrent pushes run
  # this file over each other in one %TEMP% (ops-and-gates.md's fixed-temp-name rule).
  $tmp = Join-Path $env:TEMP ('tc-pld-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  $null = New-Item -ItemType Directory -Force -ErrorAction Stop $tmp
  $A = '1111111111111111111111111111111111111111'
  $B = '2222222222222222222222222222222222222222'
  # THE WHOLE SUITE WRITES TO SCRATCH. Set before the first case and restored in the finally: a case that forgets
  # -Root must not be able to reach the production ledger, because a fixture row there is indistinguishable from a
  # real push afterwards.
  $prodPath = Get-TcPushLedgerPath
  $ledgerRootWas = $env:TC_PUSH_LEDGER_ROOT
  $env:TC_PUSH_LEDGER_ROOT = Join-Path $tmp 'suite'
  try {
    # ---- the row, on fixed inputs ----
    $txt = New-TcPushRowText -Event 'hook-lock' -WaitMs 1130000 -State 'held' -BaseSha $A -GrantSha $B -Outcome 'landed' -Checkout 'wt'
    $back = $txt | ConvertFrom-Json
    T ($kMNF + '  a row is ONE line of JSON and reads back with every field it was given') `
      (($txt -notmatch "`n") -and $back.event -eq 'hook-lock' -and [double]$back.waitMs -eq 1130000 -and $back.base -eq $A -and $back.grant -eq $B) `
      ("lines={0} event={1} wait={2}" -f (@($txt -split "`n").Count), $back.event, $back.waitMs)

    # ---- the measurement, which is the point of the file ----
    $rows = @(
      (New-TcPushRowText -Event 'hook-lock' -WaitMs 1130000 -State 'held' -BaseSha $A -GrantSha $B | ConvertFrom-Json),
      (New-TcPushRowText -Event 'hook-lock' -WaitMs 1313000 -State 'held' -BaseSha $A -GrantSha $B | ConvertFrom-Json),
      (New-TcPushRowText -Event 'hook-lock' -WaitMs 2000 -State 'held' -BaseSha $A -GrantSha $A | ConvertFrom-Json),
      (New-TcPushRowText -Event 'hook-lock' -WaitMs 0 -State 'held' -BaseSha $A -GrantSha $A | ConvertFrom-Json)
    )
    $m = Measure-TcPushRows $rows
    T ($kMF + '  a row whose ref moved between the start of the wait and the grant is counted as MOVED WHILE WAITING') `
      ($m.MovedWhileWaiting -eq 2 -and $m.Moved -eq 2) ("movedWhileWaiting={0} moved={1}" -f $m.MovedWhileWaiting, $m.Moved)
    T ($kMNF + '  a row whose ref stood still is not counted as moved, and a push that never queued is not in the wait distribution') `
      ($m.Waited -eq 3 -and $m.WaitedComparable -eq 3 -and $m.Rows -eq 4) ("waited={0} waitedComparable={1} rows={2}" -f $m.Waited, $m.WaitedComparable, $m.Rows)
    T ($kCT + '  the wait distribution reports median, p90 and max over the rows that actually queued') `
      ($m.WaitMedianMs -eq 1130000 -and $m.WaitMaxMs -eq 1313000 -and $m.WaitP90Ms -eq 1313000) `
      ("median={0} p90={1} max={2}" -f $m.WaitMedianMs, $m.WaitP90Ms, $m.WaitMaxMs)
    # THE PERCENTILE'S OWN RANK RULE, on a sample small enough to tell the two definitions apart: over three samples
    # a nearest-rank p90 is the THIRD, and the floor((n-1)*p) form used first here returned the second. A fixture
    # that only ever saw large samples could not see the difference.
    T ($kMF + '  a p90 over three samples reaches the largest of them, so a tail cannot hide inside a small sample') `
      ((Get-TcPushPercentile @(1, 2, 3) 0.9) -eq 3 -and (Get-TcPushPercentile @(1, 2, 3) 0.5) -eq 2) `
      ("p90={0} median={1}" -f (Get-TcPushPercentile @(1, 2, 3) 0.9), (Get-TcPushPercentile @(1, 2, 3) 0.5))
    T ($kMNF + '  a percentile of no samples is -1, never 0 and never a value read out of an empty array') `
      ((Get-TcPushPercentile @() 0.9) -eq -1 -and (Get-TcPushPercentile $null 0.9) -eq -1) `
      ("empty={0} null={1}" -f (Get-TcPushPercentile @() 0.9), (Get-TcPushPercentile $null 0.9))

    # A COULD-NOT-READ IS UNKNOWN, NEVER A "DID NOT MOVE". Without this a box where git could not be reached would
    # report a perfect zero-staleness rate, which is the agreeing-number shape this estate keeps paying for.
    $blindRows = @(
      (New-TcPushRowText -Event 'hook-lock' -WaitMs 5000 -State 'held' -BaseSha '' -GrantSha '' | ConvertFrom-Json),
      (New-TcPushRowText -Event 'hook-lock' -WaitMs 5000 -State 'held' -BaseSha $A -GrantSha '' | ConvertFrom-Json)
    )
    $mb = Measure-TcPushRows $blindRows
    T ($kMF + '  a row that could not read the ref counts as UNKNOWN and stays out of the moved rate entirely') `
      ($mb.Unknown -eq 2 -and $mb.Comparable -eq 0 -and $mb.Moved -eq 0 -and $mb.WaitedComparable -eq 0) `
      ("unknown={0} comparable={1} moved={2} waitedComparable={3}" -f $mb.Unknown, $mb.Comparable, $mb.Moved, $mb.WaitedComparable)
    $mEmpty = Measure-TcPushRows @()
    T ($kCT + '  no rows at all reports zero rows and a wait distribution of -1, never a median over nothing') `
      ($mEmpty.Rows -eq 0 -and $mEmpty.WaitMedianMs -eq -1) ("rows={0} median={1}" -f $mEmpty.Rows, $mEmpty.WaitMedianMs)

    # ---- writing, for real ----
    $root = Join-Path $tmp 'led'
    $w1 = Write-TcPushRow -Event 'hook-lock' -WaitMs 12 -State 'held' -BaseSha $A -GrantSha $B -Outcome 'landed' -Root $root
    $w2 = Write-TcPushRow -Event 'push-main' -WaitMs 34 -State 'held' -BaseSha $A -GrantSha $A -Outcome 'landed' -Root $root
    $read = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $root)
    T ($kCT + '  two writes to the same ledger both land, and read back as two rows') `
      ($w1.Written -and $w2.Written -and @($read).Count -eq 2 -and @($read | Where-Object { $_.event -eq 'push-main' }).Count -eq 1) `
      ("w1={0} w2={1} rows={2}" -f $w1.Written, $w2.Written, @($read).Count)

    # A MALFORMED LINE IS NAMED, NOT DROPPED. A reader that skips what it cannot parse prints a clean count over
    # nothing, which is the empty-result shape this estate has been bitten by five times.
    Add-Content -LiteralPath (Get-TcPushLedgerPath -Root $root) -Value 'this is not json' -Encoding utf8
    $read2 = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $root)
    $m2 = Measure-TcPushRows $read2
    T ($kMF + '  a line that will not parse is counted as malformed rather than silently skipped') `
      (@($read2).Count -eq 3 -and $m2.Malformed -eq 1 -and $m2.Comparable -eq 2) `
      ("rows={0} malformed={1} comparable={2}" -f @($read2).Count, $m2.Malformed, $m2.Comparable)

    # THE LEDGER MUST NOT BE ABLE TO REFUSE A PUSH. The root is a FILE here, so the directory cannot be created.
    $blocked = Join-Path $tmp 'blocked'
    [IO.File]::WriteAllText($blocked, 'not a directory')
    $wBad = Write-TcPushRow -Event 'hook-lock' -WaitMs 1 -State 'held' -Root $blocked
    T ($kMF + '  a ledger that cannot be written reports it in words and does NOT throw into the push') `
      ((-not $wBad.Written) -and $wBad.Reason) ("written={0} reason={1}" -f $wBad.Written, $wBad.Reason)

    # ---- the ref reader ----
    $shaHere = Get-TcPushLedgerRefSha -Dir (Split-Path -Parent $PSScriptRoot) -Ref 'HEAD'
    T ($kCT + '  the ref reader returns a sha for a ref this checkout has') ($shaHere -match '^[0-9a-f]{7,40}$') ("sha={0}" -f $shaHere)
    $shaNo = Get-TcPushLedgerRefSha -Dir (Split-Path -Parent $PSScriptRoot) -Ref 'refs/heads/no-such-branch-here-42'
    T ($kMF + '  a ref that does not exist reads as empty, so its caller records UNKNOWN rather than a sha it invented') `
      ($shaNo -eq '') ("sha={0}" -f $shaNo)

    # A ROW WITH A DEFAULT ROOT GOES TO THE SUITE'S SCRATCH, NOT TO THE PRODUCTION LEDGER. This is the case that
    # catches the redirect being removed - the thing that put fixture rows into the first live report.
    $wDefault = Write-TcPushRow -Event 'hook-lock' -WaitMs 7 -State 'held' -BaseSha $A -GrantSha $B
    $prodRaw = Read-TcPushRows -Path $prodPath
    $prodRows = @($prodRaw)
    $mine = @($prodRows | Where-Object { -not $_.PSObject.Properties['malformed'] -and [int]$_.pid -eq $PID })
    T ($kMF + '  a write with no root given lands in this suite''s scratch, and NOTHING this suite wrote reached the production ledger') `
      ($wDefault.Written -and $wDefault.Path -notlike ($script:TcPushLedgerRoot + '*') -and $mine.Count -eq 0) `
      ("path={0} rowsFromThisProcessInProduction={1}" -f $wDefault.Path, $mine.Count)
  } finally {
    if ($null -eq $ledgerRootWas) {
      Remove-Item -LiteralPath Env:TC_PUSH_LEDGER_ROOT -ErrorAction SilentlyContinue
    } else {
      $env:TC_PUSH_LEDGER_ROOT = $ledgerRootWas
    }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($f) { Write-Output ("push-ledger self-test FAIL: {0} of {1} check(s)" -f $f, $cases); exit 1 }
  Write-Output ("push-ledger self-test PASS: {0} cases - led by a push whose ref moved between the start of its wait and the grant being counted as moved-while-waiting, and by a ref that could not be read counting UNKNOWN rather than as a ref that stood still" -f $cases)
  exit 0
}
