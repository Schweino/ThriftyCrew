<#
  observe-gate-queue.ps1 - WHO is running run-gates on this box, what it cost them, and how much of it was the
  same content twice. A REPORT, never a gate, and run by hand when the gate queue is misbehaving.

  WHY IT EXISTS (2026-09-11). That afternoon pushes stopped being gated: `pre-push` waited its full 1,200s for one
  of the 10 machine-wide gate worker slots (lib\gate-slots.ps1) and exited 3, "Nothing was run; that is not a pass",
  which is the red that teaches `git push --no-verify`. Nothing in the tree could answer the first questions - how
  many runs start an hour, how many end in the slot wait rather than evaluating, and how many are a hand run
  followed by a hook run on the SAME tree - so they were answered by watching, and this is that harness kept.
  design\MEASURE-gate-slot-starvation-2026-09-11.md is what it produced.

  IT ADDS NO GATE LOAD. It holds no slot, opens no slot mutex and starts no gate. -Watch samples the process table
  and asks git about each checkout once per run seen; -Report and -Retro only read files that already exist.

  THE THREE MODES
    -Watch   sample live run-gates processes every -TickSec for -Minutes, writing one row per RUN to runs.jsonl
             (when it ends) and one row per tick to ticks.jsonl. A run's outcome is read from whether it ever had
             gate WORKER children: a run waiting for a slot spawns nothing. For hook runs that is cross-checked
             against the hook's own kept log, which the hook deletes on a pass - see -Report's classifier check.
    -Report  derive the totals from runs.jsonl. Every rate prints its denominator.
    -Retro   the same questions answered from what runs have already left behind: the hook's kept logs in %TEMP%,
             each checkout's ops\out\gate-readings.jsonl, and sessions' own saved output.

  THE CONTENT KEY is lib\gate-verdict.ps1's, so "the same tree twice" here means what the pre-push reuse means.

  SCOPE OF A CLEAN REPORT: UNSOUND in both directions, deliberately. -Watch cannot see a run that starts and ends
  inside one tick, reads a checkout's state once per run rather than continuously, and classifies a run by its
  children rather than its exit code (the check against hook logs is printed, so that inference is never taken on
  trust). -Retro is a FLOOR: the hook deletes the log of every pass, a removed worktree takes its gate-readings
  with it, and a session's saved output is overwritten by its next run.

  Usage:
    powershell -File ops\observe-gate-queue.ps1 -Watch -Minutes 90 -OutDir <dir>
    powershell -File ops\observe-gate-queue.ps1 -Report -OutDir <dir> [-WindowMin 60]
    powershell -File ops\observe-gate-queue.ps1 -Retro [-Day 2026-09-11]
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param(
  [switch]$Watch,
  [switch]$Report,
  [switch]$Retro,
  [int]$Minutes = 90,
  [int]$TickSec = 15,
  [int]$WindowMin = 60,
  [string]$OutDir = '',
  [string]$Day = ''
)
$ErrorActionPreference = 'Continue'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repoRoot = Split-Path $here -Parent
. (Join-Path $repoRoot 'lib\git-repo-env.ps1')
Clear-TcGitRepoEnv
. (Join-Path $repoRoot 'lib\gate-verdict.ps1')   # Get-TcWorkingTreeState: the same content key the reuse uses
$enc = New-Object Text.UTF8Encoding($false)

function Read-TcShared([string]$Path) {
  # A log the hook is still writing, and may delete under us.
  try {
    $fs = [IO.File]::Open($Path, 'Open', 'Read', ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { return (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
  } catch { return $null }
}

function Get-TcRunOutcome([object]$Run) {
  # EVALUATED = it had gate worker children on two ticks, or two at once. A run waiting for a slot spawns nothing.
  if (-not $Run.end) { return 'unfinished' }
  if ($Run.workerTicks -ge 2 -or $Run.maxWorkers -ge 2) { return 'evaluated' }
  $life = ([datetime]$Run.end - [datetime]$Run.start).TotalSeconds
  if ($life -ge 1150) { return 'slot-timeout' }
  return 'short-no-workers'
}

if ($Watch) {
  if (-not $OutDir) { $OutDir = Join-Path $env:TEMP ('gate-queue-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
  if (-not (Test-Path -LiteralPath $OutDir)) { $null = New-Item -ItemType Directory -Force -Path $OutDir }
  $runsF = Join-Path $OutDir 'runs.jsonl'; $ticksF = Join-Path $OutDir 'ticks.jsonl'; $mentF = Join-Path $OutDir 'mentions.jsonl'
  $tempRoot = [IO.Path]::GetTempPath()
  # A PROCESS'S WORKING DIRECTORY names its checkout, and Windows keeps it only in that process's PEB: a hand run
  # is `powershell -File ops\run-gates.ps1` with a RELATIVE path, so its command line does not say which checkout.
  Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class TcPeb {
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, byte[] info, int len, out int retLen);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
  public static string Cwd(int pid) {
    IntPtr h = OpenProcess(0x0410, false, pid);
    if (h == IntPtr.Zero) return null;
    try {
      byte[] pbi = new byte[48]; int rl;
      if (NtQueryInformationProcess(h, 0, pbi, pbi.Length, out rl) != 0) return null;
      long peb = BitConverter.ToInt64(pbi, 8);
      byte[] b8 = new byte[8]; IntPtr r;
      if (!ReadProcessMemory(h, new IntPtr(peb + 0x20), b8, new IntPtr(8), out r)) return null;
      long pp = BitConverter.ToInt64(b8, 0);
      byte[] us = new byte[16];
      if (!ReadProcessMemory(h, new IntPtr(pp + 0x38), us, new IntPtr(16), out r)) return null;
      int len = BitConverter.ToUInt16(us, 0); long buf = BitConverter.ToInt64(us, 8);
      if (len == 0 || buf == 0) return null;
      byte[] sb = new byte[len];
      if (!ReadProcessMemory(h, new IntPtr(buf), sb, new IntPtr(len), out r)) return null;
      return Encoding.Unicode.GetString(sb);
    } finally { CloseHandle(h); }
  }
}
'@
  $runs = @{}; $ments = @{}
  $deadline = (Get-Date).AddMinutes($Minutes)
  $tick = 0
  Write-Output ("observe-gate-queue: watching for {0} min, a tick every {1}s, into {2}" -f $Minutes, $TickSec, $OutDir)
  while ((Get-Date) -lt $deadline) {
    $tick++
    $now = Get-Date
    $procs = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CreationDate, CommandLine)
    $byId = @{}; $kids = @{}
    foreach ($p in $procs) {
      $byId[[int]$p.ProcessId] = $p
      $pp = [int]$p.ParentProcessId
      if (-not $kids.ContainsKey($pp)) { $kids[$pp] = [Collections.Generic.List[object]]::new() }
      $kids[$pp].Add($p)
    }
    $seen = @{}; $liveFile = 0; $liveWorking = 0
    foreach ($p in $procs) {
      $cl = [string]$p.CommandLine
      if ($cl -notmatch '(?i)run-gates\.ps1') { continue }
      if ($p.ProcessId -eq $PID) { continue }
      $isFile = ($p.Name -match '(?i)^(powershell|pwsh)\.exe$') -and ($cl -match '(?i)-File\s+"?[^"]*run-gates\.ps1')
      $key = '{0}|{1}' -f $p.ProcessId, $p.CreationDate.ToString('o')
      $seen[$key] = $true
      $ch = @(); if ($kids.ContainsKey([int]$p.ProcessId)) { $ch = @($kids[[int]$p.ProcessId] | Where-Object { $_.Name -ne 'conhost.exe' }) }
      $workers = @($ch | Where-Object { ([string]$_.CommandLine) -match '(?i)-SelfTest|\.py\b|\\ops\\audit-|-Capture|\.ps1' -and ([string]$_.CommandLine) -notmatch '(?i)run-gates\.ps1' })
      $fileKids = @($ch | Where-Object { ([string]$_.CommandLine) -match '(?i)-File\s+"?[^"]*run-gates\.ps1' })
      if (-not $isFile) {
        # A process that only NAMES run-gates - a wrapper that launches it, or a session grepping for it.
        if (-not $ments.ContainsKey($key)) {
          $ments[$key] = [ordered]@{ pid = [int]$p.ProcessId; start = $p.CreationDate.ToString('o'); parent = $(if ($byId[[int]$p.ParentProcessId]) { $byId[[int]$p.ParentProcessId].Name } else { 'DEAD' }); hasFileChild = $false; maxWorkers = 0; workerTicks = 0; pushes = ($cl -match '(?i)git\s+push'); lastSeen = $null; end = $null }
        }
        $m = $ments[$key]
        if ($fileKids.Count) { $m.hasFileChild = $true }
        if ($workers.Count -gt $m.maxWorkers) { $m.maxWorkers = $workers.Count }
        if ($workers.Count) { $m.workerTicks++ }
        $m.lastSeen = $now.ToString('o')
        continue
      }
      $liveFile++
      if (-not $runs.ContainsKey($key)) {
        $chain = @(); $claudePid = $null; $wrapperPushes = $false; $cur = $byId[[int]$p.ParentProcessId]; $depth = 0
        while ($cur -and $depth -lt 8) {
          $chain += $cur.Name
          if ($depth -eq 0 -and ([string]$cur.CommandLine) -match '(?i)git\s+push') { $wrapperPushes = $true }
          if ($cur.Name -eq 'claude.exe' -and -not $claudePid) { $claudePid = [int]$cur.ProcessId }
          $nxt = $byId[[int]$cur.ParentProcessId]
          if (-not $nxt -or $nxt.ProcessId -eq $cur.ProcessId -or $nxt.CreationDate -gt $cur.CreationDate) { break }
          $cur = $nxt; $depth++
        }
        # The hook runs the gate through sh; a session runs it under claude.exe, directly or through a wrapper.
        $origin = if ($chain.Count -and $chain[0] -eq 'sh.exe') { 'hook' } elseif ($chain -contains 'claude.exe') { 'manual' } else { 'other' }
        $cwd = [TcPeb]::Cwd([int]$p.ProcessId)
        $top = $null
        if ($cl -match '(?i)-File\s+"?([A-Za-z]:[\\/][^"]*?)[\\/]ops[\\/]run-gates\.ps1') { $top = $Matches[1] -replace '/', '\' }
        elseif ($cwd) {
          $st = Get-TcWorkingTreeState -Top $cwd.TrimEnd('\') -ScratchDir $OutDir
          if ($st.Ok) { $top = $st.Top }
        }
        $ck = $null
        if ($top) { $ck = Get-TcWorkingTreeState -Top $top -ScratchDir $OutDir }
        $logs = @()
        if ($origin -eq 'hook') {
          $logs = @(Get-ChildItem -LiteralPath $tempRoot -Filter 'tc-prepush-*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^tc-prepush-\d+\.log$' -and [Math]::Abs(($_.CreationTime - $p.CreationDate).TotalSeconds) -le 3 } |
            ForEach-Object { $_.FullName })
        }
        $runs[$key] = [ordered]@{
          pid = [int]$p.ProcessId; start = $p.CreationDate.ToString('o'); firstSeen = $now.ToString('o'); origin = $origin
          chain = ($chain -join '<'); claudePid = $claudePid; wrapperPushes = $wrapperPushes; cwd = $cwd; top = $top
          head = $(if ($ck) { $ck.HeadTree } else { $null }); headTree = $(if ($ck) { $ck.HeadTree } else { $null })
          keyStart = $(if ($ck) { $ck.ContentKey } else { $null }); keyErr = $(if ($ck) { $ck.Why } else { 'no-top' })
          dirtyStart = $(if ($ck) { $ck.Dirty.Count } else { -1 })
          keyEnd = $null; maxWorkers = 0; workerTicks = 0; firstWorkerAt = $null; lastSeen = $null; end = $null
          logCandidates = $logs; logVerdict = $null; logState = $null; finished = $false
        }
      }
      $r = $runs[$key]
      if ($workers.Count) { $liveWorking++; $r.workerTicks++; if (-not $r.firstWorkerAt) { $r.firstWorkerAt = $now.ToString('o') } }
      if ($workers.Count -gt $r.maxWorkers) { $r.maxWorkers = $workers.Count }
      $r.lastSeen = $now.ToString('o')
    }
    foreach ($k in @($runs.Keys)) {
      $r = $runs[$k]
      if ($r.finished -or $seen.ContainsKey($k)) { continue }
      $r.end = $now.ToString('o'); $r.finished = $true
      if ($r.top) { $ck2 = Get-TcWorkingTreeState -Top $r.top -ScratchDir $OutDir; if ($ck2.Ok) { $r.keyEnd = $ck2.ContentKey } }
      if ($r.origin -eq 'hook') {
        # THE HOOK DELETES ITS LOG ON A PASS, so a log that is gone is a pass and a log that stayed names the refusal.
        $cand = @($r.logCandidates)
        if ($cand.Count -eq 1) {
          if (Test-Path -LiteralPath $cand[0]) {
            $txt = Read-TcShared $cand[0]
            $v = @([regex]::Matches([string]$txt, '(?m)^run-gates: (PASSED|FAILED|COULD NOT EVALUATE)[^\r\n]*') | ForEach-Object { $_.Value })
            $r.logState = 'kept'; $r.logVerdict = $(if ($v.Count) { $v[$v.Count - 1] } else { '(no verdict line)' })
          } else { $r.logState = 'deleted-by-hook-rc0' }
        } else { $r.logState = ('ambiguous-' + $cand.Count) }
      }
      [IO.File]::AppendAllText($runsF, (($r | ConvertTo-Json -Compress -Depth 4) + "`n"), $enc)
    }
    foreach ($k in @($ments.Keys)) {
      if ($seen.ContainsKey($k)) { continue }
      $m = $ments[$k]; $m.end = $now.ToString('o')
      [IO.File]::AppendAllText($mentF, (($m | ConvertTo-Json -Compress) + "`n"), $enc)
      $ments.Remove($k)
    }
    $row = [ordered]@{ t = $now.ToString('o'); tick = $tick; liveRuns = $liveFile; liveWithWorkers = $liveWorking; tracked = $runs.Count }
    [IO.File]::AppendAllText($ticksF, (($row | ConvertTo-Json -Compress) + "`n"), $enc)
    $sleep = $TickSec * 1000 - [int]((Get-Date) - $now).TotalMilliseconds
    if ($sleep -gt 0) { Start-Sleep -Milliseconds $sleep }
  }
  foreach ($k in @($runs.Keys)) {
    $r = $runs[$k]
    if ($r.finished) { continue }
    [IO.File]::AppendAllText($runsF, (($r | ConvertTo-Json -Compress -Depth 4) + "`n"), $enc)
  }
  Write-Output ("OBSERVE-GATE-QUEUE-COMPLETE mode=watch ticks={0} runs={1} dir={2}" -f $tick, $runs.Count, $OutDir)
  exit 0
}

if ($Report) {
  if (-not $OutDir -or -not (Test-Path -LiteralPath (Join-Path $OutDir 'runs.jsonl'))) {
    Write-Output 'BLIND: -Report needs the -OutDir of a -Watch run, holding runs.jsonl'
    Write-Output 'OBSERVE-GATE-QUEUE-COMPLETE mode=report blind=1'
    exit 3
  }
  $ticks = @(Get-Content (Join-Path $OutDir 'ticks.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
  $all = @(Get-Content (Join-Path $OutDir 'runs.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
  $t0 = [datetime]$ticks[0].t; $tEnd = [datetime]$ticks[$ticks.Count - 1].t
  $w0 = $t0; $w1 = $t0.AddMinutes($WindowMin)
  Write-Output ("window: sampler ran {0:HH:mm:ss} to {1:HH:mm:ss} ({2} ticks); runs seen {3}, including those already live at the start" -f $t0, $tEnd, $ticks.Count, $all.Count)
  foreach ($r in $all) {
    $r | Add-Member -NotePropertyName s -NotePropertyValue ([datetime]$r.start) -Force
    $r | Add-Member -NotePropertyName e -NotePropertyValue $(if ($r.end) { [datetime]$r.end } else { $null }) -Force
    $r | Add-Member -NotePropertyName outcome -NotePropertyValue (Get-TcRunOutcome $r) -Force
  }
  $win = @($all | Where-Object { $_.s -ge $w0 -and $_.s -lt $w1 })
  Write-Output ("STARTS in the first {0} min: {1} -> {2:N1} per hour" -f $WindowMin, $win.Count, ($win.Count * 60.0 / $WindowMin))
  foreach ($o in 'hook', 'manual', 'other') { Write-Output ("   {0,-7} {1} of {2}" -f $o, @($win | Where-Object { $_.origin -eq $o }).Count, $win.Count) }
  Write-Output 'OUTCOMES of those starts:'
  foreach ($g in ($win | Group-Object outcome | Sort-Object Name)) {
    Write-Output ("   {0,-17} {1,3} of {2}  ({3})" -f $g.Name, $g.Count, $win.Count, (($g.Group | Group-Object origin | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '))
  }
  $fin = @($win | Where-Object { $_.outcome -ne 'unfinished' })
  $ev = @($fin | Where-Object { $_.outcome -eq 'evaluated' }); $to = @($fin | Where-Object { $_.outcome -eq 'slot-timeout' })
  if ($fin.Count) {
    Write-Output ("   of the {0} that finished inside the sampler: evaluated {1} ({2:P0}), slot-wait exit 3 {3} ({4:P0})" -f $fin.Count, $ev.Count, ($ev.Count / $fin.Count), $to.Count, ($to.Count / $fin.Count))
  }
  # THE INFERENCE IS CHECKED, never trusted: for hook runs the hook's own log says what really happened.
  $agree = 0; $dis = @(); $noTruth = 0
  foreach ($r in @($all | Where-Object { $_.origin -eq 'hook' -and $_.end })) {
    $truth = if ($r.logState -eq 'deleted-by-hook-rc0') { 'evaluated' }
      elseif ($r.logState -eq 'kept' -and $r.logVerdict -match 'waited') { 'slot-timeout' }
      elseif ($r.logState -eq 'kept' -and $r.logVerdict -match 'PASSED|FAILED') { 'evaluated' }
      else { $null }
    if (-not $truth) { $noTruth++; continue }
    if ($truth -eq $r.outcome) { $agree++ } else { $dis += ("{0} {1:HH:mm:ss} called {2}, log says {3}" -f $r.top, $r.s, $r.outcome, $truth) }
  }
  Write-Output ("CLASSIFIER against the hook's own log: agrees {0} of {1} readable verdict(s); {2} hook run(s) had none" -f $agree, ($agree + $dis.Count), $noTruth)
  $dis | ForEach-Object { Write-Output ('   DISAGREE ' + $_) }
  # THE SAME CONTENT TWICE, keyed exactly as lib\gate-verdict.ps1 keys it.
  $keyed = @($all | Where-Object { $_.keyStart } | Sort-Object s)
  $hooksW = @($keyed | Where-Object { $_.origin -eq 'hook' -and $_.s -ge $w0 -and $_.s -lt $w1 })
  $pairM = 0; $pairMEval = 0; $pairMOverlap = 0; $pairHook = 0; $gaps = @()
  foreach ($h in $hooksW) {
    $prior = @($keyed | Where-Object { $_.top -eq $h.top -and $_.s -lt $h.s -and $_.pid -ne $h.pid -and ($_.keyEnd -eq $h.keyStart -or $_.keyStart -eq $h.keyStart) })
    $m = @($prior | Where-Object { $_.origin -eq 'manual' })
    if ($m.Count) {
      $pairM++
      $last = $m[$m.Count - 1]
      if ($last.outcome -eq 'evaluated') { $pairMEval++; if ($last.e -and $last.e -le $h.s) { $gaps += [int]($h.s - $last.e).TotalSeconds } }
      if (-not $last.e -or $last.e -gt $h.s) { $pairMOverlap++ }
    }
    if (@($prior | Where-Object { $_.origin -eq 'hook' }).Count) { $pairHook++ }
  }
  Write-Output ("SAME CONTENT TWICE, of the {0} hook run(s) started in the window with a content key:" -f $hooksW.Count)
  Write-Output ("   preceded by a HAND run on the same checkout with the same content key: {0} of {1}" -f $pairM, $hooksW.Count)
  Write-Output ("      of those, the hand run had already EVALUATED: {0}; it was still running when the hook started: {1}" -f $pairMEval, $pairMOverlap)
  if ($gaps.Count) { Write-Output ("      gap from hand-run end to hook start, seconds: " + (($gaps | Sort-Object) -join ', ')) }
  Write-Output ("   preceded by an earlier HOOK run on the same checkout and key (a re-push): {0} of {1}" -f $pairHook, $hooksW.Count)
  $winK = @($keyed | Where-Object { $_.s -ge $w0 -and $_.s -lt $w1 })
  $uniq = @($winK | Group-Object { "$($_.top)|$($_.keyStart)" })
  Write-Output ("   distinct (checkout, content) among {0} window starts that had a key: {1} -> {2:N1} per hour of real demand" -f $winK.Count, $uniq.Count, ($uniq.Count * 60.0 / $WindowMin))
  # CLEAN IS READ FROM THE KEYS, not from a dirty count: a clean tree's content key IS HEAD's tree, and that holds
  # for rows written by any version of -Watch. It is the condition lib\gate-verdict.ps1 requires at push time.
  Write-Output ("   clean working tree at start (content key == HEAD tree): hook {0} of {1}, hand {2} of {3}" -f `
    @($keyed | Where-Object { $_.origin -eq 'hook' -and $_.keyStart -eq $_.headTree }).Count, @($keyed | Where-Object { $_.origin -eq 'hook' }).Count, `
    @($keyed | Where-Object { $_.origin -eq 'manual' -and $_.keyStart -eq $_.headTree }).Count, @($keyed | Where-Object { $_.origin -eq 'manual' }).Count)
  $endedEval = @($all | Where-Object { $_.outcome -eq 'evaluated' -and $_.e })
  Write-Output ("CAPACITY: evaluated runs that ENDED inside the sampler: {0} over {1:N0} min -> {2:N1} per hour" -f $endedEval.Count, ($tEnd - $t0).TotalMinutes, ($endedEval.Count * 60.0 / ($tEnd - $t0).TotalMinutes))
  $lr = @($ticks | Measure-Object liveRuns -Average -Maximum); $lw = @($ticks | Measure-Object liveWithWorkers -Average -Maximum)
  Write-Output ("   live runs per tick: avg {0:N1}, max {1}; of them with gate workers: avg {2:N1}, max {3}" -f $lr[0].Average, $lr[0].Maximum, $lw[0].Average, $lw[0].Maximum)
  $csv = Join-Path $OutDir 'runs.csv'
  $all | Select-Object pid, origin, top, start, end, outcome, workerTicks, maxWorkers, dirtyStart, keyStart, keyEnd, logState, logVerdict, claudePid, wrapperPushes |
    Export-Csv -NoTypeInformation -Path $csv
  Write-Output ("   one row per run: " + $csv)
  Write-Output ("OBSERVE-GATE-QUEUE-COMPLETE mode=report runs={0} window_starts={1}" -f $all.Count, $win.Count)
  exit 0
}

if ($Retro) {
  if (-not $Day) { $Day = (Get-Date).ToString('yyyy-MM-dd') }
  $d0 = [datetime]$Day; $d1 = $d0.AddDays(1)
  $rows = [Collections.Generic.List[object]]::new()
  foreach ($l in @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'tc-prepush-*.log' -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '^tc-prepush-\d+\.log$' -and $_.CreationTime -ge $d0 -and $_.CreationTime -lt $d1 })) {
    $txt = [string](Read-TcShared $l.FullName)
    $cls = if ($txt -match 'COULD NOT EVALUATE - waited') { 'exit3-slot-wait' }
      elseif ($txt -match 'run-gates: COULD NOT EVALUATE') { 'exit3-other' }
      elseif ($txt -match 'run-gates: FAILED') { 'exit1-failed' }
      elseif ($txt -match 'run-gates: PASSED') { 'passed-log-kept' }
      elseif (((Get-Date) - $l.LastWriteTime).TotalMinutes -lt 25) { 'in-progress' }
      else { 'no-verdict-died' }
    $work = $null; if ($txt -match '([\d,]+)s of gate work') { $work = [int]($Matches[1] -replace ',', '') }
    $rows.Add([pscustomobject]@{ name = $l.Name; created = $l.CreationTime; hour = $l.CreationTime.Hour; lifeS = [int]($l.LastWriteTime - $l.CreationTime).TotalSeconds; cls = $cls; workS = $work })
  }
  Write-Output ("HOOK LOGS kept for {0}: {1}. The hook DELETES its log on a pass, so this is every non-pass plus what was live." -f $Day, $rows.Count)
  $rows | Group-Object cls | Sort-Object Name | ForEach-Object { Write-Output ("   {0,-18} {1}" -f $_.Name, $_.Count) }
  # PER HOUR, NEVER ONE MEAN FOR THE DAY. The budget changed at 11:42 and the gate set grows through the day, so a
  # single mean mixes runs that cost 660s with runs that cost 1,000s and answers no question anybody asked.
  $work = @($rows | Where-Object { $null -ne $_.workS })
  if ($work.Count) {
    Write-Output ("   gate work per run, over the {0} of {1} log(s) that carry a timing line - 10 slots is 36,000 slot-seconds an hour, so the ceiling is that divided by this:" -f $work.Count, $rows.Count)
    foreach ($g in ($work | Group-Object hour | Sort-Object { [int]$_.Name })) {
      $m = $g.Group | Measure-Object workS -Average -Minimum -Maximum
      Write-Output ("     {0:00}h  n={1,2}  mean {2,6:N0}s (min {3}, max {4})  -> about {5:N0} runs an hour" -f [int]$g.Name, $m.Count, $m.Average, $m.Minimum, $m.Maximum, (36000 / [Math]::Max(1, $m.Average)))
    }
  }
  # EVERY CHECKOUT ON THE BOX, ASKED OF GIT. A linked worktree's own directory is not under the checkout this script
  # runs from - `.claude\worktrees` sits under the MAIN checkout - so looking there from a worktree finds nothing and
  # reports a confident zero. This is the same shape lib\tree-walk.ps1 exists for.
  $files = @()
  $wtList = @()
  $prevEap = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $wtList = @(& git -C $repoRoot worktree list --porcelain 2>$null)
  } finally { $ErrorActionPreference = $prevEap }
  foreach ($ln in $wtList) {
    if ([string]$ln -match '^worktree\s+(.+)$') {
      $p = Join-Path ($Matches[1].Trim() -replace '/', '\') 'ops\out\gate-readings.jsonl'
      if ((Test-Path $p) -and ($files -notcontains $p)) { $files += $p }
    }
  }
  $u0 = [DateTimeOffset]::new($d0).ToUnixTimeSeconds(); $u1 = [DateTimeOffset]::new($d1).ToUnixTimeSeconds()
  $byT = @{}
  foreach ($f in $files) {
    foreach ($ln in [IO.File]::ReadAllLines($f)) {
      if ($ln -match '"t":(\d+)') { $t = [long]$Matches[1]; if ($t -ge $u0 -and $t -lt $u1) { $byT[[string]$t + '|' + $f] = $t } }
    }
  }
  $stamps = @{}
  foreach ($v in $byT.Values) { $stamps[$v] = $true }
  Write-Output ("EVALUATED RUNS from ops\out\gate-readings.jsonl across {0} surviving checkout(s): {1} on {2} (a floor - a removed worktree takes its file with it)" -f $files.Count, $stamps.Count, $Day)
  $perHour = @{}
  foreach ($t in $stamps.Keys) { $h = [DateTimeOffset]::FromUnixTimeSeconds($t).LocalDateTime.Hour; $perHour[$h] = 1 + [int]$perHour[$h] }
  foreach ($h in ($perHour.Keys | Sort-Object)) { Write-Output ("   {0:00}h  {1}" -f $h, $perHour[$h]) }
  Write-Output ("OBSERVE-GATE-QUEUE-COMPLETE mode=retro logs={0} evaluated={1}" -f $rows.Count, $stamps.Count)
  exit 0
}

Write-Output 'observe-gate-queue: pick a mode - -Watch (sample live runs), -Report (totals from a watch), -Retro (what today already wrote down).'
Write-Output 'OBSERVE-GATE-QUEUE-COMPLETE mode=none'
exit 3
