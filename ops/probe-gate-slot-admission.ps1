<#
  probe-gate-slot-admission.ps1 - READ-ONLY observer of who owns each machine-wide gate worker slot
  (lib\gate-slots.ps1), and of what every run-gates on the box is doing while it waits for one.

  Usage:  powershell -File ops\probe-gate-slot-admission.ps1 -Minutes 45 -OutFile <events.jsonl>
          powershell -File ops\probe-gate-slot-admission.ps1 -Once        (one sample to stdout)
  Read it with: ops\report-gate-slot-admission.ps1 -Events <events.jsonl>

  WHY (2026-09-11). Four run-gates runs from one session each waited about 1,205 s for a slot and exited 3
  with nothing run, while 28 runs queued and 9 held slots. Whether a freed slot went to a run already
  holding slots or to one holding none could not be read from any log: the slots are named mutexes, and
  nothing writes down who takes them. design\MEASURE-gate-slot-admission-2026-09-11.md is the measurement
  this was built for, with its acceptance bar written before the run.

  HOW, AND WHY IT IS READ-ONLY. It never calls WaitOne on a slot, so it can never take one or change who
  gets it. Once a second it reads the system handle table (NtQuerySystemInformation, extended handle
  information), duplicates only the MUTANT handles held by run-gates and cpu-load processes, reads each
  one's name and NtQueryMutant state, and so knows which process owns each Global\tc-gate-worker-slot-N.
  A holder keeps its handle for the whole lease while a waiter's probe handle lives microseconds, so a
  persistent handle on an owned mutex is ownership. Every 30th sample reads every powershell.exe instead,
  to catch an owner that is not a gate run.

  ONE ROW PER EVENT, never a summary: run_seen, wait_start, acquire (ADMIT or GROW, with the line of
  waiters at that instant), release, run_exit (with the process's real exit code), stuck_holder,
  foreign_holder, initial_owner, and a tick every 10 s. Every total in the measurement is derived from
  that file, so a later reader can re-derive them differently.

  SCOPE OF A CLEAN REPORT: it does not report, it records. Two limits belong with any number taken from
  it. Ownership is sampled at 1 Hz, so a slot released and retaken inside one second is seen only as its
  end state - production slots turn over in minutes, but a fixture's would not. And "waiting" is inferred:
  a run holding no slot whose CPU has gone flat for 10 s after discovery. Runs already alive when the
  probe starts are marked censored, and their waits are lower bounds.

  BY HAND, during a busy period. Nothing schedules it, and ops\report-gate-slot-admission.ps1 is its pair.
#>
param(
  [double]$Minutes = 45,
  [int]$SampleMs = 1000,
  [string]$OutFile = '',
  [switch]$Once
)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class TcProcRow { public int Pid; public int Ppid; public string Name; public long Create; public long Cpu; }
public class TcSlotRow { public int Pid; public int Slot; public int Count; public long Handle; }

public static class TcSlotProbe {
  [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int ret);
  [DllImport("ntdll.dll")] static extern int NtQueryObject(IntPtr h, int cls, IntPtr buf, int len, out int ret);
  [DllImport("ntdll.dll")] static extern int NtQueryMutant(IntPtr h, int cls, IntPtr buf, int len, out int ret);
  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, IntPtr buf, int len, out int ret);
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool DuplicateHandle(IntPtr sp, IntPtr sh, IntPtr dp, out IntPtr dh, int access, bool inherit, int options);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr h, out int code);
  [DllImport("kernel32.dll")] static extern int GetCurrentProcessId();

  const int MISMATCH = unchecked((int)0xC0000004);
  static IntPtr hbuf = IntPtr.Zero; static int hlen = 0;
  static int mutantType = -1;
  static Dictionary<int, IntPtr> dupProcs = new Dictionary<int, IntPtr>();
  static Dictionary<int, IntPtr> tracked = new Dictionary<int, IntPtr>();
  public static int LastScanned = 0;

  public static List<TcProcRow> Processes() {
    int len = 1 << 21;
    while (true) {
      IntPtr buf = Marshal.AllocHGlobal(len);
      try {
        int ret; int st = NtQuerySystemInformation(5, buf, len, out ret);
        if (st == MISMATCH) { len = Math.Max(len * 2, ret + 65536); continue; }
        if (st != 0) throw new Exception("NtQuerySystemInformation(5) 0x" + st.ToString("X8"));
        var list = new List<TcProcRow>();
        long off = 0;
        while (true) {
          IntPtr p = new IntPtr(buf.ToInt64() + off);
          int next = Marshal.ReadInt32(p, 0);
          var r = new TcProcRow();
          r.Create = Marshal.ReadInt64(p, 0x20);
          r.Cpu = Marshal.ReadInt64(p, 0x28) + Marshal.ReadInt64(p, 0x30);
          int nlen = (ushort)Marshal.ReadInt16(p, 0x38);
          IntPtr nb = Marshal.ReadIntPtr(p, 0x40);
          r.Name = nb == IntPtr.Zero ? "" : Marshal.PtrToStringUni(nb, nlen / 2);
          r.Pid = (int)Marshal.ReadIntPtr(p, 0x50).ToInt64();
          r.Ppid = (int)Marshal.ReadIntPtr(p, 0x58).ToInt64();
          list.Add(r);
          if (next == 0) break;
          off += next;
        }
        return list;
      } finally { Marshal.FreeHGlobal(buf); }
    }
  }

  public static string CommandLine(int pid) {
    IntPtr h = OpenProcess(0x1000, false, pid);
    if (h == IntPtr.Zero) return null;
    IntPtr buf = Marshal.AllocHGlobal(65536);
    try {
      int ret; int st = NtQueryInformationProcess(h, 60, buf, 65536, out ret);
      if (st != 0) return null;
      int l = (ushort)Marshal.ReadInt16(buf, 0);
      IntPtr b = Marshal.ReadIntPtr(buf, 8);
      return b == IntPtr.Zero ? "" : Marshal.PtrToStringUni(b, l / 2);
    } finally { Marshal.FreeHGlobal(buf); CloseHandle(h); }
  }

  public static void Track(int pid) {
    if (tracked.ContainsKey(pid)) return;
    IntPtr h = OpenProcess(0x1000 | 0x100000, false, pid);
    if (h != IntPtr.Zero) tracked[pid] = h;
  }
  public static int ExitCode(int pid) {
    IntPtr h;
    if (!tracked.TryGetValue(pid, out h)) return -999;
    int code; if (!GetExitCodeProcess(h, out code)) code = -998;
    if (code != 259) { CloseHandle(h); tracked.Remove(pid); }
    return code;
  }

  static IntPtr HandleTable(out long count) {
    if (hbuf == IntPtr.Zero) { hlen = 32 << 20; hbuf = Marshal.AllocHGlobal(hlen); }
    while (true) {
      int ret; int st = NtQuerySystemInformation(64, hbuf, hlen, out ret);
      if (st == MISMATCH) { Marshal.FreeHGlobal(hbuf); hlen = Math.Max(hlen * 2, ret + (1 << 20)); hbuf = Marshal.AllocHGlobal(hlen); continue; }
      if (st != 0) throw new Exception("NtQuerySystemInformation(64) 0x" + st.ToString("X8"));
      count = Marshal.ReadIntPtr(hbuf, 0).ToInt64();
      return hbuf;
    }
  }

  static int MutantType() {
    if (mutantType >= 0) return mutantType;
    var m = new System.Threading.Mutex(false);
    long mine = m.SafeWaitHandle.DangerousGetHandle().ToInt64();
    int me = GetCurrentProcessId();
    long n; IntPtr t = HandleTable(out n);
    for (long i = 0; i < n; i++) {
      IntPtr e = new IntPtr(t.ToInt64() + 16 + i * 40);
      if (Marshal.ReadIntPtr(e, 8).ToInt64() == me && Marshal.ReadIntPtr(e, 16).ToInt64() == mine) {
        mutantType = (ushort)Marshal.ReadInt16(e, 30); break;
      }
    }
    GC.KeepAlive(m); m.Dispose();
    if (mutantType < 0) throw new Exception("could not find the Mutant object type index");
    return mutantType;
  }

  public static List<TcSlotRow> Slots(int[] pids, string prefix) {
    var want = new HashSet<int>(pids);
    int mt = MutantType();
    var rows = new List<TcSlotRow>();
    long n; IntPtr t = HandleTable(out n);
    IntPtr self = GetCurrentProcess();
    IntPtr nameBuf = Marshal.AllocHGlobal(4096);
    IntPtr mutBuf = Marshal.AllocHGlobal(16);
    int scanned = 0;
    try {
      for (long i = 0; i < n; i++) {
        IntPtr e = new IntPtr(t.ToInt64() + 16 + i * 40);
        int pid = (int)Marshal.ReadIntPtr(e, 8).ToInt64();
        if (!want.Contains(pid)) continue;
        if ((ushort)Marshal.ReadInt16(e, 30) != mt) continue;
        IntPtr sp;
        if (!dupProcs.TryGetValue(pid, out sp)) { sp = OpenProcess(0x40, false, pid); dupProcs[pid] = sp; }
        if (sp == IntPtr.Zero) continue;
        IntPtr hv = Marshal.ReadIntPtr(e, 16);
        IntPtr d;
        if (!DuplicateHandle(sp, hv, self, out d, 0, false, 2)) continue;
        scanned++;
        try {
          int ret;
          if (NtQueryObject(d, 1, nameBuf, 4096, out ret) != 0) continue;
          int l = (ushort)Marshal.ReadInt16(nameBuf, 0);
          IntPtr b = Marshal.ReadIntPtr(nameBuf, 8);
          if (b == IntPtr.Zero || l == 0) continue;
          string name = Marshal.PtrToStringUni(b, l / 2);
          if (!name.StartsWith(prefix, StringComparison.Ordinal)) continue;
          int slot;
          if (!int.TryParse(name.Substring(prefix.Length), out slot)) continue;
          int cnt = 999;
          if (NtQueryMutant(d, 0, mutBuf, 8, out ret) == 0) cnt = Marshal.ReadInt32(mutBuf, 0);
          rows.Add(new TcSlotRow { Pid = pid, Slot = slot, Count = cnt, Handle = hv.ToInt64() });
        } finally { CloseHandle(d); }
      }
    } finally { Marshal.FreeHGlobal(nameBuf); Marshal.FreeHGlobal(mutBuf); }
    LastScanned = scanned;
    return rows;
  }

  public static void ForgetDup(int pid) {
    IntPtr sp; if (dupProcs.TryGetValue(pid, out sp)) { if (sp != IntPtr.Zero) CloseHandle(sp); dupProcs.Remove(pid); }
  }
}
'@

$SlotPrefix = '\BaseNamedObjects\tc-gate-worker-slot-'
$Total = 10
$probeMd5 = (Get-FileHash -Algorithm MD5 -LiteralPath $PSCommandPath).Hash

function Get-RunKind([string]$cl) {
  if (-not $cl) { return $null }
  $m = [regex]::Match($cl, '(?i)(?:^|\s)-(file|f|command|c|encodedcommand|ec|e)\s+("[^"]*"|\S+)')
  if (-not $m.Success) { return $null }
  if ($m.Groups[1].Value -notmatch '^(?i)f(ile)?$') { return $null }
  $path = $m.Groups[2].Value.Trim('"')
  if ($path -match '(?i)[\\/]?run-gates\.ps1$') { return @{ kind = 'run-gates'; script = $path } }
  if ($path -match '(?i)[\\/]?cpu-load\.ps1$') { return @{ kind = 'cpu-load'; script = $path } }
  return $null
}

$runs = @{}                         # key pid -> run object (pid reuse guarded by create time)
$seen = [Collections.Generic.HashSet[string]]::new()
$owner = @{}                        # slot -> pid
$writer = $null
if ($OutFile) { $writer = New-Object IO.StreamWriter($OutFile, $true, (New-Object Text.UTF8Encoding($false))) }
function Emit($row) {
  $o = [ordered]@{ t = [DateTime]::UtcNow.ToString('o') }
  foreach ($k in $row.Keys) { $o[$k] = $row[$k] }
  $line = ConvertTo-Json -InputObject $o -Compress -Depth 4
  if ($writer) { $writer.WriteLine($line); $writer.Flush() } else { Write-Output $line }
}
function To-Utc([long]$ft) { [DateTime]::FromFileTimeUtc($ft) }
function Held-By($map, $pid_) { $c = 0; foreach ($k in $map.Keys) { if ($map[$k] -eq $pid_) { $c++ } }; $c }

$start = [DateTime]::UtcNow
$sample = 0
$lastTick = [DateTime]::MinValue
$lastStuck = [DateTime]::MinValue
Emit ([ordered]@{ ev = 'probe_start'; probe_md5 = $probeMd5; sample_ms = $SampleMs; minutes = $Minutes; host_pid = $PID })

while ($true) {
  $now = [DateTime]::UtcNow
  $procs = [TcSlotProbe]::Processes()
  $byPid = @{}
  foreach ($p in $procs) { $byPid[$p.Pid] = $p }

  # 1. discover gate runs
  foreach ($p in $procs) {
    if ($p.Name -ne 'powershell.exe') { continue }
    $key = '{0}:{1}' -f $p.Pid, $p.Create
    if (-not $seen.Add($key)) { continue }
    $k = Get-RunKind ([TcSlotProbe]::CommandLine($p.Pid))
    if (-not $k) { continue }
    [TcSlotProbe]::Track($p.Pid)
    $parent = if ($byPid.ContainsKey($p.Ppid)) { $byPid[$p.Ppid].Name } else { '' }
    $r = [pscustomobject]@{
      Pid = $p.Pid; Create = $p.Create; Kind = $k.kind; Script = $k.script; Parent = $parent
      Created = (To-Utc $p.Create); Censored = ($sample -eq 0); Hist = [Collections.Generic.List[object]]::new()
      WaitStart = $null; FirstSlot = $null; Peak = 0; Grows = 0; Admits = 0; LastRelease = $null
      TreeHist = [Collections.Generic.List[object]]::new(); SeenKids = [Collections.Generic.HashSet[int]]::new(); StuckSaid = $false
      HeldSince = $null; FirstSlotCensored = $false
    }
    $runs[$p.Pid] = $r
    Emit ([ordered]@{ ev = 'run_seen'; pid = $p.Pid; kind = $r.Kind; parent = $parent; script = $r.Script; created = $r.Created.ToString('o'); censored = $r.Censored; cpu_s = [math]::Round($p.Cpu / 1e7, 2) })
  }

  # 2. slot ownership
  $scanPids = @($runs.Values | ForEach-Object { $_.Pid })
  $fullScan = ($sample % 30 -eq 0)
  if ($fullScan) { $scanPids = @($procs | Where-Object { $_.Name -eq 'powershell.exe' } | ForEach-Object { $_.Pid }) }
  $rows = [TcSlotProbe]::Slots([int[]]$scanPids, $SlotPrefix)
  $newOwner = @{}
  for ($s = 0; $s -lt $Total; $s++) {
    $hs = @($rows | Where-Object { $_.Slot -eq $s })
    if (-not $hs.Count) { continue }
    if ($hs[0].Count -gt 0) { continue }              # object exists but nobody owns it
    $pids = @($hs | ForEach-Object { $_.Pid } | Select-Object -Unique)
    if ($owner.ContainsKey($s) -and ($pids -contains $owner[$s])) { $newOwner[$s] = $owner[$s] }
    elseif ($pids.Count -eq 1) { $newOwner[$s] = $pids[0] }
    else { if ($owner.ContainsKey($s)) { $newOwner[$s] = $owner[$s] }; Emit ([ordered]@{ ev = 'ambiguous'; slot = $s; pids = ($pids -join ',') }) }
  }
  if ($fullScan) {
    foreach ($s in @($newOwner.Keys)) {
      if (-not $runs.ContainsKey($newOwner[$s])) {
        $fp = $newOwner[$s]
        $fcmd = [TcSlotProbe]::CommandLine($fp)
        Emit ([ordered]@{ ev = 'foreign_holder'; slot = $s; pid = $fp; cmd = $fcmd })
        # Tracked from here on, so its lease is watched every sample like a gate run's.
        if ($byPid.ContainsKey($fp)) {
          [TcSlotProbe]::Track($fp)
          $fm = [regex]::Match([string]$fcmd, '(?i)-File\s+("[^"]*"|\S+)')
          $fscript = if ($fm.Success) { $fm.Groups[1].Value.Trim('"') } else { '' }
          $runs[$fp] = [pscustomobject]@{
            Pid = $fp; Create = $byPid[$fp].Create; Kind = ('other:' + [IO.Path]::GetFileName($fscript)); Script = $fscript
            Parent = $(if ($byPid.ContainsKey($byPid[$fp].Ppid)) { $byPid[$byPid[$fp].Ppid].Name } else { '' })
            Created = (To-Utc $byPid[$fp].Create); Censored = $true; Hist = [Collections.Generic.List[object]]::new()
            WaitStart = $null; FirstSlot = $now; Peak = 0; Grows = 0; Admits = 0; LastRelease = $null
            TreeHist = [Collections.Generic.List[object]]::new(); SeenKids = [Collections.Generic.HashSet[int]]::new(); StuckSaid = $false
            HeldSince = $now; FirstSlotCensored = $true
          }
        }
      }
    }
  }
  # on a non-full sample an untracked owner is invisible; keep it from the last full scan
  if (-not $fullScan) {
    foreach ($s in @($owner.Keys)) {
      if (-not $newOwner.ContainsKey($s) -and -not $runs.ContainsKey($owner[$s]) -and $byPid.ContainsKey($owner[$s])) { $newOwner[$s] = $owner[$s] }
    }
  }

  # 3. waiter state (before diffing, using the PREVIOUS ownership)
  foreach ($r in $runs.Values) {
    if (-not $byPid.ContainsKey($r.Pid)) { continue }
    $cpu = $byPid[$r.Pid].Cpu
    $r.Hist.Add([pscustomobject]@{ T = $now; Cpu = $cpu })
    while ($r.Hist.Count -gt 0 -and ($now - $r.Hist[0].T).TotalSeconds -gt 12) { $r.Hist.RemoveAt(0) }
    if ($r.Kind -eq 'run-gates' -and -not $r.WaitStart -and -not $r.FirstSlot -and (Held-By $owner $r.Pid) -eq 0) {
      $h0 = $r.Hist[0]
      if (($now - $h0.T).TotalSeconds -ge 10 -and $h0.Cpu -ge 2e7 -and ($cpu - $h0.Cpu) -lt 3e6) {
        $r.WaitStart = $h0.T
        Emit ([ordered]@{ ev = 'wait_start'; pid = $r.Pid; wait_start = $h0.T.ToString('o'); age_s = [math]::Round(($h0.T - $r.Created).TotalSeconds, 1); cpu_s = [math]::Round($h0.Cpu / 1e7, 2); censored = $r.Censored })
      }
    }
  }

  # 4. diff ownership -> events. The FIRST sample has no previous state, so it records the standing owners
  # and emits no acquire: calling those ADMITs would count slots taken before the probe existed.
  if ($sample -eq 0) {
    foreach ($s in @($newOwner.Keys)) {
      $o0 = $newOwner[$s]
      Emit ([ordered]@{ ev = 'initial_owner'; slot = $s; pid = $o0; kind = $(if ($runs.ContainsKey($o0)) { $runs[$o0].Kind } else { 'untracked' }) })
      if ($runs.ContainsKey($o0) -and -not $runs[$o0].FirstSlot) { $runs[$o0].FirstSlot = $now; $runs[$o0].FirstSlotCensored = $true }
    }
    $owner = $newOwner
  }
  $waiters =@($runs.Values | Where-Object { $_.Kind -eq 'run-gates' -and $_.WaitStart -and -not $_.FirstSlot -and $byPid.ContainsKey($_.Pid) -and (Held-By $owner $_.Pid) -eq 0 })
  for ($s = 0; $s -lt $Total; $s++) {
    $prev = if ($owner.ContainsKey($s)) { $owner[$s] } else { $null }
    $cur = if ($newOwner.ContainsKey($s)) { $newOwner[$s] } else { $null }
    if ($prev -eq $cur) { continue }
    if ($null -ne $prev) {
      $after = Held-By $newOwner $prev
      $gone = -not $byPid.ContainsKey($prev)
      Emit ([ordered]@{ ev = 'release'; slot = $s; pid = $prev; held_after = $after; process_gone = $gone })
      if ($runs.ContainsKey($prev) -and $after -eq 0) { $runs[$prev].LastRelease = $now }
    }
    if ($null -ne $cur) {
      $before = Held-By $owner $cur
      $cls = if ($before -eq 0) { 'ADMIT' } else { 'GROW' }
      $others = @($waiters | Where-Object { $_.Pid -ne $cur })
      $row = [ordered]@{ ev = 'acquire'; slot = $s; pid = $cur; class = $cls; held_before = $before; waiters_other = $others.Count }
      if ($others.Count) {
        $oldest = ($others | Sort-Object WaitStart | Select-Object -First 1)
        $row['oldest_other_wait_s'] = [math]::Round(($now - $oldest.WaitStart).TotalSeconds, 1)
        $row['oldest_other_pid'] = $oldest.Pid
        $row['oldest_other_censored'] = $oldest.Censored
      }
      if ($runs.ContainsKey($cur)) {
        $r = $runs[$cur]
        $row['kind'] = $r.Kind
        if ($cls -eq 'ADMIT') {
          $r.Admits++
          if ($r.WaitStart) {
            $row['own_wait_s'] = [math]::Round(($now - $r.WaitStart).TotalSeconds, 1)
            $row['rank_by_wait'] = 1 + @($others | Where-Object { $_.WaitStart -lt $r.WaitStart }).Count
            $row['rank_by_created'] = 1 + @($others | Where-Object { $_.Created -lt $r.Created }).Count
            $row['own_censored'] = $r.Censored
          } else { $row['own_wait_s'] = $null; $row['registered_waiter'] = $false }
          $row['age_s'] = [math]::Round(($now - $r.Created).TotalSeconds, 1)
          if (-not $r.FirstSlot) { $r.FirstSlot = $now; $r.HeldSince = $now }
        } else { $r.Grows++ }
      } else { $row['kind'] = 'untracked' }
      Emit $row
    }
  }
  $owner = $newOwner
  foreach ($r in $runs.Values) { $hb = Held-By $owner $r.Pid; if ($hb -gt $r.Peak) { $r.Peak = $hb } }

  # 5. exits
  foreach ($r in @($runs.Values)) {
    $alive = $byPid.ContainsKey($r.Pid) -and $byPid[$r.Pid].Create -eq $r.Create
    if ($alive) { continue }
    $code = [TcSlotProbe]::ExitCode($r.Pid)
    [TcSlotProbe]::ForgetDup($r.Pid)
    Emit ([ordered]@{
      ev = 'run_exit'; pid = $r.Pid; kind = $r.Kind; parent = $r.Parent; exit_code = $code; censored = $r.Censored
      created = $r.Created.ToString('o'); lifetime_s = [math]::Round(($now - $r.Created).TotalSeconds, 1)
      wait_start = $(if ($r.WaitStart) { $r.WaitStart.ToString('o') } else { $null })
      first_slot = $(if ($r.FirstSlot) { $r.FirstSlot.ToString('o') } else { $null })
      wait_s = $(if ($r.WaitStart -and $r.FirstSlot) { [math]::Round(($r.FirstSlot - $r.WaitStart).TotalSeconds, 1) } else { $null })
      wait_upper_s = $(if ($r.FirstSlot) { [math]::Round(($r.FirstSlot - $r.Created).TotalSeconds, 1) } else { $null })
      held_s = $(if ($r.FirstSlot -and $r.LastRelease) { [math]::Round(($r.LastRelease - $r.FirstSlot).TotalSeconds, 1) } else { $null })
      ever_held = [bool]$r.FirstSlot; peak = $r.Peak; grows = $r.Grows; admits = $r.Admits; script = $r.Script
    })
    $runs.Remove($r.Pid)
  }

  # 6. stuck holders, every 60 s: no new descendant and under 1 CPU-s gained by self + live descendants over 5 min
  if (($now - $lastStuck).TotalSeconds -ge 60) {
    $lastStuck = $now
    $kids = @{}
    foreach ($p in $procs) { if (-not $kids.ContainsKey($p.Ppid)) { $kids[$p.Ppid] = [Collections.Generic.List[object]]::new() }; $kids[$p.Ppid].Add($p) }
    foreach ($r in $runs.Values) {
      if ((Held-By $owner $r.Pid) -eq 0) { $r.TreeHist.Clear(); continue }
      $sum = 0L; $newKid = $false
      $stack = [Collections.Generic.Stack[int]]::new(); $stack.Push($r.Pid)
      while ($stack.Count) {
        $x = $stack.Pop()
        if ($byPid.ContainsKey($x)) { $sum += $byPid[$x].Cpu }
        if ($kids.ContainsKey($x)) { foreach ($c in $kids[$x]) { if ($c.Create -ge $byPid[$x].Create) { if ($r.SeenKids.Add($c.Pid)) { $newKid = $true }; $stack.Push($c.Pid) } } }
      }
      $r.TreeHist.Add([pscustomobject]@{ T = $now; Cpu = $sum; NewKid = $newKid })
      while ($r.TreeHist.Count -gt 6) { $r.TreeHist.RemoveAt(0) }
      if ($r.TreeHist.Count -ge 6 -and -not $r.StuckSaid) {
        $span = $r.TreeHist[$r.TreeHist.Count - 1].T - $r.TreeHist[0].T
        $gain = $r.TreeHist[$r.TreeHist.Count - 1].Cpu - $r.TreeHist[0].Cpu
        $anyNew = @($r.TreeHist | Select-Object -Skip 1 | Where-Object { $_.NewKid }).Count
        if ($span.TotalSeconds -ge 290 -and $gain -lt 1e7 -and $anyNew -eq 0) {
          $r.StuckSaid = $true
          Emit ([ordered]@{ ev = 'stuck_holder'; pid = $r.Pid; kind = $r.Kind; held = (Held-By $owner $r.Pid); tree_cpu_gain_s = [math]::Round($gain / 1e7, 2); span_s = [math]::Round($span.TotalSeconds) })
        }
      }
    }
  }

  # 7. tick
  if (($now - $lastTick).TotalSeconds -ge 10 -or $Once) {
    $lastTick = $now
    $rg = @($runs.Values | Where-Object { $_.Kind -eq 'run-gates' })
    $holders = @($runs.Values | Where-Object { (Held-By $owner $_.Pid) -gt 0 })
    $tick = [ordered]@{
      ev = 'tick'; sample = $sample; runs_alive = $rg.Count; cpuload_alive = @($runs.Values | Where-Object { $_.Kind -eq 'cpu-load' }).Count
      waiting = $waiters.Count; holders = $holders.Count; slots_owned = $owner.Count
      slots_owned_untracked = @($owner.Keys | Where-Object { -not $runs.ContainsKey($owner[$_]) }).Count
      holding = (($holders | ForEach-Object { '{0}x{1}' -f $_.Pid, (Held-By $owner $_.Pid) }) -join ' ')
      handles_scanned = [TcSlotProbe]::LastScanned; full_scan = $fullScan
    }
    Emit $tick
  }

  $sample++
  if ($Once) { break }
  if (($now - $start).TotalMinutes -ge $Minutes) { break }
  $elapsed = ([DateTime]::UtcNow - $now).TotalMilliseconds
  if ($elapsed -lt $SampleMs) { Start-Sleep -Milliseconds ([int]($SampleMs - $elapsed)) }
}

foreach ($r in $runs.Values) {
  Emit ([ordered]@{
    ev = 'run_open'; pid = $r.Pid; kind = $r.Kind; parent = $r.Parent; censored = $r.Censored; created = $r.Created.ToString('o')
    wait_start = $(if ($r.WaitStart) { $r.WaitStart.ToString('o') } else { $null })
    first_slot = $(if ($r.FirstSlot) { $r.FirstSlot.ToString('o') } else { $null })
    held_now = (Held-By $owner $r.Pid); peak = $r.Peak; grows = $r.Grows; admits = $r.Admits
  })
}
Emit ([ordered]@{ ev = 'probe_end'; samples = $sample })
if ($writer) { $writer.Close() }
