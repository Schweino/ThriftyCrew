# install-hooks.ps1 - put ops\hooks\* into .git\hooks, and prove afterwards that they are live.
#
# WHY AN INSTALLER AT ALL. .git\hooks is NOT tracked by git, so a hook committed to the repo does nothing
# until somebody copies it, and a fresh clone has none. That is the definition of a rule that silently
# disarms: the file is right there in the repo, reviewed and committed, and not running.
#
# WHY IT ALSO VERIFIES. Copying and then reporting success is the checkpoint-before-durable lie. This reads
# the installed file back and compares it to the source, so "installed" is a measured fact rather than the
# last thing the script did before printing OK.
#
#   ops\install-hooks.ps1              install and verify
#   ops\install-hooks.ps1 -Check       verify only, install nothing (what audit-hook-installed calls)
# Exit 0 = every hook installed and current. 1 = missing or stale. 3 = BLIND (no .git\hooks to install into).
param([switch]$Check)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$repo = Split-Path $PSScriptRoot -Parent
$src  = Join-Path $PSScriptRoot 'hooks'
$dstDir = Join-Path $repo '.git\hooks'

if (-not (Test-Path $src)) { Write-Output 'BLIND: ops\hooks does not exist - nothing to install'; exit 3 }
if (-not (Test-Path $dstDir)) {
  # A worktree has a .git FILE pointing at the real gitdir, not a directory. Resolve it rather than
  # reporting "installed" into a path that is not the one git reads.
  $gitPath = Join-Path $repo '.git'
  if (Test-Path $gitPath -PathType Leaf) {
    $line = (Get-Content $gitPath -Raw).Trim()
    if ($line -match '^gitdir:\s*(.+)$') { $dstDir = Join-Path ($Matches[1].Trim()) 'hooks' }
  }
}
if (-not (Test-Path $dstDir)) {
  if ($Check) { Write-Output ("BLIND: no hooks directory at " + $dstDir); exit 3 }
  New-Item -ItemType Directory -Force $dstDir | Out-Null
}

$bad = New-Object System.Collections.ArrayList
$ok = 0
foreach ($h in @(Get-ChildItem $src -File)) {
  $dst = Join-Path $dstDir $h.Name
  $want = [IO.File]::ReadAllText($h.FullName)
  $have = if (Test-Path $dst) { [IO.File]::ReadAllText($dst) } else { $null }
  if ($have -ne $want) {
    if ($Check) { [void]$bad.Add(($h.Name + $(if ($null -eq $have) { ' NOT INSTALLED' } else { ' STALE - differs from ops\hooks' }))); continue }
    # LF endings: git runs hooks through sh, and a CRLF shebang line makes it fail with a bare
    # "not found" that names nothing useful.
    [IO.File]::WriteAllText($dst, ($want -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
    $have = [IO.File]::ReadAllText($dst)
  }
  # MEASURE, do not assume the copy worked
  if (($have -replace "`r`n", "`n") -eq ($want -replace "`r`n", "`n")) { $ok++ } else { [void]$bad.Add($h.Name + ' COPY FAILED') }
}

if ($bad.Count) {
  Write-Output ("install-hooks: " + $bad.Count + " hook(s) not live:")
  $bad | ForEach-Object { Write-Output ('  ' + $_) }
  Write-Output '  Fix: powershell -File ops\install-hooks.ps1'
  Write-GuardComplete -Name 'install-hooks' -Summary ($bad.Count.ToString() + ' not live')
  exit 1
}
Write-Output ("install-hooks: $ok hook(s) live in " + $dstDir + " and byte-identical to ops\hooks")
Write-GuardComplete -Name 'install-hooks' -Summary "$ok live"
exit 0
