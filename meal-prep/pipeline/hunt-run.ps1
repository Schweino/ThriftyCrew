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
#   .\hunt-run.ps1 -Init -RunDir <p> -Conditions '...' -Stop '...' -CalMin 500 -CalMax 650 -CarbMax 40 -ProteinMin 50 [-WaveSize 10]
#   .\hunt-run.ps1 -Advance -RunDir <p> -Slug <s> -To selected -By dedup-selector [-Detail '...']
#   .\hunt-run.ps1 -Advance -RunDir <p> -Slug <s> -To pricing -By mapper -Terms 'saffron','achiote paste' -OptionalTerms 'cilantro'
#     ^ EACH term its own quoted string. -Terms 'saffron,achiote paste' is ONE element to PowerShell and is REFUSED.
#   .\hunt-run.ps1 -Derive -RunDir <p> [-Slug <s>]
#   .\hunt-run.ps1 -Lane -RunDir <p> -LaneName price -Label 'pricer batch 1' -Items 'saffron,achiote paste'
#   .\hunt-run.ps1 -WaveClose -RunDir <p> [-Drain] [-NoLedger]
#   .\hunt-run.ps1 -Status -RunDir <p> [-Json]
#   .\hunt-run.ps1 -SelfTest
param(
  [switch]$Init, [switch]$Advance, [switch]$Derive, [switch]$WaveClose, [switch]$Status, [switch]$SelfTest,
  [switch]$Revive, [string]$Reason = '',
  [switch]$Lane, [switch]$LaneSummary, [switch]$StageSummary, [switch]$RecipeSummary,
  [switch]$WaveSync, [int]$Wave = 0,
  [int]$InputTokens = -1, [int]$OutputTokens = -1,   # -1 = not reported (older lines, or a lane that cannot see usage)
  # C1 (added 2026-08-24, phase 6a). Analysing the phase-5 run's cost took transcript archaeology with
  # per-message-id dedup, and DispatchResult ALREADY carried all three of these - lane() just did not
  # stamp them. -1 keeps its meaning: "not reported", which is not 0.
  [int]$CacheRead = -1, [int]$CacheCreation = -1, [int]$Calls = -1,
  # F (2026-08-24, off the 6b run). API ROUND TRIPS, which is NOT $Calls. $Calls counts BILLED CLI
  # INVOCATIONS - a re-ask makes it 2 - and criterion 1 depends on that meaning. But cost is driven by
  # round trips: each one re-reads the entire conversation, so a 47-round-trip session billed ~500k
  # tokens while $Calls read 1, and diagnosing that needed transcript archaeology OUTSIDE the pipeline,
  # which is the very thing C1 was built to end. The CLI envelope has carried num_turns all along.
  [int]$ApiTurns = -1,
  # ...and the SUBAGENT-INCLUSIVE totals, summed off the CLI envelope's modelUsage map. The phase-5
  # mapper spawned a 21-turn Opus subagent that appeared in NO lane stamp - $1.64 of invisible spend -
  # because `usage` covers the main agent only. When these differ from the main-agent numbers beside
  # them, that difference IS the delegation.
  [int]$AllModelsIn = -1, [int]$AllModelsOut = -1, [string]$Models = '',
  [ValidateSet('', 'start', 'end')][string]$Event = '',   # pair start/end on the same lane+label to get duration
  [string]$RunDir = '', [string]$Slug = '', [string]$To = '', [string]$By = '', [string]$Detail = '',
  [string]$Title = '', [string]$SourceUrl = '', [string]$Protein = '',
  [string[]]$Terms = @(), [string[]]$OptionalTerms = @(),
  [string]$LaneName = '', [string]$Label = '', [string[]]$Items = @(),
  # T3 (2026-08-25). A start line the caller can BACKDATE, for the one shape that cannot emit its own
  # start before its work: the local extraction ladder learns which rung settled the page only after
  # the page is settled, so it wrote start and end back to back and -StageSummary ranked every local
  # extraction at ~0 s. `detail` carried the real duration as prose that no reader parses. Defaults to
  # Get-Stamp, so every other caller is byte-identical to what it was.
  [string]$At = '',
  [string]$Conditions = '', [string]$Stop = '', [int]$WaveSize = 10,
  # THE BAND IS A RUN PARAMETER (Brad's ruling 2026-08-24, before the 6b proving run). The calorie
  # window, the carb ceiling and the protein floor all change run to run, so -Init REFUSES to mint a
  # run dir until every one of them is STATED. -1 means "not stated" and is the only reason a default
  # is not offered: a band nobody typed is a band nobody agreed to, and it would be enforced silently
  # by two gates for the whole run. -ProteinMin 0 is how you say "no protein floor" out loud.
  [double]$CalMin = -1, [double]$CalMax = -1, [double]$CarbMax = -1, [double]$ProteinMin = -1,
  [string]$QueueScript = '', [switch]$Drain, [switch]$NoLedger, [switch]$Json
)
$ErrorActionPreference = 'Stop'

# CAPTURE EVERY SWITCH BEFORE DOT-SOURCING ANYTHING. A dot-sourced script runs its own param() block in
# THIS scope, so a lib declaring [switch]$SelfTest silently resets ours to $false - that PS 5.1 trap made
# migrate-prose-tokens' first -SelfTest run execute the LIVE path instead of its fixtures.
$runStageSummary = [bool]$StageSummary
$runRecipeSummary = [bool]$RecipeSummary
# -StageSummary rides the -LaneSummary reader: it is the same log, the same pairing, a different
# GROUPING. A second reader over the same file is a second place for the two to disagree.
$runLaneSummary = [bool]$LaneSummary -or $runStageSummary
$runSelfTest = [bool]$SelfTest; $runInit = [bool]$Init; $runAdvance = [bool]$Advance
$runDerive = [bool]$Derive; $runWaveClose = [bool]$WaveClose; $runStatus = [bool]$Status
$runRevive = [bool]$Revive
$runLane = [bool]$Lane; $runWaveSync = [bool]$WaveSync
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
  # Q2 (2026-08-26): `mapped` -> `priced` IS GONE, and its removal is the gate rather than a tidy-up.
  # The carriage union (Get-CarriageBlockingTerms, below) runs on ONE road only - the way into
  # `pricing`. While `mapped` -> `priced` existed, any caller could route around the union entirely by
  # naming the destination it wanted, and two of them did: the map lane's zero-absent branch and the
  # unhold road both advanced straight to `priced` whenever the MAPPER reported no absent terms. That
  # is the union's founding case exactly - doubanjiang, rice-cakes and ground-sumac all mapped to real
  # commodity ids, so the mapper reported nothing absent, so nothing was priced and the recipe sailed
  # to a paid page. The 2026-08-22 union closed that hole for recipes that transit `pricing`; this
  # closes it for the ones that never did.
  #
  # A GATE WITH A DOOR BESIDE IT IS NOT A GATE, which is why this is fixed HERE and not only at the
  # two call sites. Both were repaired the same day, but a third caller written next year would have
  # found the same door open and nothing would have said no. Now the state machine says no: a recipe
  # reaches `priced` through `pricing` (or through `parked`, which is itself only reachable from
  # `pricing`), and there is no longer any route to a paid page that the union has not read.
  'mapped'     = @('pricing', 'rejected-not-carried', 'rejected-macros')
  'pricing'    = @('priced', 'parked', 'rejected-not-carried')
  'parked'     = @('pricing', 'priced', 'parked', 'rejected-not-carried')
  # `priced` -> `rejected-macros` added 2026-08-24 (v3 D8). The band gate MOVED to before the
  # writer: build-intake-skeleton.ps1 carries macros_per_serving from parse-compute, so an
  # out-of-band recipe is retired at skeleton build, while the recipe still sits at `priced`.
  # Until this edit the only exit from `priced` was spec-built, so the daemon had to walk the
  # recipe forward through spec-built -> written just to reach a rejection state - three
  # advances that each claim work nobody did, on a recipe no writer was ever paid for. Same
  # reasoning as the 2026-08-16 addition above: a verdict a state machine cannot express is a
  # verdict that gets faked or lost.
  # `priced` -> `rejected-qa` added 2026-08-24 (v3 D8), and it was ALREADY BEING FAKED before
  # this edit. Two ordered routes retire a recipe from `priced` on the writer's account: an
  # explicit writer rejection, and a locked-field drift the writer would not correct after its
  # one re-ask. Both advanced `priced -> rejected-qa` and both were REFUSED here, so the recipe
  # sat at `priced` on disk while the orchestrator counted it rejected. Caught by the daemon's
  # real-state-machine fixture; every injected fixture accepted it, which is the same blind spot
  # that hid the band route in phase 3. The writer's failure is a QA-class verdict on a recipe
  # nobody could write, and that is a verdict this machine should be able to express.
  'priced'     = @('spec-built', 'rejected-macros', 'rejected-qa')
  'spec-built' = @('written', 'spec-built', 'rejected-qa')
  # the QA repair routes. A source-QA failure is owner-routed, so a genuine transcription defect really
  # does send the recipe back to extraction; what stays refused is skipping FORWARD past qa-passed.
  'written'    = @('qa-passed', 'rejected-qa', 'written', 'spec-built', 'mapped', 'extracted')
  # `qa-passed` -> `rejected-qa` added 2026-08-28, and it is the THIRD time this same gap has been
  # closed - `priced` got it on 2026-08-24 and `written` has carried it longer still. The exits from
  # qa-passed were `waved` and nothing else, so a recipe that PASSED qa and was then found defective
  # had nowhere to go: the daemon's qa lane tried the honest advance, hunt-run refused it, and
  # blackened-chicken-with-mango-salsa sat at qa-passed with its own run record saying
  #   "the state machine refused qa-passed -> rejected-qa, so this rejected is NOT on disk"
  # A recipe stuck in a state it cannot leave is the failure mode; the alternative on offer was to
  # walk it forward to `waved` just to reach a rejection, which claims a wave nobody formed. Same
  # reasoning as the two additions above, in this file's own words: a verdict a state machine cannot
  # express is a verdict that gets faked or lost.
  'qa-passed'  = @('waved', 'rejected-qa')
  # an audit NO-GO trims a recipe back out of the wave, to repair or to rejection. It never publishes.
  'waved'      = @('published', 'rejected-audit', 'qa-passed', 'written')
  # `held` is a LIVE page deliberately taken down: a serveability rollback (wave-publish E7), or any manual
  # takedown. It exists because on 2026-08-15 two recipes were set back to draft in Ghost by hand while
  # their state files still read `published`, so the run record claimed live pages that were not live. A
  # takedown with no state is indistinguishable from a publish that worked.
  # held -> verified is REFUSED on purpose: a held recipe must go back through `published` (which means
  # actually re-publishing it) before anyone can verify it. Verifying a drafted page is the exact lie this
  # state exists to prevent.
  # rejected-audit -> qa-passed EXISTS FOR -Revive AND FOR NOTHING ELSE (2026-08-28). A NO-GO used
  # to be terminal full stop, and on wave 11 that cost a recipe with ZERO open blockers of its own:
  # both survivors were shared-data - a gate red over three OTHER recipes' specs, and a board-wide
  # cheddar price - and both were closed hours later by other work. plan_trim no longer spends a
  # recipe's repair budget on somebody else's defect, but that fix is not retroactive, and a recipe
  # already sitting in a terminal state needed a door.
  #
  # THE EVIDENCE GATE IS THE COMMAND, NOT THIS TABLE. -Revive refuses unless the wave's own audit
  # shows at least one OPEN blocker and not one of them recipe-local. This table stays the single
  # honest record of which moves the machine allows; hiding the edge from it and writing the state
  # file behind its back would be the worse lie, and is the exact thing this file's own notes warn
  # about ("a verdict a state machine cannot express is a verdict that gets faked or lost").
  'rejected-audit' = @('qa-passed')
  'published'  = @('verified', 'held')
  'held'       = @('published')
  'verified'   = @()
}
# A REJECTED STATE IS TERMINAL BY DEFAULT, NOT BY FORCE (2026-08-28). This loop used to assign @()
# unconditionally, which silently overwrote any edge the table above declared - the literal read as
# law and the loop quietly repealed it, which is worse than either rule alone. It now fills in the
# terminal default only where the table states nothing, so `rejected-audit -> qa-passed` above
# survives as the one declared, commented exception and every other rejected state stays terminal.
foreach ($r in $script:REJECTED_STATES) { if (-not $script:NEXT.ContainsKey($r)) { $script:NEXT[$r] = @() } }
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

# Every slug named by a wave manifest that has not published yet. A recipe listed here is SPOKEN FOR:
# some wave already carries it, and a second wave claiming it double-books the most expensive stage in
# the estate.
function Get-ClaimedSlugs {
  param([string]$RunDir)
  $claimed = @{}
  foreach ($f in @(Get-ChildItem (Join-Path $RunDir 'waves\wave-*.json') -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -match '^wave-(\d+)\.json$' })) {
    $doc = Read-Json $f.FullName
    if (-not $doc) { continue }
    if ([string]$doc.published_at) { continue }   # a closed wave releases nothing; it already shipped
    foreach ($s in @($doc.slugs)) { if ($s) { $claimed[[string]$s] = [int]$doc.wave } }
  }
  return $claimed
}

# ---------------------------------------------------------------------------------------------------
# THE COMPOSITE TERM GUARD.
#
# FOUNDING BUG (2026-08-16, run hunt-2026-08-15-lowcarb-100). PowerShell binds `-Terms 'a,b'` to a
# [string[]] of ONE element whose value is the literal string "a,b". It is not an error and it is not
# visible: -Advance wrote that composite straight into the recipe's state file as a single term row.
# ingredient-queue.ps1 is keyed by INDIVIDUAL TERM, so "green bell pepper,shaved beef steak" can never
# match a queue entry; Get-DerivedPricingState above scores an unknown term PENDING (section 2.2: an
# ingredient nobody answered for must not ship), so -Derive parked the recipe on every pass, forever,
# with no error anywhere. philly-cheesesteak-stuffed-peppers sat in `parked` while BOTH of its blocking
# ingredients were already recorded CARRIED - publishable and invisible. thai-coconut-curry-pork-shoulder
# had three terms joined the same way. A recipe with exactly ONE term is unaffected, which is why this
# survived a whole run undetected.
#
# REFUSED, NOT AUTO-SPLIT. A term that legitimately contains a comma is not a thing this estate has, and
# silently rewriting a caller's argument hides the caller's bug - the same call the -Lane branch already
# makes when it refuses an unknown -LaneName instead of logging it.
function Find-CompositeTerms {
  param($Values)
  return @(@($Values) | Where-Object { $_ } | ForEach-Object { [string]$_ } | Where-Object { $_.Contains(',') })
}

function Get-CompositeTermMessage {
  param([string]$ParamName, [string]$Offender)
  $parts = @(([string]$Offender -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $fixed = (@($parts | ForEach-Object { "'" + $_ + "'" }) -join ',')
  return ("hunt-run: term '{0}' contains a comma. Pass each term as its own quoted string: -{1} {2} - PowerShell binds -{1} 'a,b' to ONE element, and a composite term can never match an ingredient-queue entry, so the recipe parks forever." -f $Offender, $ParamName, $fixed)}

# Only qa-passed recipes are eligible for a wave, FIFO by when they got there. Nothing else is a door.
#
# AND NOT ONE ALREADY CLAIMED BY AN OPEN WAVE. An audit NO-GO trims recipes back to `qa-passed` so they
# can be repaired - but the trimmed wave's manifest still lists them, because -WaveClose only ever mints
# a NEW wave and cannot rewrite an old one. So the very next close swept them straight into another wave
# while the first still claimed them. On 2026-08-16 that put 5 recipes in BOTH wave 2 and wave 3: 30
# manifest slots over 25 distinct recipes, with every wave paying a full whole-wave audit. It also made
# wave 2 permanently unpublishable, because wave-publish P3 demands every manifest slug be in state
# `waved` and the trim had moved them out. Three consecutive NO-GOs, none of them about a recipe.
function Select-WaveSlugs {
  param($Entries, [int]$Size, [hashtable]$Claimed = @{})
  $ready = @(@($Entries) |
    Where-Object { [string]$_.state -eq 'qa-passed' -and -not $Claimed.ContainsKey([string]$_.slug) } |
    Sort-Object { [string]$_.updated })
  if ($Size -gt 0 -and $ready.Count -gt $Size) { $ready = @($ready[0..($Size - 1)]) }
  return @($ready)
}

# Rewrite a wave manifest to the slugs it ACTUALLY still holds. The counterpart to a trim: the trim moves
# recipes out of `waved` via the state machine, which has no idea it was part of a wave, so without this
# the manifest keeps asserting a batch that no longer exists. Returns the dropped slugs.
function Sync-WaveManifest {
  param([string]$RunDir, [int]$Wave)
  $path = Join-Path $RunDir ("waves\wave-{0}.json" -f $Wave)
  if (-not (Test-Path $path)) { throw "no such wave manifest: $path" }
  $doc = Read-Json $path
  if ([string]$doc.published_at) { throw "wave $Wave already published - its manifest is the shipping record and is not rewritten" }
  $entries = @{}
  foreach ($e in @(Read-Entries $RunDir)) { $entries[[string]$e.slug] = $e }
  $keep = @(); $dropped = @()
  foreach ($s in @($doc.slugs)) {
    $e = $entries[[string]$s]
    if ($e -and [string]$e.state -eq 'waved' -and [int]$e.wave -eq $Wave) { $keep += [string]$s }
    else { $dropped += [string]$s }
  }
  $doc.slugs = @($keep)
  $doc.recipes = @(@($doc.recipes) | Where-Object { $keep -contains [string]$_.slug })
  $doc | Add-Member -NotePropertyName reconciled -NotePropertyValue (Get-Stamp) -Force
  Write-JsonAtomic -Path $path -Obj $doc
  return @($dropped)
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
# ---------------------------------------------------------------------------------------------------
# NON-PURCHASABLE TERMS. Two nets, in this order, and the FIRST one is the real fix.
#
# Net 1 is the mapper's OWN ruling, which was already on the row and was being thrown away. Every
# mapped line carries `decision` (map-preresolve's enum: mapped | mapped-null | mapped-optional |
# not-purchased | optional-note) and `optional`. `optional-note` means, in map-preresolve.ps1's own
# words, "water, a garnish, a sub-recipe - nothing the shopper buys". Until 2026-08-26 the loop below
# read NEITHER field: it walked every ingredient, blocked on carriage alone, and the -Advance union
# then stamped optional=$false over the mapper's optional=$true. So a line the mapper had explicitly
# ruled un-buyable came back as a BLOCKING term. Measured on run hunt-2026-08-26-ten: 'Pan Drippings'
# carried decision='optional-note' and optional=$true and the note "already bought as the vegetable
# oil line", and it parked chicken-fried-steak forever.
#
# Net 2 is grocery\non-purchasable-terms.json, for the case where the mapper mislabels one of these as
# a real purchase. It is a second net and never the first: a list of names cannot know that THIS
# recipe's "drippings" is a byproduct, and the ruling on the row can.
#
# NOTHING IS SILENTLY DROPPED. A term caught by either net is still written to the state file by the
# -Advance union, marked optional - so it reads on the recipe, it just stops the recipe waiting for a
# price nobody can ever quote.
# ---------------------------------------------------------------------------------------------------
$script:NOT_PURCHASED_DECISIONS = @('optional-note', 'not-purchased', 'mapped-optional')

function Get-NormTerm {
  param([string]$Term)
  return ([regex]::Replace(([string]$Term).Trim(), '\s+', ' ')).ToLowerInvariant()
}

function Get-NonPurchasableSet {
  param([string]$RepoRoot)
  $set = @{}
  $p = Join-Path $RepoRoot 'grocery\non-purchasable-terms.json'
  if (-not (Test-Path $p)) { return $set }
  try { $doc = Get-Content $p -Raw | ConvertFrom-Json } catch { return $set }
  foreach ($t in @($doc.terms)) {
    $k = Get-NormTerm $t
    if ($k) { $set[$k] = $true }
  }
  return $set
}

# ---------------------------------------------------------------------------------------------------
# THE COMPOSITE SPLIT, and note it is a SPLIT here while -Terms one screen down is a REFUSAL. That
# asymmetry is deliberate and it is about WHOSE BUG IT IS. A comma inside a caller-supplied -Terms
# element is the CALLER binding -Terms 'a,b' wrong, and rewriting a caller's argument hides the
# caller's bug - so that stays refused. A comma inside a DERIVED item is the recipe page's own
# ingredient line ("Garlic Powder, Cumin, and Chili Powder" - one source line holding three spices),
# which no caller can fix and which the queue can never key. Refusing it would only park the recipe a
# different way. Brad's ruling, 2026-08-26.
#
# SPLIT ON COMMAS ONLY, AND ONLY WHEN THE LINE HAS NO BID. Both guards protect the same thing: a real
# commodity whose NAME contains a conjunction. 'Half and Half' is an item in this estate with
# bid='half-and-half'; splitting on ' and ' would shred it into two foods that do not exist. A comma
# and no bid is the narrow shape that is always an unresolved multi-ingredient line. The leading
# 'and '/'or ' of a final Oxford-comma part is stripped, because "and Chili Powder" is not a food.
# ---------------------------------------------------------------------------------------------------
function Split-CompositeItem {
  param([string]$Item, [string]$Bid)
  $s = [string]$Item
  if ($Bid) { return @($s) }
  if (-not $s.Contains(',')) { return @($s) }
  $parts = @()
  foreach ($p in ($s -split ',')) {
    $q = ([string]$p).Trim()
    $q = [regex]::Replace($q, '^(and|or)\s+', '', 'IgnoreCase')
    $q = $q.Trim()
    if ($q) { $parts += $q }
  }
  if (-not $parts.Count) { return @($s) }
  return @($parts)
}

# ---------------------------------------------------------------------------------------------------
# CARRIAGE-DERIVED BLOCKING TERMS. The mapper reports "absent terms" - ingredients it could not map to a
# commodity id - and until 2026-08-22 that list WAS the pricing worklist. It is not sufficient, because
# an ingredient can map perfectly and still be a food no Omaha store stocks: doubanjiang, rice-cakes and
# ground-sumac all mapped to real ids, so the mapper reported nothing, so nothing was ever priced, so
# `-To pricing` with an empty -Terms derived `priced` instantly and the recipe sailed to a paid page.
#
# So hunt-run derives the list ITSELF from the mapped artifact's bids, and unions it with whatever the
# mapper reported. The mapper can now only ADD to the worklist, never shrink it - the difference between
# a gate and a request. FAIL-CLOSED: an unreadable mapped file yields no derived terms and says so, and
# an ingredient whose carriage is UNKNOWN parks the recipe rather than pricing it.
#
# WHAT THIS RETURNS AND WHY IT IS TWO LISTS (2026-08-26). `terms` are the blocking ones. `skipped` are
# the rows the two nets above took out, WITH the reason - they still reach the state file as optional
# rows, and a caller that cannot see why a term stopped blocking cannot review this gate. Returning one
# list and logging the rest was the old shape, and it is how a discarded mapper ruling stayed invisible.
# ---------------------------------------------------------------------------------------------------
function Get-CarriageBlockingTerms {
  param([string]$RunDir, [string]$Slug, [string]$RepoRoot)
  $out = @(); $skipped = @()
  $mf = Join-Path $RunDir ("mapped\{0}.json" -f $Slug)
  if (-not (Test-Path $mf)) { return @{ terms = @(); skipped = @(); read = $false; why = "no mapped\$Slug.json" } }
  try { $doc = Get-Content $mf -Raw | ConvertFrom-Json } catch { return @{ terms = @(); skipped = @(); read = $false; why = "mapped\$Slug.json unparseable" } }
  $carrLib = Join-Path $RepoRoot 'lib\carriage-lib.ps1'
  if (-not (Test-Path $carrLib)) { return @{ terms = @(); skipped = @(); read = $false; why = 'carriage-lib.ps1 missing' } }
  . $carrLib
  $feedFile = Join-Path $RepoRoot 'grocery\out\smp-feed.json'
  $fc = @{}
  if (Test-Path $feedFile) { try { $fc = Get-FeedCarriedSet ((Get-Content $feedFile -Raw | ConvertFrom-Json).ingredients) } catch { $fc = @{} } }
  $led = Import-CarriageLedger (Join-Path $RepoRoot 'grocery\carriage.json')
  $stop = Get-NonPurchasableSet -RepoRoot $RepoRoot
  foreach ($ing in @($doc.ingredients)) {
    $bid  = if ($ing.PSObject.Properties.Name -contains 'bid') { [string]$ing.bid } else { $null }
    $item = [string]$ing.item
    if (-not $item) { continue }
    # NET 1 - the ruling that was already on the row. Read BEFORE carriage, because a line nobody buys
    # has no carriage question to answer.
    $dec = if ($ing.PSObject.Properties.Name -contains 'decision') { [string]$ing.decision } else { '' }
    if ($script:NOT_PURCHASED_DECISIONS -contains $dec) {
      $skipped += [pscustomobject]@{ term = $item; why = ("the mapper ruled it '{0}' - nothing the shopper buys" -f $dec) }
      continue
    }
    if ($ing.PSObject.Properties.Name -contains 'optional' -and [bool]$ing.optional) {
      $skipped += [pscustomobject]@{ term = $item; why = 'the mapper marked the line optional' }
      continue
    }
    # THE SPLIT RUNS BEFORE THE CARRIAGE CHECK, so each real spice gets its own carriage answer rather
    # than one verdict for a string that is not a food.
    foreach ($part in @(Split-CompositeItem -Item $item -Bid $bid)) {
      # NET 2 - the stoplist, per PART.
      if ($stop.ContainsKey((Get-NormTerm $part))) {
        $skipped += [pscustomobject]@{ term = $part; why = 'listed in grocery\non-purchasable-terms.json' }
        continue
      }
      $c = Get-Carriage -Bid $bid -Item $part -FeedCarried $fc -Ledger $led
      if ($c.verdict -ne 'CARRIED') { $out += $part }
    }
  }
  return @{ terms = @($out | Sort-Object -Unique); skipped = @($skipped); read = $true; why = '' }
}
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
        [int]$In = -1, [int]$Out = -1, [string]$Event = '',
        [int]$CacheRead = -1, [int]$CacheCreation = -1, [int]$Calls = -1, [int]$ApiTurns = -1,
        [int]$AllIn = -1, [int]$AllOut = -1, [string]$Models = '')
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
    # C1. `in` above is the lane-tokens.ps1 total (input + cache read + cache write); these SPLIT it,
    # which is what makes a working-set problem tellable from an output problem without a transcript.
    # `calls` is turns - the first lever in the cost law (turns x working set, plus output at 5x).
    cache_read = $CacheRead; cache_creation = $CacheCreation; calls = $Calls
    # F. The ROUND TRIPS behind those tokens. `calls` is billed invocations; this is how many times the
    # agent went and looked something up, which is the number that explains the working set.
    api_turns = $ApiTurns
    # and the subagent-inclusive totals. all_in/all_out >= in/out whenever a dispatch delegated.
    all_in = $AllIn; all_out = $AllOut; models = $Models
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

  # ---- CARRIAGE UNION. The 2026-08-22 hole: an ingredient that MAPS FINE but no Omaha store stocks.
  # The mapper reports nothing (it mapped everything), so -Terms is empty, so the recipe derives `priced`
  # with no pricing work at all. hunt-run must find it from the mapped bids on its own.
  $tmpRun = Join-Path ([IO.Path]::GetTempPath()) ('hr-carr-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force (Join-Path $tmpRun 'mapped') | Out-Null
  try {
    @{ slug = 'fixture-dish'; ingredients = @(
        @{ item = 'Chicken Thighs'; bid = 'chicken-thighs' },
        @{ item = 'Doubanjiang';    bid = 'doubanjiang' },
        @{ item = 'Keto Bun';       bid = $null }) } | ConvertTo-Json -Depth 6 |
      Set-Content (Join-Path $tmpRun 'mapped\fixture-dish.json') -Encoding UTF8
    $cb = Get-CarriageBlockingTerms -RunDir $tmpRun -Slug 'fixture-dish' -RepoRoot $repo
    T 'carriage derives blocking terms from the mapped artifact' ($cb.read) $cb.why
    T 'MUST FIRE  a mapped-but-uncarried ingredient is derived as blocking' (@($cb.terms) -contains 'Doubanjiang') (@($cb.terms) -join ',')
    T 'CLEAN TWIN  a carried ingredient is NOT derived as blocking' (@($cb.terms) -notcontains 'Chicken Thighs') (@($cb.terms) -join ',')
    T 'a bid-less item proven carried by the ledger is not blocking' (@($cb.terms) -notcontains 'Keto Bun') (@($cb.terms) -join ',')
    $cbMissing = Get-CarriageBlockingTerms -RunDir $tmpRun -Slug 'no-such-slug' -RepoRoot $repo
    T 'MUST FIRE  an unreadable mapped file reports read=false rather than a silent empty pass' (-not $cbMissing.read) 'claimed a clean read'
  } finally { Remove-Item $tmpRun -Recurse -Force -ErrorAction SilentlyContinue }

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
  # THE THIRD TIME THIS GAP HAS BEEN CLOSED (2026-08-28). qa-passed's only exit was `waved`, so a
  # recipe that PASSED qa and was then found defective could not be rejected: the daemon's qa lane
  # made the honest advance, this file refused it, and blackened-chicken-with-mango-salsa sat at
  # qa-passed while its run record said "the state machine refused qa-passed -> rejected-qa, so this
  # rejected is NOT on disk". `priced` got this exit on 2026-08-24 and `written` earlier still.
  T 'MUST FIRE  a recipe that passed QA and then failed it can be REJECTED, not stranded' `
    (Test-LegalTransition 'qa-passed' 'rejected-qa') 'refused'
  T '   ...and the walk-forward it replaces stays refused: a rejection must not claim a wave' `
    (-not (Test-LegalTransition 'qa-passed' 'published')) 'allowed'
  T '   ...and rejected-qa is terminal from there, like every other rejection' `
    (-not (Test-LegalTransition 'rejected-qa' 'qa-passed')) 'allowed'
  T 'CLEAN TWIN an audit NO-GO may trim a recipe back out of its wave' (Test-LegalTransition 'waved' 'qa-passed') 'refused'
  T 'CLEAN TWIN a QA failure may route back to extraction for repair'  (Test-LegalTransition 'written' 'extracted') 'refused'

  # ---- FIXTURE 4b. A macro rejection has somewhere to go. On 2026-08-16 it did not: the mapper ruled
  # two recipes outside the run's calorie/carb window, and `extracted` offered only dupe and unreadable.
  # Both would have been false, so the mapper refused to advance them at all and they read as stuck.
  T 'MUST FIRE  a macro rejection is reachable from extracted'         (Test-LegalTransition 'extracted' 'rejected-macros') 'refused'
  T 'MUST FIRE  a macro rejection is reachable from mapped'            (Test-LegalTransition 'mapped' 'rejected-macros') 'refused'
  T 'MUST FIRE  a macro rejection is terminal like every other reject' (-not (Test-LegalTransition 'rejected-macros' 'mapped')) 'allowed'
  T 'CLEAN TWIN rejected-macros counts as a rejection, not as in-flight' ($script:REJECTED_STATES -contains 'rejected-macros') 'missing from REJECTED_STATES'

  # ---- FIXTURE 4b-ii. THE PRE-WRITE BAND GATE'S EXIT (v3 D8, 2026-08-24). The band gate moved to
  # before the writer, where the recipe is still `priced`. Until this edit `priced` offered only
  # spec-built, so the only way to record a macro rejection was to advance the recipe through
  # spec-built -> written first - two states asserting a spec was assembled and prose was written
  # for a recipe no writer ever saw. The daemon's band route now goes priced -> rejected-macros in
  # ONE advance, and the run record stops claiming work nobody did.
  T 'MUST FIRE  a macro rejection is reachable from priced (the pre-write band gate)' (Test-LegalTransition 'priced' 'rejected-macros') 'refused'
  T 'CLEAN TWIN the normal exit from priced still stands'                             (Test-LegalTransition 'priced' 'spec-built') 'refused'
  T 'MUST FIRE  priced still cannot skip the spec and go straight to written'         (-not (Test-LegalTransition 'priced' 'written')) 'allowed'

  # ---- FIXTURE 4b-iii. THE WRITER'S OWN FAILURE (v3 D8, 2026-08-24). A writer that rejects a
  # recipe outright, and a writer that drifts a LOCKED field twice, both retire it from `priced` -
  # and both were advancing to a state this graph refused, so the recipe stayed at `priced` on disk
  # while the orchestrator counted it rejected. The injected fixtures accepted it; the real machine
  # did not. Third instance of that blind spot, and the reason the daemon keeps real-machine twins.
  T 'MUST FIRE  a QA-class rejection is reachable from priced (a writer that will not conform)' (Test-LegalTransition 'priced' 'rejected-qa') 'refused'
  T 'MUST FIRE  and it is still terminal, like every other rejection'                        (-not (Test-LegalTransition 'rejected-qa' 'spec-built')) 'allowed'

  # ---- FIXTURE 4c. THE DOUBLE-BOOKED WAVE, frozen. A trim returns recipes to `qa-passed` so they can be
  # repaired, but -WaveClose only ever mints a NEW wave and cannot rewrite the old manifest, so the next
  # close swept the same recipes into a second wave while the first still claimed them. On 2026-08-16 that
  # put 5 recipes in BOTH wave 2 and wave 3 - 30 manifest slots over 25 recipes, each wave paying a full
  # whole-wave audit - and left wave 2 permanently unpublishable, because P3 demands every manifest slug
  # be `waved` and the trim had moved them out. Three NO-GOs, none of them about a recipe.
  $wRows = @(
    [pscustomobject]@{ slug = 'alpha'; state = 'qa-passed'; updated = '2026-08-16 01:00' }
    [pscustomobject]@{ slug = 'bravo'; state = 'qa-passed'; updated = '2026-08-16 02:00' }
  )
  # @(...) ON EVERY CALL. PowerShell unwraps a single-element array on return, so a one-recipe result
  # comes back as a bare PSCustomObject whose .Count is $null - the assertion then compares $null to 1
  # and fails while the value is right. Same family as the @(pipeline | ConvertFrom-Json) collapse.
  $noClaim = @(Select-WaveSlugs $wRows 10 @{})
  T 'CLEAN TWIN an unclaimed qa-passed recipe is eligible for a wave' ($noClaim.Count -eq 2) $noClaim.Count
  $withClaim = @(Select-WaveSlugs $wRows 10 @{ 'alpha' = 2 })
  T 'MUST FIRE  a recipe an open wave still claims is NOT swept into a second wave' `
    ($withClaim.Count -eq 1 -and ([string]($withClaim[0].slug)) -eq 'bravo') (@($withClaim | ForEach-Object { $_.slug }) -join ',')

  # Sync-WaveManifest drops exactly what the trim removed, and keeps what the wave still holds.
  $syncDir = Join-Path ([System.IO.Path]::GetTempPath()) ('hr-sync-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path (Join-Path $syncDir 'waves') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $syncDir 'state') -Force | Out-Null
  Write-JsonAtomic -Path (Join-Path $syncDir 'waves\wave-2.json') -Obj ([pscustomobject]@{
      wave = 2; run = 'r'; batch = 'r-w2'; created = 'x'; slugs = @('kept', 'trimmed')
      recipes = @([pscustomobject]@{ slug = 'kept' }, [pscustomobject]@{ slug = 'trimmed' })
    })
  Write-JsonAtomic -Path (Join-Path $syncDir 'state\kept.json')    -Obj ([pscustomobject]@{ slug = 'kept'; state = 'waved'; wave = 2; history = @() })
  Write-JsonAtomic -Path (Join-Path $syncDir 'state\trimmed.json') -Obj ([pscustomobject]@{ slug = 'trimmed'; state = 'qa-passed'; wave = 2; history = @() })
  $dropped = @(Sync-WaveManifest $syncDir 2)
  $after = Read-Json (Join-Path $syncDir 'waves\wave-2.json')
  T 'MUST FIRE  reconciling drops the slug the trim pulled out of the wave' `
    ($dropped.Count -eq 1 -and $dropped[0] -eq 'trimmed') ($dropped -join ',')
  T 'CLEAN TWIN reconciling keeps the slug still sitting in the wave' `
    (@($after.slugs).Count -eq 1 -and [string]@($after.slugs)[0] -eq 'kept') (@($after.slugs) -join ',')
  T 'CLEAN TWIN the recipes block is trimmed alongside the slug list' `
    (@($after.recipes).Count -eq 1) @($after.recipes).Count
  # A published manifest is the shipping record. Rewriting one would erase what actually went live.
  Write-JsonAtomic -Path (Join-Path $syncDir 'waves\wave-1.json') -Obj ([pscustomobject]@{
      wave = 1; run = 'r'; batch = 'r-w1'; created = 'x'; published_at = '2026-08-16'; slugs = @('shipped'); recipes = @()
    })
  $refused = $false
  try { Sync-WaveManifest $syncDir 1 | Out-Null } catch { $refused = $true }
  T 'MUST FIRE  a PUBLISHED wave manifest is never rewritten' $refused 'allowed'
  # ...and a published wave releases its slugs, so they are not claimed forever.
  $claims = Get-ClaimedSlugs $syncDir
  T 'CLEAN TWIN a published wave stops claiming its slugs' (-not $claims.ContainsKey('shipped')) 'still claimed'
  T 'MUST FIRE  an open wave still claims the slug it holds' ($claims.ContainsKey('kept')) 'not claimed'
  Remove-Item $syncDir -Recurse -Force -ErrorAction SilentlyContinue

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

  # ---- FIXTURE 7c. THE BAND IS A RUN PARAMETER AND -Init DEMANDS IT (2026-08-24, Brad's ruling). ---
  # Before this, the calorie window and carb ceiling were constants in TWO places (harvest.py's module
  # globals, hunt-daemon's DEFAULT_BAND) and there was NO protein floor anywhere in the estate - so a
  # run whose stated conditions said "50 g protein or more" was enforced by nothing, and no reader of
  # the run dir could tell afterwards which band the gates had actually applied. -Init now refuses to
  # mint a run dir until the band is typed, and writes it into run.json for the daemon to read back.
  # -ProteinMin 0 is how "no floor" is said out loud, which is not the same as never saying it.
  $bt = Join-Path $env:TEMP ('huntrun-band-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    # CHANGED 2026-08-24 evening (Brad: "drop the band in code - however, be prepared for me to give
    # a band during prompts"). These three used to assert that -Init REFUSED an unstated band. That
    # refusal existed because a CONSTRAINT nobody typed gets enforced silently by two gates for a whole
    # run - a real failure mode. The ABSENCE of a constraint has none: it cannot wrongly reject
    # anything. So an unstated edge is now UNBOUNDED, and what the refusal bought - a reader knowing
    # what the gates enforced - is kept in run.json and in the line -Init prints.
    $noBand = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Init -RunDir (Join-Path $bt 'r1') -Conditions 'fixture' -Stop 'fixture' 2>&1
    $noBandTxt = (@($noBand | ForEach-Object { [string]$_ }) -join ' ')
    $rj1 = $null
    if (Test-Path (Join-Path $bt 'r1\run.json')) { $rj1 = (Get-Content (Join-Path $bt 'r1\run.json') -Raw -Encoding utf8 | ConvertFrom-Json) }
    T 'MUST FIRE  an UNSTATED band mints the run dir with NO limits, and SAYS so rather than refusing' `
      (($noBandTxt -match 'band: NONE') -and $null -ne $rj1 -and $null -eq $rj1.band.calMin -and `
       $null -eq $rj1.band.calMax -and $null -eq $rj1.band.carbMax -and $null -eq $rj1.band.proteinMin) `
      $noBandTxt
    T '   and run.json records that NOTHING was stated, so a later reader is not left guessing' `
      ($null -ne $rj1 -and (@($rj1.band_stated)).Count -eq 0) `
      ($(if ($rj1) { 'stated=' + ((@($rj1.band_stated)) -join ',') } else { 'no run.json' }))

    $partial = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Init -RunDir (Join-Path $bt 'r2') -Conditions 'fixture' -Stop 'fixture' -CalMin 500 -CalMax 650 -CarbMax 40 2>&1
    $rj2 = $null
    if (Test-Path (Join-Path $bt 'r2\run.json')) { $rj2 = (Get-Content (Join-Path $bt 'r2\run.json') -Raw -Encoding utf8 | ConvertFrom-Json) }
    T 'MUST FIRE  a PARTIAL band is honoured - stated edges apply, the unstated protein floor is unbounded' `
      ($null -ne $rj2 -and [double]$rj2.band.calMin -eq 500 -and [double]$rj2.band.carbMax -eq 40 -and `
       $null -eq $rj2.band.proteinMin -and ((@($partial | ForEach-Object { [string]$_ }) -join ' ') -match 'protein any')) `
      ($partial -join ' ')

    $inverted = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Init -RunDir (Join-Path $bt 'r3') -Conditions 'fixture' -Stop 'fixture' -CalMin 700 -CalMax 500 -CarbMax 40 -ProteinMin 0 2>&1
    T 'MUST FIRE  a floor above its own ceiling is refused - it admits nothing and would source zero recipes silently' `
      ((@($inverted | ForEach-Object { [string]$_ }) -join ' ') -match 'above -CalMax') ($inverted -join ' ')

    $good = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Init -RunDir (Join-Path $bt 'r4') -Conditions 'fixture' -Stop 'fixture' -CalMin 500 -CalMax 650 -CarbMax 40 -ProteinMin 50 2>&1
    $rj = $null
    $rjp = Join-Path $bt 'r4\run.json'
    if (Test-Path $rjp) { $rj = (Get-Content $rjp -Raw -Encoding utf8 | ConvertFrom-Json) }
    T 'CLEAN TWIN a stated band mints the run dir and lands in run.json, so a report months later can say what the gates enforced' `
      ($null -ne $rj -and $null -ne $rj.band -and [double]$rj.band.calMin -eq 500 -and
       [double]$rj.band.calMax -eq 650 -and [double]$rj.band.carbMax -eq 40 -and
       [double]$rj.band.proteinMin -eq 50) `
      ($(if ($rj) { ($rj.band | ConvertTo-Json -Compress) } else { ($good -join ' ') }))

    $zero = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Init -RunDir (Join-Path $bt 'r5') -Conditions 'fixture' -Stop 'fixture' -CalMin 400 -CalMax 650 -CarbMax 35 -ProteinMin 0 2>&1
    $rj5 = $null
    $rjp5 = Join-Path $bt 'r5\run.json'
    if (Test-Path $rjp5) { $rj5 = (Get-Content $rjp5 -Raw -Encoding utf8 | ConvertFrom-Json) }
    T 'CLEAN TWIN -ProteinMin 0 records a NULL floor - "no floor", said out loud and readable afterwards' `
      ($null -ne $rj5 -and $null -eq $rj5.band.proteinMin) `
      ($(if ($rj5) { ($rj5.band | ConvertTo-Json -Compress) } else { ($zero -join ' ') }))
  } finally { Remove-Item $bt -Recurse -Force -ErrorAction SilentlyContinue }

  # ---- FIXTURE 7b. THE LANE SUMMARY READS BOTH WRITER CONVENTIONS (CORRECTED 2026-08-24). --------
  # The daemon writes start/end PAIRS with every token figure on the END line; the v2 orchestrator
  # wrote ONE event-less line per invocation with the tokens on it. The old aggregation skipped end
  # lines whole, so a summary over any daemon run reported zero tokens on every lane - measured on a
  # log holding a fully-stamped 245k-token dispatch ('lane-summary lanes=0 tokens='). Three lanes,
  # both conventions, and the C1 fields, because the phase-6b criteria are read off exactly this.
  $lt3 = Join-Path $env:TEMP ('huntrun-lsum-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    New-Item -ItemType Directory -Path $lt3 -Force | Out-Null
    $lg3 = Join-Path $lt3 'lane-log.jsonl'
    # convention 1: a daemon pair - tokens, turns, cache split and delegation all on the END line
    Add-LaneLine -Path $lg3 -Line (New-LaneLine -LaneName 'map' -Label 'map:2x' -ItemList @('a','b') -By 'mapper' -Detail '' -At '2026-08-24T10:00:00' -Event 'start')
    Add-LaneLine -Path $lg3 -Line (New-LaneLine -LaneName 'map' -Label 'map:2x' -ItemList @('a','b') -By 'mapper' -Detail 're-asked; ok' -At '2026-08-24T10:15:00' -Event 'end' -In 245806 -Out 76728 -CacheRead 159299 -CacheCreation 86495 -Calls 2 -ApiTurns 47 -AllIn 258197 -AllOut 76758)
    # convention 2: a v2-era single line, tokens on its only row
    Add-LaneLine -Path $lg3 -Line (New-LaneLine -LaneName 'qa' -Label 'qa:x' -ItemList @('x') -By 'qa' -Detail '' -At '2026-08-24T10:16:00' -In 1000 -Out 200)
    # and a local-ladder zero-token line, which is work done, not work unmeasured
    Add-LaneLine -Path $lg3 -Line (New-LaneLine -LaneName 'extract' -Label 'local rung 1' -ItemList @('y') -By 'local' -Detail '' -At '2026-08-24T10:17:00' -In 0 -Out 0)
    $sumOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -LaneSummary -RunDir $lt3 -Json 2>&1
    $sum = $null
    try { $sum = (@($sumOut | ForEach-Object { [string]$_ }) -join "`n") | ConvertFrom-Json } catch {}
    $mapRow = $null; $qaRow = $null
    if ($sum) { $mapRow = @($sum.lanes | Where-Object { $_.lane -eq 'map' })[0]; $qaRow = @($sum.lanes | Where-Object { $_.lane -eq 'qa' })[0] }
    T 'MUST FIRE  the summary reads the DAEMON pair convention - the end line''s tokens land on the lane, not zero' `
      ($null -ne $mapRow -and [long]$mapRow.in -eq 245806 -and [long]$mapRow.out -eq 76728) `
      ($(if ($mapRow) { 'in=' + $mapRow.in + ' out=' + $mapRow.out } else { ($sumOut -join ' ')[0..160] -join '' }))
    T 'MUST FIRE  ...and the C1 fields ride with it: turns, the cache split, the subagent-inclusive totals and the re-ask count' `
      ($null -ne $mapRow -and [long]$mapRow.turns -eq 2 -and [long]$mapRow.cache_read -eq 159299 -and
       [long]$mapRow.cache_creation -eq 86495 -and [long]$mapRow.all_out -eq 76758 -and [long]$mapRow.reasks -eq 1) `
      ($(if ($mapRow) { 'turns=' + $mapRow.turns + ' cr=' + $mapRow.cache_read + ' reasks=' + $mapRow.reasks } else { 'no map row' }))
    T 'MUST FIRE  a start/end pair is ONE invocation, never two' `
      ($null -ne $mapRow -and [long]$mapRow.calls -eq 1) ($(if ($mapRow) { [string]$mapRow.calls } else { 'no row' }))

    # ---- SAME-SECOND PAIRS AND SHARED LABELS (added 2026-08-25, measured on the jc1 drill).
    #
    # Two defects that both LOSE PAIRS SILENTLY, in the instrument the wide proving run is measured
    # with. (1) `at` has SECOND resolution, so a fast mechanical stage stamps its start and its end in
    # the same timestamp - measured: `map-preresolve verify` on the drill's second slug stamped both
    # at 05:51:53. The reader used to `Sort-Object at` first, and PS 5.1's sort gives no stable-order
    # guarantee for equal keys, so that end could be ordered BEFORE its own start: the end is dropped
    # and the start dangles forever. The drill reported "1 invocation(s) logged a start with no end"
    # over a log whose starts and ends balance exactly. The log is APPEND-ONLY, so file order IS
    # chronological and the sort could only destroy information. (2) The pairing key omitted `items`,
    # so two invocations sharing a lane and a label shared one slot.
    #
    # NEUTER PROOF, run 2026-08-25: restore `| Sort-Object at` and the same-second case goes red; drop
    # `items` from the pairing key and the shared-label case goes red. On the real drill log the fix
    # also moved the map lane's mean_sec from 200 to 160 - a lost pair being counted again, which is
    # the point: this recovers data, it does not merely silence a warning.
    $lt4 = Join-Path ([IO.Path]::GetTempPath()) ("hr-lanesum2-" + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Path $lt4 -Force | Out-Null
      $lg4 = Join-Path $lt4 'lane-log.jsonl'
      # a same-second pair, and TWO more invocations sharing lane+label with different items
      Add-LaneLine -Path $lg4 -Line (New-LaneLine -LaneName 'map' -Label 'verify' -ItemList @('a') -By 'mechanical' -Detail '' -At '2026-08-24T10:00:00' -Event 'start')
      Add-LaneLine -Path $lg4 -Line (New-LaneLine -LaneName 'map' -Label 'verify' -ItemList @('a') -By 'mechanical' -Detail '' -At '2026-08-24T10:00:00' -Event 'end' -In 0 -Out 0)
      Add-LaneLine -Path $lg4 -Line (New-LaneLine -LaneName 'map' -Label 'verify' -ItemList @('b') -By 'mechanical' -Detail '' -At '2026-08-24T10:00:01' -Event 'start')
      Add-LaneLine -Path $lg4 -Line (New-LaneLine -LaneName 'map' -Label 'verify' -ItemList @('c') -By 'mechanical' -Detail '' -At '2026-08-24T10:00:02' -Event 'start')
      Add-LaneLine -Path $lg4 -Line (New-LaneLine -LaneName 'map' -Label 'verify' -ItemList @('b') -By 'mechanical' -Detail '' -At '2026-08-24T10:00:05' -Event 'end' -In 0 -Out 0)
      Add-LaneLine -Path $lg4 -Line (New-LaneLine -LaneName 'map' -Label 'verify' -ItemList @('c') -By 'mechanical' -Detail '' -At '2026-08-24T10:00:09' -Event 'end' -In 0 -Out 0)
      # ASSERTED THROUGH -StageSummary -Json, because that is the ONLY surface that exposes what the
      # pairing produces. -LaneSummary's `calls` counts non-end lines and `measured` counts end lines;
      # neither touches $durations, so a fixture asserting on them cannot fail when the pairing breaks
      # - measured 2026-08-25, when exactly that fixture passed with both defects restored. A neuter
      # proof that does not fail is not a proof, and the assertion had to move, not the standard.
      $so4 = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -StageSummary -RunDir $lt4 -Json 2>&1
      $s4 = $null
      try { $s4 = (@($so4 | ForEach-Object { [string]$_ }) -join "`n") | ConvertFrom-Json } catch {}
      $r4 = $null
      if ($s4) { $r4 = @($s4.stages | Where-Object { $_.stage -eq 'verify' })[0] }
      T 'MUST FIRE  three invocations sharing lane+label with different items are THREE pairs carrying their own durations (0 + 4 + 7 = 11s) - without `items` in the key the interleaved ones overwrite each other and one pair is lost' `
        ($null -ne $r4 -and [long]$r4.n -eq 3 -and [long]$r4.total_sec -eq 11) `
        ($(if ($r4) { 'n=' + $r4.n + ' total_sec=' + $r4.total_sec } else { ($so4 -join ' ').Substring(0, [Math]::Min(200, ($so4 -join ' ').Length)) }))
      T 'MUST FIRE  ...and no start is left dangling - a same-second pair must still close' `
        ($null -ne $s4 -and @($s4.unfinished).Count -eq 0) `
        ($(if ($s4) { 'unfinished=' + (@($s4.unfinished) -join ',') } else { 'no json' }))
    } finally { Remove-Item -Recurse -Force $lt4 -ErrorAction SilentlyContinue }
    # ---- T3 (2026-08-25): -At LETS A CALLER BACKDATE ITS OWN START LINE, and the local extraction
    # ladder is why. It learns which rung settled a page only AFTER the page is settled, so it wrote
    # start and end back to back and -StageSummary ranked every local extraction at ~0 s while the
    # real duration sat in `detail` as prose no reader parses. A fake zero is worse than a gap: it
    # reads as a stage that cost nothing. Driven through the REAL -Lane entry point, because the
    # defect being fixed is in the passthrough, not in New-LaneLine (which always took -At).
    $lt5 = Join-Path ([IO.Path]::GetTempPath()) ("hr-at-" + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Path $lt5 -Force | Out-Null
      & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Lane -RunDir $lt5 `
        -LaneName 'extract' -Label 'local rung 1' -Items 'y' -By 'local' -Event 'start' `
        -At '2026-08-24T10:00:00' | Out-Null
      & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Lane -RunDir $lt5 `
        -LaneName 'extract' -Label 'local rung 1' -Items 'y' -By 'local' -Event 'end' `
        -At '2026-08-24T10:00:42' -InputTokens 0 -OutputTokens 0 | Out-Null
      $so5 = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -StageSummary -RunDir $lt5 -Json 2>&1
      $s5 = $null
      try { $s5 = (@($so5 | ForEach-Object { [string]$_ }) -join "`n") | ConvertFrom-Json } catch {}
      $r5 = $null
      if ($s5) { $r5 = @($s5.stages | Where-Object { $_.stage -eq 'local rung 1' })[0] }
      T 'MUST FIRE  -At backdates the start line, so a stage that reports its own duration is ranked at 42s instead of the fake 0s it used to show' `
        ($null -ne $r5 -and [long]$r5.total_sec -eq 42 -and [string]$r5.kind -eq 'local') `
        ($(if ($r5) { 'total_sec=' + $r5.total_sec + ' kind=' + $r5.kind } else { ($so5 -join ' ') }))
      # CLEAN TWIN: every OTHER caller passes no -At and must be stamped now, exactly as before.
      & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Lane -RunDir $lt5 `
        -LaneName 'map' -Label 'plain' -Items 'z' -By 'mechanical' -Event 'start' | Out-Null
      $plain = @(Read-LaneLog (Join-Path $lt5 'lane-log.jsonl') | Where-Object { $_.label -eq 'plain' })[0]
      T 'CLEAN TWIN a caller that passes no -At is stamped NOW, so every existing call site is byte-identical' `
        ($null -ne $plain -and ([datetime]::Parse($plain.at) -gt (Get-Date).AddMinutes(-5))) `
        ($(if ($plain) { [string]$plain.at } else { 'no plain line' }))
    } finally { Remove-Item -Recurse -Force $lt5 -ErrorAction SilentlyContinue }
    # ---- T4 NEUTER PROOFS, ALL RUN AND REVERTED 2026-08-25, counts as the suite printed them:
    #   * fold the divided batch into `own`, hiding the estimate  -> 2 red;
    #   * attribute the price lane by dividing it across recipes  -> 4 red;
    #   * report a missing history as 0 minutes instead of UNKNOWN -> 2 red;
    #   * drop the divided-not-measured disclosure line           -> 1 red.
    #
    # AND TWO LESSONS PAID FOR HERE. The -Json cases ALL PASSED while the human table threw: the
    # header used '{2,>10}' and '>' is not a .NET alignment token, so the text case exists and is
    # asserted separately - a summary nobody can read is not a summary. Second, this suite marks a
    # failure with FAIL and not with X, so a neuter harness copied from the daemon's counted zero
    # reds and flagged its own valid proofs as INVALID. Check the marker before believing a count.
    #
    # ---- T4 (2026-08-25): -RecipeSummary. The question neither other summary can answer - what did
    # ONE recipe cost, and how long did it take. The three honesty rules are each their own assertion,
    # because a per-recipe number is the easiest place in this estate to lie: attributable and shared
    # stay separate columns, the price lane is never divided into a recipe, and a missing history is
    # UNKNOWN rather than zero.
    $lt6 = Join-Path ([IO.Path]::GetTempPath()) ("hr-recsum-" + [Guid]::NewGuid().ToString('N'))
    try {
      New-Item -ItemType Directory -Path (Join-Path $lt6 'state') -Force | Out-Null
      $lg6 = Join-Path $lt6 'lane-log.jsonl'
      # a SINGLE-slug dispatch (fully attributable), a THREE-slug batch (divided), a PRICE line whose
      # items are TERMS, and a preaudit line with no items at all
      Add-LaneLine -Path $lg6 -Line (New-LaneLine -LaneName 'write' -Label 'w:a' -ItemList @('a') -By 'writer' -Detail '' -At '2026-08-25T10:00:00' -Event 'end' -In 900 -Out 100)
      Add-LaneLine -Path $lg6 -Line (New-LaneLine -LaneName 'map' -Label 'map:3x' -ItemList @('a','b','c') -By 'mapper' -Detail '' -At '2026-08-25T10:05:00' -Event 'end' -In 2700 -Out 300)
      Add-LaneLine -Path $lg6 -Line (New-LaneLine -LaneName 'price' -Label 'batch 1' -ItemList @('harissa','tteok') -By 'pricer' -Detail '' -At '2026-08-25T10:10:00' -Event 'end' -In 5000 -Out 500)
      Add-LaneLine -Path $lg6 -Line (New-LaneLine -LaneName 'audit' -Label 'wave-preaudit w1' -ItemList @() -By 'mechanical' -Detail '' -At '2026-08-25T10:12:00' -Event 'end' -In 0 -Out 0)
      foreach ($s in @('a', 'b', 'c')) {
        Write-JsonAtomic -Path (Join-Path $lt6 ('state\{0}.json' -f $s)) -Obj ([pscustomobject]@{
          slug = $s; state = 'qa-passed'; history = @(
            [pscustomobject]@{ state = 'sourced'; at = '2026-08-25T10:00:00'; by = 't'; detail = '' },
            [pscustomobject]@{ state = 'qa-passed'; at = '2026-08-25T10:30:00'; by = 't'; detail = '' }) })
      }
      # ...and one recipe with NO history at all, which must read UNKNOWN rather than 0 minutes
      Write-JsonAtomic -Path (Join-Path $lt6 'state\d.json') -Obj ([pscustomobject]@{
        slug = 'd'; state = 'mapped'; history = @() })
      $ro6 = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -RecipeSummary -RunDir $lt6 -Json 2>&1
      $rs6 = $null
      try { $rs6 = (@($ro6 | ForEach-Object { [string]$_ }) -join "`n") | ConvertFrom-Json } catch {}
      $ra = $null; $rb = $null; $rd = $null; $pr = $null
      if ($rs6) {
        $ra = @($rs6.recipes | Where-Object { $_.slug -eq 'a' })[0]
        $rb = @($rs6.recipes | Where-Object { $_.slug -eq 'b' })[0]
        $rd = @($rs6.recipes | Where-Object { $_.slug -eq 'd' })[0]
        $pr = @($rs6.unattributed | Where-Object { $_.lane -eq 'price' })[0]
      }
      T 'MUST FIRE  a single-slug dispatch is ATTRIBUTABLE and a 3-slug batch is SHARED - the two never merge into one total' `
        ($null -ne $ra -and [long]$ra.attributable -eq 1000 -and [long]$ra.shared -eq 1000 -and [long]$ra.total -eq 2000 -and [int]$ra.shared_lines -eq 1) `
        ($(if ($ra) { 'attrib=' + $ra.attributable + ' shared=' + $ra.shared + ' lines=' + $ra.shared_lines } else { ($ro6 -join ' ') }))
      T 'MUST FIRE  ...and a recipe that only ever rode the batch carries NO attributable spend at all' `
        ($null -ne $rb -and [long]$rb.attributable -eq 0 -and [long]$rb.shared -eq 1000) `
        ($(if ($rb) { 'attrib=' + $rb.attributable + ' shared=' + $rb.shared } else { 'no row' }))
      T 'MUST FIRE  the PRICE lane lands UNATTRIBUTED whole - its items are terms deduped across recipes, so dividing it would invent a number the architecture does not have' `
        ($null -ne $pr -and [long]$pr.total -eq 5500 -and @($rs6.recipes | Where-Object { $_.lanes -contains 'price' }).Count -eq 0) `
        ($(if ($pr) { 'price=' + $pr.total } else { 'price never surfaced' }))
      T 'MUST FIRE  the wall-clock spine comes from the state history - 30 minutes, from a file no summary read before' `
        ($null -ne $ra -and [int]$ra.wall_sec -eq 1800) `
        ($(if ($ra) { 'wall_sec=' + $ra.wall_sec } else { 'no row' }))
      T 'CLEAN TWIN a recipe with no history reports wall_sec -1 (UNKNOWN), never 0 - zero and unknown are different claims' `
        ($null -ne $rd -and [int]$rd.wall_sec -eq -1) `
        ($(if ($rd) { 'wall_sec=' + $rd.wall_sec } else { 'no row' }))
      # THE TEXT TABLE IS ITS OWN CASE, and it is here because the -Json cases above ALL PASSED while
      # the human table threw: the header used '{2,>10}', and '>' is not a .NET alignment token. A
      # summary nobody can read is not a summary, and only rendering it catches that.
      $txt6 = (@(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -RecipeSummary -RunDir $lt6 2>&1) | ForEach-Object { [string]$_ }) -join "`n"
      T 'MUST FIRE  the human table RENDERS, names the unattributed price lane and says plainly that `shared` is divided rather than measured' `
        ($txt6 -match 'attrib' -and $txt6 -notmatch 'Error formatting' -and
         $txt6 -match 'UNATTRIBUTED' -and $txt6 -match 'structural' -and
         $txt6 -match 'DIVIDED BY ITS BATCH SIZE' -and $txt6 -match 'wall clock is UNKNOWN, not zero') `
        ($txt6.Substring(0, [Math]::Min(240, $txt6.Length)))
    } finally { Remove-Item -Recurse -Force $lt6 -ErrorAction SilentlyContinue }
    # ---- F (2026-08-24): API ROUND TRIPS ARE NOT BILLED INVOCATIONS, and the reader must keep them
    # apart. The 6b run's own numbers are the case: one mapper session made 47 round trips and billed
    # ~500k tokens while `calls` read 1, because `calls` counts CLI invocations (a re-ask makes it 2)
    # and criterion 1 depends on exactly that. Diagnosing 6b therefore needed transcript archaeology
    # outside the pipeline, which is the thing C1 was built to end. Three assertions: the trips land,
    # they do NOT overwrite turns, and a log written before this field reports NOT-MEASURED rather
    # than a fake zero - the quiet-wrongness class this fixture family exists for.
    T 'MUST FIRE  the API round trips land on the lane, and do NOT collide with `turns`' `
      ($null -ne $mapRow -and [long]$mapRow.api_turns -eq 47 -and [long]$mapRow.turns -eq 2) `
      ($(if ($mapRow) { 'api_turns=' + $mapRow.api_turns + ' turns=' + $mapRow.turns } else { 'no map row' }))
    T 'CLEAN TWIN a lane whose lines predate the field reports NOT-MEASURED, never a fake 0 trips' `
      ($null -ne $qaRow -and [long]$qaRow.api_turns -eq 0) `
      ($(if ($qaRow) { [string]$qaRow.api_turns } else { 'no qa row' }))
    T 'CLEAN TWIN the v2 single-line convention still reads exactly as before' `
      ($null -ne $qaRow -and [long]$qaRow.calls -eq 1 -and [long]$qaRow.in -eq 1000 -and [long]$qaRow.out -eq 200) `
      ($(if ($qaRow) { 'in=' + $qaRow.in } else { 'no qa row' }))
    T 'CLEAN TWIN the run total sums BOTH conventions' `
      ($null -ne $sum -and [long]$sum.total_tokens -eq (245806 + 76728 + 1000 + 200)) `
      ($(if ($sum) { [string]$sum.total_tokens } else { 'no json' }))

    # ---- FIXTURE 7d. -StageSummary (G, 2026-08-24). The lane roll-up says the map lane took 15
    # minutes; it cannot say WHICH stage in it, and until the mechanical stages started emitting
    # start/end pairs the honest answer for half of them was 'we do not know'. Same log, same
    # pairing, different grouping - so the two readers cannot drift apart.
    Add-LaneLine -Path $lg3 -Line (New-LaneLine -LaneName 'map' -Label 'map-preresolve' -ItemList @('a') -By 'mechanical' -Detail '' -At '2026-08-24T10:20:00' -Event 'start')
    Add-LaneLine -Path $lg3 -Line (New-LaneLine -LaneName 'map' -Label 'map-preresolve' -ItemList @('a') -By 'mechanical' -Detail '' -At '2026-08-24T10:21:00' -Event 'end' -In 0 -Out 0)
    Add-LaneLine -Path $lg3 -Line (New-LaneLine -LaneName 'write' -Label 'never-finished' -ItemList @('z') -By 'mechanical' -Detail '' -At '2026-08-24T10:22:00' -Event 'start')
    $stgOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -StageSummary -RunDir $lt3 -Json 2>&1
    $stg = $null
    try { $stg = (@($stgOut | ForEach-Object { [string]$_ }) -join "`n") | ConvertFrom-Json } catch {}
    $top = $null; $mech = $null
    if ($stg) { $top = @($stg.stages)[0]; $mech = @($stg.stages | Where-Object { $_.stage -eq 'map-preresolve' })[0] }
    T 'MUST FIRE  -StageSummary ranks by STAGE, longest first - map:2x at 15 min outranks a 1 min pre-resolve' `
      ($null -ne $top -and [string]$top.stage -eq 'map:2x' -and [long]$top.total_sec -eq 900) `
      ($(if ($top) { $top.stage + ' ' + $top.total_sec + 's' } else { ($stgOut -join ' ')[0..200] -join '' }))
    T 'MUST FIRE  a MECHANICAL stage is timed and named as mechanical - the whole point is that it stopped being invisible' `
      ($null -ne $mech -and [long]$mech.total_sec -eq 60 -and [string]$mech.kind -eq 'mechanical') `
      ($(if ($mech) { $mech.kind + ' ' + $mech.total_sec + 's' } else { 'no map-preresolve row' }))
    T 'MUST FIRE  a stage that started and never ended is reported UNFINISHED, never counted as instant' `
      ($null -ne $stg -and (@($stg.unfinished) -join ',') -like '*never-finished*' -and
       @($stg.stages | Where-Object { $_.stage -eq 'never-finished' }).Count -eq 0) `
      ($(if ($stg) { 'unfinished=' + (@($stg.unfinished) -join ',') } else { 'no json' }))
    T 'CLEAN TWIN -StageSummary does NOT print the lane table - it was asked for stages' `
      (-not ((@($stgOut | ForEach-Object { [string]$_ }) -join ' ') -match 'lane summary')) `
      (($stgOut -join ' ')[0..120] -join '')
  } finally { Remove-Item $lt3 -Recurse -Force -ErrorAction SilentlyContinue }

  # ---- FIXTURE 8. THE COMPOSITE TERM. Founding bug 2026-08-16, run hunt-2026-08-15-lowcarb-100:
  # `-Terms 'green bell pepper,shaved beef steak'` binds to ONE element, went into the state file as one
  # term row, and could never match an ingredient-queue entry - so -Derive scored it PENDING on every pass
  # and philly-cheesesteak-stuffed-peppers parked FOREVER while both of its ingredients were already
  # CARRIED. Publishable and invisible. The clean twins assert the ROW COUNT, because the count is the
  # thing that was wrong: one row where there should have been two.
  $badTerms = @(Find-CompositeTerms @('green bell pepper,shaved beef steak'))
  T 'MUST FIRE  a comma inside a term element is detected' ($badTerms.Count -eq 1) $badTerms.Count
  T 'CLEAN TWIN properly separated terms are not composite' `
    ((@(Find-CompositeTerms @('green bell pepper', 'shaved beef steak'))).Count -eq 0) 'flagged a clean list'
  $msg = Get-CompositeTermMessage 'Terms' 'green bell pepper,shaved beef steak'
  T '   and the message shows the caller the CORRECT form to retype' `
    ($msg -match "-Terms 'green bell pepper','shaved beef steak'") $msg

  # The guard runs against the REAL -Advance branch, in-process (never `powershell -File`, which would
  # marshal [string[]] as one string - fixture 6 - and could not tell a refusal from that marshalling).
  $ct = Join-Path $env:TEMP ('huntrun-comma-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    New-Item -ItemType Directory -Force (Join-Path $ct 'state') | Out-Null
    & $PSCommandPath -Advance -RunDir $ct -Slug 'philly' -To sourced -By 'test' | Out-Null
    $sp8 = Join-Path $ct 'state\philly.json'

    & $PSCommandPath -Advance -RunDir $ct -Slug 'philly' -To selected -By 'test' -Terms 'green bell pepper,shaved beef steak' | Out-Null
    T 'MUST FIRE  -Advance REFUSES a -Terms element containing a comma' ($LASTEXITCODE -eq 1) ("exit " + $LASTEXITCODE)
    T '   and it refuses BEFORE writing, so no composite row reaches the state file' `
      ((Read-Json $sp8).state -eq 'sourced' -and (@((Read-Json $sp8).terms)).Count -eq 0) ([string](Read-Json $sp8).state)

    & $PSCommandPath -Advance -RunDir $ct -Slug 'philly' -To selected -By 'test' -OptionalTerms 'cilantro,parsley' | Out-Null
    T 'MUST FIRE  -Advance REFUSES the same in -OptionalTerms' ($LASTEXITCODE -eq 1) ("exit " + $LASTEXITCODE)

    & $PSCommandPath -Advance -RunDir $ct -Slug 'philly' -To selected -By 'test' `
      -Terms 'green bell pepper', 'shaved beef steak' -OptionalTerms 'cilantro' | Out-Null
    $back8 = Read-Json $sp8
    T 'CLEAN TWIN separately quoted terms are accepted' ($LASTEXITCODE -eq 0 -and [string]$back8.state -eq 'selected') ("exit " + $LASTEXITCODE)
    T 'CLEAN TWIN and they produce ONE ROW EACH (the count is what the bug got wrong)' `
      ((@($back8.terms)).Count -eq 3) (@($back8.terms)).Count
    T '   each row holding a single whole term, none of them composite' `
      ((@(Find-CompositeTerms @(@($back8.terms) | ForEach-Object { $_.term }))).Count -eq 0 -and `
       (@(@($back8.terms) | Where-Object { [string]$_.term -eq 'shaved beef steak' })).Count -eq 1) `
      ((@($back8.terms) | ForEach-Object { $_.term }) -join '|')

    & $PSCommandPath -Advance -RunDir $ct -Slug 'philly' -To extracted -By 'test' -Terms 'saffron' | Out-Null
    $back9 = Read-Json $sp8
    T 'CLEAN TWIN a single term with no comma still works, exactly one row' `
      ($LASTEXITCODE -eq 0 -and (@($back9.terms)).Count -eq 1 -and [string]@($back9.terms)[0].term -eq 'saffron') `
      ((@($back9.terms)).Count.ToString() + ' rows')
  } finally { Remove-Item $ct -Recurse -Force -ErrorAction SilentlyContinue }

  # ---- -Revive: undoing a rejection that was never this recipe's fault -----------------------------
  # On wave 11 a finished recipe was made TERMINAL with zero open blockers of its own - both survivors
  # were shared-data, and both were closed hours later by other work. plan_trim no longer spends a
  # recipe's budget on somebody else's defect, but that is not retroactive, so a door was needed. The
  # door is gated on the AUDIT'S OWN WORDS, because the blocker headings already record whose defect
  # each one was; every refusal below is that gate holding.
  $rv = Join-Path ([IO.Path]::GetTempPath()) ('hr-revive-' + [guid]::NewGuid().ToString('N'))
  try {
    [void](New-Item -ItemType Directory (Join-Path $rv 'state'))
    [void](New-Item -ItemType Directory (Join-Path $rv 'waves'))
    function SeedRv([string]$slug, [string]$state, $wave) {
      $e = [ordered]@{ slug = $slug; title = 'T'; source_url = 'u'; protein = 'chicken'; state = $state
                       wave = $wave; created = '2026-08-28T00:00:00'; updated = '2026-08-28T00:00:00'
                       terms = @(); reject_reason = 'blocked by the wave audit'; parked_on = @(); history = @() }
      Write-JsonAtomic -Path (Join-Path $rv ('state\' + $slug + '.json')) -Obj $e
    }
    function AuditRv([int]$k, [string]$body) {
      [IO.File]::WriteAllText((Join-Path $rv ('waves\wave-' + $k + '.audit.md')), $body, $script:UTF8)
    }
    function StRv([string]$slug) { (Read-Json (Join-Path $rv ('state\' + $slug + '.json'))).state }

    AuditRv 11 "## VERDICT: NO-GO`n### BLOCKER 1 (shared-data, owner: writer) - STILL OPEN`n### BLOCKER 2 (shared-data, owner: pricer) - STILL OPEN`n### Prior BLOCKER 3 (recipe-local, owner: writer) - VERIFIED FIXED`n"
    AuditRv 12 "## VERDICT: NO-GO`n### BLOCKER 1 (recipe-local, owner: writer) - STILL OPEN`n### BLOCKER 2 (shared-data, owner: pricer) - STILL OPEN`n"
    AuditRv 14 "## VERDICT: NO-GO`nno blocker headings at all`n"
    SeedRv 'rv-ok' 'rejected-audit' 11
    SeedRv 'rv-local' 'rejected-audit' 12
    SeedRv 'rv-noaudit' 'rejected-audit' 13
    SeedRv 'rv-noheads' 'rejected-audit' 14
    # These two are otherwise PERFECTLY revivable - rejected-audit, wave 11, whose audit carries only
    # shared-data blockers. That is the point: each is refused by exactly one gate, so tearing that
    # gate out is the only thing that can change the answer. The first shape of these two cases used
    # subjects that a DIFFERENT gate refused anyway, and both stayed green with their subject torn
    # out - vacuous, and caught only by running the neuter.
    SeedRv 'rv-noreason' 'rejected-audit' 11
    # `waved`, not `published`, and that is the whole subtlety: published cannot reach qa-passed at
    # all, so the state machine refuses it and the explicit check never has to. `waved` CAN reach
    # qa-passed legally, so this gate is the only thing standing between -Revive and a recipe that
    # was never rejected in the first place.
    SeedRv 'rv-wrongstate' 'waved' 11

    & $PSCommandPath -Revive -RunDir $rv -Slug 'rv-ok' -By 'test' -Reason 'both shared blockers closed' | Out-Null
    $rvDoc = Read-Json (Join-Path $rv 'state\rv-ok.json')
    T 'REVIVE a rejection whose every OPEN blocker was shared-data returns to qa-passed' `
      ($LASTEXITCODE -eq 0 -and (StRv 'rv-ok') -eq 'qa-passed') (StRv 'rv-ok')
    T 'REVIVE   ...and the stated reason AND the audit evidence land on the history' `
      (([string]$rvDoc.history[-1].detail) -match 'both shared blockers closed' -and `
       ([string]$rvDoc.history[-1].detail) -match 'none recipe-local') ([string]$rvDoc.history[-1].detail)
    T 'REVIVE   ...and the wave claim is cleared, or the next -WaveClose calls it already claimed' `
      ($null -eq $rvDoc.wave -and $null -eq $rvDoc.reject_reason) ('wave=' + [string]$rvDoc.wave)

    & $PSCommandPath -Revive -RunDir $rv -Slug 'rv-local' -By 'test' -Reason 'please' | Out-Null
    T 'MUST FIRE  REVIVE an OPEN recipe-local blocker is refused - the one-repair rule keeps its teeth' `
      ($LASTEXITCODE -ne 0 -and (StRv 'rv-local') -eq 'rejected-audit') (StRv 'rv-local')

    & $PSCommandPath -Revive -RunDir $rv -Slug 'rv-noaudit' -By 'test' -Reason 'trust me' | Out-Null
    T 'MUST FIRE  REVIVE no audit on disk is no evidence, so it is refused' `
      ($LASTEXITCODE -ne 0 -and (StRv 'rv-noaudit') -eq 'rejected-audit') (StRv 'rv-noaudit')

    & $PSCommandPath -Revive -RunDir $rv -Slug 'rv-noheads' -By 'test' -Reason 'trust me' | Out-Null
    T 'MUST FIRE  REVIVE an audit naming no blockers cannot say whose defect it was, so it is refused' `
      ($LASTEXITCODE -ne 0 -and (StRv 'rv-noheads') -eq 'rejected-audit') (StRv 'rv-noheads')

    & $PSCommandPath -Revive -RunDir $rv -Slug 'rv-noreason' -By 'test' | Out-Null
    T 'MUST FIRE  REVIVE a revival with no -Reason is refused - the one command that undoes a verdict must say why' `
      ($LASTEXITCODE -ne 0 -and (StRv 'rv-noreason') -eq 'rejected-audit') (StRv 'rv-noreason')

    & $PSCommandPath -Revive -RunDir $rv -Slug 'rv-wrongstate' -By 'test' -Reason 'it is mid-wave, not rejected' | Out-Null
    T 'MUST FIRE  REVIVE a slug that is not rejected-audit is refused' `
      ($LASTEXITCODE -ne 0 -and (StRv 'rv-wrongstate') -eq 'waved') (StRv 'rv-wrongstate')

    T 'CLEAN TWIN every OTHER rejected state is still terminal - the door is one declared exception' `
      ((-not (Test-LegalTransition 'rejected-dupe' 'qa-passed')) -and `
       (-not (Test-LegalTransition 'rejected-macros' 'qa-passed')) -and `
       (Test-LegalTransition 'rejected-audit' 'qa-passed')) 'the terminal default was repealed too widely'
  } finally { Remove-Item $rv -Recurse -Force -ErrorAction SilentlyContinue }

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
  # THE BAND IS OPTIONAL, AND EVERY EDGE IS OPTIONAL SEPARATELY (Brad's ruling 2026-08-24, evening:
  # "drop the band in code - however, be prepared for me to give a band during prompts").
  #
  # THIS RELAXES A GUARD ADDED THIS MORNING, AND THE REASON IT IS SAFE IS WORTH WRITING DOWN. -Init
  # used to REFUSE an unstated band, because a CONSTRAINT nobody typed gets enforced silently by two
  # gates for a whole run - that was the failure mode, and it is a real one. The ABSENCE of a
  # constraint has no such failure mode: it cannot wrongly reject anything. So defaulting to no limit
  # is safe in a way that defaulting to 400-650 / <= 35 never was. What the refusal bought - "a reader
  # months later can see what the gates were enforcing" - is kept, and kept in the two places that
  # actually get read: run.json records exactly what was stated, and the daemon logs the effective
  # band on every run.
  #
  # Unstated (-1) means UNBOUNDED for that edge alone. State only what you want limited: -ProteinMin 50
  # on its own is a protein floor with no calorie or carb limit, and reads that way in run.json.
  $stated = @()
  if ($CalMin -ge 0)     { $stated += 'CalMin' }
  if ($CalMax -ge 0)     { $stated += 'CalMax' }
  if ($CarbMax -ge 0)    { $stated += 'CarbMax' }
  if ($ProteinMin -gt 0) { $stated += 'ProteinMin' }
  if ($CalMin -ge 0 -and $CalMax -ge 0 -and $CalMin -gt $CalMax) {
    Write-Output ("hunt-run -Init: -CalMin {0} is above -CalMax {1}. A band with its floor over its ceiling admits nothing, and the run would source zero recipes without ever saying why." -f $CalMin, $CalMax)
    exit 1
  }
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
    # The band the run was STARTED under, in the run dir, so a report months later can say what the
    # gates were actually enforcing rather than what today's constants happen to be.
    band = [ordered]@{ calMin = $(if ($CalMin -ge 0) { $CalMin } else { $null })
                       calMax = $(if ($CalMax -ge 0) { $CalMax } else { $null })
                       carbMax = $(if ($CarbMax -ge 0) { $CarbMax } else { $null })
                       proteinMin = $(if ($ProteinMin -gt 0) { $ProteinMin } else { $null }) }
    band_stated = @($stated)
    catalog_digest = $digest; catalog_digest_written = $digestDate
    board_file = $(if ($board.Count) { $board[0].Name } else { $null })
    board_written = $(if ($board.Count) { $board[0].LastWriteTime.ToString('yyyy-MM-ddTHH:mm:ss') } else { $null })
  }
  Write-JsonAtomic -Path (Join-Path $RunDir 'run.json') -Obj $doc
  Write-Output ("hunt-run: initialised {0}  (wave size {1})" -f $runId, $WaveSize)
  if ($stated.Count) {
    Write-Output ("  band: cal {0}, carbs {1}, protein {2}   (stated: {3})" -f `
      $(if ($CalMin -ge 0 -or $CalMax -ge 0) { ("{0}-{1}" -f $(if ($CalMin -ge 0) { $CalMin } else { 'any' }), $(if ($CalMax -ge 0) { $CalMax } else { 'any' })) } else { 'any' }),
      $(if ($CarbMax -ge 0) { "<= $CarbMax" } else { 'any' }),
      $(if ($ProteinMin -gt 0) { ">= $ProteinMin" } else { 'any' }),
      ($stated -join ', '))
  } else {
    Write-Output '  band: NONE - no calorie, carb or protein limit. Every candidate the pool holds is eligible.'
  }
  if (-not $digestDate) { Write-Output '  WARNING no pipeline\catalog-digest.json - run make-catalog-digest.ps1 before sourcing' }
  if (-not $board.Count) { Write-Output '  WARNING no grocery\out\comparison-*.json - pricing reads it' }
  else { Write-Output ("  board: {0} (written {1})" -f $board[0].Name, $board[0].LastWriteTime.ToString('yyyy-MM-dd HH:mm')) }
  Write-GuardComplete -Name 'hunt-run' -Summary ("init {0}" -f $runId); exit 0
}

# ---- -Lane ----------------------------------------------------------------------------------------
# Record ONE agent invocation. Call it as the invocation is dispatched, once per agent, with the items
# that invocation actually took: terms for `price`, slugs for `map` / `extract` / `write` / `qa`.
# ---- -RecipeSummary (T4, 2026-08-25) --------------------------------------------------------------
#
# THE QUESTION NEITHER EXISTING SUMMARY CAN ANSWER: "what did ONE recipe cost, and how long did it
# take from enqueue to published?" -LaneSummary groups by lane, -StageSummary by lane+label, and
# `items[]` - which has carried the slugs since the log's first line - was used only to make the
# pairing key unique. The wall-clock spine was on disk the whole time too: every state file carries
# history[{state, at, by}], and -Status drops it.
#
# THREE HONESTY RULES, because a per-recipe number is the easiest place in this estate to lie.
#
# 1. ATTRIBUTABLE AND SHARED ARE DIFFERENT COLUMNS, never one total. A dispatch naming ONE slug is
#    that slug's cost. A map:3x naming three is divided by three, which is an ESTIMATE - the three
#    recipes did not cost the same, and nothing in the log says how the session actually split. The
#    division is shown in its own column with the line count beside it, so a reader can see how much
#    of a recipe's number is arithmetic rather than measurement.
# 2. THE PRICE LANE IS STRUCTURALLY UNATTRIBUTABLE and is reported as such, never divided. Its lines
#    carry TERMS, not slugs, because the queue dedupes across recipes by design - one lookup of
#    `harissa` serves every recipe waiting on it. Dividing that by recipe would invent a number the
#    architecture deliberately does not have. It lands in the UNATTRIBUTED block with its lane named.
# 3. A RECIPE WITH NO HISTORY IS ANNOUNCED, not rendered as 0 minutes. Zero and unknown are different
#    claims, which is the same rule the lane log's -1 exists for.
if ($runRecipeSummary) {
  $lp = Join-Path $RunDir 'lane-log.jsonl'
  if (-not (Test-Path $lp)) { Write-Output ("hunt-run: no lane log at {0}" -f $lp); exit 1 }
  $rows = @()
  foreach ($l in (Get-Content $lp -Encoding utf8)) {
    if (-not $l -or -not $l.Trim()) { continue }
    try { $rows += ($l | ConvertFrom-Json) } catch { }
  }
  $entries = @(Read-Entries -Dir $RunDir)
  if (-not $entries.Count) { Write-Output 'hunt-run recipe summary: no state files in this run'; exit 0 }

  $acc = @{}
  foreach ($e in $entries) {
    $acc[[string]$e.slug] = [pscustomobject]@{
      slug = [string]$e.slug; state = [string]$e.state; own = 0.0; shared = 0.0
      shared_lines = 0; lanes = @(); first_at = $null; last_at = $null; wall_sec = -1 }
  }
  $unattributed = @{}
  foreach ($r in $rows) {
    $ev = if ($r.PSObject.Properties.Name -contains 'event') { [string]$r.event } else { '' }
    if ($ev -eq 'start') { continue }             # tokens ride the END line; a start would double-count
    $tin = [double]$r.in; $tout = [double]$r.out
    if ($tin -lt 0) { $tin = 0 }                  # -1 is "not reported", which is not zero cost
    if ($tout -lt 0) { $tout = 0 }
    $tot = $tin + $tout
    if ($tot -le 0) { continue }
    $all = @(@($r.items) | ForEach-Object { [string]$_ })
    $mine = @($all | Where-Object { $acc.ContainsKey($_) })
    if (-not $mine.Count) {
      $ln = [string]$r.lane
      if (-not $unattributed.ContainsKey($ln)) { $unattributed[$ln] = 0.0 }
      $unattributed[$ln] += $tot
      continue
    }
    foreach ($s in $mine) {
      if ($all.Count -le 1) { $acc[$s].own += $tot }
      else {
        $acc[$s].shared += ($tot / $all.Count)
        $acc[$s].shared_lines += 1
      }
      if ($acc[$s].lanes -notcontains [string]$r.lane) { $acc[$s].lanes += [string]$r.lane }
    }
  }
  # the WALL-CLOCK SPINE, from the state files' own history
  foreach ($e in $entries) {
    $h = @($e.history) | Where-Object { $_ -and $_.at }
    if (-not $h.Count) { continue }
    $ats = @($h | ForEach-Object { [datetime]$_.at } | Sort-Object)
    $a = $acc[[string]$e.slug]
    $a.first_at = $ats[0].ToString('yyyy-MM-ddTHH:mm:ss')
    $a.last_at = $ats[$ats.Count - 1].ToString('yyyy-MM-ddTHH:mm:ss')
    $a.wall_sec = [int](($ats[$ats.Count - 1] - $ats[0]).TotalSeconds)
  }
  $out = @($acc.Values | Sort-Object -Property @{ Expression = { $_.own + $_.shared } } -Descending)

  if ($Json) {
    $payload = [pscustomobject]@{
      run = Split-Path $RunDir -Leaf
      recipes = @($out | ForEach-Object {
        [pscustomobject]@{ slug = $_.slug; state = $_.state
                           attributable = [long]$_.own; shared = [long]$_.shared
                           total = [long]($_.own + $_.shared); shared_lines = $_.shared_lines
                           lanes = @($_.lanes); first_at = $_.first_at; last_at = $_.last_at
                           wall_sec = $_.wall_sec } })
      unattributed = @($unattributed.Keys | Sort-Object | ForEach-Object {
        [pscustomobject]@{ lane = $_; total = [long]$unattributed[$_] } })
    }
    Write-Output ($payload | ConvertTo-Json -Depth 6)
    exit 0
  }

  Write-Output ("hunt-run recipe summary: {0}" -f (Split-Path $RunDir -Leaf))
  Write-Output ("  {0,-42} {1,-16} {2,10} {3,10} {4,10} {5,6} {6,9}  {7}" -f `
                'slug', 'state', 'attrib', 'shared', 'total', 'sh_ln', 'wall_min', 'lanes')
  foreach ($r in $out) {
    $wall = if ($r.wall_sec -lt 0) { '   no hist' } else { ('{0,9:N1}' -f ($r.wall_sec / 60.0)) }
    Write-Output ("  {0,-42} {1,-16} {2,10:N0} {3,10:N0} {4,10:N0} {5,6} {6}  {7}" -f `
                  $r.slug.Substring(0, [Math]::Min(42, $r.slug.Length)),
                  ([string]$r.state).Substring(0, [Math]::Min(16, ([string]$r.state).Length)),
                  $r.own, $r.shared, ($r.own + $r.shared), $r.shared_lines, $wall,
                  (@($r.lanes) -join ','))
  }
  if ($unattributed.Count) {
    Write-Output '  UNATTRIBUTED - real spend that belongs to no single recipe, never divided into one:'
    foreach ($k in @($unattributed.Keys | Sort-Object)) {
      $why = if ($k -eq 'price') { '  (lines carry TERMS, deduped across recipes - this one is structural)' } else { '' }
      Write-Output ("    {0,-12} {1,12:N0}{2}" -f $k, $unattributed[$k], $why)
    }
  }
  $noHist = @($out | Where-Object { $_.wall_sec -lt 0 })
  if ($noHist.Count) {
    Write-Output ("  {0} recipe(s) carry no history and their wall clock is UNKNOWN, not zero: {1}" -f `
                  $noHist.Count, ((@($noHist | ForEach-Object { $_.slug })) -join ', '))
  }
  Write-Output '  `shared` is a batched dispatch DIVIDED BY ITS BATCH SIZE - an estimate, not a measurement.'
  Write-GuardComplete -Name 'hunt-run' -Summary ("recipe-summary recipes={0}" -f $out.Count); exit 0
}

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
  $stageSecs = @{}
  $stageBy = @{}
  # TWO PAIRING DEFECTS, BOTH FIXED 2026-08-25, BOTH MEASURED ON THE jc1 DRILL. This is the
  # instrument the wide proving run gets measured with, and it was quietly losing pairs.
  #
  # 1. `Sort-Object at` RE-SORTED AN ALREADY-ORDERED FILE, AND ITS SORT IS NOT STABLE. `at` has
  #    SECOND resolution, so a fast mechanical stage starts and ends inside one timestamp - measured:
  #    `map-preresolve verify` on the second slug stamped start and end both at 05:51:53. PS 5.1's
  #    Sort-Object gives no stable-order guarantee for equal keys, so that end can be ordered BEFORE
  #    its own start. The end is then dropped (no start recorded yet) and the start dangles forever,
  #    which is exactly what the drill reported: "1 invocation(s) logged a start with no end" over a
  #    log whose starts and ends balance perfectly. The lane log is APPEND-ONLY - hunt-run is its only
  #    writer and every line is appended as it happens - so FILE ORDER IS ALREADY CHRONOLOGICAL and
  #    the sort could only ever destroy information. It is removed rather than made stable.
  #
  # 2. THE KEY OMITTED `items`, so two invocations sharing a lane and a label shared one slot. The map
  #    lane runs 2 workers and `map-preresolve verify` carries a fixed label with a different slug in
  #    `items` each time; genuinely concurrent ones would overwrite each other's start and report the
  #    survivor's duration for both. audit-lane-shape.ps1's Get-Invocations already keys on
  #    lane+label+items for this same reason - the two readers of this file now agree.
  foreach ($r in $rows) {
    $ev = if ($r.PSObject.Properties.Name -contains 'event') { [string]$r.event } else { '' }
    if (-not $ev) { continue }
    $key = ([string]$r.lane) + '|' + ([string]$r.label) + '|' +
           ((@($r.items) | ForEach-Object { [string]$_ }) -join ([char]1))
    if ($ev -eq 'start') { $starts[$key] = [datetime]$r.at; continue }
    if ($ev -eq 'end' -and $starts.ContainsKey($key)) {
      $sec = ([datetime]$r.at - $starts[$key]).TotalSeconds
      if ($sec -ge 0) {
        if (-not $durations.ContainsKey([string]$r.lane)) { $durations[[string]$r.lane] = @() }
        $durations[[string]$r.lane] += $sec
        # G (2026-08-24): the SAME pairing, kept at STAGE granularity too. The lane roll-up answers
        # 'which lane is slow'; -StageSummary answers 'which stage in it', which is the question that
        # was actually being asked when the mechanical stages were emitting nothing at all.
        # the STAGE roll-up is keyed lane|label WITHOUT items on purpose: it answers "which stage
        # is slow", so every invocation of one stage belongs in the same bucket. Only the PAIRING
        # key needs items to be unique.
        $sk = ([string]$r.lane) + '|' + ([string]$r.label)
        if (-not $stageSecs.ContainsKey($sk)) { $stageSecs[$sk] = @() }
        $stageSecs[$sk] += $sec
        $stageBy[$sk] = $(if ($r.PSObject.Properties.Name -contains 'by') { [string]$r.by } else { '' })
      }
      $starts.Remove($key)
    }
  }
  # ---- -StageSummary: the SAME pairing, ranked by stage --------------------------------------------
  #
  # WHY THIS EXISTS. The lane roll-up says the map lane took 20 minutes. It cannot say whether that was
  # map-preresolve, the mapper agent, or the assemble verify - and until 2026-08-24 the mechanical two
  # of those three logged nothing at all, so the honest answer was 'we do not know'. This ranks every
  # start/end pair in the log by total time, longest first, and marks which are mechanical.
  #
  # SHARE IS OF MEASURED TIME, NOT OF THE RUN. Lanes overlap by design, so these seconds sum to more
  # than the wall clock. A stage at '30%' held a third of the time SOMETHING was in flight - it is a
  # ranking, and reading it as a third of the run would overstate every row on the page.
  if ($runStageSummary) {
    if (-not $stageSecs.Count) {
      Write-Output 'hunt-run stage summary: no start/end pair in this lane log - nothing is timed yet'
      Write-GuardComplete -Name 'hunt-run' -Summary 'stage-summary stages=0'; exit 0
    }
    $stageRows = @(foreach ($k in $stageSecs.Keys) {
      $secs = @($stageSecs[$k]); $parts = $k -split '\|', 2
      [pscustomobject]@{ lane = $parts[0]; label = $parts[1]; n = $secs.Count
                         total = (($secs | Measure-Object -Sum).Sum)
                         mean = (($secs | Measure-Object -Average).Average)
                         by = [string]$stageBy[$k] }
    })
    $grand = (($stageRows | Measure-Object -Property total -Sum).Sum)
    # SORTED ONCE, SHARED. The text table and the -Json payload each used to sort for themselves, and
    # a neuter proof caught it: reversing the TEXT sort left every fixture green, because the fixture
    # reads JSON. Two orderings of the same ranking is two things that can disagree, and the one
    # nobody asserts on is the one that drifts.
    $stageRows = @($stageRows | Sort-Object total -Descending)
    # -Json is honoured HERE rather than ignored. -LaneSummary has a machine road and a reader that
    # silently dropped the flag would hand a caller the text table to parse, which is how the v2
    # summary got parsed by regex in the first place.
    if ($Json) {
      $payload = [pscustomobject]@{
        run = (Split-Path -Leaf $RunDir); measured_sec = $grand; stages = @($stageRows |
          ForEach-Object {
            [pscustomobject]@{ lane = $_.lane; stage = $_.label; n = $_.n; total_sec = $_.total
                               mean_sec = $_.mean; by = $_.by
                               kind = $(if ($_.by -eq 'mechanical') { 'mechanical' }
                                        elseif ($_.by -eq 'local') { 'local' } else { 'judgment' }) } })
        unfinished = @($starts.Keys)
      }
      # NO guard line after the payload, matching -LaneSummary -Json two screens down: a trailing
      # HUNT-RUN-COMPLETE makes the joined stdout unparseable, which is exactly how fixture 7d first
      # failed - the JSON was correct and every reader of it saw null.
      Write-Output ($payload | ConvertTo-Json -Depth 6)
      exit 0
    }
    Write-Output ("hunt-run stage summary: {0}" -f (Split-Path -Leaf $RunDir))
    Write-Output ("  {0,-9} {1,-30} {2,5} {3,10} {4,9} {5,7}  {6}" -f 'lane','stage','n','total_min','mean_sec','share','kind')
    foreach ($r in $stageRows) {
      $share = if ($grand -gt 0) { '{0:N1}%' -f (100.0 * $r.total / $grand) } else { '-' }
      $kind = if ($r.by -eq 'mechanical') { 'mechanical' } elseif ($r.by -eq 'local') { 'local' } else { 'judgment' }
      Write-Output ("  {0,-9} {1,-30} {2,5} {3,10:N1} {4,9:N0} {5,7}  {6}" -f $r.lane, $r.label.Substring(0, [Math]::Min(30, $r.label.Length)), $r.n, ($r.total / 60.0), $r.mean, $share, $kind)
    }
    $unf = @($starts.Keys)
    if ($unf.Count -gt 0) {
      Write-Output ("  {0} stage(s) logged a start with no end - still running, or died: {1}" -f $unf.Count, (($unf | Select-Object -First 4) -join ', '))
    }
    Write-Output ("  measured {0:N1} min across {1} stage(s). Lanes OVERLAP, so this exceeds wall clock - it ranks, it does not budget." -f ($grand / 60.0), $stageRows.Count)
    Write-GuardComplete -Name 'hunt-run' -Summary ("stage-summary stages={0} measured_min={1:N1}" -f $stageRows.Count, ($grand / 60.0)); exit 0
  }


  $agg = @{}
  function Get-NumField($row, [string]$name) {
    if ($row.PSObject.Properties.Name -contains $name -and $null -ne $row.$name) { return [long]$row.$name }
    return -1
  }
  foreach ($r in $rows) {
    $ln = [string]$r.lane
    $ev = if ($r.PSObject.Properties.Name -contains 'event') { [string]$r.event } else { '' }
    if (-not $agg.ContainsKey($ln)) {
      $agg[$ln] = [pscustomobject]@{ lane=$ln; calls=0; items=0; in=0; out=0; measured=0
                                     turns=0; cache_read=0; cache_creation=0; all_in=0; all_out=0
                                     reasks=0; api_turns=0 }
    }
    $a = $agg[$ln]
    # ONE INVOCATION IS COUNTED ONCE: from its start line (daemon pairs) or from its only line (the
    # v2 orchestrator's event-less rows, and the local ladder's).
    if ($ev -ne 'end') { $a.calls++; $a.items += [int]$r.count }
    # BUT THE TOKENS LIVE ON THE END LINE, AND THE OLD READER SKIPPED END LINES WHOLE. CORRECTED
    # 2026-08-24 (phase-6a aftercare, measured): the daemon stamps in/out - and since C1 the turns,
    # the cache split and the subagent-inclusive totals - on the END line of each start/end pair,
    # while the start line carries -1s. This block aggregated from starts and dropped ends, so a
    # summary over any daemon run reported ZERO tokens on every lane ('lane-summary lanes=0 tokens='
    # on a log holding a fully-stamped 245k-token dispatch). It read correctly only for the v2
    # orchestrator's one-line-per-invocation convention, which no live writer uses any more. The
    # duration pairing above always knew about the pairs; the token pass now does too.
    if ($ev -ne 'start') {
      $ri = Get-NumField $r 'in'; $ro = Get-NumField $r 'out'
      if ($ri -ge 0 -or $ro -ge 0) {
        $a.measured++
        if ($ri -gt 0) { $a.in += $ri }
        if ($ro -gt 0) { $a.out += $ro }
      }
      foreach ($pair in @(@('calls','turns'), @('cache_read','cache_read'),
                          @('cache_creation','cache_creation'), @('all_in','all_in'),
                          @('all_out','all_out'), @('api_turns','api_turns'))) {
        $v = Get-NumField $r $pair[0]
        if ($v -gt 0) { $a.($pair[1]) += $v }
      }
      $det = if ($r.PSObject.Properties.Name -contains 'detail') { [string]$r.detail } else { '' }
      if ($det -like 're-asked*') { $a.reasks++ }
    }
  }
  $tot = ($agg.Values | Measure-Object -Property in -Sum).Sum + ($agg.Values | Measure-Object -Property out -Sum).Sum
  if ($runJson) {
    ([pscustomobject]@{ run=(Split-Path $RunDir -Leaf); total_tokens=$tot; lanes=@($agg.Values | Sort-Object { -($_.in + $_.out) }) } | ConvertTo-Json -Depth 5)
    exit 0
  }
  Write-Output ("hunt-run lane summary: {0}" -f (Split-Path $RunDir -Leaf))
  # F: `trips` is the API ROUND TRIPS, the number that explains the working set. `turns` beside it is
  # billed CLI invocations, which is what criterion 1 counts. They are different questions and this is
  # the first reader that can answer the second one without leaving the pipeline.
  Write-Output ("  {0,-9} {1,6} {2,6} {3,6} {4,7} {5,12} {6,12} {7,12} {8,7} {9,7} {10,9} {11,9}" -f 'lane','calls','turns','trips','items','input','output','total','share','re-asks','mean_sec','total_min')
  foreach ($a in ($agg.Values | Sort-Object { -($_.in + $_.out) })) {
    $lt = $a.in + $a.out
    $share = if ($tot -gt 0) { '{0:N1}%' -f (100.0 * $lt / $tot) } else { '-' }
    $note = if ($a.measured -lt $a.calls) { (' [{0}/{1} tok]' -f $a.measured, $a.calls) } else { '' }
    # A DELEGATION NOTE, off C1's subagent-inclusive totals: all_out above out means a dispatch
    # billed models beyond its own session, and the difference is the number that used to live in
    # no ledger at all (the phase-5 mapper's invisible $1.64).
    if ($a.all_out -gt $a.out) { $note += (' [+{0} delegated out]' -f ($a.all_out - $a.out)) }
    $d = @($durations[$a.lane])
    $mean = if ($d.Count) { '{0:N0}' -f (($d | Measure-Object -Average).Average) } else { '-' }
    $tmin = if ($d.Count) { '{0:N1}' -f ((($d | Measure-Object -Sum).Sum) / 60.0) } else { '-' }
    $trips = if ($a.api_turns -gt 0) { [string]$a.api_turns } else { '-' }
    Write-Output ("  {0,-9} {1,6} {2,6} {3,6} {4,7} {5,12:N0} {6,12:N0} {7,12:N0} {8,7} {9,7} {10,9} {11,9}{12}" -f $a.lane,$a.calls,$a.turns,$trips,$a.items,$a.in,$a.out,$lt,$share,$a.reasks,$mean,$tmin,$note)
  }
  $unfinished = @($starts.Keys)
  if ($unfinished.Count -gt 0) {
    Write-Output ("  {0} invocation(s) logged a start with no end - still running, or died: {1}" -f $unfinished.Count, (($unfinished | Select-Object -First 4) -join ', '))
  }
  Write-Output ("  {0,-9} {1,6} {2,6} {3,6} {4,7} {5,12} {6,12} {7,12:N0}" -f 'TOTAL',(($agg.Values|Measure-Object -Property calls -Sum).Sum),(($agg.Values|Measure-Object -Property turns -Sum).Sum),(($agg.Values|Measure-Object -Property api_turns -Sum).Sum),(($agg.Values|Measure-Object -Property items -Sum).Sum),'','',$tot)
  # start lines carry -1 BY CONVENTION (the stamp lands on the end line), so only non-start rows can
  # be honestly called unmeasured - counting starts made every daemon run read as half-unmeasured.
  $unmeasured = @($rows | Where-Object {
      $e = if ($_.PSObject.Properties.Name -contains 'event') { [string]$_.event } else { '' }
      ($e -ne 'start') -and (-not ($_.PSObject.Properties.Name -contains 'in') -or [int]$_.in -lt 0) }).Count
  if ($unmeasured -gt 0) {
    Write-Output ("  NOTE {0} row(s) carry no token figures - treat every number above as a LOWER BOUND." -f $unmeasured)
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
  $line = New-LaneLine -LaneName $ln -Label $Label -ItemList $Items -By $By -Detail $Detail `
                       -At $(if ($At) { $At } else { (Get-Stamp) }) `
                       -In $InputTokens -Out $OutputTokens -Event $Event `
                       -CacheRead $CacheRead -CacheCreation $CacheCreation -Calls $Calls -ApiTurns $ApiTurns `
                       -AllIn $AllModelsIn -AllOut $AllModelsOut -Models $Models
  Add-LaneLine -Path (Join-Path $RunDir 'lane-log.jsonl') -Line $line
  Write-Output ("hunt-run lane: {0}  {1} item(s){2}" -f $ln, $line.count, $(if ($Label) { "   ($Label)" } else { '' }))
  if ($line.count -eq 0) {
    Write-Output '  NOTE no items recorded. An invocation with no item list cannot be audited for batch shape.'
  }
  Write-GuardComplete -Name 'hunt-run' -Summary ("lane {0} n={1}" -f $ln, $line.count); exit 0
}

# ---- -Advance -------------------------------------------------------------------------------------
# ---- -Revive ---------------------------------------------------------------------------------------
# Return a recipe that was rejected for SOMEBODY ELSE'S defect. Gated on the audit's own words: the
# blocker headings already say `(shared-data, owner: X)` or `(recipe-local, owner: X)`, so the
# evidence for the exemption is written down before anyone asks for it.
if ($runRevive) {
  if (-not $Slug)   { Write-Output 'hunt-run: -Revive needs -Slug'; exit 1 }
  # A REASON IS MANDATORY. This is the one command that undoes a verdict, so the record has to say
  # who decided it was wrong and why; a revival with no stated cause is indistinguishable from a
  # mistake six months later.
  if (-not $Reason) { Write-Output 'hunt-run: -Revive needs -Reason "<why this rejection no longer holds>"'; exit 1 }
  $sp = Get-StatePath $RunDir $Slug
  if (-not (Test-Path $sp)) { Write-Output ("hunt-run: '{0}' has no state file" -f $Slug); exit 1 }
  $e = Read-Json $sp
  $from = [string]$e.state
  if ($from -ne 'rejected-audit') {
    Write-Output ("hunt-run: -Revive only applies to rejected-audit; {0} is '{1}'" -f $Slug, $from); exit 1
  }
  $wk = [int]$e.wave
  $auditPath = Join-Path $RunDir ("waves\wave-{0}.audit.md" -f $wk)
  if (-not (Test-Path $auditPath)) {
    Write-Output ("hunt-run: no audit at {0} - the exemption is granted on the audit's own evidence, and there is none" -f $auditPath); exit 1
  }
  # Only OPEN blockers count. A heading that says `Prior BLOCKER` is one an earlier cycle already
  # closed, and holding a recipe terminal for a defect that is on record as fixed is the bug.
  $kinds = @()
  foreach ($ln in (Get-Content $auditPath)) {
    $m = [regex]::Match([string]$ln, '^###\s+BLOCKER\s+\d+\s*\(\s*([a-zA-Z-]+)')
    if ($m.Success) { $kinds += $m.Groups[1].Value.ToLower() }
  }
  if (-not $kinds.Count) {
    # Single-quoted on purpose: a backtick is PowerShell's escape character, so quoting the heading
    # shape with backticks inside a double-quoted string silently eats them.
    Write-Output ('hunt-run: ' + $Slug + "'s audit names no open blockers in the '### BLOCKER n (kind)' form, so nothing here can tell whose defect it was. Refusing."); exit 1
  }
  $local = @($kinds | Where-Object { $_ -eq 'recipe-local' })
  if ($local.Count) {
    Write-Output ("hunt-run: REFUSED - {0}'s audit still carries {1} recipe-local blocker(s). The one-repair rule holds for a defect in THIS recipe; fix it and let the wave re-audit." -f $Slug, $local.Count)
    exit 1
  }
  if (-not (Test-LegalTransition $from 'qa-passed')) {
    Write-Output ("hunt-run: REFUSED {0}: {1} -> qa-passed" -f $Slug, $from); exit 1
  }
  $detail = ("revived: " + $Reason + "  [audit blockers: " + (($kinds | Sort-Object -Unique) -join ', ') + "; none recipe-local]")
  $e.state = 'qa-passed'
  $e.updated = (Get-Stamp)
  $e.reject_reason = $null
  # The wave field is cleared with the rejection: the recipe is going back to the pool and will be
  # claimed by whichever wave closes next. Leaving the old number on it is how a slug reads as
  # "already claimed by an open wave" and never closes again.
  $e.wave = $null
  $e.history = @(@($e.history) + [pscustomobject]@{ state = 'qa-passed'; at = (Get-Stamp); by = $By; detail = $detail })
  Write-JsonAtomic -Path $sp -Obj $e
  Write-Output ("hunt-run: {0}  rejected-audit -> qa-passed  ({1})" -f $Slug, $detail)
  Write-GuardComplete -Name 'hunt-run' -Summary ("revive {0}" -f $Slug)
  exit 0
}

if ($runAdvance) {
  if (-not $Slug -or -not $To) { Write-Output 'hunt-run: -Advance needs -Slug and -To'; exit 1 }
  # BEFORE anything is read or written: a composite term must never reach a state file. See the
  # Find-CompositeTerms note above - a term row the queue cannot be keyed by parks the recipe forever.
  foreach ($bad in @(Find-CompositeTerms $Terms))         { Write-Output (Get-CompositeTermMessage 'Terms' $bad); exit 1 }
  foreach ($bad in @(Find-CompositeTerms $OptionalTerms)) { Write-Output (Get-CompositeTermMessage 'OptionalTerms' $bad); exit 1 }
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
  # THE CARRIAGE UNION. On the way into `pricing`, hunt-run derives the blocking list from the mapped
  # bids itself and unions it with the mapper's. A carriage-blocked ingredient is NEVER optional: a
  # garnish the store does not sell is still an ingredient nobody can buy.
  #
  # EXCEPT a line nobody buys at all, which is not the same thing and used to be treated as if it were.
  # `$cb.skipped` is what the two non-purchasable nets took out (see Get-CarriageBlockingTerms); those
  # terms are still WRITTEN BELOW, as optional rows, so the recipe records them and stops waiting on
  # them. Silently omitting them would trade one invisible failure for another.
  $derivedTerms = @(); $skippedTerms = @()
  if ($To -eq 'pricing') {
    $cb = Get-CarriageBlockingTerms -RunDir $RunDir -Slug $Slug -RepoRoot $repo
    $derivedTerms = @($cb.terms)
    $skippedTerms = @($cb.skipped)
    if (-not $cb.read) {
      Write-Output ("hunt-run: WARNING carriage not derived for {0} ({1}); relying on the mapper's -Terms alone" -f $Slug, $cb.why)
    } elseif ($derivedTerms.Count) {
      Write-Output ("hunt-run: carriage adds {0} blocking ingredient(s) the mapper did not report: {1}" -f $derivedTerms.Count, ($derivedTerms -join ', '))
    }
    foreach ($s in $skippedTerms) {
      Write-Output ("hunt-run: '{0}' does not block {1} - {2}" -f [string]$s.term, $Slug, [string]$s.why)
    }
  }
  if (@($Terms).Count -or @($OptionalTerms).Count -or $derivedTerms.Count -or $skippedTerms.Count) {
    $rows = @(); $seen = @{}
    foreach ($t in @($Terms) + @($derivedTerms) | Where-Object { $_ }) {
      $k = [string]$t; if ($seen.ContainsKey($k)) { continue }; $seen[$k] = $true
      $rows += [pscustomobject]@{ term = $k; optional = $false }
    }
    foreach ($t in @($OptionalTerms) | Where-Object { $_ }) {
      $k = [string]$t
      # a carriage-blocked term outranks an "optional" label from the mapper
      if ($seen.ContainsKey($k)) { continue }
      $seen[$k] = $true
      $rows += [pscustomobject]@{ term = $k; optional = $true }
    }
    # THE NON-PURCHASABLE ROWS LAND LAST, so a term that is genuinely blocking on one line can never be
    # demoted by a second line that happened to be ruled un-buyable. $seen already holds every blocking
    # term by this point, and blocking wins.
    foreach ($s in $skippedTerms) {
      $k = [string]$s.term
      if (-not $k -or $seen.ContainsKey($k)) { continue }
      $seen[$k] = $true
      $rows += [pscustomobject]@{ term = $k; optional = $true }
    }
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
  # THE RETROSPECTIVE HALF OF THE COMPOSITE-TERM GUARD. The -Advance guard closes the door; state files
  # written BEFORE it existed (older run dirs) still hold composite rows, and their failure mode is exactly
  # silence - the term is unknown to the queue, section 2.2 scores unknown as PENDING, and the recipe parks
  # on every -Derive with nothing distinguishing it from a genuinely unpriced one. -Derive is the reader of
  # term rows, so it is the place that can say so. It WARNS and still derives: the derivation is correct
  # for the rows it has, and refusing here would strand every other recipe in the run dir.
  $composite = @()
  foreach ($e in $entries) {
    foreach ($t in @($e.terms)) {
      if ([string]$t.term -and ([string]$t.term).Contains(',')) {
        $composite += [pscustomobject]@{ slug = [string]$e.slug; state = [string]$e.state; term = [string]$t.term }
      }
    }
  }
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
  if ($composite.Count) {
    Write-Output ''
    Write-Output ("  WARNING {0} COMPOSITE TERM ROW(S) - these can never match an ingredient-queue entry:" -f $composite.Count)
    foreach ($c in $composite) { Write-Output ("    {0,-34} [{1}]  '{2}'" -f $c.slug, $c.state, $c.term) }
    Write-Output  "           A comma inside one term row means it was passed as -Terms 'a,b' (ONE element to PowerShell)."
    Write-Output  '           Such a term is scored PENDING forever, so the recipe parks silently however well it priced.'
    Write-Output  "           Repair: re-advance the recipe with each term as its own quoted string (-Terms 'a','b')."
  }
  Write-GuardComplete -Name 'hunt-run' -Summary ("derive moved={0}" -f $moved); exit 0
}

# ---- -WaveClose -----------------------------------------------------------------------------------
if ($runWaveSync) {
  if ($Wave -le 0) { throw '-WaveSync needs -Wave <k>' }
  $dropped = @(Sync-WaveManifest $RunDir $Wave)
  if ($dropped.Count) {
    Write-Output ("hunt-run: wave {0} manifest reconciled - dropped {1} slug(s) the trim removed:" -f $Wave, $dropped.Count)
    $dropped | ForEach-Object { Write-Output "  - $_" }
  }
  else { Write-Output ("hunt-run: wave {0} manifest already matches state - nothing dropped" -f $Wave) }
  Write-GuardComplete 'hunt-run' ("wave-sync {0} dropped={1}" -f $Wave, $dropped.Count)
  exit 0
}

if ($runWaveClose) {
  $runDoc = Read-Json (Join-Path $RunDir 'run.json')
  $size = if ($WaveSize -gt 0 -and $PSBoundParameters.ContainsKey('WaveSize')) { $WaveSize } else { [int]$runDoc.wave_size }
  $entries = @(Read-Entries $RunDir)
  $claimed = Get-ClaimedSlugs $RunDir
  $ready = @(Select-WaveSlugs $entries $size $claimed)
  if (-not $ready.Count) {
    $waiting = @(@($entries) | Where-Object { [string]$_.state -eq 'qa-passed' })
    if ($waiting.Count) {
      Write-Output ("hunt-run: {0} qa-passed recipe(s) are waiting but ALL are already claimed by an open wave." -f $waiting.Count)
      Write-Output  '           They were trimmed out of that wave by an audit NO-GO and its manifest still lists them.'
      Write-Output  '           Run -WaveSync -Wave <k> to reconcile that manifest, then close again.'
      exit 1
    }
    Write-Output 'hunt-run: no qa-passed recipes waiting - nothing to close'; exit 1
  }
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
