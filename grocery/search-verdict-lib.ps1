<#
  search-verdict-lib.ps1 - the ONE definition of what a store search actually answered.

  THE DEFECT THIS EXISTS FOR. Every search lane used to return a row count, and a row count cannot tell
  "searched and found nothing" apart from "returned something unusable" apart from "could not really search".
  A thin result reads exactly like an absence, so the failure mode was confidently recording NOT-CARRIED for
  products sitting on the shelf. Measured in the 2026-08-15 Recipe Hunter trial, four of ten terms would have
  been mis-ruled on their first query:
    'chipotle powder' -> 0 hits at both stores;      'ground chipotle' -> the actual jar at Baker's
    'cumin seeds'     -> 1 hit, a HAIR CONDITIONER;  'cumin'           -> Tampico Cumin Whole $1.69/oz
    'cornmeal'        -> 0 at Family Fare;           'corn meal'       -> the store-brand 32 oz bag
    'guajillo chile'  -> 0 at both;                  'guajillo'        -> the dried pods at both
  Extra qualifying words SHRINK the result set toward zero; they do not re-rank it. Adding the more precise
  word made the answer worse.

  THREE STATES, AND THE ONLY CONCLUSION EACH PERMITS:
    MATCHES   a real result grid          -> adjudicate (a match is still not a carriage ruling)
    EMPTY     explicit no-results, or only a suggestion block, AFTER the full ladder -> not-carried
    UNUSABLE  bot wall, wrong store, timeout, never rendered                         -> blocked, NEVER
              not-carried. Unchecked is not absence.

  THE SWITCH IS -SearchVerdictSelfTest, NOT -SelfTest, AND THAT IS LOAD-BEARING.
  Dot-sourcing executes this file's param() block IN THE CALLER'S SCOPE. A lib declaring [switch]$SelfTest
  therefore resets the caller's own $SelfTest to $false the instant it is dot-sourced. On 2026-08-15 that
  exact mistake silently disarmed pull-regular-familyfare.ps1's hermetic self-test and ran a LIVE Freshop
  pull instead, looking from the outside like a self-test that printed a lot. Namespaced, it cannot collide.

  Usage:
    . search-verdict-lib.ps1
    $ladder = @(Get-RetryLadder 'chipotle powder')     # -> chipotle powder, chipotle
    if (Test-NoResultsPhrase $pageText) { ... }        # check BEFORE counting tiles
    $v = New-SearchVerdict -State EMPTY -TermUsed 'fennel' -Attempts $tries -Reason '...'
    .\search-verdict-lib.ps1 -SearchVerdictSelfTest
#>
param([switch]$SearchVerdictSelfTest)

# Words that NARROW a query into nothing. Stripping them is rung 2. 'sauce' is conditional: it is a real
# product class ('chili garlic sauce' IS the thing), so it only strips when >2 words survive without it.
$script:SV_QUALIFIERS = @('powder', 'ground', 'dried', 'whole', 'seeds', 'seed', 'fresh', 'chopped',
                          'sliced', 'raw', 'chile', 'chiles', 'chilies', 'flakes')
$script:SV_QUALIFIERS_CONDITIONAL = @('sauce', 'oil', 'mix')

# WHAT COUNTS AS A WORD BOUNDARY (B4 / gate finding 4, MEASURED 2026-08-24 on the live phase-5 pricer
# batch). It is not whitespace. `Get-RetryLadder 'korean-rice-cakes'` returned ELEVEN rungs, ten of them
# character mutilations - 'kore an-rice-cakes', 'korea n-rice-cakes', 'korean -rice-cakes' ... - because
# the term carries no SPACE, so it read as one 17-character word and the compound splitter fired at
# every position >= 4. That is the 'purple unicorn fruit' trap the header documents, arriving through a
# separator this lib did not consider. Eleven rungs x 2 server stores x ~25 s is up to nine minutes of
# real network probing for ONE term, and the pricer caught it by hand.
# A hyphen and an underscore separate words exactly as a space does; the ladder counts on all three, and
# the hyphen-to-space swap ('korean rice cakes') is a REAL rung instead of ten pieces of nonsense.
$script:SV_WORD_SEP = '[\s\-_]+'

# R1: a no-results banner outranks any number of product tiles rendered beneath it. Aldi renders 29
# suggestion tiles under the literal text 'No results for "fennel"'; parsley and green onions appeared as
# "results" for bean-sprouts, fennel AND chili-garlic-sauce. Counting tiles said 29; the truth was 0.
$script:SV_NO_RESULT_PHRASES = @('no results for', "couldn't find", 'could not find', 'did not match',
                                 'no products found', '0 results', 'no matches', 'browse related items')

function Test-NoResultsPhrase([string]$PageText) {
  if (-not $PageText) { return $false }
  $t = $PageText.ToLowerInvariant()
  foreach ($p in $script:SV_NO_RESULT_PHRASES) { if ($t.Contains($p)) { return $true } }
  return $false
}

# Split a single compound word where BOTH halves are >= 4 chars ('cornmeal' -> 'corn meal',
# 'beansprouts' -> 'bean sprouts'). The 4-char floor is what stops 'lentils' from becoming 'lent ils'.
# SPLITTING IS ONLY EVER APPLIED TO A GENUINELY SINGLE-WORD TERM, never to a form this lib derived by
# joining. 'purple unicorn fruit' joined to 'purpleunicornfruit' and then split at every legal position
# produced 12 nonsense rungs ('purp leunicornfruit', 'purpleunicor nfruit'...) and 13 wasted network calls
# in 12.9s during the 2026-08-15 verification. A derived join is a leaf, not a new trunk.
function Get-SpacingVariants([string]$Term, [bool]$AllowSplit = $true) {
  $out = New-Object System.Collections.ArrayList
  # SEPARATORS, not spaces (B4). 'corn-meal' is two words and joins to 'cornmeal'; it is not one
  # nine-letter word to be sliced apart at every position >= 4.
  $words = @($Term -split $script:SV_WORD_SEP | Where-Object { $_ })
  if ($words.Count -gt 1) {
    [void]$out.Add(($words -join ''))            # 'corn meal' / 'corn-meal' -> 'cornmeal'
  } elseif ($words.Count -eq 1 -and $AllowSplit) {
    $w = $words[0]
    for ($i = 4; $i -le ($w.Length - 4); $i++) { [void]$out.Add($w.Substring(0, $i) + ' ' + $w.Substring($i)) }
  }
  return $out.ToArray()
}

# R2: the deterministic ladder. Rung 1 the term as given, rung 2 qualifier-stripped, rung 3 spacing
# variants, rung 4 the longest single word. Ordered, de-duplicated, case-preserving.
function Get-RetryLadder([string]$Term) {
  $out = New-Object System.Collections.ArrayList
  $seen = @{}
  function Add-Rung($v) {
    $s = ([string]$v).Trim()
    if (-not $s) { return }
    $k = $s.ToLowerInvariant()
    if ($seen.ContainsKey($k)) { return }
    $seen[$k] = $true
    [void]$out.Add($s)
  }

  Add-Rung $Term
  $words = @($Term -split $script:SV_WORD_SEP | Where-Object { $_ })

  # rung 1b - THE SEPARATOR SWAP (B4). A hyphenated or underscored term said with spaces is the same
  # query every store's search box expects: 'korean-rice-cakes' -> 'korean rice cakes'. It is ONE rung,
  # and it replaces the ten character mutilations that used to arrive here because a hyphenated term
  # counted as a single word. Add-Rung de-duplicates, so a term already spelled with spaces gains
  # nothing.
  if ($words.Count -gt 1) { Add-Rung ($words -join ' ') }

  # rung 2 - strip qualifiers
  if ($words.Count -gt 1) {
    $kept = @($words | Where-Object { $script:SV_QUALIFIERS -notcontains $_.ToLowerInvariant() })
    if ($kept.Count -gt 0 -and $kept.Count -lt $words.Count) { Add-Rung ($kept -join ' ') }
    # conditional qualifiers: only strip when more than 2 words survive
    $kept2 = @($kept | Where-Object { $script:SV_QUALIFIERS_CONDITIONAL -notcontains $_.ToLowerInvariant() })
    if ($kept2.Count -gt 2 -and $kept2.Count -lt $kept.Count) { Add-Rung ($kept2 -join ' ') }
  }

  # rung 3 - spacing variants. Split only a genuinely single-word term; the qualifier-stripped form may be
  # JOINED but never re-split (that is where the nonsense rungs came from).
  foreach ($v in (Get-SpacingVariants $Term ($words.Count -eq 1))) { Add-Rung $v }
  if ($out.Count -gt 1) { foreach ($v in (Get-SpacingVariants $out[1] $false)) { Add-Rung $v } }

  # rung 4 - the head noun, and ONLY for a two-word term.
  # 'brown lentils' -> 'lentils' is a head noun and finds the real product. 'purple unicorn fruit' ->
  # 'unicorn' found 21 unrelated products and reported MATCHES: at three or more words the longest word is
  # as likely to be incidental as essential, and a ladder that manufactures presence is worse than one that
  # reports an honest EMPTY. Measured 2026-08-15 against a deliberately nonsense term.
  if ($words.Count -eq 2) {
    $longest = @($words | Sort-Object -Property @{ E = { $_.Length }; D = $true })[0]
    Add-Rung $longest
  }

  return $out.ToArray()
}

function New-SearchVerdict {
  param(
    [ValidateSet('MATCHES', 'EMPTY', 'UNUSABLE')][string]$State,
    [string]$TermUsed = '',
    $Attempts = @(),
    $Hits = @(),
    [string]$Reason = ''
  )
  return [pscustomobject]@{
    state     = $State
    term_used = $TermUsed
    attempts  = @($Attempts)
    hits      = @($Hits)
    reason    = $Reason
  }
}

# R2's stopping rule, in one place so probe and any browser-side port cannot disagree. A single hit is not
# enough on its own: 'cumin seeds' returned exactly one hit and it was a hair conditioner.
function Test-LadderSatisfied($Hits, [int]$MinHits = 2) {
  return (@($Hits).Count -ge $MinHits)
}

if ($SearchVerdictSelfTest) {
  $bad = 0
  # `return @(...)` UNROLLS a one-element array back to a bare string on the way out, and then $l[0] is the
  # CHARACTER 'l' rather than 'lentils'. The comma operator is what preserves array-ness across the return.
  function L([string]$t) { return ,@(Get-RetryLadder $t) }
  function Has($arr, $v) { return (@($arr) -contains $v) }

  # MUST-FIRE, all four frozen verbatim from the 2026-08-15 trial
  $l = L 'chipotle powder'
  if (-not (Has $l 'chipotle')) { Write-Output "  X E1: ladder('chipotle powder') lacks 'chipotle' -> $($l -join ', ')"; $bad++ }
  $l = L 'cumin seeds'
  if (-not (Has $l 'cumin')) { Write-Output "  X E2: ladder('cumin seeds') lacks 'cumin' -> $($l -join ', ')"; $bad++ }
  $l = L 'corn meal'
  if (-not (Has $l 'cornmeal')) { Write-Output "  X E3a: ladder('corn meal') lacks 'cornmeal' -> $($l -join ', ')"; $bad++ }
  $l = L 'cornmeal'
  if (-not (Has $l 'corn meal')) { Write-Output "  X E3b: ladder('cornmeal') lacks 'corn meal' -> $($l -join ', ')"; $bad++ }
  $l = L 'guajillo chile'
  if (-not (Has $l 'guajillo')) { Write-Output "  X E4: ladder('guajillo chile') lacks 'guajillo' -> $($l -join ', ')"; $bad++ }

  # the qualifier-stripped rung must come BEFORE the bare longest-word rung: 'chipotle' is a better query
  # than whatever a single-word fallback would pick, and the caller stops at the first satisfying rung.
  $l = L 'ground chipotle powder'
  $iStrip = [Array]::IndexOf($l, 'chipotle')
  if ($iStrip -lt 1) { Write-Output "  X qualifier rung missing or first -> $($l -join ', ')"; $bad++ }

  # CLEAN TWINS - the ladder must not manufacture breadth
  $l = L 'lentils'
  if ($l.Count -ne 1 -or $l[0] -ne 'lentils') { Write-Output "  X a single word with no valid split must be its own ladder -> $($l -join ', ')"; $bad++ }
  $l = L 'saffron'
  if ($l.Count -ne 1) { Write-Output "  X 'saffron' should not gain rungs -> $($l -join ', ')"; $bad++ }
  # 'chili garlic sauce' keeps its sauce: stripping would leave only 2 words, and it IS a product class
  $l = L 'chili garlic sauce'
  if (Has $l 'chili garlic') { Write-Output "  X 'sauce' was stripped when only 2 words would remain -> $($l -join ', ')"; $bad++ }
  # no duplicates, ever
  $l = L 'dried guajillo chiles'
  if (@($l | Group-Object | Where-Object { $_.Count -gt 1 }).Count) { Write-Output "  X ladder contains duplicates -> $($l -join ', ')"; $bad++ }

  # MUST-FIRE: THE LADDER MUST NOT MANUFACTURE PRESENCE. Verified live 2026-08-15 - the first version
  # laddered 'purple unicorn fruit' down to 'unicorn' and reported MATCHES on 21 unrelated products, after
  # burning 13 network calls on split-junk rungs like 'purp leunicornfruit'.
  $l = L 'purple unicorn fruit'
  if (Has $l 'unicorn') { Write-Output "  X a 3-word term fell back to a bare longest word -> $($l -join ', ')"; $bad++ }
  if ($l.Count -gt 3) { Write-Output "  X ladder exploded on a 3-word term ($($l.Count) rungs) -> $($l -join ', ')"; $bad++ }
  foreach ($r in $l) { if ($r -match '^\S{4,}\s\S+$' -and $r -notmatch '^(purple|unicorn|fruit)\b' ) { Write-Output "  X split-junk rung survived -> '$r'"; $bad++ } }
  # the 2-word head-noun rung IS still wanted
  $l = L 'brown lentils'
  if (-not (Has $l 'lentils')) { Write-Output "  X a 2-word term lost its head noun -> $($l -join ', ')"; $bad++ }

  # ---- B4 / GATE FINDING 4: A HYPHENATED TERM IS WORDS, NOT ONE LONG WORD. ---------------------
  # MEASURED 2026-08-24 on the live phase-5 pricer batch: Get-RetryLadder 'korean-rice-cakes' returned
  # ELEVEN rungs, ten of them character mutilations ('kore an-rice-cakes' ... 'korean-rice-c akes'),
  # because the term carries no space and the compound splitter fired at every position >= 4. Every
  # rung is a real network call: 11 x 2 server stores x ~25 s is up to nine minutes for ONE term.
  $l = L 'korean-rice-cakes'
  if (-not (Has $l 'korean rice cakes')) { Write-Output "  X B4: the hyphen-to-space swap is not a rung -> $($l -join ', ')"; $bad++ }
  if ($l.Count -gt 3) { Write-Output "  X B4 MUST FIRE: 'korean-rice-cakes' exploded to $($l.Count) rungs -> $($l -join ', ')"; $bad++ }
  foreach ($r in $l) {
    # WHAT A MUTILATION LOOKS LIKE, said precisely so this can never pass by accident: every one of the
    # ten measured rungs carried a space AND a surviving hyphen ('kore an-rice-cakes'), because the
    # splitter cut INSIDE a word while the term's real separators stayed put. No legitimate rung of a
    # hyphenated term does that - the swap replaces every hyphen, the join removes them all.
    if ($r -match '\s' -and $r -match '-') {
      Write-Output "  X B4 MUST FIRE: a character mutilation survived -> '$r'"; $bad++
    }
  }
  # CLEAN TWIN 1: a GENUINELY single word still splits - that is the rung 'cornmeal' -> 'corn meal'
  # was built for, and it is the half of this behaviour that must not move.
  $l = L 'cornmeal'
  if (-not (Has $l 'corn meal')) { Write-Output "  X B4 CLEAN TWIN: single-word splitting broke -> $($l -join ', ')"; $bad++ }
  if ($l.Count -ne 2) { Write-Output "  X B4 CLEAN TWIN: 'cornmeal' should be exactly 2 rungs -> $($l -join ', ')"; $bad++ }
  # CLEAN TWIN 2: a hyphen now joins exactly as a space does
  $l = L 'corn-meal'
  if (-not (Has $l 'cornmeal') -or -not (Has $l 'corn meal')) { Write-Output "  X B4: 'corn-meal' lost the join or the swap -> $($l -join ', ')"; $bad++ }
  # CLEAN TWIN 3: an underscore is a separator too, and the qualifier strip now reaches through it
  $l = L 'sun_dried_tomatoes'
  if (-not (Has $l 'sun dried tomatoes')) { Write-Output "  X B4: underscores are not word boundaries -> $($l -join ', ')"; $bad++ }
  if ($l.Count -gt 4) { Write-Output "  X B4: an underscored term exploded ($($l.Count) rungs) -> $($l -join ', ')"; $bad++ }
  # CLEAN TWIN 4: a hyphenated TWO-word term gains its head noun, exactly as the spaced form does
  $l = L 'brown-lentils'
  if (-not (Has $l 'lentils')) { Write-Output "  X B4: a hyphenated 2-word term lost its head noun -> $($l -join ', ')"; $bad++ }

  # MUST-FIRE R1: the exact Aldi capture, frozen
  $aldi = 'Skip Navigation 0 fennel View Pricing Policy No results for "fennel" Browse related items or try another search. Related items Current price: $0.95 Parsley, each'
  if (-not (Test-NoResultsPhrase $aldi)) { Write-Output '  X R1: the live Aldi no-results banner was not detected'; $bad++ }
  # CLEAN TWIN: a normal grid must not read as empty
  $ok = 'Search results for cumin. 12 items. Current price: $0.99 Stonemill Ground Cumin 2 oz Many in stock'
  if (Test-NoResultsPhrase $ok) { Write-Output '  X R1 false positive: a normal result grid read as no-results'; $bad++ }
  if (Test-NoResultsPhrase '') { Write-Output '  X empty page text should not read as a no-results banner'; $bad++ }

  # the stopping rule: one hit is never enough (the hair-conditioner case)
  if (Test-LadderSatisfied @(@{ n = 1 })) { Write-Output '  X a single hit satisfied the ladder (the hair-conditioner case)'; $bad++ }
  if (-not (Test-LadderSatisfied @(@{ n = 1 }, @{ n = 2 }))) { Write-Output '  X two hits did not satisfy the ladder'; $bad++ }

  # the verdict object shape
  $v = New-SearchVerdict -State EMPTY -TermUsed 'fennel' -Attempts @(@{ term = 'fennel'; state = 'EMPTY' }) -Reason 'no-results banner'
  if ($v.state -ne 'EMPTY' -or $v.term_used -ne 'fennel' -or @($v.attempts).Count -ne 1) { Write-Output '  X verdict object did not round-trip'; $bad++ }

  if ($bad -eq 0) { Write-Output 'search-verdict-lib SELF-TEST PASS (all four trial mis-rulings laddered; Aldi no-results banner fires; single hit never satisfies; clean twins gain no breadth)'; exit 0 }
  Write-Output ("search-verdict-lib SELF-TEST FAIL ({0} problem(s))" -f $bad); exit 1
}
