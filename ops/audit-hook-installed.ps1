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

  -Repair: RE-ASSERT, DO NOT ONLY REPORT (2026-09-26, queue 2026-09-26-4b6616). Nothing re-installed the hooks when a
  commit to ops\hooks landed: b06a3628e changed ops\hooks\pre-commit on 2026-09-25 and .git\hooks\pre-commit stayed the
  2026-09-11 copy until the next day's watchdog paged it. The copy is mechanical, so the watchdog now asks for it: on
  a stale or missing hook, and only when this checkout is the MAIN working tree (a linked worktree's ops\hooks may be a
  branch's, and would be installed for every checkout) and ops\hooks has no uncommitted change (never install an edit in
  flight), it runs ops\install-hooks.ps1 and re-checks. A verified repair exits 0 with a REPAIRED line naming what was
  stale; a refused or failed one exits 2 as before, with the reason.
#>
# The self-test classifies literal install-hooks output and reads ops\install-hooks.ps1 as text for its -Check switch.
# gate-inputs: lib\guard-contract.ps1, ops\install-hooks.ps1
[CmdletBinding()]
param([switch]$SelfTest, [switch]$Repair)
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

function Invoke-HookAudit {
  <# The whole audit, with its three effects as seams so the self-test drives the real flow.
     $Check { -> @{ Lines; ExitCode } } runs install-hooks -Check; $Install { -> @{ Lines; ExitCode } } runs install-hooks;
     $State { -> @{ Linked = <bool|null>; HooksDirty = <bool|null> } } asks git. $null in State means git could not say,
     which refuses the repair. Returns @{ Code; Why }. #>
  param([scriptblock]$Check, [scriptblock]$Install, [scriptblock]$State, [switch]$Repair)
  $c = & $Check
  $v = Get-HookVerdict -Lines $c.Lines -ExitCode $c.ExitCode
  if ($v.Code -ne 2 -or -not $Repair) { return $v }
  $st = & $State
  $refuse = if ($null -eq $st.Linked -or $null -eq $st.HooksDirty) { 'git could not say whether this is the main working tree or whether ops\hooks is clean' }
            elseif ($st.Linked) { 'this is a linked worktree, whose ops\hooks may be a branch''s' }
            elseif ($st.HooksDirty) { 'ops\hooks has an uncommitted change, and an edit in flight is never installed' }
            else { '' }
  if ($refuse) { return @{ Code = 2; Why = ($v.Why + ' - NOT repaired: ' + $refuse) } }
  $i = & $Install
  $c2 = & $Check
  $v2 = Get-HookVerdict -Lines $c2.Lines -ExitCode $c2.ExitCode
  if ($i.ExitCode -eq 0 -and $v2.Code -eq 0) { return @{ Code = 0; Why = ('REPAIRED (' + ($v.Why -replace '^hook\(s\) missing or stale:\s*', '').Trim() + ') by ops\install-hooks.ps1; now ' + $v2.Why) } }
  return @{ Code = 2; Why = ($v.Why + ' - repair FAILED (install-hooks exit ' + $i.ExitCode + ', re-check: ' + $v2.Why + ')') }
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
  # -Repair, driven through Invoke-HookAudit with seams. $hk holds the fake .git\hooks state the seams read and write.
  $staleOut = @('pre-commit STALE - differs from ops\hooks', 'INSTALL-HOOKS-COMPLETE 3 live')
  $liveOut  = @('install-hooks: 4 hook(s) live in X and byte-identical to ops\hooks', 'INSTALL-HOOKS-COMPLETE 4 live')
  $mk = {
    param($Stale, $Linked, $Dirty, [int]$InstallRc = 0)
    $hk = @{ stale = $Stale; installs = 0 }
    $so = $staleOut; $lo = $liveOut   # locals, because GetNewClosure copies only this scope's variables
    $chk = { if ($hk.stale) { @{ Lines = $so; ExitCode = 2 } } else { @{ Lines = $lo; ExitCode = 0 } } }.GetNewClosure()
    $ins = { $hk.installs++; if ($InstallRc -eq 0) { $hk.stale = $false }; @{ Lines = @('x'); ExitCode = $InstallRc } }.GetNewClosure()
    $sta = { @{ Linked = $Linked; HooksDirty = $Dirty } }.GetNewClosure()
    @{ hk = $hk; chk = $chk; ins = $ins; sta = $sta }
  }
  # MUST FIRE (the founding state, 2026-09-26 main checkout): pre-commit stale after b06a3628e, ops\hooks clean, main tree.
  $f = & $mk $true $false $false
  $r5 = Invoke-HookAudit -Check $f.chk -Install $f.ins -State $f.sta -Repair
  Case 'MUST FIRE' '-Repair on the main tree reinstalls a stale hook, re-checks, exits 0 REPAIRED' ($r5.Code -eq 0 -and $r5.Why -match '^REPAIRED \(pre-commit STALE' -and $f.hk.installs -eq 1) ("code=$($r5.Code) installs=$($f.hk.installs) why=$($r5.Why)")
  # MUST NOT FIRE: without -Repair the same state is still a finding and nothing is installed.
  $f = & $mk $true $false $false
  $r6 = Invoke-HookAudit -Check $f.chk -Install $f.ins -State $f.sta
  Case 'MUST NOT FIRE' 'no -Repair: a stale hook stays a finding (2), nothing installed' ($r6.Code -eq 2 -and $f.hk.installs -eq 0) ("code=$($r6.Code) installs=$($f.hk.installs)")
  # MUST NOT FIRE: ops\hooks carries an uncommitted edit - never install it.
  $f = & $mk $true $false $true
  $r7 = Invoke-HookAudit -Check $f.chk -Install $f.ins -State $f.sta -Repair
  Case 'MUST NOT FIRE' '-Repair refuses while ops\hooks is dirty: finding (2), nothing installed' ($r7.Code -eq 2 -and $r7.Why -match 'NOT repaired' -and $f.hk.installs -eq 0) ("code=$($r7.Code) installs=$($f.hk.installs)")
  # MUST NOT FIRE: a linked worktree - its ops\hooks may be a branch's.
  $f = & $mk $true $true $false
  $r8 = Invoke-HookAudit -Check $f.chk -Install $f.ins -State $f.sta -Repair
  Case 'MUST NOT FIRE' '-Repair refuses from a linked worktree: finding (2), nothing installed' ($r8.Code -eq 2 -and $f.hk.installs -eq 0) ("code=$($r8.Code) installs=$($f.hk.installs)")
  # MUST NOT FIRE: git could not answer - refuse, never guess.
  $f = & $mk $true $null $null
  $r9 = Invoke-HookAudit -Check $f.chk -Install $f.ins -State $f.sta -Repair
  Case 'MUST NOT FIRE' '-Repair refuses when git cannot say which tree this is' ($r9.Code -eq 2 -and $f.hk.installs -eq 0) ("code=$($r9.Code) installs=$($f.hk.installs)")
  # MUST FIRE: an install that does not take is still a finding - the re-check decides, never the install's word.
  $f = & $mk $true $false $false 1
  $r10 = Invoke-HookAudit -Check $f.chk -Install $f.ins -State $f.sta -Repair
  Case 'MUST FIRE' 'a repair the re-check does not confirm stays a finding (2), repair FAILED' ($r10.Code -eq 2 -and $r10.Why -match 'repair FAILED') ("code=$($r10.Code) why=$($r10.Why)")
  # CLEAN TWIN: live hooks with -Repair are a plain pass and install nothing.
  $f = & $mk $false $false $false
  $r11 = Invoke-HookAudit -Check $f.chk -Install $f.ins -State $f.sta -Repair
  Case 'CLEAN TWIN' 'live hooks under -Repair: pass (0), not REPAIRED, nothing installed' ($r11.Code -eq 0 -and $r11.Why -notmatch 'REPAIRED' -and $f.hk.installs -eq 0) ("code=$($r11.Code) installs=$($f.hk.installs)")
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
  $ih = Join-Path $repo 'ops\install-hooks.ps1'
  $chk = { $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $ih -Check; @{ Lines = $o; ExitCode = $LASTEXITCODE } }
  $ins = { $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $ih; @{ Lines = $o; ExitCode = $LASTEXITCODE } }
  $sta = {
    . (Join-Path $repo 'lib\git-repo-env.ps1'); Clear-TcGitRepoEnv
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
      $gd = [string](@(& git -C $repo rev-parse --absolute-git-dir 2>$null) | Select-Object -Last 1); $gdRc = $LASTEXITCODE
      $cd = [string](@(& git -C $repo rev-parse --path-format=absolute --git-common-dir 2>$null) | Select-Object -Last 1); $cdRc = $LASTEXITCODE
      $dirty = @(& git -C $repo status --porcelain -- ops/hooks 2>$null); $stRc = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    $linked = if ($gdRc -eq 0 -and $cdRc -eq 0 -and $gd.Trim() -and $cd.Trim()) { -not [string]::Equals([IO.Path]::GetFullPath($gd.Trim()), [IO.Path]::GetFullPath($cd.Trim()), [StringComparison]::OrdinalIgnoreCase) } else { $null }
    $hd = if ($stRc -eq 0) { [bool](@($dirty | Where-Object { "$_".Trim() }).Count) } else { $null }
    @{ Linked = $linked; HooksDirty = $hd }
  }
  $v = Invoke-HookAudit -Check $chk -Install $ins -State $sta -Repair:$Repair
  "hook-installed: $($v.Why)"
  Exit-Guard -Name 'HOOK-INSTALLED' -Code $v.Code -Summary ("code={0}" -f $v.Code)
}
