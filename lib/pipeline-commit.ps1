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

function Invoke-PipelineCommit {
  <# Commit exactly $Paths under a private index. Returns a verdict string.

     Guarded throughout: a lane that cannot commit is degraded, and a lane KILLED BY its committer has
     lost a night's work - the same rule run-log-lib states for logging. #>
  param(
    [Parameter(Mandatory=$true)][string]$Repo,
    [Parameter(Mandatory=$true)][string[]]$Paths,
    [Parameter(Mandatory=$true)][string]$Message,
    [Parameter(Mandatory=$true)][string]$Name,
    [switch]$Push
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
    if (-not $staged.Count) {
      return ("{0}: nothing changed under its owned paths" -f $Name)
    }
    # BELT AND BRACES. The list was asserted above; this asserts what git ACTUALLY staged, because a
    # directory path like grocery/out could in principle acquire a script.
    $badStaged = Assert-NoSourcePaths $staged
    if ($badStaged.Count) {
      return ("REFUSED: {0} staged source under a data path and will not commit it: {1}" -f $Name, (($badStaged | Select-Object -First 6) -join ', '))
    }
    & git -C $Repo -c user.name="smp-pipeline-bot" -c user.email="actions@users.noreply.github.com" commit -m $Message -- $present | Out-Null
    $rc = $LASTEXITCODE
    if ($rc -ne 0) { return ("{0}: commit refused (git exit {1}) - a hook or git itself rejected it; the tree is untouched" -f $Name, $rc) }
  } catch {
    return ("{0}: committer threw and was swallowed (the lane's work is not lost, only uncommitted): {1}" -f $Name, $_.Exception.Message)
  } finally {
    if ($held) { if ($null -eq $prevIndex) { Remove-Item Env:\GIT_INDEX_FILE -ErrorAction SilentlyContinue } else { $env:GIT_INDEX_FILE = $prevIndex } }
    if ($tmpIndex -and (Test-Path $tmpIndex)) { Remove-Item $tmpIndex -Force -ErrorAction SilentlyContinue }
  }

  $msg = ("{0}: committed {1} file(s)" -f $Name, $staged.Count)
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

  T 'CLEAN TWIN a data path list is accepted' ((Assert-NoSourcePaths @('grocery/out', 'meal-prep/db/costed.json')).Count -eq 0)

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

  if ($fail -gt 0) { Write-Output ("SELF-TEST FAIL: {0} case(s)" -f $fail); exit 1 }
  Write-Output 'SELF-TEST PASS: the source-path refusal in eight shapes, every real path list proved data-only and non-empty, no path owned twice, and the committer refusing before it touches git'
  exit 0
}
