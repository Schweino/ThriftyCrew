<#
  Kill an ORPHANED, SPINNING, READ-ONLY git command, and report every other orphan burning a core.

  WHY IT EXISTS, MEASURED 2026-09-20. Brad noticed his box sitting at 21% with nothing obvious running.
  A `git range-diff origin/main...origin/claude/wave-p5-order origin/main...origin/claude/i234-republish`
  had been running since 2026-09-19 02:44: 28.8 CPU-HOURS over 29.2 wall hours, one core pegged at 100%
  the whole time, and its parent process was already gone, so no session was ever going to read its
  output. range-diff compares every commit of one range against every commit of the other, and on two
  branches that far from main it does not finish in any useful time.

  NOTHING IN THIS ESTATE COULD SEE IT. health-heartbeat watches scheduled TASKS and OUTPUT files;
  gate-slots bounds how many gate workers run at once; ops\cpu-load.ps1 bounds DELIBERATE load and kills
  its own burners. A process orphaned by a dead session is outside all three, so it burned a core for a
  day and a quarter and the only detector was a human looking at Task Manager. Brad's ruling the same
  morning: "we cannot have that happen ever again."

  WHY IT KILLS RATHER THAN PAGES. The estate's own rule is that an alarm whose only follower is a human
  typing a command is an alarm with no repair lane, and 2026-09-20's cost ruling sharpened it: alert only
  where a human has to act. Nobody needs to decide anything about a wedged read-only git command whose
  parent is dead. The decision is already made, so the script makes it.

  THE RULE IS DELIBERATELY NARROW, because this kills processes. All five must hold:
    1. the process is git.exe;
    2. its SUBCOMMAND is on the read-only whitelist below (range-diff, log, diff, blame, ...). A git
       command that WRITES - push, commit, gc, repack, fetch, rebase, index-pack - is never reaped at any
       age, because killing a writer can leave a lock, a half-written pack or a detached rebase behind.
       This is a whitelist and not a blacklist: an unknown subcommand is treated as a writer.
    3. its parent process is GONE. A live parent means a session is waiting on the output and is entitled
       to kill it itself. This alone excludes every gate child, every capture lane and every push.
    4. it has burned at least $ReapCpuMinutes of CPU (default 10). Ordinary git commands here take
       seconds; the founding case had burned 1,728 minutes.
    5. it is STILL SPINNING, at $SpinCorePct or more of one core measured over a live sample (default
       50% over 3 s). An orphan blocked on a lock or on the network burns nothing and is reported, never
       killed, because a kill would not give the core back.

  ANYTHING ORPHANED AND OVER $ReportCpuMinutes THAT THE RULE DOES NOT COVER IS REPORTED, NEVER KILLED.
  That is the detective half (reliability-craft\rca-and-chaos.md 2: a corrective action set that is all
  preventive is claiming this can never take another shape). A powershell.exe orphan is the common one:
  Windows Task Scheduler leaves no live parent, so every scheduled task in this estate looks orphaned and
  none of them may ever be killed by this script.

  THE THRESHOLDS ARE FIRST PLAUSIBLE NUMBERS, NOT THE SURVIVORS OF A SWEEP (docs\CONTROL-CONSTANTS.md
  asks which). 10 CPU-minutes is about 60 times the slowest ordinary git call measured on this box and
  about 0.6% of the founding case; 50% of a core separates spinning from blocked with room for a busy
  box; 60 CPU-minutes for the report bar is one core-hour, the point at which waste is worth a line.
  WHAT THEY DO WHEN THE PRODUCER STOPS: every one is a LOWER bound on a running process, so an empty
  process table produces an empty report and the run exits 0 having killed nothing. That is the correct
  quiet, and the task's own registration in expected-automations.json is what notices the run stopping.

  SCOPE OF A CLEAN REPORT: SOUND about nothing, UNSOUND by construction. A clean run means no process
  matched these five conditions in this sample. A runaway that blocks and spins alternately can be missed
  by any one sample, and a wedged process that burns no CPU is not waste and is deliberately out of
  scope. A finding, on the other hand, IS real: every field in it was read from the live process table.

  EXIT CODES (lib\guard-contract.ps1): 0 nothing to do, 1 findings (reaped or reported), 3 could not look.
#>
# Declared inputs of its -SelfTest (2026-09-23, lib\gate-input-key.ps1): read off the self-test block, which works in a temp sandbox and reads nothing else of this repo. Verify with: powershell -File lib\gate-input-key.ps1 -VerifyDeclared <this file>
# gate-inputs: ops\reap-runaway-processes.ps1
[CmdletBinding()]
param(
  [switch]$SelfTest,
  # Default is a REPORT. The scheduled task passes -Reap; a human running it by hand sees what it would do.
  [switch]$Reap,
  [switch]$Alert,
  [double]$ReapCpuMinutes = 10,
  [double]$ReportCpuMinutes = 60,
  [double]$SpinCorePct = 50,
  [int]$SampleSeconds = 3
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoRoot 'lib\guard-contract.ps1')
. (Join-Path $RepoRoot 'lib\append-line.ps1')
. (Join-Path $RepoRoot 'grocery\run-log-lib.ps1')

$script:ReapLog = Join-Path $RepoRoot 'ops\out\reaped-processes.jsonl'

# The read-only subcommands. A command that only READS the object database can be killed at any moment
# with no more consequence than losing its output. Anything absent from this list is treated as a writer.
$script:ReadOnlyGitVerbs = @(
  'range-diff', 'log', 'shortlog', 'diff', 'diff-tree', 'diff-files', 'diff-index', 'show', 'blame',
  'annotate', 'grep', 'rev-list', 'rev-parse', 'merge-base', 'cat-file', 'ls-files', 'ls-tree',
  'ls-remote', 'describe', 'name-rev', 'whatchanged', 'cherry', 'count-objects', 'verify-commit',
  'verify-tag', 'patch-id', 'help', 'version'
)
# Global options that CONSUME the next token, so the subcommand is not the token after them.
$script:GitOptsTakingValue = @('-C', '-c', '--git-dir', '--work-tree', '--namespace', '--exec-path', '--super-prefix')

function Get-GitSubcommand {
  <# .SYNOPSIS Pure. The subcommand from a git command line, or '' when there is none.
     Global options come BEFORE the subcommand and some of them eat the next token, so
     "git -C C:\repo --no-pager range-diff a b" is range-diff and not C:\repo. #>
  param([string]$CommandLine)
  if (-not $CommandLine) { return '' }
  $toks = @()
  # Quoted paths are ordinary here (a repo path with spaces), so split on whitespace outside quotes.
  foreach ($m in [regex]::Matches($CommandLine, '"[^"]*"|\S+')) { $toks += ($m.Value.Trim('"')) }
  if ($toks.Count -lt 2) { return '' }
  $i = 1
  while ($i -lt $toks.Count) {
    $t = [string]$toks[$i]
    if ($script:GitOptsTakingValue -contains $t) { $i += 2; continue }
    if ($t.StartsWith('-')) { $i += 1; continue }
    return $t.ToLowerInvariant()
  }
  return ''
}

function Get-ReapVerdict {
  <# .SYNOPSIS Pure. reap | report | keep for ONE measured process, with the reason in its own words.
     Every guard here is a refusal, so a record missing any field falls through to 'keep'. #>
  param(
    [string]$Name, [string]$CommandLine, [bool]$ParentAlive,
    [double]$CpuMinutes, [double]$CoreSharePct,
    [double]$ReapCpuMinutes = 10, [double]$ReportCpuMinutes = 60, [double]$SpinCorePct = 50
  )
  $v = [pscustomobject]@{ action = 'keep'; why = ''; verb = '' }
  if ($ParentAlive) { $v.why = 'parent is alive, so a session still owns it'; return $v }
  $isGit = ([string]$Name).ToLowerInvariant() -in @('git', 'git.exe')
  $verb = ''
  if ($isGit) { $verb = Get-GitSubcommand $CommandLine }
  $v.verb = $verb
  $readOnly = $isGit -and $verb -and ($script:ReadOnlyGitVerbs -contains $verb)
  if ($readOnly -and $CpuMinutes -ge $ReapCpuMinutes -and $CoreSharePct -ge $SpinCorePct) {
    $v.action = 'reap'
    $v.why = ("orphaned read-only 'git $verb' spinning at " + [math]::Round($CoreSharePct) + '% of a core after ' +
              [math]::Round($CpuMinutes) + ' CPU-minutes')
    return $v
  }
  if ($CpuMinutes -ge $ReportCpuMinutes) {
    $v.action = 'report'
    if ($isGit -and -not $readOnly) {
      $v.why = ("orphaned 'git " + $verb + "' is NOT on the read-only whitelist, so it is never killed here: " +
                [math]::Round($CpuMinutes) + ' CPU-minutes, ' + [math]::Round($CoreSharePct) + '% of a core')
    } elseif ($readOnly) {
      $v.why = ("orphaned read-only 'git $verb' is not spinning now (" + [math]::Round($CoreSharePct) +
                '% of a core), so killing it would give nothing back: ' + [math]::Round($CpuMinutes) + ' CPU-minutes')
    } else {
      $v.why = ('orphaned ' + $Name + ' has burned ' + [math]::Round($CpuMinutes) + ' CPU-minutes at ' +
                [math]::Round($CoreSharePct) + '% of a core. A scheduled task has no live parent either, so this is a REPORT')
    }
    return $v
  }
  $v.why = ('under the bars (' + [math]::Round($CpuMinutes, 1) + ' CPU-minutes)')
  return $v
}

function Test-EffectiveParentAlive {
  <# .SYNOPSIS Pure. Is a process still OWNED by something outside its own tool chain?
     WHY THIS IS NOT JUST "does my parent exist" (measured 2026-09-20 while proving the reaper on a real
     orphan): git on Windows forks. `C:\Program Files\Git\cmd\git.exe` is a wrapper that spawns the real
     `git.exe`, so a session that dies leaves an ORPHANED WRAPPER burning nothing and a BUSY CHILD whose
     parent is alive. Asking only about the immediate parent, neither is reapable and the core stays lost.
     So the question is asked of the nearest ancestor with a DIFFERENT name: walk up through same-named
     ancestors, then look. A recycled pid (an ancestor that started after its child) is not an ancestor.
     $Table maps pid -> @{ ParentId; Name; Start }. A pid missing from it is a dead process. #>
  param([int]$Id, $Table, [int]$MaxHops = 12)
  if (-not $Table -or -not $Table.ContainsKey($Id)) { return $false }
  $self = $Table[$Id]
  $name = ([string]$self.Name).ToLowerInvariant()
  $cur = [int]$self.ParentId
  $child = $self
  for ($hop = 0; $hop -lt $MaxHops; $hop++) {   # bounded: a malformed table must not hang a reaper
    if ($cur -le 0 -or -not $Table.ContainsKey($cur)) { return $false }   # the chain ends in a dead process
    $anc = $Table[$cur]
    if ($null -ne $anc.Start -and $null -ne $child.Start -and ([datetime]$anc.Start) -gt ([datetime]$child.Start)) {
      return $false                                                      # recycled pid: not the real parent
    }
    if (([string]$anc.Name).ToLowerInvariant() -ne $name) { return $true }  # a live owner of another kind
    if ($cur -eq [int]$anc.ParentId) { return $false }                   # self-parent: malformed, not owned
    $child = $anc
    $cur = [int]$anc.ParentId
  }
  return $true   # too deep to decide: fail toward OWNED, which is the answer that kills nothing
}

function Get-AlertPlan {
  <# .SYNOPSIS Pure. Which alert subjects this run owes, given what it found.
     THE TWO HALVES ARE NOT THE SAME NEWS (Brad, 2026-09-20). A REAPED process is already dealt with:
     the core is back and nobody has to decide anything, which is exactly the estate's page test, so it
     queues for triage and is never emailed. A REPORTED one is the opposite - a core is being wasted
     right now and this script has refused to act, which is a decision only a person can make - so it
     PAGES. One subject for both would have made the noisy half set the class for the urgent half, and
     a runaway nothing owns would have waited up to a week in the weekly lane.
     THE SUBJECTS CARRY NO COUNTS AND NO PIDS: send-alert derives its once-per-day suppression key from
     the subject with numbers stripped, so a varying subject is a new alert every quarter of an hour. #>
  param([int]$ReapedCount, [int]$ReportedCount)
  $plan = New-Object 'System.Collections.Generic.List[object]'
  if ($ReapedCount -gt 0) {
    [void]$plan.Add([pscustomobject]@{ subject = 'Ops: a runaway process was reaped'; kind = 'reaped' })
  }
  if ($ReportedCount -gt 0) {
    [void]$plan.Add([pscustomobject]@{ subject = 'Ops: a process is burning a core and nothing owns it'; kind = 'reported' })
  }
  return $plan.ToArray()
}

function Get-ProcessSample {
  <# .SYNOPSIS Live. Every process with its parent's liveness, CPU-minutes and share of one core,
     measured over $Seconds. Returns an ARRAY of records. Never throws on a process that exits
     under it: a race there is the ordinary case, not a failure. #>
  param([int]$Seconds = 3, [string[]]$Names = @())
  $procs = @()
  try {
    if ($Names.Count -gt 0) { $procs = @(Get-Process -Name $Names -ErrorAction SilentlyContinue) }
    else { $procs = @(Get-Process -ErrorAction SilentlyContinue) }
  } catch { return @() }
  $first = @{}
  foreach ($p in $procs) { try { if ($null -ne $p.CPU) { $first[$p.Id] = [double]$p.CPU } } catch { } }
  if ($first.Count -eq 0) { return @() }
  Start-Sleep -Seconds $Seconds
  $live = @{}
  try { foreach ($c in @(Get-CimInstance Win32_Process -ErrorAction Stop)) { $live[[int]$c.ProcessId] = $c } } catch { return @() }
  # The ancestry table Test-EffectiveParentAlive walks. Built once for the whole sample, from the SAME
  # snapshot the verdicts are taken from, so a process that exits mid-walk cannot change one answer.
  $table = @{}
  foreach ($k in $live.Keys) {
    $c = $live[$k]
    $st = $null
    try { $st = [Management.ManagementDateTimeConverter]::ToDateTime($c.CreationDate) } catch { $st = $null }
    $table[[int]$k] = @{ ParentId = [int]$c.ParentProcessId; Name = [string]$c.Name; Start = $st }
  }
  $out = New-Object 'System.Collections.Generic.List[object]'
  foreach ($p in $procs) {
    $cim = $null
    if ($live.ContainsKey($p.Id)) { $cim = $live[$p.Id] }
    if ($null -eq $cim) { continue }                      # exited during the sample: nothing to reap
    $now = $null
    try { $p.Refresh(); $now = [double]$p.CPU } catch { continue }
    if ($null -eq $now -or -not $first.ContainsKey($p.Id)) { continue }
    $ppid = [int]$cim.ParentProcessId
    # OWNED, not merely "has a parent": the walk skips same-named ancestors (git's wrapper) and refuses a
    # recycled pid. Both rules live in Test-EffectiveParentAlive with their own fixtures.
    $parentAlive = Test-EffectiveParentAlive -Id ([int]$p.Id) -Table $table
    [void]$out.Add([pscustomobject]@{
      Id           = [int]$p.Id
      Name         = [string]$p.Name
      CommandLine  = [string]$cim.CommandLine
      ParentId     = $ppid
      ParentAlive  = [bool]$parentAlive
      CpuMinutes   = [math]::Round($now / 60, 2)
      CoreSharePct = [math]::Round((($now - $first[$p.Id]) / $Seconds) * 100, 1)
    })
  }
  return $out.ToArray()
}

function Invoke-ReapProcess {
  <# .SYNOPSIS Live. Kill one pid. $true when it is gone afterwards. A process that exited on its own
     between the verdict and the kill is a SUCCESS, not an error: the core is back either way.
     IT WAITS ON THE PROCESS'S OWN EXIT, NEVER ON A CLOCK (2026-09-23). The first version slept a fixed
     500 ms and then asked the process table, so under a 24-wide run-gates pool a killed powershell.exe
     that took longer than that to leave the table read as SURVIVED: the self-test went red on a push that
     could not reach it, and the live path could log a successful kill as COULD NOT KILL. $ExitWaitMs is a
     hang guard, not a bar - a process that is really gone ends the wait at once however loaded the box is.
     The Process object is taken BEFORE the kill, so the wait is on that process and not on whatever
     reuses its pid afterwards. $Kill is the seam a self-test swaps to hold exit open on a condition it
     controls; production passes nothing and gets Process.Kill(). #>
  param([int]$Id, [int]$ExitWaitMs = 30000, [scriptblock]$Kill = $null)
  $proc = $null
  try { $proc = [Diagnostics.Process]::GetProcessById($Id) } catch { return $true }   # already gone
  try {
    try {
      if ($Kill) { & $Kill $proc } else { $proc.Kill() }
    } catch { }   # already exited, or refused: the wait below says which
    try { return [bool]$proc.WaitForExit($ExitWaitMs) } catch {
      # A handle we may not open (another user's process) cannot be waited on. Fall back to the table,
      # conservatively: present means not confirmed gone.
      $still = $null
      try { $still = Get-Process -Id $Id -ErrorAction SilentlyContinue } catch { $still = $null }
      return ($null -eq $still)
    }
  } finally { $proc.Dispose() }
}

# ---------------------------------------------------------------------------- SELF-TEST
if ($SelfTest) {
  $pass = 0; $fail = 0
  function _T([string]$label, [bool]$cond, [string]$detail) {
    if ($cond) { Write-Output "  ok    $label"; $script:pass++ }
    else { Write-Output "  FAIL  $label - $detail"; $script:fail++ }
  }
  $q = [char]34
  # MUST FIRE: the founding case of 2026-09-20, with its real numbers.
  $founding = 'git.exe range-diff origin/main...origin/claude/wave-p5-order origin/main...origin/claude/i234-republish'
  $v = Get-ReapVerdict -Name 'git' -CommandLine $founding -ParentAlive $false -CpuMinutes 1728 -CoreSharePct 99
  _T 'MUST FIRE the founding orphaned git range-diff at 1728 CPU-minutes is REAPED' ($v.action -eq 'reap' -and $v.verb -eq 'range-diff') "action=$($v.action) verb=$($v.verb)"
  # MUST NOT FIRE: a live parent owns its own child, however long it has run.
  $v = Get-ReapVerdict -Name 'git' -CommandLine $founding -ParentAlive $true -CpuMinutes 1728 -CoreSharePct 99
  _T 'MUST NOT FIRE the same command with a LIVE parent is never touched' ($v.action -eq 'keep') "action=$($v.action)"
  # MUST NOT FIRE: writers. Killing one can leave a lock or a half-written pack behind.
  foreach ($w in @('push', 'commit', 'gc', 'repack', 'fetch', 'rebase', 'index-pack', 'maintenance')) {
    $v = Get-ReapVerdict -Name 'git' -CommandLine ("git.exe $w --all") -ParentAlive $false -CpuMinutes 5000 -CoreSharePct 100
    _T "MUST NOT FIRE an orphaned 'git $w' at 5000 CPU-minutes is REPORTED, never reaped" ($v.action -eq 'report') "action=$($v.action)"
  }
  # MUST NOT FIRE: an unknown subcommand is treated as a writer, so a new git verb cannot be killed by default.
  $v = Get-ReapVerdict -Name 'git' -CommandLine 'git.exe some-future-verb --flag' -ParentAlive $false -CpuMinutes 5000 -CoreSharePct 100
  _T 'MUST NOT FIRE an UNKNOWN git subcommand is treated as a writer' ($v.action -eq 'report') "action=$($v.action)"
  # MUST NOT FIRE: powershell. Every scheduled task on this box looks orphaned, because Task Scheduler exits.
  $v = Get-ReapVerdict -Name 'powershell' -CommandLine 'powershell.exe -File C:\Codex\ThriftyCrew\grocery\capture-run.ps1 -Kind daily' -ParentAlive $false -CpuMinutes 4000 -CoreSharePct 100
  _T 'MUST NOT FIRE an orphaned scheduled-task powershell is REPORTED, never reaped' ($v.action -eq 'report') "action=$($v.action)"
  # MUST NOT FIRE: orphaned, read-only, huge CPU, but BLOCKED right now. A kill gives no core back.
  $v = Get-ReapVerdict -Name 'git' -CommandLine 'git.exe log --all' -ParentAlive $false -CpuMinutes 900 -CoreSharePct 0
  _T 'MUST NOT FIRE an orphaned read-only git that is NOT spinning is reported, not reaped' ($v.action -eq 'report') "action=$($v.action)"
  # AT THE BAR and one step past it, in the comparison's own resolution (0.1 CPU-minute, 0.1 percentage point).
  $v = Get-ReapVerdict -Name 'git' -CommandLine 'git.exe log' -ParentAlive $false -CpuMinutes 10 -CoreSharePct 50
  _T 'AT THE BAR exactly 10 CPU-minutes at exactly 50% of a core is REAPED (the bars are inclusive)' ($v.action -eq 'reap') "action=$($v.action)"
  $v = Get-ReapVerdict -Name 'git' -CommandLine 'git.exe log' -ParentAlive $false -CpuMinutes 9.9 -CoreSharePct 50
  _T 'A STEP PAST THE BAR 9.9 CPU-minutes is kept' ($v.action -eq 'keep') "action=$($v.action)"
  $v = Get-ReapVerdict -Name 'git' -CommandLine 'git.exe log' -ParentAlive $false -CpuMinutes 10 -CoreSharePct 49.9
  _T 'A STEP PAST THE BAR 49.9% of a core is kept' ($v.action -eq 'keep') "action=$($v.action)"
  # CLEAN TWIN: the ordinary case, which is most of the table. A short git command is not a finding.
  $v = Get-ReapVerdict -Name 'git' -CommandLine 'git.exe status' -ParentAlive $false -CpuMinutes 0.2 -CoreSharePct 95
  _T 'CLEAN TWIN a brief orphaned git command is kept and is not reported' ($v.action -eq 'keep' -and $v.why -match 'under the bars') "action=$($v.action)"
  # Subcommand parsing: the global options that eat the next token are why this is a function.
  _T 'the subcommand skips -C <path> and --no-pager' ((Get-GitSubcommand ('git.exe -C ' + $q + 'C:\Codex\Thrifty Crew' + $q + ' --no-pager range-diff a b')) -eq 'range-diff') (Get-GitSubcommand 'git.exe -C x --no-pager range-diff a b')
  _T 'the subcommand skips -c key=value, so a configured PUSH still reads as push' ((Get-GitSubcommand 'git.exe -c user.name=x push origin main') -eq 'push') (Get-GitSubcommand 'git.exe -c user.name=x push origin main')
  _T 'a bare git with no subcommand yields an empty verb and is kept' ((Get-GitSubcommand 'git.exe') -eq '') (Get-GitSubcommand 'git.exe')
  $v = Get-ReapVerdict -Name 'git' -CommandLine 'git.exe' -ParentAlive $false -CpuMinutes 5000 -CoreSharePct 100
  _T 'MUST NOT FIRE a git process whose subcommand cannot be read is never reaped' ($v.action -eq 'report') "action=$($v.action)"

  # ---- OWNERSHIP THROUGH A TOOL'S OWN WRAPPER ------------------------------------------------------
  # Found while proving this script on a real orphan: git on Windows forks, so a dead session leaves an
  # orphaned WRAPPER burning nothing and a BUSY CHILD whose parent (the wrapper) is alive. Asking only
  # about the immediate parent reaps neither, and the core stays lost. Measured that morning: wrapper
  # pid 48084 at 0 CPU with a dead parent, worker pid 41964 at 59.5 CPU-seconds parented to the wrapper.
  $now = Get-Date
  $forkTable = @{
    48084 = @{ ParentId = 45896; Name = 'git.exe'; Start = $now.AddMinutes(-5) }   # wrapper, parent GONE
    41964 = @{ ParentId = 48084; Name = 'git.exe'; Start = $now.AddMinutes(-5) }   # the worker
  }
  _T 'MUST FIRE the worker under an orphaned git WRAPPER is not owned (the fork shape)' ((Test-EffectiveParentAlive -Id 41964 -Table $forkTable) -eq $false) 'read as owned'
  _T 'MUST FIRE the orphaned wrapper itself is not owned either' ((Test-EffectiveParentAlive -Id 48084 -Table $forkTable) -eq $false) 'read as owned'
  # CLEAN TWIN: the same two-process shape under a LIVE session is owned, which is every git command a
  # session or a gate runs. Reaping one of these would be the worst thing this script could do.
  $ownedTable = @{
    900 = @{ ParentId = 800; Name = 'git.exe'; Start = $now.AddMinutes(-5) }
    800 = @{ ParentId = 700; Name = 'git.exe'; Start = $now.AddMinutes(-6) }
    700 = @{ ParentId = 1;   Name = 'powershell.exe'; Start = $now.AddMinutes(-7) }
    1   = @{ ParentId = 0;   Name = 'services.exe'; Start = $now.AddHours(-9) }
  }
  _T 'CLEAN TWIN a git worker whose wrapper has a live powershell parent IS owned' ((Test-EffectiveParentAlive -Id 900 -Table $ownedTable) -eq $true) 'read as orphaned'
  # MUST NOT FIRE: a recycled pid is not an ancestor. Windows reuses pids, and a stranger that started
  # after the child would otherwise hide a real orphan behind a live pid.
  $recycled = @{
    900 = @{ ParentId = 800; Name = 'git.exe'; Start = $now.AddMinutes(-30) }
    800 = @{ ParentId = 700; Name = 'powershell.exe'; Start = $now.AddMinutes(-2) }   # started AFTER its child
  }
  _T 'MUST NOT FIRE a parent that started after its child is not the parent' ((Test-EffectiveParentAlive -Id 900 -Table $recycled) -eq $false) 'read as owned'
  # A malformed table must not hang a reaper: a self-parent and an unknown pid both end the walk.
  $loop = @{ 900 = @{ ParentId = 900; Name = 'git.exe'; Start = $now } }
  _T 'a self-parented process ends the walk instead of looping forever' ((Test-EffectiveParentAlive -Id 900 -Table $loop) -eq $false) 'did not end'
  _T 'a pid absent from the table is not owned' ((Test-EffectiveParentAlive -Id 12345 -Table $ownedTable) -eq $false) 'read as owned'

  # ---- WHICH HALF PAGES ------------------------------------------------------------------------------
  # A reaped process is dealt with; one this script refused to kill is a core being wasted right now and
  # only a person can decide about it. The two therefore carry different subjects with different classes
  # in grocery\alert-registry.json (review and page), and these cases pin the routing that decides it.
  $plan = @(Get-AlertPlan -ReapedCount 0 -ReportedCount 2)
  _T 'MUST FIRE a run that could NOT kill something pages its own subject' ($plan.Count -eq 1 -and $plan[0].kind -eq 'reported' -and $plan[0].subject -eq 'Ops: a process is burning a core and nothing owns it') "count=$($plan.Count) subject=$(if ($plan.Count) { $plan[0].subject } else { 'none' })"
  $plan = @(Get-AlertPlan -ReapedCount 3 -ReportedCount 0)
  _T 'CLEAN TWIN a run that only reaped sends the quiet subject, which the registry classes review' ($plan.Count -eq 1 -and $plan[0].kind -eq 'reaped' -and $plan[0].subject -eq 'Ops: a runaway process was reaped') "count=$($plan.Count) subject=$(if ($plan.Count) { $plan[0].subject } else { 'none' })"
  $plan = @(Get-AlertPlan -ReapedCount 2 -ReportedCount 2)
  _T 'MUST FIRE a run with both halves sends BOTH subjects, so the urgent one is never folded into the quiet one' ($plan.Count -eq 2 -and $plan[0].kind -eq 'reaped' -and $plan[1].kind -eq 'reported') "count=$($plan.Count)"
  $plan = @(Get-AlertPlan -ReapedCount 0 -ReportedCount 0)
  _T 'MUST NOT FIRE a quiet run sends nothing at all' ($plan.Count -eq 0) "count=$($plan.Count)"
  $subjects = @((Get-AlertPlan -ReapedCount 9 -ReportedCount 9) | ForEach-Object { $_.subject })
  _T 'the subjects carry no digits, so send-alert cannot read each run as a new alert type' (-not ($subjects -join ' ' -match '\d')) ($subjects -join ' | ')
  # THE ROUTED SUBJECT AND THE LITERAL AT THE CALL SITE ARE TWO COPIES OF ONE FACT, which is this
  # estate's most expensive shape. The call site has to spell the subject literally or the registry
  # audit cannot follow it, so this case is what keeps the pair honest: each routed subject must appear
  # as a -Subject literal in this file's own source. The needle is built from the FUNCTION's answer, so
  # it is not a constant grepping for itself.
  try {
    $src = (Get-Content -LiteralPath $PSCommandPath -Raw -ErrorAction Stop) + ''
    $missing = @()
    foreach ($s in $subjects) {
      $needle = '-Subject ' + [char]39 + $s + [char]39
      if (-not $src.Contains($needle)) { $missing += $s }
    }
    _T 'every routed subject is spelled as a -Subject LITERAL at a call site, so the registry audit can read it' ($missing.Count -eq 0) ("missing: " + ($missing -join ' | '))
  } catch {
    _T 'every routed subject is spelled as a -Subject LITERAL at a call site, so the registry audit can read it' $false $_.Exception.Message
  }

  # ---- THE LEDGER LINE, in the exact shape the live path writes --------------------------------------
  # MUST FIRE, and it is here because it went wrong on the first real reap: the live call passed -Line to
  # Add-TcLine, whose parameter is -Text, and the catch around it was bare. The process was killed
  # correctly and no record existed. This drives the same call with the same row shape.
  $ledger = Join-Path $env:TEMP ('tc-reap-ledger-' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '.jsonl')
  try {
    $row = [pscustomobject]([ordered]@{ ts = (Get-Date).ToString('o'); pid = 4242; name = 'git'; verb = 'range-diff'
                                        cpu_minutes = 1728; core_share_pct = 99; parent_id = 1; command = 'git.exe range-diff a b'
                                        why = 'fixture'; killed = $true; acted = $true })
    Add-TcLine -Path $ledger -Text (($row | ConvertTo-Json -Compress -Depth 4)) | Out-Null
    $back = @(Get-Content -LiteralPath $ledger -ErrorAction Stop)
    $parsed = $null
    if ($back.Count -eq 1) { $parsed = $back[0] | ConvertFrom-Json }
    _T 'MUST FIRE a reap writes ONE parsable ledger line naming the pid and the verb' (($back.Count -eq 1) -and ($null -ne $parsed) -and ([int]$parsed.pid -eq 4242) -and ([string]$parsed.verb -eq 'range-diff')) "lines=$($back.Count)"
  } catch {
    _T 'MUST FIRE a reap writes ONE parsable ledger line naming the pid and the verb' $false $_.Exception.Message
  } finally { Remove-Item -LiteralPath $ledger -Force -ErrorAction SilentlyContinue }

  # ---- END TO END, on a real orphan this script creates and owns -----------------------------------
  # The pure cases above cannot prove that the ENUMERATOR sees an orphan, measures a spin or that the
  # kill works. This spawns a grandchild that outlives its launcher, so its parent is genuinely gone.
  # Per run, never a fixed name under %TEMP%: several sessions push at once and each runs this suite.
  $marker = 'tc-reap-fixture-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
  $fxDir = Join-Path $env:TEMP $marker
  $spinner = $null
  try {
    New-Item -ItemType Directory -Path $fxDir -ErrorAction Stop | Out-Null
    # TWO FILES, NOT A NESTED -Command STRING. The first version built the grandchild's command line by
    # concatenating quotes through two levels of Start-Process; it spawned nothing and the case failed
    # for the harness's reason rather than the code's. The marker rides in the fixture's PATH, so it is
    # visible in the spinner's own command line without any quoting at all.
    $spinPs1 = Join-Path $fxDir 'spin.ps1'
    $launchPs1 = Join-Path $fxDir 'launch.ps1'
    Set-Content -LiteralPath $spinPs1 -Encoding ascii -Value 'while ($true) { $null = 1 }'
    Set-Content -LiteralPath $launchPs1 -Encoding ascii -Value (
      "Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$spinPs1'")
    $launcher = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launchPs1)
    $launcher.WaitForExit(20000) | Out-Null
    Start-Sleep -Seconds 2
    $found = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
               Where-Object { $_.CommandLine -and $_.CommandLine.Contains($marker) })
    if ($found.Count -ne 1) {
      _T 'the end-to-end fixture spawned exactly one orphaned spinner' $false "found $($found.Count)"
    } else {
      $spinner = [int]$found[0].ProcessId
      $sample = @(Get-ProcessSample -Seconds 3 -Names @('powershell'))
      $rec = @($sample | Where-Object { $_.Id -eq $spinner })
      _T 'MUST FIRE the sampler finds the real orphan and reads its PARENT as gone' ($rec.Count -eq 1 -and -not $rec[0].ParentAlive) "records=$($rec.Count) parentAlive=$(if ($rec.Count) { $rec[0].ParentAlive } else { 'n/a' })"
      _T 'MUST FIRE the sampler measures the spinner at 50% or more of one core' ($rec.Count -eq 1 -and $rec[0].CoreSharePct -ge 50) "share=$(if ($rec.Count) { $rec[0].CoreSharePct } else { 'n/a' })"
      # CLEAN TWIN: this self-test's OWN process has a live parent, so the sampler must not call it an orphan.
      $self = @($sample | Where-Object { $_.Id -eq $PID })
      _T 'CLEAN TWIN the sampler reads THIS self-test, which has a live parent, as owned' ($self.Count -eq 1 -and $self[0].ParentAlive) "self records=$($self.Count) parentAlive=$(if ($self.Count) { $self[0].ParentAlive } else { 'n/a' })"
      # MUST FIRE: the kill path actually kills.
      $killed = Invoke-ReapProcess -Id $spinner
      _T 'MUST FIRE Invoke-ReapProcess kills the real spinner and confirms it is gone' $killed 'the process survived'
      if ($killed) { $spinner = $null }
    }
  } catch {
    _T 'the end-to-end orphan fixture ran' $false $_.Exception.Message
  } finally {
    if ($spinner) { try { Stop-Process -Id $spinner -Force -ErrorAction SilentlyContinue } catch { } }
    Remove-Item -LiteralPath $fxDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  # ---- THE KILL WAITS ON THE PROCESS'S EXIT, NEVER ON A CLOCK --------------------------------------
  # Founding red, 2026-09-23 about 13:09: a push-main run was refused with pass=489 fail=1, the one failure
  # the MUST FIRE above reading "the process survived", and the same self-test passed standalone a minute
  # later. The kill slept a fixed 500 ms and then asked the table; under the gate pool a killed
  # powershell.exe took longer than that to leave it. These cases HOLD the exit open on a stop file the
  # test controls, so the exit lands after the kill has returned however loaded the box is.
  # There is no AT-THE-BAR case for -ExitWaitMs on purpose: it is a hang guard, and a case at it would be
  # an upper wall-clock bar, which is exactly the shape that went red.
  $hxDir = Join-Path $env:TEMP ('tc-reap-hold-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  $held = $null; $never = $null; $done = $null
  try {
    New-Item -ItemType Directory -Path $hxDir -ErrorAction Stop | Out-Null
    $holdPs1 = Join-Path $hxDir 'hold.ps1'
    # After the stop file it LINGERS 3 s before exiting. That is a LOWER bound, which load can only
    # lengthen, and it is what makes a fixed-sleep reaper go red on a quiet box too: measured the day
    # this landed, a mutant that slept 500 ms and then read HasExited PASSED every case without it.
    Set-Content -LiteralPath $holdPs1 -Encoding ascii -Value 'param([string]$Stop) while (-not (Test-Path -LiteralPath $Stop)) { Start-Sleep -Milliseconds 20 }; Start-Sleep -Seconds 3'
    $stopHeld = Join-Path $hxDir 'stop-held'
    $stopNever = Join-Path $hxDir 'stop-never'   # never written
    $held = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $holdPs1, '-Stop', $stopHeld)
    $null = $held.Handle   # keep a handle so HasExited stays readable and the pid cannot be reused

    # MUST FIRE: the seam does not kill; it reads the target STILL RUNNING (it cannot exit before the stop
    # file exists), then writes the stop file and returns. The exit therefore lands after the "kill" has
    # returned, and only a reaper that waits on the process's own exit can report it gone.
    $obs = @{ aliveAtKill = $null }
    $seam = { param($p) $obs.aliveAtKill = (-not $p.HasExited); Set-Content -LiteralPath $stopHeld -Value 'go' }.GetNewClosure()
    $ok = Invoke-ReapProcess -Id $held.Id -ExitWaitMs 120000 -Kill $seam   # a hang guard far past the linger
    _T 'MUST FIRE a process whose exit lands AFTER the kill returns is confirmed gone (the wait is on its exit, not a clock)' (
      $ok -and ($obs.aliveAtKill -eq $true) -and $held.HasExited) "returned=$ok aliveAtKill=$($obs.aliveAtKill) exited=$($held.HasExited)"

    # MUST NOT FIRE, the real timer's own twin: a process that never exits is NOT reported gone, and the
    # hang guard ENDS the wait. This reads that it ended and what it said, never how long it took.
    $never = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $holdPs1, '-Stop', $stopNever)
    $null = $never.Handle
    $ok = Invoke-ReapProcess -Id $never.Id -ExitWaitMs 200 -Kill { param($p) }
    _T 'MUST NOT FIRE a process that never exits is reported NOT gone once the hang guard ends the wait' (
      (-not $ok) -and (-not $never.HasExited)) "returned=$ok exited=$($never.HasExited)"

    # CLEAN TWIN: a pid that exited before the reaper got to it is a success. The open handle pins the pid,
    # so the real kill below cannot land on a stranger that reused it.
    $done = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-Command', 'exit 0')
    $null = $done.Handle
    $null = $done.WaitForExit(120000)   # hang guard only
    $ok = Invoke-ReapProcess -Id $done.Id
    _T 'CLEAN TWIN a pid that has already exited is a success' ($done.HasExited -and $ok) "returned=$ok exited=$($done.HasExited)"
  } catch {
    _T 'the held-exit fixture ran' $false $_.Exception.Message
  } finally {
    foreach ($px in @($held, $never, $done)) {
      if ($px) { try { if (-not $px.HasExited) { $px.Kill() } } catch { }; try { $px.Dispose() } catch { } }
    }
    Remove-Item -LiteralPath $hxDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  Write-Output ''
  if ($fail -gt 0) { Write-Output "reap-runaway-processes self-test: FAIL ($fail of $($pass + $fail) case(s))"; exit 1 }
  Write-Output "reap-runaway-processes self-test: PASS ($pass case(s), 0 failed)"
  exit 0
}

# ---------------------------------------------------------------------------- LIVE
# EVERY HIDDEN SCHEDULED TASK WRITES A RUN RECORD (backlog E29, gated by ops\audit-run-log-claims.ps1).
# This one runs every 15 minutes with -WindowStyle Hidden, so without a record its death would look
# exactly like a quiet box with nothing to reap, which is the failure it exists to catch. The transcript
# appends into one file per day, so the cadence costs one file, not 96.
$script:RunLog = Start-RunLog -Name 'reap-runaway-processes' -OutDir (Join-Path $RepoRoot 'ops\out')
try {
$sample = @()
try { $sample = @(Get-ProcessSample -Seconds $SampleSeconds) } catch {
  Write-Output ("reap-runaway-processes: COULD NOT LOOK - " + $_.Exception.Message)
  Exit-Guard -Name 'REAP-RUNAWAY' -Code 3 -Summary 'could not read the process table'
}
if ($sample.Count -eq 0) {
  Write-Output 'reap-runaway-processes: COULD NOT LOOK - the process table read as empty, which it never is'
  Exit-Guard -Name 'REAP-RUNAWAY' -Code 3 -Summary 'empty process table'
}

$reaped = New-Object 'System.Collections.Generic.List[object]'
$reported = New-Object 'System.Collections.Generic.List[object]'
foreach ($p in $sample) {
  if ($p.Id -eq $PID) { continue }
  $v = Get-ReapVerdict -Name $p.Name -CommandLine $p.CommandLine -ParentAlive $p.ParentAlive `
                       -CpuMinutes $p.CpuMinutes -CoreSharePct $p.CoreSharePct `
                       -ReapCpuMinutes $ReapCpuMinutes -ReportCpuMinutes $ReportCpuMinutes -SpinCorePct $SpinCorePct
  if ($v.action -eq 'reap') {
    $row = [ordered]@{
      ts = (Get-Date).ToString('o'); pid = $p.Id; name = $p.Name; verb = $v.verb
      cpu_minutes = $p.CpuMinutes; core_share_pct = $p.CoreSharePct; parent_id = $p.ParentId
      command = $p.CommandLine; why = $v.why; killed = $false; acted = [bool]$Reap
    }
    if ($Reap) { $row.killed = (Invoke-ReapProcess -Id $p.Id) }
    [void]$reaped.Add([pscustomobject]$row)
  } elseif ($v.action -eq 'report') {
    [void]$reported.Add([pscustomobject]@{ pid = $p.Id; name = $p.Name; cpu_minutes = $p.CpuMinutes;
                                           core_share_pct = $p.CoreSharePct; why = $v.why; command = $p.CommandLine })
  }
}

$reapedArr = $reaped.ToArray()
$reportedArr = $reported.ToArray()
foreach ($r in $reapedArr) {
  $verb = if ($Reap) { if ($r.killed) { 'REAPED' } else { 'COULD NOT KILL' } } else { 'WOULD REAP (-Reap not passed)' }
  Write-Output ("  $verb  pid $($r.pid) $($r.name): $($r.why)")
  Write-Output ("          $($r.command)")
  # A KILL THAT LEAVES NO RECORD IS THE ONE THING THIS SCRIPT MUST NOT DO, so the failure is LOUD.
  # Measured 2026-09-20 on the first real reap: this call passed -Line, Add-TcLine's parameter is -Text,
  # and a bare `catch { }` swallowed the ParameterBindingException. The kill was right and the ledger was
  # empty, which is the estate's own "a fallback that logs nothing is the blind kind" in two lines.
  try { Add-TcLine -Path $script:ReapLog -Text (($r | ConvertTo-Json -Compress -Depth 4)) | Out-Null }
  catch { Write-Output ("  LEDGER WRITE FAILED for pid $($r.pid): " + $_.Exception.Message) }
}
foreach ($r in $reportedArr) {
  Write-Output ("  REPORT  pid $($r.pid) $($r.name): $($r.why)")
}

if ($Alert) {
  $alert = Join-Path $RepoRoot 'grocery\send-alert.ps1'
  foreach ($a in (Get-AlertPlan -ReapedCount $reapedArr.Count -ReportedCount $reportedArr.Count)) {
    try {
      if (-not (Test-Path -LiteralPath $alert)) { break }
      $body = New-Object 'System.Collections.Generic.List[string]'
      if ($a.kind -eq 'reaped') {
        [void]$body.Add('These processes were ORPHANED, READ-ONLY and SPINNING, so this script killed them and the')
        [void]$body.Add('cores are back. Nothing is waiting on you. The line is here so a reap can never be silent,')
        [void]$body.Add('and so a rising rate of them becomes visible as the estate leaking sessions.')
        [void]$body.Add('')
        foreach ($r in $reapedArr) { [void]$body.Add(("REAPED pid $($r.pid) $($r.name) $($r.verb): $($r.why) | $($r.command)")) }
      } else {
        [void]$body.Add('A process is burning CPU, nothing owns it, and this script deliberately did NOT kill it:')
        [void]$body.Add('it is not a read-only git command, so a kill could leave a lock or a half-written file behind.')
        [void]$body.Add('Decide whether it should be running. Until somebody does, it keeps the core.')
        [void]$body.Add('')
        foreach ($r in $reportedArr) { [void]$body.Add(("REPORT pid $($r.pid) $($r.name): $($r.why) | $($r.command)")) }
      }
      # THE SUBJECT IS A LITERAL AT THE CALL SITE, not $a.subject, so grocery\audit-alert-registry.ps1 can
      # FOLLOW it: a subject built from a variable is reported UNREADABLE and is checked by nothing. The
      # self-test asserts each literal here still equals the one Get-AlertPlan routes on, which is what
      # stops the two copies drifting apart.
      $line = ($body.ToArray()) -join "`n"
      if ($a.kind -eq 'reaped') {
        & $alert -Subject 'Ops: a runaway process was reaped' -Body $line -Emitter 'ops\reap-runaway-processes.ps1'
      } else {
        & $alert -Subject 'Ops: a process is burning a core and nothing owns it' -Body $line -Emitter 'ops\reap-runaway-processes.ps1'
      }
    } catch { Write-Output ("  ALERT SEND FAILED for '" + $a.subject + "': " + $_.Exception.Message) }
  }
}

$summary = ('sampled=' + $sample.Count + ' reaped=' + $reapedArr.Count + ' reported=' + $reportedArr.Count)
if ($reapedArr.Count -gt 0 -or $reportedArr.Count -gt 0) {
  Exit-Guard -Name 'REAP-RUNAWAY' -Code 1 -Summary $summary
}
Exit-Guard -Name 'REAP-RUNAWAY' -Code 0 -Summary $summary
} finally {
  # A CRASH MUST NOT BE RECORDED AS rc=0: guard-contract sets TcGuardMarkerWritten only when Exit-Guard
  # wrote the completion marker, so its absence means the body died. Stop-RunLog tolerates a $null path.
  $rcLog = if ($script:TcGuardMarkerWritten) { 0 } else { 1 }
  Stop-RunLog -ExitCode $rcLog -Path $script:RunLog
}
