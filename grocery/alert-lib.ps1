<#
  alert-lib.ps1 - the ONE way a pipeline script may send an ops alert. Dot-source it, then call Send-Alert.

      . (Join-Path $root 'alert-lib.ps1')
      Send-Alert -Subject "Grocery: something broke" -Body $body | Out-Null
      if ($LASTEXITCODE -eq 0) { <burn the de-dup sig> }

  WHY THIS EXISTS (2026-08-06). Every alerting script in this estate invoked the mailer the same way:

      & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject "..." -Body $body

  Windows caps an entire command line at 32767 characters, and CreateProcess does not TRUNCATE at the cap -
  it refuses to start the process at all. So an alert whose body outgrows the cap does not arrive clipped;
  it does not arrive. Measured on the one body in the estate with no bound on it by construction - the
  watchers' whole test-auditors output, passed as -Body from check-ad-cycles.ps1 - the argument was
  43,030 / 43,283 / 43,718 characters on 2026-08-03/04/05, the three consecutive days a guard was blind.
  On all three days the child never launched. There was no email, and no triage-queue entry either (the
  queue is written INSIDE send-alert.ps1, so a mailer that never starts skips the durable record too), and
  the caller's catch swallowed the launch error and logged it as

      [2026-08-03T09:17:50] test-auditors threw: Program 'powershell.exe' failed to run: The filename or
      extension is too long...

  which reads like the TEST crashed rather than like the PAGE NEVER WENT OUT. A watcher stayed red for four
  days and nobody was told. The failure was in the delivery, and it wore the costume of the thing it was
  supposed to be delivering.

  Three properties, and they are the whole point of routing every caller through one function:

    1. THE BODY TRAVELS BY FILE (-BodyFile), never on the command line, so its length cannot break the send.
       This also retires the body truncation noted in check-ad-cycles.ps1 on 2026-07-31, and the quoted-body
       re-splitting that cost notify-desktop.ps1 its email leg the same week: the shell never sees the body.
    2. A FAILED SEND IS LOUD AND NAMED. "ALERT FAILED TO SEND" is its own line, distinct from whatever the
       failing check reported, so the record shows the difference between "the check failed" and "nobody was
       told the check failed". A swallowed launch error is indistinguishable from the check itself dying -
       that ambiguity is what made the four-day outage above readable as something else entirely.
    3. IT NEVER THROWS, and it leaves $LASTEXITCODE holding the real send result, so the many callers that
       burn a .sig / marker file `if ($LASTEXITCODE -eq 0)` keep working unchanged - and a send that never
       launched now reads as a failure there instead of inheriting a stale 0 from an earlier command.

    4. FROM A LINKED WORKTREE IT SENDS THROUGH THE MAIN CHECKOUT'S send-alert.ps1 (2026-09-19, backlog I232).
       Everything an alert touches is main-checkout state: the Gmail credential (.claude\skills\lesson\
       google-oauth-client.json and its token, gitignored and never seeded into a worktree), the triage queue
       the triage agent drains, the once-per-type-per-day sent-file and alert-log.txt. Sent from a worktree, the
       mail failed for want of the credential (2026-09-19 05:49, the verify-board-sample agent), the queue item
       landed in a file triage never reads, and the worktree was left with alert-log.txt modified and the
       tracked alert-sent-<date>.txt deleted by the purge, which made push-main refuse "uncommitted changes".
       Copying the credential into every worktree was the other fix on offer and is refused: it multiplies a
       secret into 100+ directories, each refreshing its own copy of the token, and fixes the mail while
       leaving the queue, the gate and the log split. The main checkout is found by reading the worktree's own
       .git pointer and its commondir, never by running git (a hook's GIT_DIR would answer for another tree).
       Anything that is not a linked worktree - the main checkout, a clone, a test-auditors fixture copied into
       %TEMP% - sends through its own send-alert.ps1 exactly as before, and so does a worktree whose main
       checkout has no send-alert.ps1, which the failure line then names.

  Do NOT go back to calling send-alert.ps1 through `powershell -File` with a -Body argument. Calling it
  IN-PROCESS (`& (Join-Path $root 'send-alert.ps1') -Subject $s -Body $b`, as notify-desktop.ps1 does) is
  also safe - there is no command line in that form - but this helper is preferred because it is the only
  form that also makes a failed send loud.
#>

# Captured at dot-source time: inside a dot-sourced file $PSScriptRoot is the LIB's directory, not the
# caller's, and stashing it here keeps it correct for callers that live in another folder entirely
# (meal-prep\pipeline\compute-v2-perserving.ps1 reaches across the tree for the same mailer).
$script:ALERT_LIB_DIR = $PSScriptRoot
# The self-test gate, in the dot-sourced form: this file has no param() block because, dot-sourced under PS 5.1, one
# would reset the caller's own switches. Run it with: powershell -File grocery\alert-lib.ps1 -SelfTest
$__alertLibSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

function Get-AlertMainCheckoutRoot {
  # The main checkout behind $RepoRoot when $RepoRoot is a LINKED worktree, else $null. Reads files only: a linked
  # worktree's .git is a FILE saying `gitdir: <main>\.git\worktrees\<name>`, and that directory's `commondir` names
  # the shared .git (git writes `../..`). $null for a .git directory (the main checkout itself), for no .git at all,
  # and for anything that does not resolve to a directory named .git with a checkout around it.
  param([string]$RepoRoot)
  if (-not $RepoRoot) { return $null }
  $dotGit = Join-Path $RepoRoot '.git'
  if (-not [IO.File]::Exists($dotGit)) { return $null }
  $lines = @([IO.File]::ReadAllLines($dotGit))
  if ($lines.Count -eq 0) { return $null }
  $m = [regex]::Match([string]$lines[0], '^gitdir:\s*(.+?)\s*$')
  if (-not $m.Success) { return $null }
  $gd = $m.Groups[1].Value.Replace('/', '\')
  if (-not [IO.Path]::IsPathRooted($gd)) { $gd = Join-Path $RepoRoot $gd }
  $cdFile = Join-Path $gd 'commondir'
  if (-not [IO.File]::Exists($cdFile)) { return $null }
  $cd = ([IO.File]::ReadAllText($cdFile)).Trim().Replace('/', '\')
  if (-not $cd) { return $null }
  if (-not [IO.Path]::IsPathRooted($cd)) { $cd = Join-Path $gd $cd }
  $cd = ([IO.Path]::GetFullPath($cd)).TrimEnd('\')
  if ([IO.Path]::GetFileName($cd) -ine '.git') { return $null }
  if (-not [IO.Directory]::Exists($cd)) { return $null }
  return [IO.Path]::GetDirectoryName($cd)
}

function Get-AlertSenderPath {
  # Which send-alert.ps1 Send-Alert runs, for the lib living in $LibDir. { Path; Routed = 'main' | 'local'; Why }.
  param([string]$LibDir)
  $local = Join-Path $LibDir 'send-alert.ps1'
  $main = Get-AlertMainCheckoutRoot -RepoRoot (Split-Path -Parent $LibDir)
  if (-not $main) { return [pscustomobject]@{ Path = $local; Routed = 'local'; Why = '' } }
  $cand = Join-Path (Join-Path $main (Split-Path -Leaf $LibDir)) 'send-alert.ps1'
  if ([IO.File]::Exists($cand)) { return [pscustomobject]@{ Path = $cand; Routed = 'main'; Why = '' } }
  return [pscustomobject]@{ Path = $local; Routed = 'local'
    Why = ('sent from a linked worktree through its own send-alert.ps1, because the main checkout has no ' + $cand + ', so the credential, queue and log are this worktree''s') }
}

function Send-Alert {
  param(
    [Parameter(Mandatory = $true)][string]$Subject,
    # -Body is spooled to a temp file and passed as -BodyFile. -BodyFile is used as-is, which is what you
    # want when the caller has ALREADY persisted the evidence (check-ad-cycles' dated test-auditors-fail
    # file): nothing is copied, and the mail carries the whole artefact.
    [string]$Body = '',
    [string]$BodyFile = '',
    # short tag for the log line, e.g. 'WATCHERS'. Defaults to the subject.
    [string]$What = '',
    # passed straight through to send-alert.ps1 for callers that run their own signature de-dup
    [switch]$Force,
    # passed straight through to send-alert.ps1 -CausedBy (2026-09-10, plan Phase 1): the open incident this alert
    # is a consequence of. Unknown, absent or not-currently-open incidents send normally.
    [string]$CausedBy = ''
  )
  $tag = if ($What) { $What } else { $Subject }
  $tmp = $null
  try {
    $bf = $BodyFile
    if (-not $bf) {
      # Spool to %TEMP%, never beside the caller: grocery\out\ is TRACKED (see the allow-list in
      # .gitignore), so a stray body file there would be swept into a commit by the daily job's
      # `git add -A`. Deleted in the finally below either way.
      $spoolDir = if ($env:TEMP -and (Test-Path $env:TEMP)) { $env:TEMP } else { $script:ALERT_LIB_DIR }
      $tmp = Join-Path $spoolDir ('smp-alert-body-' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '.txt')
      Set-Content -Path $tmp -Value $Body -Encoding UTF8
      $bf = $tmp
    }
    # ---- WHO EMITTED THIS ALERT (2026-09-05, queue 2026-09-04-bf1642) -----------------------------------
    # A queue item recorded WHAT broke and WHEN, never WHICH CODE SAID SO. On 2026-09-04 an alert fired at
    # 14:57 and the commit that DELETED the arm which emitted it landed at 15:56 - 59 minutes later. Proving
    # that item stale cost a git archaeology across three files, and every triage round would have paid it
    # again for every same-day fix. The provenance is free right here: the call stack knows the caller.
    # Frames belonging to this lib are skipped, so the emitter is the script that decided to page, not the
    # helper it paged through. This is a diagnostic stamp: it must never be able to stop an alert, so the
    # whole thing sits in its own try and an empty answer is a perfectly good answer.
    $emitter = ''
    try {
      $frames = @(Get-PSCallStack | Where-Object { $_.ScriptName -and ($_.ScriptName -notmatch '[\\/]alert-lib\.ps1$') })
      if ($frames.Count) { $emitter = [string]$frames[0].ScriptName }
    } catch { $emitter = '' }
    # From a linked worktree this is the MAIN checkout's send-alert.ps1 (Get-AlertSenderPath says why).
    $saPick = Get-AlertSenderPath -LibDir $script:ALERT_LIB_DIR
    $sa = $saPick.Path
    $incArgs = @()
    if ($CausedBy) { $incArgs = @('-CausedBy', $CausedBy) }
    # -Emitter only when there is one (2026-09-19). powershell.exe drops an EMPTY native argument, so `-Emitter ''`
    # arrived as a bare -Emitter and send-alert.ps1 died "Missing an argument for parameter 'Emitter'" before it
    # queued or mailed anything: every Send-Alert whose call stack named no script (a console, this self-test).
    if ($emitter) { $incArgs = @('-Emitter', $emitter) + $incArgs }
    if ($Force) { & powershell -ExecutionPolicy Bypass -File $sa -Subject $Subject -BodyFile $bf -Force @incArgs | Out-Null }
    else        { & powershell -ExecutionPolicy Bypass -File $sa -Subject $Subject -BodyFile $bf @incArgs | Out-Null }
    $rc = $LASTEXITCODE
    if ($rc -ne 0) {
      Write-AlertLog ('ALERT FAILED TO SEND [' + $tag + '] "' + $Subject + '" - send-alert.ps1 exited ' + $rc + '. See the alert-log.txt beside ' + $sa + '. The condition it describes is real and UNPAGED.' + $(if ($saPick.Why) { ' (' + $saPick.Why + ')' } else { '' }))
    }
    $global:LASTEXITCODE = $rc
    return $rc
  } catch {
    $why = ((([string]$_.Exception.Message) -split "`r?`n")[0]).Trim()
    Write-AlertLog ('ALERT FAILED TO SEND [' + $tag + '] "' + $Subject + '" - send-alert.ps1 NEVER RAN (' + $why + '), so there is no email AND no triage-queue entry. The condition it describes is real and UNPAGED.')
    $global:LASTEXITCODE = 9
    return 9
  } finally {
    if ($tmp) { try { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } catch {} }
  }
}

# ---- ONE CONDITION, ONE ALERT TYPE (2026-09-21, plan-2026-09-21-5.json) ------------------------------------------
# Four emitters used to page as one catch-all type per run: "Grocery capture watchdog: N issue(s)", "store-registry
# drift - N issue(s)", "Family Fare catalog is degrading - N signal(s)", "Automation silent-death: N issue(s)". The type
# key strips the number, so every unrelated cause filed under one name: measured over the 30 days ending 2026-09-21 the
# capture watchdog alone carried 7 distinct conditions under one type (RUN RECORD, AD STALE, NO FRESH ROWS, GRAPH
# SCHEMA, ...), each new cause counted as a RETURN of a type triage had already closed, and no one cause's fix could
# ever close the type. The unit of triage is now ONE CONDITION: its own subject, registry entry, dedupe key and return
# count. The body carries the condition's own lines and a pointer to the emitter's full report; healthy lines stay in
# that report.
#
# THE INBOX DOES NOT MULTIPLY. Each condition goes through the real send-alert.ps1 with -DeferMail: the durable queue
# write, the registry class, hold_observations and the once-per-type-per-day gate all run per condition exactly as for
# any alert, and a condition that would have mailed prints MAIL-DUE instead of sending. Then ONE digest-class message
# per emitter run lists every due condition, sent through the same send-alert.ps1 (the only delivery path) with
# -MarkSentTypes so each listed condition counts as mailed today. Every queue write happens before that one send.
# A condition whose sender failed outright is listed in the digest anyway: a condition this lib could not record pages.

function Get-AlertConditionKey {
  # The condition a finding line reports: its leading label up to the first ': ' ("RUN RECORD: capture-run ..." ->
  # "RUN RECORD"). A line with no short label keeps its first four words, so it is still its own condition.
  param([string]$Line)
  $t = ([string]$Line).Trim()
  $m = [regex]::Match($t, '^([A-Za-z][A-Za-z \-\\.'']{0,60}?):\s')
  if ($m.Success) { return $m.Groups[1].Value.Trim() }
  return ((@($t -split '\s+') | Select-Object -First 4) -join ' ')
}

function Send-AlertConditions {
  param(
    # The emitter's name, e.g. 'Grocery capture watchdog'. Each condition's subject is '<prefix>: <label>'.
    [Parameter(Mandatory = $true)][string]$SubjectPrefix,
    # Finding lines. A string is keyed by Get-AlertConditionKey; an object carrying Label and Text keeps its Label.
    [object[]]$Conditions = @(),
    # One line under every condition body: where the full report (healthy checks included) lives.
    [string]$ReportPointer = '',
    # Appended to each subject, e.g. today's date. The type key strips it.
    [string]$DateStamp = '',
    # Fixture seams: passed to every send-alert.ps1 call (a self-test passes its own -QueueMutexName).
    [string[]]$SenderArgs = @()
  )
  $res = [pscustomobject]@{ conditions = 0; due = @(); failed = @(); digest_rc = -1; rc = 0 }
  $groups = [ordered]@{}
  foreach ($c in @($Conditions)) {
    if ($null -eq $c) { continue }
    $label = ''; $text = ''
    if ($c -is [string]) { $text = $c; $label = Get-AlertConditionKey $c }
    else { $text = [string]$c.Text; $label = [string]$c.Label; if (-not $label) { $label = Get-AlertConditionKey $text } }
    if (-not $text.Trim()) { continue }
    if (-not $groups.Contains($label)) { $groups[$label] = New-Object System.Collections.Generic.List[string] }
    [void]$groups[$label].Add($text.Trim())
  }
  $res.conditions = $groups.Count
  if ($groups.Count -eq 0) { $global:LASTEXITCODE = 0; return $res }
  $saPick = Get-AlertSenderPath -LibDir $script:ALERT_LIB_DIR
  $emArgs = @()
  try {
    $frames = @(Get-PSCallStack | Where-Object { $_.ScriptName -and ($_.ScriptName -notmatch '[\\/]alert-lib\.ps1$') })
    if ($frames.Count) { $emArgs = @('-Emitter', [string]$frames[0].ScriptName) }
  } catch { $emArgs = @() }
  $spoolDir = if ($env:TEMP -and (Test-Path $env:TEMP)) { $env:TEMP } else { $script:ALERT_LIB_DIR }
  $due = New-Object System.Collections.Generic.List[object]
  $tmps = New-Object System.Collections.Generic.List[string]
  try {
    foreach ($label in $groups.Keys) {
      $subj = ($SubjectPrefix + ': ' + $label + $(if ($DateStamp) { ' ' + $DateStamp } else { '' }))
      $body = (($groups[$label] | ForEach-Object { ' - ' + $_ }) -join "`n")
      if ($ReportPointer) { $body += "`n`n" + $ReportPointer }
      $bf = Join-Path $spoolDir ('smp-alert-cond-' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '.txt')
      [void]$tmps.Add($bf)
      [IO.File]::WriteAllText($bf, $body, (New-Object Text.UTF8Encoding($false)))
      $out = @()
      $rc = 9
      try {
        $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $saPick.Path -Subject $subj -BodyFile $bf -DeferMail @emArgs @SenderArgs)
        $rc = $LASTEXITCODE
      } catch { $out = @('send-alert.ps1 NEVER RAN: ' + $_.Exception.Message); $rc = 9 }
      $dueLine = @($out | Where-Object { ([string]$_) -match '^MAIL-DUE ' })
      if ($dueLine.Count) { [void]$due.Add([pscustomobject]@{ label = $label; subject = $subj; type = ([string]$dueLine[0]).Substring(9).Trim(); body = $body; note = '' }) }
      elseif ($rc -ne 0) {
        # fail toward page: this condition may not be in the queue at all, so it goes in the one message
        $res.failed += $label
        [void]$due.Add([pscustomobject]@{ label = $label; subject = $subj; type = ''; body = $body; note = ('send-alert.ps1 exited ' + $rc + ' for this condition, so its queue item may not exist') })
        Write-AlertLog ('ALERT FAILED TO SEND [' + $subj + '] - send-alert.ps1 exited ' + $rc + '; it is listed in the digest instead. ' + (($out | Select-Object -Last 2) -join ' | '))
      }
    }
    $res.due = @($due.ToArray())
    if ($due.Count -eq 0) { $global:LASTEXITCODE = 0; return $res }
    $dSubj = ($SubjectPrefix + ': ' + $due.Count + ' condition(s) need action' + $(if ($DateStamp) { ' ' + $DateStamp } else { '' }))
    $dBody = ($SubjectPrefix + ' - ' + $due.Count + " condition(s). Each is its own triage-queue item with its own type.`n")
    foreach ($d in $due) {
      $dBody += "`n[" + $d.label + "]`n" + $d.body + "`n"
      if ($d.note) { $dBody += '   (' + $d.note + ")`n" }
    }
    $dbf = Join-Path $spoolDir ('smp-alert-digest-' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '.txt')
    [void]$tmps.Add($dbf)
    [IO.File]::WriteAllText($dbf, $dBody, (New-Object Text.UTF8Encoding($false)))
    $mark = (@($due | Where-Object { $_.type } | ForEach-Object { $_.type }) -join '|')
    $mArgs = @()
    if ($mark) { $mArgs = @('-MarkSentTypes', $mark) }
    $dOut = @()
    try {
      $dOut = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $saPick.Path -Subject $dSubj -BodyFile $dbf -Force @mArgs @emArgs @SenderArgs)
      $res.digest_rc = $LASTEXITCODE
    } catch { $res.digest_rc = 9; $dOut = @($_.Exception.Message) }
    $res | Add-Member -NotePropertyName digest_out -NotePropertyValue (($dOut | ForEach-Object { [string]$_ }) -join ' | ')
    if ($res.digest_rc -ne 0) { Write-AlertLog ('ALERT FAILED TO SEND [' + $dSubj + '] - send-alert.ps1 exited ' + $res.digest_rc + '. The conditions are queued; the one message listing them did not go out.') }
    $res.rc = $res.digest_rc
    if ($res.failed.Count -and $res.rc -eq 0) { $res.rc = 1 }
    $global:LASTEXITCODE = $res.rc
    return $res
  } finally {
    foreach ($t in $tmps) { try { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue } catch {} }
  }
}

# Use the caller's own logger when it has one (check-ad-cycles, run-daily-local and bakers-daily-scan each
# define a lock-tolerant Log), so a failed send lands in the same file as the failure that triggered it.
# Scripts with no logger are report-style: their stdout IS the record, and a dead page belongs in it.
function Write-AlertLog([string]$m) {
  if (Get-Command -Name Log -CommandType Function -ErrorAction SilentlyContinue) {
    try { Log $m; return } catch {}
  }
  try { Write-Output $m } catch {}
}

# ---- SELF-TEST: which send-alert.ps1 runs (2026-09-19, backlog I232) ---------------------------------------------
# Fixture checkouts in a per-run temp directory. The stub senders record that they ran and exit with a code of their
# own, so the end-to-end cases prove WHICH sender Send-Alert launched and that its exit code comes back, and nothing
# real is ever mailed, queued or logged.
if ($__alertLibSelfTest) {
  $alPass = 0; $alFail = 0
  function AlCase([string]$label, [bool]$cond, [string]$detail) {
    if ($cond) { $script:alPass++; Write-Output ('  PASS ' + $label) }
    else { $script:alFail++; Write-Output ('  FAIL ' + $label + ' :: ' + $detail) }
  }
  $alDir = Join-Path $env:TEMP ('alib-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  New-Item -ItemType Directory -Path $alDir -ErrorAction Stop | Out-Null
  $alSavedLibDir = $script:ALERT_LIB_DIR
  try {
    $enc = New-Object System.Text.UTF8Encoding($false)
    function New-AlStub([string]$dir, [int]$code) {
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
      $stub = 'param([string]$Subject, [string]$BodyFile, [string]$Emitter, [switch]$Force, [string]$CausedBy)' + "`r`n" +
              '[IO.File]::WriteAllText((Join-Path $PSScriptRoot ''ran.txt''), $Subject)' + "`r`n" + 'exit ' + $code + "`r`n"
      [IO.File]::WriteAllText((Join-Path $dir 'send-alert.ps1'), $stub, $enc)
    }
    function New-AlLinked([string]$wt, [string]$main, [string]$name) {
      $wd = Join-Path $main ('.git\worktrees\' + $name)
      New-Item -ItemType Directory -Force -Path $wd | Out-Null
      [IO.File]::WriteAllText((Join-Path $wd 'commondir'), "../..`n", $enc)
      New-Item -ItemType Directory -Force -Path $wt | Out-Null
      [IO.File]::WriteAllText((Join-Path $wt '.git'), ('gitdir: ' + $wd.Replace('\', '/') + "`n"), $enc)
    }
    # main + a linked worktree, both carrying a sender; main's exits 7, the worktree's 0
    $mainA = Join-Path $alDir 'main'; $wtA = Join-Path $alDir 'wt'
    New-Item -ItemType Directory -Force -Path (Join-Path $mainA '.git') | Out-Null
    New-AlLinked $wtA $mainA 'wt'
    New-AlStub (Join-Path $mainA 'grocery') 7
    New-AlStub (Join-Path $wtA 'grocery') 0
    # a linked worktree whose main checkout has NO sender
    $mainB = Join-Path $alDir 'main2'; $wtB = Join-Path $alDir 'wt2'
    New-Item -ItemType Directory -Force -Path (Join-Path $mainB '.git') | Out-Null
    New-AlLinked $wtB $mainB 'wt2'
    New-AlStub (Join-Path $wtB 'grocery') 0
    # no .git at all: the test-auditors fixture shape, a lib copied into %TEMP%
    $plain = Join-Path $alDir 'plain'
    New-AlStub (Join-Path $plain 'grocery') 0
    # a .git FILE that is not a gitdir pointer
    $odd = Join-Path $alDir 'odd'
    New-AlStub (Join-Path $odd 'grocery') 0
    [IO.File]::WriteAllText((Join-Path $odd '.git'), "not a pointer`n", $enc)

    $pA = Get-AlertSenderPath -LibDir (Join-Path $wtA 'grocery')
    AlCase 'MUST FIRE a linked worktree sends through the main checkout''s send-alert.ps1' ($pA.Routed -eq 'main' -and $pA.Path -eq (Join-Path $mainA 'grocery\send-alert.ps1')) ('got ' + $pA.Routed + ' ' + $pA.Path)
    $pM = Get-AlertSenderPath -LibDir (Join-Path $mainA 'grocery')
    AlCase 'CLEAN TWIN the main checkout still sends through its own send-alert.ps1' ($pM.Routed -eq 'local' -and $pM.Path -eq (Join-Path $mainA 'grocery\send-alert.ps1') -and -not $pM.Why) ('got ' + $pM.Routed + ' ' + $pM.Path)
    $pP = Get-AlertSenderPath -LibDir (Join-Path $plain 'grocery')
    AlCase 'MUST NOT FIRE a directory that is no checkout at all sends through its own sender' ($pP.Routed -eq 'local' -and $pP.Path -eq (Join-Path $plain 'grocery\send-alert.ps1')) ('got ' + $pP.Routed + ' ' + $pP.Path)
    $pB = Get-AlertSenderPath -LibDir (Join-Path $wtB 'grocery')
    AlCase 'MUST NOT FIRE a worktree whose main checkout has no sender keeps its own, and says why' ($pB.Routed -eq 'local' -and $pB.Path -eq (Join-Path $wtB 'grocery\send-alert.ps1') -and $pB.Why -match 'main checkout has no') ('got ' + $pB.Routed + ' why=' + $pB.Why)
    $pO = Get-AlertSenderPath -LibDir (Join-Path $odd 'grocery')
    AlCase 'MUST NOT FIRE a .git file that is not a gitdir pointer is not routed anywhere' ($pO.Routed -eq 'local') ('got ' + $pO.Routed + ' ' + $pO.Path)

    # end to end through the real Send-Alert
    $script:ALERT_LIB_DIR = Join-Path $wtA 'grocery'
    $outA = @(Send-Alert -Subject 'fixture alert A' -Body 'body' -What 'ALIB-FIXTURE')
    $rcA = $outA[$outA.Count - 1]
    $mainRan = Test-Path -LiteralPath (Join-Path $mainA 'grocery\ran.txt')
    $wtRan = Test-Path -LiteralPath (Join-Path $wtA 'grocery\ran.txt')
    AlCase 'MUST FIRE Send-Alert from a linked worktree runs the main checkout''s sender, never the worktree''s' ($mainRan -and -not $wtRan) ('main ran=' + $mainRan + ' worktree ran=' + $wtRan)
    AlCase 'MUST FIRE the main sender''s failing exit code comes back to the caller, and the failure is spoken' ("$rcA" -eq '7' -and $global:LASTEXITCODE -eq 7 -and (($outA -join ' ') -match 'ALERT FAILED TO SEND')) ('rc=' + $rcA + ' out=' + ($outA -join ' | '))
    $script:ALERT_LIB_DIR = Join-Path $plain 'grocery'
    $outP = @(Send-Alert -Subject 'fixture alert P' -Body 'body' -What 'ALIB-FIXTURE')
    $rcP = $outP[$outP.Count - 1]
    AlCase 'CLEAN TWIN Send-Alert from a plain fixture runs its own sender and returns its 0' ("$rcP" -eq '0' -and (Test-Path -LiteralPath (Join-Path $plain 'grocery\ran.txt'))) ('rc=' + $rcP)
  } catch {
    $alFail++
    Write-Output ('  FAIL self-test threw: ' + $_.Exception.Message)
  } finally {
    $script:ALERT_LIB_DIR = $alSavedLibDir
    Remove-Item -LiteralPath $alDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  $alTotal = $alPass + $alFail
  if ($alFail -eq 0 -and $alTotal -eq 8) { Write-Output ('alert-lib self-test: PASS (' + $alPass + ' of ' + $alTotal + ' cases)'); exit 0 }
  Write-Output ('alert-lib self-test: FAIL (' + $alFail + ' failed, ' + $alPass + ' passed, ' + $alTotal + ' ran; 8 expected)')
  exit 1
}
