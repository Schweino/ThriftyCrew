<#
  audit-semantic-identity.ps1 - the estate's front end to the local GPU semantic sidecar.

  WHY THIS EXISTS
  ---------------
  The measured #1 defect class is IDENTITY: the wrong product wearing a commodity's crown. Price
  verification cannot catch it (all four wrong products in the 2026-07-30 audit were top-of-ladder
  price-verified), and guard 5 cannot catch its mirror (a right product NO rule can see: "Cloves,
  Ground" was invisible while a $45 jar won the cell unopposed on 2026-08-01).

  Both are semantic questions. This script asks them of a local model and turns the answers into two
  advisory reports:

    IDENTITY  - shipped board cells that read as a poor instance of their commodity  -> arrivals desk
    COVERAGE  - products no rule matches that read as a real instance of one         -> rule worklist

  WHAT IT IS NOT
  --------------
  ADVISORY. It never changes a price, a crown, a rule or a link. It writes findings. A human or a
  frontier agent adjudicates through the existing paths (add-known-wrong for a wrong product, a
  commodities.json edit + crown-diff + tile-integrity for a coverage gap). That boundary is why it is
  safe to run unattended.

  BLIND, NEVER BLOCK
  ------------------
  If the sidecar is down, the GPU is busy, or Python is missing, this exits 3 (could-not-evaluate) and
  says so. It must NEVER stop a publish: the board cannot depend on a GPU box being healthy. Exit 3 is
  the same convention guards.ps1 uses for delegated audits, and OkUnlessBlind already knows how to read
  "0 findings" differently from "did not run" - which is the whole point of the zero-rows rule.

  REGEX STAYS HERE
  ----------------
  This script decides which products exist and which rules match them, using the SAME engine semantics
  (first-match-wins include, then exclude). Python never re-implements that. Two copies of a matching
  rule is this estate's most reliable bug.

  Usage
    .\audit-semantic-identity.ps1              prepare + sweep + report
    .\audit-semantic-identity.ps1 -PrepareOnly write the corpus, skip the GPU
    .\audit-semantic-identity.ps1 -SelfTest    frozen fixtures, no GPU, no data files
  Exit: 0 = ran (findings are advisory, never a failure)  2 = self-test regression  3 = BLIND
#>
# -Python exists so the BLIND path is TESTABLE. A failure mode nobody can exercise on demand is a
# failure mode nobody has actually verified, and "it degrades gracefully" is the easiest claim in
# software to believe and never check.
param([switch]$PrepareOnly, [switch]$SelfTest, [int]$MaxReport = 25, [string]$Python = '', [switch]$IncludeIdentity,
      # LANE 3 ONLY (phase 3, 2026-08-23). The contested questions come from the graph and are 97%
      # recipe-namespace, which the staple catalogue cannot define; the identity and coverage lanes
      # this script exists for keep reading commodity-defs.json and their findings do not move
      # (measured: identity 181, coverage 86, byte-identical either way).
      #
      # DEFAULTED HERE RATHER THAN AT THE CALLER, on purpose. The nightly chain is not the only
      # thing that runs this - the 07:00 and 08:00 jobs do too - and flags passed by one caller
      # would mean the last sweep of the day silently overwrote contested-scores.json with a
      # 15-of-435 version scored by the wrong model. One default, every caller, one file.
      [string]$ContestedDefs = (Join-Path (Split-Path $PSScriptRoot -Parent) 'sidecar\data\commodity-defs-graph.json'),
      # v3 WAS promoted here on 2026-08-23 and the promotion was REVERTED the same night. It beat v1
      # on all three cold hardeval numbers and filtered 18 of the live 435 where v1 filtered 21, and
      # every one of those differences turned out to be the training shuffle. Four seeds per arm:
      # holdout AUC ranges 0.9641-0.9674 and the live filtered count ranges 8-20 with the corpus and
      # the recipe held fixed. A single training run cannot separate two fine-tunes on these arenas,
      # so ANY future candidate must be compared over >= 3 seeds before it reaches this line.
      # v1 stands because it is the model phase 3 documents and the one that has actually run.
      [string]$Helper = (Join-Path (Split-Path $PSScriptRoot -Parent) 'sidecar\models\resolve-ce-v1'),
      [switch]$NoHelper,
      # PIN THE RULINGS THE HARNESS JUDGES AGAINST (2026-09-06, PLAN-top5 area 4). Empty = the live
      # known-wrong.json on the production path, and the FROZEN fixture under -SelfTest. The self-test's
      # own header promised "no data files" while loading the live ledger; a reversal of the coconut-oil
      # ruling would have turned this watcher red for a correct adjudication.
      [string]$LedgerFile = '')
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $root 'native-lib.ps1')   # Invoke-Native: a native child's stderr under EAP=Stop is a TERMINATING error, and `2>&1`/`2>$null` CAUSE that (native-lib.ps1)
$OutDir  = Join-Path $root 'out'
$sidecar = Join-Path (Split-Path $root -Parent) 'sidecar'
$py      = if ($Python) { $Python } else { Join-Path $sidecar '.venv\Scripts\python.exe' }
$sdData  = Join-Path $sidecar 'data'

# ---------------------------------------------------------------- the one classifier, fixtured below
# A finding is only worth a human's attention if it is ACTIONABLE. Two things make it not actionable:
# a store cell we already adjudicated (it is in known-wrong, the ruling stands), and a product whose
# commodity is not one we track. Filtering here rather than in Python keeps the estate's rulings in the
# estate's language.
function Test-Actionable {
  param([string]$Kind, [string]$Id, [string]$Store, [string]$Product, [hashtable]$Blocks, [hashtable]$BoardItems)
  if (-not $Id -or -not $Product) { return $false }
  # already ruled on: the blocklist IS the answer, so re-reporting it is noise
  if ($Blocks -and (Test-KnownWrong -Blocks $Blocks -CommodityId $Id -Store $Store -ProductName $Product)) { return $false }
  # TRUNCATION ARTEFACT (2026-08-01). A coverage finding claims "no rule matches this product". The corpus
  # it is drawn from carries names TRUNCATED AT EXACTLY 60 CHARACTERS (a historical capture cap, documented
  # in guards.ps1 invariant 5), and the truncation removes the end of a grocery name - which is where the
  # commodity word lives. So the rule that "does not match" often matches the FULL name perfectly.
  # `walnuts` is the founding case and it blocked its own adjudication for days: the corpus row reads
  # "Fisher Chef's Naturals Gluten Free, No Preservatives, Non-GM" while the board prices that very product
  # at $0.5712 under the full name "...Non-GMO Chopped Walnuts, 32 oz Bag". Nothing was invisible.
  # The test is deliberately narrow - truncated to exactly the cap AND a prefix of a product the board
  # already prices for this same commodity and store - so a genuinely invisible product is never suppressed
  # just because something else is priced there.
  if ($Kind -eq 'coverage' -and $BoardItems -and $Product.Length -eq 60) {
    $k = ($Id + '|' + $Store)
    if ($BoardItems.ContainsKey($k)) {
      foreach ($nm in @($BoardItems[$k])) {
        if ($nm -and $nm.Length -gt 60 -and $nm.StartsWith($Product, [StringComparison]::OrdinalIgnoreCase)) { return $false }
      }
    }
  }
  return $true
}

# ---------------------------------------------------------------- VRAM guard (Brad's ruling, 2026-08-22)
# The llama.cpp model (tools\local-llm\serve.ps1) takes ~13 GB of the 16 GB card and is ON-DEMAND ONLY,
# never scheduled, precisely because it cannot share the card with this sweep: bge-m3 + the reranker need
# ~3 GB. Launching sweep.py into a card llama-server holds does not fail fast - it OOMs minutes in, after
# the corpus prep, and reads as a Python crash. So the audit asks nvidia-smi FIRST and goes BLIND with a
# reason that names the holder. Both conditions are required: little free memory alone (a browser, the
# sidecar's own resident app.py) is not llama-server, and llama-server with room to spare is not a block.
$SWEEP_NEED_MIB = 3500
function Test-SweepBlocked {
  param([Nullable[int]]$FreeMiB, [bool]$LlamaRunning, [int]$NeedMiB = $SWEEP_NEED_MIB)
  if ($null -eq $FreeMiB) { return $null }      # no nvidia-smi reading: do not invent a block
  if ($LlamaRunning -and $FreeMiB -lt $NeedMiB) {
    return ("llama-server holds the GPU ({0} MiB free, the sweep needs ~{1} MiB) - stop tools\local-llm\serve.ps1 or wait" -f $FreeMiB, $NeedMiB)
  }
  return $null
}
function Get-GpuRoom {
  $free = $null
  try {
    $q = (Invoke-Native 'nvidia-smi' '--query-gpu=memory.free' '--format=csv,noheader,nounits').Output
    if ($q) { $free = [int](([string](@($q)[0])).Trim()) }
  } catch { }
  $llama = [bool](Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue)
  return @{ free = $free; llama = $llama }
}

if ($SelfTest) {
  # FROZEN FIXTURES (guard-fixture rule). No GPU, no network - so this runs in test-auditors every day
  # and proves the plumbing still discriminates.
  #
  # AND, SINCE 2026-09-06 (PLAN-top5 area 4), NO LIVE DATA FILE EITHER. The header above claimed exactly
  # that and the next line then loaded the LIVE known-wrong.json: the clean twin below rests on the
  # coconut-oil ruling still being in the live ledger, so a reversal - an ordinary, correct adjudication -
  # would have turned this watcher red, and a ledger edit could have changed what the twin was proving
  # without anyone touching this file. A verdict that depends on two inputs must have both of them frozen.
  # -LedgerFile is the pinning; the LIVE-TWIN case at the end still reads the shipped ledger on purpose.
  . (Join-Path $root 'known-wrong-lib.ps1')
  $fixLedger = if ($LedgerFile) { $LedgerFile } else { Join-Path $root 'regression-inputs\guard-fixtures\known-wrong-fixture.json' }
  $blocks = Get-KnownWrongBlocks -Path $fixLedger
  $bad = 0
  # The fixture must actually have loaded, or every "not actionable" case below passes by finding nothing -
  # a block set that reads as empty makes the clean twin the only case that can fail, and it fails wrongly.
  if (-not $blocks.ContainsKey("coconut-oil|Baker's")) {
    Write-Output ('  X the frozen ledger fixture did not load (' + $fixLedger + ') - every block case below would be judged against an EMPTY ruling set'); $bad++
  }
  # A REVERSED ruling is history, not a gate. Frozen here so the distinction cannot be lost silently.
  if ($blocks.ContainsKey('fixture-reversed|Fareway')) {
    Write-Output '  X a REVERSED ruling was loaded as a live block - reversed entries are a record, not a gate'; $bad++
  }
  # MUST-FIRE: an ordinary finding is actionable
  if (-not (Test-Actionable -Kind 'coverage' -Id 'ground-cloves' -Store 'Family Fare' -Product 'Our Family Cloves, Ground 2 Oz' -Blocks $blocks)) {
    Write-Output '  X MUST-FIRE: a fresh coverage finding must be actionable'; $bad++
  }
  # CLEAN TWIN: something already adjudicated must NOT be re-reported
  if (Test-Actionable -Kind 'identity' -Id 'coconut-oil' -Store "Baker's" -Product "Dr Teal's Foaming Bath with Pure Epsom Salt, Nourish & Protect with Coconut Oil" -Blocks $blocks) {
    Write-Output '  X CLEAN TWIN: an already-adjudicated cell must not be re-reported as a new finding'; $bad++
  }
  # MUST-FIRE: a malformed finding is never actionable
  if (Test-Actionable -Kind 'identity' -Id '' -Store 'Aldi' -Product 'x' -Blocks $blocks) {
    Write-Output '  X MUST-FIRE: a finding with no commodity id must be rejected'; $bad++
  }
  # TRUNCATION ARTEFACT - the walnuts case, frozen. The corpus name is cut at exactly 60 characters and the
  # board already prices that same product under its full name, so "no rule matches it" is false: the rule
  # matches the full name and did. This one finding blocked its own adjudication for days.
  $wTrunc = "Fisher Chef's Naturals Gluten Free, No Preservatives, Non-GM"
  $wFull  = "Fisher Chef's Naturals Gluten Free, No Preservatives, Non-GMO Chopped Walnuts, 32 oz Bag"
  $wBoard = @{ 'walnuts|Walmart' = @($wFull) }
  if (Test-Actionable -Kind 'coverage' -Id 'walnuts' -Store 'Walmart' -Product $wTrunc -Blocks $blocks -BoardItems $wBoard) {
    Write-Output '  X MUST-FIRE: a 60-char-truncated corpus name whose full product is already priced is an artefact, not a coverage gap'; $bad++
  }
  # CLEAN TWIN 1: same truncated name, but the board prices something ELSE for that commodity/store. This
  # product really may be invisible, so it must STAY actionable - the test must not suppress a genuine gap
  # just because the cell is filled.
  if (-not (Test-Actionable -Kind 'coverage' -Id 'walnuts' -Store 'Walmart' -Product $wTrunc -Blocks $blocks -BoardItems @{ 'walnuts|Walmart' = @('Great Value Walnut Halves, 16 oz Bag') })) {
    Write-Output '  X CLEAN TWIN: a truncated name that is NOT a prefix of the priced product is a real gap and must stay actionable'; $bad++
  }
  # CLEAN TWIN 2: a SHORT name that happens to prefix the board item is not a truncation - only names cut
  # at exactly the 60-char cap qualify, or every terse product name would be suppressed.
  if (-not (Test-Actionable -Kind 'coverage' -Id 'walnuts' -Store 'Walmart' -Product 'Fisher' -Blocks $blocks -BoardItems $wBoard)) {
    Write-Output '  X CLEAN TWIN: a short name is not a truncation artefact and must stay actionable'; $bad++
  }
  # VRAM GUARD, fixtured. MUST-FIRE: llama-server up and the card nearly full -> BLIND, naming the holder.
  $why = Test-SweepBlocked -FreeMiB 1092 -LlamaRunning $true
  if (-not $why) { Write-Output '  X MUST-FIRE: llama-server holding the card with 1092 MiB free must block the sweep'; $bad++ }
  elseif ($why -notmatch 'llama-server' -or $why -notmatch 'serve\.ps1') { Write-Output ("  X the BLIND reason must name the holder and the fix: " + $why); $bad++ }
  # CLEAN TWIN 1: the card is nearly full but llama-server is NOT the holder -> not this rule's call, run.
  if (Test-SweepBlocked -FreeMiB 1092 -LlamaRunning $false) { Write-Output '  X CLEAN TWIN: a full card without llama-server is not this guard''s block'; $bad++ }
  # CLEAN TWIN 2: llama-server up but with room to spare -> run.
  if (Test-SweepBlocked -FreeMiB 13600 -LlamaRunning $true) { Write-Output '  X CLEAN TWIN: llama-server with 13.6 GB free must not block'; $bad++ }
  # CLEAN TWIN 3: no nvidia-smi reading at all -> never invent a block.
  if (Test-SweepBlocked -FreeMiB $null -LlamaRunning $true) { Write-Output '  X CLEAN TWIN: no GPU reading must not block'; $bad++ }
  # LIVE-TWIN, LABELLED. The shipped ledger is still parsed, because a ledger that quietly stops loading
  # makes this audit re-report every cell the estate has already adjudicated. It asserts only that the file
  # LOADS and carries rulings - never that any particular ruling is still in it, which is a reviewer's call.
  # A red here means the LIVE FILE is broken, not that this watcher went blind.
  $liveBlocks = Get-KnownWrongBlocks -Path (Join-Path $root 'known-wrong.json')
  if ($liveBlocks.Count -lt 1) { Write-Output '  X LIVE-TWIN: the shipped known-wrong.json loaded ZERO blocks - every adjudicated cell will be re-reported as a fresh finding'; $bad++ }
  if ($bad -eq 0) { Write-Output ('audit-semantic-identity SELF-TEST PASS (frozen cases + a labelled LIVE-TWIN; live ledger carries ' + $liveBlocks.Count + ' block set(s))'); exit 0 }
  Write-Output ("audit-semantic-identity SELF-TEST FAIL ($bad)"); exit 2
}

. (Join-Path $root 'known-wrong-lib.ps1')

# ---------------------------------------------------------------- prepare the corpus (regex lives here)
Write-Output 'preparing corpus (engine regex semantics: first-match-wins include, then exclude)'
if (-not (Test-Path $sdData)) { New-Item -ItemType Directory -Force $sdData | Out-Null }
$coms = Read-JsonFile (Join-Path $root 'commodities.json')
$cmpF = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
if (-not $cmpF) { Write-Output 'BLIND: no comparison board to audit'; exit 3 }
$cmp = Read-JsonFile $cmpF.FullName

# board pairs = what we currently ship and therefore stand behind in public
$pairs = New-Object System.Collections.Generic.List[object]
foreach ($r in $cmp.comparison) {
  foreach ($s in $r.stores) {
    if ($s.item) { $pairs.Add([pscustomobject]@{ id = [string]$r.id; commodity = [string]$r.commodity; store = [string]$s.store; product = [string]$s.item }) }
  }
}
($pairs.ToArray() | ConvertTo-Json -Depth 4) | Set-Content (Join-Path $sdData 'board-pairs.json') -Encoding UTF8

# commodity definitions in natural language: label + what the board has ACCEPTED as one. Never the
# regex - feeding the model the patterns would relaunder the same blind spot in vector form.
$exemplars = @{}
foreach ($p in $pairs) { if (-not $exemplars.ContainsKey($p.id)) { $exemplars[$p.id] = New-Object System.Collections.Generic.List[string] }; if ($exemplars[$p.id].Count -lt 6) { $exemplars[$p.id].Add($p.product) } }
$defs = New-Object System.Collections.Generic.List[object]
foreach ($c in $coms) {
  $cid = [string]$c.id
  $defs.Add([pscustomobject]@{ id = $cid; label = [string]$c.label; unit = [string]$c.unit
    exemplars = $(if ($exemplars.ContainsKey($cid)) { @($exemplars[$cid]) } else { @() }) })
}
($defs.ToArray() | ConvertTo-Json -Depth 5) | Set-Content (Join-Path $sdData 'commodity-defs.json') -Encoding UTF8

# every product in every feed, with the CURRENT rules' verdict
$rx = New-Object System.Collections.Generic.List[object]
$exc = @{}
foreach ($c in $coms) {
  foreach ($p in @($c.include)) { if ($p) { $rx.Add([pscustomobject]@{ id = [string]$c.id; r = [regex]::new([string]$p, 'IgnoreCase,Compiled') }) } }
  $l = New-Object System.Collections.Generic.List[object]
  foreach ($p in @($c.exclude)) { if ($p) { $l.Add([regex]::new([string]$p, 'IgnoreCase,Compiled')) } }
  $exc[[string]$c.id] = $l
}
$seen = @{}
$corpus = New-Object System.Collections.Generic.List[object]
foreach ($f in (Get-ChildItem (Join-Path $OutDir 'regular\*-regular-*.json') -ErrorAction SilentlyContinue)) {
  try { $d = Read-JsonFile $f.FullName } catch { continue }
  $st = [string]$d.store
  foreach ($x in @($d.deals)) {
    $n = [string]$x.item; if (-not $n) { continue }
    $k = $st + '|' + $n; if ($seen.ContainsKey($k)) { continue }; $seen[$k] = $true
    $hit = ''
    foreach ($e in $rx) {
      if ($e.r.IsMatch($n)) {
        $bad = $false
        foreach ($xp in $exc[$e.id]) { if ($xp.IsMatch($n)) { $bad = $true; break } }
        if (-not $bad) { $hit = $e.id; break }
      }
    }
    $corpus.Add([pscustomobject]@{ store = $st; product = $n; rule_match = $hit })
  }
}
($corpus.ToArray() | ConvertTo-Json -Depth 3 -Compress) | Set-Content (Join-Path $sdData 'corpus-current.json') -Encoding UTF8
$invisible = @($corpus | Where-Object { -not $_.rule_match }).Count
Write-Output ("corpus: {0} product rows, {1} shipped board pairs, {2} match no rule" -f $corpus.Count, $pairs.Count, $invisible)
if ($PrepareOnly) { exit 0 }

# ---------------------------------------------------------------- run the GPU sweep (BLIND if it cannot)
if (-not (Test-Path $py)) { Write-Output "BLIND: no sidecar python at $py - the semantic check did not run. This is never a publish blocker."; exit 3 }
$sweep = Join-Path $sidecar 'sweep.py'
if (-not (Test-Path $sweep)) { Write-Output 'BLIND: sidecar sweep.py missing'; exit 3 }
$room = Get-GpuRoom
$blocked = Test-SweepBlocked -FreeMiB $room.free -LlamaRunning $room.llama
if ($blocked) { Write-Output ("BLIND: " + $blocked + ". The board is unaffected; the semantic guard did not run."); exit 3 }
Write-Output ('running the GPU sweep' + $(if ($null -ne $room.free) { " ({0} MiB VRAM free)" -f $room.free } else { '' }))
# EAP=Stop + a native command writing to stderr is fatal in PowerShell, and Python writes plenty of
# benign stderr: SyntaxWarnings, HuggingFace rate-limit notices, tqdm bars. The FIRST run of this audit
# died on a Python SyntaxWarning and reported a hard failure for a cosmetic warning. That is the
# logger-kills-pipeline trap wearing a different hat. Drop to Continue around the external call ONLY,
# and judge the run by its exit code and its output file, which are the things that actually mean
# something. A crashed sweep must read as BLIND, never as a board problem.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
# A missing definitions file or a missing helper is a NAMED condition, never a silent fallback:
# the lane degrades to what phase 2 shipped, and the run says which of the two it lost.
$swArgs = @($sweep)
if ($ContestedDefs -and (Test-Path $ContestedDefs)) { $swArgs += @('--contested-defs', $ContestedDefs) }
elseif ($ContestedDefs) { Write-Output ("  contested lane: no {0} - scoring against the staple catalogue only (run graph\pipeline\emit_commodity_defs.py --out)" -f (Split-Path $ContestedDefs -Leaf)) }
if (-not $NoHelper -and $Helper -and (Test-Path $Helper)) { $swArgs += @('--helper', $Helper) }
elseif (-not $NoHelper -and $Helper) { Write-Output ("  contested lane: no trained helper at {0} - the pinned model scores it, and resolve.py will refuse to filter on that" -f $Helper) }
$swOut = & $py @swArgs 2>&1 | ForEach-Object { [string]$_ }
$rc = $LASTEXITCODE
$ErrorActionPreference = $prevEap
$findF = Join-Path $sidecar 'out\semantic-findings.json'
if ($rc -ne 0 -or -not (Test-Path $findF)) {
  Write-Output ("BLIND: the sweep did not complete (exit $rc). The board is unaffected. Tail: " + (($swOut | Select-Object -Last 3) -join ' | '))
  exit 3
}
$find = Read-JsonFile $findF
# freshness: a findings file older than the board it claims to describe is a stale answer wearing a
# fresh label - the same trap as a stamp file older than the job that writes it.
try {
  if (([datetime]$find.generated) -lt (Get-Item $cmpF.FullName).LastWriteTime.AddHours(-24)) {
    Write-Output 'BLIND: findings file is older than the board it describes'; exit 3
  }
} catch {}

# ---------------------------------------------------------------- filter to what a human can act on
$blocks = Get-KnownWrongBlocks -Path $(if ($LedgerFile) { $LedgerFile } else { Join-Path $root 'known-wrong.json' })
# what the board already prices, keyed commodity|store, so the truncation test above has something to
# compare a cut-off corpus name against. Read from BOTH boards - anything reading only comparison-*.json
# is blind to 80 live recipe-board cells.
$boardItems = @{}
foreach ($bf in @(@(Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -EA SilentlyContinue | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1) + @(Get-Item (Join-Path $OutDir 'recipe-board.json') -EA SilentlyContinue))) {
  if (-not $bf) { continue }
  try {
    $bj = ((Get-Content $bf.FullName -Raw -Encoding UTF8) + '').Trim() | ConvertFrom-Json
    foreach ($r in @($bj.comparison)) {
      foreach ($s in @($r.stores)) {
        $nm = [string]$s.item
        if (-not $nm) { continue }
        $k = ([string]$r.id + '|' + [string]$s.store)
        if (-not $boardItems.ContainsKey($k)) { $boardItems[$k] = New-Object 'System.Collections.Generic.List[string]' }
        $boardItems[$k].Add($nm)
      }
    }
  } catch {}
}
$idRows = @(@($find.identity) | Where-Object { Test-Actionable -Kind 'identity' -Id ([string]$_.id) -Store ([string]$_.store) -Product ([string]$_.product) -Blocks $blocks -BoardItems $boardItems })
$cvRows = @(@($find.coverage) | Where-Object { Test-Actionable -Kind 'coverage' -Id ([string]$_.id) -Store ([string]$_.store) -Product ([string]$_.product) -Blocks $blocks -BoardItems $boardItems })
$cvTrunc = @($find.coverage).Count - $cvRows.Count - @(@($find.coverage) | Where-Object { $blocks -and (Test-KnownWrong -Blocks $blocks -CommodityId ([string]$_.id) -Store ([string]$_.store) -ProductName ([string]$_.product)) }).Count
if ($cvTrunc -gt 0) { Write-Output ("semantic-identity: {0} coverage finding(s) suppressed as TRUNCATION ARTEFACTS - the corpus name is cut at the 60-char cap and the board already prices that exact product under its full name" -f $cvTrunc) }

Write-Output ''
Write-Output ("semantic-identity: examined {0} shipped pair(s) and {1} rule-invisible product(s) in {2}s on {3}" -f $find.examined.board_pairs, $find.examined.rule_invisible, $find.elapsed_sec, $find.device)
# THE IDENTITY LANE IS OFF BY DEFAULT, and that is a measured decision, not caution.
# Phase 1 scored it at AUC 0.985, but that was against negatives which are DRAMATICALLY wrong: bath soap
# as coconut oil, dog food as salmon. Those are easy. Run against the whole live board it flags 173 pairs
# and every one inspected is CORRECT - "Wimmer's Wieners" for Hot Dogs, "Kroger Olive Oil Mayo" for
# Mayonnaise, "Yellow Bananas" for Bananas, "Dole Classic Romaine" for Lettuce. Even the six that BOTH
# the bi-encoder and the cross-encoder call weak are right.
# The models cannot separate a genuinely wrong product from a correctly-matched one that is tersely or
# synonymously named, and shipping it anyway would hand the arrivals desk 173 rows of noise a day. A
# guard nobody reads is worse than no guard - the exact lesson from the link-drift alert fixed this
# morning. It stays available behind -IncludeIdentity for evaluation, and it needs the fine-tune on our
# own ~6,000 adjudicated pairs before it earns a place in the nightly chain.
if ($IncludeIdentity) {
  Write-Output ("  IDENTITY (EXPERIMENTAL, not wired in)         : {0} actionable (of {1} raw)" -f $idRows.Count, @($find.identity).Count)
  foreach ($r in ($idRows | Select-Object -First $MaxReport)) {
    Write-Output ("    {0,-24} {1,-13} score={2,-9} cos={3,-8} {4}" -f $r.commodity, $r.store, $r.score, $r.cos, ([string]$r.product).Substring(0, [math]::Min(52, ([string]$r.product).Length)))
  }
  if ($idRows.Count -gt $MaxReport) { Write-Output ("    ... and {0} more (nothing truncated silently; see the findings file)" -f ($idRows.Count - $MaxReport)) }
} else {
  Write-Output ("  IDENTITY: {0} raw signal(s), SUPPRESSED - the lane is not accurate enough to ship (-IncludeIdentity to inspect). See the note in this script." -f @($find.identity).Count)
  $idRows = @()
}
# GROUPED BY COMMODITY, because that is the unit of work. A coverage gap is fixed by editing ONE
# commodity's rule, and 12 rows all saying "Arm & Hammer detergent is invisible" is one job, not twelve.
# Ungrouped, the count reads like a crisis; grouped, it reads like a worklist.
$cvGroups = @($cvRows | Group-Object id | Sort-Object { -(@($_.Group).Count) })
Write-Output ("  COVERAGE (real products no rule can see)      : {0} product(s) across {1} commodit(y/ies)" -f $cvRows.Count, $cvGroups.Count)
foreach ($g in ($cvGroups | Select-Object -First $MaxReport)) {
  $top = @($g.Group | Sort-Object { -[double]$_.score })[0]
  Write-Output ("    {0,-26} {1,2} product(s), best {2,-9} e.g. [{3}] {4}" -f $top.commodity, @($g.Group).Count, $top.score, $top.store, ([string]$top.product).Substring(0, [math]::Min(46, ([string]$top.product).Length)))
}
if ($cvGroups.Count -gt $MaxReport) { Write-Output ("    ... and {0} more commodit(y/ies) (nothing truncated silently; see the findings file)" -f ($cvGroups.Count - $MaxReport)) }

$report = [ordered]@{
  generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); board = $cmpF.Name
  sidecar_generated = [string]$find.generated; device = [string]$find.device
  thresholds = $find.thresholds; examined = $find.examined
  identity_count = $idRows.Count; coverage_count = $cvRows.Count
  identity = $idRows; coverage = $cvRows
}
$rp = Join-Path $OutDir 'semantic-findings.json'
($report | ConvertTo-Json -Depth 6) | Set-Content $rp -Encoding UTF8
Write-Output ''
Write-Output ("  -> $rp   ADVISORY ONLY: nothing here changes a price, a crown, a rule or a link.")
Write-GuardComplete -Name 'semantic-identity' -Summary ''
exit 0
