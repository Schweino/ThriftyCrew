<#
  rehearse-chain.ps1 - a change to the daily chain meets yesterday's real data BEFORE it pushes, so the 07:00 run
  is no longer its first integration test.

  WHY (2026-09-22, RCA F2 in design\RCA-holistic-2026-09-22.md, plan grocery\triage-plans\plan-2026-09-22-7.json).
  19 of the last 28 daily runs ended with a FAILED LANE, and 8 of the defects of 09-20 to 09-22 passed run-gates and
  failed on the next real board. The founder: a 09-21 change emptied meal-prep\db\cost-flags.txt, the pre-commit
  verify-bulk-edit read the empty file as a stripped BOM and refused the whole daily commit, and readers got the
  previous day's prices for five hours. run-gates is hermetic by design; nothing between it and the bot ran the chain
  over real data, so a change whose inputs are the pipeline's own outputs met them first in production.

  MODES
    (default)   rehearse one commit:  powershell -File ops\rehearse-chain.ps1 [-Commit HEAD] [-Source <main checkout>]
    -CheckPush  THE PRE-PUSH LEG. Reads git's ref lines (-RefsFromStdin or -RefsFile) and decides from a RECORDED
                verdict in seconds. It never rehearses, so nothing slow ever runs inside the push lock.
    -ForPush    PUSH-MAIN'S LEG, run OUTSIDE the push lock: when HEAD's push to <Remote>/<Branch> touches the manifest
                and no usable verdict is recorded, it rehearses HEAD, then decides exactly as -CheckPush will.
    -SelfTest   hermetic fixtures, per-run temp directories, nothing live.

  THREE OUTCOMES, NEVER TWO. Every mode ends in one of them, printed as its last line:
    exit 0  pass     rehearsed and passed (or, at push time, no manifest script changed, or -NoRehearsal)
    exit 1  fail     rehearsed and a stage FAILED; the stage and its own words are printed
    exit 3  blind    COULD NOT REHEARSE, with blind=<cause>: no-source, no-seed-board, stale-data, clone-failed,
                     checkout-failed, seed-failed, credential-present, chain-missing, nopublish-unproven, shiponly-unproven,
                     no-chain-verdict, commit-stage, cannot-read-push, cannot-diff, no-manifest-readable. A 3 is never a
                     pass and never a silent refusal: the cause is on the line, as run-gates' blind= token is.

  WHAT ONE REHEARSAL IS (one ARM):
    1. a STANDALONE clone (`git clone --shared`) of the commit into %TEMP%\tc-rh-<id>\<arm>, never a linked worktree:
       its own index, its own hooks, objects read through alternates, nothing written to the shared .git. A clone is
       also what makes grocery\alert-lib.ps1 send through the CLONE'S sender (a linked worktree would route through the
       main checkout's, with the real credential and the real triage queue).
    2. its push URL points at a path that does not exist, so no stage can push anywhere.
    3. seeded from the main checkout by ops\seed-worktree.ps1 (the gitignored boards, captures and built cards), and
       then REFUSED (blind=credential-present) if the mail credential or the Ghost key file arrived with the seed.
    4. the rehearsed tree's own check-ad-cycles -SelfTest must pass its -NoPublish case, or it is not run
       (blind=nopublish-unproven): a tree whose -NoPublish does not hold every reader-facing writer is never started.
    5. check-ad-cycles -NoPull -NoCommit -NoPublish -NoAlert -ShipOnly (the ship path, ~14 of the chain's ~40 minutes;
       -Full runs INSPECT too), in a child whose environment carries a SENTINEL Ghost
       key (every Ghost call answers 401), sentinel Kroger credentials, TC_REHEARSAL=1, and no GIT_* variable.
    6. the chain's own guard verdict (grocery\out\chain-verdict.json, written by THIS run or the stage is blind).
    7. THE COMMIT THE BOT WOULD MAKE: lib\bot-paths.ps1's owned paths staged under a private index and committed as
       smp-pipeline-bot with the rehearsed tree's OWN ops\hooks\pre-commit installed in the clone's own hooks.
  Stages: chain (exit 0 inside the hang guard), guards (not guards_blocked), commit (the hook let it through).

  PAIRED ON FAILURE. A failed stage is judged against the BASE (merge-base with <Remote>/<Branch>) over a freshly seeded
  arm of the same data. A stage that fails on the base too is PREEXISTING, printed, and does not refuse the change; a
  stage that fails only on the change does. This is prepush-test-auditors' EXPECTED-LIVE-RED rule applied to the chain,
  and it is why a guards hold caused by the day's data (12 of 25 logged daily runs) does not teach -NoRehearsal. The
  base arm costs a second rehearsal and is paid only on a failure. -NoPair skips it. A base arm that cannot run leaves
  the failure standing.

  THE VERDICT KEY. SHA-256 over the manifest set at the commit: `path blob` for every file ops\chain-manifest.json names
  (files, globs, and every .ps1 a derive_from script names), plus the manifest's own blob. A rebase that brings in no
  manifest change keeps the key, so a verdict survives push-main's rebase; any change to a manifest file needs a new
  rehearsal. Verdicts live OUTSIDE every checkout, in %LOCALAPPDATA%\ThriftyCrew\chain-rehearsal\<key>.json
  (TC_REHEARSAL_VERDICT_DIR overrides, for fixtures), because the key is content and the push may leave from another
  checkout than the one that rehearsed it. A verdict older than max_data_age_days BY ITS DATA DATE (the newest seeded
  board) is stale at push time.

  COST, measured on this box: see the plan's resolution_note. The rehearsal takes the chain's own time, which is why
  it runs outside the push lock (repo CLAUDE.md, THE GATE MUST NOT RUN INSIDE THE LOCK).

  WHAT IT CANNOT CATCH: a failure that needs TODAY'S data (a store rendering that first appears the same morning, like
  Sam's on 09-21), because it runs over the newest data that exists, which is yesterday's for tomorrow's run. Nor any
  stage below -NoPull (the store pulls) or behind -NoPublish (publish-deals-page, the recipe republish, the hub, the
  member mails), which are exactly the stages it must not run. capture-run's commit-size gate is not rehearsed.

  SCOPE OF A CLEAN REPORT: a pass says these three stages passed over one seeded copy of the data at one commit. It is
  not a proof that tomorrow's run passes (tomorrow has new data), and a flaky stage that passed once stays passed for
  that key until a failing rehearsal over the same key replaces the record.
#>
[CmdletBinding()]
param(
  [string]$Commit = 'HEAD',
  [string]$Source = '',
  [string]$Remote = 'origin',
  [string]$Branch = 'main',
  [switch]$CheckPush,
  [switch]$ForPush,
  [switch]$RefsFromStdin,
  [string]$RefsFile = '',
  [switch]$NoPair,
  # The whole chain, INSPECT included (about 40 minutes), instead of the ship path the chain's own -ShipOnly stops after.
  [switch]$Full,
  [int]$ChainTimeoutMin = 90,
  [string]$VerdictDir = '',
  [switch]$SelfTest
)

$script:RhRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:RhRoot 'lib\git-blob-lib.ps1')    # Invoke-GitCaptured, Get-CommittedBlobBytes
. (Join-Path $script:RhRoot 'lib\git-repo-env.ps1')    # Clear-TcGitRepoEnv
. (Join-Path $script:RhRoot 'lib\atomic-write.ps1')    # Write-TcAtomicFile
. (Join-Path $script:RhRoot 'lib\append-line.ps1')     # Add-TcLine

# Brad's F2 spec: "data no older than two days". The first number named, not a sweep. What it does when the producer
# stops: no new board means the newest seeded board ages past it, every rehearsal is blind=stale-data, and every
# chain-touching push is refused with that cause until the chain runs again or -NoRehearsal is used.
$script:RhMaxDataAgeDays = 2
# A syntactically valid Ghost Admin key that Ghost rejects: id and secret of the right shape, all zeros.
$script:RhSentinelKey = ('0' * 24) + ':' + ('0' * 64)
$script:RhCredentialPaths = @('.claude\skills\lesson\google-oauth-client.json', '.claude\skills\lesson\google-oauth-token.json', 'meal-prep\.ghostkey')
# The check-ad-cycles -SelfTest case whose pass proves -NoPublish holds every reader-facing writer.
$script:RhNoPublishCase = 'every reader-facing writer is reached only without -NoPublish'
# and the one that proves -ShipOnly stops at the ship boundary; a tree without it cannot be asked to stop there.
$script:RhShipOnlyCase = '-ShipOnly exits after the last SHIP PATH COMPLETE line'
$script:RhFull = [bool]$Full

function Invoke-RhGit([string]$Repo, [string[]]$GitArgs) { return (Invoke-GitCaptured -Repo $Repo -GitArgs $GitArgs) }

function Get-RhVerdictDir([string]$Override) {
  if ($Override) { return $Override }
  if ($env:TC_REHEARSAL_VERDICT_DIR) { return $env:TC_REHEARSAL_VERDICT_DIR }
  return (Join-Path $env:LOCALAPPDATA 'ThriftyCrew\chain-rehearsal')
}

function ConvertTo-RhGlobRegex([string]$Glob) {
  # `*` matches within one path segment only, so grocery/build-*.ps1 never reaches grocery/archive/build-x.ps1.
  return ('^' + ([regex]::Escape($Glob) -replace '\\\*', '[^/]*') + '$')
}

function Get-RhTreeBlobs([string]$Repo, [string]$Rev) {
  # path -> blob for every file at $Rev. Ok=$false when git cannot list it.
  $map = New-Object Collections.Hashtable ([StringComparer]::Ordinal)
  $r = Invoke-RhGit $Repo @('ls-tree', '-r', '-z', '--full-tree', $Rev)
  if ($r.rc -ne 0) { return [pscustomobject]@{ Ok = $false; Map = $map; Why = ('git ls-tree ' + $Rev + ' exited ' + $r.rc) } }
  foreach ($e in ([string]$r.stdout -split [char]0)) {
    $tab = $e.IndexOf("`t")
    if ($tab -lt 1) { continue }
    $meta = $e.Substring(0, $tab) -split '\s+'
    if ($meta.Count -ge 3 -and $meta[1] -eq 'blob') { $map[$e.Substring($tab + 1)] = $meta[2] }
  }
  return [pscustomobject]@{ Ok = $true; Map = $map; Why = '' }
}

function Get-RhManifestSet([string]$Repo, [string]$Rev) {
  <# The manifest set at $Rev: Ok, Absent (no manifest in that tree), Set (path -> blob), Key, MaxAge, Why. #>
  $bad = { param($absent, $w) [pscustomobject]@{ Ok = $false; Absent = $absent; Set = $null; Key = ''; MaxAge = $script:RhMaxDataAgeDays; Why = $w } }
  $tb = Get-RhTreeBlobs $Repo $Rev
  if (-not $tb.Ok) { return (& $bad $false $tb.Why) }
  $all = $tb.Map
  $mp = 'ops/chain-manifest.json'
  if (-not $all.ContainsKey($mp)) { return (& $bad $true ('the tree at ' + $Rev + ' carries no ' + $mp)) }
  $mr = Invoke-RhGit $Repo @('cat-file', 'blob', [string]$all[$mp])
  $doc = $null
  try { $doc = ([string]$mr.stdout) | ConvertFrom-Json } catch { $doc = $null }
  if ($mr.rc -ne 0 -or $null -eq $doc) { return (& $bad $false ($mp + ' at ' + $Rev + ' could not be read as JSON')) }
  $set = New-Object Collections.Hashtable ([StringComparer]::Ordinal)
  foreach ($f in @($doc.files)) { if ($f -and $all.ContainsKey([string]$f)) { $set[[string]$f] = $all[[string]$f] } }
  $rx = @(@($doc.globs) | Where-Object { $_ } | ForEach-Object { ConvertTo-RhGlobRegex ([string]$_) })
  if ($rx.Count) {
    foreach ($p in @($all.Keys)) { foreach ($x in $rx) { if ($p -match $x) { $set[$p] = $all[$p]; break } } }
  }
  $dirs = @(@($doc.derive_dirs) | Where-Object { $_ } | ForEach-Object { [string]$_ })
  $byLeaf = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
  foreach ($p in @($all.Keys)) {
    if ($p -notmatch '\.ps1$') { continue }
    $under = $false
    foreach ($d in $dirs) { if ($p.StartsWith($d, [StringComparison]::Ordinal)) { $under = $true; break } }
    if (-not $under) { continue }
    $leaf = ($p -split '/')[-1]
    if (-not $byLeaf.ContainsKey($leaf)) { $byLeaf[$leaf] = New-Object Collections.ArrayList }
    [void]$byLeaf[$leaf].Add($p)
  }
  foreach ($d in @($doc.derive_from)) {
    if (-not $d -or -not $all.ContainsKey([string]$d)) { continue }
    $dr = Invoke-RhGit $Repo @('cat-file', 'blob', [string]$all[[string]$d])
    if ($dr.rc -ne 0) { return (& $bad $false ('derive_from ' + $d + ' could not be read at ' + $Rev)) }
    foreach ($m in [regex]::Matches([string]$dr.stdout, '[A-Za-z0-9_.-]+\.ps1')) {
      if ($byLeaf.ContainsKey($m.Value)) { foreach ($p in $byLeaf[$m.Value]) { $set[$p] = $all[$p] } }
    }
  }
  # EXCLUDED: a script whose first real run is NOT the chain, even when a derive_from script names it. Tests and the gate
  # run at push time already; the store pulls are behind -NoPull, so a rehearsal would charge 14 minutes and exercise none
  # of them. An explicit files[] entry is never excluded.
  $ex = @(@($doc.exclude_globs) | Where-Object { $_ } | ForEach-Object { ConvertTo-RhGlobRegex ([string]$_) })
  if ($ex.Count) {
    $explicit = @(@($doc.files) | ForEach-Object { [string]$_ })
    foreach ($p in @($set.Keys)) { if ($explicit -contains $p) { continue }; foreach ($x in $ex) { if ($p -match $x) { $set.Remove($p); break } } }
  }
  $set[$mp] = $all[$mp]
  $rows = @($set.Keys | ForEach-Object { $_ + ' ' + $set[$_] })
  [Array]::Sort($rows, [StringComparer]::Ordinal)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $key = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($rows -join "`n")))) -replace '-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
  $maxAge = $script:RhMaxDataAgeDays
  if ($null -ne $doc.max_data_age_days) { $maxAge = [int]$doc.max_data_age_days }
  return [pscustomobject]@{ Ok = $true; Absent = $false; Set = $set; Key = $key; MaxAge = $maxAge; Why = '' }
}

function Read-RhVerdict([string]$Dir, [string]$Key) {
  $p = Join-Path $Dir ($Key + '.json')
  if (-not [IO.File]::Exists($p)) { return $null }
  try { $o = [IO.File]::ReadAllText($p) | ConvertFrom-Json } catch { return $null }
  if ($null -eq $o -or -not $o.result) { return $null }
  return $o
}

function Save-RhVerdict([string]$Dir, $Record) {
  if (-not [IO.Directory]::Exists($Dir)) { $null = [IO.Directory]::CreateDirectory($Dir) }
  $null = Write-TcAtomicFile -Path (Join-Path $Dir ([string]$Record.key + '.json')) -Text ($Record | ConvertTo-Json -Depth 5 -Compress) -NoBom -NoNewline
}

function Get-RhPushDecision {
  <# The pre-push decision, from recorded verdicts only. Code 0 allow, 1 refuse, 3 could-not-evaluate (refused, with
     its cause). Outcome is the worst over the ref lines; Lines are what the hook prints. #>
  param([string]$Repo, [string[]]$RefLines, [string]$Branch = 'main', [string]$VerdictDir, [datetime]$Today, [string]$Bypass = '')
  $lines = New-Object Collections.ArrayList
  $codes = New-Object Collections.ArrayList
  $outcome = 'not-needed'
  $zero = '^0+$'
  foreach ($rl in @($RefLines)) {
    $f = @(([string]$rl).Trim() -split '\s+')
    if ($f.Count -lt 4) { continue }
    $lsha = $f[1]; $rref = $f[2]; $rsha = $f[3]
    if ($lsha -match $zero) { continue }
    if ($rref -ne ('refs/heads/' + $Branch)) { [void]$lines.Add(('chain-rehearsal: {0} is not {1}; no rehearsal is asked of it' -f $rref, $Branch)); continue }
    if ($rsha -match $zero) { [void]$codes.Add(3); $outcome = 'could-not-rehearse'; [void]$lines.Add('chain-rehearsal: COULD NOT EVALUATE blind=cannot-diff - the push creates ' + $rref + ', so there is no base to diff the manifest against'); continue }
    $ms = Get-RhManifestSet $Repo $lsha
    if (-not $ms.Ok) {
      if ($ms.Absent) { [void]$lines.Add('chain-rehearsal: ' + $ms.Why + '; nothing to rehearse against'); continue }
      [void]$codes.Add(3); $outcome = 'could-not-rehearse'; [void]$lines.Add('chain-rehearsal: COULD NOT EVALUATE blind=no-manifest-readable - ' + $ms.Why); continue
    }
    $d = Invoke-RhGit $Repo @('diff', '--name-only', '-z', $rsha, $lsha)
    if ($d.rc -ne 0) { [void]$codes.Add(3); $outcome = 'could-not-rehearse'; [void]$lines.Add(('chain-rehearsal: COULD NOT EVALUATE blind=cannot-diff - git diff {0}..{1} exited {2}; fetch and rebase, then push again' -f $rsha.Substring(0, 9), $lsha.Substring(0, 9), $d.rc)); continue }
    $touched = @(([string]$d.stdout -split [char]0) | Where-Object { $_ -and $ms.Set.ContainsKey($_) })
    if ($touched.Count -eq 0) { [void]$lines.Add('chain-rehearsal: no chain-manifest script changed in this push; no rehearsal needed'); continue }
    $named = ($touched | Select-Object -First 6) -join ', '
    if ($touched.Count -gt 6) { $named += (' and ' + ($touched.Count - 6) + ' more') }
    $k12 = $ms.Key.Substring(0, 12)
    if ($Bypass) {
      $outcome = 'bypassed'
      [void]$lines.Add(('chain-rehearsal: *** REHEARSAL BYPASSED (-NoRehearsal / TC_NO_REHEARSAL) *** {0} chain script(s) changed ({1}) and this push is NOT rehearsed. Reason given: {2}. Logged to {3}' -f $touched.Count, $named, $Bypass, (Join-Path $VerdictDir 'bypass-log.jsonl')))
      try {
        if (-not [IO.Directory]::Exists($VerdictDir)) { $null = [IO.Directory]::CreateDirectory($VerdictDir) }
        $row = [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); key = $ms.Key; commit = $lsha; reason = $Bypass; touched = $touched.Count; repo = $Repo }
        $null = Add-TcLine -Path (Join-Path $VerdictDir 'bypass-log.jsonl') -Text ($row | ConvertTo-Json -Compress)
      } catch { [void]$lines.Add('chain-rehearsal: the bypass could not be logged: ' + $_.Exception.Message) }
      continue
    }
    $v = Read-RhVerdict $VerdictDir $ms.Key
    $how = 'powershell -File ops\rehearse-chain.ps1 (about the chain''s own time; push-main does it for you), or push-main -NoRehearsal to bypass loudly'
    if ($null -eq $v) {
      [void]$codes.Add(1); if ($outcome -ne 'could-not-rehearse') { $outcome = 'no-verdict' }
      [void]$lines.Add(('chain-rehearsal: REFUSED - {0} chain script(s) changed ({1}) and no rehearsal verdict is recorded for this content (key {2}). Run {3}.' -f $touched.Count, $named, $k12, $how))
      continue
    }
    $res = [string]$v.result
    if ($res -eq 'fail') {
      [void]$codes.Add(1); $outcome = 'rehearsed-fail'
      [void]$lines.Add(('chain-rehearsal: REFUSED - the rehearsal of this content FAILED at stage {0} over data from {1}: {2}' -f $v.stage, $v.data_date, $v.cause))
      foreach ($w in @($v.words | Select-Object -First 8)) { [void]$lines.Add('    ' + $w) }
      continue
    }
    if ($res -eq 'blind') {
      [void]$codes.Add(3); if ($outcome -ne 'rehearsed-fail') { $outcome = 'could-not-rehearse' }
      [void]$lines.Add(('chain-rehearsal: COULD NOT EVALUATE blind={0} - the rehearsal of this content could not run: {1}. That is not a pass. Fix the cause and rehearse again, or bypass loudly.' -f $v.blind, $v.cause))
      continue
    }
    if ($res -ne 'pass') {
      [void]$codes.Add(3); $outcome = 'could-not-rehearse'
      [void]$lines.Add('chain-rehearsal: COULD NOT EVALUATE blind=no-manifest-readable - the recorded verdict says ''' + $res + ''', which is none of pass, fail or blind'); continue
    }
    $dd = [datetime]::MinValue
    if (-not [datetime]::TryParseExact([string]$v.data_date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dd)) {
      [void]$codes.Add(3); $outcome = 'could-not-rehearse'; [void]$lines.Add('chain-rehearsal: COULD NOT EVALUATE blind=stale-data - the recorded pass names no readable data date'); continue
    }
    $age = ($Today.Date - $dd.Date).Days
    if ($age -gt $ms.MaxAge) {
      [void]$codes.Add(1); if ($outcome -eq 'not-needed' -or $outcome -eq 'rehearsed-pass') { $outcome = 'stale' }
      [void]$lines.Add(('chain-rehearsal: REFUSED - the recorded pass for this content ran over data from {0}, {1} day(s) old, past the {2}-day limit. Rehearse again over newer data.' -f $v.data_date, $age, $ms.MaxAge))
      continue
    }
    if ($outcome -eq 'not-needed') { $outcome = 'rehearsed-pass' }
    $pre = ''
    if (@($v.preexisting).Count) { $pre = ' (PREEXISTING on the base too, so not this change''s: ' + ((@($v.preexisting)) -join ', ') + ')' }
    [void]$lines.Add(('chain-rehearsal: PASSED - {0} chain script(s) changed and this content was rehearsed over data from {1} ({2} day(s) old){3}' -f $touched.Count, $v.data_date, $age, $pre))
  }
  $code = 0
  if ($codes -contains 1) { $code = 1 } elseif ($codes -contains 3) { $code = 3 }
  return [pscustomobject]@{ Code = $code; Outcome = $outcome; Lines = @($lines) }
}

function Get-RhNewestBoardDate([string]$Root) {
  $out = Join-Path $Root 'grocery\out'
  if (-not [IO.Directory]::Exists($out)) { return '' }
  $best = ''
  foreach ($f in [IO.Directory]::GetFiles($out, 'comparison-*.json')) {
    $m = [regex]::Match([IO.Path]::GetFileName($f), '^comparison-(\d{4}-\d{2}-\d{2})\.json$')
    if ($m.Success -and [string]::CompareOrdinal($m.Groups[1].Value, $best) -gt 0) { $best = $m.Groups[1].Value }
  }
  return $best
}

function Get-RhMainCheckout([string]$Repo) {
  $r = Invoke-RhGit $Repo @('rev-parse', '--path-format=absolute', '--git-common-dir')
  if ($r.rc -ne 0) { return '' }
  $c = ([string]$r.stdout).Trim() -replace '/', '\'
  if ((Split-Path -Leaf $c) -ne '.git') { return '' }
  return (Split-Path -Parent $c)
}

function Invoke-RhCommitStage {
  <# The commit the bot would make, judged by the tree's OWN pre-commit hook. Outcome committed|nothing|refused|blind. #>
  param([string]$Repo)
  $res = { param($o, $w, $words) [pscustomobject]@{ Outcome = $o; Why = $w; Words = @($words) } }
  # NEVER IN A SHARED .git: the hook goes into THIS repository's own hooks directory, so this must be a standalone repo.
  $gd = Invoke-RhGit $Repo @('rev-parse', '--path-format=absolute', '--git-common-dir')
  $own = [IO.Path]::GetFullPath((Join-Path $Repo '.git')).TrimEnd('\')
  $got = ''
  if ($gd.rc -eq 0) { $got = [IO.Path]::GetFullPath((([string]$gd.stdout).Trim() -replace '/', '\')).TrimEnd('\') }
  if (-not [string]::Equals($got, $own, [StringComparison]::OrdinalIgnoreCase)) { return (& $res 'blind' ('refusing to install a hook: ' + $Repo + ' is not a standalone repository (its git dir is ' + $got + ')') @()) }
  $hookSrc = Join-Path $Repo 'ops\hooks\pre-commit'
  if (-not [IO.File]::Exists($hookSrc)) { return (& $res 'blind' 'the rehearsed tree has no ops/hooks/pre-commit' @()) }
  $hooksDir = Join-Path $own 'hooks'
  if (-not [IO.Directory]::Exists($hooksDir)) { $null = [IO.Directory]::CreateDirectory($hooksDir) }
  [IO.File]::Copy($hookSrc, (Join-Path $hooksDir 'pre-commit'), $true)
  $bp = Join-Path $Repo 'lib\bot-paths.ps1'
  if (-not [IO.File]::Exists($bp)) { return (& $res 'blind' 'the rehearsed tree has no lib/bot-paths.ps1, so the bot''s staged set is unknown' @()) }
  . $bp
  # ASSIGN, THEN WRAP: both return their list comma-wrapped, and @(Get-X) inline reads the whole list as ONE element.
  $inPaths = Get-BotInputPaths
  $servedPaths = Get-BotServedPaths
  $paths = @(@($inPaths) + @($servedPaths) | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $Repo $_)) })
  if ($paths.Count -eq 0) { return (& $res 'nothing' 'none of the bot''s owned paths exist in the rehearsed tree' @()) }
  $tmpIndex = Join-Path $env:TEMP ('rh-index-' + [guid]::NewGuid().ToString('N'))
  $prev = $env:GIT_INDEX_FILE
  $env:GIT_INDEX_FILE = $tmpIndex
  try {
    $null = Invoke-RhGit $Repo @('read-tree', 'HEAD')
    $a = Invoke-RhGit $Repo (@('add', '-A', '--') + $paths)
    # AS PRODUCTION DOES: capture-run's own add names an owned path that is gitignored and untracked (grocery/sale-windows.json
    # on 2026-09-22), git adds everything else and exits 1 with an 'are ignored' notice, and capture-run carries on.
    $ignoredOnly = ([string]$a.stderr -match 'are ignored by one of your \.gitignore files')
    if ($a.rc -ne 0 -and -not ($a.rc -eq 1 -and $ignoredOnly)) { return (& $res 'blind' ('git add of the bot''s owned paths exited ' + $a.rc + ': ' + ([string]$a.stderr).Trim()) @()) }
    $q = Invoke-RhGit $Repo @('diff', '--cached', '--quiet')
    if ($q.rc -eq 0) { return (& $res 'nothing' 'the chain changed nothing under the bot''s owned paths' @()) }
    $c = Invoke-RhGit $Repo @('-c', 'user.name=smp-pipeline-bot', '-c', 'user.email=actions@users.noreply.github.com', 'commit', '-q', '-m', 'Daily pipeline: refresh prices + feed (chain rehearsal) [daily]')
    $words = @((([string]$c.stderr) + "`n" + ([string]$c.stdout)) -split "`r?`n" | Where-Object { $_.Trim() })
    if ($c.rc -ne 0) { return (& $res 'refused' ('the pre-commit hook refused the bot''s commit (git exit ' + $c.rc + ')') $words) }
    return (& $res 'committed' 'the pre-commit hook let the bot''s commit through' $words)
  } finally {
    if ($null -eq $prev) { Remove-Item Env:\GIT_INDEX_FILE -ErrorAction SilentlyContinue } else { $env:GIT_INDEX_FILE = $prev }
    if ([IO.File]::Exists($tmpIndex)) { [IO.File]::Delete($tmpIndex) }
  }
}

function Invoke-RhProcess {
  <# A child with its environment set per call (never this process's), both streams drained, and a hang guard that
     kills the whole tree. Returns Rc (-1 could not start), TimedOut, Out, Err. #>
  param([string]$File, [string]$Arguments, [string]$WorkDir, [hashtable]$Env = @{}, [int]$TimeoutSec = 3600)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $File; $psi.Arguments = $Arguments; $psi.WorkingDirectory = $WorkDir
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  foreach ($n in @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR', 'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_PREFIX', 'GIT_NAMESPACE')) {
    if ($psi.EnvironmentVariables.ContainsKey($n)) { $psi.EnvironmentVariables.Remove($n) }
  }
  foreach ($k in @($Env.Keys)) { $psi.EnvironmentVariables[[string]$k] = [string]$Env[$k] }
  $p = $null
  try {
    $p = [Diagnostics.Process]::Start($psi)
    $tOut = $p.StandardOutput.ReadToEndAsync(); $tErr = $p.StandardError.ReadToEndAsync()
    $done = $p.WaitForExit($TimeoutSec * 1000)
    if (-not $done) {
      $null = & taskkill.exe /T /F /PID $p.Id
      $p.WaitForExit(30000) | Out-Null
      return [pscustomobject]@{ Rc = -2; TimedOut = $true; Out = ''; Err = ('hang guard: killed after ' + $TimeoutSec + ' s') }
    }
    $tOut.Wait(); $tErr.Wait()
    return [pscustomobject]@{ Rc = $p.ExitCode; TimedOut = $false; Out = [string]$tOut.Result; Err = [string]$tErr.Result }
  } catch {
    return [pscustomobject]@{ Rc = -1; TimedOut = $false; Out = ''; Err = ('could not start ' + $File + ': ' + $_.Exception.Message) }
  } finally { if ($p) { $p.Dispose() } }
}

$script:RhDefaultSeeder = {
  param([string]$Tree, [string]$SourceRoot)
  $seeder = Join-Path $script:RhRoot 'ops\seed-worktree.ps1'
  $r = Invoke-RhProcess -File 'powershell.exe' -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + $seeder + '" -Target "' + $Tree + '" -Source "' + $SourceRoot + '"') -WorkDir $Tree -TimeoutSec 1800
  return [pscustomobject]@{ Rc = $r.Rc; Tail = @((($r.Out + "`n" + $r.Err) -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 6) }
}

$script:RhDefaultChainRunner = {
  param([string]$Tree, [int]$TimeoutMin, [hashtable]$ChildEnv)
  $cac = Join-Path $Tree 'grocery\check-ad-cycles.ps1'
  if (-not [IO.File]::Exists($cac)) { return [pscustomobject]@{ Blind = 'chain-missing'; Why = 'the rehearsed tree has no grocery\check-ad-cycles.ps1'; Rc = -1; TimedOut = $false; Tail = @() } }
  # THE INTERLOCK: this tree's own -SelfTest must pass its -NoPublish case, or the chain is never started here.
  $st = Invoke-RhProcess -File 'powershell.exe' -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + $cac + '" -SelfTest') -WorkDir (Split-Path $cac) -Env $ChildEnv -TimeoutSec 600
  $okLine = @(($st.Out -split "`r?`n") | Where-Object { $_ -match '^\s*(ok|PASS)\s' -and $_.Contains($script:RhNoPublishCase) })
  if ($st.Rc -ne 0 -or $okLine.Count -ne 1) {
    return [pscustomobject]@{ Blind = 'nopublish-unproven'; Why = ('the rehearsed check-ad-cycles -SelfTest exited ' + $st.Rc + ' and passed ' + $okLine.Count + ' case(s) naming "' + $script:RhNoPublishCase + '", so its -NoPublish cannot be shown to hold the reader-facing writers; not started'); Rc = -1; TimedOut = $false; Tail = @() }
  }
  $shipOk = @(($st.Out -split "`r?`n") | Where-Object { $_ -match '^\s*(ok|PASS)\s' -and $_.Contains($script:RhShipOnlyCase) })
  if (-not $script:RhFull -and $shipOk.Count -ne 1) {
    return [pscustomobject]@{ Blind = 'shiponly-unproven'; Why = ('the rehearsed check-ad-cycles -SelfTest passed ' + $shipOk.Count + ' case(s) naming "' + $script:RhShipOnlyCase + '", so it cannot be asked to stop at the ship boundary; rehearse with -Full'); Rc = -1; TimedOut = $false; Tail = @() }
  }
  $scopeArg = $(if ($script:RhFull) { '' } else { ' -ShipOnly' })
  $r = Invoke-RhProcess -File 'powershell.exe' -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + $cac + '" -NoPull -NoCommit -NoPublish -NoAlert' + $scopeArg) -WorkDir (Split-Path $cac) -Env $ChildEnv -TimeoutSec ($TimeoutMin * 60)
  $tail = @((($r.Out + "`n" + $r.Err) -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 12)
  return [pscustomobject]@{ Blind = ''; Why = ''; Rc = $r.Rc; TimedOut = $r.TimedOut; Tail = $tail }
}

function Invoke-RhArm {
  <# One rehearsal of one commit in its own clone. Result pass|fail|blind, Blind (cause), Stages (name -> ok|fail|blind),
     Failed (stage names), Why, Words, DataDate, Secs. The clone is left for the caller's finally to remove. #>
  param([string]$Repo, [string]$Sha, [string]$SourceRoot, [string]$RunRoot, [string]$Arm, [scriptblock]$Seeder, [scriptblock]$ChainRunner, [int]$TimeoutMin)
  $t0 = [DateTime]::UtcNow
  $stages = [ordered]@{ chain = 'not-run'; guards = 'not-run'; commit = 'not-run' }
  $mk = { param($result, $blind, $why, $words, $failed, $dd)
    [pscustomobject]@{ Result = $result; Blind = $blind; Why = $why; Words = @($words); Failed = @($failed); Stages = $stages; DataDate = $dd; Secs = [int]([DateTime]::UtcNow - $t0).TotalSeconds } }
  $tree = Join-Path $RunRoot $Arm
  $cl = Invoke-RhGit $RunRoot @('-c', 'core.longpaths=true', 'clone', '-q', '--shared', '--no-checkout', $Repo, $tree)
  if ($cl.rc -ne 0) { return (& $mk 'blind' 'clone-failed' ('git clone exited ' + $cl.rc + ': ' + ([string]$cl.stderr).Trim()) @() @() '') }
  $null = Invoke-RhGit $tree @('config', 'core.longpaths', 'true')
  $null = Invoke-RhGit $tree @('remote', 'set-url', '--push', 'origin', (Join-Path $RunRoot 'no-push-from-a-rehearsal'))
  $co = Invoke-RhGit $tree @('checkout', '-q', '--detach', $Sha)
  if ($co.rc -ne 0) { return (& $mk 'blind' 'checkout-failed' ('git checkout ' + $Sha + ' exited ' + $co.rc + ': ' + ([string]$co.stderr).Trim()) @() @() '') }
  $sd = & $Seeder $tree $SourceRoot
  if ($sd.Rc -ne 0) { return (& $mk 'blind' 'seed-failed' ('ops\seed-worktree.ps1 exited ' + $sd.Rc + ': ' + ((@($sd.Tail)) -join ' | ')) @() @() '') }
  foreach ($cp in $script:RhCredentialPaths) {
    if ([IO.File]::Exists((Join-Path $tree $cp))) { return (& $mk 'blind' 'credential-present' ('a live credential arrived in the scratch clone (' + $cp + '); a rehearsal must be unable to mail or publish, so it is not started') @() @() '') }
  }
  $dd = Get-RhNewestBoardDate $tree
  if (-not $dd) { return (& $mk 'blind' 'no-seed-board' 'the seed brought no grocery\out\comparison-*.json, so there is no real data to rehearse over' @() @() '') }
  $childEnv = @{ GHOST_ADMIN_KEY = $script:RhSentinelKey; KROGER_CLIENT_ID = 'tc-rehearsal-sentinel'; KROGER_CLIENT_SECRET = 'tc-rehearsal-sentinel'; TC_REHEARSAL = '1' }
  $verdictPath = Join-Path $tree 'grocery\out\chain-verdict.json'
  $before = [DateTime]::UtcNow.AddSeconds(-2)
  $ch = & $ChainRunner $tree $TimeoutMin $childEnv
  if ($ch.Blind) { return (& $mk 'blind' $ch.Blind $ch.Why @() @() $dd) }
  $failed = New-Object Collections.ArrayList
  $words = New-Object Collections.ArrayList
  $blind = ''; $why = ''
  if ($ch.TimedOut -or $ch.Rc -ne 0) {
    $stages.chain = 'fail'; [void]$failed.Add('chain')
    $why = $(if ($ch.TimedOut) { 'check-ad-cycles did not finish inside the ' + $TimeoutMin + '-minute hang guard' } else { 'check-ad-cycles exited ' + $ch.Rc })
    foreach ($w in @($ch.Tail)) { [void]$words.Add($w) }
  } else { $stages.chain = 'ok' }
  if ([IO.File]::Exists($verdictPath) -and [IO.File]::GetLastWriteTimeUtc($verdictPath) -ge $before) {
    $cv = $null
    try { $cv = [IO.File]::ReadAllText($verdictPath) | ConvertFrom-Json } catch { $cv = $null }
    if ($null -eq $cv) { $stages.guards = 'blind'; $blind = 'no-chain-verdict' }
    elseif ([bool]$cv.guards_blocked) { $stages.guards = 'fail'; [void]$failed.Add('guards'); if (-not $why) { $why = 'guards held the board (chain-verdict ' + [string]$cv.verdict + ')' } }
    else { $stages.guards = 'ok' }
  } elseif ($stages.chain -eq 'ok') { $stages.guards = 'blind'; $blind = 'no-chain-verdict' }
  $cm = Invoke-RhCommitStage -Repo $tree
  switch ($cm.Outcome) {
    'committed' { $stages.commit = 'ok' }
    'nothing'   { $stages.commit = 'ok' }
    'refused'   { $stages.commit = 'fail'; [void]$failed.Add('commit'); if (-not $why) { $why = $cm.Why }; foreach ($w in @($cm.Words | Select-Object -First 12)) { [void]$words.Add($w) } }
    'blind'     { $stages.commit = 'blind'; if (-not $blind) { $blind = 'commit-stage'; $why = $cm.Why } }
    default     { throw ('unknown commit-stage outcome: ' + $cm.Outcome) }
  }
  if ($failed.Count) { return (& $mk 'fail' '' $why @($words) @($failed) $dd) }
  if ($blind) { return (& $mk 'blind' $blind $(if ($why) { $why } else { 'a stage could not be observed' }) @() @() $dd) }
  return (& $mk 'pass' '' 'every stage passed' @() @() $dd)
}

function Invoke-RhRehearsal {
  <# Rehearse $Commit, pair a failure against the base, record the verdict, remove every scratch path. Returns the record. #>
  param([string]$Repo, [string]$Commit = 'HEAD', [string]$SourceRoot = '', [string]$Remote = 'origin', [string]$Branch = 'main',
        [string]$VerdictDir, [switch]$NoPair, [int]$TimeoutMin = 90, [datetime]$Today = (Get-Date),
        [scriptblock]$Seeder = $script:RhDefaultSeeder, [scriptblock]$ChainRunner = $script:RhDefaultChainRunner)
  $t0 = [DateTime]::UtcNow
  $rec = [ordered]@{ result = 'blind'; blind = ''; key = ''; commit = ''; stage = ''; cause = ''; words = @(); data_date = ''; preexisting = @();
    stages = $null; base = ''; scratch = ''; scope = $(if ($script:RhFull) { 'full' } else { 'ship-only' }); secs = 0; utc = ''; harness = 'ops\rehearse-chain.ps1'; harness_blob = '' }
  $hb = Invoke-RhGit $script:RhRoot @('hash-object', (Join-Path $script:RhRoot 'ops\rehearse-chain.ps1'))
  if ($hb.rc -eq 0) { $rec.harness_blob = ([string]$hb.stdout).Trim() }
  $finish = {
    $rec.secs = [int]([DateTime]::UtcNow - $t0).TotalSeconds
    $rec.utc = [DateTime]::UtcNow.ToString('o')
    if ($rec.key) { Save-RhVerdict $VerdictDir ([pscustomobject]$rec) }
    return [pscustomobject]$rec
  }
  $rp = Invoke-RhGit $Repo @('rev-parse', '--verify', '-q', ($Commit + '^{commit}'))
  if ($rp.rc -ne 0) { $rec.blind = 'cannot-read-push'; $rec.cause = ('git cannot name ' + $Commit); return (& $finish) }
  $sha = ([string]$rp.stdout).Trim()
  $rec.commit = $sha
  $ms = Get-RhManifestSet $Repo $sha
  if (-not $ms.Ok) { $rec.blind = 'no-manifest-readable'; $rec.cause = $ms.Why; return (& $finish) }
  $rec.key = $ms.Key
  if (-not $SourceRoot) { $SourceRoot = Get-RhMainCheckout $Repo }
  if (-not $SourceRoot -or -not [IO.Directory]::Exists($SourceRoot)) { $rec.blind = 'no-source'; $rec.cause = 'no main checkout to seed from (pass -Source)'; return (& $finish) }
  $srcDate = Get-RhNewestBoardDate $SourceRoot
  if (-not $srcDate) { $rec.blind = 'no-seed-board'; $rec.cause = ('the source checkout ' + $SourceRoot + ' holds no grocery\out\comparison-*.json'); return (& $finish) }
  $sd = [datetime]::ParseExact($srcDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
  if (($Today.Date - $sd).Days -gt $ms.MaxAge) { $rec.blind = 'stale-data'; $rec.data_date = $srcDate; $rec.cause = ('the newest board in ' + $SourceRoot + ' is ' + $srcDate + ', older than ' + $ms.MaxAge + ' day(s)'); return (& $finish) }
  $runRoot = Join-Path $env:TEMP ('tc-rh-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  $null = New-Item -ItemType Directory -Path $runRoot -ErrorAction Stop
  $rec.scratch = $runRoot
  try {
    $a = Invoke-RhArm -Repo $Repo -Sha $sha -SourceRoot $SourceRoot -RunRoot $runRoot -Arm 'h' -Seeder $Seeder -ChainRunner $ChainRunner -TimeoutMin $TimeoutMin
    $rec.stages = $a.Stages; $rec.data_date = $a.DataDate
    if ($a.Result -eq 'blind') { $rec.result = 'blind'; $rec.blind = $a.Blind; $rec.cause = $a.Why; return (& $finish) }
    if ($a.Result -eq 'pass') { $rec.result = 'pass'; $rec.cause = $a.Why; return (& $finish) }
    $rec.result = 'fail'; $rec.stage = ($a.Failed -join ','); $rec.cause = $a.Why; $rec.words = @($a.Words)
    if ($NoPair) { return (& $finish) }
    $mb = Invoke-RhGit $Repo @('merge-base', $sha, ($Remote + '/' + $Branch))
    $base = ([string]$mb.stdout).Trim()
    if ($mb.rc -ne 0 -or -not $base -or $base -eq $sha) { $rec.cause += ' (no distinct base to pair against, so the failure stands)'; return (& $finish) }
    $rec.base = $base
    $b = Invoke-RhArm -Repo $Repo -Sha $base -SourceRoot $SourceRoot -RunRoot $runRoot -Arm 'b' -Seeder $Seeder -ChainRunner $ChainRunner -TimeoutMin $TimeoutMin
    if ($b.Result -eq 'blind') { $rec.cause += (' (the base arm could not run, blind=' + $b.Blind + ', so the failure stands)'); return (& $finish) }
    $new = @($a.Failed | Where-Object { @($b.Failed) -notcontains $_ })
    $pre = @($a.Failed | Where-Object { @($b.Failed) -contains $_ })
    $rec.preexisting = $pre
    if ($new.Count -eq 0) { $rec.result = 'pass'; $rec.stage = ''; $rec.cause = ('every failed stage (' + ($pre -join ',') + ') fails on the base ' + $base.Substring(0, 9) + ' too, over the same data') }
    else { $rec.stage = ($new -join ','); if ($pre.Count) { $rec.cause += (' (also failing on the base, so preexisting: ' + ($pre -join ',') + ')') } }
    return (& $finish)
  } finally {
    Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $runRoot) { Write-Host ('chain-rehearsal: LEFTOVER - the scratch root ' + $runRoot + ' could not be removed (a process may still hold a file in it); remove it by hand') }
  }
}

function Format-RhComplete($Rec) {
  $b = $(if ($Rec.result -eq 'blind') { ' blind=' + $Rec.blind } else { '' })
  $k = $(if ($Rec.key) { $Rec.key.Substring(0, 12) } else { 'none' })
  return ('CHAIN-REHEARSAL-COMPLETE verdict={0}{1} stage={2} key={3} data={4} secs={5}' -f $Rec.result, $b, $(if ($Rec.stage) { $Rec.stage } else { '-' }), $k, $(if ($Rec.data_date) { $Rec.data_date } else { '-' }), $Rec.secs)
}

function Get-RhExitCode([string]$Result) {
  switch ($Result) { 'pass' { return 0 } 'fail' { return 1 } 'blind' { return 3 } default { throw ('unknown rehearsal result: ' + $Result) } }
}

# ======================================================================================================================
if ($SelfTest) {
  $script:rhCases = 0; $script:rhFail = 0
  function Test-RhCase([string]$Label, [scriptblock]$Body) {
    $script:rhCases++
    $got = ''
    try { $ErrorActionPreference = 'Stop'; $r = & $Body; $ok = [bool]$r[0]; if ($r.Count -gt 1) { $got = [string]$r[1] } }
    catch { $ok = $false; $got = 'threw: ' + $_.Exception.Message }
    if ($ok) { Write-Output ('ok    ' + $Label) } else { $script:rhFail++; Write-Output ('FAIL  ' + $Label + '   got: ' + $got) }
  }
  Clear-TcGitRepoEnv
  $st = Join-Path $env:TEMP ('tc-rhst-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  $null = New-Item -ItemType Directory -Path $st -ErrorAction Stop
  $savedVd = $env:TC_REHEARSAL_VERDICT_DIR; $savedBy = $env:TC_NO_REHEARSAL
  try {
    function New-RhFixtureRepo([string]$Name) {
      $d = Join-Path $st $Name
      $null = New-Item -ItemType Directory -Path $d
      $null = Invoke-RhGit $d @('init', '-q', '-b', 'main')
      $null = Invoke-RhGit $d @('config', 'user.name', 'rh-fixture'); $null = Invoke-RhGit $d @('config', 'user.email', 'rh@fixture.invalid')
      $null = Invoke-RhGit $d @('config', 'core.autocrlf', 'false'); $null = Invoke-RhGit $d @('config', 'commit.gpgsign', 'false')
      return $d
    }
    function Write-RhFile([string]$Root, [string]$Rel, [string]$Text) {
      $p = Join-Path $Root $Rel; $dir = Split-Path -Parent $p
      if (-not [IO.Directory]::Exists($dir)) { $null = [IO.Directory]::CreateDirectory($dir) }
      [IO.File]::WriteAllText($p, $Text, (New-Object Text.UTF8Encoding($false)))
    }
    function Save-RhCommit([string]$Root, [string]$Msg) {
      $null = Invoke-RhGit $Root @('add', '-A'); $null = Invoke-RhGit $Root @('commit', '-q', '--no-verify', '-m', $Msg)
      return ([string](Invoke-RhGit $Root @('rev-parse', 'HEAD')).stdout).Trim()
    }
    # ---- A HOOK REPO: the real lib\ (a sandbox copies the WHOLE lib), the hook and verify-bulk-edit under test, and two
    # stub checkers (verify-bot-commit-scope, verify-commodities-gate) that exit 0 because they are not the subject.
    function New-RhHookRepo([string]$Name, [bool]$Old) {
      $d = New-RhFixtureRepo $Name
      $null = [IO.Directory]::CreateDirectory((Join-Path $d 'lib'))
      foreach ($f in [IO.Directory]::GetFiles((Join-Path $script:RhRoot 'lib'), '*.ps1')) { [IO.File]::Copy($f, (Join-Path (Join-Path $d 'lib') ([IO.Path]::GetFileName($f)))) }
      $null = [IO.Directory]::CreateDirectory((Join-Path $d 'ops\hooks'))
      if ($Old) {
        # THE 09-05 HOOK, from the blobs as they stood before ba13faba0 (money lane 148d78, 2026-09-22) fixed it.
        [IO.File]::WriteAllBytes((Join-Path $d 'ops\verify-bulk-edit.ps1'), [byte[]](Get-CommittedBlobBytes -Repo $script:RhRoot -Spec '08e1381de9eff5372e8e71fbe0f49919aa135041'))
        [IO.File]::WriteAllBytes((Join-Path $d 'ops\hooks\pre-commit'), [byte[]](Get-CommittedBlobBytes -Repo $script:RhRoot -Spec 'ba13faba0^:ops/hooks/pre-commit'))
      } else {
        [IO.File]::Copy((Join-Path $script:RhRoot 'ops\verify-bulk-edit.ps1'), (Join-Path $d 'ops\verify-bulk-edit.ps1'))
        [IO.File]::Copy((Join-Path $script:RhRoot 'ops\hooks\pre-commit'), (Join-Path $d 'ops\hooks\pre-commit'))
      }
      Write-RhFile $d 'ops\verify-bot-commit-scope.ps1' "exit 0`n"
      Write-RhFile $d 'ops\verify-commodities-gate.ps1' "exit 0`n"
      # cost-flags.txt as HEAD held it on 2026-09-22: a BOM, then text.
      $bom = [byte[]](0xEF, 0xBB, 0xBF)
      $null = [IO.Directory]::CreateDirectory((Join-Path $d 'meal-prep\db'))
      [IO.File]::WriteAllBytes((Join-Path $d 'meal-prep\db\cost-flags.txt'), [byte[]]($bom + [Text.Encoding]::ASCII.GetBytes("Example flag line`n")))
      $null = Save-RhCommit $d 'seed'
      return $d
    }

    # ---- 1. THE FOUNDING DEFECT: an EMPTY cost-flags.txt against the 09-05 hook ----
    $old = New-RhHookRepo 'o' $true
    [IO.File]::WriteAllBytes((Join-Path $old 'meal-prep\db\cost-flags.txt'), [byte[]]@())
    $oc = Invoke-RhCommitStage -Repo $old
    Test-RhCase 'MUST FIRE  the founding defect: the bot''s commit of an EMPTY cost-flags.txt is REFUSED by the 09-05 hook, in its own words (BOM CHANGED)' {
      ($oc.Outcome -eq 'refused') -and ((@($oc.Words) -join "`n") -match 'BOM CHANGED') -and ((@($oc.Words) -join "`n") -match 'cost-flags\.txt'), ($oc.Outcome + ' | ' + ((@($oc.Words) | Select-Object -First 3) -join ' / '))
    }
    $new = New-RhHookRepo 'n' $false
    [IO.File]::WriteAllBytes((Join-Path $new 'meal-prep\db\cost-flags.txt'), [byte[]]@())
    $nc = Invoke-RhCommitStage -Repo $new
    $nHead = ([string](Invoke-RhGit $new @('log', '-1', '--format=%an|%s')).stdout).Trim()
    Test-RhCase 'CLEAN TWIN  the same empty file through TODAY''S hook is committed, as smp-pipeline-bot, so the harness passes a fixed tree' {
      ($nc.Outcome -eq 'committed') -and ($nHead -like 'smp-pipeline-bot|*rehearsal*'), ($nc.Outcome + ' | ' + $nHead + ' | ' + ((@($nc.Words) | Select-Object -First 3) -join ' / '))
    }
    Test-RhCase 'MUST FIRE  the commit stage refuses to install a hook anywhere but a standalone repository''s own .git' {
      $wt = Join-Path $st 'wt'
      $null = Invoke-RhGit $new @('worktree', 'add', '-q', '--detach', $wt)
      $w = Invoke-RhCommitStage -Repo $wt
      $null = Invoke-RhGit $new @('worktree', 'remove', '--force', $wt)
      ($w.Outcome -eq 'blind') -and ($w.Why -match 'not a standalone repository'), ($w.Outcome + ' ' + $w.Why)
    }

    # ---- 2. THE PUSH DECISION ----
    $p = New-RhFixtureRepo 'p'
    $man = '{"schema":1,"max_data_age_days":2,"files":["grocery/check-ad-cycles.ps1","ops/chain-manifest.json"],"globs":["grocery/build-*.ps1"],"derive_from":["grocery/guards.ps1"],"derive_dirs":["grocery/","lib/"],"exclude_globs":["grocery/test-*.ps1"]}'
    Write-RhFile $p 'ops\chain-manifest.json' $man
    Write-RhFile $p 'grocery\check-ad-cycles.ps1' "'chain'`n"
    Write-RhFile $p 'grocery\guards.ps1' ". (Join-Path `$root 'audit-thing.ps1')`n& (Join-Path `$root 'test-thing.ps1')`n"
    Write-RhFile $p 'grocery\test-thing.ps1' "'a test'`n"
    Write-RhFile $p 'grocery\audit-thing.ps1' "'audit v1'`n"
    Write-RhFile $p 'grocery\audit-other.ps1' "'not named by guards'`n"
    Write-RhFile $p 'grocery\build-x.ps1' "'builder'`n"
    Write-RhFile $p 'README.md' "doc v1`n"
    $c0 = Save-RhCommit $p 'base'
    Write-RhFile $p 'grocery\check-ad-cycles.ps1' "'chain v2'`n"
    $c1 = Save-RhCommit $p 'chain change'
    Write-RhFile $p 'README.md' "doc v2`n"
    $c2 = Save-RhCommit $p 'doc change'
    $vd = Join-Path $st 'verdicts'
    $today = [datetime]'2026-09-22'
    $refChain = 'refs/heads/main ' + $c1 + ' refs/heads/main ' + $c0
    $refDoc = 'refs/heads/main ' + $c2 + ' refs/heads/main ' + $c1
    $k1 = (Get-RhManifestSet $p $c1).Key
    $k2 = (Get-RhManifestSet $p $c2).Key
    $dNo = Get-RhPushDecision -Repo $p -RefLines @($refChain) -VerdictDir $vd -Today $today
    Test-RhCase 'MUST FIRE  a push that changes a manifest script with NO rehearsal verdict is refused (exit 1), naming the script and how to rehearse' {
      ($dNo.Code -eq 1) -and ($dNo.Outcome -eq 'no-verdict') -and ((@($dNo.Lines) -join ' ') -match 'check-ad-cycles\.ps1') -and ((@($dNo.Lines) -join ' ') -match 'rehearse-chain'), ('' + $dNo.Code + ' ' + $dNo.Outcome + ' ' + (@($dNo.Lines) -join ' / '))
    }
    $dDoc = Get-RhPushDecision -Repo $p -RefLines @($refDoc) -VerdictDir $vd -Today $today
    Test-RhCase 'MUST NOT FIRE  a push touching no manifest script needs no rehearsal (exit 0) and says so' {
      ($dDoc.Code -eq 0) -and ($dDoc.Outcome -eq 'not-needed') -and ((@($dDoc.Lines) -join ' ') -match 'no rehearsal needed'), ('' + $dDoc.Code + ' ' + $dDoc.Outcome)
    }
    $dBranch = Get-RhPushDecision -Repo $p -RefLines @('refs/heads/rh ' + $c1 + ' refs/heads/rh ' + $c0) -VerdictDir $vd -Today $today
    Test-RhCase 'MUST NOT FIRE  a push to a branch other than main is not asked for a rehearsal' { ($dBranch.Code -eq 0), ('' + $dBranch.Code) }
    Test-RhCase 'CLEAN TWIN  a doc-only commit after a rehearsal keeps the verdict key; a manifest change moves it' {
      ($k1 -eq $k2) -and ($k1 -ne (Get-RhManifestSet $p $c0).Key), ($k1 + ' ' + $k2)
    }
    Test-RhCase 'MUST FIRE  derive_from: an audit NAMED by guards.ps1 is in the set; one it does not name, a named test-*.ps1 under exclude_globs, and README are not' {
      $s = (Get-RhManifestSet $p $c1).Set
      $s.ContainsKey('grocery/audit-thing.ps1') -and (-not $s.ContainsKey('grocery/audit-other.ps1')) -and $s.ContainsKey('grocery/build-x.ps1') -and (-not $s.ContainsKey('README.md')) -and (-not $s.ContainsKey('grocery/test-thing.ps1')), (@($s.Keys) -join ',')
    }
    function Set-RhVerdict([string]$Key, [string]$Result, [string]$DataDate, [string]$Blind = '', [string]$Stage = '') {
      Save-RhVerdict $vd ([pscustomobject]@{ result = $Result; blind = $Blind; key = $Key; stage = $Stage; cause = ('fixture ' + $Result); words = @('fixture words'); data_date = $DataDate; preexisting = @() })
    }
    Set-RhVerdict $k1 'blind' '2026-09-22' 'no-seed-board'
    $dBlind = Get-RhPushDecision -Repo $p -RefLines @($refChain) -VerdictDir $vd -Today $today
    Test-RhCase 'MUST NOT FIRE  a rehearsal that COULD NOT RUN is not a pass: exit 3, and the line names its cause (blind=no-seed-board)' {
      ($dBlind.Code -eq 3) -and ($dBlind.Outcome -eq 'could-not-rehearse') -and ((@($dBlind.Lines) -join ' ') -match 'blind=no-seed-board') -and ((@($dBlind.Lines) -join ' ') -match 'not a pass'), ('' + $dBlind.Code + ' ' + (@($dBlind.Lines) -join ' / '))
    }
    Set-RhVerdict $k1 'fail' '2026-09-22' '' 'commit'
    $dFail = Get-RhPushDecision -Repo $p -RefLines @($refChain) -VerdictDir $vd -Today $today
    Test-RhCase 'MUST FIRE  a recorded FAILED rehearsal refuses (exit 1) and names the stage' {
      ($dFail.Code -eq 1) -and ($dFail.Outcome -eq 'rehearsed-fail') -and ((@($dFail.Lines) -join ' ') -match 'stage commit'), ('' + $dFail.Code + ' ' + $dFail.Outcome)
    }
    Set-RhVerdict $k1 'pass' '2026-09-20'
    $dAt = Get-RhPushDecision -Repo $p -RefLines @($refChain) -VerdictDir $vd -Today $today
    Test-RhCase 'CLEAN TWIN  a pass over data exactly AT the 2-day bar (09-20 on 09-22) lets the push through (exit 0)' {
      ($dAt.Code -eq 0) -and ($dAt.Outcome -eq 'rehearsed-pass') -and ((@($dAt.Lines) -join ' ') -match 'PASSED'), ('' + $dAt.Code + ' ' + $dAt.Outcome)
    }
    $dDocAfter = Get-RhPushDecision -Repo $p -RefLines @('refs/heads/main ' + $c2 + ' refs/heads/main ' + $c0) -VerdictDir $vd -Today $today
    Test-RhCase 'CLEAN TWIN  the same pass still holds when a doc commit rides on top of the rehearsed one' { ($dDocAfter.Code -eq 0), ('' + $dDocAfter.Code + ' ' + $dDocAfter.Outcome) }
    Set-RhVerdict $k1 'pass' '2026-09-19'
    $dPast = Get-RhPushDecision -Repo $p -RefLines @($refChain) -VerdictDir $vd -Today $today
    Test-RhCase 'MUST FIRE  a pass over data one day PAST the 2-day bar (09-19 on 09-22, 3 days) is stale and refused' {
      ($dPast.Code -eq 1) -and ($dPast.Outcome -eq 'stale'), ('' + $dPast.Code + ' ' + $dPast.Outcome)
    }
    [IO.File]::Delete((Join-Path $vd ($k1 + '.json')))
    $dBy = Get-RhPushDecision -Repo $p -RefLines @($refChain) -VerdictDir $vd -Today $today -Bypass 'fixture: emergency'
    $logRows = @()
    if ([IO.File]::Exists((Join-Path $vd 'bypass-log.jsonl'))) { $logRows = @([IO.File]::ReadAllLines((Join-Path $vd 'bypass-log.jsonl')) | Where-Object { $_ }) }
    Test-RhCase 'CLEAN TWIN  -NoRehearsal (TC_NO_REHEARSAL) still lets the push through, says so LOUDLY and logs the bypass with its reason' {
      ($dBy.Code -eq 0) -and ($dBy.Outcome -eq 'bypassed') -and ((@($dBy.Lines) -join ' ') -match '\*\*\* REHEARSAL BYPASSED') -and ($logRows.Count -eq 1) -and ($logRows[0] -match 'fixture: emergency'), ('' + $dBy.Code + ' ' + $dBy.Outcome + ' rows=' + $logRows.Count)
    }
    $dCreate = Get-RhPushDecision -Repo $p -RefLines @('refs/heads/main ' + $c1 + ' refs/heads/main ' + ('0' * 40)) -VerdictDir $vd -Today $today
    Test-RhCase 'MUST NOT FIRE  a push the harness cannot diff is exit 3 with blind=cannot-diff, never a silent pass' { ($dCreate.Code -eq 3) -and ((@($dCreate.Lines) -join ' ') -match 'blind=cannot-diff'), ('' + $dCreate.Code) }

    # ---- 3. A WHOLE REHEARSAL over a fixture source, through the seams (the seeder and the chain are the only fakes) ----
    $src = New-RhHookRepo 's' $false
    Write-RhFile $src 'ops\chain-manifest.json' '{"schema":1,"files":["grocery/check-ad-cycles.ps1","ops/chain-manifest.json"],"globs":[],"derive_from":[],"derive_dirs":[]}'
    Write-RhFile $src 'grocery\check-ad-cycles.ps1' "'chain'`n"
    $null = Save-RhCommit $src 'manifest'
    Write-RhFile $src 'grocery\check-ad-cycles.ps1' "'chain v2'`n"
    $srcHead = Save-RhCommit $src 'chain change'
    $null = Invoke-RhGit $src @('update-ref', 'refs/remotes/origin/main', ($srcHead + '~1'))
    $seedDir = Join-Path $st 'seed'
    Write-RhFile $seedDir 'grocery\out\comparison-2026-09-21.json' '{}'
    $fakeSeeder = { param($Tree, $SourceRoot) Copy-Item -Recurse -Force (Join-Path $SourceRoot 'grocery') $Tree; [pscustomobject]@{ Rc = 0; Tail = @() } }
    $mkRunner = { param([bool]$EmptyFlags)
      return { param($Tree, $TimeoutMin, $ChildEnv)
        # the chain's own outputs: a guard verdict, a bot-owned file, and an attempted push that must fail
        [IO.File]::WriteAllText((Join-Path $Tree 'grocery\out\chain-verdict.json'), '{"guards_blocked":false,"verdict":"clean"}')
        $cf = Join-Path $Tree 'meal-prep\db\cost-flags.txt'
        if ($EmptyFlags) { [IO.File]::WriteAllBytes($cf, [byte[]]@()) } else { [IO.File]::AppendAllText($cf, "second line`n") }
        $push = Invoke-RhGit $Tree @('push', '-q', 'origin', 'HEAD:refs/heads/rh-leak')
        [IO.File]::WriteAllText((Join-Path (Split-Path $Tree -Parent) ('push-rc-' + (Split-Path $Tree -Leaf) + '.txt')), [string]$push.rc)
        [pscustomobject]@{ Blind = ''; Why = ''; Rc = 0; TimedOut = $false; Tail = @('ran ' + $ChildEnv['TC_REHEARSAL'] + ' key=' + $ChildEnv['GHOST_ADMIN_KEY'].Substring(0, 4)) }
      }.GetNewClosure()
    }
    $statusBefore = ([string](Invoke-RhGit $script:RhRoot @('status', '--porcelain')).stdout)
    $fullRun = Invoke-RhRehearsal -Repo $src -Commit 'HEAD' -SourceRoot $seedDir -VerdictDir $vd -Today $today -Seeder $fakeSeeder -ChainRunner (& $mkRunner $false) -NoPair
    $statusAfter = ([string](Invoke-RhGit $script:RhRoot @('status', '--porcelain')).stdout)
    $leak = Invoke-RhGit $src @('rev-parse', '--verify', '-q', 'refs/heads/rh-leak')
    $scratchLeft = @(@($fullRun.scratch) | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    Test-RhCase 'CLEAN TWIN  a whole rehearsal over a fixture source passes, is RECORDED under its key with its data date, and the push it tried went nowhere' {
      $v = Read-RhVerdict $vd $fullRun.key
      ($fullRun.result -eq 'pass') -and ($null -ne $v) -and ($v.result -eq 'pass') -and ($v.data_date -eq '2026-09-21') -and ($leak.rc -ne 0), ($fullRun.result + ' ' + $fullRun.blind + ' ' + $fullRun.cause + ' leak.rc=' + $leak.rc)
    }
    Test-RhCase 'MUST NOT FIRE  it leaves nothing behind: no scratch clone of this commit under %TEMP%, and the launching checkout''s git status is unchanged' {
      ($fullRun.scratch -like '*tc-rh-*') -and ($scratchLeft.Count -eq 0) -and [string]::Equals($statusBefore, $statusAfter, [StringComparison]::Ordinal), ('left=' + $scratchLeft.Count)
    }
    $bad = Invoke-RhRehearsal -Repo $src -Commit 'HEAD' -SourceRoot (Join-Path $st 'no-such-source') -VerdictDir $vd -Today $today -Seeder $fakeSeeder -ChainRunner (& $mkRunner $false) -NoPair
    Test-RhCase 'MUST NOT FIRE  a rehearsal with no board to seed from reports blind=no-seed-board (exit 3), records it, and is never a pass' {
      ($bad.result -eq 'blind') -and ($bad.blind -in @('no-source', 'no-seed-board')) -and ((Get-RhExitCode $bad.result) -eq 3) -and ((Format-RhComplete $bad) -match '^CHAIN-REHEARSAL-COMPLETE verdict=blind blind='), ($bad.result + ' ' + $bad.blind)
    }
    $credSeeder = { param($Tree, $SourceRoot) Copy-Item -Recurse -Force (Join-Path $SourceRoot 'grocery') $Tree; $null = [IO.Directory]::CreateDirectory((Join-Path $Tree 'meal-prep')); [IO.File]::WriteAllText((Join-Path $Tree 'meal-prep\.ghostkey'), 'x'); [pscustomobject]@{ Rc = 0; Tail = @() } }
    $cred = Invoke-RhRehearsal -Repo $src -Commit 'HEAD' -SourceRoot $seedDir -VerdictDir $vd -Today $today -Seeder $credSeeder -ChainRunner (& $mkRunner $false) -NoPair
    Test-RhCase 'MUST FIRE  a seed that carries a live credential is never started: blind=credential-present' { ($cred.result -eq 'blind') -and ($cred.blind -eq 'credential-present'), ($cred.result + ' ' + $cred.blind) }
    $stale = Invoke-RhRehearsal -Repo $src -Commit 'HEAD' -SourceRoot $seedDir -VerdictDir $vd -Today ([datetime]'2026-09-24') -Seeder $fakeSeeder -ChainRunner (& $mkRunner $false) -NoPair
    Test-RhCase 'MUST FIRE  data older than the bar is not rehearsed over: blind=stale-data (09-21 board on 09-24)' { ($stale.result -eq 'blind') -and ($stale.blind -eq 'stale-data'), ($stale.result + ' ' + $stale.blind) }
  } finally {
    if ($null -eq $savedVd) { Remove-Item Env:\TC_REHEARSAL_VERDICT_DIR -ErrorAction SilentlyContinue } else { $env:TC_REHEARSAL_VERDICT_DIR = $savedVd }
    if ($null -eq $savedBy) { Remove-Item Env:\TC_NO_REHEARSAL -ErrorAction SilentlyContinue } else { $env:TC_NO_REHEARSAL = $savedBy }
    Remove-Item -LiteralPath $st -Recurse -Force -ErrorAction SilentlyContinue
  }
  $want = 20
  if ($script:rhCases -ne $want) { Write-Output ('rehearse-chain self-test FAIL: ran {0} case(s), the suite lists {1}' -f $script:rhCases, $want); exit 1 }
  if ($script:rhFail) { Write-Output ('rehearse-chain self-test FAIL: {0} of {1} case(s)' -f $script:rhFail, $script:rhCases); exit 1 }
  Write-Output ('rehearse-chain self-test PASS: {0} of {0} cases - led by the founding defect (an empty cost-flags.txt refused by the 09-05 hook) and a manifest change with no verdict being refused' -f $script:rhCases)
  exit 0
}

# ======================================================================================================================
$vdir = Get-RhVerdictDir $VerdictDir
Clear-TcGitRepoEnv
$repoTop = $script:RhRoot

if ($CheckPush) {
  $refLines = @()
  if ($RefsFromStdin) { $refLines = @(([Console]::In.ReadToEnd()) -split "`r?`n" | Where-Object { $_.Trim() }) }
  elseif ($RefsFile) { $refLines = @([IO.File]::ReadAllLines($RefsFile) | Where-Object { $_.Trim() }) }
  $d = Get-RhPushDecision -Repo $repoTop -RefLines $refLines -Branch $Branch -VerdictDir $vdir -Today (Get-Date) -Bypass ([string]$env:TC_NO_REHEARSAL)
  foreach ($l in $d.Lines) { Write-Output $l }
  Write-Output ('CHAIN-REHEARSAL-CHECK-COMPLETE code={0} outcome={1}' -f $d.Code, $d.Outcome)
  exit $d.Code
}

if ($ForPush) {
  $rr = Invoke-RhGit $repoTop @('rev-parse', '--verify', '-q', ($Remote + '/' + $Branch))
  $hh = Invoke-RhGit $repoTop @('rev-parse', '--verify', '-q', 'HEAD')
  if ($rr.rc -ne 0 -or $hh.rc -ne 0) {
    Write-Output ('chain-rehearsal: COULD NOT EVALUATE blind=cannot-read-push - git cannot name HEAD or ' + $Remote + '/' + $Branch)
    Write-Output 'CHAIN-REHEARSAL-CHECK-COMPLETE code=3 outcome=could-not-rehearse'
    exit 3
  }
  $line = 'refs/heads/' + $Branch + ' ' + ([string]$hh.stdout).Trim() + ' refs/heads/' + $Branch + ' ' + ([string]$rr.stdout).Trim()
  $bypass = [string]$env:TC_NO_REHEARSAL
  $d = Get-RhPushDecision -Repo $repoTop -RefLines @($line) -Branch $Branch -VerdictDir $vdir -Today (Get-Date) -Bypass $bypass
  if (-not $bypass -and ($d.Outcome -eq 'no-verdict' -or $d.Outcome -eq 'stale')) {
    Write-Output 'chain-rehearsal: this push changes the chain and has no usable rehearsal verdict - rehearsing HEAD now, OUTSIDE the push lock.'
    $rec = Invoke-RhRehearsal -Repo $repoTop -Commit 'HEAD' -SourceRoot $Source -Remote $Remote -Branch $Branch -VerdictDir $vdir -NoPair:$NoPair -TimeoutMin $ChainTimeoutMin
    Write-Output (Format-RhComplete $rec)
    $d = Get-RhPushDecision -Repo $repoTop -RefLines @($line) -Branch $Branch -VerdictDir $vdir -Today (Get-Date) -Bypass $bypass
  }
  foreach ($l in $d.Lines) { Write-Output $l }
  Write-Output ('CHAIN-REHEARSAL-CHECK-COMPLETE code={0} outcome={1}' -f $d.Code, $d.Outcome)
  exit $d.Code
}

$rec = Invoke-RhRehearsal -Repo $repoTop -Commit $Commit -SourceRoot $Source -Remote $Remote -Branch $Branch -VerdictDir $vdir -NoPair:$NoPair -TimeoutMin $ChainTimeoutMin
Write-Output ('chain-rehearsal: {0} at {1} over data from {2}: {3}' -f $rec.result.ToUpperInvariant(), $(if ($rec.commit) { $rec.commit.Substring(0, 9) } else { $Commit }), $(if ($rec.data_date) { $rec.data_date } else { '-' }), $rec.cause)
if ($rec.stages) { Write-Output ('chain-rehearsal: stages ' + ((@($rec.stages.Keys) | ForEach-Object { $_ + '=' + $rec.stages[$_] }) -join ' ')) }
foreach ($w in @($rec.words | Select-Object -First 12)) { Write-Output ('    ' + $w) }
Write-Output (Format-RhComplete $rec)
exit (Get-RhExitCode $rec.result)
