# ---- THE CADENCE GATE, WHICH WAS CALLED EIGHT TIMES AND NEVER EXISTED (2026-08-23) --------------------
# Test-CadenceDue / Set-CadenceRan / Get-CadenceLast were designed, documented, given a self-test
# (test-cadence.ps1) and asserted in test-auditors - and never written. `git log -S "function
# Test-CadenceDue"` returns NOTHING: the string was never in this file. Every call site below therefore
# threw CommandNotFoundException, the enclosing try/catch logged it, and the gated audit was SKIPPED:
# the semantic sweep, aisle-test, matcher-parity and precedence-ladders. The feature whose own log line
# reads "A SKIP IS NOT A PASS" was, in practice, skipping all four of them.
#
# It stayed invisible because both of its watchers failed in the same direction. test-cadence.ps1
# extracts these three functions out of this file by regex and reports "could not extract the helpers",
# which reads like a broken test rather than a missing feature; and test-auditors' second assertion
# reports "the cadence stamp lost round-trip precision", which names a bug that cannot exist in code
# that does not exist. Two red lines, neither of them saying "this function is missing."
#
# Implemented here, in this file and in this order, because test-cadence.ps1 pulls them out with
# a regex over THIS FILE that requires the three definitions contiguous and in this exact order
# (Test-CadenceDue, then Set-CadenceRan, then Get-CadenceLast, each closing on a brace at column 0).
# It tests the SHIPPED code rather than a copy, which is the point - so do not reorder or separate
# them, and do not indent their closing braces.
# rather than a copy, so the definitions have to stay contiguous and in that order.
$script:CadenceRoot = Split-Path $root -Parent          # repo root: InputGlobs are repo-relative
$script:CadenceDir  = Join-Path $OutDir 'cadence'
if (-not (Test-Path $script:CadenceDir)) { New-Item -ItemType Directory -Path $script:CadenceDir -Force | Out-Null }
function Test-CadenceDue {
  <#
    Is this check due to run? DUE unless BOTH the clock and its inputs say otherwise.

    A SKIP IS NOT A PASS. Every uncertain answer here resolves to DUE: no stamp, an
    unreadable stamp, a stamp we cannot parse, a glob we cannot expand. The cost of a
    wrong DUE is seconds of CPU; the cost of a wrong SKIP is a guard that silently stops
    watching, which is the one failure this estate cannot tolerate.

    AN INPUT EDIT IS DUE TODAY, not in EveryDays. A commit that blinds a guard has to be
    caught the same day - otherwise the cadence trades minutes for exactly the blindness
    the guard culture exists to prevent.
  #>
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][int]$EveryDays,
    [string[]]$InputGlobs = @()
  )
  $stampF = Join-Path $script:CadenceDir ("cadence-" + $Name + ".txt")
  if (-not (Test-Path $stampF)) { return $true }                 # never run -> DUE
  $last = $null
  try {
    $raw = (Get-Content $stampF -Raw -ErrorAction Stop).Trim()
    if ($raw) { $last = [datetime]::Parse($raw, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
  } catch { return $true }                                        # unreadable -> DUE (fails OPEN)
  if ($null -eq $last) { return $true }
  if (((Get-Date) - $last).TotalDays -ge $EveryDays) { return $true }   # the clock alone
  # THE INPUT PATH. Globs are resolved against $script:CadenceRoot so callers can name
  # repo-relative paths ('grocery/commodities.json') and the self-test can use a sandbox.
  foreach ($g in @($InputGlobs)) {
    if (-not $g) { continue }
    $full = if ([IO.Path]::IsPathRooted($g)) { $g } else { Join-Path $script:CadenceRoot $g }
    $hits = @()
    try {
      if ($full -match '^(.*?)[\\/]\*\*[\\/]([^\\/]+)$') {
        # A '**' GLOB IS EVERY SUBFOLDER (2026-09-27, design\PLAN-split-giant-files-2026-09-27.md step 0): a split
        # script's pieces live in grocery\<host>\, which 'grocery/*.ps1' cannot see. archive\ and out\ are never
        # entered, at any depth. Self-contained on purpose: grocery\test-cadence.ps1 runs this function on its own.
        $cdLeaf = $Matches[2]
        $cdStack = New-Object System.Collections.Stack
        if (Test-Path -LiteralPath $Matches[1] -PathType Container) { $cdStack.Push((Get-Item -LiteralPath $Matches[1])) }
        while ($cdStack.Count -gt 0) {
          $cdDir = $cdStack.Pop()
          $hits += @(Get-ChildItem -LiteralPath $cdDir.FullName -File -Filter $cdLeaf -ErrorAction SilentlyContinue)
          foreach ($cdSub in @(Get-ChildItem -LiteralPath $cdDir.FullName -Directory -ErrorAction SilentlyContinue)) {
            if ($cdSub.Name -ne 'archive' -and $cdSub.Name -ne 'out') { $cdStack.Push($cdSub) }
          }
        }
      } else { $hits = @(Get-ChildItem -Path $full -File -ErrorAction SilentlyContinue) }
    } catch { return $true }
    foreach ($h in $hits) { if ($h.LastWriteTime -gt $last) { return $true } }
  }
  return $false
}
function Set-CadenceRan {
  <#
    Stamp this check as just-run. ToString('o') AND NOT 's' - the founding bug: 's'
    truncates to the second, so an input written in the SAME second read as newer than
    the stamp and every check was due forever. The cadence would have cost its full
    runtime while looking like it worked. test-cadence.ps1 case 2 is what caught it.
  #>
  param([Parameter(Mandatory, Position = 0)][string]$Name)
  try {
    if (-not (Test-Path $script:CadenceDir)) { New-Item -ItemType Directory -Path $script:CadenceDir -Force | Out-Null }
    Set-Content -Path (Join-Path $script:CadenceDir ("cadence-" + $Name + ".txt")) -Value ((Get-Date).ToString('o')) -Encoding ASCII
  } catch { }   # a stamp we could not write means DUE next time, which is the safe direction
}
function Get-CadenceLast {
  <# What the log prints next to a SKIP. 'never' for a check that has not run - never a fake date. #>
  param([Parameter(Mandatory, Position = 0)][string]$Name)
  $stampF = Join-Path $script:CadenceDir ("cadence-" + $Name + ".txt")
  if (-not (Test-Path $stampF)) { return 'never' }
  try {
    $raw = (Get-Content $stampF -Raw -ErrorAction Stop).Trim()
    if (-not $raw) { return 'never' }
    return $raw
  } catch { return 'never' }
}


# ---- BOUNDED CHILDREN (2026-08-22, and the parallel verdict corrected 2026-08-23) ----------------------
# THE COMMENT THAT STOOD HERE SAID "THE PARALLEL EXPERIMENT IS REVERTED, ON THE MEASUREMENT" AND THE
# MEASUREMENT WAS CONFOUNDED. It read: four advisory audits launched side by side, serial 30.9 min vs
# parallel 41.7 min, match-soundness 111 s -> 904 s, graph-gates and db-build killed at their budgets, CPU
# at 14% - concluding they contend on I/O, each re-parsing the same ~40 MB of JSON. Read the clock on
# 2026-08-22 instead of the conclusion:
#     07:24  31f4835b  the audits go side by side - through Invoke-Bounded, which at that hour launched
#                      every child with Start-Job
#     10:09  9825bb80  parallel REVERTED on the 30.9-vs-41.7 numbers
#     11:14  9a23e342  Invoke-Bounded is measured at 3.8 MINUTES per call for a 1-SECOND script, because a
#                      PS 5.1 job is a whole child PowerShell plus runspace construction plus session-state
#                      serialisation - and is rewritten to Start-Process, which is what it is today
# The verdict was recorded one hour before the machinery it was measured through was proven to cost minutes
# per call, and was never re-measured afterwards. So it is not evidence, and PLAN-use-the-cores phase 1
# proceeds - through fanout-lib.ps1, over Start-Process children held by runspace threads, never Start-Job.
# WHAT THE OLD NOTE STILL LEAVES STANDING is an untested HYPOTHESIS: that these audits are I/O- and
# memory-bound rather than CPU-bound. That is exactly why -Sequential exists and why the fan-out logs its
# own wall time. If a future run shows the fan-out losing, the honest response is to post the two numbers
# here, not to delete the flag.
# WHAT ACTUALLY BOUGHT THE FIRST BIG WIN is the ship/inspect split further down - the board now publishes
# before any of these runs at all, so their cost no longer sits between a price and a shopper.
# THE TIMEOUT STAYS, and it is the half that earned its keep (it caught three real hangs). Every child here
# used to be synchronous and unbounded: on 2026-08-14
# audit-coverage-gaps sat in a ReDoS for 11 hours and the board never published; the two Python steps
# (the GPU sweep, graph gates) could hang a CUDA init or a SQLite lock forever and "BLIND never blocks"
# covers only a non-zero EXIT, not a process that never exits. A job that outruns its budget is stopped,
# logged by name with its budget, and reported as the estate rc 3 (could-not-evaluate) so its caller takes
# the same BLIND/advisory path it already has for a failure. The chain keeps moving; the board still ships.
# point, and it starts and collects in one breath. They stay split because that is what makes the budget
# enforceable: you cannot kill a child you never named.
# ---- A BOUNDED CHILD, WITHOUT A POWERSHELL JOB (rewritten 2026-08-22) ---------------------------------
# THE FIRST VERSION OF THIS COST MINUTES PER CALL AND I PUT IT AROUND TEN STAGES. It ran each child
# through Start-Job, and a PS 5.1 job is not a thread - it launches an entire child PowerShell, builds a
# runspace and serialises session state across the boundary, per call. Measured: audit-graph-gates.ps1
# takes 1 SECOND called directly and sat at 3.8 MINUTES through the wrapper; a probe written to time the
# two side by side hung on the wrapper and had to be killed. That overhead is most of what the owner was
# looking at when he said the chain was too slow to promote - and it was mine, added the same morning.
#
# The timeout itself is worth keeping: it caught three genuine hangs today (a cold GPU sweep, a wedged
# graph import, a stalled SQLite build). So keep the guarantee, drop the machinery. Start-Process gives a
# real OS process with a real exit code and a WaitForExit(ms) that returns false on expiry - everything
# the job was doing, in-process, with no runspace and no serialisation.
#
# STILL TRUE, AND STILL LOAD-BEARING:
#   * the whole PROCESS TREE is killed on timeout - Stop-Process on the parent alone orphans a child that
#     keeps the GPU or a file lock (that is why Stop-ProcessTree exists);
#   * a timeout returns 3, the estate's could-not-evaluate code, so every caller's existing BLIND branch
#     fires. It must never read as a clean 0 - a killed audit that logs "clean" is the exact false green
#     this estate keeps rediscovering;
#   * stderr is captured BY FILE, never by 2>&1, because redirecting a native child's stderr under
#     EAP=Stop makes its first line a terminating throw (test-native-stderr-eap.ps1).
function Stop-ProcessTree([int]$procId) {
  foreach ($c in @(Get-CimInstance Win32_Process -Filter ("ParentProcessId = " + $procId) -ErrorAction SilentlyContinue)) { Stop-ProcessTree ([int]$c.ProcessId) }
  Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
}
function Invoke-Bounded([string]$Name, [string[]]$Arguments, [int]$TimeoutSec = 600) {
  # returns @{ ExitCode; Output[]; TimedOut; Elapsed }. ExitCode 3 = could-not-evaluate (timeout or launch failure).
  $so = [IO.Path]::GetTempFileName(); $se = [IO.Path]::GetTempFileName()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $p = $null
  try {
    $p = Start-Process -FilePath 'powershell' -ArgumentList $Arguments -PassThru -NoNewWindow `
                       -RedirectStandardOutput $so -RedirectStandardError $se
    $null = $p.Handle   # PS 5.1: without touching Handle first, ExitCode reads $null after the exit
  } catch {
    Remove-Item $so, $se -Force -ErrorAction SilentlyContinue
    Log ("$Name could not be launched: " + $_.Exception.Message)
    return [pscustomobject]@{ ExitCode = 3; Output = @("$Name could not be launched - BLIND, nothing proven"); TimedOut = $false; Elapsed = 0 }
  }
  $done = $p.WaitForExit($TimeoutSec * 1000)
  $sw.Stop(); $elapsed = [int]$sw.Elapsed.TotalSeconds
  if (-not $done) {
    try { Stop-ProcessTree ([int]$p.Id) } catch { }
    try { $null = $p.WaitForExit(5000) } catch { }
    Remove-Item $so, $se -Force -ErrorAction SilentlyContinue
    Log ("TIMED OUT: $Name exceeded its $TimeoutSec s budget and was stopped - reported as BLIND (could-not-evaluate); the board still ships")
    return [pscustomobject]@{ ExitCode = 3; Output = @("$Name TIMED OUT after $TimeoutSec s - BLIND, nothing proven"); TimedOut = $true; Elapsed = $elapsed }
  }
  $out = @()
  try { $out += @(Get-Content $so -ErrorAction SilentlyContinue) } catch { }
  try { $out += @(Get-Content $se -ErrorAction SilentlyContinue) } catch { }
  Remove-Item $so, $se -Force -ErrorAction SilentlyContinue
  $rc = try { [int]$p.ExitCode } catch { 3 }
  if ($elapsed -ge 30) { Log ("{0}: {1} s (rc={2})" -f $Name, $elapsed, $rc) }
  return [pscustomobject]@{ ExitCode = $rc; Output = @($out | ForEach-Object { [string]$_ }); TimedOut = $false; Elapsed = $elapsed }
}
