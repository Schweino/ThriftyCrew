<#
  audit-run-log-claims.ps1 - the run-record library must describe the conventions that actually exist.

  WHY THIS EXISTS (2026-09-06, backlog E29). grocery\run-log-lib.ps1 opened with "ONE copy of the
  'write this run down' rule" and it WAS one of three. Five scheduled tasks run -WindowStyle Hidden;
  only the three TC Grocery ones routed through that library, while the nightly matching chain wrote
  only its own graph-nightly-status.json and TC Recipe Harvest Crawl only appended crawl-<date>.log.

  Neither of those was a run record. Nightly's status file is written at the very END, so a run that
  died before that line left nothing at all - indistinguishable from a run that never started - and
  harvest's log says what python did and nothing about whether the script finished or why. Both now
  dot-source the library as well, and both KEEP their own artefacts, which persist subprocess output
  captured into a variable and so never reach a transcript.

  THE CLAIM WAS THE ORIGINAL DEFECT. A file that says it is the single copy of a rule and is not is
  worse than no claim at all, because the next person to add a hidden task reads that line, sees a
  library, and has no way to learn that other tasks route around it. It also meant the library's two
  hard-won rules - logging must never kill the run, and every Add-Content/Start-Transcript under
  $ErrorActionPreference='Stop' must be guarded - were ENFORCED for three tasks and merely hoped for
  in the other two. That is now true of all five, and this gate is what keeps it true.

  WHAT CHANGED ON 2026-09-06, and it is the whole reason this gate can now do its job. E29 rejected
  the obvious detector - grep -WindowStyle Hidden out of every Register-ScheduledTask and require the
  target to dot-source the library - because it would have MISSED THREE OF THE FIVE TASKS: the TC
  Grocery registrations lived only in the Windows registry, where no static detector can reach. Those
  definitions are now committed at ops\scheduled-tasks\*.xml, so the check is hermetic AND complete.

  IT NOW CHECKS TWO THINGS:
    1. every hidden scheduled task's target script dot-sources run-log-lib, read from the committed
       task XML rather than from whatever the registry happens to hold
    2. the library's header does not claim to be the only copy of a rule it is not

  WHAT IT STILL CANNOT DO is notice a task that exists in the registry and NOT in ops\scheduled-tasks.
  install-grocery-tasks.ps1 -Verify is the check for that, and it is deliberately not in this gate
  because it reads live scheduler state and is not hermetic.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 hard finding, 3 could-not-evaluate.
  Read the verdict LINE, not the number (backlog E2).

  Self-test: powershell -File ops\audit-run-log-claims.ps1 -SelfTest
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

$LIB = Join-Path $repo 'grocery\run-log-lib.ps1'

$TASKDIR = Join-Path $repo 'ops\scheduled-tasks'

function Get-HiddenTaskTargets([string]$root) {
  <# Every -WindowStyle Hidden scheduled task's TARGET SCRIPT, read from the committed XML.

     Returns [pscustomobject]@{ Task; Script; Exists; UsesRunLog }. The -File argument is what a task
     actually runs, so that is what gets checked - not whatever a registrar script claims to install. #>
  $out = New-Object System.Collections.Generic.List[object]
  $dir = Join-Path $root 'ops\scheduled-tasks'
  if (-not (Test-Path $dir)) { return $out }
  foreach ($f in @(Get-ChildItem -Path $dir -Filter '*.xml' -File -ErrorAction SilentlyContinue)) {
    $xml = [IO.File]::ReadAllText($f.FullName)
    if ($xml -notmatch '-WindowStyle\s+Hidden') { continue }
    $m = [regex]::Match($xml, '-File\s+"([^"]+)"')
    if (-not $m.Success) { continue }
    $script = $m.Groups[1].Value
    $exists = Test-Path $script
    $uses = $false
    if ($exists) { $uses = ([IO.File]::ReadAllText($script) -match 'run-log-lib\.ps1') }
    $out.Add([pscustomobject]@{ Task = $f.BaseName; Script = $script; Exists = $exists; UsesRunLog = $uses })
  }
  return $out
}

function Test-HeaderNames([string]$headerText, [string]$name) {
  return ($headerText -like ('*' + $name + '*'))
}

function Get-ClaimLine([string]$path) {
  <# The TITLE line - "run-log-lib.ps1 - <what this file is>" - which is the file's assertion about
     itself. Everything below it is commentary, and commentary must be free to QUOTE a false claim in
     order to correct it. Greping the whole header cannot tell those apart, and the first version of
     this gate fired on the very header that fixed the defect. #>
  foreach ($line in [IO.File]::ReadAllLines($path)) {
    $s = $line.Trim()
    if ($s -match '^[A-Za-z0-9._-]+\.ps1\s+-\s+') { return $s }
    if ($s -eq '#>') { break }
  }
  return ''
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

  # MUST FIRE and its CLEAN TWIN, and the twin is the one that earned its place: the first version of
  # this gate greped the whole header, so it fired on the corrected header BECAUSE that header quotes
  # the old false claim in order to explain what changed. A file explaining its own history is what we
  # want; the detector had to learn the difference between a claim and a quotation of one.
  $tmpA = Join-Path ([IO.Path]::GetTempPath()) ('rlA-' + [guid]::NewGuid().ToString('N') + '.ps1')
  $tmpB = Join-Path ([IO.Path]::GetTempPath()) ('rlB-' + [guid]::NewGuid().ToString('N') + '.ps1')
  try {
    "<#`n  run-log-lib.ps1 - ONE copy of the `"write this run down`" rule.`n#>" | Set-Content $tmpA -Encoding UTF8
    if ((Get-ClaimLine $tmpA) -match 'ONE copy of the') { Write-Output 'ok    MUST FIRE  a TITLE line claiming to be the one copy is the defect' } else { Write-Output 'FAIL  the founding false claim would not be caught'; $fail++ }

    "<#`n  run-log-lib.ps1 - the run-record rule for ALL FIVE hidden scheduled tasks.`n`n  This header used to open `"ONE copy of the write this run down rule`" and that was false.`n#>" | Set-Content $tmpB -Encoding UTF8
    if ((Get-ClaimLine $tmpB) -notmatch 'ONE copy of the') { Write-Output 'ok    CLEAN TWIN a header that QUOTES the old claim to correct it is not the defect' } else { Write-Output 'FAIL  the detector cannot tell a claim from a quotation of one - the honest fix trips it'; $fail++ }
    if ((Get-ClaimLine $tmpB) -like '*ALL FIVE*') { Write-Output 'ok    the title line is what gets read, not the whole comment block' } else { Write-Output ('FAIL  wrong line read as the claim: ' + (Get-ClaimLine $tmpB)); $fail++ }
  } finally {
    Remove-Item $tmpA, $tmpB -Force -ErrorAction SilentlyContinue
  }

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
    if ((Get-ClaimLine $LIB) -notmatch 'ONE copy of the') { Write-Output 'ok    the live TITLE line no longer claims to be the only copy' } else { Write-Output 'FAIL  grocery\run-log-lib.ps1 still opens with the false ONE-copy claim'; $fail++ }
    $targets = Get-HiddenTaskTargets $repo
    if ($targets.Count -ge 5) { Write-Output ("ok    all {0} hidden task definition(s) are readable from the repo" -f $targets.Count) } else { Write-Output ("FAIL  only {0} hidden task definition(s) found - the committed XML is incomplete, which is the hole E29 was about" -f $targets.Count); $fail++ }
    foreach ($t2 in $targets) {
      if (-not $t2.Exists) { Write-Output ("FAIL  " + $t2.Task + " points at a script that does not exist: " + $t2.Script); $fail++; continue }
      if ($t2.UsesRunLog) { Write-Output ("ok    " + $t2.Task + " dot-sources run-log-lib") } else { Write-Output ("FAIL  " + $t2.Task + " runs hidden and does NOT dot-source run-log-lib: " + $t2.Script); $fail++ }
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

$targets = Get-HiddenTaskTargets $repo
$unnamed = @($targets | Where-Object { $_.Exists -and (-not $_.UsesRunLog) })
$missing = @($targets | Where-Object { -not $_.Exists })

if ((Get-ClaimLine $LIB) -match 'ONE copy of the') {
  Write-Output 'RUN-LOG CLAIMS AUDIT FAILED: grocery\run-log-lib.ps1 opens by calling itself the ONE copy of the run-record rule while other conventions exist in the tree. A file that claims to be the single copy of a rule and is not is worse than no claim - the next person to add a hidden task reads it, sees a library, and cannot learn that other tasks route around it.'
  Write-GuardComplete -Name 'run-log-claims' -Summary 'false-one-copy-claim'
  exit 2
}
if ($targets.Count -eq 0) {
  Write-Output ('RUN-LOG CLAIMS COULD NOT EVALUATE: no hidden scheduled-task definition was readable from ops\scheduled-tasks. Discovery broken, NOT a clean tree.')
  Write-GuardComplete -Name 'run-log-claims' -Summary 'blind=no-task-xml'
  exit 3
}
foreach ($m in $missing) { Write-Output ("  target missing  {0}  ->  {1}" -f $m.Task, $m.Script) }
foreach ($u in $unnamed) { Write-Output ("  no run record   {0}  ->  {1}" -f $u.Task, $u.Script) }
if ($missing.Count -gt 0 -or $unnamed.Count -gt 0) {
  Write-Output ("RUN-LOG CLAIMS AUDIT FAILED: of {0} hidden scheduled task(s), {1} target a script that does not exist and {2} run hidden without dot-sourcing run-log-lib. A task that runs with no console and no run record can only ever say its exit code, and this estate has already spent a day unable to learn why three jobs returned 1." -f $targets.Count, $missing.Count, $unnamed.Count)
  Write-GuardComplete -Name 'run-log-claims' -Summary ("tasks={0} missing={1} norunlog={2}" -f $targets.Count, $missing.Count, $unnamed.Count)
  exit 2
}
Write-Output ("run-log-claims: PASSED - all {0} hidden scheduled task(s) leave a run record through run-log-lib, checked from the committed task definitions rather than the registry." -f $targets.Count)
Write-GuardComplete -Name 'run-log-claims' -Summary ("tasks={0} norunlog=0" -f $targets.Count)
exit 0
