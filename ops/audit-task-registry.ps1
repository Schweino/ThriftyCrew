<#
  audit-task-registry.ps1 - the file-only wrapper that puts install-grocery-tasks.ps1 -VerifyRegistry
  into ops\run-gates.ps1.

  SCOPE OF A CLEAN REPORT: SOUND over the two lists it diffs - the registrar's $OWNED table
    against windows_tasks in the registry. A clean report means those two agree. A task that is
    in NEITHER is invisible to this check; health-heartbeat.ps1's REGISTRY DRIFT check is the
    one that catches that, not this file.

  WHY A WRAPPER AND NOT AN ENTRY (2026-09-07, queue 2026-09-07-dc7460). run-gates' $static list invokes
  every detector as `powershell -File <path>` with NO arguments, and install-grocery-tasks.ps1's default
  mode is -Verify, which reads the LIVE Windows scheduler. A gate that needs Task Scheduler is not
  hermetic: it would go red on a clean checkout, on a CI runner and in a worktree, for reasons that have
  nothing to do with the change being pushed - which is how a red gate stops being read. So the hermetic
  half gets its own zero-argument entry point and the live half stays where it belongs, in -Verify.

  WHAT IT PROVES. A scheduled task's NAME is a foreign key held in two hand-maintained tables: the
  $OWNED list inside install-grocery-tasks.ps1, and windows_tasks in grocery\expected-automations.json,
  which health-heartbeat reads to notice silent death. On 2026-09-07 at 06:30 a rename was applied to the
  scheduler and to $OWNED and NOT to the registry; every gate passed, and at 10:30 the heartbeat paged
  one rename as two issues - a phantom row for a task that no longer exists, and a real task nobody was
  watching. The heartbeat is the runtime backstop and it worked. This is the change-time check that did
  not exist.

  THIS FILE DECLARES NO SELF-TEST SWITCH, ON PURPOSE, and this paragraph deliberately does not spell the
  declaration out. run-gates discovers self-tests by matching that exact token in source, and it strips
  LINE comments before matching but NOT block comments like this one - so an earlier draft of this header
  that quoted the token in prose enrolled this wrapper as a self-test it does not have. It then ran with
  a switch it has no parameter for, which PowerShell drops silently into $args, and reported a green
  self-test line for coverage that does not exist. Measured 2026-09-07: run-gates listed this file twice,
  once under discovery and once as its static entry. The fixtures live with the function they test, in
  install-grocery-tasks.ps1, which run-gates discovers properly.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 hard finding, 3 could-not-evaluate.
  Read the verdict LINE, not the number.
#>
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

$target = Join-Path $here 'install-grocery-tasks.ps1'
if (-not (Test-Path $target)) {
  Write-Output ("TASK REGISTRY COULD NOT EVALUATE: {0} does not exist, so the registrar's own table cannot be read. Discovery broken, NOT a clean tree." -f $target)
  Exit-Guard -Name 'task-registry' -Summary 'blind=no-registrar' -Code 3
}

# NO 2>&1 on the child: this file sets EAP='Stop' and in PS 5.1 redirecting a native child's stderr turns
# its first stderr line into a terminating throw. The verdict is the exit code and stdout.
$out = & powershell -NoProfile -ExecutionPolicy Bypass -File $target -VerifyRegistry
$rc = $LASTEXITCODE
# Echo everything except the child's own completion marker, so the guard contract still holds here: the
# LAST line on stdout is this file's marker and nothing follows it.
foreach ($l in @($out)) { if ([string]$l -notmatch '^GROCERY-TASKS-COMPLETE') { Write-Output ([string]$l) } }

if ($rc -eq 0) {
  Write-Output 'task-registry: PASSED - the registrar and the heartbeat registry name the same scheduled tasks.'
  Exit-Guard -Name 'task-registry' -Summary 'agree=yes' -Code 0
}
if ($rc -eq 2) {
  Write-Output 'TASK REGISTRY FAILED: the registrar and grocery\expected-automations.json do not name the same tasks. A half-applied rename leaves a phantom row the heartbeat pages about and a live task nobody watches. Fix the registry row, keeping its allow_nonzero_exit and max_age_hours.'
  Exit-Guard -Name 'task-registry' -Summary 'agree=no' -Code 2
}
Write-Output ("TASK REGISTRY COULD NOT EVALUATE: install-grocery-tasks.ps1 -VerifyRegistry exited {0}, which is neither clean nor a finding. Could-not-evaluate is never a pass." -f $rc)
Exit-Guard -Name 'task-registry' -Summary ("blind=child-rc-{0}" -f $rc) -Code 3
