<#
  test-capture-run-sync.ps1 - capture-run's checkout sync, at the start of a run and at its tail, proven on the SHIPPED
  code (design\PLAN-bot-checkout-self-heal-2026-09-23.md W4.1 and W4.2).

  WHY. On 2026-09-23 both scheduled runs executed on a checkout about 14 hours behind origin, because capture-run moved
  the checkout only after a commit, and 09-22's commit had been refused; its tail then moved it with an autostash rebase
  that could strand a rebase directory, leave conflict markers at exit 0 and rewrite every dirty file's mtime.
  lib\checkout-sync.ps1 is the replacement mover and has its own suite. THIS file proves capture-run's side: the start
  sync runs before any capture, a conflict or a mixed tree stops the run before any capture, a move onto new startup
  code re-executes capture-run.ps1 ONCE under the parent's lock, an abandoned lock is not taken while the synced child
  of a killed parent still runs, and the tail syncs instead of rebasing.

  IT RUNS THE SHIPPED CODE, NEVER A COPY. Functions are lifted out of grocery\capture-run.ps1 by AST and blocks by their
  markers, and run against throwaway repos: a bare remote, an "up" clone for every other pusher, and a "bot" clone for
  the shared main checkout, all under one per-run directory in %TEMP% removed in `finally`, after Clear-TcGitRepoEnv.
  A case that must see a real `exit` (the blocked exit, the handoff) runs the lifted region in a CHILD powershell, whose
  exit code is the thing asserted. Every lock here is a per-run Local\ fixture name; nothing opens Global\tc-capture-run,
  the production carry ledger, the write journal or the sync record of this checkout.

  SCOPE OF A CLEAN REPORT: a pass proves the listed behaviours of capture-run's sync call sites over these fixtures on
  this machine, with the real lib\checkout-sync.ps1. It proves nothing about the scheduled tasks, the real remote, or
  the capture lanes, which are stubbed by a sentinel file.

  Run:   powershell -NoProfile -File grocery\test-capture-run-sync.ps1
  Exit:  0 every case passed and the count is the literal below; 1 otherwise; 3 a marker or function could not be found
         (BLIND, nothing proven). The last line is the verdict.
#>
# gate-inputs: grocery\test-capture-run-sync.ps1, grocery\capture-run.ps1, grocery\run-log-lib.ps1, grocery\native-lib.ps1, lib\checkout-sync.ps1, lib\git-blob-lib.ps1, lib\git-repo-env.ps1, lib\atomic-write.ps1, lib\append-line.ps1, lib\pipeline-commit.ps1, lib\ledger-lock.ps1, lib\event-bus.ps1, lib\json-io.ps1
$ErrorActionPreference = 'Stop'
$repoLib = Join-Path (Split-Path $PSScriptRoot -Parent) 'lib'
. (Join-Path $repoLib 'git-repo-env.ps1'); Clear-TcGitRepoEnv
. (Join-Path $repoLib 'json-io.ps1')
. (Join-Path $repoLib 'checkout-sync.ps1')
. (Join-Path $repoLib 'pipeline-commit.ps1')
# Loaded here, so the TAIL-PUSH block finds Invoke-Native and never dot-sources native-lib from the fixture's grocery\.
. (Join-Path $PSScriptRoot 'native-lib.ps1')
$env:GIT_TERMINAL_PROMPT = '0'

$EXPECTED_CASES = 36
$script:pass = 0; $script:fail = 0
function T([string]$Label, [bool]$Cond, [string]$Got = '') {
  if ($Cond) { $script:pass++; Write-Output ('  ok    ' + $Label) }
  else { $script:fail++; Write-Output ('  FAIL  ' + $Label + '   got: ' + $Got) }
}
function Invoke-Group([string]$Name, [scriptblock]$Body) {
  Write-Output $Name
  try { & $Body } catch { $script:fail++; Write-Output ('  FAIL  the group threw: ' + $_.Exception.Message + ' (at ' + $_.InvocationInfo.ScriptLineNumber + ')') }
}

# ---- THE SHIPPED CODE -------------------------------------------------------------------------------------------------
$crPath = Join-Path $PSScriptRoot 'capture-run.ps1'
if (-not (Test-Path -LiteralPath $crPath)) { Write-Output ('BLIND: capture-run.ps1 not found beside this fixture (' + $crPath + ') - nothing was proven'); Write-Output 'capture-run-sync SELF-TEST BLIND'; exit 3 }
$crSrc = [IO.File]::ReadAllText($crPath)
$crAst = [System.Management.Automation.Language.Parser]::ParseInput($crSrc, [ref]$null, [ref]$null)
$fnNames = @('Write-RunStatus', 'Add-FailedLane', 'Set-FailedLanePaged', 'Release-RunMutex', 'Test-CaptureRunPidAlive', 'Get-CaptureRunInheritedLock',
  'Get-CaptureRunCommandLine', 'Get-CaptureRunOrphanHolder', 'Enter-CaptureRunMutex', 'ConvertTo-CaptureRunSyncStatus', 'Format-CaptureRunSyncLine',
  'Get-StartSyncAction', 'Invoke-CaptureRunHandoff', 'Invoke-CaptureRunTailSync', 'Invoke-CaptureRunOwedTailSync')
$fnAsts = @($crAst.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $fnNames -contains $a.Name }, $true))
$fnFound = @($fnAsts | ForEach-Object { $_.Name } | Sort-Object -Unique)
if ($fnFound.Count -ne $fnNames.Count) { Write-Output ('BLIND: capture-run.ps1 defines ' + $fnFound.Count + ' of the ' + $fnNames.Count + ' functions this fixture lifts (' + ($fnFound -join ', ') + ') - nothing was proven'); Write-Output 'capture-run-sync SELF-TEST BLIND'; exit 3 }
$fnText = ((@($fnAsts) | ForEach-Object { $_.Extent.Text }) -join "`n`n")
. ([scriptblock]::Create($fnText))
function Get-Between([string]$Src, [string]$A, [string]$B) {
  $i = $Src.IndexOf($A); if ($i -lt 0) { return $null }
  $j = $Src.IndexOf($B, $i); if ($j -lt 0) { return $null }
  return $Src.Substring($i, $j - $i)
}
$startBlock = Get-Between $crSrc '# >>> START-SYNC BLOCK >>>' '# <<< START-SYNC BLOCK <<<'
$startRegion = Get-Between $crSrc '# >>> START-SYNC BLOCK >>>' '# ---- WHAT IS ALREADY DIRTY UNDER THE OWNED PATHS'
if (-not $startBlock -or -not $startRegion) { Write-Output 'BLIND: could not find the START-SYNC markers in capture-run.ps1 - nothing was proven'; Write-Output 'capture-run-sync SELF-TEST BLIND'; exit 3 }
$tailBlock = Get-Between $crSrc '  # >>> TAIL-PUSH BLOCK >>>' '  # <<< TAIL-PUSH BLOCK <<<'
$tailFinally = Get-Between $crSrc '  # >>> TAIL-FINALLY BLOCK >>>' '  # <<< TAIL-FINALLY BLOCK <<<'
if (-not $tailBlock -or -not $tailFinally) { Write-Output 'BLIND: could not find the TAIL-PUSH or TAIL-FINALLY markers in capture-run.ps1 - nothing was proven'; Write-Output 'capture-run-sync SELF-TEST BLIND'; exit 3 }

# ---- FIXTURES ---------------------------------------------------------------------------------------------------------
$script:fxRoot = Join-Path $env:TEMP ('tc-crs-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
New-Item -ItemType Directory -Path $script:fxRoot -ErrorAction Stop | Out-Null
$script:fxN = 0
$script:fxUtf8 = New-Object Text.UTF8Encoding($false)
$script:pages = New-Object System.Collections.Generic.List[string]
function Send-Alert { param($Subject, $Body) [void]$script:pages.Add([string]$Subject); $global:LASTEXITCODE = 0 }
function Get-BotInputPaths { return @('grocery') }
function Get-BotServedPaths { return @('public') }
$script:fxSeams = @{ IndexLockWaitSec = 0; InProgressWaitSec = 0; HeldRetrySec = 0; PollSec = 0; FetchAttempts = 1; FetchRetrySec = 0 }

function GitR([string]$Dir, [string[]]$A) {
  $g = Invoke-GitCaptured -Repo $Dir -GitArgs (@('-c', 'core.quotePath=false') + $A)
  return [pscustomobject]@{ rc = [int]$g.rc; out = ([string]$g.stdout).Trim(); raw = [string]$g.stdout; err = ([string]$g.stderr).Trim() }
}
function GitOk([string]$Dir, [string[]]$A) { $g = GitR $Dir $A; if ($g.rc -ne 0) { throw ('git ' + ($A -join ' ') + ' exited ' + $g.rc + ': ' + $g.err) }; return $g.out }
function W([string]$Dir, [string]$Rel, [string]$Text) {
  $p = Join-Path $Dir ($Rel -replace '/', '\'); New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) | Out-Null
  [IO.File]::WriteAllText($p, $Text, $script:fxUtf8)
}
function FetchStamp([string[]]$Paths) { return ((@($Paths) | ForEach-Object { if (Test-Path -LiteralPath $_) { $_ + '=' + (Get-Item -LiteralPath $_).LastWriteTimeUtc.Ticks } else { $_ + '=absent' } }) -join ';') }
function New-Estate([string]$Name) {
  $script:fxN++
  $d = Join-Path $script:fxRoot ('' + $script:fxN + '-' + $Name); New-Item -ItemType Directory -Path $d | Out-Null
  $remote = Join-Path $d 'remote.git'
  $null = GitOk $d @('init', '-q', '--bare', '-b', 'main', $remote)
  $up = Join-Path $d 'up'; $bot = Join-Path $d 'bot'
  $null = GitOk $d @('-c', 'core.autocrlf=false', 'clone', '-q', $remote, $up)
  foreach ($kv in @(@('core.autocrlf', 'false'), @('user.name', 'fx'), @('user.email', 'fx@x'))) { $null = GitOk $up (@('config') + $kv) }
  W $up 'lib/code.ps1' "line1`nline2`nline3`n"
  W $up 'public/derived.json' "{`n  ""v"": 1`n}`n"
  W $up 'grocery/ledger.json' "a`nb`nc`n"
  W $up 'grocery/capture-run.ps1' "# the capture-run this checkout started with`n"
  W $up 'tools/verifier.txt' "strict`n"
  W $up '.gitignore' "/grocery/out/untracked-quarantine/`n"
  $null = GitOk $up @('add', '-A'); $null = GitOk $up @('commit', '-q', '-m', 'base'); $null = GitOk $up @('push', '-q', '-u', 'origin', 'HEAD:main')
  $null = GitOk $d @('-c', 'core.autocrlf=false', 'clone', '-q', $remote, $bot)
  foreach ($kv in @(@('core.autocrlf', 'false'), @('user.name', 'fx'), @('user.email', 'fx@x'))) { $null = GitOk $bot (@('config') + $kv) }
  return [pscustomobject]@{ dir = $d; remote = $remote; up = $up; bot = $bot; status = (Join-Path $d 'status.json'); pagesFile = (Join-Path $d 'pages.txt'); sentinel = (Join-Path $d 'lane-ran.txt') }
}
function Push-Up($E, [string]$Rel, [string]$Text, [string]$Msg) { W $E.up $Rel $Text; $null = GitOk $E.up @('add', '-A'); $null = GitOk $E.up @('commit', '-q', '-m', $Msg); $null = GitOk $E.up @('push', '-q', 'origin', 'HEAD:main') }

# The start-sync BLOCK in this process, with the variables capture-run holds at that point.
function Invoke-StartBlock($E, [hashtable]$Vars = @{}) {
  $root = Join-Path $E.bot 'grocery'
  if ($Vars.ContainsKey('Root')) { $root = $Vars['Root'] }
  $Kind = 'daily'; $todayS = '2026-09-23'; $runLog = $null
  $WhatIf = [bool]$Vars['WhatIf']; $NoDownstream = [bool]$Vars['NoDownstream']; $NoSync = [bool]$Vars['NoSync']
  $script:HandedOffBy = [string]$Vars['HandedOffBy']; $script:MutexInherited = $false
  $script:StatusFile = $E.status; $script:RunStart = Get-Date; $script:FailedLaneRecs = @()
  $script:CommitSizeStatus = $null; $script:HeldDeletions = @(); $script:SyncStatus = $null; $script:DirtyAtStart = $null
  $script:CaptureRunSyncSeams = $script:fxSeams
  $failed = @()
  $script:pages.Clear()
  $out = . ([scriptblock]::Create($startBlock))
  return [pscustomobject]@{ action = $script:StartSyncAction; rec = $script:SyncRecord; status = $script:SyncStatus; pages = @($script:pages); failed = ($failed -join ','); text = ((@($out) | ForEach-Object { [string]$_ }) -join "`n") }
}

# The bot's commit exactly as capture-run makes it: a private index seeded from HEAD, the owned paths added whole, the
# commit, then the real index left as it was, which is the leftover the tail's -BotCommit resync must clear.
function New-BotCommit($E, [string[]]$Paths) {
  $tmp = Join-Path $E.dir ('bot-index-' + [guid]::NewGuid().ToString('N'))
  $prev = $env:GIT_INDEX_FILE
  $env:GIT_INDEX_FILE = $tmp
  try {
    $null = GitOk $E.bot @('read-tree', 'HEAD')
    $null = GitOk $E.bot (@('add', '-A', '--') + $Paths)
    $null = GitOk $E.bot @('-c', 'user.name=smp-pipeline-bot', '-c', 'user.email=actions@users.noreply.github.com', 'commit', '-q', '-m', 'Daily pipeline: refresh prices + feed (2026-09-23) [daily]')
  } finally {
    if ($null -eq $prev) { Remove-Item Env:\GIT_INDEX_FILE -ErrorAction SilentlyContinue } else { $env:GIT_INDEX_FILE = $prev }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  }
  return (GitOk $E.bot @('rev-parse', 'HEAD'))
}
# The TAIL-PUSH block in this process, as capture-run holds its variables after a commit landed.
function Invoke-TailPush($E, [string]$BotSha, [hashtable]$Vars = @{}) {
  $repo = $E.bot; $root = Join-Path $E.bot 'grocery'; $Kind = 'daily'; $today = '2026-09-23'; $todayS = $today
  $botMadeCommit = $true; $script:BotCommitSha = $BotSha
  $shipServed = $false; $servedPaths = @('public'); $pushed = $false; $failed = @(); $NoSync = [bool]$Vars['NoSync']
  $script:TailRetrySec = 0; $script:TailSyncOwed = $true; $script:TailSyncStatus = $null; $script:FailedLaneRecs = @()
  $script:CaptureRunSyncSeams = $script:fxSeams
  $script:pages.Clear()
  $out = . ([scriptblock]::Create($tailBlock))
  $remoteTip = (GitR $E.remote @('rev-parse', 'refs/heads/main')).out
  return [pscustomobject]@{ pushed = [bool]$pushed; failed = ($failed -join ','); pages = @($script:pages); owed = [bool]$script:TailSyncOwed; remote = $remoteTip; status = $script:TailSyncStatus; text = ((@($out) | ForEach-Object { [string]$_ }) -join "`n") }
}
$script:tailTexts = New-Object System.Collections.Generic.List[string]

# A child powershell running a generated script; stdout and stderr to files, the exit code read off the process.
function Invoke-FxChild([string]$Script, [hashtable]$EnvVars = @{}) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell'
  $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Script + '"'
  $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  foreach ($k in @('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR')) { if ($psi.EnvironmentVariables.ContainsKey($k)) { $psi.EnvironmentVariables.Remove($k) } }
  foreach ($k in @($EnvVars.Keys)) { $psi.EnvironmentVariables[$k] = [string]$EnvVars[$k] }
  $p = [System.Diagnostics.Process]::Start($psi)
  $tO = $p.StandardOutput.ReadToEndAsync(); $tE = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit(600000)) { try { $p.Kill() } catch { }; return [pscustomobject]@{ rc = -2; out = 'the child hung past the 600 s hang guard'; err = '' } }
  [void]$tO.Wait(10000); [void]$tE.Wait(10000)
  $r = [pscustomobject]@{ rc = [int]$p.ExitCode; out = [string]$tO.Result; err = [string]$tE.Result }
  $p.Dispose()
  return $r
}
function Q([string]$S) { return ("'" + $S.Replace("'", "''") + "'") }
# The shipped start REGION (the block, the blocked exit and the handoff) run in a child, then a sentinel "capture lane".
function New-RegionHarness($E, [string]$MutexName, [string]$Body = '') {
  $h = Join-Path $E.dir 'harness.ps1'
  if (-not $Body) { $Body = ($startRegion + "`n[IO.File]::WriteAllText(" + (Q $E.sentinel) + ", 'a capture lane ran')`nexit 0") }
  $lines = @(
    '$ErrorActionPreference = ''Stop''',
    ('. ' + (Q (Join-Path $repoLib 'git-repo-env.ps1')) + '; Clear-TcGitRepoEnv'),
    ('. ' + (Q (Join-Path $repoLib 'json-io.ps1'))),
    ('. ' + (Q (Join-Path $repoLib 'checkout-sync.ps1'))),
    ('. ' + (Q (Join-Path $repoLib 'pipeline-commit.ps1'))),
    ('. ' + (Q (Join-Path $PSScriptRoot 'run-log-lib.ps1'))),
    $fnText,
    ('function Send-Alert { param($Subject, $Body) [IO.File]::AppendAllText(' + (Q $E.pagesFile) + ', ([string]$Subject + "`n")); $global:LASTEXITCODE = 0 }'),
    'function Get-BotInputPaths { return @(''grocery'') }',
    'function Get-BotServedPaths { return @(''public'') }',
    ('$root = ' + (Q (Join-Path $E.bot 'grocery')) + '; $Kind = ''daily''; $WhatIf = $false; $NoDownstream = $false; $NoSync = $false; $todayS = ''2026-09-23''; $OutDir = ' + (Q (Join-Path $E.dir 'out'))),
    '$runLog = $null; $script:RunStart = Get-Date; $script:FailedLaneRecs = @(); $script:CommitSizeStatus = $null; $script:HeldDeletions = @(); $script:SyncStatus = $null; $script:DirtyAtStart = $null',
    ('$script:StatusFile = ' + (Q $E.status)),
    '$script:HandedOffBy = ''''; $script:MutexInherited = $false',
    '$script:CaptureRunSyncSeams = @{ IndexLockWaitSec = 0; InProgressWaitSec = 0; HeldRetrySec = 0; PollSec = 0; FetchAttempts = 1; FetchRetrySec = 0 }',
    ('$script:RunMutexName = ' + (Q $MutexName)),
    '$script:RunMutex = New-Object System.Threading.Mutex($false, $script:RunMutexName); $script:HoldsMutex = $script:RunMutex.WaitOne(0)',
    '$script:TailSyncOwed = $false; $script:TailSyncStatus = $null; $script:TailRetrySec = 0',
    $Body
  )
  [IO.File]::WriteAllText($h, ($lines -join "`n"), (New-Object Text.UTF8Encoding($true)))
  return $h
}

try {
  Invoke-Group 'PURE - what a start sync''s outcome makes the run do' {
    T 'MUST FIRE  blocked/conflict stops the run before any capture' ((Get-StartSyncAction -Record ([pscustomobject]@{ outcome = 'blocked'; class = 'conflict' }) -HandedOff $false) -eq 'exit-blocked')
    T 'MUST FIRE  failed/mixed-tree stops the run before any capture' ((Get-StartSyncAction -Record ([pscustomobject]@{ outcome = 'failed'; class = 'mixed-tree' }) -HandedOff $false) -eq 'exit-blocked')
    T 'MUST NOT FIRE blocked/foreign and degraded continue on the HEAD they have' (((Get-StartSyncAction -Record ([pscustomobject]@{ outcome = 'blocked'; class = 'foreign' }) -HandedOff $false) -eq 'continue') -and ((Get-StartSyncAction -Record ([pscustomobject]@{ outcome = 'degraded'; class = 'fetch'; startup_changed = $true }) -HandedOff $false) -eq 'continue'))
    T 'MUST FIRE  synced or partial onto new startup code re-executes' (((Get-StartSyncAction -Record ([pscustomobject]@{ outcome = 'synced'; startup_changed = $true }) -HandedOff $false) -eq 'reexec') -and ((Get-StartSyncAction -Record ([pscustomobject]@{ outcome = 'partial'; startup_changed = $true }) -HandedOff $false) -eq 'reexec'))
    T 'MUST NOT FIRE a handed-off child never re-executes, whatever its record says' ((Get-StartSyncAction -Record ([pscustomobject]@{ outcome = 'synced'; startup_changed = $true }) -HandedOff $true) -eq 'continue')
    T 'MUST NOT FIRE no record, or synced with no startup change, continues' (((Get-StartSyncAction -Record $null -HandedOff $false) -eq 'continue') -and ((Get-StartSyncAction -Record ([pscustomobject]@{ outcome = 'synced'; startup_changed = $false }) -HandedOff $false) -eq 'continue'))
  }

  Invoke-Group 'PURE - a handoff token is honoured only for this lock and a live holder' {
    $fx = 'Local\tc-crs-token'
    $ok1 = Get-CaptureRunInheritedLock -Holder ('' + $PID + '|0123456789abcdef|' + $fx) -MutexName $fx
    T 'MUST FIRE  a token naming this lock and a live pid is inherited' ($ok1.inherited) $ok1.why
    $no1 = Get-CaptureRunInheritedLock -Holder ('' + $PID + '|0123456789abcdef|Local\another-lock') -MutexName $fx
    $no2 = Get-CaptureRunInheritedLock -Holder ('' + $PID + '|0123456789abcdef|' + $fx) -MutexName $fx -IsAlive { param($p) $false }
    $no3 = Get-CaptureRunInheritedLock -Holder 'not-a-token' -MutexName $fx
    $no4 = Get-CaptureRunInheritedLock -Holder '' -MutexName $fx
    T 'MUST NOT FIRE another lock''s token, a dead holder, a malformed token and no token are never inherited' ((-not $no1.inherited) -and (-not $no2.inherited) -and (-not $no3.inherited) -and (-not $no4.inherited)) ($no1.why + ' | ' + $no2.why + ' | ' + $no3.why + ' | ' + $no4.why)
  }

  Invoke-Group 'F1 MUST FIRE - the founding bug over two runs: run 2''s START sync pulls the fix and lands both days' {
    $E = New-Estate 'f1'
    # Run 1: the day's capture, a start sync with nothing upstream, and a commit the stale verifier refuses.
    W $E.bot 'grocery/cap/cap-2026-09-22.csv' "day1`n"
    $r1 = Invoke-StartBlock $E
    $c1 = if ([IO.File]::ReadAllText((Join-Path $E.bot 'tools/verifier.txt')) -match 'strict') { 'refused' } else { 'committed' }
    T 'run 1: the start sync finds the checkout current, and the stale verifier refuses the commit' ($r1.rec.outcome -eq 'current' -and $c1 -eq 'refused') ($r1.rec.outcome + ' ' + $c1)
    # Upstream fixes the verifier that evening (09-22 21:34 in the incident).
    Push-Up $E 'tools/verifier.txt' "lenient`n" 'up: the verifier fix'
    W $E.bot 'grocery/cap/cap-2026-09-23.csv' "day2`n"
    $r2 = Invoke-StartBlock $E
    $c2 = if ([IO.File]::ReadAllText((Join-Path $E.bot 'tools/verifier.txt')) -match 'strict') { 'refused' } else { 'committed' }
    if ($c2 -eq 'committed') { $null = GitOk $E.bot @('add', '-A', '--', 'grocery'); $null = GitOk $E.bot @('commit', '-q', '-m', 'bot: both days') }
    $tree = GitR $E.bot @('ls-tree', '-r', '--name-only', 'HEAD', '--', 'grocery/cap')
    T 'run 2: the start sync is synced with behind_after 0, and the commit lands BOTH days' ($r2.rec.outcome -eq 'synced' -and [int]$r2.rec.behind_after -eq 0 -and $c2 -eq 'committed' -and ($tree.out -match 'cap-2026-09-22\.csv') -and ($tree.out -match 'cap-2026-09-23\.csv')) ($r2.rec.outcome + ' behind_after=' + $r2.rec.behind_after + ' ' + $c2 + ' tree=' + $tree.out)
    T 'run 2: the status record carries the sync as synced, and the line is printed' ($r2.status.outcome -eq 'synced' -and ($r2.text -match 'sync\[start\]: synced')) ([string]$r2.status.outcome + ' | ' + $r2.text)
  }

  Invoke-Group 'BLOCKED MUST FIRE - conflict markers in a session''s dirty file stop the run with exit 1 before any capture lane' {
    $E = New-Estate 'blocked'
    Push-Up $E 'public/derived.json' "{`n  ""v"": 2`n}`n" 'up: derived'
    W $E.bot 'lib/code.ps1' ("line1`n" + ('<' * 7) + " ours`nline2-a`n" + ('=' * 7) + "`nline2-b`n" + ('>' * 7) + " theirs`nline3`n")
    $h = New-RegionHarness $E ('Local\tc-crs-blk-' + [guid]::NewGuid().ToString('N'))
    $c = Invoke-FxChild $h
    $st = if (Test-Path -LiteralPath $E.status) { Read-JsonFile $E.status } else { $null }
    $pg = if (Test-Path -LiteralPath $E.pagesFile) { [IO.File]::ReadAllText($E.pagesFile) } else { '' }
    T 'the run exits 1 and no capture lane ran (the sentinel is absent)' ($c.rc -eq 1 -and -not (Test-Path -LiteralPath $E.sentinel)) ('rc=' + $c.rc + ' sentinel=' + (Test-Path -LiteralPath $E.sentinel) + ' err=' + $c.err)
    T 'the status record reads stage blocked-checkout, exit 1, failed lane sync, and the page names the markers' ($null -ne $st -and [string]$st.daily.stage -eq 'blocked-checkout' -and [string]$st.daily.exit_code -eq '1' -and ((@($st.daily.failed_lanes | ForEach-Object { $_.lane }) -join ',') -eq 'sync') -and ($pg -match 'Grocery bot BLOCKED: the main checkout holds conflict markers - 2026-09-23')) ('stage=' + $(if ($st) { $st.daily.stage } else { 'none' }) + ' pages=' + $pg)
    T 'nothing moved: HEAD is still the base commit' ((GitR $E.bot @('rev-list', '--count', 'HEAD')).out -eq '1') (GitR $E.bot @('rev-list', '--count', 'HEAD')).out
  }

  Invoke-Group 'HANDOFF MUST FIRE - new startup code re-executes capture-run.ps1 as a child that inherits the lock' {
    $E = New-Estate 'handoff'
    $stub = @(
      '$ErrorActionPreference = ''Stop''',
      '$src = [IO.File]::ReadAllText($env:TCX_SRC)',
      '$ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)',
      'foreach ($fn in @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and @(''Test-CaptureRunPidAlive'', ''Get-CaptureRunInheritedLock'', ''Enter-CaptureRunMutex'') -contains $a.Name }, $true))) { . ([scriptblock]::Create($fn.Extent.Text)) }',
      '$inh = Get-CaptureRunInheritedLock -Holder ([string]$env:TC_CAPTURE_RUN_LOCK_HOLDER) -MutexName $env:TCX_MUTEX',
      '$mx = New-Object System.Threading.Mutex($false, $env:TCX_MUTEX)',
      '$st = Enter-CaptureRunMutex -Mutex $mx -Inherited $inh -WaitSec 2',
      '[IO.File]::WriteAllText($env:TCX_STATUS, (''{"daily":{"stage":"complete","pid":'' + $PID + ''}}''))',
      'Write-Output (''CHILD-BLOB '' + (& git hash-object -- $PSCommandPath))',
      'Write-Output (''CHILD-WAITED '' + $st.waited + '' INHERITED '' + $st.inherited + '' HELD '' + $st.held)',
      'Write-Output (''CHILD-SYNCED '' + $env:TC_CAPTURE_RUN_SYNCED)',
      'exit 7'
    ) -join "`n"
    Push-Up $E 'grocery/capture-run.ps1' ($stub + "`n") 'up: capture-run changed'
    $newBlob = GitOk $E.up @('rev-parse', 'HEAD:grocery/capture-run.ps1')
    $newSha = GitOk $E.up @('rev-parse', 'HEAD')
    $mxName = 'Local\tc-crs-ho-' + [guid]::NewGuid().ToString('N')
    $h = New-RegionHarness $E $mxName
    $c = Invoke-FxChild $h @{ TCX_SRC = $crPath; TCX_MUTEX = $mxName; TCX_STATUS = $E.status }
    T 'the parent exits with the child''s code (7), and the parent ran no capture lane' ($c.rc -eq 7 -and -not (Test-Path -LiteralPath $E.sentinel)) ('rc=' + $c.rc + ' out=' + $c.out + ' err=' + $c.err)
    T 'the child ran the NEW capture-run.ps1 (it printed its own blob)' ($c.out -match ('CHILD-BLOB ' + $newBlob)) ('want ' + $newBlob + ' out=' + $c.out)
    T 'the child INHERITED the lock and never called WaitOne (mutant M8 target)' ($c.out -match 'CHILD-WAITED False INHERITED True HELD True') $c.out
    T 'the child was told which commit its parent synced to' ($c.out -match ('CHILD-SYNCED ' + $newSha + '\|[0-9a-f]{32}')) $c.out
  }

  Invoke-Group 'ORPHAN MUST FIRE - an abandoned lock is not taken while the synced child of a killed parent still runs' {
    $od = Join-Path $script:fxRoot 'orphan'; New-Item -ItemType Directory -Path $od | Out-Null
    $mxName = 'Local\tc-crs-orph-' + [guid]::NewGuid().ToString('N')
    $release = Join-Path $od 'release.flag'; $ready = Join-Path $od 'ready.flag'; $status = Join-Path $od 'status.json'
    $childScript = Join-Path $od 'capture-run.ps1'
    # THE CHILD OPENS A HANDLE ON THE LOCK, as capture-run does before it decides to inherit (its New-Object line runs
    # first). That handle is what keeps the kernel mutex alive, and ABANDONED, when the parent is killed: with no other
    # handle open the mutex is destroyed with its owner and the next run creates a fresh, free one (measured while
    # building this case, which first read abandoned=False for exactly that reason).
    $childReady = Join-Path $od 'child-ready.flag'
    [IO.File]::WriteAllText($childScript, ('$mh = New-Object System.Threading.Mutex($false, ' + (Q $mxName) + '); [IO.File]::WriteAllText(' + (Q $childReady) + ', ''1''); $t =[Diagnostics.Stopwatch]::StartNew(); while (-not (Test-Path -LiteralPath ' + (Q $release) + ') -and $t.Elapsed.TotalSeconds -lt 300) { Start-Sleep -Milliseconds 100 }'))
    $parentScript = Join-Path $od 'parent.ps1'
    [IO.File]::WriteAllText($parentScript, ('$m = New-Object System.Threading.Mutex($false, ' + (Q $mxName) + '); [void]$m.WaitOne(); [IO.File]::WriteAllText(' + (Q $ready) + ', ''1''); $t = [Diagnostics.Stopwatch]::StartNew(); while ($t.Elapsed.TotalSeconds -lt 300) { Start-Sleep -Milliseconds 200 }'))
    $child = Start-Process -FilePath 'powershell' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $childScript) -PassThru -WindowStyle Hidden
    $parent = Start-Process -FilePath 'powershell' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $parentScript) -PassThru -WindowStyle Hidden
    try {
      $w = [Diagnostics.Stopwatch]::StartNew(); while (-not ((Test-Path -LiteralPath $ready) -and (Test-Path -LiteralPath $childReady)) -and $w.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 100 }
      [IO.File]::WriteAllText($status, ('{"daily":{"stage":"capturing","pid":' + $child.Id + '}}'))
      Stop-Process -Id $parent.Id -Force; $parent.WaitForExit()
      $m2 = New-Object System.Threading.Mutex($false, $mxName)
      $s1 = Enter-CaptureRunMutex -Mutex $m2 -Inherited $null -WaitSec 30 -OrphanCheck { Get-CaptureRunOrphanHolder -StatusFile $status }
      T 'the third run sees the lock ABANDONED and finds the child alive by its command line (capture-run.ps1)' ($s1.abandoned -and $null -ne $s1.orphan -and $s1.orphan.alive -and $s1.orphan.pid -eq $child.Id) ('abandoned=' + $s1.abandoned + ' orphan=' + $(if ($s1.orphan) { $s1.orphan.why } else { 'none' }))
      if ($s1.held) { try { $m2.ReleaseMutex() } catch { } }
      [IO.File]::WriteAllText($release, '1'); $child.WaitForExit(60000) | Out-Null
      # MUST NOT FIRE twin: a second killed holder, and the recorded child is now gone, so the lock is taken as before.
      Remove-Item -LiteralPath $ready -Force
      $parent2 = Start-Process -FilePath 'powershell' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $parentScript) -PassThru -WindowStyle Hidden
      $w = [Diagnostics.Stopwatch]::StartNew(); while (-not (Test-Path -LiteralPath $ready) -and $w.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 100 }
      Stop-Process -Id $parent2.Id -Force; $parent2.WaitForExit()
      $s2 = Enter-CaptureRunMutex -Mutex $m2 -Inherited $null -WaitSec 30 -OrphanCheck { Get-CaptureRunOrphanHolder -StatusFile $status }
      T 'MUST NOT FIRE an abandoned lock whose recorded capture-run is dead is taken, as before' ($s2.abandoned -and $s2.held -and $null -ne $s2.orphan -and -not $s2.orphan.alive) ('abandoned=' + $s2.abandoned + ' held=' + $s2.held + ' orphan=' + $(if ($s2.orphan) { $s2.orphan.why } else { 'none' }))
      if ($s2.held) { try { $m2.ReleaseMutex() } catch { } }
      $m2.Dispose()
    } finally {
      [IO.File]::WriteAllText($release, '1')
      foreach ($pp in @($parent, $child)) { try { if (-not $pp.HasExited) { $pp.Kill() } } catch { } }
    }
  }

  Invoke-Group 'NOT ARMED MUST NOT FIRE - -WhatIf, -NoSync and a linked worktree never fetch' {
    $E = New-Estate 'unarmed'
    Push-Up $E 'public/derived.json' "{`n  ""v"": 3`n}`n" 'up: derived'
    $fh = @((Join-Path $E.bot '.git\FETCH_HEAD'))
    $before = FetchStamp $fh
    $rW = Invoke-StartBlock $E @{ WhatIf = $true }
    $rN = Invoke-StartBlock $E @{ NoSync = $true }
    T '-WhatIf and -NoSync record skipped, print the would-be decision, and FETCH_HEAD is untouched' ($rW.status.outcome -eq 'skipped' -and $rN.status.outcome -eq 'skipped' -and ($rW.text -match 'nothing fetched or moved') -and (FetchStamp $fh) -eq $before -and (GitR $E.bot @('rev-list', '--count', 'HEAD')).out -eq '1') ($rW.text + ' | ' + $rN.text + ' | ' + (FetchStamp $fh))
    $wt = Join-Path $E.dir 'wt'
    $null = GitOk $E.bot @('worktree', 'add', '-q', '-b', 'wtb', $wt)
    $fh2 = @((Join-Path $E.bot '.git\FETCH_HEAD'), (Join-Path $E.bot '.git\worktrees\wt\FETCH_HEAD'))
    $before2 = FetchStamp $fh2
    $rL = Invoke-StartBlock $E @{ Root = (Join-Path $wt 'grocery') }
    T 'a linked worktree is skipped by the sync, continues, and fetches nothing' ($rL.rec.outcome -eq 'skipped' -and $rL.action -eq 'continue' -and (FetchStamp $fh2) -eq $before2) ([string]$rL.rec.outcome + ': ' + [string]$rL.rec.why + ' | ' + (FetchStamp $fh2))
  }

  Invoke-Group 'CHILD CLEAN TWIN - a handed-off child never syncs and never re-executes, even with new startup code upstream' {
    $E = New-Estate 'child'
    Push-Up $E 'grocery/capture-run.ps1' "# a newer capture-run`n" 'up: capture-run changed again'
    $fh = @((Join-Path $E.bot '.git\FETCH_HEAD')); $before = FetchStamp $fh
    $r = Invoke-StartBlock $E @{ HandedOffBy = 'abc123|0123456789abcdef0123456789abcdef' }
    T 'the child records synced-by-parent, continues, and fetches nothing' ($r.status.outcome -eq 'synced-by-parent' -and $r.action -eq 'continue' -and (FetchStamp $fh) -eq $before -and $null -eq $r.rec) ([string]$r.status.outcome + ' ' + $r.action + ' | ' + (FetchStamp $fh))
  }

  Invoke-Group 'KILL SWITCH - disabled pages once a day and the run continues on its HEAD' {
    $E = New-Estate 'kill'
    Push-Up $E 'public/derived.json' "{`n  ""v"": 4`n}`n" 'up: derived'
    [IO.File]::WriteAllText((Join-Path $E.bot '.git\tc-checkout-sync.disabled'), 'fixture')
    $r = Invoke-StartBlock $E
    $r2 = Invoke-StartBlock $E
    T 'the first run records disabled, continues, and pages "Grocery bot checkout sync disabled"; the second run of the date does not page' ($r.rec.outcome -eq 'disabled' -and $r.action -eq 'continue' -and ((@($r.pages) -join '|') -eq 'Grocery bot checkout sync disabled - 2026-09-23') -and @($r2.pages).Count -eq 0 -and (GitR $E.bot @('rev-list', '--count', 'HEAD')).out -eq '1') ([string]$r.rec.outcome + ' pages=' + (@($r.pages) -join '|') + ' second=' + (@($r2.pages) -join '|'))
  }

  Invoke-Group 'FAILURES THAT CONTINUE - a foreign file upstream changed pages and the run goes on' {
    $E = New-Estate 'foreign'
    Push-Up $E 'lib/code.ps1' "line1-UP`nline2`nline3`n" 'up: code'
    W $E.bot 'lib/code.ps1' "line1-SESSION`nline2`nline3`n"
    $r = Invoke-StartBlock $E
    T 'blocked class foreign continues, pages by outcome, and leaves the session''s file alone' ($r.rec.outcome -eq 'blocked' -and $r.rec.class -eq 'foreign' -and $r.action -eq 'continue' -and ((@($r.pages) -join '|') -eq 'Grocery bot checkout sync blocked - 2026-09-23') -and [IO.File]::ReadAllText((Join-Path $E.bot 'lib/code.ps1')) -eq "line1-SESSION`nline2`nline3`n") ([string]$r.rec.outcome + '/' + [string]$r.rec.class + ' pages=' + (@($r.pages) -join '|'))
  }
  # ---- THE TAIL (plan W4.2) -------------------------------------------------------------------------------------------
  Invoke-Group 'F6 MUST FIRE - a local graph commit and the bot commit are replayed, the push lands, and the tree is what rebase -X theirs builds' {
    $E = New-Estate 'f6'
    Push-Up $E 'grocery/ledger.json' "a`nB-up`nc`n" 'up: ledger line b'
    Push-Up $E 'public/derived.json' "{`n  ""v"": 2`n}`n" 'up: derived v2'
    W $E.bot 'graph/x.json' "g1`n"; $null = GitOk $E.bot @('add', '--', 'graph/x.json'); $null = GitOk $E.bot @('commit', '-q', '-m', 'graph nightly (local)')
    W $E.bot 'grocery/ledger.json' "a`nb`nc-bot`n"
    W $E.bot 'public/derived.json' "{`n  ""v"": 9`n}`n"
    $sha = New-BotCommit $E @('grocery', 'public')
    # What the old tail would have built, in a scratch clone of the bot at the same commit.
    $scratch = Join-Path $E.dir 'scratch'
    $null = GitOk $E.dir @('-c', 'core.autocrlf=false', 'clone', '-q', $E.bot, $scratch)
    foreach ($kv in @(@('core.autocrlf', 'false'), @('user.name', 'fx'), @('user.email', 'fx@x'))) { $null = GitOk $scratch (@('config') + $kv) }
    $null = GitOk $scratch @('fetch', '-q', $E.remote, 'main')
    $null = GitOk $scratch @('rebase', '-q', '-X', 'theirs', 'FETCH_HEAD')
    $want = GitOk $scratch @('rev-parse', 'HEAD^{tree}')
    $r = Invoke-TailPush $E $sha
    $script:tailTexts.Add($r.text)
    $got = (GitR $E.remote @('rev-parse', 'refs/heads/main^{tree}')).out
    T 'the push lands on attempt 1, and origin''s tree is exactly the tree rebase -X theirs builds' ($r.pushed -and ($r.text -match 'pushed on attempt 1') -and $got -eq $want) ('pushed=' + $r.pushed + ' want=' + $want + ' got=' + $got + ' text=' + $r.text)
    $subjects = (GitR $E.remote @('log', '--format=%s', '-3', 'refs/heads/main')).out
    T 'both local commits reached origin, replayed on top of upstream, and nothing is owed' (($subjects -match 'Daily pipeline: refresh prices') -and ($subjects -match 'graph nightly \(local\)') -and (GitR $E.remote @('rev-list', '--count', 'refs/heads/main')).out -eq '5' -and -not $r.owed -and [string]$r.status.outcome -eq 'synced') ('subjects=' + $subjects + ' owed=' + $r.owed)
  }

  Invoke-Group 'RETRY MUST FIRE - a rejected push re-syncs and lands on attempt 2' {
    $E = New-Estate 'retry'
    Push-Up $E 'public/derived.json' "{`n  ""v"": 5`n}`n" 'up: derived'
    [IO.File]::WriteAllText((Join-Path $E.remote 'hooks\pre-receive'), "#!/bin/sh`nif [ ! -f ""`$GIT_DIR/rejected-once"" ]; then touch ""`$GIT_DIR/rejected-once""; echo 'fixture: the first push is rejected' >&2; exit 1; fi`nexit 0`n", $script:fxUtf8)
    W $E.bot 'grocery/ledger.json' "a`nb`nc`nd`n"
    $sha = New-BotCommit $E @('grocery')
    $r = Invoke-TailPush $E $sha
    $script:tailTexts.Add($r.text)
    T 'attempt 1 is rejected, attempt 2 syncs again and lands' ($r.pushed -and ($r.text -match 'sync\[tail 2\]') -and ($r.text -match 'pushed on attempt 2') -and $r.failed -eq '' -and (Test-Path -LiteralPath (Join-Path $E.remote 'rejected-once'))) ('pushed=' + $r.pushed + ' failed=' + $r.failed + ' text=' + $r.text)
  }

  Invoke-Group 'PARTIAL MUST FIRE - a partial tail sync with a local commit does not push, and fails lane sync' {
    $E = New-Estate 'partial'
    Push-Up $E 'public/derived.json' "{`n  ""v"": 6`n}`n" 'up: push 1'
    $null = GitOk $E.bot @('fetch', '-q', 'origin')
    Push-Up $E 'lib/code.ps1' "line1-UP`nline2`nline3`n" 'up: push 2 touches the session file'
    $tip2 = (GitR $E.remote @('rev-parse', 'refs/heads/main')).out
    W $E.bot 'lib/code.ps1' "line1-SESSION`nline2`nline3`n"
    W $E.bot 'grocery/ledger.json' "a`nb`nc`ne`n"
    $sha = New-BotCommit $E @('grocery')
    $r = Invoke-TailPush $E $sha
    $script:tailTexts.Add($r.text)
    T 'the sync ends partial, nothing is pushed and origin still holds push 2' (-not $r.pushed -and [string]$r.status.outcome -eq 'partial' -and $r.remote -eq $tip2) ('pushed=' + $r.pushed + ' outcome=' + [string]$r.status.outcome + ' remote=' + $r.remote)
    T 'failed lane sync, a page naming partial at the push, and the session''s file untouched' ($r.failed -eq 'sync' -and ((@($r.pages) -join '|') -eq 'Grocery bot checkout sync partial at the push - 2026-09-23') -and [IO.File]::ReadAllText((Join-Path $E.bot 'lib/code.ps1')) -eq "line1-SESSION`nline2`nline3`n") ('failed=' + $r.failed + ' pages=' + (@($r.pages) -join '|'))
  }

  Invoke-Group 'ADDENDUM MUST FIRE - a path the bot commit deletes is absent from the index and the disk after the push' {
    foreach ($moved in @($true, $false)) {
      $E = New-Estate ('deleted-' + $moved)
      Push-Up $E 'grocery/out/browser-capture-due-2026-09-18.flag' "due`n" 'up: a flag the pipeline later retires'
      $null = GitOk $E.bot @('pull', '-q', '--ff-only')
      if ($moved) { Push-Up $E 'public/derived.json' "{`n  ""v"": 7`n}`n" 'up: derived' }
      # THE PIPELINE retires the flag, and the bot commit carries the deletion through its private index.
      $flag = 'grocery/out/browser-capture-due-2026-09-18.flag'
      Remove-Item -LiteralPath (Join-Path $E.bot $flag) -Force
      W $E.bot 'grocery/ledger.json' "a`nb`nc`nf`n"
      $sha = New-BotCommit $E @('grocery')
      $leftover = (GitR $E.bot @('ls-files', '--', $flag)).out
      $r = Invoke-TailPush $E $sha
      $script:tailTexts.Add($r.text)
      $idx = (GitR $E.bot @('ls-files', '--', $flag)).out
      $st = (GitR $E.bot @('status', '--porcelain', '--', $flag)).out
      $onRemote = (GitR $E.remote @('ls-tree', '--name-only', 'refs/heads/main', '--', $flag)).out
      $label = if ($moved) { 'with origin moved (synced)' } else { 'with origin not moved (current)' }
      T ($label + ': the real index held the deleted path before the tail and holds nothing after; the disk, git status and origin have none of it') ($r.pushed -and $leftover -eq $flag -and $idx -eq '' -and $st -eq '' -and $onRemote -eq '' -and -not (Test-Path -LiteralPath (Join-Path $E.bot $flag))) ('pushed=' + $r.pushed + ' leftover=' + $leftover + ' index=' + $idx + ' status=' + $st + ' remote=' + $onRemote)
    }
  }

  Invoke-Group 'FINALLY MUST FIRE - a run that throws after its commit stage still pays its tail sync' {
    $E = New-Estate 'finally'
    Push-Up $E 'public/derived.json' "{`n  ""v"": 8`n}`n" 'up: derived'
    $tip = (GitR $E.remote @('rev-parse', 'refs/heads/main')).out
    $body = ('$script:TailSyncOwed = $true' + "`n" + 'try { throw ''fixture: a watcher threw after the commit stage'' } finally {' + "`n" + $tailFinally + "`n}`n" + 'exit 0')
    $h = New-RegionHarness $E ('Local\tc-crs-fin-' + [guid]::NewGuid().ToString('N')) $body
    $c = Invoke-FxChild $h
    T 'the throw still ends the run non-zero, and the owed sync moved the checkout to origin first' ($c.rc -ne 0 -and ($c.out -match 'tail: this run threw before its tail sync') -and ($c.out -match 'sync\[tail\]: synced') -and (GitR $E.bot @('rev-parse', 'HEAD')).out -eq $tip) ('rc=' + $c.rc + ' out=' + $c.out + ' err=' + $c.err)
  }

  Invoke-Group 'UNCOMMITTED MUST NOT FIRE - a run that did not commit pays one tail sync, once' {
    $E = New-Estate 'owed'
    Push-Up $E 'public/derived.json' "{`n  ""v"": 10`n}`n" 'up: derived'
    $NoSync = $false; $script:TailSyncOwed = $true; $script:CaptureRunSyncSeams = $script:fxSeams; $script:pages.Clear()
    $o1 = Invoke-CaptureRunOwedTailSync -Repo $E.bot -Root (Join-Path $E.bot 'grocery') -Kind 'daily' -Today '2026-09-23'
    $o2 = Invoke-CaptureRunOwedTailSync -Repo $E.bot -Root (Join-Path $E.bot 'grocery') -Kind 'daily' -Today '2026-09-23'
    T 'the owed sync is synced and not bad, and a second call owes nothing and does nothing' ($null -ne $o1 -and [string]$o1.record.outcome -eq 'synced' -and -not $o1.bad -and $null -eq $o2 -and -not $script:TailSyncOwed -and (GitR $E.bot @('rev-list', '--count', 'HEAD')).out -eq '2') ($(if ($o1) { $o1.line } else { 'none' }) + ' second=' + $(if ($o2) { $o2.line } else { 'none' }))
  }

  Invoke-Group 'KILL SWITCH ON A COMMITTED RUN - the commit stays local, lane sync, no push' {
    $E = New-Estate 'killtail'
    Push-Up $E 'public/derived.json' "{`n  ""v"": 11`n}`n" 'up: derived'
    [IO.File]::WriteAllText((Join-Path $E.bot '.git\tc-checkout-sync.disabled'), 'fixture')
    W $E.bot 'grocery/ledger.json' "a`nb`nc`ng`n"
    $sha = New-BotCommit $E @('grocery')
    $tip = (GitR $E.remote @('rev-parse', 'refs/heads/main')).out
    $r = Invoke-TailPush $E $sha
    $script:tailTexts.Add($r.text)
    T 'disabled: nothing pushed, failed lane sync, and the bot commit is still HEAD, local' (-not $r.pushed -and $r.failed -eq 'sync' -and $r.remote -eq $tip -and (GitR $E.bot @('rev-parse', 'HEAD')).out -eq $sha -and [string]$r.status.outcome -eq 'disabled') ('pushed=' + $r.pushed + ' failed=' + $r.failed + ' outcome=' + [string]$r.status.outcome)
  }

  Invoke-Group 'NO AUTOSTASH MUST NOT FIRE - bar B3 on its mechanism' {
    $autoCfg = 'rebase.' + 'autoStash'
    $stashLine = 'Created ' + 'autostash'
    $hits = @($script:tailTexts | Where-Object { $_ -match [regex]::Escape($stashLine) }).Count
    T ('no tail fixture run printed "' + $stashLine + '" (' + $script:tailTexts.Count + ' runs read), and capture-run.ps1 no longer names ' + $autoCfg) ($script:tailTexts.Count -ge 6 -and $hits -eq 0 -and $crSrc.IndexOf($autoCfg, [StringComparison]::OrdinalIgnoreCase) -lt 0) ('runs=' + $script:tailTexts.Count + ' hits=' + $hits)
  }
} finally {
  Remove-Item -LiteralPath $script:fxRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$total = $script:pass + $script:fail
Write-Output ('capture-run-sync: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $total + ' of ' + $EXPECTED_CASES + ' literal cases ran')
if ($script:fail -eq 0 -and $total -eq $EXPECTED_CASES) { Write-Output 'capture-run-sync SELF-TEST PASS'; exit 0 }
Write-Output 'capture-run-sync SELF-TEST FAIL'
exit 1
