<#
  prepush-test-auditors.ps1 - before a push that touches one of grocery\test-auditors.ps1's inputs, run
  test-auditors and refuse the push only when it adds a failing case that was not already failing.

  WHY IT EXISTS (2026-09-10, design\PLAN-zero-alert-days-2026-09-10.md Phase 5, build step 5). Three
  "a GUARD has gone blind" alerts in 20 days were self-inflicted by a triage session's own in-flight edits
  (2026-08-30, and twice on 2026-08-31), and queue item 2026-09-10-4ac6ae was a commit that broke
  test-auditors getting past a clean pre-push gate. ops\run-gates.ps1 cannot reach test-auditors: it is
  data-dependent (it reads the gitignored boards), and run-gates is hermetic by design. So the hook runs
  this AFTER run-gates passes.

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

  HOW "ALREADY FAILING" IS DECIDED: a known-failures record in the SHARED git directory
  (<git-common-dir>\tc-test-auditors-known-failures.json), so every linked worktree reads the same one
  and nothing about it can be committed. Chosen over a second test-auditors run against origin/main
  because that run would need its own seeded checkout of the boards and would double a six-minute push.
    * ONLY THE DAILY CHAIN ADDS A CASE. grocery\check-ad-cycles.ps1 calls -Record with the output of its
      own test-auditors run, which already paged any failure it holds. A push-time run may only CONFIRM
      or SHRINK the record, so a refused push can never launder its own failure by being retried.
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
    -Record -OutputFile <file> -ExitCode <rc>
                     the daily chain: record the failing cases of a completed test-auditors run.
    -ListInputs      print what the input derivation resolved over the tracked tree.
    -SelfTest        frozen cases; discovered by ops\run-gates.ps1.

  SCOPE OF A CLEAN REPORT: UNSOUND. The input set is read from the text of test-auditors.ps1, so a file a
  child script reaches through a computed path, or a data file named only inside a child, is not an
  input and a push touching only that does not run the suite. It runs against the WORKING TREE, not the
  pushed commit, so another session's uncommitted edit can refuse (never pass) a push. Two failures whose
  messages share a key are one case to it, so a push that worsens an already-failing case is not refused.
  The record's in-flight check counts code, fixture and harness inputs only (rules 1-4), so a hand edit to
  a named rule file such as commodities.json that is uncommitted when the chain records can be recorded as
  already failing; counting those files would refuse nearly every morning's record (see Test-GuardInput).
#>
[CmdletBinding()]
param(
  [switch]$RefsFromStdin,
  [switch]$Record,
  [string]$OutputFile,
  [int]$ExitCode = -1,
  [switch]$ListInputs,
  [switch]$SelfTest
)

$ErrorActionPreference = 'Continue'
$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoRoot 'lib\guard-contract.ps1')
# The bot's ownership set. Absent, nothing is treated as bot-owned, which only makes the suite run MORE.
$script:BotPathsLoaded = $false
$bpLib = Join-Path $RepoRoot 'lib\bot-paths.ps1'
if (Test-Path -LiteralPath $bpLib) { . $bpLib; $script:BotPathsLoaded = $true }

# The hook already clears these; clear them again so a caller that is not the hook cannot hand this
# script's git calls, or the test-auditors it spawns, a linked worktree's GIT_DIR.
foreach ($v in @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR', 'GIT_OBJECT_DIRECTORY',
                 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_PREFIX', 'GIT_NAMESPACE')) {
  Remove-Item -LiteralPath ("Env:\" + $v) -ErrorAction SilentlyContinue
}

$script:GuardName = 'PREPUSH-TEST-AUDITORS'
$script:MaxAgeHours = 192        # see the header: 7-day chain cadence + 24h; first plausible value, no sweep
$script:TimeoutSeconds = 1200    # the same bound check-ad-cycles gives this suite
$script:MeasuredSeconds = 359    # test-auditors wall time measured 2026-09-10 in the main checkout
$script:AuditorsRel = 'grocery/test-auditors.ps1'
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
  return @(@($Lines) | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^\s{0,4}FAIL\s{2}' } | ForEach-Object { $_.Trim() })
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
  return [pscustomobject]@{ self = $SelfRel; fixRoot = $fixRoot; globs = $globs; code = $code; data = $data; botOwned = $owned }
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
# script is still unmatched after the cheap rules.
function Get-GuardHits([string[]]$Paths, $Inputs, [string]$Root, [bool]$CodeOnly = $false) {
  $hits = @(); $pending = @()
  foreach ($p in @($Paths | Where-Object { $_ })) {
    $why = Test-GuardInput $p $Inputs $CodeOnly
    if ($why) { $hits += "$p ($why)" } elseif ($p -match '\.(ps1|psm1)$') { $pending += $p }
  }
  if ($hits.Count -eq 0 -and $pending.Count -gt 0) {
    $null = Add-DotSourceClosure $Inputs (Get-TrackedScriptReader $Root)
    foreach ($p in $pending) { $why = Test-GuardInput $p $Inputs $CodeOnly; if ($why) { $hits += "$p ($why)" } }
  }
  return ,$hits
}

function Read-KnownFailures([string]$Path, [datetime]$NowUtc, [int]$MaxAgeHours) {
  $r = [pscustomobject]@{ state = 'missing'; keys = @(); lines = @(); recordedAt = ''; ageHours = -1.0; detail = '' }
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
    $r.ageHours = [math]::Round(($NowUtc - $at).TotalHours, 1)
    if ($r.ageHours -lt -1) { $r.state = 'unreadable'; $r.detail = ('recorded in the future: ' + $r.recordedAt); return $r }
    if ($r.ageHours -gt $MaxAgeHours) { $r.state = 'stale'; $r.detail = ('recorded ' + $r.recordedAt + ', ' + $r.ageHours + 'h old, limit ' + $MaxAgeHours + 'h'); return $r }
    $r.state = 'fresh'; $r.detail = ('recorded ' + $r.recordedAt + ', ' + $r.ageHours + 'h old')
  } catch { $r.state = 'unreadable'; $r.detail = $_.Exception.Message }
  return $r
}

function Write-KnownFailures([string]$Path, [object[]]$Entries, [string]$Writer, [int]$Rc, [datetime]$NowUtc) {
  $obj = [ordered]@{ schema = 1; recorded_at = $NowUtc.ToString('o'); writer = $Writer; test_auditors_rc = $Rc; failing = @($Entries) }
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

# A push-time run may CONFIRM or SHRINK the record, never add to it. $null means "do not write".
function Get-ConfirmedEntries([string[]]$FailLines, $Known) {
  $current = ConvertTo-Entries $FailLines
  if ($Known.state -eq 'fresh') { return ,@($current | Where-Object { $Known.keys -contains $_.key }) }
  if ($current.Count -eq 0) { return ,@() }
  return $null
}

function Get-PushVerdict([int]$Rc, [bool]$Complete, [string[]]$FailLines, $Known) {
  $fails = @($FailLines | Where-Object { $_ })
  $v = [pscustomobject]@{ code = 3; verdict = 'COULD NOT EVALUATE'; detail = ''; newLines = @(); oldLines = @() }
  if (-not $Complete) { $v.detail = 'test-auditors did not end with its completion marker (it crashed, timed out, or was killed)'; return $v }
  if (@(0, 1, 2) -notcontains $Rc) { $v.detail = ('test-auditors exited ' + $Rc + ', which is not one of its verdicts (0, 1, 2)'); return $v }
  if (($Rc -eq 2) -ne ($fails.Count -gt 0)) { $v.detail = ('test-auditors exited ' + $Rc + ' with ' + $fails.Count + ' FAIL line(s); the FAIL format this check reads no longer matches its exit code'); return $v }
  if ($fails.Count -eq 0) { $v.code = 0; $v.verdict = 'PASS'; $v.detail = ('test-auditors exited ' + $Rc + ' with no failing case'); return $v }
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
    $v.detail = ('test-auditors has ' + $fails.Count + ' failing case(s), every one already in the known-failures record (' + $Known.detail + '); this push added none. That is not a pass')
  }
  return $v
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
  $fresh = [pscustomobject]@{ state = 'fresh'; keys = @((Get-CaseKey $hyA)); lines = @($hyA); recordedAt = 'x'; ageHours = 2.0; detail = 'recorded x' }
  $v = Get-PushVerdict 2 $true @($hyB) $fresh
  Case 'CLEAN TWIN' 'a failure already in the record allows an unrelated guard push and is still listed' ($v.code -eq 0 -and $v.oldLines.Count -eq 1) "code=$($v.code)"
  $v = Get-PushVerdict 2 $true @($hyB, $newL) $fresh
  Case 'MUST FIRE' 'a push that adds a failing case is refused and names that case' ($v.code -eq 1 -and ($v.newLines -join '|') -match 'OkUnlessBlind' -and $v.oldLines.Count -eq 1) "code=$($v.code)"
  $stale = [pscustomobject]@{ state = 'stale'; keys = @((Get-CaseKey $hyA)); lines = @(); recordedAt = 'x'; ageHours = 240.0; detail = '240h old' }
  $v = Get-PushVerdict 2 $true @($hyB) $stale
  Case 'MUST FIRE' 'a stale record does not let even a recorded case through' ($v.code -eq 1) "code=$($v.code)"
  $unread = [pscustomobject]@{ state = 'unreadable'; keys = @(); lines = @(); recordedAt = ''; ageHours = -1.0; detail = 'bad json' }
  $v = Get-PushVerdict 2 $true @($hyB) $unread
  Case 'MUST FIRE' 'an unreadable record refuses a push with any failing case' ($v.code -eq 1) "code=$($v.code)"
  $v = Get-PushVerdict 2 $false @($hyB) $fresh
  Case 'MUST FIRE' 'a run with no completion marker could not evaluate' ($v.code -eq 3) "code=$($v.code)"
  $v = Get-PushVerdict 2 $true @() $fresh
  Case 'MUST FIRE' 'exit 2 with no readable FAIL line could not evaluate' ($v.code -eq 3) "code=$($v.code)"
  $v = Get-PushVerdict 0 $true @() $unread
  Case 'CLEAN TWIN' 'a clean run still passes with no usable record' ($v.code -eq 0 -and $v.verdict -eq 'PASS') "code=$($v.code)"

  $conf = Get-ConfirmedEntries @($newL) $fresh
  Case 'MUST FIRE' 'a push-time run never writes a case the record lacks' ($null -ne $conf -and @($conf | Where-Object { $_.key -eq (Get-CaseKey $newL) }).Count -eq 0)
  Case 'MUST FIRE' 'with no fresh record a push-time run with failures writes nothing' ($null -eq (Get-ConfirmedEntries @($hyA) $stale))
  $conf = Get-ConfirmedEntries @($hyB) $fresh
  Case 'CLEAN TWIN' 'a push-time run still confirms a case the record holds' ($null -ne $conf -and $conf.Count -eq 1)

  $tmpDir = Join-Path $env:TEMP ('tc-prepush-ta-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $null = New-Item -ItemType Directory -Force $tmpDir
  try {
    $rp = Join-Path $tmpDir 'known.json'
    Write-KnownFailures $rp (ConvertTo-Entries @($hyA)) 'self-test' 2 $now
    $k = Read-KnownFailures $rp $now 192
    Case 'CLEAN TWIN' 'a record written now reads back fresh with its case' ($k.state -eq 'fresh' -and $k.keys.Count -eq 1 -and $k.keys[0] -eq (Get-CaseKey $hyA)) "state=$($k.state) $($k.detail)"
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

  # A SUITE THAT SILENTLY RAN A SUBSET still prints "N of N". The first run of this file did exactly that:
  # a throw inside the record block skipped five cases and the tally read 30 of 30. The count is pinned.
  $expectedCases = 41
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
  if (-not $complete -or (@(0, 1, 2) -notcontains $ExitCode) -or (($ExitCode -eq 2) -ne ($fl.Count -gt 0))) {
    "prepush-test-auditors: RECORD NOT WRITTEN - that run did not complete as a verdict (rc=$ExitCode, marker=$complete, FAIL lines=$($fl.Count)); the previous record is kept and ages out"
    Exit-Guard -Name $script:GuardName -Code 3 -Summary 'record=incomplete-run'
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
    "prepush-test-auditors: RECORD NOT WRITTEN - $($inflight.Count) guard input(s) differ from what the remote holds (uncommitted or unpushed), first: $($inflight[0]). That run measured in-flight edits, not a baseline; the previous record is kept and ages out"
    Exit-Guard -Name $script:GuardName -Code 3 -Summary "record=inflight n=$($inflight.Count)"
  }
  $entries = ConvertTo-Entries $fl
  try { Write-KnownFailures $rp $entries 'daily chain (check-ad-cycles)' $ExitCode ([datetime]::UtcNow) }
  catch { "prepush-test-auditors: RECORD NOT WRITTEN - $($_.Exception.Message)"; Exit-Guard -Name $script:GuardName -Code 3 -Summary 'record=write-failed' }
  "prepush-test-auditors: RECORDED $($entries.Count) known failing case(s) from a test-auditors exit $ExitCode to $rp" + $(if ($entries.Count) { ': ' + (@($entries | ForEach-Object { $_.key }) -join '; ') } else { '' })
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

if (-not $RefsFromStdin) {
  'usage: prepush-test-auditors.ps1 -RefsFromStdin | -Record -OutputFile <file> -ExitCode <rc> | -ListInputs | -SelfTest'
  Exit-Guard -Name $script:GuardName -Code 3 -Summary 'blind=no-mode'
}

# ============================================================================================ PRE-PUSH
$refLines = @(([Console]::In.ReadToEnd()) -split "`r?`n" | Where-Object { $_.Trim() })
$paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$unknown = ''; $refCount = 0
foreach ($ln in $refLines) {
  $f = @(([string]$ln).Trim() -split '\s+')
  if ($f.Count -lt 4 -or $f[1] -notmatch '[^0]') { continue }
  $refCount++
  # Commits being pushed that no remote-tracking ref already holds. A stale tracking ref only widens this.
  $out = @(& git -C $RepoRoot -c core.quotepath=off log --format= --name-only --no-renames -m $f[1] --not --remotes 2>$null)
  if ($LASTEXITCODE -ne 0) { $unknown = "git could not list the commits of $($f[1])"; continue }
  foreach ($o in $out) { $t = ([string]$o).Trim(); if ($t) { [void]$paths.Add($t) } }
}

$hits = @()
if (-not $unknown) {
  $hits = Get-GuardHits @($paths) $inputs $RepoRoot
  if ($hits.Count -eq 0) {
    "prepush-test-auditors: NOT NEEDED - $($paths.Count) pushed path(s) across $refCount ref(s), none is a test-auditors input (derived from $($script:AuditorsRel): $($inputs.code.Count) script name(s), $($inputs.data.Count) file name(s), $($inputs.globs.Count) glob(s), fixture root $($inputs.fixRoot)). test-auditors did not run."
    Exit-Guard -Name $script:GuardName -Code 0 -Summary "pushed=$($paths.Count) inputs=0"
  }
  "prepush-test-auditors: $($hits.Count) of $($paths.Count) pushed path(s) are test-auditors inputs, first: $($hits[0])"
} else {
  "prepush-test-auditors: $unknown, so every push is treated as touching a guard input"
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

"prepush-test-auditors: running $($script:AuditorsRel) (measured $($script:MeasuredSeconds)s on 2026-09-10, bound $($script:TimeoutSeconds)s)"
$stamp = [guid]::NewGuid().ToString('N').Substring(0, 8)
$outF = Join-Path $env:TEMP ("tc-prepush-ta-$PID-$stamp.out")
$errF = Join-Path $env:TEMP ("tc-prepush-ta-$PID-$stamp.err")
$sw = [Diagnostics.Stopwatch]::StartNew()
$rc = 124
try {
  $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $taPath + '"')) `
    -WorkingDirectory $RepoRoot -NoNewWindow -PassThru -RedirectStandardOutput $outF -RedirectStandardError $errF
  $null = $proc.Handle
  if ($proc.WaitForExit($script:TimeoutSeconds * 1000)) { $proc.WaitForExit(); $rc = $proc.ExitCode }
  else { $null = & taskkill.exe /PID $proc.Id /T /F 2>$null }
} catch { "prepush-test-auditors: could not start test-auditors: $($_.Exception.Message)" }
$sw.Stop()
$lines = @(); if (Test-Path -LiteralPath $outF) { $lines = @([IO.File]::ReadAllLines($outF)) }
Remove-Item -LiteralPath $errF -ErrorAction SilentlyContinue
$complete = Test-GuardComplete -Output $lines -Name 'test-auditors'
$fl = Get-FailLines $lines
$rp = Get-RecordPath $RepoRoot
$known = Read-KnownFailures $rp ([datetime]::UtcNow) $script:MaxAgeHours
$v = Get-PushVerdict $rc $complete $fl $known
$secs = [int]$sw.Elapsed.TotalSeconds

"prepush-test-auditors: $($v.verdict) after ${secs}s - $($v.detail)."
foreach ($l in $v.newLines) { $s = $l -replace '^FAIL\s+', ''; '  NEW FAILING CASE      ' + $(if ($s.Length -gt 300) { $s.Substring(0, 300) + '...' } else { $s }) }
foreach ($l in $v.oldLines) { $s = $l -replace '^FAIL\s+', ''; '  ALREADY FAILING       ' + $(if ($s.Length -gt 300) { $s.Substring(0, 300) + '...' } else { $s }) }
if ($v.code -eq 0) { Remove-Item -LiteralPath $outF -ErrorAction SilentlyContinue }
else {
  if ($v.code -eq 3) { "prepush-test-auditors: last lines test-auditors printed: " + (@($lines | Select-Object -Last 3) -join ' | ') }
  "prepush-test-auditors: the full test-auditors output is kept at $outF"
}

if ($v.code -eq 0 -and $rp) {
  $conf = Get-ConfirmedEntries $fl $known
  if ($null -ne $conf) {
    try { Write-KnownFailures $rp $conf 'pre-push (confirm or shrink only)' $rc ([datetime]::UtcNow) } catch { "prepush-test-auditors: the record could not be refreshed: $($_.Exception.Message)" }
  }
}
Exit-Guard -Name $script:GuardName -Code $v.code -Summary "pushed=$($paths.Count) inputs=$($hits.Count) rc=$rc failing=$($fl.Count) new=$($v.newLines.Count) seconds=$secs"
