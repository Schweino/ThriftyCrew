<#
  capture-run-lock-lib.ps1 - is anything still working the tree behind an ABANDONED Global\tc-capture-run?

  WHY A FILE OF ITS OWN (2026-09-23, design\PLAN-bot-checkout-self-heal-2026-09-23.md W4.1 step 7, and the review of
  that lane). Since W4.1 an abandoned capture-run lock can mean a killed parent whose re-executed child still captures,
  commits and pushes. Two scripts ask the lock that question: capture-run.ps1 itself, before it takes the lock, and
  grocery\chain-idle.ps1, which the 09:00 browser-stores agent runs before it builds anything. chain-idle used to read
  ABANDONED as FREE and RELEASE the lock, which both told the agent to build into the orphan's tree and erased the only
  signal the next capture-run uses to find the orphan. One answer, in one file, read by both.

  THE RULE: A PROBE THAT CANNOT LOOK ANSWERS LIVE (lib\push-lock.ps1's rule, and Test-CaptureRunPidAlive's in
  capture-run.ps1). Get-CaptureRunOrphanHolder answers alive when
    - a pid the status record names (either kind, not this process) is alive and its command line runs capture-run.ps1,
      or its command line could not be read while the process is alive;
    - OR a process scan finds a live powershell whose command line runs capture-run.ps1, other than this process and
      its ancestors. The scan is what covers the windows the record cannot: a torn or unreadable record, a same-kind
      hand run that timed out on the lock and wrote 'skipped-locked' with its own pid over the child's record, and the
      child's first seconds, when the record still carries the parent's pid and 'synced-handoff';
    - OR the scan itself could not look.
  A skip costs ONE occurrence: the skipper exits without releasing, its exit abandons the lock again, and the next
  occurrence asks the same question. So a live WAITER (another capture-run blocked on the lock) also answers alive,
  deliberately: the two cannot both skip for long, because each skip exits and the survivor finds nobody left.

  SCOPE OF A CLEAN ANSWER. alive = false means no powershell process whose command line runs capture-run.ps1 was found
  alive, beyond this process and its ancestors. A capture-run started under another host name, or whose command line
  does not name the file, is not seen.

  Dot-source: . (Join-Path $root 'capture-run-lock-lib.ps1')   (no param() block: dot-sourced, it would reset the
  caller's own parameters). Tested by grocery\test-capture-run-sync.ps1 (ORPHAN and CHAIN-IDLE groups).
#>

. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile, for the status record

# The capture-run command-line shape, as a regex over Win32_Process.CommandLine. A fixture passes its own file's path.
$script:TcCaptureRunScriptPattern = '(?i)capture-run\.ps1'

function Get-CaptureRunCommandLine([int]$ProcessId) {
  # '' when there is no such process (or it has no command line); $null when the lookup ITSELF failed, so a caller can
  # tell "nothing is there" from "could not look".
  try {
    $w = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId=' + $ProcessId) -ErrorAction Stop
    if ($w) { return [string]$w.CommandLine }
    return ''
  } catch { return $null }
}

function Test-CaptureRunProcessExists([int]$ProcessId) {
  if ($ProcessId -le 0) { return $false }
  try { return ($null -ne (Get-Process -Id $ProcessId -ErrorAction Stop)) }
  catch [Microsoft.PowerShell.Commands.ProcessCommandException] { return $false }
  catch { return $true }   # cannot look: LIVE
}

function Get-CaptureRunProcessScan {
  # Every live powershell.exe or pwsh.exe whose command line matches $Pattern, other than this process and its ancestors
  # (the scheduled task's own wrapper chain names capture-run.ps1 too). @{ ok; pids = int[]; why }. ok = $false when the
  # process list could not be read, which the caller answers LIVE. -ListProcesses is the seam: rows with ProcessId,
  # ParentProcessId, Name and CommandLine.
  param([string]$Pattern = $script:TcCaptureRunScriptPattern, [scriptblock]$ListProcesses = $null)
  $rows = $null
  try {
    if ($ListProcesses) { $rows = @(& $ListProcesses | Where-Object { $null -ne $_ }) }
    else { $rows = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | Select-Object ProcessId, ParentProcessId, Name, CommandLine) }
  } catch {
    return [pscustomobject]@{ ok = $false; pids = @(); why = ('the process list could not be read: ' + $_.Exception.Message) }
  }
  if ($null -eq $rows -or $rows.Count -eq 0) { return [pscustomobject]@{ ok = $false; pids = @(); why = 'the process list came back empty, which no live box does' } }
  $parent = @{}
  foreach ($r in $rows) { if ($null -ne $r) { $parent[[int]$r.ProcessId] = [int]$r.ParentProcessId } }
  $mine = New-Object 'System.Collections.Generic.HashSet[int]'
  $cur = [int]$PID
  for ($i = 0; $i -lt 64 -and $cur -gt 0 -and $mine.Add($cur); $i++) {
    if (-not $parent.ContainsKey($cur)) { break }
    $cur = [int]$parent[$cur]
  }
  $found = New-Object System.Collections.Generic.List[int]
  foreach ($r in $rows) {
    if ($null -eq $r) { continue }
    $n = [string]$r.Name
    if (@('powershell.exe', 'pwsh.exe') -notcontains $n.ToLowerInvariant()) { continue }
    if ($mine.Contains([int]$r.ProcessId)) { continue }
    if ([string]$r.CommandLine -match $Pattern) { $found.Add([int]$r.ProcessId) }
  }
  return [pscustomobject]@{ ok = $true; pids = $found.ToArray(); why = '' }
}

function Get-CaptureRunOrphanHolder {
  # Is a capture-run other than this process alive? @{ alive; pid; kind; why }. See THE RULE above.
  # -CommandLineOf and -ScanProcesses are seams; -Pattern names the script (a fixture passes its own file's path).
  param([string]$StatusFile, [scriptblock]$CommandLineOf = $null, [scriptblock]$ScanProcesses = $null, [string]$Pattern = $script:TcCaptureRunScriptPattern)
  $r = [pscustomobject]@{ alive = $false; pid = 0; kind = ''; why = '' }
  $notes = New-Object System.Collections.Generic.List[string]
  $doc = $null
  if (-not $StatusFile -or -not (Test-Path -LiteralPath $StatusFile)) { $notes.Add('no status record to read') }
  else {
    try { $doc = Read-JsonFile $StatusFile } catch { $doc = $null; $notes.Add('the status record is unreadable (' + $_.Exception.Message + ')') }
  }
  if ($null -ne $doc) {
    foreach ($k in @('ad', 'daily')) {
      if (-not $doc.PSObject.Properties[$k] -or $null -eq $doc.$k) { continue }
      $p = 0
      if (-not [int]::TryParse([string]$doc.$k.pid, [ref]$p) -or $p -le 0 -or $p -eq $PID) { continue }
      $cl = if ($CommandLineOf) { & $CommandLineOf $p } else { Get-CaptureRunCommandLine $p }
      if ($null -eq $cl) {
        if (Test-CaptureRunProcessExists $p) { $r.alive = $true; $r.pid = $p; $r.kind = $k; $r.why = ('pid ' + $p + ' (' + $k + ') is alive and its command line could not be read, so it counts as a live capture-run'); return $r }
        continue
      }
      if ([string]$cl -match $Pattern) { $r.alive = $true; $r.pid = $p; $r.kind = $k; $r.why = ('pid ' + $p + ' (' + $k + ') is alive and runs capture-run.ps1'); return $r }
    }
    $notes.Add('no capture-run the status record names is alive')
  }
  $scan = if ($ScanProcesses) { & $ScanProcesses } else { Get-CaptureRunProcessScan -Pattern $Pattern }
  if ($null -eq $scan -or -not $scan.ok) {
    $r.alive = $true
    $r.why = (($notes -join '; ') + '; and the process scan could not look (' + $(if ($scan) { [string]$scan.why } else { 'no answer' }) + '), so it counts as a live capture-run').TrimStart('; ')
    return $r
  }
  if (@($scan.pids).Count) {
    $r.alive = $true; $r.pid = [int]@($scan.pids)[0]
    $r.why = (($notes -join '; ') + '; and a process scan found pid ' + $r.pid + ' alive running capture-run.ps1').TrimStart('; ')
    return $r
  }
  $notes.Add('and no live capture-run.ps1 process was found')
  $r.why = ($notes -join '; ')
  return $r
}
