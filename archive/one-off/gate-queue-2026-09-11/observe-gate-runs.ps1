# observe-gate-runs.ps1 v2 - PASSIVE observer of live run-gates processes. Starts nothing, takes no mutex.
# A RUN is the process that HOSTS the script: a command line with `-File <...>run-gates.ps1` (v1 counted any
# process naming the file, which caught Claude tool wrappers that only launch it, and one that merely listed
# the path among files to stage). -ListOnly excluded. Its direct children are its pool's workers. Ancestry is
# recorded once; the parent is re-checked every poll so an ORPHANED run (its hook shell or tool shell gone,
# so nobody will read its verdict) is recorded when it happens. Exit code through a handle opened while live.
param([int]$DurationMin = 60, [int]$PollSec = 4, [string]$Out)
$ErrorActionPreference = 'Continue'
function Emit($o) { [IO.File]::AppendAllText($Out, (($o | ConvertTo-Json -Compress -Depth 5) + "`n")) }
$rootRx = '-File\s+["'']?[^\s"'']*run-gates\.ps1'
$runs = @{}
$seenChild = @{}
$end = (Get-Date).AddMinutes($DurationMin)
Emit @{ ev = 'start'; t = (Get-Date).ToString('o'); pollSec = $PollSec; rootRule = $rootRx }
while ((Get-Date) -lt $end) {
  $t = (Get-Date).ToString('o')
  $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CreationDate, CommandLine)
  $byId = @{}; foreach ($p in $all) { $byId[[int]$p.ProcessId] = $p }
  $live = @{}
  foreach ($p in $all) {
    $cl = [string]$p.CommandLine
    if ($p.Name -notmatch '^(powershell|pwsh)\.exe$') { continue }
    if ($cl -notmatch $rootRx -or $cl -match '-ListOnly') { continue }
    $key = '{0}|{1}' -f $p.ProcessId, $p.CreationDate.Ticks
    $live[$key] = $true
    $par = $byId[[int]$p.ParentProcessId]
    $parentAlive = ($null -ne $par) -and ($par.CreationDate -le $p.CreationDate)
    if (-not $runs.ContainsKey($key)) {
      $chain = @(); $cur = $par; $prevCreated = $p.CreationDate
      for ($k = 0; $k -lt 10; $k++) {
        if (-not $cur -or $cur.CreationDate -gt $prevCreated) { $chain += @{ name = '(gone)' }; break }
        $acl = [string]$cur.CommandLine; if ($acl.Length -gt 500) { $acl = $acl.Substring(0, 500) }
        $chain += @{ pid = [int]$cur.ProcessId; name = $cur.Name; created = $cur.CreationDate.ToString('o'); cmd = $acl }
        if ($cur.Name -eq 'explorer.exe') { break }
        $prevCreated = $cur.CreationDate
        $cur = $byId[[int]$cur.ParentProcessId]
      }
      $h = $null
      try { $h = Get-Process -Id $p.ProcessId -ErrorAction Stop; $null = $h.Handle } catch { $h = $null }
      $runs[$key] = @{ Proc = $h; Pid = [int]$p.ProcessId; Orphan = (-not $parentAlive); MaxW = 0; FirstW = $null }
      Emit @{ ev = 'new'; t = $t; key = $key; pid = [int]$p.ProcessId; created = $p.CreationDate.ToString('o'); cmd = $cl; chain = $chain; orphanAtFirstSight = (-not $parentAlive); handle = ($null -ne $h) }
    } elseif (-not $parentAlive -and -not $runs[$key].Orphan) {
      $runs[$key].Orphan = $true
      Emit @{ ev = 'orphaned'; t = $t; key = $key }
    }
  }
  $pidToKey = @{}; foreach ($key in $live.Keys) { $pidToKey[$runs[$key].Pid] = $key }
  $width = @{}
  foreach ($c in $all) {
    $pp = [int]$c.ParentProcessId
    if (-not $pidToKey.ContainsKey($pp)) { continue }
    $key = $pidToKey[$pp]
    $rp = $byId[$pp]
    if ($c.CreationDate -lt $rp.CreationDate) { continue }
    if ($c.Name -eq 'conhost.exe') { continue }
    if (-not $width.ContainsKey($key)) { $width[$key] = 0 }
    $width[$key]++
    $ck = '{0}|{1}' -f $c.ProcessId, $c.CreationDate.Ticks
    if (-not $seenChild.ContainsKey($ck)) {
      $seenChild[$ck] = $true
      $ccl = [string]$c.CommandLine; if ($ccl.Length -gt 200) { $ccl = $ccl.Substring($ccl.Length - 200) }
      Emit @{ ev = 'child'; t = $t; key = $key; cpid = [int]$c.ProcessId; created = $c.CreationDate.ToString('o'); name = $c.Name; cmd = $ccl }
    }
  }
  Emit @{ ev = 'poll'; t = $t; live = $live.Count; workers = (($width.Values | Measure-Object -Sum).Sum); w = $width }
  foreach ($key in @($runs.Keys)) {
    if ($live.ContainsKey($key)) { continue }
    $r = $runs[$key]; $code = $null
    if ($r.Proc) { try { $null = $r.Proc.WaitForExit(2000); $code = $r.Proc.ExitCode } catch { } }
    Emit @{ ev = 'exit'; t = $t; key = $key; exit = $code; orphan = $r.Orphan }
    $runs.Remove($key)
  }
  Start-Sleep -Seconds $PollSec
}
Emit @{ ev = 'end'; t = (Get-Date).ToString('o'); stillLive = @($runs.Keys) }
