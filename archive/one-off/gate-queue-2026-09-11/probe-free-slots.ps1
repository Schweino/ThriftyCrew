# probe-free-slots.ps1 - how many of the 10 machine-wide gate slots are FREE at an instant, while runs wait.
# It takes each free slot for microseconds and releases it in the same pass, so a waiter that misses one
# gets it on its next 500 ms poll. It starts nothing and holds nothing between samples.
# Reports, per sample: free slots, live real run-gates hosts, and gate workers running under them.
param([int]$Samples = 20, [int]$EverySec = 3, [string]$Out)
$prefix = 'Global\tc-gate-worker-slot-'
$rootRx = '-File\s+["'']?[^\s"'']*run-gates\.ps1'
for ($s = 0; $s -lt $Samples; $s++) {
  $held = [Collections.Generic.List[object]]::new()
  for ($i = 0; $i -lt 10; $i++) {
    $mx = New-Object System.Threading.Mutex($false, ($prefix + $i))
    $got = $false
    try { $got = $mx.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    if ($got) { $held.Add($mx) } else { $mx.Dispose() }
  }
  $free = $held.Count
  foreach ($m in $held) { try { $m.ReleaseMutex() } catch { }; try { $m.Dispose() } catch { } }
  $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CreationDate, CommandLine)
  $roots = @($all | Where-Object { $_.Name -match '^powershell' -and [string]$_.CommandLine -match $rootRx -and [string]$_.CommandLine -notmatch '-ListOnly|tc-prepush-selftest' })
  $rootIds = @{}; foreach ($r in $roots) { $rootIds[[int]$r.ProcessId] = $true }
  $real = @(); $w = 0
  foreach ($r in $roots) {
    $ch = @($all | Where-Object { [int]$_.ParentProcessId -eq [int]$r.ProcessId -and $_.CreationDate -ge $r.CreationDate -and $_.Name -ne 'conhost.exe' })
    if (@($ch | Where-Object { $rootIds.ContainsKey([int]$_.ProcessId) }).Count) { continue }
    $real += $r; $w += $ch.Count
  }
  $line = '{0} free={1} liveRuns={2} workers={3}' -f (Get-Date -Format 'HH:mm:ss'), $free, $real.Count, $w
  if ($Out) { [IO.File]::AppendAllText($Out, $line + "`n") } else { Write-Output $line }
  Start-Sleep -Seconds $EverySec
}
