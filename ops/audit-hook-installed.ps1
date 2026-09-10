<#
  audit-hook-installed.ps1 - the git hooks that run the change-time gate are actually live on this machine.

  WHY THIS FILE EXISTS, AND WHY IT HAD TO BE WRITTEN RATHER THAN UN-CITED (2026-09-10, WS 10d).
  Five places in this tree said it was already running: CLAUDE.md ("asserted live by
  ops/audit-hook-installed.ps1"), ops\hooks\pre-push, ops\hooks\pre-commit, ops\install-hooks.ps1 and
  ops\test-precommit-hook.ps1. **It did not exist and never had** - `git log` for the path is empty.
  So the property "the gate runs on every push" rested on an untracked file in .git\hooks, asserted by
  a guard nobody wrote, in the same file (CLAUDE.md) that already records the gate being falsely
  claimed for a month between 2026-08-11 and 2026-09-09. A citation that resolves to nothing reads as
  authority; ops\audit-memory-citations.ps1 exists because of exactly that shape, one directory over.

  Deleting the five citations would have been the cheaper fix and the wrong one: the property they
  describe is real and worth asserting. ops\install-hooks.ps1 -Check already does the comparison, so
  this is the thin guard the citations promised, plus a caller.

  WHY THE DAILY CHAIN AND NOT run-gates. run-gates is INVOKED BY the pre-push hook, so a hook check
  inside it proves only that the hook it is running inside exists. And in a worktree or a fresh clone
  .git\hooks is legitimately absent, which would make every spawned agent's gate red. The live check
  runs from grocery\capture-watchdog.ps1 on the main checkout once a day, where "the hook is missing"
  is a real, alertable state. Only this file's -SelfTest is hermetic, and that is what run-gates runs.

  SCOPE OF A CLEAN REPORT: SOUND about presence and byte-identity of the hooks in .git\hooks against
  ops\hooks. It says nothing about whether anybody pushed with --no-verify, which is the deliberate,
  loud bypass and not a defect.

  EXIT CODES (lib\guard-contract.ps1): 0 live and identical, 2 missing or stale, 3 could not evaluate.
#>
[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

function Get-HookVerdict {
  <# Classify install-hooks.ps1 -Check output. Pure: takes the lines and the exit code.
     Returns @{ Code=<0|2|3>; Why=<string> }. The COMPLETE marker is required for a pass, because
     "the checker died halfway" and "the hooks are fine" must never share an exit path. #>
  param($Lines, [int]$ExitCode)
  $text = (@($Lines) | ForEach-Object { "$_" }) -join "`n"
  $done = $text -match 'INSTALL-HOOKS-COMPLETE'
  if ($ExitCode -eq 3 -or $text -match '(?m)^BLIND') {
    return @{ Code = 3; Why = 'COULD NOT EVALUATE: ' + (($text -split "`n" | Where-Object { $_ -match 'BLIND' } | Select-Object -Last 1)) }
  }
  if (-not $done) { return @{ Code = 3; Why = 'install-hooks -Check did not finish (no INSTALL-HOOKS-COMPLETE)' } }
  if ($ExitCode -ne 0 -or $text -match 'NOT INSTALLED|STALE') {
    $bad = @($text -split "`n" | Where-Object { $_ -match 'NOT INSTALLED|STALE' })
    return @{ Code = 2; Why = 'hook(s) missing or stale: ' + ($bad -join '; ') }
  }
  return @{ Code = 0; Why = (($text -split "`n" | Where-Object { $_ -match 'live' } | Select-Object -Last 1)) }
}

if ($SelfTest) {
  $fails = @(); $ran = @()
  function Case {
    param([string]$Label, [string]$Name, [bool]$Ok, [string]$Detail = '')
    $script:ran += $Name
    if (-not $Ok) { $script:fails += "$Label $Name" }
    '  {0,-14} {1,-58} {2}' -f $Label, $Name, $(if ($Ok) { 'ok' } else { "FAIL $Detail" })
  }
  # MUST NOT FIRE: the exact output install-hooks.ps1 -Check produced on 2026-09-10 on the main checkout.
  $v0 = Get-HookVerdict -Lines @('install-hooks: 3 hook(s) live in C:\Codex\ThriftyCrew\.git\hooks and byte-identical to ops\hooks', 'INSTALL-HOOKS-COMPLETE 3 live') -ExitCode 0
  Case 'MUST NOT FIRE' 'three live, identical hooks are a pass' ($v0.Code -eq 0) $v0.Why
  # MUST FIRE: a hook deleted from .git\hooks.
  $v1 = Get-HookVerdict -Lines @('pre-push NOT INSTALLED', 'INSTALL-HOOKS-COMPLETE 2 live') -ExitCode 2
  Case 'MUST FIRE' 'a hook that is not installed is a finding (2)' ($v1.Code -eq 2) $v1.Why
  # MUST FIRE: a hook edited in place, so it no longer matches ops\hooks.
  $v2 = Get-HookVerdict -Lines @('pre-commit STALE - differs from ops\hooks', 'INSTALL-HOOKS-COMPLETE 2 live') -ExitCode 2
  Case 'MUST FIRE' 'a stale hook is a finding (2)' ($v2.Code -eq 2) $v2.Why
  # MUST FIRE: no hooks directory at all - a worktree or clone. Could-not-evaluate, never a pass.
  $v3 = Get-HookVerdict -Lines @('BLIND: no hooks directory at X') -ExitCode 3
  Case 'MUST FIRE' 'a missing hooks directory is COULD NOT EVALUATE (3), not a pass' ($v3.Code -eq 3) $v3.Why
  # MUST FIRE: the checker died with exit 0 and no marker. That is the five-incident shape.
  $v4 = Get-HookVerdict -Lines @('install-hooks: checking') -ExitCode 0
  Case 'MUST FIRE' 'exit 0 with no completion marker is NOT a pass' ($v4.Code -eq 3) $v4.Why
  # CLEAN TWIN: the checker this wraps is where the citations say it is.
  Case 'CLEAN TWIN' 'ops\install-hooks.ps1 exists and declares -Check' `
    ((Test-Path -LiteralPath (Join-Path $repo 'ops\install-hooks.ps1')) -and
     ([IO.File]::ReadAllText((Join-Path $repo 'ops\install-hooks.ps1')) -match '\[switch\]\$Check'))
  ''
  if ($fails.Count) {
    "audit-hook-installed selftest: $($fails.Count) FAILED of $($ran.Count)"
    $fails | ForEach-Object { "  $_" }
    Exit-Guard -Name 'HOOK-INSTALLED-SELFTEST' -Code 1 -Summary "failed=$($fails.Count) of $($ran.Count)"
  }
  "audit-hook-installed selftest: $($ran.Count) of $($ran.Count) cases pass"
  Exit-Guard -Name 'HOOK-INSTALLED-SELFTEST' -Code 0 -Summary "cases=$($ran.Count)"
}

Invoke-Guard -Name 'HOOK-INSTALLED' -Body {
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'ops\install-hooks.ps1') -Check
  $rc = $LASTEXITCODE
  $v = Get-HookVerdict -Lines $out -ExitCode $rc
  "hook-installed: $($v.Why)"
  Exit-Guard -Name 'HOOK-INSTALLED' -Code $v.Code -Summary ("code={0}" -f $v.Code)
}
