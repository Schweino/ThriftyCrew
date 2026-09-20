<#
  prepush-test-auditors.ps1 - before a push that touches one of grocery\test-auditors.ps1's inputs, run
  the test-auditors cases that push can reach, and refuse the push only when it adds a failing case that
  was not already failing.

  WHY IT EXISTS (2026-09-10, design\PLAN-zero-alert-days-2026-09-10.md Phase 5, build step 5). Three
  "a GUARD has gone blind" alerts in 20 days were self-inflicted by a triage session's own in-flight edits
  (2026-08-30, and twice on 2026-08-31), and queue item 2026-09-10-4ac6ae was a commit that broke
  test-auditors getting past a clean pre-push gate. ops\run-gates.ps1 cannot reach test-auditors: it is
  data-dependent (it reads the gitignored boards), and run-gates is hermetic by design. So the hook runs
  this AFTER run-gates passes.

  WHY IT SELECTS (ruling R19, Brad, 2026-09-10: keep it blocking, make it fast). The whole suite took 295 to
  338s on every guard-touching push, and 399 of the last 958 session commits touched one. Measured
  2026-09-10 before building anything: a plain run took 300.2s for 702 cases, the time is spread over about
  270 child processes, and no shared setup costs more than a few seconds, so running only what a push can
  reach is the lever (a pool would have needed the Tier 2/3 output-path collision work first).

  WHAT COUNTS AS A GUARD INPUT. Derived at push time from test-auditors.ps1's own source, never a hand
  list, so a case added there moves the set with it:
    1. test-auditors.ps1 itself.
    2. everything under the fixture root it assigns to $fix (grocery\regression-inputs\guard-fixtures).
    3. every path matching a glob it enumerates through Join-Path from $root, $fix or the repo root.
       Measured 2026-09-10: grocery\*.ps1, meal-prep\pipeline\*.ps1, .github\workflows\*.yml and
       guard-fixtures\recipe-floors\*.json.
    4. every code file (.ps1 .psm1 .py .yml .yaml .sh .js) whose file name it quotes, plus the dot-source
       closure of those scripts (computed only when a pushed script is not already matched).
    5. every other file whose name it quotes (commodities.json, known-wrong.json, stores.json ...).
  Rules 4 and 5 skip a path the daily bot owns (lib\bot-paths.ps1, Test-BotPathOwned) or one under an
  `out` or `public` directory. That exclusion is measured, not taste. Replaying the 996 commits since
  2026-08-21 against the tree of 2026-09-10: rules 1-4 alone match 499 of 8,333 tracked files and 3 of the
  35 daily bot commits. Adding every quoted data file made it 30 of 35, a six-minute suite on nearly every
  morning's data push, over outputs the chain rewrites daily (chain-verdict.json, price-history.json,
  product-urls.json). Excluding out\ and public\ alone still left 29 of 35. With the bot-owned rule as
  shipped: 0 of 35 daily bot commits and 399 of 958 session commits, over 485 tracked files before the
  dot-source closure (511 after it, by -ListInputs). A daily output changing is not a guard edit, and the
  hook's promise that data churn cannot fail an automated push is kept.

  WHICH CASES A PUSH RUNS (R19). test-auditors' cases sit in units, `if (Use-Unit '<id>' ...) { ... }`.
  Nothing about a unit's inputs is typed by hand except what its code cannot show:
    * A UNIT READS what its own code names: every quoted file name, every `Join-Path $fix '...'` fixture
      path, every glob, plus the same for any top-level helper function it calls. A script it RUNS brings
      the names quoted in that script's text too, recursively (comments stripped). A script it only READS
      (Get-Content, ReadAllText, Select-String, Test-Path) brings itself and nothing more, because a regex
      over a file's text cannot be changed by that file's dependencies. A unit that builds code at run time
      ([scriptblock]::Create, Invoke-Expression) has every script it names treated as RUN.
    * -Reads '<pattern>' declares what a child scans that no literal names (grocery/*.ps1, and ** for a
      recursive scan). -Always '<reason>' declares a unit whose reach cannot be written as a pattern; it
      runs on every guard-touching push.
    * A UNIT THAT READS A VARIABLE ANOTHER UNIT ASSIGNS RUNS WITH IT. A def-use pass walks back from each
      read that no assignment in the same unit dominates, adding every earlier unit that assigns the
      variable, and stops at the first one that assigns it unconditionally. A call to a function a unit
      defines inside its own body brings that unit. This is not a nicety: on 2026-09-10 the line-ending
      unit read $crSrc from another, and `$null -notmatch 'x'` is True, so a skipped provider would have
      printed a PASS rather than failed.
    * THE RUN IS FULL, NOT SELECTIVE, when the push touches the harness or a library every unit runs
      through (test-auditors.ps1, this file, lib\bot-paths.ps1, and the scripts the harness dot-sources or
      copies before its first unit), when a pushed guard input is named by no unit (which cases it reaches
      cannot be established), or when the unit model cannot be built (a parse error, a Use-Unit whose
      declaration is not literal). The harness is handed the units to SKIP, never the units to run, so a
      unit this file failed to see still runs.
    * A SELECTIVE RUN NEVER READS AS A PASS. It prints "ran N of T cases, selected by M pushed path(s)",
      the harness names itself SELECTIVE, and a clean one is reported as SELECTED CASES PASSED.

  HOW "ALREADY FAILING" IS DECIDED: a known-failures record in the SHARED git directory
  (<git-common-dir>\tc-test-auditors-known-failures.json), so every linked worktree reads the same one
  and nothing about it can be committed. Chosen over a second test-auditors run against origin/main
  because that run would need its own seeded checkout of the boards and would double a six-minute push.
    * ONLY THE DAILY CHAIN ADDS A CASE. grocery\check-ad-cycles.ps1 calls -Record with the output of its
      own test-auditors run, which already paged any failure it holds. A push-time FULL run may only
      CONFIRM or SHRINK the record, so a refused push can never launder its own failure by being retried.
      A SELECTIVE run writes nothing: it cannot tell a recorded case that passed from one it never ran,
      and re-dating the record over units it skipped would extend the age of cases nobody looked at.
      -Record refuses a selective run's output outright.
    * A RUN OVER IN-FLIGHT GUARD EDITS IS NOT A BASELINE. -Record refuses when any guard input differs
      from what the remote holds (an uncommitted change or an unpushed commit), because that run measured
      somebody's unpushed edit, which is exactly the self-inflicted class this exists to stop. Checked
      when the run is recorded, not when it started: an edit made and reverted during the run is missed.
    * AGE LIMIT 192h. The chain runs test-auditors every 7 days or the morning after its inputs move, so
      a correct record can legitimately be 7 days old; 24h of slack on top. First plausible value, no
      sweep. WHEN THE PRODUCER STOPS the record ages out and every failing case is treated as not
      established, so the push is REFUSED, loudly, never waved through.
    * A record that is missing, unreadable, or dated in the future is the same as a stale one.
    * A case is keyed by its FAIL message up to the first ": " or " - ", digits folded to #, so a count
      or a temp path in the tail does not make a known case look new.

  A CHECKOUT WITHOUT THE BOARDS IS REFUSED (exit 3). test-auditors skips its live-board cases there and
  would print a smaller, cheerful verdict, and a could-not-evaluate is never a pass in this estate.
  Background agents push from worktrees, and that is exactly the lane the self-inflicted alerts came
  from, so they are not exempt. The cost is small: .worktreeinclude copies the comparison boards into
  every worktree Claude Code creates, so only a hand-made bare checkout meets the refusal, and it
  names a repair that is not a bypass (push from the main checkout, or copy the boards in).

  `git push --no-verify` remains the one bypass. This file adds none: -Record by hand over your own
  unpushed change is refused by the in-flight rule above.

  Modes:
    -RefsFromStdin   the pre-push hook: pre-push's ref lines on stdin. Exit 0 allow, 1 refuse, 3 could
                     not evaluate (refuse).
    -PathsFile <f>   the same decision for a list of repo-relative paths instead of refs (measurement and
                     fixtures). Runs the suite; never writes the known-failures record.
    -Record -OutputFile <file> -ExitCode <rc>
                     the daily chain: record the failing cases of a completed test-auditors run.
    -ListInputs      print what the input derivation resolved over the tracked tree.
    -ListUnits       print the unit model; with -PathsFile, print what those paths would select, and stop.
    -SelfTest        frozen cases; discovered by ops\run-gates.ps1.

  SCOPE OF A CLEAN REPORT: UNSOUND. The input set is read from the text of test-auditors.ps1 and of the
  scripts its units run, so a file a child reaches through a computed path and no -Reads declares, or a
  data file named only by a script a unit merely reads, is not an input of that unit. Variables read only
  inside code a unit builds at run time are invisible to the def-use pass. It runs against the WORKING
  TREE, not the pushed commit, so another session's uncommitted edit can refuse (never pass) a push. Two
  failures whose messages share a key are one case to it, so a push that worsens an already-failing case
  is not refused. The record's in-flight check counts code, fixture and harness inputs only (rules 1-4),
  so a hand edit to a named rule file such as commodities.json that is uncommitted when the chain records
  can be recorded as already failing; counting those files would refuse nearly every morning's record.
#>
[CmdletBinding()]
param(
  [switch]$RefsFromStdin,
  [string]$PathsFile,
  [switch]$Record,
  [string]$OutputFile,
  [int]$ExitCode = -1,
  [switch]$ListInputs,
  [switch]$ListUnits,
  [switch]$SelfTest
)

$RepoRoot = Split-Path -Parent $PSScriptRoot
$script:GuardName = 'PREPUSH-TEST-AUDITORS'

# A LIBRARY THAT DOES NOT LOAD IS COULD-NOT-EVALUATE, NEVER A PRINTED WARNING (2026-09-11). Under 'Continue' a
# dot-source of a missing file prints "is not recognized" and the script carries on, and the hook sends this
# script's stderr to /dev/null, so nobody sees it. Measured that day: ops\test-prepush-hook.ps1 copied this file
# into its sandbox without lib\git-repo-env.ps1, the clear below never ran there, and all 26 of its cases passed.
# So every library loads under 'Stop' inside a try. Missing, unparseable, throwing or erroring while loading, it
# exits 3, which the hook refuses. try/catch alone catches the first three; 'Stop' is what catches the fourth.
$ErrorActionPreference = 'Stop'
try { . (Join-Path $RepoRoot 'lib\guard-contract.ps1') }
catch {
  # No completion marker: the contract that writes it is what failed, and exit 3 never carries one.
  "prepush-test-auditors: COULD NOT EVALUATE - lib\guard-contract.ps1 did not load ($($_.Exception.Message)). Not a pass."
  exit 3
}
$script:BotPathsLoaded = $false
$libRel = 'lib\bot-paths.ps1'
try {
  # The bot's ownership set. ABSENT, nothing is treated as bot-owned, which only makes the suite run MORE, so
  # absence is allowed. PRESENT and failing to load is refused like any other library.
  $bpLib = Join-Path $RepoRoot $libRel
  if (Test-Path -LiteralPath $bpLib) { . $bpLib; $script:BotPathsLoaded = $true }
  # The hook already clears these; clear them again so a caller that is not the hook cannot hand this
  # script's git calls, or the test-auditors it spawns, a linked worktree's GIT_DIR (lib\git-repo-env.ps1).
  $libRel = 'lib\git-repo-env.ps1'
  . (Join-Path $RepoRoot $libRel)
  Clear-TcGitRepoEnv
} catch {
  $ErrorActionPreference = 'Continue'
  "prepush-test-auditors: COULD NOT EVALUATE - $libRel did not load ($($_.Exception.Message)). Not a pass."
  Exit-Guard -Name $script:GuardName -Code 3 -Summary 'blind=lib-load'
}
$ErrorActionPreference = 'Continue'

$script:MaxAgeHours = 192        # see the header: 7-day chain cadence + 24h; first plausible value, no sweep
$script:TimeoutSeconds = 1200    # the same bound check-ad-cycles gives this suite
$script:MeasuredSeconds = 300    # a full test-auditors run, measured 2026-09-10 21:40 in the main checkout (300.2s, 702 cases)
$script:AuditorsRel = 'grocery/test-auditors.ps1'
$script:SelfRel = 'ops/prepush-test-auditors.ps1'
$script:CodeRx = '\.(ps1|psm1|py|yml|yaml|sh|js)$'
$script:FileLitRx = '^[\w.\-\\/*]+\.(ps1|psm1|py|yml|yaml|sh|js|json|jsonl|txt|md|csv|tsv|html)$'

function Get-CaseKey([string]$Line) {
  $t = ([string]$Line).Trim() -replace '^FAIL\s+', ''
  $cuts = @(@($t.IndexOf(': '), $t.IndexOf(' - ')) | Where-Object { $_ -gt 0 })
  if ($cuts.Count -gt 0) { $t = $t.Substring(0, ($cuts | Measure-Object -Minimum).Minimum) }
  $t = ($t -replace '\d+', '#') -replace '\s+', ' '
  if ($t.Length -gt 160) { $t = $t.Substring(0, 160) }
  return $t.Trim()
}

function Get-FailLines($Lines) {
  # LIVE-RED COUNTS AS A FAILING LINE HERE, AND DELIBERATELY (2026-09-20, queue 2026-09-19-ae9df2).
  # test-auditors split its live-board reds out of the FAIL tally so the DAILY CHAIN stops paging them as
  # "a GUARD has gone blind". That is a routing change for the alert, not a licence for a push: a live red
  # is still a red this gate must judge, and the whole EXPECTED-LIVE-RED pairing below keys on these lines
  # (the '# live-board-ruling-case audit=' marker sits on the very line that now calls Live()). Reading only
  # FAIL here would have silently retired that pairing and let a new live red through unexamined.
  return @(@($Lines) | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^\s{0,4}(FAIL|LIVE-RED)\s{2}' } | ForEach-Object { $_.Trim() })
}

function Get-AuditorInputs([string]$Text, [string]$SelfRel) {
  $selfDir = ''
  if ($SelfRel.Contains('/')) { $selfDir = $SelfRel.Substring(0, $SelfRel.LastIndexOf('/') + 1) }
  $code = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $data = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($m in [regex]::Matches($Text, "'([^'\r\n]{1,200})'")) {
    $l = $m.Groups[1].Value
    if ($l -notmatch $script:FileLitRx -or $l.Contains('*')) { continue }
    $b = ($l -split '[\\/]')[-1]
    if ($b -match $script:CodeRx) { [void]$code.Add($b) } else { [void]$data.Add($b) }
  }
  $fixRoot = ''
  $fm = [regex]::Match($Text, "\`$fix\s*=\s*Join-Path\s+\`$root\s+'([^']+)'")
  if ($fm.Success) { $fixRoot = $selfDir + $fm.Groups[1].Value.Replace('\', '/').Trim('/') + '/' }
  $globs = New-Object System.Collections.ArrayList
  foreach ($g in [regex]::Matches($Text, "Join-Path\s+(?<b>\`$root|\`$fix|\(Split-Path \`$root -Parent\))\s+'(?<l>[^']*\*[^']*)'")) {
    $bv = $g.Groups['b'].Value
    if ($bv -eq '$root') { $base = $selfDir } elseif ($bv -eq '$fix') { $base = $fixRoot } else { $base = '' }
    if ($bv -eq '$fix' -and -not $fixRoot) { continue }
    $pat = $base + $g.Groups['l'].Value.Replace('\', '/')
    if (@($globs | Where-Object { $_.pattern -eq $pat }).Count -gt 0) { continue }
    [void]$globs.Add([pscustomobject]@{ pattern = $pat; rx = ('^' + [regex]::Escape($pat).Replace('\*', '[^/]*') + '$') })
  }
  $owned = if ($script:BotPathsLoaded) { { param($p) Test-BotPathOwned -Path $p } } else { { param($p) $false } }
  return [pscustomobject]@{ self = $SelfRel; selfDir = $selfDir; fixRoot = $fixRoot; globs = $globs; code = $code; data = $data; botOwned = $owned }
}

# -CodeOnly (the record's in-flight check) drops rule 5. Measured 2026-09-10: grocery\sale-fallback-ownership.json
# is quoted by test-auditors, is not bot-owned, and is rewritten by the chain and left uncommitted most
# mornings, so counting named data files would refuse nearly every daily record and the record would never
# exist. The self-inflicted class is a guard, fixture or harness edit, and that is what the check keeps.
function Test-GuardInput([string]$Path, $Inputs, [bool]$CodeOnly = $false) {
  $p = $Path.Replace('\', '/')
  $b = ($p -split '/')[-1]
  if ([string]::Equals($p, $Inputs.self, [StringComparison]::OrdinalIgnoreCase)) { return 'test-auditors itself' }
  if ($Inputs.fixRoot -and $p.StartsWith($Inputs.fixRoot, [StringComparison]::OrdinalIgnoreCase)) { return ('under its fixture root ' + $Inputs.fixRoot) }
  foreach ($g in $Inputs.globs) { if ($p -match $g.rx) { return ('matches its glob ' + $g.pattern) } }
  $named = $Inputs.code.Contains($b) -or $Inputs.data.Contains($b)
  if (-not $named) { return '' }
  if (('/' + $p) -match '/(out|public)/' -or (& $Inputs.botOwned $p)) { return '' }
  if ($Inputs.code.Contains($b)) { return 'a script it names or dot-sources' }
  if ($CodeOnly) { return '' }
  return 'a file it names'
}

function Add-DotSourceClosure($Inputs, [scriptblock]$ReadScripts) {
  $queue = New-Object System.Collections.Queue
  foreach ($c in @($Inputs.code)) { $queue.Enqueue($c) }
  $added = 0
  while ($queue.Count -gt 0) {
    $c = [string]$queue.Dequeue()
    if ($c -notmatch '\.ps1$') { continue }
    foreach ($src in @(& $ReadScripts $c)) {
      if (-not $src) { continue }
      foreach ($m in [regex]::Matches([string]$src, '(?m)^\s*\.\s+[^\r\n]*?([\w.\-]+\.ps1)')) {
        $d = $m.Groups[1].Value
        if ($Inputs.code.Add($d)) { $queue.Enqueue($d); $added++ }
      }
    }
  }
  return $added
}

function Get-TrackedScriptReader([string]$Root) {
  $byBase = @{}
  foreach ($t in @(& git -C $Root -c core.quotepath=off ls-files 2>$null)) {
    $b = ([string]$t -split '/')[-1].ToLower()
    if ($b -notmatch '\.ps1$') { continue }
    if (-not $byBase.ContainsKey($b)) { $byBase[$b] = @() }
    $byBase[$b] += [string]$t
  }
  return { param($name) foreach ($p in @($byBase[([string]$name).ToLower()])) { if ($p) { $f = Join-Path $Root $p; if (Test-Path -LiteralPath $f) { [IO.File]::ReadAllText($f) } } } }.GetNewClosure()
}

# Which of these repo-relative paths are guard inputs? The dot-source closure is paid for only when a
# script is still unmatched after the cheap rules. Returns objects: .path and .why.
function Get-GuardHits([string[]]$Paths, $Inputs, [string]$Root, [bool]$CodeOnly = $false) {
  $hits = @(); $pending = @()
  foreach ($p in @($Paths | Where-Object { $_ })) {
    $why = Test-GuardInput $p $Inputs $CodeOnly
    if ($why) { $hits += [pscustomobject]@{ path = $p; why = $why } } elseif ($p -match '\.(ps1|psm1)$') { $pending += $p }
  }
  if ($hits.Count -eq 0 -and $pending.Count -gt 0) {
    $null = Add-DotSourceClosure $Inputs (Get-TrackedScriptReader $Root)
    foreach ($p in $pending) { $why = Test-GuardInput $p $Inputs $CodeOnly; if ($why) { $hits += [pscustomobject]@{ path = $p; why = $why } } }
  }
  return ,$hits
}

function Read-KnownFailures([string]$Path, [datetime]$NowUtc, [int]$MaxAgeHours) {
  $r = [pscustomobject]@{ state = 'missing'; keys = @(); lines = @(); recordedAt = ''; ageHours = -1.0; detail = ''; totalCases = -1 }
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { $r.detail = ('no record at ' + $Path); return $r }
  try {
    $j = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($null -eq $j -or $null -eq $j.failing -or -not [string]$j.recorded_at) { throw 'the record has no recorded_at or no failing list' }
    $at = [DateTimeOffset]::Parse([string]$j.recorded_at, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
    $keys = @(); $lines = @()
    foreach ($f in @($j.failing)) {
      if ($null -eq $f -or -not [string]$f.key) { throw 'a failing entry has no key' }
      $keys += [string]$f.key; $lines += [string]$f.line
    }
    $r.keys = $keys; $r.lines = $lines; $r.recordedAt = [string]$j.recorded_at
    if ($null -ne $j.total_cases -and [string]$j.total_cases -match '^\d+$') { $r.totalCases = [int]$j.total_cases }
    $r.ageHours = [math]::Round(($NowUtc - $at).TotalHours, 1)
    if ($r.ageHours -lt -1) { $r.state = 'unreadable'; $r.detail = ('recorded in the future: ' + $r.recordedAt); return $r }
    if ($r.ageHours -gt $MaxAgeHours) { $r.state = 'stale'; $r.detail = ('recorded ' + $r.recordedAt + ', ' + $r.ageHours + 'h old, limit ' + $MaxAgeHours + 'h'); return $r }
    $r.state = 'fresh'; $r.detail = ('recorded ' + $r.recordedAt + ', ' + $r.ageHours + 'h old')
  } catch { $r.state = 'unreadable'; $r.detail = $_.Exception.Message }
  return $r
}

function Write-KnownFailures([string]$Path, [object[]]$Entries, [string]$Writer, [int]$Rc, [datetime]$NowUtc, [int]$TotalCases = -1) {
  $obj = [ordered]@{ schema = 1; recorded_at = $NowUtc.ToString('o'); writer = $Writer; test_auditors_rc = $Rc; failing = @($Entries) }
  if ($TotalCases -ge 0) { $obj['total_cases'] = $TotalCases }
  $json = ConvertTo-Json -InputObject $obj -Depth 4
  $tmp = $Path + '.' + $PID + '.tmp'
  [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
  # Delete then move, not File.Replace: PowerShell hands Replace's null backup path over as '' and it throws.
  # The instant between the two reads as a MISSING record, which refuses rather than passes.
  if (Test-Path -LiteralPath $Path) { [IO.File]::Delete($Path) }
  [IO.File]::Move($tmp, $Path)
}

function ConvertTo-Entries([string[]]$FailLines) {
  $seen = @{}; $out = @()
  foreach ($l in @($FailLines | Where-Object { $_ })) {
    $k = Get-CaseKey $l
    if ($seen.ContainsKey($k)) { continue }
    $seen[$k] = $true
    $line = if ($l.Length -gt 400) { $l.Substring(0, 400) } else { $l }
    $out += [pscustomobject]@{ key = $k; line = $line }
  }
  return ,$out
}

# A push-time FULL run may CONFIRM or SHRINK the record, never add to it. $null means "do not write".
function Get-ConfirmedEntries([string[]]$FailLines, $Known) {
  $current = ConvertTo-Entries $FailLines
  if ($Known.state -eq 'fresh') { return ,@($current | Where-Object { $Known.keys -contains $_.key }) }
  if ($current.Count -eq 0) { return ,@() }
  return $null
}

function Get-PushVerdict([int]$Rc, [bool]$Complete, [string[]]$FailLines, $Known, [bool]$Selective = $false, [string]$RanNote = '') {
  $fails = @($FailLines | Where-Object { $_ })
  $v = [pscustomobject]@{ code = 3; verdict = 'COULD NOT EVALUATE'; detail = ''; newLines = @(); oldLines = @() }
  if (-not $Complete) { $v.detail = 'test-auditors did not end with its completion marker (it crashed, timed out, or was killed)'; return $v }
  # 4 IS A VERDICT SINCE 2026-09-20 (queue 2026-09-19-ae9df2): every watcher fired, a LIVE-TWIN case found a
  # bad cell on the live board. It is never a pass here - it carries LIVE-RED lines, which Get-FailLines
  # collects, so it lands in the same REFUSED/ALLOWED/EXPECTED-LIVE-RED machinery rc 2 always did.
  if (@(0, 1, 2, 4) -notcontains $Rc) { $v.detail = ('test-auditors exited ' + $Rc + ', which is not one of its verdicts (0, 1, 2, 4)'); return $v }
  if ((@(2, 4) -contains $Rc) -ne ($fails.Count -gt 0)) { $v.detail = ('test-auditors exited ' + $Rc + ' with ' + $fails.Count + ' FAIL/LIVE-RED line(s); the FAIL format this check reads no longer matches its exit code'); return $v }
  if ($fails.Count -eq 0) {
    $v.code = 0
    if ($Selective) { $v.verdict = 'SELECTED CASES PASSED'; $v.detail = ('the ' + $RanNote + ' exited ' + $Rc + ' with no failing case. The units this push cannot reach did not run, so this is not a pass for the suite') }
    else { $v.verdict = 'PASS'; $v.detail = ('test-auditors exited ' + $Rc + ' with no failing case') }
    return $v
  }
  if ($Known.state -ne 'fresh') {
    $v.code = 1; $v.verdict = 'REFUSED'; $v.newLines = $fails
    $v.detail = ('test-auditors has ' + $fails.Count + ' failing case(s) and the known-failures record is ' + $Known.state + ' (' + $Known.detail + '), so it cannot be established that any of them failed before this push')
    return $v
  }
  foreach ($l in $fails) { if ($Known.keys -contains (Get-CaseKey $l)) { $v.oldLines += $l } else { $v.newLines += $l } }
  if ($v.newLines.Count -gt 0) {
    $v.code = 1; $v.verdict = 'REFUSED'
    $v.detail = ('this push adds ' + $v.newLines.Count + ' failing test-auditors case(s) that the known-failures record (' + $Known.detail + ') does not hold')
  } else {
    $v.code = 0; $v.verdict = 'ALLOWED'
    $v.detail = ('test-auditors has ' + $fails.Count + ' failing case(s), every one already in the known-failures record (' + $Known.detail + '); this push added none. That is not a pass' + $(if ($Selective) { ', and only the ' + $RanNote + ' ran' } else { '' }))
  }
  return $v
}

# The harness's completion line, parsed: case tallies and whether it ran selectively.
function Get-HarnessSummary($Lines) {
  $s = [pscustomobject]@{ found = $false; cases = -1; selective = $false; unitsRan = -1; unitsSkipped = -1 }
  foreach ($l in @($Lines)) {
    # live= is OPTIONAL in this pattern (2026-09-20, queue 2026-09-19-ae9df2). The harness added a third
    # tally to its marker; a required token would have made every run read found=$false and cases=-1, which
    # is a could-not-evaluate wearing a pass's clothes. An older marker with no live= still parses, and the
    # case total picks the new tally up so a live red is never counted out of the suite.
    $m = [regex]::Match([string]$l, '^TEST-AUDITORS-COMPLETE\s+pass=(\d+)\s+failed=(\d+)(?:\s+live=(\d+))?\s+hygiene=(\d+)\s+skipped=(\d+)(.*)$')
    if (-not $m.Success) { continue }
    $s.found = $true
    $liveN = 0; if ($m.Groups[3].Success) { $liveN = [int]$m.Groups[3].Value }
    $s.cases = [int]$m.Groups[1].Value + [int]$m.Groups[2].Value + $liveN + [int]$m.Groups[4].Value + [int]$m.Groups[5].Value
    $tail = $m.Groups[6].Value
    $s.selective = ($tail -match '(^|\s)selective=1(\s|$)')
    $mr = [regex]::Match($tail, 'units_ran=(\d+)'); if ($mr.Success) { $s.unitsRan = [int]$mr.Groups[1].Value }
    $ms = [regex]::Match($tail, 'units_skipped=(\d+)'); if ($ms.Success) { $s.unitsSkipped = [int]$ms.Groups[1].Value }
  }
  return $s
}

# ONE CHILD RUN, its stdout and stderr redirected to <Stem>.out and <Stem>.err. A function so the self-test
# drives the same launch and the same file handling the hook does, not a copy of them.
function Invoke-TaChild([string]$ScriptPath, [string[]]$ExtraArgs, [string]$Stem, [int]$TimeoutSeconds) {
  $r = [pscustomobject]@{ rc = 124; lines = @(); outFile = ($Stem + '.out'); errFile = ($Stem + '.err'); secs = 0; startError = '' }
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $ScriptPath + '"'))
  if ($ExtraArgs) { $argList += $ExtraArgs }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WorkingDirectory $RepoRoot -NoNewWindow -PassThru -RedirectStandardOutput $r.outFile -RedirectStandardError $r.errFile
    $null = $proc.Handle
    if ($proc.WaitForExit($TimeoutSeconds * 1000)) { $proc.WaitForExit(); $r.rc = $proc.ExitCode }
    else { $null = & taskkill.exe /PID $proc.Id /T /F 2>$null }
  } catch { $r.startError = $_.Exception.Message }
  $sw.Stop(); $r.secs = [int]$sw.Elapsed.TotalSeconds
  if (Test-Path -LiteralPath $r.outFile) { $r.lines = @([IO.File]::ReadAllLines($r.outFile)) }
  return $r
}

# WHAT A CHILD'S TWO FILES BECOME ONCE THE VERDICT IS KNOWN (2026-09-11): both removed on a pass, both kept and
# named on anything else. stderr used to be removed unconditionally, before the verdict existed. So a
# test-auditors that died at startup, printing nothing to stdout and its cause to stderr alone, was refused as
# COULD NOT EVALUATE with an EMPTY .out kept and the one file that said why already deleted. Observed on a push
# from worktree priceless-lichterman-f9ee7f at about 12:56 that day, after run-gates passed 353 of 353; the
# same suite started by hand passed startup, so the cause was never recovered.
function Complete-TaChildFiles($Run, [int]$Code, [int]$HeadLines = 5) {
  if ($Code -eq 0) {
    Remove-Item -LiteralPath $Run.outFile -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Run.errFile -ErrorAction SilentlyContinue
    return
  }
  $out = @($Run.lines | Where-Object { ([string]$_).Trim() })
  if ($Code -eq 3) { 'prepush-test-auditors: last lines test-auditors printed: ' + $(if ($out.Count -gt 0) { @($out | Select-Object -Last 3) -join ' | ' } else { '(none, its stdout is empty)' }) }
  if (Test-Path -LiteralPath $Run.errFile) {
    $err = @([IO.File]::ReadAllLines($Run.errFile) | Where-Object { $_.Trim() })
    if ($err.Count -gt 0) {
      $show = [Math]::Min($HeadLines, $err.Count)
      "prepush-test-auditors: test-auditors (rc=$($Run.rc)) wrote $($err.Count) line(s) to stderr, kept at $($Run.errFile); the first $show"
      foreach ($l in $err[0..($show - 1)]) { '  stderr | ' + $(if ($l.Length -gt 300) { $l.Substring(0, 300) + '...' } else { $l }) }
    } else {
      "prepush-test-auditors: test-auditors (rc=$($Run.rc)) wrote nothing to stderr; the empty file is kept at $($Run.errFile)"
    }
  } else {
    "prepush-test-auditors: test-auditors left no stderr file at $($Run.errFile)" + $(if ($Run.startError) { " (it could not be started: $($Run.startError))" } else { '' })
  }
  "prepush-test-auditors: the full test-auditors output is kept at $($Run.outFile)"
}

# HOW test-auditors DECIDES IT HAS A BOARD, read from its own $HasBoard assignment (and its -or
# continuation lines) so this check and the harness cannot drift into two copies of one rule.
function Get-BoardPatterns([string]$Text, [string]$SelfRel) {
  $selfDir = ''
  if ($SelfRel.Contains('/')) { $selfDir = $SelfRel.Substring(0, $SelfRel.LastIndexOf('/') + 1) }
  $lines = $Text -split "`r?`n"
  $k = -1
  for ($j = 0; $j -lt $lines.Count; $j++) { if ($lines[$j] -match '^\s*\$HasBoard\s*=') { $k = $j; break } }
  $out = @()
  if ($k -lt 0) { return ,$out }
  $seg = $lines[$k]
  while ($lines[$k].TrimEnd().EndsWith('-or') -and ($k + 1) -lt $lines.Count) { $k++; $seg += "`n" + $lines[$k] }
  foreach ($m in [regex]::Matches($seg, "Join-Path\s+\`$root\s+'([^']+)'")) { $out += ($selfDir + $m.Groups[1].Value.Replace('\', '/')) }
  return ,$out
}

function Test-HasBoard([string]$Root, [string[]]$Patterns) {
  foreach ($p in @($Patterns | Where-Object { $_ })) {
    $full = Join-Path $Root ($p.Replace('/', '\'))
    if ($p.Contains('*')) { if (@(Get-ChildItem $full -ErrorAction SilentlyContinue).Count -gt 0) { return $true } }
    elseif (Test-Path -LiteralPath $full) { return $true }
  }
  return $false
}

function Get-RecordPath([string]$Root) {
  $common = (@(& git -C $Root rev-parse --path-format=absolute --git-common-dir 2>$null) -join '').Trim()
  if ($LASTEXITCODE -ne 0 -or -not $common) { return '' }
  return (Join-Path $common 'tc-test-auditors-known-failures.json')
}

# ============================================================================================ PASS REUSE
# A RETRY AFTER A REBASE THAT MOVED NO INPUT REUSES THE PASS INSTEAD OF PAYING THE WHOLE SUITE AGAIN (2026-09-18,
# queue discovered:push-livelock-2026-09-18). git fixes a push's expected remote sha when it connects; the hook then
# runs run-gates and this check, and takes the machine-wide push lock only AFTER both (Brad, 2026-09-12). run-gates
# reuses a self-test's result by input key after a rebase (lib\gate-input-key.ps1), so its re-gate is cheap. This
# check had no such reuse: every retry of a push touching a test-auditors input paid a full ~7 minute run, any landing
# by another session in those minutes doomed it, and the longest push starved. Measured 2026-09-18 on the money lane's
# three commits: five consecutive pushes rejected "cannot lock ref", the last two after test-auditors PASS 721/0 in 436s.
# THE KEY is SHA-256 over this checkout's root and, for every tracked file that is a test-auditors input (the derivation
# above, after the dot-source closure), this script itself and every tracked lib\*.ps1 (test-auditors copies the whole
# lib into its run root, a spelling the derivation cannot read): the index blob id, or the working-tree bytes' hash
# when git status lists the path. Plus name, length and mtime of every board file the board test matches, because the
# boards are gitignored and test-auditors reads them. So a rebase that brought in only non-input files leaves the key
# unchanged, and any moved input, harness byte or board changes it.
# FAIL CLOSED: a missing, unreadable, wrong-schema, mismatched, too-old or narrower (selective where this push needs
# more) record is a full run, never a pass. Only a PASS is reused: the stored verdict is re-judged against the CURRENT
# known-failures record, and anything but exit 0 runs the suite. A real run that is not a pass withdraws the record.
# The key is taken again after the run and a pass is recorded only if nothing moved under it.
# SCOPE: inherits the derivation's unsoundness (a file a unit reaches through a computed path is not keyed), and an
# ignored non-board file test-auditors reads is not keyed; the age bound caps how long either can matter.
$script:PassMaxAgeHours = 6   # first plausible value, no sweep: a retry follows its run by minutes; the key, not the clock, makes a reuse safe

function Get-PassRecordPath([string]$Root) {
  $rp = Get-RecordPath $Root
  if (-not $rp) { return '' }
  $sha = [Security.Cryptography.SHA256]::Create()
  $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(([IO.Path]::GetFullPath($Root)).TrimEnd('\').ToLowerInvariant()))
  $h = -join ($bytes[0..5] | ForEach-Object { $_.ToString('x2') })
  return (Join-Path (Split-Path -Parent $rp) ('tc-test-auditors-pass-' + $h + '.json'))
}

function Get-TaInputKey([string]$Root, $Inputs, [string[]]$BoardPatterns) {
  $r = [pscustomobject]@{ ok = $false; key = ''; inputs = 0; dirty = 0; boards = 0; ms = 0; why = '' }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $ls = @(& git -C $Root -c core.quotepath=off ls-files -s 2>$null); $lsRc = $LASTEXITCODE
  if ($lsRc -ne 0 -or $ls.Count -eq 0) { $r.why = "git ls-files rc=$lsRc listed $($ls.Count) file(s)"; return $r }
  $st = @(& git -C $Root -c core.quotepath=off status --porcelain --untracked-files=no 2>$null); $stRc = $LASTEXITCODE
  if ($stRc -ne 0) { $r.why = "git status rc=$stRc"; return $r }
  $dirty = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($s in $st) { $x = [string]$s; if ($x.Length -gt 3) { foreach ($part in ($x.Substring(3) -split ' -> ')) { [void]$dirty.Add($part.Trim().Trim('"')) } } }
  $null = Add-DotSourceClosure $Inputs (Get-TrackedScriptReader $Root)
  $sha = [Security.Cryptography.SHA256]::Create()
  $rows = New-Object 'System.Collections.Generic.List[string]'
  $rows.Add('root' + "`t" + ([IO.Path]::GetFullPath($Root)).TrimEnd('\').ToLowerInvariant())
  foreach ($l in $ls) {
    $t = [string]$l; $tab = $t.IndexOf("`t"); if ($tab -lt 0) { continue }
    $p = $t.Substring($tab + 1); $meta = @($t.Substring(0, $tab) -split ' ')
    $harness = [string]::Equals($p, $script:SelfRel, [StringComparison]::OrdinalIgnoreCase) -or ($p -match '^lib/[^/]+\.ps1$')
    if (-not $harness -and (Test-GuardInput $p $Inputs) -eq '') { continue }
    $id = $meta[1]
    if ($dirty.Contains($p)) {
      $f = Join-Path $Root $p.Replace('/', '\')
      $id = if (Test-Path -LiteralPath $f) { 'wt:' + (-join ($sha.ComputeHash([IO.File]::ReadAllBytes($f)) | ForEach-Object { $_.ToString('x2') })) } else { 'deleted' }
      $r.dirty++
    }
    $rows.Add($p + "`t" + $id); $r.inputs++
  }
  foreach ($bp in @($BoardPatterns | Where-Object { $_ })) {
    foreach ($fi in @(Get-ChildItem (Join-Path $Root $bp.Replace('/', '\')) -File -ErrorAction SilentlyContinue)) {
      $rows.Add('board:' + $bp + ':' + $fi.Name + "`t" + $fi.Length + ':' + $fi.LastWriteTimeUtc.Ticks); $r.boards++
    }
  }
  if ($r.inputs -eq 0) { $r.why = 'no tracked file is a test-auditors input, so there is nothing to key on'; return $r }
  $arr = $rows.ToArray(); [Array]::Sort($arr, [StringComparer]::Ordinal)
  $r.key = -join (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($arr -join "`n")))[0..7] | ForEach-Object { $_.ToString('x2') })
  $r.ok = $true; $sw.Stop(); $r.ms = [int]$sw.Elapsed.TotalMilliseconds
  return $r
}

# $Mode and $Selected are what THIS push needs. Returns .reuse, .why and the record.
function Read-TaPassRecord([string]$Path, [string]$Key, [datetime]$NowUtc, [double]$MaxAgeHours, [string]$Mode, [string[]]$Selected) {
  $r = [pscustomobject]@{ reuse = $false; why = ''; rec = $null }
  if (-not $Key) { $r.why = 'no input key'; return $r }
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { $r.why = ('no pass record at ' + $Path); return $r }
  try {
    $j = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($null -eq $j -or [string]$j.schema -ne '1' -or -not [string]$j.key -or -not [string]$j.recorded_at -or -not [string]$j.mode -or $null -eq $j.rc) { throw 'the pass record is missing a field' }
    if (-not [string]::Equals([string]$j.key, $Key, [StringComparison]::Ordinal)) { $r.why = ('an input moved since the recorded pass (recorded key ' + $j.key + ', now ' + $Key + ')'); return $r }
    $at = [DateTimeOffset]::Parse([string]$j.recorded_at, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
    $age = [math]::Round(($NowUtc - $at).TotalHours, 2)
    if ($age -lt -0.1 -or $age -gt $MaxAgeHours) { $r.why = ('the recorded pass is ' + $age + 'h old, limit ' + $MaxAgeHours + 'h'); return $r }
    if (@(0, 1, 2) -notcontains [int]$j.rc) { throw ('the recorded rc ' + $j.rc + ' is not a test-auditors verdict') }
    if ([string]$j.mode -eq 'selective') {
      if ($Mode -ne 'selective') { $r.why = 'the recorded pass ran selectively and this push needs a full run'; return $r }
      $have = @($j.selected | ForEach-Object { [string]$_ })
      $missing = @($Selected | Where-Object { $_ -and $have -notcontains $_ })
      if ($missing.Count -gt 0) { $r.why = ('this push selects ' + $missing.Count + ' unit(s) the recorded pass did not run, first ' + $missing[0]); return $r }
    } elseif ([string]$j.mode -ne 'full') { throw ('unknown mode ' + $j.mode) }
    $r.reuse = $true; $r.rec = $j; $r.why = ('a ' + $j.mode + ' run recorded ' + $j.recorded_at + ' (' + $age + 'h ago) over identical input content')
  } catch { $r.reuse = $false; $r.why = ('the pass record is unreadable: ' + $_.Exception.Message) }
  return $r
}

function Write-TaPassRecord([string]$Path, [string]$Key, [int]$Rc, [string[]]$FailLines, [string]$Mode, [string[]]$Selected, [int]$Cases, [datetime]$NowUtc) {
  $obj = [ordered]@{ schema = 1; key = $Key; recorded_at = $NowUtc.ToString('o'); rc = $Rc; mode = $Mode; selected = @($Selected | Where-Object { $_ }); cases = $Cases; fail_lines = @($FailLines | Where-Object { $_ }) }
  $json = ConvertTo-Json -InputObject $obj -Depth 4
  $tmp = $Path + '.' + $PID + '.tmp'
  [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
  # Delete then move, as Write-KnownFailures: the instant between reads as a MISSING record, which runs rather than passes.
  if (Test-Path -LiteralPath $Path) { [IO.File]::Delete($Path) }
  [IO.File]::Move($tmp, $Path)
}

function Format-ReuseLine([string]$Key, $Pass, $KeyInfo) {
  return ('prepush-test-auditors: REUSED key=' + $Key + ' - ' + $Pass.why + '; ' + $KeyInfo.inputs + ' input file(s) (' + $KeyInfo.dirty + ' uncommitted) and ' + $KeyInfo.boards + ' board file(s) hashed in ' + $KeyInfo.ms + 'ms, none moved since that pass, so test-auditors did not run again')
}

# ============================================================================================ UNITS
$script:TIf  = [System.Management.Automation.Language.IfStatementAst]
$script:TFn  = [System.Management.Automation.Language.FunctionDefinitionAst]
$script:TCmd = [System.Management.Automation.Language.CommandAst]
$script:TVar = [System.Management.Automation.Language.VariableExpressionAst]
$script:TAsg = [System.Management.Automation.Language.AssignmentStatementAst]
$script:TCnv = [System.Management.Automation.Language.ConvertExpressionAst]
$script:TArr = [System.Management.Automation.Language.ArrayLiteralAst]
$script:TFor = [System.Management.Automation.Language.ForEachStatementAst]
$script:TPar = [System.Management.Automation.Language.ParameterAst]
$script:TStr = [System.Management.Automation.Language.StringConstantExpressionAst]
$script:TExp = [System.Management.Automation.Language.ExpandableStringExpressionAst]
$script:TMem = [System.Management.Automation.Language.InvokeMemberExpressionAst]
$script:TStB = [System.Management.Automation.Language.StatementBlockAst]
$script:TNaB = [System.Management.Automation.Language.NamedBlockAst]
$script:TScB = [System.Management.Automation.Language.ScriptBlockAst]
$script:TSbx = [System.Management.Automation.Language.ScriptBlockExpressionAst]
$script:TTry = [System.Management.Automation.Language.TryStatementAst]
$script:CaseCmds = @('Ok', 'Bad', 'Skip', 'Hygiene')
# A literal that is only the TEXT of a message is not an input.
$script:MsgCmds = @('Ok', 'Bad', 'Skip', 'Hygiene', 'Write-Output', 'Write-Host', 'Write-Warning', 'Log', 'Say')
# A literal handed only to one of these is READ: its dependencies cannot change what the unit sees.
$script:ReadCmds = @('Get-Content', 'Select-String', 'Test-Path', 'Get-Item', 'Get-FileHash', 'Get-ItemProperty')
$script:ReadMembers = @('ReadAllText', 'ReadAllLines', 'ReadAllBytes', 'Exists', 'GetLastWriteTimeUtc', 'GetLastWriteTime')
# Automatic variables, and the harness's own tallies (a case's verdict does not depend on how many passed before it).
$script:NotDeps = @('_', 'args', 'input', 'true', 'false', 'null', 'lastexitcode', 'psscriptroot', 'pscommandpath', 'myinvocation', 'matches',
  'error', '?', 'pid', 'home', 'pwd', 'erroractionpreference', 'warningpreference', 'progresspreference', 'verbosepreference', 'confirmpreference',
  'debugpreference', 'informationpreference', 'psversiontable', 'this', 'foreach', 'switch', 'host', 'executioncontext', 'ofs', 'psitem',
  'psboundparameters', 'stacktrace', 'sender', 'event', 'eventargs', 'pass', 'failed', 'skipped', 'hygiene')
$script:WrapRx = "^Use-Unit\s+'(?<id>[a-z0-9][a-z0-9-]{0,80})'(?<rest>(?:\s+-Reads\s+'[^'\r\n]+'(?:\s*,\s*'[^'\r\n]+')*|\s+-Always\s+'(?:[^'\r\n]|'')+')*)\s*$"

function Get-VarName($v) {
  $vp = $v.VariablePath
  if ($vp.IsDriveQualified) { $d = ([string]$vp.DriveName).ToLower(); if (@('script', 'global', 'local', 'private') -notcontains $d) { return $null } }
  # UserPath, never VariablePath.UnqualifiedPath: under PS 5.1 that property is INTERNAL and reads as $null, so
  # the fallback below it always fired and the call was dead (2026-09-12). The scope prefix is stripped on the
  # line below, which is why removing it changes nothing here. lib\selftest-lib.ps1 makes the same refusal.
  $up = [string]$vp.UserPath
  if (-not $up) { return $null }
  $n = $up.ToLower(); if ($n.Contains(':')) { $n = $n.Substring($n.LastIndexOf(':') + 1) }
  if ($script:NotDeps -contains $n) { return $null }
  return $n
}

function Get-BlockOf($Node) {
  $p = $Node.Parent
  while ($p -and -not ($p -is $script:TStB -or $p -is $script:TNaB -or $p -is $script:TScB)) { $p = $p.Parent }
  return $p
}

# Everything the def-use pass and the input derivation need from a set of statement blocks.
function Get-Facts([object[]]$Roots) {
  $f = [pscustomobject]@{ assigns = @{}; any = @{}; top = @{}; reads = New-Object System.Collections.ArrayList; calls = New-Object System.Collections.ArrayList
                          leaked = @{}; lits = New-Object System.Collections.ArrayList; dynamic = $false; text = ''; cases = 0 }
  $rootSet = New-Object 'System.Collections.Generic.HashSet[object]'
  foreach ($r in $Roots) { [void]$rootSet.Add($r) }
  for ($ri = 0; $ri -lt $Roots.Count; $ri++) {
    $root = $Roots[$ri]
    $f.text += $root.Extent.Text + "`n"
    $targets = New-Object 'System.Collections.Generic.HashSet[int]'
    $nodes = $root.FindAll({ param($x) $true }, $true)
    foreach ($n in $nodes) {
      if ($n -is $script:TAsg) {
        $lhs = $n.Left; $tv = @()
        if ($lhs -is $script:TVar) { $tv += $lhs } elseif ($lhs -is $script:TCnv -and $lhs.Child -is $script:TVar) { $tv += $lhs.Child } elseif ($lhs -is $script:TArr) { $tv += @($lhs.Elements | Where-Object { $_ -is $script:TVar }) }
        foreach ($t in $tv) {
          [void]$targets.Add($t.Extent.StartOffset)
          $nm = Get-VarName $t; if (-not $nm) { continue }
          if ([string]$n.Operator -ne 'Equals') { [void]$f.reads.Add(@($nm, $n, $ri)) }
          $blk = Get-BlockOf $n; $isTop = $rootSet.Contains($blk)
          if (-not $f.assigns.ContainsKey($nm)) { $f.assigns[$nm] = New-Object System.Collections.ArrayList }
          [void]$f.assigns[$nm].Add(@($blk, $n.Extent.EndOffset, $ri, $isTop)); $f.any[$nm] = $true; if ($isTop) { $f.top[$nm] = $true }
          # A TRY WITH NO CATCH lets no exception past, so an assignment at the top of its body is still in force
          # after the try. Measured 2026-09-10: without this, Get-Early's `try { $out = ... } finally { }` made
          # every unit that harvests an early child "need" the first unit that assigns a $out.
          $tb = $blk
          while ($tb -and $tb.Parent -is $script:TTry -and [object]::ReferenceEquals($tb.Parent.Body, $tb) -and $tb.Parent.CatchClauses.Count -eq 0) {
            $outer = Get-BlockOf $tb.Parent; if (-not $outer) { break }
            $oTop = $rootSet.Contains($outer)
            [void]$f.assigns[$nm].Add(@($outer, $n.Extent.EndOffset, $ri, $oTop)); if ($oTop) { $f.top[$nm] = $true }
            $tb = $outer
          }
        }
      } elseif ($n -is $script:TFor) {
        [void]$targets.Add($n.Variable.Extent.StartOffset)
        $nm = Get-VarName $n.Variable
        if ($nm) { if (-not $f.assigns.ContainsKey($nm)) { $f.assigns[$nm] = New-Object System.Collections.ArrayList }; [void]$f.assigns[$nm].Add(@($n.Body, $n.Body.Extent.StartOffset, $ri, $false)); $f.any[$nm] = $true }
      } elseif ($n -is $script:TPar) {
        [void]$targets.Add($n.Name.Extent.StartOffset)
        $nm = Get-VarName $n.Name
        if ($nm) { $sb = $n.Parent; while ($sb -and -not ($sb -is $script:TScB)) { $sb = $sb.Parent }; if (-not $f.assigns.ContainsKey($nm)) { $f.assigns[$nm] = New-Object System.Collections.ArrayList }; [void]$f.assigns[$nm].Add(@($sb, $n.Extent.EndOffset, $ri, $false)) }
      } elseif ($n -is $script:TCmd) {
        $cn = $n.GetCommandName()
        if ($cn) { [void]$f.calls.Add(@($cn, $n, $ri)); if ($script:CaseCmds -contains $cn) { $f.cases++ }; if ($cn -eq 'Invoke-Expression' -or $cn -eq 'iex') { $f.dynamic = $true } }
      } elseif ($n -is $script:TFn) {
        # A function defined in a unit's own statements leaks to script scope; one inside another function
        # or a script block does not.
        $q = $n.Parent; $leaks = $true
        while ($q -and -not $rootSet.Contains($q)) { if ($q -is $script:TFn -or $q -is $script:TSbx) { $leaks = $false; break }; $q = $q.Parent }
        if ($leaks) { $f.leaked[$n.Name] = $true }
      } elseif ($n -is $script:TMem) {
        $mn = [string]$n.Member.Value
        if (($mn -eq 'Create' -and $n.Expression.Extent.Text -match 'scriptblock') -or $mn -eq 'NewScriptBlock' -or $mn -eq 'InvokeScript') { $f.dynamic = $true }
      }
      if ($n -is $script:TStr -or $n -is $script:TExp) { [void]$f.lits.Add($n) }
    }
    foreach ($n in $nodes) {
      if ($n -is $script:TVar -and -not $targets.Contains($n.Extent.StartOffset)) { $nm = Get-VarName $n; if ($nm) { [void]$f.reads.Add(@($nm, $n, $ri)) } }
    }
  }
  return $f
}

function Test-Dominated($Facts, [string]$Name, $Node, [int]$RootIndex) {
  if (-not $Facts.assigns.ContainsKey($Name)) { return $false }
  $anc = New-Object 'System.Collections.Generic.HashSet[object]'
  $p = $Node.Parent; while ($p) { [void]$anc.Add($p); $p = $p.Parent }
  $at = $Node.Extent.StartOffset
  foreach ($a in $Facts.assigns[$Name]) {
    if ($a[3] -and $a[2] -lt $RootIndex) { return $true }                 # an earlier wrapper of the same unit, top level
    if ($a[2] -eq $RootIndex -and $a[1] -le $at -and $anc.Contains($a[0])) { return $true }
  }
  return $false
}

function Get-LiteralClass($Node, [bool]$Dynamic) {
  $p = $Node.Parent
  while ($p) {
    if ($p -is $script:TCmd) {
      $cn = $p.GetCommandName()
      if ($cn -eq 'Join-Path' -or $cn -eq 'Split-Path') { $p = $p.Parent; continue }
      if ($cn -and $script:MsgCmds -contains $cn) { return 'message' }
      if ($cn -and $script:ReadCmds -contains $cn) { if ($Dynamic) { return 'run' }; return 'read' }
      return 'run'
    }
    if ($p -is $script:TMem -and $script:ReadMembers -contains [string]$p.Member.Value) { if ($Dynamic) { return 'run' }; return 'read' }
    if ($p -is $script:TStB -or $p -is $script:TNaB -or $p -is $script:TScB) { return 'run' }
    $p = $p.Parent
  }
  return 'run'
}

function ConvertTo-PatternRx([string]$Pattern) {
  $p = $Pattern.Replace('\', '/')
  if ($p.EndsWith('/')) { return ('^' + [regex]::Escape($p)) }
  return ('^' + [regex]::Escape($p).Replace('\*\*', '.*').Replace('\*', '[^/]*') + '$')
}

# 'dot' for a dot-source, 'def' for another definition statement (Add-Type, an alias, a module, a class), '' otherwise.
function Get-DefinitionKind($Stmt) {
  if ($Stmt -is [System.Management.Automation.Language.TypeDefinitionAst]) { return 'def' }
  if ($Stmt -is [System.Management.Automation.Language.PipelineAst] -and $Stmt.PipelineElements.Count -eq 1 -and $Stmt.PipelineElements[0] -is $script:TCmd) {
    $c = $Stmt.PipelineElements[0]
    if ([string]$c.InvocationOperator -eq 'Dot') { return 'dot' }
    $n = $c.GetCommandName(); if ($n -and @('Add-Type', 'Set-Alias', 'New-Alias', 'Import-Module') -contains $n) { return 'def' }
  }
  return ''
}

# The repo-relative path of `. (Join-Path $root|$PSScriptRoot|(Split-Path ... -Parent) 'x.ps1')`, or '' if not literal.
function Get-DotSourceRel($Stmt, [string]$SelfDir) {
  $mm = [regex]::Match($Stmt.Extent.Text, "^\.\s+\(Join-Path\s+(?<b>\`$root|\`$PSScriptRoot|\(Split-Path\s+(?:\`$root|\`$PSScriptRoot)\s+-Parent\))\s+'(?<l>[^'*]+\.ps1)'\)\s*$")
  if (-not $mm.Success) { return '' }
  $base = if ($mm.Groups['b'].Value -match 'Split-Path') { '' } else { $SelfDir }
  return ($base + $mm.Groups['l'].Value.Replace('\', '/'))
}

# Every name reachable from these scripts through the names their text quotes. The harness is never followed.
function Get-NameClosure([string[]]$Seeds, [scriptblock]$Reader, [hashtable]$Cache, [string[]]$NoFollow) {
  # ONE CHILD HOP, THEN LIBRARIES ONLY. A script a unit runs contributes every name its own text quotes (a
  # child it spawns, a file it reads); below that only dot-source edges are followed. Measured 2026-09-10:
  # following quoted names transitively reached nearly the whole tree, because almost every script quotes an
  # orchestrator (check-ad-cycles.ps1, alert-lib.ps1), and a guards.ps1 push selected 46 of 138 units.
  # THE HARNESS IS NEVER FOLLOWED: a push touching it is a full run anyway.
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($r in @($Seeds)) { if ($r) { [void]$seen.Add($r) } }
  foreach ($r in @($Seeds)) { if ($r -and $r -match '\.ps1$' -and @($NoFollow) -notcontains $r) { foreach ($d in (Get-ScriptNames $r $Reader $Cache)) { [void]$seen.Add($d) } } }
  $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $q = New-Object System.Collections.Queue
  foreach ($x in @($seen)) { $q.Enqueue($x) }
  while ($q.Count) {
    $c = [string]$q.Dequeue()
    if ($c -notmatch '\.ps1$' -or @($NoFollow) -contains $c -or -not $visited.Add($c)) { continue }
    $dk = 'dot:' + $c.ToLower()
    if (-not $Cache.ContainsKey($dk)) {
      $ds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
      foreach ($src in @(& $Reader $c)) { foreach ($mm in [regex]::Matches([string]$src, '(?m)^\s*\.\s+[^\r\n]*?([\w.\-]+\.ps1)')) { [void]$ds.Add($mm.Groups[1].Value) } }
      $Cache[$dk] = $ds
    }
    foreach ($d in $Cache[$dk]) { [void]$seen.Add($d); $q.Enqueue($d) }
  }
  return $seen
}

# The unit model of a test-auditors text. .ok false means: do not select, run everything.
function Get-UnitModel([string]$Text, [string]$SelfRel) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $m = [pscustomobject]@{ ok = $false; why = ''; entries = (New-Object System.Collections.ArrayList); byId = @{}; ids = @(); topFns = @{}
                          harness = @(); libs = @(); caseSites = 0; casesInUnits = 0; casesInFns = 0; casesOutside = 0; unitCount = 0; alwaysCount = 0; readsCount = 0; ms = 0 }
  $tokens = $null; $errs = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errs)
  if ($errs.Count) { $m.why = ('test-auditors does not parse (' + $errs.Count + ' error(s))'); return $m }
  $tries = @($ast.EndBlock.Statements | Where-Object { $_ -is $script:TTry })
  if ($tries.Count -ne 1) { $m.why = ('expected one top-level try block in test-auditors, found ' + $tries.Count); return $m }
  $selfDir = ''; if ($SelfRel.Contains('/')) { $selfDir = $SelfRel.Substring(0, $SelfRel.LastIndexOf('/') + 1) }
  $m.caseSites = @($ast.FindAll({ param($n) $n -is $script:TCmd -and $script:CaseCmds -contains $n.GetCommandName() }, $true)).Count
  $setupText = ''
  foreach ($s in @($ast.EndBlock.Statements)) { if (-not ($s -is $script:TTry) -and -not ($s -is $script:TFn)) { $setupText += $s.Extent.Text + "`n" } }
  $seenUnit = $false
  $cur = $null
  foreach ($s in @($tries[0].Body.Statements)) {
    if ($s -is $script:TFn) { $m.topFns[$s.Name] = $s; continue }
    # DEFINITIONS STAY OUTSIDE THE WRAPPERS and always run: a dot-source, Add-Type, an alias, a module. One
    # before the first unit is part of the harness; a dot-source BETWEEN units is a library whose functions
    # later units call, so a push reaching it selects every caller (Get-Selection), and one whose path is
    # not a literal makes the model unusable.
    $dsKind = Get-DefinitionKind $s
    if ($dsKind) {
      if (-not $seenUnit) { $setupText += $s.Extent.Text + "`n"; continue }
      if ($dsKind -eq 'dot') {
        $libRel = Get-DotSourceRel $s $selfDir
        if (-not $libRel) { $m.why = ('a dot-source between units whose path is not a literal, at line ' + $s.Extent.StartLineNumber + ': ' + $s.Extent.Text); return $m }
        $m.libs += [pscustomobject]@{ path = $libRel; unit = $(if ($null -ne $cur -and $cur.unit) { $cur.id } else { '' }); line = $s.Extent.StartLineNumber }
      }
      continue
    }
    $isWrap = $false
    if ($s -is $script:TIf) {
      $cond = $s.Clauses[0].Item1.Extent.Text
      if ($cond -match '^\s*Use-Unit\b') {
        $wm = [regex]::Match($cond, $script:WrapRx)
        if (-not $wm.Success -or $s.Clauses.Count -ne 1 -or $null -ne $s.ElseClause) { $m.why = ('a Use-Unit wrapper whose declaration cannot be read at line ' + $s.Extent.StartLineNumber + ': ' + $cond); return $m }
        $isWrap = $true; $seenUnit = $true
        $id = $wm.Groups['id'].Value
        if (-not $m.byId.ContainsKey($id)) {
          if ($null -ne $cur -and $cur.id -ne $id -and $m.byId.ContainsKey($id)) { $m.why = "unit $id is split around another unit"; return $m }
          $e = [pscustomobject]@{ id = $id; unit = $true; roots = (New-Object System.Collections.ArrayList); reads = @(); always = ''; line = $s.Extent.StartLineNumber; facts = $null; needs = @{}; run = @{}; read = @{}; named = @{}; fixPrefixes = @(); globs = @() }
          [void]$m.entries.Add($e); $m.byId[$id] = $e; $m.ids += $id
        } elseif ($cur.id -ne $id) { $m.why = "unit $id is split around another unit"; return $m }
        $e = $m.byId[$id]; $cur = $e
        foreach ($rm in [regex]::Matches($wm.Groups['rest'].Value, "-Reads\s+(?<v>'[^'\r\n]+'(?:\s*,\s*'[^'\r\n]+')*)")) { foreach ($q in [regex]::Matches($rm.Groups['v'].Value, "'([^']+)'")) { $e.reads += $q.Groups[1].Value } }
        $am = [regex]::Match($wm.Groups['rest'].Value, "-Always\s+'((?:[^'\r\n]|'')+)'"); if ($am.Success) { $e.always = $am.Groups[1].Value.Replace("''", "'") }
        [void]$e.roots.Add($s.Clauses[0].Item2)
      }
    }
    if (-not $isWrap) {
      if (-not $seenUnit) { $setupText += $s.Extent.Text + "`n"; continue }
      # code between units belongs to no unit: it always runs, and it can end a provider walk
      $e = [pscustomobject]@{ id = ''; unit = $false; roots = (New-Object System.Collections.ArrayList); reads = @(); always = 'outside any unit'; line = $s.Extent.StartLineNumber; facts = $null; needs = @{}; run = @{}; read = @{}; named = @{}; fixPrefixes = @(); globs = @() }
      $blk = New-Object System.Collections.ArrayList; [void]$e.roots.Add($s)
      [void]$m.entries.Add($e); $cur = $e
    }
  }
  if ($m.ids.Count -eq 0) { $m.why = 'test-auditors has no Use-Unit wrappers'; return $m }
  # the harness: this file's path, the auditors file, bot-paths, guard-contract, and every script the setup dot-sources or copies
  # GUARD-CONTRACT BY NAME (2026-09-11). It reached this set through a literal `Copy-Item ... 'lib\guard-contract.ps1'`
  # in the setup, which test-auditors replaced that day with a loop copying every lib\*.ps1 into a per-run root - a
  # spelling the regex below cannot read. Measured with -PathsFile: a push touching only lib/guard-contract.ps1 went
  # from a full run to a selective 71 of 141 units. It belongs here on its own merits: every run writes its completion
  # marker through it, outside every unit, and this file refuses a run without that marker.
  $h = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($x in @($SelfRel, $script:SelfRel, 'lib/bot-paths.ps1', 'lib/guard-contract.ps1')) { [void]$h.Add($x) }
  foreach ($hm in [regex]::Matches($setupText, "(?m)^\s*(?:\.\s+|Copy-Item\s+)\(Join-Path\s+(?<b>\`$root|\`$PSScriptRoot|\(Split-Path\s+(?:\`$root|\`$PSScriptRoot)\s+-Parent\))\s+'(?<l>[^']+\.ps1)'\)")) {
    $base = if ($hm.Groups['b'].Value -match 'Split-Path') { '' } else { $selfDir }
    [void]$h.Add($base + $hm.Groups['l'].Value.Replace('\', '/'))
  }
  $m.harness = @($h)
  # top-level helper functions: their free reads and literals are charged to the units that call them
  $fnFacts = @{}
  foreach ($fn in $m.topFns.Keys) {
    $fa = $m.topFns[$fn]
    $ff = Get-Facts @($fa.Body)
    $params = @{}
    foreach ($pp in @($fa.Parameters)) { if ($pp) { $pn = Get-VarName $pp.Name; if ($pn) { $params[$pn] = $true } } }
    $free = @{}
    foreach ($rd in $ff.reads) { if (-not $params.ContainsKey($rd[0]) -and -not (Test-Dominated $ff $rd[0] $rd[1] $rd[2])) { $free[$rd[0]] = $true } }
    $fnFacts[$fn] = [pscustomobject]@{ facts = $ff; free = $free; calls = @($ff.calls | ForEach-Object { $_[0] } | Where-Object { $m.topFns.ContainsKey($_) } | Sort-Object -Unique) }
    $m.casesInFns += $ff.cases
  }
  $leakHome = @{}
  foreach ($e in $m.entries) {
    $e.facts = Get-Facts @($e.roots)
    if ($e.unit) {
      # THE HARNESS'S OWN VERDICT MUST SIT OUTSIDE EVERY UNIT. Found 2026-09-10 on the first measured selective
      # run: the generator had wrapped the verdict, the completion marker and the exit into the last unit, so
      # a push that did not select that unit ended silently and was (correctly) refused as could-not-evaluate.
      $verdictCalls = @($e.facts.calls | Where-Object { $_[0] -eq 'Write-GuardComplete' -or $_[0] -eq 'Exit-Guard' })
      $topExits = @(foreach ($rb in $e.roots) { foreach ($st in @($rb.Statements)) { if ($st -is [System.Management.Automation.Language.ExitStatementAst]) { $st } } })
      if ($verdictCalls.Count -gt 0 -or $topExits.Count -gt 0) { $m.why = ('unit ' + $e.id + ' contains the harness''s own verdict (its completion marker or its exit), so skipping that unit would silence the whole run'); return $m } $m.casesInUnits += $e.facts.cases; $m.unitCount++; if ($e.always) { $m.alwaysCount++ }; if ($e.reads.Count) { $m.readsCount++ } } else { $m.casesOutside += $e.facts.cases }
    foreach ($ln in $e.facts.leaked.Keys) { if (-not $leakHome.ContainsKey($ln)) { $leakHome[$ln] = $e } }
  }
  # def-use: needs
  for ($k = 0; $k -lt $m.entries.Count; $k++) {
    $e = $m.entries[$k]; $free = @{}
    foreach ($rd in $e.facts.reads) { if (-not (Test-Dominated $e.facts $rd[0] $rd[1] $rd[2])) { $free[$rd[0]] = $true } }
    $fnSeen = @{}
    foreach ($c in $e.facts.calls) {
      $cn = $c[0]
      if ($fnFacts.ContainsKey($cn)) {
        $stack = New-Object System.Collections.Stack; $stack.Push($cn); $local = @{}
        while ($stack.Count) { $g = [string]$stack.Pop(); if ($local.ContainsKey($g)) { continue }; $local[$g] = $true; $fnSeen[$g] = $true; foreach ($v in $fnFacts[$g].free.Keys) { if (-not (Test-Dominated $e.facts $v $c[1] $c[2])) { $free[$v] = $true } }; foreach ($g2 in $fnFacts[$g].calls) { $stack.Push($g2) } }
      } elseif ($leakHome.ContainsKey($cn) -and -not [object]::ReferenceEquals($leakHome[$cn], $e) -and $leakHome[$cn].unit) { if (-not $e.needs.ContainsKey($leakHome[$cn].id)) { $e.needs[$leakHome[$cn].id] = ('function ' + $cn) } }
    }
    $cnSet = @{}
    foreach ($c in $e.facts.calls) { $cnSet[$c[0]] = $true }
    foreach ($g in $fnSeen.Keys) { foreach ($c in $fnFacts[$g].facts.calls) { $cnSet[$c[0]] = $true } }
    $e | Add-Member -NotePropertyName callNames -NotePropertyValue $cnSet -Force
    foreach ($v in $free.Keys) {
      for ($j = $k - 1; $j -ge 0; $j--) {
        $pe = $m.entries[$j]
        if ($pe.facts.any.ContainsKey($v)) { if ($pe.unit -and -not $e.needs.ContainsKey($pe.id)) { $e.needs[$pe.id] = ('$' + $v) }; if ($pe.facts.top.ContainsKey($v)) { break } }
      }
    }
    # inputs: literals of the unit and of every helper it calls
    $litSets = @(@{ lits = $e.facts.lits; dyn = $e.facts.dynamic })
    $texts = $e.facts.text
    foreach ($g in $fnSeen.Keys) { $litSets += @{ lits = $fnFacts[$g].facts.lits; dyn = ($e.facts.dynamic -or $fnFacts[$g].facts.dynamic) }; $texts += $fnFacts[$g].facts.text }
    foreach ($ls in $litSets) {
      foreach ($ln in $ls.lits) {
        $val = [string]$ln.Value
        if ($val -notmatch $script:FileLitRx -or $val.Contains('*')) { continue }
        $b = ($val -split '[\\/]')[-1]
        $cls = Get-LiteralClass $ln ([bool]$ls.dyn)
        if ($cls -eq 'message') { continue }
        $e.named[$b] = $true
        if ($b -match $script:CodeRx) { if ($cls -eq 'read') { $e.read[$b] = $true } else { $e.run[$b] = $true } }
      }
    }
    foreach ($b in @($e.read.Keys)) { if ($e.run.ContainsKey($b)) { $e.read.Remove($b) } }
    $e.fixPrefixes = @([regex]::Matches($texts, "Join-Path\s+\`$fix\s+'([^']+)'") | ForEach-Object { $_.Groups[1].Value.Replace('\', '/') } | Sort-Object -Unique)
    $e.globs = @([regex]::Matches($texts, "Join-Path\s+(\`$root|\`$fix|\(Split-Path \`$root -Parent\))\s+'([^']*\*[^']*)'") | ForEach-Object {
      $bv = $_.Groups[1].Value; $base = if ($bv -eq '$root') { $selfDir } elseif ($bv -eq '$fix') { '<fix>' } else { '' }
      $base + $_.Groups[2].Value.Replace('\', '/') } | Sort-Object -Unique)
  }
  $m.ms = [int]$sw.Elapsed.TotalMilliseconds
  $m.ok = $true
  return $m
}

# The names a script's text quotes (comments stripped), through a reader, memoized in $Cache.
function Get-ScriptNames([string]$Base, [scriptblock]$Reader, [hashtable]$Cache) {
  $k = $Base.ToLower()
  if ($Cache.ContainsKey($k)) { return $Cache[$k] }
  $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $Cache[$k] = $set
  foreach ($src in @(& $Reader $Base)) {
    if (-not $src) { continue }
    $t = [regex]::Replace([string]$src, '(?s)<#.*?#>', '')
    $t = [regex]::Replace($t, '(?m)^\s*#.*$', '')
    foreach ($mm in [regex]::Matches($t, "'([^'\r\n]{1,200})'|""([^""\r\n]{1,200})""")) {
      $v = if ($mm.Groups[1].Success) { $mm.Groups[1].Value } else { $mm.Groups[2].Value }
      if ($v -notmatch $script:FileLitRx -or $v.Contains('*')) { continue }
      [void]$set.Add(($v -split '[\\/]')[-1])
    }
  }
  return $set
}

# Every name reachable from the scripts a unit RUNS. The harness itself is never followed.
function Get-RunClosure($Entry, [scriptblock]$Reader, [hashtable]$Cache, [string[]]$NoFollow) {
  if ($null -ne $Entry.PSObject.Properties['closure'] -and $null -ne $Entry.closure) { return $Entry.closure }
  $seen = Get-NameClosure @($Entry.run.Keys) $Reader $Cache $NoFollow
  $Entry | Add-Member -NotePropertyName closure -NotePropertyValue $seen -Force
  return $seen
}

# The basenames a closure must never walk through: the harness and its libraries.
function Get-NoFollow($Model, $Inputs) {
  return @(@($Model.harness) + @($Inputs.self) | ForEach-Object { ([string]$_ -split '/')[-1] } | Sort-Object -Unique)
}

# Which units does one repo-relative path reach? Returns unit ids; the rule that matched each is kept in $script:AttribWhy.
$script:AttribWhy = @{}
function Get-UnitsForPath([string]$Path, $Model, $Inputs, [scriptblock]$Reader, [hashtable]$Cache) {
  $p = $Path.Replace('\', '/')
  $b = ($p -split '/')[-1]
  $nf = Get-NoFollow $Model $Inputs
  $out = @()
  foreach ($e in $Model.entries) {
    if (-not $e.unit) { continue }
    $why = ''
    foreach ($pat in $e.reads) { if ($p -match (ConvertTo-PatternRx $pat)) { $why = ('declares -Reads ' + $pat); break } }
    if (-not $why) { foreach ($g in $e.globs) { $gp = $g.Replace('<fix>', $Inputs.fixRoot); if ($p -match (ConvertTo-PatternRx $gp)) { $why = ('enumerates ' + $gp); break } } }
    if (-not $why -and $Inputs.fixRoot) { foreach ($fp in $e.fixPrefixes) { $full = $Inputs.fixRoot + $fp.TrimEnd('/'); if ([string]::Equals($p, $full, [StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($full + '/', [StringComparison]::OrdinalIgnoreCase)) { $why = ('names fixture ' + $fp); break } } }
    if (-not $why -and $e.named.ContainsKey($b)) { $why = ('names ' + $b) }
    if (-not $why -and $e.run.Count -gt 0) {
      $cl = Get-RunClosure $e $Reader $Cache $nf
      if ($cl.Contains($b)) { $via = @($e.run.Keys | Where-Object { (Get-NameClosure @($_) $Reader $Cache $nf).Contains($b) } | Select-Object -First 1); $why = ('runs ' + ($via -join '') + ', which reaches ' + $b) }
    }
    if ($why) { $out += $e.id; $script:AttribWhy[$e.id + ' <- ' + $p] = $why }
  }
  return ,$out
}

# The decision: none | full | selective, with the units to skip.
function Get-Selection([string[]]$Paths, [string[]]$GuardPaths, $Model, $Inputs, [scriptblock]$Reader, [hashtable]$Cache) {
  $s = [pscustomobject]@{ mode = 'full'; why = ''; selected = @(); skipped = @(); attributed = @{}; needed = @(); always = @() }
  if (-not $Model.ok) { $s.why = ('the unit model could not be built: ' + $Model.why); return $s }
  foreach ($p in @($Paths)) { foreach ($hp in $Model.harness) { if ([string]::Equals($p.Replace('\', '/'), $hp, [StringComparison]::OrdinalIgnoreCase)) { $s.why = ($p + ' is the harness or a library every unit runs through'); return $s } } }
  $sel = @{}
  $nf = Get-NoFollow $Model $Inputs
  foreach ($p in @($Paths | Where-Object { $_ })) {
    $ids = Get-UnitsForPath $p $Model $Inputs $Reader $Cache
    $pn = $p.Replace('\', '/'); $pb = ($pn -split '/')[-1]
    foreach ($lib in $Model.libs) {
      $libBase = ($lib.path -split '/')[-1]
      $reach = [string]::Equals($pn, $lib.path, [StringComparison]::OrdinalIgnoreCase)
      if (-not $reach) { $reach = (Get-NameClosure @($libBase) $Reader $Cache $nf).Contains($pb) }
      if ($reach) { $script:AttribWhy[('(library) <- ' + $p)] = ($lib.path + ' is dot-sourced between units') }
      if (-not $reach) { continue }
      $fnNames = @{}
      foreach ($src in @(& $Reader $libBase)) { foreach ($fm in [regex]::Matches([string]$src, '(?m)^\s*function\s+([\w-]+)')) { $fnNames[$fm.Groups[1].Value] = $true } }
      if ($fnNames.Count -eq 0) { $s.why = ($p + ' reaches ' + $lib.path + ', a library the harness dot-sources between units, and no function it defines could be read'); return $s }
      $callers = @(); if ($lib.unit) { $callers += $lib.unit }
      foreach ($e in $Model.entries) { if ($e.unit) { foreach ($fnn in $fnNames.Keys) { if ($e.callNames.ContainsKey($fnn)) { $callers += $e.id; break } } } }
      $ids = @(@($ids) + $callers | Sort-Object -Unique)
    }
    $s.attributed[$p] = $ids
    foreach ($id in $ids) { $sel[$id] = $true }
  }
  foreach ($gp in @($GuardPaths | Where-Object { $_ })) {
    if (@($s.attributed[$gp]).Count -eq 0) { $s.why = ($gp + ' is a test-auditors input that no unit names, so which cases it reaches cannot be established'); return $s }
  }
  foreach ($e in $Model.entries) { if ($e.unit -and $e.always) { if (-not $sel.ContainsKey($e.id)) { $s.always += $e.id }; $sel[$e.id] = $true } }
  $q = New-Object System.Collections.Queue; foreach ($id in @($sel.Keys)) { $q.Enqueue($id) }
  while ($q.Count) { $id = [string]$q.Dequeue(); foreach ($n in $Model.byId[$id].needs.Keys) { if (-not $sel.ContainsKey($n)) { $sel[$n] = $true; $s.needed += $n; $q.Enqueue($n) } } }
  $s.selected = @($Model.ids | Where-Object { $sel.ContainsKey($_) })
  $s.skipped = @($Model.ids | Where-Object { -not $sel.ContainsKey($_) })
  if ($s.skipped.Count -eq 0) { $s.why = 'every unit is reached'; return $s }
  $s.mode = 'selective'
  $s.why = ('' + $s.selected.Count + ' of ' + $Model.ids.Count + ' unit(s) reached (' + $s.always.Count + ' always-run, ' + $s.needed.Count + ' brought in by a variable or function another selected unit reads)')
  return $s
}

# ============================================================================================ EXPECTED LIVE RED
# A RULING PUSH IS RED ON PURPOSE, AND THIS CHECK USED TO MAKE THAT A DEADLOCK (Brad's ruling, 2026-09-19, "Teach the
# gate"). Two test-auditors cases read the LIVE board: the food-category live twin and the known-wrong live clean twin.
# A push that ADDS a ruling (a known-wrong.json entry, a category-excludes.json class) against a wrong product that is
# still on the board turns them red, and the estate says that red is intended: add-known-wrong's header says a new
# finding is EXPECTED to turn the gate red, and CLAUDE.md says a fresh correction is red on purpose until the next
# build. But the case was new, so this check refused the push, and the next build, which builds from origin/main,
# never saw the ruling: the loop could not end. Found on claude/gc-fence (green-chilli: a Burman aioli at Aldi and a
# Stokes canned stew at Walmart), refused with exactly those two cases while run-gates read pass=441 fail=0.
# THE RULING: accept a NEW failing live-board case ONLY when the push itself causes it by adding a ruling. Every other
# new failure is refused exactly as before.
# THE MECHANISM IS A PAIRED RUN, NOT A READING OF THE DIFF. For each such case, the SAME audit (the working tree's copy,
# which is what test-auditors ran) runs against the SAME live board in throwaway arms that differ only in the rule
# files the audit reads, enumerated from the audit's own `Join-Path $root '<x>.json'` literals:
#   arm 1  every rule file at the push's BASE (merge-base of the pushed tip and the remote ref, else origin/main)
#   arm 2  every rule file at the pushed TIP
#   arm 3  the RULING files at the tip and every other rule file at the base; run only when a non-ruling rule file
#          differs between base and tip, because otherwise it is arm 2 (added to the two-arm design for a stated
#          reason: arm 1 green and arm 2 red proves the push's rule files caused the red, not that a RULING did. A
#          removed food-class-allowlist exception or a categories.json relabel is not a ruling, and telling which
#          finding each produced by re-implementing the audits' matching here would be a second copy of their rules)
# A case is EXPECTED only when test-auditors itself saw exit 2 (or, since 2026-09-20, exit 4 - the LIVE-RED tier, whose
# lines Get-FailLines collects exactly as it collects FAIL lines), arm 1 exits 0, arm 2 exits 2 with at least one finding
# that names a (commodity, store, product), every arm-2 finding is absent from arm 1 AND present in arm 3, and the
# working tree's rule files are the tip's (the red came from the working tree), compared as git blob ids. An exit 3 in
# any arm is never accepted. Red on arm 1 too is a live defect this push did not cause: refused unless the record
# holds it.
# SCOPE: only the cases test-auditors marks `# live-board-ruling-case audit=<script>` on their Bad line, and only when
# the known-failures record is fresh and EVERY new failing case is one of them; a single other new case refuses the
# push with no paired run at all, byte for byte as before. The board is hardlinked into each arm (the same files, not a
# copy): the audits' board globs, comparison-*.json, recipe-board.json and regular\*-regular-*.json. coverage-lib.ps1 is
# deliberately NOT placed in an arm, so an arm writes no coverage record into the live out\.
# SCOPE OF AN ACCEPTANCE: it proves the push's ruling files flag exactly these products on this checkout's board. It
# does not prove the ruling is right, and the board keeps showing the product until the next build. A STALE board
# is judged as it stands: gc-fence's first dry run read its 08:12 seed, which still carried a product main's own
# rules already flag, and was refused as red at the base; re-seed a worktree before pushing a ruling.
$script:RulingFiles = @('known-wrong.json', 'category-excludes.json', 'commodities.json')
$script:LiveCaseRx = "Bad\s+\(\s*'((?:[^']|'')+)'.*#\s*live-board-ruling-case\s+audit=([\w.\-]+\.ps1)\s*$"
$script:ArmBoardGlobs = @('comparison-*.json', 'recipe-board.json', 'regular\*-regular-*.json')

# The live-board ruling cases test-auditors declares, as { prefix; audit }: the Bad message's leading literal, which a
# FAIL line starts with, and the audit script that case runs against the live board.
function Get-LiveRulingCases([string]$TaText) {
  $out = @()
  foreach ($ln in ($TaText -split "`r?`n")) {
    $m = [regex]::Match($ln, $script:LiveCaseRx)
    if ($m.Success) { $out += [pscustomobject]@{ prefix = $m.Groups[1].Value.Replace("''", "'"); audit = $m.Groups[2].Value } }
  }
  return ,$out
}

# The rule files an audit reads beside itself, read from its own `Join-Path $root '<x>.json'` literals.
function Get-AuditRuleFiles([string]$AuditText) {
  $set = New-Object 'System.Collections.Generic.List[string]'
  foreach ($m in [regex]::Matches($AuditText, "Join-Path\s+\`$root\s+'([\w.\-]+\.json)'", 'IgnoreCase')) {
    $n = $m.Groups[1].Value
    if (-not $set.Contains($n)) { $set.Add($n) }
  }
  return ,($set.ToArray())
}

# The (commodity, store, product) findings an audit printed: food-category's BUG lines, known-wrong's BLOCKED and
# BLOCKED-LINK lines, each as 'commodity|store|product'.
function Get-AuditFindings($Lines) {
  $out = New-Object 'System.Collections.Generic.List[string]'
  foreach ($l in @($Lines)) {
    $t = [string]$l
    foreach ($rx in @("^\s+BUG\s+(?<c>\S+)\s+\[(?<s>.*?)\s*\]\s+class=\S+\s+'(?<p>.*)'\s*$",
                      "^\s+BLOCKED\s+\[(?<s>[^\]]*)\]\s+(?<c>\S+)\s+'(?<p>.*)'\s.*per_unit=",
                      "^\s+BLOCKED-LINK\s+\[(?<s>[^\]]*)\]\s+(?<c>\S+) curated link points at '(?<p>.*)', which is adjudicated wrong\s*$")) {
      $m = [regex]::Match($t, $rx)
      # one finding per product: food-category prints a BUG line per CLASS, so a stew in a can is two lines, one product
      if ($m.Success) { $fk = $m.Groups['c'].Value + '|' + $m.Groups['s'].Value + '|' + $m.Groups['p'].Value; if (-not $out.Contains($fk)) { $out.Add($fk) }; break }
    }
  }
  return ,($out.ToArray())
}

# git cat-file into a file, byte for byte (PowerShell's own capture of native output re-encodes it). $false when the
# blob is absent at that revision or git fails.
function Save-GitBlob([string]$Root, [string]$Spec, [string]$Dest) {
  $null = & git -C $Root cat-file -e $Spec 2>$null
  if ($LASTEXITCODE -ne 0) { return $false }
  $psi = New-Object Diagnostics.ProcessStartInfo 'git'
  $psi.Arguments = ('-C "' + $Root + '" cat-file blob "' + $Spec + '"')
  $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  $p = [Diagnostics.Process]::Start($psi)
  $fs = [IO.File]::Create($Dest)
  try { $p.StandardOutput.BaseStream.CopyTo($fs) } finally { $fs.Close() }
  $null = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  if ($p.ExitCode -ne 0) { Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue; return $false }
  return $true
}

# The blob id at <rev>:<path>, or 'absent' when that revision has no such file.
function Get-BlobId([string]$Root, [string]$Spec) {
  $id = (@(& git -C $Root rev-parse --verify -q $Spec 2>$null) -join '').Trim()
  if ($LASTEXITCODE -ne 0 -or $id -notmatch '^[0-9a-f]{40}$') { return 'absent' }
  return $id
}

# The base a push's rule change is measured from: the merge-base of the tip and the remote ref's old sha when git has
# it, else of the tip and origin/main. '' when neither resolves.
function Get-PushBase([string]$Root, [string]$Tip, [string]$Remote) {
  $cands = @()
  if ($Remote -and $Remote -match '[^0]') { $cands += $Remote }
  $cands += 'refs/remotes/origin/main'
  foreach ($c in $cands) {
    $mb = (@(& git -C $Root merge-base $Tip $c 2>$null) -join '').Trim()
    if ($LASTEXITCODE -eq 0 -and $mb -match '^[0-9a-f]{40}$') { return $mb }
  }
  return ''
}

# One arm: <ArmDir>\grocery\<audit> (the working tree's copy), every lib\*.ps1, each rule file from the revision its
# spec names (absent there = absent here), and the live board hardlinked under grocery\out. Runs the audit with no
# arguments, exactly as the live case does. Returns rc, lines, findings; rc -1 when the arm could not be built.
function Invoke-AuditArm([string]$ArmDir, [string]$Root, [string]$AuditDirRel, [string]$Audit, [hashtable]$RuleRevs, [string]$LiveOut) {
  $r = [pscustomobject]@{ rc = -1; lines = @(); findings = @(); why = '' }
  try {
    $g = Join-Path $ArmDir $AuditDirRel.Replace('/', '\')
    $null = New-Item -ItemType Directory -Path (Join-Path $ArmDir 'lib'), $g, (Join-Path $g 'out\regular') -Force -ErrorAction Stop
    foreach ($lf in @(Get-ChildItem (Join-Path $Root 'lib\*.ps1') -File)) { Copy-Item -LiteralPath $lf.FullName -Destination (Join-Path $ArmDir 'lib') -ErrorAction Stop }
    Copy-Item -LiteralPath (Join-Path (Join-Path $Root $AuditDirRel.Replace('/', '\')) $Audit) -Destination $g -ErrorAction Stop
    foreach ($f in @($RuleRevs.Keys)) {
      $rev = [string]$RuleRevs[$f]
      if ($rev) { $null = Save-GitBlob $Root ($rev + ':' + $AuditDirRel.TrimEnd('/') + '/' + $f) (Join-Path $g $f) }
    }
    $linked = 0
    foreach ($glob in $script:ArmBoardGlobs) {
      $sub = Split-Path $glob -Parent
      foreach ($bf in @(Get-ChildItem (Join-Path $LiveOut $glob) -File -ErrorAction SilentlyContinue)) {
        $dst = if ($sub) { Join-Path (Join-Path $g 'out') (Join-Path $sub $bf.Name) } else { Join-Path (Join-Path $g 'out') $bf.Name }
        $null = New-Item -ItemType HardLink -Path $dst -Target $bf.FullName -ErrorAction Stop
        $linked++
      }
    }
    if ($linked -eq 0) { $r.why = ('no board file under ' + $LiveOut + ' matched ' + ($script:ArmBoardGlobs -join ', ')); return $r }
    $run = Invoke-TaChild (Join-Path $g $Audit) @() (Join-Path $ArmDir 'run') 300
    $r.rc = $run.rc; $r.lines = $run.lines; $r.findings = Get-AuditFindings $run.lines
    if ($run.startError) { $r.rc = -1; $r.why = ('the audit could not be started: ' + $run.startError) }
  } catch { $r.rc = -1; $r.why = ('the arm could not be built: ' + $_.Exception.Message) }
  return $r
}

# The decision. $V is Get-PushVerdict's result; returns { v; lines; accepted; findings; arms }. $V comes back
# untouched (the same object, no field changed, no line printed, no arm run) unless the verdict is a refusal over a
# fresh record whose every new line is a declared live-board ruling case.
function Resolve-ExpectedLiveReds($V, $Known, [object[]]$Cases, [string]$Root, [string]$AuditDirRel, [string]$Base, [string]$Tip, [string]$LiveOut) {
  $res = [pscustomobject]@{ v = $V; lines = @(); accepted = 0; findings = 0; arms = 0 }
  if ($V.code -ne 1 -or $Known.state -ne 'fresh' -or @($V.newLines).Count -eq 0 -or @($Cases).Count -eq 0) { return $res }
  $byLine = @{}
  foreach ($l in @($V.newLines)) {
    $t = ([string]$l) -replace '^FAIL\s+', ''
    $hit = $null
    foreach ($c in @($Cases)) { if ($t.StartsWith($c.prefix, [StringComparison]::Ordinal)) { $hit = $c; break } }
    if ($null -eq $hit) { return $res }   # a new failure that is not a live-board ruling case: refused exactly as before
    $byLine[$l] = $hit
  }
  if (-not $Base -or -not $Tip) {
    $res.lines += ('prepush-test-auditors: NOT EXPECTED - the new failing case(s) are live-board ruling cases, but the push''s base or tip could not be resolved (base=' + $Base + ' tip=' + $Tip + '), so no paired run could say whether this push caused them')
    return $res
  }
  $b8 = $Base.Substring(0, [Math]::Min(9, $Base.Length)); $t8 = $Tip.Substring(0, [Math]::Min(9, $Tip.Length))
  $scratch = Join-Path $env:TEMP ('tc-ptaer-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $verdicts = @{}   # audit -> { ok; why; findings }
  try {
    $null = New-Item -ItemType Directory -Path $scratch -ErrorAction Stop
    foreach ($audit in @($byLine.Values | ForEach-Object { $_.audit } | Sort-Object -Unique)) {
      $vd = [pscustomobject]@{ ok = $false; why = ''; findings = @() }
      $verdicts[$audit] = $vd
      $auditPath = Join-Path (Join-Path $Root $AuditDirRel.Replace('/', '\')) $audit
      if (-not (Test-Path -LiteralPath $auditPath)) { $vd.why = ($audit + ' is not in this checkout'); continue }
      $rules = Get-AuditRuleFiles ([IO.File]::ReadAllText($auditPath))
      if ($rules.Count -eq 0) { $vd.why = ('no rule file could be read from ' + $audit + '''s source'); continue }
      # The red test-auditors saw came from the working tree, so the tip's rule files must BE the working tree's. Compared
      # as BLOB IDS through git's own clean filter (hash-object), never as bytes: a fresh checkout is CRLF over LF blobs,
      # and a byte compare called gc-fence's untouched known-wrong.json an uncommitted edit (found on its dry run).
      $dirty = @(); $nonRulingMoved = $false
      foreach ($f in $rules) {
        $rel = $AuditDirRel.TrimEnd('/') + '/' + $f
        $tipId = Get-BlobId $Root ($Tip + ':' + $rel); $baseId = Get-BlobId $Root ($Base + ':' + $rel)
        $wtF = Join-Path (Join-Path $Root $AuditDirRel.Replace('/', '\')) $f
        $wtId = 'absent'
        if (Test-Path -LiteralPath $wtF) { $wtId = (@(& git -C $Root hash-object -- $rel 2>$null) -join '').Trim(); if ($LASTEXITCODE -ne 0 -or -not $wtId) { $wtId = 'unhashable' } }
        if (-not [string]::Equals($tipId, $wtId, [StringComparison]::Ordinal)) { $dirty += $f }
        if ($script:RulingFiles -notcontains $f -and -not [string]::Equals($tipId, $baseId, [StringComparison]::Ordinal)) { $nonRulingMoved = $true }
      }
      if ($dirty.Count -gt 0) { $vd.why = ('the working tree''s ' + ($dirty -join ', ') + ' differs from the pushed tip, so the red test-auditors saw is not the push''s'); continue }
      $revs1 = @{}; $revs2 = @{}; $revs3 = @{}
      foreach ($f in $rules) { $revs1[$f] = $Base; $revs2[$f] = $Tip; $revs3[$f] = $(if ($script:RulingFiles -contains $f) { $Tip } else { $Base }) }
      $a1 = Invoke-AuditArm (Join-Path $scratch ('a1-' + $audit)) $Root $AuditDirRel $audit $revs1 $LiveOut; $res.arms++
      $a2 = Invoke-AuditArm (Join-Path $scratch ('a2-' + $audit)) $Root $AuditDirRel $audit $revs2 $LiveOut; $res.arms++
      if ($a1.rc -lt 0 -or $a2.rc -lt 0) { $vd.why = ('an arm could not run: ' + $a1.why + $a2.why); continue }
      if ($a1.rc -eq 3 -or $a2.rc -eq 3) { $vd.why = ('the audit could not look (exit 3) at the base (arm 1 rc=' + $a1.rc + ') or the tip (arm 2 rc=' + $a2.rc + '); a could-not-look is never accepted'); continue }
      if ($a1.rc -ne 0) { $vd.why = ('it is red at the base ' + $b8 + ' too (arm 1 rc=' + $a1.rc + ', first finding ' + $(if ($a1.findings.Count) { $a1.findings[0] } else { 'none named' }) + '), so this push did not cause it: a live defect the known-failures record does not hold'); continue }
      if ($a2.rc -ne 2) { $vd.why = ('with the tip''s rule files the audit exits ' + $a2.rc + ', not 2, so the paired run does not reproduce the red test-auditors saw'); continue }
      if ($a2.findings.Count -eq 0) { $vd.why = 'arm 2 is red but names no (commodity, store, product), so nothing says what the ruling flags'; continue }
      $f3 = $a2.findings
      if ($nonRulingMoved) {
        $a3 = Invoke-AuditArm (Join-Path $scratch ('a3-' + $audit)) $Root $AuditDirRel $audit $revs3 $LiveOut; $res.arms++
        if ($a3.rc -lt 0 -or $a3.rc -eq 3) { $vd.why = ('the ruling-only arm could not look (rc=' + $a3.rc + ') ' + $a3.why); continue }
        $f3 = $a3.findings
      }
      $unexplained = @($a2.findings | Where-Object { ($a1.findings -contains $_) -or ($f3 -notcontains $_) })
      if ($unexplained.Count -gt 0) { $vd.why = ('' + $unexplained.Count + ' of ' + $a2.findings.Count + ' finding(s) are not flagged by this push''s ruling files alone (first: ' + $unexplained[0] + '), so something other than a ruling made the board red'); continue }
      $vd.ok = $true; $vd.findings = $a2.findings
    }
  } catch {
    # Anything thrown refuses every case: an audit whose arms did not finish is overwritten, not trusted.
    $thrown = ('the paired run threw: ' + $_.Exception.Message)
    foreach ($k in @($byLine.Values | ForEach-Object { $_.audit } | Sort-Object -Unique)) { $verdicts[$k] = [pscustomobject]@{ ok = $false; why = $thrown; findings = @() } }
  } finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
  $okLines = @(); $allOk = $true; $out = @()
  foreach ($l in @($V.newLines)) {
    $c = $byLine[$l]; $vd = $verdicts[$c.audit]; $key = Get-CaseKey $l
    $rcm = [regex]::Match((([string]$l) -replace '^FAIL\s+', '').Substring($c.prefix.Length), '^(\d+)\)')
    if ($null -ne $vd -and $vd.ok -and -not ($rcm.Success -and $rcm.Groups[1].Value -eq '2')) { $vd = [pscustomobject]@{ ok = $false; why = ('test-auditors saw this case exit ' + $(if ($rcm.Success) { $rcm.Groups[1].Value } else { 'an unreadable code' }) + ', not 2'); findings = @() } }
    if ($null -eq $vd -or -not $vd.ok) {
      $allOk = $false
      $out += ('  NOT EXPECTED          ' + $key + ': ' + $(if ($null -ne $vd) { $vd.why } else { 'no paired run' }))
      continue
    }
    $okLines += $l
    foreach ($fd in $vd.findings) {
      $p = $fd -split '\|', 3
      $out += ('  EXPECTED-LIVE-RED     ' + $key + ': [' + $p[1] + '] ' + $p[0] + ' ''' + $p[2] + ''' - this push adds the ruling that flags it (same audit, same live board: green with the rule files at ' + $b8 + ', red at ' + $t8 + '); the next board build clears it. Until that build the live board still shows this product.')
      $res.findings++
    }
  }
  $res.lines = $out
  if (-not $allOk) { return $res }
  $nv = [pscustomobject]@{ code = 0; verdict = 'ALLOWED'; detail = ''; newLines = @(); oldLines = @($V.oldLines); expectedLines = $okLines }
  $nv.detail = ('this push adds ' + $okLines.Count + ' failing live-board case(s), ' + $okLines.Count + ' accepted as expected (' + $res.findings + ' finding(s)): each is red only because this push adds the ruling that flags a product still on the live board, proven by a paired run of the same audit on the same board, green with the rule files at ' + $b8 + ' and red at ' + $t8 + '. That is not a pass: those cases stay red until the next board build' + $(if (@($V.oldLines).Count -gt 0) { ', and ' + @($V.oldLines).Count + ' other failing case(s) are already in the known-failures record' } else { '' }))
  $res.v = $nv; $res.accepted = $okLines.Count
  return $res
}

# ============================================================================================ SELF-TEST
if ($SelfTest) {
  $fails = @(); $ran = 0
  function Case([string]$Label, [string]$Name, [bool]$Ok, [string]$Detail = '') {
    $script:ran++
    if (-not $Ok) { $script:fails += "$Label $Name" }
    '  {0,-14} {1,-78} {2}' -f $Label, $Name, $(if ($Ok) { 'ok' } else { "FAIL $Detail" })
  }
  $fx = @'
$root = $PSScriptRoot
$fix  = Join-Path $root 'regression-inputs\guard-fixtures'
. (Join-Path $root 'native-lib.ps1')
$scan = @(Get-ChildItem (Join-Path $root '*.ps1')) + @(Get-ChildItem (Join-Path (Split-Path $root -Parent) 'modz\pipeline\*.ps1'))
$r = RunPS 'audit-pack-basis.ps1' @('-CompareFile', (Join-Path $fix 'packbasis-board.json'))
$quoted = @('rule-table.json', 'daily-ledger.json', 'out\daily-verdict.json')
$w = Get-Content (Join-Path (Split-Path $root -Parent) 'lib\json-io.ps1')
'@
  # SYNTHETIC MODULE NAMES (modx, modz) and synthetic file names, so this frozen fixture neither names a
  # live rulings file (audit-fixture-inputs) nor builds a path into a real module's internals
  # (audit-cross-module-reach). The bot's ownership set is injected for the same reason; the live wiring
  # is pinned below.
  $in = Get-AuditorInputs $fx 'modx/test-auditors.ps1'
  $in.botOwned = { param($p) $p -eq 'modx/daily-ledger.json' }
  Case 'MUST FIRE' 'a guard script in the directory test-auditors globs is an input' ((Test-GuardInput 'modx/guards.ps1' $in) -ne '')
  Case 'MUST FIRE' 'a new fixture under its fixture root is an input' ((Test-GuardInput 'modx/regression-inputs/guard-fixtures/new-case/board.json' $in) -ne '')
  Case 'MUST FIRE' 'a library it names by path is an input' ((Test-GuardInput 'lib/json-io.ps1' $in) -ne '')
  Case 'MUST FIRE' 'a rule file it names is an input' ((Test-GuardInput 'modx/rule-table.json' $in) -ne '')
  Case 'MUST FIRE' 'a script in a repo-rooted glob is an input' ((Test-GuardInput 'modz/pipeline/some-audit.ps1' $in) -ne '')
  Case 'MUST FIRE' 'test-auditors.ps1 itself is an input' ((Test-GuardInput 'modx/test-auditors.ps1' $in) -ne '')
  Case 'MUST NOT FIRE' 'a document outside every rule is not an input' ((Test-GuardInput 'notes/a-plan.md' $in) -eq '')
  Case 'MUST NOT FIRE' 'a daily output it names, under out\, is not an input' ((Test-GuardInput 'modx/out/daily-verdict.json' $in) -eq '')
  Case 'MUST NOT FIRE' 'a file it names that the daily bot owns is not an input' ((Test-GuardInput 'modx/daily-ledger.json' $in) -eq '')
  Case 'MUST NOT FIRE' 'a script one directory below a non-recursive glob is not an input' ((Test-GuardInput 'modx/sub/deeper-thing.ps1' $in) -eq '')
  Case 'MUST NOT FIRE' 'another module''s data is not an input' ((Test-GuardInput 'modz/db/candidate-pool.json' $in) -eq '')
  Case 'MUST NOT FIRE' 'for the record''s in-flight check, a named data file is not an edit in flight' ((Test-GuardInput 'modx/rule-table.json' $in $true) -eq '')
  Case 'CLEAN TWIN' 'for the record''s in-flight check, a guard script edit still is' ((Test-GuardInput 'modx/guards.ps1' $in $true) -ne '')
  $reader = { param($n) if ($n -eq 'audit-pack-basis.ps1') { ". (Join-Path `$PSScriptRoot 'pack-helper-lib.ps1')`n" } }
  $pre = Test-GuardInput 'modx/lib2/pack-helper-lib.ps1' $in
  $null = Add-DotSourceClosure $in $reader
  Case 'MUST FIRE' 'a library dot-sourced by a script test-auditors runs is an input once the closure is taken' `
    ($pre -eq '' -and (Test-GuardInput 'modx/lib2/pack-helper-lib.ps1' $in) -ne '') "before='$pre'"

  $hyA = 'FAIL  Hy-Vee tag/identity fixtures FAILED (rc=1) - either a price the till will not honour can publish again: FAIL  still pinned'
  $hyB = 'FAIL  Hy-Vee tag/identity fixtures FAILED (rc=3) - a different tail entirely, with C:\Temp\x-2ad40858'
  $newL = 'FAIL  guards lost OkUnlessBlind - a guard that examines zero rows can print ok again'
  Case 'MUST FIRE' 'one case keys the same when its exit code and tail differ' ((Get-CaseKey $hyA) -eq (Get-CaseKey $hyB)) ((Get-CaseKey $hyA) + ' vs ' + (Get-CaseKey $hyB))
  Case 'MUST NOT FIRE' 'two different cases do not share a key' ((Get-CaseKey $hyA) -ne (Get-CaseKey $newL))
  Case 'MUST FIRE' 'FAIL lines are read from indented harness output' ((Get-FailLines @('  PASS  a', "  FAIL  $($newL.Substring(6))", 'x FAIL  y')).Count -eq 1)

  $now = [datetime]::UtcNow
  $fresh = [pscustomobject]@{ state = 'fresh'; keys = @((Get-CaseKey $hyA)); lines = @($hyA); recordedAt = 'x'; ageHours = 2.0; detail = 'recorded x'; totalCases = 702 }
  $v = Get-PushVerdict 2 $true @($hyB) $fresh
  Case 'CLEAN TWIN' 'a failure already in the record allows an unrelated guard push and is still listed' ($v.code -eq 0 -and $v.oldLines.Count -eq 1) "code=$($v.code)"
  $v = Get-PushVerdict 2 $true @($hyB, $newL) $fresh
  Case 'MUST FIRE' 'a push that adds a failing case is refused and names that case' ($v.code -eq 1 -and ($v.newLines -join '|') -match 'OkUnlessBlind' -and $v.oldLines.Count -eq 1) "code=$($v.code)"
  $stale = [pscustomobject]@{ state = 'stale'; keys = @((Get-CaseKey $hyA)); lines = @(); recordedAt = 'x'; ageHours = 240.0; detail = '240h old'; totalCases = -1 }
  $v = Get-PushVerdict 2 $true @($hyB) $stale
  Case 'MUST FIRE' 'a stale record does not let even a recorded case through' ($v.code -eq 1) "code=$($v.code)"
  $unread = [pscustomobject]@{ state = 'unreadable'; keys = @(); lines = @(); recordedAt = ''; ageHours = -1.0; detail = 'bad json'; totalCases = -1 }
  $v = Get-PushVerdict 2 $true @($hyB) $unread
  Case 'MUST FIRE' 'an unreadable record refuses a push with any failing case' ($v.code -eq 1) "code=$($v.code)"
  $v = Get-PushVerdict 2 $false @($hyB) $fresh
  Case 'MUST FIRE' 'a run with no completion marker could not evaluate' ($v.code -eq 3) "code=$($v.code)"
  $v = Get-PushVerdict 2 $true @() $fresh
  Case 'MUST FIRE' 'exit 2 with no readable FAIL line could not evaluate' ($v.code -eq 3) "code=$($v.code)"
  $v = Get-PushVerdict 0 $true @() $unread
  Case 'CLEAN TWIN' 'a clean run still passes with no usable record' ($v.code -eq 0 -and $v.verdict -eq 'PASS') "code=$($v.code)"
  $v = Get-PushVerdict 0 $true @() $unread $true 'selected cases'
  Case 'MUST FIRE' 'a clean SELECTIVE run is allowed but never reads as a pass' ($v.code -eq 0 -and $v.verdict -ne 'PASS' -and $v.detail -match 'not a pass') "verdict=$($v.verdict)"

  $conf = Get-ConfirmedEntries @($newL) $fresh
  Case 'MUST FIRE' 'a push-time run never writes a case the record lacks' ($null -ne $conf -and @($conf | Where-Object { $_.key -eq (Get-CaseKey $newL) }).Count -eq 0)
  Case 'MUST FIRE' 'with no fresh record a push-time run with failures writes nothing' ($null -eq (Get-ConfirmedEntries @($hyA) $stale))
  $conf = Get-ConfirmedEntries @($hyB) $fresh
  Case 'CLEAN TWIN' 'a push-time run still confirms a case the record holds' ($null -ne $conf -and $conf.Count -eq 1)

  $selSum = Get-HarnessSummary @('x', 'TEST-AUDITORS-COMPLETE pass=40 failed=1 hygiene=0 skipped=2 selective=1 units_ran=6 units_skipped=140')
  Case 'MUST FIRE' 'the chain can tell a selective harness run from a full one (so -Record refuses it)' ($selSum.found -and $selSum.selective -and $selSum.cases -eq 43 -and $selSum.unitsRan -eq 6) "sel=$($selSum.selective) cases=$($selSum.cases)"
  $fullSum = Get-HarnessSummary @('TEST-AUDITORS-COMPLETE pass=701 failed=1 hygiene=0 skipped=0')
  Case 'CLEAN TWIN' 'a full harness run still reads as full, with its case count' ($fullSum.found -and -not $fullSum.selective -and $fullSum.cases -eq 702) "cases=$($fullSum.cases)"

  $tmpDir = Join-Path $env:TEMP ('tc-prepush-ta-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $null = New-Item -ItemType Directory -Force $tmpDir
  try {
    $rp = Join-Path $tmpDir 'known.json'
    Write-KnownFailures $rp (ConvertTo-Entries @($hyA)) 'self-test' 2 $now 702
    $k = Read-KnownFailures $rp $now 192
    Case 'CLEAN TWIN' 'a record written now reads back fresh with its case and its case total' ($k.state -eq 'fresh' -and $k.keys.Count -eq 1 -and $k.keys[0] -eq (Get-CaseKey $hyA) -and $k.totalCases -eq 702) "state=$($k.state) total=$($k.totalCases) $($k.detail)"
    Write-KnownFailures $rp (ConvertTo-Entries @()) 'self-test' 0 $now
    $k = Read-KnownFailures $rp $now 192
    Case 'MUST NOT FIRE' 'an empty record reads back fresh with no case' ($k.state -eq 'fresh' -and $k.keys.Count -eq 0) "state=$($k.state) keys=$($k.keys.Count) $($k.detail)"
    Write-KnownFailures $rp (ConvertTo-Entries @($hyA)) 'self-test' 2 ($now.AddDays(-10))
    Case 'MUST FIRE' 'a record older than the limit reads stale' ((Read-KnownFailures $rp $now 192).state -eq 'stale')
    [IO.File]::WriteAllText($rp, '{"recorded_at": "2026-09-10T00:00:00Z", "failing": [', (New-Object Text.UTF8Encoding($false)))
    Case 'MUST FIRE' 'a truncated record reads unreadable' ((Read-KnownFailures $rp $now 192).state -eq 'unreadable')
    [IO.File]::WriteAllText($rp, ('{"recorded_at": "' + $now.ToString('o') + '"}'), (New-Object Text.UTF8Encoding($false)))
    Case 'MUST FIRE' 'a record with no failing list reads unreadable, not empty' ((Read-KnownFailures $rp $now 192).state -eq 'unreadable')
    Case 'MUST FIRE' 'no record reads missing' ((Read-KnownFailures (Join-Path $tmpDir 'none.json') $now 192).state -eq 'missing')
  } catch {
    $fails += ('record cases THREW: ' + $_.Exception.Message)
    "  record cases THREW: $($_.Exception.Message)"
  } finally { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }

  # ---- UNIT SELECTION, on a frozen synthetic harness (R19) ----
  # Each unit carries the shape of a real one: u001 runs an audit over a fixture and READS another script's
  # text; u002 runs a second audit and reads a variable u001 assigned; u003 declares a scan glob; u004 is
  # declared always-run; u005 calls a top-level helper whose literal names its rule file and assigns its own $r.
  $ux = @'
$root = $PSScriptRoot
$fix  = Join-Path $root 'regression-inputs\guard-fixtures'
. (Join-Path $root 'harness-lib.ps1')
try {
$shared = 1
function Get-DeltaRules { return (Join-Path $fix 'delta-table.json') }
if (Use-Unit 'u001-alpha') {
$r = RunPS 'audit-alpha.ps1' @('-CompareFile', (Join-Path $fix 'alpha-board.json'))
if ($r.rc -eq 0) { Ok 'alpha fires' } else { Bad 'alpha is blind' }
$gammaSrc = Get-Content (Join-Path $root 'gamma.ps1') -Raw
} # u001-alpha
if (Use-Unit 'u002-beta') {
$r = RunPS 'audit-beta.ps1' @()
if ($gammaSrc -notmatch 'unsafe') { Ok 'beta reads the gamma text u001 loaded' } else { Bad 'beta' }
} # u002-beta
if (Use-Unit 'u003-scan' -Reads 'modx/*.ps1') {
Ok 'scan'
} # u003-scan
if (Use-Unit 'u004-live' -Always 'reads the live tree') {
Ok 'live'
} # u004-live
. (Join-Path $root 'delta-lib.ps1')
if (Use-Unit 'u005-delta') {
$r = RunPS 'audit-delta.ps1' @('-Rules', (Get-DeltaRules))
if ($r.rc -eq 0 -and (Test-DeltaShape 1)) { Ok 'delta' } else { Bad 'delta' }
} # u005-delta
} finally { }
'@
  $uxReader = { param($n) switch ($n) { 'audit-alpha.ps1' { ". (Join-Path `$PSScriptRoot 'shared-lib.ps1')" } 'audit-beta.ps1' { "`$lib = 'shared-lib.ps1'`n& (Join-Path `$PSScriptRoot 'beta-child.ps1')" } 'gamma.ps1' { ". (Join-Path `$PSScriptRoot 'gamma-lib.ps1')" } 'delta-lib.ps1' { "function Test-DeltaShape(`$x) { `$x -gt 0 }" } default { '' } } }
  $uxIn = Get-AuditorInputs $ux 'modx/test-auditors.ps1'
  $uxIn.botOwned = { param($p) $false }
  $um = Get-UnitModel $ux 'modx/test-auditors.ps1'
  Case 'CLEAN TWIN' 'the synthetic harness builds a unit model with its five units' ($um.ok -and $um.ids.Count -eq 5) "ok=$($um.ok) why=$($um.why) ids=$($um.ids -join ',')"
  $uc = @{}
  $s1 = Get-Selection @('modx/regression-inputs/guard-fixtures/alpha-board.json') @('modx/regression-inputs/guard-fixtures/alpha-board.json') $um $uxIn $uxReader $uc
  Case 'MUST FIRE' 'a changed fixture selects the unit whose code names it' ($s1.mode -eq 'selective' -and $s1.selected -contains 'u001-alpha') "mode=$($s1.mode) sel=$($s1.selected -join ',') why=$($s1.why)"
  Case 'MUST NOT FIRE' 'a changed fixture does not select a unit that never names it' ($s1.skipped -contains 'u002-beta' -and $s1.skipped -contains 'u005-delta') "skipped=$($s1.skipped -join ',')"
  Case 'MUST FIRE' 'an always-run unit runs on any guard-touching push' ($s1.selected -contains 'u004-live') "sel=$($s1.selected -join ',')"
  $s2 = Get-Selection @('modx/lib/shared-lib.ps1') @('modx/lib/shared-lib.ps1') $um $uxIn $uxReader $uc
  Case 'MUST FIRE' 'a shared library selects every unit whose run scripts reach it' ($s2.selected -contains 'u001-alpha' -and $s2.selected -contains 'u002-beta') "mode=$($s2.mode) sel=$($s2.selected -join ',') why=$($s2.why)"
  $gl = Get-UnitsForPath 'modx/gamma-lib.ps1' $um $uxIn $uxReader $uc
  Case 'MUST NOT FIRE' 'a library of a script a unit only READS does not reach that unit' (@($gl) -notcontains 'u001-alpha') "units=$(@($gl) -join ',')"
  $gs = Get-UnitsForPath 'modx/gamma.ps1' $um $uxIn $uxReader $uc
  Case 'CLEAN TWIN' 'the script a unit reads still reaches that unit' (@($gs) -contains 'u001-alpha') "units=$(@($gs) -join ',')"
  $s3 = Get-Selection @('modx/audit-beta.ps1') @('modx/audit-beta.ps1') $um $uxIn $uxReader $uc
  Case 'MUST FIRE' 'a unit that reads a variable another unit assigns brings that unit with it' ($s3.selected -contains 'u002-beta' -and $s3.selected -contains 'u001-alpha' -and $s3.needed -contains 'u001-alpha') "sel=$($s3.selected -join ',') needed=$($s3.needed -join ',')"
  Case 'MUST NOT FIRE' 'a unit that assigns its own variable before reading it needs no other unit' (@($um.byId['u005-delta'].needs.Keys).Count -eq 0) "needs=$(@($um.byId['u005-delta'].needs.Keys) -join ',')"
  $s4 = Get-Selection @('modx/delta-table.json') @('modx/delta-table.json') $um $uxIn $uxReader $uc
  Case 'MUST FIRE' 'a file named only inside a helper function reaches the unit that calls it' ($s4.selected -contains 'u005-delta') "sel=$($s4.selected -join ',') why=$($s4.why)"
  $s5 = Get-Selection @('modx/some-new-scanner.ps1') @('modx/some-new-scanner.ps1') $um $uxIn $uxReader $uc
  Case 'MUST FIRE' 'a declared -Reads glob selects its unit' ($s5.selected -contains 'u003-scan') "sel=$($s5.selected -join ',') why=$($s5.why)"
  $s6 = Get-Selection @('modx/regression-inputs/guard-fixtures/orphan-board.json') @('modx/regression-inputs/guard-fixtures/orphan-board.json') $um $uxIn $uxReader $uc
  Case 'MUST FIRE' 'a guard input no unit names makes the run full, not empty' ($s6.mode -eq 'full' -and $s6.why -match 'no unit names') "mode=$($s6.mode) why=$($s6.why)"
  $s7 = Get-Selection @('modx/harness-lib.ps1') @('modx/harness-lib.ps1') $um $uxIn $uxReader $uc
  Case 'MUST FIRE' 'a library the harness dot-sources before its first unit makes the run full' ($s7.mode -eq 'full' -and $s7.why -match 'harness') "mode=$($s7.mode) why=$($s7.why)"
  $s8 = Get-Selection @('modx/test-auditors.ps1') @('modx/test-auditors.ps1') $um $uxIn $uxReader $uc
  Case 'MUST FIRE' 'a push touching the harness itself is a full run' ($s8.mode -eq 'full') "mode=$($s8.mode) why=$($s8.why)"
  $dp = Get-UnitsForPath 'notes/a-plan.md' $um $uxIn $uxReader $uc
  Case 'MUST NOT FIRE' 'a document reaches no unit' (@($dp).Count -eq 0) "units=$(@($dp) -join ',')"
  $umBad = Get-UnitModel ($ux.Replace("if (Use-Unit 'u003-scan' -Reads 'modx/*.ps1') {", 'if (Use-Unit $scanId) {')) 'modx/test-auditors.ps1'
  $s9 = Get-Selection @('modx/regression-inputs/guard-fixtures/alpha-board.json') @('modx/regression-inputs/guard-fixtures/alpha-board.json') $umBad $uxIn $uxReader @{}
  Case 'MUST FIRE' 'a Use-Unit whose declaration cannot be read makes the run full' ($s9.mode -eq 'full' -and -not $umBad.ok) "mode=$($s9.mode) why=$($umBad.why)"
  $s10 = Get-Selection @('modx/delta-lib.ps1') @('modx/delta-lib.ps1') $um $uxIn $uxReader $uc
  Case 'MUST FIRE' 'a library dot-sourced between units selects every unit that calls a function it defines' ($s10.mode -eq 'selective' -and $s10.selected -contains 'u005-delta' -and $s10.skipped -contains 'u002-beta') "mode=$($s10.mode) sel=$($s10.selected -join ',') why=$($s10.why)"
  $umTail = Get-UnitModel ($ux.Replace('} # u005-delta', ('Write-Guard' + 'Complete -Name ''modx'' -Summary ''x''') + "`n} # u005-delta")) 'modx/test-auditors.ps1'
  Case 'MUST FIRE' 'a unit holding the harness''s own completion marker makes the model unusable (a full run)' (-not $umTail.ok -and $umTail.why -match 'verdict') "ok=$($umTail.ok) why=$($umTail.why)"
  $bc = Get-UnitsForPath 'modx/beta-child.ps1' $um $uxIn $uxReader $uc
  Case 'MUST FIRE' 'a script that a run script invokes reaches the unit (one child hop)' (@($bc) -contains 'u002-beta') "units=$(@($bc) -join ',')"

  # LIVE: the derivation reaches the real harness, and the harness still prints what this reads.
  $taPath = Join-Path $RepoRoot $script:AuditorsRel.Replace('/', '\')
  $taText = if (Test-Path -LiteralPath $taPath) { [IO.File]::ReadAllText($taPath) } else { '' }
  $live = Get-AuditorInputs $taText $script:AuditorsRel
  "  live derivation resolved: $($live.code.Count) code name(s), $($live.data.Count) file name(s), $($live.globs.Count) glob(s), fixture root '$($live.fixRoot)'"
  Case 'MUST FIRE' 'live: test-auditors.ps1 is its own input' ((Test-GuardInput $script:AuditorsRel $live) -ne '')
  $liveGlob = @($live.globs | Where-Object { $_.pattern -match '^[^*]*/\*\.ps1$' })
  Case 'MUST FIRE' 'live: a new script in a directory test-auditors globs is an input' `
    ($liveGlob.Count -gt 0 -and (Test-GuardInput ($liveGlob[0].pattern.Replace('*', 'new-guard')) $live) -ne '') "globs=$($liveGlob.Count)"
  Case 'MUST NOT FIRE' 'live: a document outside every input rule is not an input' ((Test-GuardInput 'notes/a-plan.md' $live) -eq '')
  $ownedFile = @()
  if ($script:BotPathsLoaded) { $bpAll = Get-BotInputPaths; $ownedFile = @($bpAll | Where-Object { $_ -match '\.\w+$' -and $_ -notmatch '[*?]' -and ('/' + $_) -notmatch '/(out|public)/' }) }
  if ($ownedFile.Count -gt 0) { [void]$live.data.Add(($ownedFile[0] -split '/')[-1]) }
  Case 'MUST NOT FIRE' 'live: a quoted file the daily bot owns is not an input' ($ownedFile.Count -gt 0 -and (Test-GuardInput $ownedFile[0] $live) -eq '') "bot-paths loaded=$($script:BotPathsLoaded) owned files=$($ownedFile.Count)"
  Case 'MUST FIRE' 'live: test-auditors still prints a failing case as an indented FAIL line' ($taText.Contains('Write-Output ("  FA' + 'IL  " + $m)'))
  Case 'MUST FIRE' 'live: test-auditors still ends with its test-auditors completion marker' ($taText.Contains("Write-GuardComplete -Name 'test-" + "auditors'"))
  $liveBoards = Get-BoardPatterns $taText $script:AuditorsRel
  Case 'MUST FIRE' 'live: the board files are read from test-auditors'' own board test' ($liveBoards.Count -gt 0) ($liveBoards -join ', ')
  $bpFx = Get-BoardPatterns ("`$x = 1`n`$HasBoard = (@(Get-ChildItem (Join-Path `$root 'out\a-*.json')).Count -gt 0) -or`n    (Test-Path (Join-Path `$root 'out\b.json'))`nfunction Ok(`$m) { Join-Path `$root 'c.json' }") 'modx/test-auditors.ps1'
  Case 'MUST FIRE' 'the board test is read across its -or continuation and no further' ($bpFx.Count -eq 2 -and $bpFx[0] -eq 'modx/out/a-*.json') ($bpFx -join ', ')

  # LIVE COMPLETENESS (R19): every case in the real harness is inside a unit, or inside a helper a unit calls,
  # and every unit either derives its inputs from its own code or is declared always-run.
  $lm = Get-UnitModel $taText $script:AuditorsRel
  "  live unit model: $($lm.unitCount) unit(s) - $($lm.unitCount - $lm.alwaysCount) derive their inputs from their own code ($($lm.readsCount) of them also declare -Reads), $($lm.alwaysCount) declared always-run; $($lm.caseSites) case call site(s): $($lm.casesInUnits) inside units, $($lm.casesInFns) inside helper functions units call, $($lm.casesOutside) outside any unit; built in $($lm.ms)ms"
  Case 'MUST FIRE' 'live: the real test-auditors builds a usable unit model' ($lm.ok -and $lm.unitCount -gt 0) "why=$($lm.why)"
  Case 'MUST FIRE' 'live: every case call site is inside a unit or a helper function, none outside' ($lm.ok -and $lm.casesOutside -eq 0 -and ($lm.casesInUnits + $lm.casesInFns) -eq $lm.caseSites) "sites=$($lm.caseSites) units=$($lm.casesInUnits) fns=$($lm.casesInFns) outside=$($lm.casesOutside)"
  $trackedAll = @(& git -C $RepoRoot -c core.quotepath=off ls-files 2>$null)
  $deadReads = @()
  foreach ($e in @($lm.entries | Where-Object { $_.unit })) { foreach ($pat in $e.reads) { $rx = ConvertTo-PatternRx $pat; if (@($trackedAll | Where-Object { $_ -match $rx }).Count -eq 0) { $deadReads += ($e.id + ': ' + $pat) } } }
  Case 'MUST FIRE' 'live: every declared -Reads pattern matches a tracked file (a typo would silently select nothing)' ($trackedAll.Count -gt 0 -and $deadReads.Count -eq 0) ($deadReads -join '; ')
  # The REAL Use-Unit, extracted from the harness and driven, so the protocol this file writes is proven
  # against the code that reads it.
  $tk = $null; $pe = $null
  $taAst = [System.Management.Automation.Language.Parser]::ParseInput($taText, [ref]$tk, [ref]$pe)
  $uuDef = @($taAst.FindAll({ param($n) $n -is $script:TFn -and $n.Name -eq 'Use-Unit' }, $true))
  $gcCalls = @($taAst.FindAll({ param($n) $n -is $script:TCmd -and $n.GetCommandName() -eq ('Write-Guard' + 'Complete') }, $true))
  $gcInUnit = @($gcCalls | Where-Object { $q = $_.Parent; $inU = $false; while ($q) { if ($q -is $script:TIf -and $q.Clauses[0].Item1.Extent.Text -match '^\s*Use-Unit\b') { $inU = $true; break }; $q = $q.Parent }; $inU })
  Case 'MUST FIRE' 'live: the harness writes its completion marker outside every unit, so a selective run always reaches its verdict' ($gcCalls.Count -gt 0 -and $gcInUnit.Count -eq 0) "calls=$($gcCalls.Count) inside-a-unit=$($gcInUnit.Count)"
  $uuProbe = {
    param([string]$FnText, [string[]]$Skip)
    $script:SkipUnits = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $script:UnitsRan = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $script:UnitsSkipped = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($sk in @($Skip)) { if ($sk) { [void]$script:SkipUnits.Add($sk) } }
    . ([scriptblock]::Create($FnText))
    @((Use-Unit 'u001-a'), (Use-Unit 'u002-b' -Reads 'x/*.ps1'), (Use-Unit 'u003-c' -Always 'r'))
  }
  if ($uuDef.Count -eq 1) {
    $none = @(& $uuProbe $uuDef[0].Extent.Text @())
    Case 'CLEAN TWIN' 'live: with no skip file the real Use-Unit runs every unit (the daily full run)' ($none.Count -eq 3 -and $none[0] -and $none[1] -and $none[2]) "got=$($none -join ',')"
    $one = @(& $uuProbe $uuDef[0].Extent.Text @('u002-b'))
    Case 'MUST FIRE' 'live: the real Use-Unit skips exactly the unit named in the skip file and runs the rest' ($one.Count -eq 3 -and $one[0] -and -not $one[1] -and $one[2]) "got=$($one -join ',')"
  } else {
    Case 'MUST FIRE' 'live: test-auditors defines exactly one Use-Unit' $false "found=$($uuDef.Count)"
    Case 'MUST FIRE' 'live: the real Use-Unit could be driven' $false 'not found'
  }

  # ---- PASS REUSE ACROSS A REBASE (2026-09-18, discovered:push-livelock-2026-09-18) ----
  # A real temp repo through the real key and the real record, in a directory of this run's own. The founding bug:
  # a retry after a rebase that brought in only non-input files re-ran the full ~7 minute suite, and lost the ref
  # race again. The must-fire is the other direction: any moved input, harness byte or board runs in full.
  $prDir = Join-Path $env:TEMP ('tc-ptapr-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    Clear-TcGitRepoEnv
    $null = New-Item -ItemType Directory -Path $prDir -ErrorAction Stop
    $u8 = New-Object Text.UTF8Encoding($false)
    foreach ($d in @('modz', 'ops', 'lib', 'notes', 'modz\boards')) { $null = New-Item -ItemType Directory -Path (Join-Path $prDir $d) -Force }
    $prTa = "`$x = RunPS 'modq-audit.ps1'`n'TEST-AUDITORS-COMPLETE'`n"
    [IO.File]::WriteAllText((Join-Path $prDir 'modz\test-auditors.ps1'), $prTa, $u8)
    [IO.File]::WriteAllText((Join-Path $prDir 'modz\modq-audit.ps1'), "'v1'`n", $u8)
    [IO.File]::WriteAllText((Join-Path $prDir 'ops\prepush-test-auditors.ps1'), "'harness v1'`n", $u8)
    [IO.File]::WriteAllText((Join-Path $prDir 'lib\modq-lib.ps1'), "'lib v1'`n", $u8)
    [IO.File]::WriteAllText((Join-Path $prDir 'notes\readme.txt'), "not an input`n", $u8)
    [IO.File]::WriteAllText((Join-Path $prDir 'modz\boards\comparison-2026-09-18.json'), "{}`n", $u8)
    $gq = { param([string[]]$A) $null = & git -C $prDir -c user.name=fixture -c user.email=fixture@example.invalid -c core.autocrlf=false @A 2>$null }
    & $gq @('init', '-q'); & $gq @('add', 'modz/test-auditors.ps1', 'modz/modq-audit.ps1', 'ops/prepush-test-auditors.ps1', 'lib/modq-lib.ps1', 'notes/readme.txt'); & $gq @('commit', '-q', '-m', 'base')
    $prBoards = @('modz/boards/comparison-*.json')
    $kOf = { Get-TaInputKey $prDir (Get-AuditorInputs $prTa 'modz/test-auditors.ps1') $prBoards }
    $k1 = & $kOf
    $recP = Join-Path $prDir 'pass.json'
    $now = [datetime]::UtcNow
    Write-TaPassRecord $recP $k1.key 0 @() 'full' @() 700 $now
    # CLEAN TWIN: a "rebase" that brings in only non-input files leaves the key, and the pass is REUSED with its key printed.
    [IO.File]::WriteAllText((Join-Path $prDir 'notes\readme.txt'), "another session's note`n", $u8)
    [IO.File]::WriteAllText((Join-Path $prDir 'notes\new.txt'), "arrived by rebase`n", $u8)
    & $gq @('add', 'notes/readme.txt', 'notes/new.txt'); & $gq @('commit', '-q', '-m', 'foreign non-input')
    $k2 = & $kOf
    $p2 = Read-TaPassRecord $recP $k2.key $now 6 'full' @()
    $line2 = Format-ReuseLine $k2.key $p2 $k2
    Case 'CLEAN TWIN' 'pass reuse: only non-input files arrived, so the same key reuses the recorded pass, printed REUSED with the key' ($k1.ok -and $k2.ok -and $k1.inputs -ge 4 -and $k1.key -eq $k2.key -and $p2.reuse -and $line2.StartsWith('prepush-test-auditors: REUSED key=' + $k1.key)) "k1=$($k1.key)/$($k1.inputs) k2=$($k2.key) reuse=$($p2.reuse) why=$($p2.why)"
    # MUST FIRE: an input changed between the runs, so the key moves and the run is full.
    [IO.File]::WriteAllText((Join-Path $prDir 'modz\modq-audit.ps1'), "'v2'`n", $u8)
    & $gq @('add', 'modz/modq-audit.ps1'); & $gq @('commit', '-q', '-m', 'input moved')
    $k3 = & $kOf
    $p3 = Read-TaPassRecord $recP $k3.key $now 6 'full' @()
    Case 'MUST FIRE' 'pass reuse: a test-auditors input changed between runs, so the key moves and the run is full' ($k3.ok -and $k3.key -ne $k1.key -and -not $p3.reuse -and $p3.why -match 'an input moved') "k1=$($k1.key) k3=$($k3.key) reuse=$($p3.reuse) why=$($p3.why)"
    Write-TaPassRecord $recP $k3.key 0 @() 'full' @() 700 $now
    [IO.File]::WriteAllText((Join-Path $prDir 'modz\modq-audit.ps1'), "'v3 uncommitted'`n", $u8)
    $k4 = & $kOf
    Case 'MUST FIRE' 'pass reuse: an UNCOMMITTED edit to an input moves the key (the suite reads the working tree)' ($k4.ok -and $k4.dirty -eq 1 -and $k4.key -ne $k3.key -and -not (Read-TaPassRecord $recP $k4.key $now 6 'full' @()).reuse) "k3=$($k3.key) k4=$($k4.key) dirty=$($k4.dirty)"
    [IO.File]::WriteAllText((Join-Path $prDir 'modz\modq-audit.ps1'), "'v2'`n", $u8)
    [IO.File]::WriteAllText((Join-Path $prDir 'ops\prepush-test-auditors.ps1'), "'harness v2'`n", $u8)
    $k5 = & $kOf
    [IO.File]::WriteAllText((Join-Path $prDir 'ops\prepush-test-auditors.ps1'), "'harness v1'`n", $u8)
    [IO.File]::WriteAllText((Join-Path $prDir 'lib\modq-lib.ps1'), "'lib v2'`n", $u8)
    $k6 = & $kOf
    [IO.File]::WriteAllText((Join-Path $prDir 'lib\modq-lib.ps1'), "'lib v1'`n", $u8)
    [IO.File]::WriteAllText((Join-Path $prDir 'modz\boards\comparison-2026-09-18.json'), "{`"rebuilt`":1}`n", $u8)
    $k7 = & $kOf
    Case 'MUST FIRE' 'pass reuse: a harness byte (this script or any lib) or a board rebuild moves the key' ($k5.key -ne $k3.key -and $k6.key -ne $k3.key -and $k7.key -ne $k3.key -and $k5.ok -and $k6.ok -and $k7.ok) "k3=$($k3.key) harness=$($k5.key) lib=$($k6.key) board=$($k7.key)"
    $old = Read-TaPassRecord $recP $k3.key $now.AddHours(7) 6 'full' @()
    Write-TaPassRecord $recP $k3.key 0 @() 'selective' @('u001-a') 40 $now
    $nar = Read-TaPassRecord $recP $k3.key $now 6 'full' @()
    $nar2 = Read-TaPassRecord $recP $k3.key $now 6 'selective' @('u001-a', 'u009-z')
    Case 'MUST FIRE' 'pass reuse: a too-old record, or a selective pass where this push needs more units, is a full run' (-not $old.reuse -and -not $nar.reuse -and -not $nar2.reuse) "old=$($old.why) | full=$($nar.why) | wider=$($nar2.why)"
    [IO.File]::WriteAllText($recP, '{"schema":1,"key":', $u8)
    $bad = Read-TaPassRecord $recP $k3.key $now 6 'full' @()
    $gone = Read-TaPassRecord (Join-Path $prDir 'absent.json') $k3.key $now 6 'full' @()
    Case 'MUST FIRE' 'pass reuse: an unreadable or missing record is a full run, never a pass (fail closed)' (-not $bad.reuse -and -not $gone.reuse -and $bad.why -match 'unreadable') "bad=$($bad.why) | missing=$($gone.why)"
  } catch {
    $fails += ('pass-reuse cases THREW: ' + $_.Exception.Message)
    "  pass-reuse cases THREW: $($_.Exception.Message)"
  } finally { Remove-Item -LiteralPath $prDir -Recurse -Force -ErrorAction SilentlyContinue }

  # ---- A CHILD'S FILES AFTER THE VERDICT (2026-09-11) ----
  # Real children through the real launcher and the real cleanup, in a directory of this run's own, so a
  # concurrent run of this suite can neither share nor delete them. The crash child is the founding shape: its
  # cause on stderr, nothing on stdout, an exit before its completion marker. The pass child writes to stderr
  # too, so its files are removed because the run passed and not because stderr happened to be empty. The
  # 120s wait is a hang guard, never a speed bar.
  $chDir = Join-Path $env:TEMP ('tc-ptast-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    $null = New-Item -ItemType Directory -Path $chDir -ErrorAction Stop
    $utf8 = New-Object Text.UTF8Encoding($false)
    $crashPs = Join-Path $chDir 'crash.ps1'
    [IO.File]::WriteAllText($crashPs, ("[Console]::Error.WriteLine('founding startup crash: a harness library is missing')`n" + "exit 1`n"), $utf8)
    $crash = Invoke-TaChild $crashPs @() (Join-Path $chDir 'crash') 120
    $vc = Get-PushVerdict $crash.rc (Test-GuardComplete -Output $crash.lines -Name 'test-auditors') (Get-FailLines $crash.lines) $unread
    $crashMsg = (Complete-TaChildFiles $crash $vc.code) -join "`n"
    $errKept = Test-Path -LiteralPath $crash.errFile
    Case 'MUST FIRE' 'a child that dies on stderr before its marker keeps its stderr file and names it with its cause' `
      ($vc.code -eq 3 -and $errKept -and $crashMsg.Contains($crash.errFile) -and $crashMsg.Contains('founding startup crash: a harness library is missing')) "code=$($vc.code) rc=$($crash.rc) errKept=$errKept output: $crashMsg"
    $passPs = Join-Path $chDir 'pass.ps1'
    [IO.File]::WriteAllText($passPs, ("[Console]::Error.WriteLine('a warning a passing run may print')`n" + "'  PASS  one case'`n" + "'TEST-AUDITORS-COMPLETE pass=1 failed=0 hygiene=0 skipped=0'`n" + "exit 0`n"), $utf8)
    $pass = Invoke-TaChild $passPs @() (Join-Path $chDir 'pass') 120
    $vp = Get-PushVerdict $pass.rc (Test-GuardComplete -Output $pass.lines -Name 'test-auditors') (Get-FailLines $pass.lines) $unread
    $written = @(@($pass.outFile, $pass.errFile) | Where-Object { (Test-Path -LiteralPath $_) -and (Get-Item -LiteralPath $_).Length -gt 0 }).Count
    $null = Complete-TaChildFiles $pass $vp.code
    $removed = @(@($pass.outFile, $pass.errFile) | Where-Object { -not (Test-Path -LiteralPath $_) }).Count
    Case 'CLEAN TWIN' 'a passing run still removes both files it wrote, stderr included' ($vp.code -eq 0 -and $written -eq 2 -and $removed -eq 2) "code=$($vp.code) rc=$($pass.rc) written=$written removed=$removed"
  } catch {
    $fails += ('child-file cases THREW: ' + $_.Exception.Message)
    "  child-file cases THREW: $($_.Exception.Message)"
  } finally { Remove-Item -LiteralPath $chDir -Recurse -Force -ErrorAction SilentlyContinue }

  # ---- EXPECTED LIVE RED (Brad's ruling 2026-09-19, "Teach the gate") ----
  # The founding deadlock: a push adding a ruling against a product still on the live board turns the live-board cases
  # red on purpose, and this check refused it forever. A sandbox git repo holds the REAL audits (copied from this
  # checkout, with every lib), rule files committed at a base and at several tips, and an untracked fixture board, so
  # each case drives the real paired run through the real audits. Synthetic commodity and store names throughout.
  $liveCases = Get-LiveRulingCases $taText
  Case 'MUST FIRE' 'live: test-auditors marks exactly the food-category and known-wrong live-board cases' (@($liveCases).Count -eq 2 -and (@($liveCases | ForEach-Object { $_.audit } | Sort-Object) -join ',') -eq 'audit-food-category.ps1,audit-known-wrong.ps1') "got=$(@($liveCases | ForEach-Object { $_.audit + ' <' + $_.prefix + '>' }) -join '; ')"
  $auditTexts = @{}
  foreach ($an in @('audit-food-category.ps1', 'audit-known-wrong.ps1')) { $ap = Join-Path $RepoRoot ('grocery\' + $an); $auditTexts[$an] = $(if (Test-Path -LiteralPath $ap) { [IO.File]::ReadAllText($ap) } else { '' }) }
  $fcRules = Get-AuditRuleFiles $auditTexts['audit-food-category.ps1']; $kwRules = Get-AuditRuleFiles $auditTexts['audit-known-wrong.ps1']
  $globsNamed = @($script:ArmBoardGlobs | Where-Object { $leaf = ($_ -split '\\')[-1].Replace('*-regular-*', '-regular-*'); -not (($auditTexts['audit-food-category.ps1'] + $auditTexts['audit-known-wrong.ps1']).Contains($leaf)) })
  Case 'MUST FIRE' 'live: each audit''s rule files are read from its own source, and the arms'' board globs are the ones they read' ($fcRules.Count -ge 3 -and $kwRules.Count -ge 3 -and @($fcRules + $kwRules | Where-Object { $script:RulingFiles -contains $_ }).Count -ge 2 -and $globsNamed.Count -eq 0) "fc=$($fcRules -join ',') kw=$($kwRules -join ',') unnamed-globs=$($globsNamed -join ',')"
  $rn = @{}; foreach ($x in @($fcRules + $kwRules)) { $rn[($x -replace '\.json$', '')] = $x }
  $caseFc = @($liveCases | Where-Object { $_.audit -eq 'audit-food-category.ps1' })
  $caseKw = @($liveCases | Where-Object { $_.audit -eq 'audit-known-wrong.ps1' })
  $fcLine = 'FAIL  ' + $(if ($caseFc.Count) { $caseFc[0].prefix } else { 'unmarked food-category case (rc=' }) + '2) - fixture'
  $kwLine = 'FAIL  ' + $(if ($caseKw.Count) { $caseKw[0].prefix } else { 'unmarked known-wrong case (rc=' }) + '2) - fixture'
  $freshX = [pscustomobject]@{ state = 'fresh'; keys = @((Get-CaseKey $hyA)); lines = @($hyA); recordedAt = 'x'; ageHours = 2.0; detail = 'recorded x'; totalCases = 702 }
  $exDir = Join-Path $env:TEMP ('tc-ptaex-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    Clear-TcGitRepoEnv
    $null = New-Item -ItemType Directory -Path $exDir -ErrorAction Stop
    $u8x = New-Object Text.UTF8Encoding($false)
    foreach ($d in @('lib', 'modg', 'modg\out\regular')) { $null = New-Item -ItemType Directory -Path (Join-Path $exDir $d) -Force }
    foreach ($lf in @(Get-ChildItem (Join-Path $RepoRoot 'lib\*.ps1') -File)) { Copy-Item -LiteralPath $lf.FullName -Destination (Join-Path $exDir 'lib') }
    foreach ($an in $auditTexts.Keys) { [IO.File]::WriteAllText((Join-Path $exDir ('modg\' + $an)), $auditTexts[$an], $u8x) }
    $gx = { param([string[]]$A) $null = & git -C $exDir -c user.name=fixture -c user.email=fixture@example.invalid -c core.autocrlf=false @A 2>$null }
    $putRule = { param([string]$Stem, [string]$Json, [string]$Eol = "`n") [IO.File]::WriteAllText((Join-Path $exDir ('modg\' + $rn[$Stem])), ($Json + $Eol), $u8x) }
    $commitX = { param([string]$Msg) & $gx @('add', '-A', '--', '.gitignore', '.gitattributes', 'modg', 'lib'); & $gx @('commit', '-q', '-m', $Msg); return ((@(& git -C $exDir rev-parse HEAD) -join '').Trim()) }
    [IO.File]::WriteAllText((Join-Path $exDir '.gitignore'), "modg/out/`n", $u8x)
    # text=auto as the real repo has it, so a CRLF working copy of an LF blob hashes to that blob, as it does in a fresh checkout
    [IO.File]::WriteAllText((Join-Path $exDir '.gitattributes'), "* text=auto`n", $u8x)
    $kwOld = '{"key":"fx-pear|StoreB|old-wrong-pear","commodity":"fx-pear","store":"StoreB","names":["Old Wrong Pear"],"retire_when":"ruling-reversed","evidence":"fixture","ruled_on":"2026-01-01","ruled_by":"fixture"}'
    $kwNew = '{"key":"fx-apple|StoreB|apple-fizz-soda-12-oz","commodity":"fx-apple","store":"StoreB","names":["Apple Fizz Soda 12 oz"],"retire_when":"ruling-reversed","evidence":"fixture","ruled_on":"2026-01-02","ruled_by":"fixture"}'
    $ceBase = '{"classes":{"beverage":["\\bcola\\b","\\bdrink\\b"]},"apply":[{"categories":"^Produce$","classes":["beverage"]}],"exempt":{"beverage":""},"universal_for_unknown":[]}'
    $ceSoda = $ceBase.Replace('"\\bdrink\\b"]', '"\\bdrink\\b","\\bsoda\\b"]')
    & $putRule 'category-excludes' $ceBase
    & $putRule 'categories' '{"categories":[{"label":"Produce","commodities":["fx-apple","fx-pear"]}]}'
    & $putRule 'food-class-allowlist' '[{"id":"fx-pear","store":"StoreA","pattern":"nectar","reason":"fixture exception"}]'
    & $putRule 'known-wrong' ('{"entries":[' + $kwOld + ']}')
    & $putRule 'commodities' '[{"id":"fx-apple"},{"id":"fx-pear"}]'
    & $putRule 'stores' '{"stores":[{"name":"StoreA","regular_prefix":"storea"},{"name":"StoreB","regular_prefix":"storeb"}]}'
    [IO.File]::WriteAllText((Join-Path $exDir 'modg\out\comparison-2026-01-01.json'), '{"comparison":[{"id":"fx-apple","cheapest_store":"StoreB","stores":[{"store":"StoreA","item":"Gala Apples 3 lb","per_unit":1.0},{"store":"StoreB","item":"Apple Fizz Soda 12 oz","per_unit":0.5}]},{"id":"fx-pear","cheapest_store":"StoreA","stores":[{"store":"StoreA","item":"Pear Nectar Drink","per_unit":0.7},{"store":"StoreB","item":"Bosc Pears","per_unit":0.9}]}]}', $u8x)
    & $gx @('init', '-q')
    $shaB = & $commitX 'base'
    & $putRule 'category-excludes' $ceSoda; & $putRule 'known-wrong' ('{"entries":[' + $kwOld + ',' + $kwNew + ']}')
    $shaA = & $commitX 'tip A: a ruling in each file'
    & $gx @('checkout', '-q', $shaB); & $putRule 'known-wrong' '{"entries":[]}'
    $shaC = & $commitX 'tip C: the blocklist emptied'
    & $gx @('checkout', '-q', $shaB); & $putRule 'category-excludes' $ceSoda; & $putRule 'food-class-allowlist' '[]'
    $shaD = & $commitX 'tip D: a ruling and a removed exception'
    & $gx @('checkout', '-q', $shaB); & $putRule 'category-excludes' $ceSoda
    $shaB2 = & $commitX 'base B2: already red'
    & $putRule 'known-wrong' ('{"entries":[' + $kwOld + ',' + $kwNew + ']}')
    $shaTB = & $commitX 'tip B: a ruling over an already-red base'
    $exOut = Join-Path $exDir 'modg\out'
    $runEx = { param([string]$Base, [string]$Tip, [string[]]$Lines, $Known)
      & $gx @('checkout', '-q', $Tip)
      Resolve-ExpectedLiveReds (Get-PushVerdict 2 $true $Lines $Known) $Known $liveCases $exDir 'modg/' $Base $Tip $exOut }
    $shas = @($shaB, $shaA, $shaC, $shaD, $shaB2, $shaTB) | Where-Object { $_ -match '^[0-9a-f]{40}$' }
    if (@($shas | Sort-Object -Unique).Count -ne 6) { throw ('the sandbox repo made ' + @($shas | Sort-Object -Unique).Count + ' of 6 distinct commits') }

    # MUST FIRE: the founding push. A known-wrong entry and a category-excludes class, each against a product on the
    # board, base green: both new live cases are ACCEPTED, and each finding is printed as EXPECTED-LIVE-RED.
    $eA = & $runEx $shaB $shaA @($fcLine, $kwLine) $freshX
    $eAl = @($eA.lines | Where-Object { $_ -match '^\s+EXPECTED-LIVE-RED\s' })
    Case 'MUST FIRE' 'a push adding a ruling against a product on the board, base green, is ACCEPTED with EXPECTED-LIVE-RED lines' ($eA.v.code -eq 0 -and $eA.accepted -eq 2 -and $eAl.Count -eq 2 -and ($eAl -join '|').Contains('[StoreB] fx-apple ''Apple Fizz Soda 12 oz''') -and ($eAl -join '|').Contains('next board build clears it') -and $eA.v.detail.Contains('2 accepted as expected')) "code=$($eA.v.code) accepted=$($eA.accepted) arms=$($eA.arms) lines=$($eA.lines -join ' || ')"
    # MUST FIRE: the same ruling pushed over a base where the food-category audit is ALREADY red. That red is a live
    # defect this push did not cause, so the push is refused and the reason says so.
    $eB = & $runEx $shaB2 $shaTB @($fcLine, $kwLine) $freshX
    Case 'MUST FIRE' 'a live case red on BOTH arms (red at the base too) is still REFUSED, and says it was red at the base' ($eB.v.code -eq 1 -and $eB.accepted -eq 0 -and (@($eB.lines) -join '|') -match 'NOT EXPECTED.*red at the base') "code=$($eB.v.code) lines=$($eB.lines -join ' || ')"
    # MUST FIRE: one new failure that is not a live-board ruling case refuses the push exactly as before, with no
    # paired run and no line added.
    $eU = & $runEx $shaB $shaA @($fcLine, $newL) $freshX
    Case 'MUST FIRE' 'a push adding an unrelated failing case beside a live one is REFUSED as before, with no paired run' ($eU.v.code -eq 1 -and $eU.arms -eq 0 -and @($eU.lines).Count -eq 0 -and @($eU.v.newLines).Count -eq 2) "code=$($eU.v.code) arms=$($eU.arms) lines=$(@($eU.lines).Count)"
    # MUST NOT FIRE: the tip's audit could not look (an emptied blocklist is exit 3). Never accepted, and said so.
    $eC = & $runEx $shaB $shaC @($kwLine) $freshX
    Case 'MUST NOT FIRE' 'arm 2 exits 3 (blind) and is NOT accepted, naming the could-not-look' ($eC.v.code -eq 1 -and $eC.accepted -eq 0 -and (@($eC.lines) -join '|') -match 'could not look \(exit 3\)') "code=$($eC.v.code) lines=$($eC.lines -join ' || ')"
    # EDGE: two findings, one flagged by the ruling (the new soda class) and one by a removed allowlist exception,
    # which is not a ruling. The ruling-only arm flags just the first, so the push is refused.
    $eD = & $runEx $shaB $shaD @($fcLine) $freshX
    Case 'MUST FIRE' 'two findings, one explained by the ruling and one not, is REFUSED and names the unexplained one' ($eD.v.code -eq 1 -and $eD.accepted -eq 0 -and $eD.arms -eq 3 -and (@($eD.lines) -join '|') -match '1 of 2 finding.*Pear Nectar Drink') "code=$($eD.v.code) arms=$($eD.arms) lines=$($eD.lines -join ' || ')"
    # MUST NOT FIRE: a stale record is refused as before; the paired run never reaches a push the record cannot judge.
    $staleX = [pscustomobject]@{ state = 'stale'; keys = @(); lines = @(); recordedAt = 'x'; ageHours = 240.0; detail = '240h old'; totalCases = -1 }
    $eS = & $runEx $shaB $shaA @($fcLine) $staleX
    Case 'MUST NOT FIRE' 'with a stale known-failures record a live-case red is refused as before, with no paired run' ($eS.v.code -eq 1 -and $eS.arms -eq 0 -and @($eS.lines).Count -eq 0) "code=$($eS.v.code) arms=$($eS.arms)"
    # The tip's rule files must be the working tree's, compared as git blob ids. Found on gc-fence's dry run: a fresh
    # checkout is CRLF over LF blobs, and a byte compare called its untouched known-wrong.json an uncommitted edit.
    & $gx @('checkout', '-q', '-f', $shaA)
    & $putRule 'known-wrong' ('{"entries":[' + $kwOld + ',' + $kwNew + ']}') "`r`n"
    $eW = & $runEx $shaB $shaA @($kwLine) $freshX
    Case 'MUST NOT FIRE' 'a CRLF working copy of the tip''s LF rule file is not an uncommitted edit, and the ruling is still accepted' ($eW.v.code -eq 0 -and $eW.accepted -eq 1) "code=$($eW.v.code) lines=$($eW.lines -join ' || ')"
    & $putRule 'known-wrong' ('{"entries":[' + $kwOld + ',' + $kwNew + ',' + $kwNew.Replace('apple-fizz', 'apple-fuzz') + ']}')
    $eE = & $runEx $shaB $shaA @($kwLine) $freshX
    Case 'MUST FIRE' 'an uncommitted edit to a rule file refuses: the red test-auditors saw is not the pushed tip''s' ($eE.v.code -eq 1 -and $eE.arms -eq 0 -and (@($eE.lines) -join '|') -match 'differs from the pushed tip') "code=$($eE.v.code) arms=$($eE.arms) lines=$($eE.lines -join ' || ')"
    & $gx @('checkout', '-q', '-f', $shaA)
  } catch {
    $fails += ('expected-live-red cases THREW: ' + $_.Exception.Message)
    "  expected-live-red cases THREW: $($_.Exception.Message)"
  } finally { Remove-Item -LiteralPath $exDir -Recurse -Force -ErrorAction SilentlyContinue }
  # CLEAN TWIN: an ordinary push (only failures the record already holds, or none) comes back byte-identical: the same
  # verdict object, every field unchanged, no line, no arm.
  $v0 = Get-PushVerdict 2 $true @($hyB) $fresh
  $j0 = $v0 | ConvertTo-Json -Depth 4 -Compress
  $e0 = Resolve-ExpectedLiveReds $v0 $fresh $liveCases $RepoRoot 'grocery/' 'b' 't' $env:TEMP
  $vP = Get-PushVerdict 0 $true @() $fresh
  $eP = Resolve-ExpectedLiveReds $vP $fresh $liveCases $RepoRoot 'grocery/' 'b' 't' $env:TEMP
  Case 'MUST NOT FIRE' 'an ordinary push with no new failure keeps its verdict byte-identical (ALLOWED over a recorded case, and PASS)' ([object]::ReferenceEquals($e0.v, $v0) -and ($e0.v | ConvertTo-Json -Depth 4 -Compress) -eq $j0 -and $e0.v.code -eq 0 -and @($e0.lines).Count -eq 0 -and $e0.arms -eq 0 -and [object]::ReferenceEquals($eP.v, $vP) -and $eP.v.verdict -eq 'PASS' -and @($eP.lines).Count -eq 0) "code=$($e0.v.code) lines=$(@($e0.lines).Count) arms=$($e0.arms) pass=$($eP.v.verdict)"

  # A SUITE THAT SILENTLY RAN A SUBSET still prints "N of N". The first run of this file did exactly that:
  # a throw inside the record block skipped five cases and the tally read 30 of 30. The count is pinned.
  $expectedCases = 88
  if ($ran -ne $expectedCases) { $fails += "ran $ran case(s), expected $expectedCases - a block of cases was skipped" }

  ''
  if ($fails.Count -gt 0) {
    "prepush-test-auditors -SelfTest: $($fails.Count) FAILED of $ran"
    $fails | ForEach-Object { "  $_" }
    Exit-Guard -Name $script:GuardName -Code 1 -Summary "failed=$($fails.Count) of $ran"
  }
  "prepush-test-auditors -SelfTest: $ran of $ran cases pass"
  Exit-Guard -Name $script:GuardName -Code 0 -Summary "cases=$ran"
}

# ============================================================================================ SHARED
$taPath = Join-Path $RepoRoot $script:AuditorsRel.Replace('/', '\')
if (-not (Test-Path -LiteralPath $taPath)) {
  "prepush-test-auditors: COULD NOT EVALUATE - $($script:AuditorsRel) is missing, so no guard input can be derived. Not a pass."
  Exit-Guard -Name $script:GuardName -Code 3 -Summary 'blind=no-test-auditors'
}
$taText = [IO.File]::ReadAllText($taPath)
$inputs = Get-AuditorInputs $taText $script:AuditorsRel

# ============================================================================================ RECORD
if ($Record) {
  $rp = Get-RecordPath $RepoRoot
  if (-not $rp) { 'prepush-test-auditors: RECORD NOT WRITTEN - git could not resolve the shared git directory'; Exit-Guard -Name $script:GuardName -Code 3 -Summary 'record=no-git-dir' }
  if (-not $OutputFile -or -not (Test-Path -LiteralPath $OutputFile)) {
    "prepush-test-auditors: RECORD NOT WRITTEN - no test-auditors output at '$OutputFile'; the previous record is kept and ages out"
    Exit-Guard -Name $script:GuardName -Code 3 -Summary 'record=no-output'
  }
  $lines = [IO.File]::ReadAllText($OutputFile, [Text.Encoding]::UTF8) -split "`r?`n"
  $complete = Test-GuardComplete -Output $lines -Name 'test-auditors'
  $fl = Get-FailLines $lines
  # 4 is a verdict since 2026-09-20 (queue 2026-09-19-ae9df2), and its LIVE-RED lines are failing lines here.
  if (-not $complete -or (@(0, 1, 2, 4) -notcontains $ExitCode) -or ((@(2, 4) -contains $ExitCode) -ne ($fl.Count -gt 0))) {
    "prepush-test-auditors: RECORD NOT WRITTEN - that run did not complete as a verdict (rc=$ExitCode, marker=$complete, FAIL lines=$($fl.Count)); the previous record is kept and ages out"
    Exit-Guard -Name $script:GuardName -Code 3 -Summary 'record=incomplete-run'
  }
  $recSum = Get-HarnessSummary $lines
  if ($recSum.selective) {
    "prepush-test-auditors: RECORD NOT WRITTEN - that was a SELECTIVE test-auditors run ($($recSum.unitsRan) unit(s) ran, $($recSum.unitsSkipped) skipped); only a full run is a baseline. The previous record is kept and ages out"
    Exit-Guard -Name $script:GuardName -Code 3 -Summary 'record=selective-run'
  }
  # A RUN OVER IN-FLIGHT GUARD EDITS IS NOT A BASELINE (see the header).
  $st = @(& git -C $RepoRoot -c core.quotepath=off status --porcelain --untracked-files=no 2>$null); $stRc = $LASTEXITCODE
  $up = @(& git -C $RepoRoot -c core.quotepath=off log --format= --name-only --no-renames HEAD --not --remotes 2>$null); $upRc = $LASTEXITCODE
  if ($stRc -ne 0 -or $upRc -ne 0) {
    "prepush-test-auditors: RECORD NOT WRITTEN - git could not say whether any guard input differs from the remote (status rc=$stRc, log rc=$upRc)"
    Exit-Guard -Name $script:GuardName -Code 3 -Summary 'record=git-failed'
  }
  $cand = @()
  foreach ($s in $st) { $x = [string]$s; if ($x.Length -gt 3) { foreach ($part in ($x.Substring(3) -split ' -> ')) { $cand += $part.Trim().Trim('"') } } }
  foreach ($u in $up) { $x = ([string]$u).Trim(); if ($x) { $cand += $x } }
  $inflight = Get-GuardHits $cand $inputs $RepoRoot $true
  if ($inflight.Count -gt 0) {
    "prepush-test-auditors: RECORD NOT WRITTEN - $($inflight.Count) guard input(s) differ from what the remote holds (uncommitted or unpushed), first: $($inflight[0].path) ($($inflight[0].why)). That run measured in-flight edits, not a baseline; the previous record is kept and ages out"
    Exit-Guard -Name $script:GuardName -Code 3 -Summary "record=inflight n=$($inflight.Count)"
  }
  $entries = ConvertTo-Entries $fl
  try { Write-KnownFailures $rp $entries 'daily chain (check-ad-cycles)' $ExitCode ([datetime]::UtcNow) $recSum.cases }
  catch { "prepush-test-auditors: RECORD NOT WRITTEN - $($_.Exception.Message)"; Exit-Guard -Name $script:GuardName -Code 3 -Summary 'record=write-failed' }
  "prepush-test-auditors: RECORDED $($entries.Count) known failing case(s) of $($recSum.cases) from a test-auditors exit $ExitCode to $rp" + $(if ($entries.Count) { ': ' + (@($entries | ForEach-Object { $_.key }) -join '; ') } else { '' })
  Exit-Guard -Name $script:GuardName -Code 0 -Summary "recorded=$($entries.Count)"
}

if ($ListInputs) {
  $null = Add-DotSourceClosure $inputs (Get-TrackedScriptReader $RepoRoot)
  $tracked = @(& git -C $RepoRoot -c core.quotepath=off ls-files 2>$null)
  $hitsL = @($tracked | Where-Object { (Test-GuardInput ([string]$_) $inputs) -ne '' })
  "prepush-test-auditors: resolved $($inputs.code.Count) code name(s) after dot-source closure, $($inputs.data.Count) file name(s), fixture root '$($inputs.fixRoot)', bot-paths loaded=$($script:BotPathsLoaded), globs: " + (@($inputs.globs | ForEach-Object { $_.pattern }) -join ', ')
  "prepush-test-auditors: $($hitsL.Count) of $($tracked.Count) tracked file(s) are test-auditors inputs"
  Exit-Guard -Name $script:GuardName -Code $(if ($tracked.Count -gt 0 -and $hitsL.Count -gt 0) { 0 } else { 3 }) -Summary "tracked=$($tracked.Count) inputs=$($hitsL.Count)"
}

if ($ListUnits -and -not $PathsFile) {
  $lm = Get-UnitModel $taText $script:AuditorsRel
  if (-not $lm.ok) { "prepush-test-auditors: COULD NOT EVALUATE - the unit model could not be built: $($lm.why)"; Exit-Guard -Name $script:GuardName -Code 3 -Summary 'units=unbuildable' }
  "prepush-test-auditors: $($lm.unitCount) unit(s) - $($lm.unitCount - $lm.alwaysCount) derive their inputs from their own code ($($lm.readsCount) also declare -Reads), $($lm.alwaysCount) declared always-run; $($lm.caseSites) case call site(s): $($lm.casesInUnits) in units, $($lm.casesInFns) in helper functions, $($lm.casesOutside) outside any unit; harness: $($lm.harness -join ', '); built in $($lm.ms)ms"
  foreach ($e in @($lm.entries | Where-Object { $_.unit })) {
    '  {0,-44} cases={1,-3} runs=[{2}] reads=[{3}] fixtures=[{4}] globs=[{5}] declared=[{6}] needs=[{7}]' -f $e.id, $e.facts.cases, (@($e.run.Keys) -join ' '), (@($e.read.Keys) -join ' '), ($e.fixPrefixes -join ' '), ($e.globs -join ' '), $(if ($e.always) { 'ALWAYS: ' + $e.always } else { $e.reads -join ' ' }), (@($e.needs.Keys) -join ' ')
  }
  Exit-Guard -Name $script:GuardName -Code 0 -Summary "units=$($lm.unitCount) always=$($lm.alwaysCount) sites=$($lm.caseSites) outside=$($lm.casesOutside)"
}

if (-not $RefsFromStdin -and -not $PathsFile) {
  'usage: prepush-test-auditors.ps1 -RefsFromStdin | -PathsFile <file> [-ListUnits] | -Record -OutputFile <file> -ExitCode <rc> | -ListInputs | -ListUnits | -SelfTest'
  Exit-Guard -Name $script:GuardName -Code 3 -Summary 'blind=no-mode'
}

# ============================================================================================ PRE-PUSH
$paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$unknown = ''; $refCount = 0; $pushTips = @()
if ($PathsFile) {
  if (-not (Test-Path -LiteralPath $PathsFile)) { "prepush-test-auditors: COULD NOT EVALUATE - no paths file at '$PathsFile'"; Exit-Guard -Name $script:GuardName -Code 3 -Summary 'blind=no-paths-file' }
  foreach ($ln in [IO.File]::ReadAllLines($PathsFile)) { $t = $ln.Trim().Replace('\', '/'); if ($t -and -not $t.StartsWith('#')) { [void]$paths.Add($t) } }
  $refCount = 1
} else {
  $refLines = @(([Console]::In.ReadToEnd()) -split "`r?`n" | Where-Object { $_.Trim() })
  foreach ($ln in $refLines) {
    $f = @(([string]$ln).Trim() -split '\s+')
    if ($f.Count -lt 4 -or $f[1] -notmatch '[^0]') { continue }
    $refCount++
    $pushTips += ,@($f[1], $f[3])
    # Commits being pushed that no remote-tracking ref already holds. A stale tracking ref only widens this.
    $out = @(& git -C $RepoRoot -c core.quotepath=off log --format= --name-only --no-renames -m $f[1] --not --remotes 2>$null)
    if ($LASTEXITCODE -ne 0) { $unknown = "git could not list the commits of $($f[1])"; continue }
    foreach ($o in $out) { $t = ([string]$o).Trim(); if ($t) { [void]$paths.Add($t) } }
  }
}

$hits = @()
$sel = [pscustomobject]@{ mode = 'full'; why = ''; selected = @(); skipped = @(); attributed = @{}; needed = @(); always = @() }
$model = $null
if (-not $unknown) {
  $hits = Get-GuardHits @($paths) $inputs $RepoRoot
  if ($hits.Count -eq 0) {
    "prepush-test-auditors: NOT NEEDED - $($paths.Count) pushed path(s) across $refCount ref(s), none is a test-auditors input (derived from $($script:AuditorsRel): $($inputs.code.Count) script name(s), $($inputs.data.Count) file name(s), $($inputs.globs.Count) glob(s), fixture root $($inputs.fixRoot)). test-auditors did not run."
    Exit-Guard -Name $script:GuardName -Code 0 -Summary "pushed=$($paths.Count) inputs=0"
  }
  "prepush-test-auditors: $($hits.Count) of $($paths.Count) pushed path(s) are test-auditors inputs, first: $($hits[0].path) ($($hits[0].why))"
  $swSel = [Diagnostics.Stopwatch]::StartNew()
  $model = Get-UnitModel $taText $script:AuditorsRel
  $sel = Get-Selection @($paths) @($hits | ForEach-Object { $_.path }) $model $inputs (Get-TrackedScriptReader $RepoRoot) @{}
  $swSel.Stop()
  if ($sel.mode -eq 'selective') {
    "prepush-test-auditors: SELECTIVE - $($sel.why), from $($paths.Count) pushed path(s); $($sel.skipped.Count) unit(s) this push cannot reach will not run (selection took $([int]$swSel.Elapsed.TotalMilliseconds)ms)"
    "prepush-test-auditors: selected: $($sel.selected -join ', ')"
  } else {
    "prepush-test-auditors: FULL RUN - $($sel.why)"
  }
} else {
  "prepush-test-auditors: $unknown, so every push is treated as touching a guard input and the run is full"
}

$boardPatterns = Get-BoardPatterns $taText $script:AuditorsRel
if ($boardPatterns.Count -eq 0) {
  "prepush-test-auditors: COULD NOT EVALUATE - no `$HasBoard test was found in $($script:AuditorsRel), so whether this checkout has the boards it reads cannot be decided. THIS IS NOT A PASS."
  Exit-Guard -Name $script:GuardName -Code 3 -Summary 'blind=no-board-test'
}
if (-not (Test-HasBoard $RepoRoot $boardPatterns)) {
  "prepush-test-auditors: COULD NOT EVALUATE - this checkout ($RepoRoot) has none of the board files test-auditors looks for ($($boardPatterns -join ', ')), so test-auditors would skip its live-board cases and its verdict would prove nothing. THIS IS NOT A PASS."
  "prepush-test-auditors: push from the main checkout, or copy the boards in (ops\seed-worktree.ps1, .worktreeinclude) and push again."
  Exit-Guard -Name $script:GuardName -Code 3 -Summary 'blind=no-board'
}
if ($ListUnits) {
  foreach ($k in @($script:AttribWhy.Keys | Sort-Object)) { '  reached  {0,-70} {1}' -f $k, $script:AttribWhy[$k] }
  if ($null -ne $model -and $model.ok) { foreach ($id in @($sel.needed)) { foreach ($e in @($model.entries | Where-Object { $_.unit -and $_.needs.ContainsKey($id) -and $sel.selected -contains $_.id })) { '  needed   {0,-44} by {1,-44} for {2}' -f $id, $e.id, $e.needs[$id] } } }
  "prepush-test-auditors: -ListUnits: selection printed above; test-auditors did not run."
  Exit-Guard -Name $script:GuardName -Code 0 -Summary "mode=$($sel.mode) selected=$($sel.selected.Count) skipped=$($sel.skipped.Count)"
}

# PASS REUSE (see the PASS REUSE block above): only for a real push, never for -PathsFile measurement.
$passPath = ''; $passKey = $null
if ($RefsFromStdin -and -not $PathsFile) {
  $passPath = Get-PassRecordPath $RepoRoot
  $passKey = Get-TaInputKey $RepoRoot $inputs $boardPatterns
  if (-not $passKey.ok) {
    "prepush-test-auditors: no pass can be reused - the input key could not be computed ($($passKey.why)); running"
  } elseif (-not $passPath) {
    "prepush-test-auditors: no pass can be reused - git could not resolve the shared git directory; running"
  } else {
    $pr = Read-TaPassRecord $passPath $passKey.key ([datetime]::UtcNow) $script:PassMaxAgeHours $sel.mode @($sel.selected)
    if ($pr.reuse) {
      $rKnown = Read-KnownFailures (Get-RecordPath $RepoRoot) ([datetime]::UtcNow) $script:MaxAgeHours
      $rSel = ($sel.mode -eq 'selective')
      $rFail = @($pr.rec.fail_lines | ForEach-Object { [string]$_ } | Where-Object { $_ })
      $rv = Get-PushVerdict ([int]$pr.rec.rc) $true $rFail $rKnown $rSel $(if ($rSel) { 'selected cases of the recorded run' } else { 'full run' })
      if ($rv.code -eq 0) {
        Format-ReuseLine $passKey.key $pr $passKey
        "prepush-test-auditors: $($rv.verdict) (reused) - $($rv.detail)."
        foreach ($l in $rv.oldLines) { $s = $l -replace '^FAIL\s+', ''; '  ALREADY FAILING       ' + $(if ($s.Length -gt 300) { $s.Substring(0, 300) + '...' } else { $s }) }
        Exit-Guard -Name $script:GuardName -Code 0 -Summary "pushed=$($paths.Count) inputs=$($hits.Count) mode=$($sel.mode) reused=$($passKey.key) failing=$($rFail.Count)"
      }
      "prepush-test-auditors: the recorded pass for key=$($passKey.key) no longer passes against the current known-failures record ($($rv.detail)); running"
    } else {
      "prepush-test-auditors: no pass reused (key=$($passKey.key)) - $($pr.why); running"
    }
  }
}

$stamp = [guid]::NewGuid().ToString('N').Substring(0, 8)
$stem = Join-Path $env:TEMP ("tc-prepush-ta-$PID-$stamp")
$skipF = ''
$taExtra = @()
if ($sel.mode -eq 'selective') {
  $skipF = $stem + '.skip'
  [IO.File]::WriteAllLines($skipF, [string[]]@($sel.skipped), (New-Object Text.UTF8Encoding($false)))
  $taExtra = @('-SkipUnitsFile', ('"' + $skipF + '"'))
  "prepush-test-auditors: running $($script:AuditorsRel) on $($sel.selected.Count) of $($model.unitCount) unit(s) (a full run measured $($script:MeasuredSeconds)s on 2026-09-10, bound $($script:TimeoutSeconds)s)"
} else {
  "prepush-test-auditors: running $($script:AuditorsRel) in full (measured $($script:MeasuredSeconds)s on 2026-09-10, bound $($script:TimeoutSeconds)s)"
}
$run = Invoke-TaChild $taPath $taExtra $stem $script:TimeoutSeconds
if ($run.startError) { "prepush-test-auditors: could not start test-auditors: $($run.startError)" }
$rc = $run.rc
$lines = $run.lines
if ($skipF) { Remove-Item -LiteralPath $skipF -ErrorAction SilentlyContinue }
$complete = Test-GuardComplete -Output $lines -Name 'test-auditors'
$fl = Get-FailLines $lines
$hs = Get-HarnessSummary $lines
$rp = Get-RecordPath $RepoRoot
$known = Read-KnownFailures $rp ([datetime]::UtcNow) $script:MaxAgeHours
$isSelective = ($sel.mode -eq 'selective')
$totalText = if ($known.totalCases -ge 0) { [string]$known.totalCases } else { 'an unrecorded number of' }
$ranNote = if ($isSelective) { ('' + $(if ($hs.cases -ge 0) { $hs.cases } else { '?' }) + ' selected case(s)') } else { 'full run' }
if ($isSelective -and $complete -and -not $hs.selective) {
  # The harness ran every unit anyway (a skip file it could not read, or an older harness). That is a full run.
  $isSelective = $false; $ranNote = 'full run'
  "prepush-test-auditors: the harness did not report a selective run, so it ran every unit; treating this as a full run"
}
$v = Get-PushVerdict $rc $complete $fl $known $isSelective $ranNote
$secs = $run.secs
# EXPECTED LIVE RED (see its block above): a real push only, and only one pushed tip, since a paired run measures one
# rule change. Otherwise $v is untouched.
$expected = [pscustomobject]@{ v = $v; lines = @(); accepted = 0; findings = 0; arms = 0 }
if ($RefsFromStdin -and -not $PathsFile -and $v.code -eq 1) {
  $tipSet = @($pushTips | ForEach-Object { $_[0] } | Sort-Object -Unique)
  $eTip = ''; $eBase = ''
  if ($tipSet.Count -eq 1) { $eTip = [string]$tipSet[0]; $eRemote = [string](@($pushTips | Where-Object { $_[0] -eq $eTip })[0][1]); $eBase = Get-PushBase $RepoRoot $eTip $eRemote }
  $selfDirE = $script:AuditorsRel.Substring(0, $script:AuditorsRel.LastIndexOf('/') + 1)
  $expected = Resolve-ExpectedLiveReds $v $known (Get-LiveRulingCases $taText) $RepoRoot $selfDirE $eBase $eTip (Join-Path $RepoRoot ($selfDirE.Replace('/', '\') + 'out'))
  $v = $expected.v
}

if ($isSelective -and $hs.found) {
  "prepush-test-auditors: ran $($hs.cases) of $totalText cases ($($hs.unitsRan) of $($hs.unitsRan + $hs.unitsSkipped) units), selected by $($paths.Count) pushed path(s)."
} elseif ($complete -and $hs.cases -ge 0) {
  "prepush-test-auditors: ran all $($hs.cases) cases (full run)."
}
"prepush-test-auditors: $($v.verdict) after ${secs}s - $($v.detail)."
foreach ($l in $v.newLines) { $s = $l -replace '^FAIL\s+', ''; '  NEW FAILING CASE      ' + $(if ($s.Length -gt 300) { $s.Substring(0, 300) + '...' } else { $s }) }
foreach ($l in $v.oldLines) { $s = $l -replace '^FAIL\s+', ''; '  ALREADY FAILING       ' + $(if ($s.Length -gt 300) { $s.Substring(0, 300) + '...' } else { $s }) }
foreach ($l in @($expected.lines)) { $l }
Complete-TaChildFiles $run $v.code

if ($passPath -and $null -ne $passKey -and $passKey.ok) {
  # An expected live red is never recorded as a pass: a reuse re-judges only against the known-failures record, which
  # does not hold these cases, so a retry pays the paired run again rather than replaying an acceptance.
  if ($v.code -eq 0 -and $expected.accepted -eq 0) {
    $after = Get-TaInputKey $RepoRoot $inputs $boardPatterns
    if ($after.ok -and [string]::Equals($after.key, $passKey.key, [StringComparison]::Ordinal)) {
      try { Write-TaPassRecord $passPath $passKey.key $rc $fl $(if ($isSelective) { 'selective' } else { 'full' }) @($sel.selected) $hs.cases ([datetime]::UtcNow); "prepush-test-auditors: pass recorded for key=$($passKey.key), so a retry over the same input content reuses it" }
      catch { "prepush-test-auditors: the pass record could not be written: $($_.Exception.Message)" }
    } else {
      Remove-Item -LiteralPath $passPath -Force -ErrorAction SilentlyContinue
      "prepush-test-auditors: pass NOT recorded - an input moved during the run (key before $($passKey.key), after $($after.key) $($after.why))"
    }
  } else {
    Remove-Item -LiteralPath $passPath -Force -ErrorAction SilentlyContinue
  }
}

if ($v.code -eq 0 -and $rp -and -not $PathsFile) {
  if ($isSelective) {
    "prepush-test-auditors: the known-failures record is not written by a selective run (it cannot tell a recorded case that passed from one it did not run)."
  } else {
    $conf = Get-ConfirmedEntries $fl $known
    if ($null -ne $conf) {
      $tot = if ($hs.cases -ge 0) { $hs.cases } else { $known.totalCases }
      try { Write-KnownFailures $rp $conf 'pre-push (confirm or shrink only)' $rc ([datetime]::UtcNow) $tot } catch { "prepush-test-auditors: the record could not be refreshed: $($_.Exception.Message)" }
    }
  }
}
Exit-Guard -Name $script:GuardName -Code $v.code -Summary ("pushed=$($paths.Count) inputs=$($hits.Count) mode=$($sel.mode) units=$($sel.selected.Count) rc=$rc cases=$($hs.cases) failing=$($fl.Count) new=$($v.newLines.Count) seconds=$secs" + $(if ($expected.accepted -gt 0) { " expected=$($expected.accepted)" } else { '' }))
