<#
  pipeline-commit.ps1 - a scheduled lane commits the paths it OWNS, and cannot commit source.

  WHY THIS EXISTS (2026-09-07). capture-run.ps1 was the only committer in the estate. check-ad-cycles
  does all the pricing work and commits nothing - it is called BY capture-run, which commits
  afterwards - so the commit was bound to the ENTRY POINT rather than to the work. Any other route into
  the same pipeline left its output uncommitted: on 2026-09-06 the work ran four times and the
  committer ran twice, and 153 files sat dirty for twenty hours, including a recost priced off a board
  that had since been corrected.

  WHAT THIS IS NOT, AND MUST NEVER BECOME. It is not a sweeper. ops\audit-git-sweepers.ps1 forbids
  `git add -A` without a `--` pathspec after four incidents of one shape, the most recent on
  2026-09-05: push-data.ps1 put 325 files on main, 192 of them .ps1 MID-EDIT, 27 of which threw at
  startup, and left them there for 59 minutes. A sweeper running at 21:30 on 2026-09-06 would have
  committed one session's half-finished agent prompts and another's in-progress gates. "Never
  uncommitted again" implemented that way is worse than the problem it solves.

  THE LOAD-BEARING PART IS Assert-NoSourcePaths. A data committer running unattended, in a tree that
  humans and agents are editing at the same time, must be structurally incapable of staging source. Not
  "careful not to" - incapable. That is what makes this safe where a sweeper is not, and it is the
  direct answer to 2026-09-05.

  IT REUSES capture-run's PRIVATE-INDEX PATTERN AND DOES NOT REFACTOR IT. `git commit` with no pathspec
  commits the whole INDEX, so a bot that adds exactly its own paths still ships whatever a session left
  staged in the same shared tree - that is 2026-08-25 (0c47012c), where an unrelated unit rode out under
  the pipeline's name. Seeding a temp index from HEAD makes the commit exactly its own add set and
  leaves the session's index untouched. capture-run's own stage is deliberately untouched: it works, and
  it carries the scar tissue of four incidents.

  PUSH POLICY: TRY ONCE, NEVER BLOCK. Four schedulers can race. Each caller attempts a single push and,
  on failure, leaves the commit local and says so - the next capture-run pushes it. A commit that exists
  locally is already the whole of what "not uncommitted" means, and a retry loop between four
  schedulers is a worse failure than a late push.

  Dot-source:  . (Join-Path $repoRoot 'lib\pipeline-commit.ps1')
  Self-test:   powershell -File lib\pipeline-commit.ps1 -SelfTest

  THIS FILE DECLARES NO param() BLOCK, DELIBERATELY - the trap guard-contract.ps1 documents. In PS 5.1
  dot-sourcing runs a param() block in the CALLER's scope, so a param([switch]$SelfTest) here would
  reset every caller's own -SelfTest to $false on the line after it bound.
#>
$__pcSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

# Invoke-GitCaptured / Format-GitRefusal (2026-09-09, queue 2026-09-09-a95022). The commit below piped
# STDOUT ONLY, and the pre-commit hook writes its entire diagnosis to STDERR, so a refusal here reported
# an exit code and nothing else - the identical blind spot capture-run.ps1:857 had, found the day both
# scheduled runs were refused over one file nobody could name. Sourced from THIS file's own directory so
# it resolves wherever the repo is checked out, worktree included.
. (Join-Path $PSScriptRoot 'git-blob-lib.ps1')

# Anything that is CODE or CONFIG, in the broadest reading. Deliberately over-inclusive: the cost of a
# false refusal is that a human commits a data file by hand, and the cost of a false accept is
# 2026-09-05. Those are not remotely the same price.
$script:PC_SOURCE_RX = '(?i)(\.ps1|\.py|\.psm1|\.psd1|\.sh|\.yml|\.yaml|\.md|\.js|\.ts|\.html|\.css)$|^\.claude/|^ops/|^lib/|^\.github/|^docs/|^design/'

function Get-PipelinePaths {
  <# The paths each scheduled lane OWNS. One list per owner, and no path appears under two owners -
     two committers racing for the same file is a merge conflict on a schedule. #>
  param([Parameter(Mandatory=$true)][ValidateSet('pricing', 'graph', 'harvest')][string]$Kind)
  switch ($Kind) {
    'pricing' {
      return @(
        'grocery/out',
        'grocery/product-urls.json',
        'grocery/notify-known-ids.json',
        'grocery/sale-fallback-ownership.json',
        'meal-prep/db/costed.json',
        'meal-prep/db/costed.stamp.json',
        'meal-prep/db/recipes',
        'meal-prep/recipes-db.json',
        'meal-prep/ingredient-map.json',
        'meal-prep/free-rotation.json',
        'meal-prep/pipeline/v2-perserving.json',
        'meal-prep/pipeline/v2-perserving.prev.json'
        # public/** and site/tools/*.html are DELIBERATELY ABSENT. Committing public/board.json IS
        # the feed deploy - it is what readers get - and a scheduled data committer has no business
        # deploying. capture-run still ships those under its own publish decision, which is where a
        # ship belongs. The .html files would be refused by the source assertion anyway.
      )
    }
    'graph' {
      return @(
        'graph/identity',
        'graph/learning',
        'graph/provenance',
        'graph/state',
        'grocery/out/semantic-findings.json',
        'grocery/out/logs/graph-nightly-status.json'
      )
    }
    'harvest' {
      return @(
        'meal-prep/db/candidate-pool.json',
        'meal-prep/db/harvest-state.json',
        'meal-prep/db/source-domains.json',
        'meal-prep/db/considered-dishes.json'
      )
    }
  }
}

function Assert-NoSourcePaths {
  <# THE SAFETY INVARIANT. Returns the offending paths; empty means the list is data-only.

     A caller MUST refuse to commit when this returns anything. It is checked against the declared
     PATH LIST rather than against what git happened to stage, because the list is the thing a human
     reviews and the thing that can be tested without a repo. #>
  param([string[]]$Paths)
  $bad = @()
  foreach ($p in @($Paths)) {
    $n = ([string]$p).Replace('\', '/').TrimStart('./')
    if ($n -match $script:PC_SOURCE_RX) { $bad += $p }
  }
  return $bad
}

# ---- FOREIGN-HELD FILES: a session's dirty file is not the run's to commit (2026-09-10, queue 2026-09-10-3a9de4) ----
# THE CLASS. Both committers stage their owned paths WHOLE - grocery/out is 1,342 tracked files and a run writes
# a few hundred of them - so any session's uncommitted edit under an owned path rode into the bot commit, and the
# pre-commit hook, judging the STAGED set, refused the ENTIRE commit. On 2026-09-09 one BOM-stripped
# json-readers-baseline.json refused both scheduled commits and the edge served a stale feed all day. a95022
# made the refusal NAME the file; it did not stop the refusal.
# THE RULE. Snapshot the owned files that are already dirty when the run STARTS; at commit time, a snapshot file
# whose LastWriteTime is still before the run started was not rewritten by the run, so it is unstaged and named.
# Everything the run wrote is committed, and the hook stays fail-closed over what remains staged.
# WHAT IT CANNOT DO, stated so nobody reads it as more: an edit a session makes DURING the run to a file the run
# never writes has an mtime after the start and cannot be attributed, so it is still staged. A snapshot that
# cannot be taken holds NOTHING back and says so - it never silently stages less.
function Get-DirtyOwnedSnapshot {
  <# The tracked files under $Paths that are MODIFIED in the working tree now, each with its LastWriteTime.
     Returns [pscustomobject]@{ ok; files = [pscustomobject]@{ path; mtime }[]; why }. #>
  param([Parameter(Mandatory = $true)][string]$Repo, [Parameter(Mandatory = $true)][string[]]$Paths)
  $present = @($Paths | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $Repo $_)) })
  if (-not $present.Count) { return [pscustomobject]@{ ok = $true; files = @(); why = 'no owned path exists' } }
  $g = Invoke-GitCaptured -Repo $Repo -GitArgs (@('status', '--porcelain', '--untracked-files=no', '--') + $present)
  if ($g.rc -ne 0) { return [pscustomobject]@{ ok = $false; files = @(); why = ('git status exited ' + $g.rc + ': ' + ([string]$g.stderr).Trim()) } }
  $files = New-Object System.Collections.Generic.List[object]
  foreach ($line in @(([string]$g.stdout) -split "`r?`n")) {
    if ($line.Length -lt 4) { continue }
    # The WORKTREE column: ' M' and 'MM'. A staged-only change, a rename or a deletion is not a file the run
    # could have been handed dirty and then hold back unchanged.
    if ($line[1] -ne 'M') { continue }
    $rel = $line.Substring(3).Trim()
    if ($rel.Length -ge 2 -and $rel.StartsWith('"') -and $rel.EndsWith('"')) { $rel = $rel.Substring(1, $rel.Length - 2) }
    $full = Join-Path $Repo $rel
    if (-not (Test-Path -LiteralPath $full)) { continue }
    $files.Add([pscustomobject]@{ path = $rel; mtime = (Get-Item -LiteralPath $full).LastWriteTime })
  }
  return [pscustomobject]@{ ok = $true; files = $files.ToArray(); why = '' }
}

function Get-PathMtimes {
  <# path -> LastWriteTime for each path that still exists. A path missing from the map is not held. #>
  param([Parameter(Mandatory = $true)][string]$Repo, [string[]]$Paths)
  $map = @{}
  foreach ($p in @($Paths)) {
    if (-not $p) { continue }
    $full = Join-Path $Repo $p
    if (Test-Path -LiteralPath $full) { $map[[string]$p] = (Get-Item -LiteralPath $full).LastWriteTime }
  }
  return $map
}

function Get-ForeignHeldPaths {
  <# PURE. From a start-of-run snapshot, the files the run did NOT rewrite: dirty before it started and with an
     mtime still before $RunStart. A file rewritten by the run (mtime at or after the start) is the run's own.
     An unusable snapshot holds nothing back. Comma-returned, so a caller assigns it and reads .Count. #>
  param($Snapshot, [datetime]$RunStart, $CurrentMtimes)
  $held = New-Object System.Collections.Generic.List[string]
  if ($null -eq $Snapshot -or -not $Snapshot.ok -or $null -eq $CurrentMtimes) { return ,$held.ToArray() }
  foreach ($f in @($Snapshot.files)) {
    if ($null -eq $f) { continue }
    $p = [string]$f.path
    if (-not $CurrentMtimes.ContainsKey($p)) { continue }
    if ([datetime]$CurrentMtimes[$p] -lt $RunStart) { $held.Add($p) }
  }
  return ,$held.ToArray()
}

function Invoke-PipelineCommit {
  <# Commit exactly $Paths under a private index. Returns a verdict string.

     Guarded throughout: a lane that cannot commit is degraded, and a lane KILLED BY its committer has
     lost a night's work - the same rule run-log-lib states for logging. #>
  param(
    [Parameter(Mandatory=$true)][string]$Repo,
    [Parameter(Mandatory=$true)][string[]]$Paths,
    [Parameter(Mandatory=$true)][string]$Message,
    [Parameter(Mandatory=$true)][string]$Name,
    [switch]$Push,
    # THE CALLER'S START-OF-RUN SNAPSHOT (2026-09-10, queue 2026-09-10-3a9de4) - pass both or neither. With them,
    # an owned file that was already dirty when the caller's run started and has not been rewritten since is
    # unstaged and named instead of refusing the whole commit. Without them this behaves exactly as before.
    $DirtyAtStart = $null,
    [datetime]$RunStart = [datetime]::MinValue
  )
  $bad = Assert-NoSourcePaths $Paths
  if ($bad.Count) {
    return ("REFUSED: {0} would stage source or config, which a scheduled data committer must never do: {1}. This is the 2026-09-05 shape and the refusal is the feature." -f $Name, ($bad -join ', '))
  }

  $present = @($Paths | Where-Object { Test-Path (Join-Path $Repo $_) })
  if (-not $present.Count) { return ("{0}: nothing to commit - none of its owned paths exist" -f $Name) }

  $tmpIndex = $null; $prevIndex = $null; $held = $false
  try {
    # A PRIVATE INDEX, for the reason capture-run.ps1 documents: `git commit` with no pathspec commits
    # the whole INDEX, so staging exactly our own paths is not enough while a session shares the tree.
    $tmpIndex = Join-Path $env:TEMP ('pipe-index-' + [guid]::NewGuid().ToString('N'))
    $prevIndex = $env:GIT_INDEX_FILE
    $env:GIT_INDEX_FILE = $tmpIndex
    $held = $true
    & git -C $Repo read-tree HEAD | Out-Null
    & git -C $Repo add -A -- $present | Out-Null
    $staged = @(& git -C $Repo diff --cached --name-only | Where-Object { $_ })
    # FOREIGN-HELD (2026-09-10, queue 2026-09-10-3a9de4): unstage what another session dirtied before this run
    # started and the run did not rewrite. See Get-ForeignHeldPaths above.
    $foreignHeld = @()
    $foreignNote = ''
    if (($null -ne $DirtyAtStart) -and ($RunStart -gt [datetime]::MinValue)) {
      if (-not $DirtyAtStart.ok) {
        $foreignNote = ('; foreign-held: the start-of-run snapshot is unavailable (' + [string]$DirtyAtStart.why + '), so nothing was held back')
      } else {
        $fhNow = Get-PathMtimes -Repo $Repo -Paths @($DirtyAtStart.files | ForEach-Object { [string]$_.path })
        $foreignHeld = Get-ForeignHeldPaths -Snapshot $DirtyAtStart -RunStart $RunStart -CurrentMtimes $fhNow
        foreach ($fh in $foreignHeld) { & git -C $Repo reset -q -- $fh | Out-Null }
        if ($foreignHeld.Count) {
          $foreignNote = ('; foreign-held: ' + $foreignHeld.Count + ' tracked owned file(s) another session dirtied before this run started, left uncommitted: ' + ($foreignHeld -join ', '))
          $staged = @(& git -C $Repo diff --cached --name-only | Where-Object { $_ })
        }
      }
    }
    if (-not $staged.Count) {
      return ("{0}: nothing changed under its owned paths{1}" -f $Name, $foreignNote)
    }
    # BELT AND BRACES. The list was asserted above; this asserts what git ACTUALLY staged, because a
    # directory path like grocery/out could in principle acquire a script.
    $badStaged = Assert-NoSourcePaths $staged
    if ($badStaged.Count) {
      return ("REFUSED: {0} staged source under a data path and will not commit it: {1}" -f $Name, (($badStaged | Select-Object -First 6) -join ', '))
    }
    # CAPTURE BOTH STREAMS (2026-09-09, queue 2026-09-09-a95022). `| Out-Null` discarded stdout and the
    # hook's stderr never entered this process at all, so this lane's refusal string could only ever say
    # "a hook rejected it" - which is the sentence that cost a full reproduction on 09-09. No `2>&1` and no
    # `2>$null`: under EAP=Stop a native child's redirected stderr becomes a terminating error.
    # WITH A FILE HELD BACK THE COMMIT TAKES THE INDEX, NOT THE PATHSPEC (2026-09-10, queue 2026-09-10-3a9de4):
    # `git commit -- <paths>` commits the WORKING TREE of everything under those paths, which would put the held
    # file straight back into the commit. With nothing held, the call is exactly what it was.
    $commitTail = if ($foreignHeld.Count) { @() } else { @('--') + @($present) }
    $cRes = Invoke-GitCaptured -Repo $Repo -GitArgs (@(
      '-c', 'user.name=smp-pipeline-bot', '-c', 'user.email=actions@users.noreply.github.com',
      'commit', '-m', $Message) + $commitTail)
    $rc = $cRes.rc
    if ($rc -ne 0) {
      $refusal = Format-GitRefusal -Rc $rc -Stderr $cRes.stderr
      return ("{0}: commit refused (git exit {1}) - a hook or git itself rejected it; the tree is untouched{4}. {2}`n{3}" -f `
              $Name, $rc, $refusal.summary, (($refusal.transcript) -join "`n"), $foreignNote)
    }
  } catch {
    return ("{0}: committer threw and was swallowed (the lane's work is not lost, only uncommitted): {1}" -f $Name, $_.Exception.Message)
  } finally {
    if ($held) { if ($null -eq $prevIndex) { Remove-Item Env:\GIT_INDEX_FILE -ErrorAction SilentlyContinue } else { $env:GIT_INDEX_FILE = $prevIndex } }
    if ($tmpIndex -and (Test-Path $tmpIndex)) { Remove-Item $tmpIndex -Force -ErrorAction SilentlyContinue }
  }

  $msg = ("{0}: committed {1} file(s){2}" -f $Name, $staged.Count, $foreignNote)
  if ($Push) {
    try {
      & git -C $Repo push origin HEAD:main | Out-Null
      if ($LASTEXITCODE -eq 0) { $msg += ' and pushed' }
      else { $msg += ' - push failed, left local for the next capture-run to carry' }
    } catch { $msg += ' - push threw, left local for the next capture-run to carry' }
  }
  return $msg
}

if ($__pcSelfTest) {
  $fail = 0
  function T($n, $c, $g = '') { if ($c) { Write-Output ("ok    " + $n) } else { Write-Output ("FAIL  " + $n + "   got: " + $g); $script:fail++ } }

  T 'MUST NOT FIRE a data path list is accepted' ((Assert-NoSourcePaths @('grocery/out', 'meal-prep/db/costed.json')).Count -eq 0)

  # THE FOUNDING CASE, 2026-09-05: 192 .ps1 files on main, mid-edit.
  T 'MUST FIRE  a .ps1 path is refused' ((Assert-NoSourcePaths @('grocery/out', 'grocery/capture-run.ps1')).Count -eq 1)
  T 'MUST FIRE  a .py path is refused' ((Assert-NoSourcePaths @('meal-prep/pipeline/harvest.py')).Count -eq 1)
  T 'MUST FIRE  the agent prompts are refused' ((Assert-NoSourcePaths @('.claude/agents/recipe-writer.md')).Count -eq 1)
  T 'MUST FIRE  ops/ is refused even with no extension' ((Assert-NoSourcePaths @('ops/hooks/pre-commit')).Count -eq 1)
  T 'MUST FIRE  lib/ is refused' ((Assert-NoSourcePaths @('lib/pipeline-commit.ps1')).Count -eq 1)
  T 'MUST FIRE  a backslash path is normalised before matching, not missed' ((Assert-NoSourcePaths @('ops\audit-write-seam.ps1')).Count -eq 1)
  T 'MUST FIRE  design/ notes are refused - they are a human''s to commit' ((Assert-NoSourcePaths @('design/PLAN-x.md')).Count -eq 1)
  T 'MUST FIRE  a site template is refused' ((Assert-NoSourcePaths @('site/tools/dinner-tonight-tool.html')).Count -eq 1)

  # EVERY REAL LIST MUST PASS ITS OWN ASSERTION, or a lane ships that cannot ever commit.
  foreach ($k in @('pricing', 'graph', 'harvest')) {
    $p = Get-PipelinePaths -Kind $k
    $bad = Assert-NoSourcePaths $p
    T ("the $k list is data-only and can actually commit") ($bad.Count -eq 0) ($bad -join ', ')
    T ("the $k list is not empty") (@($p).Count -gt 0) (@($p).Count)
  }

  # NO PATH MAY HAVE TWO OWNERS - two committers racing for one file is a scheduled merge conflict.
  $all = @()
  foreach ($k in @('pricing', 'graph', 'harvest')) { $all += (Get-PipelinePaths -Kind $k) }
  $dupes = @($all | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
  T 'MUST FIRE  no path is owned by two lanes' ($dupes.Count -eq 0) ($dupes -join ', ')

  $v = Invoke-PipelineCommit -Repo 'C:\nope' -Paths @('ops/audit-write-seam.ps1') -Message 'x' -Name 'probe'
  T 'MUST FIRE  the committer REFUSES a source path before touching git at all' ($v -like 'REFUSED:*') $v

  $v2 = Invoke-PipelineCommit -Repo 'C:\nope' -Paths @('grocery/out/definitely-not-here.json') -Message 'x' -Name 'probe'
  T 'a path that does not exist is nothing to commit, not an error' ($v2 -like '*nothing to commit*') $v2

  # ---- FOREIGN-HELD (2026-09-10, queue 2026-09-10-3a9de4) ----------------------------------------------------------
  # PURE: the rule itself, with frozen times.
  $t0 = [datetime]'2026-09-10T07:00:00'
  # A NEUTRAL fixture directory, lane/out. The rule is path-agnostic, and spelling another module's internals from lib\
  # is a cross-module reach (ops\audit-cross-module-reach.ps1 caught the first cut of these fixtures at 147 against 133).
  $snapOk = [pscustomobject]@{ ok = $true; why = ''; files = @(
    [pscustomobject]@{ path = 'lane/out/json-readers-baseline.json'; mtime = $t0.AddHours(-2) },
    [pscustomobject]@{ path = 'lane/out/capture-cursor.json'; mtime = $t0.AddHours(-2) }) }
  $now1 = @{ 'lane/out/json-readers-baseline.json' = $t0.AddHours(-2); 'lane/out/capture-cursor.json' = $t0.AddMinutes(5) }
  $h1 = Get-ForeignHeldPaths -Snapshot $snapOk -RunStart $t0 -CurrentMtimes $now1
  T 'MUST FIRE  a file dirty before the run and untouched since is held; the one the run rewrote is not' (($h1.Count -eq 1) -and ($h1[0] -eq 'lane/out/json-readers-baseline.json')) ($h1 -join ', ')
  $h2 = Get-ForeignHeldPaths -Snapshot ([pscustomobject]@{ ok = $false; files = @(); why = 'git status failed' }) -RunStart $t0 -CurrentMtimes $now1
  T 'MUST FIRE  a snapshot that could not be taken holds NOTHING back' ($h2.Count -eq 0) ($h2 -join ', ')
  $h3 = Get-ForeignHeldPaths -Snapshot $snapOk -RunStart $t0 -CurrentMtimes @{ 'lane/out/capture-cursor.json' = $t0.AddMinutes(5) }
  T 'MUST NOT FIRE a snapshot file that has since disappeared is not held' ($h3.Count -eq 0) ($h3 -join ', ')

  # END TO END in a throwaway repo, repository environment cleared first (ops rule: a fixture that builds a temp repo
  # must not inherit GIT_DIR or GIT_INDEX_FILE from a hook). FROZEN from the founding case: a session stripped the BOM
  # from a pipeline-written baseline (grocery's json-readers-baseline.json, 2026-09-09) before the run started, and the
  # run never rewrote it. Same neutral lane/out directory; the run's own output is a .txt, so the fixture writes no
  # out\*.json report family that nothing reads (ops\audit-write-only-reports.ps1).
  $savedGitEnv = @{}
  foreach ($ev in @('GIT_DIR', 'GIT_INDEX_FILE', 'GIT_WORK_TREE')) { $savedGitEnv[$ev] = [Environment]::GetEnvironmentVariable($ev); [Environment]::SetEnvironmentVariable($ev, $null) }
  $tr = Join-Path $env:TEMP ('pc-fh-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    New-Item -ItemType Directory -Path (Join-Path $tr 'lane\out') -Force | Out-Null
    & git -C $tr init -q . | Out-Null
    & git -C $tr config user.email t@t | Out-Null
    & git -C $tr config user.name t | Out-Null
    $fA = Join-Path $tr 'lane\out\json-readers-baseline.json'
    $fB = Join-Path $tr 'lane\out\run-output.txt'
    [IO.File]::WriteAllBytes($fA, ([byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes('{"n":1}')))
    [IO.File]::WriteAllText($fB, 'v1')
    & git -C $tr add -A -- lane/out | Out-Null
    & git -C $tr commit -q -m seed | Out-Null
    [IO.File]::WriteAllBytes($fA, [Text.Encoding]::UTF8.GetBytes('{"n":1}'))
    (Get-Item $fA).LastWriteTime = (Get-Date).AddHours(-2)
    $snapE = Get-DirtyOwnedSnapshot -Repo $tr -Paths @('lane/out')
    T 'the start snapshot sees exactly the foreign dirty file' (($snapE.ok) -and (@($snapE.files).Count -eq 1)) ('' + @($snapE.files).Count)
    $rs = (Get-Date).AddMinutes(-30)
    [IO.File]::WriteAllText($fB, 'v2')
    $ve = Invoke-PipelineCommit -Repo $tr -Paths @('lane/out') -Message 'run' -Name 'probe' -DirtyAtStart $snapE -RunStart $rs
    $inHead = @(& git -C $tr show --name-only --pretty=format: HEAD | Where-Object { $_ })
    $stillDirty = @(& git -C $tr status --porcelain | Where-Object { $_ })
    T 'MUST FIRE  the commit carries only the run''s file, names the held one, and leaves it dirty in the worktree (today''s code refused the whole commit here)' `
      (($ve -match 'committed 1 file') -and ($ve -match 'foreign-held: 1 .*json-readers-baseline\.json') -and (($inHead -join ',') -eq 'lane/out/run-output.txt') -and (($stillDirty -join ',') -match 'json-readers-baseline\.json')) ($ve + ' | head=' + ($inHead -join ',') + ' | dirty=' + ($stillDirty -join ','))
    # CLEAN TWIN: the same foreign file, dirty at start AND rewritten by the run, is committed as the run's own.
    [IO.File]::WriteAllText($fB, 'v3')
    $snapT = Get-DirtyOwnedSnapshot -Repo $tr -Paths @('lane/out')
    $rs2 = (Get-Date).AddMinutes(-1)
    [IO.File]::WriteAllBytes($fA, ([byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes('{"n":2}')))
    [IO.File]::WriteAllText($fB, 'v4')
    $vt = Invoke-PipelineCommit -Repo $tr -Paths @('lane/out') -Message 'run2' -Name 'probe' -DirtyAtStart $snapT -RunStart $rs2
    T 'CLEAN TWIN  a foreign file the run rewrote is committed as the run''s own (2 files, nothing held)' (($vt -match 'committed 2 file') -and ($vt -notmatch 'foreign-held')) $vt
  } finally {
    Remove-Item -LiteralPath $tr -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($ev in @($savedGitEnv.Keys)) { [Environment]::SetEnvironmentVariable($ev, $savedGitEnv[$ev]) }
  }

  if ($fail -gt 0) { Write-Output ("SELF-TEST FAIL: {0} case(s)" -f $fail); exit 1 }
  Write-Output 'SELF-TEST PASS: the source-path refusal in eight shapes, every real path list proved data-only and non-empty, no path owned twice, and the committer refusing before it touches git'
  exit 0
}
