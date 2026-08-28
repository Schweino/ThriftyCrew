# map-preresolve.ps1 - THE MECHANICAL HALF OF THE MAP STAGE (PLAN-recipe-hunter-v3 S4 / D7, 2026-08-24).
# ---------------------------------------------------------------------------------------------------
# Runs per micro-batch BEFORE the mapper agent is dispatched, and answers - from data already on disk,
# in one pass - every ingredient question that does not need judgment. What it cannot answer it
# ENUMERATES, so the mapper's dispatch carries the residual instead of the whole recipe.
#
# WHY. Map was 13.1% of a v2 run's tokens at 627 agent invocations, and the majority of what those
# invocations did was look things up: is this name in the vocabulary, is there a prior ruling, does the
# board carry it, is there a density. Every one of those is a file read. The agent's actual value is
# the residue - identity judgments, form flips, each-weight calls, label transcription, and the macro
# cross-check - and this script exists to hand it exactly that and nothing else.
#
# THE FOUR SURFACES IT COMPOSES, and it composes them, it never re-implements them:
#   * ingredient-resolutions.ps1  -Json         prior rulings (identity + whether a bid is wired)
#   * ingredient-vocab.ps1        -Missing -Json  exact/alias resolution AND the near-miss scoring
#   * price-ingredient.ps1        -Json         what the Omaha board actually carries, per term
#   * db\densities.json / db\each-nouns.json / food-macros-db.json   the arithmetic's prerequisites
# The vocabulary matcher in particular is NOT copied here. Its head-noun rule and its FORM_WORDS list
# are the reason "Dry White Wine" does not become "White Wine Vinegar", and a second copy of that
# judgment is the forked-taxonomy defect this estate already has scars from. ONE ingredient-vocab
# invocation classifies the whole batch through its -Missing road; this script reads the verdict.
#
# CONCURRENCY: NONE NEEDED, AND THAT IS DELIBERATE - SAY SO RATHER THAN LEAVE IT TO BE WONDERED AT.
# Every write this script makes is to <RunDir>\mapped-pre\<slug>.json, one file per slug, and the map
# lane runs at cap 2 over DISTINCT slugs. There is no shared file to race on, so there is no mutex.
# If any future version of this script aggregates into ONE file - a batch summary, a run-level index -
# that file takes ingredient-resolutions.ps1's named-system-mutex pattern WITH a concurrent-writers
# fixture PROVEN to fail with the lock removed (the fourth PS trap: source-domains' reference fixture
# passed with its own mutex neutered for a year, because the writers never overlapped).
#
# THE UNBID HOLD IS RECORDED HERE AND ENFORCED BY THE DAEMON. A line that resolves to a commodity with
# no bid wired in db\ingredients.json is a `unbid` row and lands in the file's `holds` list with a
# named follow-up. This script moves no state and dispatches nothing. The daemon reads `holds` and
# holds the recipe at `mapped` itself, because phase 3 measured what happens when the rule lives in a
# prompt instead: the same mapper, asked its own standing rule twice with the same prompt and model,
# answered ADVANCE once and HOLD once. A rule a model must remember is a rule it sometimes forgets.
#
#   .\map-preresolve.ps1 -RunDir <dir> -Slugs a,b,c      (the daemon calls it through hunt_lib.ps_invoke)
#   .\map-preresolve.ps1 -RunDir <dir> -Slugs a -Json    the tables on stdout as well as on disk
#   .\map-preresolve.ps1 -Assemble -RunDir <dir> -Slug a -RulingsFile <payload.json>
#   .\map-preresolve.ps1 -NewBids -RulingsFile <payload.json>       (JSON: the bids nothing wires yet)
#   .\map-preresolve.ps1 -SelfTest
#
# -Assemble: THE DAEMON HOLDS THE PEN ON mapped\<slug>.json (phase 6a, A1 / cold-read pins P2-P6).
# ---------------------------------------------------------------------------------------------------
# The mapper used to write that file itself, and on the phase-5 gate run it wrote the PRE-RESOLVE
# TABLE'S shape instead of the decision shape - `rows`/`residual_terms`/`resolution` where
# `ingredients[]` of {item, grams, decision} plus `protein` belonged. build-intake-skeleton.ps1 exited 1
# with "the mapper decision file names no mapped ingredient" over a recipe the live mapper had just
# settled cleanly. It was not carelessness: map_prompt said "the full decision file, every line,
# unchanged contract" without naming one field, and handed it a differently-shaped table as its input.
# Prose said unchanged, and the only mechanical check was a whole stage later.
#
# So the model no longer writes the file. It returns TWO COMPACT ARRAYS per slug and this mode
# assembles everything else mechanically:
#   `lines`   {raw, buy, notes, grams?} for EVERY purchasable line. The `buy` string cannot be
#             mechanised - "7 oz, room temperature (an 8 oz brick minus 2 tbsp)" is a judgment about
#             what a cook holds, and D8 LOCKS it into the intake, which is where the prose-number
#             defect died. `grams` is optional and states the TARGET weight when the buy string
#             quantizes away from the exact scale (measured on the v2 corpus: 2 of 7 lines).
#   `rulings` {raw, term, canon_item, bid, decision, grams, evidence} for the RESIDUAL lines only.
# Everything else - title, source_url, the servings block, the scale, the decisions for pre-resolved
# lines, the report blocks - falls out of the table, the extraction and the run state file.
#
# ONE WRITER PER SLUG FILE, SO NO MUTEX, AND THAT IS SAID HERE RATHER THAN LEFT TO BE WONDERED AT.
# -Assemble is called once per slug by the map lane, whose workers never share a slug, and it writes
# exactly mapped\<slug>.json. There is no shared file to race on. If any future version aggregates
# into one file, that file takes ingredient-resolutions.ps1's named-system-mutex pattern WITH a
# concurrent-writers fixture PROVEN to fail with the lock removed - the fourth PS trap.
#
# -Assemble EXIT CODES:
#   0  the file is written and every line is settled.
#   1  FINDINGS, and NOTHING IS WRITTEN. Half a decision file on disk is worse than none, because the
#      half that landed looks settled and D8 builds an intake over it. The daemon marks the recipe
#      STUCK and names the findings, which is a state a person can act on.
#   2  could not run: no table, no rulings file, unparseable input.
#
# EXIT CODES - section 4.5's v3 convention, read onto THIS script, and note that 1 is the NORMAL case:
#   0  every line of every slug pre-resolved. The mapper is STILL dispatched: the macro cross-check is
#      its job on every recipe, so a fully pre-resolved table shrinks that dispatch to the cross-check
#      alone. It never silently skips the judge.
#   1  residual lines exist (unresolved / different-form / new-food-suspect). The table is written and
#      the mapper dispatch PROCEEDS over the residual. This is what a healthy batch looks like.
#   2  could not run: a missing or unparseable extraction, a composed surface that would not answer.
#      The batch is BLOCKED and NOT dispatched. Could-not-look is never a clean bill, and it is never
#      a reason to guess either.
# `unbid` rows are HOLDS, not residual: the mapper is not asked about them, so they do not make exit 1
# on their own. The hold is the daemon's, and it applies after the mapper has ruled the rest.
# ---------------------------------------------------------------------------------------------------
param(
  [string]$RunDir = '',
  [string[]]$Slugs = @(),
  [switch]$Assemble,                # A1 / pin P5: build mapped\<slug>.json from the table + the rulings
  [switch]$NewBids,                 # A4: which bids in a rulings payload does the vocabulary NOT wire?
  [string]$Slug = '',               # -Assemble is per slug: ONE writer per file, so no mutex
  [string]$RulingsFile = '',        # the mapper's payload for that slug, written by the daemon
  [int]$TargetServings = 14,        # the house batch size; a parameter so a fixture can prove the scale
  [switch]$SelfTest,
  [switch]$Json,
  [switch]$NoBoard,                 # skip the price-ingredient pass (fixtures; the board is a big read)
  # test seams - every default points at the live estate, every fixture points somewhere scratch
  [string]$VocabFile = '', [string]$ResolutionsFile = '', [string]$DensitiesFile = '',
  [string]$EachNounsFile = '', [string]$FoodDbFile = '', [string]$PoolFile = '',
  [switch]$NoPrecheck                # skip the parse-compute cross-check (fixtures; it shells a child)
)
$ErrorActionPreference = 'Stop'
# COPY EVERY SWITCH INTO A PLAIN BOOL FIRST. A dot-sourced lib declaring its own [switch]$SelfTest
# resets ours in THIS scope - the PS 5.1 trap that made migrate-prose-tokens' first -SelfTest run
# execute the live path instead of its fixtures.
$runSelfTest = [bool]$SelfTest; $runJson = [bool]$Json; $runNoBoard = [bool]$NoBoard; $runNoPrecheck = [bool]$NoPrecheck
$runAssemble = [bool]$Assemble; $runNewBids = [bool]$NewBids

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here                      # ...\meal-prep
$repo = Split-Path -Parent $mp                        # ...\ThriftyCrew
$script:repoRoot = $repo
. (Join-Path $repo 'lib\guard-contract.ps1')

$script:VOCAB_PS   = Join-Path $here 'ingredient-vocab.ps1'
$script:RESOLVE_PS = Join-Path $here 'ingredient-resolutions.ps1'
$script:PRICE_PS   = Join-Path $repo 'grocery\price-ingredient.ps1'
$script:PARSE_COMPUTE_PS = Join-Path $here 'parse-compute.ps1'

if (-not $VocabFile)       { $VocabFile       = Join-Path $mp 'db\ingredients.json' }
if (-not $ResolutionsFile) { $ResolutionsFile = Join-Path $mp 'db\ingredient-resolutions.json' }
if (-not $DensitiesFile)   { $DensitiesFile   = Join-Path $mp 'db\densities.json' }
if (-not $EachNounsFile)   { $EachNounsFile   = Join-Path $mp 'db\each-nouns.json' }
if (-not $FoodDbFile)      { $FoodDbFile      = Join-Path $mp 'food-macros-db.json' }
if (-not $PoolFile)        { $PoolFile        = Join-Path $mp 'db\candidate-pool.json' }

# ---------------------------------------------------------------------------------------------------
# READING JSON IN PS 5.1, the two traps that have each cost this estate a whole feature.
#
# 1. Get-Content -Raw decodes with the ANSI codepage, which mangles every non-ASCII byte these files
#    carry. Read the bytes as UTF-8 explicitly.
# 2. ASSIGN FIRST, THEN WRAP. `@(<pipeline> | ConvertFrom-Json)` on a MANY-element array binds ONE
#    element of type Object[] - ConvertFrom-Json emits the whole array as a single pipeline object and
#    @() collects that one object. The estate's standing "wrap ConvertFrom-Json in @()" rule is only
#    the one-element half of the story and on a real file it is actively wrong: it cost both new
#    -BatchFile roads their entire batch, and it was invisible at batch size one.
# ---------------------------------------------------------------------------------------------------
function Read-Json {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return $null }
  $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) -replace '^\uFEFF', ''
  if (-not $text.Trim()) { return $null }
  return ($text | ConvertFrom-Json)
}
function As-Array {
  <#
    ASSIGN FIRST, THEN WRAP, THEN REFUSE TO BE UNROLLED. The third clause is a trap of its own and it
    cost this script a fixture on 2026-08-24: a PowerShell function that ends `return @($x)` UNROLLS a
    one-element array at the return boundary, so the caller gets the bare element. `.Count` on a bare
    PSCustomObject is $null in PS 5.1 - not 1, not an error - so `if ($c.Count)` reads FALSE and the
    branch quietly does not run. Here that silently dropped the vocabulary's near-miss candidates out
    of the evidence for every single-candidate line, which is exactly the "Dry White Wine ->
    White Wine Vinegar" evidence the mapper is meant to rule on. The comma operator returns the array
    itself. Same family as the three pinned collection traps: invisible at the sizes fixtures reach for
    first, and wrong in the direction of saying less than it knows.

    AND THE COMMA HAS A PRICE THE CALLER PAYS: an array returned this way enters a PIPELINE as ONE
    object, not as its elements. `As-Array $x | Where-Object {...}` hands Where-Object the whole array
    and filters a collection of one - measured here on 2026-08-24, where it made `uncovered_lines` come
    back empty on a table with eight uncovered lines, and made the cross-check's per-line qty string
    the space-joined qty of EVERY line at once. `foreach ($e in (As-Array $x))` is safe; a PIPE is not.
    PARENTHESISE the call: `(As-Array $x) | Where-Object`. And note that `@(As-Array $x) | ...` does
    NOT fix it - measured: @() around a command COLLECTS its output objects, so an array arriving as
    one output object becomes an array holding one array. Only the parentheses (or an assignment
    first) hand the pipeline the array itself, which the pipeline then unrolls.
  #>
  param($Value)
  if ($null -eq $Value) { return ,@() }
  $assigned = $Value
  return ,@($assigned)
}

function Get-CommodityIds {
  <#
    EVERY GROCERY COMMODITY ID THE ESTATE ALREADY KNOWS, across all THREE namespaces.

    CORRECTED 2026-08-24 BY THE PHASE-6A GATE DRILL, and the live mapper's own evidence is the
    measurement. The first build asked db\ingredients.json - the recipe VOCABULARY - whether a bid was
    "new", and refused `brown-lentils` as an unapproved new commodity id. It is nothing of the sort:
    it is a LIVE BOARD ID in grocery\commodities.json, priced at 5 of 7 stores, and what was actually
    missing was a vocabulary ROW pointing at it. The mapper said so in as many words and was right:
    "proposing 'brown-lentils' as new would have been precisely the duplicate-minting the 2026-08-16
    audit caught ten times over."

    THE TWO NAMESPACES ARE DIFFERENT QUESTIONS, and the commodity-registrar's own definition is
    explicit that they have different answers more often than not: "which existing NAME does this
    resolve to" is db\ingredients.json, and "which existing ID prices it" is these three files. The
    registrar gate is about the second. A missing vocabulary row is a real gap, but it is the mapper's
    to propose and it does not mint a commodity.

      1. grocery\commodities.json                the weekly staples catalog (588 ids)
      2. grocery\recipe-commodities.json         the recipe sale-overlay rule set, {commodities:[...]}
      3. grocery\out\recipe-board-everyday.json  the recipe-board baseline, {comparison:[...]} - its
                                                 row set is its OWN authority; some ids live nowhere else
  #>
  param([string]$Root)
  $ids = @{}
  function Add-Ids($rows) {
    foreach ($r in (As-Array $rows)) {
      if ($null -eq $r) { continue }
      $id = ''
      foreach ($f in @('id', 'bid', 'commodity_id')) {
        if ($r.PSObject.Properties.Name -contains $f -and $r.$f) { $id = [string]$r.$f; break }
      }
      if ($id) { $ids[$id] = $true }
    }
  }
  foreach ($rel in @('grocery\commodities.json', 'grocery\recipe-commodities.json',
                     'grocery\out\recipe-board-everyday.json')) {
    $path = Join-Path $Root $rel
    $doc = $null
    try { $doc = Read-Json $path } catch { $doc = $null }
    if ($null -eq $doc) { continue }
    # Three shapes on disk and all three are real: a bare array, {commodities:[...]}, {comparison:[...]}.
    if ($doc -is [array]) { Add-Ids $doc }
    else {
      foreach ($k in @('commodities', 'comparison', 'items', 'rows')) {
        if ($doc.PSObject.Properties.Name -contains $k) { Add-Ids $doc.$k }
      }
    }
  }
  return $ids
}

function Get-LeadingNumber {
  # "588" and "10g" and "about 51 g" are all the same claim; a null is a claim nobody made.
  param([string]$V)
  if (-not $V) { return $null }
  $m = [regex]::Match([string]$V, '-?\\d+(\\.\\d+)?')
  if (-not $m.Success) { return $null }
  return [double]$m.Value
}

function Get-TermKey {
  # ingredient-resolutions.ps1's own normalisation, and it must stay its own: the cache is keyed by
  # this function's output, so a second spelling of it is a cache that silently never hits. Kept
  # byte-identical and pinned by a fixture that asserts the two agree on the same strings.
  param([string]$T)
  if (-not $T) { return '' }
  $t = $T.ToLower().Trim()
  $t = $t -replace '[^a-z0-9 ]', ' '
  $t = $t -replace '\s+', ' '
  return $t.Trim()
}

# ---------------------------------------------------------------------------------------------------
# THE ROW CLASSIFIER. Pure: takes what each surface said about one ingredient line and returns the
# section 4.5 row. Pure on purpose - the classification is the part worth freezing in fixtures, and a
# classifier that had to open five files to be tested would be tested at the end of a drill or not at
# all.
#
#   resolved           a canon item, a wired bid. Nothing for the mapper.
#   unbid              a canon item, NO bid wired. A HOLD, not a mapper question.
#   different-form     the nearest rows share the head noun but differ on a FORM word. The mapper
#                      rules the flip; nothing here may quietly bridge it (the founding "Dry White
#                      Wine" -> "White Wine Vinegar" case).
#   new-food-suspect   nothing in the vocabulary shares a core word AND the food DB has no row. The
#                      mapper transcribes a label.
#   unresolved         everything else the mapper must identify.
# ---------------------------------------------------------------------------------------------------
function Get-Resolution {
  param(
    [string]$CanonItem,      # the vocabulary row's display name, or '' when nothing resolved
    [bool]$BidWired,
    [string]$VocabClass,     # RESOLVES | RENAME | DIFFERENT-FORM | GENUINE-GAP  (ingredient-vocab's)
    [bool]$FoodDbKnown
  )
  if ($CanonItem) {
    if ($BidWired) { return 'resolved' }
    return 'unbid'
  }
  if ($VocabClass -eq 'DIFFERENT-FORM') { return 'different-form' }
  if ($VocabClass -eq 'GENUINE-GAP' -and -not $FoodDbKnown) { return 'new-food-suspect' }
  return 'unresolved'
}

# Residual = what the MAPPER is being paid to rule. `unbid` is deliberately absent: it is the daemon's
# mechanical hold, and asking a model about it is what phase 3 measured flip-flopping.
$script:RESIDUAL_RESOLUTIONS = @('unresolved', 'different-form', 'new-food-suspect')
function Test-IsResidual { param([string]$Resolution) return ($script:RESIDUAL_RESOLUTIONS -contains $Resolution) }

function Get-HoldReason {
  param([string]$Term, [string]$CanonItem, [string]$Bid)
  # A hold with no name is a recipe that looks stuck. Name the thing that has to happen.
  $id = if ($Bid) { $Bid } else { '(no commodity id)' }
  return ("'{0}' resolves to {1} [{2}] but no bid is wired in db\ingredients.json - price it and wire the bid, then the next seed clears this hold with no agent" -f $Term, $CanonItem, $id)
}

# ---------------------------------------------------------------------------------------------------
# THE COMPOSED SURFACES. One invocation each PER BATCH, never per term: price-ingredient alone takes
# ~400 ms to load the board, and a 5-recipe micro-batch carries 40-plus terms.
# ---------------------------------------------------------------------------------------------------
function ConvertTo-PsArg {
  <# One value as PowerShell SOURCE. An array becomes a real array literal, which is the whole point. #>
  param($V)
  if ($null -eq $V) { return "''" }
  if ($V -is [array]) {
    $els = @(@($V) | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" })
    return '@(' + ($els -join ',') + ')'
  }
  return "'" + ([string]$V).Replace("'", "''") + "'"
}

function Invoke-Child {
  <#
    A child, not a dot-source: every file this composes has a param block and top-level code, so
    dot-sourcing them would RUN them (and clobber our own switches on the way through).

    AND IT IS THE -Command ROAD, NOT -File, FOR THE SAME REASON hunt_lib.ps_invoke IS. MEASURED HERE
    ON 2026-08-24, by this script's own fixtures: the first build used
    `powershell -File <script> -Slugs clean nosuchslug`, and the child bound ONE slug. The missing
    extraction it was supposed to be BLOCKED on was never looked for, so the drill that asserts exit 2
    got a cheerful exit 0 and a table on disk for half the batch. That is the `-Slugs a,b` /
    `-Terms 'a,b'` family exactly, one level down, and it is why this estate has one marshalling road
    per language rather than two per caller. Array values go in as nested arrays and come out as PS
    array literals.
  #>
  param([string]$Script, $ChildArgs)
  $parts = New-Object System.Collections.Generic.List[string]
  $parts.Add('&') | Out-Null
  $parts.Add((ConvertTo-PsArg $Script)) | Out-Null
  foreach ($a in @($ChildArgs)) {
    if ($a -is [string] -and $a.StartsWith('-') -and $a -notmatch '\s') { $parts.Add([string]$a) | Out-Null }
    else { $parts.Add((ConvertTo-PsArg $a)) | Out-Null }
  }
  $cmd = ($parts.ToArray() -join ' ') + '; exit $LASTEXITCODE'
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1
  $rc = $LASTEXITCODE
  $text = (@($out | ForEach-Object { [string]$_ }) -join "`n")
  return [pscustomobject]@{ rc = $rc; text = $text }
}

function Get-CompositePython {
  # The Windows Store python.exe on PATH is a stub that exits 49 without running anything, so the
  # interpreter is always an absolute resolved path - the same list rebid-ingredient.ps1 uses.
  foreach ($c in @('C:\Codex\Python312\python.exe',
                   "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
                   'C:\Program Files\Python312\python.exe')) {
    if (Test-Path $c) { return $c }
  }
  return $null
}

function Get-CompositeSplits {
  <#
    ONE coverage_check --split-terms call for every distinct term in the batch, and it belongs in this
    block for the same reason the vocabulary and board calls do: it is a composed surface, asked once.

    WHAT IT ANSWERS. Which of these terms name MORE THAN ONE FOOD. "Salt and Pepper" is two foods on
    one line and the food DB can never carry a row for it - that is not a lookup that failed, it is a
    question with no answer, and on run hunt-2026-08-26-ten it took two recipes STUCK at the write
    lane and parked four more one lane earlier waiting on a commodity id no single id can be.

    THE RULE IS NOT IMPLEMENTED HERE. coverage_check.py owns the head-noun scoring this turns on and
    has since 2026-08-23; a PowerShell reimplementation of it would be the forked-taxonomy defect
    this file's own header warns about, one function further down.

    NOT A GATE. A split that cannot be asked for - no interpreter, a child that fails - leaves every
    term whole, which is exactly today's behaviour. The batch says so and carries on.
  #>
  param($Terms, $ResolvedWhole, $Names)
  $out = @{}
  $py = Get-CompositePython
  if (-not $py) { return @{ splits = $out; why = 'no python interpreter at C:\Codex\Python312' } }
  $script = Join-Path $here 'coverage_check.py'
  if (-not (Test-Path $script)) { return @{ splits = $out; why = 'no coverage_check.py beside this script' } }
  $req = @{ terms = @($Terms); resolved = @($ResolvedWhole); names = @($Names) } | ConvertTo-Json -Depth 4 -Compress
  try {
    $txt = $req | & $py $script --split-terms 2>&1
    $text = (@($txt | ForEach-Object { [string]$_ }) -join "`n").Trim()
    $line = @($text -split "`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)[0]
    if (-not $line) { return @{ splits = $out; why = ("the splitter printed no JSON: {0}" -f $text.Substring(0, [Math]::Min(160, $text.Length))) } }
    $doc = $line | ConvertFrom-Json
    if (-not $doc.ok) { return @{ splits = $out; why = [string]$doc.why } }
    if ($doc.parts) {
      foreach ($prop in $doc.parts.PSObject.Properties) { $out[[string]$prop.Name] = @($prop.Value | ForEach-Object { [string]$_ }) }
    }
    return @{ splits = $out; why = '' }
  } catch {
    return @{ splits = $out; why = ("the splitter would not run: {0}" -f $_.Exception.Message) }
  }
}

function Get-StatedMassGrams {
  <#
    THE MASS A RAW INGREDIENT LINE STATES ABOUT ITSELF, in grams, or $null if it states none.

    Used to demote the quantity engine's number where the engine plainly did not read the line: on
    "2 medium 1.5 lbs. chicken breasts" it takes the count and the each-noun and makes 400 g, while
    the line says 1.5 lbs. See the call site in -Assemble for why that demotion, and not a change to
    parse-compute's tokenizer, is the safe fix.

    DELIBERATELY CONSERVATIVE. It reads the FIRST mass token it finds and nothing cleverer: no
    ranges, no addition, no "plus more for serving". Anything it cannot read confidently is $null,
    which leaves today's behaviour exactly as it was - this function can only ever demote a number,
    never invent one.
  #>
  param([string]$Raw)
  if (-not $Raw) { return $null }
  # [\s-]* NOT \s* : a page writes "1 (14.5-ounce) can diced tomatoes", and the hyphen between the
  # number and the unit made this refuse a mass that is plainly stated. Its Python twin,
  # coverage_check.stated_mass_grams, carries the identical change - see the note in the self-test.
  if ($Raw -notmatch '(?<n>\d+(?:\.\d+)?(?:\s*/\s*\d+)?)[\s-]*(?<u>lbs?\.?|pounds?|ozs?\.?|ounces?|kg|kilograms?|grams?|g)\b') { return $null }
  $n = $Matches['n']; $u = ($Matches['u'] -replace '\.', '').ToLower()
  $val = $null
  if ($n -match '^\s*(\d+(?:\.\d+)?)\s*/\s*(\d+(?:\.\d+)?)\s*$') {
    $den = [double]$Matches[2]
    if ($den -ne 0) { $val = [double]$Matches[1] / $den }
  } else {
    try { $val = [double]$n } catch { $val = $null }
  }
  if ($null -eq $val -or $val -le 0) { return $null }
  switch -regex ($u) {
    '^(lbs?|pounds?)$'  { return $val * 453.592 }
    '^(ozs?|ounces?)$'  { return $val * 28.3495 }
    '^(kg|kilograms?)$' { return $val * 1000 }
    '^(grams?|g)$'      { return $val }
  }
  return $null
}

function Get-EngineWeightGuessReason {
  <#
    IS THE ENGINE'S WEIGHT FOR THIS LINE A GUESS? Returns the reason when yes, $null when no. This is
    the ONE question the cross-check turns on, and it has two roads:

      1. parse-compute's own admission - `grams_basis_fallback` - default tbsp, default tsp, a
         handful with no density. B2, 2026-08-24.
      2. a count/each number on a line that STATES its own mass, which the engine never flagged
         because it does not know it missed anything. 2026-08-27.

    BOTH ROADS LIVE HERE ON PURPOSE. The stated-mass road was first wired straight into the call site
    with the decision inline, and a neuter that reverted that one line left every fixture green -
    twice in two days, in two different files, the wiring was the part nothing covered. Folding both
    roads into the single function the cross-check must call removes the wiring: there is no longer a
    line to revert that does not also take road 1 - which older fixtures already depend on - with it.
  #>
  param($Row, [string]$Raw)
  if ($null -eq $Row) { return $null }
  if ($Row.PSObject.Properties.Name -contains 'grams_basis_fallback' -and $Row.grams_basis_fallback) {
    return [string]$Row.grams_basis_fallback
  }
  $basis = $null
  if ($Row.PSObject.Properties.Name -contains 'grams_source_basis') { $basis = $Row.grams_source_basis }
  return (Test-EngineIgnoredStatedMass $Raw $basis)
}

function Test-EngineIgnoredStatedMass {
  <#
    SHOULD THE ENGINE'S WEIGHT FOR THIS LINE BE DEMOTED TO A GUESS? Returns the reason string when
    yes, $null when no.

    THIS IS A SEPARATE FUNCTION BECAUSE THE PARSER ALONE IS NOT THE BEHAVIOUR. The first version of
    this fix left the decision inline at the call site and fixtured only Get-StatedMassGrams; a
    neuter that reverted the call site left every fixture green, which is a fixture testing a helper
    nobody has to call. Same lesson the daemon's conditions wiring taught the day before, in a
    different file. The decision lives here so a fixture can reach it.

    THE RULE: the line states a mass, the engine landed materially away from it, so the engine did
    not read the line. Ratio band matches the cross-check's own 1.5x / 0.667x, because the two are
    answering the same question about the same pair of numbers.
  #>
  param([string]$Raw, $EngineGrams)
  if ($null -eq $EngineGrams) { return $null }
  $eng = 0.0
  try { $eng = [double]$EngineGrams } catch { return $null }
  if ($eng -le 0) { return $null }
  $stated = Get-StatedMassGrams $Raw
  if ($null -eq $stated -or $stated -lt 1) { return $null }
  $r = $eng / $stated
  if ($r -le 1.5 -and $r -ge 0.667) { return $null }
  return ("count/each guess of {0} g against a line stating {1} g - the engine did not read the stated weight" -f [int]$eng, [int]$stated)
}

function Split-ExtractionComposites {
  <#
    Rewrite one extraction's ingredient list so a line naming two foods becomes two lines.

    THE RAW LINE IS THE JOIN KEY EVERYWHERE DOWNSTREAM - the grams snapshot is keyed by it, and so are
    both of the mapper payload's arrays - so the parts CANNOT share one. Each part carries the source's
    own line with the part named after it, which keeps the key unique, keeps the provenance readable,
    and makes the grams snapshot MISS on purpose: nobody can apportion "Pinch salt and pepper" between
    two foods without a ruling, and a shared gram figure copied onto both parts would put the whole
    line's weight into the batch twice. A part with no grams is a residual line the mapper weighs,
    which is the road that already exists for every line the engine cannot ground.

    `item_split_from` records the original term so a person reading the table sees what happened.
  #>
  param($Extraction, $Splits)
  if (-not $Splits -or $Splits.Count -eq 0) { return @{ changed = 0; notes = @() } }
  $outIngs = New-Object System.Collections.Generic.List[object]
  $notes = New-Object System.Collections.Generic.List[string]
  $changed = 0
  foreach ($ing in (As-Array $Extraction.ingredients)) {
    $t = [string]$ing.item; if (-not $t) { $t = [string]$ing.raw }
    if (-not ($t -and $Splits.ContainsKey($t))) { $outIngs.Add($ing) | Out-Null; continue }
    $parts = @($Splits[$t])
    foreach ($part in $parts) {
      $clone = [pscustomobject]@{}
      foreach ($prop in $ing.PSObject.Properties) {
        $clone | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
      }
      $clone | Add-Member -NotePropertyName 'item' -NotePropertyValue $part -Force
      $clone | Add-Member -NotePropertyName 'raw' -NotePropertyValue (("{0} [split: {1}]" -f [string]$ing.raw, $part)) -Force
      $clone | Add-Member -NotePropertyName 'item_split_from' -NotePropertyValue $t -Force
      $clone | Add-Member -NotePropertyName 'raw_split_from' -NotePropertyValue ([string]$ing.raw) -Force
      $outIngs.Add($clone) | Out-Null
    }
    $changed++
    $notes.Add(("'{0}' names {1} foods on one line and was split into {2} - a composite can never have one food-DB row or one commodity id" -f $t, $parts.Count, ($parts -join ' + '))) | Out-Null
  }
  if ($changed -gt 0) {
    $Extraction | Add-Member -NotePropertyName 'ingredients' -NotePropertyValue ($outIngs.ToArray()) -Force
  }
  return @{ changed = $changed; notes = @($notes.ToArray()) }
}

function Get-VocabClassification {
  <# ONE ingredient-vocab -Missing call for every distinct term in the batch. Returns a hashtable
     term -> {class, resolves_to, candidates}. Its -Missing road is the bulk classifier and it is the
     ONLY place the head-noun / form-word scoring lives. #>
  param([string[]]$Terms, [string]$VocabPath)
  $map = @{}
  $names = @($Terms | Where-Object { $_ } | Select-Object -Unique)
  if (-not $names.Count) { return $map }
  $tmp = Join-Path $env:TEMP ('mpre-terms-' + [guid]::NewGuid().ToString('N') + '.txt')
  try {
    Set-Content -Path $tmp -Value $names -Encoding utf8
    $childArgs = @('-Missing', $tmp, '-Json')
    if ($VocabPath) { $childArgs += @('-VocabFile', $VocabPath) }
    $r = Invoke-Child $script:VOCAB_PS $childArgs
    if ($r.rc -ne 0) { throw ("ingredient-vocab -Missing exited {0}: {1}" -f $r.rc, $r.text.Trim()) }
    $parsed = $r.text | ConvertFrom-Json
    $rows = As-Array $parsed.results
    foreach ($row in $rows) { $map[[string]$row.name] = $row }
    return $map
  } finally { if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } }
}

function Get-BoardAnswers {
  <# ONE price-ingredient call for every distinct term. Returns term -> the result row. #>
  param([string[]]$Terms)
  $map = @{}
  $names = @($Terms | Where-Object { $_ } | Select-Object -Unique)
  if (-not $names.Count) { return $map }
  $r = Invoke-Child $script:PRICE_PS @('-Name', $names, '-Json')
  if ($r.rc -ne 0) { throw ("price-ingredient exited {0}: {1}" -f $r.rc, $r.text.Trim()) }
  $parsed = $r.text | ConvertFrom-Json
  $rows = As-Array $parsed.results
  foreach ($row in $rows) { $map[[string]$row.term] = $row }
  return $map
}

function Get-ResolutionCache {
  <# The prior-rulings ledger, whole, in one read. -Json on the bare path prints count+resolutions. #>
  param([string]$Path)
  $map = @{}
  $doc = Read-Json $Path
  if (-not $doc) { return $map }
  $rows = As-Array $doc.resolutions
  foreach ($row in $rows) { $map[[string]$row.key] = $row }
  return $map
}

# ---------------------------------------------------------------------------------------------------
# THE PER-SLUG PASS
# ---------------------------------------------------------------------------------------------------
function New-PreResolveTable {
  <#
    Builds one slug's section 4.5 table. Pure over the four already-read lookups, so the whole classification
    is fixturable without touching the estate.
      $Extraction  the extracted\<slug>.json object
      $Vocab       rows of db\ingredients.json (item, bid, unit, board, gpu, aliases)
      $Classes     term -> ingredient-vocab -Missing row
      $BoardAnswers term -> price-ingredient result row (or an empty hashtable under -NoBoard)
      $Cache       term key -> ingredient-resolutions row
      $Dens/$Each/$FoodDb   name sets
  #>
  # $BoardAnswers, NOT $Board. PowerShell variable names are CASE-INSENSITIVE, and this function
  # holds a per-row `$board` (the vocabulary row's board class). As `$Board` the two were ONE variable:
  # the parameter became a string on the first ingredient line and `.ContainsKey` threw on the second.
  # Third instance of this family in this estate - $script:REJECTED clobbered by a local $rejected in
  # hunt-run.ps1, and the $ppg/$ppG 250,000x engine bug. Give a parameter a name no local would take.
  param([string]$Slug, $Extraction, $Vocab, $Classes, $BoardAnswers, $Cache, $Dens, $Each, $FoodDb)

  # Exact and alias resolution is a dictionary lookup, and both build-v2-spec and ingredient-vocab
  # already do it independently. The NEAR-MISS SCORING is the part that must never fork, and that
  # comes from $Classes - ingredient-vocab's own verdict.
  $byItem = @{}; $byAlias = @{}; $byBid = @{}
  foreach ($v in (As-Array $Vocab)) {
    if (-not $v.item) { continue }
    $byItem[[string]$v.item] = $v
    if ($v.bid) { $byBid[[string]$v.bid] = $v }
    if ($v.PSObject.Properties.Name -contains 'aliases') {
      foreach ($a in (As-Array $v.aliases)) { if ($a) { $byAlias[[string]$a] = $v } }
    }
  }

  $rows     = New-Object System.Collections.Generic.List[object]
  $holds    = New-Object System.Collections.Generic.List[object]
  $residual = New-Object System.Collections.Generic.List[object]

  foreach ($ing in (As-Array $Extraction.ingredients)) {
    $raw  = [string]$ing.raw
    $term = [string]$ing.item
    if (-not $term) { $term = $raw }

    $canon = ''; $bid = ''; $rowBoard = ''; $src = ''
    $evidence = New-Object System.Collections.Generic.List[string]

    # 1. THE PRIOR RULING FIRST. It is the cheapest answer and the one the estate paid an agent for.
    $key = Get-TermKey $term
    $hit = $null
    if ($key -and $Cache.ContainsKey($key)) { $hit = $Cache[$key] }
    if ($hit -and $hit.item_id) {
      $src = 'cache'
      $bid = [string]$hit.item_id
      if ($byBid.ContainsKey($bid)) {
        $row = $byBid[$bid]
        $canon = [string]$row.item
        $rowBoard = [string]$row.board
      }
      $evidence.Add(("prior ruling: '{0}' -> {1} (by {2} on {3})" -f $key, $bid, $hit.by, $hit.at))
    }

    # 2. THE VOCABULARY, exact then adjudicated alias. Never a near match - every bridge is a ruling.
    if (-not $canon) {
      if ($byItem.ContainsKey($term)) {
        $row = $byItem[$term]; $canon = [string]$row.item; $bid = [string]$row.bid
        $rowBoard = [string]$row.board; $src = 'vocab'
        $evidence.Add("exact vocabulary row")
      } elseif ($byAlias.ContainsKey($term)) {
        $row = $byAlias[$term]; $canon = [string]$row.item; $bid = [string]$row.bid
        $rowBoard = [string]$row.board; $src = 'alias'
        $evidence.Add(("adjudicated alias -> '{0}'" -f $canon))
      }
    }

    # 3. WHAT INGREDIENT-VOCAB MADE OF IT. Its class carries the near-miss judgment we do not fork.
    $cls = ''
    if ($Classes.ContainsKey($term)) {
      $c = $Classes[$term]
      $cls = [string]$c.class
      $cands = As-Array $c.candidates
      if ($cands.Count) {
        $shown = @($cands | Select-Object -First 3 | ForEach-Object {
          $flag = if ($_.different_form) { 'DIFFERENT FORM: ' + (((As-Array $_.form_diff) | Select-Object -First 3) -join '/') } else { 'same form' }
          ("{0} [{1}] {2}" -f $_.item, $_.bid, $flag) })
        $evidence.Add("nearest vocabulary rows: " + ($shown -join ' | '))
      } elseif ($cls -eq 'GENUINE-GAP') {
        $evidence.Add("no vocabulary row shares a core word with this name")
      }
    }

    # 4. IS A BID ACTUALLY WIRED. This is a fact about db\ingredients.json, never about a price.
    $bidWired = $false
    if ($canon -and $byItem.ContainsKey($canon)) { $bidWired = [bool]([string]$byItem[$canon].bid) }
    elseif ($bid -and $byBid.ContainsKey($bid))  { $bidWired = $true }
    if ($canon -and -not $bidWired) { $evidence.Add("NO BID wired for this row") }
    if ($src -eq 'cache' -and -not $canon) {
      $evidence.Add(("commodity id '{0}' has no row in db\ingredients.json yet" -f $bid))
    }

    # 5. THE ARITHMETIC'S PREREQUISITES. Each is a plain "is the row there", and each absence is a
    #    thing the mapper is being asked to supply rather than a thing it has to go and discover.
    $lookup       = if ($canon) { $canon } else { $term }
    $densityKnown = [bool]($Dens.ContainsKey($lookup))
    $eachKnown    = [bool]($Each.ContainsKey($lookup))
    $foodDbKnown  = [bool]($FoodDb.ContainsKey($lookup))
    $gpuKnown     = $false
    if ($canon -and $byItem.ContainsKey($canon)) {
      $g = $byItem[$canon].gpu
      $gpuKnown = ($null -ne $g -and [double]$g -gt 0)
    }
    if (-not $densityKnown -and -not $eachKnown) { $evidence.Add("no densities.json row and no each-noun") }
    if (-not $foodDbKnown) {
      $evidence.Add("no food-macros-db row - a label needs transcribing")
      # ...AND THE CANDIDATE ROWS FDC ALREADY HAS FOR IT, so the mapper does not go and fetch a page.
      # This is the line the 9-10 WebFetches per singleton dispatch hang off: each fetched page then
      # rides in the mapper's conversation for every later round trip, which is the quadratic term
      # measured on 6b. The cache is filled mechanically by fdc_lookup and holds CANDIDATES only -
      # picking which row is the food stays frontier, and the live probe showed why (FDC's top hit for
      # "chicken drumstick" is "Chicken, skin (drumsticks and thighs)" at 440 cal, which is skin).
      $fdc = Get-FdcCandidates $lookup
      # WORDED AS A SHELF, NOT AN ANSWER, and the wording is load-bearing. FDC's search is keyword
      # based, so for some terms every candidate is wrong while LOOKING authoritative: "cinnamon"
      # returns Bread / Muffins / Bagels and "unsalted butter" returns Pretzels / Popcorn, all of them
      # real SR Legacy rows with real numbers and none of them the food. Meanwhile "parsley" returns
      # fresh, freeze-dried and dried spice, which is a genuinely useful shelf. Telling the two apart
      # is an identity call - section 1.4 puts those with the mapper at 37% false locally - so this
      # hands over the rows and says plainly that NONE of them may be right.
      if ($fdc) {
        $evidence.Add("USDA FDC rows that MENTION this term, per 100 g - a shelf, not an answer. " +
                      "FDC matches on keywords, so all of these can be the wrong food: pick the one " +
                      "that IS this ingredient, or none of them and transcribe a label instead. " + $fdc)
      }
    }

    # 6. THE BOARD. What Omaha actually carries, from data the daily pipeline already wrote.
    if ($BoardAnswers.ContainsKey($lookup)) {
      $b = $BoardAnswers[$lookup]
      $evidence.Add(("board {0}: {1}" -f [string]$b.tier,
        $(if ($b.tier -eq 'MAPPED') { ("{0}, {1}, cheapest {2} at {3}" -f $b.commodity, $b.coverage, $b.cheapest, $b.cheapest_store) }
          elseif ($b.tier -eq 'CAPTURE') { "no commodity claims it; today's captures carry matching products" }
          else { "no commodity and no capture match" })))
    }

    $resolution = Get-Resolution $canon $bidWired $cls $foodDbKnown

    $row = [pscustomobject]@{
      raw           = $raw
      term          = $term
      canon_item    = $(if ($canon) { $canon } else { $null })
      bid           = $(if ($bid) { $bid } else { $null })
      board         = $(if ($rowBoard) { $rowBoard } else { $null })
      resolution    = $resolution
      gpu_known     = $gpuKnown
      density_known = ($densityKnown -or $eachKnown)
      fooddb_known  = $foodDbKnown
      evidence      = ($evidence -join '; ')
      source        = $(if ($src) { $src } else { $null })
      optional      = [bool]$ing.optional
      # Set when this row came out of a COMPOSITE line ("Salt and Pepper" -> Salt, Pepper). It is the
      # only place a reader of the table can see that one source line became two.
      #
      # THIS COMMENT USED TO CLAIM "and the mapper is told the same thing in the residual block so it
      # rules on the part, never on the pair." THAT WAS NOT TRUE OF ANY BLOCK, and was not true on the
      # day it was written: `grep -n item_split_from hunt-daemon.py` returned nothing, so the only
      # trace a mapper ever saw of a split was the `[split: <food>]` suffix inside the raw string,
      # which no prompt defined. On 2026-08-27 the mapper duly answered the PAIR once, keyed on the
      # source's unsplit raw with a combined buy string, and both parts lost their buy strings and
      # stuck the recipe at the map lane. A comment asserting a contract on another file's behalf is
      # how that hid: it reads as a guarantee and nothing checks it.
      # It is true NOW, and here is where to check it: hunt-daemon.py's map_prompt renders this field
      # on both the settled and the residual road and states the contract in its job description, and
      # hunt_daemon_selftest.py's `_split_lines_are_explained_to_the_mapper` fails if either stops.
      item_split_from = $(if ($ing.PSObject.Properties.Name -contains 'item_split_from') { [string]$ing.item_split_from } else { $null })
      # SOURCE-BASIS GRAMS (ADDED 2026-08-24, A-package / pin P3). Null here and filled in by the live
      # path from parse-compute's own per-line snapshot, because the arithmetic runs once per BATCH and
      # this function is pure over four lookups. Null means "the engine could not weigh this line",
      # which for a purchasable line is a STUCK at assembly - never a silent zero. A zero-gram line is
      # an ingredient the reader buys and the card ignores, which is the fabricated-band defect from
      # D8's own header, one stage upstream.
      grams_source_basis = $null
    }
    $rows.Add($row) | Out-Null
    if ($resolution -eq 'unbid') {
      $holds.Add([pscustomobject]@{ term = $term; canon_item = $canon; bid = $bid
                                    why = (Get-HoldReason $term $canon $bid) }) | Out-Null
    }
    if (Test-IsResidual $resolution) { $residual.Add($row) | Out-Null }
  }

  # .ToArray() rather than @($list): @() over a List[object] of dictionaries throws "Argument types do
  # not match" in PS 5.1 - the second of the three traps wave-preaudit shipped with on day one.
  $rowArr = $rows.ToArray()
  $holdArr = $holds.ToArray()
  $resArr = $residual.ToArray()
  return [pscustomobject]@{
    slug          = $Slug
    title         = [string]$Extraction.title
    source_url    = [string]$Extraction.source_url
    servings      = $Extraction.servings
    built_at      = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    line_count    = $rowArr.Count
    resolved_count = @($rowArr | Where-Object { $_.resolution -eq 'resolved' }).Count
    residual_count = $resArr.Count
    hold_count    = $holdArr.Count
    residual_terms = @($resArr | ForEach-Object { [string]$_.term })
    holds         = $holdArr
    rows          = $rowArr
  }
}

# ---------------------------------------------------------------------------------------------------
# THE MACRO CROSS-CHECK (S4: "fed the arithmetic pre-computed ... so it verifies rather than derives")
#
# The mapper's one remaining per-recipe judgment on EVERY recipe, cross-check included, is whether this
# dish's macros read like the dish the page describes. v2 asked it to derive that: read the lines, guess
# the grams, look up the foods, do the arithmetic, then compare. Every step of that is mechanical except
# the last one, and the mechanical steps are where a model's arithmetic drifts.
#
# So the arithmetic runs HERE, in parse-compute.ps1 - the estate's ONE qty-string-to-grams engine, the
# one with the fraction-safe metric, the container rule, the cooked-to-dry table and 89/100 measured
# parity against r100. It is not re-implemented, not approximated, and not asked for: it is invoked.
# The numbers travel in the mapper's dispatch PROMPT as pre-computed inputs to verify, which is why
# they are NOT a new schema field - the two named deltas in section 4.5 stay the only two.
#
# WHAT IT CAN AND CANNOT REACH, said plainly rather than papered over. parse-compute needs a CANON name
# per line, so the arithmetic covers exactly the lines this script pre-resolved. `lines_covered` and
# `lines_total` travel with the numbers, because a per-serving figure computed over 9 of 17 lines is a
# different claim from one computed over all 17 and must never read as the same claim.
#
# SCRATCH DIR PER INVOCATION, and that is the concurrency answer. parse-compute writes
# recipes-computed.json and flags-report.txt into whatever RunDir it is handed; the map lane runs 2
# workers, so a shared _precheck folder under the run dir would be exactly the single shared file this
# script's header says it does not have. A GUID temp dir per invocation keeps that true.
# ---------------------------------------------------------------------------------------------------
function Get-SourceMacros {
  <# What the SOURCE published per serving, from whichever surface actually has it. Two shapes exist on
     disk and both are real: a v2 extraction carries `nutrition_per_serving` (strings, "10g"), and a v3
     candidate carries the harvester's `band` block (numbers). Neither is guessed and neither is
     derived - if nobody published macros for this dish, that is what it says, because "the page did
     not say" and "we did not look" must never be the same bytes. #>
  param($Extraction, $PoolRow)
  $n = $Extraction.nutrition_per_serving
  if ($n) {
    return [pscustomobject]@{
      from      = 'extraction.nutrition_per_serving'
      cal       = (Get-LeadingNumber ([string]$n.calories))
      carbs     = (Get-LeadingNumber ([string]$n.carbohydrates))
      protein_g = (Get-LeadingNumber ([string]$n.protein))
      fat_g     = (Get-LeadingNumber ([string]$n.fat))
    }
  }
  if ($PoolRow -and $PoolRow.band) {
    return [pscustomobject]@{
      from = 'candidate-pool.band'; cal = $PoolRow.band.cal; carbs = $PoolRow.band.carbs
      protein_g = $PoolRow.band.protein_g; fat_g = $null
    }
  }
  return [pscustomobject]@{ from = 'none published'; cal = $null; carbs = $null; protein_g = $null; fat_g = $null }
}

function Get-MacroPrecheck {
  <# One parse-compute run over the whole batch's pre-resolved lines. Returns slug -> the precheck block.
     A failure here is a FINDING carried into the dispatch, never a blocked batch and never a fabricated
     number: the mapper is told the arithmetic was unavailable and rules with that in hand. #>
  param($Tables, $Extractions, $PoolRows)
  $out = @{}
  $grams = @{}          # slug -> (raw -> source-basis grams). A-package / pin P3.
  $basis = @{}          # slug -> (raw -> the engine's fallback flag) for lines it could NOT ground
  $rawOrder = @{}       # slug -> the raw strings, in the order they were handed to the engine
  $rows = New-Object System.Collections.Generic.List[object]
  $covered = @{}
  foreach ($t in @($Tables)) {
    $slug = [string]$t.slug
    $src = $Extractions[$slug]
    $ings = New-Object System.Collections.Generic.List[object]
    $order = New-Object System.Collections.Generic.List[string]
    foreach ($r in (As-Array $t.rows)) {
      if (-not $r.canon_item) { continue }
      $line = @((As-Array $src.ingredients) | Where-Object { [string]$_.raw -eq [string]$r.raw })[0]
      $qty = ''
      if ($line) { $qty = ((@([string]$line.qty, [string]$line.unit) | Where-Object { $_ }) -join ' ').Trim() }
      $ings.Add([pscustomobject]@{ canon = [string]$r.canon_item; is_new = $false
                                   sources = @([pscustomobject]@{ item = [string]$r.term; qty = $qty }) }) | Out-Null
      $order.Add([string]$r.raw) | Out-Null
    }
    $covered[$slug] = $ings.Count
    $rawOrder[$slug] = $order.ToArray()
    $grams[$slug] = @{}
    $basis[$slug] = @{}
    $pool = $null
    if ($PoolRows.ContainsKey($slug)) { $pool = $PoolRows[$slug] }
    $out[$slug] = [pscustomobject]@{
      state = 'unavailable'; reason = 'no pre-resolved line carried a canon name to compute over'
      source = (Get-SourceMacros $src $pool)
      lines_covered = [int]$ings.Count; lines_total = [int]$t.line_count
      uncovered_lines = @((As-Array $t.rows) | Where-Object { -not $_.canon_item } | ForEach-Object { [string]$_.term })
      computed_per_serving = $null; portion_factor = $null; tuning = @(); missing_db_items = @() }
    if (-not $ings.Count) { continue }
    $rows.Add([pscustomobject]@{
      proposed_name = $slug           # KEYED BY SLUG: parse-compute keys its overrides on proposed_name
      slug = $slug; protein = 'any'; cuisine = ''; format = ''
      source_url = [string]$t.source_url; source_site = ''
      source_servings = $(if ($t.servings) { [double]$t.servings } else { 4 })
      ingredients = $ings.ToArray() }) | Out-Null
  }
  $rowArr = $rows.ToArray()
  if (-not $rowArr.Count) { return [pscustomobject]@{ precheck = $out; grams = $grams; basis = $basis } }

  $scratch = Join-Path $env:TEMP ('mpre-pc-' + [guid]::NewGuid().ToString('N'))
  try {
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null
    ($rowArr | ConvertTo-Json -Depth 8) | Set-Content -Path (Join-Path $scratch 'recipes-canon.json') -Encoding utf8
    $r = Invoke-Child $script:PARSE_COMPUTE_PS @('-RunDir', $scratch)
    if ($r.rc -ne 0) {
      foreach ($k in @($out.Keys)) { $out[$k].reason = ("parse-compute exited {0}: {1}" -f $r.rc, $r.text.Trim()) }
      return [pscustomobject]@{ precheck = $out; grams = $grams; basis = $basis }
    }
    $parsed = Read-Json (Join-Path $scratch 'recipes-computed.json')
    # ASSIGN FIRST, THEN WRAP. A ONE-recipe batch comes back as a bare object and a many-recipe batch as
    # an array, and the entire value of that rule is that the two read the same to the code below.
    $computed = As-Array $parsed
    foreach ($c in $computed) {
      $cs = [string]$c.slug
      if (-not $out.ContainsKey($cs)) { continue }
      # ---- THE PER-LINE GRAMS, harvested BEFORE the partial/computed branch below. -----------------
      # A `partial` cross-check ships no per-SERVING number, and that rule does not move (a plausible
      # wrong macro figure is worse than a visible miss). But the per-LINE weight of a line the engine
      # DID reach is honest either way: it is that line's own printed measure converted by the estate's
      # one qty engine, and it does not depend on the lines the engine could not reach. So the grams
      # are harvested here, on both branches. What the partial rule protects is the number computed
      # ACROSS lines; this is the number computed WITHIN one.
      #
      # POSITIONAL ALIGNMENT, and it is checked rather than assumed. parse-compute appends exactly one
      # ingredients_source_basis entry per input ingredient, in input order. If the two lengths ever
      # disagree, NOTHING is recorded for that slug - every purchasable line then has to get its grams
      # from a ruling or the assembly is STUCK, which is the safe direction. Silently pairing a raw
      # line with another line's weight is the shape of the 250,000x engine bug.
      $sb = As-Array $c.ingredients_source_basis
      $ord = @($rawOrder[$cs])
      if (@($sb).Count -ne @($ord).Count) {
        $out[$cs].reason = (($out[$cs].reason + '; ') -replace '^; ', '') + ("the engine returned {0} per-line weight(s) for {1} line(s) - no per-line grams recorded" -f @($sb).Count, @($ord).Count)
      } else {
        for ($gi = 0; $gi -lt @($ord).Count; $gi++) {
          $gv = $sb[$gi].grams_src
          if ($null -ne $gv -and [double]$gv -gt 0) {
            $grams[$cs][[string]$ord[$gi]] = [double]$gv
            # B2 (2026-08-24): CARRY THE ENGINE'S OWN ACCOUNT OF HOW IT GOT THE NUMBER.
            # parse-compute already flags every derivation it could not ground in the food's own data
            # - `default tbsp` falls back to densities.json defaults.sauce_tbsp (16 g), `default tsp`
            # to sauce_tsp, `handful w/o density` to a flat 10 g, and the no-qty family to house
            # staples. Those flags reached here and were DISCARDED, so a guess and a grounded weight
            # were indistinguishable downstream and the cross-check compared them as equals. Measured:
            # "3 tablespoons chopped fresh parsley" has no Fresh Parsley density row, so the engine
            # returned 3 x 16 = 48 g at SAUCE density (chopped parsley is ~3.8 g/tbsp), the mapper's
            # correct 40 g at target read as a 0.24x disagreement, and a good recipe parked.
            $fl = @($sb[$gi].flags) | Where-Object { $_ }
            if (@($fl | Where-Object { $script:ENGINE_FALLBACK_FLAGS -contains [string]$_ }).Count) {
              $basis[$cs][[string]$ord[$gi]] = ($fl -join '+')
            }
          }
        }
      }
      # A PARTIAL CROSS-CHECK IS NOT A CROSS-CHECK, AND SHIPPING ONE WOULD BE WORSE THAN SHIPPING NONE.
      # MEASURED 2026-08-24 on this script's first live run: over the four never-mapped phase-2
      # extractions the arithmetic reached 9-12 lines of 17-20, and the line it missed was, every time,
      # the PROTEIN - "boneless skinless chicken breasts" is residual precisely because it is the line
      # carrying the describing words the vocabulary has not ruled on yet. So the numbers came back at
      # 9.6-13.6 g protein per serving against a catalog floor of 25, and parse-compute's 550-gate
      # tuner then injected an auto Rice base into recipes that have none, pushing carbs to 108-116 g
      # on low-carb dinners. Every one of those numbers is arithmetic doing exactly what it was told,
      # over a line set that is not the recipe. Handing it to the mapper as "the pre-computed
      # cross-check" would be handing it a plausible wrong number to verify - the one thing this estate
      # has decided repeatedly is worse than a visible miss.
      # So: `computed` only when the arithmetic reached EVERY line, which is precisely the exit-0 case.
      # Otherwise `partial`, with the uncovered lines named, and the mapper does its own cross-check
      # over the lines it is ruling - which is the work it was being dispatched for anyway.
      if ([int]$out[$cs].lines_covered -lt [int]$out[$cs].lines_total) {
        $out[$cs].state = 'partial'
        $out[$cs].reason = ("the arithmetic reached {0} of {1} lines; the rest are residual and have no canon name yet" -f $out[$cs].lines_covered, $out[$cs].lines_total)
        continue
      }
      $out[$cs].state = 'computed'
      $out[$cs].reason = ''
      $out[$cs].computed_per_serving = [pscustomobject]@{
        cal = $c.per_serving.calories; carbs = $c.per_serving.carbs_g
        protein_g = $c.per_serving.protein_g; fat_g = $c.per_serving.fat_g }
      $out[$cs].portion_factor = $c.portion_factor
      $out[$cs].tuning = (As-Array $c.tuning)
      $out[$cs].missing_db_items = (As-Array $c.missing_db_items)
    }
    return [pscustomobject]@{ precheck = $out; grams = $grams; basis = $basis }
  } catch {
    foreach ($k in @($out.Keys)) { $out[$k].reason = ("the cross-check would not run: " + $_.Exception.Message) }
    return [pscustomobject]@{ precheck = $out; grams = $grams; basis = $basis }
  } finally { Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------------------------------
# THE ASSEMBLER (A1 / pins P2-P6). Pure over the table, the rulings payload, the vocabulary and the run
# state row, so the whole assembly is fixturable without a run dir.
#
# THE DECISION VOCABULARY IS Get-LineClass's, AND NOTHING ELSE'S (pin P4). build-intake-skeleton.ps1
# classifies every mapper line by its `decision` string, and `decision` was FREE TEXT in the v2 contract
# - 21 distinct values across 550 lines. On turkey-parmesan-meatball-bake that silently dropped 1588 g
# of Ground Chicken and three optional lines, computed 250 cal per serving over what was left, and the
# pre-write band gate retired a real recipe at "250 cal below the floor". A gate ruling on a fabricated
# number is worse than no gate: it fails CLOSED and looks like rigour.
# So this assembler emits FOUR strings and no others, and the fixture DOT-SOURCES the real Get-LineClass
# to prove where each one lands:
#     mapped           -> included
#     mapped-null      -> included      (a real food with no commodity id: pantry-static pricing)
#     mapped-optional  -> optional      (counted in the macros, and named in the snapshot)
#     optional-note    -> not-purchased (water, a garnish, a sub-recipe - nothing the shopper buys)
# The mapper's own ruling enum is the closed set {mapped, mapped-null, mapped-optional, not-purchased,
# rejected}; `rejected` never becomes a decision string at all - it is the honest no, and it makes this
# mode exit 1 with the line named rather than shipping a file with a hole in it.
$script:ASM_RULING_DECISIONS = @('mapped', 'mapped-null', 'mapped-optional', 'not-purchased', 'rejected')

# GARNISH PHRASING. Matched as PHRASES rather than on the bare word "garnish", because a line may
# legitimately BE the garnish and still be bought in a stated quantity ("1/4 cup parsley, for garnish"),
# and those never reach the caller anyway - the qty engine weighs them. See the call site for why the
# absence of a weight is the quantity test.
#
# `to serve` / `for serving` are IN: "warm tortillas, to serve" and "sour cream, for serving" are the
# same shape - a serving suggestion with no measure - and they park recipes the same way.
# B2 (2026-08-24). THE ENGINE'S OWN NAMES FOR "I COULD NOT GROUND THIS".
# Every one of these is parse-compute telling the truth about a weight it did not derive from the
# food's own densities.json row or each-noun. They are its strings, copied verbatim - see GramsFor's
# tbsp/tsp branches and the no-qty family. A weight carrying one of these is a GUESS, and comparing a
# guess against the mapper's grounded ruling is a cross-check firing on noise.
$script:ENGINE_FALLBACK_FLAGS = @('default tbsp', 'default tsp', 'handful w/o density',
                                  'no-qty->house staple', 'no-qty->serve-default',
                                  'no-qty zero (minor item)')

$script:GARNISH_PHRASES = @('to garnish', 'for garnish', 'for garnishing', 'as garnish',
                            'as a garnish', 'to serve', 'for serving', 'for topping', 'to top')

# A LEADING LABEL DECLARES THE WHOLE LINE A SERVING SUGGESTION (2026-08-26, Brad's ruling after the
# smoke run). The phrases above are all TRAILING qualifiers on one food ("Fresh parsley (to garnish)"),
# and they cannot see the other shape a source uses for the same thing: a LABEL at the front, with the
# foods listed after a colon.
#
# MEASURED on `easy-beef-enchiladas`, run hunt-2026-08-26-smoke, which parked on:
#
#     "optional toppings: diced onions, chopped cilantro, sour cream, shredded lettuce"
#
# The mapper ruled it correctly - `mapped-null`, zero grams, evidence "Four distinct foods on one
# unsplittable line with no quantity, so no single bid can carry it ... Garnish to taste, pantry-static
# and safe." The row is `optional: true`. But `mapped-null` + optional maps to `mapped-optional` in
# Get-AssembledDecision, NOT to `optional-note`, and `mapped-optional` then demands a gram weight this
# line can never have. So the assembler refused a line every stage before it had settled correctly.
#
# Across every rulings file this estate has (40 runs), 2 lines reach the assembler needing grams and
# stating none: this one, and the rice-blend alternatives line D5 already settles.
#
# SAFE BY CONSTRUCTION, the same way the garnish ruling is: the caller reaches this ONLY where neither
# the qty engine nor the mapper could weigh the line, so it can only ever fire where the recipe dies
# today. A toppings label on a line that STATES a measure gets grams from the engine and never arrives.
$script:GARNISH_LABEL_RX = '^\s*(optional(\s+(toppings?|garnishes?|extras?))?|toppings?|garnishes?|for\s+serving|to\s+serve|serve\s+with)\s*:'

# A PANTRY SEASONING STATED "TO TASTE" IS NOT A PURCHASABLE LINE (T1, Brad's ruling 2026-08-25,
# after the m1 drill parked a recipe in EACH of its two batches on "salt and pepper to taste").
#
# MEASURED: 2 of the 6 recipes the m1 drill sent down the pipe died here. Both times the mapper
# ruled the line purchasable, and the refusal below correctly refused the file - "a purchasable line
# with no weight cannot be costed". The extraction already marks 'to taste' optional
# (local_extract.py:233), so the mapper is overriding a call that was already made, which is the
# standing argument for settling it mechanically: a rule a model must remember is a rule it
# sometimes forgets. This is the garnish ruling one food class over.
#
# BRAD RULED THE NARROW VERSION, and the width is the whole design. A blanket "any line saying to
# taste" rule would silently drop `harissa, to taste` from cost AND macros - a real ingredient, a
# real price, and the reader never told. So the line qualifies only when EVERY word of its food half
# is a seasoning word AND at least one is salt or pepper. `harissa` is in neither list, so
# `harissa, to taste` falls through to the refusal and the recipe parks, which is the honest outcome
# and the same one it gets today.
#
# INHERITS THE GARNISH RULE'S SAFETY PROPERTY EXACTLY: it lives INSIDE the zero-weight refusal, so
# it can only ever fire where the recipe dies today and cannot change a line that currently works.
# "1 tsp salt, to taste" gets grams from the qty engine and never reaches here.
$script:TO_TASTE_SEASONING_CORE = @('salt', 'pepper', 'peppercorn', 'peppercorns')
$script:TO_TASTE_SEASONING_MODIFIERS = @('black', 'white', 'kosher', 'sea', 'ground', 'freshly',
                                         'fresh', 'cracked', 'coarse', 'coarsely', 'fine', 'finely',
                                         'table', 'flaky', 'flake', 'flakes', 'pink', 'himalayan',
                                         'iodized', 'and')

# ALTERNATIVES LINES (D5, Brad's ruling 2026-08-24). A source line that offers a CHOICE of foods -
# "Prepared brown and wild rice blend, brown rice, quinoa, or cauliflower rice" - names no single food
# and so has no single weight or price. 6b parked a recipe on exactly that line after map, registrar
# and pricing had all been paid.
#
# THE RULING: price the alternatives, take the CHEAPEST, and disclose it - but ONLY alternatives that
# resolve through a board id or label. An include-pattern substitution NEVER counts.
#
# WHY THAT GUARD IS NOT PAPERWORK, measured on this very line:
#     brown and wild rice blend   include pattern   $0.4396/lb   <- that is WHITE rice
#     brown rice                  board id/label    $0.88/lb     <- the only exact match
#     quinoa                      search term       $0.1372/oz
#     cauliflower rice            include pattern   $0.4396/lb   <- white rice again
# Two of the four resolve to a different food entirely. Without the guard the "cheapest alternative"
# is a substitution wearing the right name.
#
# AND UNITS ARE THE SECOND TRAP. quinoa's $0.1372 is per OUNCE - $2.20/lb, the dearest of the four -
# so comparing the raw `cheapest` figures across alternatives ranks it FIRST. Anything comparing prices
# here must normalise, and where it cannot it must refuse to rank rather than guess.
$script:ALT_EXACT_ROADS = @('exact commodity id', 'commodity label', 'board id/label')

function Split-AlternativeFoods([string]$Raw) {
  <#
    The candidate foods in an alternatives line, or an empty list when the line is not one.
    Requires a comma-separated list with a trailing " or " - the shape a recipe writes a choice in.
    A bare "salt or pepper" is NOT an alternatives line by this test, and that is deliberate: two foods
    joined by `or` with no list punctuation is more often a phrase than a menu.
  #>
  if (-not $Raw) { return @() }
  # PARENTHETICALS ARE STRIPPED FIRST, AND THAT IS NOT TIDINESS - IT IS THE WHOLE TEST.
  # Found 2026-08-24, the day D5 shipped, by asking how common a quantity-bearing alternatives line
  # actually is. It is not: of 201 lines in the pool carrying `, or `, 155 state a quantity and almost
  # every one of those is a VARIETY NOTE in brackets, not a menu -
  #     "1 bell pepper (red, yellow, or orange, chopped)"
  #     "1 lb. Italian sausage (hot, mild, or sweet)"
  #     "1 cup dry red wine (such as Cabernet Sauvignon, Merlot, or Pinot Noir)"
  #     "10 small corn tortillas (6-inch, or flour tortillas)"
  # The main food is stated once and IS weighable. Splitting on the bracketed `or` produced
  # `[1 bell pepper (red] [yellow] [orange] [chopped)]` - four foods, none of them real. Those lines
  # never reached D5 because their quantity gets them a weight, so this was luck rather than design:
  # a bracketed line with NO weight ("Fresh herbs (parsley, dill, or chives)") would have reached the
  # refusal, mis-split, and gone shopping for the wrong food.
  #
  # So a menu has to be a menu at the TOP LEVEL of the line. If removing the brackets removes the
  # `, or `, the line was never offering a choice of ingredient in the first place.
  $s = ($Raw -replace '\([^)]*\)', ' ') -replace '\[[^\]]*\]', ' '
  $s = ($s -replace '\s+', ' ').Trim().TrimEnd(',')
  if ($s -notmatch ',\s*or\s+') { return @() }
  # a leading state word ("Prepared", "Cooked") applies to the whole list, not to one option
  $lead = ''
  if ($s -match '^(prepared|cooked|uncooked|dry)\s+(.*)$') { $lead = $Matches[1]; $s = $Matches[2] }
  $parts = @()
  foreach ($p in ($s -split ',\s*or\s+|,\s*|\s+or\s+')) {
    $t = ([string]$p).Trim().TrimEnd('.')
    if ($t) { $parts += $t }
  }
  if ($parts.Count -lt 2) { return @() }
  return @($parts)
}

function Get-PerLbPrice($Result) {
  # lb and oz are the only units the board uses for these foods, and 1 lb is 16 oz. Anything else is
  # NOT normalised - it returns $null and the caller refuses to rank rather than comparing nonsense.
  if ($null -eq $Result.cheapest) { return $null }
  switch ([string]$Result.unit) {
    'lb' { return [double]$Result.cheapest }
    'oz' { return ([double]$Result.cheapest) * 16.0 }
    default { return $null }
  }
}

function Select-CheapestAlternative {
  <#
    Returns @{ term; commodity; per_lb; evidence } for the cheapest EXACTLY-MATCHED alternative, or
    $null when none of them resolves exactly. Mechanical: one price-ingredient call, no model.
  #>
  param([string[]]$Foods, [string]$PriceScript = '')
  if (-not $Foods -or $Foods.Count -lt 2) { return $null }
  if (-not $PriceScript) { $PriceScript = Join-Path $script:repoRoot 'grocery\price-ingredient.ps1' }
  if (-not (Test-Path $PriceScript)) { return $null }
  # NO 2>&1 HERE. In PS 5.1 redirecting a native command's stderr wraps each line in an ErrorRecord,
  # which lands non-JSON text in $raw and makes ConvertFrom-Json fail - measured while building this:
  # every alternative came back "no exact match" while price-ingredient was answering correctly.
  $raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $PriceScript -Json @Foods
  $doc = $null
  try { $doc = (@($raw | ForEach-Object { [string]$_ }) -join "`n") | ConvertFrom-Json } catch { return $null }
  if (-not $doc -or -not $doc.results) { return $null }
  $best = $null
  foreach ($r in @($doc.results)) {
    if ([string]$r.tier -ne 'MAPPED') { continue }
    if ($script:ALT_EXACT_ROADS -notcontains [string]$r.resolved_by) { continue }
    $per = Get-PerLbPrice $r
    if ($null -eq $per) { continue }
    if ($null -eq $best -or $per -lt $best.per_lb) {
      $best = @{ term = [string]$r.term; commodity = [string]$r.commodity; per_lb = $per
                 evidence = ("cheapest of {0} stated alternatives that resolve exactly: '{1}' -> {2} at {3}/lb ({4})" -f `
                             $Foods.Count, [string]$r.term, [string]$r.commodity, [Math]::Round($per, 4), [string]$r.resolved_by) }
    }
  }
  return $best
}

# A BID MAY NOT BE AN ID ITS OWN RULING SAYS IT REFUSED (2026-08-24, found in the 6b post-run read).
#
# `turmeric-braised-chicken-with-golden-beets-and-leeks` was ruled:
#     "item": "Bone-In Skinless Chicken Drumstick",
#     "bid":  "chicken-thighs",
#     "notes": "...Refused the chicken-thighs bridge on the standing 'leg quarters are not thighs'
#               precedent: drumsticks are a distinct cut ... so the thigh id would overprice and
#               mis-weigh."
# The prose refuses the id; the machine-readable field IS the id. The SAME mapper got hawaiian-chicken
# right with identical reasoning, so it is a slip rather than a policy - and nothing checked, because
# the evidence gate is written for a HUMAN reader and no machine reads it. Measured across every
# mapped file this estate has: 1 of 579 ruled lines. Rare, and it was on its way to pricing a drumstick
# recipe off thigh rows.
#
# WHICH SIDE IS WRONG IS NOT KNOWABLE HERE, so this does not pick one. It is a FINDING, which parks the
# recipe and quotes both halves back - the same safe direction every other assembly finding takes.
#
# WORD BOUNDARIES MATTER: `chicken-breast` is a substring of `bone-in-chicken-breast`, and a ruling
# that refuses one while bidding the other is CORRECT reasoning, not a contradiction.
#
# **CORRECTED 2026-08-26**, after this check's FIRST production firing was a FALSE POSITIVE that stuck
# a CORRECT recipe: `easy-beef-enchiladas` in run hunt-2026-08-26-smoke. Two separate faults compounded
# there. Only ONE of them is this predicate's, and the other is at the call site - see the -Assemble
# loop, where the mapper's own bid is now captured before the registrar can rewrite it.
#
# THE PREDICATE'S FAULT: THE CLAUSE BOUND DID NOT INCLUDE THE COLON. The gap class was `[^.;]{0,60}?`,
# so a match could walk straight through the colon that ENDS a refusal clause and land on a mention in
# the NEXT one. The enchiladas evidence reads:
#
#     "Refused the corn-tortillas bridge: corn and flour tortillas are different products at
#      different per-unit prices and gram weights. New id proposed with an alias instruction
#      against the generic `tortillas` board id. 8 x 71 g."
#
# Against bid `tortillas` the token guards below did their job on `corn-tortillas` - the `tortillas`
# INSIDE it is correctly not a match, and a refused SIBLING id must never count as refusing the bid.
# What fired was the STANDALONE `tortillas` in "corn and flour tortillas are different products", 45
# characters past the refusal word and one clause too late. That clause does not refuse anything; it
# EXPLAINS the refusal, and naming the bid there is what a good ruling looks like.
#
# So the gap class is now `[^.;:!?]{0,60}?` - the same clause-ending set `learn_apply.refuse_near_bid`
# has always used, which had this right. MEASURED against the founding chicken-thighs fixture: it
# fires either way, because `drumsticks` sits 91 characters from the refusal word and the LENGTH bound
# was already excluding it. The colon was never carrying the founding case, so tightening it costs
# that MUST-FIRE nothing and removes the only false positive this check has ever produced.
#
# DO NOT "fix" this by narrowing the gap back to `\W{0,80}` (non-word characters only). That is what
# PLAN-ingredient-memory 3.4 froze, and it cannot cross the word "the" in "Refused THE chicken-thighs
# bridge" - the founding case's own text - so the MUST-FIRE silently stops firing. The clause bound
# and the token bounds are what carry this check; the gap WIDTH is not.
$script:REFUSAL_WORDS = 'refus\w*|reject\w*|declin\w*|rul\w*\s+out|not\s+bridg\w*'

# A REPORTED REFUSAL IS NOT THIS RULING'S REFUSAL (2026-08-28). Third production firing, third false
# positive, and this one names the mechanism the other two only hinted at. Verbatim from
# `baked-cubano-chicken`, run hunt-2026-08-27-highprotein:
#
#     "This line IS sliced deli lunch meat, which is exactly what deli-ham prices - a reuse. Refused
#      the vocabulary's Diced Ham: cubed convenience packs are a different pack and price class. The
#      'spiral ham' precedent refused deli-ham for a bone-in whole ham, which is the opposite case
#      and does not bind here."
#
# The ruling bids `deli-ham`, argues FOR it twice, and is stuck because it CITED A PAST RULING that
# refused that id in order to distinguish it. The check cannot tell "someone else refused Y, and that
# does not apply" from "I refuse Y" - and citing the precedent you are declining to follow is exactly
# what a careful mapper does, so this check was punishing its best reasoning for the third time.
#
# THE DISCRIMINATOR IS A SUBJECT. This ruling's OWN refusals are subject-less imperatives - "Refused
# the corn-tortillas bridge", "REFUSED chicken-breast (boneless skinless)", "Refused the
# chicken-thighs bridge" - which is how every founding fixture below reads. A REPORTED one names who
# did the refusing right before the verb: "the 'spiral ham' precedent refused". So a refusal whose
# verb is immediately preceded by an attribution noun is somebody else's, and is not read as this
# ruling contradicting itself.
#
# NARROWING, NOT DISABLING. Every fixture above still fires: none of them puts a noun before the verb,
# and `$realNotes` says "...precedent" AFTER its refusal, not before it. An id the ruling refuses in
# its own voice still parks the recipe.
$script:REFUSAL_ATTRIBUTION =
  "(?i)(?:precedent|ruling|rule|note|entry|row|audit|finding|case|ledger|guard|gate|check|memo|comment|convention|standing\s+order)s?['’]?s?\s*$"

function Test-BidContradictsNotes {
  param([string]$Bid, [string]$Notes)
  if (-not $Bid -or -not $Notes) { return $false }
  $b = [regex]::Escape($Bid.Trim())
  # The bid, AS A WHOLE TOKEN, within ~60 characters after a refusal word AND INSIDE THE SAME CLAUSE.
  # `.` `;` `:` `!` `?` all end the refusal being read; the lookarounds keep a bid from matching inside
  # a longer hyphenated id in either direction (`tortillas` in `corn-tortillas`, `chicken-thighs` in
  # `boneless-chicken-thighs`), because a refused sibling is sound reasoning, not a contradiction.
  $rx = ('(?i)(?:' + $script:REFUSAL_WORDS + ')(?:[^.;:!?]{0,60}?)(?<![a-z0-9-])' + $b + '(?![a-z0-9-])')
  # EVERY match is examined, not just the first: one evidence string can carry a reported refusal AND
  # a real one, and returning on the first would let the order of the prose decide the verdict.
  foreach ($m in [regex]::Matches($Notes, $rx)) {
    $before = $Notes.Substring(0, $m.Index)
    if ([regex]::IsMatch($before, $script:REFUSAL_ATTRIBUTION)) { continue }
    return $true
  }
  return $false
}

# FDC CANDIDATE ROWS, read from the cache fdc_lookup.py fills. Read-only and offline: this never
# reaches the network, so a cold cache simply means the mapper works the way it always did.
$script:FdcCache = $null

function Get-FdcMacro {
  <#
    One macro off a cached FDC candidate, or '?'.

    A MACRO FDC DID NOT STATE RENDERS `?`, NEVER 0. A missing number and a zero are different claims
    about a food - salt and water are honestly 0/0/0 and the row schema treats an absent macro
    differently - and 29 of the live cache's candidates are missing at least one macro today. Handles
    both a ConvertFrom-Json object and a hashtable, because a fixture builds one and the cache the
    other.
  #>
  param($Macros, [string]$Field)
  if ($null -eq $Macros) { return '?' }
  $val = $null
  if ($Macros -is [System.Collections.IDictionary]) {
    if ($Macros.Contains($Field)) { $val = $Macros[$Field] }
  } else {
    $prop = $Macros.PSObject.Properties[$Field]
    if ($prop) { $val = $prop.Value }
  }
  if ($null -eq $val -or ([string]$val).Trim() -eq '') { return '?' }
  return [string]$val
}

function Get-FdcCandidates {
  param([string]$Term)
  if (-not $Term) { return '' }
  if ($null -eq $script:FdcCache) {
    $script:FdcCache = @{}
    # Built from segments rather than one literal: a backslash path is one bad escape away from
    # silently pointing at nothing, and a cache that never loads looks exactly like a cold cache.
    $cf = Join-Path (Join-Path (Join-Path $script:repoRoot 'meal-prep') 'db') 'fdc-cache.json'
    if (Test-Path $cf) {
      try {
        $doc = Get-Content $cf -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($k in $doc.terms.PSObject.Properties.Name) { $script:FdcCache[$k] = $doc.terms.$k }
      } catch { $script:FdcCache = @{} }
    }
  }
  $key = ($Term -replace '\s+', ' ').Trim().ToLower()
  if (-not $script:FdcCache.ContainsKey($key)) { return '' }
  $rows = @($script:FdcCache[$key].candidates)
  if (-not $rows.Count) { return '' }
  $parts = @()
  # FOUR CANDIDATES, EACH A WHOLE ROW, AND THE ID THAT CITES IT (M1, 2026-08-25). The three-number
  # form this replaced rendered neither the fdc_id nor fat nor fibre, while map_prompt requires six
  # fields and write_food_db_rows REFUSES a row citing neither an id nor a URL - so a mapper obeying
  # the contract could not build a row off the shelf and went and re-acquired the food. Measured on
  # the lf1 round-1 transcript: 6 direct api.nal.usda.gov calls with DEMO_KEY for foods the shelf had
  # already covered, plus 5 turns discovering fdc_lookup.py itself.
  foreach ($r in ($rows | Select-Object -First 4)) {
    $m = $r.macros
    # `fdc:` FIRST and rendered as the literal citation string: the prompt asks for `fdc:<id>` in
    # `source` and the shelf had never once shown one. Fibre is rendered because atwater_check credits
    # it at 2 kcal/g (fdc_lookup.py's own comment), so a legitimate high-fibre row FAILS the gate
    # without it.
    $line = ("fdc:{0} {1} [{2}] per 100 g: {3} cal, {4} P, {5} C, {6} F, {7} fiber" -f `
             [string]$r.fdc_id, [string]$r.description, [string]$r.data_type,
             (Get-FdcMacro $m 'calories'), (Get-FdcMacro $m 'protein_g'), (Get-FdcMacro $m 'carbs_g'),
             (Get-FdcMacro $m 'fat_g'), (Get-FdcMacro $m 'fiber_g'))
    # THE STATED PORTIONS, NEVER AN INVENTED ONE. The food DB wants a serving in BOTH a household
    # measure and grams (fdc_lookup._portions exists for exactly this), and without them the mapper
    # must invent serving_qty/serving_unit or go find a label. Capped at 3.
    $ports = @()
    foreach ($pt in (@($r.portions) | Select-Object -First 3)) {
      if ($null -eq $pt) { continue }
      $measure = [string]$pt.measure
      if (-not $measure -or $null -eq $pt.grams) { continue }
      $ports += ("{0}={1}g" -f $measure, [string]$pt.grams)
    }
    if ($ports.Count) { $line = $line + (' portions: ' + ($ports -join ', ')) }
    $parts += $line
  }
  return ($parts -join ' | ')
}

function Test-IsGarnishLine([string]$Raw) {
  if (-not $Raw) { return $false }
  $s = $Raw.ToLower()
  foreach ($p in $script:GARNISH_PHRASES) { if ($s.Contains($p)) { return $true } }
  # trailing bare ", garnish" - the same statement with the preposition dropped
  if ($s -match ',\s*garnish(es)?\s*$') { return $true }
  # a LEADING label - "optional toppings: a, b, c" - which no trailing qualifier can see
  if ($s -match $script:GARNISH_LABEL_RX) { return $true }
  return $false
}

function Test-IsPantrySeasoningToTaste([string]$Raw) {
  <#
    True only for a line that says "to taste" AND whose food half is nothing but seasoning words,
    at least one of them salt or pepper. Every unknown word is a REFUSAL, which is what keeps
    `harissa, to taste` and `salt and harissa to taste` out of this branch.
  #>
  if (-not $Raw) { return $false }
  $s = $Raw.ToLower()
  if ($s -notmatch '\bto\s+taste\b') { return $false }
  # the FOOD half: drop the to-taste clause, then anything that is not a letter or a space. A digit
  # or a unit surviving here means the line states a measure, and a stated measure is not this rule's
  # business - the word test below refuses it, because `tsp` is in neither list.
  $food = [regex]::Replace($s, '\bto\s+taste\b', ' ')
  $food = [regex]::Replace($food, '[^a-z ]', ' ')
  $food = ([regex]::Replace($food, '\s+', ' ')).Trim()
  if (-not $food) { return $false }
  $hasCore = $false
  foreach ($w in @($food -split ' ')) {
    if (-not $w) { continue }
    if ($script:TO_TASTE_SEASONING_CORE -contains $w) { $hasCore = $true; continue }
    if ($script:TO_TASTE_SEASONING_MODIFIERS -contains $w) { continue }
    return $false
  }
  return $hasCore
}

# A DELIBERATE ZERO IS NOT A MISSING WEIGHT (Brad's D1 ruling, 2026-08-24, arriving at the assembler).
#
# MEASURED 2026-08-26, `steak-stir-fry-recipe` in run hunt-2026-08-26-smoke4, on the line
# "Fresh Basil and Lemon Wedges". EVERY stage before this one settled it exactly as D1 says to:
# extraction marked the row `optional: true` under the source's "Optional for Garnish" heading, the
# mapper ruled it `mapped-optional` with `bid: null` and `grams_source: 0` and wrote "No bid because
# there is no amount to price, which is pantry-safe". The assembler then refused it as "a purchasable
# line with no weight".
#
# THE MECHANISM, CONFIRMED BY INSTRUMENTING THE GATE RATHER THAN BY READING IT. The refusal is
# `if ($null -eq $grams -or $grams -le 0)`, and it is the SECOND arm that fires: with the debug print
# in place this line reported `grams_isnull=False grams='0' gramsFrom='ruling'`. So the ruling DID
# state a weight - the gate's own finding text ("no gram weight from the engine or from a ruling") is
# wrong about its own input - and `-le 0` is where "nobody weighed this" and "the estate ruled this
# weighs nothing" become the same value. It is NOT the `-not $g` falsiness trap: no falsiness test
# exists on this path, and $grams is a [double] 0, never $null, on the failing line.
#
# WHY THE EXEMPTION IS KEYED ON SIGNALS AND NOT ON THE ZERO. A zero on its own says nothing: the
# engine writes one too (`no-qty zero (minor item)` is in ENGINE_FALLBACK_FLAGS), and a line the
# mapper thinks the shopper BUYS that happens to carry 0 g is the fabricated-band defect this refusal
# exists for. So four things must all hold, and each is something a stage deliberately WROTE:
#   * the weight is 0 and it came from the MAPPER ($GramsFrom 'ruling' or 'line'). A weight the engine
#     guessed, or no weight at all ($GramsFrom ''), is not a ruling and is still refused.
#   * NO BID. A line with a wired commodity id is a line the shopper buys, whatever it weighs.
#   * the line is OPTIONAL - the extraction's `optional: true`, or the mapper's `mapped-optional`,
#     either one. Both are explicit; a non-optional line with an explicit 0 g still parks the recipe,
#     which is the fixture that keeps this gate's teeth.
# `mapped-optional` is in hunt_lib.MAPPED_RULING_DECISIONS and in ASM_RULING_DECISIONS above, so this
# reads the closed enum rather than a word the mapper invented.
function Test-IsRuledZeroOptional {
  param([bool]$Optional, [string]$RulingDecision, [string]$Bid, $Grams, [string]$GramsFrom)
  if ($null -eq $Grams) { return $false }            # NO WEIGHT GIVEN - the case this gate is for
  $g = 0.0
  try { $g = [double]$Grams } catch { return $false }
  if ($g -ne 0) { return $false }                    # a negative weight is a bug, not a ruling
  if ($GramsFrom -ne 'ruling' -and $GramsFrom -ne 'line') { return $false }
  if ($Bid) { return $false }                        # a wired id is a food the shopper buys
  $d = ([string]$RulingDecision).Trim().ToLower()
  if (-not $Optional -and $d -ne 'mapped-optional') { return $false }
  return $true
}

function Get-AssembledDecision {
  <# The ruling enum (or a pre-resolved line's absence of one) onto Get-LineClass's vocabulary. #>
  param([string]$Ruling, [bool]$Optional)
  $r = ([string]$Ruling).Trim().ToLower()
  if (-not $r) { $r = 'mapped' }                       # a pre-resolved line: the table already settled it
  switch ($r) {
    'not-purchased'   { return 'optional-note' }
    'mapped-optional' { return 'mapped-optional' }
    'mapped-null'     { if ($Optional) { return 'mapped-optional' } return 'mapped-null' }
    default           { if ($Optional) { return 'mapped-optional' } return 'mapped' }
  }
}

function New-MappedDecisionFile {
  <#
    Returns [pscustomobject]@{ doc = <the mapped file, or $null>; findings = @(...) }.
      $Table    the mapped-pre\<slug>.json object
      $Payload  the mapper's rulings payload for this slug
      $StateRow the run state file's object (for `protein`), or $null
      $KnownBids a hashtable of every bid db\ingredients.json actually wires
  #>
  param($Table, $Payload, $StateRow, $KnownBids, [int]$TargetServ)
  $findings = New-Object System.Collections.Generic.List[string]

  # ---- the scale, applied EXACTLY ONCE (pin P3). ------------------------------------------------
  # The table's grams are SOURCE basis; the file's are TARGET. The v2 row this is frozen against:
  # 16 oz of cauliflower at 4 source servings = 454 g x scale_factor 3.5 = 1588 g on disk.
  $srcServ = 0
  if ($null -ne $Table.servings) { try { $srcServ = [double]$Table.servings } catch { $srcServ = 0 } }
  if ($srcServ -le 0) {
    $findings.Add("the pre-resolve table states no source servings, so nothing can be scaled - a guessed batch size is a guessed price and a guessed macro") | Out-Null
    $srcServ = 0
  }
  $scale = if ($srcServ -gt 0) { [Math]::Round($TargetServ / $srcServ, 4) } else { 0 }

  # ---- the two arrays, joined to the table by the RAW LINE, with ONE bounded fallback. -----------
  #
  # MEASURED ON THE PHASE-6A GATE DRILL, 2026-08-24: over a 2-recipe batch the model copied 17 of 17
  # `lines[]` raws and 15 of 16 `rulings[]` raws EXACTLY - and truncated one, writing
  # '1/4 cup grated Parmesan cheese' where the table says '1/4 cup grated Parmesan cheese (plus
  # additional for serving)'. The assembler correctly refused the file. But refusing a whole recipe -
  # after a 15-minute paid dispatch that ruled the line perfectly well - over a dropped parenthetical
  # is a gate failing on transcription rather than on judgment, and re-asking for a copy of a long
  # string is buying a second session to fix a typo.
  #
  # SO: raw first, then TERM, and nothing else. `term` is the table's own short key, it is what the
  # residual block leads each line with, and it is short enough to copy exactly. The fallback fires
  # ONLY when the term identifies exactly ONE table row - an ambiguous term is not a match, it is a
  # guess, and a guess here pairs an ingredient with another line's ruling. Anything the term road
  # cannot settle is still a finding and still refuses the file.
  $lineBy = @{}
  foreach ($l in (As-Array $Payload.lines)) { if ($l.raw) { $lineBy[[string]$l.raw] = $l } }
  $ruleBy = @{}
  foreach ($r in (As-Array $Payload.rulings)) { if ($r.raw) { $ruleBy[[string]$r.raw] = $r } }
  # term -> ruling, kept ONLY where the term is unique in the payload AND unique in the table
  $ruleByTerm = @{}
  $termDupes = @{}
  foreach ($r in (As-Array $Payload.rulings)) {
    $rt = [string]$r.term
    if (-not $rt) { continue }
    if ($ruleByTerm.ContainsKey($rt)) { $termDupes[$rt] = $true } else { $ruleByTerm[$rt] = $r }
  }
  $lineByTerm = @{}
  $lineTermDupes = @{}
  foreach ($l in (As-Array $Payload.lines)) {
    $lt = [string]$l.term
    if (-not $lt) { continue }
    if ($lineByTerm.ContainsKey($lt)) { $lineTermDupes[$lt] = $true } else { $lineByTerm[$lt] = $l }
  }
  $tableTermCount = @{}
  foreach ($row0 in (As-Array $Table.rows)) {
    $tt = [string]$row0.term
    if (-not $tt) { continue }
    $tableTermCount[$tt] = 1 + [int]$tableTermCount[$tt]
  }
  $paraphrased = New-Object System.Collections.Generic.List[string]

  # ---- the registrar's verdicts, keyed by the bid they were asked about (A4 / pin P6). -----------
  $regBy = @{}
  foreach ($g in (As-Array $Payload.registrar_rulings)) {
    $k = [string]$g.proposed_bid; if (-not $k) { $k = [string]$g.bid }
    if ($k) { $regBy[$k] = $g }
  }

  $ings = New-Object System.Collections.Generic.List[object]
  $terms = New-Object System.Collections.Generic.List[string]
  # B2: lines the qty engine could not ground. Returned so the caller can append them to the run's
  # density-gaps list - the densities.json worklist, built from what recipes ACTUALLY use rather
  # than from someone guessing which 232 foods matter.
  $gapRows = New-Object System.Collections.Generic.List[object]
  foreach ($row in (As-Array $Table.rows)) {
    $raw = [string]$row.raw
    $optional = [bool]$row.optional
    $rowTerm = [string]$row.term
    $ruling = $null; if ($ruleBy.ContainsKey($raw)) { $ruling = $ruleBy[$raw] }
    if ($null -eq $ruling -and $rowTerm -and $ruleByTerm.ContainsKey($rowTerm) `
        -and -not $termDupes.ContainsKey($rowTerm) -and [int]$tableTermCount[$rowTerm] -eq 1) {
      $ruling = $ruleByTerm[$rowTerm]
      $paraphrased.Add(("ruling for '{0}' joined on its TERM - the returned raw line was '{1}', which is not this table's" -f $rowTerm, [string]$ruling.raw)) | Out-Null
    }
    $line = $null;   if ($lineBy.ContainsKey($raw))  { $line = $lineBy[$raw] }
    if ($null -eq $line -and $rowTerm -and $lineByTerm.ContainsKey($rowTerm) `
        -and -not $lineTermDupes.ContainsKey($rowTerm) -and [int]$tableTermCount[$rowTerm] -eq 1) {
      $line = $lineByTerm[$rowTerm]
      $paraphrased.Add(("buy line for '{0}' joined on its TERM rather than on the raw line" -f $rowTerm)) | Out-Null
    }

    # AN UNBID ROW MUST NEVER REACH HERE. The daemon holds the recipe at `mapped` off the table's
    # `holds` list, before it assembles anything - so an unbid row arriving here means the hold was
    # skipped, and shipping it would put an ingredient with no wired bid onto a priced card.
    if ([string]$row.resolution -eq 'unbid') {
      $findings.Add(("'{0}' resolves to {1} with NO bid wired - this is a HOLD the daemon should have taken off the table's holds list, not a line to assemble over" -f $raw, [string]$row.canon_item)) | Out-Null
      continue
    }

    $isResidual = (Test-IsResidual ([string]$row.resolution))
    if ($isResidual -and $null -eq $ruling) {
      $findings.Add(("'{0}' is a RESIDUAL line ({1}) and the mapper returned no ruling for it - this is exactly the line it was dispatched to settle" -f $raw, [string]$row.resolution)) | Out-Null
      continue
    }

    $rulingDecision = ''
    if ($ruling) { $rulingDecision = ([string]$ruling.decision).Trim().ToLower() }
    if ($rulingDecision -and ($script:ASM_RULING_DECISIONS -notcontains $rulingDecision)) {
      # A VALUE OUTSIDE THE CLOSED SET MINTS AN IDENTITY NOTHING DOWNSTREAM WILL EVER MATCH AGAIN,
      # and free-texting this field is what produced 21 distinct decision words across 550 v2 lines.
      $findings.Add(("'{0}' was ruled '{1}', which is not one of {2}" -f $raw, [string]$ruling.decision, ($script:ASM_RULING_DECISIONS -join ' | '))) | Out-Null
      continue
    }
    if ($rulingDecision -eq 'rejected') {
      $findings.Add(("'{0}' was REJECTED by the mapper ({1}) - there is no intake to build over a line nobody settled" -f $raw, ([string]$ruling.evidence))) | Out-Null
      continue
    }

    $item = [string]$row.canon_item
    $bid  = [string]$row.bid
    $board = [string]$row.board
    if ($ruling) {
      if ($ruling.canon_item) { $item = [string]$ruling.canon_item }
      if ($ruling.PSObject.Properties.Name -contains 'bid') { $bid = [string]$ruling.bid }
      if ($ruling.PSObject.Properties.Name -contains 'board' -and $ruling.board) { $board = [string]$ruling.board }
      # `board` is informational (no consumer reads it - see 4.5's frozen field set) and the table's
      # value is the pre-resolve's own reading, so a ruling that says nothing leaves it alone.
    }

    # THE BID THE MAPPER ACTUALLY WROTE, frozen here because the registrar gate below may REWRITE
    # `$bid` to an alias target, and the notes-vs-bid check reads evidence the MAPPER wrote about the
    # ids the MAPPER was choosing between. Asking whether that evidence refused an id the mapper never
    # bid is not a question with a meaning.
    #
    # MEASURED, 2026-08-26, `easy-beef-enchiladas` in run hunt-2026-08-26-smoke - the first production
    # firing of this check, and a FALSE POSITIVE that stuck a correct recipe. The mapper bid
    # `flour-tortillas` and wrote "Refused the corn-tortillas bridge: corn and flour tortillas are
    # different products...". The registrar ruled `alias` -> `tortillas` (right: commodities.json
    # labels that id "Tortillas (flour)"), the line below rewrote `$bid`, and the check then asked
    # whether evidence written about `flour-tortillas` and `corn-tortillas` refused `tortillas`.
    # Nothing in that ruling contradicts anything.
    $ruledBid = $bid

    # ---- THE REGISTRAR GATE (A4 / pin P6). ------------------------------------------------------
    # A3 strips the Agent tool from the mapper, which severs the road its own definition orders new
    # ids down ("through the commodity-registrar gate"). A4 rebuilds it daemon-side, and the
    # ENFORCEMENT lives here rather than in the prompt: a bid NO COMMODITY NAMESPACE already carries
    # is a NEW commodity id, and it may only be minted with an approve (or an alias to something that
    # already exists) from the registrar. This test does not trust the payload to declare its own
    # proposals - it reads the three namespaces (see Get-CommodityIds, and read its correction note:
    # the first build asked the recipe VOCABULARY instead and refused a live board id).
    if ($bid -and -not $KnownBids.ContainsKey($bid)) {
      $g = $null; if ($regBy.ContainsKey($bid)) { $g = $regBy[$bid] }
      $verdict = ''; if ($g) { $verdict = ([string]$g.verdict).Trim().ToLower() }
      if ($verdict -eq 'alias' -and $g.bid) {
        $bid = [string]$g.bid
        if (-not $KnownBids.ContainsKey($bid)) {
          $findings.Add(("'{0}': the registrar aliased the proposed id to '{1}', which no commodity namespace carries either" -f $raw, $bid)) | Out-Null
          continue
        }
      } elseif ($verdict -eq 'approve') {
        # minted, and the board field is whatever the ruling said - the id has no vocabulary row yet
      } elseif ($verdict -eq 'reject') {
        $findings.Add(("'{0}': the commodity-registrar REJECTED the new id '{1}' - {2}" -f $raw, $bid, ([string]$g.reason))) | Out-Null
        continue
      } else {
        $findings.Add(("'{0}' proposes the NEW commodity id '{1}' - no commodity namespace carries it and no commodity-registrar ruling approves it. A duplicate id lets the same food carry two disagreeing prices while every per-file guard reads green" -f $raw, $bid)) | Out-Null
        continue
      }
    }

    $decision = Get-AssembledDecision $rulingDecision $optional
    if ($decision -eq 'optional-note') {
      # not something the shopper buys: no grams, no buy string, and it is NAMED rather than dropped
      $ings.Add([pscustomobject]@{
        source_raw = $raw; item = $(if ($item) { $item } else { $null }); bid = $null; board = $null
        grams = 0; buy = ''; optional = $true; decision = $decision
        notes = $(if ($ruling) { [string]$ruling.evidence } elseif ($line) { [string]$line.notes } else { '' }) }) | Out-Null
      continue
    }

    if (-not $item -and $rulingDecision -eq 'mapped-null' -and [string]$ruling.term) {
      # MEASURED ON THE PHASE-6A GATE DRILL, 2026-08-24. The live mapper ruled `mustard powder`
      # `mapped-null` with canon_item null - correctly REFUSING to bridge dry ground seed onto the
      # prepared-condiment id (a true form flip on both price and gram weight, and it argued the case
      # in writing). `mapped-null` means "a real food with no commodity id", which is pantry-static
      # pricing and is the safe answer rule 1 asks for. But it nulled the NAME along with the id, and a
      # line with no food cannot be costed or weighed - so the whole recipe died on a naming
      # convention after the judgment had already been made correctly.
      # The food's name is sitting in the ruling's own `term`, which came from the extraction. Use it,
      # and NAME the substitution rather than doing it quietly.
      $item = [string]$ruling.term
      $paraphrased.Add(("'{0}' was ruled mapped-null with no canon_item; the food is named from its own term" -f $item)) | Out-Null
    }
    if (-not $item) {
      $findings.Add(("'{0}' carries no item name after assembly - a line with no food cannot be priced or weighed" -f $raw)) | Out-Null
      continue
    }

    # ---- THE GRAMS: EVERY ROAD IS SOURCE BASIS, AND THE SCALE IS APPLIED ONCE, HERE. --------------
    #
    # CORRECTED 2026-08-24 BY THE PHASE-6A GATE DRILL, and it is the most important thing that drill
    # found. The first build asked the mapper for TARGET grams - the weight matching its own
    # target-scale buy string - and the live mapper returned SOURCE grams on every single line it
    # stated one for. Ten lines across two recipes, and the ratio was EXACTLY the recipe's own scale
    # factor every time: "3 1/2 lb boneless skinless chicken breast" carrying 454 g (3.50x), "2 1/3 lb
    # bulk Italian sausage" carrying 454 g (2.33x), "5 1/4 cups nonfat milk" carrying 368 g.
    #
    # THAT IS NOT SLOPPINESS, IT IS THE ONLY SENSIBLE READING OF ITS INPUTS. Every gram the mapper is
    # shown - the table's `grams_source_basis`, the source recipe's own printed measures - is source
    # basis. Asking it to hand back a differently-based number in a field called `grams` was asking a
    # model to remember an invisible convention, and the estate's own rule is that a rule a model must
    # remember is a rule it sometimes forgets (phase 3 measured this stage answering ADVANCE once and
    # HOLD once to its own standing rule).
    #
    # So the basis is now the same on every road: the mapper states `grams_source` (or `grams`, read
    # the same way), the engine states `grams_source_basis`, and THIS LINE is the only place a scale
    # is ever applied. Quantization still lives in the buy string and is worth up to a few percent -
    # a basis error was worth 250%, and the band gate would have retired both of the drill's recipes
    # at 212 and 217 cal against a 400 floor. Failing closed is the right direction and throwing away
    # a good recipe on a fabricated number is D8's own named worse-than-no-gate case.
    $grams = $null
    $gramsFrom = ''
    foreach ($src in @($ruling, $line)) {
      if ($null -eq $src) { continue }
      foreach ($f in @('grams_source', 'grams')) {
        if ($src.PSObject.Properties.Name -contains $f -and $null -ne $src.$f) {
          try { $grams = [double]$src.$f } catch { $grams = $null }
          if ($null -ne $grams) {
            $gramsFrom = $(if ($src -eq $ruling) { 'ruling' } else { 'line' })
            break
          }
        }
      }
      if ($null -ne $grams) { break }
    }
    if ($null -ne $grams -and $scale -gt 0) { $grams = $grams * $scale }
    if ($null -eq $grams -and $null -ne $row.grams_source_basis -and $scale -gt 0) {
      $grams = [double]$row.grams_source_basis * $scale
      $gramsFrom = 'engine'
    }
    # THE CROSS-CHECK, on every line where BOTH the engine and the mapper weighed the same food. A
    # quantized buy string moves a few percent; a basis error moves by the scale factor. Anything past
    # 50% is not rounding, and it is NAMED rather than quietly averaged away.
    # B2 (2026-08-24): A CROSS-CHECK BETWEEN A GROUNDED NUMBER AND A GUESS IS NOISE, NOT EVIDENCE.
    # The engine says so itself: `grams_basis_fallback` carries its own flag for any weight it could
    # not derive from the food's densities.json row or each-noun. Comparing the mapper's grounded
    # ruling against that guess and PARKING the recipe is a guard firing on the engine's own admitted
    # ignorance - measured on fresh parsley, where 3 x sauce-density 16 g = 48 g made a correct 40 g
    # ruling look like a 0.24x error. The check keeps its FULL force wherever both sides are grounded,
    # which is where a disagreement means something.
    #
    # WHAT THIS COSTS, SAID PLAINLY: on an ungrounded line nothing now cross-checks the mapper. Three
    # things blunt it - the line is RECORDED to the run's density-gaps file below, so it is visible
    # rather than silent; the mapper's ruling is evidence-gated already; and the band gate plus the
    # macro recompute still catch a gross error downstream.
    $guessWhy = Get-EngineWeightGuessReason $row $raw
    $engineGuessed = [bool]$guessWhy
    if ($guessWhy -and -not ($row.PSObject.Properties.Name -contains 'grams_basis_fallback' -and $row.grams_basis_fallback)) {
      $row | Add-Member -NotePropertyName 'grams_basis_fallback' -NotePropertyValue $guessWhy -Force
    }
    # B2's SECOND FAMILY, MEASURED 2026-08-27: A COUNT GUESS ON A LINE THAT STATES ITS OWN WEIGHT.
    #
    # `grams_basis_fallback` catches the derivations parse-compute KNOWS it could not ground - default
    # tbsp, default tsp, a handful with no density. It does not catch this one, because the engine
    # thinks it did fine: on "2 medium 1.5 lbs. chicken breasts" it read the leading count and the
    # each-noun, made 2 x 200 g = 400 g, and set NO fallback flag. The line states 1.5 lbs - 680 g -
    # and the engine simply did not look at it. So a guess arrived wearing the grounded flag, and the
    # cross-check below then fired at full force against the mapper's correct 680 g reading and
    # PARKED the recipe. honey-balsamic-chicken-tenders stuck on it three times in one run, the same
    # 1.7x every time: deterministic, not a slip.
    #
    # THE FIX IS NOT TO RE-TOKENIZE THE LINE. parse-compute feeds all 574 live specs and their costed
    # numbers; changing how it reads a count-plus-weight line is a blast radius nobody asked for
    # inside a recipe run. What is safe, and is exactly B2's own argument, is to stop treating the
    # engine's number as AUTHORITATIVE when the line itself carries a mass the engine's answer
    # contradicts. Demoted to a gap, the cross-check is skipped and the mapper's grounded ruling
    # stands - which on every line of this shape is the stated weight, the one thing on the line that
    # is not an estimate.
    #
    # NARROW BY CONSTRUCTION: it fires only where the raw line states an explicit mass AND the engine
    # landed materially away from it. A line with no stated mass is untouched, and so is one where
    # the engine agrees with the mass it states. Both roads are inside
    # Get-EngineWeightGuessReason above, which is what $engineGuessed is set from.
    if ($engineGuessed -and $null -ne $row.grams_source_basis) {
      $gapRows.Add([pscustomobject]@{
        slug = [string]$Table.slug; raw = $raw; item = $item
        engine_grams_source = [double]$row.grams_source_basis
        engine_basis = [string]$row.grams_basis_fallback
        ruling_grams_target = $(if ($gramsFrom -ne 'engine' -and $null -ne $grams) { [Math]::Round([double]$grams, 1) } else { $null })
      }) | Out-Null
      $paraphrased.Add(("'{0}': the qty engine could not ground this weight ({1}), so its number is a fallback and the cross-check is skipped; recorded to the density gaps list" -f $raw, [string]$row.grams_basis_fallback)) | Out-Null
    }
    if (-not $engineGuessed -and $gramsFrom -ne 'engine' -and $null -ne $grams -and $null -ne $row.grams_source_basis -and $scale -gt 0) {
      $engineTarget = [double]$row.grams_source_basis * $scale
      # A SUB-GRAM REFERENCE IS NOT A REFERENCE. Below 1 g the ratio is dominated by rounding on both
      # sides - a dried-parsley line the engine makes 0.4 g reads as a 2.5x disagreement against a
      # perfectly honest 1 g, which is noise wearing a finding's clothes.
      if ($engineTarget -ge 1) {
        $ratio = $grams / $engineTarget
        if ($ratio -gt 1.5 -or $ratio -lt 0.667) {
          $findings.Add(("'{0}': the ruling weighs it {1} g at target scale and the qty engine makes it {2} g - a {3}x disagreement. Quantizing a printed measure moves a few percent; this is a different basis or a different food" -f $raw, [int]$grams, [int]$engineTarget, [Math]::Round($ratio, 2))) | Out-Null
        }
      }
    }
    if ($null -eq $grams -or $grams -le 0) {
      # A QUANTITY-LESS GARNISH IS NOT A PURCHASABLE LINE (Brad's ruling 2026-08-24, after the 6b
      # proving run parked `cheese-stuffed-chicken-parmesan` on "Fresh parsley (to garnish)").
      #
      # The estate already has the right ruling for this shape - `not-purchased` -> `optional-note`,
      # whose own comment above names "water, a garnish, a sub-recipe" - and an optional-note line is
      # NAMED in the file rather than dropped, so the reader still sees the garnish and the cost and
      # macros are untouched. The mapper simply did not reach for it, and the estate's standing rule
      # is that a rule a model must remember is a rule it sometimes forgets. So it is mechanical here.
      #
      # PLACED DELIBERATELY INSIDE THE REFUSAL, NOT BEFORE IT. The trigger is "neither the qty engine
      # nor the mapper could weigh this line", which IS the quantity test: a garnish that states a
      # measure ("2 tablespoons chopped parsley, for garnish") gets grams from the engine and never
      # reaches here. So this can only ever fire where the recipe dies today, and it cannot change a
      # single line that currently works.
      # D5: AN ALTERNATIVES LINE NAMES A CHOICE, SO CHOOSE - cheapest exact match, disclosed.
      #
      # SCOPE, STATED HONESTLY. This settles the line's IDENTITY, not its weight. The motivating line
      # ("Prepared brown and wild rice blend, brown rice, quinoa, or cauliflower rice") states no
      # quantity at all - it is a serving base, the same shape as a garnish - so once the food is
      # chosen there is still nothing to weigh, and the line becomes an optional note naming ONE food
      # instead of a menu. That is strictly better for the shopper and it invents no number.
      # An alternatives line that DOES state a measure is not handled here: it would need the qty
      # engine re-run against the chosen food, which is a bigger change and is recorded as such.
      $altFoods = @(Split-AlternativeFoods $raw)
      if ($altFoods.Count -ge 2) {
        $pick = Select-CheapestAlternative -Foods $altFoods
        if ($pick) {
          $ings.Add([pscustomobject]@{
            source_raw = $raw; item = $pick.term; bid = $null; board = $null
            grams = 0; buy = ''; optional = $true; decision = 'optional-note'
            notes = ("serving base, no quantity stated by the source. " + $pick.evidence) }) | Out-Null
          $paraphrased.Add(("'{0}' offers a CHOICE of foods and states no quantity; {1}" -f $raw, $pick.evidence)) | Out-Null
          continue
        }
        # NONE of them resolved exactly. That is not a licence to guess - an include-pattern match is
        # how 'cauliflower rice' prices as white rice - so the line falls through to the refusal below
        # and the recipe parks, which is the honest outcome.
        $paraphrased.Add(("'{0}' offers a CHOICE of foods but none of them resolves to a board id or label, so none was chosen" -f $raw)) | Out-Null
      }
      if (Test-IsGarnishLine $raw) {
        $ings.Add([pscustomobject]@{
          source_raw = $raw; item = $(if ($item) { $item } else { $null }); bid = $null; board = $null
          grams = 0; buy = ''; optional = $true; decision = 'optional-note'
          notes = ("garnish with no stated quantity - nothing to buy, weigh or cost; recorded so the reader still sees it") }) | Out-Null
        $paraphrased.Add(("'{0}' reads as a garnish with no stated quantity, so it is recorded as an optional note rather than costed" -f $raw)) | Out-Null
        continue
      }
      if (Test-IsPantrySeasoningToTaste $raw) {
        $ings.Add([pscustomobject]@{
          source_raw = $raw; item = $(if ($item) { $item } else { $null }); bid = $null; board = $null
          grams = 0; buy = ''; optional = $true; decision = 'optional-note'
          notes = ("pantry seasoning stated 'to taste' - no quantity to buy, weigh or cost; recorded so the reader still sees it") }) | Out-Null
        $paraphrased.Add(("'{0}' is a pantry seasoning stated 'to taste', so it is recorded as an optional note rather than costed" -f $raw)) | Out-Null
        continue
      }
      # THE ESTATE ALREADY RULED THIS LINE WEIGHS NOTHING (D1, arriving as a ruling rather than as a
      # phrase). See Test-IsRuledZeroOptional for the mechanism and for why all four signals are
      # required. LAST of the four exemptions on purpose: the three above read the RAW LINE and can
      # settle a line no ruling covers, and this one reads what the mapper WROTE, so it is the last
      # chance before the honest refusal and it cannot pre-empt D5's alternatives pick.
      #
      # IT LANDS AS `optional-note`, NOT AS `mapped-optional` AT 0 g, and that is not cosmetic - it is
      # the only shape that survives the next stage. build-intake-skeleton's Get-LineClass sends
      # `mapped-optional` to class `optional`, which is COUNTED, and its own `$g -le 0` arm then raises
      # "'Fresh Basil' is included (mapped-optional) but carries no grams" and the recipe dies one
      # stage further along. `optional-note` classes `not-purchased`: excluded from cost and macros,
      # and NAMED in the intake's notes, which is exactly what D1 asks for.
      if (Test-IsRuledZeroOptional -Optional $optional -RulingDecision $rulingDecision -Bid $bid -Grams $grams -GramsFrom $gramsFrom) {
        $ings.Add([pscustomobject]@{
          source_raw = $raw; item = $item; bid = $null; board = $null
          grams = 0; buy = ''; optional = $true; decision = 'optional-note'
          notes = $(if ($ruling -and $ruling.evidence) { [string]$ruling.evidence }
                    elseif ($line -and $line.notes) { [string]$line.notes }
                    else { 'ruled optional with an explicit zero weight - nothing to buy, weigh or cost; recorded so the reader still sees it' }) }) | Out-Null
        $paraphrased.Add(("'{0}' was ruled optional with an explicit 0 g and no bid, so it is recorded as an optional note rather than costed" -f $raw)) | Out-Null
        continue
      }
      # NEVER A SILENT ZERO. A zero-gram line is an ingredient the reader buys and the card ignores,
      # and it is the fabricated-band defect from D8's own header arriving one stage earlier.
      $findings.Add(("'{0}' has no gram weight from the engine or from a ruling - a purchasable line with no weight cannot be costed and its macros would be computed as if the food were not there" -f $raw)) | Out-Null
      continue
    }

    $buy = ''
    if ($line) { $buy = [string]$line.buy }
    if (-not $buy) {
      $findings.Add(("'{0}' has no buy string - that line is printed verbatim in the reader's Ingredients section and D8 locks it, so there is nothing to lock" -f $raw)) | Out-Null
      continue
    }

    $notes = ''
    if ($line -and $line.notes) { $notes = [string]$line.notes }
    if ($ruling -and $ruling.evidence) { $notes = (@($notes, [string]$ruling.evidence) | Where-Object { $_ }) -join ' ' }
    if (-not $notes -and -not $isResidual) { $notes = ("pre-resolved mechanically: " + [string]$row.evidence) }

    $ings.Add([pscustomobject]@{
      source_raw = $raw
      item       = $item
      bid        = $(if ($bid) { $bid } else { $null })
      board      = $(if ($board) { $board } else { $null })
      # A SUB-HALF-GRAM LINE ROUNDS TO ZERO, AND ZERO IS THE ONE VALUE THIS FILE MAY NOT CARRY.
      # Measured on the gate drill: two bay leaves at 2.33x is 0.47 g, dried oregano 1 1/4 tsp is
      # 0.4 g, and all three rounded to 0 - past the `-le 0` refusal above, which sees the unrounded
      # number. build-intake-skeleton then DROPPED them with "included but carries no grams", which is
      # the silent-zero this assembler exists to refuse, arriving through [Math]::Round.
      # A bay leaf is a thing the shopper buys, so it is floored at 1 g rather than dropped or refused:
      # refusing would kill good recipes over herbs, and dropping is the fabricated-band defect.
      grams      = [Math]::Max(1, [int][Math]::Round($grams, 0))
      buy        = $buy
      optional   = $optional
      decision   = $decision
      notes      = $notes
      grams_from = $gramsFrom }) | Out-Null
    # THE RULING MUST NOT REFUSE THE ID IT IS BIDDING (2026-08-24). See Test-BidContradictsNotes for
    # the founding case. Which side is wrong is not knowable here, so both halves are quoted back and
    # the recipe parks - the same safe direction every other finding in this assembler takes.
    # PINNED TO `$ruledBid`, THE MAPPER'S OWN BID - never `$bid`, which the registrar gate above may
    # have rewritten to an alias target the mapper never saw. See the capture site for the measured
    # false positive that rewrite produced.
    if (Test-BidContradictsNotes -Bid $ruledBid -Notes $notes) {
      $findings.Add(("'{0}': the ruling BIDS '{1}' and its own evidence says it refused that id - '{2}'. One of the two is wrong and this file cannot tell which, so nothing is assembled over it" -f $raw, $ruledBid, ($notes -replace '\s+', ' ').Trim().Substring(0, [Math]::Min(160, ($notes -replace '\s+', ' ').Trim().Length)))) | Out-Null
    }
    if ($item -and -not $terms.Contains($item)) { $terms.Add($item) | Out-Null }
  }

  $protein = ''
  if ($StateRow -and $StateRow.protein) { $protein = [string]$StateRow.protein }
  if (-not $protein -and $Payload.protein) { $protein = [string]$Payload.protein }
  if (-not $protein) {
    $findings.Add('no protein: the run state file names none and the mapper returned none. D8 refuses to build a skeleton without it, and the wave manifest is built out of exactly this field') | Out-Null
  }

  if ($findings.Count) { return [pscustomobject]@{ doc = $null; findings = $findings.ToArray(); density_gaps = $gapRows.ToArray() } }

  $doc = [ordered]@{
    slug            = [string]$Table.slug
    title           = [string]$Table.title
    source_url      = [string]$Table.source_url
    source_servings = $srcServ
    target_servings = $TargetServ
    scale_factor    = $scale
    protein         = $protein
    mapped_by       = 'recipe-ingredient-mapper'
    assembled_by    = 'map-preresolve.ps1 -Assemble'
    mapped_at       = (Get-Date -Format 'yyyy-MM-dd')
    conventions     = 'buy strings are cook measures (what goes in the pot). Grams are TARGET-scale: the mapper states them where its printed measure quantizes away from the exact scale, and otherwise they are parse-compute''s source-basis weight for that line multiplied by scale_factor exactly once.'
    ingredients          = $ings.ToArray()
    pricing_terms_needed = @((As-Array $Payload.absent_terms) | ForEach-Object { [string]$_ })
    ruled_substitutions  = @((As-Array $Payload.ruled_substitutions))
    rejected             = @((As-Array $Payload.rejected))
    # CHANGE M (2026-08-25): the DAEMON writes food-macros-db.json now, so this records what it
    # WROTE rather than what the mapper claimed to have written. Renamed with the meaning.
    db_entries_written   = @((As-Array $Payload.db_entries_written))
    db_row_findings      = @((As-Array $Payload.db_row_findings))
    new_commodity_proposals = @((As-Array $Payload.new_commodity_proposals))
    registrar_rulings    = @((As-Array $Payload.registrar_rulings))
    # NAMED, NEVER SILENT. Every line joined by the fallback rather than by an exact raw copy is
    # recorded here, so a model that quietly stops copying the join key is visible in the artifact
    # instead of only in a run that happened to fail.
    join_fallbacks       = @($paraphrased.ToArray())
    macro_cross_check    = $Payload.macro_cross_check
  }
  return [pscustomobject]@{ doc = [pscustomobject]$doc; findings = @(); density_gaps = $gapRows.ToArray() }
}

# ---------------------------------------------------------------------------------------------------
# SELF-TEST. Every fixture over a collection uses at least three elements - the PS 5.1 collection traps
# were all invisible at size one, which was exactly the size their first fixtures used.
# ---------------------------------------------------------------------------------------------------
if ($runSelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ("  ok    " + $n) } else { Write-Output ("  X     " + $n + "   got: " + $got); $script:bad++ }
  }

  # A vocabulary with the shapes that matter: a plain wired row, an ADJUDICATED ALIAS, a row with NO
  # BID (six of the live 282 are exactly this), and the near-miss pair that founded the whole rule.
  $vocab = @(
    [pscustomobject]@{ item='Boneless Skinless Chicken Thigh'; bid='chicken-thighs'; unit='lb'; board='weekly'; gpu=453.592; aliases=@('Boneless Skinless Chicken Thighs') },
    [pscustomobject]@{ item='White Wine Vinegar'; bid='white-wine-vinegar'; unit='floz'; board='recipe'; gpu=29.6 },
    [pscustomobject]@{ item='Yellow Onion'; bid='onions'; unit='lb'; board='weekly'; gpu=453.592 },
    [pscustomobject]@{ item='Sumac'; bid=''; unit='oz'; board='recipe'; gpu=$null },
    [pscustomobject]@{ item='Shaved Beef Steak'; bid='shaved-beef-steak'; unit='lb'; board='weekly'; gpu=453.592 }
  )
  $dens   = @{ 'Boneless Skinless Chicken Thigh'=1; 'Yellow Onion'=1; 'White Wine Vinegar'=1; 'Shaved Beef Steak'=1 }
  $each   = @{ 'Yellow Onion'=1 }
  $foodDb = @{ 'Boneless Skinless Chicken Thigh'=1; 'Yellow Onion'=1; 'White Wine Vinegar'=1; 'Shaved Beef Steak'=1; 'Sumac'=1 }

  # ---- FIXTURE 1. THE KEY FUNCTION IS THE CACHE'S OWN. The resolutions ledger is keyed by
  # ingredient-resolutions.ps1's Get-TermKey; a second spelling of that normalisation is a cache that
  # silently never hits, which reads exactly like a cache that was never populated.
  T 'the term key matches ingredient-resolutions.ps1 byte for byte on the cases its own suite pins' `
    ((Get-TermKey '  Shaved Beef Steak, ') -eq 'shaved beef steak' -and
     (Get-TermKey 'sour    cream') -eq 'sour cream' -and
     (Get-TermKey 'beef steak') -ne (Get-TermKey 'shaved beef steak') -and
     (Get-TermKey '') -eq '') `
    ((Get-TermKey '  Shaved Beef Steak, ') + ' / ' + (Get-TermKey 'sour    cream'))

  # ---- FIXTURE 1b. THE RETURN-BOUNDARY UNROLL, frozen (2026-08-24, measured on this script's own
  # first build). A function ending `return @($x)` hands back the bare element when the array holds
  # ONE thing, and `.Count` on a bare PSCustomObject is $null in PS 5.1 - so `if ($c.Count)` reads
  # false and the branch silently does not run. It dropped the vocabulary's near-miss candidates out
  # of the evidence for every single-candidate line: the row still said `different-form`, but the
  # WHY - "White Wine Vinegar, DIFFERENT FORM: vinegar" - was gone, which is the one thing the mapper
  # is being handed the table for. Both sizes, because the defect is invisible at the other one.
  $one   = As-Array @([pscustomobject]@{ item='White Wine Vinegar'; different_form=$true })
  $three = As-Array @([pscustomobject]@{ item='a' }, [pscustomobject]@{ item='b' }, [pscustomobject]@{ item='c' })
  T 'MUST FIRE  a ONE-element collection survives the return boundary as a collection, Count 1' `
    ($one.Count -eq 1) ("Count=" + [string]$one.Count)
  T 'CLEAN TWIN a three-element collection is still three' ($three.Count -eq 3) ("Count=" + [string]$three.Count)
  T 'CLEAN TWIN and $null reads as an empty collection, never as one null element' `
    ((As-Array $null).Count -eq 0) ("Count=" + [string](As-Array $null).Count)
  # ...and the price of the comma, frozen in both directions. An array returned this way enters a
  # PIPELINE as ONE object: `As-Array $x | Where-Object` filters a collection of one, which is how a
  # table with eight uncovered lines reported none of them on 2026-08-24. Wrapping the call in @()
  # unrolls it again, and `foreach` never needed the wrap in the first place.
  $pipeBare  = @(As-Array @('a','b','c') | Where-Object { $_ -ne 'b' })
  $pipeAt    = @(@(As-Array @('a','b','c')) | Where-Object { $_ -ne 'b' })
  $pipeParen = @((As-Array @('a','b','c')) | Where-Object { $_ -ne 'b' })
  T 'MUST FIRE  piping STRAIGHT off As-Array filters ONE object, not three elements (the comma''s price)' `
    ($pipeBare.Count -eq 1) ("Count=" + [string]$pipeBare.Count)
  T 'MUST FIRE  and @() around the CALL does NOT fix it - it collects one output object holding an array' `
    ($pipeAt.Count -eq 1) ("Count=" + [string]$pipeAt.Count)
  T 'CLEAN TWIN PARENTHESISING the call hands the pipeline the array itself, and the filter sees three' `
    ($pipeParen.Count -eq 2 -and ($pipeParen -join '') -eq 'ac') (($pipeParen -join ','))

  # ---- FIXTURE 2. THE CLASSIFIER, every branch, as a pure table. This is the judgment the whole
  # script exists to make, and it is worth having fixtured away from any file on disk.
  T 'MUST FIRE  a canon item with a wired bid is `resolved`' `
    ((Get-Resolution 'Yellow Onion' $true 'RESOLVES' $true) -eq 'resolved') (Get-Resolution 'Yellow Onion' $true 'RESOLVES' $true)
  T 'MUST FIRE  a canon item with NO wired bid is `unbid` - the hold, not a mapper question' `
    ((Get-Resolution 'Sumac' $false 'RESOLVES' $true) -eq 'unbid') (Get-Resolution 'Sumac' $false 'RESOLVES' $true)
  T 'MUST FIRE  a near miss on a FORM word is `different-form`, never quietly resolved' `
    ((Get-Resolution '' $false 'DIFFERENT-FORM' $true) -eq 'different-form') (Get-Resolution '' $false 'DIFFERENT-FORM' $true)
  T 'MUST FIRE  nothing in the vocabulary AND nothing in the food DB is a `new-food-suspect`' `
    ((Get-Resolution '' $false 'GENUINE-GAP' $false) -eq 'new-food-suspect') (Get-Resolution '' $false 'GENUINE-GAP' $false)
  T 'CLEAN TWIN a gap the food DB DOES know is only `unresolved` - there is no label to transcribe' `
    ((Get-Resolution '' $false 'GENUINE-GAP' $true) -eq 'unresolved') (Get-Resolution '' $false 'GENUINE-GAP' $true)
  T 'CLEAN TWIN a plain rename candidate is `unresolved`, for the mapper to rule' `
    ((Get-Resolution '' $false 'RENAME' $true) -eq 'unresolved') (Get-Resolution '' $false 'RENAME' $true)

  # ---- FIXTURE 3. THE RESIDUAL SPLIT. `unbid` is NOT residual, and that is the whole point of the
  # mechanical hold: the adapter drill asked the mapper its own standing rule twice, same prompt and
  # same model, and got ADVANCE once and HOLD once. A rule a model must remember is a rule it
  # sometimes forgets, and this one gates whether a writer gets paid.
  T 'MUST FIRE  `unbid` is a HOLD and never reaches the mapper''s residual' `
    (-not (Test-IsResidual 'unbid')) 'counted as residual'
  T 'MUST FIRE  `resolved` never reaches the residual either' (-not (Test-IsResidual 'resolved')) 'counted as residual'
  T 'CLEAN TWIN all three judgment classes DO reach the residual' `
    ((Test-IsResidual 'unresolved') -and (Test-IsResidual 'different-form') -and (Test-IsResidual 'new-food-suspect')) 'a judgment class was dropped'
  T 'MUST FIRE  a hold names the follow-up rather than leaving the recipe looking stuck' `
    ((Get-HoldReason 'sumac' 'Sumac' '') -match 'wire the bid' -and (Get-HoldReason 'sumac' 'Sumac' '') -match 'no agent') `
    (Get-HoldReason 'sumac' 'Sumac' '')

  # ---- FIXTURE 4. THE WHOLE TABLE OVER A FIVE-LINE RECIPE. Five lines and not one, because every PS
  # 5.1 collection trap this plan pins was invisible at size one: the OrderedDictionary indexer, @()
  # over a List[object] of dictionaries, and @(ConvertFrom-Json) binding one Object[].
  $extraction = [pscustomobject]@{
    title = 'Drill Dish'; source_url = 'https://d/x'; servings = 4
    ingredients = @(
      [pscustomobject]@{ raw='2 lbs shaved beef steak'; item='shaved beef steak'; qty='2'; unit='lbs'; optional=$false },
      [pscustomobject]@{ raw='1 1/2 lbs boneless skinless chicken thighs'; item='boneless skinless chicken thighs'; qty='1 1/2'; unit='lbs'; optional=$false },
      [pscustomobject]@{ raw='1 small yellow onion, chopped'; item='Yellow Onion'; qty='1'; unit=$null; optional=$false },
      [pscustomobject]@{ raw='1 teaspoon sumac'; item='Sumac'; qty='1'; unit='teaspoon'; optional=$false },
      [pscustomobject]@{ raw='1/2 cup dry white wine'; item='dry white wine'; qty='1/2'; unit='cup'; optional=$false },
      [pscustomobject]@{ raw='1 tablespoon ras el hanout'; item='ras el hanout'; qty='1'; unit='tablespoon'; optional=$false }
    )
  }
  # The cache holds the FIRST line and nothing else, so the fixture can show a cache hit skipping the
  # mapper while an identical-looking line beside it does not.
  $cache = @{ 'shaved beef steak' = [pscustomobject]@{ key='shaved beef steak'; item_id='shaved-beef-steak'; bid_exists=$true; by='mapper'; at='2026-08-20' } }
  # ingredient-vocab's verdicts, as its -Missing road returns them.
  $classes = @{
    'shaved beef steak'                 = [pscustomobject]@{ name='shaved beef steak'; class='GENUINE-GAP'; candidates=@() }
    'boneless skinless chicken thighs'  = [pscustomobject]@{ name='boneless skinless chicken thighs'; class='RESOLVES'; resolves_to='Boneless Skinless Chicken Thigh'; candidates=@() }
    'Yellow Onion'                      = [pscustomobject]@{ name='Yellow Onion'; class='RESOLVES'; resolves_to='Yellow Onion'; candidates=@() }
    'Sumac'                             = [pscustomobject]@{ name='Sumac'; class='RESOLVES'; resolves_to='Sumac'; candidates=@() }
    'dry white wine'                    = [pscustomobject]@{ name='dry white wine'; class='DIFFERENT-FORM'
                                                             candidates=@([pscustomobject]@{ item='White Wine Vinegar'; bid='white-wine-vinegar'; different_form=$true; form_diff=@('vinegar') }) }
    'ras el hanout'                     = [pscustomobject]@{ name='ras el hanout'; class='GENUINE-GAP'; candidates=@() }
  }
  $tbl = New-PreResolveTable 'drill-dish' $extraction $vocab $classes @{} $cache $dens $each $foodDb
  $byTerm = @{}; foreach ($r in $tbl.rows) { $byTerm[[string]$r.term] = $r }

  T 'MUST FIRE  a six-line recipe produces SIX rows, not one composite (the PS 5.1 collection traps)' `
    ($tbl.line_count -eq 6 -and @($tbl.rows).Count -eq 6) ("line_count=" + $tbl.line_count + " rows=" + @($tbl.rows).Count)
  T 'MUST FIRE  a CACHE-RESOLVED term never reaches the residual (D7''s named fixture)' `
    ($byTerm['shaved beef steak'].resolution -eq 'resolved' -and $byTerm['shaved beef steak'].source -eq 'cache' -and
     $tbl.residual_terms -notcontains 'shaved beef steak') `
    ($byTerm['shaved beef steak'].resolution + '/' + [string]$byTerm['shaved beef steak'].source)
  T 'MUST FIRE  ...and it carries the prior ruling as evidence, so the mapper can see WHY it was skipped' `
    ($byTerm['shaved beef steak'].evidence -match 'prior ruling') $byTerm['shaved beef steak'].evidence
  T 'MUST FIRE  an ADJUDICATED ALIAS resolves and is marked source=alias, not source=vocab' `
    ($byTerm['boneless skinless chicken thighs'].resolution -eq 'resolved' -and
     $byTerm['boneless skinless chicken thighs'].source -eq 'alias' -and
     $byTerm['boneless skinless chicken thighs'].canon_item -eq 'Boneless Skinless Chicken Thigh') `
    ([string]$byTerm['boneless skinless chicken thighs'].source + '/' + [string]$byTerm['boneless skinless chicken thighs'].canon_item)
  T 'CLEAN TWIN an exact vocabulary name is source=vocab' `
    ($byTerm['Yellow Onion'].source -eq 'vocab' -and $byTerm['Yellow Onion'].resolution -eq 'resolved') `
    ([string]$byTerm['Yellow Onion'].source)
  T 'MUST FIRE  an UNBID resolved term holds the recipe with a NAMED follow-up (D7''s second fixture)' `
    ($byTerm['Sumac'].resolution -eq 'unbid' -and $tbl.hold_count -eq 1 -and
     [string]@($tbl.holds)[0].term -eq 'Sumac' -and [string]@($tbl.holds)[0].why -match 'wire the bid') `
    ($byTerm['Sumac'].resolution + ' holds=' + $tbl.hold_count)
  T 'MUST FIRE  ...and the unbid line is NOT in the residual - the hold is mechanical, not a question' `
    ($tbl.residual_terms -notcontains 'Sumac') (($tbl.residual_terms) -join ',')
  T 'MUST FIRE  "dry white wine" is flagged DIFFERENT FORM against "White Wine Vinegar", never matched' `
    ($byTerm['dry white wine'].resolution -eq 'different-form' -and $null -eq $byTerm['dry white wine'].canon_item -and
     $byTerm['dry white wine'].evidence -match 'DIFFERENT FORM') `
    ($byTerm['dry white wine'].resolution + ' -> ' + [string]$byTerm['dry white wine'].canon_item)
  T 'CLEAN TWIN a genuine gap the food DB has never heard of is a new-food suspect' `
    ($byTerm['ras el hanout'].resolution -eq 'new-food-suspect') $byTerm['ras el hanout'].resolution
  T 'MUST FIRE  the residual is exactly the two judgment lines - three of six pre-resolved, one held' `
    ($tbl.residual_count -eq 2 -and $tbl.resolved_count -eq 3 -and $tbl.hold_count -eq 1) `
    ("residual=" + $tbl.residual_count + " resolved=" + $tbl.resolved_count + " held=" + $tbl.hold_count)
  T 'the prerequisite flags are facts, not guesses: a wired row knows its gpu, an unknown food does not' `
    ($byTerm['Yellow Onion'].gpu_known -and $byTerm['Yellow Onion'].density_known -and
     -not $byTerm['ras el hanout'].fooddb_known -and -not $byTerm['ras el hanout'].gpu_known) `
    ("onion gpu=" + $byTerm['Yellow Onion'].gpu_known + " rasel fooddb=" + $byTerm['ras el hanout'].fooddb_known)

  # ---- FIXTURE 5. THE UNHOLD, AS A PURE RE-RUN. The seed re-runs this script over `mapped` recipes;
  # a hold that has cleared must CLEAR, or a repaired recipe sits on the held list forever with nobody
  # re-checking anything. Same extraction, same everything, one wired bid different.
  $vocabWired = @($vocab | ForEach-Object {
    if ([string]$_.item -eq 'Sumac') { [pscustomobject]@{ item='Sumac'; bid='sumac'; unit='oz'; board='recipe'; gpu=28.3495 } } else { $_ } })
  $tbl2 = New-PreResolveTable 'drill-dish' $extraction $vocabWired $classes @{} $cache $dens $each $foodDb
  T 'MUST FIRE  wiring the bid CLEARS the hold on a re-run - the unhold path is mechanical' `
    ($tbl2.hold_count -eq 0 -and ($tbl2.rows | Where-Object { $_.term -eq 'Sumac' }).resolution -eq 'resolved') `
    ("holds=" + $tbl2.hold_count)
  T 'CLEAN TWIN and nothing else moved: the same two judgment lines are still residual' `
    ($tbl2.residual_count -eq 2 -and ($tbl2.residual_terms -join ',') -eq ($tbl.residual_terms -join ',')) `
    ("residual=" + $tbl2.residual_count + " [" + ($tbl2.residual_terms -join ',') + "]")

  # ---- FIXTURE 6. THE EXIT CODES, end to end, as a CHILD PROCESS. The pure fixtures above cannot see
  # an exit code, and section 4.5's convention is the contract the daemon reads: 1 is the NORMAL case,
  # 2 is BLOCKED and never a pass. An end-to-end drill is also the only thing that catches a collection
  # defect that only appears when results are collected - two of wave-preaudit's three day-one defects.
  $scratch = Join-Path $env:TEMP ('mpre-' + [guid]::NewGuid().ToString('N'))
  try {
    New-Item -ItemType Directory -Path (Join-Path $scratch 'extracted') -Force | Out-Null
    $vocabPath = Join-Path $scratch 'vocab.json'
    # 200-row floor in ingredient-vocab: pad with rows nothing in the fixture names.
    $pad = @(1..205 | ForEach-Object { [pscustomobject]@{ item=("Filler $_"); bid=("filler-$_"); unit='oz'; board='recipe'; gpu=28.3495 } })
    $allVocab = @($vocab) + $pad
    ($allVocab | ConvertTo-Json -Depth 5) | Set-Content $vocabPath -Encoding utf8
    $cachePath = Join-Path $scratch 'resolutions.json'
    ([pscustomobject]@{ count=1; resolutions=@([pscustomobject]@{ key='shaved beef steak'; term='shaved beef steak'; item_id='shaved-beef-steak'; bid_exists=$true; by='fixture'; at='2026-08-20' }) } | ConvertTo-Json -Depth 5) | Set-Content $cachePath -Encoding utf8

    # a slug whose every line pre-resolves -> exit 0
    ([pscustomobject]@{ title='Clean Dish'; source_url='https://d/c'; servings=4; ingredients=@(
        [pscustomobject]@{ raw='2 lbs shaved beef steak'; item='shaved beef steak'; optional=$false },
        [pscustomobject]@{ raw='1 yellow onion'; item='Yellow Onion'; optional=$false },
        [pscustomobject]@{ raw='2 tbsp white wine vinegar'; item='White Wine Vinegar'; optional=$false }
      ) } | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $scratch 'extracted\clean.json') -Encoding utf8
    # a slug with a genuine residual -> exit 1
    ([pscustomobject]@{ title='Residual Dish'; source_url='https://d/r'; servings=4; ingredients=@(
        [pscustomobject]@{ raw='1 yellow onion'; item='Yellow Onion'; optional=$false },
        [pscustomobject]@{ raw='1 tbsp ras el hanout'; item='ras el hanout'; optional=$false },
        [pscustomobject]@{ raw='1/2 cup dry white wine'; item='dry white wine'; optional=$false }
      ) } | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $scratch 'extracted\residual.json') -Encoding utf8

    $common = @('-RunDir', $scratch, '-NoBoard', '-VocabFile', $vocabPath, '-ResolutionsFile', $cachePath)
    $r0 = Invoke-Child $PSCommandPath ($common + @('-Slugs', @('clean')))
    T 'MUST FIRE  a fully pre-resolved batch exits 0 (and the mapper is STILL dispatched, for the cross-check)' `
      ($r0.rc -eq 0) ("rc=" + $r0.rc + " " + $r0.text.Trim())
    T 'MUST FIRE  ...and it still prints the NAME-COMPLETE marker, so "did it finish" is answerable' `
      ($r0.text -match 'MAP-PRERESOLVE-COMPLETE') $r0.text.Trim()
    $r1 = Invoke-Child $PSCommandPath ($common + @('-Slugs', @('residual')))
    T 'MUST FIRE  a batch with residual lines exits 1 - the NORMAL case, table written, dispatch proceeds' `
      ($r1.rc -eq 1) ("rc=" + $r1.rc + " " + $r1.text.Trim())
    T 'CLEAN TWIN a mixed batch of BOTH slugs is still exit 1, not averaged away' `
      ((Invoke-Child $PSCommandPath ($common + @('-Slugs', @('clean', 'residual')))).rc -eq 1) 'not 1'
    # The exit-2 drill runs against an EMPTY mapped-pre: r0 and r1 above already wrote tables, and
    # asserting "no partial batch" over their leftovers would assert nothing at all.
    Remove-Item (Join-Path $scratch 'mapped-pre') -Recurse -Force -ErrorAction SilentlyContinue
    $r2 = Invoke-Child $PSCommandPath ($common + @('-Slugs', @('clean', 'nosuchslug')))
    T 'MUST FIRE  a MISSING extraction is exit 2 - BLOCKED, never a clean bill and never a guess' `
      ($r2.rc -eq 2) ("rc=" + $r2.rc + " " + $r2.text.Trim())
    T 'MUST FIRE  ...and exit 2 writes NO table for the slugs it did reach: half a batch is worse than none' `
      (-not (Test-Path (Join-Path $scratch 'mapped-pre\clean.json'))) 'wrote a partial batch'

    # re-run the good pair so the tables exist for the shape assertions
    Invoke-Child $PSCommandPath ($common + @('-Slugs', @('clean', 'residual'))) | Out-Null
    $wrote = @(Get-ChildItem (Join-Path $scratch 'mapped-pre') -Filter '*.json' | ForEach-Object { $_.Name })
    T 'MUST FIRE  the table lands PER SLUG at mapped-pre\<slug>.json (section 4.5), never one shared file' `
      (@($wrote).Count -eq 2 -and $wrote -contains 'clean.json' -and $wrote -contains 'residual.json') (($wrote) -join ',')
    $disk = Read-Json (Join-Path $scratch 'mapped-pre\residual.json')
    $diskRows = As-Array $disk.rows
    T 'MUST FIRE  the file round-trips as THREE rows, each with section 4.5''s full field set' `
      (@($diskRows).Count -eq 3 -and
       (@('raw','canon_item','bid','board','resolution','gpu_known','density_known','fooddb_known','evidence','source') |
         Where-Object { $diskRows[0].PSObject.Properties.Name -notcontains $_ }).Count -eq 0) `
      ("rows=" + @($diskRows).Count + " fields=" + ((@($diskRows)[0].PSObject.Properties.Name) -join ','))
    T 'MUST FIRE  the live ingredient-vocab classified the batch (nothing here forks its head-noun rule)' `
      (($diskRows | Where-Object { $_.term -eq 'dry white wine' }).resolution -eq 'different-form') `
      (($diskRows | Where-Object { $_.term -eq 'dry white wine' }).resolution)

    # ---- FIXTURE 7. THE MACRO CROSS-CHECK, and the line it must not cross. MEASURED 2026-08-24 on the
    # four never-mapped phase-2 extractions: the arithmetic reached 9-12 lines of 17-20, and the line it
    # missed was the PROTEIN every single time - "boneless skinless chicken breasts" is residual exactly
    # because it carries the describing words the closed vocabulary has not ruled on. The numbers that
    # came back were 9.6-13.6 g protein per serving against a catalog floor of 25, with parse-compute's
    # 550-gate tuner injecting an auto Rice base that pushed carbs to 108-116 g on low-carb dinners.
    # Handing that to the mapper as "the pre-computed cross-check" is handing it a plausible wrong number
    # to verify. So a partial table ships NO number, and says which lines it could not reach.
    $rDisk = Read-Json (Join-Path $scratch 'mapped-pre\residual.json')
    $cDisk = Read-Json (Join-Path $scratch 'mapped-pre\clean.json')
    T 'MUST FIRE  a PARTIAL table ships NO computed macros - a number over the easy lines is not a check' `
      ($rDisk.macro_precheck.state -eq 'partial' -and $null -eq $rDisk.macro_precheck.computed_per_serving) `
      ([string]$rDisk.macro_precheck.state)
    T 'MUST FIRE  ...and it NAMES the lines the arithmetic could not reach, rather than just a count' `
      (@($rDisk.macro_precheck.uncovered_lines).Count -eq 2 -and
       (@($rDisk.macro_precheck.uncovered_lines) -contains 'ras el hanout') -and
       (@($rDisk.macro_precheck.uncovered_lines) -contains 'dry white wine')) `
      ((@($rDisk.macro_precheck.uncovered_lines)) -join ',')
    T 'CLEAN TWIN a FULLY pre-resolved table does get the pre-computed numbers - the exit-0 case' `
      ($cDisk.macro_precheck.state -eq 'computed' -and $null -ne $cDisk.macro_precheck.computed_per_serving -and
       $cDisk.macro_precheck.lines_covered -eq $cDisk.macro_precheck.lines_total) `
      ([string]$cDisk.macro_precheck.state + ' ' + [string]$cDisk.macro_precheck.lines_covered + '/' + [string]$cDisk.macro_precheck.lines_total)
    T 'MUST FIRE  a dish nobody published macros for says so, rather than reading as zero' `
      ([string]$cDisk.macro_precheck.source.from -eq 'none published' -and $null -eq $cDisk.macro_precheck.source.cal) `
      ([string]$cDisk.macro_precheck.source.from)
  } finally { Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue }

  # =================================================================================================
  # THE ASSEMBLER (A1 / pins P2-P6). Every fixture below is pure over New-MappedDecisionFile, except
  # the exit-code drill at the end, which runs this script as a child.
  # =================================================================================================

  # ---- THE REAL Get-LineClass, LIFTED OUT OF build-intake-skeleton.ps1 AT TEST TIME (pin P4). ------
  # NOT a copy, and not a dot-source either: that file has a param() block with its own [switch]$SelfTest
  # (which would reset ours in this scope - the first PS 5.1 trap in this script's header) and top-level
  # code that would exit out from under us. So the function's own SOURCE BYTES are read from the live
  # file and defined here. If somebody adds a decision class over there, this fixture sees it on the
  # next run; if somebody deletes the function, this fixture cannot run and says so, which is the
  # honest failure. What P4 buys is that the assembler's four output strings are checked against the
  # classifier that will actually read them, rather than against a second copy of its rules.
  $skelPath = Join-Path $here 'build-intake-skeleton.ps1'
  $skelText = [IO.File]::ReadAllText($skelPath, [Text.Encoding]::UTF8)
  $mClass = [regex]::Match($skelText, '(?ms)^function Get-LineClass \{.*?^\}')
  T 'MUST FIRE  the REAL Get-LineClass is readable out of build-intake-skeleton.ps1 - the assembler''s vocabulary is checked against the classifier that will actually read it' `
    ($mClass.Success) 'could not find function Get-LineClass'
  if ($mClass.Success) { Invoke-Expression $mClass.Value }

  # The COMMODITY id namespaces, as the assembler sees them: a set of ids that already price a food.
  # NOT the recipe vocabulary - see Get-CommodityIds' correction note, and the gate drill that earned
  # it. The plausibility floor lives on the live path, not in this pure function.
  $known = @{}
  foreach ($b in @('cauliflower','kielbasa','heavy-cream','cream-cheese','parmesan','onions')) {
    $known[$b] = $true
  }

  function New-Tbl {
    param($Rows, [double]$Servings = 4)
    return [pscustomobject]@{ slug='drill-dish'; title='Drill Dish'; source_url='https://d/x'
                              servings=$Servings; rows=@($Rows) }
  }
  function New-Row {
    param([string]$Raw, [string]$Term, [string]$Canon, [string]$Bid, [string]$Res = 'resolved',
          $Grams = $null, [bool]$Optional = $false)
    return [pscustomobject]@{ raw=$Raw; term=$Term; canon_item=$(if($Canon){$Canon}else{$null})
                              bid=$(if($Bid){$Bid}else{$null}); board='weekly'; resolution=$Res
                              gpu_known=$true; density_known=$true; fooddb_known=$true
                              evidence='fixture'; source='vocab'; optional=$Optional
                              grams_source_basis=$Grams }
  }
  $stateRow = [pscustomobject]@{ slug='drill-dish'; protein='pork' }

  # ---- FIXTURE A1. THE SCALE VECTOR, FROZEN FROM THE REAL v2 FILE (pin P3). ------------------------
  # baked-cauliflower-mac-smoked-sausage.json on disk: 16 oz of cauliflower at 4 source servings is
  # 453.592 g at SOURCE basis, scale_factor 3.5, and 1588 g in the file. The table's grams are source
  # basis and the file's are target, and the scale is applied EXACTLY ONCE - scaling something already
  # scaled is how a 1588 g line becomes 5558 g.
  $rowsA = @(
    (New-Row '16 ounces cauliflower chopped into macaroni sized pieces' 'cauliflower' 'Cauliflower' 'cauliflower' 'resolved' 453.592),
    (New-Row '14 ounces smoked sausage' 'smoked sausage' 'Smoked Sausage' 'kielbasa' 'resolved' 396.893),
    (New-Row '1/4 cup heavy cream' 'heavy cream' 'Heavy Cream' 'heavy-cream' 'resolved' 60.0)
  )
  $payA = [pscustomobject]@{ slug='drill-dish'
    lines = @(
      [pscustomobject]@{ raw='16 ounces cauliflower chopped into macaroni sized pieces'; buy='3 1/2 lb, chopped into macaroni-sized pieces (about 3 medium heads)'; notes='exact 3.5x, zero drift' },
      # THE QUANTIZATION CASE, and it is 2 of the 7 lines on the real v2 file: the mapper's printed
      # measure moved off the exact scale, so it states the grams that agree with its own buy string.
      # IT STATES THEM AT SOURCE BASIS, which is the phase-6a gate drill's correction - see the grams
      # block above. The v2 file's target weight is 1361 g for "3 lb"; at 3.5x that is 388.9 g of
      # source, against the engine's unquantized 396.893. The exact 3.5x would have been 1389.
      [pscustomobject]@{ raw='14 ounces smoked sausage'; buy='3 lb, sliced into thin rounds (about three and a half 14 oz ropes)'; notes='quantized -2.0%'; grams_source=388.9 },
      [pscustomobject]@{ raw='1/4 cup heavy cream'; buy='3/4 cup plus 2 tbsp'; notes='14 tbsp at 15 g/tbsp' })
    rulings = @() }
  $resA = New-MappedDecisionFile (New-Tbl $rowsA 4) $payA $stateRow $known 14

  # ---- FIXTURE: THE COUNT GUESS REACHES THE REAL CROSS-CHECK (2026-08-27, end to end). ------------
  # This is the wiring, not the predicate. Two neuters of the predicate went red while a neuter of
  # the LINE that calls it stayed green, twice - so the assembler itself is asked here, through the
  # same function the map lane calls, with the exact row that stuck honey-balsamic-chicken-tenders
  # three times: engine 400 g from "2 medium" x an each-noun, on a line that says 1.5 lbs.
  $rowsCG = @((New-Row '2 medium 1.5 lbs. chicken breasts' 'chicken breasts' 'Cauliflower' 'cauliflower' 'resolved' 400.0))
  $payCG = [pscustomobject]@{ slug='drill-dish'
    lines = @([pscustomobject]@{ raw='2 medium 1.5 lbs. chicken breasts'; buy='5 1/4 lb'; notes='the stated weight, 680 g of source'; grams_source=680.388 })
    rulings = @() }
  $resCG = New-MappedDecisionFile (New-Tbl $rowsCG 4) $payCG $stateRow $known 14
  T 'MUST FIRE  the assembler does NOT refuse a stated weight over a count guess - this exact row parked a recipe three times in one run' `
    ($null -ne $resCG.doc -and -not ((@($resCG.findings) -join ' ') -match 'disagreement')) `
    ("findings=" + (@($resCG.findings) -join '; '))
  T '  and the recipe keeps the STATED weight, scaled once: 680 g of source at 3.5x is 2381 g' `
    ($null -ne $resCG.doc -and [Math]::Abs(@($resCG.doc.ingredients)[0].grams - 2381) -le 2) `
    ("g=" + [string]@($resCG.doc.ingredients)[0].grams)
  # CLEAN TWIN. The cross-check must keep its full force where the engine really is grounded, or this
  # fix has quietly deleted the guard instead of narrowing it.
  $rowsCG2 = @((New-Row '1.5 lbs chicken breasts' 'chicken breasts' 'Cauliflower' 'cauliflower' 'resolved' 680.388))
  $payCG2 = [pscustomobject]@{ slug='drill-dish'
    lines = @([pscustomobject]@{ raw='1.5 lbs chicken breasts'; buy='18 lb'; notes='a real basis error'; grams_source=2381.0 })
    rulings = @() }
  $resCG2 = New-MappedDecisionFile (New-Tbl $rowsCG2 4) $payCG2 $stateRow $known 14
  T 'CLEAN TWIN an engine number that AGREES with the stated weight still refuses a 3.5x ruling - the guard is narrowed, not deleted' `
    ((@($resCG2.findings) -join ' ') -match 'disagreement') `
    ("findings=" + (@($resCG2.findings) -join '; '))
  T 'MUST FIRE  the frozen v2 vector: 453.592 g at 4 source servings scales ONCE to 1588 g at 14' `
    (@($resA.findings).Count -eq 0 -and $resA.doc.scale_factor -eq 3.5 -and
     @($resA.doc.ingredients)[0].grams -eq 1588) `
    ("findings=" + (@($resA.findings) -join '; ') + " g=" + [string]@($resA.doc.ingredients)[0].grams)
  T 'MUST FIRE  a MAPPER-STATED weight beats the engine''s and is SCALED ONCE like every other road - 388.9 g of source is the 1361 g the v2 file carries for "3 lb"' `
    (@($resA.doc.ingredients)[1].grams -eq 1361 -and @($resA.doc.ingredients)[1].grams_from -eq 'line') `
    ([string]@($resA.doc.ingredients)[1].grams + ' from ' + [string]@($resA.doc.ingredients)[1].grams_from)
  T 'CLEAN TWIN a line with no stated grams takes the engine''s weight, scaled once, and the two roads land on the same basis' `
    (@($resA.doc.ingredients)[2].grams -eq 210 -and @($resA.doc.ingredients)[2].grams_from -eq 'engine') `
    ([string]@($resA.doc.ingredients)[2].grams)

  # ---- FIXTURE A1b. THE BASIS CROSS-CHECK (added 2026-08-24 from the gate drill). -----------------
  # The live mapper returned SOURCE grams on all ten lines it weighed, in a field the contract then
  # called TARGET - the ratio was EXACTLY the recipe's own scale factor every time. Now that every
  # road is source basis, the inverse mistake (a mapper handing back a target-scale number) is the one
  # left, and it is caught wherever the engine weighed the same food. A basis error moves by the scale
  # factor; quantizing a printed measure moves a few percent.
  $payBasis = [pscustomobject]@{ slug='drill-dish'
    lines = @([pscustomobject]@{ raw='16 ounces cauliflower chopped into macaroni sized pieces'; buy='3 1/2 lb'; notes=''; grams_source=1588 },
              [pscustomobject]@{ raw='14 ounces smoked sausage'; buy='3 lb'; notes=''; grams_source=388.9 },
              [pscustomobject]@{ raw='1/4 cup heavy cream'; buy='3/4 cup plus 2 tbsp'; notes='' })
    rulings = @() }
  $resBasis = New-MappedDecisionFile (New-Tbl $rowsA 4) $payBasis $stateRow $known 14
  T 'MUST FIRE  a TARGET-scale number in a source-basis field is caught by the engine cross-check and NAMED, rather than shipping a 3.5x line' `
    ($null -eq $resBasis.doc -and (@($resBasis.findings) -join ' ') -match 'disagreement' -and
     (@($resBasis.findings) -join ' ') -match 'different basis') ((@($resBasis.findings) -join '; ')[0..220] -join '')
  T 'CLEAN TWIN a QUANTIZED weight a few percent off the engine passes - that is what quantizing a printed measure looks like, and refusing it would refuse the v2 corpus' `
    (@($resA.findings).Count -eq 0) ((@($resA.findings) -join '; '))
  # ...and a SUB-HALF-GRAM line is floored at 1, never rounded to the zero this file may not carry
  $rowsTiny = @((New-Row 'a' 'a' 'Cauliflower' 'cauliflower' 'resolved' 100.0),
                (New-Row 'b' 'b' 'Heavy Cream' 'heavy-cream' 'resolved' 100.0),
                (New-Row 'bay' 'bay leaves' 'Bay Leaves' 'kielbasa' 'resolved' 0.2))
  $payTiny = [pscustomobject]@{ slug='drill-dish'
    lines = @([pscustomobject]@{ raw='a'; buy='1 lb'; notes='' }, [pscustomobject]@{ raw='b'; buy='1 cup'; notes='' },
              [pscustomobject]@{ raw='bay'; buy='2 bay leaves'; notes='' }); rulings=@() }
  $resTiny = New-MappedDecisionFile (New-Tbl $rowsTiny 6) $payTiny $stateRow $known 14
  T 'MUST FIRE  a SUB-HALF-GRAM line is floored at 1 g, never rounded to the zero this file may not carry - two bay leaves at 2.33x is 0.47 g, and the skeleton DROPS a zero-gram line' `
    (@($resTiny.findings).Count -eq 0 -and @($resTiny.doc.ingredients)[2].grams -eq 1) `
    ("findings=" + (@($resTiny.findings) -join '; ') + " g=" + [string]@($resTiny.doc.ingredients)[2].grams)
  T 'MUST FIRE  the servings block is written out whole - source, target and the factor - so nothing downstream re-derives a scale' `
    ($resA.doc.source_servings -eq 4 -and $resA.doc.target_servings -eq 14 -and $resA.doc.scale_factor -eq 3.5) `
    (([string]$resA.doc.source_servings) + '->' + [string]$resA.doc.target_servings + ' x' + [string]$resA.doc.scale_factor)
  T 'MUST FIRE  the assembled file carries every field its consumers actually read - frozen by grepping build-intake-skeleton.ps1 and hunt-run.ps1 for every mapped-file read' `
    ((@('slug','title','source_url','protein','source_servings','target_servings','scale_factor','ingredients') |
       Where-Object { $resA.doc.PSObject.Properties.Name -notcontains $_ }).Count -eq 0 -and
     (@('item','grams','buy','decision','bid') |
       Where-Object { @($resA.doc.ingredients)[0].PSObject.Properties.Name -notcontains $_ }).Count -eq 0) `
    (($resA.doc.PSObject.Properties.Name) -join ',')
  T 'MUST FIRE  `protein` comes off the RUN STATE FILE, which has carried it since sourcing - D8 refuses to build without it and the wave manifest is built out of it' `
    ($resA.doc.protein -eq 'pork') ([string]$resA.doc.protein)

  # ---- FIXTURE A1c. A BID MAY NOT BE AN ID ITS OWN RULING REFUSED --------------------------------
  # FROZEN FIXTURE, verbatim from turmeric-braised-chicken-with-golden-beets-and-leeks in the 6b run.
  # Its notes refuse `chicken-thighs` on the leg-quarters-are-not-thighs precedent and its bid IS
  # chicken-thighs. The same mapper got hawaiian-chicken right with identical reasoning, so it is a
  # slip - and nothing caught it, because the evidence gate is written for a HUMAN reader and no
  # machine reads it. 1 of 579 ruled lines across every mapped file this estate has.
  $realNotes = ("98 g per skinless bone-in drumstick as purchased (USDA 62 g meat at a 63% bone-in " +
                "yield). Refused the chicken-thighs bridge on the standing 'leg quarters are not " +
                "thighs' precedent: drumsticks are a distinct cut, a distinct price class")
  T 'MUST FIRE  a ruling that BIDS the id its own evidence refused is caught' `
    (Test-BidContradictsNotes -Bid 'chicken-thighs' -Notes $realNotes) 'the contradiction was missed'
  T 'CLEAN TWIN the SAME evidence bidding the RIGHT id is not a contradiction' `
    (-not (Test-BidContradictsNotes -Bid 'chicken-drumsticks' -Notes $realNotes)) 'flagged a correct ruling'
  # WORD BOUNDARIES. `chicken-breast` is a substring of `bone-in-chicken-breast`, and refusing one
  # while bidding the other is sound reasoning - this is a real ruling from the same run.
  $subNotes = ("REFUSED chicken-breast (boneless skinless): a split bone-in breast sells well below " +
               "the boneless per-lb price AND carries about 28% bone. New id proposed.")
  T 'MUST FIRE  refusing `chicken-breast` while bidding `bone-in-chicken-breast` is SOUND, not a contradiction' `
    (-not (Test-BidContradictsNotes -Bid 'bone-in-chicken-breast' -Notes $subNotes)) 'flagged a sound ruling'
  T 'CLEAN TWIN ...but bidding the exact id that was refused still fires' `
    (Test-BidContradictsNotes -Bid 'chicken-breast' -Notes $subNotes) 'missed an exact contradiction'
  T 'CLEAN TWIN evidence with no refusal in it is never a contradiction' `
    (-not (Test-BidContradictsNotes -Bid 'rice' -Notes 'mapped to rice, the obvious id')) 'false positive'
  # AND THE BOUNDARY IN THE DIRECTION THAT ACTUALLY NEEDS IT. The first pair of boundary fixtures
  # tested a bid that does not appear in the notes at all, so they passed with or without the
  # lookarounds and proved nothing. The guard earns its place HERE: a SHORT id sitting inside a LONGER
  # refused one. Refusing `bone-in-chicken-breast` while bidding plain `chicken-breast` is a correct
  # ruling, and a substring match would call it a contradiction and park a good recipe.
  $longRefusal = 'Refused bone-in-chicken-breast: this line is the boneless cut, sold by a different id.'
  T 'MUST FIRE  a SHORT bid inside a LONGER refused id is not a contradiction - substring matching would park a good recipe' `
    (-not (Test-BidContradictsNotes -Bid 'chicken-breast' -Notes $longRefusal)) `
    'matched chicken-breast inside bone-in-chicken-breast'

  # ---- FIXTURE A1c-3. THE THIRD PRODUCTION FIRING, AND THE THIRD FALSE POSITIVE (2026-08-28). -----
  # FROZEN FIXTURE, verbatim from `baked-cubano-chicken` in run hunt-2026-08-27-highprotein. The
  # ruling bids `deli-ham`, argues FOR it twice - "This line IS sliced deli lunch meat, which is
  # exactly what deli-ham prices" - and was stuck anyway, because it CITED a past ruling that refused
  # that id in order to say the past ruling does not apply here.
  #
  # That is the difference between a refusal and a REPORT of one, and it is what the attribution rule
  # reads: the ruling's own refusal in this very string ("Refused the vocabulary's Diced Ham") has no
  # subject before the verb, and the reported one does ("the 'spiral ham' precedent refused").
  $hamNotes = ("This line IS sliced deli lunch meat, which is exactly what deli-ham prices (7 of 7, " +
               "cheapest 0.1238 Walmart) - a reuse. Refused the vocabulary's Diced Ham: cubed " +
               "convenience packs are a different pack and price class. The 'spiral ham' precedent " +
               "refused deli-ham for a bone-in whole ham, which is the opposite case and does not " +
               "bind here.")
  T 'CLEAN TWIN a ruling that CITES a past refusal of its own bid, to distinguish it, is not contradicting itself' `
    (-not (Test-BidContradictsNotes -Bid 'deli-ham' -Notes $hamNotes)) `
    'the 2026-08-28 cubano false positive fired again'
  # AND THE NARROWING HAS A FLOOR. Strip the attribution - make the same sentence the ruling'"'"'s OWN
  # voice - and the check must fire again, or this stopped being a gate.
  $hamOwnVoice = ("This line IS sliced deli lunch meat. Refused deli-ham for a bone-in whole ham.")
  T 'MUST FIRE  ...but the SAME refusal in the ruling OWN voice, with no one else to attribute it to, still parks the recipe' `
    (Test-BidContradictsNotes -Bid 'deli-ham' -Notes $hamOwnVoice) `
    'the attribution rule swallowed a real self-contradiction'
  # A REPORTED REFUSAL BESIDE A REAL ONE. Order must not decide the verdict: the reported one comes
  # FIRST here, so a check that returned on its first match would clear a genuine contradiction.
  $hamBoth = ("The 'spiral ham' precedent refused deli-ham for a whole ham. Refused deli-ham here " +
              "too, on the pack-class rule.")
  T 'MUST FIRE  a REPORTED refusal standing before a REAL one does not clear it - every match is read, not just the first' `
    (Test-BidContradictsNotes -Bid 'deli-ham' -Notes $hamBoth) `
    'the first (reported) match short-circuited the real contradiction behind it'

  # ---- FIXTURE A1c-2. THE FALSE POSITIVE THIS CHECK ACTUALLY PRODUCED (2026-08-26). --------------
  # FROZEN FIXTURE, verbatim from `easy-beef-enchiladas` in run hunt-2026-08-26-smoke - the FIRST
  # production firing of the notes-vs-bid check, and a FALSE POSITIVE that stuck a CORRECT recipe.
  # The mapper bid `flour-tortillas` and refused `corn-tortillas`; nothing contradicted anything.
  #
  # The evidence names THREE ids and every one of them has to be read differently:
  #   `corn-tortillas`  - genuinely refused, and the ONLY id this evidence refuses
  #   `tortillas`       - a token INSIDE `corn-tortillas`, and separately a standalone mention in the
  #                       clause AFTER the colon that EXPLAINS the refusal. Neither is a refusal.
  #   `flour-tortillas` - the bid, never refused; it appears in the prose only as "flour tortillas"
  # SINGLE-QUOTED, so the BACKTICKS around `tortillas` survive verbatim - they are the boundary
  # character the real evidence puts there, and a double-quoted PowerShell string would eat them.
  $tortNotes = ('Refused the corn-tortillas bridge: corn and flour tortillas are different products ' +
                'at different per-unit prices and gram weights. New id proposed with an alias ' +
                'instruction against the generic `tortillas` board id. 8 x 71 g.')
  T 'CLEAN TWIN the MAPPER OWN BID `flour-tortillas`, against evidence that refuses `corn-tortillas`, is not a contradiction' `
    (-not (Test-BidContradictsNotes -Bid 'flour-tortillas' -Notes $tortNotes)) `
    'flagged the correct enchiladas ruling'
  # THE ONE THAT ACTUALLY FIRED. `tortillas` is a token of `corn-tortillas` AND appears standalone one
  # clause later - the token guards handled the first, and the gap class walking through the colon let
  # the second through. Both readings must be silent: neither is this ruling refusing its own bid.
  T 'CLEAN TWIN the ALIAS-RESOLVED id `tortillas` does not fire either - it is a token of the refused sibling, and its standalone mention sits past the colon, in the clause that EXPLAINS the refusal' `
    (-not (Test-BidContradictsNotes -Bid 'tortillas' -Notes $tortNotes)) `
    'the 2026-08-26 false positive fired again'
  T 'MUST FIRE  ...and the id that WAS refused still fires on the very same evidence, so the fix narrowed this check rather than disabling it' `
    (Test-BidContradictsNotes -Bid 'corn-tortillas' -Notes $tortNotes) 'the real refusal was missed'
  # A REFUSED SIBLING SHARING A TOKEN, in the direction the enchiladas case does not cover: the refused
  # id is LONGER and the bid is its TAIL rather than its head.
  $sibNotes = 'Refused boneless-chicken-thighs: this line is the bone-in cut, sold by a different id.'
  T 'CLEAN TWIN a refused SIBLING sharing a token with the bid - `chicken-thighs` inside `boneless-chicken-thighs` - is sound reasoning, not a contradiction' `
    (-not (Test-BidContradictsNotes -Bid 'chicken-thighs' -Notes $sibNotes)) `
    'matched chicken-thighs inside boneless-chicken-thighs'
  T 'MUST FIRE  ...and bidding the exact sibling that was refused still fires' `
    (Test-BidContradictsNotes -Bid 'boneless-chicken-thighs' -Notes $sibNotes) 'missed an exact contradiction'

  # ---- FIXTURE A1c-3. THE CALL SITE, NOT THE PREDICATE. -----------------------------------------
  # PLAN-map-judge-split-2026-08-25 section 4 records the trap: a predicate can be right while the call
  # site feeds it the wrong argument, and every predicate fixture above would still read green. That is
  # EXACTLY what happened on 2026-08-26 - the enchiladas false positive needed BOTH the colon-crossing
  # gap AND a call site that had let the registrar rewrite the bid out from under the evidence.
  #
  # So this runs the WHOLE -Assemble path in the enchiladas shape: the mapper bids a NEW id, the
  # registrar aliases it onto an existing one, and the evidence refuses a SIBLING while naming the
  # alias target as a standalone token. `onions` stands in for `tortillas` because it is a wired id in
  # this fixture namespace; the shape is identical. If the call site ever reverts to passing the
  # rewritten bid, this fixture parks a clean recipe and says so.
  $aliasEvidence = ('Refused the green-onions bridge: green and yellow onions are different products ' +
                    'at different per-unit prices. New id proposed with an alias instruction against ' +
                    'the generic `onions` board id.')
  $rowsT  = @((New-Row 't' 't' '' '' 'new-food-suspect' $null))
  $linesT = @([pscustomobject]@{ raw='t'; buy='14 large'; notes='' })
  $ruleT  = @([pscustomobject]@{ raw='t'; term='t'; canon_item='Yellow Onions'; bid='yellow-onions'
                                 decision='mapped'; grams_source=568; evidence=$aliasEvidence })
  $payT = [pscustomobject]@{ slug='drill-dish'; lines=$linesT; rulings=$ruleT
    registrar_rulings=@([pscustomobject]@{ proposed_bid='yellow-onions'; verdict='alias'; bid='onions'
                                           reason='the board id already prices this food' }) }
  $resT = New-MappedDecisionFile (New-Tbl $rowsT 4) $payT $stateRow $known 14
  T 'MUST FIRE  CALL SITE: the notes-vs-bid check reads the MAPPER bid, not the registrar alias rewrite - the enchiladas shape assembles cleanly and the alias still lands' `
    (@($resT.findings).Count -eq 0 -and $null -ne $resT.doc -and
     @($resT.doc.ingredients)[0].bid -eq 'onions') `
    ("findings=" + (@($resT.findings) -join '; '))
  # AND THE CALL SITE STILL CATCHES A REAL ONE. Same alias rewrite, but now the MAPPER OWN bid is the
  # id its own evidence refused - the 2.6 defect, arriving through a registrar alias. Reading the
  # rewritten bid would MISS this, which is the false-NEGATIVE half of the same call-site mistake.
  $ruleTC = @([pscustomobject]@{ raw='t'; term='t'; canon_item='Yellow Onions'; bid='yellow-onions'
                                 decision='mapped'; grams_source=568
                                 evidence='Refused yellow-onions: this line is the green cut, sold by a different id.' })
  $payTC = [pscustomobject]@{ slug='drill-dish'; lines=$linesT; rulings=$ruleTC
    registrar_rulings=@([pscustomobject]@{ proposed_bid='yellow-onions'; verdict='alias'; bid='onions'
                                           reason='the board id already prices this food' }) }
  $resTC = New-MappedDecisionFile (New-Tbl $rowsT 4) $payTC $stateRow $known 14
  T 'MUST FIRE  CALL SITE: a ruling that refuses its OWN bid is still caught THROUGH a registrar alias, and the finding quotes the mapper id rather than the rewritten one' `
    ($null -eq $resTC.doc -and (@($resTC.findings) -join ' ') -match "BIDS 'yellow-onions'") `
    ((@($resTC.findings) -join '; '))
  # THE CALL SITE IN THE FALSE-POSITIVE DIRECTION, which the two fixtures above do NOT pin between
  # them: the first stays clean whichever bid is passed, and the second is a false NEGATIVE.
  #
  # This is the enchiladas hazard in its purest form. The mapper refuses the GENERIC board id and
  # proposes a specific one; the registrar then aliases the specific id straight back onto the generic
  # one it just argued against - which is exactly what happened to `flour-tortillas` -> `tortillas`.
  # Read the REWRITTEN bid and the check asks "does this evidence refuse `onions`?", and the evidence
  # says yes, in so many words. Read the MAPPER'S bid and there is no contradiction: it bid
  # `yellow-onions` and it never refused `yellow-onions`. The registrar overriding the mapper is a
  # DISAGREEMENT BETWEEN TWO AGENTS, and the registrar wins it by design - it is not this check's
  # business, and it is not a reason to park a recipe.
  $ruleTG = @([pscustomobject]@{ raw='t'; term='t'; canon_item='Yellow Onions'; bid='yellow-onions'
                                 decision='mapped'; grams_source=568
                                 evidence='Refused the generic onions id as too coarse for this line, so a specific id is proposed.' })
  $payTG = [pscustomobject]@{ slug='drill-dish'; lines=$linesT; rulings=$ruleTG
    registrar_rulings=@([pscustomobject]@{ proposed_bid='yellow-onions'; verdict='alias'; bid='onions'
                                           reason='the board id already prices this food' }) }
  $resTG = New-MappedDecisionFile (New-Tbl $rowsT 4) $payTG $stateRow $known 14
  T 'MUST FIRE  CALL SITE: a registrar alias onto an id the mapper EXPLICITLY refused is not a self-contradiction - the mapper never bid that id, and reading the rewritten bid parks a good recipe' `
    (@($resTG.findings).Count -eq 0 -and $null -ne $resTG.doc -and
     @($resTG.doc.ingredients)[0].bid -eq 'onions') `
    ("findings=" + (@($resTG.findings) -join '; '))

  # ---- FIXTURE A1e. B2: A GUESS IS NOT A CROSS-CHECK --------------------------------------------
  # FROZEN FIXTURE, and the founding case is verbatim from the 2026-08-24 no-band drill.
  # "3 tablespoons chopped fresh parsley": densities.json carries Dried Parsley but not FRESH parsley,
  # so parse-compute's tbsp branch fell to defaults.sauce_tbsp = 16 g and returned 3 x 16 = 48 g at
  # source basis (chopped fresh parsley is ~3.8 g/tbsp). Scaled 3.5x that is 168 g against the mapper's
  # correct 40 g - a 0.24x "disagreement" - and the recipe PARKED on the engine's own admitted guess.
  # parse-compute had flagged it `default tbsp` all along; map-preresolve discarded the flag.
  $rowsD = @((New-Row 'p1' 'p1' 'Kielbasa' 'kielbasa' 'resolved' 200.0),
             (New-Row 'p2' 'parsley' 'Fresh Parsley' 'parmesan' 'resolved' 48.0))
  $payD = [pscustomobject]@{ slug='drill-dish'
    lines = @([pscustomobject]@{ raw='p1'; buy='1 lb kielbasa'; notes='' },
              [pscustomobject]@{ raw='p2'; buy='3 tablespoons chopped fresh parsley'; notes='' })
    rulings = @([pscustomobject]@{ raw='p2'; decision='mapped'; canon_item='Fresh Parsley'; bid='parmesan'
                                   grams_source=11.4; evidence='3 tbsp chopped parsley' }) }
  $tblD = New-Tbl $rowsD 4
  @($tblD.rows)[1].raw = '3 tablespoons chopped fresh parsley'
  @($payD.lines)[1].raw = '3 tablespoons chopped fresh parsley'
  @($payD.rulings)[0].raw = '3 tablespoons chopped fresh parsley'
  # the engine could NOT ground this weight, and says so - exactly as parse-compute flags it
  @($tblD.rows)[1] | Add-Member -NotePropertyName 'grams_basis_fallback' -NotePropertyValue 'default tbsp' -Force
  $resD = New-MappedDecisionFile $tblD $payD $stateRow $known 14
  T 'MUST FIRE  a grounded ruling is NOT cross-checked against a weight the engine admits it guessed - the parsley park' `
    (@($resD.findings).Count -eq 0) ("findings=" + (@($resD.findings) -join '; '))
  T 'MUST FIRE  ...and the guessed line is RECORDED as a density gap, so the worklist builds itself from real recipes' `
    (@($resD.density_gaps).Count -eq 1 -and [string]@($resD.density_gaps)[0].engine_basis -eq 'default tbsp') `
    ("gaps=" + (@($resD.density_gaps) | ForEach-Object { [string]$_.item + '/' + [string]$_.engine_basis }) -join ', ')
  T 'MUST FIRE  ...and the MAPPER''s weight is what ships, not the guess (11.4 g source x 3.5 = 40 g)' `
    ((@($resD.doc.ingredients) | Where-Object { $_.source_raw -like '*parsley*' }).grams -eq 40) `
    ((@($resD.doc.ingredients) | ForEach-Object { [string]$_.item + '=' + [string]$_.grams }) -join ' | ')
  # THE GUARD KEEPS ITS FULL FORCE WHERE BOTH SIDES ARE GROUNDED. Same numbers, no fallback flag.
  $rowsE = @((New-Row 'e1' 'e1' 'Kielbasa' 'kielbasa' 'resolved' 200.0),
             (New-Row 'e2' 'parsley' 'Fresh Parsley' 'parmesan' 'resolved' 48.0))
  $payE = [pscustomobject]@{ slug='drill-dish'
    lines = @([pscustomobject]@{ raw='e1'; buy='1 lb'; notes='' }, [pscustomobject]@{ raw='e2'; buy='3 tbsp'; notes='' })
    rulings = @([pscustomobject]@{ raw='e2'; decision='mapped'; canon_item='Fresh Parsley'; bid='parmesan'
                                   grams_source=11.4; evidence='x' }) }
  $resE = New-MappedDecisionFile (New-Tbl $rowsE 4) $payE $stateRow $known 14
  T 'MUST FIRE  a GROUNDED engine weight still cross-checks the ruling and still finds the 0.24x disagreement' `
    ((@($resE.findings) -join ' ') -match 'disagreement') ("findings=" + (@($resE.findings) -join '; '))
  T 'CLEAN TWIN a grounded line with no disagreement records NO density gap' `
    (@($resE.density_gaps).Count -eq 0) ("gaps=" + @($resE.density_gaps).Count)

  # ---- FIXTURE A1g. A QUANTITY-LESS GARNISH IS AN OPTIONAL NOTE, NOT A PARKED RECIPE -------------
  # FROZEN FIXTURE (Brad's ruling 2026-08-24). The 6b proving run parked
  # `cheese-stuffed-chicken-parmesan` on "Fresh parsley (to garnish)": no stated quantity, so no gram
  # weight from the engine or a ruling, so the never-a-silent-zero refusal fired and the recipe died
  # after map, registrar and pricing had all been paid. The estate already had the right shape for it -
  # optional-note, whose own comment names "water, a garnish, a sub-recipe" - and the mapper simply did
  # not reach for it.
  #
  # THE OVER-REACH TWINS ARE THE POINT. A garnish that STATES a measure still costs and weighs like any
  # other line (it gets grams from the qty engine and never reaches the refusal), and a quantity-less
  # line that is NOT a garnish must still park. Three garnish shapes, because a collection fixture takes
  # at least three.
  $rowsG = @((New-Row 'g1' 'g1' 'Kielbasa' 'kielbasa' 'resolved' 200.0),
             (New-Row 'g2' 'parsley' 'Fresh Parsley' 'parmesan' 'resolved' $null),
             (New-Row 'g3' 'cilantro' 'Fresh Cilantro' 'onions' 'resolved' $null),
             (New-Row 'g4' 'sour cream' 'Sour Cream' 'cream-cheese' 'resolved' $null),
             (New-Row 'g5' 'chopped parsley' 'Fresh Parsley' 'parmesan' 'resolved' 10.0))
  $payG = [pscustomobject]@{ slug='drill-dish'
    lines = @([pscustomobject]@{ raw='g1'; buy='1 lb chicken breast'; notes='' },
              [pscustomobject]@{ raw='g2'; buy=''; notes='' },
              [pscustomobject]@{ raw='g3'; buy=''; notes='' },
              [pscustomobject]@{ raw='g4'; buy=''; notes='' },
              [pscustomobject]@{ raw='g5'; buy='1/4 cup chopped parsley'; notes='' }); rulings=@() }
  # the raw strings ARE the ingredient lines the reader sees, so they carry the garnish phrasing
  $tblG = New-Tbl $rowsG 4
  @($tblG.rows)[1].raw = 'Fresh parsley (to garnish)'
  @($tblG.rows)[2].raw = 'Chopped cilantro, for serving'
  @($tblG.rows)[3].raw = 'Sour cream, garnish'
  @($tblG.rows)[4].raw = '1/4 cup chopped parsley, for garnish'
  @($payG.lines)[1].raw = 'Fresh parsley (to garnish)'
  @($payG.lines)[2].raw = 'Chopped cilantro, for serving'
  @($payG.lines)[3].raw = 'Sour cream, garnish'
  @($payG.lines)[4].raw = '1/4 cup chopped parsley, for garnish'
  $resG = New-MappedDecisionFile $tblG $payG $stateRow $known 14
  $gNotes = @(@($resG.doc.ingredients) | Where-Object { $_.decision -eq 'optional-note' })
  T 'MUST FIRE  three quantity-less garnish shapes become optional-notes instead of parking the recipe' `
    ($gNotes.Count -eq 3 -and @($resG.findings).Count -eq 0) `
    ("optional-notes=" + $gNotes.Count + " findings=" + (@($resG.findings) -join '; '))
  T 'MUST FIRE  ...and each is NAMED in the file with zero grams and nothing to buy, so the reader still sees the garnish and the cost is untouched' `
    ((@($gNotes | Where-Object { $_.grams -eq 0 -and -not $_.buy -and $_.optional }).Count) -eq 3) `
    (($gNotes | ForEach-Object { [string]$_.source_raw + ' g=' + [string]$_.grams }) -join ' | ')
  T 'CLEAN TWIN a garnish that STATES a measure is costed like any other line, never demoted' `
    ((@(@($resG.doc.ingredients) | Where-Object { $_.source_raw -like '*1/4 cup*' -and $_.decision -ne 'optional-note' }).Count) -eq 1) `
    ((@($resG.doc.ingredients) | ForEach-Object { [string]$_.source_raw + '=' + [string]$_.decision }) -join ' | ')
  # AND THE REFUSAL ITSELF MUST SURVIVE: a weightless line that is not a garnish still parks.
  $rowsG2 = @((New-Row 'n1' 'n1' 'Kielbasa' 'kielbasa' 'resolved' 200.0),
              (New-Row 'n2' 'rice blend' 'Rice Blend' 'cauliflower' 'resolved' $null))
  $payG2 = [pscustomobject]@{ slug='drill-dish'
    lines = @([pscustomobject]@{ raw='n1'; buy='1 lb chicken breast'; notes='' },
              [pscustomobject]@{ raw='n2'; buy=''; notes='' }); rulings=@() }
  $tblG2 = New-Tbl $rowsG2 4
  # CHANGED 2026-08-24 when D5 landed: this line USED to be the rice-blend alternatives line, which D5
  # now settles by choosing a food - so it stopped parking and this fixture went red. The fixture is
  # about the never-a-silent-zero refusal surviving, so it needs a weightless line that is NEITHER a
  # garnish NOR a menu. A plain food with no quantity is exactly that.
  @($tblG2.rows)[1].raw = 'Prepared brown rice'
  @($payG2.lines)[1].raw = 'Prepared brown rice'
  $resG2 = New-MappedDecisionFile $tblG2 $payG2 $stateRow $known 14
  T 'MUST FIRE  a weightless line that is NOT a garnish still parks - the never-a-silent-zero refusal is untouched' `
    ((@($resG2.findings) -join ' ') -match 'has no gram weight') `
    ("findings=" + (@($resG2.findings) -join '; '))

  # ---- FIXTURE A1g-2. THE LEADING TOPPINGS LABEL (2026-08-26). ----------------------------------
  # FROZEN FIXTURE, verbatim from `easy-beef-enchiladas` in run hunt-2026-08-26-smoke. Found while
  # fixing the notes-vs-bid false positive on the SAME recipe: with that gone, this is what still
  # parked it. The mapper ruled the line `mapped-null` with zero grams on an `optional: true` row and
  # said in its evidence "Garnish to taste, pantry-static and safe" - every stage had it right, and the
  # assembler refused it because `mapped-null` + optional becomes `mapped-optional`, which needs grams.
  #
  # The trailing GARNISH_PHRASES cannot see this shape: the label is at the FRONT and the foods follow
  # a colon. Note the line contains "sour cream" and "diced onions" - real foods with real board ids -
  # so nothing about the food names marks it; only the label does.
  $rowsGL = @((New-Row 'l1' 'l1' 'Kielbasa' 'kielbasa' 'resolved' 200.0),
              (New-Row 'l2' 'toppings' 'Optional Toppings' '' 'new-food-suspect' $null $true))
  $payGL = [pscustomobject]@{ slug='drill-dish'
    lines = @([pscustomobject]@{ raw='l1'; buy='1 lb kielbasa'; notes='' },
              [pscustomobject]@{ raw='l2'; buy=''; notes='' })
    rulings = @([pscustomobject]@{ raw='l2'; term='diced onions, chopped cilantro, sour cream, shredded lettuce'
                                   canon_item='Optional Toppings: Diced Onion, Cilantro, Sour Cream, Shredded Lettuce'
                                   bid=$null; decision='mapped-null'; grams_source=0
                                   evidence='Four distinct foods on one unsplittable line with no quantity, so no single bid can carry it. Garnish to taste, pantry-static and safe.' }) }
  $tblGL = New-Tbl $rowsGL 4
  @($tblGL.rows)[1].raw = 'optional toppings: diced onions, chopped cilantro, sour cream, shredded lettuce'
  @($payGL.lines)[1].raw = 'optional toppings: diced onions, chopped cilantro, sour cream, shredded lettuce'
  @($payGL.rulings)[0].raw = 'optional toppings: diced onions, chopped cilantro, sour cream, shredded lettuce'
  $resGL = New-MappedDecisionFile $tblGL $payGL $stateRow $known 14
  $glNote = @(@($resGL.doc.ingredients) | Where-Object { $_.decision -eq 'optional-note' })
  T 'MUST FIRE  a LEADING `optional toppings:` label is a serving suggestion, not a parked recipe - the real line easy-beef-enchiladas died on' `
    (@($resGL.findings).Count -eq 0 -and $null -ne $resGL.doc -and $glNote.Count -eq 1) `
    ("findings=" + (@($resGL.findings) -join '; '))
  T 'MUST FIRE  ...and it is NAMED with zero grams and nothing to buy, so the reader still sees the toppings and neither cost nor macros move' `
    ($glNote.Count -eq 1 -and @($glNote)[0].grams -eq 0 -and -not @($glNote)[0].buy -and @($glNote)[0].optional) `
    (($glNote | ForEach-Object { [string]$_.source_raw + ' g=' + [string]$_.grams }) -join ' | ')
  # THE LABEL FORMS, as a predicate - a collection fixture takes at least three, and each is a shape a
  # real source uses. `serve with:` and `garnishes:` are the same statement with a different noun.
  T 'MUST FIRE  the other leading-label forms read the same way' `
    ((Test-IsGarnishLine 'Toppings: shredded cheese, salsa') -and
     (Test-IsGarnishLine 'Garnishes: lime wedges') -and
     (Test-IsGarnishLine 'For serving: warm tortillas') -and
     (Test-IsGarnishLine 'Serve with: steamed rice') -and
     (Test-IsGarnishLine 'Optional: chopped cilantro')) 'a label form was missed'
  # THE OVER-REACH TWINS. The label must be a LABEL: one of these words IMMEDIATELY followed by a
  # colon, introducing a list. A food whose NAME merely contains one of these words is an ordinary
  # purchasable line, and demoting it would be the silent-zero defect this whole branch exists to
  # refuse - a line the shopper buys that the card prices at nothing.
  T 'CLEAN TWIN a food that merely NAMES a topping is not a label - `Ice cream topping, 2 tbsp` and `Sour cream` are ordinary lines' `
    ((-not (Test-IsGarnishLine 'Ice cream topping, 2 tbsp')) -and
     (-not (Test-IsGarnishLine 'Sour cream')) -and
     (-not (Test-IsGarnishLine '2 cups shredded Mexican-blend cheese, (divided)'))) `
    'demoted an ordinary purchasable line'
  # THE COLON IS WHAT MAKES IT A LABEL, and this is the twin that proves it. Without the `\s*:` the
  # pattern would demote any line merely STARTING with one of these words, and "Optional but
  # recommended, ..." is a real ingredient-line opening that names a food the shopper buys.
  # MEASURED: neuter the colon and this goes red; the twins above pass either way, because none of
  # them starts with a label word at all.
  T 'CLEAN TWIN the COLON is what makes a label - a line merely STARTING with `Optional` or `Toppings` and then naming a food is an ordinary line' `
    ((-not (Test-IsGarnishLine 'Optional but recommended, 2 tbsp sour cream')) -and
     (-not (Test-IsGarnishLine 'Toppings of your choice work here too')) -and
     (-not (Test-IsGarnishLine 'Serve with a green salad'))) `
    'demoted a line whose label word carried no colon'
  # THE `^` ANCHOR IS BELT-AND-BRACES AND IS NOT SEPARATELY PINNED, said plainly rather than left for
  # the next reader to discover. The COLON carries this pattern: to reach the anchor a line would have
  # to put one of these words DIRECTLY before a colon somewhere other than the start ("...my favourite
  # toppings: ..."), and no line in this estate's 40 runs does. Neutering the anchor alone leaves every
  # fixture here green - measured 2026-08-26 - so the anchor is kept as cheap insurance and this
  # comment, not a fixture, is what records that it is untested. The estate has been here before: the
  # first pair of notes-vs-bid boundary fixtures also passed with or without the guard they claimed to
  # prove.

  # ---- FIXTURE A1t. T1: A PANTRY SEASONING "TO TASTE" IS AN OPTIONAL NOTE, NOT A PARKED RECIPE ----
  # FROZEN FIXTURE (Brad's ruling 2026-08-25). The m1 drill sent 6 recipes down the pipe and parked one
  # in EACH of its two batches on "salt and pepper to taste": the mapper ruled the line purchasable and
  # the never-a-silent-zero refusal correctly refused the file. This is the garnish ruling one food
  # class over, and it fires in the same place - INSIDE the zero-weight refusal - so it cannot touch a
  # line that works today.
  #
  # BRAD RULED THE NARROW VERSION AND THE OVER-REACH TWINS ARE WHY. A blanket "any to taste line" rule
  # would drop `harissa, to taste` from cost AND macros with the reader never told, so one unknown word
  # refuses the whole line.
  #
  # NEUTER PROOFS, BOTH RUN AND REVERTED 2026-08-25, with the counts the suite actually printed:
  #   * delete the branch from the assembler          -> 2 red, the two end-to-end MUST FIREs. The
  #     predicate cases stay green, correctly: the function still exists, only its caller went.
  #   * WIDEN the predicate to Brad's rejected option (any line saying "to taste" qualifies)
  #                                                   -> 4 red: all three narrowness twins AND the
  #     end-to-end harissa park. That is the pair of rulings pinned in both directions - the rule
  #     cannot be deleted and it cannot be widened without a case going red.
  $rowsT = @((New-Row 't1' 't1' 'Kielbasa' 'kielbasa' 'resolved' 200.0),
             (New-Row 't2' 'salt and pepper' 'Salt' 'parmesan' 'resolved' $null),
             (New-Row 't3' 'kosher salt' 'Salt' 'onions' 'resolved' $null),
             (New-Row 't4' 'black pepper' 'Black Pepper' 'cream-cheese' 'resolved' $null))
  $payT = [pscustomobject]@{ slug='drill-dish'
    lines = @([pscustomobject]@{ raw='t1'; buy='1 lb chicken breast'; notes='' },
              [pscustomobject]@{ raw='t2'; buy=''; notes='' },
              [pscustomobject]@{ raw='t3'; buy=''; notes='' },
              [pscustomobject]@{ raw='t4'; buy=''; notes='' }); rulings=@() }
  $tblT = New-Tbl $rowsT 4
  @($tblT.rows)[1].raw = 'Salt and pepper to taste'
  @($tblT.rows)[2].raw = 'Kosher salt, to taste'
  @($tblT.rows)[3].raw = 'Freshly ground black pepper, to taste'
  @($payT.lines)[1].raw = 'Salt and pepper to taste'
  @($payT.lines)[2].raw = 'Kosher salt, to taste'
  @($payT.lines)[3].raw = 'Freshly ground black pepper, to taste'
  $resT = New-MappedDecisionFile $tblT $payT $stateRow $known 14
  $tNotes = @(@($resT.doc.ingredients) | Where-Object { $_.decision -eq 'optional-note' })
  T 'MUST FIRE  three pantry-seasoning "to taste" shapes become optional-notes instead of parking - this killed 2 of the m1 drill''s 6 recipes' `
    ($tNotes.Count -eq 3 -and @($resT.findings).Count -eq 0) `
    ("optional-notes=" + $tNotes.Count + " findings=" + (@($resT.findings) -join '; '))
  T 'MUST FIRE  ...and each is NAMED with zero grams and nothing to buy, so the reader still sees the seasoning and the cost is untouched' `
    ((@($tNotes | Where-Object { $_.grams -eq 0 -and -not $_.buy -and $_.optional }).Count) -eq 3) `
    (($tNotes | ForEach-Object { [string]$_.source_raw + ' g=' + [string]$_.grams }) -join ' | ')
  T 'MUST FIRE  the seasoning vocabulary covers the phrasings recipes actually print' `
    ((Test-IsPantrySeasoningToTaste 'Salt and pepper to taste') -and
     (Test-IsPantrySeasoningToTaste 'sea salt and cracked black pepper, to taste') -and
     (Test-IsPantrySeasoningToTaste 'Freshly ground black pepper to taste')) 'a real phrasing was refused'
  T 'CLEAN TWIN "harissa, to taste" is no pantry seasoning - a real ingredient keeps its price and macros' `
    (-not (Test-IsPantrySeasoningToTaste 'harissa, to taste')) 'harissa was swallowed'
  T 'CLEAN TWIN one unknown word refuses the WHOLE line - "salt and harissa to taste" is not a seasoning line' `
    (-not (Test-IsPantrySeasoningToTaste 'salt and harissa to taste')) 'a mixed line was swallowed'
  T 'CLEAN TWIN no "to taste" clause, no rule - a bare seasoning line is untouched' `
    (-not (Test-IsPantrySeasoningToTaste 'Kosher salt')) 'a bare seasoning was swallowed'
  T 'CLEAN TWIN a STATED measure is not this rule''s business - "1 tsp salt, to taste" is refused by the word test' `
    (-not (Test-IsPantrySeasoningToTaste '1 tsp salt, to taste')) 'a measured line was swallowed'
  # AND END TO END: the refusal itself must survive for a real food, or the narrow rule is not narrow.
  $rowsT2 = @((New-Row 'h1' 'h1' 'Kielbasa' 'kielbasa' 'resolved' 200.0),
              (New-Row 'h2' 'harissa' 'Harissa' 'cauliflower' 'resolved' $null))
  $payT2 = [pscustomobject]@{ slug='drill-dish'
    lines = @([pscustomobject]@{ raw='h1'; buy='1 lb chicken breast'; notes='' },
              [pscustomobject]@{ raw='h2'; buy=''; notes='' }); rulings=@() }
  $tblT2 = New-Tbl $rowsT2 4
  @($tblT2.rows)[1].raw = 'Harissa, to taste'
  @($payT2.lines)[1].raw = 'Harissa, to taste'
  $resT2 = New-MappedDecisionFile $tblT2 $payT2 $stateRow $known 14
  T 'MUST FIRE  end to end, a REAL ingredient stated "to taste" still parks the recipe - no price or macro is silently dropped' `
    ((@($resT2.findings) -join ' ') -match 'has no gram weight') `
    ("findings=" + (@($resT2.findings) -join '; '))

  # ---- FIXTURE A1z. A DELIBERATE ZERO IS NOT A MISSING WEIGHT (2026-08-26). ----------------------
  # FROZEN FIXTURE, verbatim from `steak-stir-fry-recipe` in run hunt-2026-08-26-smoke4 - the raw line,
  # the buy string, the ruling and its evidence are copied off disk character for character. D1 says a
  # quantity-less garnish is dropped from cost and macros and kept named for the reader; extraction
  # marked the row optional, the mapper ruled it `mapped-optional` with no bid and an explicit 0 g, and
  # the assembler still refused it as "a purchasable line with no weight".
  #
  # THE THREE OTHER EXEMPTIONS CANNOT REACH THIS LINE, AND THAT IS PINNED FIRST. Without these three
  # twins the fixture below would pass through the garnish branch and prove nothing about the new one:
  # "Fresh Basil and Lemon Wedges" carries no trailing garnish phrase, no leading label with a colon,
  # no "to taste", and no top-level `, or ` menu. The signals it DOES carry are the ones the mapper and
  # the extraction wrote, which is the whole argument for keying the exemption on them.
  T 'MUST FIRE  the smoke4 line reaches the NEW exemption and no other - it is no garnish phrase, no to-taste seasoning and no alternatives menu' `
    ((-not (Test-IsGarnishLine 'Fresh Basil and Lemon Wedges')) -and
     (-not (Test-IsPantrySeasoningToTaste 'Fresh Basil and Lemon Wedges')) -and
     (@(Split-AlternativeFoods 'Fresh Basil and Lemon Wedges').Count -eq 0)) `
    'another exemption claimed the line, so this fixture proves nothing about the new one'
  # THE PREDICATE, every signal one at a time. A zero on its own is never enough.
  T 'MUST FIRE  optional + mapped-optional + no bid + an explicit 0 g FROM THE MAPPER is a ruled zero' `
    (Test-IsRuledZeroOptional -Optional $true -RulingDecision 'mapped-optional' -Bid '' -Grams 0 -GramsFrom 'ruling') `
    'the smoke4 shape was not recognised'
  T 'CLEAN TWIN either optional signal alone carries it - the extraction flag with no ruling, or the mapper''s word on a row nobody flagged' `
    ((Test-IsRuledZeroOptional -Optional $true -RulingDecision '' -Bid '' -Grams 0 -GramsFrom 'line') -and
     (Test-IsRuledZeroOptional -Optional $false -RulingDecision 'mapped-optional' -Bid '' -Grams 0 -GramsFrom 'ruling')) `
    'one of the two optional signals was ignored'
  T 'MUST FIRE  NO WEIGHT GIVEN is still refused - $null is the case this gate exists for, and it is not a ruling' `
    (-not (Test-IsRuledZeroOptional -Optional $true -RulingDecision 'mapped-optional' -Bid '' -Grams $null -GramsFrom '')) `
    'a missing weight was read as a deliberate zero'
  T 'MUST FIRE  a NON-OPTIONAL line with an explicit 0 g is still refused - the teeth, and the reason this reads signals and not the number' `
    (-not (Test-IsRuledZeroOptional -Optional $false -RulingDecision 'mapped' -Bid '' -Grams 0 -GramsFrom 'ruling')) `
    'a purchasable line was let through on its zero alone'
  T 'MUST FIRE  a WIRED BID is a food the shopper buys, whatever it weighs' `
    (-not (Test-IsRuledZeroOptional -Optional $true -RulingDecision 'mapped-optional' -Bid 'onions' -Grams 0 -GramsFrom 'ruling')) `
    'a bid line was demoted to an optional note'
  T 'MUST FIRE  the ENGINE''s zero is not a ruling - `no-qty zero (minor item)` is one of its own fallback flags' `
    (-not (Test-IsRuledZeroOptional -Optional $true -RulingDecision 'mapped-optional' -Bid '' -Grams 0 -GramsFrom 'engine')) `
    'the engine`s guess was read as a ruling'
  T 'CLEAN TWIN a line with a REAL weight is not this rule''s business at all' `
    (-not (Test-IsRuledZeroOptional -Optional $true -RulingDecision 'mapped-optional' -Bid '' -Grams 5 -GramsFrom 'ruling')) `
    'a weighted line was demoted'
  # ---- AND NOW THE CALL SITE, which is where the bug actually lived. PLAN-map-judge-split-2026-08-25
  # section 4 records a neuter coming back 0 red because a fixture pinned a function while the defect
  # sat at its call site, so the predicate twins above are not the proof - these are. The vector runs
  # through New-MappedDecisionFile with a CLEAN TWIN line beside it, because a one-line fixture cannot
  # tell "assembled correctly" from "assembled nothing".
  $rowsZ = @((New-Row 'z1' 'z1' 'Kielbasa' 'kielbasa' 'resolved' 200.0),
             (New-Row 'zg' 'fresh basil and lemon wedges' '' '' 'new-food-suspect' $null $true))
  $payZ = [pscustomobject]@{ slug='drill-dish'
    lines = @([pscustomobject]@{ raw='z1'; buy='1 lb kielbasa'; notes='' },
              [pscustomobject]@{ raw='zg'; grams_source=0
                                 buy='optional: a handful of fresh basil leaves, torn, and lemon wedges for serving'
                                 notes="Garnish under the source's 'Optional for Garnish' heading with no quantity; carried at 0 g so it changes neither cost nor macros." })
    rulings = @([pscustomobject]@{ raw='zg'; term='fresh basil and lemon wedges'; canon_item='Fresh Basil'
                                   bid=$null; decision='mapped-optional'; grams_source=0
                                   evidence='Optional garnish with no stated quantity; named as fresh basil (the lemon wedges come off the lemons already bought). No bid because there is no amount to price, which is pantry-safe.' }) }
  $tblZ = New-Tbl $rowsZ 4
  @($tblZ.rows)[1].raw = 'Fresh Basil and Lemon Wedges'
  @($payZ.lines)[1].raw = 'Fresh Basil and Lemon Wedges'
  @($payZ.rulings)[0].raw = 'Fresh Basil and Lemon Wedges'
  $resZ = New-MappedDecisionFile $tblZ $payZ $stateRow $known 14
  $zNote = @(@($resZ.doc.ingredients) | Where-Object { $_.source_raw -eq 'Fresh Basil and Lemon Wedges' })
  T 'MUST FIRE  CALL SITE: the verbatim smoke4 line ASSEMBLES instead of parking the recipe - optional, no bid, an explicit 0 g' `
    (@($resZ.findings).Count -eq 0 -and $null -ne $resZ.doc -and $zNote.Count -eq 1) `
    ("findings=" + (@($resZ.findings) -join '; '))
  T 'MUST FIRE  ...and it is NAMED for the reader with NO cost and NO macros - `optional-note`, zero grams, no bid, nothing to buy' `
    ($zNote.Count -eq 1 -and @($zNote)[0].item -eq 'Fresh Basil' -and @($zNote)[0].decision -eq 'optional-note' -and
     @($zNote)[0].grams -eq 0 -and $null -eq @($zNote)[0].bid -and -not @($zNote)[0].buy -and @($zNote)[0].optional) `
    (($zNote | ForEach-Object { [string]$_.item + ' d=' + [string]$_.decision + ' g=' + [string]$_.grams + ' bid=' + [string]$_.bid }) -join ' | ')
  # `optional-note` AND NOT `mapped-optional` AT 0 g, pinned against the REAL classifier read out of
  # build-intake-skeleton.ps1 above. `mapped-optional` classes `optional`, which is COUNTED, and that
  # script's own `-le 0` arm would then raise "included but carries no grams" - the same recipe dying
  # one stage further along, which is not a fix.
  T 'MUST FIRE  ...and the decision it lands on is NOT-PURCHASED under the real Get-LineClass, so the next stage excludes it rather than counting a zero' `
    ((Get-LineClass @($zNote)[0].decision) -eq 'not-purchased' -and (Get-LineClass 'mapped-optional') -eq 'optional') `
    ("class=" + (Get-LineClass @($zNote)[0].decision))
  $zKiel = @(@($resZ.doc.ingredients) | Where-Object { $_.source_raw -eq 'z1' })
  T 'CLEAN TWIN the ordinary weighted line beside it is untouched - 200 g of source at 3.5x is still 700 g, still `mapped`, still bid and still bought' `
    ($zKiel.Count -eq 1 -and @($zKiel)[0].grams -eq 700 -and @($zKiel)[0].decision -eq 'mapped' -and
     @($zKiel)[0].bid -eq 'kielbasa' -and @($zKiel)[0].buy -eq '1 lb kielbasa') `
    (($zKiel | ForEach-Object { [string]$_.grams + ' ' + [string]$_.decision + ' ' + [string]$_.bid }) -join ' | ')
  # ---- THE TEETH, AT THE CALL SITE. Two shapes, because "still refused" has two halves: a line nobody
  # weighed, and a line weighed at zero that nobody ruled optional. Both must still park the recipe
  # with the SAME finding text, or this fix widened the gate instead of narrowing it.
  $rowsZ2 = @((New-Row 'z1' 'z1' 'Kielbasa' 'kielbasa' 'resolved' 200.0),
              (New-Row 'zp' 'sumac' 'Sumac' '' 'unresolved' $null))
  $payZ2 = [pscustomobject]@{ slug='drill-dish'
    lines = @([pscustomobject]@{ raw='z1'; buy='1 lb kielbasa'; notes='' },
              [pscustomobject]@{ raw='zp'; buy='2 tbsp sumac'; notes='' })
    rulings = @([pscustomobject]@{ raw='zp'; term='sumac'; canon_item='Sumac'; bid=$null
                                   decision='mapped'; grams_source=$null; evidence='a real spice the shopper buys' }) }
  $resZ2 = New-MappedDecisionFile (New-Tbl $rowsZ2 4) $payZ2 $stateRow $known 14
  T 'MUST FIRE  TEETH, CALL SITE: a NON-OPTIONAL purchasable line with NO weight is STILL refused, with the same finding text' `
    ($null -eq $resZ2.doc -and
     (@($resZ2.findings) -join ' ') -match 'has no gram weight from the engine or from a ruling') `
    ("findings=" + (@($resZ2.findings) -join '; '))
  $payZ3 = [pscustomobject]@{ slug='drill-dish'
    lines = @([pscustomobject]@{ raw='z1'; buy='1 lb kielbasa'; notes='' },
              [pscustomobject]@{ raw='zp'; buy='2 tbsp sumac'; notes='' })
    rulings = @([pscustomobject]@{ raw='zp'; term='sumac'; canon_item='Sumac'; bid=$null
                                   decision='mapped'; grams_source=0; evidence='a real spice the shopper buys' }) }
  $resZ3 = New-MappedDecisionFile (New-Tbl $rowsZ2 4) $payZ3 $stateRow $known 14
  T 'MUST FIRE  TEETH, CALL SITE: a NON-OPTIONAL line the mapper weighed at ZERO is refused too - the exemption reads the signals, never the number' `
    ($null -eq $resZ3.doc -and (@($resZ3.findings) -join ' ') -match 'has no gram weight from the engine or from a ruling') `
    ("findings=" + (@($resZ3.findings) -join '; '))

  # ---- FIXTURE A1d. D5: AN ALTERNATIVES LINE NAMES A CHOICE, SO CHOOSE ---------------------------
  # FROZEN FIXTURE (Brad's ruling 2026-08-24). 6b parked a recipe on
  # "Prepared brown and wild rice blend, brown rice, quinoa, or cauliflower rice" after map, registrar
  # AND pricing had been paid. The ruling: take the cheapest, but ONLY alternatives resolving through a
  # board id or label - an include-pattern match is how `cauliflower rice` prices as WHITE RICE.
  $altSplit = (@(Split-AlternativeFoods 'Prepared brown and wild rice blend, brown rice, quinoa, or cauliflower rice')) -join '|'
  T 'MUST FIRE  an alternatives line splits into its stated foods, with the leading state word stripped' `
    ($altSplit -eq 'brown and wild rice blend|brown rice|quinoa|cauliflower rice') $altSplit
  T 'CLEAN TWIN an ordinary line is not an alternatives line' `
    ((@(Split-AlternativeFoods '2 cups brown rice')).Count -eq 0) 'split a plain line'
  T 'CLEAN TWIN a bare "a or b" with no list punctuation is a phrase, not a menu' `
    ((@(Split-AlternativeFoods 'salt or pepper')).Count -eq 0) 'split a bare or-phrase'
  # A PARENTHETICAL IS NOT A MENU (found 2026-08-24, the day D5 shipped). Of 201 pool lines carrying
  # `, or `, 155 state a quantity and nearly all of those are VARIETY NOTES in brackets. The first
  # splitter turned "1 bell pepper (red, yellow, or orange, chopped)" into four foods, none real. Those
  # lines never reached D5 because their quantity earns them a weight - luck, not design, since a
  # bracketed line with NO weight would have mis-split and gone shopping for the wrong food.
  T 'MUST FIRE  a bracketed VARIETY note is not an alternatives line - the food is stated once' `
    ((@(Split-AlternativeFoods '1 bell pepper (red, yellow, or orange, chopped)')).Count -eq 0) `
    ((@(Split-AlternativeFoods '1 bell pepper (red, yellow, or orange, chopped)')) -join ' | ')
  T 'MUST FIRE  ...and neither is a bracketed SUBSTITUTION note' `
    ((@(Split-AlternativeFoods '10 small corn tortillas (6-inch, or flour tortillas)')).Count -eq 0) `
    ((@(Split-AlternativeFoods '10 small corn tortillas (6-inch, or flour tortillas)')) -join ' | ')
  T 'MUST FIRE  ...nor a bracketed list on a line with NO quantity, which is the one that could reach D5' `
    ((@(Split-AlternativeFoods 'Fresh herbs (parsley, dill, or chives)')).Count -eq 0) `
    ((@(Split-AlternativeFoods 'Fresh herbs (parsley, dill, or chives)')) -join ' | ')
  T 'CLEAN TWIN and a genuine TOP-LEVEL menu still splits' `
    ((@(Split-AlternativeFoods 'Prepared brown and wild rice blend, brown rice, quinoa, or cauliflower rice')).Count -eq 4) `
    ((@(Split-AlternativeFoods 'Prepared brown and wild rice blend, brown rice, quinoa, or cauliflower rice')) -join ' | ')
  # THE UNIT TRAP, and it is the reason this ranks per POUND rather than on the raw figure. quinoa
  # prices per OUNCE at 0.1372, which is 2.20/lb - the DEAREST of the four - yet a naive comparison
  # ranks it first.
  T 'MUST FIRE  prices are normalised to a common unit before ranking - an oz price is 16x its number' `
    ((Get-PerLbPrice ([pscustomobject]@{ cheapest = 0.1372; unit = 'oz' })) -gt `
     (Get-PerLbPrice ([pscustomobject]@{ cheapest = 0.88;   unit = 'lb' }))) `
    'an ounce price outranked a pound price'
  T 'MUST FIRE  a unit this cannot normalise returns NULL and is refused, never ranked on its number' `
    ($null -eq (Get-PerLbPrice ([pscustomobject]@{ cheapest = 0.5; unit = 'ea' }))) 'ranked an each price'
  # The exact-road guard, over a stubbed price result set: two include-pattern rows are CHEAPER and
  # must both lose to the one board id/label row.
  $altStub = Join-Path $env:TEMP ('altstub-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
  try {
    @'
param([switch]$Json, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Name = @())
$r = @(
  [pscustomobject]@{ term='brown and wild rice blend'; tier='MAPPED'; commodity='rice'; resolved_by='include pattern /rice/'; unit='lb'; cheapest=0.4396 }
  [pscustomobject]@{ term='brown rice';                tier='MAPPED'; commodity='brown-rice'; resolved_by='board id/label'; unit='lb'; cheapest=0.88 }
  [pscustomobject]@{ term='quinoa';                    tier='MAPPED'; commodity='quinoa-uncooked'; resolved_by="search term 'quinoa'"; unit='oz'; cheapest=0.1372 }
  [pscustomobject]@{ term='cauliflower rice';          tier='MAPPED'; commodity='rice'; resolved_by='include pattern /rice/'; unit='lb'; cheapest=0.4396 })
[pscustomobject]@{ results = $r } | ConvertTo-Json -Depth 6
'@ | Set-Content -Path $altStub -Encoding utf8
    $pick = Select-CheapestAlternative -Foods @('brown and wild rice blend','brown rice','quinoa','cauliflower rice') -PriceScript $altStub
    T 'MUST FIRE  the CHEAPEST EXACT match wins, and two cheaper include-pattern rows both lose - that is the guard that stops cauliflower rice pricing as white rice' `
      ($null -ne $pick -and $pick.term -eq 'brown rice' -and $pick.commodity -eq 'brown-rice') `
      ($(if ($pick) { $pick.term + ' / ' + $pick.commodity } else { 'nothing chosen' }))
    T 'MUST FIRE  ...and the choice is DISCLOSED - the evidence names the food, the id and the road' `
      ($null -ne $pick -and $pick.evidence -match 'brown rice' -and $pick.evidence -match 'board id/label') `
      ($(if ($pick) { $pick.evidence } else { 'nothing chosen' }))
  } finally { Remove-Item $altStub -Force -ErrorAction SilentlyContinue }
  # AND WHEN NOTHING RESOLVES EXACTLY, NOTHING IS CHOSEN. Guessing here is the whole defect.
  $altStub2 = Join-Path $env:TEMP ('altstub2-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
  try {
    @'
param([switch]$Json, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Name = @())
$r = @([pscustomobject]@{ term='a'; tier='MAPPED'; commodity='rice'; resolved_by='include pattern /rice/'; unit='lb'; cheapest=0.10 },
       [pscustomobject]@{ term='b'; tier='ABSENT'; commodity=$null; resolved_by='no commodity claims this term'; unit='lb'; cheapest=$null })
[pscustomobject]@{ results = $r } | ConvertTo-Json -Depth 6
'@ | Set-Content -Path $altStub2 -Encoding utf8
    T 'MUST FIRE  no exact match means NO choice - the recipe parks rather than pricing a substitution' `
      ($null -eq (Select-CheapestAlternative -Foods @('a','b') -PriceScript $altStub2)) 'chose a non-exact match'
  } finally { Remove-Item $altStub2 -Force -ErrorAction SilentlyContinue }

  # ---- FIXTURE A2. THE DECISION VOCABULARY IS Get-LineClass's (pin P4). ---------------------------
  # Free-texting this field produced 21 distinct values across 550 v2 lines, and the ones the builder
  # did not recognise silently dropped 1588 g of Ground Chicken out of a recipe, computed 250 cal per
  # serving over what was left, and let the band gate retire a real dish on a fabricated number.
  $rowsB = @(
    (New-Row 'a' 'a' 'Cauliflower' 'cauliflower' 'resolved' 100.0),
    (New-Row 'b' 'b' 'Heavy Cream' 'heavy-cream' 'resolved' 100.0 $true),
    (New-Row 'c' 'c' '' '' 'unresolved' $null),
    (New-Row 'd' 'd' '' '' 'unresolved' $null))
  $payB = [pscustomobject]@{ slug='drill-dish'
    lines = @([pscustomobject]@{ raw='a'; buy='1 lb'; notes='' },
              [pscustomobject]@{ raw='b'; buy='2 cups'; notes='' },
              [pscustomobject]@{ raw='c'; buy='3 tbsp'; notes='' },
              [pscustomobject]@{ raw='d'; buy=''; notes='' })
    rulings = @([pscustomobject]@{ raw='c'; term='c'; canon_item='Sumac Blend'; bid=$null; decision='mapped-null'; grams_source=12; evidence='real food, no commodity id - pantry-static' },
                [pscustomobject]@{ raw='d'; term='d'; canon_item='Water'; bid=$null; decision='not-purchased'; grams_source=$null; evidence='nobody buys water' }) }
  $resB = New-MappedDecisionFile (New-Tbl $rowsB 4) $payB $stateRow $known 14
  $classes = @(@($resB.doc.ingredients) | ForEach-Object { Get-LineClass ([string]$_.decision) })
  T 'MUST FIRE  EVERY decision string the assembler emits classes as included / optional / not-purchased under the REAL Get-LineClass - never `unknown`, never `unsettled`' `
    (@($resB.findings).Count -eq 0 -and @($classes).Count -eq 4 -and
     -not (@($classes) -contains 'unknown') -and -not (@($classes) -contains 'unsettled')) `
    (("findings=" + (@($resB.findings) -join '; ')) + ' classes=' + (@($classes) -join ','))
  T 'MUST FIRE  ...and all four land where they were meant to: mapped=included, mapped-optional=optional, mapped-null=included, optional-note=not-purchased' `
    ((@($classes) -join ',') -eq 'included,optional,included,not-purchased') ((@($classes) -join ','))
  T 'CLEAN TWIN a not-purchased line is NAMED in the file rather than dropped, so QA and the auditor can see the call that was made' `
    (@($resB.doc.ingredients)[3].item -eq 'Water' -and @($resB.doc.ingredients)[3].grams -eq 0 -and
     @($resB.doc.ingredients)[3].notes -match 'nobody buys water') `
    ([string]@($resB.doc.ingredients)[3].decision)
  # ...and a word outside the closed set is refused rather than shipped as a 22nd value
  $payBad = [pscustomobject]@{ slug='drill-dish'
    lines = @([pscustomobject]@{ raw='c'; buy='3 tbsp'; notes='' })
    rulings = @([pscustomobject]@{ raw='c'; term='c'; canon_item='X'; bid=$null; decision='unresolved-hold'; grams_source=3; evidence='' }) }
  $resBad = New-MappedDecisionFile (New-Tbl @((New-Row 'c' 'c' '' '' 'unresolved' $null)) 4) $payBad $stateRow $known 14
  T 'MUST FIRE  a decision word OUTSIDE the closed set is refused and named - `unresolved-hold` is a real v2 value that classed `unsettled` and dropped a protein' `
    ($null -eq $resBad.doc -and (@($resBad.findings) -join ' ') -match 'unresolved-hold') ((@($resBad.findings) -join '; '))

  # ---- FIXTURE A3. THE REGISTRAR GATE (A4 / pin P6). ---------------------------------------------
  # A3 strips the Agent tool from the mapper, which severs the road its own definition orders new ids
  # down. A4 rebuilds it daemon-side, and the enforcement lives in the assembler so it does not depend
  # on a prompt being remembered. The test reads the VOCABULARY - it does not trust the payload to
  # declare its own proposals.
  $rowsC = @(
    (New-Row 'p' 'p' '' '' 'new-food-suspect' $null),
    (New-Row 'q' 'q' 'Cauliflower' 'cauliflower' 'resolved' 100.0),
    (New-Row 'r' 'r' 'Heavy Cream' 'heavy-cream' 'resolved' 100.0))
  $linesC = @([pscustomobject]@{ raw='p'; buy='1 can'; notes='' },
              [pscustomobject]@{ raw='q'; buy='1 lb'; notes='' },
              [pscustomobject]@{ raw='r'; buy='1 cup'; notes='' })
  $ruleC  = @([pscustomobject]@{ raw='p'; term='p'; canon_item='Artichoke Hearts'; bid='artichoke-hearts'; decision='mapped'; grams_source=312; evidence='new id proposed' })
  $reject = [pscustomobject]@{ slug='drill-dish'; lines=$linesC; rulings=$ruleC
    registrar_rulings=@([pscustomobject]@{ proposed_bid='artichoke-hearts'; verdict='reject'; bid=''; reason='the existing canned-vegetables id already prices this' }) }
  $resRej = New-MappedDecisionFile (New-Tbl $rowsC 4) $reject $stateRow $known 14
  T 'MUST FIRE  with the registrar returning REJECT, NO file is produced and the proposed bid appears NOWHERE in it' `
    ($null -eq $resRej.doc -and (@($resRej.findings) -join ' ') -match 'REJECTED the new id' -and
     (@($resRej.findings) -join ' ') -match 'already prices this') ((@($resRej.findings) -join '; '))
  $silent = [pscustomobject]@{ slug='drill-dish'; lines=$linesC; rulings=$ruleC }
  $resSil = New-MappedDecisionFile (New-Tbl $rowsC 4) $silent $stateRow $known 14
  T 'MUST FIRE  a NEW commodity id with no registrar ruling at all is refused too - silence is not approval, and the check reads db\ingredients.json rather than trusting the payload to declare its own proposals' `
    ($null -eq $resSil.doc -and (@($resSil.findings) -join ' ') -match 'no commodity-registrar ruling approves it') ((@($resSil.findings) -join '; '))
  $alias = [pscustomobject]@{ slug='drill-dish'; lines=$linesC; rulings=$ruleC
    registrar_rulings=@([pscustomobject]@{ proposed_bid='artichoke-hearts'; verdict='alias'; bid='onions'; reason='fixture alias onto a wired id' }) }
  $resAli = New-MappedDecisionFile (New-Tbl $rowsC 4) $alias $stateRow $known 14
  T 'CLEAN TWIN an ALIAS verdict lands the EXISTING id, never the proposed one' `
    (@($resAli.findings).Count -eq 0 -and @($resAli.doc.ingredients)[0].bid -eq 'onions') `
    ("findings=" + (@($resAli.findings) -join '; ') + " bid=" + [string]@($resAli.doc.ingredients)[0].bid)
  $approve = [pscustomobject]@{ slug='drill-dish'; lines=$linesC; rulings=$ruleC
    registrar_rulings=@([pscustomobject]@{ proposed_bid='artichoke-hearts'; verdict='approve'; bid='artichoke-hearts'; reason='no id in any namespace prices canned artichoke hearts' }) }
  $resApp = New-MappedDecisionFile (New-Tbl $rowsC 4) $approve $stateRow $known 14
  T 'CLEAN TWIN only an APPROVE mints the new id, and then it does land' `
    (@($resApp.findings).Count -eq 0 -and @($resApp.doc.ingredients)[0].bid -eq 'artichoke-hearts') `
    ("findings=" + (@($resApp.findings) -join '; '))
  $aliasBad = [pscustomobject]@{ slug='drill-dish'; lines=$linesC; rulings=$ruleC
    registrar_rulings=@([pscustomobject]@{ proposed_bid='artichoke-hearts'; verdict='alias'; bid='nothing-wires-this'; reason='' }) }
  $resAB = New-MappedDecisionFile (New-Tbl $rowsC 4) $aliasBad $stateRow $known 14
  T 'MUST FIRE  an alias onto an id NO COMMODITY NAMESPACE carries either is refused - an alias is a claim about an EXISTING id' `
    ($null -eq $resAB.doc -and (@($resAB.findings) -join ' ') -match 'carries either') ((@($resAB.findings) -join '; '))

  # ---- FIXTURE A4. THE FIVE WAYS A LINE IS NOT SETTLED, each refusing the WHOLE file. -------------
  # Nothing is written on any of them. Half a decision file on disk is worse than none: the half that
  # landed looks settled, and D8 builds an intake over it.
  $baseRows = @((New-Row 'x' 'x' 'Cauliflower' 'cauliflower' 'resolved' 100.0),
                (New-Row 'y' 'y' 'Heavy Cream' 'heavy-cream' 'resolved' 100.0),
                (New-Row 'z' 'z' '' '' 'unresolved' $null))
  $baseLines = @([pscustomobject]@{ raw='x'; buy='1 lb'; notes='' },
                 [pscustomobject]@{ raw='y'; buy='1 cup'; notes='' },
                 [pscustomobject]@{ raw='z'; buy='2 tbsp'; notes='' })
  $noRuling = New-MappedDecisionFile (New-Tbl $baseRows 4) ([pscustomobject]@{ lines=$baseLines; rulings=@() }) $stateRow $known 14
  T 'MUST FIRE  a RESIDUAL line the mapper said nothing about refuses the file - that line is exactly what it was dispatched to settle' `
    ($null -eq $noRuling.doc -and (@($noRuling.findings) -join ' ') -match 'returned no ruling') ((@($noRuling.findings) -join '; '))
  $noGrams = New-MappedDecisionFile (New-Tbl $baseRows 4) ([pscustomobject]@{ lines=$baseLines
    rulings=@([pscustomobject]@{ raw='z'; term='z'; canon_item='Sumac'; bid=$null; decision='mapped'; grams_source=$null; evidence='' }) }) $stateRow $known 14
  T 'MUST FIRE  a purchasable line with NO grams from the engine and none from a ruling is a refusal, never a silent zero - a zero-gram line is food the reader buys and the card ignores' `
    ($null -eq $noGrams.doc -and (@($noGrams.findings) -join ' ') -match 'no gram weight') ((@($noGrams.findings) -join '; '))
  $noBuy = New-MappedDecisionFile (New-Tbl $baseRows 4) ([pscustomobject]@{
    lines=@([pscustomobject]@{ raw='x'; buy='1 lb'; notes='' }, [pscustomobject]@{ raw='y'; buy=''; notes='' }, [pscustomobject]@{ raw='z'; buy='2 tbsp'; notes='' })
    rulings=@([pscustomobject]@{ raw='z'; term='z'; canon_item='Sumac'; bid=$null; decision='mapped'; grams_source=6; evidence='' }) }) $stateRow $known 14
  T 'MUST FIRE  a line with no BUY string is a refusal - that string is printed verbatim in the reader''s Ingredients section and D8 locks it, so there would be nothing to lock' `
    ($null -eq $noBuy.doc -and (@($noBuy.findings) -join ' ') -match 'no buy string') ((@($noBuy.findings) -join '; '))
  $rejected = New-MappedDecisionFile (New-Tbl $baseRows 4) ([pscustomobject]@{ lines=$baseLines
    rulings=@([pscustomobject]@{ raw='z'; term='z'; canon_item=''; bid=$null; decision='rejected'; grams_source=$null; evidence='no Omaha store carries a tteok that is not a snack cake' }) }) $stateRow $known 14
  T 'MUST FIRE  a line the mapper REJECTED refuses the file and quotes its reason - the honest no is a STUCK, not a hole' `
    ($null -eq $rejected.doc -and (@($rejected.findings) -join ' ') -match 'snack cake') ((@($rejected.findings) -join '; '))
  $unbidRows = @((New-Row 'x' 'x' 'Cauliflower' 'cauliflower' 'resolved' 100.0),
                 (New-Row 'y' 'y' 'Heavy Cream' 'heavy-cream' 'resolved' 100.0),
                 (New-Row 'u' 'u' 'Sumac' '' 'unbid' 5.0))
  $unbid = New-MappedDecisionFile (New-Tbl $unbidRows 4) ([pscustomobject]@{
    lines=@([pscustomobject]@{ raw='x'; buy='1 lb'; notes='' }, [pscustomobject]@{ raw='y'; buy='1 cup'; notes='' }, [pscustomobject]@{ raw='u'; buy='1 tsp'; notes='' }); rulings=@() }) $stateRow $known 14
  T 'MUST FIRE  an UNBID row reaching the assembler is a refusal - the daemon holds that recipe off the table''s `holds` list, and shipping it would put an unpriced ingredient on a priced card' `
    ($null -eq $unbid.doc -and (@($unbid.findings) -join ' ') -match 'HOLD') ((@($unbid.findings) -join '; '))
  $noProt = New-MappedDecisionFile (New-Tbl $rowsA 4) $payA $null $known 14
  T 'MUST FIRE  no protein anywhere is a refusal - D8 exits 1 on it and the wave manifest is built out of exactly that field' `
    ($null -eq $noProt.doc -and (@($noProt.findings) -join ' ') -match 'no protein') ((@($noProt.findings) -join '; '))
  $noServ = New-MappedDecisionFile (New-Tbl $rowsA 0) $payA $stateRow $known 14
  T 'MUST FIRE  a table with no source servings is a refusal - a guessed batch size is a guessed price AND a guessed macro' `
    ($null -eq $noServ.doc -and (@($noServ.findings) -join ' ') -match 'source servings') ((@($noServ.findings) -join '; '))

  # ---- FIXTURE A5. THE EXIT CODES, AS A CHILD PROCESS, and the refusal to write half a file. ------
  $asm = Join-Path $env:TEMP ('mpre-asm-' + [guid]::NewGuid().ToString('N'))
  try {
    New-Item -ItemType Directory -Path (Join-Path $asm 'mapped-pre') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $asm 'state') -Force | Out-Null
    ((New-Tbl $rowsA 4) | ConvertTo-Json -Depth 9) | Set-Content (Join-Path $asm 'mapped-pre\drill-dish.json') -Encoding utf8
    ([pscustomobject]@{ slug='drill-dish'; protein='pork'; state='mapped' } | ConvertTo-Json) | Set-Content (Join-Path $asm 'state\drill-dish.json') -Encoding utf8
    $pAll = Join-Path $asm 'rulings-ok.json'
    ($payA | ConvertTo-Json -Depth 9) | Set-Content $pAll -Encoding utf8
    $rOk = Invoke-Child $PSCommandPath @('-Assemble', '-RunDir', $asm, '-Slug', 'drill-dish', '-RulingsFile', $pAll)
    T 'MUST FIRE  -Assemble exits 0 and writes mapped\<slug>.json - ONE file, ONE writer, no mutex (the map lane''s workers never share a slug)' `
      ($rOk.rc -eq 0 -and (Test-Path (Join-Path $asm 'mapped\drill-dish.json'))) ("rc=" + $rOk.rc + ' ' + $rOk.text.Trim())
    $onDisk = Read-Json (Join-Path $asm 'mapped\drill-dish.json')
    # ASSIGN FIRST. `@(As-Array $x)` COLLECTS ONE OUTPUT OBJECT holding an array - As-Array's own header
    # says so and this fixture walked straight into it on 2026-08-24: .Count read 1 over three lines and
    # [0].grams unrolled to "1588 1361 210". The comma operator preserves array-ness across the return
    # boundary; @() around the CALL undoes nothing and re-wraps it. Only an assignment (or parentheses)
    # hands the value on as the array itself.
    $diskIngs = As-Array $onDisk.ingredients
    T 'MUST FIRE  ...and the file round-trips through disk with all three lines and the frozen v2 gram vector intact' `
      ($diskIngs.Count -eq 3 -and $diskIngs[0].grams -eq 1588 -and
       $onDisk.scale_factor -eq 3.5 -and $onDisk.protein -eq 'pork') `
      ("lines=" + [string]$diskIngs.Count + " g=" + [string]$diskIngs[0].grams)
    Remove-Item (Join-Path $asm 'mapped') -Recurse -Force -ErrorAction SilentlyContinue
    $pBad = Join-Path $asm 'rulings-bad.json'
    ([pscustomobject]@{ slug='drill-dish'; lines=@($payA.lines[0], $payA.lines[1]); rulings=@() } | ConvertTo-Json -Depth 9) | Set-Content $pBad -Encoding utf8
    $rBad = Invoke-Child $PSCommandPath @('-Assemble', '-RunDir', $asm, '-Slug', 'drill-dish', '-RulingsFile', $pBad)
    T 'MUST FIRE  findings are exit 1 and NOTHING is written - half a decision file looks settled, and D8 would build an intake over it' `
      ($rBad.rc -eq 1 -and -not (Test-Path (Join-Path $asm 'mapped\drill-dish.json'))) `
      ("rc=" + $rBad.rc + " wrote=" + (Test-Path (Join-Path $asm 'mapped\drill-dish.json')))
    T 'MUST FIRE  ...and exit 1 NAMES the line, so the STUCK is a state a person can act on' `
      ($rBad.text -match 'FINDING' -and $rBad.text -match 'heavy cream') $rBad.text.Trim()
    $rMissing = Invoke-Child $PSCommandPath @('-Assemble', '-RunDir', $asm, '-Slug', 'nosuchslug', '-RulingsFile', $pAll)
    T 'MUST FIRE  no pre-resolve table is exit 2 - BLOCKED, never a clean bill' ($rMissing.rc -eq 2) ("rc=" + $rMissing.rc)
    $rNoPayload = Invoke-Child $PSCommandPath @('-Assemble', '-RunDir', $asm, '-Slug', 'drill-dish', '-RulingsFile', (Join-Path $asm 'nope.json'))
    T 'MUST FIRE  no rulings payload is exit 2 too' ($rNoPayload.rc -eq 2) ("rc=" + $rNoPayload.rc)
    $rComma = Invoke-Child $PSCommandPath @('-Assemble', '-RunDir', $asm, '-Slug', 'a,b', '-RulingsFile', $pAll)
    T 'MUST FIRE  a COMMA in -Slug is exit 2 - that is ONE composite string, the -Terms ''a,b'' family arriving one level down' `
      ($rComma.rc -eq 2 -and $rComma.text -match 'composite') ("rc=" + $rComma.rc)
  } finally { Remove-Item $asm -Recurse -Force -ErrorAction SilentlyContinue }

  # ---- FIXTURE A6. THE FDC SHELF RENDERS A WHOLE ROW, AND THE ID THAT CITES IT (M1, 2026-08-25). --
  # THE DEADLOCK THIS CLOSES, measured on the lf1 transcripts: the shelf rendered description,
  # data_type, calories, protein and carbs - three of the six fields map_prompt requires - and never
  # the fdc_id, while write_food_db_rows REFUSES a row whose source is neither `fdc:` nor a URL. A
  # mapper obeying the contract could not build a row off the shelf, so round 1 re-acquired six foods
  # by querying api.nal.usda.gov itself with DEMO_KEY, five of them already on the shelf.
  #
  # NEUTER PROOF, RUN AND REVERTED 2026-08-25: reverting the render to the three-number form
  # ("{0} [{1}] per 100 g: {2} cal, {3} P, {4} C" over description/data_type/cal/P/C, First 3) turned
  # FIVE cases red, not the two this section was written expecting - the four-row/fdc: case, the `?`
  # case, the honest-zero case, the portions case, and the assembled-evidence case. All five are the
  # same defect seen from five sides, and the count is recorded rather than the prediction. The four
  # that stayed GREEN are exactly the twins: the asked-and-empty shelf, the never-asked shelf, the
  # marker wording, and a food-DB-known row carrying no shelf at all.
  $script:FdcCache = @{
    'ras el hanout' = [pscustomobject]@{ asked=$true; candidates=@(
      [pscustomobject]@{ fdc_id=171322; description='Spices, ras el hanout'; data_type='SR Legacy'; brand=$null; basis='per 100 g'
                         macros=[pscustomobject]@{ calories=347.0; protein_g=11.1; carbs_g=55.4; fat_g=13.9; fiber_g=25.5 }
                         portions=@([pscustomobject]@{ measure='1 tbsp'; grams=6.8 },
                                    [pscustomobject]@{ measure='1 tsp'; grams=2.3 },
                                    [pscustomobject]@{ measure='1 cup'; grams=109.0 },
                                    [pscustomobject]@{ measure='1 jar'; grams=42.0 }) },
      # THE MISSING-MACRO CASE, and it is not hypothetical: 29 of the live cache's candidates are
      # missing at least one macro today, all-purpose flour and granulated sugar among them.
      [pscustomobject]@{ fdc_id=789890; description='Ras el hanout blend, no fat stated'; data_type='Foundation'; brand=$null; basis='per 100 g'
                         macros=[pscustomobject]@{ calories=330.0; protein_g=10.0; carbs_g=60.0; fiber_g=20.0 }
                         portions=@() },
      # ...AND THE HONEST ZERO BESIDE IT. Salt and water really are 0/0/0, so a zero must render as 0
      # and only an ABSENT number as `?`. The two are different claims about a food.
      [pscustomobject]@{ fdc_id=173468; description='Salt, table'; data_type='SR Legacy'; brand=$null; basis='per 100 g'
                         macros=[pscustomobject]@{ calories=0.0; protein_g=0.0; carbs_g=0.0; fat_g=0.0; fiber_g=0.0 }
                         portions=@() },
      [pscustomobject]@{ fdc_id=999001; description='RAS EL HANOUT'; data_type='Branded'; brand='A Brand'; basis='per 100 g'
                         macros=[pscustomobject]@{ calories=300.0; protein_g=9.0; carbs_g=50.0; fat_g=12.0; fiber_g=18.0 }
                         portions=@() },
      [pscustomobject]@{ fdc_id=999002; description='A FIFTH ROW THE SHELF MUST NOT SHOW'; data_type='Branded'; brand='B Brand'; basis='per 100 g'
                         macros=[pscustomobject]@{ calories=1.0; protein_g=1.0; carbs_g=1.0; fat_g=1.0; fiber_g=1.0 }
                         portions=@() }
    ) }
    'labneh' = [pscustomobject]@{ asked=$true; candidates=@() }
  }
  $shelf = Get-FdcCandidates 'Ras El Hanout'
  $shelfRows = @($shelf -split ' \| ')
  T 'MUST FIRE  the shelf renders FOUR whole rows and every one of them opens with the literal `fdc:<id>` the prompt asks for in `source`' `
    ($shelfRows.Count -eq 4 -and @($shelfRows | Where-Object { $_ -match '^fdc:\d+ ' }).Count -eq 4 -and
     $shelf -notmatch 'A FIFTH ROW' -and $shelfRows[0] -match '^fdc:171322 Spices, ras el hanout \[SR Legacy\] per 100 g: 347 cal, 11\.1 P, 55\.4 C, 13\.9 F, 25\.5 fiber') `
    ("rows=" + [string]$shelfRows.Count + ' :: ' + $shelf)
  T 'MUST FIRE  a macro FDC DID NOT STATE renders `?` and never 0 - a missing number and a zero are different claims about a food' `
    ($shelfRows[1] -match 'per 100 g: 330 cal, 10 P, 60 C, \? F, 20 fiber') $shelfRows[1]
  T 'CLEAN TWIN an HONEST zero still renders 0 - salt is really 0/0/0, and turning that into `?` would be the same lie backwards' `
    ($shelfRows[2] -match 'per 100 g: 0 cal, 0 P, 0 C, 0 F, 0 fiber') $shelfRows[2]
  T 'MUST FIRE  the STATED portions ride along in both a household measure and grams, capped at three' `
    ($shelfRows[0] -match 'portions: 1 tbsp=6\.8g, 1 tsp=2\.3g, 1 cup=109g$' -and $shelfRows[0] -notmatch '1 jar') $shelfRows[0]
  T 'CLEAN TWIN a candidate with NO stated portions carries no portions clause at all, rather than an empty one' `
    ($shelfRows[1] -notmatch 'portions:') $shelfRows[1]
  T 'CLEAN TWIN a term FDC was asked about and had nothing for is still an empty shelf' `
    ((Get-FdcCandidates 'labneh') -eq '') (Get-FdcCandidates 'labneh')
  T 'CLEAN TWIN a term NOBODY has asked about is an empty shelf too - a cold cache must still look exactly like a cold cache' `
    ((Get-FdcCandidates 'gochujang') -eq '') (Get-FdcCandidates 'gochujang')

  # ...AND THROUGH THE REAL EVIDENCE ASSEMBLY, not the renderer alone. The marker wording is what
  # Daemon.FDC_SHELF_MARKER matches on to compute shelf_coverage, so it is asserted here byte for byte
  # rather than trusted: changing it silently breaks the coverage line and nothing else complains.
  # ITS OWN LOOKUPS, under names no earlier fixture takes: this suite reassigns $extraction, $classes
  # and $vocab several times on the way down, and a positional call binding a STRING where $Classes
  # belongs throws on .ContainsKey rather than failing an assertion.
  $fdcVocab = @(
    [pscustomobject]@{ item='Yellow Onion'; bid='onions'; unit='lb'; board='weekly'; gpu=453.592 },
    [pscustomobject]@{ item='Boneless Skinless Chicken Thigh'; bid='chicken-thighs'; unit='lb'; board='weekly'; gpu=453.592 },
    [pscustomobject]@{ item='Sumac'; bid='sumac'; unit='oz'; board='recipe'; gpu=28.35 }
  )
  $fdcExtraction = [pscustomobject]@{
    title='Drill Dish'; source_url='https://d/x'; servings=4
    ingredients=@(
      [pscustomobject]@{ raw='1 tablespoon ras el hanout'; item='ras el hanout'; qty='1'; unit='tablespoon'; optional=$false },
      [pscustomobject]@{ raw='1 small yellow onion, chopped'; item='Yellow Onion'; qty='1'; unit=$null; optional=$false },
      [pscustomobject]@{ raw='1 teaspoon sumac'; item='Sumac'; qty='1'; unit='teaspoon'; optional=$false }
    ) }
  $fdcClasses = @{
    'ras el hanout' = [pscustomobject]@{ name='ras el hanout'; class='GENUINE-GAP'; candidates=@() }
    'Yellow Onion'  = [pscustomobject]@{ name='Yellow Onion'; class='RESOLVES'; resolves_to='Yellow Onion'; candidates=@() }
    'Sumac'         = [pscustomobject]@{ name='Sumac'; class='RESOLVES'; resolves_to='Sumac'; candidates=@() }
  }
  $fdcDens = @{ 'Yellow Onion'=1; 'Sumac'=1 }
  $fdcEach = @{ 'Yellow Onion'=1 }
  $fdcFoodDb = @{ 'Yellow Onion'=1; 'Sumac'=1; 'Boneless Skinless Chicken Thigh'=1 }
  $tblFdc = New-PreResolveTable 'drill-dish' $fdcExtraction $fdcVocab $fdcClasses @{} @{} $fdcDens $fdcEach $fdcFoodDb
  $rowFdc = @($tblFdc.rows | Where-Object { [string]$_.term -eq 'ras el hanout' })[0]
  $rowKnown = @($tblFdc.rows | Where-Object { [string]$_.term -eq 'Yellow Onion' })[0]
  T 'MUST FIRE  the assembled row still carries the `USDA FDC rows that MENTION this term` marker Daemon.FDC_SHELF_MARKER counts on' `
    ([string]$rowFdc.evidence -match 'USDA FDC rows that MENTION this term, per 100 g - a shelf, not an answer\.') `
    ([string]$rowFdc.evidence)
  T 'MUST FIRE  ...and the four whole rows arrive WITH it, so the mapper can cite one without re-acquiring the food' `
    ([string]$rowFdc.evidence -match 'fdc:171322' -and [string]$rowFdc.evidence -match '13\.9 F, 25\.5 fiber') `
    ([string]$rowFdc.evidence)
  T 'CLEAN TWIN a term the food DB already knows gets no shelf line at all - the attach only ever runs where a label is missing' `
    ([string]$rowKnown.evidence -notmatch 'USDA FDC') ([string]$rowKnown.evidence)
  $script:FdcCache = $null

  # ---- COMPOSITE TERM SPLITTING, END TO END (2026-08-26) -----------------------------------------
  # THE RULE ITSELF IS coverage_check.py's AND ITS FIXTURES LIVE THERE. What is proved here is the
  # WIRING: that this file asks, that it can read the answer back, and that the rewrite it does to an
  # extraction is one the rest of this file can carry. Run hunt-2026-08-26-ten lost twelve recipes at
  # the write lane and parked four more, and 'Salt and Pepper' was the named blocker on two of them.
  $splitProbe = Get-CompositeSplits @('Salt and Pepper', 'Sweet and Sour Sauce', 'Yellow Onion') `
                                    @('Yellow Onion') `
                                    @('Salt', 'Black Pepper', 'Yellow Onion', 'Sour Sauce')
  T 'MUST FIRE  the composite splitter can actually be ASKED from here - a rule nothing calls is a rule the batch does not have' `
    ([string]$splitProbe.why -eq '') ([string]$splitProbe.why)
  T "MUST FIRE  'Salt and Pepper' comes back as TWO foods across the process boundary" `
    ($splitProbe.splits.ContainsKey('Salt and Pepper') -and
     (@($splitProbe.splits['Salt and Pepper']) -join '|') -eq 'Salt|Pepper') `
    ((@($splitProbe.splits.Keys) -join ',') + ' => ' + (@($splitProbe.splits['Salt and Pepper']) -join '|'))
  T 'CLEAN TWIN a one-food term and a fixed compound both come back UNSPLIT, so the batch is not rewritten for nothing' `
    ((-not $splitProbe.splits.ContainsKey('Yellow Onion')) -and
     (-not $splitProbe.splits.ContainsKey('Sweet and Sour Sauce'))) `
    (@($splitProbe.splits.Keys) -join ',')

  $exSplit = [pscustomobject]@{ slug='fx'; title='Fixture'; servings=4; ingredients=@(
      [pscustomobject]@{ raw='Pinch salt and pepper ($0.05)'; item='Salt and Pepper'; optional=$false },
      [pscustomobject]@{ raw='1 medium yellow onion'; item='Yellow Onion'; optional=$false }) }
  $spRes = Split-ExtractionComposites $exSplit @{ 'Salt and Pepper' = @('Salt','Pepper') }
  $spIngs = @($exSplit.ingredients)
  T 'MUST FIRE  one composite line becomes TWO ingredient lines and the untouched line is left alone' `
    ($spRes.changed -eq 1 -and $spIngs.Count -eq 3 -and
     (@($spIngs | ForEach-Object { [string]$_.item }) -join '|') -eq 'Salt|Pepper|Yellow Onion') `
    ((@($spIngs | ForEach-Object { [string]$_.item }) -join '|') + " changed=" + $spRes.changed)
  # THE RAW LINE IS THE JOIN KEY - the grams snapshot, the mapper's `lines` and its `rulings` are all
  # keyed by it. Two parts sharing one raw would pull the SAME ruling and the SAME gram figure, which
  # is the whole line's weight counted twice and one part ruled as the other.
  T 'MUST FIRE  the split parts get DISTINCT raw lines - a shared join key would put one line''s grams into the batch twice' `
    ((@($spIngs | ForEach-Object { [string]$_.raw }) | Select-Object -Unique).Count -eq 3) `
    ((@($spIngs | ForEach-Object { [string]$_.raw }) -join ' || '))
  T 'MUST FIRE  ...and each part still names the line it came from, so nobody reading the table has to guess' `
    ((@($spIngs | Where-Object { [string]$_.item_split_from -eq 'Salt and Pepper' }).Count -eq 2) -and
     ([string]$spIngs[0].raw_split_from -eq 'Pinch salt and pepper ($0.05)')) `
    ([string]$spIngs[0].raw_split_from)
  # AND THE TABLE CARRIES IT. New-PreResolveTable builds what the mapper is actually shown.
  $tblSplit = New-PreResolveTable 'fx' $exSplit $vocab @{} @{} @{} $dens $each $foodDb
  $rowSalt = @($tblSplit.rows | Where-Object { [string]$_.term -eq 'Salt' })[0]
  T 'MUST FIRE  the built table carries one row per PART, each stamped with the composite it came from' `
    (@($tblSplit.rows).Count -eq 3 -and [string]$rowSalt.item_split_from -eq 'Salt and Pepper') `
    ((@($tblSplit.rows | ForEach-Object { [string]$_.term }) -join '|') + ' split_from=' + [string]$rowSalt.item_split_from)

  # ---- FIXTURE: THE COUNT GUESS ON A LINE THAT STATES ITS OWN WEIGHT (2026-08-27). ---------------
  # honey-balsamic-chicken-tenders stuck three times in one run on "2 medium 1.5 lbs. chicken
  # breasts": the engine read the count and the each-noun, made 2 x 200 g = 400 g, set NO fallback
  # flag, and the cross-check then fired at full force against the mapper's correct 680 g. Same 1.7x
  # every time - deterministic, and the recipe could not clear it by being re-asked.
  # ITS PYTHON TWIN IS coverage_check.stated_mass_grams, used by band_precheck at ingest. Same units,
  # same conservative refusals, first mass token only. Change one, change both: the same ambiguity
  # defeated BOTH lanes on 2026-08-27 - the qty engine vetoed a correct 680 g here, and the ingest
  # pre-check missed the same protein entirely and computed 152 cal against a true 349.
  T 'MUST FIRE  a line stating pounds is read as that weight, so a count/each guess beside it can be demoted' `
    ([Math]::Abs((Get-StatedMassGrams '2 medium 1.5 lbs. chicken breasts') - 680.388) -lt 0.01) `
    ([string](Get-StatedMassGrams '2 medium 1.5 lbs. chicken breasts'))
  T '  ounces, grams and kilograms too, since the sources use all of them' `
    (([Math]::Abs((Get-StatedMassGrams '14.5 oz black olives (drained)') - 411.07) -lt 0.1) -and
     ([Math]::Abs((Get-StatedMassGrams '600 g chicken tenderloin') - 600) -lt 0.01) -and
     ([Math]::Abs((Get-StatedMassGrams '1.8 kg whole chicken') - 1800) -lt 0.01)) `
    ("oz=" + (Get-StatedMassGrams '14.5 oz black olives (drained)') + " g=" + (Get-StatedMassGrams '600 g chicken tenderloin'))
  T '  and a fraction, which is how half these sources print a weight' `
    ([Math]::Abs((Get-StatedMassGrams '1/2 lb ground beef') - 226.796) -lt 0.01) `
    ([string](Get-StatedMassGrams '1/2 lb ground beef'))
  # CLEAN TWINS. This function can only ever DEMOTE a number, so anything it reads wrongly would take
  # a working line's cross-check away. It stays silent on everything it cannot read confidently.
  T 'CLEAN TWIN a line with no mass at all states nothing - the cross-check keeps its full force there' `
    ($null -eq (Get-StatedMassGrams '2 medium yellow onions, diced')) `
    ([string](Get-StatedMassGrams '2 medium yellow onions, diced'))
  T 'CLEAN TWIN a VOLUME is not a mass - floz and cups must not be read as weight' `
    (($null -eq (Get-StatedMassGrams '1 cup buttermilk')) -and
     ($null -eq (Get-StatedMassGrams '3 tablespoons honey'))) `
    ("cup=" + [string](Get-StatedMassGrams '1 cup buttermilk') + " tbsp=" + [string](Get-StatedMassGrams '3 tablespoons honey'))
  T 'CLEAN TWIN a zero or a bare unit reads as nothing rather than as 0 g' `
    (($null -eq (Get-StatedMassGrams '0 lb nothing')) -and ($null -eq (Get-StatedMassGrams 'lb of something'))) `
    ("zero=" + [string](Get-StatedMassGrams '0 lb nothing'))
  # ---- AND THE DECISION ITSELF, not just the parser under it. The first cut of this fix fixtured
  # only Get-StatedMassGrams, and a neuter that reverted the CALL SITE left every case green.
  T 'MUST FIRE  the real stuck line demotes: 400 g from a count against a line stating 1.5 lbs' `
    ((Test-EngineIgnoredStatedMass '2 medium 1.5 lbs. chicken breasts' 400) -match 'did not read the stated weight') `
    ([string](Test-EngineIgnoredStatedMass '2 medium 1.5 lbs. chicken breasts' 400))
  T 'CLEAN TWIN an engine that AGREES with the stated weight is NOT demoted - the cross-check keeps its force' `
    ($null -eq (Test-EngineIgnoredStatedMass '2 medium 1.5 lbs. chicken breasts' 680)) `
    ([string](Test-EngineIgnoredStatedMass '2 medium 1.5 lbs. chicken breasts' 680))
  T 'CLEAN TWIN quantization is not a basis error - a few percent off the stated weight still stands' `
    ($null -eq (Test-EngineIgnoredStatedMass '1 lb ground beef' 465)) `
    ([string](Test-EngineIgnoredStatedMass '1 lb ground beef' 465))
  T 'CLEAN TWIN a line stating NO mass is never demoted, whatever the engine said' `
    ($null -eq (Test-EngineIgnoredStatedMass '2 medium yellow onions, diced' 400)) `
    ([string](Test-EngineIgnoredStatedMass '2 medium yellow onions, diced' 400))
  T 'CLEAN TWIN no engine number means nothing to demote' `
    ($null -eq (Test-EngineIgnoredStatedMass '2 medium 1.5 lbs. chicken breasts' $null)) `
    'demoted a null'
  # ---- AND THE ONE FUNCTION THE CROSS-CHECK ACTUALLY CALLS, carrying BOTH roads. Neutering this is
  # what neutering the wiring used to be, except now it cannot be done without taking parse-compute's
  # own fallback road down with it - which is the point of folding them together.
  $rowStated = [pscustomobject]@{ grams_source_basis = 400 }
  $rowAgrees = [pscustomobject]@{ grams_source_basis = 680 }
  $rowFlagged = [pscustomobject]@{ grams_source_basis = 48; grams_basis_fallback = 'default tbsp' }
  T 'MUST FIRE  the cross-check''s own question demotes a count guess against a stated weight' `
    ((Get-EngineWeightGuessReason $rowStated '2 medium 1.5 lbs. chicken breasts') -match 'did not read the stated weight') `
    ([string](Get-EngineWeightGuessReason $rowStated '2 medium 1.5 lbs. chicken breasts'))
  T 'MUST FIRE  ...and still carries parse-compute''s OWN fallback road (B2, 2026-08-24)' `
    ((Get-EngineWeightGuessReason $rowFlagged '3 tablespoons chopped fresh parsley') -eq 'default tbsp') `
    ([string](Get-EngineWeightGuessReason $rowFlagged '3 tablespoons chopped fresh parsley'))
  T 'CLEAN TWIN a grounded engine number that agrees with the line is not a guess by either road' `
    ($null -eq (Get-EngineWeightGuessReason $rowAgrees '2 medium 1.5 lbs. chicken breasts')) `
    ([string](Get-EngineWeightGuessReason $rowAgrees '2 medium 1.5 lbs. chicken breasts'))

  if ($bad -gt 0) { Write-Output ("map-preresolve SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'map-preresolve SELF-TEST PASS'
  Write-GuardComplete -Name 'map-preresolve' -Summary 'selftest pass'
  exit 0
}

# ---------------------------------------------------------------------------------------------------
# -NewBids (A4, added 2026-08-24 from the phase-6a gate drill).
#
# WHICH BIDS IN A RULINGS PAYLOAD HAS db\ingredients.json NEVER HEARD OF? That is the question the
# registrar exists to answer, and the daemon needs it BEFORE it dispatches - but the daemon must not
# read the vocabulary itself, because the assembler already reads it for the same question and two
# readers of one file is how two answers appear.
#
# MEASURED ON THE GATE DRILL: the live mapper ruled `dry brown lentils` onto the id `brown-lentils`,
# which the vocabulary does not wire, and returned `new_commodity_proposals: []`. The assembler
# correctly refused the file. But depending on a model to DECLARE that it minted an id is depending on
# bookkeeping to enforce a gate, and this estate's rule is the opposite: read the authority. So the
# proposal list is DERIVED here and unioned with whatever the mapper declared. The gate does not
# weaken - a new id still needs an approve or an alias - it just stops being skippable by omission.
if ($runNewBids) {
  if (-not $RulingsFile) { Write-Output 'map-preresolve -NewBids: -RulingsFile is required'; exit 2 }
  if (-not (Test-Path $RulingsFile)) { Write-Output ("map-preresolve -NewBids: no payload at {0}" -f $RulingsFile); exit 2 }
  $pay = $null
  try { $pay = Read-Json $RulingsFile } catch { Write-Output ("map-preresolve -NewBids: {0} will not parse: {1}" -f $RulingsFile, $_.Exception.Message); exit 2 }
  if (-not $pay) { Write-Output ("map-preresolve -NewBids: {0} is empty" -f $RulingsFile); exit 2 }
  $wired = @{}
  try { $wired = Get-CommodityIds $repo }
  catch { Write-Output ("map-preresolve -NewBids: BLOCKED - the commodity namespaces would not load: {0}" -f $_.Exception.Message); exit 2 }
  if (@($wired.Keys).Count -lt 300) {
    # The same plausibility floor the assembler applies, for the same reason: a load-bearing file read
    # at a few percent of its scale is a parse error, and here it would report EVERY id as new.
    Write-Output ("map-preresolve -NewBids: BLOCKED - read only {0} commodity id(s) across the three namespaces, which is implausibly small." -f @($wired.Keys).Count)
    exit 2
  }

  $declared = @{}
  foreach ($d in (As-Array $pay.new_commodity_proposals)) {
    $db = [string]$d.proposed_bid
    if ($db) { $declared[$db] = [string]$d.evidence }
  }
  $out = New-Object System.Collections.Generic.List[object]
  $seenBid = @{}
  foreach ($r in (As-Array $pay.rulings)) {
    $b = [string]$r.bid
    if (-not $b -or $wired.ContainsKey($b) -or $seenBid.ContainsKey($b)) { continue }
    $seenBid[$b] = $true
    $ev = ''
    if ($declared.ContainsKey($b)) { $ev = $declared[$b] }
    if (-not $ev) { $ev = [string]$r.evidence }
    $out.Add([pscustomobject]@{ term = [string]$r.term; proposed_bid = $b; evidence = $ev
                                declared = $declared.ContainsKey($b) }) | Out-Null
  }
  # ...and a declared proposal for a bid no ruling used is still a proposal worth ruling on.
  foreach ($db in @($declared.Keys)) {
    if ($wired.ContainsKey($db) -or $seenBid.ContainsKey($db)) { continue }
    $seenBid[$db] = $true
    $out.Add([pscustomobject]@{ term = ''; proposed_bid = $db; evidence = $declared[$db]; declared = $true }) | Out-Null
  }
  ([pscustomobject]@{ slug = [string]$pay.slug; count = $out.Count; proposals = $out.ToArray() } | ConvertTo-Json -Depth 6)
  exit 0
}

# ---------------------------------------------------------------------------------------------------
# THE -Assemble LIVE PATH (A1 / pins P2-P6). One slug, one writer, no mutex - see the header.
# ---------------------------------------------------------------------------------------------------
if ($runAssemble) {
  if (-not $RunDir) { Write-Output 'map-preresolve -Assemble: -RunDir is required'; exit 2 }
  if (-not $Slug)   { Write-Output 'map-preresolve -Assemble: -Slug is required (one slug, one file, one writer)'; exit 2 }
  if ($Slug -match ',') {
    Write-Output ("map-preresolve -Assemble: -Slug '{0}' contains a comma - that is ONE composite string. Assemble one slug per call." -f $Slug); exit 2
  }
  if (-not $RulingsFile) { Write-Output 'map-preresolve -Assemble: -RulingsFile is required'; exit 2 }
  $tablePath = Join-Path $RunDir ("mapped-pre\{0}.json" -f $Slug)
  if (-not (Test-Path $tablePath)) { Write-Output ("map-preresolve -Assemble: BLOCKED - no pre-resolve table at {0}" -f $tablePath); exit 2 }
  if (-not (Test-Path $RulingsFile)) { Write-Output ("map-preresolve -Assemble: BLOCKED - no rulings payload at {0}" -f $RulingsFile); exit 2 }
  $table = $null; $payload = $null
  try { $table = Read-Json $tablePath } catch { Write-Output ("map-preresolve -Assemble: BLOCKED - {0} will not parse: {1}" -f $tablePath, $_.Exception.Message); exit 2 }
  try { $payload = Read-Json $RulingsFile } catch { Write-Output ("map-preresolve -Assemble: BLOCKED - {0} will not parse: {1}" -f $RulingsFile, $_.Exception.Message); exit 2 }
  if (-not $table -or -not $table.rows) { Write-Output ("map-preresolve -Assemble: BLOCKED - {0} carries no rows" -f $tablePath); exit 2 }
  if (-not $payload) { Write-Output ("map-preresolve -Assemble: BLOCKED - {0} is empty" -f $RulingsFile); exit 2 }

  # THE THREE COMMODITY NAMESPACES ARE READ FOR ONE QUESTION: which ids already price a food. That is
  # what tells a reused id from a NEW one, and a new one needs the registrar (pin P6). NOT the recipe
  # vocabulary - see Get-CommodityIds' correction note; asking the wrong file refused a live board id
  # on the gate drill. The plausibility floor is the same rule the pre-resolve path applies: a
  # load-bearing file read at a few percent of its scale is a parse error, not data, and here it would
  # report every id as new and stop every recipe.
  $known = @{}
  try { $known = Get-CommodityIds $repo }
  catch { Write-Output ("map-preresolve -Assemble: BLOCKED - the commodity namespaces would not load: {0}" -f $_.Exception.Message); exit 2 }
  if (@($known.Keys).Count -lt 300) {
    Write-Output ("map-preresolve -Assemble: BLOCKED - read only {0} commodity id(s) across the three namespaces, which is implausibly small. Every ruled id would read as NEW and every recipe would stop." -f @($known.Keys).Count)
    exit 2
  }

  $stateRow = $null
  $statePath = Join-Path $RunDir ("state\{0}.json" -f $Slug)
  if (Test-Path $statePath) { try { $stateRow = Read-Json $statePath } catch { $stateRow = $null } }

  $res = New-MappedDecisionFile $table $payload $stateRow $known $TargetServings

  # B2 (2026-08-24): APPEND THE DENSITY GAPS, WHATEVER ELSE HAPPENS. Written BEFORE the findings check
  # because a recipe that parks is exactly the one whose gaps are worth knowing about, and this file is
  # evidence for later rather than a gate. Append-only JSONL: it is the densities.json worklist, built
  # from what recipes ACTUALLY use and rankable by how often each food turns up.
  foreach ($gap in @($res.density_gaps)) {
    try {
      $line = ([pscustomobject]@{
        at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss'); run = (Split-Path $RunDir -Leaf)
        slug = $gap.slug; item = $gap.item; raw = $gap.raw
        engine_basis = $gap.engine_basis; engine_grams_source = $gap.engine_grams_source
        ruling_grams_target = $gap.ruling_grams_target } | ConvertTo-Json -Compress -Depth 4)
      Add-Content -Path (Join-Path $RunDir 'density-gaps.jsonl') -Value $line -Encoding utf8
    } catch {
      # A worklist may never break an assembly. It is evidence, not a gate.
    }
  }

  if (@($res.findings).Count) {
    # NOTHING IS WRITTEN. Half a decision file on disk is worse than none: the half that landed looks
    # settled, and D8 builds an intake over it.
    Write-Output ("map-preresolve -Assemble: {0} finding(s) - NOTHING was written to mapped\{1}.json" -f @($res.findings).Count, $Slug)
    foreach ($f in @($res.findings)) { Write-Output ("    FINDING  " + $f) }
    Write-GuardComplete -Name 'map-preresolve' -Summary ("assemble {0}: {1} finding(s)" -f $Slug, @($res.findings).Count)
    exit 1
  }
  $outMapped = Join-Path $RunDir 'mapped'
  if (-not (Test-Path $outMapped)) { New-Item -ItemType Directory -Path $outMapped -Force | Out-Null }
  $target = Join-Path $outMapped ("{0}.json" -f $Slug)
  ($res.doc | ConvertTo-Json -Depth 9) | Set-Content -Path $target -Encoding utf8
  $n = @($res.doc.ingredients).Count
  $opt = @(@($res.doc.ingredients) | Where-Object { $_.decision -eq 'mapped-optional' }).Count
  $notp = @(@($res.doc.ingredients) | Where-Object { $_.decision -eq 'optional-note' }).Count
  Write-Output ("map-preresolve -Assemble: {0} -> {1} line(s) ({2} optional, {3} not purchased), {4} servings x{5} = {6}" -f `
    $Slug, $n, $opt, $notp, $res.doc.source_servings, $res.doc.scale_factor, $res.doc.target_servings)
  Write-Output ("    wrote {0}" -f $target)
  Write-GuardComplete -Name 'map-preresolve' -Summary ("assembled {0}: {1} line(s)" -f $Slug, $n)
  exit 0
}

# ---------------------------------------------------------------------------------------------------
# THE LIVE PATH
# ---------------------------------------------------------------------------------------------------
if (-not $RunDir)  { Write-Output 'map-preresolve: -RunDir is required'; exit 2 }
if (-not (Test-Path $RunDir)) { Write-Output ("map-preresolve: no such run dir: {0}" -f $RunDir); exit 2 }
$slugList = @($Slugs | ForEach-Object { [string]$_ } | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
if (-not $slugList.Count) { Write-Output 'map-preresolve: -Slugs is required (a real array, one element per slug)'; exit 2 }
# A comma INSIDE an element is the -Terms 'a,b' family arriving one level down. Refuse it here rather
# than writing a table for a slug that does not exist.
foreach ($s in $slugList) {
  if ($s -match ',') {
    Write-Output ("map-preresolve: -Slugs element '{0}' contains a comma - that is ONE composite string, not two slugs. Pass a real array (hunt_lib.ps_invoke does)." -f $s)
    exit 2
  }
}

# 1. READ EVERY EXTRACTION FIRST. All of them, before anything is written: a batch that cannot be read
#    whole is BLOCKED, and half a batch on disk is worse than none because the half that landed looks
#    pre-resolved.
$extractions = @{}
foreach ($slug in $slugList) {
  $p = Join-Path $RunDir ("extracted\{0}.json" -f $slug)
  if (-not (Test-Path $p)) { Write-Output ("map-preresolve: BLOCKED - no extraction at {0}" -f $p); exit 2 }
  $doc = $null
  try { $doc = Read-Json $p } catch { Write-Output ("map-preresolve: BLOCKED - {0} will not parse: {1}" -f $p, $_.Exception.Message); exit 2 }
  if (-not $doc -or -not $doc.ingredients) {
    Write-Output ("map-preresolve: BLOCKED - {0} has no ingredients" -f $p); exit 2
  }
  $extractions[$slug] = $doc
}

# 2. READ THE LOOKUPS ONCE FOR THE WHOLE BATCH.
$vocab = $null; $cache = $null; $dens = @{}; $each = @{}; $foodDb = @{}
try {
  $vocabParsed = Read-Json $VocabFile
  $vocab = As-Array $vocabParsed
  if (@($vocab).Count -lt 200) {
    # ingredient-vocab's own plausibility floor, honoured here for the same reason it exists there: a
    # tool that reads a load-bearing file at a few percent of its known scale is BROKEN, not testifying.
    Write-Output ("map-preresolve: BLOCKED - read only {0} vocabulary rows from {1}, which is implausibly small. This is a parse error, not data." -f @($vocab).Count, $VocabFile)
    exit 2
  }
  $cache = Get-ResolutionCache $ResolutionsFile
  $dRoot = Read-Json $DensitiesFile
  if ($dRoot -and $dRoot.items) { foreach ($p in $dRoot.items.PSObject.Properties) { $dens[$p.Name] = $p.Value } }
  $eRoot = Read-Json $EachNounsFile
  if ($eRoot -and $eRoot.items) { foreach ($p in $eRoot.items.PSObject.Properties) { $each[$p.Name] = $p.Value } }
  $fRoot = Read-Json $FoodDbFile
  foreach ($i in (As-Array $fRoot.items)) { if ($i.item) { $foodDb[[string]$i.item] = $i } }
} catch {
  Write-Output ("map-preresolve: BLOCKED - a lookup would not load: {0}" -f $_.Exception.Message); exit 2
}

# 3a. SPLIT THE COMPOSITE TERMS FIRST, BEFORE ANY LOOKUP IS COMPOSED OVER THEM. A line naming two
# foods has to become two lines HERE or it becomes one unanswerable question everywhere after:
# ingredient-vocab is asked to classify a food that does not exist, the board is asked to price it,
# and the food DB is asked for a row it can never carry. Run hunt-2026-08-26-ten lost twelve recipes
# to the last of those and four more to the second.
$preTerms = New-Object System.Collections.Generic.List[string]
foreach ($slug in $slugList) {
  foreach ($ing in (As-Array $extractions[$slug].ingredients)) {
    $t = [string]$ing.item; if (-not $t) { $t = [string]$ing.raw }
    if ($t -and -not $preTerms.Contains($t)) { $preTerms.Add($t) | Out-Null }
  }
}
# A term the estate ALREADY resolves as a whole is a food it carries, however its name reads, so the
# splitter is never asked about it. This is what keeps "Half and Half" one food.
$knownNames = New-Object System.Collections.Generic.List[string]
$resolvedWhole = New-Object System.Collections.Generic.List[string]
foreach ($v in (As-Array $vocab)) {
  if ($v.item) { $knownNames.Add([string]$v.item) | Out-Null }
  if ($v.PSObject.Properties.Name -contains 'aliases') {
    foreach ($al in (As-Array $v.aliases)) { if ($al) { $knownNames.Add([string]$al) | Out-Null } }
  }
}
foreach ($k in $foodDb.Keys) { $knownNames.Add([string]$k) | Out-Null }
foreach ($n in $knownNames) { $resolvedWhole.Add($n) | Out-Null }
$splitRes = Get-CompositeSplits $preTerms.ToArray() $resolvedWhole.ToArray() $knownNames.ToArray()
if ($splitRes.why) {
  # NOT A GATE: every term stays whole and the batch says so, which is the behaviour that shipped
  # before this step existed. Silence here would be a term-formation rule nobody can tell ran.
  Write-Output ("map-preresolve: WARNING - composite terms were NOT split ({0}); a line naming two foods will reach the mapper whole." -f $splitRes.why)
}
$splitNotes = New-Object System.Collections.Generic.List[string]
if ($splitRes.splits.Count -gt 0) {
  foreach ($slug in $slugList) {
    $r = Split-ExtractionComposites $extractions[$slug] $splitRes.splits
    foreach ($n in @($r.notes)) { $splitNotes.Add(("{0}: {1}" -f $slug, $n)) | Out-Null }
    if ($r.changed -gt 0) { Write-Output ("map-preresolve: {0} - split {1} composite ingredient line(s)" -f $slug, $r.changed) }
  }
}

# 3. ONE VOCAB CALL AND ONE BOARD CALL FOR THE WHOLE BATCH.
$terms = New-Object System.Collections.Generic.List[string]
foreach ($slug in $slugList) {
  foreach ($ing in (As-Array $extractions[$slug].ingredients)) {
    $t = [string]$ing.item; if (-not $t) { $t = [string]$ing.raw }
    if ($t -and -not $terms.Contains($t)) { $terms.Add($t) | Out-Null }
  }
}
$termArr = $terms.ToArray()
$classes = @{}
try { $classes = Get-VocabClassification $termArr $VocabFile }
catch { Write-Output ("map-preresolve: BLOCKED - {0}" -f $_.Exception.Message); exit 2 }

# The board lookup uses the CANON name where one is known and the recipe's own words where one is not,
# which is the pair of questions actually worth asking: what does the board carry for what we mapped
# it to, and what does the board make of what the page says.
$boardTerms = New-Object System.Collections.Generic.List[string]
foreach ($t in $termArr) {
  $lookup = $t
  $c = $null; if ($classes.ContainsKey($t)) { $c = $classes[$t] }
  if ($c -and [string]$c.class -eq 'RESOLVES' -and $c.resolves_to) { $lookup = [string]$c.resolves_to }
  if (-not $boardTerms.Contains($lookup)) { $boardTerms.Add($lookup) | Out-Null }
}
$board = @{}
if (-not $runNoBoard) {
  try { $board = Get-BoardAnswers $boardTerms.ToArray() }
  catch {
    # THE BOARD IS EVIDENCE, NOT A GATE. A board that will not load is a finding on every row, never a
    # silent pass and never a fabricated carriage answer - but it is also not a reason to block a batch
    # whose identity questions are all answerable without it.
    Write-Output ("map-preresolve: WARNING - the board would not answer ({0}); every row records that nobody looked." -f $_.Exception.Message)
    $board = @{}
  }
}

# 4. BUILD AND WRITE, one file per slug.
$outDir = Join-Path $RunDir 'mapped-pre'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$tables = New-Object System.Collections.Generic.List[object]
foreach ($slug in $slugList) {
  $tables.Add((New-PreResolveTable $slug $extractions[$slug] $vocab $classes $board $cache $dens $each $foodDb)) | Out-Null
}
$tblArr = $tables.ToArray()

# 5. THE MACRO CROSS-CHECK, over the lines this pass pre-resolved. It runs AFTER the tables exist
#    because it is computed over their canon names, and it gates NOTHING: the band gate belongs to
#    D8's skeleton, pre-write. This is an input to the mapper's judgment and it travels in the prompt.
$pool = @{}
if (-not $runNoPrecheck) {
  try {
    # candidate-pool.json is {_doc, updated, count, candidates}, NOT a bare array. Reading the wrapper
    # as the array is how a lookup silently answers "nobody published macros for this dish" about a
    # dish whose macros are sitting right there - measured on this script's first live run, 4 for 4.
    $poolDoc = Read-Json $PoolFile
    $cands = if ($poolDoc -and ($poolDoc.PSObject.Properties.Name -contains 'candidates')) { As-Array $poolDoc.candidates } else { As-Array $poolDoc }
    foreach ($c in $cands) { if ($c.slug -and ($slugList -contains [string]$c.slug)) { $pool[[string]$c.slug] = $c } }
  } catch { $pool = @{} }
}
$precheck = @{}
$lineGrams = @{}
$lineBasis = @{}
if ($runNoPrecheck) {
  foreach ($slug in $slugList) {
    $precheck[$slug] = [pscustomobject]@{ state='skipped'; reason='-NoPrecheck'; source=$null
                                          lines_covered=0; lines_total=0; computed_per_serving=$null
                                          portion_factor=$null; tuning=@(); missing_db_items=@() }
    $lineGrams[$slug] = @{}
    $lineBasis[$slug] = @{}
  }
} else {
  $mp = Get-MacroPrecheck $tblArr $extractions $pool
  $precheck = $mp.precheck
  $lineGrams = $mp.grams
  $lineBasis = $mp.basis
}
foreach ($t in $tblArr) {
  $t | Add-Member -NotePropertyName 'macro_precheck' -NotePropertyValue $precheck[[string]$t.slug] -Force
  # STAMP THE PER-LINE SOURCE-BASIS GRAMS (A-package / pin P3). The engine reaches exactly the lines
  # this pass pre-resolved - a residual line has no canon name to weigh - so the residual lines stay
  # null and their grams come from the mapper's ruling, or the assembly is STUCK and says which line.
  $g = @{}
  if ($lineGrams.ContainsKey([string]$t.slug)) { $g = $lineGrams[[string]$t.slug] }
  $bs = @{}
  if ($lineBasis.ContainsKey([string]$t.slug)) { $bs = $lineBasis[[string]$t.slug] }
  foreach ($row in (As-Array $t.rows)) {
    if ($g.ContainsKey([string]$row.raw)) { $row.grams_source_basis = [double]$g[[string]$row.raw] }
    # B2: and WHETHER the engine could ground it. Null means grounded; a string names the fallback.
    if ($bs.ContainsKey([string]$row.raw)) {
      $row | Add-Member -NotePropertyName 'grams_basis_fallback' -NotePropertyValue ([string]$bs[[string]$row.raw]) -Force
    }
  }
  ($t | ConvertTo-Json -Depth 9) | Set-Content -Path (Join-Path $outDir ("{0}.json" -f $t.slug)) -Encoding utf8
}

$totLines = 0; $totRes = 0; $totHold = 0; $totResolved = 0
foreach ($t in $tblArr) { $totLines += $t.line_count; $totRes += $t.residual_count; $totHold += $t.hold_count; $totResolved += $t.resolved_count }
foreach ($t in $tblArr) {
  Write-Output ("map-preresolve: {0,-42} {1} line(s), {2} pre-resolved, {3} residual, {4} hold(s)" -f $t.slug, $t.line_count, $t.resolved_count, $t.residual_count, $t.hold_count)
  foreach ($h in (As-Array $t.holds)) { Write-Output ("    HOLD  " + $h.why) }
  $mp2 = $t.macro_precheck
  if ($mp2 -and $mp2.state -eq 'computed') {
    Write-Output ("    macro cross-check over {0} of {1} line(s): computed {2} cal / {3} carbs / {4} protein  vs source {5} cal / {6} carbs / {7} protein ({8})" -f `
      $mp2.lines_covered, $mp2.lines_total, $mp2.computed_per_serving.cal, $mp2.computed_per_serving.carbs,
      $mp2.computed_per_serving.protein_g, $mp2.source.cal, $mp2.source.carbs, $mp2.source.protein_g, $mp2.source.from)
  } elseif ($mp2 -and $mp2.state -eq 'partial') {
    Write-Output ("    macro cross-check NOT PRE-COMPUTED ({0}) - the mapper does it over the lines it rules" -f $mp2.reason)
  } elseif ($mp2 -and $mp2.state -eq 'unavailable') {
    Write-Output ("    macro cross-check UNAVAILABLE: " + $mp2.reason)
  }
}
$rate = if ($totLines -gt 0) { [Math]::Round(100.0 * $totResolved / $totLines, 1) } else { 0 }
Write-Output ("map-preresolve: {0} slug(s), {1} line(s), {2} pre-resolved ({3}%), {4} residual, {5} hold(s)" -f $tblArr.Count, $totLines, $totResolved, $rate, $totRes, $totHold)
if ($runJson) { ([pscustomobject]@{ slugs=$slugList; lines=$totLines; resolved=$totResolved; residual=$totRes; holds=$totHold; tables=$tblArr } | ConvertTo-Json -Depth 9) }

Write-GuardComplete -Name 'map-preresolve' -Summary ("{0} slug(s), {1} residual line(s), {2} hold(s)" -f $tblArr.Count, $totRes, $totHold)
if ($totRes -gt 0) { exit 1 }
exit 0
