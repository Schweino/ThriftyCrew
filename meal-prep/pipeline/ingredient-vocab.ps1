# ingredient-vocab.ps1
# ---------------------------------------------------------------------------------------------------
# The ingredient canon-name vocabulary: what names db\ingredients.json actually accepts, and what the
# nearest rows are when a name does not resolve.
#
# FOUNDING INCIDENT (2026-08-16). The estate HAD the prices. ingredients.json carries 282 rows, 276
# with bids - "1/3 Fat Cream Cheese", "Light Sour Cream", "Broccoli Florets", "Dried Parsley", "Green
# Bell Peppers", "White Mushrooms". A run's recipes wrote "Cream Cheese", "Sour Cream", "Broccoli",
# "Fresh Parsley", "Yellow Bell Pepper", "Portobello Mushrooms". build-v2-spec resolves canon name to
# row by EXACT match, so every one of those missed by a word and silently costed $0.00. Four live pages
# shipped understating cost; ten recipes died in a wave; seventeen more were reported "blocked on
# missing prices" that were never missing. Nobody compared the failing names to the vocabulary, because
# no tool could.
#
#   .\ingredient-vocab.ps1 -List [-Json]          the whole vocabulary, prompt-sized
#   .\ingredient-vocab.ps1 -Query 'Cream Cheese'  exact/alias hit, else nearest rows + form flags
#   .\ingredient-vocab.ps1 -Missing <file>        classify many names at once (feeds the worklist)
#   .\ingredient-vocab.ps1 -SelfTest
# Exit 0 resolved / ok, 3 on -Query when the name does NOT resolve, 2 self-test failure.
#
# THIS TOOL NEVER SUBSTITUTES A NAME. It reports candidates for a human or the registrar to rule on.
# Fuzzy matching at build time is banned permanently: "Dry White Wine" -> "White Wine Vinegar" is a
# different dinner, and "Fresh Parsley" -> "Dried Parsley" is a different gram weight AND price. A
# plausible wrong match is worse than a visible miss, because nothing ever fires again.
# ---------------------------------------------------------------------------------------------------
param(
  [switch]$List, [string]$Query = '', [string]$Missing = '', [switch]$SelfTest,
  [int]$Top = 5, [string]$VocabFile = '', [switch]$Json, [switch]$AllowSmallVocab,
  # -RowsFile SCORES A DIFFERENT ROW SET THROUGH THE SAME SCORER (2026-09-04). The food DB needed a
  # near-name shelf of its own - map-preresolve's evidence said only "no food-macros-db row - a label
  # needs transcribing" and never named the rows the DB already held - and there were two wrong ways
  # to get one: a second head-noun scorer inside map-preresolve, or a third inside coverage_check.py.
  # map-preresolve's own header says why neither is acceptable ("ONE ingredient-vocab", the
  # forked-taxonomy defect). So the scorer stays here and the ROWS become an argument.
  #
  # The rows only need `item`, and `bid`/`unit` when they have them; the food DB carries item and no
  # bid, which costs nothing but the bid half of the form-word sweep.
  [string]$RowsFile = '',
  # -Recall keeps candidates that share a core word but NOT the head noun. The vocabulary worklist
  # wants precision (a worklist that cries wolf gets skimmed); a SHELF wants recall, because the
  # shelf's whole job is to put the near rows in front of a judgment that is going to be made anyway,
  # and precision for the food DB lives at the write gate instead.
  [switch]$Recall
)
$ErrorActionPreference = 'Stop'
$runList=[bool]$List; $runSelfTest=[bool]$SelfTest; $runJson=[bool]$Json; $runAllowSmall=[bool]$AllowSmallVocab; $runRecall=[bool]$Recall

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
. (Join-Path $repo 'lib\guard-contract.ps1')
if (-not $VocabFile) { $VocabFile = Join-Path $mp 'db\ingredients.json' }

# PLAUSIBILITY FLOOR. On 2026-08-16 a check of this same file reported EIGHT entries - it had read a
# JSON array as an object - and that absurd number was taken as confirmation that the estate had no
# ingredients. A 544-recipe estate cannot own an 8-row ingredient map. A tool that reads a load-bearing
# file at a few percent of its known scale is BROKEN and must say so rather than testify.
$script:MIN_VOCAB = 200

# Words that mark a DIFFERENT FORM of a food, not a synonym for it. Two names that differ only on one
# of these are near-misses to flag loudly, never to alias silently: the price, the gram weight, or the
# dish itself changes. Frozen broccoli florets are not fresh broccoli; wine is not wine vinegar.
$script:FORM_WORDS = @('fresh','dried','frozen','canned','jarred','light','fat','free','low','reduced',
  'ground','whole','sliced','shredded','grated','crushed','minced','powder','powdered','paste','sauce',
  'vinegar','juice','oil','raw','cooked','smoked','sweet','unsweetened','salted','unsalted','boneless',
  'skinless','bone','in','lean','extra','virgin','instant','quick','rolled','steel','cut','baby','wild',
  'roasted','toasted','blanched','pickled','fermented','concentrate','syrup','extract','seasoning','mix',
  # cut/portion words: a floret, a spear and a head of broccoli are priced and weighed differently
  'florets','floret','spears','halves','quarters','chunks','strips','slices','tips','head','heads',
  'breast','breasts','thigh','thighs','tenders','fillet','fillets','loin','shoulder','shank','roast')

function Read-Vocab {
  param([string]$Path, [bool]$AllowSmall)
  if (-not (Test-Path $Path)) { throw ("ingredient-vocab: no vocabulary at {0}" -f $Path) }
  # TWO PS 5.1 TRAPS, BOTH LOAD-BEARING, BOTH CAUGHT BY THE FLOOR BELOW ON 2026-08-16:
  #
  # 1. -Encoding utf8 is required, or this file mis-parses.
  # 2. ASSIGN, THEN WRAP. `@(Get-Content -Raw | ConvertFrom-Json)` yields ONE element - ConvertFrom-Json
  #    emits the whole array as a single pipeline object, so @() wraps the array rather than collecting
  #    its members, and .Count reads 1. Assigning first and wrapping after yields the true 282. This is
  #    the same array-marshalling family as `-Terms 'a,b'` binding to one composite string and `-Slugs
  #    a,b` arriving as one argument across `powershell -File` - the third instance found in one day,
  #    and the one that started this incident by reporting the estate owned no ingredients.
  $parsed = Get-Content $Path -Raw -Encoding utf8 | ConvertFrom-Json
  $rows = @($parsed)
  $real = @($rows | Where-Object { $_ -and $_.item -and -not ([string]$_.item).StartsWith('_') })
  if (@($real).Count -lt $script:MIN_VOCAB -and -not $AllowSmall) {
    throw ("ingredient-vocab: PARSED ONLY {0} rows from {1}, which is implausibly small for this estate (floor {2}). This is a parse error, not data - do not act on it. If the vocabulary genuinely shrank, pass -AllowSmallVocab deliberately." -f @($real).Count, $Path, $script:MIN_VOCAB)
  }
  return $real
}

function Read-Rows {
  <# ANY row set with an `item` on each row: a bare array, or {items:[...]} as the food DB is written.

     THE VOCABULARY'S PLAUSIBILITY FLOOR DOES NOT APPLY HERE and that is deliberate - MIN_VOCAB is a
     statement about how big THIS estate's ingredient map must be, not about every file that might be
     scored. What does apply is the half of that lesson which generalises: ZERO rows is a parse
     failure being reported as data, so it throws rather than returning an empty set that would make
     every term look like a genuine gap.
  #>
  param([string]$Path)
  if (-not (Test-Path $Path)) { throw ("ingredient-vocab: no rows file at {0}" -f $Path) }
  # ASSIGN, THEN WRAP - the PS 5.1 trap Read-Vocab documents. @(... | ConvertFrom-Json) is ONE element.
  $parsed = Get-Content $Path -Raw -Encoding utf8 | ConvertFrom-Json
  $rows = if ($parsed -and ($parsed.PSObject.Properties.Name -contains 'items')) { @($parsed.items) } else { @($parsed) }
  $real = @($rows | Where-Object { $_ -and $_.item -and -not ([string]$_.item).StartsWith('_') })
  if (@($real).Count -eq 0) {
    throw ("ingredient-vocab: PARSED 0 rows from {0}. That is a parse failure being reported as data - do not act on it." -f $Path)
  }
  return $real
}

function Get-NameTokens {
  param([string]$Name)
  if (-not $Name) { return @() }
  $t = ($Name.ToLower() -replace '[^a-z0-9 ]', ' ')
  return @($t -split '\s+' | Where-Object { $_ })
}

function Get-CoreTokens { param([string]$Name) return @(Get-NameTokens $Name | Where-Object { $script:FORM_WORDS -notcontains $_ }) }

function Test-Resolves {
  param([string]$Name, $Rows)
  $n = ([string]$Name).Trim()
  foreach ($r in $Rows) {
    if ([string]$r.item -eq $n) { return $r }
    if ($r.PSObject.Properties.Name -contains 'aliases') {
      foreach ($a in @($r.aliases)) { if ([string]$a -eq $n) { return $r } }
    }
  }
  return $null
}

# THE HEAD NOUN IS THE FOOD. Everything before it is a modifier. "Egg Yolk" and "Egg Noodles" share
# `egg` and are not remotely the same purchase; "Yellow Bell Pepper" and "Red Bell Pepper" share the
# head `pepper` and are. Scoring on ANY shared word proposed Egg Yolk -> Egg Noodles, Yellow Mustard ->
# Yellow Onion and Gruyere -> Mozzarella on the first real run. A worklist that cries wolf gets skimmed,
# and skimming is how "Dry White Wine" -> "White Wine Vinegar" eventually gets waved through.
function Get-HeadNoun {
  param([string]$Name)
  $core = @(Get-CoreTokens $Name)
  if (@($core).Count -eq 0) { $core = @(Get-NameTokens $Name) }
  if (@($core).Count -eq 0) { return '' }
  return [string]$core[@($core).Count - 1]
}

function Get-Candidates {
  param([string]$Name, $Rows, [int]$Top, [switch]$IncludeWeak)
  $core = @(Get-CoreTokens $Name)
  $all  = @(Get-NameTokens $Name)
  $head = Get-HeadNoun $Name
  $out = @()
  foreach ($r in $Rows) {
    $rc = @(Get-CoreTokens ([string]$r.item))
    $ra = @(Get-NameTokens ([string]$r.item))
    $sharedCore = @($core | Where-Object { $rc -contains $_ })
    if (@($sharedCore).Count -eq 0) { continue }
    # Head-noun agreement separates a real candidate from a coincidental word overlap.
    $rHead = Get-HeadNoun ([string]$r.item)
    $headMatch = ($head -ne '' -and $head -eq $rHead)
    if (-not $headMatch -and -not $IncludeWeak) { continue }
    # score on shared CORE words - the food itself. Form words are excluded from the score so that
    # "Fresh Parsley" and "Dried Parsley" rank on `parsley`, then get flagged for the form difference.
    $score = 10 * @($sharedCore).Count
    $formDiff = @()
    foreach ($w in $all) { if ($script:FORM_WORDS -contains $w -and $ra -notcontains $w) { $formDiff += $w } }
    foreach ($w in $ra)  { if ($script:FORM_WORDS -contains $w -and $all -notcontains $w) { $formDiff += $w } }
    # THE BID OFTEN CARRIES THE FORM THE ITEM NAME HIDES. "Broccoli Florets" reads like plain broccoli
    # until you see its bid is `frozen-broccoli-florets` - frozen, and priced as such. Scanning only the
    # display name would have offered it as a clean rename for "Broccoli", which is how a fresh-produce
    # line silently acquires a frozen price. Found by this script's own fixture, 2026-08-16.
    foreach ($w in @(([string]$r.bid).ToLower() -split '[^a-z0-9]+' | Where-Object { $_ })) {
      if ($script:FORM_WORDS -contains $w -and $all -notcontains $w) { $formDiff += $w }
    }
    $out += [pscustomobject]@{
      item = [string]$r.item; bid = [string]$r.bid; unit = [string]$r.unit
      score = $score; shared = @($sharedCore); form_diff = @($formDiff | Select-Object -Unique)
      different_form = (@($formDiff).Count -gt 0); head_match = $headMatch
    }
  }
  return @($out | Sort-Object @{Expression='head_match';Descending=$true}, @{Expression='score';Descending=$true}, @{Expression='different_form'} | Select-Object -First $Top)
}

# ---- self-test -------------------------------------------------------------------------------------
if ($runSelfTest) {
  $bad = 0
  function T([string]$n,[bool]$ok,[string]$got){ if($ok){Write-Output ("  ok    "+$n)}else{Write-Output ("  X     "+$n+"   got: "+$got); $script:bad++} }

  $fake = @(
    [pscustomobject]@{ item='1/3 Fat Cream Cheese'; bid='1-3-fat-cream-cheese'; unit='oz' },
    [pscustomobject]@{ item='Broccoli Florets';     bid='frozen-broccoli-florets'; unit='oz' },
    [pscustomobject]@{ item='Dried Parsley';        bid='dried-parsley'; unit='oz' },
    [pscustomobject]@{ item='White Wine Vinegar';   bid='white-wine-vinegar'; unit='floz' },
    [pscustomobject]@{ item='White Mushrooms';      bid='white-mushrooms'; unit='oz' },
    [pscustomobject]@{ item='Chicken Breast';       bid='chicken-breast'; unit='lb'; aliases=@('Boneless Skinless Chicken Breast') }
  )

  # the founding case
  $c = @(Get-Candidates 'Cream Cheese' $fake 5)
  T 'MUST FIRE  "Cream Cheese" surfaces "1/3 Fat Cream Cheese" as a candidate' (@($c).Count -ge 1 -and $c[0].item -eq '1/3 Fat Cream Cheese') (@($c | ForEach-Object { $_.item }) -join ',')
  T 'MUST FIRE  ...and it is FLAGGED as a different form, never offered as a synonym' ($c[0].different_form) 'not flagged'

  $p = @(Get-Candidates 'Fresh Parsley' $fake 5)
  T 'MUST FIRE  "Fresh Parsley" finds "Dried Parsley" and flags the form difference' (@($p).Count -ge 1 -and $p[0].item -eq 'Dried Parsley' -and $p[0].different_form) (@($p | ForEach-Object { $_.item }) -join ',')

  $w = @(Get-Candidates 'Dry White Wine' $fake 5)
  T 'MUST FIRE  "Dry White Wine" flags "White Wine Vinegar" rather than matching it' (@($w).Count -eq 0 -or $w[0].different_form) 'offered as a clean match'

  $b = @(Get-Candidates 'Broccoli' $fake 5)
  T 'MUST FIRE  "Broccoli" finds "Broccoli Florets" (which is FROZEN) and flags it' (@($b).Count -ge 1 -and $b[0].item -eq 'Broccoli Florets' -and $b[0].different_form) (@($b | ForEach-Object { "$($_.item):$($_.different_form)" }) -join ',')

  T 'an exact name resolves' ((Test-Resolves 'Dried Parsley' $fake) -ne $null) 'did not resolve'
  T 'MUST FIRE  an alias resolves to its row' ((Test-Resolves 'Boneless Skinless Chicken Breast' $fake).item -eq 'Chicken Breast') 'alias ignored'
  T 'MUST FIRE  an unknown name does NOT resolve' ($null -eq (Test-Resolves 'Cream Cheese' $fake)) 'falsely resolved'
  T 'CLEAN TWIN a totally unrelated name yields no candidates at all' ((@(Get-Candidates 'Saffron' $fake 5)).Count -eq 0) 'invented a match'

  # head-noun discipline - the fix for a worklist full of noise, found on the first real run
  $fake2 = @(
    [pscustomobject]@{ item='Egg Noodles';     bid='egg-noodles'; unit='oz' },
    [pscustomobject]@{ item='Yellow Onion';    bid='onions'; unit='lb' },
    [pscustomobject]@{ item='Red Bell Pepper'; bid='red-bell-pepper'; unit='each' },
    [pscustomobject]@{ item='Mozzarella Cheese'; bid='mozzarella-cheese'; unit='oz' }
  )
  T 'MUST FIRE  "Egg Yolk" does NOT propose "Egg Noodles" (shared word, different food)' ((@(Get-Candidates 'Egg Yolk' $fake2 5)).Count -eq 0) (@(Get-Candidates 'Egg Yolk' $fake2 5 | ForEach-Object { $_.item }) -join ',')
  T 'MUST FIRE  "Yellow Mustard" does NOT propose "Yellow Onion"' ((@(Get-Candidates 'Yellow Mustard' $fake2 5)).Count -eq 0) (@(Get-Candidates 'Yellow Mustard' $fake2 5 | ForEach-Object { $_.item }) -join ',')
  T 'CLEAN TWIN "Yellow Bell Pepper" DOES propose "Red Bell Pepper" (same head noun)' ((@(Get-Candidates 'Yellow Bell Pepper' $fake2 5)).Count -eq 1) (@(Get-Candidates 'Yellow Bell Pepper' $fake2 5 | ForEach-Object { $_.item }) -join ',')
  T 'the head noun is the last non-form word' ((Get-HeadNoun 'Fresh Parsley') -eq 'parsley' -and (Get-HeadNoun 'Boneless Skinless Chicken Breast') -eq 'chicken') ((Get-HeadNoun 'Boneless Skinless Chicken Breast'))
  T '-IncludeWeak still surfaces coincidental overlaps when asked' ((@(Get-Candidates 'Egg Yolk' $fake2 5 -IncludeWeak)).Count -ge 1) 'weak suppressed even when requested'

  # the plausibility floor - the fix for the 8-row misread
  $tmp = Join-Path $env:TEMP ('vocab-' + [guid]::NewGuid().ToString('N') + '.json')
  try {
    (@([pscustomobject]@{ item='Only One'; bid='x' }) | ConvertTo-Json -Depth 4) | Set-Content $tmp -Encoding utf8
    $threw = $false
    try { Read-Vocab $tmp $false } catch { $threw = $true }
    T 'MUST FIRE  an implausibly small vocabulary is REFUSED, not reported as fact' $threw 'accepted a 1-row vocabulary'
    $ok2 = $false
    try { $r = Read-Vocab $tmp $true; $ok2 = (@($r).Count -eq 1) } catch { $ok2 = $false }
    T 'CLEAN TWIN -AllowSmallVocab makes the override a deliberate choice' $ok2 'override did not work'
  } finally { if (Test-Path $tmp) { Remove-Item $tmp -Force } }

  # against the REAL file
  $real = Read-Vocab $VocabFile $false
  T 'MUST FIRE  the live vocabulary parses at full size (the 2026-08-16 misread)' (@($real).Count -ge 250) ([string]@($real).Count)
  # The founding case, now RULED (Brad, 2026-08-16): "Cream Cheese" is an adjudicated alias of
  # "1/3 Fat Cream Cheese". This fixture asserted the opposite until the ruling landed - it is kept,
  # inverted, so the alias cannot be silently dropped from the vocabulary later.
  $cc = Test-Resolves 'Cream Cheese' $real
  T 'MUST FIRE  the "Cream Cheese" alias resolves to the 1/3-fat row (the founding case, ruled)' ($cc -and [string]$cc.item -eq '1/3 Fat Cream Cheese') $(if($cc){[string]$cc.item}else{'does not resolve'})
  # A NEAR MISS must still miss. "Green Bell Peppers" is a real row; the singular is not, and nothing
  # may quietly bridge that gap - not plural-stripping, not stemming, not "close enough". Every bridge
  # is an adjudicated alias or it does not exist. (The previous fixture used Portobello Mushrooms, which
  # stopped being unruled the moment it was captured and given a row - a fixture has to name something
  # that stays true.)
  $unruled = Test-Resolves 'Green Bell Pepper' $real
  T 'MUST FIRE  a NEAR-MISS name does not resolve without a ruling (singular vs the real plural row)' ($null -eq $unruled) 'resolved without a ruling'
  T 'CLEAN TWIN a known-good name resolves against the live vocabulary' ((Test-Resolves 'Black Pepper' $real) -ne $null) 'Black Pepper missing'

  # ---- -RowsFile / -Recall: the SAME scorer over a different row set (2026-09-04) ---------------
  #
  # The food DB needed a near-name shelf and there were two wrong ways to build one: a second
  # head-noun scorer inside map-preresolve, or a third inside coverage_check.py. These pin that the
  # rows became an argument and the scorer did not fork.
  $tmpd = Join-Path ([IO.Path]::GetTempPath()) ("ivrows-" + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmpd | Out-Null
  try {
    $enc = New-Object System.Text.UTF8Encoding($false)
    $wrapped = Join-Path $tmpd 'wrapped.json'
    $bare    = Join-Path $tmpd 'bare.json'
    $empty   = Join-Path $tmpd 'empty.json'
    # 'Lime Zest' IS in this file, exactly. That is deliberate: it is what makes the "resolution is
    # never claimed" case below able to fail - with Test-Resolves wrongly asked of a foreign row set,
    # an exact name hit answers RESOLVES and hides every near row behind it. A fixture whose rows do
    # not contain the queried name could never reach that branch.
    # 'Zestmarker Fixture' exists ONLY here and in no vocabulary, so a candidate list containing it is
    # proof the rows came from THIS FILE rather than from db\ingredients.json.
    [IO.File]::WriteAllText($wrapped, (@{ items = @(
      @{ item = 'Lemon Zest' }, @{ item = 'Orange Zest' }, @{ item = 'Dried Parsley' },
      @{ item = 'Fresh Parsley' }, @{ item = 'Cheddar Cheese' }, @{ item = 'Egg Noodles' },
      @{ item = 'Lime Zest' }, @{ item = 'Zestmarker Fixture Zest' }) } | ConvertTo-Json -Depth 5), $enc)
    [IO.File]::WriteAllText($bare, (@(@{ item = 'Lemon Zest' }, @{ item = 'Orange Zest' }) | ConvertTo-Json -Depth 5), $enc)
    [IO.File]::WriteAllText($empty, '[]', $enc)

    $wr = Read-Rows $wrapped
    T 'MUST FIRE  Read-Rows unwraps an {items:[...]} file - the shape the food DB is actually written in' (@($wr).Count -eq 8) (@($wr).Count)
    $br = Read-Rows $bare
    T 'MUST FIRE  ...and reads a BARE array too, which is the shape the vocabulary uses' (@($br).Count -eq 2) (@($br).Count)
    $threw = $false
    try { Read-Rows $empty | Out-Null } catch { $threw = $true }
    T 'MUST FIRE  ZERO rows THROWS rather than returning an empty set - a parse failure reported as data would make every term look like a genuine gap, which is the MIN_VOCAB lesson generalised' $threw 'returned an empty set'
    $threw2 = $false
    try { Read-Rows (Join-Path $tmpd 'nope.json') | Out-Null } catch { $threw2 = $true }
    T 'MUST FIRE  a missing rows file throws rather than scoring against nothing' $threw2 'did not throw'

    # THE SCORER IS THE SAME ONE. Not "a scorer that behaves similarly" - the same function, over
    # rows that came from somewhere else.
    $z = @(Get-Candidates 'Lime Zest' $wr 5)
    T 'MUST FIRE  the vocabulary scorer ranks food-DB rows: "Lime Zest" surfaces "Lemon Zest" and "Orange Zest" off a head-noun match on `zest`' `
      ((@($z).Count -ge 2) -and (@($z | ForEach-Object { $_.item }) -contains 'Lemon Zest') -and (@($z | ForEach-Object { $_.item }) -contains 'Orange Zest')) `
      ((@($z | ForEach-Object { $_.item }) -join ','))
    $fp = @(Get-Candidates 'Fresh Parsley' $wr 5)
    T 'MUST FIRE  ...and the FORM flag still fires over a foreign row set - Dried vs Fresh Parsley is flagged, never offered as a synonym' `
      ((@($fp).Count -ge 1) -and (@($fp | Where-Object { $_.item -eq 'Dried Parsley' -and $_.different_form }).Count -ge 1)) `
      ((@($fp | ForEach-Object { $_.item }) -join ','))

    # RECALL vs PRECISION. -Recall keeps a shared-core-word candidate whose HEAD NOUN differs; the
    # worklist must not, because a worklist that cries wolf gets skimmed.
    # 'Egg Yolk' vs 'Egg Noodles' is the pair Get-HeadNoun's own comment names as the reason head-noun
    # agreement exists at all: they share the core word `egg` and are not remotely the same purchase.
    $strict = @(Get-Candidates 'Egg Yolk' $wr 5)
    $loose  = @(Get-Candidates 'Egg Yolk' $wr 5 -IncludeWeak)
    T 'MUST FIRE  -Recall is the difference: `Egg Yolk` -> `Egg Noodles` shares the core word `egg` with a DIFFERENT head noun, so the worklist road drops it and the shelf road keeps it' `
      ((@($strict).Count -eq 0) -and (@($loose).Count -ge 1)) ("strict=" + @($strict).Count + " loose=" + @($loose).Count)
    T 'CLEAN TWIN ...and the loose road really found the row it should have, not just any row' `
      ((@($loose | ForEach-Object { $_.item }) -contains 'Egg Noodles')) ((@($loose | ForEach-Object { $_.item }) -join ','))

    # END TO END through the child contract map-preresolve will use.
    $terms = Join-Path $tmpd 'terms.txt'
    [IO.File]::WriteAllText($terms, "Lime Zest`r`n", $enc)
    $childOut = & $PSCommandPath -Missing $terms -RowsFile $wrapped -Recall -Json 2>&1
    $childRc = $LASTEXITCODE
    $doc = ($childOut -join "`n") | ConvertFrom-Json
    $cands = @($doc.results[0].candidates)
    $names = @($cands | ForEach-Object { [string]$_.item })
    T 'MUST FIRE  the -Missing -Json contract is UNCHANGED over a foreign row set, so map-preresolve reads it exactly as it reads the vocabulary answer' `
      (($childRc -eq 0) -and ([string]$doc.results[0].name -eq 'Lime Zest') -and (@($cands).Count -ge 2)) `
      ("rc=$childRc " + (($childOut -join ' ').Substring(0, [Math]::Min(160, ($childOut -join ' ').Length))))
    T 'MUST FIRE  ...and the candidates really came from THE ROWS FILE - `Zestmarker Fixture Zest` exists in it and in no vocabulary, so scoring db\ingredients.json instead cannot produce it' `
      ($names -contains 'Zestmarker Fixture Zest') ($names -join ',')
    T 'MUST FIRE  ...and RESOLUTION is never claimed over a foreign row set. The rows file holds `Lime Zest` EXACTLY, so asking Test-Resolves here would answer RESOLVES and return an empty candidate list - hiding every near row behind an exact-name hit' `
      (([string]$doc.results[0].class -ne 'RESOLVES') -and (@($cands).Count -ge 2)) `
      ([string]$doc.results[0].class + " cands=" + @($cands).Count)

    # -Recall THROUGH THE CHILD, which is the only place the $runRecall wiring is exercised. Calling
    # Get-Candidates -IncludeWeak directly proves the SCORER and says nothing about whether the switch
    # reaches it - measured 2026-09-04, when neutering the wiring left every case green.
    [IO.File]::WriteAllText($terms, "Egg Yolk`r`n", $enc)
    $looseOut  = & $PSCommandPath -Missing $terms -RowsFile $wrapped -Recall -Json 2>&1
    $strictOut = & $PSCommandPath -Missing $terms -RowsFile $wrapped -Json 2>&1
    $looseN  = @((($looseOut  -join "`n") | ConvertFrom-Json).results[0].candidates | ForEach-Object { [string]$_.item })
    $strictN = @((($strictOut -join "`n") | ConvertFrom-Json).results[0].candidates | ForEach-Object { [string]$_.item })
    T 'MUST FIRE  -Recall reaches the scorer THROUGH the child contract: `Egg Yolk` surfaces `Egg Noodles` with it and not without it' `
      (($looseN -contains 'Egg Noodles') -and (-not ($strictN -contains 'Egg Noodles'))) `
      ("loose=" + ($looseN -join ',') + " strict=" + ($strictN -join ','))
  } finally {
    Remove-Item -Recurse -Force $tmpd -ErrorAction SilentlyContinue
  }

  if ($bad -gt 0) { Write-Output ("ingredient-vocab SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'ingredient-vocab SELF-TEST PASS'
  Write-GuardComplete -Name 'ingredient-vocab' -Summary 'selftest pass'
  exit 0
}

$rows = if ($RowsFile) { Read-Rows $RowsFile } else { Read-Vocab $VocabFile $runAllowSmall }

# ---- -List -----------------------------------------------------------------------------------------
if ($runList) {
  if ($runJson) { ([pscustomobject]@{ count=@($rows).Count; items=@($rows | ForEach-Object { [pscustomobject]@{ item=[string]$_.item; bid=[string]$_.bid; unit=[string]$_.unit; aliases=@($_.aliases) } }) } | ConvertTo-Json -Depth 5); exit 0 }
  Write-Output ("INGREDIENT VOCABULARY ({0} rows). These are the ONLY canon names a recipe may use." -f @($rows).Count)
  Write-Output 'Using one costs nothing. Extending the list is a deliberate, recorded act - propose a rename,'
  Write-Output 'an adjudicated alias, or a new row through the commodity-registrar. Never invent a name.'
  foreach ($r in ($rows | Sort-Object item)) {
    $al = if ($r.PSObject.Properties.Name -contains 'aliases' -and @($r.aliases).Count) { '   aka ' + (@($r.aliases) -join ' | ') } else { '' }
    Write-Output ("  {0,-40} {1,-30} {2}{3}" -f $r.item, $r.bid, $r.unit, $al)
  }
  exit 0
}

# ---- -Missing (bulk classification, feeds the reconciliation worklist) --------------------------------
if ($Missing) {
  if (-not (Test-Path $Missing)) { Write-Output ("ingredient-vocab: no such file {0}" -f $Missing); exit 1 }
  $names = @(Get-Content $Missing -Encoding utf8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
  $out = @()
  foreach ($n in $names) {
    # RESOLUTION IS A VOCABULARY QUESTION, so a foreign row set does not get one. Test-Resolves
    # reads aliases and bids that only the vocabulary has; asking it of the food DB would answer
    # "RESOLVES" on an exact name match and hide every near row behind it, which is the opposite of
    # what a shelf is for.
    $hit = if ($RowsFile) { $null } else { Test-Resolves $n $rows }
    if ($hit) { $out += [pscustomobject]@{ name=$n; class='RESOLVES'; resolves_to=[string]$hit.item; candidates=@() }; continue }
    $cands = if ($runRecall) { @(Get-Candidates $n $rows $Top -IncludeWeak) } else { @(Get-Candidates $n $rows $Top) }
    $cls = if (@($cands).Count -eq 0) { 'GENUINE-GAP' } elseif ($cands[0].different_form) { 'DIFFERENT-FORM' } else { 'RENAME' }
    $out += [pscustomobject]@{ name=$n; class=$cls; resolves_to=$null; candidates=@($cands) }
  }
  if ($runJson) { ([pscustomobject]@{ count=@($out).Count; results=@($out) } | ConvertTo-Json -Depth 6); exit 0 }
  foreach ($o in $out) {
    Write-Output ("{0,-16} {1}" -f $o.class, $o.name)
    if ($o.resolves_to) { Write-Output ("                 -> resolves to '{0}'" -f $o.resolves_to) }
    foreach ($c in @($o.candidates)) {
      Write-Output ("                 {0,-38} bid={1,-28} {2}" -f $c.item, $c.bid, $(if($c.different_form){'DIFFERENT FORM: ' + ((@($c.form_diff)|Select-Object -First 3) -join '/')}else{'same form'}))
    }
  }
  exit 0
}

# ---- -Query ----------------------------------------------------------------------------------------
if (-not $Query) { Write-Output 'ingredient-vocab: pass -List, -Query <name>, -Missing <file> or -SelfTest'; exit 1 }
$hit = Test-Resolves $Query $rows
if ($hit) {
  if ($runJson) { ([pscustomobject]@{ query=$Query; resolved=$true; row=$hit } | ConvertTo-Json -Depth 5); exit 0 }
  Write-Output ("RESOLVES  '{0}' -> row '{1}'  bid={2}  unit={3}" -f $Query, $hit.item, $hit.bid, $hit.unit)
  exit 0
}
$cands = @(Get-Candidates $Query $rows $Top)
if ($runJson) { ([pscustomobject]@{ query=$Query; resolved=$false; candidates=@($cands) } | ConvertTo-Json -Depth 5); exit 3 }
Write-Output ("UNKNOWN NAME  '{0}' is not in the ingredient vocabulary ({1} rows)." -f $Query, @($rows).Count)
if (-not @($cands).Count) {
  Write-Output '  No row shares a core word. This looks like a GENUINE GAP - it needs a new row via the'
  Write-Output '  commodity-registrar plus a real capture, not a rename.'
  exit 3
}
Write-Output '  Nearest rows (CANDIDATES TO RULE ON - this tool never substitutes a name):'
foreach ($c in $cands) {
  Write-Output ("    {0,-38} bid={1,-28} {2}" -f $c.item, $c.bid, $(if($c.different_form){'*** DIFFERENT FORM (' + ((@($c.form_diff)|Select-Object -First 3) -join '/') + ') - price and grams may differ; needs a ruling, not an alias'}else{'same form - likely a rename'}))
}
exit 3
