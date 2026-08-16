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
#   .\hunt-run.ps1 -Lane -RunDir <p> -LaneName price -Label 'pricer batch 1' -Items 'saffron,achiote paste'
#   .\hunt-run.ps1 -WaveClose -RunDir <p> [-Drain] [-NoLedger]
#   .\hunt-run.ps1 -Status -RunDir <p> [-Json]
#   .\hunt-run.ps1 -SelfTest
param(
  [switch]$Init, [switch]$Advance, [switch]$Derive, [switch]$WaveClose, [switch]$Status, [switch]$SelfTest,
  [switch]$Lane, [switch]$LaneSummary,
  [int]$InputTokens = -1, [int]$OutputTokens = -1,   # -1 = not reported (older lines, or a lane that cannot see usage)
  [ValidateSet('', 'start', 'end')][string]$Event = '',   # pair start/end on the same lane+label to get duration
  [string]$RunDir = '', [string]$Slug = '', [string]$To = '', [string]$By = '', [string]$Detail = '',
  [string]$Title = '', [string]$SourceUrl = '', [string]$Protein = '',
  [string[]]$Terms = @(), [string[]]$OptionalTerms = @(),
  [string]$LaneName = '', [string]$Label = '', [string[]]$Items = @(),
  [string]$Conditions = '', [string]$Stop = '', [int]$WaveSize = 10,
  [string]$QueueScript = '', [switch]$Drain, [switch]$NoLedger, [switch]$Json
)
$ErrorActionPreference = 'Stop'

# CAPTURE EVERY SWITCH BEFORE DOT-SOURCING ANYTHING. A dot-sourced script runs its own param() block in
# THIS scope, so a lib declaring [switch]$SelfTest silently resets ours to $false - that PS 5.1 trap made
# migrate-prose-tokens' first -SelfTest run execute the LIVE path instead of its fixtures.
$runLaneSummary = [bool]$LaneSummary
$runSelfTest = [bool]$SelfTest; $runInit = [bool]$Init; $runAdvance = [bool]$Advance
$runDerive = [bool]$Derive; $runWaveClose = [bool]$WaveClose; $runStatus = [bool]$Status
$runLane = [bool]$Lane
$runDrain = [bool]$Drain; $runNoLedger = [bool]$NoLedger; $runJson = [bool]$Json

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here                      # ...\meal-prep
$repo = Split-Path -Parent $mp                        # ...\income
. (Join-Path $repo 'lib\guard-contract.ps1')          # Write-GuardComplete: proves this ran to the end

# ---------------------------------------------------------------------------------------------------
# THE STATE GRAPH. Forward skips are the thing this refuses: the reason a recipe cannot go straight from
# `written` to `waved` is that qa-passed is the only door into a wave, and a wave is what publishes.
# ---------------------------------------------------------------------------------------------------
# NAMED _STATES DELIBERATELY. As `$script:REJECTED` it was clobbered by a local `$rejected` holding the
# status report's rejected ROWS - PowerShell variable names are case-insensitive, so the two were one
# variable. The constant became a list of recipe objects, `-notcontains` then matched nothing, and the
# status screen reported all 9 recipes in flight while also reporting 7 of them rejected. Second instance
# of this class in this one file (see the self-test's $tRows note); same family as the $ppg/$ppG 250,000x
# engine bug. Give a shared constant a name no local would ever take.
$script:REJECTED_STATES = @('rejected-dupe', 'rejected-unreadable', 'rejected-not-carried', 'rejected-qa', 'rejected-audit', 'rejected-macros')
$script:NEXT = @{
  'sourced'    = @('selected', 'rejected-dupe')
  'selected'   = @('extracted', 'rejected-unreadable', 'rejected-dupe')
  # `rejected-macros`: the recipe is readable, not a dupe, and its ingredients are buyable - it simply
  # cannot land inside the run's macro window on any label-accurate reading. Added 2026-08-16, when the
  # mapper rejected two recipes on exactly those grounds and had nowhere to put the verdict: from
  # `extracted` the only exits were dupe and unreadable, and both would have been false. The mapper
  # refused to force it, correctly, and the recipes sat at `extracted` looking stuck to everyone
  # watching. A verdict a state machine cannot express is a verdict that gets faked or lost.
  'extracted'  = @('mapped', 'rejected-unreadable', 'rejected-dupe', 'rejected-macros')
  'mapped'     = @('pricing', 'priced', 'rejected-not-carried', 'rejected-macros')
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
  # `held` is a LIVE page deliberately taken down: a serveability rollback (wave-publish E7), or any manual
  # takedown. It exists because on 2026-08-15 two recipes were set back to draft in Ghost by hand while
  # their state files still read `published`, so the run record claimed live pages that were not live. A
  # takedown with no state is indistinguishable from a publish that worked.
  # held -> verified is REFUSED on purpose: a held recipe must go back through `published` (which means
  # actually re-publishing it) before anyone can verify it. Verifying a drafted page is the exact lie this
  # state exists to prevent.
  'published'  = @('verified', 'held')
  'held'       = @('published')
  'verified'   = @()
}
foreach ($r in $script:REJECTED_STATES) { $script:NEXT[$r] = @() }
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

# ---------------------------------------------------------------------------------------------------
# THE LANE LOG. One append-only line per agent invocation, in `<RunDir>\lane-log.jsonl`.
#
# WHY (2026-08-15). A session built the hunt orchestration off SKILL.md alone instead of the plan's
# section 2.4 and made PRICING a per-recipe pipeline stage. The price lane is a SINGLETON QUEUE DRAINER
# that batches up to 10 terms ACROSS recipes - ingredient-queue.ps1 is keyed by TERM, not by recipe - so
# per-recipe pricing throws away the cross-recipe dedup and opens 7 store sessions per RECIPE instead of
# per 10-term batch. That is the exact sweep shape that walled Walmart at 55 of 526 terms. Nothing caught
# it: every artifact the run left behind (states, queue, waves) is identical whether the lane batched or
# not, because they all record the RESULT and none records the SHAPE OF THE WORK.
#
# So the shape gets written down as it happens. This file is what audit-lane-shape.ps1 reads, and it is
# also the honest source for the v2.1 section 5.2 usage instrumentation and the 5.3 singleton check, both
# of which otherwise have to be reconstructed by re-reading workflow transcripts.
#
# APPEND-ONLY AND NEVER REWRITTEN, deliberately: a lane log that can be edited after the fact certifies
# nothing. JSONL rather than a JSON array for the same reason - a killed run leaves every completed line
# readable, where a truncated array is unparseable in full.
$script:LANES = @('hunt', 'select', 'extract', 'map', 'price', 'write', 'qa', 'audit', 'publish', 'review')

# Items arrive either as a real array (in-process) or as ONE comma-joined string, because `powershell -File`
# marshals a [string[]] as a single command-line argument - the frozen ledger bug in fixture 6 below. Both
# shapes must produce the same rows or the audit under-counts exactly the runs it exists to judge.
function Split-LaneItems {
  param($Raw)
  $out = @()
  foreach ($chunk in @($Raw)) {
    foreach ($piece in ([string]$chunk -split ',')) {
      $t = $piece.Trim()
      if ($t) { $out += $t }
    }
  }
  return @($out)
}

function New-LaneLine {
  param([string]$LaneName, [string]$Label, $ItemList, [string]$By, [string]$Detail, [string]$At,
        [int]$In = -1, [int]$Out = -1, [string]$Event = '')
  $rows = @(Split-LaneItems $ItemList)
  # in/out are the agent's reported token usage for THIS invocation. -1 means "not reported" and is
  # kept distinct from 0: a stage that genuinely returned nothing is not the same as a stage whose
  # usage the orchestrator could not see, and a summary that averages them together lies about both.
  # `event` pairs a start line with an end line on the same lane+label, which is the only way this
  # estate can measure DURATION: the orchestrator runs in a sandbox where Date.now() throws, so it
  # cannot time its own agent calls. The agent stamps both ends itself instead.
  return [pscustomobject]@{
    at = $At; lane = $LaneName; label = $Label; count = $rows.Count; items = @($rows)
    by = $By; detail = $Detail; in = $In; out = $Out; event = $Event
  }
}

function Add-LaneLine {
  param([string]$Path, $Line)
  # -Compress so one invocation is one line. A pretty-printed object would span lines and JSONL would stop
  # being JSONL the moment anything read it a line at a time.
  $json = ($Line | ConvertTo-Json -Depth 6 -Compress)
  for ($i = 0; $i -lt 3; $i++) {
    try { [IO.File]::AppendAllText($Path, ($json + "`r`n"), $script:UTF8); return }
    catch {
      if ($i -eq 2) { throw ("hunt-run: could not append to '{0}' after 3 attempts: {1}" -f $Path, $_.Exception.Message) }
      Start-Sleep -Milliseconds (150 * ($i + 1))
    }
  }
}

function Read-LaneLog {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return @() }
  $out = @()
  foreach ($ln in @([IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8))) {
    $t = ([string]$ln -replace "^﻿", '').Trim()
    if (-not $t) { continue }
    $out += ($t | ConvertFrom-Json)
  }
  return @($out)
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

  # ---- FIXTURE 4b. A macro rejection has somewhere to go. On 2026-08-16 it did not: the mapper ruled
  # two recipes outside the run's calorie/carb window, and `extracted` offered only dupe and unreadable.
  # Both would have been false, so the mapper refused to advance them at all and they read as stuck.
  T 'MUST FIRE  a macro rejection is reachable from extracted'         (Test-LegalTransition 'extracted' 'rejected-macros') 'refused'
  T 'MUST FIRE  a macro rejection is reachable from mapped'            (Test-LegalTransition 'mapped' 'rejected-macros') 'refused'
  T 'MUST FIRE  a macro rejection is terminal like every other reject' (-not (Test-LegalTransition 'rejected-macros' 'mapped')) 'allowed'
  T 'CLEAN TWIN rejected-macros counts as a rejection, not as in-flight' ($script:REJECTED_STATES -contains 'rejected-macros') 'missing from REJECTED_STATES'

  # ---- FIXTURE 4b. THE `held` STATE, frozen at its founding bug. On 2026-08-15 two published recipes were
  # set back to DRAFT in Ghost by hand because their cards could not price, and their state files went on
  # reading `published` - the run record asserted two live pages that were not live. A takedown needs a
  # state or it is invisible.
  T 'CLEAN TWIN a published recipe can be held (a takedown is recordable)' (Test-LegalTransition 'published' 'held') 'refused'
  T 'CLEAN TWIN a held recipe can go back to published once its dependency is fixed' (Test-LegalTransition 'held' 'published') 'refused'
  T 'MUST FIRE  a held recipe cannot be VERIFIED without republishing first' `
    (-not (Test-LegalTransition 'held' 'verified')) 'let a drafted page be verified as live'
  T 'MUST FIRE  a held recipe cannot walk back into the pipeline' (-not (Test-LegalTransition 'held' 'written')) 'allowed'

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

  # ---- FIXTURE 6. THE LEDGER MARSHALLING BUG, frozen. WaveClose opens the batch-ledger row that records
  # which recipes are in the wave. Called through `powershell -File`, a [string[]] -Slugs marshals as ONE
  # command-line string, so a 2-recipe wave opened a row naming a SINGLE slug and the batch under-recorded
  # itself with nothing complaining. Caught by the wave-1 audit on 2026-08-15, not by a test - which is
  # why this exists. It runs the real ledger against a temp file, because the bug IS invocation behaviour
  # and no pure function can reproduce it.
  $bl = Join-Path $here 'batch-ledger.ps1'
  if (Test-Path $bl) {
    $lt = Join-Path $env:TEMP ('huntrun-ledger-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
    try {
      & powershell -NoProfile -ExecutionPolicy Bypass -File $bl -Start -Batch 'probe-file' -Slugs @('a', 'b') -LedgerPath $lt | Out-Null
      & $bl -Start -Batch 'probe-inproc' -Slugs @('a', 'b') -LedgerPath $lt | Out-Null
      $lrows = @(([IO.File]::ReadAllText($lt, [Text.Encoding]::UTF8) | ConvertFrom-Json))
      $viaFile   = @($lrows | Where-Object { [string]$_.batch -eq 'probe-file' })[0]
      $viaInProc = @($lrows | Where-Object { [string]$_.batch -eq 'probe-inproc' })[0]
      T 'MUST FIRE  `powershell -File` still loses array slugs (the bug this guards against)' `
        (@($viaFile.slugs).Count -eq 1) ("recorded " + @($viaFile.slugs).Count)
      T 'CLEAN TWIN the in-process call WaveClose uses records every slug' `
        (@($viaInProc.slugs).Count -eq 2) ("recorded " + @($viaInProc.slugs).Count)
    } finally { if (Test-Path $lt) { Remove-Item $lt -Force -ErrorAction SilentlyContinue } }
  }

  # ---- FIXTURE 7. THE LANE LOG. It records the SHAPE of the work, which every other artifact throws away.
  # Founding bug, 2026-08-15: an orchestrator built from SKILL.md alone made pricing a per-recipe stage
  # instead of the singleton cross-recipe queue drainer section 2.4 specifies, and nothing in the run dir
  # could tell afterwards. audit-lane-shape.ps1 judges this file; these cases guard the WRITE side.
  T 'MUST FIRE  a typo lane name is not a lane (it would file pricing where no audit looks)' `
    (@($script:LANES) -notcontains 'pricer') 'accepted "pricer"'
  T 'CLEAN TWIN the real lane names are lanes' `
    ((@($script:LANES) -contains 'price') -and (@($script:LANES) -contains 'map')) 'missing a lane'

  # The `powershell -File` marshalling shape, frozen: -Items 'a,b,c' arrives as ONE string. If it were
  # stored as one item, an 8-invocation run would look like 8 batches of 1 term whatever it really did,
  # and the audit would fire on correct runs and pass on broken ones. Both call shapes must agree.
  $viaString = @(Split-LaneItems @('saffron,achiote paste, ras el hanout'))
  $viaArray  = @(Split-LaneItems @('saffron', 'achiote paste', 'ras el hanout'))
  T 'MUST FIRE  a comma-joined -Items string splits into its terms, not one item' ($viaString.Count -eq 3) $viaString.Count
  T '   and it trims, so " ras el hanout" is not a different term' (@($viaString) -contains 'ras el hanout') (@($viaString) -join '|')
  T 'CLEAN TWIN an in-process array gives the identical rows' `
    ((@($viaArray) -join '|') -eq (@($viaString) -join '|')) ((@($viaArray) -join '|') + ' vs ' + (@($viaString) -join '|'))
  T 'empty and whitespace items are dropped, never counted as work' ((@(Split-LaneItems @('a', '', '  ', 'b'))).Count -eq 2) (@(Split-LaneItems @('a', '', '  ', 'b'))).Count

  $lt2 = Join-Path $env:TEMP ('huntrun-lane-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.jsonl')
  try {
    Add-LaneLine -Path $lt2 -Line (New-LaneLine -LaneName 'price' -Label 'batch 1' -ItemList @('saffron,achiote paste') -By 'orchestrator' -Detail '' -At (Get-Stamp))
    Add-LaneLine -Path $lt2 -Line (New-LaneLine -LaneName 'map' -Label 'micro-batch 1' -ItemList @('a', 'b', 'c', 'd', 'e') -By 'orchestrator' -Detail '' -At (Get-Stamp))
    $rawLines = @([IO.File]::ReadAllLines($lt2, [Text.Encoding]::UTF8) | Where-Object { $_.Trim() })
    # ONE invocation is ONE line. A pretty-printed writer spans lines, and then a line-at-a-time reader
    # counts a single 10-term batch as ten invocations - the audit's headline number, inverted.
    T 'MUST FIRE  one invocation writes exactly one line' ($rawLines.Count -eq 2) $rawLines.Count
    $lg = @(Read-LaneLog $lt2)
    T 'the lane log round-trips'                    (@($lg).Count -eq 2 -and [string]$lg[0].lane -eq 'price') 'lost lines'
    T 'the item list survives with its count'       ([int]$lg[0].count -eq 2 -and @($lg[0].items) -contains 'achiote paste') ([int]$lg[0].count)
    T 'MUST FIRE  a 5-item list does not collapse'  (@($lg[1].items).Count -eq 5) (@($lg[1].items).Count)
    # append-only: the second write must not disturb the first. A log that can be rewritten certifies nothing.
    T 'MUST FIRE  appending does not rewrite the earlier line' ([string]$lg[0].label -eq 'batch 1') ([string]$lg[0].label)
    T 'a missing lane log reads as empty, not as an error' ((@(Read-LaneLog (Join-Path $env:TEMP 'no-such-lane-log.jsonl'))).Count -eq 0) 'threw'
  } finally { if (Test-Path $lt2) { Remove-Item $lt2 -Force -ErrorAction SilentlyContinue } }

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

# ---- -Lane ----------------------------------------------------------------------------------------
# Record ONE agent invocation. Call it as the invocation is dispatched, once per agent, with the items
# that invocation actually took: terms for `price`, slugs for `map` / `extract` / `write` / `qa`.
# ---- -LaneSummary ---------------------------------------------------------------------------------
# The cost breakdown this estate has never actually seen. v2.1 section 5.2 asked for usage.jsonl written
# at the END of a run; no run has ever reached its final phase, so the number was never produced. This
# reads the append-only lane log instead, so the answer survives any halt.
if ($runLaneSummary) {
  $lp = Join-Path $RunDir 'lane-log.jsonl'
  if (-not (Test-Path $lp)) { Write-Output ("hunt-run: no lane log at {0}" -f $lp); exit 1 }
  $rows = @()
  foreach ($l in (Get-Content $lp -Encoding utf8)) {
    if (-not $l -or -not $l.Trim()) { continue }
    try { $rows += ($l | ConvertFrom-Json) } catch { }
  }
  if (-not $rows.Count) { Write-Output 'hunt-run lane summary: lane log is empty'; exit 0 }

  # DURATION comes from pairing start/end lines on the same lane+label. The orchestrator cannot time
  # its own calls (Date.now() throws in that sandbox), so each agent stamps both ends itself. A stage
  # with no end line is either still running or died - counted as unfinished, never as instant.
  $starts = @{}
  $durations = @{}
  foreach ($r in ($rows | Sort-Object at)) {
    $ev = if ($r.PSObject.Properties.Name -contains 'event') { [string]$r.event } else { '' }
    if (-not $ev) { continue }
    $key = ([string]$r.lane) + '|' + ([string]$r.label)
    if ($ev -eq 'start') { $starts[$key] = [datetime]$r.at; continue }
    if ($ev -eq 'end' -and $starts.ContainsKey($key)) {
      $sec = ([datetime]$r.at - $starts[$key]).TotalSeconds
      if ($sec -ge 0) {
        if (-not $durations.ContainsKey([string]$r.lane)) { $durations[[string]$r.lane] = @() }
        $durations[[string]$r.lane] += $sec
      }
      $starts.Remove($key)
    }
  }

  $agg = @{}
  foreach ($r in $rows) {
    $ln = [string]$r.lane
    # only count a call ONCE - an end line is the same invocation as its start, not a second one
    $ev = if ($r.PSObject.Properties.Name -contains 'event') { [string]$r.event } else { '' }
    if ($ev -eq 'end') { continue }
    if (-not $agg.ContainsKey($ln)) { $agg[$ln] = [pscustomobject]@{ lane=$ln; calls=0; items=0; in=0; out=0; measured=0 } }
    $a = $agg[$ln]; $a.calls++; $a.items += [int]$r.count
    $ri = if ($r.PSObject.Properties.Name -contains 'in') { [int]$r.in } else { -1 }
    $ro = if ($r.PSObject.Properties.Name -contains 'out') { [int]$r.out } else { -1 }
    if ($ri -ge 0 -or $ro -ge 0) { $a.measured++; if ($ri -gt 0) { $a.in += $ri }; if ($ro -gt 0) { $a.out += $ro } }
  }
  $tot = ($agg.Values | Measure-Object -Property in -Sum).Sum + ($agg.Values | Measure-Object -Property out -Sum).Sum
  if ($runJson) {
    ([pscustomobject]@{ run=(Split-Path $RunDir -Leaf); total_tokens=$tot; lanes=@($agg.Values | Sort-Object { -($_.in + $_.out) }) } | ConvertTo-Json -Depth 5)
    exit 0
  }
  Write-Output ("hunt-run lane summary: {0}" -f (Split-Path $RunDir -Leaf))
  Write-Output ("  {0,-9} {1,6} {2,7} {3,12} {4,12} {5,12} {6,7} {7,9} {8,9}" -f 'lane','calls','items','input','output','total','share','mean_sec','total_min')
  foreach ($a in ($agg.Values | Sort-Object { -($_.in + $_.out) })) {
    $lt = $a.in + $a.out
    $share = if ($tot -gt 0) { '{0:N1}%' -f (100.0 * $lt / $tot) } else { '-' }
    $note = if ($a.measured -lt $a.calls) { (' [{0}/{1} tok]' -f $a.measured, $a.calls) } else { '' }
    $d = @($durations[$a.lane])
    $mean = if ($d.Count) { '{0:N0}' -f (($d | Measure-Object -Average).Average) } else { '-' }
    $tmin = if ($d.Count) { '{0:N1}' -f ((($d | Measure-Object -Sum).Sum) / 60.0) } else { '-' }
    Write-Output ("  {0,-9} {1,6} {2,7} {3,12:N0} {4,12:N0} {5,12:N0} {6,7} {7,9} {8,9}{9}" -f $a.lane,$a.calls,$a.items,$a.in,$a.out,$lt,$share,$mean,$tmin,$note)
  }
  $unfinished = @($starts.Keys)
  if ($unfinished.Count -gt 0) {
    Write-Output ("  {0} invocation(s) logged a start with no end - still running, or died: {1}" -f $unfinished.Count, (($unfinished | Select-Object -First 4) -join ', '))
  }
  Write-Output ("  {0,-9} {1,6} {2,7} {3,12} {4,12} {5,12:N0}" -f 'TOTAL',($rows.Count),(($agg.Values|Measure-Object -Property items -Sum).Sum),'','',$tot)
  $unmeasured = @($rows | Where-Object { -not ($_.PSObject.Properties.Name -contains 'in') -or [int]$_.in -lt 0 }).Count
  if ($unmeasured -gt 0) {
    Write-Output ("  NOTE {0} of {1} invocations carry no token figures - treat every number above as a LOWER BOUND." -f $unmeasured, $rows.Count)
  }
  Write-GuardComplete -Name 'hunt-run' -Summary ("lane-summary lanes={0} tokens={1}" -f $agg.Count, $tot)
  exit 0
}

if ($runLane) {
  if (-not $LaneName) { Write-Output ("hunt-run: -Lane needs -LaneName. One of: {0}" -f (@($script:LANES) -join ', ')); exit 1 }
  $ln = $LaneName.ToLower()
  # An unknown lane name is REFUSED rather than logged. A typo'd lane ('pricer' for 'price') would file
  # every pricer invocation under a lane no audit knows to look at, which reads afterwards as a run that
  # never priced anything - a silent pass, the exact shape this log exists to prevent.
  if (@($script:LANES) -notcontains $ln) {
    Write-Output ("hunt-run: '{0}' is not a lane. One of: {1}" -f $LaneName, (@($script:LANES) -join ', ')); exit 1
  }
  if (-not (Test-Path $RunDir)) { Write-Output ("hunt-run: no such run dir '{0}'" -f $RunDir); exit 1 }
  $line = New-LaneLine -LaneName $ln -Label $Label -ItemList $Items -By $By -Detail $Detail -At (Get-Stamp) -In $InputTokens -Out $OutputTokens -Event $Event
  Add-LaneLine -Path (Join-Path $RunDir 'lane-log.jsonl') -Line $line
  Write-Output ("hunt-run lane: {0}  {1} item(s){2}" -f $ln, $line.count, $(if ($Label) { "   ($Label)" } else { '' }))
  if ($line.count -eq 0) {
    Write-Output '  NOTE no items recorded. An invocation with no item list cannot be audited for batch shape.'
  }
  Write-GuardComplete -Name 'hunt-run' -Summary ("lane {0} n={1}" -f $ln, $line.count); exit 0
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
  if (@($script:REJECTED_STATES) -contains $To) { $e.reject_reason = $Detail }
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
    if (@($script:REJECTED_STATES) -contains $d.state) { $e.reject_reason = $detail }
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
  # THE AUDIT IS PRICED PER WAVE, NOT PER RECIPE. The 2026-08-15 shakedown spent 31% of its tokens on three
  # whole-wave audits over a 2-recipe wave. A short wave still pays that whole cost, so closing one should
  # be a visible choice. It WARNS and proceeds - drain means drain, and a gate here would strand recipes at
  # the end of a run, which is the one time a short wave is unavoidable.
  if ($runDrain -and $ready.Count -lt 3) {
    Write-Output ("hunt-run: NOTE a {0}-recipe wave pays the whole-wave audit alone (the auditor's cost is per WAVE)." -f $ready.Count)
    Write-Output  '           If these are not time-sensitive, hold them for the next run and close a fuller wave.'
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
    # IN-PROCESS, never `powershell -File`, because -Slugs is [string[]]: the -File path marshals the array
    # as ONE command-line string, so a 2-recipe wave opened a ledger row listing a single slug and the
    # batch under-recorded itself silently. Caught by the wave-1 audit on 2026-08-15. Same trap the
    # engine README documents for build-cards/publish, and the same one that made reanchor report
    # "1 spec" for a 2-slug wave. A ledger that does not know what is in the batch cannot verify it.
    & $bl -Start -Batch $batch -Slugs $slugs | Out-Null
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
$rejectedRows  = @(@($entries | Where-Object { @($script:REJECTED_STATES) -contains [string]$_.state }))
$parked    = @(@($entries | Where-Object { [string]$_.state -eq 'parked' }))
# HELD IS ITS OWN LINE, never folded into "in flight". A held recipe is a page that WAS live and is down
# now; burying it among recipes still being worked on is how a takedown gets forgotten.
$held      = @(@($entries | Where-Object { [string]$_.state -eq 'held' }))
$inflight  = @(@($entries | Where-Object { @('published', 'verified', 'parked', 'held') -notcontains [string]$_.state -and @($script:REJECTED_STATES) -notcontains [string]$_.state }))
$waves = @(Get-ChildItem (Join-Path $RunDir 'waves\wave-*.json') -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^wave-\d+\.json$' })

if ($runJson) {
  $o = [pscustomobject]@{
    run = (Split-Path $RunDir -Leaf); total = $entries.Count
    published = @($published | ForEach-Object { [string]$_.slug })
    held = @($held | ForEach-Object { [string]$_.slug })
    parked = @($parked | ForEach-Object { [pscustomobject]@{ slug = [string]$_.slug; waiting_on = @($_.parked_on) } })
    rejected = @($rejectedRows | ForEach-Object { [pscustomobject]@{ slug = [string]$_.slug; state = [string]$_.state; reason = [string]$_.reject_reason } })
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
if ($held.Count) { Write-Output ("  HELD       {0}   (WAS live, taken down - these are pages readers cannot see)" -f $held.Count) }
Write-Output ("  REJECTED   {0}" -f $rejectedRows.Count)
Write-Output ''
foreach ($s in @($byState.Keys | Sort-Object)) { Write-Output ("  {0,-22} {1}" -f $s, @($byState[$s]).Count) }
if ($parked.Count) {
  Write-Output ''
  Write-Output '  PARKED detail (this is the resume worklist):'
  foreach ($p in $parked) { Write-Output ("    {0,-34} waiting on: {1}" -f $p.slug, $(if (@($p.parked_on).Count) { @($p.parked_on) -join ', ' } else { '(unknown - run -Derive)' })) }
}
if ($held.Count) {
  Write-Output ''
  Write-Output '  HELD detail (live pages that are DOWN - each needs a decision):'
  foreach ($h in $held) {
    $last = @(@($h.history) | Select-Object -Last 1)
    Write-Output ("    {0,-34} {1}" -f $h.slug, $(if ($last.Count) { [string]$last[0].detail } else { '(no detail)' }))
  }
}
if ($rejectedRows.Count) {
  Write-Output ''
  Write-Output '  REJECTED detail:'
  foreach ($r in $rejectedRows) { Write-Output ("    {0,-34} {1}  {2}" -f $r.slug, $r.state, [string]$r.reject_reason) }
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
Write-GuardComplete -Name 'hunt-run' -Summary ("status n={0} published={1} parked={2} rejected={3}" -f $entries.Count, $published.Count, $parked.Count, $rejectedRows.Count)
exit 0
