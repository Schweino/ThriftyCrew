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
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\git-repo-env.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\atomic-write.ps1')   # Write-TcAtomicFile - a hook is replaced, never overwritten under a running shell
$repo = Split-Path $PSScriptRoot -Parent
$src  = Join-Path $PSScriptRoot 'hooks'

if (-not (Test-Path $src)) { Write-Output 'BLIND: ops\hooks does not exist - nothing to install'; exit 3 }
# WHERE GIT READS HOOKS IS ASKED OF GIT (2026-09-11). This was <repo>\.git\hooks, and for a linked worktree the
# gitdir its .git FILE names, plus \hooks. That second directory is not one git ever opens for hooks: a linked
# worktree runs the hooks of the COMMON directory, or of core.hooksPath when that is set (some worktrees here set
# it in their own config.worktree). Read from the code, not run: from a worktree this would have created .git\worktrees\<name>\hooks,
# written the hooks there, read them back byte-identical and reported them live, while the hooks git runs
# stayed as they were - the very "installed into a path that is not the one git reads" its comment said it
# prevented. Measured from .claude\worktrees\nice-wilson-dd8f36: `git rev-parse --git-path hooks` answers
# C:\Codex\ThriftyCrew\.git\hooks. The repository environment is cleared first, so a run spawned from inside a
# hook asks about this checkout rather than the hook's.
Clear-TcGitRepoEnv
$gp = ''; $gpRc = -1
$prevEap = $ErrorActionPreference
try {
  $ErrorActionPreference = 'Continue'
  $gp = [string](@(& git -C $repo rev-parse --git-path hooks 2>$null) | Select-Object -Last 1)
  $gpRc = $LASTEXITCODE
} finally { $ErrorActionPreference = $prevEap }
if ($gpRc -ne 0 -or -not $gp.Trim()) { Write-Output ('BLIND: git could not say where ' + $repo + ' reads its hooks'); exit 3 }
$dstDir = $gp.Trim()
if (-not [IO.Path]::IsPathRooted($dstDir)) { $dstDir = Join-Path $repo $dstDir }
$dstDir = [IO.Path]::GetFullPath($dstDir)
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
    #
    # REPLACED, NEVER OVERWRITTEN IN PLACE (2026-09-11). sh reads a hook AS IT RUNS IT, so overwriting the bytes
    # under a push that is already executing this file hands that shell the tail of a different script. Measured
    # here that afternoon: a push at 18:26 died with "C:\Codex\ThriftyCrew\.git\hooks/pre-push: line 112: s:
    # command not found" while another session installed its own pre-push change - the running shell read one file
    # before the write and another after it. A temp-then-move leaves the running shell on the old inode and gives
    # the next push the new one whole, and Write-TcAtomicFile retries the move when a reader still holds the name
    # (lib\atomic-write.ps1, the rule in .claude\rules\ops-and-gates.md). -NoBom -NoNewline so the bytes written
    # are exactly the bytes this line wrote before: a hook is compared byte for byte by the check below.
    $null = Write-TcAtomicFile -Path $dst -Text ($want -replace "`r`n", "`n") -NoBom -NoNewline
    $have = [IO.File]::ReadAllText($dst)
  }
  # MEASURE, do not assume the copy worked
  if (($have -replace "`r`n", "`n") -eq ($want -replace "`r`n", "`n")) { $ok++ } else { [void]$bad.Add($h.Name + ' COPY FAILED') }
}

if ($bad.Count) {
  Write-Output ("install-hooks: " + $bad.Count + " hook(s) not live:")
  $bad | ForEach-Object { Write-Output ('  ' + $_) }
  Write-Output '  Fix: powershell -File ops\install-hooks.ps1'
  Exit-Guard -Name 'install-hooks' -Summary ($bad.Count.ToString() + ' not live') -Code 1
}
Write-Output ("install-hooks: $ok hook(s) live in " + $dstDir + " and byte-identical to ops\hooks")
Exit-Guard -Name 'install-hooks' -Summary "$ok live" -Code 0
