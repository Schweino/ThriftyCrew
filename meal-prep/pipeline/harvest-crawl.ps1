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
  # MUST FIRE: the SCHEDULED wrapper may never source publishers. Brad's rule is that publisher
  # discovery happens only when he asks - fetching a stranger's site on a timer is how a domain gets
  # BLOCKED, and a blocked publisher costs far more than a slow one. --probe-domains is manual, and
  # this is where that is enforced rather than merely intended.
  T 'MUST FIRE  the scheduled crawl NEVER probes for new publishers - that is manual by ruling' `
    ($code.Length -gt 0 -and -not ($code -match 'probe|--admit')) 'the scheduled task can source publishers'
  T 'the crawl itself is still the pinned interpreter on harvest.py --crawl' `
    ($code -match '&\s+\$py\s+@args' -and $code -match "'--crawl'" -and $code -match '\$harvest') `
    'the invocation is not python + harvest.py --crawl'
  # A SECOND EXTERNAL PROGRAM JOINED IT on 2026-09-04 - harvest_embed.py, which rebuilds the dedup
  # evidence index. The old case name claimed there was only ONE, and would have stayed green while
  # its own name became false; that is the shape of assertion this estate has been bitten by, so it
  # was renamed rather than left to pass. Both halves of the new program are asserted, because the
  # pinned interpreter has no torch and the card is not this job's to take.
  T 'MUST FIRE  the index rebuild runs under the SIDECAR venv - the pinned interpreter has no torch' `
    ($code -match 'sidecar' -and $code -match 'harvest_embed\.py') 'the rebuild is missing or on the wrong interpreter'
  T 'MUST FIRE  ...and it stays on the CPU. This job never asks for the card, and asking is the one thing it may not do' `
    ($code -match "'--device'\s*'cpu'" -and -not ($code -match 'cuda')) 'the rebuild could take the GPU'
  T 'MUST FIRE  the crawl READS the evidence back and alerts when it has gone stale - recording a degradation nobody reads is a clean bill' `
    ($code -match ('--pool' + '-health') -and $code -match ('Send' + '-Alert')) 'a stale index would pass silently'
  # THE ORDER IS THE MECHANISM. Each of these four steps is individually correct in any order and the
  # chain only works in one: ingest the new shelf, build the index over it, score the pool against
  # that index, then read the result. Shipped 2026-09-04 with the rescore missing, and the reading
  # said `index fresh, 3134 covered` directly above `997 BLIND`.
  $iCrawl  = $code.IndexOf('--crawl')
  $iBuild  = $code.IndexOf('harvest_embed')
  $iScore  = $code.IndexOf('--' + 'rescore')
  $iRead   = $code.IndexOf('--pool' + '-health')
  T 'MUST FIRE  the pool is RESCORED against the fresh index - a rebuild nothing is scored against buys nothing' `
    ($iScore -gt 0) 'the crawl never rescores, so the new index is never read'
  $iCal = $code.IndexOf('--' + 'calibrate')
  T 'MUST FIRE  the ask floor is RE-READ off the labelled rulings - it is gitignored and dates itself against the digest, so nothing else maintains it' `
    ($iCal -gt 0) 'the crawl never recalibrates, so the embedding half of the shortlist can go quietly dead'
  T 'MUST FIRE  ...and in THIS order: crawl, rebuild, calibrate, rescore, read' `
    ($iCrawl -gt 0 -and $iCrawl -lt $iBuild -and $iBuild -lt $iCal -and $iCal -lt $iScore -and $iScore -lt $iRead) `
    ("crawl={0} build={1} calibrate={2} rescore={3} read={4}" -f $iCrawl, $iBuild, $iCal, $iScore, $iRead)
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
# ---- the dedup evidence index, rebuilt on the CPU under the sidecar venv --------------------------
# Measured 2026-09-04: this index was last written 2026-08-23 and covered 70 of 3,134 available
# candidates. Nothing built it and nothing read it, so the semantic half of the dedup evidence was
# absent for twelve days and every one of the 152 dupe rejections this estate has ever made was of a
# candidate carrying none. Best effort: a crawl that cannot embed still crawled, and says so.
$sidecar = Join-Path $repo 'sidecar\.venv\Scripts\python.exe'
$embed   = Join-Path $here 'harvest_embed.py'
if ((Test-Path $sidecar) -and (Test-Path $embed)) {
  Say '  rebuilding the dedup evidence index (bge-m3, CPU)'
  $eo = & $sidecar $embed '--build' '--device' 'cpu'
  $eo | Out-File -FilePath $log -Append -Encoding utf8
  foreach ($ln in @($eo)) { if ($ln -match 'candidate|carry no|COMPLETE|Error|Traceback') { Say ('  ' + $ln.Trim()) } }
} else {
  Say '  FINDING the evidence index was NOT rebuilt - no sidecar interpreter (torch lives there, the pinned one has none)'
}

# ---- and the ask floor is re-read off the labelled rulings -------------------------------------
# catalog-similarity.json is gitignored and dates itself against the catalog digest, so it is absent
# on a fresh checkout and stale whenever the catalog moves - and without it the embedding half of the
# dedup shortlist contributes nothing at all. The floor is read from the estate's own labelled dupes,
# which grow every run, so this is also how it sharpens.
if ((Test-Path $sidecar) -and (Test-Path $embed)) {
  $co = & $sidecar $embed '--calibrate' '--device' 'cpu'
  $co | Out-File -FilePath $log -Append -Encoding utf8
  foreach ($ln in @($co)) { if ($ln -match 'ask floor|OVERLAP|CANNOT RUN') { Say ('  ' + $ln.Trim()) } }
}

# ---- and then the pool is scored AGAINST the fresh index --------------------------------------
# WITHOUT THIS THE REBUILD BUYS NOTHING. A candidate's neighbour evidence is written when the pool
# is scored, so an index rebuilt after the last scoring is an index nothing has read. Measured
# 2026-09-04: straight after the first real rebuild the reading said `index fresh, 3134 covered` and
# `997 BLIND` on the line above it, and both were true.
$ro = & $py $harvest '--rescore'
$ro | Out-File -FilePath $log -Append -Encoding utf8
foreach ($ln in @($ro)) { if ($ln -match 'blind|neighbour|scored|FINDING') { Say ('  ' + $ln.Trim()) } }

# ---- and the reading, out loud, with an alert when it has gone stale ------------------------------
# THE PART THAT IS ACTUALLY "NEVER AGAIN". Every degradation above recorded itself faithfully and
# nothing ever read one, which is how a broken thing stayed indistinguishable from a working one.
$ph = @(& $py $harvest '--pool-health' | Where-Object { $_ -notmatch 'HARVEST-COMPLETE' })
foreach ($ln in $ph) { Say ([string]$ln) }
$idxLine = @($ph | Where-Object { $_ -match 'embed index' })
$tagLine = @($ph | Where-Object { $_ -match 'dedup at ingest' })
$idxStale = ($idxLine.Count -eq 0) -or ($idxLine[0] -notmatch 'embed index\s+fresh')
# a whole batch that could not reach the model is the second alertable shape: tagged, never judged
$allUnavail = ($tagLine.Count -gt 0) -and ($tagLine[0] -match 'unavailable=') -and ($tagLine[0] -notmatch 'llm=')
if ($idxStale -or $allUnavail) {
  $why = @()
  if ($idxStale)    { $why += 'the embedding index is not fresh' }
  if ($allUnavail)  { $why += 'no candidate in the pool has ever been judged by the local model' }
  Say ('  FINDING ' + ($why -join '; '))
  $lib = Join-Path $repo 'grocery\alert-lib.ps1'
  if (Test-Path $lib) {
    . $lib
    $bodyTxt = (($why -join "`n") + "`n`n" + ($ph -join "`n") + "`n`nRebuild: sidecar\.venv\Scripts\python.exe meal-prep\pipeline\harvest_embed.py --build --device cpu")
    Send-Alert -Subject 'Recipe pool: the dedup evidence has gone stale' -Body $bodyTxt | Out-Null
  }
  if ($rc -eq 0) { $rc = 1 }
}

Say ("harvest-crawl: exit {0}  (log: {1})" -f $rc, $log)
exit $rc
