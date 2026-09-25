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
    -ListSet    READ-ONLY, the set without a rehearsal (W0.5, design\PLAN-push-derived-conflicts-2026-09-23.md):
                  powershell -File ops\rehearse-chain.ps1 -ListSet [-Commit <sha>] [-Range <base>..<tip>]
                prints the manifest set at -Commit (default HEAD), and with -Range the TRIGGER -ForPush would decide for
                that range. It clones nothing, takes no rehearsal slot, reads no verdict and writes nothing, so it costs
                seconds where a default run costs about 14 minutes and one of the 6 slots. -Range is refused without
                -ListSet (a default run would rehearse), and -ListSet is refused beside -CheckPush or -ForPush.
    -Onto <sha> / -StackFile <path>   (W9.1 step 1; any of the modes above that rehearse) rehearse -Commit REBASED onto
                <sha>, or onto the stack the file lists: line 1 the base (the origin sha), then one commit per line, the
                commits of every ticket ahead, oldest first (W9.2 writes it). The stacked tip is built by New-RhStack in a
                private bare clone, before any slot is taken, and its manifest set is the verdict key. A replay that
                conflicts records NOTHING and is blind=stack-conflict, with a chain-rehearsal: STACK CONFLICT line.
                With -ForPush the push is still judged chain-touching on HEAD against <Remote>/<Branch>; when it is, the
                verdict looked up (and rehearsed) is the stacked tip's.
    -Early      THE REHEARSAL AT COMMIT (W9.1 step 2), needs -Onto or -StackFile:
                  powershell -File ops\rehearse-chain.ps1 -Early -Onto <origin sha> [-Commit HEAD]
                push-main -Prepare and the post-commit hook (D19) start it DETACHED. It starts nothing when the stacked
                content touches no member, when a pass or fail verdict for its key is recorded over fresh data, or when a
                live early run in any checkout holds its key; otherwise it records itself in
                <verdict dir>\early\<SHA-256 of the lower-cased checkout path>.json, SUPERSEDES this checkout's older live
                run of a different key by writing that run's stop file, takes one of 4 early caps and then a rehearsal
                slot, and rehearses. Its last line: CHAIN-REHEARSAL-EARLY-COMPLETE started=yes|no reason=<r> ...
                (exit 0 for started=no with reason not-chain, verdict-exists or in-flight; else the rehearsal's exit, or 3).
    -StopFile <path>   (W9.1 step 4, W9.3) polled every 5 s while any child runs, and between stages; when it appears
                the run stops its OWN child tree, records nothing, removes its scratch root and ends blind=stopped
                (-ForPush: CHAIN-REHEARSAL-CHECK-COMPLETE code=3 outcome=could-not-rehearse blind=stopped). -Early makes
                its own and names it in the in-flight file. Nobody else ever kills a rehearsal.
    Every chain child gets TC_REHEARSAL_RUN=1 (a post-commit hook that sees it starts nothing) and a TEMP inside the
    scratch root, so what a stopped child leaves in its temp directory goes with the root. The verdict record also
    carries early, onto, head, checkout (hashed as the in-flight file is) and stage_secs (stack, clone, checkout, seed,
    selftest, ship, commit); -CheckPush and -ForPush decide on none of them, and read only `early`: when a recorded
    verdict decided the push, their CHAIN-REHEARSAL-CHECK-COMPLETE line ends early=yes or early=no, from that verdict's
    own record (no outranks yes over several ref lines), and with no deciding verdict the token is absent. push-main
    reads it into early_hit (W9.1 step 7, B22); every other reader matches `code=\d+ outcome=(\S+)` and ignores it.
    -SelfTest   hermetic fixtures, per-run temp directories, nothing live.

  THE TRIGGER IS ONE FUNCTION. Get-RhTrigger answers "does the diff <base>..<tip> touch the manifest set at <base> OR at
  <tip>" (the union, W6.0: a deleted member is in the set only at the base), and
  Get-RhPushDecision (so -CheckPush and -ForPush) and -ListSet -Range all ask it, so the printed decision and the pushed
  one cannot drift apart. The diff is tree to tree between the two endpoints, exactly as -ForPush diffs <Remote>/<Branch>
  against HEAD, never from their merge base; that is why -Range refuses three dots. What a range triggers is not what a
  recorded verdict would then allow: that half reads the verdict store and is -CheckPush's.

  -LISTSET'S OUTPUT, a contract for a parser (W0.3's -History reads it). A SET line is a bare repo path, one per member,
  sorted Ordinal. Every other line begins with CHAIN-REHEARSAL- or chain-rehearsal:, which no repo path does:
    CHAIN-REHEARSAL-TRIGGER range=<base sha>..<tip sha> decision=needed|not-needed touched=<n>   (with -Range)
    CHAIN-REHEARSAL-CLOSURE <path> <- <file that dot-sources it>                                 (one per closure member, W9.5)
    CHAIN-REHEARSAL-TOUCHED <path>                                                               (one per touched member)
    CHAIN-REHEARSAL-LISTSET-COMPLETE files=<n> members=<m> closure=<c> commit=<sha> key=<verdict key>[ decision=<d>]
                                                                                                 (always the LAST line)
  files= stays the FIRST token and counts every bare SET line, closure members included, because the key covers them
  all; n = m + c. A closure member is printed twice on purpose: as a bare SET line, so a parser that reads only bare
  lines still gets the whole set, and on a CLOSURE line naming what reaches it (W9.5 asked for a `closure <path> <-`
  line; it carries the CHAIN-REHEARSAL- prefix so this contract's "every other line" rule still holds).
  A tree with no manifest is a real answer, not a blind: files=0 manifest=absent (and decision=not-needed), exit 0, the
  same "nothing to rehearse against" -CheckPush allows. A could-not-evaluate prints one chain-rehearsal: COULD NOT
  EVALUATE line, NO path lines and a marker with blind=<cause> and NO files= token, so no parser can read it as an empty
  set; exit 3.

  THREE OUTCOMES, NEVER TWO. Every mode ends in one of them, printed as its last line:
    exit 0  pass     rehearsed and passed (or, at push time, no manifest script changed, or -NoRehearsal; or -ListSet listed)
    exit 1  fail     rehearsed and a stage FAILED; the stage and its own words are printed
    exit 3  blind    COULD NOT REHEARSE, with blind=<cause>: no-source, no-seed-board, stale-data, clone-failed,
                     checkout-failed, seed-failed, credential-present, chain-missing, nopublish-unproven, shiponly-unproven,
                     no-chain-verdict, commit-stage, no-rehearsal-slot, cannot-read-push, cannot-diff, no-manifest-readable,
                     stack-conflict, stopped, bad-usage (and for -Early, no-early-cap);
                     and for -ListSet, cannot-read-commit, bad-range, bad-usage. A 3 is never a pass and never a silent
                     refusal: the cause is on the line, as run-gates' blind= token is.

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
  (files, globs, and every .ps1 a derive_from script names), every .ps1 those scripts DOT-SOURCE, transitively (the
  closure, W9.5: until 2026-09-23 a change to a library only a member dot-sources kept every verdict valid, so a push
  could land code the chain runs that no rehearsal had run), plus the manifest's own blob. A rebase that brings in no
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
  # READ-ONLY: print the manifest set at -Commit, and with -Range <base>..<tip> the trigger -ForPush would decide (W0.5).
  [switch]$ListSet,
  [string]$Range = '',
  # W9.1 (design\PLAN-push-derived-conflicts-2026-09-23.md 16.3): rehearse -Commit rebased onto -Onto <sha>, or onto the
  # stack a -StackFile lists; -Early does it as the speculative rehearsal at commit time; -StopFile is polled to stop it.
  [string]$Onto = '',
  [string]$StackFile = '',
  [string]$StopFile = '',
  [switch]$Early,
  [switch]$SelfTest
)

$script:RhRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:RhRoot 'lib\git-blob-lib.ps1')    # Invoke-GitCaptured, Get-CommittedBlobBytes
. (Join-Path $script:RhRoot 'lib\git-repo-env.ps1')    # Clear-TcGitRepoEnv
. (Join-Path $script:RhRoot 'lib\atomic-write.ps1')    # Write-TcAtomicFile
. (Join-Path $script:RhRoot 'lib\append-line.ps1')     # Add-TcLine
. (Join-Path $script:RhRoot 'lib\gate-slots.ps1')     # Enter-TcGateSlots / Exit-TcGateSlots: the rehearsal cap is a slot budget, not a second lock
. (Join-Path $script:RhRoot 'lib\mutex-hold.ps1')     # Start-TcMutexHold: the self-test holds slots from ANOTHER process

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
# AT MOST 6 REHEARSALS AT ONCE, machine-wide (Brad, 2026-09-22: "Can we cap at 6? I have a Ryzen 9 9950X CPU so I think
# I have enough cores here to help with this and it shouldnt slow everything down?"). Brad's figure from a box of 32
# logical processors and 61.6 GB RAM, NOT the survivor of a sweep; the per-rehearsal peak working set measured against it
# is in plan-2026-09-22-7. Built on lib\gate-slots.ps1 (its own mutex prefix and queue, served in arrival order, exactly
# as lib\push-lock.ps1 reuses it at a budget of one). A 7th WAITS and says so; it is never blind and never failed while
# it waits. What it does when the producer stops: a slot holder that dies frees its mutex, and a queue that has not
# moved for $RhSlotStallSec gives up with blind=no-rehearsal-slot, recorded nowhere (it says nothing about the content).
$script:RhMaxConcurrent = 6
$script:RhSlotPrefix = 'Global\tc-rehearsal-slot-'
# The first plausible number: four ship-path rehearsals (~15 min each) in a row with no slot freed means a wedge.
$script:RhSlotStallSec = 3600
# THE EARLY CAP (W9.1 step 2): an early rehearsal takes one of these BEFORE its rehearsal slot, so at most 4 of the 6
# slots ever run speculative work and 2 are always left to a push that is waiting. 4 is the plan's first plausible
# value, not swept. Push-time rehearsals never take it. Lock order (plan 16.6): 2a, always outside the slot (2b).
$script:RhEarlyMaxSlots = 4
$script:RhEarlyPrefix = 'Global\tc-rehearsal-early-'
$script:RhEarlyStallSec = 3600
# THE STOP (W9.1 step 4): the stop file this run polls, and how often. 5 s is the plan's first plausible value, not
# swept; a stop costs at most that much more of a slot.
$script:RhStopFile = $StopFile
$script:RhStopPollMs = 5000
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
  $bad = { param($absent, $w) [pscustomobject]@{ Ok = $false; Absent = $absent; Set = $null; Key = ''; MaxAge = $script:RhMaxDataAgeDays; BoardGlob = ''; VerdictPath = ''; Why = $w } }
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
  # THE DOT-SOURCE CLOSURE (W9.5): every .ps1 a member dot-sources, transitively, joins the set, because the chain runs it
  # and a change to it alone reaches the chain. Exclusions are not applied to it: a script a member dot-sources is run
  # by the chain whatever its name. Closure maps each such path to the file that sources it.
  $cl = Get-RhDotSourceClosure -Repo $Repo -All $all -Seeds @($set.Keys)
  if (-not $cl.Ok) { return (& $bad $false ($cl.Why + ' at ' + $Rev)) }
  foreach ($p in @($cl.Closure.Keys)) { $set[$p] = $all[$p] }
  $set[$mp] = $all[$mp]
  $rows = @($set.Keys | ForEach-Object { $_ + ' ' + $set[$_] })
  [Array]::Sort($rows, [StringComparer]::Ordinal)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $key = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($rows -join "`n")))) -replace '-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
  $maxAge = $script:RhMaxDataAgeDays
  if ($null -ne $doc.max_data_age_days) { $maxAge = [int]$doc.max_data_age_days }
  # WHERE THE CHAIN PUTS ITS OUTPUTS is declared by the manifest (the chain's contract), not spelled here.
  return [pscustomobject]@{ Ok = $true; Absent = $false; Set = $set; Closure = $cl.Closure; Key = $key; MaxAge = $maxAge; BoardGlob = [string]$doc.board_glob; VerdictPath = [string]$doc.chain_verdict; Why = '' }
}

# Blob id -> text. A blob id names its bytes, so the cache can never go stale; it spares the base and the tip of one
# trigger reading the same few hundred scripts twice.
$script:RhBlobText = New-Object Collections.Hashtable ([StringComparer]::Ordinal)

function Read-RhBlobTexts([string]$Repo, [string[]]$Blobs) {
  <# Fill $script:RhBlobText for every blob in $Blobs through ONE `git cat-file --batch`, reading raw bytes and decoding
     UTF-8 (never the console code page). Returns '' or why it could not. stdout is drained by an async copy before stdin
     is written, so a large answer cannot fill the pipe while this is still asking. #>
  $need = New-Object Collections.ArrayList
  foreach ($b in @($Blobs)) { if ($b -and -not $script:RhBlobText.ContainsKey($b) -and -not $need.Contains($b)) { [void]$need.Add($b) } }
  if ($need.Count -eq 0) { return '' }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'git'; $psi.Arguments = ('-C "' + $Repo + '" cat-file --batch')
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $p = $null
  try {
    $p = [Diagnostics.Process]::Start($psi)
    $ms = New-Object IO.MemoryStream
    $copy = $p.StandardOutput.BaseStream.CopyToAsync($ms)
    $errT = $p.StandardError.ReadToEndAsync()
    # A SINK LINE FIRST: under PS 5.1 the StandardInput writer is created with the console encoding and may put its BOM
    # on the pipe before anything is written, and git then reads the BOM as part of the first id. The sink line absorbs
    # it: git answers it `missing`, which the parser below skips.
    $ask = [Text.Encoding]::ASCII.GetBytes(('rh-bom-sink' + "`n" + ($need -join "`n") + "`n"))
    $p.StandardInput.BaseStream.Write($ask, 0, $ask.Length)
    $p.StandardInput.BaseStream.Flush()
    $p.StandardInput.Close()
    $copy.Wait(); $p.WaitForExit(); $null = $errT.Result
    if ($p.ExitCode -ne 0) { return ('git cat-file --batch exited ' + $p.ExitCode) }
    $buf = $ms.ToArray(); $i = 0; $utf8 = New-Object Text.UTF8Encoding($false)
    while ($i -lt $buf.Length) {
      $nl = [Array]::IndexOf($buf, [byte]10, $i)
      if ($nl -lt 0) { return 'git cat-file --batch ended inside a header' }
      $hdr = [Text.Encoding]::ASCII.GetString($buf, $i, $nl - $i) -split ' '
      $i = $nl + 1
      if ($hdr.Count -eq 2 -and $hdr[1] -eq 'missing' -and $hdr[0].EndsWith('rh-bom-sink', [StringComparison]::Ordinal)) { continue }
      if ($hdr.Count -lt 3) { return ('git cat-file --batch could not read ' + $hdr[0]) }
      $size = [int]$hdr[2]
      $script:RhBlobText[$hdr[0]] = $utf8.GetString($buf, $i, $size)
      $i += $size + 1
    }
    foreach ($b in $need) { if (-not $script:RhBlobText.ContainsKey($b)) { return ('git cat-file --batch returned no text for ' + $b) } }
    return ''
  } catch { return ('git cat-file --batch could not run: ' + $_.Exception.Message) }
  finally { if ($p) { $p.Dispose() } }
}

function Get-RhDotSourceLiterals([string]$Text) {
  <# Pure over TEXT. The literal path of every dot-source in a script: a `.` operator at the start of a statement
     (after start of line, a space, `{`, `;` or `(`), followed by an expression whose quoted literals, joined with `/`
     up to and including the first one ending in .ps1, spell the path; a leading `$var\` segment (the base) is dropped
     and resolved by the caller. Comments are skipped. UNSOUND for a path computed at run time (a variable holding the
     whole path, a -f format), which is the same gap lib\gate-input-key.ps1 names. #>
  $code = [regex]::Replace($Text, '(?s)<#.*?#>', '')
  $out = New-Object Collections.ArrayList
  foreach ($line in ($code -split "`r?`n")) {
    if ($line.TrimStart().StartsWith('#')) { continue }
    foreach ($m in [regex]::Matches($line, '(?:^|[\s{;(])\.[ \t]+([\(''"$][^\r\n]*)')) {
      $rest = $m.Groups[1].Value
      $parts = New-Object Collections.ArrayList
      $lit = ''
      foreach ($q in [regex]::Matches($rest, '''([^''\r\n]*)''|"([^"\r\n]*)"')) {
        $v = $(if ($q.Groups[1].Success) { $q.Groups[1].Value } else { $q.Groups[2].Value })
        [void]$parts.Add($v)
        if ($v -match '\.ps1$') { $lit = ($parts -join '/'); break }
      }
      if (-not $lit) {
        $bare = [regex]::Match($rest, '^\$[\w:{}]+[\\/]([^\s''"();]+\.ps1)\b')
        if ($bare.Success) { $lit = $bare.Groups[1].Value } else { continue }
      }
      $lit = ($lit -replace '\\', '/') -replace '/+', '/'
      $lit = [regex]::Replace($lit, '^(\$\{?[\w:]+\}?/)+', '')
      if ($lit -match '\$') { continue }
      [void]$out.Add($lit)
    }
  }
  return , $out.ToArray()
}

function Resolve-RhDotSource([string]$FilePath, [string]$Literal, $All) {
  <# The tree paths a literal dot-source in $FilePath can name: the literal against the file's own folder (`..`
     resolved), and the literal without its leading ./ and ../ against every ancestor folder up to the root, because
     its base may be $PSScriptRoot, a parent of it or the checkout root. Only paths that exist in the tree count. #>
  $dir = ''; $ix = $FilePath.LastIndexOf('/'); if ($ix -gt 0) { $dir = $FilePath.Substring(0, $ix) }
  $cands = New-Object Collections.ArrayList
  $segs = New-Object Collections.ArrayList
  if ($dir) { foreach ($s in ($dir -split '/')) { [void]$segs.Add($s) } }
  $okRel = $true
  foreach ($s in ($Literal -split '/')) {
    if ($s -eq '' -or $s -eq '.') { continue }
    if ($s -eq '..') { if ($segs.Count) { $segs.RemoveAt($segs.Count - 1) } else { $okRel = $false } ; continue }
    [void]$segs.Add($s)
  }
  if ($okRel) { [void]$cands.Add(($segs -join '/')) }
  $strip = [regex]::Replace($Literal, '^(\.\.?/)+', '')
  $anc = $dir
  while ($true) {
    [void]$cands.Add($(if ($anc) { $anc + '/' + $strip } else { $strip }))
    if (-not $anc) { break }
    $j = $anc.LastIndexOf('/'); $anc = $(if ($j -gt 0) { $anc.Substring(0, $j) } else { '' })
  }
  return , @($cands | Where-Object { $All.ContainsKey($_) } | Select-Object -Unique)
}

function Get-RhDotSourceClosure {
  <# Transitive over literal dot-sources from every .ps1 in $Seeds: Closure maps each reached path that is NOT a seed to
     the file that first sources it. A cycle terminates because a path is visited once. Ok=$false with Why when a blob
     cannot be read. #>
  param([string]$Repo, $All, [string[]]$Seeds)
  $closure = New-Object Collections.Hashtable ([StringComparer]::Ordinal)
  $seen = New-Object Collections.Hashtable ([StringComparer]::Ordinal)
  foreach ($s in @($Seeds)) { $seen[$s] = $true }
  $frontier = @($Seeds | Where-Object { $_ -match '\.ps1$' })
  while ($frontier.Count) {
    $why = Read-RhBlobTexts $Repo @($frontier | ForEach-Object { [string]$All[$_] })
    if ($why) { return [pscustomobject]@{ Ok = $false; Closure = $closure; Why = ('the dot-source closure could not be read: ' + $why) } }
    $next = New-Object Collections.ArrayList
    foreach ($f in $frontier) {
      $lits = Get-RhDotSourceLiterals ([string]$script:RhBlobText[[string]$All[$f]])
      foreach ($l in $lits) {
        $hits = Resolve-RhDotSource $f $l $All
        foreach ($h in $hits) {
          if ($seen.ContainsKey($h) -or $h -notmatch '\.ps1$') { continue }
          $seen[$h] = $true; $closure[$h] = $f; [void]$next.Add($h)
        }
      }
    }
    $frontier = @($next)
  }
  return [pscustomobject]@{ Ok = $true; Closure = $closure; Why = '' }
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

function Get-RhTrigger {
  <# THE TRIGGER, the one definition (header, THE TRIGGER IS ONE FUNCTION): does the tree-to-tree diff $Base..$Tip touch
     the manifest set AT EITHER END? Get-RhPushDecision decides from it and -ListSet -Range prints it. Reads git only: it
     clones nothing, takes no slot and writes nothing. Returns Blind ('' when evaluated, else no-manifest-readable or
     cannot-diff), Why, DiffRc, Absent (the tip carries no manifest, so there is nothing to rehearse against), Manifest
     (Get-RhManifestSet at $Tip, whose Key is the verdict key) and Touched (the members of the UNION the diff names, in
     git's own path order).
     THE UNION (W6.0, design\PLAN-push-derived-conflicts-2026-09-23.md): a push that DELETES a member is not in the set at
     its tip, because the file is gone, so a trigger read at the tip alone never rehearsed it, yet the deletion moves the
     verdict key of every rehearsal after it. So a path touched by the diff counts when it is a member at $Base OR at $Tip.
     This rehearses more pushes than before, never fewer. A base whose manifest is ABSENT contributes nothing; a base
     whose manifest cannot be read contributes nothing only when the diff names the manifest itself (which then triggers
     anyway, because the manifest is always a member at the tip); otherwise it is blind=no-manifest-readable. #>
  param([string]$Repo, [string]$Base, [string]$Tip)
  $ms = Get-RhManifestSet $Repo $Tip
  $r = [ordered]@{ Blind = ''; Why = ''; DiffRc = 0; Absent = $false; Manifest = $ms; Touched = @() }
  if (-not $ms.Ok) {
    if ($ms.Absent) { $r.Absent = $true } else { $r.Blind = 'no-manifest-readable' }
    $r.Why = $ms.Why
    return [pscustomobject]$r
  }
  $d = Invoke-RhGit $Repo @('diff', '--name-only', '-z', $Base, $Tip)
  if ($d.rc -ne 0) { $r.Blind = 'cannot-diff'; $r.DiffRc = $d.rc; $r.Why = ('git diff exited ' + $d.rc); return [pscustomobject]$r }
  $names = @(([string]$d.stdout -split [char]0) | Where-Object { $_ })
  $bs = Get-RhManifestSet $Repo $Base
  $baseSet = $null
  if ($bs.Ok) { $baseSet = $bs.Set }
  elseif (-not $bs.Absent -and -not ($names -contains 'ops/chain-manifest.json')) {
    $r.Blind = 'no-manifest-readable'; $r.Why = ('the base ' + $Base + ': ' + $bs.Why); return [pscustomobject]$r
  }
  $r.Touched = @($names | Where-Object { $ms.Set.ContainsKey($_) -or ($null -ne $baseSet -and $baseSet.ContainsKey($_)) })
  return [pscustomobject]$r
}

function Get-RhPushDecision {
  <# The pre-push decision, from recorded verdicts only. Code 0 allow, 1 refuse, 3 could-not-evaluate (refused, with
     its cause). Outcome is the worst over the ref lines; Lines are what the hook prints. Whether a ref line needs a
     rehearsal at all is Get-RhTrigger's answer, the same one -ListSet -Range prints. #>
  param([string]$Repo, [string[]]$RefLines, [string]$Branch = 'main', [string]$VerdictDir, [datetime]$Today, [string]$Bypass = '')
  $lines = New-Object Collections.ArrayList
  $codes = New-Object Collections.ArrayList
  $outcome = 'not-needed'
  $early = ''
  $zero = '^0+$'
  foreach ($rl in @($RefLines)) {
    $f = @(([string]$rl).Trim() -split '\s+')
    if ($f.Count -lt 4) { continue }
    $lsha = $f[1]; $rref = $f[2]; $rsha = $f[3]
    if ($lsha -match $zero) { continue }
    if ($rref -ne ('refs/heads/' + $Branch)) { [void]$lines.Add(('chain-rehearsal: {0} is not {1}; no rehearsal is asked of it' -f $rref, $Branch)); continue }
    if ($rsha -match $zero) { [void]$codes.Add(3); $outcome = 'could-not-rehearse'; [void]$lines.Add('chain-rehearsal: COULD NOT EVALUATE blind=cannot-diff - the push creates ' + $rref + ', so there is no base to diff the manifest against'); continue }
    $tr = Get-RhTrigger -Repo $Repo -Base $rsha -Tip $lsha
    $ms = $tr.Manifest
    # if/elseif and never a switch: `continue` inside a switch continues the SWITCH, not this foreach.
    if ($tr.Absent) { [void]$lines.Add('chain-rehearsal: ' + $tr.Why + '; nothing to rehearse against'); continue }
    if ($tr.Blind -eq 'no-manifest-readable') { [void]$codes.Add(3); $outcome = 'could-not-rehearse'; [void]$lines.Add('chain-rehearsal: COULD NOT EVALUATE blind=no-manifest-readable - ' + $tr.Why); continue }
    if ($tr.Blind -eq 'cannot-diff') { [void]$codes.Add(3); $outcome = 'could-not-rehearse'; [void]$lines.Add(('chain-rehearsal: COULD NOT EVALUATE blind=cannot-diff - git diff {0}..{1} exited {2}; fetch and rebase, then push again' -f $rsha.Substring(0, 9), $lsha.Substring(0, 9), $tr.DiffRc)); continue }
    if ($tr.Blind) { throw ('unknown trigger blind cause: ' + $tr.Blind) }
    $touched = @($tr.Touched)
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
    # EARLY (W9.1 step 7, for push-main's early_hit and B22): whether the verdict that decided this ref line was an
    # early (commit-time) rehearsal, read from that verdict's own record. 'no' outranks 'yes' over several ref lines, and
    # a line no verdict decided (none recorded, not a chain push, bypassed) leaves it unset, so the marker says nothing.
    if ($null -ne $v) {
      $vEarly = $(if ($v.PSObject.Properties['early'] -and ($v.early -eq $true)) { 'yes' } else { 'no' })
      if ($early -ne 'no') { $early = $vEarly }
    }
    $how ='powershell -File ops\rehearse-chain.ps1 (about the chain''s own time; push-main does it for you), or push-main -NoRehearsal to bypass loudly'
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
  return [pscustomobject]@{ Code = $code; Outcome = $outcome; Lines = @($lines); Early = $early }
}

function Format-RhCheckComplete($Decision) {
  # The -CheckPush / -ForPush marker. A trailing early=yes|no is appended only when a recorded verdict decided the push;
  # every reader of this line matches `code=\d+ outcome=(\S+)`, so the token is additive.
  $tail = $(if ($Decision.Early) { ' early=' + $Decision.Early } else { '' })
  return ('CHAIN-REHEARSAL-CHECK-COMPLETE code={0} outcome={1}{2}' -f $Decision.Code, $Decision.Outcome, $tail)
}

function Get-RhNewestBoardDate([string]$Root, [string]$BoardGlob) {
  # $BoardGlob is the manifest's board_glob, one * standing for the board's yyyy-MM-dd.
  if (-not $BoardGlob -or $BoardGlob -notmatch '^[^*]+/[^/*]*\*[^/*]*$') { return '' }
  $out = Join-Path $Root ((Split-Path $BoardGlob -Parent) -replace '/', '\')
  $leaf = Split-Path $BoardGlob -Leaf
  if (-not [IO.Directory]::Exists($out)) { return '' }
  $rx = '^' + ([regex]::Escape($leaf) -replace '\\\*', '(\d{4}-\d{2}-\d{2})') + '$'
  $best = ''
  foreach ($f in [IO.Directory]::GetFiles($out, $leaf)) {
    $m = [regex]::Match([IO.Path]::GetFileName($f), $rx)
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

function Test-RhStopped {
  # The stop (W9.1 step 4): a superseding early start, or a red leg in push-main (W9.3), writes this run's stop file.
  return [bool]($script:RhStopFile -and [IO.File]::Exists($script:RhStopFile))
}

function Invoke-RhProcess {
  <# A child with its environment set per call (never this process's), both streams drained, and a hang guard that
     kills the whole tree. Returns Rc (-1 could not start, -2 hang guard, -3 stopped), TimedOut, Stopped, Out, Err.
     THE STOP: while it waits it polls $StopFile every $script:RhStopPollMs; on seeing it, it stops its OWN child tree
     (taskkill /T, exactly as the hang guard does) and returns. The rehearsal process itself is never killed by anyone
     else, so its own finally still removes the scratch root and releases its slots. #>
  param([string]$File, [string]$Arguments, [string]$WorkDir, [hashtable]$Env = @{}, [int]$TimeoutSec = 3600, [string]$StopFile = $script:RhStopFile)
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
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $limitMs = [double]$TimeoutSec * 1000
    while ($true) {
      $left = $limitMs - $sw.Elapsed.TotalMilliseconds
      if ($left -le 0) { break }
      if ($p.WaitForExit([int][Math]::Min([double]$script:RhStopPollMs, $left))) { break }
      if ($StopFile -and [IO.File]::Exists($StopFile)) {
        $null = & taskkill.exe /T /F /PID $p.Id
        $p.WaitForExit(30000) | Out-Null
        return [pscustomobject]@{ Rc = -3; TimedOut = $false; Stopped = $true; Out = ''; Err = ('stopped: ' + $StopFile + ' appeared') }
      }
    }
    if (-not $p.HasExited) {
      $null = & taskkill.exe /T /F /PID $p.Id
      $p.WaitForExit(30000) | Out-Null
      return [pscustomobject]@{ Rc = -2; TimedOut = $true; Stopped = $false; Out = ''; Err = ('hang guard: killed after ' + $TimeoutSec + ' s') }
    }
    $p.WaitForExit()
    $tOut.Wait(); $tErr.Wait()
    return [pscustomobject]@{ Rc = $p.ExitCode; TimedOut = $false; Stopped = $false; Out = [string]$tOut.Result; Err = [string]$tErr.Result }
  } catch {
    return [pscustomobject]@{ Rc = -1; TimedOut = $false; Stopped = $false; Out = ''; Err = ('could not start ' + $File + ': ' + $_.Exception.Message) }
  } finally { if ($p) { $p.Dispose() } }
}

$script:RhDefaultSeeder = {
  param([string]$Tree, [string]$SourceRoot)
  $seeder = Join-Path $script:RhRoot 'ops\seed-worktree.ps1'
  $r = Invoke-RhProcess -File 'powershell.exe' -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + $seeder + '" -Target "' + $Tree + '" -Source "' + $SourceRoot + '"') -WorkDir $Tree -Env $script:RhChildTempEnv -TimeoutSec 1800
  return [pscustomobject]@{ Rc = $r.Rc; Stopped = [bool]$r.Stopped; Tail = @((($r.Out + "`n" + $r.Err) -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 6) }
}
# Every child of an arm gets TEMP and TMP INSIDE the scratch root (Invoke-RhArm sets this), so whatever a stopped or
# killed child leaves in its temp directory (check-ad-cycles' own -SelfTest roots, for one) is removed with the root.
$script:RhChildTempEnv = @{}

$script:RhDefaultChainRunner = {
  param([string]$Tree, [int]$TimeoutMin, [hashtable]$ChildEnv)
  $cac = Join-Path $Tree 'grocery\check-ad-cycles.ps1'
  if (-not [IO.File]::Exists($cac)) { return [pscustomobject]@{ Blind = 'chain-missing'; Why = 'the rehearsed tree has no grocery\check-ad-cycles.ps1'; Rc = -1; TimedOut = $false; Tail = @() } }
  # THE INTERLOCK: this tree's own -SelfTest must pass its -NoPublish case, or the chain is never started here.
  $t0 = [DateTime]::UtcNow
  $st = Invoke-RhProcess -File 'powershell.exe' -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + $cac + '" -SelfTest') -WorkDir (Split-Path $cac) -Env $ChildEnv -TimeoutSec 600
  $stSecs = [int]([DateTime]::UtcNow - $t0).TotalSeconds
  if ($st.Stopped) { return [pscustomobject]@{ Blind = 'stopped'; Why = 'stopped during the interlock self-test'; Rc = -3; TimedOut = $false; Stopped = $true; Tail = @(); SelftestSecs = $stSecs; ShipSecs = 0 } }
  $okLine = @(($st.Out -split "`r?`n") | Where-Object { $_ -match '^\s*(ok|PASS)\s' -and $_.Contains($script:RhNoPublishCase) })
  if ($st.Rc -ne 0 -or $okLine.Count -ne 1) {
    return [pscustomobject]@{ Blind = 'nopublish-unproven'; Why = ('the rehearsed check-ad-cycles -SelfTest exited ' + $st.Rc + ' and passed ' + $okLine.Count + ' case(s) naming "' + $script:RhNoPublishCase + '", so its -NoPublish cannot be shown to hold the reader-facing writers; not started'); Rc = -1; TimedOut = $false; Tail = @() }
  }
  $shipOk = @(($st.Out -split "`r?`n") | Where-Object { $_ -match '^\s*(ok|PASS)\s' -and $_.Contains($script:RhShipOnlyCase) })
  if (-not $script:RhFull -and $shipOk.Count -ne 1) {
    return [pscustomobject]@{ Blind = 'shiponly-unproven'; Why = ('the rehearsed check-ad-cycles -SelfTest passed ' + $shipOk.Count + ' case(s) naming "' + $script:RhShipOnlyCase + '", so it cannot be asked to stop at the ship boundary; rehearse with -Full'); Rc = -1; TimedOut = $false; Tail = @() }
  }
  $scopeArg = $(if ($script:RhFull) { '' } else { ' -ShipOnly' })
  $t1 = [DateTime]::UtcNow
  $r = Invoke-RhProcess -File 'powershell.exe' -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + $cac + '" -NoPull -NoCommit -NoPublish -NoAlert' + $scopeArg) -WorkDir (Split-Path $cac) -Env $ChildEnv -TimeoutSec ($TimeoutMin * 60)
  $shipSecs = [int]([DateTime]::UtcNow - $t1).TotalSeconds
  if ($r.Stopped) { return [pscustomobject]@{ Blind = 'stopped'; Why = 'stopped during the ship path'; Rc = -3; TimedOut = $false; Stopped = $true; Tail = @(); SelftestSecs = $stSecs; ShipSecs = $shipSecs } }
  $tail = @((($r.Out + "`n" + $r.Err) -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 12)
  return [pscustomobject]@{ Blind = ''; Why = ''; Rc = $r.Rc; TimedOut = $r.TimedOut; Stopped = $false; Tail = $tail; SelftestSecs = $stSecs; ShipSecs = $shipSecs }
}

function Invoke-RhArm {
  <# One rehearsal of one commit in its own clone. Result pass|fail|blind, Blind (cause), Stages (name -> ok|fail|blind),
     Failed (stage names), Why, Words, DataDate, Secs, StageSecs (seconds per stage: clone, checkout, seed, selftest,
     ship, commit; W9.1 step 6). The clone is left for the caller's finally to remove. A stop (Test-RhStopped) is
     honoured between stages and inside every child wait, and ends the arm blind=stopped. #>
  param([string]$Repo, [string]$Sha, [string]$SourceRoot, [string]$RunRoot, [string]$Arm, [scriptblock]$Seeder, [scriptblock]$ChainRunner, [int]$TimeoutMin, $Manifest)
  $t0 = [DateTime]::UtcNow
  $stages = [ordered]@{ chain = 'not-run'; guards = 'not-run'; commit = 'not-run' }
  $ss = [ordered]@{ clone = 0; checkout = 0; seed = 0; selftest = 0; ship = 0; commit = 0 }
  $mk = { param($result, $blind, $why, $words, $failed, $dd)
    [pscustomobject]@{ Result = $result; Blind = $blind; Why = $why; Words = @($words); Failed = @($failed); Stages = $stages; StageSecs = $ss; DataDate = $dd; Secs = [int]([DateTime]::UtcNow - $t0).TotalSeconds } }
  $lap = [Diagnostics.Stopwatch]::StartNew()
  $stopMsg = 'the rehearsal was stopped (its stop file appeared); nothing is recorded for this content'
  if (Test-RhStopped) { return (& $mk 'blind' 'stopped' $stopMsg @() @() '') }
  $tree = Join-Path $RunRoot $Arm
  $cl = Invoke-RhGit $RunRoot @('-c', 'core.longpaths=true', 'clone', '-q', '--shared', '--no-checkout', $Repo, $tree)
  if ($cl.rc -ne 0) { return (& $mk 'blind' 'clone-failed' ('git clone exited ' + $cl.rc + ': ' + ([string]$cl.stderr).Trim()) @() @() '') }
  $null = Invoke-RhGit $tree @('config', 'core.longpaths', 'true')
  $null = Invoke-RhGit $tree @('remote', 'set-url', '--push', 'origin', (Join-Path $RunRoot 'no-push-from-a-rehearsal'))
  $ss.clone = [int]$lap.Elapsed.TotalSeconds; $lap.Restart()
  $co = Invoke-RhGit $tree @('checkout', '-q', '--detach', $Sha)
  if ($co.rc -ne 0) { return (& $mk 'blind' 'checkout-failed' ('git checkout ' + $Sha + ' exited ' + $co.rc + ': ' + ([string]$co.stderr).Trim()) @() @() '') }
  $ss.checkout = [int]$lap.Elapsed.TotalSeconds; $lap.Restart()
  # A TEMP INSIDE THE ROOT for every child of this arm, so a stopped child's temp leftovers go with the root.
  $childTemp = Join-Path $RunRoot ('t' + $Arm)
  $null = [IO.Directory]::CreateDirectory($childTemp)
  $prevTempEnv = $script:RhChildTempEnv
  $script:RhChildTempEnv = @{ TEMP = $childTemp; TMP = $childTemp }
  try { $sd = & $Seeder $tree $SourceRoot } finally { $script:RhChildTempEnv = $prevTempEnv }
  $ss.seed = [int]$lap.Elapsed.TotalSeconds; $lap.Restart()
  if (($sd.PSObject.Properties['Stopped'] -and $sd.Stopped) -or (Test-RhStopped)) { return (& $mk 'blind' 'stopped' $stopMsg @() @() '') }
  if ($sd.Rc -ne 0) { return (& $mk 'blind' 'seed-failed' ('ops\seed-worktree.ps1 exited ' + $sd.Rc + ': ' + ((@($sd.Tail)) -join ' | ')) @() @() '') }
  foreach ($cp in $script:RhCredentialPaths) {
    if ([IO.File]::Exists((Join-Path $tree $cp))) { return (& $mk 'blind' 'credential-present' ('a live credential arrived in the scratch clone (' + $cp + '); a rehearsal must be unable to mail or publish, so it is not started') @() @() '') }
  }
  $dd = Get-RhNewestBoardDate $tree $Manifest.BoardGlob
  if (-not $dd) { return (& $mk 'blind' 'no-seed-board' 'the seed brought no comparison board (comparison-*.json), so there is no real data to rehearse over' @() @() '') }
  # TC_REHEARSAL_RUN=1 (W9.1 step 3): a post-commit hook that sees it starts nothing, so no commit made inside a
  # rehearsal can start a rehearsal from inside a rehearsal.
  $childEnv = @{ GHOST_ADMIN_KEY = $script:RhSentinelKey; KROGER_CLIENT_ID = 'tc-rehearsal-sentinel'; KROGER_CLIENT_SECRET = 'tc-rehearsal-sentinel'; TC_REHEARSAL = '1'; TC_REHEARSAL_RUN = '1'; TEMP = $childTemp; TMP = $childTemp }
  $verdictPath = Join-Path $tree ($Manifest.VerdictPath -replace '/', '\')
  $before = [DateTime]::UtcNow.AddSeconds(-2)
  $ch = & $ChainRunner $tree $TimeoutMin $childEnv
  $chSecs = [int]$lap.Elapsed.TotalSeconds; $lap.Restart()
  if ($ch.PSObject.Properties['SelftestSecs']) { $ss.selftest = [int]$ch.SelftestSecs; $ss.ship = [int]$ch.ShipSecs } else { $ss.ship = $chSecs }
  if (($ch.PSObject.Properties['Stopped'] -and $ch.Stopped) -or $ch.Blind -eq 'stopped' -or (Test-RhStopped)) { return (& $mk 'blind' 'stopped' $stopMsg @() @() $dd) }
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
  $prevRun = $env:TC_REHEARSAL_RUN
  $env:TC_REHEARSAL_RUN = '1'
  try { $cm = Invoke-RhCommitStage -Repo $tree }
  finally { if ($null -eq $prevRun) { Remove-Item Env:\TC_REHEARSAL_RUN -ErrorAction SilentlyContinue } else { $env:TC_REHEARSAL_RUN = $prevRun } }
  $ss.commit = [int]$lap.Elapsed.TotalSeconds
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

function New-RhStack {
  <# THE STACK (W9.1 step 1): the tree a push would land, built without touching any worktree. The base is -Onto, or
     the first line of -StackFile (W9.2 writes it: the origin sha, then every commit of every ticket ahead, oldest
     first); on it go, in order, the stack file's commits and then the commits of <merge-base>..<Commit>, each applied
     the way `git rebase` applies it (a merge-ort three-way merge against the commit's own parent, `git merge-tree
     --write-tree --merge-base=<parent>`, merges skipped as rebase skips them) and committed with `git commit-tree`.
     All of it happens in a private BARE `git clone --shared` under %TEMP%, so the new objects never enter the shared
     .git and nothing that is checked out moves. Cheap (no checkout), so it runs BEFORE any rehearsal slot is taken,
     and the verdict key of the stacked tip is known before anything waits.
     Returns Ok, Blind (stack-conflict | cannot-read-push | clone-failed | bad-usage), Why, Repo (the bare clone: the
     caller removes it with Remove-RhStack), Onto, Base (the tip before the commit's own range: what a failure pairs
     against), Tip, Applied, Files and ConflictOn (a conflict's files and the commit it stopped on), Secs. #>
  param([string]$Repo, [string]$Commit, [string]$Onto = '', [string]$StackFile = '')
  $t0 = [DateTime]::UtcNow
  $r = [ordered]@{ Ok = $false; Blind = ''; Why = ''; Repo = ''; Onto = ''; Base = ''; Tip = ''; Applied = 0; Files = @(); ConflictOn = ''; Secs = 0 }
  $done = { $r.Secs = [int]([DateTime]::UtcNow - $t0).TotalSeconds; return [pscustomobject]$r }
  $ahead = @()
  $base0 = $Onto
  if ($StackFile) {
    if (-not [IO.File]::Exists($StackFile)) { $r.Blind = 'cannot-read-push'; $r.Why = ('the stack file ' + $StackFile + ' does not exist'); return (& $done) }
    $ls = @([IO.File]::ReadAllLines($StackFile) | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    if ($ls.Count -lt 1) { $r.Blind = 'cannot-read-push'; $r.Why = ('the stack file ' + $StackFile + ' names no base'); return (& $done) }
    if ($Onto -and -not [string]::Equals($Onto, $ls[0], [StringComparison]::OrdinalIgnoreCase)) { $r.Blind = 'bad-usage'; $r.Why = ('-Onto ' + $Onto + ' is not the stack file''s base ' + $ls[0]); return (& $done) }
    $base0 = $ls[0]
    if ($ls.Count -gt 1) { $ahead = @($ls[1..($ls.Count - 1)]) }
  }
  if (-not $base0) { $r.Blind = 'bad-usage'; $r.Why = 'a stack needs -Onto or -StackFile'; return (& $done) }
  $dir = Join-Path $env:TEMP ('tc-rhs-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  # CLONE FROM THE COMMON GIT DIR: $Repo may be a checkout's subfolder (a sandbox) or a linked worktree, and git clones a
  # repository, not a folder inside one. Every commit named here lives in the common object store.
  $gd = Invoke-RhGit $Repo @('rev-parse', '--path-format=absolute', '--git-common-dir')
  $src = $(if ($gd.rc -eq 0 -and ([string]$gd.stdout).Trim()) { (([string]$gd.stdout).Trim() -replace '/', '\') } else { $Repo })
  $cl = Invoke-RhGit $env:TEMP @('clone', '-q', '--bare', '--shared', $src, $dir)
  if ($cl.rc -ne 0) { $r.Blind = 'clone-failed'; $r.Why = ('git clone --bare --shared exited ' + $cl.rc + ': ' + ([string]$cl.stderr).Trim()); return (& $done) }
  $r.Repo = $dir
  $name = { param($spec) $n = Invoke-RhGit $dir @('rev-parse', '--verify', '-q', ([string]$spec + '^{commit}')); if ($n.rc -ne 0) { return '' }; return ([string]$n.stdout).Trim() }
  $onto = & $name $base0
  $head = & $name $Commit
  if (-not $onto -or -not $head) { $r.Blind = 'cannot-read-push'; $r.Why = ('git cannot name ' + $(if (-not $onto) { $base0 } else { $Commit }) + ' as a commit'); return (& $done) }
  $r.Onto = $onto
  $cur = $onto
  $apply = { param($c)
    $par = & $name ($c + '^')
    if (-not $par) { return ('the commit ' + $c + ' has no parent to replay it against') }
    $mt = Invoke-RhGit $dir @('merge-tree', '--write-tree', '--name-only', ('--merge-base=' + $par), $cur, $c)
    $ol = @(([string]$mt.stdout) -split "`r?`n")
    if ($mt.rc -eq 1) {
      $files = New-Object Collections.ArrayList
      for ($i = 1; $i -lt $ol.Count; $i++) { if (-not $ol[$i].Trim()) { break }; [void]$files.Add($ol[$i].Trim()) }
      $r.Files = @($files); $r.ConflictOn = $c
      return 'conflict'
    }
    if ($mt.rc -ne 0 -or -not $ol[0].Trim()) { return ('git merge-tree exited ' + $mt.rc + ': ' + ([string]$mt.stderr).Trim()) }
    $subj = ([string](Invoke-RhGit $dir @('log', '-1', '--format=%s', $c)).stdout).Trim()
    $ct = Invoke-RhGit $dir @('-c', 'user.name=tc-rehearsal-stack', '-c', 'user.email=rehearsal-stack@tc.invalid', 'commit-tree', $ol[0].Trim(), '-p', $cur, '-m', ('stacked by rehearse-chain: ' + $subj))
    if ($ct.rc -ne 0) { return ('git commit-tree exited ' + $ct.rc + ': ' + ([string]$ct.stderr).Trim()) }
    $script:RhStackCur = ([string]$ct.stdout).Trim()
    return ''
  }
  foreach ($a in $ahead) {
    $as = & $name $a
    if (-not $as) { $r.Blind = 'cannot-read-push'; $r.Why = ('the stack file names ' + $a + ', which git cannot name as a commit'); return (& $done) }
    $w = & $apply $as
    if ($w -eq 'conflict') { $r.Blind = 'stack-conflict'; $r.Why = ('a commit of a ticket ahead conflicts with the stack below it'); return (& $done) }
    if ($w) { $r.Blind = 'cannot-read-push'; $r.Why = $w; return (& $done) }
    $cur = $script:RhStackCur; $r.Applied++
  }
  $r.Base = $cur
  $mb = Invoke-RhGit $dir @('merge-base', $head, $onto)
  $mbs = ([string]$mb.stdout).Trim()
  if ($mb.rc -ne 0 -or -not $mbs) { $r.Blind = 'cannot-read-push'; $r.Why = ('git merge-base ' + $head.Substring(0, 9) + ' ' + $onto.Substring(0, 9) + ' found none'); return (& $done) }
  if ($ahead.Count -eq 0 -and [string]::Equals($mbs, $onto, [StringComparison]::Ordinal)) {
    $cur = $head   # HEAD already sits on the base: the stacked tip IS HEAD, with its own id
  } else {
    $rl = Invoke-RhGit $dir @('rev-list', '--reverse', '--no-merges', ($mbs + '..' + $head))
    foreach ($c in @(([string]$rl.stdout) -split "`r?`n" | Where-Object { $_.Trim() })) {
      $w = & $apply $c.Trim()
      if ($w -eq 'conflict') { $r.Blind = 'stack-conflict'; $r.Why = ('this commit''s own range conflicts with the stack it is applied on'); return (& $done) }
      if ($w) { $r.Blind = 'cannot-read-push'; $r.Why = $w; return (& $done) }
      $cur = $script:RhStackCur; $r.Applied++
    }
  }
  $r.Tip = $cur; $r.Ok = $true
  return (& $done)
}

function Remove-RhStack($Stack) {
  if ($Stack -and $Stack.Repo -and ([string]$Stack.Repo).Contains('tc-rhs-')) { Remove-Item -LiteralPath $Stack.Repo -Recurse -Force -ErrorAction SilentlyContinue }
}

function Format-RhStackConflict($Stack) {
  $on = $(if ($Stack.ConflictOn) { $Stack.ConflictOn.Substring(0, 9) } else { '-' })
  return ('chain-rehearsal: STACK CONFLICT - applying ' + $on + ' onto the stack conflicts in: ' + ((@($Stack.Files)) -join ', ') + '. ' + $Stack.Why + '. No verdict is recorded.')
}

function Invoke-RhRehearsal {
  <# Rehearse $Commit, pair a failure against the base, record the verdict, remove every scratch path. Returns the record.
     With -Onto or -StackFile (or a -Stack New-RhStack already built) the rehearsed tree is the STACKED tip, and the key
     is that tip's. A stack conflict records nothing (blind=stack-conflict); a stopped run records nothing (blind=stopped). #>
  param([string]$Repo, [string]$Commit = 'HEAD', [string]$SourceRoot = '', [string]$Remote = 'origin', [string]$Branch = 'main',
        [string]$VerdictDir, [switch]$NoPair, [int]$TimeoutMin = 90, [datetime]$Today = (Get-Date),
        [scriptblock]$Seeder = $script:RhDefaultSeeder, [scriptblock]$ChainRunner = $script:RhDefaultChainRunner,
        [int]$SlotTotal = $script:RhMaxConcurrent, [string]$SlotPrefix = $script:RhSlotPrefix, [string]$SlotQueueRoot = $script:TcGateQueueRoot, [int]$SlotStallSec = $script:RhSlotStallSec,
        [string]$Onto = '', [string]$StackFile = '', $Stack = $null, [switch]$Early, [string]$CheckoutHash = '')
  $t0 = [DateTime]::UtcNow
  $rec = [ordered]@{ result = 'blind'; blind = ''; key = ''; commit = ''; stage = ''; cause = ''; words = @(); data_date = ''; preexisting = @();
    stages = $null; base = ''; scratch = ''; scope = $(if ($script:RhFull) { 'full' } else { 'ship-only' }); slot_waited_s = 0; secs = 0; utc = ''; harness = 'ops\rehearse-chain.ps1'; harness_blob = '';
    early = [bool]$Early; onto = ''; head = ''; checkout = $CheckoutHash; stage_secs = $null }
  $hb = Invoke-RhGit $script:RhRoot @('hash-object', (Join-Path $script:RhRoot 'ops\rehearse-chain.ps1'))
  if ($hb.rc -eq 0) { $rec.harness_blob = ([string]$hb.stdout).Trim() }
  $finish = {
    $rec.secs = [int]([DateTime]::UtcNow - $t0).TotalSeconds
    $rec.utc = [DateTime]::UtcNow.ToString('o')
    # A STOPPED RUN RECORDS NOTHING: it says nothing about the content, and a verdict covers only its own key anyway.
    if ($rec.key -and -not ($rec.result -eq 'blind' -and $rec.blind -eq 'stopped')) { Save-RhVerdict $VerdictDir ([pscustomobject]$rec) }
    return [pscustomobject]$rec
  }
  $rp = Invoke-RhGit $Repo @('rev-parse', '--verify', '-q', ($Commit + '^{commit}'))
  if ($rp.rc -ne 0) { $rec.blind = 'cannot-read-push'; $rec.cause = ('git cannot name ' + $Commit); return (& $finish) }
  $headSha = ([string]$rp.stdout).Trim()
  $rec.head = $headSha
  $ownStack = $false
  if ($null -eq $Stack -and ($Onto -or $StackFile)) { $Stack = New-RhStack -Repo $Repo -Commit $headSha -Onto $Onto -StackFile $StackFile; $ownStack = $true }
  try {
    $gitRepo = $Repo; $sha = $headSha; $pairBase = ''
    if ($Stack) {
      $rec.onto = [string]$Stack.Onto
      if (-not $Stack.Ok) {
        $rec.blind = $Stack.Blind; $rec.cause = $Stack.Why
        if ($Stack.Blind -eq 'stack-conflict') { Write-Host (Format-RhStackConflict $Stack) }
        $rec.secs = [int]([DateTime]::UtcNow - $t0).TotalSeconds; $rec.utc = [DateTime]::UtcNow.ToString('o')
        return [pscustomobject]$rec
      }
      $gitRepo = $Stack.Repo; $sha = $Stack.Tip; $pairBase = $Stack.Base
    }
    $rec.commit = $sha
    $ms = Get-RhManifestSet $gitRepo $sha
    if (-not $ms.Ok) { $rec.blind = 'no-manifest-readable'; $rec.cause = $ms.Why; return (& $finish) }
    $rec.key = $ms.Key
    if (-not $SourceRoot) { $SourceRoot = Get-RhMainCheckout $Repo }
    if (-not $SourceRoot -or -not [IO.Directory]::Exists($SourceRoot)) { $rec.blind = 'no-source'; $rec.cause = 'no main checkout to seed from (pass -Source)'; return (& $finish) }
    if (-not $ms.BoardGlob -or -not $ms.VerdictPath) { $rec.blind = 'no-manifest-readable'; $rec.cause = 'the manifest at this commit declares no board_glob or chain_verdict, so there is nothing to seed-check or read'; return (& $finish) }
    $srcDate = Get-RhNewestBoardDate $SourceRoot $ms.BoardGlob
    if (-not $srcDate) { $rec.blind = 'no-seed-board'; $rec.cause = ('the source checkout ' + $SourceRoot + ' holds no comparison board (comparison-*.json)'); return (& $finish) }
    $sd = [datetime]::ParseExact($srcDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    if (($Today.Date - $sd).Days -gt $ms.MaxAge) { $rec.blind = 'stale-data'; $rec.data_date = $srcDate; $rec.cause = ('the newest board in ' + $SourceRoot + ' is ' + $srcDate + ', older than ' + $ms.MaxAge + ' day(s)'); return (& $finish) }
    # THE CAP, taken before any clone exists. Waiting is not a verdict: nothing is recorded while this waits.
    $slot = $null
    try {
      $slot = Enter-TcGateSlots -Want 1 -Total $SlotTotal -Prefix $SlotPrefix -QueueRoot $SlotQueueRoot -WaitSec $SlotStallSec -PollMs 500 `
        -OnWait { param($ahead) Write-Host ('chain-rehearsal: WAITING for a rehearsal slot - all {0} are in use (Brad''s cap), {1} rehearsal(s) queued ahead of this one. This is a wait, not a failure.' -f $SlotTotal, $ahead) }
    } catch { $slot = $null; Write-Host ('chain-rehearsal: the rehearsal slot queue could not be read (' + $_.Exception.Message + '); not rehearsing rather than exceeding the cap') }
    if ($null -eq $slot -or $slot.TimedOut -or $slot.Count -lt 1) {
      if ($slot) { Exit-TcGateSlots $slot }
      $rec.blind = 'no-rehearsal-slot'; $rec.cause = ('no rehearsal slot came free: the queue of rehearsals did not move for ' + $SlotStallSec + ' s; nothing was recorded for this content, so rehearse again')
      $rec.secs = [int]([DateTime]::UtcNow - $t0).TotalSeconds; $rec.utc = [DateTime]::UtcNow.ToString('o')
      return [pscustomobject]$rec
    }
    $rec.slot_waited_s = [int]($slot.WaitedMs / 1000)
    $runRoot = Join-Path $env:TEMP ('tc-rh-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
    $null = New-Item -ItemType Directory -Path $runRoot -ErrorAction Stop
    $rec.scratch = $runRoot
    try {
      $a = Invoke-RhArm -Repo $gitRepo -Sha $sha -SourceRoot $SourceRoot -RunRoot $runRoot -Arm 'h' -Seeder $Seeder -ChainRunner $ChainRunner -TimeoutMin $TimeoutMin -Manifest $ms
      $rec.stages = $a.Stages; $rec.data_date = $a.DataDate
      $stS = [ordered]@{ stack = $(if ($Stack) { [int]$Stack.Secs } else { 0 }) }
      foreach ($k in @($a.StageSecs.Keys)) { $stS[$k] = $a.StageSecs[$k] }
      $rec.stage_secs = $stS
      if ($a.Result -eq 'blind') { $rec.result = 'blind'; $rec.blind = $a.Blind; $rec.cause = $a.Why; return (& $finish) }
      if ($a.Result -eq 'pass') { $rec.result = 'pass'; $rec.cause = $a.Why; return (& $finish) }
      $rec.result = 'fail'; $rec.stage = ($a.Failed -join ','); $rec.cause = $a.Why; $rec.words = @($a.Words)
      if ($NoPair) { return (& $finish) }
      if ($Stack) { $base = $pairBase; $mbrc = 0 }
      else {
        $mb = Invoke-RhGit $Repo @('merge-base', $sha, ($Remote + '/' + $Branch))
        $base = ([string]$mb.stdout).Trim(); $mbrc = $mb.rc
      }
      if ($mbrc -ne 0 -or -not $base -or $base -eq $sha) { $rec.cause += ' (no distinct base to pair against, so the failure stands)'; return (& $finish) }
      $rec.base = $base
      $b = Invoke-RhArm -Repo $gitRepo -Sha $base -SourceRoot $SourceRoot -RunRoot $runRoot -Arm 'b' -Seeder $Seeder -ChainRunner $ChainRunner -TimeoutMin $TimeoutMin -Manifest (Get-RhManifestSet $gitRepo $base)
      if ($b.Result -eq 'blind' -and $b.Blind -eq 'stopped') { $rec.result = 'blind'; $rec.blind = 'stopped'; $rec.cause = $b.Why; return (& $finish) }
      if ($b.Result -eq 'blind') { $rec.cause += (' (the base arm could not run, blind=' + $b.Blind + ', so the failure stands)'); return (& $finish) }
      $new = @($a.Failed | Where-Object { @($b.Failed) -notcontains $_ })
      $pre = @($a.Failed | Where-Object { @($b.Failed) -contains $_ })
      $rec.preexisting = $pre
      if ($new.Count -eq 0) { $rec.result = 'pass'; $rec.stage = ''; $rec.cause = ('every failed stage (' + ($pre -join ',') + ') fails on the base ' + $base.Substring(0, 9) + ' too, over the same data') }
      else { $rec.stage = ($new -join ','); if ($pre.Count) { $rec.cause += (' (also failing on the base, so preexisting: ' + ($pre -join ',') + ')') } }
      return (& $finish)
    } finally {
      Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
      Exit-TcGateSlots $slot
      if (Test-Path -LiteralPath $runRoot) { Write-Host ('chain-rehearsal: LEFTOVER - the scratch root ' + $runRoot + ' could not be removed (a process may still hold a file in it); remove it by hand') }
    }
  } finally {
    if ($ownStack) { Remove-RhStack $Stack }
  }
}

function Get-RhCheckoutHash([string]$Path) {
  # SHA-256 of the lower-cased full checkout path: the in-flight file's name and the verdict record's `checkout`.
  $full = [IO.Path]::GetFullPath($Path).TrimEnd('\').ToLowerInvariant()
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($full))) -replace '-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
}

function Test-RhInFlightLive($Rec) {
  # A recorded early run is live when its pid is running AND began when the record says (a reused pid is not it).
  if ($null -eq $Rec -or -not $Rec.pid) { return $false }
  $pr = Get-Process -Id ([int]$Rec.pid) -ErrorAction SilentlyContinue
  if ($null -eq $pr) { return $false }
  try { $st = $pr.StartTime.ToUniversalTime().Ticks } catch { return $true }
  return ([string]$st -eq [string]$Rec.pid_start)
}

function Wait-RhInFlightKey {
  <# E1 of design\PLAN-faster-pushes-no-accuracy-loss-2026-09-25.md: a push that would rehearse KEY waits for a LIVE early
     run of that EXACT key (any checkout) to end, instead of starting a second, identical rehearsal beside it. Measured
     before this: 6 of 16 chain landings did exactly that. Returns Outcome none (no live run of the key; nothing waited),
     ended (the run is no longer live; the caller re-reads the verdict and rehearses itself when there is none), stopped
     (this run's own stop file appeared) or timeout (MaxMin passed; the caller rehearses itself), and Polls. It never
     decides a verdict: the caller reads the recorded one, exactly as it reads any other. -OnPoll is the self-test's seam. #>
  param([string]$VerdictDir, [string]$Key, [int]$MaxMin = 90, [int]$PollMs = 5000, [scriptblock]$OnPoll = $null, [scriptblock]$Say = $null)
  $earlyDir = Join-Path $VerdictDir 'early'
  $findLive = {
    if (-not $Key -or -not [IO.Directory]::Exists($earlyDir)) { return $null }
    foreach ($f in [IO.Directory]::GetFiles($earlyDir, '*.json')) {
      $o = $null; try { $o = [IO.File]::ReadAllText($f) | ConvertFrom-Json } catch { $o = $null }
      if ($o -and [string]::Equals([string]$o.key, $Key, [StringComparison]::Ordinal) -and (Test-RhInFlightLive $o)) { return $o }
    }
    return $null
  }
  $live = & $findLive
  if ($null -eq $live) { return [pscustomobject]@{ Outcome = 'none'; Polls = 0 } }
  if ($Say) { & $Say ('chain-rehearsal: an early rehearsal of this exact content is already running (pid ' + $live.pid + ', key ' + $Key.Substring(0, 12) + '); waiting for its verdict instead of starting a second one') }
  $sw = [Diagnostics.Stopwatch]::StartNew(); $polls = 0
  while ($true) {
    if (Test-RhStopped) { return [pscustomobject]@{ Outcome = 'stopped'; Polls = $polls } }
    if ($sw.Elapsed.TotalMinutes -ge $MaxMin) { return [pscustomobject]@{ Outcome = 'timeout'; Polls = $polls } }
    if ($OnPoll) { & $OnPoll $polls }
    Start-Sleep -Milliseconds $PollMs
    $polls++
    if ($null -eq (& $findLive)) { return [pscustomobject]@{ Outcome = 'ended'; Polls = $polls } }
  }
}

function Invoke-RhEarly {
  <# -EARLY (W9.1 step 2): rehearse $Commit rebased onto $Onto (or the stack a -StackFile lists) as the speculative
     rehearsal a commit starts, under every rule of a push-time one plus four of its own:
       - it starts nothing when the stacked content touches no manifest member (Get-RhTrigger $Onto..tip, the union),
         when a pass or fail verdict for the stacked key is already recorded over fresh data, or when a LIVE in-flight
         early run in ANY checkout already holds that key;
       - it records its run at <verdict dir>\early\<SHA-256 of the lower-cased checkout path>.json (pid, key, onto,
         head, start, stop file) through Write-TcAtomicFile, and removes it when it ends;
       - SUPERSEDE: when this checkout's in-flight file names a LIVE run of a DIFFERENT key, it writes that run's stop
         file first (a stop that cannot be written is reported and ignored: the older run finishes, which is harmless
         because a verdict covers only its own key);
       - it takes an EARLY CAP (4 of the 6 slots at most, plan 16.6 order 2a) before the rehearsal slot (2b).
     Returns Started, Reason (rehearsed | not-chain | verdict-exists | in-flight | stack-conflict | no-early-cap |
     cannot-read-push | bad-usage | no-manifest-readable | cannot-diff | stopped-before-start), Key, Record,
     InFlight, StopFile, Superseded, Lines. #>
  param([string]$Repo, [string]$Commit = 'HEAD', [string]$Onto = '', [string]$StackFile = '', [string]$VerdictDir, [string]$SourceRoot = '',
        [string]$CheckoutPath = '', [datetime]$Today = (Get-Date), [switch]$NoPair, [int]$TimeoutMin = 90,
        [scriptblock]$Seeder = $script:RhDefaultSeeder, [scriptblock]$ChainRunner = $script:RhDefaultChainRunner,
        [int]$EarlyTotal = $script:RhEarlyMaxSlots, [string]$EarlyPrefix = $script:RhEarlyPrefix, [string]$EarlyQueueRoot = $script:TcGateQueueRoot, [int]$EarlyStallSec = $script:RhEarlyStallSec,
        [int]$SlotTotal = $script:RhMaxConcurrent, [string]$SlotPrefix = $script:RhSlotPrefix, [string]$SlotQueueRoot = $script:TcGateQueueRoot, [int]$SlotStallSec = $script:RhSlotStallSec)
  $res = [ordered]@{ Started = $false; Reason = ''; Key = ''; Record = $null; InFlight = ''; StopFile = ''; Superseded = ''; Lines = (New-Object Collections.ArrayList) }
  $say = { param($t) [void]$res.Lines.Add([string]$t) }
  if (-not $Onto -and -not $StackFile) { $res.Reason = 'bad-usage'; & $say 'chain-rehearsal: COULD NOT EVALUATE blind=bad-usage - -Early needs -Onto <sha> (or -StackFile)'; return [pscustomobject]$res }
  if (-not $CheckoutPath) { $CheckoutPath = $Repo }
  $rp = Invoke-RhGit $Repo @('rev-parse', '--verify', '-q', ($Commit + '^{commit}'))
  if ($rp.rc -ne 0) { $res.Reason = 'cannot-read-push'; & $say ('chain-rehearsal: COULD NOT EVALUATE blind=cannot-read-push - git cannot name ' + $Commit); return [pscustomobject]$res }
  $headSha = ([string]$rp.stdout).Trim()
  $earlyDir = Join-Path $VerdictDir 'early'
  $ck = Get-RhCheckoutHash $CheckoutPath
  $mine = Join-Path $earlyDir ($ck + '.json')
  $stack = New-RhStack -Repo $Repo -Commit $headSha -Onto $Onto -StackFile $StackFile
  $cap = $null; $prevStop = $script:RhStopFile; $wrote = $false; $myStop = ''
  try {
    if (-not $stack.Ok) {
      $res.Reason = $stack.Blind
      if ($stack.Blind -eq 'stack-conflict') { & $say (Format-RhStackConflict $stack) }
      & $say ('chain-rehearsal: COULD NOT EVALUATE blind=' + $stack.Blind + ' - ' + $stack.Why)
      return [pscustomobject]$res
    }
    $tr = Get-RhTrigger -Repo $stack.Repo -Base $stack.Onto -Tip $stack.Tip
    if ($tr.Absent) { $res.Reason = 'not-chain'; & $say ('chain-rehearsal: EARLY - ' + $tr.Why + '; nothing to rehearse against, so nothing starts'); return [pscustomobject]$res }
    if ($tr.Blind) { $res.Reason = $tr.Blind; & $say ('chain-rehearsal: COULD NOT EVALUATE blind=' + $tr.Blind + ' - ' + $tr.Why); return [pscustomobject]$res }
    if (@($tr.Touched).Count -eq 0) { $res.Reason = 'not-chain'; & $say ('chain-rehearsal: EARLY - this content touches no chain-manifest member onto ' + $stack.Onto.Substring(0, 9) + ', so nothing starts'); return [pscustomobject]$res }
    $key = $tr.Manifest.Key; $res.Key = $key
    $v = Read-RhVerdict $VerdictDir $key
    if ($v -and ([string]$v.result -eq 'pass' -or [string]$v.result -eq 'fail')) {
      $dd = [datetime]::MinValue
      if ([datetime]::TryParseExact([string]$v.data_date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dd) -and (($Today.Date - $dd.Date).Days -le $tr.Manifest.MaxAge)) {
        $res.Reason = 'verdict-exists'; & $say ('chain-rehearsal: EARLY - a ' + $v.result + ' verdict is already recorded for this stacked content (key ' + $key.Substring(0, 12) + '), so nothing starts'); return [pscustomobject]$res
      }
    }
    if ([IO.Directory]::Exists($earlyDir)) {
      foreach ($f in [IO.Directory]::GetFiles($earlyDir, '*.json')) {
        $o = $null; try { $o = [IO.File]::ReadAllText($f) | ConvertFrom-Json } catch { $o = $null }
        if ($o -and [string]::Equals([string]$o.key, $key, [StringComparison]::Ordinal) -and (Test-RhInFlightLive $o)) {
          $res.Reason = 'in-flight'; $res.InFlight = $f
          & $say ('chain-rehearsal: EARLY - an early rehearsal of this key is already in flight (pid ' + $o.pid + ', ' + [IO.Path]::GetFileName($f) + '), so nothing starts')
          return [pscustomobject]$res
        }
      }
    }
    if ([IO.File]::Exists($mine)) {
      $old = $null; try { $old = [IO.File]::ReadAllText($mine) | ConvertFrom-Json } catch { $old = $null }
      if ($old -and (Test-RhInFlightLive $old) -and $old.stop_file) {
        try { $null = Write-TcAtomicFile -Path ([string]$old.stop_file) -Text ('superseded by pid ' + $PID + ' key ' + $key) -NoBom -NoNewline; $res.Superseded = [string]$old.pid
          & $say ('chain-rehearsal: EARLY - SUPERSEDED the in-flight early rehearsal of key ' + ([string]$old.key).Substring(0, 12) + ' (pid ' + $old.pid + ') in this checkout: its stop file is written') }
        catch { & $say ('chain-rehearsal: EARLY - the older run''s stop file could not be written (' + $_.Exception.Message + '); it runs to the end, which is harmless') }
      }
    }
    if (-not [IO.Directory]::Exists($earlyDir)) { $null = [IO.Directory]::CreateDirectory($earlyDir) }
    $myStop = Join-Path $earlyDir ($ck + '-' + $PID + '.stop')
    if ([IO.File]::Exists($myStop)) { [IO.File]::Delete($myStop) }
    $me = Get-Process -Id $PID
    $inf = [ordered]@{ pid = $PID; pid_start = [string]$me.StartTime.ToUniversalTime().Ticks; key = $key; onto = $stack.Onto; head = $headSha; tip = $stack.Tip; start = [DateTime]::UtcNow.ToString('o'); stop_file = $myStop; checkout = $ck }
    $null = Write-TcAtomicFile -Path $mine -Text ($inf | ConvertTo-Json -Compress) -NoBom -NoNewline
    $wrote = $true; $res.InFlight = $mine; $res.StopFile = $myStop
    $script:RhStopFile = $myStop
    try {
      $cap = Enter-TcGateSlots -Want 1 -Total $EarlyTotal -Prefix $EarlyPrefix -QueueRoot $EarlyQueueRoot -WaitSec $EarlyStallSec -PollMs 500 `
        -OnWait { param($ahead) Write-Host ('chain-rehearsal: EARLY WAITING for an early-rehearsal cap - all {0} are in use, {1} queued ahead. Push-time rehearsals are not held by this.' -f $EarlyTotal, $ahead) }
    } catch { $cap = $null; & $say ('chain-rehearsal: the early cap queue could not be read (' + $_.Exception.Message + ')') }
    if ($null -eq $cap -or $cap.TimedOut -or $cap.Count -lt 1) { $res.Reason = 'no-early-cap'; & $say ('chain-rehearsal: COULD NOT EVALUATE blind=no-early-cap - no early-rehearsal cap came free inside ' + $EarlyStallSec + ' s; nothing started'); return [pscustomobject]$res }
    if (Test-RhStopped) { $res.Reason = 'stopped-before-start'; & $say 'chain-rehearsal: EARLY - stopped before it started'; return [pscustomobject]$res }
    $res.Started = $true; $res.Reason = 'rehearsed'
    & $say ('chain-rehearsal: EARLY - rehearsing ' + $headSha.Substring(0, 9) + ' rebased onto ' + $stack.Onto.Substring(0, 9) + ' (key ' + $key.Substring(0, 12) + '), in-flight file ' + $mine)
    $res.Record = Invoke-RhRehearsal -Repo $Repo -Commit $headSha -Stack $stack -Early -CheckoutHash $ck -VerdictDir $VerdictDir -SourceRoot $SourceRoot -Today $Today -NoPair:$NoPair -TimeoutMin $TimeoutMin `
      -Seeder $Seeder -ChainRunner $ChainRunner -SlotTotal $SlotTotal -SlotPrefix $SlotPrefix -SlotQueueRoot $SlotQueueRoot -SlotStallSec $SlotStallSec
    return [pscustomobject]$res
  } finally {
    if ($cap) { Exit-TcGateSlots $cap }
    $script:RhStopFile = $prevStop
    if ($wrote -and [IO.File]::Exists($mine)) {
      $o = $null; try { $o = [IO.File]::ReadAllText($mine) | ConvertFrom-Json } catch { $o = $null }
      if ($o -and [string]$o.pid -eq [string]$PID) { try { [IO.File]::Delete($mine) } catch { } }
    }
    if ($myStop -and [IO.File]::Exists($myStop)) { try { [IO.File]::Delete($myStop) } catch { } }
    Remove-RhStack $stack
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

function Get-RhListSet {
  <# -LISTSET (W0.5): the manifest set at one commit and, with a range, the trigger -ForPush would decide for it, as the
     lines the header's output contract names. Returns Code (0 listed, 3 could not evaluate) and Lines, the last of
     which is always the CHAIN-REHEARSAL-LISTSET-COMPLETE marker. Reads git only: no clone, no slot, no verdict read, no
     write, so nothing here can change what a push decides. $CommitGiven says -Commit was passed explicitly; with a
     range it must name the range's tip, because the set a range triggers on is the one AT its tip. #>
  param([string]$Repo, [string]$Commit = 'HEAD', [string]$Range = '', [switch]$CommitGiven)
  $blind = { param($cause, $why)
    return [pscustomobject]@{ Code = 3; Lines = @(('chain-rehearsal: COULD NOT EVALUATE blind=' + $cause + ' - ' + $why), ('CHAIN-REHEARSAL-LISTSET-COMPLETE blind=' + $cause)) } }
  $name = { param($spec) $n = Invoke-RhGit $Repo @('rev-parse', '--verify', '-q', ([string]$spec + '^{commit}')); if ($n.rc -ne 0) { return '' }; return ([string]$n.stdout).Trim() }
  $base = ''
  if ($Range) {
    $ix = $Range.IndexOf('..')
    if ($Range.Contains('...')) { return (& $blind 'bad-range' ('-Range ' + $Range + ' has three dots, which diff from the merge base; -ForPush diffs the two endpoints tree to tree, so write <base>..<tip>')) }
    if ($ix -lt 1 -or ($ix + 2) -ge $Range.Length) { return (& $blind 'bad-range' ('-Range ' + $Range + ' is not <base>..<tip>')) }
    $a = $Range.Substring(0, $ix); $b = $Range.Substring($ix + 2)
    $base = & $name $a
    $sha = & $name $b
    if (-not $base -or -not $sha) { return (& $blind 'bad-range' ('git cannot name ' + $(if (-not $base) { $a } else { $b }) + ' as a commit')) }
    if ($CommitGiven) {
      $c = & $name $Commit
      if (-not [string]::Equals($c, $sha, [StringComparison]::Ordinal)) { return (& $blind 'bad-range' ('-Commit ' + $Commit + ' is not the tip of -Range ' + $Range + '; with a range the set listed is the one at its tip, which is the set the trigger reads')) }
    }
    $tr = Get-RhTrigger -Repo $Repo -Base $base -Tip $sha
    if ($tr.Blind) { return (& $blind $tr.Blind $tr.Why) }
    $ms = $tr.Manifest
  } else {
    $sha = & $name $Commit
    if (-not $sha) { return (& $blind 'cannot-read-commit' ('git cannot name ' + $Commit + ' as a commit')) }
    $ms = Get-RhManifestSet $Repo $sha
    if (-not $ms.Ok -and -not $ms.Absent) { return (& $blind 'no-manifest-readable' $ms.Why) }
  }
  $out = New-Object Collections.ArrayList
  $paths = [string[]]@()
  $cpaths = [string[]]@()
  if ($ms.Ok) {
    $paths = [string[]]@($ms.Set.Keys); [Array]::Sort($paths, [StringComparer]::Ordinal)
    $cpaths = [string[]]@($ms.Closure.Keys); [Array]::Sort($cpaths, [StringComparer]::Ordinal)
  }
  foreach ($p in $paths) { [void]$out.Add($p) }
  foreach ($p in $cpaths) { [void]$out.Add('CHAIN-REHEARSAL-CLOSURE ' + $p + ' <- ' + [string]$ms.Closure[$p]) }
  $tail = ''
  if ($Range) {
    $tp = [string[]]@($tr.Touched)
    [Array]::Sort($tp, [StringComparer]::Ordinal)
    $dec = $(if ($tp.Count) { 'needed' } else { 'not-needed' })
    [void]$out.Add(('CHAIN-REHEARSAL-TRIGGER range={0}..{1} decision={2} touched={3}' -f $base, $sha, $dec, $tp.Count))
    foreach ($p in $tp) { [void]$out.Add('CHAIN-REHEARSAL-TOUCHED ' + $p) }
    $tail = ' decision=' + $dec
  }
  if ($ms.Ok) { [void]$out.Add(('CHAIN-REHEARSAL-LISTSET-COMPLETE files={0} members={1} closure={2} commit={3} key={4}{5}' -f $paths.Count, ($paths.Count - $cpaths.Count), $cpaths.Count, $sha, $ms.Key, $tail)) }
  else { [void]$out.Add(('CHAIN-REHEARSAL-LISTSET-COMPLETE files=0 members=0 closure=0 commit={0} key=- manifest=absent{1}' -f $sha, $tail)) }
  return [pscustomobject]@{ Code = 0; Lines = @($out) }
}

# ======================================================================================================================
if ($SelfTest) {
  $script:rhCases = 0; $script:rhFail = 0
  function Test-RhCase([string]$Label, [scriptblock]$Body) {
    # A BODY RETURNS EXACTLY TWO THINGS: the verdict and the got-text. `a -and b, 'got'` parses as `a -and (b, 'got')`
    # because the comma binds tighter than -and, so b is never judged (a two-element array is truthy) and the body
    # returns ONE boolean. Found 2026-09-23 while killing M11: every multi-condition case here had an inert last
    # condition. So a body that does not return a pair is a FAILED case, and every verdict is wrapped whole: `(a -and b), 'got'`.
    $script:rhCases++
    $res = Get-RhCaseResult $Body
    if ($res.Ok) { Write-Output ('ok    ' + $Label) } else { $script:rhFail++; Write-Output ('FAIL  ' + $Label + '   got: ' + $res.Got) }
  }
  function Get-RhCaseResult([scriptblock]$Body) {
    $got = ''
    try {
      $ErrorActionPreference = 'Stop'; $r = @(& $Body)
      if ($r.Count -ne 2 -or -not ($r[0] -is [bool])) { $ok = $false; $got = ('the case body returned ' + $r.Count + ' value(s), not (verdict, got); wrap the whole verdict in parentheses') }
      else { $ok = [bool]$r[0]; $got = [string]$r[1] }
    }
    catch { $ok = $false; $got = 'threw: ' + $_.Exception.Message }
    return [pscustomobject]@{ Ok = $ok; Got = $got }
  }
  $malformed = Get-RhCaseResult { ($true) -and ($false), ('got') }   # and-comma-case:allow the MUST FIRE below runs the founding shape on purpose, to prove the harness fails it
  Test-RhCase 'MUST FIRE  the case harness scores a body whose last condition the comma swallowed (`a -and b, got`) as FAILED, never as a pass' {
    ((-not $malformed.Ok) -and ($malformed.Got -match 'returned 1 value')), ('ok=' + $malformed.Ok + ' got=' + $malformed.Got)
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
      $null = [IO.Directory]::CreateDirectory((Join-Path $d 'meal-prep\db'))   # reach-fixture-ok: builds a throwaway fixture repo under %TEMP%; nothing opens the live module
      [IO.File]::WriteAllBytes((Join-Path $d 'meal-prep\db\cost-flags.txt'), [byte[]]($bom + [Text.Encoding]::ASCII.GetBytes("Example flag line`n")))   # reach-fixture-ok: builds a throwaway fixture repo under %TEMP%; nothing opens the live module
      $null = Save-RhCommit $d 'seed'
      return $d
    }

    # ---- 1. THE FOUNDING DEFECT: an EMPTY cost-flags.txt against the 09-05 hook ----
    $old = New-RhHookRepo 'o' $true
    [IO.File]::WriteAllBytes((Join-Path $old 'meal-prep\db\cost-flags.txt'), [byte[]]@())   # reach-fixture-ok: builds a throwaway fixture repo under %TEMP%; nothing opens the live module
    $oc = Invoke-RhCommitStage -Repo $old
    Test-RhCase 'MUST FIRE  the founding defect: the bot''s commit of an EMPTY cost-flags.txt is REFUSED by the 09-05 hook, in its own words (BOM CHANGED)' {
      (($oc.Outcome -eq 'refused') -and ((@($oc.Words) -join "`n") -match 'BOM CHANGED') -and ((@($oc.Words) -join "`n") -match 'cost-flags\.txt')), ($oc.Outcome + ' | ' + ((@($oc.Words) | Select-Object -First 3) -join ' / '))
    }
    $new = New-RhHookRepo 'n' $false
    [IO.File]::WriteAllBytes((Join-Path $new 'meal-prep\db\cost-flags.txt'), [byte[]]@())   # reach-fixture-ok: builds a throwaway fixture repo under %TEMP%; nothing opens the live module
    $nc = Invoke-RhCommitStage -Repo $new
    $nHead = ([string](Invoke-RhGit $new @('log', '-1', '--format=%an|%s')).stdout).Trim()
    Test-RhCase 'CLEAN TWIN  the same empty file through TODAY''S hook is committed, as smp-pipeline-bot, so the harness passes a fixed tree' {
      (($nc.Outcome -eq 'committed') -and ($nHead -like 'smp-pipeline-bot|*rehearsal*')), ($nc.Outcome + ' | ' + $nHead + ' | ' + ((@($nc.Words) | Select-Object -First 3) -join ' / '))
    }
    Test-RhCase 'MUST FIRE  the commit stage refuses to install a hook anywhere but a standalone repository''s own .git' {
      $wt = Join-Path $st 'wt'
      $null = Invoke-RhGit $new @('worktree', 'add', '-q', '--detach', $wt)
      $w = Invoke-RhCommitStage -Repo $wt
      $null = Invoke-RhGit $new @('worktree', 'remove', '--force', $wt)
      (($w.Outcome -eq 'blind') -and ($w.Why -match 'not a standalone repository')), ($w.Outcome + ' ' + $w.Why)
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
      (($dNo.Code -eq 1) -and ($dNo.Outcome -eq 'no-verdict') -and ((@($dNo.Lines) -join ' ') -match 'check-ad-cycles\.ps1') -and ((@($dNo.Lines) -join ' ') -match 'rehearse-chain')), ('' + $dNo.Code + ' ' + $dNo.Outcome + ' ' + (@($dNo.Lines) -join ' / '))
    }
    $dDoc = Get-RhPushDecision -Repo $p -RefLines @($refDoc) -VerdictDir $vd -Today $today
    Test-RhCase 'MUST NOT FIRE  a push touching no manifest script needs no rehearsal (exit 0) and says so' {
      (($dDoc.Code -eq 0) -and ($dDoc.Outcome -eq 'not-needed') -and ((@($dDoc.Lines) -join ' ') -match 'no rehearsal needed')), ('' + $dDoc.Code + ' ' + $dDoc.Outcome)
    }
    $dBranch = Get-RhPushDecision -Repo $p -RefLines @('refs/heads/rh ' + $c1 + ' refs/heads/rh ' + $c0) -VerdictDir $vd -Today $today
    Test-RhCase 'MUST NOT FIRE  a push to a branch other than main is not asked for a rehearsal' { ($dBranch.Code -eq 0), ('' + $dBranch.Code) }
    Test-RhCase 'CLEAN TWIN  a doc-only commit after a rehearsal keeps the verdict key; a manifest change moves it' {
      (($k1 -eq $k2) -and ($k1 -ne (Get-RhManifestSet $p $c0).Key)), ($k1 + ' ' + $k2)
    }
    Test-RhCase 'MUST FIRE  derive_from: an audit NAMED by guards.ps1 is in the set; one it does not name, a named test-*.ps1 under exclude_globs, and README are not' {
      $s = (Get-RhManifestSet $p $c1).Set
      ($s.ContainsKey('grocery/audit-thing.ps1') -and (-not $s.ContainsKey('grocery/audit-other.ps1')) -and $s.ContainsKey('grocery/build-x.ps1') -and (-not $s.ContainsKey('README.md')) -and (-not $s.ContainsKey('grocery/test-thing.ps1'))), (@($s.Keys) -join ',')
    }
    function Set-RhVerdict([string]$Key, [string]$Result, [string]$DataDate, [string]$Blind = '', [string]$Stage = '') {
      Save-RhVerdict $vd ([pscustomobject]@{ result = $Result; blind = $Blind; key = $Key; stage = $Stage; cause = ('fixture ' + $Result); words = @('fixture words'); data_date = $DataDate; preexisting = @() })
    }
    Set-RhVerdict $k1 'blind' '2026-09-22' 'no-seed-board'
    $dBlind = Get-RhPushDecision -Repo $p -RefLines @($refChain) -VerdictDir $vd -Today $today
    Test-RhCase 'MUST NOT FIRE  a rehearsal that COULD NOT RUN is not a pass: exit 3, and the line names its cause (blind=no-seed-board)' {
      (($dBlind.Code -eq 3) -and ($dBlind.Outcome -eq 'could-not-rehearse') -and ((@($dBlind.Lines) -join ' ') -match 'blind=no-seed-board') -and ((@($dBlind.Lines) -join ' ') -match 'not a pass')), ('' + $dBlind.Code + ' ' + (@($dBlind.Lines) -join ' / '))
    }
    Set-RhVerdict $k1 'fail' '2026-09-22' '' 'commit'
    $dFail = Get-RhPushDecision -Repo $p -RefLines @($refChain) -VerdictDir $vd -Today $today
    Test-RhCase 'MUST FIRE  a recorded FAILED rehearsal refuses (exit 1) and names the stage' {
      (($dFail.Code -eq 1) -and ($dFail.Outcome -eq 'rehearsed-fail') -and ((@($dFail.Lines) -join ' ') -match 'stage commit')), ('' + $dFail.Code + ' ' + $dFail.Outcome)
    }
    Set-RhVerdict $k1 'pass' '2026-09-20'
    $dAt = Get-RhPushDecision -Repo $p -RefLines @($refChain) -VerdictDir $vd -Today $today
    Test-RhCase 'CLEAN TWIN  a pass over data exactly AT the 2-day bar (09-20 on 09-22) lets the push through (exit 0)' {
      (($dAt.Code -eq 0) -and ($dAt.Outcome -eq 'rehearsed-pass') -and ((@($dAt.Lines) -join ' ') -match 'PASSED')), ('' + $dAt.Code + ' ' + $dAt.Outcome)
    }
    $dDocAfter = Get-RhPushDecision -Repo $p -RefLines @('refs/heads/main ' + $c2 + ' refs/heads/main ' + $c0) -VerdictDir $vd -Today $today
    Test-RhCase 'CLEAN TWIN  the same pass still holds when a doc commit rides on top of the rehearsed one' { ($dDocAfter.Code -eq 0), ('' + $dDocAfter.Code + ' ' + $dDocAfter.Outcome) }
    Set-RhVerdict $k1 'pass' '2026-09-19'
    $dPast = Get-RhPushDecision -Repo $p -RefLines @($refChain) -VerdictDir $vd -Today $today
    Test-RhCase 'MUST FIRE  a pass over data one day PAST the 2-day bar (09-19 on 09-22, 3 days) is stale and refused' {
      (($dPast.Code -eq 1) -and ($dPast.Outcome -eq 'stale')), ('' + $dPast.Code + ' ' + $dPast.Outcome)
    }
    [IO.File]::Delete((Join-Path $vd ($k1 + '.json')))
    $dBy = Get-RhPushDecision -Repo $p -RefLines @($refChain) -VerdictDir $vd -Today $today -Bypass 'fixture: emergency'
    $logRows = @()
    if ([IO.File]::Exists((Join-Path $vd 'bypass-log.jsonl'))) { $logRows = @([IO.File]::ReadAllLines((Join-Path $vd 'bypass-log.jsonl')) | Where-Object { $_ }) }
    Test-RhCase 'CLEAN TWIN  -NoRehearsal (TC_NO_REHEARSAL) still lets the push through, says so LOUDLY and logs the bypass with its reason' {
      (($dBy.Code -eq 0) -and ($dBy.Outcome -eq 'bypassed') -and ((@($dBy.Lines) -join ' ') -match '\*\*\* REHEARSAL BYPASSED') -and ($logRows.Count -eq 1) -and ($logRows[0] -match 'fixture: emergency')), ('' + $dBy.Code + ' ' + $dBy.Outcome + ' rows=' + $logRows.Count)
    }
    $dCreate = Get-RhPushDecision -Repo $p -RefLines @('refs/heads/main ' + $c1 + ' refs/heads/main ' + ('0' * 40)) -VerdictDir $vd -Today $today
    Test-RhCase 'MUST NOT FIRE  a push the harness cannot diff is exit 3 with blind=cannot-diff, never a silent pass' { (($dCreate.Code -eq 3) -and ((@($dCreate.Lines) -join ' ') -match 'blind=cannot-diff')), ('' + $dCreate.Code) }

    # ---- 2b. THE UNION TRIGGER (W6.0): a deleted member is a member only at the push's BASE. Each case names the deleted
    # path in the refusal, so a trigger read at the tip alone (mutant M11) turns it red even where the manifest's own
    # edit would still have asked for a rehearsal.
    $vdU = Join-Path $st 'verdicts-union'
    [IO.File]::Delete((Join-Path $p 'grocery\build-x.ps1'))
    $u1 = Save-RhCommit $p 'delete a GLOB member, manifest untouched'
    $dGlobDel = Get-RhPushDecision -Repo $p -RefLines @('refs/heads/main ' + $u1 + ' refs/heads/main ' + $c2) -VerdictDir $vdU -Today $today
    Test-RhCase 'MUST FIRE  a push that deletes a manifest member reached by a glob, and edits nothing else, needs a rehearsal (the member is in the set only at the base)' {
      (($dGlobDel.Code -eq 1) -and ($dGlobDel.Outcome -eq 'no-verdict') -and ((@($dGlobDel.Lines) -join ' ') -match 'grocery/build-x\.ps1')), ('' + $dGlobDel.Code + ' ' + $dGlobDel.Outcome + ' ' + (@($dGlobDel.Lines) -join ' / '))
    }
    Write-RhFile $p 'ops\chain-manifest.json' ($man.Replace('"grocery/check-ad-cycles.ps1",', ''))
    [IO.File]::Delete((Join-Path $p 'grocery\check-ad-cycles.ps1'))
    $u2 = Save-RhCommit $p 'delete a files[] member and drop it from files[]'
    $dFilesDel = Get-RhPushDecision -Repo $p -RefLines @('refs/heads/main ' + $u2 + ' refs/heads/main ' + $u1) -VerdictDir $vdU -Today $today
    $u2Touched = @((Get-RhTrigger -Repo $p -Base $u1 -Tip $u2).Touched)
    Test-RhCase 'MUST FIRE  a push that deletes a files[] member and removes it from files[] needs a rehearsal, and the deleted member is among the touched' {
      (($dFilesDel.Code -eq 1) -and ($dFilesDel.Outcome -eq 'no-verdict') -and ($u2Touched -contains 'grocery/check-ad-cycles.ps1') -and ($u2Touched -contains 'ops/chain-manifest.json')), ('' + $dFilesDel.Code + ' ' + $dFilesDel.Outcome + ' touched=' + ($u2Touched -join ','))
    }
    Write-RhFile $p 'grocery\audit-thing.ps1' "'audit v2'`n"
    $u3 = Save-RhCommit $p 'edit a member that is one at both ends'
    $dEdit = Get-RhPushDecision -Repo $p -RefLines @('refs/heads/main ' + $u3 + ' refs/heads/main ' + $u2) -VerdictDir $vdU -Today $today
    Test-RhCase 'CLEAN TWIN  under the union a push that EDITS a member still needs a rehearsal, naming it' {
      (($dEdit.Code -eq 1) -and ($dEdit.Outcome -eq 'no-verdict') -and ((@($dEdit.Lines) -join ' ') -match 'grocery/audit-thing\.ps1')), ('' + $dEdit.Code + ' ' + $dEdit.Outcome)
    }
    Write-RhFile $p 'grocery\audit-other.ps1' "'still not named by guards'`n"
    [IO.File]::Delete((Join-Path $p 'grocery\test-thing.ps1'))
    $u4 = Save-RhCommit $p 'edit a non-member and delete an excluded test'
    $dNone = Get-RhPushDecision -Repo $p -RefLines @('refs/heads/main ' + $u4 + ' refs/heads/main ' + $u3) -VerdictDir $vdU -Today $today
    Test-RhCase 'MUST NOT FIRE  a push touching no member at EITHER end (a non-member edit, an excluded test deleted) needs no rehearsal' {
      (($dNone.Code -eq 0) -and ($dNone.Outcome -eq 'not-needed')), ('' + $dNone.Code + ' ' + $dNone.Outcome + ' ' + (@($dNone.Lines) -join ' / '))
    }

    # ---- 2c. THE DOT-SOURCE CLOSURE (W9.5): a member dot-sources lib/x.ps1 (through a parent of $PSScriptRoot), x
    # dot-sources lib/y.ps1, and y dot-sources x back (a cycle). lib/z.ps1 is named only in a COMMENTED dot-source and
    # is reached by nothing. Three spellings: Join-Path on (Split-Path -Parent $PSScriptRoot), Join-Path $PSScriptRoot,
    # and a double-quoted "$PSScriptRoot\...".
    $cr = New-RhFixtureRepo 'c'
    Write-RhFile $cr 'ops\chain-manifest.json' '{"schema":1,"max_data_age_days":2,"files":["grocery/check-ad-cycles.ps1","ops/chain-manifest.json"],"globs":[],"derive_from":[],"derive_dirs":["grocery/","lib/"]}'   # reach-fixture-ok: a fixture manifest in a throwaway repo; nothing opens the live module
    Write-RhFile $cr 'grocery\check-ad-cycles.ps1' ("'chain'`n. (Join-Path (Split-Path -Parent `$PSScriptRoot) 'lib\x.ps1')`n# . (Join-Path (Split-Path -Parent `$PSScriptRoot) 'lib\z.ps1')`n")
    Write-RhFile $cr 'lib\x.ps1' ("'x v1'`n. (Join-Path `$PSScriptRoot 'y.ps1')`n")
    Write-RhFile $cr 'lib\y.ps1' ("'y v1'`nif (`$false) { . `"`$PSScriptRoot\x.ps1`" }`n")
    Write-RhFile $cr 'lib\z.ps1' "'z, reached by nothing'`n"
    $cc0 = Save-RhCommit $cr 'closure base'
    Write-RhFile $cr 'lib\x.ps1' ("'x v2'`n. (Join-Path `$PSScriptRoot 'y.ps1')`n")
    $cc1 = Save-RhCommit $cr 'edit only the library a member dot-sources'
    Write-RhFile $cr 'lib\y.ps1' ("'y v2'`nif (`$false) { . `"`$PSScriptRoot\x.ps1`" }`n")
    $cc2 = Save-RhCommit $cr 'edit only the library reached through a second library'
    Write-RhFile $cr 'lib\z.ps1' "'z v2'`n"
    $cc3 = Save-RhCommit $cr 'edit only the unreached library'
    $vdC = Join-Path $st 'verdicts-closure'
    $csSet = Get-RhManifestSet $cr $cc0
    $dX = Get-RhPushDecision -Repo $cr -RefLines @('refs/heads/main ' + $cc1 + ' refs/heads/main ' + $cc0) -VerdictDir $vdC -Today $today
    Test-RhCase 'MUST FIRE  a library a member dot-sources (lib/x.ps1) is in the set, and a push changing only it needs a rehearsal, naming it' {
      ($csSet.Ok -and $csSet.Set.ContainsKey('lib/x.ps1') -and ($dX.Code -eq 1) -and ($dX.Outcome -eq 'no-verdict') -and ((@($dX.Lines) -join ' ') -match 'lib/x\.ps1')), ('ok=' + $csSet.Ok + ' ' + $csSet.Why + ' set=' + (@($csSet.Set.Keys) -join ',') + ' ' + $dX.Code + ' ' + $dX.Outcome)
    }
    $dY = Get-RhPushDecision -Repo $cr -RefLines @('refs/heads/main ' + $cc2 + ' refs/heads/main ' + $cc1) -VerdictDir $vdC -Today $today
    Test-RhCase 'MUST FIRE  the closure is TRANSITIVE: lib/y.ps1, reached only through lib/x.ps1, is in the set and a push changing only it needs a rehearsal' {
      ($csSet.Set.ContainsKey('lib/y.ps1') -and ($dY.Code -eq 1) -and ((@($dY.Lines) -join ' ') -match 'lib/y\.ps1')), ('set=' + (@($csSet.Set.Keys) -join ',') + ' ' + $dY.Code + ' ' + $dY.Outcome)
    }
    $dZ = Get-RhPushDecision -Repo $cr -RefLines @('refs/heads/main ' + $cc3 + ' refs/heads/main ' + $cc2) -VerdictDir $vdC -Today $today
    Test-RhCase 'MUST NOT FIRE  a file no member reaches (lib/z.ps1, named only in a COMMENTED dot-source) stays out, and a push changing only it needs none' {
      ((-not $csSet.Set.ContainsKey('lib/z.ps1')) -and ($dZ.Code -eq 0) -and ($dZ.Outcome -eq 'not-needed')), ('set=' + (@($csSet.Set.Keys) -join ',') + ' ' + $dZ.Code + ' ' + $dZ.Outcome)
    }
    $csCl = @(@($csSet.Closure.Keys) | Sort-Object | ForEach-Object { $_ + '<-' + $csSet.Closure[$_] }) -join ','
    Test-RhCase 'CLEAN TWIN  a dot-source cycle (x sources y, y sources x) terminates, and the closure is exactly x <- the member and y <- x' {
      ($csSet.Ok -and ($csCl -ceq 'lib/x.ps1<-grocery/check-ad-cycles.ps1,lib/y.ps1<-lib/x.ps1')), ('ok=' + $csSet.Ok + ' closure=' + $csCl)
    }
    $csLs = Get-RhListSet -Repo $cr -Commit $cc0
    $csClLines = @(@($csLs.Lines) | Where-Object { ([string]$_).StartsWith('CHAIN-REHEARSAL-CLOSURE ', [StringComparison]::Ordinal) })
    Test-RhCase 'MUST FIRE  -ListSet prints each closure member with the file that dot-sources it' {
      (($csLs.Code -eq 0) -and ((@($csClLines) -join '|') -ceq 'CHAIN-REHEARSAL-CLOSURE lib/x.ps1 <- grocery/check-ad-cycles.ps1|CHAIN-REHEARSAL-CLOSURE lib/y.ps1 <- lib/x.ps1')), ((@($csLs.Lines) -join ' / '))
    }
    $csBare = @(@($csLs.Lines) | Where-Object { -not ([string]$_).StartsWith('CHAIN-REHEARSAL-', [StringComparison]::Ordinal) -and -not ([string]$_).StartsWith('chain-rehearsal:', [StringComparison]::Ordinal) })
    Test-RhCase 'CLEAN TWIN  the fixture''s complete line reads files=4 members=2 closure=2, files= equals members= plus closure= and the number of bare path lines' {
      (($csBare.Count -eq 4) -and ([string]@($csLs.Lines)[-1] -cmatch '^CHAIN-REHEARSAL-LISTSET-COMPLETE files=4 members=2 closure=2 commit=')), ('bare=' + $csBare.Count + ' last=' + [string]@($csLs.Lines)[-1])
    }
    # Over THIS tree at HEAD: every set member printed once as a bare line, the counts adding up, and every closure line
    # naming a path and a sourcer that are both in the set.
    $rtLs = Get-RhListSet -Repo $script:RhRoot -Commit 'HEAD'
    $rtSet = Get-RhManifestSet $script:RhRoot 'HEAD'
    $rtBare = @(@($rtLs.Lines) | Where-Object { -not ([string]$_).StartsWith('CHAIN-REHEARSAL-', [StringComparison]::Ordinal) -and -not ([string]$_).StartsWith('chain-rehearsal:', [StringComparison]::Ordinal) })
    $rtCl = @(@($rtLs.Lines) | Where-Object { ([string]$_).StartsWith('CHAIN-REHEARSAL-CLOSURE ', [StringComparison]::Ordinal) })
    $rtM = [regex]::Match([string]@($rtLs.Lines)[-1], '^CHAIN-REHEARSAL-LISTSET-COMPLETE files=(\d+) members=(\d+) closure=(\d+) ')
    $rtWant = [string[]]@($rtSet.Set.Keys); [Array]::Sort($rtWant, [StringComparer]::Ordinal)
    $rtBad = @($rtCl | Where-Object { $f = ([string]$_).Split(' '); -not ($f.Count -eq 4 -and $f[2] -eq '<-' -and $rtSet.Set.ContainsKey($f[1]) -and $rtSet.Set.ContainsKey($f[3])) })
    Test-RhCase 'CLEAN TWIN  -ListSet over this tree prints every member plus the closure: the bare lines are exactly the set, files= equals their count and members= plus closure=, and each closure line names two set members' {
      (($rtLs.Code -eq 0) -and $rtM.Success -and ([string]::Equals(($rtBare -join "`n"), ($rtWant -join "`n"), [StringComparison]::Ordinal)) -and ([int]$rtM.Groups[1].Value -eq $rtBare.Count) -and ([int]$rtM.Groups[1].Value -eq ([int]$rtM.Groups[2].Value + [int]$rtM.Groups[3].Value)) -and ([int]$rtM.Groups[3].Value -eq $rtCl.Count) -and ($rtCl.Count -gt 0) -and ($rtBad.Count -eq 0)), ('rc=' + $rtLs.Code + ' last=' + [string]@($rtLs.Lines)[-1] + ' bare=' + $rtBare.Count + ' closureLines=' + $rtCl.Count + ' bad=' + ($rtBad -join ';'))
    }

    # ---- 3. A WHOLE REHEARSAL over a fixture source, through the seams (the seeder and the chain are the only fakes) ----
    $src = New-RhHookRepo 's' $false
    Write-RhFile $src 'ops\chain-manifest.json' '{"schema":1,"board_glob":"grocery/out/comparison-*.json","chain_verdict":"grocery/out/chain-verdict.json","files":["grocery/check-ad-cycles.ps1","ops/chain-manifest.json"],"globs":[],"derive_from":[],"derive_dirs":[]}'   # reach-fixture-ok: a fixture manifest in a throwaway repo; nothing opens the live module
    Write-RhFile $src 'grocery\check-ad-cycles.ps1' "'chain'`n"
    $null = Save-RhCommit $src 'manifest'
    Write-RhFile $src 'grocery\check-ad-cycles.ps1' "'chain v2'`n"
    $srcHead = Save-RhCommit $src 'chain change'
    $null = Invoke-RhGit $src @('update-ref', 'refs/remotes/origin/main', ($srcHead + '~1'))
    $seedDir = Join-Path $st 'seed'
    Write-RhFile $seedDir 'grocery\out\comparison-2026-09-21.json' '{}'   # reach-fixture-ok: builds a throwaway fixture repo under %TEMP%; nothing opens the live module
    $fakeSeeder = { param($Tree, $SourceRoot) Copy-Item -Recurse -Force (Join-Path $SourceRoot 'grocery') $Tree; [pscustomobject]@{ Rc = 0; Tail = @() } }
    $mkRunner = { param([bool]$EmptyFlags)
      return { param($Tree, $TimeoutMin, $ChildEnv)
        # the chain's own outputs: a guard verdict, a bot-owned file, and an attempted push that must fail
        [IO.File]::WriteAllText((Join-Path $Tree 'grocery\out\chain-verdict.json'), '{"guards_blocked":false,"verdict":"clean"}')   # reach-fixture-ok: builds a throwaway fixture repo under %TEMP%; nothing opens the live module
        $cf = Join-Path $Tree 'meal-prep\db\cost-flags.txt'   # reach-fixture-ok: builds a throwaway fixture repo under %TEMP%; nothing opens the live module
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
      (($fullRun.result -eq 'pass') -and ($null -ne $v) -and ($v.result -eq 'pass') -and ($v.data_date -eq '2026-09-21') -and ($leak.rc -ne 0)), ($fullRun.result + ' ' + $fullRun.blind + ' ' + $fullRun.cause + ' leak.rc=' + $leak.rc)
    }
    Test-RhCase 'MUST NOT FIRE  it leaves nothing behind: no scratch clone of this commit under %TEMP%, and the launching checkout''s git status is unchanged' {
      (($fullRun.scratch -like '*tc-rh-*') -and ($scratchLeft.Count -eq 0) -and [string]::Equals($statusBefore, $statusAfter, [StringComparison]::Ordinal)), ('left=' + $scratchLeft.Count)
    }
    $bad = Invoke-RhRehearsal -Repo $src -Commit 'HEAD' -SourceRoot (Join-Path $st 'no-such-source') -VerdictDir $vd -Today $today -Seeder $fakeSeeder -ChainRunner (& $mkRunner $false) -NoPair
    Test-RhCase 'MUST NOT FIRE  a rehearsal with no board to seed from reports blind=no-seed-board (exit 3), records it, and is never a pass' {
      (($bad.result -eq 'blind') -and ($bad.blind -in @('no-source', 'no-seed-board')) -and ((Get-RhExitCode $bad.result) -eq 3) -and ((Format-RhComplete $bad) -match '^CHAIN-REHEARSAL-COMPLETE verdict=blind blind=')), ($bad.result + ' ' + $bad.blind)
    }
    $credSeeder = { param($Tree, $SourceRoot) Copy-Item -Recurse -Force (Join-Path $SourceRoot 'grocery') $Tree; $null = [IO.Directory]::CreateDirectory((Join-Path $Tree 'meal-prep')); [IO.File]::WriteAllText((Join-Path $Tree 'meal-prep\.ghostkey'), 'x'); [pscustomobject]@{ Rc = 0; Tail = @() } }
    $cred = Invoke-RhRehearsal -Repo $src -Commit 'HEAD' -SourceRoot $seedDir -VerdictDir $vd -Today $today -Seeder $credSeeder -ChainRunner (& $mkRunner $false) -NoPair
    Test-RhCase 'MUST FIRE  a seed that carries a live credential is never started: blind=credential-present' { (($cred.result -eq 'blind') -and ($cred.blind -eq 'credential-present')), ($cred.result + ' ' + $cred.blind) }
    $stale = Invoke-RhRehearsal -Repo $src -Commit 'HEAD' -SourceRoot $seedDir -VerdictDir $vd -Today ([datetime]'2026-09-24') -Seeder $fakeSeeder -ChainRunner (& $mkRunner $false) -NoPair
    Test-RhCase 'MUST FIRE  data older than the bar is not rehearsed over: blind=stale-data (09-21 board on 09-24)' { (($stale.result -eq 'blind') -and ($stale.blind -eq 'stale-data')), ($stale.result + ' ' + $stale.blind) }

    # ---- 4. BRAD'S CAP: at most 6 at once, through gate-slots with a private prefix and queue. Slots are held from
    # OTHER processes (lib\mutex-hold.ps1), because a Windows mutex is reentrant on its owning thread.
    $capPrefix = 'Global\tc-rhst-' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '-'
    $capQueue = Join-Path $st 'q'
    $holds = New-Object Collections.ArrayList
    try {
      for ($i = 0; $i -lt 5; $i++) { [void]$holds.Add((Start-TcMutexHold -Name ($capPrefix + $i))) }
      $sixth = Enter-TcGateSlots -Want 1 -Total $script:RhMaxConcurrent -Prefix $capPrefix -QueueRoot $capQueue -WaitSec 5 -PollMs 100 -OnWait { param($a) $script:rhSixthWaited = $true }
      $script:rhSixthWaited = [bool]$script:rhSixthWaited
      $sixthGot = $sixth.Count
      Exit-TcGateSlots $sixth
      Test-RhCase ('MUST NOT FIRE  with 5 of the ' + $script:RhMaxConcurrent + ' rehearsal slots held elsewhere, a 6th starts at once without waiting') {
        ((@($holds | Where-Object { $_.Held }).Count -eq 5) -and ($sixthGot -eq 1) -and (-not $script:rhSixthWaited)), ('held=' + @($holds | Where-Object { $_.Held }).Count + ' got=' + $sixthGot + ' waited=' + $script:rhSixthWaited)
      }
      [void]$holds.Add((Start-TcMutexHold -Name ($capPrefix + 5)))
      $vd2 = Join-Path $st 'verdicts-cap'
      $capArgs = @{ Repo = $src; Commit = 'HEAD'; SourceRoot = $seedDir; VerdictDir = $vd2; Today = $today; Seeder = $fakeSeeder; ChainRunner = (& $mkRunner $false); NoPair = $true;
        SlotTotal = $script:RhMaxConcurrent; SlotPrefix = $capPrefix; SlotQueueRoot = $capQueue }
      $seventhOut = @(& { Invoke-RhRehearsal @capArgs -SlotStallSec 3 } 6>&1)
      $seventh = @($seventhOut | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['result'] })[0]
      $waitLines = @($seventhOut | Where-Object { ([string]$_) -match 'WAITING for a rehearsal slot - all 6 are in use' })
      Test-RhCase 'MUST FIRE  with all 6 slots held, a 7th rehearsal WAITS and says so, and runs no clone while it waits' {
        (($waitLines.Count -ge 1) -and ($seventh.blind -eq 'no-rehearsal-slot') -and (-not $seventh.scratch)), ('wait lines=' + $waitLines.Count + ' blind=' + $seventh.blind + ' scratch=' + $seventh.scratch)
      }
      $dWait = Get-RhPushDecision -Repo $src -RefLines @('refs/heads/main ' + $srcHead + ' refs/heads/main ' + (([string](Invoke-RhGit $src @('rev-parse', 'HEAD~1')).stdout).Trim())) -VerdictDir $vd2 -Today $today
      Test-RhCase 'MUST NOT FIRE  the waiting 7th is never recorded as blind or failed: no verdict exists for its content, so the push reads no-verdict' {
        (($null -eq (Read-RhVerdict $vd2 $seventh.key)) -and ($dWait.Outcome -eq 'no-verdict')), ('verdict=' + [bool](Read-RhVerdict $vd2 $seventh.key) + ' outcome=' + $dWait.Outcome)
      }
      Stop-TcMutexHold $holds[0]; $holds.RemoveAt(0)
      $afterFree = Invoke-RhRehearsal @capArgs -SlotStallSec 30
      Test-RhCase 'CLEAN TWIN  once one of the 6 slots frees, the same rehearsal runs and passes' { ($afterFree.result -eq 'pass'), ($afterFree.result + ' ' + $afterFree.blind + ' ' + $afterFree.cause) }
    } finally {
      foreach ($h in @($holds.ToArray())) { Stop-TcMutexHold $h }
    }

    # ---- 5. -LISTSET (W0.5, design\PLAN-push-derived-conflicts-2026-09-23.md): the set and the trigger, printed without
    # a rehearsal. -ListSet reads the repo its own copy sits in, so the script runs as a CHILD from a sandbox inside a
    # fixture repo's working tree (untracked, so no commit and no diff sees it). Three sandboxes, each with the whole lib\:
    #   ln  an exact copy of this file, for the -ForPush twin;
    #   lo  this file as it stood BEFORE -ListSet existed, read from its blob, so "-ForPush decides exactly as before" is a
    #       paired run of both scripts over one fixture rather than a claim;
    #   lp  a copy whose rehearsal-slot prefix and slot stall, and whose lib\gate-slots.ps1 queue root, are PRIVATE, each
    #       rewrite asserted to land exactly once. Every -ListSet run goes through lp, so no case here can open the
    #       production slot names even if a regression made -ListSet reach for a slot.
    $lsBlobBefore = '5126d59abccb3478072383c40e09c7cf2c423e26'   # ops/rehearse-chain.ps1 at f33d11829, the last blob before -ListSet
    $lf = New-RhFixtureRepo 'l'
    Write-RhFile $lf 'README.md' "doc v0`n"
    $lPre = Save-RhCommit $lf 'no manifest yet'
    # Zeta sorts FIRST by Ordinal (Z is 0x5A, a is 0x61) and after audit-thing by a culture sort, so the exact-order
    # assertion tells an Ordinal sort from Sort-Object. absent-listed is in files[] and not in the tree, so it is no member.
    Write-RhFile $lf 'ops\chain-manifest.json' '{"schema":1,"max_data_age_days":2,"board_glob":"grocery/out/comparison-*.json","chain_verdict":"grocery/out/chain-verdict.json","files":["grocery/check-ad-cycles.ps1","ops/chain-manifest.json","grocery/Zeta.ps1","grocery/absent-listed.ps1"],"globs":["grocery/build-*.ps1"],"derive_from":["grocery/guards.ps1"],"derive_dirs":["grocery/"],"exclude_globs":["grocery/test-*.ps1"]}'   # reach-fixture-ok: a fixture manifest in a throwaway repo; nothing opens the live module
    Write-RhFile $lf 'grocery\check-ad-cycles.ps1' "'chain'`n"
    Write-RhFile $lf 'grocery\guards.ps1' ". (Join-Path `$root 'audit-thing.ps1')`n& (Join-Path `$root 'test-thing.ps1')`n"
    Write-RhFile $lf 'grocery\audit-thing.ps1' "'audit v1'`n"
    Write-RhFile $lf 'grocery\audit-other.ps1' "'not named by guards'`n"
    Write-RhFile $lf 'grocery\test-thing.ps1' "'a test'`n"
    Write-RhFile $lf 'grocery\build-x.ps1' "'builder'`n"
    Write-RhFile $lf 'grocery\Zeta.ps1' "'listed by name'`n"
    $l0 = Save-RhCommit $lf 'manifest and chain'
    Write-RhFile $lf 'grocery\check-ad-cycles.ps1' "'chain v2'`n"
    Write-RhFile $lf 'grocery\audit-thing.ps1' "'audit v2'`n"
    $l1 = Save-RhCommit $lf 'two chain members change, one of them through derive_from'
    Write-RhFile $lf 'README.md' "doc v1`n"
    $l2 = Save-RhCommit $lf 'doc only'
    $lsWant = @('grocery/Zeta.ps1', 'grocery/audit-thing.ps1', 'grocery/build-x.ps1', 'grocery/check-ad-cycles.ps1', 'ops/chain-manifest.json')
    $lsKey = (Get-RhManifestSet $lf $l1).Key
    function New-RhSandbox([string]$Name, [byte[]]$Script) {
      $box = Join-Path $lf $Name
      $null = [IO.Directory]::CreateDirectory((Join-Path $box 'ops'))
      $null = [IO.Directory]::CreateDirectory((Join-Path $box 'lib'))
      foreach ($f in [IO.Directory]::GetFiles((Join-Path $script:RhRoot 'lib'), '*.ps1')) { [IO.File]::Copy($f, (Join-Path (Join-Path $box 'lib') ([IO.Path]::GetFileName($f)))) }
      [IO.File]::WriteAllBytes((Join-Path $box 'ops\rehearse-chain.ps1'), $Script)
      return $box
    }
    function Get-RhOrdinalCount([string]$Text, [string]$Needle) {
      $n = 0; $i = $Text.IndexOf($Needle, [StringComparison]::Ordinal)
      while ($i -ge 0) { $n++; $i = $Text.IndexOf($Needle, $i + $Needle.Length, [StringComparison]::Ordinal) }
      return $n
    }
    $lsSelf = Join-Path $script:RhRoot 'ops\rehearse-chain.ps1'
    $ln = New-RhSandbox 'ln' ([IO.File]::ReadAllBytes($lsSelf))
    $lo = New-RhSandbox 'lo' ([byte[]](Get-CommittedBlobBytes -Repo $script:RhRoot -Spec $lsBlobBefore))
    # NEEDLES BY CONCATENATION: this file is the text being rewritten, so a needle spelled whole here would count twice.
    $lsPrefix = 'Global\tc-rhls-' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '-'
    $lsQueue = Join-Path $st 'lq'
    $nPrefix = '$script:RhSlot' + 'Prefix = ''Global\tc-rehearsal' + '-slot-'''
    $nStall = '$script:RhSlot' + 'StallSec = ' + '3600'
    $nQueue = '$script:TcGateQueue' + 'Root = Join-Path ([Environment]::GetFolderPath(''LocalApplicationData'')) ''ThriftyCrew\gate-slot-queue'''
    $lsSrcText = [IO.File]::ReadAllText($lsSelf)
    $lsGsText = [IO.File]::ReadAllText((Join-Path $script:RhRoot 'lib\gate-slots.ps1'))
    $lpRewrites = '' + (Get-RhOrdinalCount $lsSrcText $nPrefix) + ',' + (Get-RhOrdinalCount $lsSrcText $nStall) + ',' + (Get-RhOrdinalCount $lsGsText $nQueue)
    $lpOk = ($lpRewrites -eq '1,1,1')
    $lp = ''
    if ($lpOk) {
      $lpText = $lsSrcText.Replace($nPrefix, ('$script:RhSlotPrefix = ''' + $lsPrefix + '''')).Replace($nStall, '$script:RhSlotStallSec = 2')
      $lp = New-RhSandbox 'lp' ((New-Object Text.UTF8Encoding($false)).GetBytes($lpText))
      [IO.File]::WriteAllText((Join-Path $lp 'lib\gate-slots.ps1'), $lsGsText.Replace($nQueue, ('$script:TcGateQueueRoot = ''' + $lsQueue + '''')), (New-Object Text.UTF8Encoding($false)))
    }
    $lsPsExe = (Get-Command powershell).Source
    $lsVd = Join-Path $st 'lvd'
    $null = [IO.Directory]::CreateDirectory($lsVd)
    function Invoke-RhSandbox([string]$Box, [string]$ArgLine, [hashtable]$Extra = @{}) {
      # Every child sees a PRIVATE verdict directory and no bypass, whatever this shell carries.
      if (-not $Box) { return [pscustomobject]@{ Rc = -9; Lines = @(); Err = ('the sandbox was not built: slot rewrites landed ' + $lpRewrites + ', not 1,1,1') } }
      $e = @{ TC_REHEARSAL_VERDICT_DIR = $lsVd; TC_NO_REHEARSAL = '' }
      foreach ($k in @($Extra.Keys)) { $e[$k] = $Extra[$k] }
      $r = Invoke-RhProcess -File $lsPsExe -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $Box 'ops\rehearse-chain.ps1') + '" ' + $ArgLine) -WorkDir $Box -Env $e -TimeoutSec 300
      return [pscustomobject]@{ Rc = $r.Rc; Lines = @(([string]$r.Out) -split "`r?`n" | Where-Object { $_ -ne '' }); Err = [string]$r.Err }
    }
    function Get-RhTreeListing([string]$Dir) {
      # Every entry below $Dir with its size and write time, sorted Ordinal: two equal listings mean nothing was added,
      # removed, resized or rewritten there.
      if (-not [IO.Directory]::Exists($Dir)) { return '<absent>' }
      $items = Get-ChildItem -LiteralPath $Dir -Recurse -Force
      $rows = New-Object Collections.ArrayList
      foreach ($i in @($items)) { [void]$rows.Add($i.FullName.Substring($Dir.Length) + '|' + $(if ($i.PSIsContainer) { 'dir' } else { [string]$i.Length }) + '|' + $i.LastWriteTimeUtc.Ticks) }
      $a = [string[]]$rows.ToArray(); [Array]::Sort($a, [StringComparer]::Ordinal)
      return ($a -join "`n")
    }
    function Get-RhSetLines($Lines) {
      return @(@($Lines) | Where-Object { -not ([string]$_).StartsWith('CHAIN-REHEARSAL-', [StringComparison]::Ordinal) -and -not ([string]$_).StartsWith('chain-rehearsal:', [StringComparison]::Ordinal) })
    }

    $lsRun = Invoke-RhSandbox $lp ('-ListSet -Range ' + $l0 + '..' + $l1)
    $lsSet = Get-RhSetLines $lsRun.Lines
    $lsLast = [string]@($lsRun.Lines)[-1]
    $lsWantLast = 'CHAIN-REHEARSAL-LISTSET-COMPLETE files=' + $lsWant.Count + ' members=' + $lsWant.Count + ' closure=0 commit=' + $l1 + ' key=' + $lsKey + ' decision=needed'
    Test-RhCase 'MUST FIRE  -ListSet over a fixture manifest prints its set EXACTLY and in Ordinal order (Zeta first): files[], a glob, a derive_from member and the manifest, and no absent entry, excluded test or unnamed audit; files= is its count and key= is the verdict key' {
      ($lpOk -and ($lsRun.Rc -eq 0) -and [string]::Equals((@($lsSet) -join "`n"), ($lsWant -join "`n"), [StringComparison]::Ordinal) -and [string]::Equals($lsLast, $lsWantLast, [StringComparison]::Ordinal)), ('rewrites=' + $lpRewrites + ' rc=' + $lsRun.Rc + ' set=' + (@($lsSet) -join ',') + ' last=' + $lsLast + ' err=' + $lsRun.Err)
    }
    $lsTrig = @(@($lsRun.Lines) | Where-Object { ([string]$_).StartsWith('CHAIN-REHEARSAL-TRIGGER ', [StringComparison]::Ordinal) -or ([string]$_).StartsWith('CHAIN-REHEARSAL-TOUCHED ', [StringComparison]::Ordinal) })
    $lsT0 = 'CHAIN-REHEARSAL-TRIGGER range=' + $l0 + '..' + $l1 + ' decision=needed touched=2'
    $lsTrigWant = @($lsT0, 'CHAIN-REHEARSAL-TOUCHED grocery/audit-thing.ps1', 'CHAIN-REHEARSAL-TOUCHED grocery/check-ad-cycles.ps1')
    Test-RhCase 'MUST FIRE  with -Range it prints the trigger -ForPush would decide: needed, naming exactly the two members the range changed, one of them reached only through derive_from' {
      [string]::Equals(($lsTrig -join "`n"), ($lsTrigWant -join "`n"), [StringComparison]::Ordinal), ($lsTrig -join ' / ')
    }
    $lsDoc = Get-RhListSet -Repo $lf -Range ($l1 + '..' + $l2)
    $lsDocTrig = 'CHAIN-REHEARSAL-TRIGGER range=' + $l1 + '..' + $l2 + ' decision=not-needed touched=0'
    Test-RhCase 'MUST NOT FIRE  a doc-only range asks for no rehearsal: decision=not-needed touched=0 with no touched line, and the set is still listed' {
      (($lsDoc.Code -eq 0) -and (@(@($lsDoc.Lines) | Where-Object { ([string]$_).StartsWith('CHAIN-REHEARSAL-TOUCHED', [StringComparison]::Ordinal) }).Count -eq 0) -and (@(@($lsDoc.Lines) | Where-Object { $_ -ceq $lsDocTrig }).Count -eq 1) -and ((Get-RhSetLines $lsDoc.Lines).Count -eq $lsWant.Count) -and ([string]@($lsDoc.Lines)[-1] -cmatch ' decision=not-needed$')), (@($lsDoc.Lines) -join ' / ')
    }
    $lsBad = Get-RhListSet -Repo $lf -Commit ('f' * 40)
    Test-RhCase 'MUST NOT FIRE  a commit -ListSet cannot name is never read as an empty set: exit 3, blind=cannot-read-commit on the marker, no files= token and no path line' {
      (($lsBad.Code -eq 3) -and (@($lsBad.Lines).Count -eq 2) -and ([string]@($lsBad.Lines)[-1] -ceq 'CHAIN-REHEARSAL-LISTSET-COMPLETE blind=cannot-read-commit') -and (@(@($lsBad.Lines) | Where-Object { $_ -match 'files=' }).Count -eq 0) -and ((Get-RhSetLines $lsBad.Lines).Count -eq 0)), (@($lsBad.Lines) -join ' / ')
    }
    $lsAbs = Get-RhListSet -Repo $lf -Commit $lPre
    Test-RhCase 'MUST NOT FIRE  a commit with no manifest lists no set, and that is a real answer, not a blind: exit 0, files=0 manifest=absent' {
      (($lsAbs.Code -eq 0) -and (@($lsAbs.Lines).Count -eq 1) -and ([string]@($lsAbs.Lines)[-1] -ceq ('CHAIN-REHEARSAL-LISTSET-COMPLETE files=0 members=0 closure=0 commit=' + $lPre + ' key=- manifest=absent'))), (@($lsAbs.Lines) -join ' / ')
    }
    $lsDots = Get-RhListSet -Repo $lf -Range ($l0 + '...' + $l1)
    $lsMis = Get-RhListSet -Repo $lf -Range ($l0 + '..' + $l1) -Commit $l0 -CommitGiven
    Test-RhCase 'MUST NOT FIRE  a three-dot range (a merge-base diff, which -ForPush never makes) and a -Commit that is not the range''s tip are refused as bad-range, never listed' {
      (($lsDots.Code -eq 3) -and ([string]@($lsDots.Lines)[-1] -ceq 'CHAIN-REHEARSAL-LISTSET-COMPLETE blind=bad-range') -and ($lsMis.Code -eq 3) -and ([string]@($lsMis.Lines)[-1] -ceq 'CHAIN-REHEARSAL-LISTSET-COMPLETE blind=bad-range')), ((@($lsDots.Lines) -join ' / ') + ' || ' + (@($lsMis.Lines) -join ' / '))
    }
    $lsVd8 = Join-Path $st 'lvd8'
    $null = [IO.Directory]::CreateDirectory($lsVd8)
    $lsNoLs = Invoke-RhSandbox $lp ('-Range ' + $l0 + '..' + $l1) @{ TC_REHEARSAL_VERDICT_DIR = $lsVd8 }
    $lsBoth = Invoke-RhSandbox $lp '-ListSet -ForPush' @{ TC_REHEARSAL_VERDICT_DIR = $lsVd8 }
    $lsUsageLines = @(@($lsNoLs.Lines) + @($lsBoth.Lines))
    $lsRan = @($lsUsageLines | Where-Object { $_ -match '^CHAIN-REHEARSAL-(CHECK-)?COMPLETE ' })
    Test-RhCase 'MUST FIRE  -Range without -ListSet (which would otherwise REHEARSE) and -ListSet beside -ForPush are refused with blind=bad-usage, exit 3, before anything runs: no rehearsal or push decision printed and no verdict written' {
      ($lpOk -and ($lsNoLs.Rc -eq 3) -and ([string]@($lsNoLs.Lines)[-1] -ceq 'CHAIN-REHEARSAL-LISTSET-COMPLETE blind=bad-usage') -and ($lsBoth.Rc -eq 3) -and ([string]@($lsBoth.Lines)[-1] -ceq 'CHAIN-REHEARSAL-LISTSET-COMPLETE blind=bad-usage') -and ($lsRan.Count -eq 0) -and ((Get-RhTreeListing $lsVd8) -eq '')), ('rc=' + $lsNoLs.Rc + '/' + $lsBoth.Rc + ' ' + ($lsUsageLines -join ' / ') + ' verdicts=' + (Get-RhTreeListing $lsVd8))
    }

    # NOTHING WRITTEN, NO SLOT TAKEN. Every one of the 6 slots of lp's private prefix is held by ANOTHER process
    # (lib\mutex-hold.ps1) for the whole run, so a -ListSet that asked for a slot would have to queue: its ticket would
    # create lp's private queue root and, through Invoke-RhRehearsal, print WAITING. The verdict directory and the child's
    # own TEMP are compared by listing AND watched, because a rehearsal removes its scratch clone in a finally and only a
    # watcher sees a clone that came and went.
    function Invoke-RhListSetProbe {
      $root = Join-Path $st 'lw'; $t = Join-Path $root 't'; $v = Join-Path $root 'v'
      $null = [IO.Directory]::CreateDirectory($t); $null = [IO.Directory]::CreateDirectory($v)
      [IO.File]::WriteAllText((Join-Path $t 'keep.txt'), 'present before the run')
      Save-RhVerdict $v ([pscustomobject]@{ result = 'pass'; blind = ''; key = ('0' * 64); stage = ''; cause = 'fixture'; words = @(); data_date = '2026-09-22'; preexisting = @() })
      $res = [ordered]@{ Error = ''; Rc = $null; Lines = @(); TBefore = ''; TAfter = ''; VBefore = ''; VAfter = ''; Held = 0; Alive = 0; Events = @(); Flushed = $false; QueueMade = $false }
      $hl = New-Object Collections.ArrayList
      $fsw = $null; $sid = 'rhls-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
      $kinds = @('Created', 'Changed', 'Deleted', 'Renamed')
      try {
        if (-not $lpOk) { throw ('the sandbox was not built: slot rewrites landed ' + $lpRewrites + ', not 1,1,1') }
        for ($i = 0; $i -lt $script:RhMaxConcurrent; $i++) { [void]$hl.Add((Start-TcMutexHold -Name ($lsPrefix + $i))) }
        $res.Held = @($hl | Where-Object { $_.Held }).Count
        $res.TBefore = Get-RhTreeListing $t; $res.VBefore = Get-RhTreeListing $v
        $fsw = New-Object IO.FileSystemWatcher $root
        $fsw.IncludeSubdirectories = $true
        $fsw.NotifyFilter = [IO.NotifyFilters]'FileName, DirectoryName, LastWrite, Size'
        foreach ($ev in $kinds) { $null = Register-ObjectEvent -InputObject $fsw -EventName $ev -SourceIdentifier ($sid + '-' + $ev) }
        $fsw.EnableRaisingEvents = $true
        $run = Invoke-RhSandbox $lp ('-ListSet -Commit ' + $l1) @{ TEMP = $t; TMP = $t; TC_REHEARSAL_VERDICT_DIR = $v }
        $res.Rc = $run.Rc; $res.Lines = @($run.Lines)
        $res.Alive = @($hl | Where-Object { $_.Held -and -not $_.Process.HasExited }).Count
        # FLUSH: the watcher reports in order, so once it has reported this file it has reported everything before it.
        $flush = Join-Path $root ('flush-' + [guid]::NewGuid().ToString('N') + '.txt')
        [IO.File]::WriteAllText($flush, 'x')
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (-not $res.Flushed -and $sw.Elapsed.TotalSeconds -lt 30) {   # a hang guard, never a bar: the event takes milliseconds
          foreach ($e in @(Get-Event -SourceIdentifier ($sid + '-Created') -ErrorAction SilentlyContinue)) { if ([string]::Equals([string]$e.SourceEventArgs.FullPath, $flush, [StringComparison]::OrdinalIgnoreCase)) { $res.Flushed = $true } }
          if (-not $res.Flushed) { Start-Sleep -Milliseconds 50 }
        }
        $evs = New-Object Collections.ArrayList
        foreach ($ev in $kinds) {
          foreach ($e in @(Get-Event -SourceIdentifier ($sid + '-' + $ev) -ErrorAction SilentlyContinue)) {
            $fp = [string]$e.SourceEventArgs.FullPath
            if ([string]::Equals($fp, $flush, [StringComparison]::OrdinalIgnoreCase)) { continue }
            # PowerShell 5.1's own start-up writes and deletes __PSScriptPolicyTest_* in TEMP (measured 2026-09-23 on a bare
            # child): the host's write, not the script's. A directory's Changed only echoes a create or delete inside it,
            # and those are judged themselves.
            if ([IO.Path]::GetFileName($fp).StartsWith('__PSScriptPolicyTest_', [StringComparison]::Ordinal) -and [string]::Equals([IO.Path]::GetDirectoryName($fp), $t, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($ev -eq 'Changed' -and [IO.Directory]::Exists($fp)) { continue }
            [void]$evs.Add($ev + ' ' + $fp.Substring($root.Length))
          }
        }
        $res.Events = @($evs)
        $res.TAfter = Get-RhTreeListing $t; $res.VAfter = Get-RhTreeListing $v
        $res.QueueMade = [IO.Directory]::Exists($lsQueue)
      } catch { $res.Error = $_.Exception.Message }
      finally {
        if ($fsw) { $fsw.EnableRaisingEvents = $false }
        foreach ($ev in $kinds) { Unregister-Event -SourceIdentifier ($sid + '-' + $ev) -ErrorAction SilentlyContinue; Remove-Event -SourceIdentifier ($sid + '-' + $ev) -ErrorAction SilentlyContinue }
        if ($fsw) { $fsw.Dispose() }
        foreach ($h in @($hl.ToArray())) { Stop-TcMutexHold $h }
      }
      return [pscustomobject]$res
    }
    $lsProbe = Invoke-RhListSetProbe
    $lsWaited = @(@($lsProbe.Lines) | Where-Object { $_ -match 'WAITING' })
    Test-RhCase ('MUST NOT FIRE  -ListSet writes nothing and takes no slot: with all ' + $script:RhMaxConcurrent + ' rehearsal slots held by other processes it lists at once (no WAITING, no queue ticket), and its verdict directory and TEMP are unchanged by listing and by a watcher') {
      ((-not $lsProbe.Error) -and ($lsProbe.Held -eq $script:RhMaxConcurrent) -and ($lsProbe.Alive -eq $script:RhMaxConcurrent) -and ($lsProbe.Rc -eq 0) -and ([string]@($lsProbe.Lines)[-1] -cmatch ('^CHAIN-REHEARSAL-LISTSET-COMPLETE files=' + $lsWant.Count + ' ')) -and ($lsWaited.Count -eq 0) -and (-not $lsProbe.QueueMade) -and $lsProbe.Flushed -and (@($lsProbe.Events).Count -eq 0) -and [string]::Equals($lsProbe.TBefore, $lsProbe.TAfter, [StringComparison]::Ordinal) -and [string]::Equals($lsProbe.VBefore, $lsProbe.VAfter, [StringComparison]::Ordinal)),
        ('error=' + $lsProbe.Error + ' held=' + $lsProbe.Held + ' alive=' + $lsProbe.Alive + ' rc=' + $lsProbe.Rc + ' last=' + [string]@($lsProbe.Lines)[-1] + ' waited=' + $lsWaited.Count + ' queue=' + $lsProbe.QueueMade + ' flushed=' + $lsProbe.Flushed + ' events=' + (@($lsProbe.Events) -join ';') + ' tSame=' + ($lsProbe.TBefore -eq $lsProbe.TAfter) + ' vSame=' + ($lsProbe.VBefore -eq $lsProbe.VAfter))
    }

    # THE -FORPUSH TWIN. The child reads the real clock, so the fixture verdict is dated today. Each state moves the
    # fixture's HEAD and origin/main, then runs the script from before -ListSet (lo) and this one (ln) back to back.
    $lsToday = (Get-Date).ToString('yyyy-MM-dd')
    # EARLY TOKEN (W9.1 step 7): the marker now ends with early=yes|no when a recorded verdict decided the push, taken
    # from that verdict's own record, and says nothing when none did. The twin strips that one trailing token before it
    # compares with the older script, and asserts the token itself through each state's Tok.
    $lsStates = @(
      [pscustomobject]@{ Name = 'allow';       Tip = $l1; Base = $l0; Verdict = 'pass'; Early = $false; Code = 0; Outcome = 'rehearsed-pass'; Tok = ' early=no' },
      [pscustomobject]@{ Name = 'allow-early'; Tip = $l1; Base = $l0; Verdict = 'pass'; Early = $true;  Code = 0; Outcome = 'rehearsed-pass'; Tok = ' early=yes' },
      [pscustomobject]@{ Name = 'not-needed';  Tip = $l2; Base = $l1; Verdict = 'pass'; Early = $true;  Code = 0; Outcome = 'not-needed';     Tok = '' },
      [pscustomobject]@{ Name = 'refuse';      Tip = $l1; Base = $l0; Verdict = 'fail'; Early = $false; Code = 1; Outcome = 'rehearsed-fail'; Tok = ' early=no' })
    $lsTwin = New-Object Collections.ArrayList
    $lsStrip = { param($ls) @(@($ls) | ForEach-Object { [regex]::Replace([string]$_, '^(CHAIN-REHEARSAL-CHECK-COMPLETE .*) early=(yes|no)$', '$1') }) }
    foreach ($lsS in $lsStates) {
      Save-RhVerdict $lsVd ([pscustomobject]@{ result = $lsS.Verdict; blind = ''; key = $lsKey; stage = 'commit'; cause = ('fixture ' + $lsS.Verdict); words = @('fixture words'); data_date = $lsToday; preexisting = @(); early = $lsS.Early })
      $null = Invoke-RhGit $lf @('checkout', '-q', '--detach', $lsS.Tip)
      $null = Invoke-RhGit $lf @('update-ref', 'refs/remotes/origin/main', $lsS.Base)
      $lsO = Invoke-RhSandbox $lo '-ForPush'
      $lsN = Invoke-RhSandbox $ln '-ForPush'
      $lsWantMark = 'CHAIN-REHEARSAL-CHECK-COMPLETE code=' + $lsS.Code + ' outcome=' + $lsS.Outcome + $lsS.Tok
      $lsSame = ($lsO.Rc -eq $lsN.Rc) -and [string]::Equals(((& $lsStrip $lsO.Lines) -join "`n"), ((& $lsStrip $lsN.Lines) -join "`n"), [StringComparison]::Ordinal)
      $lsOk = $lsSame -and ($lsN.Rc -eq $lsS.Code) -and (@($lsN.Lines).Count -ge 2) -and [string]::Equals([string]@($lsN.Lines)[-1], $lsWantMark, [StringComparison]::Ordinal)
      [void]$lsTwin.Add([pscustomobject]@{ Name = $lsS.Name; Ok = $lsOk; Got = ($lsS.Name + ': before rc=' + $lsO.Rc + ' [' + (@($lsO.Lines) -join ' / ') + '] now rc=' + $lsN.Rc + ' [' + (@($lsN.Lines) -join ' / ') + '] ' + $lsN.Err) })
    }
    Test-RhCase 'CLEAN TWIN  -ForPush over the same fixture decides exactly as before -ListSet existed: allow, allow over an early verdict, not-needed and refuse print the same lines and exit codes as that script, run from its blob beside this one, once the marker''s trailing early token is set aside; and that token reads early=no, early=yes, absent (no verdict decided it) and early=no' {
      (@($lsTwin | Where-Object { $_.Ok }).Count -eq $lsStates.Count), ((@($lsTwin | Where-Object { -not $_.Ok } | ForEach-Object { $_.Got })) -join ' || ')
    }

    # ---- 6. REHEARSE AT COMMIT (W9.1): -Onto, -StackFile, -Early, the in-flight record, supersede and the stop.
    # Fixture timeline: e0 is the commit's base; origin moved to eO, which changes a MEMBER (grocery/member-b.ps1); HEAD
    # eH changes another member on e0. So HEAD as committed and HEAD rebased onto eO have DIFFERENT keys, which is what
    # lets the measured condition tell a rebased early rehearsal from an unrebased one (mutant M19).
    $er = New-RhHookRepo 'e' $false
    Write-RhFile $er 'ops\chain-manifest.json' '{"schema":1,"max_data_age_days":2,"board_glob":"grocery/out/comparison-*.json","chain_verdict":"grocery/out/chain-verdict.json","files":["grocery/check-ad-cycles.ps1","grocery/member-b.ps1","grocery/ahead.ps1","ops/chain-manifest.json"],"globs":[],"derive_from":[],"derive_dirs":[]}'   # reach-fixture-ok: a fixture manifest in a throwaway repo; nothing opens the live module
    Write-RhFile $er 'grocery\check-ad-cycles.ps1' "'chain v1'`n"
    Write-RhFile $er 'grocery\member-b.ps1' "'b v1'`n"
    Write-RhFile $er 'README.md' "doc v1`n"
    $e0 = Save-RhCommit $er 'early base'
    $eAt = { param($from, [hashtable]$files, $msg)
      $null = Invoke-RhGit $er @('checkout', '-q', '--detach', $from)
      foreach ($k in @($files.Keys)) { Write-RhFile $er $k $files[$k] }
      return (Save-RhCommit $er $msg) }
    $eO = & $eAt $e0 @{ 'grocery\member-b.ps1' = "'b v2'`n" } 'origin at commit time changes a member'
    $eO2 = & $eAt $eO @{ 'README.md' = "doc v2`n" } 'origin moves on by a non-member change'
    $eO3 = & $eAt $eO @{ 'grocery\member-b.ps1' = "'b v3'`n" } 'origin moves on by a member change'
    $eH = & $eAt $e0 @{ 'grocery\check-ad-cycles.ps1' = "'chain v2'`n" } 'the session''s own chain change'
    $eHdoc = & $eAt $eH @{ 'README.md' = "doc own`n" } 'a doc commit on top of it: same key'
    $eH2 = & $eAt $e0 @{ 'grocery\check-ad-cycles.ps1' = "'chain v3'`n" } 'a second chain change: a new key'
    $eDoc = & $eAt $e0 @{ 'README.md' = "doc only`n" } 'a commit touching no member'
    $eAhead = & $eAt $e0 @{ 'grocery\ahead.ps1' = "'from the ticket ahead'`n" } 'a ticket ahead adds a member absent until then'
    $eClash = & $eAt $e0 @{ 'grocery\member-b.ps1' = "'b clash'`n" } 'a ticket ahead that conflicts with origin'
    $null = Invoke-RhGit $er @('checkout', '-q', '--detach', $eH)
    # THE PUSH'S KEY, by REAL git: HEAD rebased with `git rebase` in a throwaway clone, then Get-RhManifestSet. This is
    # the independent half of "the early key equals the key -ForPush computes after push-main's rebase".
    function Get-RhRebasedKey([string]$Head, [string]$OntoSha) {
      $d = Join-Path $st ('rb-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
      $null = Invoke-RhGit $st @('clone', '-q', '--shared', '--no-checkout', $er, $d)
      $null = Invoke-RhGit $d @('config', 'core.autocrlf', 'false')
      $null = Invoke-RhGit $d @('checkout', '-q', '--detach', $Head)
      $rb = Invoke-RhGit $d @('-c', 'user.name=rh-fixture', '-c', 'user.email=rh@fixture.invalid', 'rebase', '-q', $OntoSha)
      $tip = ([string](Invoke-RhGit $d @('rev-parse', 'HEAD')).stdout).Trim()
      return [pscustomobject]@{ Rc = $rb.rc; Tip = $tip; Repo = $d; Key = (Get-RhManifestSet $d $tip).Key }
    }
    $eRuns = Join-Path $st 'eruns'; $null = [IO.Directory]::CreateDirectory($eRuns)
    $eRunner = {
      param($Tree, $TimeoutMin, $ChildEnv)
      [IO.File]::WriteAllText((Join-Path $Tree 'grocery\out\chain-verdict.json'), '{"guards_blocked":false,"verdict":"clean"}')   # reach-fixture-ok: builds a throwaway fixture repo under %TEMP%; nothing opens the live module
      $seen = [ordered]@{ chain = [IO.File]::ReadAllText((Join-Path $Tree 'grocery\check-ad-cycles.ps1')).Trim(); b = [IO.File]::ReadAllText((Join-Path $Tree 'grocery\member-b.ps1')).Trim()
        ahead = [IO.File]::Exists((Join-Path $Tree 'grocery\ahead.ps1')); run = [string]$ChildEnv['TC_REHEARSAL_RUN']; temp = [string]$ChildEnv['TEMP']; tree = $Tree }
      [IO.File]::WriteAllText((Join-Path $eRuns ([guid]::NewGuid().ToString('N') + '.json')), ($seen | ConvertTo-Json -Compress))
      [pscustomobject]@{ Blind = ''; Why = ''; Rc = 0; TimedOut = $false; Stopped = $false; Tail = @() }
    }.GetNewClosure()
    function Get-RhRuns { $o = @(); foreach ($f in [IO.Directory]::GetFiles($eRuns, '*.json')) { $o += ([IO.File]::ReadAllText($f) | ConvertFrom-Json); [IO.File]::Delete($f) }; return , $o }
    $ePfx = 'Global\tc-rhe-' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '-'
    $eSlotPfx = 'Global\tc-rhes-' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '-'
    $eQ = Join-Path $st 'eq'
    $vdE = Join-Path $st 'verdicts-early'
    $eCk = 'C:\rh-fixture\checkout-a'
    $eArgs = @{ Repo = $er; VerdictDir = $vdE; SourceRoot = $seedDir; Today = $today; Seeder = $fakeSeeder; ChainRunner = $eRunner; NoPair = $true;
      EarlyPrefix = $ePfx; EarlyQueueRoot = $eQ; EarlyStallSec = 30; SlotPrefix = $eSlotPfx; SlotQueueRoot = $eQ; SlotStallSec = 30 }
    $e1 = Invoke-RhEarly @eArgs -Commit $eH -Onto $eO -CheckoutPath $eCk
    $e1Runs = Get-RhRuns
    $rbO = Get-RhRebasedKey $eH $eO
    Test-RhCase 'MUST FIRE  a commit that changes a member starts ONE early rehearsal onto the given origin sha, of HEAD REBASED onto it, and its verdict key equals the key of that content after a real git rebase onto the same origin' {
      ($e1.Started -and ($e1.Record.result -eq 'pass') -and ($rbO.Rc -eq 0) -and ($e1.Key -ceq $rbO.Key) -and ($e1.Record.key -ceq $rbO.Key) -and ($e1Runs.Count -eq 1) -and ($e1Runs[0].chain -ceq "'chain v2'") -and ($e1Runs[0].b -ceq "'b v2'")), ('started=' + $e1.Started + ' reason=' + $e1.Reason + ' result=' + $e1.Record.result + ' ' + $e1.Record.blind + ' ' + $e1.Record.cause + ' key=' + $e1.Key + ' rebased=' + $rbO.Key + ' runs=' + $e1Runs.Count + ' ' + (@($e1Runs | ForEach-Object { $_.chain + '/' + $_.b }) -join ';') + ' ' + (@($e1.Lines) -join ' / '))
    }
    Test-RhCase 'MUST FIRE  the rehearsal exports TC_REHEARSAL_RUN=1 to the chain child (a post-commit hook that sees it starts nothing), and gives it a TEMP inside its own scratch root' {
      (($e1Runs.Count -eq 1) -and ($e1Runs[0].run -ceq '1') -and ([string]$e1Runs[0].temp).StartsWith((Split-Path -Parent ([string]$e1Runs[0].tree)) + '\', [StringComparison]::OrdinalIgnoreCase)), ('runs=' + $e1Runs.Count + ' run=' + (@($e1Runs | ForEach-Object { $_.run }) -join ',') + ' temp=' + (@($e1Runs | ForEach-Object { $_.temp }) -join ','))
    }
    $e1V = Read-RhVerdict $vdE $e1.Key
    $ssNames = @('stack', 'clone', 'checkout', 'seed', 'selftest', 'ship', 'commit')
    $ssBad = @($ssNames | Where-Object { -not ($e1V -and $e1V.stage_secs -and $e1V.stage_secs.PSObject.Properties[$_] -and ($e1V.stage_secs.$_ -is [int] -or $e1V.stage_secs.$_ -is [long])) })
    Test-RhCase 'CLEAN TWIN  the early verdict record carries early, onto, head, checkout (the hashed checkout path) and a numeric stage_secs for every stage' {
      (($null -ne $e1V) -and ($e1V.early -eq $true) -and ($e1V.onto -ceq $eO) -and ($e1V.head -ceq $eH) -and ($e1V.checkout -ceq (Get-RhCheckoutHash $eCk)) -and ($ssBad.Count -eq 0)), ('rec=' + [bool]$e1V + ' early=' + $e1V.early + ' onto=' + $e1V.onto + ' head=' + $e1V.head + ' ck=' + $e1V.checkout + ' missing=' + ($ssBad -join ','))
    }
    $dAfter = Get-RhPushDecision -Repo $rbO.Repo -RefLines @('refs/heads/main ' + $rbO.Tip + ' refs/heads/main ' + $eO) -VerdictDir $vdE -Today $today
    Test-RhCase 'CLEAN TWIN  the push of that same content, rebased onto that origin, reads PASSED from the early verdict in seconds: no rehearsal runs' {
      (($dAfter.Code -eq 0) -and ($dAfter.Outcome -eq 'rehearsed-pass') -and ((Get-RhRuns).Count -eq 0)), ('' + $dAfter.Code + ' ' + $dAfter.Outcome + ' ' + (@($dAfter.Lines) -join ' / '))
    }
    $dAfterMark = Format-RhCheckComplete $dAfter
    Test-RhCase 'MUST FIRE  that decision says its covering verdict was an EARLY one: Early=yes, and the CHAIN-REHEARSAL-CHECK-COMPLETE line ends early=yes (push-main reads it into early_hit for B22)' {
      (($dAfter.Early -ceq 'yes') -and [string]::Equals($dAfterMark, 'CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=rehearsed-pass early=yes', [StringComparison]::Ordinal)), ('early=' + $dAfter.Early + ' mark=' + $dAfterMark)
    }
    $dDocE = Get-RhPushDecision -Repo $er -RefLines @('refs/heads/main ' + $eDoc + ' refs/heads/main ' + $e0) -VerdictDir $vdE -Today $today
    $dDocMark = Format-RhCheckComplete $dDocE
    Test-RhCase 'MUST NOT FIRE  a push touching no member is decided by no verdict, so its marker carries no early token at all (never a guessed early=no)' {
      (($dDocE.Outcome -eq 'not-needed') -and ($dDocE.Early -ceq '') -and ($dDocMark -cnotmatch '\bearly=')), ('outcome=' + $dDocE.Outcome + ' early=' + $dDocE.Early + ' mark=' + $dDocMark)
    }
    $rbO2 = Get-RhRebasedKey $eH $eO2
    $dO2 = Get-RhPushDecision -Repo $rbO2.Repo -RefLines @('refs/heads/main ' + $rbO2.Tip + ' refs/heads/main ' + $eO2) -VerdictDir $vdE -Today $today
    $rbO3 = Get-RhRebasedKey $eH $eO3
    $dO3 = Get-RhPushDecision -Repo $rbO3.Repo -RefLines @('refs/heads/main ' + $rbO3.Tip + ' refs/heads/main ' + $eO3) -VerdictDir $vdE -Today $today
    Test-RhCase 'MUST FIRE  the measured condition: origin moved past the early rehearsal''s base by a NON-member commit, the early verdict still covers the push; moved by a MEMBER commit, it does not' {
      (($rbO2.Key -ceq $e1.Key) -and ($dO2.Code -eq 0) -and ($dO2.Outcome -eq 'rehearsed-pass') -and ($rbO3.Key -cne $e1.Key) -and ($dO3.Code -eq 1) -and ($dO3.Outcome -eq 'no-verdict')), ('O2 key same=' + ($rbO2.Key -ceq $e1.Key) + ' ' + $dO2.Outcome + ' | O3 key same=' + ($rbO3.Key -ceq $e1.Key) + ' ' + $dO3.Outcome)
    }
    $eNo = Invoke-RhEarly @eArgs -Commit $eDoc -Onto $eO -CheckoutPath $eCk
    Test-RhCase 'MUST NOT FIRE  a commit touching no member starts nothing (reason not-chain), and runs no chain' {
      ((-not $eNo.Started) -and ($eNo.Reason -eq 'not-chain') -and ((Get-RhRuns).Count -eq 0)), ('started=' + $eNo.Started + ' reason=' + $eNo.Reason)
    }
    $eAgain = Invoke-RhEarly @eArgs -Commit $eHdoc -Onto $eO -CheckoutPath 'C:\rh-fixture\checkout-b'
    $k2 = ''
    $s2 = New-RhStack -Repo $er -Commit $eH2 -Onto $eO
    try { $k2 = (Get-RhManifestSet $s2.Repo $s2.Tip).Key } finally { Remove-RhStack $s2 }
    $fakeIn = Join-Path (Join-Path $vdE 'early') ((Get-RhCheckoutHash 'C:\rh-fixture\checkout-z') + '.json')
    $meStart = [string](Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
    [IO.File]::WriteAllText($fakeIn, (([ordered]@{ pid = $PID; pid_start = $meStart; key = $k2; stop_file = (Join-Path $st 'never.stop') }) | ConvertTo-Json -Compress))
    $eHeld = Invoke-RhEarly @eArgs -Commit $eH2 -Onto $eO -CheckoutPath $eCk
    [IO.File]::Delete($fakeIn)
    Test-RhCase 'MUST NOT FIRE  a commit whose rebased key already has a verdict starts nothing, from any checkout; nor does one whose key a LIVE early run in ANOTHER checkout already holds' {
      ((-not $eAgain.Started) -and ($eAgain.Reason -eq 'verdict-exists') -and (-not $eHeld.Started) -and ($eHeld.Reason -eq 'in-flight') -and ((Get-RhRuns).Count -eq 0)), ('again=' + $eAgain.Reason + ' held=' + $eHeld.Reason + ' ' + (@($eHeld.Lines) -join ' / '))
    }
    $clashFile = Join-Path $st 'stack-clash.txt'
    [IO.File]::WriteAllText($clashFile, ($eO + "`n" + $eClash + "`n"))
    # THE VERDICT STORE BY CONTENT: every verdict file's name and SHA-256 (a directory's own write time is not a verdict).
    function Get-RhVerdictHashes([string]$Dir) { $a = @(); if ([IO.Directory]::Exists($Dir)) { foreach ($f in ([IO.Directory]::GetFiles($Dir, '*.json') | Sort-Object)) { $a += ([IO.Path]::GetFileName($f) + '=' + (Get-FileHash -Algorithm SHA256 -LiteralPath $f).Hash) } }; return ($a -join ';') }
    $vdBefore = Get-RhVerdictHashes $vdE
    $sc = Invoke-RhRehearsal -Repo $er -Commit $eH -StackFile $clashFile -VerdictDir $vdE -SourceRoot $seedDir -Today $today -Seeder $fakeSeeder -ChainRunner $eRunner -NoPair -SlotPrefix $eSlotPfx -SlotQueueRoot $eQ -SlotStallSec 30
    Test-RhCase 'MUST FIRE  a stack whose replay conflicts records NO verdict: blind=stack-conflict, exit 3, the verdict store unchanged and no chain run' {
      (($sc.result -eq 'blind') -and ($sc.blind -eq 'stack-conflict') -and ((Get-RhExitCode $sc.result) -eq 3) -and ([string]::Equals($vdBefore, (Get-RhVerdictHashes $vdE), [StringComparison]::Ordinal)) -and ((Get-RhRuns).Count -eq 0)), ($sc.result + ' ' + $sc.blind + ' ' + $sc.cause + ' rc=' + (Get-RhExitCode $sc.result) + ' storeSame=' + [string]::Equals($vdBefore, (Get-RhVerdictHashes $vdE), [StringComparison]::Ordinal) + ' runs=' + (Get-RhRuns).Count)
    }
    $aheadFile = Join-Path $st 'stack-ahead.txt'
    [IO.File]::WriteAllText($aheadFile, ($eO + "`n" + $eAhead + "`n"))
    $sa = Invoke-RhRehearsal -Repo $er -Commit $eH -StackFile $aheadFile -VerdictDir $vdE -SourceRoot $seedDir -Today $today -Seeder $fakeSeeder -ChainRunner $eRunner -NoPair -SlotPrefix $eSlotPfx -SlotQueueRoot $eQ -SlotStallSec 30
    $saRuns = Get-RhRuns
    Test-RhCase 'MUST FIRE  a stack file stacks: the rehearsed tree holds origin, the ticket ahead and this commit''s own change, and the key is that stacked tip''s, not HEAD''s rebased onto origin alone' {
      (($sa.result -eq 'pass') -and ($saRuns.Count -eq 1) -and $saRuns[0].ahead -and ($saRuns[0].chain -ceq "'chain v2'") -and ($saRuns[0].b -ceq "'b v2'") -and ($sa.key -cne $e1.Key)), ($sa.result + ' ' + $sa.blind + ' ' + $sa.cause + ' runs=' + $saRuns.Count + ' ' + (@($saRuns | ForEach-Object { $_.chain + '/' + $_.b + '/' + $_.ahead }) -join ';'))
    }
    # THE EARLY CAP: 4 early caps held by OTHER processes (a mutex is reentrant on its owning thread). A 5th early run
    # waits and gives up inside its lowered stall; a push-time rehearsal at the same moment is still granted a slot.
    $capHolds = New-Object Collections.ArrayList
    try {
      for ($i = 0; $i -lt $script:RhEarlyMaxSlots; $i++) { [void]$capHolds.Add((Start-TcMutexHold -Name ($ePfx + $i))) }
      $eCapArgs = $eArgs.Clone(); $eCapArgs.EarlyStallSec = 2
      $eCap = Invoke-RhEarly @eCapArgs -Commit $eH2 -Onto $eO -CheckoutPath $eCk
      $pushTime = Invoke-RhRehearsal -Repo $er -Commit $eH2 -VerdictDir $vdE -SourceRoot $seedDir -Today $today -Seeder $fakeSeeder -ChainRunner $eRunner -NoPair -SlotPrefix $eSlotPfx -SlotQueueRoot $eQ -SlotStallSec 30
      $capRuns = Get-RhRuns
      Test-RhCase ('MUST FIRE  the early cap: with all ' + $script:RhEarlyMaxSlots + ' early caps held by other processes a 5th early run starts nothing (no-early-cap), while a push-time rehearsal is still granted a slot and runs') {
        ((@($capHolds | Where-Object { $_.Held }).Count -eq $script:RhEarlyMaxSlots) -and (-not $eCap.Started) -and ($eCap.Reason -eq 'no-early-cap') -and ($pushTime.result -eq 'pass') -and ($capRuns.Count -eq 1)), ('held=' + @($capHolds | Where-Object { $_.Held }).Count + ' early=' + $eCap.Reason + ' push=' + $pushTime.result + ' ' + $pushTime.blind + ' runs=' + $capRuns.Count)
      }
    } finally { foreach ($h in @($capHolds.ToArray())) { Stop-TcMutexHold $h } }

    # SUPERSEDE AND THE STOP, across PROCESSES: a run is stopped only through its own stop file, so the run being stopped
    # must be another process. Each child runs -Early from a sandbox inside the fixture repo, a copy of this file whose
    # slot, early-cap and queue names are private, whose stop poll is 200 ms, and whose seeder and chain are stubs: the
    # chain stub blocks on a release file when TC_RHFX_BLOCK names one, in a CHILD it starts, so the stop has a child to stop.
    $esToday = (Get-Date).ToString('yyyy-MM-dd')
    $esSeed = Join-Path $st 'eseed'
    Write-RhFile $esSeed ('grocery\out\comparison-' + $esToday + '.json') '{}'   # reach-fixture-ok: builds a throwaway fixture repo under %TEMP%; nothing opens the live module
    $esBox = Join-Path $er 'le'
    $null = [IO.Directory]::CreateDirectory((Join-Path $esBox 'ops')); $null = [IO.Directory]::CreateDirectory((Join-Path $esBox 'lib'))
    foreach ($f in [IO.Directory]::GetFiles((Join-Path $script:RhRoot 'lib'), '*.ps1')) { [IO.File]::Copy($f, (Join-Path (Join-Path $esBox 'lib') ([IO.Path]::GetFileName($f)))) }
    $esQ = Join-Path $st 'esq'
    $esPfx = 'Global\tc-rhxs-' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '-'
    $esEPfx = 'Global\tc-rhxe-' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '-'
    $nEarly = '$script:RhEarly' + 'Prefix = ''Global\tc-rehearsal' + '-early-'''
    $nPoll = '$script:RhStop' + 'PollMs = ' + '5000'
    $nSeed = '$script:RhDefault' + 'Seeder = {'
    $nRun = '$script:RhDefault' + 'ChainRunner = {'
    $stubSeed = '$script:RhDefault' + 'Seeder = { param([string]$Tree, [string]$SourceRoot) Copy-Item -Recurse -Force (Join-Path $SourceRoot ''grocery'') $Tree; [pscustomobject]@{ Rc = 0; Stopped = $false; Tail = @() } }' + "`n" + '$script:RhUnusedSeeder = {'
    $stubRun = '$script:RhDefault' + 'ChainRunner = { param([string]$Tree, [int]$TimeoutMin, [hashtable]$ChildEnv)' + "`n" +
      '  [IO.File]::WriteAllText((Join-Path $Tree ''grocery\out\chain-verdict.json''), ''{"guards_blocked":false,"verdict":"clean"}'')' + "`n" +
      '  if ($env:TC_RHFX_BLOCK) { [IO.File]::WriteAllText(($env:TC_RHFX_BLOCK + ''.started''), $Tree)' + "`n" +
      '    $w = Invoke-RhProcess -File ''powershell.exe'' -Arguments (''-NoProfile -Command "while (-not (Test-Path -LiteralPath '''''' + $env:TC_RHFX_BLOCK + ''.release'''')) { Start-Sleep -Milliseconds 100 }"'') -WorkDir $Tree -Env $ChildEnv -TimeoutSec 300' + "`n" +
      '    if ($w.Stopped) { return [pscustomobject]@{ Blind = ''stopped''; Why = ''stopped in the fixture chain''; Rc = -3; TimedOut = $false; Stopped = $true; Tail = @() } } }' + "`n" +
      '  [pscustomobject]@{ Blind = ''''; Why = ''''; Rc = 0; TimedOut = $false; Stopped = $false; Tail = @() } }' + "`n" + '$script:RhUnusedChainRunner = {'
    $esSrc = [IO.File]::ReadAllText((Join-Path $script:RhRoot 'ops\rehearse-chain.ps1'))
    $esGs = [IO.File]::ReadAllText((Join-Path $script:RhRoot 'lib\gate-slots.ps1'))
    $esRewrites = '' + (Get-RhOrdinalCount $esSrc $nPrefix) + ',' + (Get-RhOrdinalCount $esSrc $nStall) + ',' + (Get-RhOrdinalCount $esSrc $nEarly) + ',' + (Get-RhOrdinalCount $esSrc $nPoll) + ',' + (Get-RhOrdinalCount $esSrc $nSeed) + ',' + (Get-RhOrdinalCount $esSrc $nRun) + ',' + (Get-RhOrdinalCount $esGs $nQueue)
    $esOk = ($esRewrites -eq '1,1,1,1,1,1,1')
    if ($esOk) {
      $esText = $esSrc.Replace($nPrefix, ('$script:RhSlotPrefix = ''' + $esPfx + '''')).Replace($nStall, '$script:RhSlotStallSec = 30').Replace($nEarly, ('$script:RhEarlyPrefix = ''' + $esEPfx + '''')).Replace($nPoll, '$script:RhStopPollMs = 200').Replace($nSeed, $stubSeed).Replace($nRun, $stubRun)
      [IO.File]::WriteAllText((Join-Path $esBox 'ops\rehearse-chain.ps1'), $esText, (New-Object Text.UTF8Encoding($false)))
      [IO.File]::WriteAllText((Join-Path $esBox 'lib\gate-slots.ps1'), $esGs.Replace($nQueue, ('$script:TcGateQueueRoot = ''' + $esQ + '''')), (New-Object Text.UTF8Encoding($false)))
    }
    $vdS = Join-Path $st 'verdicts-stop'; $null = [IO.Directory]::CreateDirectory($vdS)
    $esIn = Join-Path (Join-Path $vdS 'early') ((Get-RhCheckoutHash $esBox) + '.json')
    function Start-RhEsChild([string]$Commit, [string]$Block, [string]$TempDir) {
      $null = [IO.Directory]::CreateDirectory($TempDir)
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = $lsPsExe; $psi.WorkingDirectory = $esBox; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
      $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
      $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $esBox 'ops\rehearse-chain.ps1') + '" -Early -Onto ' + $eO + ' -Commit ' + $Commit + ' -Source "' + $esSeed + '" -NoPair')
      foreach ($n in @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'TC_NO_REHEARSAL')) { if ($psi.EnvironmentVariables.ContainsKey($n)) { $psi.EnvironmentVariables.Remove($n) } }
      $psi.EnvironmentVariables['TC_REHEARSAL_VERDICT_DIR'] = $vdS; $psi.EnvironmentVariables['TEMP'] = $TempDir; $psi.EnvironmentVariables['TMP'] = $TempDir
      $psi.EnvironmentVariables['TC_RHFX_BLOCK'] = $Block
      $pr = [Diagnostics.Process]::Start($psi)
      return [pscustomobject]@{ P = $pr; Out = $pr.StandardOutput.ReadToEndAsync(); Err = $pr.StandardError.ReadToEndAsync() }
    }
    function Wait-RhEsChild($C, [int]$Sec, [string]$Release) {
      # A hang guard, never a bar: on a miss the release file frees the stub so the child still ends.
      # Released says the stub had to be FREED to end, which a working stop never needs.
      $released = $false
      if (-not $C.P.WaitForExit($Sec * 1000)) { if ($Release) { [IO.File]::WriteAllText($Release, 'x'); $released = $true }; $null = $C.P.WaitForExit(120000) }
      $C.Out.Wait(); $C.Err.Wait()
      return [pscustomobject]@{ Released = $released; Rc = $C.P.ExitCode; Lines = @(([string]$C.Out.Result) -split "`r?`n" | Where-Object { $_ -ne '' }); Err = [string]$C.Err.Result }
    }
    function Wait-RhFile([string]$Path, $C, [int]$Sec) {
      $sw = [Diagnostics.Stopwatch]::StartNew()
      while (-not [IO.File]::Exists($Path) -and -not $C.P.HasExited -and $sw.Elapsed.TotalSeconds -lt $Sec) { Start-Sleep -Milliseconds 100 }   # a hang guard, never a bar
      return [IO.File]::Exists($Path)
    }
    function Get-RhStoreHash { return (Get-RhVerdictHashes $vdS) }
    function Get-RhTempLeft([string]$Dir) { return @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'tc-rh*' -or $_.Name -like 'rh-index-*' } | ForEach-Object { $_.Name }) }
    # (a) THE STOP: A blocks inside its chain; its stop file, written here, ends it.
    $blkA = Join-Path $st 'blkA'; $tA = Join-Path $st 'tA'
    $storeA0 = Get-RhStoreHash
    $cA = $null; $rA = $null; $aStarted = $false; $aStop = ''
    if ($esOk) {
      $cA = Start-RhEsChild $eH $blkA $tA
      $aStarted = Wait-RhFile ($blkA + '.started') $cA 120
      if ($aStarted -and [IO.File]::Exists($esIn)) { $aStop = [string](([IO.File]::ReadAllText($esIn) | ConvertFrom-Json).stop_file) }
      if ($aStop) { [IO.File]::WriteAllText($aStop, 'stopped by the fixture') }
      $rA = Wait-RhEsChild $cA 120 ($blkA + '.release')
    }
    $aLast = $(if ($rA) { [string]@($rA.Lines)[-1] } else { '' })
    $slotsFree = $null
    try { $slotsFree = Enter-TcGateSlots -Want $script:RhMaxConcurrent -Total $script:RhMaxConcurrent -Prefix $esPfx -QueueRoot $esQ -WaitSec 5 -PollMs 100 } catch { $slotsFree = $null }
    $slotsGot = $(if ($slotsFree) { $slotsFree.Count } else { -1 }); if ($slotsFree) { Exit-TcGateSlots $slotsFree }
    Test-RhCase 'MUST FIRE  the stop: a running early rehearsal whose stop file appears stops its OWN chain child and ends blind=stopped, exit 3, with its scratch root gone, its in-flight file removed and all 6 of its slots free' {
      ($esOk -and $aStarted -and [bool]$aStop -and (-not $rA.Released) -and ($rA.Rc -eq 3) -and ($aLast -cmatch '^CHAIN-REHEARSAL-EARLY-COMPLETE started=yes reason=rehearsed verdict=blind blind=stopped ') -and ((Get-RhTempLeft $tA).Count -eq 0) -and (-not [IO.File]::Exists($esIn)) -and ($slotsGot -eq $script:RhMaxConcurrent)), ('rewrites=' + $esRewrites + ' released=' + $rA.Released + ' started=' + $aStarted + ' stop=' + $aStop + ' rc=' + $rA.Rc + ' last=' + $aLast + ' left=' + ((Get-RhTempLeft $tA) -join ',') + ' inflight=' + [IO.File]::Exists($esIn) + ' slots=' + $slotsGot + ' err=' + $(if ($rA) { $rA.Err.Substring(0, [Math]::Min(300, $rA.Err.Length)) }))
    }
    Test-RhCase 'MUST NOT FIRE  a stopped run changes nothing in the verdict store: every verdict file''s hash is identical before and after' {
      ($esOk -and [bool]$rA -and [string]::Equals($storeA0, (Get-RhStoreHash), [StringComparison]::Ordinal)), ('before=' + $storeA0 + ' after=' + (Get-RhStoreHash))
    }
    # (b) SUPERSEDE: A2 blocks; B' (a doc commit on top, the SAME key) stops nothing; B (a NEW key) stops A2 and runs.
    $blkA2 = Join-Path $st 'blkA2'; $tA2 = Join-Path $st 'tA2'; $tB1 = Join-Path $st 'tB1'; $tB = Join-Path $st 'tB'
    $cA2 = $null; $rA2 = $null; $rB1 = $null; $rB = $null; $a2Started = $false; $a2Stop = ''; $b1StopSeen = $true
    if ($esOk) {
      $cA2 = Start-RhEsChild $eH $blkA2 $tA2
      $a2Started = Wait-RhFile ($blkA2 + '.started') $cA2 120
      if ($a2Started -and [IO.File]::Exists($esIn)) { $a2Stop = [string](([IO.File]::ReadAllText($esIn) | ConvertFrom-Json).stop_file) }
      $rB1 = Wait-RhEsChild (Start-RhEsChild $eHdoc '' $tB1) 120 ''
      $b1StopSeen = ($a2Stop -and [IO.File]::Exists($a2Stop))
      $rB = Wait-RhEsChild (Start-RhEsChild $eH2 '' $tB) 120 ''
      $rA2 = Wait-RhEsChild $cA2 120 ($blkA2 + '.release')
    }
    $b1Last = $(if ($rB1) { [string]@($rB1.Lines)[-1] } else { '' })
    $bLast = $(if ($rB) { [string]@($rB.Lines)[-1] } else { '' })
    $a2Last = $(if ($rA2) { [string]@($rA2.Lines)[-1] } else { '' })
    Test-RhCase 'CLEAN TWIN  supersede leaves the same key alone: a second commit in the same checkout that keeps the key (a doc commit on top) starts nothing and writes no stop file' {
      ($esOk -and $a2Started -and ($rB1.Rc -eq 0) -and ($b1Last -cmatch '^CHAIN-REHEARSAL-EARLY-COMPLETE started=no reason=in-flight ') -and (-not $b1StopSeen)), ('started=' + $a2Started + ' rc=' + $rB1.Rc + ' last=' + $b1Last + ' stopSeen=' + $b1StopSeen)
    }
    Test-RhCase 'MUST FIRE  supersede: a second commit in the same checkout that CHANGES the key writes the first run''s stop file; the first ends blind=stopped with its scratch root gone, and the second runs and passes' {
      ($esOk -and $a2Started -and ($rB.Rc -eq 0) -and ($bLast -cmatch '^CHAIN-REHEARSAL-EARLY-COMPLETE started=yes reason=rehearsed verdict=pass key=\S+ superseded=\d+$') -and (-not $rA2.Released) -and ($rA2.Rc -eq 3) -and ($a2Last -cmatch ' blind=stopped ') -and ((Get-RhTempLeft $tA2).Count -eq 0) -and ((Get-RhTempLeft $tB).Count -eq 0)), ('b rc=' + $rB.Rc + ' last=' + $bLast + ' | a2 released=' + $rA2.Released + ' rc=' + $rA2.Rc + ' last=' + $a2Last + ' left=' + ((Get-RhTempLeft $tA2) -join ',') + ' err=' + $(if ($rB) { $rB.Err.Substring(0, [Math]::Min(300, $rB.Err.Length)) }))
    }
  } finally {
    if ($null -eq $savedVd) { Remove-Item Env:\TC_REHEARSAL_VERDICT_DIR -ErrorAction SilentlyContinue } else { $env:TC_REHEARSAL_VERDICT_DIR = $savedVd }
    if ($null -eq $savedBy) { Remove-Item Env:\TC_NO_REHEARSAL -ErrorAction SilentlyContinue } else { $env:TC_NO_REHEARSAL = $savedBy }
    Remove-Item -LiteralPath $st -Recurse -Force -ErrorAction SilentlyContinue
  }
  # THE MANIFEST NAMES ONLY THE HOOK A REHEARSAL EXERCISES (2026-09-22, post-landing review F4, plan-2026-09-22-10).
  # Stage 7 commits through the tree's own pre-commit; nothing here runs commit-msg or pre-push, whose proof is
  # ops/test-prepush-hook.ps1. Read off the committed manifest at HEAD, the tree this self-test is gating.
  $hkSet = Get-RhManifestSet $script:RhRoot 'HEAD'
  Test-RhCase 'MUST FIRE  a pre-commit edit is a manifest change (the rehearsal commits through that hook)' { ($hkSet.Ok -and $hkSet.Set.ContainsKey('ops/hooks/pre-commit')), ('ok=' + $hkSet.Ok + ' why=' + $hkSet.Why) }
  Test-RhCase 'MUST NOT FIRE  a pre-push or commit-msg edit demands no rehearsal it cannot exercise' { ($hkSet.Ok -and -not $hkSet.Set.ContainsKey('ops/hooks/pre-push') -and -not $hkSet.Set.ContainsKey('ops/hooks/commit-msg')), ('ok=' + $hkSet.Ok) }
  # E1 (PLAN-faster-pushes-no-accuracy-loss-2026-09-25): a push waits for a LIVE early run of its exact key. The live run
  # is a real child process held open on a release file the case controls, never a clock: the first poll releases it,
  # so the wait can only end by seeing the process gone.
  $e1Root = Join-Path $env:TEMP ('rh-e1-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  $null = New-Item -ItemType Directory -Force -ErrorAction Stop (Join-Path $e1Root 'early')
  $e1Rel = Join-Path $e1Root 'release'
  $e1Key = ('ab' * 32)
  $e1Hold = Start-Process -FilePath 'powershell.exe' -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-Command', ('while (-not (Test-Path -LiteralPath ''' + $e1Rel + ''')) { Start-Sleep -Milliseconds 100 }'))
  $null = $e1Hold.Handle
  try {
    $e1Rec = [ordered]@{ pid = $e1Hold.Id; pid_start = [string]$e1Hold.StartTime.ToUniversalTime().Ticks; key = $e1Key }
    [IO.File]::WriteAllText((Join-Path $e1Root 'early\x.json'), ($e1Rec | ConvertTo-Json -Compress))
    $e1Other = Wait-RhInFlightKey -VerdictDir $e1Root -Key ('cd' * 32) -PollMs 50
    Test-RhCase 'MUST NOT FIRE  a live early run of a DIFFERENT key is not waited for (outcome none, 0 polls)' { (($e1Other.Outcome -ceq 'none') -and ($e1Other.Polls -eq 0)), ('outcome=' + $e1Other.Outcome + ' polls=' + $e1Other.Polls) }
    $e1Same = Wait-RhInFlightKey -VerdictDir $e1Root -Key $e1Key -PollMs 50 -MaxMin 2 -OnPoll { param($n) if ($n -eq 0) { [IO.File]::WriteAllText($e1Rel, 'go') } }
    Test-RhCase 'MUST FIRE  a live early run of the SAME key is waited for until its process is gone (outcome ended, at least 1 poll, the holder exited)' { (($e1Same.Outcome -ceq 'ended') -and ($e1Same.Polls -ge 1) -and $e1Hold.WaitForExit(30000)), ('outcome=' + $e1Same.Outcome + ' polls=' + $e1Same.Polls + ' exited=' + $e1Hold.HasExited) }
    $e1Dead = Wait-RhInFlightKey -VerdictDir $e1Root -Key $e1Key -PollMs 50
    Test-RhCase 'CLEAN TWIN  a record whose process has exited is not live, so a push rehearses at once as before (outcome none, 0 polls)' { (($e1Dead.Outcome -ceq 'none') -and ($e1Dead.Polls -eq 0)), ('outcome=' + $e1Dead.Outcome + ' polls=' + $e1Dead.Polls) }
  } finally {
    [IO.File]::WriteAllText($e1Rel, 'go')
    if (-not $e1Hold.HasExited) { $null = $e1Hold.WaitForExit(10000) }
    Remove-Item -LiteralPath $e1Root -Recurse -Force -ErrorAction SilentlyContinue
  }
  $want = 66
  if ($script:rhCases -ne $want) { Write-Output ('rehearse-chain self-test FAIL: ran {0} case(s), the suite lists {1}' -f $script:rhCases, $want); exit 1 }
  if ($script:rhFail) { Write-Output ('rehearse-chain self-test FAIL: {0} of {1} case(s)' -f $script:rhFail, $script:rhCases); exit 1 }
  Write-Output ('rehearse-chain self-test PASS: {0} of {0} cases - led by the founding defect (an empty cost-flags.txt refused by the 09-05 hook) and a manifest change with no verdict being refused' -f $script:rhCases)
  exit 0
}

# ======================================================================================================================
$vdir = Get-RhVerdictDir $VerdictDir
Clear-TcGitRepoEnv
$repoTop = $script:RhRoot

# -Range BELONGS TO -ListSet. Without it this run would fall through to the default mode and REHEARSE (about 14 minutes
# and one of the 6 slots) for a caller who asked only for a listing, so it is refused before anything is read.
if ($Range -and -not $ListSet) {
  Write-Output ('chain-rehearsal: COULD NOT EVALUATE blind=bad-usage - -Range ' + $Range + ' is read only by -ListSet, and without it this run would rehearse. Nothing was rehearsed; add -ListSet.')
  Write-Output 'CHAIN-REHEARSAL-LISTSET-COMPLETE blind=bad-usage'
  exit 3
}
if ($Early) {
  # -EARLY (W9.1): the speculative rehearsal a commit starts (push-main -Prepare, or the post-commit hook of D19,
  # each of which starts this DETACHED and returns at once). It never runs beside -CheckPush, -ForPush or -ListSet.
  if ($CheckPush -or $ForPush -or $ListSet) {
    Write-Output 'chain-rehearsal: COULD NOT EVALUATE blind=bad-usage - -Early cannot be combined with -CheckPush, -ForPush or -ListSet. Nothing was rehearsed.'
    Write-Output 'CHAIN-REHEARSAL-EARLY-COMPLETE started=no reason=bad-usage key=none'
    exit 3
  }
  $e = Invoke-RhEarly -Repo $repoTop -Commit $Commit -Onto $Onto -StackFile $StackFile -VerdictDir $vdir -SourceRoot $Source -CheckoutPath $repoTop -NoPair:$NoPair -TimeoutMin $ChainTimeoutMin
  foreach ($l in $e.Lines) { Write-Output $l }
  $k12 = $(if ($e.Key) { $e.Key.Substring(0, 12) } else { 'none' })
  $sup = $(if ($e.Superseded) { ' superseded=' + $e.Superseded } else { '' })
  if ($e.Started) {
    Write-Output (Format-RhComplete $e.Record)
    $vb = $(if ($e.Record.result -eq 'blind') { ' blind=' + $e.Record.blind } else { '' })
    Write-Output ('CHAIN-REHEARSAL-EARLY-COMPLETE started=yes reason=rehearsed verdict={0}{1} key={2}{3}' -f $e.Record.result, $vb, $k12, $sup)
    exit (Get-RhExitCode $e.Record.result)
  }
  $benign = @('not-chain', 'verdict-exists', 'in-flight', 'stopped-before-start')
  Write-Output ('CHAIN-REHEARSAL-EARLY-COMPLETE started=no reason={0} key={1}{2}' -f $e.Reason, $k12, $sup)
  if ($benign -contains $e.Reason) { exit 0 } else { exit 3 }
}
if ($ListSet) {
  if ($CheckPush -or $ForPush) {
    Write-Output 'chain-rehearsal: COULD NOT EVALUATE blind=bad-usage - -ListSet is read-only and cannot be combined with -CheckPush or -ForPush; run them separately. Nothing was decided.'
    Write-Output 'CHAIN-REHEARSAL-LISTSET-COMPLETE blind=bad-usage'
    exit 3
  }
  $ls = Get-RhListSet -Repo $repoTop -Commit $Commit -Range $Range -CommitGiven:($PSBoundParameters.ContainsKey('Commit'))
  foreach ($l in $ls.Lines) { Write-Output $l }
  exit $ls.Code
}

if ($CheckPush) {
  $refLines = @()
  if ($RefsFromStdin) { $refLines = @(([Console]::In.ReadToEnd()) -split "`r?`n" | Where-Object { $_.Trim() }) }
  elseif ($RefsFile) { $refLines = @([IO.File]::ReadAllLines($RefsFile) | Where-Object { $_.Trim() }) }
  $d = Get-RhPushDecision -Repo $repoTop -RefLines $refLines -Branch $Branch -VerdictDir $vdir -Today (Get-Date) -Bypass ([string]$env:TC_NO_REHEARSAL)
  foreach ($l in $d.Lines) { Write-Output $l }
  Write-Output (Format-RhCheckComplete $d)
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
  $headSha = ([string]$hh.stdout).Trim(); $originSha = ([string]$rr.stdout).Trim()
  $line = 'refs/heads/' + $Branch + ' ' + $headSha + ' refs/heads/' + $Branch + ' ' + $originSha
  $bypass = [string]$env:TC_NO_REHEARSAL
  $decRepo = $repoTop
  $stack = $null
  try {
    # -STACKFILE / -ONTO (W9.1 step 1, for W9.2): the push itself is still judged chain-touching on HEAD against
    # <Remote>/<Branch>; when it is, the verdict looked up and rehearsed is the STACKED tip's, so a queue member finds
    # the key the tickets ahead of it will leave behind.
    if ($StackFile -or $Onto) {
      $tr0 = Get-RhTrigger -Repo $repoTop -Base $originSha -Tip $headSha
      if (-not $tr0.Absent -and ($tr0.Blind -or @($tr0.Touched).Count -gt 0)) {
        $stack = New-RhStack -Repo $repoTop -Commit $headSha -Onto $Onto -StackFile $StackFile
        if (-not $stack.Ok) {
          if ($stack.Blind -eq 'stack-conflict') { Write-Output (Format-RhStackConflict $stack) }
          Write-Output ('chain-rehearsal: COULD NOT EVALUATE blind=' + $stack.Blind + ' - ' + $stack.Why)
          Write-Output ('CHAIN-REHEARSAL-CHECK-COMPLETE code=3 outcome=could-not-rehearse blind=' + $stack.Blind)
          exit 3
        }
        $decRepo = $stack.Repo
        $line = 'refs/heads/' + $Branch + ' ' + $stack.Tip + ' refs/heads/' + $Branch + ' ' + $stack.Onto
        Write-Output ('chain-rehearsal: judging the STACKED tip ' + $stack.Tip.Substring(0, 9) + ': ' + $headSha.Substring(0, 9) + ' onto ' + $stack.Onto.Substring(0, 9) + ' with ' + ($stack.Applied) + ' commit(s) replayed')
      }
    }
    $d = Get-RhPushDecision -Repo $decRepo -RefLines @($line) -Branch $Branch -VerdictDir $vdir -Today (Get-Date) -Bypass $bypass
    if (-not $bypass -and ($d.Outcome -eq 'no-verdict' -or $d.Outcome -eq 'stale')) {
      # E1 (PLAN-faster-pushes-no-accuracy-loss-2026-09-25): an early rehearsal of this EXACT key already running is
      # waited for, never duplicated. Its verdict is read below exactly as any recorded verdict is; if it ends with none
      # (stopped, blind, died) or the wait times out, this push rehearses itself as before.
      $lf = @(([string]$line).Trim() -split '\s+')
      $trK = Get-RhTrigger -Repo $decRepo -Base $lf[3] -Tip $lf[1]
      $wantKey = $(if (-not $trK.Absent -and -not $trK.Blind -and $trK.Manifest) { [string]$trK.Manifest.Key } else { '' })
      $wt = Wait-RhInFlightKey -VerdictDir $vdir -Key $wantKey -MaxMin $ChainTimeoutMin -Say { param($t) Write-Output $t }
      if ($wt.Outcome -eq 'stopped') {
        Write-Output 'chain-rehearsal: STOPPED - this run''s stop file appeared while it waited for the early rehearsal; nothing is recorded for this content'
        Write-Output 'CHAIN-REHEARSAL-CHECK-COMPLETE code=3 outcome=could-not-rehearse blind=stopped'
        exit 3
      }
      if ($wt.Outcome -ne 'none') {
        Write-Output ('chain-rehearsal: the early rehearsal it waited for is over (' + $wt.Outcome + ' after ' + $wt.Polls + ' poll(s)); reading the recorded verdict')
        $d = Get-RhPushDecision -Repo $decRepo -RefLines @($line) -Branch $Branch -VerdictDir $vdir -Today (Get-Date) -Bypass $bypass
      }
    }
    if (-not $bypass -and ($d.Outcome -eq 'no-verdict' -or $d.Outcome -eq 'stale')) {
      Write-Output 'chain-rehearsal: this push changes the chain and has no usable rehearsal verdict - rehearsing HEAD now, OUTSIDE the push lock.'
      $rec = Invoke-RhRehearsal -Repo $repoTop -Commit 'HEAD' -SourceRoot $Source -Remote $Remote -Branch $Branch -VerdictDir $vdir -NoPair:$NoPair -TimeoutMin $ChainTimeoutMin -Stack $stack
      Write-Output (Format-RhComplete $rec)
      if ($rec.result -eq 'blind' -and $rec.blind -eq 'stopped') {
        Write-Output 'chain-rehearsal: STOPPED - this rehearsal''s stop file appeared, so it ended without a verdict; nothing is recorded for this content'
        Write-Output 'CHAIN-REHEARSAL-CHECK-COMPLETE code=3 outcome=could-not-rehearse blind=stopped'
        exit 3
      }
      $d = Get-RhPushDecision -Repo $decRepo -RefLines @($line) -Branch $Branch -VerdictDir $vdir -Today (Get-Date) -Bypass $bypass
    }
    foreach ($l in $d.Lines) { Write-Output $l }
    Write-Output (Format-RhCheckComplete $d)
    exit $d.Code
  } finally { Remove-RhStack $stack }
}

$rec = Invoke-RhRehearsal -Repo $repoTop -Commit $Commit -SourceRoot $Source -Remote $Remote -Branch $Branch -VerdictDir $vdir -NoPair:$NoPair -TimeoutMin $ChainTimeoutMin -Onto $Onto -StackFile $StackFile
Write-Output ('chain-rehearsal: {0} at {1} over data from {2}: {3}' -f $rec.result.ToUpperInvariant(), $(if ($rec.commit) { $rec.commit.Substring(0, 9) } else { $Commit }), $(if ($rec.data_date) { $rec.data_date } else { '-' }), $rec.cause)
if ($rec.stages) { Write-Output ('chain-rehearsal: stages ' + ((@($rec.stages.Keys) | ForEach-Object { $_ + '=' + $rec.stages[$_] }) -join ' ')) }
foreach ($w in @($rec.words | Select-Object -First 12)) { Write-Output ('    ' + $w) }
Write-Output (Format-RhComplete $rec)
exit (Get-RhExitCode $rec.result)
