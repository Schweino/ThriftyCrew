<#
  audit-run-log-claims.ps1 - the run-record library must describe the conventions that actually exist.

  WHY THIS EXISTS (2026-09-06, backlog E29). grocery\run-log-lib.ps1 opened with "ONE copy of the
  'write this run down' rule" and it was one of THREE. Five scheduled tasks run -WindowStyle Hidden,
  and only the three TC Grocery ones route through that library; the nightly matching chain writes its
  own graph-nightly-status.json, and TC Recipe Harvest Crawl appends with Out-File at four sites.

  NOTHING IS UNLOGGED, so this is ergonomics and not correctness. The defect is the CLAIM. A file that
  says it is the single copy of a rule and is not is worse than no claim at all, because the next
  person to add a hidden task reads that line, sees a library, and has no way to learn that two other
  tasks route around it. It also means the library's two hard-won rules - logging must never kill the
  run, and every Add-Content/Start-Transcript under $ErrorActionPreference='Stop' must be guarded -
  are ENFORCED for three tasks and merely hoped for in the other two.

  WHAT THIS CAN AND CANNOT COVER, stated because E29 rejected the obvious gate for exactly this reason.
  The tempting detector greps -WindowStyle Hidden out of every Register-ScheduledTask line and requires
  the target to dot-source the library. It would be hermetic and it would MISS THREE OF THE FIVE TASKS,
  because the TC Grocery registrations live in the Windows registry and not in any file a static
  detector can read. A static gate can only cover what is in the tree, and the tasks that hurt are the
  ones that are not.

  So this gate checks the one thing that IS in the tree and IS checkable: that when a second logging
  convention exists, the library's header names it. It is a documentation-drift gate. It cannot make
  the conventions converge - that is E29's open half and needs a ruling on whether the registry
  registrations move in-repo.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 hard finding, 3 could-not-evaluate.
  Read the verdict LINE, not the number (backlog E2).

  Self-test: powershell -File ops\audit-run-log-claims.ps1 -SelfTest
#>
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

$LIB = Join-Path $repo 'grocery\run-log-lib.ps1'

# The OTHER conventions, each as (marker file, marker string, the name the header must use). A
# convention is "present" when its marker still exists in the tree; when it is present the header must
# name it, and when it is gone the header should stop claiming it.
function Get-Conventions([string]$root) {
  return @(
    [pscustomobject]@{
      Name    = 'graph-nightly-status.json'
      Present = (Select-String -Path (Join-Path $root 'graph\pipeline\*.ps1') -Pattern 'graph-nightly-status' -SimpleMatch -List -ErrorAction SilentlyContinue) -ne $null
      Why     = 'the nightly matching chain writes its own status file instead of using the library'
    }
    [pscustomobject]@{
      Name    = 'harvest-crawl.ps1'
      Present = (Select-String -Path (Join-Path $root 'meal-prep\pipeline\harvest-crawl.ps1') -Pattern 'Out-File' -SimpleMatch -List -ErrorAction SilentlyContinue) -ne $null
      Why     = 'TC Recipe Harvest Crawl appends its own log with Out-File instead of using the library'
    }
  )
}

function Test-HeaderNames([string]$headerText, [string]$name) {
  return ($headerText -like ('*' + $name + '*'))
}

function Get-Header([string]$path) {
  <# The comment block only. A mention buried in the CODE is not the header telling a reader what this
     library covers, and counting it would let the claim drift while the gate stayed green. #>
  $t = [IO.File]::ReadAllText($path)
  $i = $t.IndexOf('#>')
  if ($i -lt 0) { return '' }
  return $t.Substring(0, $i)
}

if ($SelfTest) {
  $fail = 0

  # MUST FIRE: the founding claim. A header asserting it is the only copy while another convention
  # exists is the exact defect this gate was written for.
  $bad = '<# run-log-lib.ps1 - ONE copy of the "write this run down" rule. #>'
  if (-not (Test-HeaderNames $bad 'graph-nightly-status.json')) { Write-Output 'ok    MUST FIRE  a header that does not name an existing second convention is a finding' } else { Write-Output 'FAIL  the founding false claim passed'; $fail++ }

  # CLEAN TWIN: a header that does name it passes. Without this the gate could be "always fails".
  $good = '<# covers the TC Grocery tasks; the chain uses graph-nightly-status.json and harvest-crawl.ps1 appends its own #>'
  if (Test-HeaderNames $good 'graph-nightly-status.json') { Write-Output 'ok    CLEAN TWIN a header that names the other convention passes' } else { Write-Output 'FAIL  a correct header was reported as a finding'; $fail++ }
  if (Test-HeaderNames $good 'harvest-crawl.ps1') { Write-Output 'ok    CLEAN TWIN both conventions are checked, not just the first' } else { Write-Output 'FAIL  only one convention is actually checked'; $fail++ }

  # The header is the comment block, not the file. A mention in code must NOT satisfy the gate.
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('rl-' + [guid]::NewGuid().ToString('N') + '.ps1')
  try {
    "<#`n  a header that names nothing`n#>`n`$x = 'graph-nightly-status.json'" | Set-Content $tmp -Encoding UTF8
    if (-not (Test-HeaderNames (Get-Header $tmp) 'graph-nightly-status.json')) { Write-Output 'ok    MUST FIRE  a mention in the CODE does not count as the header naming it' } else { Write-Output 'FAIL  code was read as documentation - the claim could drift while this stayed green'; $fail++ }
  } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

  # And the live file, because a self-test that only reads its own fixtures proves the string
  # comparison works and nothing about the estate.
  if (Test-Path $LIB) {
    $hdr = Get-Header $LIB
    if ($hdr -notmatch 'ONE copy of the') { Write-Output 'ok    the live header no longer claims to be the only copy' } else { Write-Output 'FAIL  grocery\run-log-lib.ps1 still opens with the false ONE-copy claim'; $fail++ }
    foreach ($c in (Get-Conventions $repo)) {
      if (-not $c.Present) { Write-Output ("ok    convention gone from the tree, header need not name it: " + $c.Name); continue }
      if (Test-HeaderNames $hdr $c.Name) { Write-Output ("ok    the live header names " + $c.Name) } else { Write-Output ("FAIL  the live header does not name " + $c.Name); $fail++ }
    }
  } else {
    Write-Output 'FAIL  grocery\run-log-lib.ps1 is missing'; $fail++
  }

  if ($fail -gt 0) {
    Write-Output ("SELF-TEST FAIL: {0} case(s)" -f $fail)
    Write-GuardComplete -Name 'run-log-claims' -Summary ("selftest-fail={0}" -f $fail)
    exit 2
  }
  Write-Output 'SELF-TEST PASS: the founding false claim, its clean twin, the code-is-not-documentation case, and the live header'
  Write-GuardComplete -Name 'run-log-claims' -Summary 'selftest=pass'
  exit 0
}

if (-not (Test-Path $LIB)) {
  Write-Output ("RUN-LOG CLAIMS COULD NOT EVALUATE: {0} does not exist. Discovery broken, NOT a clean tree." -f $LIB)
  Write-GuardComplete -Name 'run-log-claims' -Summary 'blind=no-lib'
  exit 3
}
$hdr = Get-Header $LIB
if ([string]::IsNullOrWhiteSpace($hdr)) {
  Write-Output 'RUN-LOG CLAIMS COULD NOT EVALUATE: run-log-lib.ps1 has no readable comment header, so there is no claim to check.'
  Write-GuardComplete -Name 'run-log-claims' -Summary 'blind=no-header'
  exit 3
}

$conv = Get-Conventions $repo
$present = @($conv | Where-Object { $_.Present })
$unnamed = @($present | Where-Object { -not (Test-HeaderNames $hdr $_.Name) })

if ($hdr -match 'ONE copy of the') {
  Write-Output 'RUN-LOG CLAIMS AUDIT FAILED: grocery\run-log-lib.ps1 opens by calling itself the ONE copy of the run-record rule while other conventions exist in the tree. A file that claims to be the single copy of a rule and is not is worse than no claim - the next person to add a hidden task reads it, sees a library, and cannot learn that other tasks route around it.'
  Write-GuardComplete -Name 'run-log-claims' -Summary 'false-one-copy-claim'
  exit 2
}
if ($unnamed.Count -gt 0) {
  foreach ($u in $unnamed) { Write-Output ("  unnamed convention  {0}  -  {1}" -f $u.Name, $u.Why) }
  Write-Output ("RUN-LOG CLAIMS AUDIT FAILED: {0} run-logging convention(s) exist that grocery\run-log-lib.ps1's header does not name. Either bring that caller onto the library or name it in the header, so the next person adding a hidden task can see what is actually covered." -f $unnamed.Count)
  Write-GuardComplete -Name 'run-log-claims' -Summary ("unnamed={0} present={1}" -f $unnamed.Count, $present.Count)
  exit 2
}
Write-Output ("run-log-claims: PASSED - the header names all {0} other run-logging convention(s) in the tree. Convergence is still E29's open half and needs a ruling on the registry registrations." -f $present.Count)
Write-GuardComplete -Name 'run-log-claims' -Summary ("present={0} unnamed=0" -f $present.Count)
exit 0
