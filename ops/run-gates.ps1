<#
  run-gates.ps1 - the CHANGE-TIME gate. Everything provable without live data, run on every push.

  WHY THIS EXISTS (2026-08-08). This estate had 60 detectors, 324 scripts and 62,000 lines of PowerShell,
  and NOTHING ran when the code changed. Both GitHub workflows were `schedule:` only and there were zero git
  hooks, so every guard was policed by a clock: a bad commit shipped and was caught the next morning at best.
  That gap matters more now that the standing rule is to push every commit immediately - the day this was
  written, 12 commits went to main in one push through no automated gate at all.

  WHAT IT CAN AND CANNOT CHECK, and why the scope is what it is. A clean checkout has no board:
  grocery\out\comparison-*.json is gitignored, so guards.ps1, tile-integrity and every data audit would be
  BLIND on a runner - and a blind check that reports success is the exact failure this estate keeps writing
  guards about. So this gate deliberately runs only what is hermetic:

    1. every -SelfTest in the tree. That is the real payload. Each one drives frozen must-fire fixtures of a
       founding bug plus its clean twin, needs no data, no network and no secrets, and fails loudly when a
       fix stops being able to detect the thing it was written for.
    2. the static-analysis detectors that read SOURCE rather than data (guard contract, cloud readiness,
       script census) - the ones that catch a guard going dead, losing its completion marker, or becoming
       unreachable.

  The data-dependent audits stay where they are, in the daily chain against a real board. This gate answers
  "did this change break the machinery?", not "is today's board correct".

  Exit 0 = every gate passed. 1 = at least one failed. 3 = could not evaluate (found no self-tests at all,
  which would mean the discovery is broken rather than the tree being clean).
#>
param([switch]$ListOnly)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

# Self-tests that cannot run hermetically, with the reason. Keyed by file name, same standard as every other
# allowlist here: a line is a decision someone defends in a diff, not a way to make the gate quiet.
$SKIP = @{
  'check-ad-cycles.ps1' = 'the daily chain itself - running it would execute the whole pipeline, not test it'
  # test-auditors is NOT hermetic and cannot be made so cheaply: it drives the real audits against the real
  # board, and grocery\out\comparison-*.json is gitignored. On gates run #2 it failed with
  # "food-category clean twin failed (rc=3)" - rc=3 is could-not-evaluate, i.e. it went BLIND for want of a
  # board, not because anything was broken. Gating pushes on that would train everyone to ignore a red gate,
  # which is worse than not having one. It runs every day in check-ad-cycles against a real board, where its
  # 418 checks mean something. Excluded here on purpose, not overlooked.
  'test-auditors.ps1'   = 'data-dependent: needs a real board, which a clean checkout does not have (out\comparison-*.json is gitignored). Runs daily in the chain instead.'
}

$scripts = @(Get-ChildItem $repo -Recurse -File -Filter *.ps1 -ErrorAction SilentlyContinue |
  # \out\ is the pipeline's OUTPUT directory. Scripts that land there are one-offs and debris (the script
  # census counts 37 of them); running their self-tests would gate every push on abandoned scratch work.
  Where-Object { $_.FullName -notmatch '\\worktrees\\|\\archive\\|node_modules|\.venv|\\out\\' } |
  Sort-Object FullName)

$withSelfTest = @()
foreach ($s in $scripts) {
  if ($SKIP.ContainsKey($s.Name)) { continue }
  $t = [IO.File]::ReadAllText($s.FullName)
  # it must ACCEPT the switch, not merely mention it in prose
  if ($t -match '\[switch\]\$SelfTest' -or $t -match '\$__\w*SelfTest\s*=') { $withSelfTest += $s }
}

if ($ListOnly) {
  Write-Output ("self-tests discovered: {0}" -f $withSelfTest.Count)
  $withSelfTest | ForEach-Object { Write-Output ('  ' + $_.FullName.Replace($repo, '')) }
  exit 0
}

if (-not $withSelfTest.Count) {
  Write-Output 'run-gates: COULD NOT EVALUATE - discovered zero self-tests, which means this discovery is broken, not that the tree is clean'
  Write-GuardComplete -Name 'run-gates' -Summary 'blind=no-selftests'
  exit 3
}

$pass = 0; $fail = @()
Write-Output ("run-gates: {0} self-test(s) discovered" -f $withSelfTest.Count)
foreach ($s in $withSelfTest) {
  $rel = $s.FullName.Replace($repo, '').TrimStart('\')
  # NO 2>&1: merging a child's stderr under EAP=Stop makes its first stderr line a terminating throw in THIS
  # script. That trap has bitten test-auditors, guards and check-ad-cycles in this estate already.
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $s.FullName -SelfTest
  $rc = $LASTEXITCODE
  if ($rc -eq 0) { $pass++; Write-Output ("  ok    {0}" -f $rel) }
  else {
    $fail += $rel
    Write-Output ("  FAIL  {0}  (exit {1})" -f $rel, $rc)
    # THE EXCERPT MUST SHOW THE FAILURES (2026-08-08). This was `-match '(?i)fail|X '` capped at 5 lines, and
    # '(?i)...x ' matches the "x " inside words - "mutex + atomic swap" scored as a hit. On gates run #2 that
    # spent 3 of the 5 slots on PASSING lines and hid 3 of test-auditors' 4 failures from the log entirely,
    # so the run read as one broken watcher when it was four. Anchored to the FAIL/X markers, and 12 lines.
    @($out) | Where-Object { $_ -match '^\s*(FAIL|X)\b' -or $_ -match '(?-i)SELF-TEST FAIL' } |
      Select-Object -First 12 | ForEach-Object { Write-Output ('          ' + $_) }
    if (@($out).Count -gt 0) { Write-Output ('          ...' + (@($out).Count) + ' line(s) of output in total') }
  }
}

# ---- static-analysis detectors: they read SOURCE, so they work on a bare checkout ----
$static = @(
  @{ f = 'grocery\audit-guard-contract.ps1';   n = 'every chain detector can prove it ran, none are dead or half-covered' }
  @{ f = 'grocery\audit-cloud-readiness.ps1';  n = 'every credential consumer in the chain can run on a runner' }
  @{ f = 'grocery\audit-script-census.ps1';    n = 'no script is unreachable and unrecorded' }
)
foreach ($g in $static) {
  $p = Join-Path $repo $g.f
  if (-not (Test-Path $p)) { $fail += $g.f; Write-Output ("  FAIL  {0} is missing" -f $g.f); continue }
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $p
  $rc = $LASTEXITCODE
  if ($rc -eq 0) { $pass++; Write-Output ("  ok    {0}  ({1})" -f $g.f, $g.n) }
  else {
    $fail += $g.f
    Write-Output ("  FAIL  {0}  (exit {1}) - {2}" -f $g.f, $rc, $g.n)
    @($out) | Where-Object { $_ -match '!|FAIL' } | Select-Object -First 12 | ForEach-Object { Write-Output ('          ' + $_) }
  }
}

Write-Output ''
Write-Output ("run-gates: {0} passed, {1} failed" -f $pass, $fail.Count)
foreach ($f in $fail) { Write-Output ("  failed: " + $f) }
Write-GuardComplete -Name 'run-gates' -Summary ("pass={0} fail={1}" -f $pass, $fail.Count)
exit $(if ($fail.Count) { 1 } else { 0 })
