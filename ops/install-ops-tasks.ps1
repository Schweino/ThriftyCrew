<#
  Register the ops-lane Windows scheduled tasks.

    -SelfTest  pure: registers nothing, touches no scheduler, so ops\run-gates.ps1 can run it.
    -Verify    read-only: is every owned task on the live scheduler under the owned name?
    -Install   registers/updates from committed XML. CHANGES SYSTEM STATE.
               -Only <task name> narrows it to one owned task, so adding a task does not re-register the others.

  WHY A SEPARATE REGISTRAR. The estate's convention is one registrar per lane -
  graph\pipeline\install-nightly-task.ps1, meal-prep\pipeline\install-harvest-task.ps1,
  media\reels\install-daily-task.ps1, ops\install-grocery-tasks.ps1 - and
  ops\install-grocery-tasks.ps1 says in its own header that it must not fight the others for
  ownership. The learning loop's tasks are ops-lane, so they get the ops-lane registrar rather
  than being smuggled into the grocery one.

  BRAD'S RULE, 2026-08-22: Windows tasks are the ONLY routines that fire. No Claude scheduled
  agents. Every one belongs in grocery\expected-automations.json so health-heartbeat can notice
  it stop, and that entry is an INPUT to registration here, not paperwork afterwards.

  THE REFUSAL IS A THIRD COPY ON PURPOSE. `Test-TaskWatched` also lives in the nightly and
  harvest registrars. They own different lanes and must not take a dependency on each other;
  ops\audit-task-registration.ps1 fails the push if any registrar with a committed definition
  drops the refusal, so the three cannot drift apart silently.

  EXIT CODES (lib\guard-contract.ps1): 0 clean, 2 hard finding, 3 could-not-evaluate.
#>
[CmdletBinding()]
param([switch]$SelfTest, [switch]$Verify, [switch]$Install, [string]$Only = '')

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

$registry = Join-Path $repo 'grocery\expected-automations.json'
$XMLDIR = Join-Path $repo 'ops\scheduled-tasks'

# The tasks this file OWNS. One row per task; the XML is the truth about what it runs.
$OWNED = @(
  [pscustomobject]@{ Name = 'TC Sidecar Watchdog';   File = 'tc-sidecar-watchdog.xml' }
  [pscustomobject]@{ Name = 'TC Recall Sleep 0435';  File = 'tc-recall-sleep-0435.xml' }
  [pscustomobject]@{ Name = 'TC Brain Digest 0645';  File = 'tc-brain-digest-0645.xml' }
  [pscustomobject]@{ Name = 'TC Daemon Battery 0230'; File = 'tc-daemon-battery-0230.xml' }
)

function Test-TaskWatched {
  <#
    .SYNOPSIS Is this task named in the watcher's registry? '' to proceed, else the refusal.
    .DESCRIPTION THE WATCH ENTRY IS AN INPUT TO REGISTRATION. TC Graph Nightly Matching was
                 registered 2026-08-22 and watched 2026-08-25, so for three mornings nothing
                 would have noticed it stop; TC Recipe Harvest Crawl was hand-added the same
                 way two days later, which makes it a class rather than an incident. The only
                 cover was health-heartbeat printing TASK UNWATCHED the next day - an alarm
                 whose only follower is a human typing an entry.
  #>
  param([Parameter(Mandatory=$true)][string]$TaskName, $Registry)
  if (-not $Registry) {
    return ("{0} could not be read, so whether '{1}' is watched is UNKNOWN. Unreadable is not watched." -f 'grocery\expected-automations.json', $TaskName)
  }
  $watch = $null
  foreach ($row in @($Registry.windows_tasks)) { if ($row -and ([string]$row.name -eq $TaskName)) { $watch = $row } }
  if (-not $watch) {
    return ("grocery\expected-automations.json has no windows_tasks entry for '{0}', so health-heartbeat could not notice if it stopped firing. Add the entry (name, max_age_hours, why, proves) FIRST, then register." -f $TaskName)
  }
  foreach ($f in @('max_age_hours', 'why', 'proves')) {
    if (-not $watch.PSObject.Properties[$f] -or -not [string]$watch.$f) {
      return ("the windows_tasks entry for '{0}' has no '{1}'. A row without one is a row that cannot page usefully." -f $TaskName, $f)
    }
  }
  return ''
}

function Read-Registry {
  param([string]$Path)
  try { return [IO.File]::ReadAllText($Path) | ConvertFrom-Json } catch { return $null }
}

function Get-DefinitionArguments {
  <# A committed definition's <Arguments>, entity-decoded; '' when it has none. #>
  param([string]$XmlPath)
  $am = [regex]::Match([IO.File]::ReadAllText($XmlPath), '<Arguments>(.*?)</Arguments>', 'Singleline')
  if (-not $am.Success) { return '' }
  return [System.Net.WebUtility]::HtmlDecode($am.Groups[1].Value)
}

function Get-TaskTargetPaths {
  <#
    .SYNOPSIS Every script or program a definition's Arguments name by absolute path.
    .DESCRIPTION A DEFINITION CAN BE COMMITTED BEFORE THE SCRIPT IT RUNS REACHES THE CHECKOUT IT RUNS FROM. Every
                 action here names C:\Codex\ThriftyCrew\..., the MAIN checkout, while a session works in a linked
                 worktree whose commit reaches main only when something there pulls. Registered in that gap, TC
                 Daemon Battery 0230 (2026-09-11) would fire at 02:30 into a missing file: the child exits nonzero,
                 run-once-a-day stamps the day as run, and the heartbeat pages a failure that is really a
                 registration made too early. The wrapper's own -File and the child's \"...\" path inside -ArgLine
                 are both read, so a wrapped task is checked for the script that does the work.
  #>
  param([string]$Arguments)
  $out = @()
  foreach ($m in [regex]::Matches([string]$Arguments, '(?<=")([A-Za-z]:\\[^"]*?\.(?:ps1|py|exe))(?=\\?")')) { $out += $m.Groups[1].Value }
  return ,$out
}

# ---------------------------------------------------------------------------
if ($SelfTest) {
  $bad = 0; $ran = 0
  function T([string]$n, [bool]$ok, $got = '') {
    $script:ran++
    if ($ok) { Write-Output ("  ok    " + $n) } else { Write-Output ("  X     {0}   got: {1}" -f $n, $got); $script:bad++ }
  }

  $tn = $OWNED[0].Name

  # MUST FIRE: the three ways an unwatched task could be born, each refused BY NAME.
  $rMissing = [pscustomobject]@{ windows_tasks = @([pscustomobject]@{ name = 'Something Else'; max_age_hours = 30; why = 'x'; proves = 'y' }) }
  $w1 = Test-TaskWatched -TaskName $tn -Registry $rMissing
  T 'MUST FIRE  a task the registry does not name is refused, by name' `
    ($w1 -like "*$tn*" -and $w1 -like '*no windows_tasks entry*') $w1
  $rThin = [pscustomobject]@{ windows_tasks = @([pscustomobject]@{ name = $tn; max_age_hours = 30; why = 'x' }) }
  T 'MUST FIRE  an entry with no ''proves'' is refused - a row that cannot page is not a watch' `
    ((Test-TaskWatched -TaskName $tn -Registry $rThin) -like "*no 'proves'*") (Test-TaskWatched -TaskName $tn -Registry $rThin)
  T 'MUST FIRE  an unreadable registry is refused rather than assumed clean' `
    ((Test-TaskWatched -TaskName $tn -Registry $null) -like '*Unreadable is not watched*') (Test-TaskWatched -TaskName $tn -Registry $null)

  # MUST NOT FIRE: the rows shipped today permit registration. If this goes red the watch
  # entry was removed and the task would be registered blind.
  $rReal = Read-Registry -Path $registry
  foreach ($o in $OWNED) {
    $w2 = Test-TaskWatched -TaskName $o.Name -Registry $rReal
    T ("MUST NOT FIRE the shipped row for '{0}' permits registration" -f $o.Name) ($w2 -eq '') $w2
  }

  # MUST FIRE: every owned task has a committed definition, or nothing static can read what
  # it actually runs and three gates are reading a file that does not exist.
  foreach ($o in $OWNED) {
    T ("MUST FIRE  '{0}' has a committed definition" -f $o.Name) `
      (Test-Path -LiteralPath (Join-Path $XMLDIR $o.File)) (Join-Path $XMLDIR $o.File)
  }

  # MUST FIRE: the XML's URI matches the owned name. A mismatch registers the task under a
  # name nothing watches, which is precisely the state the refusal exists to prevent - and it
  # would slip past the refusal, because the refusal checks the name this table SAYS.
  foreach ($o in $OWNED) {
    $x = Join-Path $XMLDIR $o.File
    $uri = ''
    if (Test-Path -LiteralPath $x) {
      $m = [regex]::Match([IO.File]::ReadAllText($x), '<URI>\\?([^<]+)</URI>')
      if ($m.Success) { $uri = $m.Groups[1].Value.Trim() }
    }
    T ("MUST FIRE  the XML URI for '{0}' matches the owned name" -f $o.Name) ($uri -eq $o.Name) $uri
  }

  # MUST FIRE: the committed XML must not carry a real account SID.
  foreach ($o in $OWNED) {
    $x = Join-Path $XMLDIR $o.File
    $txt = if (Test-Path -LiteralPath $x) { [IO.File]::ReadAllText($x) } else { '' }
    T ("MUST NOT FIRE the committed XML for '{0}' carries no account SID" -f $o.Name) `
      (-not ($txt -match '<UserId>S-1-5-21')) 'a committed SID leaks the account and will not import elsewhere'
  }

  # CLEAN TWIN: the registration path actually CALLS the refusal. Needle by concatenation so
  # this assertion is not its own match.
  $src = [IO.File]::ReadAllText($PSCommandPath)
  $nCall = 'Test-Task' + 'Watched -TaskName $o.Name -Registry $regDoc'
  T 'CLEAN TWIN the registration path calls the refusal before registering' `
    ($src.Contains($nCall)) 'the refusal is defined but never called'

  # CLEAN TWIN: the target parser reads all three paths a WRAPPED definition names - the wrapper, its -Exe, and the
  # child script inside -ArgLine's escaped quotes - from the committed bytes rather than a paraphrase of them.
  $rsPaths = Get-TaskTargetPaths -Arguments (Get-DefinitionArguments -XmlPath (Join-Path $XMLDIR 'tc-recall-sleep-0435.xml'))
  T 'CLEAN TWIN the target parser reads a wrapped definition''s wrapper, its -Exe and its child script' `
    (($rsPaths -contains 'C:\Codex\ThriftyCrew\ops\run-once-a-day.ps1') -and ($rsPaths -contains 'C:\Codex\Python312\python.exe') -and
     ($rsPaths -contains 'C:\Users\Owner\.claude\skills\recall-sleep.py')) ($rsPaths -join ' | ')
  $dbPaths = Get-TaskTargetPaths -Arguments (Get-DefinitionArguments -XmlPath (Join-Path $XMLDIR 'tc-daemon-battery-0230.xml'))
  T 'CLEAN TWIN and it reads the daemon battery''s runner out of -ArgLine' `
    ($dbPaths -contains 'C:\Codex\ThriftyCrew\ops\run-daemon-battery.ps1') ($dbPaths -join ' | ')
  # MUST FIRE: a definition naming a script that is not on disk is found missing, by its path.
  $ghost = 'C:\Codex\ThriftyCrew\ops\no-such-task-script-' + [guid]::NewGuid().ToString('N') + '.ps1'
  $gPaths = Get-TaskTargetPaths -Arguments ('-NoProfile -File "' + $ghost + '" -Alert')
  $gMissing = @($gPaths | Where-Object { -not (Test-Path -LiteralPath $_) })
  T 'MUST FIRE  a definition whose script is not on this box is found missing, by path' `
    (($gMissing.Count -eq 1) -and ($gMissing[0] -eq $ghost)) ($gMissing -join ' | ')
  $nTargets = 'Get-TaskTarget' + 'Paths -Arguments (Get-DefinitionArguments -XmlPath $x)'
  T 'CLEAN TWIN the registration path checks every target exists before registering' `
    ($src.Contains($nTargets)) 'the target check is defined but never called'

  Write-Output ''
  if ($bad -gt 0) {
    Write-Output ("install-ops-tasks selftest: {0} FAILED of {1}" -f $bad, $ran)
    Exit-Guard -Name 'INSTALL-OPS-TASKS-SELFTEST' -Code 1 -Summary "failed=$bad of $ran"
  }
  Write-Output ("install-ops-tasks selftest: {0} of {0} cases pass" -f $ran)
  Exit-Guard -Name 'INSTALL-OPS-TASKS-SELFTEST' -Code 0 -Summary "cases=$ran"
}

Invoke-Guard -Name 'INSTALL-OPS-TASKS' -Body {
  if (-not $Verify -and -not $Install) {
    Write-Output 'Nothing asked for. Use -Verify (read-only), -Install (changes the scheduler) or -SelfTest.'
    Exit-Guard -Name 'INSTALL-OPS-TASKS' -Code 0 -Summary 'noop'
  }

  $regDoc = Read-Registry -Path $registry
  $bad = 0

  if ($Verify) {
    Write-Output 'ops-lane tasks, against the live scheduler:'
    foreach ($o in $OWNED) {
      $live = $null
      try { $live = Get-ScheduledTask -TaskName $o.Name -ErrorAction Stop } catch { $live = $null }
      if ($live) {
        Write-Output ("  ok      {0}  (state {1})" -f $o.Name, $live.State)
      } else {
        Write-Output ("  MISSING {0}  - not registered. Run with -Install." -f $o.Name)
        $bad++
      }
    }
    Exit-Guard -Name 'INSTALL-OPS-TASKS' -Code $(if ($bad) { 2 } else { 0 }) -Summary "verified=$($OWNED.Count) missing=$bad"
  }

  # -Only narrows the install to one owned task. Re-registering a task from XML resets what the heartbeat reads about
  # it, so adding a task should not touch the others.
  $targets = @($OWNED | Where-Object { (-not $Only) -or ($_.Name -eq $Only) })
  if ($Only -and -not $targets.Count) {
    Write-Output ("REFUSED: -Only '{0}' is not a task this registrar owns ({1})" -f $Only, (($OWNED | ForEach-Object { $_.Name }) -join ', '))
    Exit-Guard -Name 'INSTALL-OPS-TASKS' -Code 2 -Summary 'refused=unknown-task'
  }

  # -Install. The refusal runs BEFORE any scheduler call, for every task being installed, so a partial
  # install cannot leave one task registered and unwatched.
  foreach ($o in $targets) {
    $why = Test-TaskWatched -TaskName $o.Name -Registry $regDoc
    if ($why) {
      Write-Output ("REFUSED: {0}" -f $why)
      Exit-Guard -Name 'INSTALL-OPS-TASKS' -Code 2 -Summary 'refused=unwatched'
    }
  }

  # AND EVERY SCRIPT A DEFINITION RUNS MUST ALREADY BE ON DISK where the action names it - see Get-TaskTargetPaths.
  foreach ($o in $targets) {
    $x = Join-Path $XMLDIR $o.File
    if (-not (Test-Path -LiteralPath $x)) { continue }   # refused by name in the loop below
    $paths = Get-TaskTargetPaths -Arguments (Get-DefinitionArguments -XmlPath $x)
    $missing = @($paths | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missing.Count) {
      Write-Output ("REFUSED: '{0}' runs {1}, which is not on this box. Register it once the commit that adds it has reached that checkout." -f $o.Name, ($missing -join ', '))
      Exit-Guard -Name 'INSTALL-OPS-TASKS' -Code 2 -Summary 'refused=target-missing'
    }
  }

  foreach ($o in $targets) {
    $x = Join-Path $XMLDIR $o.File
    if (-not (Test-Path -LiteralPath $x)) {
      Write-Output ("REFUSED: no committed definition at {0}" -f $x)
      Exit-Guard -Name 'INSTALL-OPS-TASKS' -Code 2 -Summary 'refused=no-definition'
    }
    $xml = [IO.File]::ReadAllText($x)
    $sid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
    $xml = $xml.Replace('__CURRENT_USER_SID__', $sid)
    # STRIP THE XML DECLARATION. `Register-ScheduledTask -Xml` takes a .NET string, which is
    # UTF-16 in memory, and refuses one whose declaration claims anything else: "The task XML
    # is malformed. (1,40)::ERROR: unable to switch the encoding". The committed bytes are
    # UTF-8 and must stay UTF-8, so the fix is to make no encoding claim in the CALL rather
    # than to reconcile the two on disk.
    #
    # `ops\install-grocery-tasks.ps1` found this on 2026-09-07 and wrote it down, and this
    # registrar hit the identical error on its first install anyway. Worth noting where it
    # cost something: the knowledge existed, in this directory, and was not reached.
    $xml = [regex]::Replace($xml, '^\s*<\?xml[^>]*\?>\s*', '')
    try {
      $null = Register-ScheduledTask -TaskName $o.Name -Xml $xml -Force
      Write-Output ("  registered {0}" -f $o.Name)
    } catch {
      Write-Output ("  FAILED to register {0}: {1}" -f $o.Name, $_.Exception.Message)
      $bad++
    }
  }
  Exit-Guard -Name 'INSTALL-OPS-TASKS' -Code $(if ($bad) { 2 } else { 0 }) -Summary "installed=$($targets.Count) of $($OWNED.Count) failed=$bad"
}
