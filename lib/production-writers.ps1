# production-writers.ps1 - who owns each dirty or untracked path in the production checkout (W0.3).
#
# WHY THIS EXISTS (design/PLAN-bot-dedicated-checkout-2026-09-25.md, ruled 2026-09-25). Under design D the main
# checkout is the PRODUCTION checkout, written only by scheduled jobs. The sync may one day set aside a file no
# scheduled writer owns (D4, ruled (b)), and that is only safe once every producer has declared its paths: on the day
# the plan was written, 40 of 60 dirty or untracked entries were owned by no declared writer, and some of those
# belonged to OTHER scheduled writers (weekly stamps, incident reports, the reaper log). So this is a CENSUS first:
# it classifies, it never moves anything, and D4 switches on only after 7 clean days of it.
#
# THE ORDER OF OWNERSHIP. (1) lib/bot-paths.ps1 Test-BotPathOwned: the capture bot and the three lanes, one
# declaration. (2) ops/production-writers.json: every other scheduled writer, each with its evidence. (3) Neither:
# UNREGISTERED, with a hint that is a hint and never a verdict.
#
# SCOPE OF A CLEAN REPORT. Unsound: a writer's file is only seen while it is dirty or untracked, so a producer that
# happened to leave nothing behind today is not tested by today's row. A "0 unregistered" day proves nothing about a
# writer that did not run. Incomplete by design for the hint: it guesses "a session" from the path's shape.
#
# Dot-source:  . (Join-Path $repoRoot 'lib\production-writers.ps1')
# Self-test:   powershell -File lib\production-writers.ps1 -SelfTest
#
# NO param() BLOCK HERE, DELIBERATELY - same rule as lib\bot-paths.ps1: dot-sourced under PS 5.1 a param() block
# runs in the CALLER's scope and resets the caller's own -SelfTest.
$__pwSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

if (-not (Get-Command Test-BotPathOwned -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'bot-paths.ps1') }
if (-not (Get-Command Invoke-GitCaptured -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'git-blob-lib.ps1') }
if (-not (Get-Command Add-TcLine -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'append-line.ps1') }

$script:TcProductionCensusLogName = 'tc-production-intruders.jsonl'

function Read-TcProductionRegistry {
  <# The registry, or a THROW. An unreadable registry is a BLIND census, never an empty one: an empty writer list
     would read every producer's file as an intruder. #>
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { throw "production registry not found: $Path" }
  $text = [IO.File]::ReadAllText($Path, (New-Object Text.UTF8Encoding($false)))
  $reg = $text | ConvertFrom-Json
  if ($null -eq $reg.PSObject.Properties['writers']) { throw "production registry has no writers list: $Path" }
  $pol = [string]$reg.intruder_policy
  switch ($pol) {
    'wait' { }
    'set-aside' { }
    default { throw "production registry: unknown intruder_policy '$pol' (wait or set-aside)" }
  }
  return $reg
}

function Get-TcProductionWriter {
  <# The writer that owns one repo-relative path: 'scheduled-bot' (lib/bot-paths.ps1), a registry writer's name,
     or '' for UNREGISTERED. #>
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Registry, [string[]]$BotOwned)
  $botArgs = @{ Path = $Path }
  if ($PSBoundParameters.ContainsKey('BotOwned')) { $botArgs.Owned = $BotOwned }
  if (Test-BotPathOwned @botArgs) { return 'scheduled-bot' }
  foreach ($w in @($Registry.writers)) {
    $pats = @($w.paths | ForEach-Object { [string]$_ })
    if ($pats.Count -and (Test-BotPathOwned -Path $Path -Owned $pats)) { return [string]$w.name }
  }
  return ''
}

function Get-TcIntruderHint([string]$Path) {
  $p = $Path.Replace('\', '/')
  if ($p -match '\.(ps1|psm1|py|js|cmd)$') { return 'code: looks like a session' }
  if ($p.StartsWith('design/', [StringComparison]::Ordinal)) { return 'design doc: looks like a session' }
  return 'writer unknown'
}

function ConvertFrom-TcPorcelainZ {
  <# `git status --porcelain=v1 -z` into (xy, path) pairs. A rename or copy carries its origin as the next field,
     which is skipped: the path that exists in the tree is the one that matters here. #>
  param([string]$Text)
  $out = New-Object System.Collections.Generic.List[object]
  $f = $Text.Split([char]0)
  for ($i = 0; $i -lt $f.Length; $i++) {
    $e = $f[$i]
    if ($e.Length -lt 4) { continue }
    $xy = $e.Substring(0, 2)
    $out.Add([pscustomobject]@{ xy = $xy; path = $e.Substring(3) })
    if ($xy[0] -eq 'R' -or $xy[0] -eq 'C') { $i++ }
  }
  return ,$out.ToArray()
}

function Get-TcProductionCensus {
  <# Classify every dirty or untracked entry of $Repo. Reads git and the registry; writes nothing. #>
  param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)]$Registry, [string[]]$BotOwned)
  $r = Invoke-GitCaptured -Repo $Repo -GitArgs @('status', '--porcelain=v1', '-z', '--untracked-files=all')
  if ($r.rc -ne 0) { throw ('git status failed in ' + $Repo + ' (rc ' + $r.rc + '): ' + ([string]$r.stderr).Trim()) }
  $entries = ConvertFrom-TcPorcelainZ -Text ([string]$r.stdout)
  $bot = 0; $reg = 0
  $byWriter = [ordered]@{}
  $un = New-Object System.Collections.Generic.List[object]
  foreach ($e in $entries) {
    $wArgs = @{ Path = $e.path; Registry = $Registry }
    if ($PSBoundParameters.ContainsKey('BotOwned')) { $wArgs.BotOwned = $BotOwned }
    $w = Get-TcProductionWriter @wArgs
    if ($w -eq 'scheduled-bot') { $bot++ }
    elseif ($w) { $reg++ }
    else { $un.Add([pscustomobject]@{ xy = $e.xy; path = $e.path; hint = (Get-TcIntruderHint $e.path) }) }
    $k = if ($w) { $w } else { 'UNREGISTERED' }
    if ($byWriter.Contains($k)) { $byWriter[$k]++ } else { $byWriter[$k] = 1 }
  }
  $sess = @($un | Where-Object { $_.hint -like '*session*' }).Count
  return [pscustomobject]@{
    entries = $entries.Count; bot = $bot; registered = $reg; unregistered = $un.Count
    unregistered_session_shaped = $sess; unregistered_list = $un.ToArray(); by_writer = $byWriter
    policy = [string]$Registry.intruder_policy
    summary = ('{0} dirty or untracked entries: {1} the bot''s, {2} registered writers'', {3} UNREGISTERED ({4} session-shaped)' -f $entries.Count, $bot, $reg, $un.Count, $sess)
  }
}

function Add-TcProductionCensusRow {
  <# One row per DATE in <git common dir>\tc-production-intruders.jsonl, outside every working tree so the record is
     never itself an intruder. Returns 'written' or 'already'. Read-then-append: two runs the same minute could both
     write, which a reader of one-row-per-day tolerates by taking the first row of a date. #>
  param([Parameter(Mandatory)][string]$CommonDir, [Parameter(Mandatory)]$Census, [Parameter(Mandatory)][string]$Date)
  $log = Join-Path $CommonDir $script:TcProductionCensusLogName
  if (Test-Path -LiteralPath $log) {
    foreach ($ln in [IO.File]::ReadAllLines($log)) {
      if ($ln -match ('"date":\s*"' + [regex]::Escape($Date) + '"')) { return 'already' }
    }
  }
  $row = [ordered]@{
    date = $Date; ts = (Get-Date).ToString('o'); entries = $Census.entries; bot = $Census.bot
    registered = $Census.registered; unregistered = $Census.unregistered
    unregistered_session_shaped = $Census.unregistered_session_shaped; policy = $Census.policy
    by_writer = $Census.by_writer
    unregistered_paths = @($Census.unregistered_list | Select-Object -First 60 | ForEach-Object { $_.xy + ' ' + $_.path })
  }
  $null = Add-TcLine -Path $log -Text ($row | ConvertTo-Json -Compress -Depth 4)
  return 'written'
}

function Invoke-TcProductionCensusCheck {
  <# The whole check, as the capture watchdog and ops\report-production-intruders.ps1 both run it: read the registry,
     classify, record today's row when -Record. A REPORT: it returns one line and never a finding. A throw is BLIND. #>
  param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$RegistryPath, [string]$Date = '',
        [switch]$Record, [string]$CommonDir = '')
  try {
    $reg = Read-TcProductionRegistry -Path $RegistryPath
    $c = Get-TcProductionCensus -Repo $Repo -Registry $reg
    $rec = 'not recorded'
    if ($Record) {
      if (-not $CommonDir) {
        $g = Invoke-GitCaptured -Repo $Repo -GitArgs @('rev-parse', '--path-format=absolute', '--git-common-dir')
        if ($g.rc -ne 0) { throw 'could not read the git common dir' }
        $CommonDir = ([string]$g.stdout).Trim()
      }
      if (-not $Date) { $Date = (Get-Date).ToString('yyyy-MM-dd') }
      $rec = 'day row ' + (Add-TcProductionCensusRow -CommonDir $CommonDir -Census $c -Date $Date)
    }
    return [pscustomobject]@{ blind = $false; census = $c
      line = ('production intruders (report only, W0.3): ' + $c.summary + '; policy ' + $c.policy + '; ' + $rec) }
  } catch {
    return [pscustomobject]@{ blind = $true; census = $null
      line = ('production intruders: BLIND - ' + $_.Exception.Message + ' - who owns the production checkout''s dirty files is unknown this run') }
  }
}

if ($__pwSelfTest) {
  $ErrorActionPreference = 'Stop'
  . (Join-Path $PSScriptRoot 'git-repo-env.ps1')
  $script:pwCases = 0; $script:pwFail = 0
  function PwT([string]$Label, [bool]$Ok, [string]$Got = '') {
    $script:pwCases++
    if ($Ok) { Write-Output ('  PASS  ' + $Label) } else { $script:pwFail++; Write-Output ('  FAIL  ' + $Label + '   got: ' + $Got) }
  }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('pw-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
  try {
    Clear-TcGitRepoEnv
    $repo = Join-Path $tmp 'r'
    New-Item -ItemType Directory -Path $repo | Out-Null
    $null = Invoke-GitCaptured -Repo $repo -GitArgs @('init', '-q', '-b', 'main')
    $null = Invoke-GitCaptured -Repo $repo -GitArgs @('config', 'user.email', 'fx@example.invalid')
    $null = Invoke-GitCaptured -Repo $repo -GitArgs @('config', 'user.name', 'fx')
    $null = Invoke-GitCaptured -Repo $repo -GitArgs @('config', 'core.autocrlf', 'false')
    function PwW([string]$rel, [string]$text) {
      $p = Join-Path $repo $rel; $d = Split-Path $p -Parent
      if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
      [IO.File]::WriteAllText($p, $text)
    }
    PwW 'fx/out/board.json' 'a'
    PwW 'grocery/x-weekly-stamp.txt' 'a'
    PwW 'lib/staged.ps1' 'a'
    PwW 'old name.txt' 'a'
    $null = Invoke-GitCaptured -Repo $repo -GitArgs @('add', '-A')
    $null = Invoke-GitCaptured -Repo $repo -GitArgs @('commit', '-q', '-m', 'base')
    PwW 'fx/out/board.json' 'b'                 # the bot's, modified
    PwW 'grocery/x-weekly-stamp.txt' 'b'             # a registered writer's, modified
    PwW 'lib/staged.ps1' 'b'                         # a session's staged edit
    $null = Invoke-GitCaptured -Repo $repo -GitArgs @('add', '--', 'lib/staged.ps1')
    PwW 'lib/chain-queue.ps1' 'x'                    # 09-24 09:00's shape: a session's untracked code file
    PwW 'design/PLAN-draft.md' 'x'                   # an untracked plan draft
    PwW 'fx/outbound notes.txt' 'x'             # a sibling of an owned directory, with a space
    $null = Invoke-GitCaptured -Repo $repo -GitArgs @('mv', 'old name.txt', 'grocery/INCIDENT-2026-09-25-x.md')
    $regPath = Join-Path $tmp 'reg.json'
    $regText = '{"version":1,"intruder_policy":"wait","writers":[{"name":"stamps","paths":["grocery/*-weekly-stamp.txt"]},{"name":"incidents","paths":["grocery/INCIDENT-*.md"]}]}'
    [IO.File]::WriteAllText($regPath, $regText)
    $bot = @('fx/out')
    $reg = Read-TcProductionRegistry -Path $regPath
    $c = Get-TcProductionCensus -Repo $repo -Registry $reg -BotOwned $bot
    PwT 'CLEAN TWIN: seven entries, a rename read once under its new name' ($c.entries -eq 7) ([string]$c.entries)
    PwT 'CLEAN TWIN: the bot''s modified board is the bot''s' ($c.bot -eq 1) ([string]$c.bot)
    PwT 'CLEAN TWIN: a weekly stamp and a renamed-in incident report are registered writers''' ($c.registered -eq 2) ([string]$c.registered)
    $unp = @($c.unregistered_list | ForEach-Object { $_.path }) -join ','
    PwT 'MUST FIRE: the staged edit, the untracked code file, the plan draft and the prefix sibling are UNREGISTERED' `
        (($c.unregistered -eq 4) -and ($unp -match 'lib/staged\.ps1') -and ($unp -match 'lib/chain-queue\.ps1') -and ($unp -match 'design/PLAN-draft\.md') -and ($unp -match 'fx/outbound notes\.txt')) $unp
    PwT 'MUST NOT FIRE: a sibling whose name only starts with the owned fx/out is not the bot''s' `
        ((Get-TcProductionWriter -Path 'fx/outbound notes.txt' -Registry $reg -BotOwned $bot) -eq '') 'owned'
    PwT 'CLEAN TWIN: three of the four are session-shaped, the prefix sibling is writer unknown' ($c.unregistered_session_shaped -eq 3) ([string]$c.unregistered_session_shaped)
    $empty = '{"version":1,"intruder_policy":"wait","writers":[]}' | ConvertFrom-Json
    $c0 = Get-TcProductionCensus -Repo $repo -Registry $empty -BotOwned $bot
    PwT 'MUST FIRE: with no registered writers, the stamp and the incident report become UNREGISTERED too' ($c0.unregistered -eq 6) ([string]$c0.unregistered)
    $bad = Join-Path $tmp 'bad.json'; [IO.File]::WriteAllText($bad, '{"version":1,"intruder_policy":"wait"}')
    $thrown = ''; try { $null = Read-TcProductionRegistry -Path $bad } catch { $thrown = $_.Exception.Message }
    PwT 'MUST FIRE: a registry with no writers list THROWS, never reads as empty' ($thrown -match 'no writers list') $thrown
    $pol = Join-Path $tmp 'pol.json'; [IO.File]::WriteAllText($pol, '{"version":1,"intruder_policy":"move","writers":[]}')
    $thrown = ''; try { $null = Read-TcProductionRegistry -Path $pol } catch { $thrown = $_.Exception.Message }
    PwT 'MUST FIRE: an unknown intruder_policy THROWS (the switch refuses what it does not know)' ($thrown -match 'unknown intruder_policy') $thrown
    $cd = Join-Path $tmp 'common'; New-Item -ItemType Directory -Path $cd | Out-Null
    $w1 = Add-TcProductionCensusRow -CommonDir $cd -Census $c -Date '2026-09-25'
    $w2 = Add-TcProductionCensusRow -CommonDir $cd -Census $c -Date '2026-09-25'
    $w3 = Add-TcProductionCensusRow -CommonDir $cd -Census $c -Date '2026-09-26'
    $rows = @([IO.File]::ReadAllLines((Join-Path $cd 'tc-production-intruders.jsonl')))
    PwT 'MUST FIRE: one row per date - a second run the same day writes nothing' ((($w1 + ',' + $w2 + ',' + $w3) -eq 'written,already,written') -and ($rows.Count -eq 2)) ($w1 + ',' + $w2 + ',' + $w3 + ' rows=' + $rows.Count)
    $j = $rows[0] | ConvertFrom-Json
    PwT 'CLEAN TWIN: the row carries the counts and names every unregistered path' (($j.unregistered -eq 4) -and (@($j.unregistered_paths).Count -eq 4) -and ($j.bot -eq 1)) ($rows[0])
    $chk = Invoke-TcProductionCensusCheck -Repo $repo -RegistryPath $bad
    PwT 'MUST FIRE: the check over an unreadable registry is BLIND and says so' ($chk.blind -and ($chk.line -match 'BLIND')) $chk.line
    $chk2 = Invoke-TcProductionCensusCheck -Repo $repo -RegistryPath $regPath -Record -CommonDir $cd -Date '2026-09-27'
    PwT 'CLEAN TWIN: the check records its day and reports one line' ((-not $chk2.blind) -and ($chk2.line -match 'day row written') -and ($chk2.line -match 'UNREGISTERED')) $chk2.line
    $n0 = @(Get-ChildItem -LiteralPath $repo -Recurse -Force -File | Where-Object { $_.FullName -notmatch '\\\.git\\' }).Count
    PwT 'MUST NOT FIRE: the census wrote nothing into the checkout it read (7 files before and after)' ($n0 -eq 7) ([string]$n0)
  } catch {
    $script:pwFail++; Write-Output ('  FAIL  the fixture threw: ' + $_.Exception.Message)
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  $want = 14
  if ($script:pwCases -ne $want) { Write-Output ("PRODUCTION-WRITERS SELF-TEST FAIL: ran $script:pwCases cases, the literal list holds $want"); exit 1 }
  if ($script:pwFail) { Write-Output "PRODUCTION-WRITERS SELF-TEST FAIL ($script:pwFail of $script:pwCases)"; exit 1 }
  Write-Output "PRODUCTION-WRITERS SELF-TEST PASS ($script:pwCases of $script:pwCases cases)"
  exit 0
}
