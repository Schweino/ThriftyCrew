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
#   .\map-preresolve.ps1 -SelfTest
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

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here                      # ...\meal-prep
$repo = Split-Path -Parent $mp                        # ...\ThriftyCrew
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
    if (-not $foodDbKnown) { $evidence.Add("no food-macros-db row - a label needs transcribing") }

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
  $rows = New-Object System.Collections.Generic.List[object]
  $covered = @{}
  foreach ($t in @($Tables)) {
    $slug = [string]$t.slug
    $src = $Extractions[$slug]
    $ings = New-Object System.Collections.Generic.List[object]
    foreach ($r in (As-Array $t.rows)) {
      if (-not $r.canon_item) { continue }
      $line = @((As-Array $src.ingredients) | Where-Object { [string]$_.raw -eq [string]$r.raw })[0]
      $qty = ''
      if ($line) { $qty = ((@([string]$line.qty, [string]$line.unit) | Where-Object { $_ }) -join ' ').Trim() }
      $ings.Add([pscustomobject]@{ canon = [string]$r.canon_item; is_new = $false
                                   sources = @([pscustomobject]@{ item = [string]$r.term; qty = $qty }) }) | Out-Null
    }
    $covered[$slug] = $ings.Count
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
  if (-not $rowArr.Count) { return $out }

  $scratch = Join-Path $env:TEMP ('mpre-pc-' + [guid]::NewGuid().ToString('N'))
  try {
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null
    ($rowArr | ConvertTo-Json -Depth 8) | Set-Content -Path (Join-Path $scratch 'recipes-canon.json') -Encoding utf8
    $r = Invoke-Child $script:PARSE_COMPUTE_PS @('-RunDir', $scratch)
    if ($r.rc -ne 0) {
      foreach ($k in @($out.Keys)) { $out[$k].reason = ("parse-compute exited {0}: {1}" -f $r.rc, $r.text.Trim()) }
      return $out
    }
    $parsed = Read-Json (Join-Path $scratch 'recipes-computed.json')
    # ASSIGN FIRST, THEN WRAP. A ONE-recipe batch comes back as a bare object and a many-recipe batch as
    # an array, and the entire value of that rule is that the two read the same to the code below.
    $computed = As-Array $parsed
    foreach ($c in $computed) {
      $cs = [string]$c.slug
      if (-not $out.ContainsKey($cs)) { continue }
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
    return $out
  } catch {
    foreach ($k in @($out.Keys)) { $out[$k].reason = ("the cross-check would not run: " + $_.Exception.Message) }
    return $out
  } finally { Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue }
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

  if ($bad -gt 0) { Write-Output ("map-preresolve SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'map-preresolve SELF-TEST PASS'
  Write-GuardComplete -Name 'map-preresolve' -Summary 'selftest pass'
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
if ($runNoPrecheck) {
  foreach ($slug in $slugList) {
    $precheck[$slug] = [pscustomobject]@{ state='skipped'; reason='-NoPrecheck'; source=$null
                                          lines_covered=0; lines_total=0; computed_per_serving=$null
                                          portion_factor=$null; tuning=@(); missing_db_items=@() }
  }
} else {
  $precheck = Get-MacroPrecheck $tblArr $extractions $pool
}
foreach ($t in $tblArr) {
  $t | Add-Member -NotePropertyName 'macro_precheck' -NotePropertyValue $precheck[[string]$t.slug] -Force
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
