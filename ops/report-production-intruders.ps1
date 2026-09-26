<#
  report-production-intruders.ps1 - who owns each dirty or untracked path in the production checkout (W0.3).

  design/PLAN-bot-dedicated-checkout-2026-09-25.md, ruled 2026-09-25 (design D, D4 (b)). The main checkout becomes
  the production checkout, written only by scheduled jobs. This prints every dirty or untracked entry that no
  declared writer owns (lib/bot-paths.ps1 for the capture bot and the lanes, ops/production-writers.json for every
  other scheduled writer), and with -Record keeps one row a day in <git common dir>\tc-production-intruders.jsonl.
  The capture watchdog (10:30) runs the same check and prints the count. D4's set-aside switches on only after this
  reads 0 UNREGISTERED producer paths for 7 clean days; a session's file is what D4 is for, a producer's is not.

  A REPORT, NEVER A GATE, AND IT MOVES NOTHING. Exit 0 = counted (whatever the count), 3 = BLIND (the registry or git
  could not be read), never a pass.

  SCOPE OF A CLEAN REPORT: unsound. A producer that left nothing dirty today is not tested by today's row, so "0
  unregistered" says nothing about a writer that did not run. The session hint is a guess from the path's shape.

  Usage:  powershell -NoProfile -File ops\report-production-intruders.ps1 [-Repo <checkout>] [-Record] [-Today yyyy-MM-dd]
          powershell -NoProfile -File ops\report-production-intruders.ps1 -SelfTest
  -Repo defaults to the production checkout: the parent of this repository's git common dir.
#>
# WHAT THE SELF-TEST READS: a temp git repo and temp registry it builds, and this script run as a child; the real registry is never read.
# gate-inputs: ops\report-production-intruders.ps1
param([string]$Repo = '', [string]$Registry = '', [switch]$Record, [string]$Today = '', [switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path $here -Parent
. (Join-Path $repoRoot 'lib\production-writers.ps1')
if (-not $Registry) { $Registry = Join-Path $here 'production-writers.json' }

function Resolve-PiProductionCheckout([string]$From) {
  $g = Invoke-GitCaptured -Repo $From -GitArgs @('rev-parse', '--path-format=absolute', '--git-common-dir')
  if ($g.rc -ne 0) { throw 'could not read the git common dir' }
  return (Split-Path ([string]$g.stdout).Trim() -Parent)
}

function Invoke-PiReport([string]$RepoDir, [string]$RegistryPath, [bool]$Rec, [string]$Date) {
  $chk = Invoke-TcProductionCensusCheck -Repo $RepoDir -RegistryPath $RegistryPath -Record:$Rec -Date $Date
  Write-Output ('report-production-intruders: ' + $RepoDir)
  if ($chk.blind) {
    Write-Output ('  ' + $chk.line)
    Write-Output 'PRODUCTION-INTRUDERS-COMPLETE entries=-1 bot=-1 registered=-1 unregistered=-1 blind=1'
    $script:piRc = 3; return
  }
  $c = $chk.census
  foreach ($k in $c.by_writer.Keys) { Write-Output ('  {0,-40} {1}' -f $k, $c.by_writer[$k]) }
  foreach ($u in $c.unregistered_list) { Write-Output ('  UNREGISTERED  [{0}] {1}  ({2})' -f $u.xy, $u.path, $u.hint) }
  Write-Output ('  ' + $chk.line)
  Write-Output ('PRODUCTION-INTRUDERS-COMPLETE entries={0} bot={1} registered={2} unregistered={3} session_shaped={4} blind=0' -f $c.entries, $c.bot, $c.registered, $c.unregistered, $c.unregistered_session_shaped)
  $script:piRc = 0
}

if ($SelfTest) {
  # The census rules are lib\production-writers.ps1's and its own self-test drives them. This drives the CLI as a
  # child, as the watchdog and a person run it: the counted exit, the BLIND exit, and the marker as the last line.
  . (Join-Path $repoRoot 'lib\git-repo-env.ps1')
  $cases = 0; $fail = 0
  function PiT([string]$Label, [bool]$Ok, [string]$Got = '') {
    $script:cases++
    if ($Ok) { Write-Output ('  PASS  ' + $Label) } else { $script:fail++; Write-Output ('  FAIL  ' + $Label + '   got: ' + $Got) }
  }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('pi-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
  try {
    Clear-TcGitRepoEnv
    $r = Join-Path $tmp 'r'; New-Item -ItemType Directory -Path $r | Out-Null
    $null = Invoke-GitCaptured -Repo $r -GitArgs @('init', '-q', '-b', 'main')
    [IO.File]::WriteAllText((Join-Path $r 'a.ps1'), 'x')
    $reg = Join-Path $tmp 'reg.json'
    [IO.File]::WriteAllText($reg, '{"version":1,"intruder_policy":"wait","writers":[]}')
    $self = $MyInvocation.MyCommand.Path
    if (-not $self) { $self = Join-Path $here 'report-production-intruders.ps1' }
    $o1 = @(& powershell -NoProfile -File $self -Repo $r -Registry $reg)
    $rc1 = $LASTEXITCODE
    PiT 'MUST FIRE: an untracked code file in a fixture checkout is reported UNREGISTERED, exit 0 (a report counts, never fails)' `
        (($rc1 -eq 0) -and (@($o1 | Where-Object { $_ -match 'UNREGISTERED\s+\[\?\?\] a\.ps1' }).Count -eq 1)) ("rc=$rc1 " + ($o1 -join ' | '))
    PiT 'CLEAN TWIN: the marker is the last line and carries the counts' `
        ([string]$o1[-1] -match '^PRODUCTION-INTRUDERS-COMPLETE entries=1 bot=0 registered=0 unregistered=1 session_shaped=1 blind=0$') ([string]$o1[-1])
    $o2 = @(& powershell -NoProfile -File $self -Repo $r -Registry (Join-Path $tmp 'missing.json'))
    $rc2 = $LASTEXITCODE
    PiT 'MUST FIRE: a missing registry is BLIND, exit 3, never a zero count' `
        (($rc2 -eq 3) -and ([string]$o2[-1] -match 'blind=1$')) ("rc=$rc2 " + [string]$o2[-1])
    $n = @(Get-ChildItem -LiteralPath $r -Force -File).Count
    PiT 'MUST NOT FIRE: without -Record nothing is written, in the checkout or its git dir' `
        (($n -eq 1) -and -not (Test-Path -LiteralPath (Join-Path $r '.git\tc-production-intruders.jsonl'))) ([string]$n)
  } catch {
    $fail++; Write-Output ('  FAIL  the fixture threw: ' + $_.Exception.Message)
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($cases -ne 4) { Write-Output "REPORT-PRODUCTION-INTRUDERS SELF-TEST FAIL: ran $cases cases, the literal list holds 4"; exit 1 }
  if ($fail) { Write-Output "REPORT-PRODUCTION-INTRUDERS SELF-TEST FAIL ($fail of $cases)"; exit 1 }
  Write-Output "REPORT-PRODUCTION-INTRUDERS SELF-TEST PASS ($cases of $cases cases)"
  exit 0
}

try {
  if (-not $Repo) { $Repo = Resolve-PiProductionCheckout $repoRoot }
} catch {
  Write-Output ('  production intruders: BLIND - ' + $_.Exception.Message)
  Write-Output 'PRODUCTION-INTRUDERS-COMPLETE entries=-1 bot=-1 registered=-1 unregistered=-1 blind=1'
  exit 3
}
$script:piRc = 3
Invoke-PiReport $Repo $Registry ([bool]$Record) $Today
exit $script:piRc
