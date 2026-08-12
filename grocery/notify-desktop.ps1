<#
  notify-desktop.ps1 - put a Windows prompt on Brad's screen when an automated run needs a human.

  WHY (Brad, 2026-07-29: "If you ever hit a bot wall, give me a windows prompt letting me know"):
  a bot wall is the one failure the agent genuinely cannot clear on its own - solving a human-verification
  challenge is off-limits, so the run either quarantines a partial capture or ships a store stale. On
  2026-07-29 Walmart died at 55 of 526 terms and Sam's at 203, and the only signal was an email that landed
  after the run had already finished making do. A prompt on screen while Brad is at the machine turns a
  post-mortem into a 30-second fix.

  NON-BLOCKING BY DESIGN. The dialog is shown by a DETACHED process, so an unattended run (scheduled task,
  cloud job, Brad asleep) is never held up waiting for someone to click OK. The prompt simply waits on screen
  until it is dismissed. This script always exits 0 - a notifier must never be the thing that breaks a run.

  It is a COMPLEMENT to send-alert.ps1 (email), not a replacement: use -AlsoEmail when the run is unattended
  and the wall means a store will go stale. On screen for "you can fix this now", email for the record.

  *** CLICKING OK IS THE RESUME SIGNAL *** (Brad, 2026-07-29: "clicking ok on the alert you gave me should
  be confirmation for you to resume"). Dismissing the dialog writes out\notify-ack-<store>.json. The agent
  polls for that file instead of asking Brad to type anything - the click is the handshake. Any stale ack is
  deleted when a new prompt is raised, so a leftover from last week can never read as "already cleared".

  Usage:
    .\notify-desktop.ps1 -Store "Sam's Club" -Detail "human-verification wall after 203 of 526 terms"
    .\notify-desktop.ps1 -Title "Grocery run needs you" -Message "..." -AlsoEmail
    .\notify-desktop.ps1 -WaitForAck "Sam's Club" -TimeoutMin 20     # block until OK is clicked
#>
param(
  [string]$Store   = "",
  [string]$Detail  = "",
  [string]$Title   = "",
  [string]$Message = "",
  [switch]$AlsoEmail,
  [switch]$SelfTest,
  # New V3 authority: when supplied, clicking OK journals the acknowledgment
  # directly through the authenticated local capture controller.
  [string]$ControllerChallengeId = "",
  # Poll for the ack a prompt writes when it is dismissed. Prints ACK or TIMEOUT; exit 0 = cleared to resume.
  [string]$WaitForAck = "",
  [int]$TimeoutMin = 20
)
$ErrorActionPreference = 'Continue'   # a notifier must not throw into the caller
$root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\income\grocery' }

function New-Prompt([string]$store, [string]$detail, [string]$title, [string]$message, [string]$when) {
  $t = if ($title) { $title } elseif ($store) { "Grocery run blocked: $store bot wall" } else { 'Grocery run needs you' }
  $m = if ($message) { $message }
       elseif ($store) {
@"
$store hit a human-verification wall at $when.

$detail

I can't clear this one - solving the challenge is off-limits, so the pull stops
here and that store's prices go stale (or get quarantined) unless someone
clears it.

WHAT HELPS: leave this alert open, switch to $store in Chrome, and clear the
"not a robot" / press-and-hold challenge yourself. Then return to this alert
and click OK. That OK click is the callback that tells me to re-check the
store canary and resume from where the pull stopped.
"@
       }
       elseif ($detail) { $detail }
       else { "An automated grocery run needs attention. Nothing more specific was passed - check the run's log and notify-log.txt." }
  return @{ Title = $t; Message = $m }
}
if ($WaitForAck) {
  $slugW = ($WaitForAck.ToLower() -replace '[^a-z0-9]', '')
  $ackW  = Join-Path $root ("out\notify-ack-$slugW.json")
  $deadline = (Get-Date).AddMinutes($TimeoutMin)
  Write-Output ("waiting for the OK click on the $WaitForAck prompt (up to $TimeoutMin min)...")
  while ((Get-Date) -lt $deadline) {
    if (Test-Path $ackW) { Write-Output ("ACK - $WaitForAck prompt was dismissed; cleared to resume"); exit 0 }
    Start-Sleep -Seconds 5
  }
  Write-Output ("TIMEOUT - no OK click on the $WaitForAck prompt within $TimeoutMin min; still blocked")
  exit 1
}

$p = New-Prompt $Store $Detail $Title $Message (Get-Date -Format 'ddd HH:mm')
$Title = $p.Title; $Message = $p.Message

# ---- log first: the prompt is best-effort, the record is not -------------------------------------------
$logLine = ('{0}  [{1}]  {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $(if($Store){$Store}else{'-'}), ($Message -replace '\s+', ' '))
try { Add-Content -Path (Join-Path $root 'notify-log.txt') -Value $logLine -ErrorAction Stop } catch { Start-Sleep -Milliseconds 250; try { Add-Content -Path (Join-Path $root 'notify-log.txt') -Value $logLine -ErrorAction SilentlyContinue } catch {} }

if ($SelfTest) {
  # prove the pieces work without putting a dialog on screen
  $ok = $true
  if (-not (Test-Path (Join-Path $root 'notify-log.txt'))) { Write-Output 'FAIL  notify-log.txt was not written'; $ok = $false }
  else { Write-Output 'ok    the notification is logged before any UI is attempted' }
  try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop; Write-Output 'ok    System.Windows.Forms is available for the prompt' }
  catch { Write-Output 'FAIL  System.Windows.Forms unavailable - the prompt would silently not appear'; $ok = $false }
  if ($Title -and $Message) { Write-Output 'ok    a title + body are always composed, even with no arguments' } else { Write-Output 'FAIL  empty title/message'; $ok = $false }
  # the real shape: -Store/-Detail must name the store, quote the detail, and say what unblocks it
  $s = New-Prompt "Sam's Club" 'wall after 203 of 526 terms' '' '' 'Wed 09:10'
  if ($s.Title -match "Sam's Club" -and $s.Title -match 'bot wall') { Write-Output 'ok    -Store names the store in the title' } else { Write-Output "FAIL  title was '$($s.Title)'"; $ok = $false }
  if ($s.Message -match '203 of 526' -and $s.Message -match 'WHAT HELPS') { Write-Output 'ok    body quotes the detail and says what unblocks it' } else { Write-Output 'FAIL  body missing detail or remedy'; $ok = $false }
  $o = New-Prompt '' '' 'Custom' 'Body only' 'Wed 09:10'
  if ($o.Title -eq 'Custom' -and $o.Message -eq 'Body only') { Write-Output 'ok    explicit -Title/-Message override the composed text' } else { Write-Output 'FAIL  override path'; $ok = $false }
  # FROZEN FOUNDING BUG (2026-08-06): the -AlsoEmail leg used `powershell -File send-alert.ps1 -Body $Message`,
  # and a real bot-wall body carrying quotes was re-split on the command line - send-alert answered
  # "-BodyFile not found: a" and mailed NOTHING while the desktop dialog went up, so the run looked alerted.
  # The email leg cannot be exercised here without actually sending mail, so this asserts the CALL SHAPE
  # instead: the source must invoke send-alert.ps1 directly, never through a child powershell -File. That is
  # the whole defect - a string round trip - so the shape IS the thing worth pinning.
  $src = Get-Content $PSCommandPath -Raw
  if ($src -match '(?m)^\s*&\s*powershell[^\r\n]*send-alert\.ps1') {
    Write-Output 'FAIL  -AlsoEmail calls send-alert through `powershell -File`; a quoted body will be re-split and the email will silently not send'; $ok = $false
  } elseif ($src -match '(?m)^\s*&\s*\(Join-Path \$root ''send-alert\.ps1''\)\s+-Subject') {
    Write-Output 'ok    -AlsoEmail calls send-alert in-process (no command-line round trip for the body)'
  } else {
    Write-Output 'FAIL  could not find the -AlsoEmail call to send-alert.ps1 at all - the email leg may have been dropped'; $ok = $false
  }
  if ($ok) { Write-Output 'all self-tests pass'; exit 0 } else { exit 1 }
}

# ---- the prompt, in a DETACHED process so an unattended run is never held up ---------------------------
# CLICKING OK IS THE RESUME SIGNAL (Brad, 2026-07-29: "clicking ok on the alert you gave me should be
# confirmation for you to resume"). The detached process writes an ACK file the moment the dialog is
# dismissed, so the agent can poll for it instead of asking Brad to type anything. The ack is deleted up
# front, so a stale one from a previous wall can never read as "already cleared" - that would have the agent
# charge back into a wall it was never released from.
$slug = if ($Store) { ($Store.ToLower() -replace '[^a-z0-9]', '') } else { 'run' }
$ackFile = Join-Path $root ("out\notify-ack-$slug.json")
try { if (Test-Path $ackFile) { Remove-Item $ackFile -Force } } catch {}
try {
  $t = $Title   -replace "'", "''"
  $m = $Message -replace "'", "''"
  $a = $ackFile -replace "'", "''"
  $s = $slug    -replace "'", "''"
  $challenge = $ControllerChallengeId -replace "'", "''"
  $ackController = (Join-Path $root '..\platform\scripts\ack-capture-challenge.ps1') -replace "'", "''"
  $inner = "Add-Type -AssemblyName System.Windows.Forms; " +
           "`$f = New-Object System.Windows.Forms.Form; `$f.TopMost = `$true; `$f.ShowInTaskbar = `$false; " +
           "[void][System.Windows.Forms.MessageBox]::Show(`$f, '$m', '$t', " +
           "[System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning); `$f.Dispose(); " +
           "`$d = Split-Path '$a' -Parent; if (-not (Test-Path `$d)) { New-Item -ItemType Directory -Path `$d -Force | Out-Null }; " +
           "@{ store='$s'; acknowledged_at=(Get-Date).ToString('s'); meaning='user dismissed the prompt - treat as clearance to resume' } " +
           "| ConvertTo-Json | Set-Content '$a' -Encoding UTF8; " +
           $(if ($challenge) { "& '$ackController' -ChallengeId '$challenge'" } else { "" })
  Start-Process -FilePath 'powershell.exe' `
                -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-Command', $inner) `
                -WindowStyle Hidden | Out-Null
  Write-Output ("desktop prompt raised: " + $Title)
  Write-Output ("clicking OK writes: " + $ackFile + "   (poll it - that click IS the resume signal)")
} catch {
  Write-Output ("desktop prompt FAILED to raise (" + $_.Exception.Message + ") - the notification is still in notify-log.txt")
}

if ($AlsoEmail) {
  # CALL send-alert IN-PROCESS, NOT VIA `powershell -File` (2026-08-06). The child-process form marshals every
  # argument through a command line, and a -Detail carrying quotes/punctuation is re-split on the way across:
  # a real bot-wall alert reading  PerimeterX 'Robot or human?' wall after 75 of 526 terms  arrived at
  # send-alert as -Subject <title> plus a stray positional 'a', which it rejected with
  # "send-alert: -BodyFile not found: a". The desktop dialog had gone up, so the run looked alerted while the
  # EMAIL leg - the only record an unattended run leaves - silently sent nothing. `& <script>` passes the real
  # strings with no command-line round trip. `exit` inside a script invoked with & ends THAT script only, and
  # its $ErrorActionPreference='Stop' is scoped to it, so this cannot terminate the notifier. See
  # [[ps51-json-array-traps]] (powershell -File marshals arguments as strings).
  try {
    & (Join-Path $root 'send-alert.ps1') -Subject $Title -Body $Message | Out-Null
    Write-Output 'and emailed via send-alert.ps1'
  } catch { Write-Output ('email leg failed (' + $_.Exception.Message + ') - see send-alert.ps1') }
}
exit 0
