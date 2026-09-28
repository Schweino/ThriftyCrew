<#
  lib\hook-refresh.ps1 - reinstall the hooks git runs after something MOVED a checkout across an ops\hooks change.

  WHY (queue 2026-09-27-78df57, grocery/triage-plans/plan-2026-09-28-11.json). The hooks git runs for EVERY checkout
  are copies in the common .git\hooks, refreshed only by ops\install-hooks.ps1 or the 10:30 capture-watchdog -Repair.
  None of the three roads that move the main checkout's HEAD to a landed tip reinstalled, so a landed ops\hooks
  change ran as the previous hook for hours (26 of the last 27 such landings; modeled median 18 h, max 25.9 h). The
  three movers now call Update-TcInstalledHooks right after a successful move:
    lib\checkout-sync.ps1 (the ~07:00/~08:00 bots), grocery\sync-production-checkout.ps1 (the scheduled tasks),
    ops\push-main.ps1's landedSync (reset --keep, main checkout only, after the push lock is released).
  The watchdog's daily -Repair stays as the backstop.

  CONTRACT. Update-TcInstalledHooks -Repo <dir> -From <sha> -To <sha> [-Installer <scriptblock>] returns
  [pscustomobject]@{ ran; rc; files; line }. It reinstalls only when From..To changed a TOP-LEVEL file under ops\hooks
  (the files install-hooks copies; ops\hooks\claude\* is not one). It NEVER throws, NEVER writes to the pipeline (a
  caller's scriptblock return would carry the line: push-main's main_sync), and never alters a caller's outcome: the
  caller prints .line through its own logger. It takes no lock and makes no blocking wait beyond one git diff and one
  install-hooks child (sub-second copies), so it nests nothing in the declared lock order (og-27). The repository
  environment (GIT_DIR and the rest) is cleared for its own git and child calls and RESTORED after (og-23), so a
  caller running inside a hook keeps its own.
  -Installer is the test seam: param($Repo) -> exit code. Default: powershell -File <Repo>\ops\install-hooks.ps1,
  which writes each hook through Write-TcAtomicFile and verifies it by bytes.

  SCOPE OF A CLEAN REPORT: UNSOUND - ran=$false means only that From..To changed no top-level ops\hooks file; a hand
  move of the checkout (a session's own pull or reset) never calls this, and the watchdog -Repair covers that.

  Self-test:  powershell -NoProfile -File lib\hook-refresh.ps1 -SelfTest
  NO param() BLOCK: this file is dot-sourced into lib\checkout-sync.ps1 and ops\push-main.ps1, and a param block would
  reset the caller's own -SelfTest (the lib\checkout-sync.ps1 rule).
#>
# gate-inputs: lib\hook-refresh.ps1, ops\install-hooks.ps1, lib\guard-contract.ps1, lib\git-repo-env.ps1, lib\atomic-write.ps1
$__hrSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

function Get-TcHookRefreshFiles {
  <# The top-level ops/hooks files a diff name list names: the ones install-hooks copies. Pure. #>
  param([string[]]$Names)
  $out = @()
  foreach ($n in @($Names)) {
    $s = ([string]$n).Trim() -replace '\\', '/'
    if ($s -match '^ops/hooks/([^/]+)$') { $out += $Matches[1] }
  }
  return ,$out
}

function Update-TcInstalledHooks {
  param([string]$Repo, [string]$From, [string]$To, [scriptblock]$Installer = $null)
  $r = [pscustomobject]@{ ran = $false; rc = $null; files = @(); line = '' }
  if (-not $Repo -or -not $From -or -not $To -or [string]::Equals($From, $To, [StringComparison]::Ordinal)) { return $r }
  # The same names Clear-TcGitRepoEnv clears (lib\git-repo-env.ps1); held here so they can be RESTORED after.
  $envNames = @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR', 'GIT_OBJECT_DIRECTORY',
    'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_PREFIX', 'GIT_NAMESPACE')
  $saved = @{}
  foreach ($v in $envNames) { $p = Get-Item -LiteralPath ('Env:\' + $v) -ErrorAction SilentlyContinue; if ($p) { $saved[$v] = [string]$p.Value } }
  $prevEap = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    foreach ($v in $envNames) { if ($saved.ContainsKey($v)) { Remove-Item -LiteralPath ('Env:\' + $v) -ErrorAction SilentlyContinue } }
    $names = @(& git -C $Repo diff --name-only $From $To -- ops/hooks 2>$null)
    $drc = $LASTEXITCODE
    if ($drc -ne 0) { $r.line = ('hook-refresh: could not diff ' + $From + '..' + $To + ' (git exited ' + $drc + '); the 10:30 watchdog -Repair will retry'); return $r }
    $files = Get-TcHookRefreshFiles -Names $names
    if (@($files).Count -eq 0) { return $r }
    $r.files = @($files); $r.ran = $true
    $rc = $null
    if ($Installer) { $rc = @(& $Installer $Repo) | Select-Object -Last 1 }
    else {
      $inst = Join-Path $Repo 'ops\install-hooks.ps1'
      $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $inst 2>$null
      $rc = $LASTEXITCODE
    }
    $r.rc = $(if ($null -eq $rc) { -1 } else { [int]$rc })
    if ($r.rc -eq 0) { $r.line = ('hook-refresh: reinstalled ' + (@($files) -join ', ') + ' (install-hooks exit 0)') }
    else { $r.line = ('hook-refresh: install exited ' + $r.rc + ' for ' + (@($files) -join ', ') + '; the 10:30 watchdog -Repair will retry') }
  } catch {
    $r.line = ('hook-refresh: threw (' + $_.Exception.Message + '); the 10:30 watchdog -Repair will retry')
  } finally {
    $ErrorActionPreference = $prevEap
    foreach ($v in @($saved.Keys)) { Set-Item -LiteralPath ('Env:\' + $v) -Value $saved[$v] }
  }
  return $r
}

if ($__hrSelfTest) {
  $ErrorActionPreference = 'Stop'
  $here = Split-Path $PSCommandPath -Parent
  $real = Split-Path $here -Parent
  . (Join-Path $here 'git-repo-env.ps1')
  $script:hrFail = 0; $script:hrCases = 0
  function Assert-HrCase([string]$label, [bool]$ok, [string]$got) {
    $script:hrCases++
    if ($ok) { Write-Output ('  ok    ' + $label) } else { $script:hrFail++; Write-Output ('  FAIL  ' + $label + '   got: ' + $got) }
  }
  $scratch = Join-Path ([IO.Path]::GetTempPath()) ('tchr-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $savedGd = $env:GIT_DIR
  try {
    New-Item -ItemType Directory -Path $scratch -ErrorAction Stop | Out-Null
    Clear-TcGitRepoEnv
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
      $w = Join-Path $scratch 'repo'
      New-Item -ItemType Directory -Path (Join-Path $w 'ops\hooks\claude') -Force -ErrorAction Stop | Out-Null
      New-Item -ItemType Directory -Path (Join-Path $w 'grocery') -Force -ErrorAction Stop | Out-Null
      $null = & git -C $w init -q -b main . 2>$null
      $null = & git -C $w config user.email 't@example.invalid'; $null = & git -C $w config user.name 't'; $null = & git -C $w config core.autocrlf false
      $u8 = New-Object Text.UTF8Encoding($false)
      $v1 = "#!/bin/sh`necho v1 b06a3628e-shape`n"; $v2 = "#!/bin/sh`necho v2 b06a3628e-shape`n"
      [IO.File]::WriteAllText((Join-Path $w 'ops\hooks\pre-commit'), $v1, $u8)
      [IO.File]::WriteAllText((Join-Path $w 'ops\hooks\claude\production_barrier.py'), "x = 1`n", $u8)
      [IO.File]::WriteAllText((Join-Path $w 'grocery\commodities.json'), "[]`n", $u8)
      $null = & git -C $w add -A 2>$null; $null = & git -C $w commit -q -m c1 2>$null
      $c1 = [string](@(& git -C $w rev-parse HEAD) | Select-Object -Last 1)
      # the installed copy holds the OLD bytes
      [IO.File]::WriteAllText((Join-Path $w '.git\hooks\pre-commit'), $v1, $u8)
      # c2: only a grocery file (CLEAN TWIN); c3: only ops/hooks/claude/* (the 15d574651 shape); c4: ops/hooks/pre-commit
      [IO.File]::WriteAllText((Join-Path $w 'grocery\commodities.json'), "[1]`n", $u8); $null = & git -C $w commit -q -am c2 2>$null
      $c2 = [string](@(& git -C $w rev-parse HEAD) | Select-Object -Last 1)
      [IO.File]::WriteAllText((Join-Path $w 'ops\hooks\claude\production_barrier.py'), "x = 2`n", $u8); $null = & git -C $w commit -q -am c3 2>$null
      $c3 = [string](@(& git -C $w rev-parse HEAD) | Select-Object -Last 1)
      [IO.File]::WriteAllText((Join-Path $w 'ops\hooks\pre-commit'), $v2, $u8); $null = & git -C $w commit -q -am c4 2>$null
      $c4 = [string](@(& git -C $w rev-parse HEAD) | Select-Object -Last 1)
    } finally { $ErrorActionPreference = $prevEap }
    # the real installer, run from the scratch repo: ops\install-hooks.ps1 and the WHOLE lib\ beside it (og-33)
    Copy-Item -LiteralPath (Join-Path $real 'ops\install-hooks.ps1') -Destination (Join-Path $w 'ops\install-hooks.ps1') -ErrorAction Stop
    Copy-Item -LiteralPath (Join-Path $real 'lib') -Destination (Join-Path $w 'lib') -Recurse -ErrorAction Stop
    $hookPath = Join-Path $w '.git\hooks\pre-commit'
    $hash0 = (Get-FileHash -LiteralPath $hookPath).Hash
    $script:seamCalls = 0
    $seamOk = { param($rp) $script:seamCalls++; 0 }
    $seamBad = { param($rp) $script:seamCalls++; 1 }

    $a = Update-TcInstalledHooks -Repo $w -From $c1 -To $c2 -Installer $seamOk
    Assert-HrCase 'CLEAN TWIN: a move that changes only grocery/commodities.json calls the installer 0 times, no line, .git/hooks byte-identical' ((-not $a.ran) -and ($script:seamCalls -eq 0) -and (-not $a.line) -and ((Get-FileHash -LiteralPath $hookPath).Hash -eq $hash0)) ('ran=' + $a.ran + ' calls=' + $script:seamCalls)
    $b = Update-TcInstalledHooks -Repo $w -From $c2 -To $c3 -Installer $seamOk
    Assert-HrCase 'MUST NOT FIRE: a move that changes only ops/hooks/claude/production_barrier.py (the 15d574651 shape) calls the installer 0 times' ((-not $b.ran) -and ($script:seamCalls -eq 0) -and ((Get-FileHash -LiteralPath $hookPath).Hash -eq $hash0)) ('ran=' + $b.ran + ' calls=' + $script:seamCalls)
    $c = Update-TcInstalledHooks -Repo $w -From $c3 -To $c4 -Installer $seamBad
    Assert-HrCase 'DEGRADE: an installer that exits 1 returns rc 1 and exactly one "install exited 1" line, and never throws' (($c.ran) -and ($c.rc -eq 1) -and ($c.line -like 'hook-refresh: install exited 1 *') -and ($script:seamCalls -eq 1)) ($c.line)
    $d = Update-TcInstalledHooks -Repo $w -From $c1 -To $c4
    $installed = [IO.File]::ReadAllText($hookPath)
    Assert-HrCase 'MUST FIRE (b06a3628e shape): after a move across an ops/hooks/pre-commit change the REAL installer leaves .git/hooks/pre-commit equal to the new tree bytes' (($d.ran) -and ($d.rc -eq 0) -and ([string]::Equals($installed, $v2, [StringComparison]::Ordinal)) -and ($d.line -eq 'hook-refresh: reinstalled pre-commit (install-hooks exit 0)')) ('rc=' + $d.rc + ' line=' + $d.line)
    $e = Update-TcInstalledHooks -Repo $w -From $c4 -To $c4 -Installer $seamOk
    Assert-HrCase 'CLEAN TWIN: From equal to To (nothing moved) does nothing' ((-not $e.ran) -and (-not $e.line)) ('ran=' + $e.ran)
    $env:GIT_DIR = (Join-Path $scratch 'not-a-repo')
    $f = Update-TcInstalledHooks -Repo $w -From 'deadbeef' -To $c4 -Installer $seamOk
    Assert-HrCase 'a caller GIT_DIR is restored after the call, and a diff git refuses is a line, never a throw' (($env:GIT_DIR -eq (Join-Path $scratch 'not-a-repo')) -and ($f.line -like 'hook-refresh: could not diff*') -and (-not $f.ran)) ('GIT_DIR=' + $env:GIT_DIR + ' line=' + $f.line)
    Remove-Item Env:\GIT_DIR -ErrorAction SilentlyContinue
  } catch { $script:hrFail++; Write-Output ('  FAIL  hook-refresh self-test harness threw: ' + $_.Exception.Message) }
  finally {
    if ($null -ne $savedGd) { $env:GIT_DIR = $savedGd } else { Remove-Item Env:\GIT_DIR -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($script:hrCases -ne 6) { $script:hrFail++; Write-Output ('  FAIL  expected 6 cases, ran ' + $script:hrCases) }
  if ($script:hrFail -eq 0) { Write-Output ('hook-refresh self-test pass (' + $script:hrCases + ' cases)'); exit 0 }
  Write-Output ('hook-refresh self-test FAIL (' + $script:hrFail + ' of ' + $script:hrCases + ' failed)'); exit 1
}
