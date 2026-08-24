# build-intake-skeleton.ps1 - THE MACHINE HALF OF THE INTAKE (PLAN-recipe-hunter-v3 S6 / D8, 2026-08-24).
# ---------------------------------------------------------------------------------------------------
# Assembles everything in a recipe's intake that is derivable - name, slug, protein, source_url,
# visibility, the full ingredients[] with grams and buy strings, macros_per_serving, and the head times -
# and leaves the writer exactly the fields with no mechanical check behind them: prose.*, cuisine,
# head.description/keywords/steps/step_names, writer_notes, forbidden_prose_terms.
#
# WHY. The writer was 4.8% of a v2 run's tokens and, more to the point, it was the stage that could
# introduce a number. Every gram, every buy string and every macro in this file already exists in the
# mapper's decision file or falls straight out of the food DB; asking a model to copy them across is
# paying for transcription and buying a chance of drift. After this, the writer structurally cannot
# introduce a number, which retires the prose-number defect class instead of catching it at QA.
#
# TWO CONSEQUENCES, BOTH LOAD-BEARING:
#   * THE BAND GATE MOVES BEFORE THE WRITE. macros_per_serving exists here, so an out-of-band recipe
#     retires at `rejected-macros` before any prose is paid for. v2 checked the band on the WRITE
#     result - after the most expensive per-recipe stage had already run. This script does NOT rule the
#     band itself: it produces the numbers and the DAEMON rules with hunt_lib.in_band, which is the one
#     parity-covered predicate and is also what the post-build spec read uses. Two gates, one predicate.
#   * THE SKELETON IS A POSTCONDITION, NOT A SUGGESTION. `-Verify` diffs the writer-completed intake
#     against the snapshot this build took, and any drift in a LOCKED field is exit 1 with the fields
#     named. The writer completes the file IN PLACE; it no longer creates it.
#
# THE LOCKED / WRITER-FILLABLE SPLIT (section 4.5, with `cuisine` CORRECTED 2026-08-24 - see below):
#   LOCKED           name, slug, protein, source_url, visibility, ingredients[] (item/grams/buy),
#                    macros_per_serving, head.prepTime/cookTime/totalTime
#   WRITER-FILLABLE  prose.*, cuisine, head.description/keywords/steps/step_names, writer_notes,
#                    forbidden_prose_terms
#
# `cuisine` IS WRITER-FILLABLE, AND THIS IS A CORRECTION TO SECTION 4.5, MEASURED. The plan lists it
# LOCKED. Nothing on disk before the writer carries a cuisine: not the extraction contract (state,
# reason, title, source_url, servings, times, ingredients, instructions, concerns), not the mapper
# decision file (slug, title, source_url, servings, scale, protein, ingredients), not the run state
# file, and not the pool candidate's signature (protein / method / sauce_family / starch). Locking a
# field with no mechanical source would mean the skeleton either invents one or refuses to build. It is
# a judgment about the dish rather than a number, so it sits with the writer under the existing "the
# writer computes no number" rule, exactly where v2 had it, and build-v2-spec checks its presence as it
# always did.
#
#   .\build-intake-skeleton.ps1 -RunDir <dir> -Slug <slug>
#   .\build-intake-skeleton.ps1 -Verify -InFile <RunDir>\intake\<slug>.json -Skeleton <RunDir>\intake\<slug>.skeleton.json
#   .\build-intake-skeleton.ps1 -SelfTest
#
# EXIT CODES - section 4.5's v3 convention. Note that unlike map-preresolve, exit 1 here is NOT the
# normal case: a skeleton is either complete or it is not.
#   0  BUILD: the skeleton is complete and its macros are trustworthy.  VERIFY: no locked field moved.
#   1  BUILD: the skeleton was written but is INCOMPLETE - named findings (a food-DB row missing, so the
#      macros are partial; a source time string nothing could parse). The band cannot be ruled on a
#      partial macro figure, so the caller treats this as work stopped, not work passed.
#      VERIFY: a locked field DRIFTED. The drifted fields are named, one line each.
#   2  could not run: no mapper decision file, no extraction, unparseable input, or a refusal to
#      overwrite prose that is already on disk. BLOCKED, never a pass.
# The completion marker `BUILD-INTAKE-SKELETON-COMPLETE` is the last line on every path except a crash,
# because "did it finish" and "what did it find" are different questions.
# ---------------------------------------------------------------------------------------------------
param(
  [string]$RunDir = '',
  [string]$Slug = '',
  [switch]$Verify,
  [string]$InFile = '',
  [string]$Skeleton = '',
  [switch]$Force,                   # overwrite an intake that already carries writer prose
  [switch]$SelfTest,
  [switch]$Json,
  [string]$FoodDbFile = '',
  [int]$Servings = 14               # the house batch. The mapper's grams are already at this scale.
)
$ErrorActionPreference = 'Stop'
# Copy every switch into a plain bool BEFORE anything is dot-sourced: a lib declaring its own
# [switch]$SelfTest resets ours in THIS scope, which made migrate-prose-tokens' first -SelfTest run
# execute the live path instead of its fixtures.
$runVerify = [bool]$Verify; $runSelfTest = [bool]$SelfTest; $runJson = [bool]$Json; $runForce = [bool]$Force

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $here 'macro-recompute-lib.ps1')   # Get-MacroRecompute - the ONE per-serving arithmetic

if (-not $FoodDbFile) { $FoodDbFile = Join-Path $mp 'food-macros-db.json' }

function Read-Json {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return $null }
  # NOT Get-Content -Raw: in PS 5.1 that decodes with the ANSI codepage and mangles every non-ASCII
  # byte these files carry.
  $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) -replace '^\uFEFF', ''
  if (-not $text.Trim()) { return $null }
  return ($text | ConvertFrom-Json)
}
function As-Array {
  # ASSIGN FIRST, THEN WRAP, THEN REFUSE TO BE UNROLLED. `@(<pipeline> | ConvertFrom-Json)` binds ONE
  # element of type Object[] on a many-element array, and a function ending `return @($a)` hands back
  # the bare element when the array holds one thing (`.Count` on a bare PSCustomObject is $null in
  # PS 5.1, so `if ($x.Count)` silently reads false). The comma returns the array itself.
  # ITS PRICE: an array returned this way enters a PIPELINE as ONE object. PARENTHESISE the call -
  # `(As-Array $x) | Where-Object` - or assign first. `@(As-Array $x) | ...` does NOT fix it.
  param($Value)
  if ($null -eq $Value) { return ,@() }
  $assigned = $Value
  return ,@($assigned)
}

# ---------------------------------------------------------------------------------------------------
# THE HEAD TIMES. Publishers print free text ("40 minutes", "1 hr 15 mins", "1 hour 5 minutes") and the
# spec's head block wants ISO-8601 durations. Pure and fixtured, because an unparseable time must be a
# NAMED finding rather than a silent zero: a recipe whose card says PT0M is a recipe that looks instant.
# ---------------------------------------------------------------------------------------------------
function ConvertTo-IsoDuration {
  param([string]$Text)
  if (-not $Text) { return '' }
  $t = ([string]$Text).Trim()
  if ($t -match '^(?i)PT(\d+H)?(\d+M)?$') { return $t.ToUpper() }   # already ISO, pass it through
  $low = $t.ToLower() -replace '[\u2013\u2014]', '-'
  $h = 0; $m = 0; $any = $false
  foreach ($mt in [regex]::Matches($low, '(\d+(?:\.\d+)?)\s*(hours|hour|hrs|hr|h)\b')) {
    $h += [double]$mt.Groups[1].Value; $any = $true
  }
  foreach ($mt in [regex]::Matches($low, '(\d+(?:\.\d+)?)\s*(minutes|minute|mins|min|m)\b')) {
    $m += [double]$mt.Groups[1].Value; $any = $true
  }
  if (-not $any) {
    # A BARE NUMBER IS MINUTES, and only a bare number: "35" is a time this estate's publishers print.
    if ($low -match '^\d+$') { $m = [double]$low; $any = $true } else { return '' }
  }
  $total = [int][Math]::Round($h * 60 + $m, 0)
  if ($total -le 0) { return '' }
  $hh = [int][Math]::Floor($total / 60); $mm = $total % 60
  $out = 'PT'
  if ($hh -gt 0) { $out += ("{0}H" -f $hh) }
  if ($mm -gt 0 -or $hh -eq 0) { $out += ("{0}M" -f $mm) }
  return $out
}

function Get-IsoMinutes {
  param([string]$Iso)
  if (-not $Iso) { return 0 }
  $h = 0; $m = 0
  $mt = [regex]::Match([string]$Iso, '^(?i)PT(?:(\d+)H)?(?:(\d+)M)?$')
  if (-not $mt.Success) { return 0 }
  if ($mt.Groups[1].Success) { $h = [int]$mt.Groups[1].Value }
  if ($mt.Groups[2].Success) { $m = [int]$mt.Groups[2].Value }
  return ($h * 60 + $m)
}

function New-HeadTimes {
  <# prepTime = the source's ACTIVE time, cookTime = total minus active, totalTime = the source's total.
     That is the split every published v2 spec carries. When only a total is stated, the total stands
     alone rather than being apportioned by guesswork. #>
  param([string]$TimeTotal, [string]$TimeActive)
  $total  = ConvertTo-IsoDuration $TimeTotal
  $active = ConvertTo-IsoDuration $TimeActive
  $cook = ''
  if ($total -and $active) {
    $diff = (Get-IsoMinutes $total) - (Get-IsoMinutes $active)
    if ($diff -gt 0) {
      $hh = [int][Math]::Floor($diff / 60); $mm = $diff % 60
      $cook = 'PT'
      if ($hh -gt 0) { $cook += ("{0}H" -f $hh) }
      if ($mm -gt 0 -or $hh -eq 0) { $cook += ("{0}M" -f $mm) }
    }
  }
  return [pscustomobject]@{ prepTime = $active; cookTime = $cook; totalTime = $total }
}

# ---------------------------------------------------------------------------------------------------
# WHICH MAPPER LINES ARE INTAKE LINES.
#
# THIS WAS BUILT ON A GUESS AND THE GUESS WAS WRONG, MEASURED 2026-08-24 ON THE PHASE-4 GATE RUN. The
# first build kept a line only when `decision` was the exact string "mapped". `decision` is FREE TEXT
# in the mapper's contract: 21 distinct values across 550 lines in the run dirs on disk. So on
# turkey-parmesan-meatball-bake the builder silently dropped 1588 g of Ground Chicken
# (`unresolved-hold`) and three `mapped-optional` lines, computed 250 cal per serving over what was
# left, and the pre-write band gate retired a real recipe at "250 cal below the 400 floor". A gate
# ruling on a fabricated number is worse than no gate: it fails CLOSED and looks like rigour.
#
# The classes below are derived from what v2's own shipped intakes actually did with each decision
# word, recipe by recipe, not from what the word sounds like:
#   INCLUDED   mapped, mapped-null, mapped-null-pending-registrar, mapped-pending-price,
#              mapped-ruled-addition, mapped-with-conflict, mapped-precedent, ruled-substitution,
#              flagged-no-label-and-no-commodity   (all present in the v2 intakes)
#   OPTIONAL   mapped-optional - v2 kept 6 and dropped 5 of these BY WRITER JUDGMENT, and the writer no
#              longer touches ingredients. The mechanical default is to COUNT them, because a line with
#              a gram weight that the card ignores is a shopper buying food the macros do not describe,
#              and because the direction that drops a line is the one that just fabricated a recipe.
#              Every one is NAMED in the snapshot so QA and the auditor can see the call that was made.
#   NOT-PURCHASED  optional-pantry / optional-null / optional-note / optional-unquantified (v2 dropped
#              14 of 14), sub-recipe, alternative-not-mapped, mapped-free (water). Excluded, and named.
#   UNSETTLED  anything saying `unresolved`. There is no intake to build over a line the mapper did not
#              settle, so this is a FINDING and the recipe stops.
#   UNKNOWN    anything else, on a line carrying an item and grams: INCLUDED and NAMED. A new
#              vocabulary word must surface, not change behaviour silently, and including is the
#              direction that cannot lose a protein.
# ---------------------------------------------------------------------------------------------------
function Get-LineClass {
  param([string]$Decision)
  $d = ([string]$Decision).Trim().ToLower()
  if (-not $d) { return 'included' }                       # no verdict recorded: the mapper's default
  if ($d -match 'unresolved') { return 'unsettled' }
  if ($d -match '^optional-' -or $d -match 'sub-recipe' -or $d -match 'alternative-not-mapped' -or
      $d -eq 'mapped-free') { return 'not-purchased' }
  if ($d -eq 'mapped-optional') { return 'optional' }
  if ($d -match '^mapped' -or $d -eq 'ruled-substitution' -or $d -eq 'flagged-no-label-and-no-commodity') {
    return 'included'
  }
  return 'unknown'
}

# ---------------------------------------------------------------------------------------------------
# THE SKELETON. Pure over the two decision files plus the food DB, so the whole assembly is fixturable
# without a run dir.
# ---------------------------------------------------------------------------------------------------
function New-IntakeSkeleton {
  param($Mapped, $Extraction, $FoodDb, [int]$Servings)
  $findings = New-Object System.Collections.Generic.List[string]
  $notes    = New-Object System.Collections.Generic.List[string]

  $ings = New-Object System.Collections.Generic.List[object]
  foreach ($i in (As-Array $Mapped.ingredients)) {
    $decision = ([string]$i.decision).Trim()
    $item     = [string]$i.item
    $g = 0
    if ($null -ne $i.grams) { $g = [int][Math]::Round([double]$i.grams, 0) }
    $cls = Get-LineClass $decision

    if ($cls -eq 'unsettled') {
      # THE MAPPER DID NOT SETTLE THIS LINE, so there is no intake to build over it. Dropping it
      # silently is what this build did on its first day and it is the defect this whole check exists
      # for - see the header note on turkey-parmesan-meatball-bake.
      $findings.Add(("'{0}' is `"{1}`" in the mapper decision file - the intake cannot be built over an unsettled line" -f $item, $decision)) | Out-Null
      continue
    }
    if ($cls -eq 'not-purchased') {
      $notes.Add(("excluded '{0}' ({1}) - not something the shopper buys" -f $item, $decision)) | Out-Null
      continue
    }
    if (-not $item) {
      $notes.Add(("excluded a line with no item name (decision `"{0}`")" -f $decision)) | Out-Null
      continue
    }
    if ($g -le 0) {
      # A line the mapper INCLUDED but gave no weight is a real gap: build-v2-spec prices and computes
      # macros off grams, so a zero-gram line is an ingredient the reader buys and the card ignores.
      $findings.Add(("'{0}' is included ({1}) but carries no grams" -f $item, $decision)) | Out-Null
      continue
    }
    if ($cls -eq 'unknown') {
      # A NEW VOCABULARY WORD SURFACES, IT DOES NOT CHANGE BEHAVIOUR SILENTLY. `decision` is free text
      # in the mapper's contract (21 distinct values measured across 550 lines), so an unrecognised one
      # is INCLUDED - the mapper gave it both an item and a weight, and the direction that loses a
      # protein is the one that already cost this build a fabricated 250-cal recipe - and NAMED here.
      $notes.Add(("included '{0}' on an unrecognised decision `"{1}`" - check it" -f $item, $decision)) | Out-Null
    }
    if ($cls -eq 'optional') {
      $notes.Add(("'{0}' is optional in the source ({1}) and IS counted in the macros" -f $item, $decision)) | Out-Null
    }
    $ings.Add([pscustomobject]@{ item = $item; grams = $g; buy = [string]$i.buy }) | Out-Null
    if (-not $i.buy) { $findings.Add(("'{0}' has no buy string" -f $item)) | Out-Null }
  }
  # ONE LINE PER CANON ITEM. The mapper splits a food that is used twice into two lines - "3/4 cup plus
  # 2 tbsp shredded cheddar" for the mix and "1/4 cup plus 3 tbsp (topping)" - and v2's WRITER merged
  # them by hand into "1 1/3 cups shredded cheddar, divided". The writer no longer touches ingredients,
  # so the merge has to happen here or it does not happen at all. It is not a style choice: ZERO of the
  # 570 live specs carry a duplicate ingredient item, and build-v2-spec builds ingredients_display,
  # ingredients_grams and scaler.ing strictly parallel to these lines, so a duplicate would put the
  # same food on a card twice with two different amounts. Measured on the phase-4 gate corpus, where
  # three of nine recipes carried duplicate lines (jalapeno-popper-chicken-casserole split cheddar,
  # bacon bits AND jalapenos). Grams sum; the buy strings are JOINED rather than picked between,
  # because "where each part goes" is information the reader needs and nothing downstream re-derives.
  $merged = New-Object System.Collections.Generic.List[object]
  $seen = @{}
  foreach ($row in $ings.ToArray()) {
    $key = [string]$row.item
    if ($seen.ContainsKey($key)) {
      $prev = $seen[$key]
      $prev.grams = [int]($prev.grams + $row.grams)
      if ($row.buy -and ($prev.buy -ne [string]$row.buy)) {
        $prev.buy = (@($prev.buy, [string]$row.buy) | Where-Object { $_ }) -join '; '
      }
      $notes.Add(("merged a second '{0}' line into the first - {1} g total" -f $key, $prev.grams)) | Out-Null
      continue
    }
    $seen[$key] = $row
    $merged.Add($row) | Out-Null
  }
  $ingArr = $merged.ToArray()
  if (-not $ingArr.Count) { $findings.Add('the mapper decision file names no mapped ingredient') | Out-Null }

  $rc = Get-MacroRecompute $ingArr $FoodDb $Servings
  foreach ($miss in @($rc.missing)) {
    # THE MACROS ARE NOT TRUSTWORTHY WITHOUT EVERY ROW, so this is a finding and not a footnote:
    # build-v2-spec THROWS on a missing food-DB row, and the band gate would otherwise rule on a
    # number computed over a subset of the dish.
    $findings.Add(("no food-macros-db row for '{0}' - the macros are computed WITHOUT it" -f $miss)) | Out-Null
  }

  $times = New-HeadTimes ([string]$Extraction.time_total) ([string]$Extraction.time_active)
  if (-not $times.totalTime -and $Extraction.time_total) {
    $findings.Add(("could not read a duration from time_total '{0}'" -f [string]$Extraction.time_total)) | Out-Null
  }
  if (-not $times.prepTime -and $Extraction.time_active) {
    $findings.Add(("could not read a duration from time_active '{0}'" -f [string]$Extraction.time_active)) | Out-Null
  }

  $name = [string]$Mapped.title
  if (-not $name) { $name = [string]$Extraction.title }
  if (-not $name) { $findings.Add('no title in either the mapper decision file or the extraction') | Out-Null }
  $url = [string]$Mapped.source_url
  if (-not $url) { $url = [string]$Extraction.source_url }
  if (-not $url) { $findings.Add('no source_url - the credit line and the QA URL match both need it') | Out-Null }
  $protein = [string]$Mapped.protein
  if (-not $protein) { $findings.Add('no protein in the mapper decision file') | Out-Null }

  $intake = [ordered]@{
    name        = $name
    slug        = [string]$Mapped.slug
    protein     = $protein
    cuisine     = ''                 # WRITER-FILLABLE - see the header's correction
    source_url  = $url
    visibility  = 'paid'             # the house default; build-v2-spec applies the same one
    ingredients = $ingArr
    macros_per_serving = [ordered]@{
      calories  = [int][Math]::Round([double]$rc.cal, 0)
      protein_g = [Math]::Round([double]$rc.protein, 1)
      carbs_g   = [Math]::Round([double]$rc.carbs, 1)
      fat_g     = [Math]::Round([double]$rc.fat, 1)
    }
    writer_notes = @()
    forbidden_prose_terms = @()
    prose = [ordered]@{}
    head  = [ordered]@{
      description = ''; keywords = ''; image = ''
      prepTime = $times.prepTime; cookTime = $times.cookTime; totalTime = $times.totalTime
      steps = @()
    }
  }
  return [pscustomobject]@{ intake = $intake; findings = @($findings.ToArray()); notes = @($notes.ToArray()) }
}

# ---------------------------------------------------------------------------------------------------
# THE LOCKED-FIELD DIFF. The skeleton is a postcondition: after the writer returns, every locked field
# must still read exactly as it was issued. Pure, and it reports FIELD PATHS rather than a boolean,
# because the daemon's one re-dispatch quotes the drifted fields verbatim back to the writer.
# ---------------------------------------------------------------------------------------------------
$script:LOCKED_SCALARS = @('name', 'slug', 'protein', 'source_url', 'visibility')
$script:LOCKED_MACROS  = @('calories', 'protein_g', 'carbs_g', 'fat_g')
$script:LOCKED_TIMES   = @('prepTime', 'cookTime', 'totalTime')

function Get-LockedDrift {
  param($Intake, $SkeletonDoc)
  $out = New-Object System.Collections.Generic.List[string]
  $skel = $SkeletonDoc
  if ($skel.PSObject.Properties.Name -contains 'intake') { $skel = $skel.intake }

  foreach ($k in $script:LOCKED_SCALARS) {
    $a = [string]$skel.$k; $b = [string]$Intake.$k
    if ($a -ne $b) { $out.Add(("{0}: issued '{1}', returned '{2}'" -f $k, $a, $b)) | Out-Null }
  }

  $si = As-Array $skel.ingredients
  $ii = As-Array $Intake.ingredients
  if ($si.Count -ne $ii.Count) {
    $out.Add(("ingredients: issued {0} line(s), returned {1} - the writer may not add or drop an ingredient" -f $si.Count, $ii.Count)) | Out-Null
  } else {
    for ($n = 0; $n -lt $si.Count; $n++) {
      foreach ($f in @('item', 'grams', 'buy')) {
        $a = [string]$si[$n].$f; $b = [string]$ii[$n].$f
        if ($a -ne $b) {
          $out.Add(("ingredients[{0}].{1}: issued '{2}', returned '{3}'" -f $n, $f, $a, $b)) | Out-Null
        }
      }
    }
  }

  foreach ($k in $script:LOCKED_MACROS) {
    $a = [string]$skel.macros_per_serving.$k; $b = [string]$Intake.macros_per_serving.$k
    if ($a -ne $b) { $out.Add(("macros_per_serving.{0}: issued '{1}', returned '{2}'" -f $k, $a, $b)) | Out-Null }
  }

  foreach ($k in $script:LOCKED_TIMES) {
    $a = [string]$skel.head.$k; $b = [string]$Intake.head.$k
    if ($a -ne $b) { $out.Add(("head.{0}: issued '{1}', returned '{2}'" -f $k, $a, $b)) | Out-Null }
  }
  return ,@($out.ToArray())
}

function Test-HasProse {
  param($Intake)
  if (-not $Intake -or -not $Intake.prose) { return $false }
  foreach ($p in $Intake.prose.PSObject.Properties) { if ($p.Value) { return $true } }
  return $false
}

# ---------------------------------------------------------------------------------------------------
# SELF-TEST. Every fixture over a collection uses at least three elements.
# ---------------------------------------------------------------------------------------------------
if ($runSelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ("  ok    " + $n) } else { Write-Output ("  X     " + $n + "   got: " + $got); $script:bad++ }
  }

  # ---- FIXTURE 1. THE HEAD TIMES. Publishers print free text and a card that says PT0M reads as
  # instant, so an unparseable time is a NAMED finding and never a silent zero.
  T 'plain minutes' ((ConvertTo-IsoDuration '40 minutes') -eq 'PT40M') (ConvertTo-IsoDuration '40 minutes')
  T 'hours and minutes together' ((ConvertTo-IsoDuration '1 hour 15 minutes') -eq 'PT1H15M') (ConvertTo-IsoDuration '1 hour 15 minutes')
  T 'the abbreviations publishers actually use' `
    ((ConvertTo-IsoDuration '1 hr 5 mins') -eq 'PT1H5M' -and (ConvertTo-IsoDuration '25 min') -eq 'PT25M') `
    ((ConvertTo-IsoDuration '1 hr 5 mins') + '/' + (ConvertTo-IsoDuration '25 min'))
  T 'minutes over 60 roll into hours' ((ConvertTo-IsoDuration '90 minutes') -eq 'PT1H30M') (ConvertTo-IsoDuration '90 minutes')
  T 'an ISO duration passes straight through' ((ConvertTo-IsoDuration 'PT45M') -eq 'PT45M') (ConvertTo-IsoDuration 'PT45M')
  T 'a bare number is minutes' ((ConvertTo-IsoDuration '35') -eq 'PT35M') (ConvertTo-IsoDuration '35')
  T 'MUST FIRE  a string with no duration in it returns EMPTY, never PT0M' `
    ((ConvertTo-IsoDuration 'overnight') -eq '' -and (ConvertTo-IsoDuration '') -eq '') `
    ("'" + (ConvertTo-IsoDuration 'overnight') + "'")
  $ht = New-HeadTimes '40 minutes' '15 minutes'
  T 'MUST FIRE  cookTime is total minus active (the split every published v2 spec carries)' `
    ($ht.prepTime -eq 'PT15M' -and $ht.cookTime -eq 'PT25M' -and $ht.totalTime -eq 'PT40M') `
    ($ht.prepTime + '/' + $ht.cookTime + '/' + $ht.totalTime)
  $ht2 = New-HeadTimes '30 minutes' ''
  T 'CLEAN TWIN with no active time stated, the total stands alone rather than being guessed at' `
    ($ht2.totalTime -eq 'PT30M' -and $ht2.prepTime -eq '' -and $ht2.cookTime -eq '') `
    ($ht2.prepTime + '/' + $ht2.cookTime + '/' + $ht2.totalTime)
  $ht3 = New-HeadTimes '20 minutes' '30 minutes'
  T 'MUST FIRE  an active time LONGER than the total does not produce a negative cook time' `
    ($ht3.cookTime -eq '') ("'" + $ht3.cookTime + "'")

  # ---- FIXTURE 2. THE SKELETON over a FIVE-line decision file, one of which the mapper REJECTED.
  $foodDb = @{
    'Boneless Skinless Chicken Thigh' = [pscustomobject]@{ serving_grams = 112; calories = 150; protein_g = 19; carbs_g = 0;  fat_g = 8 }
    'Yellow Onion'                    = [pscustomobject]@{ serving_grams = 110; calories = 44;  protein_g = 1;  carbs_g = 10; fat_g = 0 }
    'Heavy Cream'                     = [pscustomobject]@{ serving_grams = 15;  calories = 50;  protein_g = 0;  carbs_g = 0;  fat_g = 5 }
    'Cheddar Cheese, Shredded'        = [pscustomobject]@{ serving_grams = 28;  calories = 110; protein_g = 7;  carbs_g = 1;  fat_g = 9 }
  }
  $mapped = [pscustomobject]@{
    slug = 'drill-dish'; title = 'Drill Dish'; source_url = 'https://d/x'; protein = 'chicken'
    ingredients = @(
      [pscustomobject]@{ item = 'Boneless Skinless Chicken Thigh'; grams = 2240; buy = '5 lb'; decision = 'mapped' },
      [pscustomobject]@{ item = 'Yellow Onion'; grams = 220; buy = '2 medium'; decision = 'mapped' },
      [pscustomobject]@{ item = 'Heavy Cream'; grams = 150; buy = '2/3 cup'; decision = 'mapped' },
      [pscustomobject]@{ item = 'Cheddar Cheese, Shredded'; grams = 224; buy = '2 cups'; decision = 'mapped' },
      [pscustomobject]@{ item = 'Salt and Pepper (to taste)'; grams = 0; buy = ''; decision = 'optional-pantry' }
    )
  }
  $extraction = [pscustomobject]@{ title = 'Drill Dish'; source_url = 'https://d/x'; servings = 4
                                   time_total = '40 minutes'; time_active = '15 minutes' }
  $built = New-IntakeSkeleton $mapped $extraction $foodDb 14
  $sk = $built.intake
  T 'MUST FIRE  a NOT-PURCHASED line is not an ingredient - four of five lines land, and it is NAMED' `
    (@($sk.ingredients).Count -eq 4 -and
     (@($sk.ingredients) | ForEach-Object { $_.item }) -notcontains 'Salt and Pepper (to taste)' -and
     (@($built.notes) -join ' ') -match 'excluded .Salt and Pepper') `
    ("count=" + @($sk.ingredients).Count + " notes=" + ((@($built.notes)) -join ' | '))
  T 'MUST FIRE  the machine fields come straight from the decision files, none of them typed' `
    ($sk.name -eq 'Drill Dish' -and $sk.slug -eq 'drill-dish' -and $sk.protein -eq 'chicken' -and
     $sk.source_url -eq 'https://d/x' -and $sk.visibility -eq 'paid') `
    ($sk.name + '/' + $sk.slug + '/' + $sk.protein)
  # cal:     2240/112=20 x150 = 3000; 220/110=2 x44 = 88; 150/15=10 x50 = 500; 224/28=8 x110 = 880.
  #          4468 / 14 = 319.14 -> 319.
  # protein: 20 x19 = 380; 2 x1 = 2; 10 x0 = 0; 8 x7 = 56.  438 / 14 = 31.28 -> 31.3.
  T 'MUST FIRE  macros_per_serving is grams x food-DB / servings - build-v2-spec''s own arithmetic' `
    ($sk.macros_per_serving.calories -eq 319 -and $sk.macros_per_serving.protein_g -eq 31.3) `
    ("cal=" + $sk.macros_per_serving.calories + " p=" + $sk.macros_per_serving.protein_g)
  T 'the head times are assembled, and the writer-fillable fields are left EMPTY for the writer' `
    ($sk.head.totalTime -eq 'PT40M' -and $sk.head.prepTime -eq 'PT15M' -and $sk.head.description -eq '' -and
     $sk.cuisine -eq '' -and @($sk.prose.Keys).Count -eq 0) `
    ($sk.head.totalTime + " desc='" + $sk.head.description + "'")
  T 'CLEAN TWIN a complete decision file produces NO findings' (@($built.findings).Count -eq 0) `
    ((@($built.findings)) -join ' | ')

  # ---- FIXTURE 2b. THE DECISION VOCABULARY, over the words that are ACTUALLY on disk. `decision` is
  # free text in the mapper's contract - 21 distinct values across 550 lines in the run dirs - and the
  # first build of this script kept only the exact string 'mapped'. On turkey-parmesan-meatball-bake
  # that silently dropped 1588 g of Ground Chicken (`unresolved-hold`) plus three `mapped-optional`
  # lines, computed 250 cal per serving over what was left, and the pre-write band gate retired a real
  # recipe at "250 cal below the 400 floor". A gate ruling on a fabricated number fails CLOSED and
  # looks like rigour, which is the worst way for a gate to be wrong.
  foreach ($w in @('mapped', 'mapped-null', 'mapped-null-pending-registrar', 'mapped-pending-price',
                   'mapped-ruled-addition', 'mapped-with-conflict', 'mapped-precedent',
                   'ruled-substitution', 'flagged-no-label-and-no-commodity', '')) {
    T ("CLEAN TWIN decision '" + $w + "' is an INCLUDED line (v2's own intakes carried it)") `
      ((Get-LineClass $w) -eq 'included') (Get-LineClass $w)
  }
  foreach ($w in @('optional-pantry', 'optional-null', 'optional-note', 'optional-unquantified',
                   'sub-recipe', 'sub-recipe-reference', 'alternative-not-mapped', 'mapped-free')) {
    T ("MUST FIRE  decision '" + $w + "' is NOT PURCHASED (v2 dropped 14 of 14 of the optional-* family)") `
      ((Get-LineClass $w) -eq 'not-purchased') (Get-LineClass $w)
  }
  T 'MUST FIRE  `unresolved-hold` is UNSETTLED - there is no intake to build over it' `
    ((Get-LineClass 'unresolved-hold') -eq 'unsettled') (Get-LineClass 'unresolved-hold')
  T 'MUST FIRE  `mapped-optional` is its own class - counted, and named, never silently dropped' `
    ((Get-LineClass 'mapped-optional') -eq 'optional') (Get-LineClass 'mapped-optional')
  T 'MUST FIRE  a word nobody has seen before is UNKNOWN, so it surfaces instead of changing behaviour' `
    ((Get-LineClass 'ruled-by-brad-on-a-tuesday') -eq 'unknown') (Get-LineClass 'ruled-by-brad-on-a-tuesday')

  # ...and end to end through the builder, because the classes only matter as line counts and macros.
  $vocabMapped = [pscustomobject]@{ slug='v'; title='V'; source_url='https://d/v'; protein='chicken'
    ingredients = @(
      [pscustomobject]@{ item='Boneless Skinless Chicken Thigh'; grams=2240; buy='5 lb'; decision='mapped' },
      [pscustomobject]@{ item='Yellow Onion'; grams=220; buy='2 medium'; decision='mapped-null' },
      [pscustomobject]@{ item='Heavy Cream'; grams=150; buy='2/3 cup'; decision='mapped-optional' },
      [pscustomobject]@{ item='Cheddar Cheese, Shredded'; grams=224; buy='2 cups'; decision='ruled-by-brad-on-a-tuesday' },
      [pscustomobject]@{ item='Salt and Pepper (to taste)'; grams=0; buy=''; decision='optional-pantry' },
      [pscustomobject]@{ item='Chimichurri (sub-recipe)'; grams=0; buy=''; decision='sub-recipe' })
  }
  $bv = New-IntakeSkeleton $vocabMapped $extraction $foodDb 14
  T 'MUST FIRE  FOUR of six lines are intake lines, and the optional one is COUNTED not dropped' `
    (@($bv.intake.ingredients).Count -eq 4 -and
     (@($bv.intake.ingredients) | ForEach-Object { $_.item }) -contains 'Heavy Cream') `
    ("count=" + @($bv.intake.ingredients).Count)
  T 'MUST FIRE  ...the optional line and the unrecognised word are both NAMED in the notes' `
    ((@($bv.notes) -join ' ') -match "'Heavy Cream' is optional" -and
     (@($bv.notes) -join ' ') -match 'unrecognised decision') ((@($bv.notes)) -join ' | ')
  T 'CLEAN TWIN and none of that is a FINDING - the recipe is buildable' (@($bv.findings).Count -eq 0) `
    ((@($bv.findings)) -join ' | ')

  $heldMapped = [pscustomobject]@{ slug='h'; title='H'; source_url='https://d/h'; protein='chicken'
    ingredients = @(
      [pscustomobject]@{ item='Ground Chicken'; grams=1588; buy='3 1/2 lb'; decision='unresolved-hold' },
      [pscustomobject]@{ item='Yellow Onion'; grams=220; buy='2 medium'; decision='mapped' },
      [pscustomobject]@{ item='Heavy Cream'; grams=150; buy='2/3 cup'; decision='mapped' })
  }
  $bh = New-IntakeSkeleton $heldMapped $extraction $foodDb 14
  T 'MUST FIRE  THE FOUNDING CASE: an UNSETTLED protein line is a FINDING, never a quiet subtraction' `
    ((@($bh.findings) -join ' ') -match "'Ground Chicken' is .unresolved-hold." -and
     (@($bh.intake.ingredients) | ForEach-Object { $_.item }) -notcontains 'Ground Chicken') `
    ((@($bh.findings)) -join ' | ')
  T 'MUST FIRE  ...so the band gate is never handed the macros of a dish missing its protein' `
    (@($bh.findings).Count -ge 1) 'no finding raised'

  # ---- FIXTURE 2c. ONE LINE PER CANON ITEM. The mapper splits a food used in two places; v2's WRITER
  # merged those by hand, and the writer no longer touches ingredients. ZERO of the 570 live specs
  # carry a duplicate ingredient item, and build-v2-spec builds three parallel arrays off these lines,
  # so a duplicate puts the same food on a card twice. THREE lines collapsing to TWO, because a
  # two-into-one fixture cannot tell a merge from a drop.
  $dupMapped = [pscustomobject]@{ slug='d2'; title='D2'; source_url='https://d/d2'; protein='chicken'
    ingredients = @(
      [pscustomobject]@{ item='Cheddar Cheese, Shredded'; grams=99; buy='3/4 cup plus 2 tbsp shredded cheddar'; decision='mapped' },
      [pscustomobject]@{ item='Yellow Onion'; grams=220; buy='2 medium'; decision='mapped' },
      [pscustomobject]@{ item='Cheddar Cheese, Shredded'; grams=49; buy='1/4 cup plus 3 tbsp shredded cheddar (topping)'; decision='mapped' })
  }
  $bd = New-IntakeSkeleton $dupMapped $extraction $foodDb 14
  $cheddar = @(@($bd.intake.ingredients) | Where-Object { $_.item -eq 'Cheddar Cheese, Shredded' })
  T 'MUST FIRE  three lines over two foods produce TWO ingredient lines, never a duplicate item' `
    (@($bd.intake.ingredients).Count -eq 2 -and @($cheddar).Count -eq 1) `
    ("lines=" + @($bd.intake.ingredients).Count + " cheddar=" + @($cheddar).Count)
  T 'MUST FIRE  the grams SUM - a merge that picked one side would lose 49 g of cheese' `
    ($cheddar[0].grams -eq 148) ("grams=" + [string]$cheddar[0].grams)
  T 'MUST FIRE  and BOTH buy strings survive, so the reader still learns where each part goes' `
    ($cheddar[0].buy -match 'plus 2 tbsp' -and $cheddar[0].buy -match 'topping') $cheddar[0].buy
  T 'CLEAN TWIN the merge is NAMED in the notes rather than happening quietly' `
    ((@($bd.notes) -join ' ') -match "merged a second 'Cheddar Cheese, Shredded' line") ((@($bd.notes)) -join ' | ')

  # ---- FIXTURE 3. AN INCOMPLETE SKELETON SAYS SO. build-v2-spec THROWS on a missing food-DB row, and
  # the band gate would otherwise rule on a number computed over a subset of the dish.
  $partialDb = @{}
  foreach ($k in $foodDb.Keys) { if ($k -ne 'Heavy Cream') { $partialDb[$k] = $foodDb[$k] } }
  $b2 = New-IntakeSkeleton $mapped $extraction $partialDb 14
  T 'MUST FIRE  a missing food-DB row is a NAMED finding, not a quiet subtraction from the macros' `
    (@($b2.findings).Count -ge 1 -and (@($b2.findings) -join ' ') -match "no food-macros-db row for 'Heavy Cream'") `
    ((@($b2.findings)) -join ' | ')
  $noBuy = [pscustomobject]@{ slug='d'; title='D'; source_url='https://d/x'; protein='chicken'
    ingredients = @([pscustomobject]@{ item='Yellow Onion'; grams=220; buy=''; decision='mapped' },
                    [pscustomobject]@{ item='Heavy Cream'; grams=0; buy='2/3 cup'; decision='mapped' },
                    [pscustomobject]@{ item='Cheddar Cheese, Shredded'; grams=224; buy='2 cups'; decision='mapped' }) }
  $b3 = New-IntakeSkeleton $noBuy $extraction $foodDb 14
  T 'MUST FIRE  a missing buy string and an INCLUDED line with no grams are both named' `
    ((@($b3.findings) -join ' ') -match 'no buy string' -and (@($b3.findings) -join ' ') -match 'carries no grams') `
    ((@($b3.findings)) -join ' | ')
  T 'CLEAN TWIN a zero-gram NOT-PURCHASED line is a note, not a finding - "to taste" is not a defect' `
    (@($built.findings).Count -eq 0 -and (@($built.notes) -join ' ') -match 'Salt and Pepper') `
    ((@($built.findings)) -join ' | ')

  # ---- FIXTURE 4. THE LOCKED-FIELD DIFF, which is the whole enforcement mechanism. The writer must be
  # able to fill its own fields freely and unable to move a machine one.
  $issued = $built.intake
  function Copy-Intake($src) { return ($src | ConvertTo-Json -Depth 12 | ConvertFrom-Json) }

  $filled = Copy-Intake $issued
  $filled.cuisine = 'Moroccan'
  $filled.head.description = 'A weeknight chicken bake.'
  $filled.head.keywords = 'chicken, bake'
  $filled.head.steps = @('Heat the oven.', 'Bake.', 'Portion.')
  $filled | Add-Member -NotePropertyName 'prose' -NotePropertyValue ([pscustomobject]@{
      intro_html = 'This is the dinner.'; portion_html = 'Weigh the pan.' }) -Force
  $filled.writer_notes = @('scaled from 4', 'thighs not breasts', 'no wine')
  $d0 = Get-LockedDrift $filled $issued
  T 'CLEAN TWIN a clean prose-only fill passes untouched - every writer-fillable field moved' `
    ($d0.Count -eq 0) (($d0) -join ' | ')

  $drifted = Copy-Intake $filled
  $drifted.ingredients[1].grams = 300
  $d1 = Get-LockedDrift $drifted $issued
  T 'MUST FIRE  a GRAM the writer changed is refused, and the field is NAMED with both values' `
    ($d1.Count -eq 1 -and $d1[0] -match 'ingredients\[1\]\.grams' -and $d1[0] -match "issued '220'" -and $d1[0] -match "returned '300'") `
    (($d1) -join ' | ')

  $drifted2 = Copy-Intake $filled
  $drifted2.macros_per_serving.calories = 640
  $drifted2.ingredients[0].buy = '4 lb'
  $drifted2.name = 'Drill Dish Deluxe'
  $d2 = Get-LockedDrift $drifted2 $issued
  T 'MUST FIRE  three separate drifts are reported as THREE named fields, not as one boolean' `
    ($d2.Count -eq 3 -and ($d2 -join ' ') -match 'macros_per_serving\.calories' -and
     ($d2 -join ' ') -match 'ingredients\[0\]\.buy' -and ($d2 -join ' ') -match "^name:|( name:)") `
    (($d2) -join ' | ')

  $dropped = Copy-Intake $filled
  $dropped.ingredients = @($dropped.ingredients[0], $dropped.ingredients[1], $dropped.ingredients[2])
  $d3 = Get-LockedDrift $dropped $issued
  T 'MUST FIRE  an ingredient the writer DROPPED is refused by count, before any per-line compare' `
    ($d3.Count -eq 1 -and $d3[0] -match 'issued 4 line\(s\), returned 3') (($d3) -join ' | ')

  $timeDrift = Copy-Intake $filled
  $timeDrift.head.totalTime = 'PT25M'
  $dT = Get-LockedDrift $timeDrift $issued
  T 'MUST FIRE  a head TIME is locked too - the card prints it and nothing downstream rechecks it' `
    ($dT.Count -eq 1) (($dT) -join ' | ')

  # ---- FIXTURE 4b. THE RETURN-BOUNDARY TRAP, frozen in the one place where it fails CLOSED.
  # Get-LockedDrift returns `,@(...)`. Wrapping the CALL in @() collects one output object holding
  # the array, so .Count reads 1 whatever the answer was - and here that means -Verify reporting a
  # drift on an intake nobody touched, which looks like the guard working. Measured 2026-08-24.
  $wrapped = @(Get-LockedDrift $filled $issued)
  T 'MUST FIRE  @() around the CALL reads Count 1 on a CLEAN diff - the trap, in the direction that hides' `
    ($wrapped.Count -eq 1) ("Count=" + [string]$wrapped.Count)
  T 'CLEAN TWIN assigning first reads the real answer, 0' ($d0.Count -eq 0) ("Count=" + [string]$d0.Count)
  $wrapped3 = @(Get-LockedDrift $drifted2 $issued)
  T 'MUST FIRE  and it reads Count 1 on a THREE-field drift too, so the count means nothing either way' `
    ($wrapped3.Count -eq 1 -and $d2.Count -eq 3) ("wrapped=" + [string]$wrapped3.Count + " assigned=" + [string]$d2.Count)

  # ---- FIXTURE 5. END TO END, as a CHILD PROCESS, because the exit code IS the contract the daemon
  # reads and no pure fixture can see one. Two of wave-preaudit's three day-one defects only appeared
  # when results were collected, which is exactly what a child-process drill exercises.
  $scratch = Join-Path $env:TEMP ('bis-' + [guid]::NewGuid().ToString('N'))
  try {
    New-Item -ItemType Directory -Path (Join-Path $scratch 'mapped') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $scratch 'extracted') -Force | Out-Null
    $dbPath = Join-Path $scratch 'fooddb.json'
    ([pscustomobject]@{ items = @($foodDb.Keys | ForEach-Object {
        $r = $foodDb[$_]
        [pscustomobject]@{ item = $_; serving_grams = $r.serving_grams; calories = $r.calories
                           protein_g = $r.protein_g; carbs_g = $r.carbs_g; fat_g = $r.fat_g } }) } |
      ConvertTo-Json -Depth 6) | Set-Content $dbPath -Encoding utf8
    ($mapped | ConvertTo-Json -Depth 8)     | Set-Content (Join-Path $scratch 'mapped\drill-dish.json') -Encoding utf8
    ($extraction | ConvertTo-Json -Depth 6) | Set-Content (Join-Path $scratch 'extracted\drill-dish.json') -Encoding utf8

    function Child([string[]]$ChildArgs) {
      # THE -Command ROAD, NOT -File. `powershell -File` cannot bind a multi-element [string[]] from
      # argv, and one marshalling road per language is cheaper than remembering which call has an array
      # in it today. Measured on map-preresolve's first build, where -File bound one slug of two and
      # turned an exit-2 drill into a cheerful exit 0.
      $parts = @('&', ("'" + $PSCommandPath.Replace("'", "''") + "'"))
      foreach ($a in $ChildArgs) {
        if ($a -is [string] -and $a.StartsWith('-') -and $a -notmatch '\s') { $parts += $a }
        else { $parts += ("'" + ([string]$a).Replace("'", "''") + "'") }
      }
      $cmd = ($parts -join ' ') + '; exit $LASTEXITCODE'
      $out = & powershell -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1
      return [pscustomobject]@{ rc = $LASTEXITCODE; text = ((@($out | ForEach-Object { [string]$_ })) -join "`n") }
    }

    $r0 = Child @('-RunDir', $scratch, '-Slug', 'drill-dish', '-FoodDbFile', $dbPath)
    T 'MUST FIRE  a complete skeleton exits 0 and prints the NAME-COMPLETE marker' `
      ($r0.rc -eq 0 -and $r0.text -match 'BUILD-INTAKE-SKELETON-COMPLETE') ("rc=" + $r0.rc + " " + $r0.text.Trim())
    $intakePath = Join-Path $scratch 'intake\drill-dish.json'
    $snapPath   = Join-Path $scratch 'intake\drill-dish.skeleton.json'
    T 'MUST FIRE  BOTH files land: the intake the writer completes IN PLACE, and the snapshot to diff against' `
      ((Test-Path $intakePath) -and (Test-Path $snapPath)) `
      ("intake=" + (Test-Path $intakePath) + " snapshot=" + (Test-Path $snapPath))
    $onDisk = Read-Json $intakePath
    T 'MUST FIRE  the intake on disk carries FOUR ingredient lines, not one composite row' `
      (@($onDisk.ingredients).Count -eq 4) ("count=" + @($onDisk.ingredients).Count)

    # AN UNTOUCHED INTAKE IS A WRITER THAT WROTE NOTHING, and that is a refusal rather than a clean
    # diff. Found live on the phase-4 gate run: a writer returned `status: "blocked"` with a careful
    # paragraph of reasons and touched no field. `blocked` is not `rejected`, so the lane read it as a
    # success; the locked-field diff saw no drift because nothing LOCKED had moved, and a spec would
    # have been built with every prose field empty. The check is a postcondition over the artifact,
    # which is the only kind this estate trusts - a `status` string is a claim about it.
    $v0 = Child @('-Verify', '-InFile', $intakePath, '-Skeleton', $snapPath)
    T 'MUST FIRE  an intake the writer never touched exits 1 - "no prose at all" is a refusal, not a pass' `
      ($v0.rc -eq 1 -and $v0.text -match 'returned NO prose at all') ("rc=" + $v0.rc + " " + $v0.text.Trim())

    # the writer fills its own fields and moves one it may not
    $doc = Read-Json $intakePath
    $doc.cuisine = 'Moroccan'
    $doc.head.description = 'A weeknight chicken bake.'
    $doc | Add-Member -NotePropertyName 'prose' -NotePropertyValue ([pscustomobject]@{ intro_html = 'x' }) -Force
    ($doc | ConvertTo-Json -Depth 12) | Set-Content $intakePath -Encoding utf8
    $v1 = Child @('-Verify', '-InFile', $intakePath, '-Skeleton', $snapPath)
    T 'CLEAN TWIN a prose-only completion still exits 0 - the writer owns those fields' `
      ($v1.rc -eq 0) ("rc=" + $v1.rc + " " + $v1.text.Trim())

    $doc.ingredients[2].grams = 900
    $doc.macros_per_serving.calories = 999
    ($doc | ConvertTo-Json -Depth 12) | Set-Content $intakePath -Encoding utf8
    $v2 = Child @('-Verify', '-InFile', $intakePath, '-Skeleton', $snapPath)
    T 'MUST FIRE  -Verify exits 1 on locked-field drift and NAMES both fields on stdout' `
      ($v2.rc -eq 1 -and $v2.text -match 'ingredients\[2\]\.grams' -and $v2.text -match 'macros_per_serving\.calories') `
      ("rc=" + $v2.rc + " " + $v2.text.Trim())

    T 'MUST FIRE  a rebuild REFUSES to overwrite an intake that already carries prose (exit 2)' `
      ((Child @('-RunDir', $scratch, '-Slug', 'drill-dish', '-FoodDbFile', $dbPath)).rc -eq 2) 'overwrote the prose'
    T 'CLEAN TWIN -Force makes the overwrite a deliberate choice' `
      ((Child @('-RunDir', $scratch, '-Slug', 'drill-dish', '-FoodDbFile', $dbPath, '-Force')).rc -eq 0) 'refused with -Force'

    T 'MUST FIRE  a missing mapper decision file is exit 2 - BLOCKED, never a clean bill' `
      ((Child @('-RunDir', $scratch, '-Slug', 'nosuchslug', '-FoodDbFile', $dbPath)).rc -eq 2) 'not 2'
    T 'MUST FIRE  -Verify against a missing snapshot is exit 2, never a quiet pass' `
      ((Child @('-Verify', '-InFile', $intakePath, '-Skeleton', (Join-Path $scratch 'nope.json'))).rc -eq 2) 'not 2'

    # an incomplete skeleton: the food DB loses a row the recipe needs
    $thinDb = Join-Path $scratch 'thin.json'
    ([pscustomobject]@{ items = @($foodDb.Keys | Where-Object { $_ -ne 'Heavy Cream' } | ForEach-Object {
        $r = $foodDb[$_]
        [pscustomobject]@{ item = $_; serving_grams = $r.serving_grams; calories = $r.calories
                           protein_g = $r.protein_g; carbs_g = $r.carbs_g; fat_g = $r.fat_g } }) } |
      ConvertTo-Json -Depth 6) | Set-Content $thinDb -Encoding utf8
    $r1 = Child @('-RunDir', $scratch, '-Slug', 'drill-dish', '-FoodDbFile', $thinDb, '-Force')
    T 'MUST FIRE  an INCOMPLETE skeleton exits 1 and names what is missing - the band cannot be ruled on it' `
      ($r1.rc -eq 1 -and $r1.text -match 'Heavy Cream') ("rc=" + $r1.rc + " " + $r1.text.Trim())
  } finally { Remove-Item $scratch -Recurse -Force -ErrorAction SilentlyContinue }

  if ($bad -gt 0) { Write-Output ("build-intake-skeleton SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'build-intake-skeleton SELF-TEST PASS'
  Write-GuardComplete -Name 'build-intake-skeleton' -Summary 'selftest pass'
  exit 0
}

# ---------------------------------------------------------------------------------------------------
# THE LIVE PATHS
# ---------------------------------------------------------------------------------------------------
if ($runVerify) {
  if (-not $InFile -or -not (Test-Path $InFile)) {
    Write-Output ("build-intake-skeleton: BLOCKED - no intake at {0}" -f $InFile)
    Write-GuardComplete -Name 'build-intake-skeleton' -Summary 'blocked: no intake'; exit 2
  }
  if (-not $Skeleton -or -not (Test-Path $Skeleton)) {
    # A DIFF WITH NOTHING TO DIFF AGAINST IS NOT A PASS. Without the snapshot there is no claim about
    # what was issued, and reporting clean here would be reporting that nobody looked.
    Write-Output ("build-intake-skeleton: BLOCKED - no skeleton snapshot at {0}" -f $Skeleton)
    Write-GuardComplete -Name 'build-intake-skeleton' -Summary 'blocked: no snapshot'; exit 2
  }
  $intake = $null; $snap = $null
  try { $intake = Read-Json $InFile; $snap = Read-Json $Skeleton }
  catch {
    Write-Output ("build-intake-skeleton: BLOCKED - could not parse: {0}" -f $_.Exception.Message)
    Write-GuardComplete -Name 'build-intake-skeleton' -Summary 'blocked: parse'; exit 2
  }
  if (-not $intake -or -not $snap) {
    Write-Output 'build-intake-skeleton: BLOCKED - the intake or the snapshot is empty'
    Write-GuardComplete -Name 'build-intake-skeleton' -Summary 'blocked: empty'; exit 2
  }
  # ASSIGN, DO NOT WRAP. Get-LockedDrift returns `,@(...)` so a single drift cannot unroll on the
  # way out; `@(Get-LockedDrift ...)` then collects ONE output object holding that array and .Count
  # reads 1 forever - measured here, it reported a drift on an untouched intake. The fifth PS
  # collection trap, in the one place where getting it wrong fails CLOSED and looks like rigour.
  $drift = Get-LockedDrift $intake $snap
  # AND DID ANY PROSE ARRIVE. A postcondition over the artifact, not a claim about it: the writer's
  # whole job is the prose, so "is there prose" is checkable and a `status` field is not. Found live on
  # 2026-08-24 - a writer returned `status: "blocked"` with a paragraph of reasons and wrote nothing;
  # `blocked` is not `rejected`, so the lane read it as a success and would have built a spec whose
  # every prose field was empty. The locked-field diff cannot see that, because nothing LOCKED moved.
  if (-not (Test-HasProse $intake) -and -not ([string]$intake.head.description)) {
    $drift = @($drift) + @("prose: the writer returned NO prose at all - every prose.* field and head.description is empty, so nothing it was dispatched for arrived")
  }
  if ($runJson) { ([pscustomobject]@{ slug = [string]$intake.slug; drift = $drift } | ConvertTo-Json -Depth 5) }
  if ($drift.Count) {
    Write-Output ("build-intake-skeleton: {0} LOCKED FIELD(S) DRIFTED in {1}" -f $drift.Count, [string]$intake.slug)
    foreach ($d in $drift) { Write-Output ("    " + $d) }
    Write-GuardComplete -Name 'build-intake-skeleton' -Summary ("{0} locked field(s) drifted" -f $drift.Count)
    exit 1
  }
  Write-Output ("build-intake-skeleton: {0} - every locked field is as issued" -f [string]$intake.slug)
  Write-GuardComplete -Name 'build-intake-skeleton' -Summary 'verify clean'
  exit 0
}

if (-not $RunDir) { Write-Output 'build-intake-skeleton: -RunDir is required'; exit 2 }
if (-not $Slug)   { Write-Output 'build-intake-skeleton: -Slug is required'; exit 2 }
$mappedPath = Join-Path $RunDir ("mapped\{0}.json" -f $Slug)
$extPath    = Join-Path $RunDir ("extracted\{0}.json" -f $Slug)
foreach ($need in @($mappedPath, $extPath)) {
  if (-not (Test-Path $need)) {
    Write-Output ("build-intake-skeleton: BLOCKED - required input missing: {0}" -f $need)
    Write-GuardComplete -Name 'build-intake-skeleton' -Summary 'blocked: missing input'; exit 2
  }
}
$mappedDoc = $null; $extDoc = $null; $foodDb = @{}
try {
  $mappedDoc = Read-Json $mappedPath
  $extDoc    = Read-Json $extPath
  $fRoot     = Read-Json $FoodDbFile
  foreach ($i in (As-Array $fRoot.items)) { if ($i.item) { $foodDb[[string]$i.item] = $i } }
} catch {
  Write-Output ("build-intake-skeleton: BLOCKED - {0}" -f $_.Exception.Message)
  Write-GuardComplete -Name 'build-intake-skeleton' -Summary 'blocked: parse'; exit 2
}
if (-not $mappedDoc -or -not $extDoc) {
  Write-Output 'build-intake-skeleton: BLOCKED - the mapper decision file or the extraction is empty'
  Write-GuardComplete -Name 'build-intake-skeleton' -Summary 'blocked: empty input'; exit 2
}

$outDir = Join-Path $RunDir 'intake'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$intakePath = Join-Path $outDir ("{0}.json" -f $Slug)
$snapPath   = Join-Path $outDir ("{0}.skeleton.json" -f $Slug)

# REFUSING TO OVERWRITE PROSE IS NOT PEDANTRY. The writer completes this file IN PLACE, so a rebuild on
# a resume would erase paid-for work and leave a recipe that reads as never-written. A deliberate
# rebuild passes -Force.
if ((Test-Path $intakePath) -and -not $runForce) {
  $existing = $null
  try { $existing = Read-Json $intakePath } catch { $existing = $null }
  if (Test-HasProse $existing) {
    Write-Output ("build-intake-skeleton: BLOCKED - {0} already carries writer prose. Rebuilding would erase it; pass -Force if that is what you mean." -f $intakePath)
    Write-GuardComplete -Name 'build-intake-skeleton' -Summary 'blocked: would erase prose'; exit 2
  }
}

if (-not $mappedDoc.slug) { $mappedDoc | Add-Member -NotePropertyName 'slug' -NotePropertyValue $Slug -Force }
$built = New-IntakeSkeleton $mappedDoc $extDoc $foodDb $Servings
$findings = @($built.findings)
$notes    = @($built.notes)

($built.intake | ConvertTo-Json -Depth 12) | Set-Content -Path $intakePath -Encoding utf8
# The SNAPSHOT is a separate file on purpose: the intake is about to be edited in place by the writer,
# and a postcondition that lives inside the thing it is checking is not a postcondition.
([pscustomobject]@{
  _doc = 'The machine fields as ISSUED. build-intake-skeleton.ps1 -Verify diffs the writer-completed intake against this; any drift in a locked field is exit 1 with the fields named.'
  built_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'); slug = $Slug
  findings = $findings; notes = $notes; intake = $built.intake } | ConvertTo-Json -Depth 12) |
  Set-Content -Path $snapPath -Encoding utf8

$m = $built.intake.macros_per_serving
Write-Output ("build-intake-skeleton: {0} - {1} ingredient line(s), {2} cal / {3} g protein / {4} g carbs / {5} g fat per serving at {6} servings" -f `
  $Slug, @($built.intake.ingredients).Count, $m.calories, $m.protein_g, $m.carbs_g, $m.fat_g, $Servings)
Write-Output ("build-intake-skeleton: intake {0}" -f $intakePath)
Write-Output ("build-intake-skeleton: snapshot {0}" -f $snapPath)
if ($runJson) { ($built.intake | ConvertTo-Json -Depth 12) }
foreach ($n in $notes)    { Write-Output ("    note     " + $n) }
foreach ($f in $findings) { Write-Output ("    FINDING  " + $f) }

Write-GuardComplete -Name 'build-intake-skeleton' -Summary ("{0}: {1} finding(s)" -f $Slug, $findings.Count)
if ($findings.Count) { exit 1 }
exit 0
