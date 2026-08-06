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

  Do NOT go back to calling send-alert.ps1 through `powershell -File` with a -Body argument. Calling it
  IN-PROCESS (`& (Join-Path $root 'send-alert.ps1') -Subject $s -Body $b`, as notify-desktop.ps1 does) is
  also safe - there is no command line in that form - but this helper is preferred because it is the only
  form that also makes a failed send loud.
#>

# Captured at dot-source time: inside a dot-sourced file $PSScriptRoot is the LIB's directory, not the
# caller's, and stashing it here keeps it correct for callers that live in another folder entirely
# (meal-prep\pipeline\compute-v2-perserving.ps1 reaches across the tree for the same mailer).
$script:ALERT_LIB_DIR = $PSScriptRoot

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
    [switch]$Force
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
    $sa = Join-Path $script:ALERT_LIB_DIR 'send-alert.ps1'
    if ($Force) { & powershell -ExecutionPolicy Bypass -File $sa -Subject $Subject -BodyFile $bf -Force | Out-Null }
    else        { & powershell -ExecutionPolicy Bypass -File $sa -Subject $Subject -BodyFile $bf | Out-Null }
    $rc = $LASTEXITCODE
    if ($rc -ne 0) {
      Write-AlertLog ('ALERT FAILED TO SEND [' + $tag + '] "' + $Subject + '" - send-alert.ps1 exited ' + $rc + '. See alert-log.txt. The condition it describes is real and UNPAGED.')
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

# Use the caller's own logger when it has one (check-ad-cycles, run-daily-local and bakers-daily-scan each
# define a lock-tolerant Log), so a failed send lands in the same file as the failure that triggered it.
# Scripts with no logger are report-style: their stdout IS the record, and a dead page belongs in it.
function Write-AlertLog([string]$m) {
  if (Get-Command -Name Log -CommandType Function -ErrorAction SilentlyContinue) {
    try { Log $m; return } catch {}
  }
  try { Write-Output $m } catch {}
}
