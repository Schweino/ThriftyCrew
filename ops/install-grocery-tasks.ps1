<#
  install-grocery-tasks.ps1 - the five hidden scheduled tasks, in the repo instead of only the registry.

  WHY THIS EXISTS (2026-09-06, backlog E29). Five tasks run with -WindowStyle Hidden. Two were
  registered by scripts in this repo (graph\pipeline\install-nightly-task.ps1 and
  meal-prep\pipeline\install-harvest-task.ps1). THE THREE TC GROCERY ONES HAD NO IN-REPO REGISTRAR AT
  ALL - they existed only in the Windows registry, which is why docs\RUNTIME-MAP.md had to note that
  one of them is named 0930 and runs at 10:30 "because it is the registry key".

  That is not a documentation gap, it is a coverage hole with teeth. E29 rejected the obvious gate -
  grep -WindowStyle Hidden out of every Register-ScheduledTask and require the target to dot-source
  run-log-lib - because it would have MISSED THREE OF THE FIVE, precisely the three the rule was
  written for. A static gate can only cover what is in the tree, and the tasks that hurt were the ones
  that were not. Putting the definitions here is what makes any gate possible at all.

  THE DEFINITIONS ARE ops\scheduled-tasks\*.xml, exported from the live scheduler on 2026-09-06 and
  committed as the BEFORE-IMAGE. Two edits were made to the raw export and both are load-bearing:
    * the account SID became __CURRENT_USER_SID__, substituted at registration time. A raw export
      carries S-1-5-21-..., which is identifying, machine-specific, and would name a nonexistent
      account on any other box.
    * the XML declaration said UTF-16 (what the scheduler emits) while the bytes were UTF-8. A file
      whose declaration lies about its own encoding fails in the confusing way rather than the
      obvious one.

  MODES, and the default is the safe one:
    -Verify   (DEFAULT) read-only. Compares the live scheduler against these files and reports drift.
              Changes nothing. This is the mode that can run in a gate or unattended.
    -Install  registers/updates the three TC Grocery tasks from the XML. CHANGES SYSTEM STATE.
    -FixName  additionally renames "TC Grocery Capture Watchdog 0930" to ...1030 to match the time it
              actually runs. SEPARATE SWITCH ON PURPOSE: a rename is an unregister followed by a
              register, so a failure between them leaves NO task at all. The time is never moved -
              10:30 is what the estate has been running and validating against for months, and the
              NAME is the thing that is wrong.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 hard finding, 3 could-not-evaluate.

  Self-test: powershell -File ops\install-grocery-tasks.ps1 -SelfTest
#>
param([switch]$Verify, [switch]$Install, [switch]$FixName, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

$XMLDIR = Join-Path $repo 'ops\scheduled-tasks'

# The three this file OWNS. The other two exports are committed as reference - their registrars live
# with the lanes they belong to and this script must not fight them for ownership.
$OWNED = @(
  [pscustomobject]@{ Name = 'TC Grocery Ad Pulls 0700';         File = 'tc-grocery-ad-pulls-0700.xml' }
  [pscustomobject]@{ Name = 'TC Grocery Daily Capture 0800';    File = 'tc-grocery-daily-capture-0800.xml' }
  # RENAMED ON THE LIVE SCHEDULER 2026-09-07, so 1030 is the NAME now and not a target. Leaving
  # 0930 as the primary with RenameTo pointing forward would have made a later -Install without
  # -FixName register a SECOND watchdog under the old name, and -Verify would have passed because
  # it falls back to RenameTo when the primary is missing. Legacy is kept so a machine that was
  # never migrated is noticed rather than ignored.
  [pscustomobject]@{ Name = 'TC Grocery Capture Watchdog 1030'; File = 'tc-grocery-capture-watchdog-0930.xml'; Legacy = 'TC Grocery Capture Watchdog 0930' }
)

function Get-XmlField {
  <# One field out of a task XML, by tag. A FUNCTION rather than an inline regex because three callers
     need it and this estate has been bitten by a helper that did not travel with a lift. #>
  param([Parameter(Mandatory=$true)][string]$Xml, [Parameter(Mandatory=$true)][string]$Tag)
  $m = [regex]::Match($Xml, ('<' + [regex]::Escape($Tag) + '>(.*?)</' + [regex]::Escape($Tag) + '>'), 'Singleline')
  if ($m.Success) { return $m.Groups[1].Value.Trim() }
  return ''
}

function Compare-TaskToXml {
  <# The drift check. Returns a list of difference strings; empty means the live task matches the file.

     COMPARES WHAT MATTERS AND NOT THE WHOLE DOCUMENT. A byte diff of two task XMLs is noise - the
     scheduler rewrites ordering, whitespace and optional defaults - so this compares the four fields
     whose drift would actually change behaviour: what runs, with what arguments, when, and hidden. #>
  param([Parameter(Mandatory=$true)]$Live, [Parameter(Mandatory=$true)][string]$Xml)
  $diffs = @()
  $wantCmd  = Get-XmlField -Xml $Xml -Tag 'Command'
  $wantArgs = Get-XmlField -Xml $Xml -Tag 'Arguments'
  $wantWhen = Get-XmlField -Xml $Xml -Tag 'StartBoundary'

  $liveCmd  = ''; $liveArgs = ''
  foreach ($a in @($Live.Actions)) { if ($a.Execute) { $liveCmd = [string]$a.Execute; $liveArgs = [string]$a.Arguments; break } }
  $liveWhen = ''
  foreach ($t in @($Live.Triggers)) { if ($t.StartBoundary) { $liveWhen = [string]$t.StartBoundary; break } }

  if ($wantCmd  -and ($liveCmd  -ne $wantCmd))  { $diffs += ("Command: live '{0}' vs file '{1}'" -f $liveCmd, $wantCmd) }
  if ($wantArgs -and ($liveArgs -ne $wantArgs)) { $diffs += ("Arguments: live '{0}' vs file '{1}'" -f $liveArgs, $wantArgs) }
  if ($wantWhen -and ($liveWhen -ne $wantWhen)) { $diffs += ("StartBoundary: live '{0}' vs file '{1}'" -f $liveWhen, $wantWhen) }
  if ($wantArgs -and ($wantArgs -notmatch '-WindowStyle\s+Hidden')) { $diffs += 'the FILE does not carry -WindowStyle Hidden, so the exported definition is not the one this estate runs' }
  return $diffs
}

function Test-NameMatchesTime {
  <# Does a task's NAME agree with the hour it runs? Returns '' when it does, or the correction.

     This is the 0930/10:30 lie, generalised. A name that disagrees with the schedule is worse than an
     ugly name: docs\RUNTIME-MAP.md had to carry a note explaining it, and the next person reading the
     task list has no way to know which of the two to believe. #>
  param([Parameter(Mandatory=$true)][string]$Name, [Parameter(Mandatory=$true)][string]$StartBoundary)
  $mn = [regex]::Match($Name, '(\d{2})(\d{2})\s*$')
  if (-not $mn.Success) { return '' }
  $mt = [regex]::Match([string]$StartBoundary, 'T(\d{2}):(\d{2})')
  if (-not $mt.Success) { return '' }
  $claimed = $mn.Groups[1].Value + $mn.Groups[2].Value
  $actual  = $mt.Groups[1].Value + $mt.Groups[2].Value
  if ($claimed -eq $actual) { return '' }
  return ("named {0} but its trigger is {1}" -f $claimed, $actual)
}

if ($SelfTest) {
  $fail = 0
  function T($n, $c, $g = '') { if ($c) { Write-Output ("ok    " + $n) } else { Write-Output ("FAIL  " + $n + "   got: " + $g); $script:fail++ } }

  $xml = '<Task><Triggers><CalendarTrigger><StartBoundary>2026-08-31T10:30:00-05:00</StartBoundary></CalendarTrigger></Triggers><Actions><Exec><Command>powershell.exe</Command><Arguments>-WindowStyle Hidden -File "x.ps1"</Arguments></Exec></Actions></Task>'
  T 'a field is read out of the task XML' ((Get-XmlField -Xml $xml -Tag 'Command') -eq 'powershell.exe') (Get-XmlField -Xml $xml -Tag 'Command')

  $live = [pscustomobject]@{
    Actions  = @([pscustomobject]@{ Execute = 'powershell.exe'; Arguments = '-WindowStyle Hidden -File "x.ps1"' })
    Triggers = @([pscustomobject]@{ StartBoundary = '2026-08-31T10:30:00-05:00' })
  }
  T 'MUST NOT FIRE a live task matching the file reports no drift' ((Compare-TaskToXml $live $xml).Count -eq 0) ((Compare-TaskToXml $live $xml) -join '; ')

  # MUST FIRE: the thing this whole file exists to make visible. A task whose ARGUMENTS drifted from
  # the repo is running something nobody committed.
  $drift = [pscustomobject]@{
    Actions  = @([pscustomobject]@{ Execute = 'powershell.exe'; Arguments = '-WindowStyle Hidden -File "SOMETHING-ELSE.ps1"' })
    Triggers = @([pscustomobject]@{ StartBoundary = '2026-08-31T10:30:00-05:00' })
  }
  $d = Compare-TaskToXml $drift $xml
  T 'MUST FIRE  a live task running different ARGUMENTS than the repo is drift' (($d -join ' ') -like '*Arguments*') ($d -join '; ')

  $dt = [pscustomobject]@{
    Actions  = @([pscustomobject]@{ Execute = 'powershell.exe'; Arguments = '-WindowStyle Hidden -File "x.ps1"' })
    Triggers = @([pscustomobject]@{ StartBoundary = '2026-08-31T03:00:00-05:00' })
  }
  T 'MUST FIRE  a live task running at a different TIME than the repo is drift' (((Compare-TaskToXml $dt $xml) -join ' ') -like '*StartBoundary*')

  # MUST FIRE: an exported definition that lost -WindowStyle Hidden is not the task this estate runs,
  # and registering it would put a console window on the user's screen every morning.
  $noHide = '<Task><Actions><Exec><Command>powershell.exe</Command><Arguments>-File "x.ps1"</Arguments></Exec></Actions></Task>'
  T 'MUST FIRE  a definition missing -WindowStyle Hidden is reported' (((Compare-TaskToXml $live $noHide) -join ' ') -like '*WindowStyle Hidden*')

  T 'MUST FIRE  the 0930/10:30 name lie is detected' ((Test-NameMatchesTime 'TC Grocery Capture Watchdog 0930' '2026-08-31T10:30:00-05:00') -ne '') (Test-NameMatchesTime 'TC Grocery Capture Watchdog 0930' '2026-08-31T10:30:00-05:00')
  T 'CLEAN TWIN a name that agrees with its trigger is not a finding' ((Test-NameMatchesTime 'TC Grocery Daily Capture 0800' '2026-08-20T08:00:00-05:00') -eq '')
  T 'CLEAN TWIN a task with no time in its name is not judged' ((Test-NameMatchesTime 'TC Recipe Harvest Crawl' '2026-08-24T18:00:00-05:00') -eq '')

  foreach ($o in $OWNED) {
    $p = Join-Path $XMLDIR $o.File
    if (Test-Path $p) {
      $x = [IO.File]::ReadAllText($p)
      T ('the committed definition exists and carries Hidden: ' + $o.File) ($x -match '-WindowStyle\s+Hidden')
      T ('the committed definition carries NO account SID: ' + $o.File) ($x -notmatch 'S-1-5-21-')
      # NOT "the declaration matches the bytes" - that was the assertion that pinned a definition
      # Register-ScheduledTask could not parse. What matters is that the REGISTRATION PATH carries no
      # encoding claim, because the call takes a UTF-16 .NET string whatever the file says.
      T ('the registration path strips the XML declaration: ' + $o.File) ((([regex]::Replace($x, '^\s*<\?xml[^>]*\?>\s*', '')) -notmatch '<\?xml'))
    } else {
      Write-Output ('FAIL  missing committed definition: ' + $p); $fail++
    }
  }

  if ($fail -gt 0) { Write-Output ("SELF-TEST FAIL: {0} case(s)" -f $fail); Write-GuardComplete -Name 'grocery-tasks' -Summary ("selftest-fail={0}" -f $fail); exit 2 }
  Write-Output 'SELF-TEST PASS: drift on arguments and on time, the lost-Hidden case, the 0930 name lie and its twins, and the committed definitions'
  Write-GuardComplete -Name 'grocery-tasks' -Summary 'selftest=pass'
  exit 0
}

if ($Install -or $FixName) {
  # THE MUTATING PATH. Left to a human on purpose: this changes Windows scheduler state, which is not
  # something an unattended run should do to a live estate, and a rename is an unregister followed by
  # a register with a window in between where NO task exists.
  Write-Output 'INSTALL requested. Read this before it runs:'
  Write-Output '  - it registers the three TC Grocery tasks from ops\scheduled-tasks\*.xml'
  Write-Output '  - the before-image is those same files, exported from the live scheduler 2026-09-06'
  Write-Output '  - re-run with -Verify afterwards; it must report NO drift'
  foreach ($o in $OWNED) {
    $p = Join-Path $XMLDIR $o.File
    if (-not (Test-Path $p)) { Write-Output ("REFUSED: missing " + $p); Write-GuardComplete -Name 'grocery-tasks' -Summary 'refused=missing-xml'; exit 3 }
    $xml = [IO.File]::ReadAllText($p).Replace('__CURRENT_USER_SID__', [string]([Security.Principal.WindowsIdentity]::GetCurrent().User.Value))
    # STRIP THE XML DECLARATION (2026-09-07). Register-ScheduledTask -Xml takes a .NET string, which is
    # UTF-16 in memory, and refuses one whose declaration claims anything else: "The task XML is
    # malformed. (1,40)::ERROR: unable to switch the encoding". The export says UTF-16, the bytes on
    # disk are UTF-8, and reconciling those two on disk is what broke this - so the call carries no
    # encoding claim at all. Found by running it; the self-test, -Verify and the gate were all green on
    # a definition that could not be registered.
    $xml = [regex]::Replace($xml, '^\s*<\?xml[^>]*\?>\s*', '')
    $target = $o.Name
    Write-Output ("  registering: " + $target)
    # -FixName removes a LEGACY name still sitting on this machine. The rename itself is done; what is
    # left is cleaning up a box that has not caught up. Unregister-then-register is only ever run
    # against the legacy name, never against the live one, so there is no window where the task the
    # scheduler is about to fire does not exist.
    if ($FixName -and $o.Legacy) {
      Unregister-ScheduledTask -TaskName $o.Legacy -Confirm:$false -ErrorAction SilentlyContinue
    }
    Register-ScheduledTask -TaskName $target -Xml $xml -Force | Out-Null
  }
  Write-Output 'Registered. Run -Verify now.'
  Write-GuardComplete -Name 'grocery-tasks' -Summary 'installed=3'
  exit 0
}

# -Verify is the default and the only mode that runs unattended.
if (-not (Test-Path $XMLDIR)) {
  Write-Output ("GROCERY TASKS COULD NOT EVALUATE: {0} does not exist. Discovery broken, NOT a clean tree." -f $XMLDIR)
  Write-GuardComplete -Name 'grocery-tasks' -Summary 'blind=no-xmldir'
  exit 3
}
$findings = @()
$checked = 0
foreach ($o in $OWNED) {
  $p = Join-Path $XMLDIR $o.File
  if (-not (Test-Path $p)) { $findings += ("no committed definition for '" + $o.Name + "'"); continue }
  $xml = [IO.File]::ReadAllText($p)
  $live = Get-ScheduledTask -TaskName $o.Name -ErrorAction SilentlyContinue
  if (-not $live -and $o.Legacy) {
    $live = Get-ScheduledTask -TaskName $o.Legacy -ErrorAction SilentlyContinue
    if ($live) { $findings += ("{0}: still registered under the LEGACY name; run -Install -FixName on this machine" -f $o.Legacy) }
  }
  if (-not $live) {
    Write-Output ("GROCERY TASKS COULD NOT EVALUATE: '{0}' is not registered on this machine. That is not drift - a box without the task is not a box with a wrong one." -f $o.Name)
    Write-GuardComplete -Name 'grocery-tasks' -Summary 'blind=task-absent'
    exit 3
  }
  $checked++
  foreach ($d in (Compare-TaskToXml $live $xml)) { $findings += ("{0}: {1}" -f $live.TaskName, $d) }
  $when = ''
  foreach ($t in @($live.Triggers)) { if ($t.StartBoundary) { $when = [string]$t.StartBoundary; break } }
  $nameSays = Test-NameMatchesTime -Name $live.TaskName -StartBoundary $when
  if ($nameSays) { $findings += ("{0}: {1} - run -Install -FixName to correct the NAME (the time is right; the name is not)" -f $live.TaskName, $nameSays) }
}

foreach ($f in $findings) { Write-Output ("  " + $f) }
if ($findings.Count -gt 0) {
  Write-Output ("GROCERY TASKS AUDIT FAILED: {0} finding(s) across {1} task(s) checked. A scheduled task that has drifted from the definition in this repo is running something nobody committed, and until 2026-09-06 there was no definition in this repo to drift from." -f $findings.Count, $checked)
  Write-GuardComplete -Name 'grocery-tasks' -Summary ("checked={0} findings={1}" -f $checked, $findings.Count)
  exit 2
}
Write-Output ("grocery-tasks: PASSED - all {0} task(s) match the committed definitions, and every name agrees with the hour it runs." -f $checked)
Write-GuardComplete -Name 'grocery-tasks' -Summary ("checked={0} findings=0" -f $checked)
exit 0
