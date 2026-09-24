<#
  checkout-sync.ps1 - bring the SHARED main checkout to origin/main with a two-way move. No stash, no rebase,
  no reset --hard, no merge into anybody's file.

  WHY THIS EXISTS (design\PLAN-bot-checkout-self-heal-2026-09-23.md, W3.1; ruled by Brad the same day). On 2026-09-23
  the daily grocery run executed on a checkout about 14 hours behind origin, because capture-run fetched and rebased
  only AFTER a commit that had been refused. The mover it used, `git -c rebase.autoStash=true rebase -X theirs`, was
  proved in temp repos to damage a shared checkout: it exits 128 and strands a rebase-merge directory holding only an
  autostash (E1); it exits 0 with conflict markers left in the tree (E2); and it rewrites the mtime of every dirty file
  and drops staging even when origin had not moved at all (E4). This file is the one replacement mover. It has no
  caller when it lands: W4.1 wires the start of capture-run and W4.2 its tail.

  WHAT ONE CALL DOES (Invoke-TcCheckoutSync), in order. The step numbers are the plan's.
    0. Guards. GIT_DIR or GIT_WORK_TREE set, or a LINKED worktree: `skipped`, and nothing is written, not even the log
       row, because the log there would be another checkout's. GIT_INDEX_FILE set: `failed` (a private index was not
       released, and a move under it would move a tree nobody is looking at). The kill switch
       `<git common dir>\tc-checkout-sync.disabled`: `disabled`, and `page` is true once per date.
    1. Anything in progress, BEFORE the branch check (HEAD is detached during a stopped rebase, so a branch check first
       would report the wrong thing). 1a index.lock: waited on, never deleted. 1b a rebase-merge directory whose ONLY
       entry is `autostash`, older than -AutostashAgeSec: `git rebase --quit`, and the autostash must then be
       stash@{0} (the E1 shape; --abort exits 1 on it and leaves the directory). 1c any other operation (rebase,
       merge, cherry-pick, revert, sequencer, bisect): waited on, never aborted. 1c2 a LEFTOVER INTENT (a sync killed
       between read-tree and update-ref): when HEAD is on the branch at its H0, the index equals its NEW's tree and
       the tree matches the index on every path it changed, the missing update-ref is made as a compare-and-swap and a
       note names the interrupted run; any other leftover is named in the outcome's `why` and KEPT until a run ends
       current, synced or partial. 1d unmerged entries and 1e NEW conflict markers in ANY dirty tracked file (JSON
       included, X4; read through a stream that shares write and delete): a path that is owned, NAMED by -OwnBlobs and,
       for a marked one, not staged, is set aside and restored from HEAD, and the outcome then pages and says so; any
       other path is `blocked` class `conflict`, with nothing written. 1f HEAD must be refs/heads/<Branch>. 1g
       (addendum) -BotCommit: index entries still holding the parent's version of a path that commit changed, the
       private-index commit's leftover, are reset to HEAD. Deletions included.
    2. Fetch, with retries, each attempt bounded by -FetchTimeoutSec (its process tree killed on expiry) and by
       http.lowSpeedLimit/lowSpeedTime. A failure is `degraded` class `fetch`, which pages once a date (the state
       file's fetch_paged_on) as the kill switch does; capture-watchdog's CHECKOUT floor sees a checkout that stays
       behind.
    3. Already containing origin: `current`, with ZERO writes to the tree, the index or HEAD (beyond step 1g's index
       resync, which only a caller passing -BotCommit asks for).
    4. A merge commit among the local commits: `degraded`. It is never linearised.
    5. The target NEW: origin, or the local commits replayed onto it off to the side with merge-tree -X theirs and
       commit-tree, which builds the tree `rebase -X theirs` builds and touches neither the index nor the tree.
    6. Every startup file (capture-run.ps1 and what it dot-sources, $script:TcCheckoutSyncStartupFiles) that the move
       changes is PARSED at NEW from the object database first. A missing file or a parse error is `degraded` and
       nothing moves. `startup_changed` tells the caller to re-execute.
    7. Every path the move changes is classified against `git status`: IN-THE-WAY (an ignored file, or an untracked one
       under an OWNED path, where NEW adds a path; git overwrites an ignored one without a word) is moved to quarantine;
       an untracked file outside the owned paths is FOREIGN unless it already holds NEW's blob; ALREADY-UPSTREAM (a
       dirty or untracked file that already holds NEW's blob) gets an index update only, its bytes and mtime never
       touched; OWN-MERGE and
       OWN-SETASIDE (the pipeline's own output, owned AND vouched by -OwnBlobs) are merged, or set aside with upstream
       winning; OWN-DELETED comes back as upstream's version; FOREIGN (a staged change, anyone else's edit, a deletion
       nobody vouches for, and every other status code) is NEVER WRITTEN.
    8. FOREIGN present: PARTIAL. The target falls back to the newest OBSERVED push tip (a value the remote-tracking
       ref's reflog has held) before the first upstream commit touching a FOREIGN path. None: `blocked` class
       `foreign`. The page names each path, its status and that commit.
    9. Apply: intent record; displaced bytes into a dated tree `<QuarantineRoot>\<date>\<HHmmss>-sync\` (quarantine\,
       set-aside\, undo\, manifest.json); `git read-tree -m -u H0 NEW`; `git update-ref` as a compare-and-swap.
       read-tree is atomic in its up-to-date check and NOT in its write phase on Windows (section 2.6): a file another
       process holds open without FILE_SHARE_DELETE is refused mid-write with rc 128 and `unable to unlink old`, with
       other paths already written. FORWARD then stages git's own writes and retries once; BACKWARD restores every path
       to its pre-sync state. Both are verified by bytes. The same held file over a path upstream DELETES is only a
       warning and rc 0, so every deleted path must be absent before the ref moves: one delete of a leftover still
       holding H0's blob after -HeldRetrySec, else BACKWARD and `blocked` class `held-file`. An in-the-way file a reader
       holds cannot be quarantined: one retry, then the put-back and `blocked` class `held-file`. A lost swap gets ONE
       recovery (F11); an update-ref that fails while the branch still names H0 is not a lost swap: one retry, then
       BACKWARD and `degraded` class `ref-lock`.
   10. Verify: HEAD, no unmerged entry, no operation, the INDEX at NEW on every changed path, the WORKTREE at NEW on
       every changed path but the merged ones, and the fingerprint (porcelain v2 line, length, mtime) of every dirty
       path outside the move identical, except that a path whose status is unchanged and whose mtime only moved FORWARD
       is a session's own save and goes into `notes`. The undo\ copies are deleted only after this passes.
   11. Record: `<git common dir>\tc-checkout-sync.json` (the last record, the intent, the kill-switch page date) and
       one row appended to `<git common dir>\tc-checkout-sync-log.jsonl`.

  OUTCOMES (the record's `outcome`, `class`, `why`, `page`): current, synced (no page); partial, blocked (classes
  foreign, held-file, read-tree, conflict), degraded (classes in-progress, index-lock, branch, merge, replay,
  startup-parse, head-moved, index, ref-lock), failed (classes environment, mixed-tree, verify, exception) page;
  disabled and degraded class fetch page once a date; skipped neither pages nor logs. A current or synced outcome
  that made a step 1d/1e set-aside pages too. The caller decides what to do with each; the plan's table is the
  contract: only `conflict` and `mixed-tree` should stop a run before its captures.

  WHAT IT NEVER DOES. It never runs stash, rebase (except --quit on the 1b shape), reset --hard, checkout -B, merge or
  clean; never deletes index.lock; never aborts an operation it did not recover; never writes a FOREIGN file, not even
  its mtime; never rewrites an index entry it did not make, except ALREADY-UPSTREAM (whose bytes already equal
  upstream's) and the -BotCommit leftovers (which that commit made); never deletes a quarantined, set-aside or undo file
  on a failure path; never moves HEAD off refs/heads/<Branch>; never runs in a linked worktree.

  IDEMPOTENT, AND WHAT MAKES IT SO. A retried sync is idempotent: `current` writes nothing, and a completed move is seen
  at step 3 as `current`. A sync killed before its update-ref leaves HEAD at H0 with the index or tree at NEW and its
  intent in the state file; the next sync's step 1c2 finishes it when the index and tree are exactly at NEW, and
  otherwise names it on every outcome until a run ends clean, so it never compounds and is never misnamed as a
  session's work. The log append (Add-TcLine) is NOT idempotent, so it is never retried by this code; it is written
  before the state file and in its own try, so a held state file does not cost the row.

  CONCURRENCY. Writers of the two state files are serialised by capture-run's mutex (Global\tc-capture-run, the plan's
  lock level 0); readers such as capture-watchdog read one record lock-free, which survives a non-repeatable read.
  The sync takes no push lock and no gate slot.

  CONSTANTS. Each is the first plausible value, not the survivor of a sweep (plan section 6 W5.1): index.lock wait 60 s,
  in-progress wait 120 s, autostash-only age 300 s, held-file retry 2 s once (also the held-delete, held-quarantine
  and ref-lock retries), fetch 3 attempts 5 s apart, each bounded at 300 s and at 1,000 B/s for 60 s, marker scan
  cap 52,428,800 bytes, NUL probe 8,000 bytes. What each does when the producer stops: none is a floor; a sync that
  never runs writes no row, and capture-watchdog's CHECKOUT floor (W1.1) is what sees that.

  STARTUP FILES. $script:TcCheckoutSyncStartupFiles is a LITERAL list: capture-run.ps1 plus every file it dot-sources.
  lib\test-checkout-sync.ps1 asserts it equals Get-TcCaptureRunDotSources over the real grocery\capture-run.ps1, so a
  change that adds or drops a dot-source in capture-run must change this list in the same commit, or that self-test is
  red. Files the startup libs themselves dot-source (ledger-lock, event-bus, git-repo-env) are NOT in it, so a change to
  one of those alone does not re-execute: a known limit, filed in design\backlog-inbox\sh-sync-2026-09-23.md.

  SCOPE OF A CLEAN RESULT. The marker scan (1e) is unsound: it sees marker triples in regular files up to the cap with
  no NUL in their first 8,000 bytes; a larger file is listed `unscanned`, and a binary one is not read. A `synced`
  record proves the step 10 checks over the paths the move changed and the dirty paths outside it; a path that was
  clean before the sync and outside the move is not fingerprinted, because nothing here or in read-tree writes one.

  Dot-source:  . (Join-Path $repoRoot 'lib\checkout-sync.ps1')
  Self-test:   powershell -NoProfile -File lib\checkout-sync.ps1 -SelfTest   (runs lib\test-checkout-sync.ps1)

  NO param() BLOCK, DELIBERATELY - the rule lib\pipeline-commit.ps1 states: dot-sourced under PS 5.1 a param() block
  runs in the caller's scope and would reset the caller's own -SelfTest.
#>
# Its declared inputs (lib\gate-input-key.ps1): the self-test is the suite beside it, which builds every repo it reads
# under %TEMP% and reads one file of this checkout, grocery\capture-run.ps1, for the startup-file drift case. The code
# it loads is this file, the suite, and the four libraries they dot-source (each walked for what IT loads). capture-run
# is read as TEXT - copied and AST-scanned, never loaded or run - so it is hashed and not walked: walking it put 2,968
# files in this key, 1,202 of them gitignored boards and cards, and the key moved on 201 of 287 commits (2026-09-24).
# gate-inputs: lib\checkout-sync.ps1, lib\test-checkout-sync.ps1, lib\git-repo-env.ps1, lib\git-blob-lib.ps1, lib\atomic-write.ps1, lib\append-line.ps1
# gate-inputs-text: grocery\capture-run.ps1
$__csSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

. (Join-Path $PSScriptRoot 'git-blob-lib.ps1')   # Invoke-GitCaptured, Get-CommittedBlobBytes, ConvertTo-GitArgString
. (Join-Path $PSScriptRoot 'atomic-write.ps1')   # Write-TcAtomicFile: the state file is read lock-free
. (Join-Path $PSScriptRoot 'append-line.ps1')    # Add-TcLine: the log row is one unbuffered append
$script:TcCsLibFile = $PSCommandPath
$script:TcCsLibBlob = ''

# capture-run.ps1 and every file it dot-sources, repo-relative with forward slashes. See STARTUP FILES above.
$script:TcCheckoutSyncStartupFiles = @(
  'grocery/capture-run.ps1',
  'grocery/alert-lib.ps1',
  'grocery/capture-run-lock-lib.ps1',
  'grocery/capture-policy-lib.ps1',
  'grocery/commit-size-lib.ps1',
  'grocery/fanout-lib.ps1',
  'grocery/native-lib.ps1',
  'grocery/run-log-lib.ps1',
  'lib/atomic-write.ps1',
  'lib/bot-paths.ps1',
  'lib/chain-code-currency.ps1',
  'lib/chain-verdict-lib.ps1',
  'lib/checkout-sync.ps1',
  'lib/git-blob-lib.ps1',
  'lib/json-io.ps1',
  'lib/pipeline-commit.ps1'
)

# The seven operations 1c waits on, each resolved through `git rev-parse --git-path`.
$script:TcCsInProgress = @('rebase-merge', 'rebase-apply', 'MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'sequencer', 'BISECT_LOG')
$script:TcCsZeroSha = '0000000000000000000000000000000000000000'

# ---- GIT, ALWAYS THROUGH Invoke-GitCaptured ------------------------------------------------------------------------
# capture-run runs under EAP=Stop, where any redirect of a native child's stderr is a terminating throw; this never
# redirects and never throws. --no-optional-locks keeps a read from refreshing the index (F4's zero-writes case reads
# the index's md5); --literal-pathspecs keeps a path holding '[' from reading as a glob; quotePath=false plus -z keeps
# a path whole (a DEL byte is C-quoted even with quotePath=false, measured on git 2.54.0.windows.1).
function Invoke-TcCsGit {
  param([string]$Repo, [string[]]$GitArgs)
  $g = Invoke-GitCaptured -Repo $Repo -GitArgs (@('--no-optional-locks', '--literal-pathspecs', '-c', 'core.quotePath=false') + @($GitArgs))
  return [pscustomobject]@{ rc = [int]$g.rc; out = ([string]$g.stdout).Trim(); raw = [string]$g.stdout; err = ([string]$g.stderr).Trim() }
}

# The same, with a WALL-CLOCK BOUND, for the one command that talks to the network (review finding 9): a stalled remote
# must not hold the run, and capture-run's mutex, before any capture starts. On the bound the whole process tree is
# killed (git fetch runs a transport child), rc is -2 and timedOut is true. Both pipes drain while the child runs.
# The tree is the one taskkill /T walks: git's transports (git-remote-https, ssh, upload-pack) are direct children of
# git.exe and are reached; a grandchild an MSYS shell forks and then execs is orphaned from it and is not (measured with
# the self-test's `sleep` uploadpack, which ends on its own).
function Invoke-TcCsGitTimed {
  param([string]$Repo, [string[]]$GitArgs, [int]$TimeoutSec)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'git'
  $psi.Arguments = ConvertTo-GitArgString -GitArgs (@('-C', $Repo, '--no-optional-locks', '-c', 'core.quotePath=false') + @($GitArgs))
  $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false); $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
  $p = $null
  try {
    $p = [System.Diagnostics.Process]::Start($psi)
    $tOut = $p.StandardOutput.ReadToEndAsync(); $tErr = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit([Math]::Max(1, $TimeoutSec) * 1000)) {
      $kp = New-Object System.Diagnostics.ProcessStartInfo('taskkill.exe', ('/T /F /PID ' + $p.Id))
      $kp.UseShellExecute = $false; $kp.CreateNoWindow = $true; $kp.RedirectStandardOutput = $true; $kp.RedirectStandardError = $true
      $k = [System.Diagnostics.Process]::Start($kp)
      $kE = $k.StandardError.ReadToEndAsync(); [void]$k.StandardOutput.ReadToEnd(); [void]$kE.Wait(10000); $k.WaitForExit(); $krc = $k.ExitCode; $k.Dispose()
      [void]$p.WaitForExit(10000)
      return [pscustomobject]@{ rc = -2; timedOut = $true; out = ''; raw = ''; err = ('git ' + $GitArgs[0] + ' was still running after ' + $TimeoutSec + ' s and its process tree was killed (taskkill rc ' + $krc + ')') }
    }
    [void]$tOut.Wait(10000); [void]$tErr.Wait(10000)
    return [pscustomobject]@{ rc = [int]$p.ExitCode; timedOut = $false; out = ([string]$tOut.Result).Trim(); raw = [string]$tOut.Result; err = ([string]$tErr.Result).Trim() }
  } catch {
    return [pscustomobject]@{ rc = -1; timedOut = $false; out = ''; raw = ''; err = ('could not run git: ' + $_.Exception.Message) }
  } finally { if ($p) { $p.Dispose() } }
}

# Non-empty NUL-separated tokens, as an array that never unrolls to a scalar.
function Split-TcCsNul([string]$Raw) {
  $toks = [System.Collections.Generic.List[string]]::new()
  if ($Raw) { foreach ($t in $Raw.Split([char]0)) { if ($t.Length) { $toks.Add($t) } } }
  return , $toks.ToArray()
}

# The same git command over a pathspec list, chunked so no command line nears the 32K limit. Returns the worst rc
# and every chunk's stderr.
function Invoke-TcCsGitPaths {
  param([string]$Repo, [string[]]$Pre, [string[]]$Paths)
  $worst = 0; $errs = [System.Collections.Generic.List[string]]::new(); $outs = [System.Collections.Generic.List[string]]::new()
  $chunk = [System.Collections.Generic.List[string]]::new(); $len = 0
  $all = @(@($Paths) | Where-Object { $_ })
  for ($i = 0; $i -le $all.Count; $i++) {
    $flush = ($i -eq $all.Count) -or (($len + ([string]$all[$i]).Length) -gt 20000 -and $chunk.Count)
    if ($flush -and $chunk.Count) {
      $g = Invoke-TcCsGit -Repo $Repo -GitArgs (@($Pre) + @('--') + $chunk.ToArray())
      if ($g.rc -ne 0 -and $worst -eq 0) { $worst = $g.rc }
      if ($g.err) { $errs.Add($g.err) }
      $outs.Add($g.raw)
      $chunk.Clear(); $len = 0
    }
    if ($i -lt $all.Count) { $chunk.Add([string]$all[$i]); $len += ([string]$all[$i]).Length + 3 }
  }
  return [pscustomobject]@{ rc = $worst; err = ($errs -join "`n"); raw = ($outs -join '') }
}

function Get-TcCsGitPath([string]$Repo, [string]$Name) {
  $g = Invoke-TcCsGit -Repo $Repo -GitArgs @('rev-parse', '--path-format=absolute', '--git-path', $Name)
  if ($g.rc -ne 0 -or -not $g.out) { return '' }
  return [IO.Path]::GetFullPath(($g.out -replace '/', '\'))
}

# The operations 1c waits on that are present now, resolved in ONE rev-parse (it answers each --git-path in order).
function Get-TcCsOperationsInProgress([string]$Repo) {
  $a = [System.Collections.Generic.List[string]]::new(); $a.Add('rev-parse'); $a.Add('--path-format=absolute')
  foreach ($n in $script:TcCsInProgress) { $a.Add('--git-path'); $a.Add($n) }
  $g = Invoke-TcCsGit -Repo $Repo -GitArgs $a.ToArray()
  $lines = @($g.out -split "`r?`n" | Where-Object { $_ })
  if ($g.rc -ne 0 -or $lines.Count -ne $script:TcCsInProgress.Count) { throw ('git rev-parse --git-path answered ' + $lines.Count + ' of ' + $script:TcCsInProgress.Count + ' (rc ' + $g.rc + '): ' + $g.err) }
  $present = [System.Collections.Generic.List[string]]::new()
  for ($i = 0; $i -lt $lines.Count; $i++) { if (Test-Path -LiteralPath ([IO.Path]::GetFullPath(($lines[$i] -replace '/', '\')))) { $present.Add($script:TcCsInProgress[$i]) } }
  return , $present.ToArray()
}

function Test-TcCsOwnedPath([string]$Path, [string[]]$Owned) {
  foreach ($o in @($Owned)) {
    $t = ([string]$o).Trim().TrimEnd('/')
    if (-not $t) { continue }
    if ([string]::Equals($Path, $t, [StringComparison]::Ordinal)) { return $true }
    if ($Path.StartsWith($t + '/', [StringComparison]::Ordinal)) { return $true }
  }
  return $false
}

function Get-TcCsFullPath([string]$Repo, [string]$Rel) { return (Join-Path $Repo ($Rel -replace '/', '\')) }

# `git status -z --porcelain=v2` as path -> @{ codes; lines }. codes are v1-style XY ('.' read as ' ', '??' for
# untracked); a path with more than one entry (a staged deletion beside an untracked copy) has more than one code.
function Get-TcCsStatus([string]$Repo) {
  $g = Invoke-TcCsGit -Repo $Repo -GitArgs @('status', '-z', '--porcelain=v2', '--untracked-files=all', '--no-renames')
  $map = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
  if ($g.rc -ne 0) { return [pscustomobject]@{ ok = $false; map = $map; why = ('git status exited ' + $g.rc + ': ' + $g.err) } }
  $toks = Split-TcCsNul $g.raw
  for ($i = 0; $i -lt $toks.Count; $i++) {
    $t = $toks[$i]; $path = ''; $code = ''
    # A header line is skipped HERE, never inside the switch: `continue` in a switch only leaves the switch.
    if ($t[0] -eq '#') { continue }
    switch ($t.Substring(0, 1)) {
      '1' { $parts = $t.Split(' ', 9); $code = $parts[1]; $path = $parts[8] }
      '2' { $parts = $t.Split(' ', 10); $code = $parts[1]; $path = $parts[9]; $i++ }   # a rename entry carries its origin next; --no-renames makes none
      'u' { $parts = $t.Split(' ', 11); $code = $parts[1]; $path = $parts[10] }
      '?' { $code = '??'; $path = $t.Substring(2) }
      '!' { $code = '!!'; $path = $t.Substring(2) }
      default { throw ('unknown git status v2 entry: ' + $t) }
    }
    if ($code.Length -eq 2 -and $code -ne '??' -and $code -ne '!!') { $code = $code.Replace('.', ' ') }
    if (-not $map.ContainsKey($path)) { $map[$path] = [pscustomobject]@{ codes = [System.Collections.Generic.List[string]]::new(); lines = [System.Collections.Generic.List[string]]::new() } }
    $map[$path].codes.Add($code); $map[$path].lines.Add($t)
  }
  return [pscustomobject]@{ ok = $true; map = $map; why = '' }
}

# One path's fingerprint: its porcelain v2 line(s), its length and its LastWriteTimeUtc ticks, or 'absent'.
function Get-TcCsFingerprint([string]$Repo, [string]$Path, $StatusMap) {
  $lines = ''
  if ($StatusMap.ContainsKey($Path)) { $lines = ($StatusMap[$Path].lines -join '|') }
  $full = Get-TcCsFullPath $Repo $Path
  $fi = New-Object IO.FileInfo($full)
  $disk = if ($fi.Exists) { ([string]$fi.Length + '|' + [string]$fi.LastWriteTimeUtc.Ticks) } else { 'absent' }
  return ($lines + '#' + $disk)
}
function Get-TcCsDiskPart([string]$Fingerprint) { $k = $Fingerprint.LastIndexOf('#'); return $Fingerprint.Substring($k + 1) }

# `git hash-object` of every existing path in one call per chunk: path -> blob. A missing path is absent from the map.
function Get-TcCsDiskBlobs([string]$Repo, [string[]]$Paths) {
  $map = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
  $exist = @(@($Paths) | Where-Object { [IO.File]::Exists((Get-TcCsFullPath $Repo $_)) })
  $chunk = [System.Collections.Generic.List[string]]::new(); $len = 0
  for ($i = 0; $i -le $exist.Count; $i++) {
    $flush = ($i -eq $exist.Count) -or (($len + ([string]$exist[$i]).Length) -gt 20000 -and $chunk.Count)
    if ($flush -and $chunk.Count) {
      $g = Invoke-TcCsGit -Repo $Repo -GitArgs (@('hash-object', '--') + $chunk.ToArray())
      if ($g.rc -ne 0) { throw ('git hash-object exited ' + $g.rc + ': ' + $g.err) }
      $shas = @($g.out -split "`r?`n" | Where-Object { $_ })
      if ($shas.Count -ne $chunk.Count) { throw ('git hash-object returned ' + $shas.Count + ' blob(s) for ' + $chunk.Count + ' path(s)') }
      for ($k = 0; $k -lt $chunk.Count; $k++) { $map[$chunk[$k]] = $shas[$k] }
      $chunk.Clear(); $len = 0
    }
    if ($i -lt $exist.Count) { $chunk.Add([string]$exist[$i]); $len += ([string]$exist[$i]).Length + 3 }
  }
  return $map
}

# `git diff-tree -r -z --no-renames A B` as an ordered list of @{ path; st; oldBlob; newBlob; oldMode; newMode }.
function Get-TcCsTreeDiff([string]$Repo, [string]$A, [string]$B) {
  $g = Invoke-TcCsGit -Repo $Repo -GitArgs @('diff-tree', '-r', '-z', '--no-renames', $A, $B)
  if ($g.rc -ne 0) { throw ('git diff-tree ' + $A + ' ' + $B + ' exited ' + $g.rc + ': ' + $g.err) }
  $toks = Split-TcCsNul $g.raw
  $out = [System.Collections.Generic.List[object]]::new()
  for ($i = 0; $i + 1 -lt $toks.Count; $i += 2) {
    $h = $toks[$i].TrimStart(':').Split(' ')
    if ($h.Count -lt 5) { throw ('unreadable diff-tree entry: ' + $toks[$i]) }
    $out.Add([pscustomobject]@{ path = $toks[$i + 1]; st = $h[4].Substring(0, 1); oldMode = $h[0]; newMode = $h[1]; oldBlob = $h[2]; newBlob = $h[3] })
  }
  return , $out.ToArray()
}

# ---- CONFLICT MARKERS -----------------------------------------------------------------------------------------------
# Ordered triples over BYTES: a line `^<{7}( |$)`, later `^={7}$`, later `^>{7}( |$)`. A CR before the LF is read as the
# line end, because a checkout under core.autocrlf=true writes CRLF. A lone `=======` (a setext underline) is never a
# triple, and a start marker restarts the search.
function Get-TcCsMarkerTriples([byte[]]$Bytes) {
  if ($null -eq $Bytes -or $Bytes.Length -lt 7) { return 0 }
  $n = 0; $state = 0; $i = 0; $len = $Bytes.Length
  while ($i -lt $len) {
    $c = $Bytes[$i]
    if (($c -eq 60 -or $c -eq 61 -or $c -eq 62) -and ($i + 7) -le $len) {
      $run = $true
      for ($k = 1; $k -lt 7; $k++) { if ($Bytes[$i + $k] -ne $c) { $run = $false; break } }
      if ($run) {
        $nx = -1; if (($i + 7) -lt $len) { $nx = [int]$Bytes[$i + 7] }
        $eol = ($nx -eq -1) -or ($nx -eq 10) -or ($nx -eq 13 -and ((($i + 8) -ge $len) -or $Bytes[$i + 8] -eq 10))
        $isMark = if ($c -eq 61) { $eol } else { $eol -or ($nx -eq 32) }
        if ($isMark) {
          if ($c -eq 60) { $state = 1 }
          elseif ($c -eq 61 -and $state -eq 1) { $state = 2 }
          elseif ($c -eq 62 -and $state -eq 2) { $n++; $state = 0 }
        }
      }
    }
    $j = [Array]::IndexOf($Bytes, [byte]10, $i)
    if ($j -lt 0) { break }
    $i = $j + 1
  }
  return $n
}

# ---- WORKTREE-FORM BYTES -------------------------------------------------------------------------------------------
# A blob as the WORKING TREE holds it (smudge and eol applied): the shared checkout runs core.autocrlf=true, so a raw
# blob is LF while the file beside it is CRLF, and a merge between the two would conflict on every line.
function Get-TcCsWorktreeFormBytes([string]$Repo, [string]$Spec) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'git'
  $psi.Arguments = ConvertTo-GitArgString -GitArgs @('-C', $Repo, 'cat-file', '--filters', $Spec)
  $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  try {
    $ms = New-Object System.IO.MemoryStream
    $tErr = $p.StandardError.ReadToEndAsync(); $p.StandardOutput.BaseStream.CopyTo($ms); $tErr.Wait(); $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw ('git cat-file --filters ' + $Spec + ' exited ' + $p.ExitCode) }
    return , $ms.ToArray()
  } finally { $p.Dispose() }
}

# A file's bytes through a stream that shares Read, Write AND Delete, so a lane writing the file at that moment, or a
# replace over it, is never refused by this read (ops-and-gates: a lock-free reader can cost a writer its write, and
# [IO.File]::ReadAllBytes shares Read only). -Count > 0 reads at most that many bytes from the start.
function Read-TcCsSharedBytes([string]$Path, [long]$Count = 0) {
  $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]'ReadWrite, Delete'))
  try {
    $want = if ($Count -gt 0) { [Math]::Min($Count, $fs.Length) } else { $fs.Length }
    $buf = New-Object byte[] ([int]$want)
    $got = 0
    while ($got -lt $want) { $n = $fs.Read($buf, $got, ([int]$want - $got)); if ($n -le 0) { break }; $got += $n }
    if ($got -lt $want) { $short = New-Object byte[] $got; [Array]::Copy($buf, $short, $got); return , $short }
    return , $buf
  } finally { $fs.Dispose() }
}

function Test-TcCsBytePrefix([byte[]]$Prefix, [byte[]]$Whole) {
  if ($null -eq $Prefix -or $null -eq $Whole -or $Whole.Length -lt $Prefix.Length) { return $false }
  for ($i = 0; $i -lt $Prefix.Length; $i++) { if ($Prefix[$i] -ne $Whole[$i]) { return $false } }
  return $true
}

# ---- THE LOCAL COMMITS, REPLAYED OFF TO THE SIDE -------------------------------------------------------------------
# Replays Upstream..Tip onto -Onto (default Upstream) with -X theirs, exactly the tree `git rebase -X theirs` builds,
# touching neither the index nor the working tree. Authors are kept; the committer is the bot, as the old tail's was.
# Returns @{ ok; tip; replayed; dropped; why }.
function Invoke-TcCsLocalCommitReplay {
  param([string]$Repo, [string]$Upstream, [string]$Tip, [string]$Onto = '', [string]$BotName, [string]$BotEmail)
  $list = Invoke-TcCsGit -Repo $Repo -GitArgs @('rev-list', '--reverse', '--topo-order', '--parents', ($Upstream + '..' + $Tip))
  if ($list.rc -ne 0) { return @{ ok = $false; why = ('git rev-list exited ' + $list.rc + ': ' + $list.err) } }
  $nb = if ($Onto) { $Onto } else { $Upstream }
  $n = 0; $dropped = 0
  $msgFile = Join-Path $env:TEMP ('tc-cs-msg-' + [guid]::NewGuid().ToString('N') + '.txt')
  $envNames = @('GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_AUTHOR_DATE', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL')
  try {
    foreach ($ln in @($list.out -split "`r?`n" | Where-Object { $_ })) {
      $parts = @($ln -split ' ')
      if ($parts.Count -ne 2) { return @{ ok = $false; why = ('local commit ' + $parts[0].Substring(0, 9) + ' is a merge; it is never linearised') } }
      $c = $parts[0]; $cp = $parts[1]
      $mt = Invoke-TcCsGit -Repo $Repo -GitArgs @('merge-tree', '--write-tree', ('--merge-base=' + $cp), '-X', 'theirs', $nb, $c)
      if ($mt.rc -ne 0) {
        $first = @($mt.out -split "`r?`n" | Where-Object { $_ -match 'CONFLICT' } | Select-Object -First 1)
        return @{ ok = $false; why = ('local commit ' + $c.Substring(0, 9) + ' conflicts with upstream even under -X theirs (merge-tree rc ' + $mt.rc + ')' + $(if ($first.Count) { ': ' + $first[0].Trim() } else { '' })) }
      }
      $tree = @($mt.out -split "`r?`n")[0].Trim()
      $nbTree = (Invoke-TcCsGit -Repo $Repo -GitArgs @('rev-parse', ($nb + '^{tree}'))).out
      if ([string]::Equals($tree, $nbTree, [StringComparison]::Ordinal)) { $dropped++; continue }
      $meta = Invoke-TcCsGit -Repo $Repo -GitArgs @('log', '-1', '--format=%an%x00%ae%x00%ad', '--date=raw', $c)
      $m = @($meta.out -split [char]0)
      $body = (Invoke-GitCaptured -Repo $Repo -GitArgs @('log', '-1', '--format=%B', $c)).stdout
      [IO.File]::WriteAllText($msgFile, [string]$body, (New-Object Text.UTF8Encoding($false)))
      $saved = @{}; foreach ($v in $envNames) { $saved[$v] = [Environment]::GetEnvironmentVariable($v) }
      try {
        [Environment]::SetEnvironmentVariable('GIT_AUTHOR_NAME', $m[0]); [Environment]::SetEnvironmentVariable('GIT_AUTHOR_EMAIL', $m[1])
        [Environment]::SetEnvironmentVariable('GIT_AUTHOR_DATE', $m[2])
        [Environment]::SetEnvironmentVariable('GIT_COMMITTER_NAME', $BotName); [Environment]::SetEnvironmentVariable('GIT_COMMITTER_EMAIL', $BotEmail)
        $ct = Invoke-TcCsGit -Repo $Repo -GitArgs @('commit-tree', $tree, '-p', $nb, '-F', $msgFile)
      } finally { foreach ($v in $envNames) { [Environment]::SetEnvironmentVariable($v, $saved[$v]) } }
      if ($ct.rc -ne 0) { return @{ ok = $false; why = ('git commit-tree exited ' + $ct.rc + ': ' + $ct.err) } }
      $nb = $ct.out; $n++
    }
  } finally { Remove-Item -LiteralPath $msgFile -Force -ErrorAction SilentlyContinue }
  return @{ ok = $true; tip = $nb; replayed = $n; dropped = $dropped; why = '' }
}

# ---- STARTUP FILES -------------------------------------------------------------------------------------------------
# Every file a script dot-sources as `. (Join-Path <base> '<literal>')`, repo-relative, plus the script itself. Only
# the base spellings capture-run uses are read ($PSScriptRoot, $root, $here for the script's folder; its parent through
# Split-Path, $repo or $repoRoot); any other spelling comes back in `unresolved` and ok is false, never guessed.
function Get-TcCaptureRunDotSources {
  param([Parameter(Mandatory)][string]$ScriptPath, [string]$ScriptRelDir = 'grocery', [string]$ScriptRelName = 'capture-run.ps1')
  $toks = $null; $errs = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$toks, [ref]$errs)
  $files = New-Object System.Collections.Generic.SortedSet[string] ([StringComparer]::Ordinal)
  $unres = [System.Collections.Generic.List[string]]::new()
  if ($errs -and @($errs).Count) { return [pscustomobject]@{ ok = $false; files = @(); unresolved = @('the script does not parse: ' + $errs[0].Message) } }
  [void]$files.Add(($ScriptRelDir + '/' + $ScriptRelName))
  $here = $ScriptRelDir.TrimEnd('/'); $parent = ''
  $k = $here.LastIndexOf('/'); if ($k -ge 0) { $parent = $here.Substring(0, $k) }
  $dots = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] -and $a.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot }, $true)
  foreach ($d in $dots) {
    $e0 = $d.CommandElements[0]
    $ok = $false
    if ($e0 -is [System.Management.Automation.Language.ParenExpressionAst]) {
      $cmds = @($e0.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true))
      $jp = $cmds | Where-Object { $_.GetCommandName() -eq 'Join-Path' } | Select-Object -First 1
      if ($jp -and $jp.CommandElements.Count -eq 3 -and $jp.CommandElements[2] -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        $base = (($jp.CommandElements[1].Extent.Text) -replace '\s+', ' ').Trim()
        $lit = ([string]$jp.CommandElements[2].Value) -replace '\\', '/'
        $dir = $null
        switch -Regex ($base) {
          '^\$(PSScriptRoot|root|here)$' { $dir = $here }
          '^\(Split-Path (\$(PSScriptRoot|root) -Parent|-Parent \$(PSScriptRoot|root))\)$' { $dir = $parent }
          '^\$(repo|repoRoot)$' { $dir = $parent }
          default { $dir = $null }   # an unread spelling: reported below as unresolved, never guessed
        }
        if ($null -ne $dir) {
          $rel = if ($dir) { $dir + '/' + $lit } else { $lit }
          [void]$files.Add($rel); $ok = $true
        }
      }
    }
    if (-not $ok) { $unres.Add(('line ' + $d.Extent.StartLineNumber + ': ' + $d.Extent.Text)) }
  }
  return [pscustomobject]@{ ok = ($unres.Count -eq 0); files = @($files); unresolved = $unres.ToArray() }
}

# Parse a startup file AT a commit, from the object database, before anything moves to it. '' when it parses.
function Test-TcCsParsesAt([string]$Repo, [string]$Commit, [string]$Path) {
  $g = Invoke-TcCsGit -Repo $Repo -GitArgs @('cat-file', 'blob', ($Commit + ':' + $Path))
  if ($g.rc -ne 0) { return ('missing at ' + $Commit.Substring(0, 9)) }
  $text = [string]$g.raw
  if ($text.Length -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
  $toks = $null; $errs = $null
  [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$toks, [ref]$errs)
  if ($errs -and @($errs).Count) { return ('line ' + $errs[0].Extent.StartLineNumber + ': ' + $errs[0].Message) }
  return ''
}

function Get-TcCsLibBlob {
  if ($script:TcCsLibBlob) { return $script:TcCsLibBlob }
  try {
    $g = Invoke-GitCaptured -Repo (Split-Path -Parent $script:TcCsLibFile) -GitArgs @('hash-object', '--', $script:TcCsLibFile)
    if ($g.rc -eq 0) { $script:TcCsLibBlob = ([string]$g.stdout).Trim() }
  } catch { }
  return $script:TcCsLibBlob
}

# ==== THE SYNC =======================================================================================================
function Invoke-TcCheckoutSync {
  param(
    [Parameter(Mandatory)][string]$Repo,
    [ValidateSet('start', 'tail')][string]$Phase = 'start',
    # The paths the bot owns (lib\bot-paths.ps1), as exact paths or directory prefixes, repo-relative with '/'.
    [string[]]$OwnedPaths = @(),
    # repo path -> blob the pipeline journal says the bot wrote (Get-PipelineOwnBlobs, W3.2). Only a path both owned
    # AND whose bytes still hash to this blob is the bot's own; everything else dirty is FOREIGN.
    [hashtable]$OwnBlobs = $null,
    # Where displaced bytes go. MANDATORY, with no default: the caller owns that directory, and this library naming
    # another module's internals is the coupling ops\audit-cross-module-reach.ps1 ratchets. capture-run passes its
    # own out\untracked-quarantine, which .gitignore ignores (W0.1); a directory git would list must not be passed.
    [Parameter(Mandatory)][string]$QuarantineRoot,
    [string[]]$StartupFiles = $script:TcCheckoutSyncStartupFiles,
    # The clock seam: dated tree names, the autostash age and the kill-switch page date read it.
    [datetime]$Now = (Get-Date),
    [string]$Kind = '',
    # The commit this run just made through a private index; its leftover index entries are resynced (step 1g).
    [string]$BotCommit = '',
    [int]$IndexLockWaitSec = 60,
    [int]$InProgressWaitSec = 120,
    [int]$AutostashAgeSec = 300,
    [int]$HeldRetrySec = 2,
    [int]$PollSec = 5,
    [int]$FetchAttempts = 3,
    [int]$FetchRetrySec = 5,
    # One fetch attempt's wall-clock bound, killed with its process tree on expiry (review finding 9).
    [int]$FetchTimeoutSec = 300,
    [long]$MarkerScanMaxBytes = 52428800,
    [int]$NulProbeBytes = 8000,
    [string]$Remote = 'origin',
    [string]$Branch = 'main',
    [string]$BotName = 'smp-pipeline-bot',
    [string]$BotEmail = 'actions@users.noreply.github.com',
    # TEST SEAMS, null in production. BeforeMove runs after the displacements and before read-tree (a session writing
    # mid-sync, or a reader opening a file); AfterReadTree right after the FIRST read-tree, whatever its rc; BeforeRef
    # between the tree move and update-ref (a lane committing in that window).
    [scriptblock]$BeforeMove = $null,
    [scriptblock]$AfterReadTree = $null,
    [scriptblock]$BeforeRef = $null
  )
  $clock = [Diagnostics.Stopwatch]::StartNew()
  $rec = [ordered]@{
    ts = $Now.ToString('o'); pid = $PID; kind = $Kind; phase = $Phase; outcome = ''; class = ''; why = ''; page = $false
    H0 = ''; O = ''; NEW = ''; behind = 0; behind_after = 0; ahead = 0; replayed = 0; dropped = 0; changed = 0
    quarantined = @(); set_aside = @(); merged = @(); already_upstream = @(); own_deleted = @(); foreign = @()
    partial_target = ''; partial_blocker = ''; held = ''; unscanned = @(); startup_changed = $false; startup_files = @()
    index_resynced = @(); cas_recovered = ''; notes = @(); tree = ''; sec = 0; lib_blob = ''; logged = $false
  }
  $ctx = @{ commonDir = ''; log = $true; preSetAside = [System.Collections.Generic.List[string]]::new(); leftover = $null; leftoverText = '' }
  if (-not $OwnBlobs) { $OwnBlobs = @{} }
  $stage = 'plan'

  # ---- the one exit: fill the record, write the state and the log row, return ------------------------------------
  function Complete-TcCsSync([string]$Outcome, [string]$Class, [string]$Why) {
    $rec.outcome = $Outcome; $rec.class = $Class; $rec.why = $Why
    switch ($Outcome) {
      'current' { $rec.page = $false }
      'synced' { $rec.page = $false }
      'skipped' { $rec.page = $false }
      'disabled' { }   # decided by the caller of this function, once a date
      'partial' { $rec.page = $true }
      'blocked' { $rec.page = $true }
      'degraded' { $rec.page = $true }   # class fetch: once a date, decided against the state file below
      'failed' { $rec.page = $true }
      default { throw ('unknown checkout-sync outcome: ' + $Outcome) }
    }
    $resolved = ($Outcome -eq 'current') -or ($Outcome -eq 'synced') -or ($Outcome -eq 'partial')
    # A step 1d/1e set-aside is a write, so a clean outcome that made one says so and pages (review finding 2).
    if ($ctx.preSetAside.Count -and $resolved) {
      $rec.page = $true
      $rec.why = $rec.why + '; before the move the sync set aside and restored from HEAD the pipeline''s own conflicted path(s): ' + ($ctx.preSetAside -join ', ')
    }
    # A leftover intent this run did not resolve is named on every outcome that is not clean, and KEPT (finding 7).
    if ($ctx.leftover -and -not $resolved -and $ctx.leftoverText) { $rec.why = $rec.why + ' [' + $ctx.leftoverText + ']' }
    $rec.sec = [math]::Round($clock.Elapsed.TotalSeconds, 2)
    $rec.lib_blob = Get-TcCsLibBlob
    if ($ctx.log -and $ctx.commonDir) {
      $stateFile = Join-Path $ctx.commonDir 'tc-checkout-sync.json'
      $doc = Read-TcCsState $stateFile
      if ($Outcome -eq 'degraded' -and $Class -eq 'fetch') {
        $today = $Now.ToString('yyyy-MM-dd')
        $rec.page = -not [string]::Equals([string]$doc.fetch_paged_on, $today, [StringComparison]::Ordinal)
        if ($rec.page) { $doc.fetch_paged_on = $today }
      }
      # THE LOG ROW FIRST AND ON ITS OWN (review finding 10): a held state file must not cost the append-only record.
      $rec.logged = $true
      try { [void](Add-TcLine -Path (Join-Path $ctx.commonDir 'tc-checkout-sync-log.jsonl') -Text ($rec | ConvertTo-Json -Depth 6 -Compress)) }
      catch { $rec.logged = $false; $rec.notes = @($rec.notes) + @('the log row could not be appended: ' + $_.Exception.Message) }
      try {
        $doc.last = $rec
        # A throw mid-move keeps THIS run's intent (step 1c2 of the next run can finish it); an unresolved leftover is
        # kept; everything else clears.
        if ($Outcome -ne 'disabled' -and -not $ctx.ContainsKey('keepOwnIntent')) { $doc.intent = $(if ($ctx.leftover -and -not $resolved) { $ctx.leftover } else { $null }) }
        [void](Write-TcAtomicFile -Path $stateFile -Text ($doc | ConvertTo-Json -Depth 6) -NoBom)
      } catch { $rec.notes = @($rec.notes) + @('the state file could not be replaced: ' + $_.Exception.Message) }
    }
    return [pscustomobject]$rec
  }
  # Where the undo copies are, or that no dated tree was made because nothing was displaced.
  function Get-TcCsUndoText { if ($rec.tree) { return ('The undo copies are kept in ' + $rec.tree) }; return 'Nothing was displaced, so no dated tree was made' }

  try {
    # ---- 0. GUARDS --------------------------------------------------------------------------------------------------
    if ($env:GIT_DIR -or $env:GIT_WORK_TREE) { $ctx.log = $false; return (Complete-TcCsSync 'skipped' 'environment' 'GIT_DIR or GIT_WORK_TREE is set: a hook environment names another repository, so nothing is synced or logged') }
    $gd = Invoke-TcCsGit -Repo $Repo -GitArgs @('rev-parse', '--path-format=absolute', '--git-dir', '--git-common-dir')
    $gdl = @($gd.out -split "`r?`n" | Where-Object { $_ })
    if ($gd.rc -ne 0 -or $gdl.Count -lt 2) { $ctx.log = $false; return (Complete-TcCsSync 'failed' 'environment' ('not a git checkout: rev-parse exited ' + $gd.rc + ' ' + $gd.err)) }
    $gitDir = [IO.Path]::GetFullPath(($gdl[0] -replace '/', '\')).TrimEnd('\')
    $ctx.commonDir = [IO.Path]::GetFullPath(($gdl[1] -replace '/', '\')).TrimEnd('\')
    if (-not [string]::Equals($gitDir, $ctx.commonDir, [StringComparison]::OrdinalIgnoreCase)) { $ctx.log = $false; return (Complete-TcCsSync 'skipped' 'linked-worktree' ('a linked worktree (' + $gitDir + '): the bot syncs only the main checkout, and its log is not this checkout''s to write')) }
    if ($env:GIT_INDEX_FILE) { return (Complete-TcCsSync 'failed' 'environment' ('GIT_INDEX_FILE is still set (' + $env:GIT_INDEX_FILE + '): a private index was not released, and a sync under it would move a tree nobody is looking at; nothing was written')) }
    $kill = Join-Path $ctx.commonDir 'tc-checkout-sync.disabled'
    if (Test-Path -LiteralPath $kill) {
      $stateFile = Join-Path $ctx.commonDir 'tc-checkout-sync.json'
      $doc = Read-TcCsState $stateFile
      $today = $Now.ToString('yyyy-MM-dd')
      $rec.page = -not [string]::Equals([string]$doc.disabled_paged_on, $today, [StringComparison]::Ordinal)
      if ($rec.page) {
        $doc.disabled_paged_on = $today
        try { [void](Write-TcAtomicFile -Path $stateFile -Text ($doc | ConvertTo-Json -Depth 6) -NoBom) } catch { }
      }
      $since = (Get-Item -LiteralPath $kill).LastWriteTime.ToString('s')
      return (Complete-TcCsSync 'disabled' 'kill-switch' ('the kill switch ' + $kill + ' is present (since ' + $since + '); nothing was synced'))
    }

    # ---- 1. IN PROGRESS, BEFORE THE BRANCH CHECK --------------------------------------------------------------------
    $pollMs = [Math]::Max(100, $PollSec * 1000)
    # 1a. index.lock: waited on, never deleted.
    $lock = Get-TcCsGitPath $Repo 'index.lock'
    if ($lock -and (Test-Path -LiteralPath $lock)) {
      $w = [Diagnostics.Stopwatch]::StartNew()
      while ((Test-Path -LiteralPath $lock) -and $w.Elapsed.TotalSeconds -lt $IndexLockWaitSec) { Start-Sleep -Milliseconds $pollMs }
      if (Test-Path -LiteralPath $lock) {
        $age = [math]::Round(($Now.ToUniversalTime() - (Get-Item -LiteralPath $lock).LastWriteTimeUtc).TotalSeconds)
        return (Complete-TcCsSync 'degraded' 'index-lock' ('index.lock is present and ' + $age + ' s old after a ' + $IndexLockWaitSec + ' s wait; another git command holds the index, and the lock is never deleted here'))
      }
    }
    # 1b. The E1 shape: a rebase-merge directory holding ONLY an autostash, left by a rebase that died at reset --hard.
    $rm = Get-TcCsGitPath $Repo 'rebase-merge'
    if ($rm -and (Test-Path -LiteralPath $rm -PathType Container)) {
      $entries = @(Get-ChildItem -LiteralPath $rm -Force)
      if ($entries.Count -eq 1 -and $entries[0].Name -eq 'autostash' -and -not $entries[0].PSIsContainer) {
        $newest = (Get-Item -LiteralPath $rm -Force).LastWriteTimeUtc
        if ($entries[0].LastWriteTimeUtc -gt $newest) { $newest = $entries[0].LastWriteTimeUtc }
        $age = ($Now.ToUniversalTime() - $newest).TotalSeconds
        if ($age -gt $AutostashAgeSec) {
          $sha = ([IO.File]::ReadAllText($entries[0].FullName)).Trim()
          $q = Invoke-TcCsGit -Repo $Repo -GitArgs @('rebase', '--quit')
          if ($q.rc -ne 0) { return (Complete-TcCsSync 'degraded' 'in-progress' ('a half-started rebase holds only an autostash, and git rebase --quit exited ' + $q.rc + ': ' + $q.err)) }
          if (Test-Path -LiteralPath $rm) { return (Complete-TcCsSync 'degraded' 'in-progress' 'git rebase --quit exited 0 and left the rebase-merge directory') }
          $top = (Invoke-TcCsGit -Repo $Repo -GitArgs @('stash', 'list', '-n', '1', '--format=%H')).out
          if (-not [string]::Equals($top, $sha, [StringComparison]::Ordinal)) { return (Complete-TcCsSync 'degraded' 'in-progress' ('git rebase --quit exited 0, but stash@{0} is ' + $top + ', not the autostash ' + $sha)) }
          $rec.notes = @($rec.notes) + @('recovered half-started rebase, autostash kept as stash ' + $sha)
        }
      }
    }
    # 1c. Any other operation: waited on, never aborted or quit.
    $w = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
      $present = Get-TcCsOperationsInProgress $Repo
      if (-not $present.Count) { break }
      if ($w.Elapsed.TotalSeconds -ge $InProgressWaitSec) { return (Complete-TcCsSync 'degraded' 'in-progress' ('an operation is in progress in this checkout (' + ($present -join ', ') + ') after a ' + $InProgressWaitSec + ' s wait; the sync never touches another owner''s operation')) }
      Start-Sleep -Milliseconds $pollMs
    }
    # 1c2. A LEFTOVER INTENT (review finding 7): a sync killed between its read-tree and its update-ref leaves HEAD at
    # the intent's H0 with the index and tree at its NEW, which step 7 would read as a session's staged work. When
    # exactly that is so (HEAD on the branch at H0, the index equal to NEW's tree, and the tree on every changed
    # path at the index), the move is FINISHED with the update-ref it never made, as a compare-and-swap. Any other
    # leftover is named on the outcome and KEPT unless this run ends clean; nothing is written on its account.
    $leftDoc = Read-TcCsState (Join-Path $ctx.commonDir 'tc-checkout-sync.json')
    if ($null -ne $leftDoc.intent) {
      $li = $leftDoc.intent
      $liH0 = [string]$li.H0; $liNew = [string]$li.NEW
      $liWho = 'a sync interrupted earlier (pid ' + [string]$li.pid + ', started ' + [string]$li.started + ', H0 ' + $(if ($liH0.Length -ge 9) { $liH0.Substring(0, 9) } else { $liH0 }) + ', NEW ' + $(if ($liNew.Length -ge 9) { $liNew.Substring(0, 9) } else { $liNew }) + $(if ($li.PSObject.Properties['tree'] -and $li.tree) { ', its dated tree ' + [string]$li.tree } else { '' }) + ')'
      $finished = $false
      $symL = (Invoke-TcCsGit -Repo $Repo -GitArgs @('symbolic-ref', '-q', 'HEAD')).out
      $headL = (Invoke-TcCsGit -Repo $Repo -GitArgs @('rev-parse', 'HEAD')).out
      $newTree = if ($liNew) { (Invoke-TcCsGit -Repo $Repo -GitArgs @('rev-parse', '--verify', '-q', ($liNew + '^{tree}'))).out } else { '' }
      if ($newTree -and [string]::Equals($symL, ('refs/heads/' + $Branch), [StringComparison]::Ordinal) -and [string]::Equals($headL, $liH0, [StringComparison]::Ordinal)) {
        # The index equals NEW's tree, asked read-only: `git write-tree` would rewrite the index's cache-tree extension.
        $idxAtNew = (Invoke-TcCsGit -Repo $Repo -GitArgs @('diff-index', '--cached', '--quiet', $liNew)).rc -eq 0
        if ($idxAtNew) {
          $dl = Get-TcCsTreeDiff -Repo $Repo -A $liH0 -B $liNew
          $offDisk = [System.Collections.Generic.List[string]]::new()
          if ($dl.Count) {
            $wd = Invoke-TcCsGitPaths -Repo $Repo -Pre @('diff', '-z', '--name-only', '--no-renames') -Paths @($dl | ForEach-Object { $_.path })
            foreach ($t in (Split-TcCsNul $wd.raw)) { $offDisk.Add($t) }
            foreach ($x in @($dl | Where-Object { $_.st -eq 'D' })) { if ([IO.File]::Exists((Get-TcCsFullPath $Repo $x.path))) { $offDisk.Add($x.path + ' (still on disk)') } }
          }
          if (-not $offDisk.Count) {
            $urL = Invoke-TcCsGit -Repo $Repo -GitArgs @('update-ref', '-m', ('capture-run sync: finishing an interrupted move onto ' + $liNew), ('refs/heads/' + $Branch), $liNew, $liH0)
            if ($urL.rc -eq 0) {
              $finished = $true
              $rec.notes = @($rec.notes) + @('finished ' + $liWho + ': HEAD was at its H0 with the index and tree at its NEW, so the update-ref it never made was made now; an owned merge it had planned was not applied, and its undo copies stay in its dated tree')
            } else { $ctx.leftoverText = $liWho + ' left the index and tree at its target, and finishing its update-ref failed (rc ' + $urL.rc + '): ' + $urL.err }
          } else { $ctx.leftoverText = $liWho + ' left the index at its target and the tree off it on: ' + ($offDisk -join ', ') + '; repair by hand: git read-tree -m -u ' + $liNew + ' ' + $liH0 }
        }
      }
      if (-not $finished) {
        $ctx.leftover = $li
        if (-not $ctx.leftoverText) { $ctx.leftoverText = $liWho + ' left an intent this run could not finish (HEAD ' + $(if ($headL.Length -ge 9) { $headL.Substring(0, 9) } else { $headL }) + '); the plan below judges the tree as it stands' }
        $rec.notes = @($rec.notes) + @($ctx.leftoverText)
      }
    }
    # 1d + 1e. Unmerged entries (read the OUTPUT: ls-files -u exits 0 either way, X6) and NEW marker triples.
    $un = Invoke-TcCsGit -Repo $Repo -GitArgs @('ls-files', '-u', '-z')
    $unmerged = New-Object System.Collections.Generic.SortedSet[string] ([StringComparer]::Ordinal)
    foreach ($t in (Split-TcCsNul $un.raw)) { $tab = $t.IndexOf("`t"); if ($tab -ge 0) { [void]$unmerged.Add($t.Substring($tab + 1)) } }
    $marked = New-Object System.Collections.Generic.SortedSet[string] ([StringComparer]::Ordinal)
    $unscanned = [System.Collections.Generic.List[string]]::new()
    $dh = Invoke-TcCsGit -Repo $Repo -GitArgs @('diff', '-z', '--name-only', '--no-renames', 'HEAD')
    foreach ($p in (Split-TcCsNul $dh.raw)) {
      if ($unmerged.Contains($p)) { continue }
      $fi = New-Object IO.FileInfo((Get-TcCsFullPath $Repo $p))
      if (-not $fi.Exists) { continue }
      if ($fi.Length -gt $MarkerScanMaxBytes) { $unscanned.Add($p); continue }
      # The NUL probe first, through a stream that shares write and delete, and the whole file only when it is text.
      $head = Read-TcCsSharedBytes $fi.FullName $NulProbeBytes
      if ($head.Length -gt 0 -and [Array]::IndexOf($head, [byte]0) -ge 0) { continue }
      $bytes = if ($fi.Length -le $head.Length) { $head } else { Read-TcCsSharedBytes $fi.FullName }
      $wt = Get-TcCsMarkerTriples $bytes
      if ($wt -eq 0) { continue }
      $headBytes = Get-CommittedBlobBytes -Repo $Repo -Spec ('HEAD:' + $p)
      if ($wt -gt (Get-TcCsMarkerTriples $headBytes)) { [void]$marked.Add($p) }
    }
    $rec.unscanned = $unscanned.ToArray()
    # ONLY THE PIPELINE'S OWN CONFLICT IS RESTORED (review finding 2, 2026-09-23). An owned path is not enough: step 7
    # calls an owned but unvouched edit FOREIGN, and F3b calls a staged change FOREIGN even when owned and vouched, so
    # 1d/1e restore a path only when it is owned, the journal names it (-OwnBlobs has the key: the marked or unmerged
    # bytes can never hash to the blob the pipeline wrote, so naming is the only vouching there is), and, for a marked
    # path, its index entry still equals HEAD's. Everything else blocks with nothing written.
    $badPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($p in @(@($unmerged) + @($marked) | Sort-Object -Unique)) {
      $isUn = $unmerged.Contains($p)
      $why0 = ''
      if (-not (Test-TcCsOwnedPath $p $OwnedPaths)) { $why0 = 'not the bot''s' }
      elseif (-not $OwnBlobs.ContainsKey($p)) { $why0 = 'owned, but the pipeline journal does not name it' }
      elseif (-not $isUn -and (Invoke-TcCsGit -Repo $Repo -GitArgs @('diff-index', '--cached', '--quiet', 'HEAD', '--', $p)).rc -ne 0) { $why0 = 'owned and named, but staged' }
      if ($why0) { $badPaths.Add($p + $(if ($isUn) { ' (unmerged, ' } else { ' (new conflict markers, ' }) + $why0 + ')') }
    }
    if ($badPaths.Count) {
      return (Complete-TcCsSync 'blocked' 'conflict' ('the checkout holds unresolved conflicts on path(s) the sync may not restore: ' + ($badPaths -join ', ') + '; nothing was written'))
    }
    foreach ($p in @(@($unmerged) + @($marked) | Sort-Object -Unique)) {
      $why = if ($unmerged.Contains($p)) { 'unmerged' } else { 'new conflict markers' }
      $src = Get-TcCsFullPath $Repo $p
      if (Test-Path -LiteralPath $src -PathType Leaf) { Save-TcCsDisplaced -Kind 'set-aside' -Path $p -Source $src -Reason $why }
      $hasHead = (Invoke-TcCsGit -Repo $Repo -GitArgs @('cat-file', '-e', ('HEAD:' + $p))).rc -eq 0
      if (-not $hasHead) { return (Complete-TcCsSync 'degraded' 'conflict' ('an owned path holds ' + $why + ' and HEAD has no version of it to restore: ' + $p)) }
      $co = Invoke-TcCsGit -Repo $Repo -GitArgs @('checkout', 'HEAD', '--', $p)
      if ($co.rc -ne 0) { return (Complete-TcCsSync 'degraded' 'conflict' ('git checkout HEAD -- ' + $p + ' exited ' + $co.rc + ': ' + $co.err)) }
      $rec.set_aside = @($rec.set_aside) + @($p)
      $rec.notes = @($rec.notes) + @('set aside and restored from HEAD (' + $why + '): ' + $p)
      $ctx.preSetAside.Add($p)
    }
    # 1f. The branch.
    $sym = Invoke-TcCsGit -Repo $Repo -GitArgs @('symbolic-ref', '-q', 'HEAD')
    if ($sym.rc -ne 0 -or -not [string]::Equals($sym.out, ('refs/heads/' + $Branch), [StringComparison]::Ordinal)) {
      return (Complete-TcCsSync 'degraded' 'branch' ('HEAD is not refs/heads/' + $Branch + ' (' + $(if ($sym.out) { $sym.out } else { 'detached' }) + '); the sync never moves another branch'))
    }
    # 1g. The bot's own private-index commit left the REAL index holding the parent's entries (addendum): reset exactly
    # those, deletions included. --no-renames, because a rename pairing hides the deleted path (capture-run.ps1:1159).
    if ($BotCommit) {
      $rs = Sync-TcCsBotCommitIndex -Repo $Repo -BotCommit $BotCommit
      if (-not $rs.ok) { return (Complete-TcCsSync 'degraded' 'index' $rs.why) }
      $rec.index_resynced = @($rs.paths)
    }

    # ---- 2. FETCH ---------------------------------------------------------------------------------------------------
    $fetched = $false; $fErr = ''
    $prevPrompt = $env:GIT_TERMINAL_PROMPT; $env:GIT_TERMINAL_PROMPT = '0'
    try {
      for ($a = 1; $a -le [Math]::Max(1, $FetchAttempts); $a++) {
        # Bounded twice: http.lowSpeed* ends an HTTPS transfer that stalls below 1,000 B/s for 60 s, and the wall-clock
        # -FetchTimeoutSec kills anything else (an ssh or local transport that never answers).
        $f = Invoke-TcCsGitTimed -Repo $Repo -TimeoutSec $FetchTimeoutSec -GitArgs @('-c', 'http.lowSpeedLimit=1000', '-c', 'http.lowSpeedTime=60', 'fetch', '--no-tags', $Remote, ('+refs/heads/' + $Branch + ':refs/remotes/' + $Remote + '/' + $Branch))
        if ($f.rc -eq 0) { $fetched = $true; break }
        $fErr = 'fetch attempt ' + $a + $(if ($f.timedOut) { ' timed out: ' } else { ' exited ' + $f.rc + ': ' }) + $f.err
        if ($a -lt $FetchAttempts) { Start-Sleep -Seconds ([Math]::Max(0, $FetchRetrySec)) }
      }
    } finally { $env:GIT_TERMINAL_PROMPT = $prevPrompt }
    if (-not $fetched) { return (Complete-TcCsSync 'degraded' 'fetch' ($fErr + '; running on the HEAD this checkout has')) }

    # ---- 3. WHERE WE ARE --------------------------------------------------------------------------------------------
    $rec.H0 = (Invoke-TcCsGit -Repo $Repo -GitArgs @('rev-parse', 'HEAD')).out
    $fullO = (Invoke-TcCsGit -Repo $Repo -GitArgs @('rev-parse', ('refs/remotes/' + $Remote + '/' + $Branch))).out
    $rec.O = $fullO
    $rec.behind = [int](Invoke-TcCsGit -Repo $Repo -GitArgs @('rev-list', '--count', ($rec.H0 + '..' + $fullO))).out
    $rec.ahead = [int](Invoke-TcCsGit -Repo $Repo -GitArgs @('rev-list', '--count', ($fullO + '..' + $rec.H0))).out
    if ($rec.behind -eq 0) { $rec.NEW = $rec.H0; return (Complete-TcCsSync 'current' '' 'HEAD already contains origin; nothing was written') }
    # ---- 4. NEVER LINEARISE A MERGE ---------------------------------------------------------------------------------
    $merges = [int](Invoke-TcCsGit -Repo $Repo -GitArgs @('rev-list', '--merges', '--count', ($fullO + '..' + $rec.H0))).out
    if ($merges -gt 0) { return (Complete-TcCsSync 'degraded' 'merge' ('' + $merges + ' local merge commit(s) sit on top of origin; the sync never linearises a merge')) }
    $statusNow = Get-TcCsStatus $Repo
    if (-not $statusNow.ok) { return (Complete-TcCsSync 'failed' 'environment' $statusNow.why) }

    # ---- 5 TO 8. THE TARGET, ITS STARTUP PARSE, THE PLAN, AND THE PARTIAL FALLBACK ----------------------------------
    $plan = Get-TcCsPlanFor -Onto $fullO
    if (-not $plan.ok) { return (Complete-TcCsSync 'degraded' $plan.cls $plan.why) }
    $isPartial = $false
    if ($plan.foreign.Count) {
      $rec.foreign = @($plan.foreign | ForEach-Object { $_.path + ' (' + $_.code + ')' })
      $pt = Get-TcCsPartialTarget -Repo $Repo -H0 $rec.H0 -O $fullO -Remote $Remote -Branch $Branch -Foreign @($plan.foreign | ForEach-Object { $_.path })
      $rec.partial_blocker = $pt.blocker
      if (-not $pt.ok) { return (Complete-TcCsSync 'blocked' 'foreign' ('uncommitted work the bot does not own sits on path(s) upstream changed, and ' + $pt.why + ': ' + ($rec.foreign -join ', ') + '; nothing was written')) }
      $plan = Get-TcCsPlanFor -Onto $pt.tip
      if (-not $plan.ok) { return (Complete-TcCsSync 'degraded' $plan.cls $plan.why) }
      if ($plan.foreign.Count) { return (Complete-TcCsSync 'blocked' 'foreign' ('even the observed push tip ' + $pt.tip.Substring(0, 9) + ' changes path(s) holding uncommitted work the bot does not own: ' + (@($plan.foreign | ForEach-Object { $_.path + ' (' + $_.code + ')' }) -join ', ') + '; nothing was written')) }
      $rec.partial_target = $pt.tip; $isPartial = $true
    }
    $rec.NEW = $plan.new; $rec.replayed = $plan.replayed; $rec.dropped = $plan.dropped; $rec.changed = $plan.entries.Count
    $rec.startup_changed = ($plan.startup.Count -gt 0); $rec.startup_files = @($plan.startup)
    # The fingerprint of every dirty path OUTSIDE the move, taken before anything is written: step 10 asserts each is
    # byte-, mtime- and status-identical afterwards (bar B4). FOREIGN paths a partial left behind are among them.
    $inMove = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::Ordinal)
    foreach ($e in $plan.entries) { [void]$inMove.Add($e.path) }
    $ctx.fp0 = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
    foreach ($p in @($statusNow.map.Keys)) { if (-not $inMove.Contains($p)) { $ctx.fp0[$p] = Get-TcCsFingerprint $Repo $p $statusNow.map } }

    # ---- 9. APPLY ---------------------------------------------------------------------------------------------------
    $stateFile = Join-Path $ctx.commonDir 'tc-checkout-sync.json'
    $doc = Read-TcCsState $stateFile
    $doc.intent = [ordered]@{ pid = $PID; phase = $Phase; started = $Now.ToString('o'); H0 = $rec.H0; O = $fullO; NEW = $plan.new; plan = @($plan.entries | Where-Object { $_.cls -ne 'clean' } | ForEach-Object { $_.cls + ' ' + $_.path }) }
    [void](Write-TcAtomicFile -Path $stateFile -Text ($doc | ConvertTo-Json -Depth 6) -NoBom)
    $byCls = @{}; foreach ($c in 'clean', 'in-the-way', 'already-upstream', 'own-merge', 'own-setaside', 'own-deleted') { $byCls[$c] = @($plan.entries | Where-Object { $_.cls -eq $c }) }
    $stage = 'displacing'
    foreach ($e in $byCls['in-the-way']) {
      # A reader holding the file open without delete sharing refuses the move (review finding 11): ONE retry after
      # -HeldRetrySec, then blocked class held-file with every byte already displaced put back. Any other failure
      # throws to the 'displacing' catch as before.
      $qSrc = Get-TcCsFullPath $Repo $e.path
      $moved = $false
      for ($qa = 1; $qa -le 2 -and -not $moved; $qa++) {
        try { Save-TcCsDisplaced -Kind 'quarantine' -Path $e.path -Source $qSrc -Reason 'untracked or ignored, where upstream adds this path' -Move; $moved = $true }
        catch {
          if ($_.Exception.Message -notmatch 'used by another process|sharing violation') { throw }
          if ($qa -eq 1 -and $HeldRetrySec -gt 0) { Start-Sleep -Seconds $HeldRetrySec }
        }
      }
      if (-not $moved) {
        $rec.held = $e.path
        $pb = Restore-TcCsPreSync -Plan $plan -GitWrote @()
        if ($pb) { return (Complete-TcCsSync 'failed' 'mixed-tree' ('a reader held ' + $e.path + ' open, so it could not be moved out of upstream''s way, and the put-back could not verify: ' + $pb)) }
        return (Complete-TcCsSync 'blocked' 'held-file' ('a reader held ' + $e.path + ' open (untracked, where upstream adds it), so it could not be moved out of the way; every byte already displaced was put back, nothing moved, and HEAD stays at ' + $rec.H0))
      }
      $rec.quarantined = @($rec.quarantined) + @($e.path)
    }
    foreach ($e in @($byCls['own-merge']) + @($byCls['own-setaside'])) {
      $src = Get-TcCsFullPath $Repo $e.path
      Save-TcCsDisplaced -Kind 'undo' -Path $e.path -Source $src -Reason ($e.cls + ': the bytes before the move')
      if ($e.cls -eq 'own-setaside') { Save-TcCsDisplaced -Kind 'set-aside' -Path $e.path -Source $src -Reason $e.why; $rec.set_aside = @($rec.set_aside) + @($e.path) }
    }
    $au = @($byCls['already-upstream'] | ForEach-Object { $_.path })
    if ($au.Count) { $ga = Invoke-TcCsGitPaths -Repo $Repo -Pre @('add') -Paths $au; if ($ga.rc -ne 0) { throw ('git add of the already-upstream path(s) exited ' + $ga.rc + ': ' + $ga.err) } }
    $own = @(@($byCls['own-merge']) + @($byCls['own-setaside']) | ForEach-Object { $_.path })
    if ($own.Count) { $gc = Invoke-TcCsGitPaths -Repo $Repo -Pre @('checkout') -Paths $own; if ($gc.rc -ne 0) { throw ('git checkout -- of the owned path(s) exited ' + $gc.rc + ': ' + $gc.err) } }
    $stage = 'displaced'
    if ($rec.tree) {
      # The intent names the dated tree, so a run killed from here on is found with its displaced bytes (finding 7).
      $doc.intent.tree = $rec.tree
      [void](Write-TcAtomicFile -Path $stateFile -Text ($doc | ConvertTo-Json -Depth 6) -NoBom)
    }
    if ($BeforeMove) { $null = & $BeforeMove }
    # 9d. HEAD must still be H0.
    $hNow = (Invoke-TcCsGit -Repo $Repo -GitArgs @('rev-parse', 'HEAD')).out
    if (-not [string]::Equals($hNow, $rec.H0, [StringComparison]::Ordinal)) {
      $pb = Restore-TcCsPreSync -Plan $plan -GitWrote @()
      return (Complete-TcCsSync 'degraded' 'head-moved' ('HEAD moved to ' + $hNow + ' while the sync planned; every displaced byte was put back' + $(if ($pb) { ' except: ' + $pb } else { '' })))
    }
    # 9e. The move, and the held-file recovery.
    $stage = 'moving'
    $rt = Invoke-TcCsGit -Repo $Repo -GitArgs @('read-tree', '-m', '-u', $rec.H0, $plan.new)
    if ($AfterReadTree) { $null = & $AfterReadTree }
    if ($rt.rc -ne 0) {
      $heldM = [regex]::Match($rt.err, "unable to unlink old '([^']+)'")
      $wrote = Get-TcCsGitWritten -Plan $plan
      $forwardOk = $false
      if ($heldM.Success) {
        $rec.held = $heldM.Groups[1].Value
        if ($HeldRetrySec -gt 0) { Start-Sleep -Seconds $HeldRetrySec }
        $stageList = @(@($wrote) + @($au) | Sort-Object -Unique)
        $fa = if ($stageList.Count) { Invoke-TcCsGitPaths -Repo $Repo -Pre @('add') -Paths $stageList } else { [pscustomobject]@{ rc = 0 } }
        if ($fa.rc -eq 0) {
          $rt2 = Invoke-TcCsGit -Repo $Repo -GitArgs @('read-tree', '-m', '-u', $rec.H0, $plan.new)
          $forwardOk = ($rt2.rc -eq 0)
          if ($forwardOk) { $rec.notes = @($rec.notes) + @('read-tree was refused on a held file (' + $rec.held + '), and the forward retry completed the move') }
        }
        if (-not $forwardOk) { $wrote = Get-TcCsGitWritten -Plan $plan }
      }
      if (-not $forwardOk) {
        $bad = Restore-TcCsPreSync -Plan $plan -GitWrote $wrote
        $stage = 'displaced'
        if ($bad) { return (Complete-TcCsSync 'failed' 'mixed-tree' ('read-tree was refused (rc ' + $rt.rc + ') and the backward restore could not verify: ' + $bad + '. HEAD is ' + $rec.H0 + '. ' + (Get-TcCsUndoText))) }
        $cls = if ($heldM.Success) { 'held-file' } else { 'read-tree' }
        $what = if ($heldM.Success) { 'a reader held ' + $rec.held + ' open, so git could not replace it' } else { 'read-tree refused the move (rc ' + $rt.rc + '): ' + $rt.err }
        return (Complete-TcCsSync 'blocked' $cls ($what + '; every path was restored to its bytes before the sync and verified, and HEAD stays at ' + $rec.H0))
      }
    }
    # 9e2. A HELD DELETION (review finding 1). Over a path upstream DELETES, git's unlink of a file held open without
    # delete sharing only WARNS (`unable to unlink '<p>': Invalid argument`) and read-tree exits 0 with the index entry
    # gone and the file left behind, so rc alone cannot see it. Every deleted path must be absent before the ref moves.
    # A leftover still holding H0's blob (recoverable from the object database) gets ONE delete after -HeldRetrySec; a
    # leftover holding anything else, or one that still cannot be deleted, is the held-file case: BACKWARD, verified.
    $left = Get-TcCsDeletedLeftovers -Plan $plan
    if ($left.Count) {
      $rec.held = ($left -join ', ')
      if ($HeldRetrySec -gt 0) { Start-Sleep -Seconds $HeldRetrySec }
      $lb = Get-TcCsDiskBlobs -Repo $Repo -Paths $left
      $byP = @{}; foreach ($e in $plan.entries) { $byP[$e.path] = $e }
      foreach ($p in $left) {
        if ($lb.ContainsKey($p) -and [string]::Equals([string]$lb[$p], [string]$byP[$p].oldBlob, [StringComparison]::Ordinal)) {
          try { [IO.File]::Delete((Get-TcCsFullPath $Repo $p)) } catch { }
        }
      }
      $left2 = Get-TcCsDeletedLeftovers -Plan $plan
      if ($left2.Count) {
        $bad = Restore-TcCsPreSync -Plan $plan -GitWrote (Get-TcCsGitWritten -Plan $plan)
        $stage = 'displaced'
        if ($bad) { return (Complete-TcCsSync 'failed' 'mixed-tree' ('read-tree could not delete ' + ($left2 -join ', ') + ' (held open) and the backward restore could not verify: ' + $bad + '. HEAD is ' + $rec.H0 + '. ' + (Get-TcCsUndoText))) }
        return (Complete-TcCsSync 'blocked' 'held-file' ('a reader held ' + ($left2 -join ', ') + ' open where upstream deletes it, so git could not remove it; every path was restored to its bytes before the sync and verified, and HEAD stays at ' + $rec.H0))
      }
      $rec.notes = @($rec.notes) + @('read-tree could not delete ' + ($left -join ', ') + ' (held open), and the one delete after the wait completed the move')
    }
    $stage = 'moved'
    if ($BeforeRef) { $null = & $BeforeRef }
    # 9f. The ref, as a compare-and-swap.
    $ur = Invoke-TcCsGit -Repo $Repo -GitArgs @('update-ref', '-m', ('capture-run sync: onto ' + $fullO), ('refs/heads/' + $Branch), $plan.new, $rec.H0)
    if ($ur.rc -ne 0 -and [string]::Equals((Invoke-TcCsGit -Repo $Repo -GitArgs @('rev-parse', ('refs/heads/' + $Branch))).out, $rec.H0, [StringComparison]::Ordinal)) {
      # NOT A LOST SWAP (review finding 6): the branch still names H0, so update-ref failed for another reason (a ref
      # lock held by a concurrent command, pack-refs, or a crashed git's stale lock). ONE retry after -HeldRetrySec;
      # then BACKWARD, verified by bytes, so HEAD, the index and the tree all end at H0 and the next sync starts clean.
      if ($HeldRetrySec -gt 0) { Start-Sleep -Seconds $HeldRetrySec }
      $ur = Invoke-TcCsGit -Repo $Repo -GitArgs @('update-ref', '-m', ('capture-run sync: onto ' + $fullO), ('refs/heads/' + $Branch), $plan.new, $rec.H0)
      if ($ur.rc -ne 0 -and [string]::Equals((Invoke-TcCsGit -Repo $Repo -GitArgs @('rev-parse', ('refs/heads/' + $Branch))).out, $rec.H0, [StringComparison]::Ordinal)) {
        $bad = Restore-TcCsPreSync -Plan $plan -GitWrote (Get-TcCsGitWritten -Plan $plan)
        $stage = 'displaced'
        if ($bad) { return (Complete-TcCsSync 'failed' 'mixed-tree' ('update-ref could not move refs/heads/' + $Branch + ' (rc ' + $ur.rc + '): ' + $ur.err + '; the backward restore could not verify: ' + $bad + '. HEAD is ' + $rec.H0 + '. ' + (Get-TcCsUndoText))) }
        return (Complete-TcCsSync 'degraded' 'ref-lock' ('update-ref could not move refs/heads/' + $Branch + ' twice (rc ' + $ur.rc + '): ' + $ur.err + '; nothing had committed on top of ' + $rec.H0 + ', so no swap was lost; HEAD, the index and the tree were restored to it and verified'))
      }
    }
    if ($ur.rc -ne 0) {
      # THE SWAP LOST: something committed on top of H0 while the tree moved (a lane's private-index commit takes no
      # index lock; a session's real-index commit does, but only between our two commands). ONE recovery, never a loop:
      # replay exactly H0..H1 onto the target, set the INDEX entries of the interloper's own paths from the replayed tip
      # (the committer wrote its bytes before committing them), and swap against H1. `git reset <tip> -- <paths>`, not
      # `read-tree -m NEW tip`: the two-way read-tree refuses an entry whose worktree differs from its index, and a lane
      # that commits a file that was dirty when the sync planned leaves exactly that (found by the f11c case).
      # EVERY failure from here is class mixed-tree: HEAD is H1 and the index is at the target, so they disagree.
      $h1 = (Invoke-TcCsGit -Repo $Repo -GitArgs @('rev-parse', ('refs/heads/' + $Branch))).out
      if ((Invoke-TcCsGit -Repo $Repo -GitArgs @('merge-base', '--is-ancestor', $rec.H0, $h1)).rc -ne 0) { return (Complete-TcCsSync 'failed' 'mixed-tree' ('lost the compare-and-swap: main moved to ' + $h1 + ', which does not descend from ' + $rec.H0 + '; the index holds the target and HEAD does not - repair by hand: git read-tree -m ' + $plan.new + ' ' + $h1)) }
      $rp2 = Invoke-TcCsLocalCommitReplay -Repo $Repo -Upstream $rec.H0 -Tip $h1 -Onto $plan.new -BotName $BotName -BotEmail $BotEmail
      if (-not $rp2.ok) { return (Complete-TcCsSync 'failed' 'mixed-tree' ('lost the compare-and-swap and the interloper ' + $h1 + ' did not replay: ' + $rp2.why + '; HEAD is ' + $h1 + ' and the index holds ' + $plan.new)) }
      $ctx.casPaths = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::Ordinal)
      foreach ($x in (Get-TcCsTreeDiff -Repo $Repo -A $rec.H0 -B $h1)) { [void]$ctx.casPaths.Add($x.path) }
      $ri = if ($ctx.casPaths.Count) { Invoke-TcCsGitPaths -Repo $Repo -Pre @('reset', '-q', $rp2.tip) -Paths @($ctx.casPaths) } else { [pscustomobject]@{ rc = 0; err = '' } }
      $ur2 = if ($ri.rc -eq 0) { Invoke-TcCsGit -Repo $Repo -GitArgs @('update-ref', '-m', ('capture-run sync (recovered): onto ' + $fullO), ('refs/heads/' + $Branch), $rp2.tip, $h1) } else { $ri }
      if ($ur2.rc -ne 0) { return (Complete-TcCsSync 'failed' 'mixed-tree' ('lost the compare-and-swap, and its one recovery failed too (rc ' + $ur2.rc + '): ' + $ur2.err + '; HEAD and the index disagree')) }
      # The interloper's own paths are its to change: a lane that commits files that were dirty when the sync planned
      # leaves them clean, and step 10 skips them in its untouched-fingerprint check (casPaths above).
      $rec.cas_recovered = $h1; $plan.new = $rp2.tip; $rec.NEW = $rp2.tip
    }
    $stage = 'ref'
    # 9g. The only file this writes that it did not just restore is the pipeline's own vouched output.
    foreach ($e in $byCls['own-merge']) { [IO.File]::WriteAllBytes((Get-TcCsFullPath $Repo $e.path), [byte[]]$e.merged); $rec.merged = @($rec.merged) + @($e.path) }
    $rec.already_upstream = @($au); $rec.own_deleted = @($byCls['own-deleted'] | ForEach-Object { $_.path })

    # ---- 10. VERIFY -------------------------------------------------------------------------------------------------
    $v = Test-TcCsAfterMove -Plan $plan -FullO $fullO -IsPartial $isPartial
    $rec.behind_after = $v.behind_after
    if ($v.later.Count) { $rec.notes = @($rec.notes) + @('' + $v.later.Count + ' dirty path(s) outside the move were saved by someone else during the sync (status and index unchanged, mtime forward), never written by it: ' + ($v.later -join ', ')) }
    if ($v.worktree) { return (Complete-TcCsSync 'failed' 'mixed-tree' ('HEAD moved to ' + $plan.new + ' but the working tree does not hold it: ' + $v.worktree + '. ' + (Get-TcCsUndoText))) }
    if ($v.other) { return (Complete-TcCsSync 'failed' 'verify' ($v.other + '. ' + (Get-TcCsUndoText))) }
    Remove-TcCsUndo
    $stage = 'done'
    if ($isPartial) {
      return (Complete-TcCsSync 'partial' 'foreign' ('moved to the observed push tip ' + $plan.new.Substring(0, 9) + ', ' + $rec.behind_after + ' commit(s) short of origin, because uncommitted work the bot does not own sits on path(s) ' + $pt.blocker_text + ': ' + ($rec.foreign -join ', ')))
    }
    return (Complete-TcCsSync 'synced' '' ('moved ' + $rec.behind + ' commit(s) forward, ' + $rec.replayed + ' local commit(s) replayed'))
  } catch {
    $msg = $_.Exception.Message
    switch ($stage) {
      'plan' { return (Complete-TcCsSync 'failed' 'exception' ('the sync threw before the move (only a step 1d/1e set-aside copy can exist): ' + $msg)) }
      'displacing' { $pb = Restore-TcCsPreSync -Plan $plan -GitWrote @(); return (Complete-TcCsSync 'failed' $(if ($pb) { 'mixed-tree' } else { 'exception' }) ('the sync threw while setting bytes aside: ' + $msg + $(if ($pb) { '; the put-back could not verify: ' + $pb } else { '; every displaced byte was put back' }))) }
      'displaced' { $pb = Restore-TcCsPreSync -Plan $plan -GitWrote @(); return (Complete-TcCsSync 'failed' $(if ($pb) { 'mixed-tree' } else { 'exception' }) ('the sync threw before the move: ' + $msg + $(if ($pb) { '; the put-back could not verify: ' + $pb } else { '; every displaced byte was put back' }))) }
      'moving' { $ctx.keepOwnIntent = $true; return (Complete-TcCsSync 'failed' 'mixed-tree' ('the sync threw during the tree move: ' + $msg + '. HEAD is ' + $rec.H0 + ' and the index or tree may be at ' + $rec.NEW + '; repair by hand: git read-tree -m -u ' + $rec.NEW + ' ' + $rec.H0 + ', then restore the undo copies. ' + (Get-TcCsUndoText) + '. The intent is kept, so the next sync can finish this move')) }
      'moved' { $ctx.keepOwnIntent = $true; return (Complete-TcCsSync 'failed' 'mixed-tree' ('the sync threw after the tree moved and before the ref did: ' + $msg + '. HEAD is ' + $rec.H0 + ' and the index and tree are at ' + $rec.NEW + '; repair by hand: git read-tree -m -u ' + $rec.NEW + ' ' + $rec.H0 + ', then restore the undo copies. ' + (Get-TcCsUndoText) + '. The intent is kept, so the next sync can finish this move')) }
      'ref' { return (Complete-TcCsSync 'failed' 'exception' ('the sync threw after HEAD moved to ' + $rec.NEW + ': ' + $msg + '. ' + (Get-TcCsUndoText))) }
      'done' { return (Complete-TcCsSync 'failed' 'exception' ('the sync threw after it completed: ' + $msg)) }
      default { return (Complete-TcCsSync 'failed' 'exception' ('the sync threw at an unknown stage ' + $stage + ': ' + $msg)) }
    }
  }
}

# ---- THE PIECES Invoke-TcCheckoutSync CALLS. Each reads the caller's $Repo, $rec, $ctx and parameters by dynamic
# scope, because each is only ever called from inside it; none is a public entry point. ------------------------------

function Read-TcCsState([string]$Path) {
  $doc = [ordered]@{ schema = 1; last = $null; intent = $null; disabled_paged_on = ''; fetch_paged_on = '' }
  if (Test-Path -LiteralPath $Path) {
    try {
      $j = [Text.Encoding]::UTF8.GetString((Read-TcCsSharedBytes $Path)).TrimStart([char]0xFEFF) | ConvertFrom-Json
      if ($j.PSObject.Properties['disabled_paged_on']) { $doc.disabled_paged_on = [string]$j.disabled_paged_on }
      if ($j.PSObject.Properties['fetch_paged_on']) { $doc.fetch_paged_on = [string]$j.fetch_paged_on }
      if ($j.PSObject.Properties['last']) { $doc.last = $j.last }
      if ($j.PSObject.Properties['intent']) { $doc.intent = $j.intent }
    } catch { $doc.disabled_paged_on = '' }
  }
  return $doc
}

# The dated tree, made on first use: <QuarantineRoot>\<yyyy-MM-dd>\<HHmmss>-sync[-n]\. -ErrorAction Stop on the leaf so
# two syncs in one second never share one.
function Get-TcCsTree {
  if ($rec.tree) { return $rec.tree }
  $day = Join-Path $QuarantineRoot $Now.ToString('yyyy-MM-dd')
  [void](New-Item -ItemType Directory -Force -Path $day -ErrorAction Stop)
  $stem = $Now.ToString('HHmmss') + '-sync'
  for ($n = 1; $n -le 50; $n++) {
    $cand = Join-Path $day $(if ($n -eq 1) { $stem } else { $stem + '-' + $n })
    if (Test-Path -LiteralPath $cand) { continue }
    try { [void](New-Item -ItemType Directory -Path $cand -ErrorAction Stop); $rec.tree = $cand; return $cand } catch { continue }
  }
  throw ('could not create a dated sync tree under ' + $day)
}

# Copy (or -Move) one path's bytes into <tree>\<Kind>\<path>, keeping its LastWriteTime, and add its manifest row.
# The copy is written BEFORE the manifest row that names it (pointed-to first).
function Save-TcCsDisplaced {
  param([string]$Kind, [string]$Path, [string]$Source, [string]$Reason, [switch]$Move)
  $tree = Get-TcCsTree
  $dst = Join-Path (Join-Path $tree $Kind) ($Path -replace '/', '\')
  [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) -ErrorAction Stop)
  $blob = (Invoke-TcCsGit -Repo $Repo -GitArgs @('hash-object', '--', $Path)).out
  $idx = ''
  $ls = Invoke-TcCsGit -Repo $Repo -GitArgs @('ls-files', '-s', '-z', '--', $Path)
  $lsToks = Split-TcCsNul $ls.raw
  if ($lsToks.Count) { $idx = @($lsToks[0] -split '\s+')[1] }
  if ($Move) { Move-Item -LiteralPath $Source -Destination $dst -ErrorAction Stop }   # atomic-replace:allow a move of a displaced file into a fresh dated tree, not a replace of a file anything reads
  else { [IO.File]::Copy($Source, $dst, $true) }
  if (-not $ctx.ContainsKey('manifest')) { $ctx.manifest = [System.Collections.Generic.List[object]]::new() }
  $ctx.manifest.Add([ordered]@{ path = $Path; class = $Kind; reason = $Reason; blob = $blob; index_blob = $idx; at = ($Kind + '\' + ($Path -replace '/', '\')) })
  if (-not $ctx.ContainsKey('saved')) { $ctx.saved = [System.Collections.Generic.List[object]]::new() }
  $ctx.saved.Add([pscustomobject]@{ kind = $Kind; path = $Path; copy = $dst; moved = [bool]$Move })
  [void](Write-TcAtomicFile -Path (Join-Path $tree 'manifest.json') -Text (ConvertTo-Json -InputObject @($ctx.manifest.ToArray()) -Depth 4) -NoBom)
}

# Deleted only after step 10 passed: the undo copies are the one record of the bytes a failed move displaced.
function Remove-TcCsUndo {
  if ($rec.tree) {
    $u = Join-Path $rec.tree 'undo'
    if (Test-Path -LiteralPath $u) { Remove-Item -LiteralPath $u -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

# Step 1g. Index entries that still hold -BotCommit's PARENT version of a path that commit changed (and HEAD has not
# changed since) are the private-index commit's leftover: `git status` shows them as a staged revert, and a whole-index
# commit would undo the run. Each is reset to HEAD. An entry holding anything else is somebody's staging and is kept.
function Sync-TcCsBotCommitIndex {
  param([string]$Repo, [string]$BotCommit)
  $bc = (Invoke-TcCsGit -Repo $Repo -GitArgs @('rev-parse', '--verify', '-q', ($BotCommit + '^{commit}'))).out
  if (-not $bc) { return @{ ok = $false; why = ('-BotCommit ' + $BotCommit + ' is not a commit'); paths = @() } }
  $changed = Get-TcCsTreeDiff -Repo $Repo -A ($bc + '^1') -B $bc
  $since = Get-TcCsTreeDiff -Repo $Repo -A $bc -B 'HEAD'
  $moved = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::Ordinal)
  foreach ($s in $since) { [void]$moved.Add($s.path) }
  $idxG = Invoke-TcCsGit -Repo $Repo -GitArgs @('ls-files', '-s', '-z')
  $index = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
  foreach ($t in (Split-TcCsNul $idxG.raw)) {
    $tab = $t.IndexOf("`t"); if ($tab -lt 0) { continue }
    $f = $t.Substring(0, $tab).Split(' ')
    if ($f[2] -eq '0') { $index[$t.Substring($tab + 1)] = ($f[0] + ' ' + $f[1]) }
  }
  $stale = [System.Collections.Generic.List[string]]::new()
  foreach ($c in $changed) {
    if ($moved.Contains($c.path)) { continue }
    $parentState = if ($c.oldBlob -eq $script:TcCsZeroSha) { '' } else { $c.oldMode + ' ' + $c.oldBlob }
    $idxState = if ($index.ContainsKey($c.path)) { [string]$index[$c.path] } else { '' }
    if ([string]::Equals($idxState, $parentState, [StringComparison]::Ordinal)) { $stale.Add($c.path) }
  }
  if ($stale.Count) {
    $r = Invoke-TcCsGitPaths -Repo $Repo -Pre @('reset', '-q') -Paths $stale.ToArray()
    if ($r.rc -ne 0) { return @{ ok = $false; why = ('git reset of the bot commit''s leftover index entries exited ' + $r.rc + ': ' + $r.err); paths = @() } }
  }
  return @{ ok = $true; why = ''; paths = $stale.ToArray() }
}

# Steps 5 to 7 for one target: NEW (origin, or the local commits replayed onto it), the startup parse at NEW, and the
# class of every path the move changes. Returns @{ ok; cls; why; new; replayed; dropped; entries; foreign; startup }.
function Get-TcCsPlanFor {
  param([string]$Onto)
  $out = @{ ok = $false; cls = ''; why = ''; new = $Onto; replayed = 0; dropped = 0; entries = @(); foreign = @(); startup = @() }
  $ahead = [int](Invoke-TcCsGit -Repo $Repo -GitArgs @('rev-list', '--count', ($Onto + '..' + $rec.H0))).out
  if ($ahead -gt 0) {
    $rp = Invoke-TcCsLocalCommitReplay -Repo $Repo -Upstream $Onto -Tip $rec.H0 -BotName $BotName -BotEmail $BotEmail
    if (-not $rp.ok) { $out.cls = 'replay'; $out.why = $rp.why; return $out }
    $out.new = $rp.tip; $out.replayed = $rp.replayed; $out.dropped = $rp.dropped
  }
  $diff = Get-TcCsTreeDiff -Repo $Repo -A $rec.H0 -B $out.new
  $changedSet = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::Ordinal)
  foreach ($x in $diff) { [void]$changedSet.Add($x.path) }
  $startup = @(@($StartupFiles) | Where-Object { $changedSet.Contains(([string]$_ -replace '\\', '/')) })
  foreach ($sf in $startup) {
    $pe = Test-TcCsParsesAt -Repo $Repo -Commit $out.new -Path ($sf -replace '\\', '/')
    if ($pe) { $out.cls = 'startup-parse'; $out.why = ('synced code does not parse: ' + $sf + ' ' + $pe + '; nothing moved'); return $out }
  }
  $out.startup = $startup
  $entries = [System.Collections.Generic.List[object]]::new()
  $foreign = [System.Collections.Generic.List[object]]::new()
  $scratch = Join-Path $env:TEMP ('tc-cs-merge-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  try {
    foreach ($x in $diff) {
      $p = $x.path
      $st = if ($statusNow.map.ContainsKey($p)) { $statusNow.map[$p] } else { $null }
      $code = if ($null -eq $st) { '' } elseif ($st.codes.Count -eq 1) { $st.codes[0] } else { ($st.codes -join '+') }
      $e = [pscustomobject]@{ path = $p; st = $x.st; code = $code; cls = ''; why = ''; oldBlob = $x.oldBlob; newBlob = $x.newBlob; merged = $null; fp = (Get-TcCsFingerprint $Repo $p $statusNow.map) }
      $onDisk = [IO.File]::Exists((Get-TcCsFullPath $Repo $p))
      $owned = Test-TcCsOwnedPath $p $OwnedPaths
      if ($code -eq '' -or $code -eq '!!') {
        if ($x.st -eq 'A' -and $onDisk -and (Invoke-TcCsGit -Repo $Repo -GitArgs @('ls-files', '--error-unmatch', '--', $p)).rc -ne 0) { $e.cls = 'in-the-way' }
        else { $e.cls = 'clean' }
      } elseif ($code -eq '??') {
        # An untracked file where upstream adds the path is moved aside only when it is the bot's (review finding 3): a
        # session's untracked draft outside the owned paths is FOREIGN like its ` M` twin, unless it already holds
        # upstream's blob, in which case an index update carries it with its bytes and mtime untouched.
        if ($x.st -eq 'D') { $e.cls = 'foreign'; $e.why = 'an untracked file at a path upstream deletes' }
        elseif ($owned) { $e.cls = 'in-the-way' }
        elseif ([string]::Equals((Invoke-TcCsGit -Repo $Repo -GitArgs @('hash-object', '--', $p)).out, $x.newBlob, [StringComparison]::Ordinal)) { $e.cls = 'already-upstream' }
        else { $e.cls = 'foreign'; $e.why = 'an untracked file the bot does not own, where upstream adds this path' }
      } else {
        switch -Regex ($code) {
          '^[^ ]' { $e.cls = 'foreign'; $e.why = ('a staged change (' + $code + ') on a path upstream changed; the sync never rewrites an index entry it did not make') }
          '^ M$' {
            $cur = (Invoke-TcCsGit -Repo $Repo -GitArgs @('hash-object', '--', $p)).out
            $vouched = $owned -and $OwnBlobs.ContainsKey($p) -and [string]::Equals([string]$OwnBlobs[$p], $cur, [StringComparison]::Ordinal)
            if ($x.st -ne 'D' -and [string]::Equals($cur, $x.newBlob, [StringComparison]::Ordinal)) { $e.cls = 'already-upstream' }
            elseif (-not $vouched) { $e.cls = 'foreign'; $e.why = $(if ($owned) { 'an edit under an owned path whose bytes the pipeline journal does not vouch for' } else { 'an uncommitted edit the bot does not own' }) }
            elseif ($x.st -eq 'D') { $e.cls = 'own-setaside'; $e.why = 'upstream deleted a file the pipeline had rewritten; upstream wins' }
            else {
              $mg = Get-TcCsOwnMerge -Path $p -H0 $rec.H0 -New $out.new -Scratch $scratch
              if ($mg.ok) { $e.cls = 'own-merge'; $e.merged = $mg.bytes; $e.why = $mg.how }
              else { $e.cls = 'own-setaside'; $e.why = ('the pipeline''s edit overlaps upstream''s (' + $mg.how + '); upstream wins') }
            }
          }
          '^ D$' { if ($owned) { $e.cls = 'own-deleted' } else { $e.cls = 'foreign'; $e.why = 'an uncommitted deletion nobody vouches for, on a path upstream changed' } }
          default { $e.cls = 'foreign'; $e.why = ('status ' + $code + ' is not a shape the sync carries; it is never written') }
        }
      }
      $entries.Add($e)
      if ($e.cls -eq 'foreign') { $foreign.Add($e) }
    }
  } finally { if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue } }
  $out.entries = $entries.ToArray(); $out.foreign = $foreign.ToArray(); $out.ok = $true
  return $out
}

# The pipeline's own edit onto upstream's: both sides only APPENDED (upstream's file plus this checkout's tail, exact),
# else a clean `git merge-file` in scratch. Worktree-form bytes on every side. Returns @{ ok; bytes; how }.
function Get-TcCsOwnMerge {
  param([string]$Path, [string]$H0, [string]$New, [string]$Scratch)
  if (-not (Test-Path -LiteralPath $Scratch)) { [void](New-Item -ItemType Directory -Path $Scratch -ErrorAction Stop) }
  $base = Get-TcCsWorktreeFormBytes -Repo $Repo -Spec ($H0 + ':' + $Path)
  $up = Get-TcCsWorktreeFormBytes -Repo $Repo -Spec ($New + ':' + $Path)
  $local = Read-TcCsSharedBytes (Get-TcCsFullPath $Repo $Path)
  if ((Test-TcCsBytePrefix $base $local) -and (Test-TcCsBytePrefix $base $up) -and $local.Length -gt $base.Length) {
    $tail = New-Object byte[] ($local.Length - $base.Length); [Array]::Copy($local, $base.Length, $tail, 0, $tail.Length)
    $joined = New-Object byte[] ($up.Length + $tail.Length); [Array]::Copy($up, 0, $joined, 0, $up.Length); [Array]::Copy($tail, 0, $joined, $up.Length, $tail.Length)
    return @{ ok = $true; bytes = $joined; how = 'append' }
  }
  $stem = Join-Path $Scratch ([guid]::NewGuid().ToString('N'))
  [IO.File]::WriteAllBytes($stem + '.base', $base); [IO.File]::WriteAllBytes($stem + '.up', $up); [IO.File]::WriteAllBytes($stem + '.local', $local)
  # IN PLACE on the scratch copy, never -p: -p hands the result back through a decoded pipe, which drops a BOM.
  $mf = Invoke-GitCaptured -Repo $Repo -GitArgs @('merge-file', ($stem + '.local'), ($stem + '.base'), ($stem + '.up'))
  if ([int]$mf.rc -ne 0) { return @{ ok = $false; bytes = $null; how = ('git merge-file rc ' + $mf.rc) } }
  return @{ ok = $true; bytes = [IO.File]::ReadAllBytes($stem + '.local'); how = 'merge-file' }
}

# Step 8. The newest OBSERVED push tip (a value refs/remotes/<remote>/<branch> has held, by its reflog) on origin's
# first-parent chain, strictly after the merge base and strictly before the first commit touching a FOREIGN path.
# One `git log` call, parsed from -z; `git log` takes no --pathspec-from-file (measured, git 2.54.0.windows.1).
function Get-TcCsPartialTarget {
  param([string]$Repo, [string]$H0, [string]$O, [string]$Remote, [string]$Branch, [string[]]$Foreign)
  $res = @{ ok = $false; tip = ''; why = ''; blocker = ''; blocker_text = '' }
  $mb = (Invoke-TcCsGit -Repo $Repo -GitArgs @('merge-base', $H0, $O)).out
  if (-not $mb) { $res.why = 'HEAD and origin share no merge base'; return $res }
  $lg = Invoke-TcCsGit -Repo $Repo -GitArgs @('log', '--first-parent', '--diff-merges=first-parent', '--reverse', '--no-renames', '--name-only', '-z', '--format=%x01%H', ($mb + '..' + $O))
  if ($lg.rc -ne 0) { $res.why = ('git log exited ' + $lg.rc + ': ' + $lg.err); return $res }
  $fset = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::Ordinal)
  foreach ($f in @($Foreign)) { [void]$fset.Add($f) }
  $chain = [System.Collections.Generic.List[string]]::new(); $blockAt = -1
  foreach ($t in (Split-TcCsNul $lg.raw)) {
    $tok = $t.TrimStart("`n")
    if (-not $tok) { continue }
    if ($tok[0] -eq [char]1) { $chain.Add($tok.Substring(1).Trim()); continue }
    if ($blockAt -lt 0 -and $chain.Count -and $fset.Contains($tok)) { $blockAt = $chain.Count - 1 }
  }
  if ($blockAt -lt 0) { $res.why = 'no upstream commit on origin''s first-parent chain touches them (the change is the local commits'' own)'; return $res }
  $e = $chain[$blockAt]
  $subj = (Invoke-TcCsGit -Repo $Repo -GitArgs @('log', '-1', '--format=%s', $e)).out
  $res.blocker = $e; $res.blocker_text = ('first changed upstream by ' + $e.Substring(0, 9) + ' "' + $subj + '"')
  $rl = Invoke-TcCsGit -Repo $Repo -GitArgs @('reflog', 'show', '--format=%H', ('refs/remotes/' + $Remote + '/' + $Branch))
  $seen = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::Ordinal)
  foreach ($h in @($rl.out -split "`r?`n" | Where-Object { $_ })) { [void]$seen.Add($h.Trim()) }
  for ($i = $blockAt - 1; $i -ge 0; $i--) { if ($seen.Contains($chain[$i])) { $res.ok = $true; $res.tip = $chain[$i]; return $res } }
  $res.why = ('no observed push tip lies between the merge base and ' + $e.Substring(0, 9) + ' "' + $subj + '", which is the first upstream commit to change them')
  return $res
}

# The D paths whose disk state now equals NEW's (a blob, or absent where NEW deletes) and did not before read-tree:
# git's own partial writes. A path someone else wrote mid-sync equals neither and is never counted here.
function Get-TcCsGitWritten {
  param($Plan)
  $cands = @($Plan.entries | Where-Object { $_.cls -ne 'foreign' -and $_.cls -ne 'already-upstream' })
  $blobs = Get-TcCsDiskBlobs -Repo $Repo -Paths @($cands | ForEach-Object { $_.path })
  $out = [System.Collections.Generic.List[string]]::new()
  foreach ($e in $cands) {
    $nowDisk = if ($blobs.ContainsKey($e.path)) { [string]$blobs[$e.path] } else { '' }
    $newState = if ($e.st -eq 'D') { '' } else { $e.newBlob }
    # Before read-tree: a clean or restored owned path held H0's blob; in-the-way and own-deleted paths were absent.
    $preState = switch ($e.cls) { 'in-the-way' { '' } 'own-deleted' { '' } default { if ($e.st -eq 'A') { '' } else { $e.oldBlob } } }
    if ([string]::Equals($nowDisk, $newState, [StringComparison]::Ordinal) -and -not [string]::Equals($nowDisk, $preState, [StringComparison]::Ordinal)) { $out.Add($e.path) }
  }
  return , $out.ToArray()
}

# The paths upstream DELETES (and the sync may write) that are still on disk after read-tree: git's held-unlink warning.
function Get-TcCsDeletedLeftovers {
  param($Plan)
  $out = [System.Collections.Generic.List[string]]::new()
  foreach ($e in @($Plan.entries)) {
    if ($e.st -eq 'D' -and $e.cls -ne 'foreign' -and [IO.File]::Exists((Get-TcCsFullPath $Repo $e.path))) { $out.Add($e.path) }
  }
  return , $out.ToArray()
}

# BACKWARD: every D path back to its state before the sync, and every displaced byte back where it was. Returns '' when
# each restored path verifies against its step 7 fingerprint, else the paths that do not.
# THE INDEX OF EVERY NON-FOREIGN D PATH is reset to HEAD (H0 here: the ref has not moved), not only git's partial
# writes. Before the sync each of them held H0's entry (a clean or owned path) or none (an in-the-way path), and a
# read-tree that exited 0 before a later step refused (a held deletion, a ref that could not be locked) left EVERY one
# at NEW (review findings 1 and 6). After a refused read-tree the index is still H0, so the reset is a no-op there.
function Restore-TcCsPreSync {
  param($Plan, [string[]]$GitWrote)
  $bad = [System.Collections.Generic.List[string]]::new()
  if ($null -eq $Plan -or $null -eq $Plan.entries) { return '' }
  $byPath = @{}; foreach ($e in $Plan.entries) { $byPath[$e.path] = $e }
  $idxPaths = @(@($GitWrote) + @($Plan.entries | Where-Object { $_.cls -ne 'foreign' } | ForEach-Object { $_.path }) | Sort-Object -Unique)
  if ($idxPaths.Count) { $null = Invoke-TcCsGitPaths -Repo $Repo -Pre @('reset', '-q') -Paths $idxPaths }
  foreach ($p in @($GitWrote)) {
    $e = $byPath[$p]
    if ($e.cls -eq 'clean' -and $e.st -ne 'A') { $co = Invoke-TcCsGit -Repo $Repo -GitArgs @('checkout', $rec.H0, '--', $p); if ($co.rc -ne 0) { $bad.Add($p + ' (checkout rc ' + $co.rc + ')') } }
    else {
      # git wrote NEW's bytes at a path that held nothing before the move (an add, an in-the-way or an owned deletion):
      # those bytes are NEW's blob, recoverable from the object database, so git's copy is removed.
      $full = Get-TcCsFullPath $Repo $p
      if ([IO.File]::Exists($full)) { try { [IO.File]::Delete($full) } catch { $bad.Add($p + ' (could not remove git''s copy)') } }
    }
  }
  if ($ctx.ContainsKey('saved')) {
    foreach ($s in @($ctx.saved.ToArray())) {
      if ($s.kind -eq 'set-aside') { continue }   # a set-aside copy is the person's record; the undo copy restores
      $dst = Get-TcCsFullPath $Repo $s.path
      try {
        if ($s.moved) {
          if ([IO.File]::Exists($dst)) { [IO.File]::Delete($dst) }
          [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) -ErrorAction Stop)
          Move-Item -LiteralPath $s.copy -Destination $dst -ErrorAction Stop   # atomic-replace:allow putting a quarantined file back where it was
        } else { [IO.File]::Copy($s.copy, $dst, $true) }
      } catch { $bad.Add($s.path + ' (' + $_.Exception.Message + ')') }
    }
  }
  $after = Get-TcCsStatus $Repo
  $cleanBlobs = Get-TcCsDiskBlobs -Repo $Repo -Paths @($Plan.entries | Where-Object { $_.cls -eq 'clean' } | ForEach-Object { $_.path })
  foreach ($e in $Plan.entries) {
    if ($e.cls -eq 'foreign') { continue }
    if ($e.cls -eq 'clean') {
      # A clean path must not hold NEW's bytes over an index at H0. A path someone else wrote mid-sync is theirs.
      $nowDisk = if ($cleanBlobs.ContainsKey($e.path)) { [string]$cleanBlobs[$e.path] } else { '' }
      $newState = if ($e.st -eq 'D') { '' } else { $e.newBlob }
      if ([string]::Equals($nowDisk, $newState, [StringComparison]::Ordinal)) { $bad.Add($e.path + ' (holds upstream''s bytes over the old index)') }
      continue
    }
    $fpNow = Get-TcCsFingerprint $Repo $e.path $after.map
    if (-not [string]::Equals($fpNow, $e.fp, [StringComparison]::Ordinal)) { $bad.Add($e.path + ' (' + $e.cls + ': ' + $fpNow + ' <> ' + $e.fp + ')') }
  }
  return ($bad -join '; ')
}

# Step 10, after a forward move. Returns @{ worktree = '' or why; other = '' or why; behind_after }.
function Test-TcCsAfterMove {
  param($Plan, [string]$FullO, [bool]$IsPartial)
  $v = @{ worktree = ''; other = ''; behind_after = 0 }
  $h = (Invoke-TcCsGit -Repo $Repo -GitArgs @('rev-parse', 'HEAD')).out
  $sym = (Invoke-TcCsGit -Repo $Repo -GitArgs @('symbolic-ref', '-q', 'HEAD')).out
  $v.behind_after = [int](Invoke-TcCsGit -Repo $Repo -GitArgs @('rev-list', '--count', ($Plan.new + '..' + $FullO))).out
  $problems = [System.Collections.Generic.List[string]]::new()
  if (-not [string]::Equals($h, $Plan.new, [StringComparison]::Ordinal) -or -not [string]::Equals($sym, ('refs/heads/' + $Branch), [StringComparison]::Ordinal)) { $problems.Add('HEAD is ' + $h + ' (' + $sym + '), not ' + $Plan.new) }
  if ((Split-TcCsNul (Invoke-TcCsGit -Repo $Repo -GitArgs @('ls-files', '-u', '-z')).raw).Count) { $problems.Add('unmerged entries after the move') }
  $ops = Get-TcCsOperationsInProgress $Repo
  if ($ops.Count) { $problems.Add('an operation is in progress after the move: ' + ($ops -join ', ')) }
  if (-not $IsPartial -and $v.behind_after -ne 0) { $problems.Add('still ' + $v.behind_after + ' commit(s) behind origin after the move') }
  $dset = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::Ordinal)
  foreach ($e in $Plan.entries) { [void]$dset.Add($e.path) }
  # THE INDEX holds NEW on every path the move changed: HEAD alone can read right while the tree never moved.
  $cachedToks = Split-TcCsNul (Invoke-TcCsGit -Repo $Repo -GitArgs @('diff', '--cached', '-z', '--name-only', '--no-renames', $Plan.new)).raw
  $offIdx = @($cachedToks | Where-Object { $dset.Contains($_) })
  if ($offIdx.Count) { $problems.Add('the index does not hold the target on ' + $offIdx.Count + ' changed path(s): ' + ($offIdx -join ', ')) }
  # THE WORKTREE holds NEW on every changed path but the merged ones (j2: `checkout -B` exits 0 over a stale held file).
  $mergedSet = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::Ordinal)
  foreach ($e in @($Plan.entries | Where-Object { $_.cls -eq 'own-merge' })) { [void]$mergedSet.Add($e.path) }
  $wtBad = [System.Collections.Generic.List[string]]::new()
  foreach ($p in (Split-TcCsNul (Invoke-TcCsGit -Repo $Repo -GitArgs @('diff', '-z', '--name-only', '--no-renames')).raw)) {
    if ($dset.Contains($p) -and -not $mergedSet.Contains($p)) { $wtBad.Add($p) }
  }
  foreach ($e in $Plan.entries) {
    $full = Get-TcCsFullPath $Repo $e.path
    if ($e.st -eq 'D' -and [IO.File]::Exists($full) -and $e.cls -ne 'foreign') { $wtBad.Add($e.path + ' (still on disk where upstream deletes it)') }
    if ($e.cls -eq 'own-merge') {
      $b = if ([IO.File]::Exists($full)) { Read-TcCsSharedBytes $full } else { $null }
      if ($null -eq $b -or [Convert]::ToBase64String($b) -ne [Convert]::ToBase64String([byte[]]$e.merged)) { $wtBad.Add($e.path + ' (not the merged bytes)') }
    }
  }
  if ($wtBad.Count) { $v.worktree = ('' + $wtBad.Count + ' changed path(s) are not at the target on disk: ' + ($wtBad -join ', ')) }
  # THE FINGERPRINT of every dirty path outside the move (and every already-upstream path's bytes and mtime) is identical.
  $after = Get-TcCsStatus $Repo
  $fpBad = [System.Collections.Generic.List[string]]::new()
  $v.later = [System.Collections.Generic.List[string]]::new()
  foreach ($p in @($ctx.fp0.Keys)) {
    if ($ctx.ContainsKey('casPaths') -and $ctx.casPaths.Contains($p)) { continue }
    $fp0 = [string]$ctx.fp0[$p]
    $fpNow = Get-TcCsFingerprint $Repo $p $after.map
    if ([string]::Equals($fp0, $fpNow, [StringComparison]::Ordinal)) { continue }
    # A SAVE BY SOMEONE ELSE, NOT A WRITE BY THIS SYNC (review finding 4). Nothing here or in a two-way read-tree
    # writes a path outside the move, so a path whose status line(s) and index entry are unchanged and whose mtime
    # only moved FORWARD is a session saving its own file mid-sync: a note, never a failure. A status change, a
    # vanished file or an mtime that went backwards is still a failure.
    $k0 = $fp0.LastIndexOf('#'); $k1 = $fpNow.LastIndexOf('#')
    $d0 = @($fp0.Substring($k0 + 1).Split('|')); $d1 = @($fpNow.Substring($k1 + 1).Split('|'))
    if ([string]::Equals($fp0.Substring(0, $k0), $fpNow.Substring(0, $k1), [StringComparison]::Ordinal) -and $d0.Count -eq 2 -and $d1.Count -eq 2 -and ([long]$d1[1] -gt [long]$d0[1])) { $v.later.Add($p); continue }
    $fpBad.Add($p)
  }
  foreach ($e in @($Plan.entries | Where-Object { $_.cls -eq 'already-upstream' })) {
    $fpNow = Get-TcCsFingerprint $Repo $e.path $after.map
    if (-not [string]::Equals((Get-TcCsDiskPart $fpNow), (Get-TcCsDiskPart $e.fp), [StringComparison]::Ordinal)) { $fpBad.Add($e.path + ' (already upstream)') }
  }
  if ($fpBad.Count) { $problems.Add('' + $fpBad.Count + ' path(s) outside the move changed under the sync: ' + ($fpBad -join ', ')) }
  $v.other = ($problems -join '; ')
  return $v
}

if ($__csSelfTest) {
  # The suite lives beside this file so the library stays small enough to read whole; its last line is the verdict.
  & (Join-Path $PSScriptRoot 'test-checkout-sync.ps1')
  exit $LASTEXITCODE
}
