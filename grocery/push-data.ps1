<#
  push-data.ps1 - Run at the END of a LOCAL browser-store refresh (Baker's daily agent + weekly agent) to
  commit the freshly-pulled data to the repo, so the cloud recomputes with current prices instead of
  clobbering them with stale data.

  WHAT CHANGED AND WHY (2026-09-06, PLAN-top5-2026-09-06 area 3).

  This script was written in July for a tree that held only raw store inputs, and its safety rested
  entirely on that assumption. The assumption stopped being true when agents began editing CODE in the
  real working tree, and nothing re-checked it. On 2026-09-05 it was invoked twice, a minute apart, and
  its `git add -A` put 325 files on main - 192 of them .ps1 files MID-EDIT, 27 of which threw at startup.
  main held that for 59 minutes. Three defects in 32 lines, all three fixed here:

    1. `git add -A` with no pathspec. capture-run.ps1 had already learned the right pattern on
       2026-08-22 ("STAGE PIPELINE-OWNED PATHS ONLY - NEVER git add -A") and wrote its ownership list
       inline, where this script could not reach it. The list now lives in lib\bot-paths.ps1 and BOTH
       read it, along with the pre-commit hook that refuses a bot commit which strays outside it.
    2. `git commit ... 2>&1 | Out-Null` discarded the commit's EXIT CODE. The pre-commit hook installed
       on 2026-09-05 can refuse a commit, and this script would not notice: it then pulled and pushed,
       shipping whatever was already committed, and printed "raw store inputs pushed". The commit's exit
       code is now the thing the rest of the run turns on.
    3. `git checkout --` over five files DISCARDED uncommitted local edits to smp-feed.json,
       published-board.sig, last-visibility.txt, price-history.json and alert-state.json, silently,
       before anything else ran. That is data loss, not misfiling. It is gone. Four of those five are
       pipeline-owned and are now COMMITTED like any other evidence; anything left dirty is REPORTED.

  A PRIVATE INDEX, BECAUSE EXPLICIT STAGING IS NOT ENOUGH. `git commit` with no pathspec commits the
  whole INDEX, so a bot that stages correctly still ships whatever a session left staged - that is the
  2026-08-25 shape (0c47012c). Every add and commit below runs under GIT_INDEX_FILE pointing at a temp
  index seeded from HEAD, so the bot commit is exactly its own staged set and the session's index is
  never disturbed.

  SERVED FILES ARE GATED ON THE GUARD VERDICT, exactly as capture-run gates them. export-feed writes
  public\smp-feed.json BEFORE guards run, and every recipe card prices off that feed, so a board the
  gate rejected must not reach the edge through this door either. No verdict for today = INPUTS ONLY,
  said out loud; the daily chain ships the served set on its next green run.

  NOTHING IS EVER SWEPT AND NOTHING IS EVER DISCARDED. A tracked file that is dirty and not owned by
  the pipeline is listed by name at the end of the run and left exactly where it is.
#>
$ErrorActionPreference = 'Continue'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')    # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\bot-paths.ps1')  # Get-BotInputPaths / Get-BotServedPaths: the ONE ownership list
$root = $PSScriptRoot
$repo = Split-Path $PSScriptRoot -Parent

$inputPaths  = Get-BotInputPaths
$servedPaths = Get-BotServedPaths

# THE GUARD VERDICT AS A VALUE, NEVER INFERRED FROM A LOG. check-ad-cycles writes it right after guards
# run. A verdict from another DAY is not a verdict for this board, and an unreadable one admits nothing.
$shipServed = $false
$verdictWhy = 'no chain verdict for today was found'
try {
  $vf = Join-Path $root 'out\chain-verdict.json'
  if (Test-Path -LiteralPath $vf) {
    $v = Read-JsonFile $vf
    $todayS = (Get-Date).ToString('yyyy-MM-dd')
    if ([string]$v.date -eq $todayS) {
      if ([bool]$v.guards_blocked) { $verdictWhy = 'guards BLOCKED today''s board' }
      else { $shipServed = $true; $verdictWhy = 'guards passed today''s board' }
    } else {
      $verdictWhy = ("the newest chain verdict is for " + [string]$v.date + ", not today")
    }
  }
} catch { $verdictWhy = ('chain-verdict unreadable: ' + $_.Exception.Message) }

$commitMsg = 'Local browser-store refresh ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')
$BotName   = 'smp-pipeline-bot'
$BotEmail  = 'actions@users.noreply.github.com'

# >>> PUSH-DATA COMMIT LANE (2026-09-06) - lifted verbatim by test-push-data.ps1 >>>
# Reads : $repo $inputPaths $servedPaths $shipServed $commitMsg $BotName $BotEmail $verdictWhy
# Writes: $staged $committed $commitRefused $pushed $leftoverDirty
# It runs against a THROWAWAY repo in the fixture and against the real one here - never a transcribed
# copy, which would pass forever while production drifted (the rule test-commit-size-gate already sets).
$staged = @(); $committed = $false; $commitRefused = $false; $pushed = $false; $leftoverDirty = @()
$owned = @($inputPaths + $(if ($shipServed) { $servedPaths } else { @() }))
if (-not $shipServed) {
  Write-Output ("push-data: staging INPUTS only - " + $verdictWhy + ", so public\** and the recipe files are NOT shipped by this run.")
}
# git EXITS NONZERO on a pathspec that matches nothing, so only pass what is actually there.
$paths = @($owned | Where-Object { Test-Path -LiteralPath (Join-Path $repo ($_ -replace '/', '\')) })
# The rotating alert-sent files are owned but their NAMES change daily; ask git whether any exist first.
$alertSent = @(& git -C $repo status --porcelain --untracked-files=all -- 'grocery/alert-sent-*.txt' | Where-Object { $_ })

# A PRIVATE INDEX. Seeded from HEAD, so this commit cannot carry a session's staged work, and the
# session's own index is never touched. try/finally, because PowerShell.Exiting does not fire under -File.
$tmpIndex = Join-Path $env:TEMP ('bot-index-' + [guid]::NewGuid().ToString('N'))
$prevIndex = $env:GIT_INDEX_FILE
try {
  $env:GIT_INDEX_FILE = $tmpIndex
  & git -C $repo read-tree HEAD | ForEach-Object { Write-Output ('read-tree: ' + $_) }
  if ($LASTEXITCODE -ne 0) { throw 'could not seed a private index from HEAD' }
  if ($alertSent.Count) { & git -C $repo add -A -- 'grocery/alert-sent-*.txt' | Out-Null }
  if ($paths.Count) { & git -C $repo add -A -- $paths | Out-Null }
  $staged = @(& git -C $repo diff --cached --name-only | Where-Object { $_ })
  if (-not $staged.Count) {
    Write-Output 'push-data: no pipeline-owned changes to push'
  } else {
    # THE EXIT CODE IS THE POINT. The pre-commit hook can refuse this commit; a run that does not read
    # the code goes on to push a DIFFERENT commit and reports success (defect 2).
    & git -C $repo -c user.name="$BotName" -c user.email="$BotEmail" commit -m $commitMsg |
      ForEach-Object { Write-Output ('commit: ' + $_) }
    if ($LASTEXITCODE -eq 0) {
      $committed = $true
      Write-Output ("push-data: committed " + $staged.Count + " pipeline-owned file(s) as $BotName")
    } else {
      $commitRefused = $true
      Write-Output ("push-data: COMMIT REFUSED (git exit " + $LASTEXITCODE + ") - a hook or git itself rejected it. NOTHING was pushed; the working tree is untouched.")
    }
  }
} catch {
  $commitRefused = $true
  Write-Output ('push-data: commit lane threw: ' + $_.Exception.Message + ' - NOTHING was pushed')
} finally {
  if ($null -eq $prevIndex) { Remove-Item Env:\GIT_INDEX_FILE -ErrorAction SilentlyContinue } else { $env:GIT_INDEX_FILE = $prevIndex }
  Remove-Item -LiteralPath $tmpIndex -Force -ErrorAction SilentlyContinue
}

# RESYNC THE SESSION'S INDEX FOR WHAT WE JUST COMMITTED, AND ONLY THAT. A private-index commit moves HEAD
# while the real index still holds the OLD blobs, so `git status` would show the just-committed files as a
# staged REVERT - one careless `git commit` away from undoing the run. Resetting the committed paths puts
# the real index back in step with HEAD; it never touches the working tree, and it never touches a path
# outside the commit, so a foreign file a session had staged is still staged afterwards.
if ($committed) {
  foreach ($f in $staged) { & git -C $repo reset -q -- $f | Out-Null }
}

if ($committed) {
  & git -C $repo fetch origin main | ForEach-Object { Write-Output ('fetch: ' + $_) }
  # ONLY REBASE WHEN THE REMOTE ACTUALLY MOVED. `rebase.autoStash` carries a human's WIP across
  # untouched in CONTENT, but it restores it with `stash apply`, which does NOT restore the INDEX: a
  # file a session had deliberately staged comes back unstaged, and on a shared tree that is somebody
  # else's work quietly changing state under them. On the ordinary run origin/main is already an
  # ancestor of HEAD and no rebase is needed at all, so ask first and touch nothing when the answer is
  # no. (When the remote HAS moved there is no way round it, and content-preserved beats not-pushed.)
  & git -C $repo merge-base --is-ancestor origin/main HEAD
  $needRebase = ($LASTEXITCODE -ne 0)
  $rebaseOk = $true
  if ($needRebase) {
    # NEVER STRAND A DETACHED HEAD. -X theirs prefers the freshly regenerated derived files, which is
    # what capture-run's push learned on 2026-07-16.
    Write-Output 'push-data: origin/main moved - rebasing (autoStash restores WIP content, but not what was STAGED)'
    & git -C $repo -c rebase.autoStash=true rebase -X theirs origin/main | ForEach-Object { Write-Output ('rebase: ' + $_) }
    $rebaseOk = ($LASTEXITCODE -eq 0)
  }
  if (-not $rebaseOk) {
    & git -C $repo rebase --abort | ForEach-Object { Write-Output ('abort: ' + $_) }
    Write-Output 'push-data: rebase conflict - committed locally but NOT pushed; will retry next run'
  } else {
    & git -C $repo push origin HEAD:main | ForEach-Object { Write-Output ('push: ' + $_) }
    if ($LASTEXITCODE -eq 0) { $pushed = $true; Write-Output 'push-data: pushed - the cloud will recompute with current prices' }
    else { Write-Output 'push-data: PUSH FAILED (network/auth) - committed locally; will retry next run' }
  }
}

# WHAT WE DID NOT TAKE, SAID OUT LOUD. The old sweep took everything and told nobody; the correct
# opposite is not silence, it is a named list. A path that keeps appearing here either belongs in
# lib\bot-paths.ps1 or belongs to a session - and only a human can tell which.
$leftoverDirty = @(& git -C $repo status --porcelain | Where-Object { $_ } | ForEach-Object { ($_ -replace '^.{2,3}', '').Trim().Trim('"') } |
                   Where-Object { $_ -and -not (Test-BotPathOwned -Path $_) })
if ($leftoverDirty.Count) {
  Write-Output ("push-data: LEFT ALONE - " + $leftoverDirty.Count + " dirty path(s) outside lib\bot-paths.ps1's ownership list (not swept, not discarded):")
  $leftoverDirty | Select-Object -First 20 | ForEach-Object { Write-Output ('  ' + $_) }
  if ($leftoverDirty.Count -gt 20) { Write-Output ('  ...and ' + ($leftoverDirty.Count - 20) + ' more') }
}
# <<< PUSH-DATA COMMIT LANE <<<

# THE LAST LINE IS THE ONE THE CALLERS KEEP. Both RunChild wrappers log `-Last $keep` lines with keep=1,
# so a verdict stated only in the middle of the transcript is a verdict nobody reads.
if ($commitRefused) {
  Write-Output 'push-data: FAILED - the commit was REFUSED and nothing was pushed. Prices did not leave this machine.'
  exit 1
}
if ($committed -and -not $pushed) { Write-Output 'push-data: committed locally but NOT pushed - the live site still serves the previous board'; exit 0 }
Write-Output ('push-data: OK (' + $(if ($pushed) { 'pushed ' + $staged.Count + ' file(s)' } else { 'nothing to push' }) + ', ' + $leftoverDirty.Count + ' unowned dirty path(s) left alone)')
exit 0
