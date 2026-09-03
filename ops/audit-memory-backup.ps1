<#
  audit-memory-backup.ps1 - the agent memory store is DATA THIS ESTATE REASONS FROM. Version it, prove the
  history is current, and prove it never reaches the public repo.

  WHY (2026-09-03). Two things happened on the same day.

  FIRST, a memory file was destroyed by an ordinary edit. Repairing three mojibake characters, a string
  replacement went through the shell mis-encoded and performed a GLOBAL single-character substitution
  instead: every 'r' became a different character in budget-tracker.md, and every 'M' became 'e' in
  grocery-browser-exfil.md. 2,035 characters damaged by a 3-character repair. Both writes reported success,
  neither changed the file SIZE, and nothing versioned the directory - so recovery meant reconstructing the
  content out of session transcripts and proving the restore by replaying the damage onto it. With a history
  that is a checkout.

  SECOND, the obvious fix was nearly the wrong one. ops\prompt-backup mirrors the agent prompts INTO this
  repo, so mirroring memory the same way looks like the answer. It is not: this repo is PUBLIC (verified by
  an unauthenticated GitHub API call returning private=False), and the memory store carries the business's
  cost and revenue notes, account identifiers and contact addresses. So memory gets its OWN git history,
  local, with NO REMOTE, and this guard exists as much to keep it out of the public repo as to keep it
  backed up. Those are the same job: "memory and git must not drift" cuts both ways.

  Six checks:
    1. HISTORY EXISTS   - the memory directory is a git repository at all
    2. NO REMOTE        - it has no push target, so it cannot leak to a public host
    3. NOT IN THIS REPO - no memory file is tracked by ThriftyCrew
    4. HISTORY CURRENT  - no uncommitted memory changes (-Sync commits them)
    5. INDEX INTEGRITY  - MEMORY.md and the files on disk agree: no orphan links, no unindexed
                          files, no duplicate links
    6. ENCODING INTACT  - no mojibake, the founding damage of this guard
  Exit 0 clean, 2 a real finding, 3 BLIND (nothing to check - a pass that proves nothing).
  -Sync commits pending memory changes, then re-checks. -SelfTest runs frozen fixtures.
#>
param([switch]$Sync, [switch]$SelfTest, [string]$MemoryDir = '')
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$REPO = 'C:\Codex\ThriftyCrew'
if (-not $MemoryDir) { $MemoryDir = 'C:\Users\Owner\.claude\projects\C--Codex\memory' }

# Mojibake is UTF-8 bytes decoded as Windows-1252. Built from CODEPOINTS, never typed: a literal non-ASCII
# needle is re-encoded on its way through the shell, which is the exact mechanism that caused the damage
# this guard was written about.
$MOJI = @(
  ([string][char]0x00E2 + [char]0x20AC + [char]0x2122),   # mangled right single quote
  ([string][char]0x00E2 + [char]0x20AC + [char]0x201C),   # mangled left double quote
  ([string][char]0x00C3 + [char]0x00A9),                  # mangled e-acute
  ([string][char]0x00C3 + [char]0x00B1)                   # mangled n-tilde
)

function Get-GitOut([string]$Dir, [string]$GitArgs) {
  # Read the process stream, never `| Out-String`: PowerShell rejoins native output with CRLF, which on
  # 2026-09-03 added 393 bytes to a 28,965-byte file and silently disabled a comparison in another guard.
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'git'
  $psi.Arguments = ('-C "' + $Dir + '" ' + $GitArgs)
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
  $p = [System.Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEnd(); $null = $p.StandardError.ReadToEnd(); $p.WaitForExit()
  return [pscustomobject]@{ Text = $out; Code = $p.ExitCode }
}

function Test-MemoryStore {
  param([string]$Dir)
  $issues = New-Object System.Collections.Generic.List[string]
  $checked = 0

  if (-not (Test-Path $Dir)) { return @{ rc = 3; issues = @("the memory directory does not exist: $Dir"); checked = 0 } }
  $files = @(Get-ChildItem $Dir -Filter '*.md' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'MEMORY.md' })
  $indexPath = Join-Path $Dir 'MEMORY.md'
  if (-not (Test-Path $indexPath)) { return @{ rc = 3; issues = @('no MEMORY.md - there is no index to check the store against'); checked = 0 } }
  if ($files.Count -eq 0) { return @{ rc = 3; issues = @('zero memory files - a clean result here would prove nothing'); checked = 0 } }

  # 1. HISTORY EXISTS
  $checked++
  if (-not (Test-Path (Join-Path $Dir '.git'))) {
    $issues.Add('the memory store is NOT a git repository - one bad write is unrecoverable, which is the failure this guard exists for')
    return @{ rc = 2; issues = $issues; checked = $checked }
  }

  # 2. NO REMOTE. A remote is how this ends up somewhere public.
  $checked++
  $rem = Get-GitOut $Dir 'remote -v'
  if (($rem.Text).Trim()) {
    $issues.Add('the memory store has a git REMOTE configured, so it can be pushed off this machine: ' + (($rem.Text).Trim() -replace "\r?\n", ' / ') + ' - memory carries cost, revenue and account notes and must stay local')
  }

  # 3. NOT TRACKED BY THE PUBLIC REPO
  $checked++
  if (Test-Path (Join-Path $REPO '.git')) {
    $tracked = Get-GitOut $REPO 'ls-files'
    $leak = @(($tracked.Text -split "`r?`n") | Where-Object { $_ -match 'projects/C--Codex/memory/' })
    if ($leak.Count) { $issues.Add(("$($leak.Count) memory file(s) are TRACKED BY THE PUBLIC ThriftyCrew REPO, e.g. " + ($leak[0]))) }
  }

  # 4. HISTORY CURRENT
  $checked++
  $st = Get-GitOut $Dir 'status --porcelain'
  $dirty = @(($st.Text -split "`r?`n") | Where-Object { $_.Trim() })
  if ($dirty.Count) {
    $issues.Add("$($dirty.Count) memory file(s) are uncommitted, so the history does not hold what the store currently says - run with -Sync")
  }

  # 5. INDEX INTEGRITY
  $checked++
  $idx = [IO.File]::ReadAllText($indexPath, [Text.Encoding]::UTF8) -split "`r?`n"
  $linked = @()
  foreach ($l in $idx) { $m = [regex]::Match($l, '\]\(([^)]+\.md)\)'); if ($m.Success) { $linked += $m.Groups[1].Value } }
  $names = @($files | ForEach-Object { $_.Name })
  $orphans   = @($linked | Where-Object { $names -notcontains $_ })
  $unindexed = @($names  | Where-Object { $linked -notcontains $_ })
  $dupes     = @($linked | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
  if ($orphans.Count)   { $issues.Add("MEMORY.md links $($orphans.Count) file(s) that do not exist: " + (($orphans | Select-Object -First 5) -join ', ')) }
  if ($unindexed.Count) { $issues.Add("$($unindexed.Count) memory file(s) are in no index line, so recall will never surface them: " + (($unindexed | Select-Object -First 5) -join ', ')) }
  if ($dupes.Count)     { $issues.Add("MEMORY.md links the same file more than once: " + (($dupes | Select-Object -First 5) -join ', ')) }

  # 6. ENCODING INTACT - the founding damage
  $checked++
  $bad = New-Object System.Collections.Generic.List[string]
  foreach ($f in @($files + @(Get-Item $indexPath))) {
    $t = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
    foreach ($seq in $MOJI) { if ($t.Contains($seq)) { $bad.Add($f.Name); break } }
  }
  if ($bad.Count) { $issues.Add("$($bad.Count) memory file(s) carry mojibake (UTF-8 read as ANSI): " + (($bad | Select-Object -First 5) -join ', ')) }

  return @{ rc = $(if ($issues.Count) { 2 } else { 0 }); issues = $issues; checked = $checked; files = $files.Count }
}

# ------------------------------------------------------------------ self-test
if ($SelfTest) {
  $fail = 0
  function T([string]$label, [bool]$cond, [string]$detail) {
    if ($cond) { Write-Output "ok    $label" } else { Write-Output "FAIL  $label  - $detail"; $script:fail++ } }

  $fx = Join-Path $env:TEMP ('memaudit-selftest-' + $PID)
  function NewStore {
    if (Test-Path $fx) { Remove-Item $fx -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $fx | Out-Null
    Set-Content (Join-Path $fx 'alpha.md') "---`nname: alpha`n---`nbody" -Encoding UTF8
    Set-Content (Join-Path $fx 'beta.md')  "---`nname: beta`n---`nbody" -Encoding UTF8
    Set-Content (Join-Path $fx 'MEMORY.md') "- [Alpha](alpha.md) - a`n- [Beta](beta.md) - b" -Encoding UTF8
    $null = Get-GitOut $fx 'init'
    $null = Get-GitOut $fx 'config user.name t'
    $null = Get-GitOut $fx 'config user.email t@t'
    $null = Get-GitOut $fx 'add -A'
    $null = Get-GitOut $fx 'commit -m base'
  }

  # CLEAN TWIN: a healthy store passes. Without this the must-fires prove only that it says no to everything.
  NewStore
  $r = Test-MemoryStore $fx
  T 'CLEAN TWIN a committed, fully indexed, well-encoded store passes' ($r.rc -eq 0) ("rc=$($r.rc) " + ($r.issues -join '; '))

  # MUST-FIRE 1: no history at all - the founding condition, an unrecoverable store
  NewStore; Remove-Item (Join-Path $fx '.git') -Recurse -Force
  $r = Test-MemoryStore $fx
  T 'MUST-FIRE a store with no git history is reported' (($r.rc -eq 2) -and (($r.issues -join ' ') -match 'NOT a git repository')) ("rc=$($r.rc)")

  # MUST-FIRE 2: a REMOTE - the leak path this guard exists to block
  NewStore; $null = Get-GitOut $fx 'remote add origin https://github.com/someone/public.git'
  $r = Test-MemoryStore $fx
  T 'MUST-FIRE a configured remote is reported as a leak path' (($r.rc -eq 2) -and (($r.issues -join ' ') -match 'REMOTE')) ("rc=$($r.rc)")

  # MUST-FIRE 3: uncommitted change - the history no longer holds what the store says
  NewStore; Add-Content (Join-Path $fx 'alpha.md') 'edited after the commit'
  $r = Test-MemoryStore $fx
  T 'MUST-FIRE an uncommitted memory edit is reported' (($r.rc -eq 2) -and (($r.issues -join ' ') -match 'uncommitted')) ("rc=$($r.rc)")

  # MUST-FIRE 4: an unindexed file - present on disk, invisible to recall
  NewStore; Set-Content (Join-Path $fx 'gamma.md') 'x' -Encoding UTF8; $null = Get-GitOut $fx 'add -A'; $null = Get-GitOut $fx 'commit -m g'
  $r = Test-MemoryStore $fx
  T 'MUST-FIRE a file in no index line is reported' (($r.rc -eq 2) -and (($r.issues -join ' ') -match 'no index line')) ("rc=$($r.rc)")

  # MUST-FIRE 5: an orphan index line - a link to a file that is gone
  NewStore; Remove-Item (Join-Path $fx 'beta.md'); $null = Get-GitOut $fx 'add -A'; $null = Get-GitOut $fx 'commit -m rm'
  $r = Test-MemoryStore $fx
  T 'MUST-FIRE an index line pointing at a missing file is reported' (($r.rc -eq 2) -and (($r.issues -join ' ') -match 'do not exist')) ("rc=$($r.rc)")

  # MUST-FIRE 6: MOJIBAKE - the damage that caused this guard to be written
  NewStore
  $moji = 'Member' + [string][char]0x00E2 + [char]0x20AC + [char]0x2122 + 's Mark'
  [IO.File]::WriteAllText((Join-Path $fx 'alpha.md'), $moji, (New-Object System.Text.UTF8Encoding($false)))
  $null = Get-GitOut $fx 'add -A'; $null = Get-GitOut $fx 'commit -m moji'
  $r = Test-MemoryStore $fx
  T 'MUST-FIRE mojibake in a memory file is reported' (($r.rc -eq 2) -and (($r.issues -join ' ') -match 'mojibake')) ("rc=$($r.rc)")

  # BLIND: an empty store must never read as clean
  if (Test-Path $fx) { Remove-Item $fx -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $fx | Out-Null
  Set-Content (Join-Path $fx 'MEMORY.md') '' -Encoding UTF8
  $r = Test-MemoryStore $fx
  T 'BLIND a store with zero memory files reports rc 3, never a clean pass' ($r.rc -eq 3) ("rc=$($r.rc)")

  if (Test-Path $fx) { Remove-Item $fx -Recurse -Force -ErrorAction SilentlyContinue }
  if ($fail -gt 0) { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
  Write-Output 'SELF-TEST PASS (8 memory-store cases)'
  exit 0
}

# ------------------------------------------------------------------ live
if ($Sync) {
  if (Test-Path (Join-Path $MemoryDir '.git')) {
    $st = Get-GitOut $MemoryDir 'status --porcelain'
    if ((($st.Text) -split "`r?`n" | Where-Object { $_.Trim() }).Count) {
      $null = Get-GitOut $MemoryDir 'add -A'
      $msg = 'Memory sync ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')
      $c = Get-GitOut $MemoryDir ('commit -m "' + $msg + '"')
      Write-Output ('memory-backup: committed pending memory changes (' + $msg + ')')
    } else { Write-Output 'memory-backup: nothing to commit' }
  } else { Write-Output 'memory-backup: -Sync cannot commit - the store is not a git repository yet' }
}

$res = Test-MemoryStore $MemoryDir
Write-Output ("memory-backup: {0} memory file(s), {1} check(s) run against {2}" -f [int]$res.files, [int]$res.checked, $MemoryDir)
if ($res.rc -eq 3) {
  foreach ($i in $res.issues) { Write-Output ('  BLIND  ' + $i) }
  Write-GuardComplete -Name 'memory-backup' -Summary 'blind'
  exit 3
}
if ($res.issues.Count -eq 0) {
  Write-Output '  ok - the memory store is versioned locally, has no remote, is absent from the public repo, is fully committed, its index agrees with the files on disk, and nothing is mojibaked'
  Write-GuardComplete -Name 'memory-backup' -Summary ("files={0} clean" -f [int]$res.files)
  exit 0
}
foreach ($i in $res.issues) { Write-Output ('  ' + $i) }
Write-Output '  Fix: run this with -Sync to commit pending memory changes. A remote, or a memory file tracked by ThriftyCrew, must be removed by hand - that repo is PUBLIC.'
Write-GuardComplete -Name 'memory-backup' -Summary ("files={0} issues={1}" -f [int]$res.files, $res.issues.Count)
exit 2
