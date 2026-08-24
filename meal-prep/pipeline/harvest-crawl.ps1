<#
.SYNOPSIS
  The scheduled harvest crawl. Restocks the candidate shelf. Costs no Claude tokens and no GPU.

.DESCRIPTION
  Brad's ruling 2026-08-24: schedule the CRAWL, keep the RUN manual.

  WHY THE SPLIT IS THE WHOLE POINT. Harvesting is free - it reads publisher sitemaps, fetches pages
  through a content-addressed cache, and parses the machine-readable recipe block sites publish for
  Google. No model of any kind touches it (the similarity scoring is bge-m3 on the CPU, measured at
  36 ms per recipe, and harvest's only GPU flag, --classify, is not used here). Everything that
  SPENDS - the decider, mapper, registrar, pricer, writer, QA, auditor - lives in a run, and a run
  stays manual because that is where 7.2M tokens per published recipe goes.

  WHAT THIS FIXES. Nothing about the Recipe Hunter was scheduled. `NIGHTLY_CAP = 60` is named nightly
  but nothing ran nightly - it is a politeness BUDGET that resets at midnight, not a schedule - so the
  pool sat unchanged from 2026-08-23 until someone crawled it by hand. The shelf did not restock
  itself, and a session that wanted a run discovered an empty pool mid-run. That happened on
  2026-08-24 and cost a proving run its corpus.

  IT CANNOT COLLIDE WITH THE CARD. This never loads a model, so it is not subject to the
  llama-server ordering rule (graph\pipeline\nightly.ps1 owns that, and only
  install-nightly-task.ps1 may schedule it). The default 18:00 slot is chosen to be clear of the
  07:00 ad pull, the 08:00 daily capture, the 09:30 watchdog and the nightly's 21:30-06:30 window -
  not because of contention, but so a human reading the task list sees one job per part of the day.

  POLITENESS IS THE CRAWL'S OWN, NOT THIS FILE'S. harvest.py caps itself at 60 network fetches per
  publisher per calendar day and tracks the count in its own state. Running this twice in a day is
  harmless: the second run finds no room and fetches nothing. That is asserted by the self-test.

  Exit 0 = crawled (or correctly found no room). Exit 1 = the crawl reported findings. Exit 2 = it
  could not run at all.
#>
param([switch]$SelfTest, [int]$Limit = 400, [int]$PerDomain = 60, [switch]$DryRun)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
$py   = 'C:\Codex\Python312\python.exe'
$harvest = Join-Path $here 'harvest.py'
$logDir = Join-Path $mp 'runs\_harvest-log'

function Say([string]$s) { Write-Output $s }

if ($SelfTest) {
  $bad = 0
  function T([string]$name, [bool]$ok, $got = '') {
    if ($ok) { Write-Output ("  ok    " + $name) }
    else { Write-Output ("  X     {0}   got: {1}" -f $name, $got); $script:bad++ }
  }
  # The interpreter is the estate's, never the Windows Store shim that exits 49 without running.
  T 'the Python interpreter is the pinned one, not a bare `python`' (Test-Path $py) $py
  T 'harvest.py is where this expects it' (Test-Path $harvest) $harvest
  # MUST FIRE: this file may never start or stop llama-server. The card belongs to nightly.ps1, and a
  # crawl that reached for it would break the one ordering rule the estate has.
  # THE SCAN IS OVER THE EXECUTING REGION ONLY, and it took two tries to get honest.
  # First shape grepped the WHOLE file and tripped on this script's own header, which EXPLAINS that it
  # must not touch the card. Second shape grepped everything after the header - and tripped on the
  # SELF-TEST BLOCK, whose assertion patterns contain the very strings it searches for. A grep over a
  # file that contains the grep is circular and proves nothing. So the region is delimited explicitly.
  $src = Get-Content $PSCommandPath -Raw
  $code = ''
  # LastIndexOf, not IndexOf: the FIRST occurrence of this marker string is the line right here,
  # inside the test itself. IndexOf found that, so $code began mid-self-test and the scan matched its
  # own assertion patterns - the third variation of the same tail-eating in one fixture.
  $mk = $src.LastIndexOf('# ---- EXECUTION BEGINS')
  if ($mk -ge 0) { $code = $src.Substring($mk) }
  T 'the execution marker is present, or the two guards below are scanning nothing' ($code.Length -gt 0) 'no marker'
  T 'MUST FIRE  the executing region NEVER touches llama-server, serve.ps1 or nvidia-smi - the card belongs to nightly.ps1' `
    ($code.Length -gt 0 -and -not ($code -match 'serve|llama|nvidia|StopOnly')) 'found a card reference in the executing region'
  T 'MUST FIRE  ...and never invokes an agent, because the whole point is that harvesting is free' `
    ($code.Length -gt 0 -and -not ($code -match 'claude|daemon|dispatch')) 'found an agent reference in the executing region'
  T 'MUST FIRE  the one external program it runs is the pinned interpreter on harvest.py --crawl' `
    ($code -match '&\s+\$py\s+@args' -and $code -match "'--crawl'" -and $code -match '\$harvest') `
    'the invocation is not python + harvest.py --crawl'
  Write-Output ''
  if ($bad -gt 0) { Write-Output ("harvest-crawl SELF-TEST FAIL: {0} case(s)" -f $bad); exit 1 }
  Write-Output 'harvest-crawl SELF-TEST PASS'
  exit 0
}

# ---- EXECUTION BEGINS ----------------------------------------------------------------------------
if (-not (Test-Path $py))      { Say 'harvest-crawl: CANNOT RUN - no python interpreter at C:\Codex\Python312'; exit 2 }
if (-not (Test-Path $harvest)) { Say 'harvest-crawl: CANNOT RUN - no harvest.py'; exit 2 }
if (-not (Test-Path $logDir))  { New-Item -ItemType Directory -Force $logDir | Out-Null }

$stamp = (Get-Date).ToString('yyyy-MM-dd')
$log = Join-Path $logDir ("crawl-{0}.log" -f $stamp)
$args = @($harvest, '--crawl', '--limit', $Limit, '--per-domain', $PerDomain)
if ($DryRun) { $args += '--dry-run' }

Say ("harvest-crawl: {0}  limit {1}, {2}/publisher" -f (Get-Date).ToString('HH:mm:ss'), $Limit, $PerDomain)
$out = & $py @args
$rc = $LASTEXITCODE
$out | Out-File -FilePath $log -Append -Encoding utf8
foreach ($ln in @($out)) { if ($ln -match 'POOL now|new pool entries|FINDING|CANNOT RUN') { Say ('  ' + $ln.Trim()) } }
Say ("harvest-crawl: exit {0}  (log: {1})" -f $rc, $log)
exit $rc
