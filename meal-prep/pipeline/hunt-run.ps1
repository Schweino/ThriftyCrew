# hunt-run.ps1 - the Recipe Hunter v2 run state machine and wave assembler.
#
# WHY THIS EXISTS (2026-08-15). The Hunter streams: a recipe can be in QA while another is still being
# extracted. Streaming means the run's progress no longer lives in one session's head, and the estate has
# already paid for that twice - the burrito batch published 29 pages whose post-publish review was
# interrupted and NOTHING NOTICED (see batch-ledger.ps1), and a run that ends mid-flight is otherwise
# indistinguishable from one that finished. This file makes every recipe's position durable, derived, and
# resumable.
#
# THE ONE RULE THAT SHAPES THE DESIGN: a recipe's pricing status is DERIVED, never stored as a counter.
# Brad's flow chart carried a per-recipe "pending count" incremented at enqueue and decremented on
# completion, with "count == 0 and zero failures" as the ship condition. A counter written AFTER the tasks
# it counts can race: every task can finish before the count lands, and the recipe ships at zero having
# been checked zero times. That is the checkpoint-before-durable class. Here, pending and failed are
# recomputed from ingredient-queue.ps1's own verdicts every time they are read, so the number cannot
# disagree with the evidence.
#
# AND THE RULE THAT DECIDES REJECTIONS, inherited verbatim from the queue (Rule B): an ingredient is
# CARRIED when ONE of the seven Omaha stores carries it, NOT-CARRIED only when all seven have been CHECKED
# and none do. Anything else - a bot wall, a timeout, a store never reached - is PENDING, and a recipe
# waiting on a PENDING ingredient is PARKED, never rejected. Aldi and the Chrome extension both threw bot
# walls on 2026-08-14; treating "could not look" as "not carried" throws away good recipes.
#
# THIS FILE OWNS NO VERDICT LOGIC OF ITS OWN. It asks ingredient-queue.ps1 for verdicts and reads the
# `verdict` field that queue recomputes on every -Record through its single Get-QueueVerdict. Re-deriving
# Rule B here would be a second copy of a rule, which is how two copies of the same rule start disagreeing.
#
# Usage:
#   .\hunt-run.ps1 -Init -RunDir <p> -Conditions '20 high-protein slow cooker' -Stop '20 accepted' [-WaveSize 10]
#   .\hunt-run.ps1 -Advance -RunDir <p> -Slug <s> -To selected -By dedup-selector [-Detail '...']
#   .\hunt-run.ps1 -Advance -RunDir <p> -Slug <s> -To pricing -By mapper -Terms 'saffron,achiote paste' -OptionalTerms 'cilantro'
#   .\hunt-run.ps1 -Derive -RunDir <p> [-Slug <s>]
#   .\hunt-run.ps1 -WaveClose -RunDir <p> [-Drain] [-NoLedger]
#   .\hunt-run.ps1 -Status -RunDir <p> [-Json]
#   .\hunt-run.ps1 -SelfTest
param(
  [switch]$Init, [switch]$Advance, [switch]$Derive, [switch]$WaveClose, [switch]$Status, [switch]$SelfTest,
  [string]$RunDir = '', [string]$Slug = '', [string]$To = '', [string]$By = '', [string]$Detail = '',
  [string]$Title = '', [string]$SourceUrl = '', [string]$Protein = '',
  [string[]]$Terms = @(), [string[]]$OptionalTerms = @(),
  [string]$Conditions = '', [string]$Stop = '', [int]$WaveSize = 10,
  [string]$QueueScript = '', [switch]$Drain, [switch]$NoLedger, [switch]$Json
)
$ErrorActionPreference = 'Stop'

# CAPTURE EVERY SWITCH BEFORE DOT-SOURCING ANYTHING. A dot-sourced script runs its own param() block in
# THIS scope, so a lib declaring [switch]$SelfTest silently resets ours to $false - that PS 5.1 trap made
# migrate-prose-tokens' first -SelfTest run execute the LIVE path instead of its fixtures.
$runSelfTest = [bool]$SelfTest; $runInit = [bool]$Init; $runAdvance = [bool]$Advance
$runDerive = [bool]$Derive; $runWaveClose = [bool]$WaveClose; $runStatus = [bool]$Status
$runDrain = [bool]$Drain; $runNoLedger = [bool]$NoLedger; $runJson = [bool]$Json

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here                      # ...\meal-prep
$repo = Split-Path -Parent $mp                        # ...\income
. (Join-Path $repo 'lib\guard-contract.ps1')          # Write-GuardComplete: proves this ran to the end

# ---------------------------------------------------------------------------------------------------
# THE STATE GRAPH. Forward skips are the thing this refuses: the reason a recipe cannot go straight from
# `written` to `waved` is that qa-passed is the only door into a wave, and a wave is what publishes.
# ---------------------------------------------------------------------------------------------------
$script:REJECTED = @('rejected-dupe', 'rejected-unreadable', 'rejected-not-carried', 'rejected-qa', 'rejected-audit')
$script:NEXT = @{
  'sourced'    = @('selected', 'rejected-dupe')
  'selected'   = @('extracted', 'rejected-unreadable', 'rejected-dupe')
  'extracted'  = @('mapped', 'rejected-unreadable', 'rejected-dupe')
  'mapped'     = @('pricing', 'priced', 'rejected-not-carried')
  'pricing'    = @('priced', 'parked', 'rejected-not-carried')
  'parked'     = @('pricing', 'priced', 'parked', 'rejected-not-carried')
  'priced'     = @('spec-built')
  'spec-built' = @('written', 'spec-built', 'rejected-qa')
  # the QA repair routes. A source-QA failure is owner-routed, so a genuine transcription defect really
  # does send the recipe back to extraction; what stays refused is skipping FORWARD past qa-passed.
  'written'    = @('qa-passed', 'rejected-qa', 'written', 'spec-built', 'mapped', 'extracted')
  'qa-passed'  = @('waved')
  # an audit NO-GO trims a recipe back out of the wave, to repair or to rejection. It never publishes.
  'waved'      = @('published', 'rejected-audit', 'qa-passed', 'written')
  'published'  = @('verified')
  'verified'   = @()
}
foreach ($r in $script:REJECTED) { $script:NEXT[$r] = @() }
$script:ALL_STATES = @($script:NEXT.Keys)

function Test-LegalTransition {
  param([string]$From, [string]$To)
  if (-not $script:NEXT.ContainsKey($From)) { return $false }
  return (@($script:NEXT[$From]) -contains $To)
}

# ---------------------------------------------------------------------------------------------------
# DERIVED PRICING STATE. Pure: takes the recipe's recorded terms and a term->verdict map, returns the
# state. Unknown to the queue means PENDING - an ingredient nobody has answered for is not a rejection.
# ---------------------------------------------------------------------------------------------------
function Get-DerivedPricingState {
  param($TermRows, $VerdictMap)
  $pending = @(); $failed = @(); $carried = @()
  foreach ($t in @($TermRows)) {
    if ([bool]$t.optional) { continue }               # a garnish never blocks and never rejects a recipe
    $name = [string]$t.term
    $v = if ($VerdictMap.ContainsKey($name)) { [string]$VerdictMap[$name] } else { 'PENDING' }
    switch ($v) {
      'CARRIED'     { $carried += $name }
      'NOT-CARRIED' { $failed  += $name }
      default       { $pending += $name }
    }
  }
  $state = if ($failed.Count) { 'rejected-not-carried' } elseif ($pending.Count) { 'parked' } else { 'priced' }
  return [pscustomobject]@{ state = $state; pending = @($pending); failed = @($failed); carried = @($carried) }
}

# Only qa-passed recipes are eligible for a wave, FIFO by when they got there. Nothing else is a door.
function Select-WaveSlugs {
  param($Entries, [int]$Size)
  $ready = @(@($Entries) | Where-Object { [string]$_.state -eq 'qa-passed' } | Sort-Object { [string]$_.updated })
  if ($Size -gt 0 -and $ready.Count -gt $Size) { $ready = @($ready[0..($Size - 1)]) }
  return @($ready)
}

# ---------------------------------------------------------------------------------------------------
# IO. Temp-then-rename so a killed run never leaves a half-written state file, with a short retry because
# a transient lock must not kill a run (the logger-kills-pipeline lesson: EAP=Stop plus a locked file
# reads as a hang, not as an error).
# ---------------------------------------------------------------------------------------------------
$script:UTF8 = New-Object System.Text.UTF8Encoding($false)
function Read-Json {
  param([string]$Path)
  $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) -replace "^﻿", ''
  return ($raw | ConvertFrom-Json)
}
function Write-JsonAtomic {
  param([string]$Path, $Obj, [int]$Depth = 12)
  $json = ($Obj | ConvertTo-Json -Depth $Depth)
  $tmp = $Path + '.tmp'
  for ($i = 0; $i -lt 3; $i++) {
    try {
      [IO.File]::WriteAllText($tmp, $json, $script:UTF8)
      Move-Item -LiteralPath $tmp -Destination $Path -Force
      return
    } catch {
      if ($i -eq 2) { throw ("hunt-run: could not write '{0}' after 3 attempts: {1}" -f $Path, $_.Exception.Message) }
      Start-Sleep -Milliseconds (150 * ($i + 1))
    }
  }
}
function Get-Stamp { (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') }
function Get-StateDir { param([string]$Dir) Join-Path $Dir 'state' }
function Get-StatePath { param([string]$Dir, [string]$S) Join-Path (Get-StateDir $Dir) ($S + '.json') }
function Read-Entries {
  param([string]$Dir)
  $sd = Get-StateDir $Dir
  if (-not (Test-Path $sd)) { return @() }
  return @(Get-ChildItem (Join-Path $sd '*.json') -File | ForEach-Object { Read-Json $_.FullName })
}

# The live verdict map. ONE call to the queue, and we read the `verdict` it recomputes on every -Record
# through its own single implementation of Rule B. Re-deriving that rule here would be the second copy.
function Get-TermVerdictMap {
  param([string]$QueuePath)
  $map = @{}
  if (-not (Test-Path $QueuePath)) { return $map }
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $QueuePath -List -Json 2>&1
  $text = (@($out | ForEach-Object { [string]$_ }) -join "`n")
  try { $doc = $text | ConvertFrom-Json } catch { throw ("hunt-run: could not parse ingredient-queue output: " + $text) }
  foreach ($it in @($doc.items)) { $map[[string]$it.term] = [string]$it.verdict }
  return $map
}

# ===================================================================================================
# SELF-TEST. Every check is a must-fire fixture of a founding bug plus a clean twin, per the estate's
# guard-fixture rule: a guard with no must-fire case is indistinguishable from a guard that is broken.
# Hermetic - it writes only into a temp directory and calls nothing live.
# ===================================================================================================
if ($runSelfTest) {
  $f = 0
  function T($m, $c, $g) { if ($c) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $g); $script:f++ } }

  # ---- FIXTURE 1. THE FOUNDING BUG of this whole design, frozen. Brad's flow chart discarded a recipe
  # when "0 stores have a price", which cannot tell a store that said no from a store that was walled.
  # One unanswered ingredient must PARK the recipe, never reject it.
  #
  # NOTE ON THE VARIABLE NAMES HERE. These are $tRows, not $terms, because PowerShell variable names are
  # CASE-INSENSITIVE and this script declares [string[]]$Terms in its param block. A fixture assigned to
  # $terms binds to that TYPED parameter, which silently coerces each PSCustomObject to its "@{term=...}"
  # string - so every term read back as empty, every verdict lookup missed, and all three pricing
  # fixtures reported `parked` no matter what the map said. The first run of this self-test caught it.
  # Same family as the $ppg/$ppG 250,000x cost bug in the engine port. Do not rename these to $terms.
  $tRows = @([pscustomobject]@{ term = 'saffron'; optional = $false }, [pscustomobject]@{ term = 'achiote paste'; optional = $false })
  $vmPend = @{ 'saffron' = 'CARRIED'; 'achiote paste' = 'PENDING' }
  $d = Get-DerivedPricingState $tRows $vmPend
  T 'MUST FIRE  one PENDING ingredient parks the recipe, it never rejects it' ($d.state -eq 'parked') $d.state
  T '   and it parks for the RIGHT reason (the pending term is named)' (@($d.pending) -contains 'achiote paste') (@($d.pending) -join ',')
  $vmAll = @{ 'saffron' = 'CARRIED'; 'achiote paste' = 'CARRIED' }
  T 'CLEAN TWIN every blocking ingredient CARRIED prices the recipe' ((Get-DerivedPricingState $tRows $vmAll).state -eq 'priced') 'not priced'

  # a term the queue has never heard of is PENDING, not absent-therefore-fine. An ingredient nobody
  # answered for is exactly the case that must not ship.
  $d3 = Get-DerivedPricingState $tRows @{ 'saffron' = 'CARRIED' }
  T 'MUST FIRE  a term missing from the queue counts as PENDING, not as passed' ($d3.state -eq 'parked') $d3.state

  # ---- FIXTURE 2. A genuine NOT-CARRIED (all seven checked, none carry) is the ONLY way to reject...
  $vmFail = @{ 'saffron' = 'CARRIED'; 'achiote paste' = 'NOT-CARRIED' }
  $d4 = Get-DerivedPricingState $tRows $vmFail
  T 'MUST FIRE  a blocking NOT-CARRIED ingredient rejects the recipe' ($d4.state -eq 'rejected-not-carried') $d4.state
  T '   and it names the ingredient that killed it' (@($d4.failed) -contains 'achiote paste') (@($d4.failed) -join ',')
  # ...and the same verdict on an OPTIONAL line must not. The pricing stage must never reject a recipe
  # over a garnish, which is why the extractor marks `optional` at all.
  $tRowsOpt = @([pscustomobject]@{ term = 'saffron'; optional = $false }, [pscustomobject]@{ term = 'cilantro'; optional = $true })
  T 'CLEAN TWIN the same NOT-CARRIED on an OPTIONAL line does not reject' `
    ((Get-DerivedPricingState $tRowsOpt @{ 'saffron' = 'CARRIED'; 'cilantro' = 'NOT-CARRIED' }).state -eq 'priced') 'rejected on a garnish'
  # failed beats pending: a recipe with a dead ingredient is dead now, not parked forever waiting on the rest
  T 'a real failure outranks an outstanding check' `
    ((Get-DerivedPricingState $tRows @{ 'saffron' = 'PENDING'; 'achiote paste' = 'NOT-CARRIED' }).state -eq 'rejected-not-carried') 'parked instead'

  # ---- FIXTURE 3. Only qa-passed enters a wave. A recipe still in `written` has not been checked
  # against its source yet, and a wave is what publishes.
  $entries = @(
    [pscustomobject]@{ slug = 'a'; state = 'qa-passed'; updated = '2026-08-15T09:00:00' },
    [pscustomobject]@{ slug = 'b'; state = 'written';   updated = '2026-08-15T09:01:00' },
    [pscustomobject]@{ slug = 'c'; state = 'qa-passed'; updated = '2026-08-15T09:02:00' }
  )
  $w = Select-WaveSlugs $entries 10
  T 'MUST FIRE  a wave refuses a slug that is only `written`' (@($w | ForEach-Object { $_.slug }) -notcontains 'b') 'let an unchecked recipe into a wave'
  T 'CLEAN TWIN the qa-passed recipes do form the wave' (@($w).Count -eq 2) (@($w).Count)
  T 'a wave is capped at its size, FIFO' (@(Select-WaveSlugs $entries 1).Count -eq 1 -and (Select-WaveSlugs $entries 1)[0].slug -eq 'a') 'wrong slug or size'

  # ---- FIXTURE 4. Forward skips are refused in both directions that matter.
  T 'MUST FIRE  a published recipe cannot walk backwards into mapping' (-not (Test-LegalTransition 'published' 'mapped')) 'allowed'
  T 'MUST FIRE  a written recipe cannot skip QA straight into a wave'  (-not (Test-LegalTransition 'written' 'waved')) 'allowed'
  T 'MUST FIRE  a rejected recipe is terminal'                         (-not (Test-LegalTransition 'rejected-not-carried' 'priced')) 'allowed'
  T 'CLEAN TWIN the normal path is legal'                              (Test-LegalTransition 'qa-passed' 'waved') 'refused'
  T 'CLEAN TWIN an audit NO-GO may trim a recipe back out of its wave' (Test-LegalTransition 'waved' 'qa-passed') 'refused'
  T 'CLEAN TWIN a QA failure may route back to extraction for repair'  (Test-LegalTransition 'written' 'extracted') 'refused'

  # ---- FIXTURE 5. The state file round-trips through the atomic write with its history intact. History
  # is what makes an interrupted run readable afterwards; losing it silently is the whole failure mode.
  $tmp = Join-Path $env:TEMP ('huntrun-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force (Join-Path $tmp 'state') | Out-Null
  try {
    $e = [pscustomobject]@{ slug = 'x'; title = 'X'; state = 'pricing'; wave = $null; created = (Get-Stamp); updated = (Get-Stamp)
                            terms = @([pscustomobject]@{ term = 'saffron'; optional = $false })
                            history = @([pscustomobject]@{ state = 'sourced'; at = (Get-Stamp); by = 'test'; detail = '' },
                                        [pscustomobject]@{ state = 'pricing'; at = (Get-Stamp); by = 'test'; detail = 'two terms' })
                            reject_reason = $null }
    $p = Join-Path $tmp 'state\x.json'
    Write-JsonAtomic -Path $p -Obj $e
    $back = Read-Json $p
    T 'the state file round-trips'                      ([string]$back.slug -eq 'x' -and [string]$back.state -eq 'pricing') 'lost fields'
    T 'MUST FIRE  history survives the write'           (@($back.history).Count -eq 2) (@($back.history).Count)
    T 'terms survive the write with their optional flag' (@($back.terms).Count -eq 1 -and -not [bool]@($back.terms)[0].optional) 'lost terms'
    T 'the temp file is not left behind'                (-not (Test-Path ($p + '.tmp'))) 'stray .tmp'
    # a one-element array must stay an array through PS 5.1 round-tripping - the collapse that made a
    # one-row ledger unreadable by the very stamp that wrote it
    T 'MUST FIRE  a single-element array does not collapse to a scalar' (@($back.terms).Count -eq 1 -and $null -ne @($back.terms)[0].term) 'collapsed'
  } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

  if ($f -eq 0) { Write-Output 'hunt-run SELF-TEST PASS'; exit 0 }
  Write-Output ("hunt-run SELF-TEST FAIL: {0} case(s)" -f $f); exit 1
}

# ===================================================================================================
# LIVE
# ===================================================================================================
if (-not $RunDir) { Write-Output 'hunt-run: -RunDir is required'; exit 1 }
if (-not $QueueScript) { $QueueScript = Join-Path $repo 'grocery\ingredient-queue.ps1' }

# ---- -Init ----------------------------------------------------------------------------------------
if ($runInit) {
  foreach ($d in @('', 'state', 'candidates', 'selected', 'extracted', 'mapped', 'intake', 'qa', 'waves')) {
    $p = if ($d) { Join-Path $RunDir $d } else { $RunDir }
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force $p | Out-Null }
  }
  $runId = Split-Path $RunDir -Leaf
  # PROVENANCE IS MEASURED, NOT WRITTEN. The digest and board dates are read off the files themselves;
  # a hand-typed as_of is the laundering class that surfaces later as a wrong price.
  $digest = Join-Path $mp 'pipeline\catalog-digest.json'
  $digestDate = if (Test-Path $digest) { (Get-Item $digest).LastWriteTime.ToString('yyyy-MM-ddTHH:mm:ss') } else { $null }
  $board = @(Get-ChildItem (Join-Path $repo 'grocery\out\comparison-*.json') -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1)
  $doc = [pscustomobject]@{
    run = $runId; created = (Get-Stamp); conditions = $Conditions; stop = $Stop; wave_size = $WaveSize
    auto_publish = $true
    catalog_digest = $digest; catalog_digest_written = $digestDate
    board_file = $(if ($board.Count) { $board[0].Name } else { $null })
    board_written = $(if ($board.Count) { $board[0].LastWriteTime.ToString('yyyy-MM-ddTHH:mm:ss') } else { $null })
  }
  Write-JsonAtomic -Path (Join-Path $RunDir 'run.json') -Obj $doc
  Write-Output ("hunt-run: initialised {0}  (wave size {1})" -f $runId, $WaveSize)
  if (-not $digestDate) { Write-Output '  WARNING no pipeline\catalog-digest.json - run make-catalog-digest.ps1 before sourcing' }
  if (-not $board.Count) { Write-Output '  WARNING no grocery\out\comparison-*.json - pricing reads it' }
  else { Write-Output ("  board: {0} (written {1})" -f $board[0].Name, $board[0].LastWriteTime.ToString('yyyy-MM-dd HH:mm')) }
  Write-GuardComplete -Name 'hunt-run' -Summary ("init {0}" -f $runId); exit 0
}

# ---- -Advance -------------------------------------------------------------------------------------
if ($runAdvance) {
  if (-not $Slug -or -not $To) { Write-Output 'hunt-run: -Advance needs -Slug and -To'; exit 1 }
  if (@($script:ALL_STATES) -notcontains $To) {
    Write-Output ("hunt-run: '{0}' is not a state. One of: {1}" -f $To, (@($script:ALL_STATES | Sort-Object) -join ', ')); exit 1
  }
  $sp = Get-StatePath $RunDir $Slug
  if (-not (Test-Path $sp)) {
    if ($To -ne 'sourced') {
      Write-Output ("hunt-run: '{0}' has no state file - its first -Advance must be -To sourced" -f $Slug); exit 1
    }
    $e = [pscustomobject]@{ slug = $Slug; title = $Title; source_url = $SourceUrl; protein = $Protein
                            state = 'sourced'; wave = $null; created = (Get-Stamp); updated = (Get-Stamp)
                            terms = @(); reject_reason = $null; parked_on = @()
                            history = @([pscustomobject]@{ state = 'sourced'; at = (Get-Stamp); by = $By; detail = $Detail }) }
    Write-JsonAtomic -Path $sp -Obj $e
    Write-Output ("hunt-run: {0}  ->  sourced" -f $Slug)
    Write-GuardComplete -Name 'hunt-run' -Summary ("advance {0} sourced" -f $Slug); exit 0
  }
  $e = Read-Json $sp
  $from = [string]$e.state
  if ($from -eq $To -and $To -ne 'written' -and $To -ne 'parked' -and $To -ne 'spec-built') {
    Write-Output ("hunt-run: {0} is already {1}  (no-op)" -f $Slug, $To)
    Write-GuardComplete -Name 'hunt-run' -Summary 'advance noop'; exit 0
  }
  if (-not (Test-LegalTransition $from $To)) {
    Write-Output ("hunt-run: REFUSED {0}: {1} -> {2}. Legal from '{1}': {3}" -f $Slug, $from, $To, $(if (@($script:NEXT[$from]).Count) { @($script:NEXT[$from]) -join ', ' } else { '(terminal)' }))
    exit 1
  }
  if (@($Terms).Count -or @($OptionalTerms).Count) {
    $rows = @()
    foreach ($t in @($Terms)      | Where-Object { $_ }) { $rows += [pscustomobject]@{ term = [string]$t; optional = $false } }
    foreach ($t in @($OptionalTerms) | Where-Object { $_ }) { $rows += [pscustomobject]@{ term = [string]$t; optional = $true } }
    $e.terms = @($rows)
  }
  $e.state = $To
  $e.updated = Get-Stamp
  if (@($script:REJECTED) -contains $To) { $e.reject_reason = $Detail }
  $e.history = @(@($e.history) + @([pscustomobject]@{ state = $To; at = (Get-Stamp); by = $By; detail = $Detail }))
  Write-JsonAtomic -Path $sp -Obj $e
  Write-Output ("hunt-run: {0}  {1}  ->  {2}{3}" -f $Slug, $from, $To, $(if ($Detail) { "   ($Detail)" } else { '' }))
  Write-GuardComplete -Name 'hunt-run' -Summary ("advance {0} {1}" -f $Slug, $To); exit 0
}

# ---- -Derive --------------------------------------------------------------------------------------
# Recompute pricing-derived states from the queue's own verdicts. Safe and cheap to run after every
# pricer invocation; it is the only thing that moves a recipe out of `pricing` or `parked`.
if ($runDerive) {
  $map = Get-TermVerdictMap $QueueScript
  $entries = @(Read-Entries $RunDir)
  if ($Slug) { $entries = @($entries | Where-Object { [string]$_.slug -eq $Slug }) }
  $moved = 0; $lines = @()
  foreach ($e in $entries) {
    if (@('pricing', 'parked') -notcontains [string]$e.state) { continue }
    $d = Get-DerivedPricingState $e.terms $map
    if ($d.state -eq [string]$e.state) { continue }
    if (-not (Test-LegalTransition ([string]$e.state) $d.state)) { continue }
    $detail = switch ($d.state) {
      'priced'               { "all {0} blocking ingredient(s) carried" -f @($d.carried).Count }
      'parked'               { "waiting on: " + (@($d.pending) -join ', ') }
      'rejected-not-carried' { "not carried in Omaha: " + (@($d.failed) -join ', ') }
    }
    $from = [string]$e.state
    $e.state = $d.state; $e.updated = Get-Stamp
    $e.parked_on = @($d.pending)
    if (@($script:REJECTED) -contains $d.state) { $e.reject_reason = $detail }
    $e.history = @(@($e.history) + @([pscustomobject]@{ state = $d.state; at = (Get-Stamp); by = 'derive'; detail = $detail }))
    Write-JsonAtomic -Path (Get-StatePath $RunDir ([string]$e.slug)) -Obj $e
    $moved++; $lines += ("  {0}  {1} -> {2}   {3}" -f $e.slug, $from, $d.state, $detail)
  }
  Write-Output ("hunt-run derive: {0} recipe(s) moved" -f $moved)
  $lines | ForEach-Object { Write-Output $_ }
  Write-GuardComplete -Name 'hunt-run' -Summary ("derive moved={0}" -f $moved); exit 0
}

# ---- -WaveClose -----------------------------------------------------------------------------------
if ($runWaveClose) {
  $runDoc = Read-Json (Join-Path $RunDir 'run.json')
  $size = if ($WaveSize -gt 0 -and $PSBoundParameters.ContainsKey('WaveSize')) { $WaveSize } else { [int]$runDoc.wave_size }
  $entries = @(Read-Entries $RunDir)
  $ready = @(Select-WaveSlugs $entries $size)
  if (-not $ready.Count) { Write-Output 'hunt-run: no qa-passed recipes waiting - nothing to close'; exit 1 }
  if ($ready.Count -lt $size -and -not $runDrain) {
    Write-Output ("hunt-run: only {0} of {1} qa-passed - pass -Drain to close a short wave" -f $ready.Count, $size); exit 1
  }
  $existing = @(Get-ChildItem (Join-Path $RunDir 'waves\wave-*.json') -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^wave-(\d+)\.json$' })
  $k = 1
  foreach ($x in $existing) { if ($x.Name -match '^wave-(\d+)\.json$') { $n = [int]$Matches[1]; if ($n -ge $k) { $k = $n + 1 } } }
  $runId = [string]$runDoc.run
  $batch = "$runId-w$k"
  $slugs = @($ready | ForEach-Object { [string]$_.slug })
  $manifest = [pscustomobject]@{
    wave = $k; run = $runId; batch = $batch; created = (Get-Stamp); slugs = @($slugs)
    recipes = @($ready | ForEach-Object { [pscustomobject]@{ slug = [string]$_.slug; title = [string]$_.title; source_url = [string]$_.source_url; protein = [string]$_.protein } })
  }
  Write-JsonAtomic -Path (Join-Path $RunDir ("waves\wave-{0}.json" -f $k)) -Obj $manifest
  foreach ($e in $ready) {
    $e.state = 'waved'; $e.wave = $k; $e.updated = Get-Stamp
    $e.history = @(@($e.history) + @([pscustomobject]@{ state = 'waved'; at = (Get-Stamp); by = 'wave-close'; detail = "wave $k" }))
    Write-JsonAtomic -Path (Get-StatePath $RunDir ([string]$e.slug)) -Obj $e
  }
  if (-not $runNoLedger) {
    $bl = Join-Path $here 'batch-ledger.ps1'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $bl -Start -Batch $batch -Slugs $slugs | Out-Null
    # the four stages that genuinely completed per-recipe upstream of the wave. Stamped only now, and
    # only because the wave proves they happened for every slug in it.
    foreach ($st in @('select', 'map', 'write', 'build-specs')) {
      & powershell -NoProfile -ExecutionPolicy Bypass -File $bl -Stamp -Batch $batch -Stage $st -Detail 'streamed per-recipe before wave close' | Out-Null
    }
  }
  Write-Output ("hunt-run: wave {0} closed with {1} recipe(s)  [batch {2}]" -f $k, $slugs.Count, $batch)
  $slugs | ForEach-Object { Write-Output ("  " + $_) }
  Write-Output ("  next: recipe-batch-auditor -> waves\wave-{0}.audit.md (first line GO or NO-GO), then wave-publish.ps1 -RunDir <p> -Wave {0}" -f $k)
  Write-GuardComplete -Name 'hunt-run' -Summary ("wave {0} closed n={1}" -f $k, $slugs.Count); exit 0
}

# ---- -Status (also the resume entry point) --------------------------------------------------------
$entries = @(Read-Entries $RunDir)
$byState = @{}
foreach ($e in $entries) { $s = [string]$e.state; if (-not $byState.ContainsKey($s)) { $byState[$s] = @() }; $byState[$s] += [string]$e.slug }
$published = @(@($entries | Where-Object { @('published', 'verified') -contains [string]$_.state }))
$rejected  = @(@($entries | Where-Object { @($script:REJECTED) -contains [string]$_.state }))
$parked    = @(@($entries | Where-Object { [string]$_.state -eq 'parked' }))
$inflight  = @(@($entries | Where-Object { @('published', 'verified', 'parked') -notcontains [string]$_.state -and @($script:REJECTED) -notcontains [string]$_.state }))
$waves = @(Get-ChildItem (Join-Path $RunDir 'waves\wave-*.json') -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^wave-\d+\.json$' })

if ($runJson) {
  $o = [pscustomobject]@{
    run = (Split-Path $RunDir -Leaf); total = $entries.Count
    published = @($published | ForEach-Object { [string]$_.slug })
    parked = @($parked | ForEach-Object { [pscustomobject]@{ slug = [string]$_.slug; waiting_on = @($_.parked_on) } })
    rejected = @($rejected | ForEach-Object { [pscustomobject]@{ slug = [string]$_.slug; state = [string]$_.state; reason = [string]$_.reject_reason } })
    in_flight = @($inflight | ForEach-Object { [pscustomobject]@{ slug = [string]$_.slug; state = [string]$_.state } })
    by_state = $byState; waves = @($waves | ForEach-Object { $_.Name })
  }
  ($o | ConvertTo-Json -Depth 8)
  exit 0
}
Write-Output ("hunt-run status: {0}   {1} recipe(s)" -f (Split-Path $RunDir -Leaf), $entries.Count)
Write-Output ''
Write-Output ("  PUBLISHED  {0}" -f $published.Count)
Write-Output ("  IN FLIGHT  {0}" -f $inflight.Count)
Write-Output ("  PARKED     {0}   (waiting on a store, NOT rejected)" -f $parked.Count)
Write-Output ("  REJECTED   {0}" -f $rejected.Count)
Write-Output ''
foreach ($s in @($byState.Keys | Sort-Object)) { Write-Output ("  {0,-22} {1}" -f $s, @($byState[$s]).Count) }
if ($parked.Count) {
  Write-Output ''
  Write-Output '  PARKED detail (this is the resume worklist):'
  foreach ($p in $parked) { Write-Output ("    {0,-34} waiting on: {1}" -f $p.slug, $(if (@($p.parked_on).Count) { @($p.parked_on) -join ', ' } else { '(unknown - run -Derive)' })) }
}
if ($rejected.Count) {
  Write-Output ''
  Write-Output '  REJECTED detail:'
  foreach ($r in $rejected) { Write-Output ("    {0,-34} {1}  {2}" -f $r.slug, $r.state, [string]$r.reject_reason) }
}
if ($waves.Count) {
  Write-Output ''
  Write-Output '  WAVES:'
  foreach ($w in $waves) {
    # the audit sits BESIDE the manifest, in waves\. Joining this against $RunDir instead made every wave
    # report "no audit yet" however green its audit was - a status line that can never show a verdict is
    # worse than none, because the operator acts on it.
    $audit = Join-Path $w.DirectoryName ($w.BaseName + '.audit.md')
    $verdict = 'no audit yet'
    if (Test-Path $audit) {
      $first = @(Get-Content $audit -TotalCount 1)
      $verdict = if ($first.Count) { ([string]$first[0]).Trim() } else { '(empty audit file)' }
    }
    Write-Output ("    {0,-16} {1}" -f $w.BaseName, $verdict)
  }
}
Write-GuardComplete -Name 'hunt-run' -Summary ("status n={0} published={1} parked={2} rejected={3}" -f $entries.Count, $published.Count, $parked.Count, $rejected.Count)
exit 0
