<#
  audit-fact-claims.ps1 - the Fact Check List, on the correct side of the publish.

  WHY THIS EXISTS (2026-09-06, backlog E6). The estate already checks every number a card asserts:
  costs reconcile to costed.json, macros recompute from the food DB, scaling ratios and prose numbers
  are covered by coverage_check.py, and since CHANGE W the writer cannot compute a number at all - the
  figures arrive locked in its dispatch, so the prose-number defect class dies by construction.

  WHAT NOTHING CHECKS IS THE PROSE'S NON-NUMERIC ASSERTIONS. A card can say "this freezes for three
  months", "Aldi carries this year-round", or "thighs are cheaper than breasts" and every existing
  audit passes it, because none of those is a number from the pipeline. They are claims the writer made
  on its OWN authority, on a live paid site, and two of the three classes have a system of record in
  this estate that the prose is quietly bypassing:

    STORAGE / FOOD SAFETY   "keeps 5 days", "freezes up to 3 months". A wrong one is a health claim.
    STORE CARRIAGE          "Aldi always has it". The estate proves carriage from store evidence in
                            grocery\carriage.json and REFUSES to publish a recipe whose ingredient has
                            none. Prose asserting it in words routes around that entire mechanism.
    COMPARATIVE PRICE       "cheaper than", "half the price of". A price claim with no board behind it.

  THE PATTERN, from prompt-craft: ask the generator for the claims that would undermine its own output,
  then diff that list against the prose. Both directions matter and the second is the one that pays:

    forward   a declared claim whose content appears nowhere in the prose - the writer listed something
              it did not actually say, so the list is decoration
    inverse   a RISK ASSERTION IN THE PROSE THAT THE WRITER DID NOT DECLARE. That is an undeclared
              claim, and it is the whole point of the check.

  RATCHET, NOT A HARD FAIL. 584 specs predate `fact_claims` and would all be red on day one, which
  run-gates' own header explains is worse than no gate: it teaches people to ignore red. The baseline
  is a high-water mark of UNDECLARED risk assertions and may only go DOWN.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 hard finding, 3 could-not-evaluate.
  Read the verdict LINE, not the number (backlog E2).

  Self-test: powershell -File meal-prep\pipeline\audit-fact-claims.ps1 -SelfTest
#>
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\meal-prep\pipeline' }
$repo = Split-Path (Split-Path $here -Parent) -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

$SPEC_DIR      = Join-Path $repo 'meal-prep\db\recipes'
$BASELINE_FILE = Join-Path $repo 'meal-prep\db\fact-claims-baseline.json'

# THE SEVEN STORES, so a carriage assertion is recognised by the store it names rather than by a verb.
$STORES = @('aldi', 'walmart', 'hy-vee', 'hyvee', 'family fare', 'familyfare', 'fareway', "baker's", 'bakers', "sam's club", 'sams club')

function Get-TcRiskAssertions {
  <# Pure. Returns the sentences in $Prose that assert something on the writer's own authority in one
     of the three classes above.

     DELIBERATELY NARROW. A detector that flagged every sentence with a number, or every mention of a
     store, would fire on almost every card and be switched off within a week - and the assertions that
     matter would be lost in it. Each pattern below needs an ASSERTION, not just a topic word: a recipe
     that says "serve with rice" mentions no store, and "12 servings" is a pipeline number, and neither
     is a claim anyone has to stand behind. #>
  param([string]$Prose)
  $out = @()
  if (-not $Prose) { return ,@($out) }
  # strip tags so a claim split across markup is still one sentence
  $text = [regex]::Replace($Prose, '<[^>]+>', ' ')
  $text = [regex]::Replace($text, '\s+', ' ')
  foreach ($s in ([regex]::Split($text, '(?<=[.!?])\s+'))) {
    $sent = $s.Trim()
    if (-not $sent) { continue }
    $l = $sent.ToLower()

    # 1. STORAGE / FOOD SAFETY: a duration attached to keeping, freezing or reheating.
    if ($l -match '\b(keeps?|keep|last[s]?|fridge|refrigerat\w*|freez\w*|thaw\w*|reheat\w*)\b' -and
        $l -match '\b\d+\s*(day|days|week|weeks|month|months|hour|hours)\b') {
      $out += [pscustomobject]@{ Class = 'storage'; Sentence = $sent }; continue
    }
    # 2. STORE CARRIAGE: a named store plus an availability assertion.
    $hasStore = $false
    foreach ($st in $STORES) { if ($l -match [regex]::Escape($st)) { $hasStore = $true; break } }
    if ($hasStore -and $l -match '\b(always|year.round|every week|reliably|usually (has|have|carr)|carries|carry|stocks?|in stock|never out)\b') {
      $out += [pscustomobject]@{ Class = 'carriage'; Sentence = $sent }; continue
    }
    # 3. COMPARATIVE PRICE: a price comparison the board did not make.
    if ($l -match '\b(cheaper|less expensive|costs? less|half the price|better value|beats? the price|undercuts?)\b') {
      $out += [pscustomobject]@{ Class = 'price-compare'; Sentence = $sent }; continue
    }
  }
  # `,@()` - a single finding must not unroll to a bare object. CALLERS ASSIGN BEFORE WRAPPING; an
  # inline @(callsite) reads an EMPTY result as one element. Same trap as ops\audit-write-seam.ps1.
  return ,@($out)
}

function Test-TcClaimEchoed {
  <# Is a declared claim actually SAID in the prose? Compares distinctive words - tokens of four or more
     letters, minus a small stop set - rather than the whole string, because a claim is a paraphrase of
     a sentence and never a copy of it. Two thirds of a claim's distinctive words present is the bar. #>
  param([string]$Claim, [string]$Prose)
  if (-not $Claim) { return $true }
  $stop = @('this','that','with','from','have','has','the','and','for','are','will','your','you','its','it','a','of','to','in','is','be','can','keeps','keep')
  $text = ([regex]::Replace($Prose, '<[^>]+>', ' ')).ToLower()
  $words = @([regex]::Matches($Claim.ToLower(), '[a-z]{4,}') | ForEach-Object { $_.Value } | Where-Object { $stop -notcontains $_ } | Sort-Object -Unique)
  if (-not $words.Count) { return $true }
  $hit = @($words | Where-Object { $text -match [regex]::Escape($_) }).Count
  return (($hit / [double]$words.Count) -ge 0.66)
}

function Get-TcSpecFactProblems {
  <# Both directions of the diff for ONE spec. Pure - the self-test drives it with synthetic specs. #>
  param([string]$Slug, [string]$Prose, [string[]]$Claims)
  $p = @()
  $declared = @($Claims | Where-Object { $_ -and $_.Trim() })
  foreach ($c in $declared) {
    if (-not (Test-TcClaimEchoed -Claim $c -Prose $Prose)) {
      $p += [pscustomobject]@{ Slug = $Slug; Kind = 'declared-not-said'; Detail = $c }
    }
  }
  $risks = Get-TcRiskAssertions -Prose $Prose
  foreach ($r in @($risks)) {
    $covered = $false
    foreach ($c in $declared) { if (Test-TcClaimEchoed -Claim $c -Prose $r.Sentence) { $covered = $true; break } }
    if (-not $covered) {
      $p += [pscustomobject]@{ Slug = $Slug; Kind = ('undeclared-' + $r.Class); Detail = $r.Sentence }
    }
  }
  return ,@($p)
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0
  function T($m, $cond, $got) { if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }

  # --- the three risk classes must fire
  $r1 = Get-TcRiskAssertions -Prose '<p>Portion it out. It keeps 5 days in the fridge.</p>'
  T 'MUST FIRE  a storage duration is a risk assertion' (@($r1).Count -eq 1 -and $r1[0].Class -eq 'storage') (($r1 | ForEach-Object { $_.Class }) -join ',')
  $r2 = Get-TcRiskAssertions -Prose 'Aldi carries this cut year-round, so you will not be hunting.'
  T 'MUST FIRE  a store carriage assertion is a risk assertion' (@($r2).Count -eq 1 -and $r2[0].Class -eq 'carriage') (($r2 | ForEach-Object { $_.Class }) -join ',')
  $r3 = Get-TcRiskAssertions -Prose 'Thighs are cheaper than breasts and taste better.'
  T 'MUST FIRE  a comparative price claim is a risk assertion' (@($r3).Count -eq 1 -and $r3[0].Class -eq 'price-compare') (($r3 | ForEach-Object { $_.Class }) -join ',')

  # --- CLEAN TWINS. These keep the detector usable; without them it fires on every card.
  $c1 = Get-TcRiskAssertions -Prose 'Makes 14 servings at 42 grams of protein each. Serve with rice.'
  T 'CLEAN TWIN pipeline numbers are not claims' (@($c1).Count -eq 0) (($c1 | ForEach-Object { $_.Sentence }) -join ' | ')
  $c2 = Get-TcRiskAssertions -Prose 'We priced this at Aldi this week.'
  T 'CLEAN TWIN naming a store without an availability assertion is not a carriage claim' (@($c2).Count -eq 0) (($c2 | ForEach-Object { $_.Sentence }) -join ' | ')
  $c3 = Get-TcRiskAssertions -Prose 'Let it cool before you portion it.'
  T 'CLEAN TWIN a storage verb with NO duration is not a claim' (@($c3).Count -eq 0) (($c3 | ForEach-Object { $_.Sentence }) -join ' | ')

  # --- the echo test
  T 'a claim whose words are in the prose is echoed' `
    (Test-TcClaimEchoed -Claim 'keeps five days in the fridge' -Prose 'It keeps five days in the fridge.') 'not echoed'
  T 'MUST FIRE  a claim the prose never makes is NOT echoed' `
    (-not (Test-TcClaimEchoed -Claim 'freezes for three months without loss of texture' -Prose 'It keeps five days in the fridge.')) 'a claim not in the prose read as echoed'

  # --- BOTH DIRECTIONS OF THE DIFF, which is the pattern
  $p1 = Get-TcSpecFactProblems -Slug 'zz' -Prose 'It keeps 5 days in the fridge.' -Claims @('it keeps 5 days in the fridge')
  T 'CLEAN TWIN a declared claim that the prose makes raises nothing' (@($p1).Count -eq 0) (($p1 | ForEach-Object { $_.Kind }) -join ',')

  $p2 = Get-TcSpecFactProblems -Slug 'zz' -Prose 'It keeps 5 days in the fridge.' -Claims @()
  T 'MUST FIRE  INVERSE - a risk assertion the writer did NOT declare is the finding this audit exists for' `
    (@($p2).Count -eq 1 -and $p2[0].Kind -eq 'undeclared-storage') (($p2 | ForEach-Object { $_.Kind }) -join ',')

  $p3 = Get-TcSpecFactProblems -Slug 'zz' -Prose 'Serve with rice.' -Claims @('this freezes for three months')
  T 'MUST FIRE  FORWARD - a declared claim the prose never makes is a decorative list' `
    (@($p3).Count -eq 1 -and $p3[0].Kind -eq 'declared-not-said') (($p3 | ForEach-Object { $_.Kind }) -join ',')

  $p4 = Get-TcSpecFactProblems -Slug 'zz' -Prose 'Serve with rice. Makes 14 servings.' -Claims @()
  T 'CLEAN TWIN a card asserting nothing raises nothing' (@($p4).Count -eq 0) (($p4 | ForEach-Object { $_.Kind }) -join ',')

  T 'MUST FIRE  a single problem comes back as an ARRAY, not unrolled' ($p2 -is [array]) ($p2.GetType().FullName)

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: 3 risk classes, 3 clean twins that keep it usable, the echo test both ways, both directions of the diff, and return arity'
  exit 0
}

# ------------------------------------------------------------------------------------- live run
if (-not (Test-Path -LiteralPath $SPEC_DIR)) {
  Write-Output ("FACT-CLAIMS AUDIT BLIND: the spec directory is missing ({0}). Nothing was checked, so nothing was proven." -f $SPEC_DIR)
  Write-GuardComplete -Name 'fact-claims' -Summary 'blind=no-spec-dir'
  exit 3
}
$specs = @(Get-ChildItem $SPEC_DIR -Filter *.json -File -ErrorAction SilentlyContinue)
if (-not $specs.Count) {
  Write-Output 'FACT-CLAIMS AUDIT BLIND: found zero specs, which means the discovery is broken rather than the catalogue being empty.'
  Write-GuardComplete -Name 'fact-claims' -Summary 'blind=no-specs'
  exit 3
}

$problems = @(); $withClaims = 0; $unreadable = 0
foreach ($s in $specs) {
  try { $doc = (Get-Content $s.FullName -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $unreadable++; continue }
  if (-not $doc) { $unreadable++; continue }
  # PROSE IS FLATTENED IN THE BUILT SPEC. The writer's payload uses `prose.intro_html`; the spec builder
  # lands them at the top level, so this reads the flat names and not a `prose` object that is not there.
  # SOME PROSE FIELDS ARE ARRAYS - make_it is a list of steps - and `[string]$array` renders as the
  # literal text "System.Object[]". The first live run printed exactly that and, far worse, would have
  # written a BASELINE computed over prose it had never read: every claim inside a step list invisible,
  # the high-water mark set too low, and the gate then failing the first card that declared one honestly.
  $prose = (@('intro_html', 'shop_smart', 'make_it', 'portion_html', 'cost_closing_html', 'upsell_html', 'cost_note_html') |
    ForEach-Object {
      $v = $doc.$_
      if ($null -eq $v) { '' } elseif ($v -is [array]) { (@($v) -join ' ') } else { [string]$v }
    }) -join ' '
  $claims = @()
  if ($doc.PSObject.Properties['fact_claims']) { $claims = @($doc.fact_claims | ForEach-Object { [string]$_ }) }
  if ($claims.Count) { $withClaims++ }
  # ASSIGN, THEN WRAP, THEN APPEND ONE AT A TIME. `$problems += @(Get-TcSpecFactProblems ...)` appends
  # the whole comma-wrapped ARRAY as a single element, so $problems ends up a mix of records and arrays
  # and every column prints System.Object[]. Third time this trap has bitten today; the rule is in
  # [[ps-json-array-collapse]] and it is never safe to wrap a function call inline.
  $found = Get-TcSpecFactProblems -Slug ($s.BaseName) -Prose $prose -Claims $claims
  foreach ($x in @($found)) { $problems += $x }
}
$problems = @($problems)
# The ratchet counts UNDECLARED risk assertions. A declared-not-said is a writer defect on a NEW card
# and is reported, but it cannot exist on the 584 legacy specs (they declare nothing), so folding it
# into the high-water mark would let a real one hide under the legacy backlog.
$undeclared = @($problems | Where-Object { $_.Kind -like 'undeclared-*' })
$decorative = @($problems | Where-Object { $_.Kind -eq 'declared-not-said' })
$count = $undeclared.Count

Write-Output ("fact-claims: {0} spec(s), {1} carrying fact_claims, {2} unreadable" -f $specs.Count, $withClaims, $unreadable)
foreach ($p in ($undeclared | Sort-Object Slug | Select-Object -First 15)) {
  Write-Output ("  {0,-22} {1,-22} {2}" -f $p.Slug, $p.Kind, $(if ($p.Detail.Length -gt 90) { $p.Detail.Substring(0, 90) + '...' } else { $p.Detail }))
}
if ($undeclared.Count -gt 15) { Write-Output ("  ... and {0} more" -f ($undeclared.Count - 15)) }

if ($decorative.Count) {
  Write-Output ("FACT-CLAIMS AUDIT FAILED: {0} declared claim(s) appear nowhere in their card's prose. A fact_claims list that does not match the prose is decoration, and it is worse than none - it reads as a check that happened." -f $decorative.Count)
  foreach ($d in ($decorative | Select-Object -First 10)) { Write-Output ("  {0,-22} {1}" -f $d.Slug, $d.Detail) }
  Write-GuardComplete -Name 'fact-claims' -Summary ("decorative={0} undeclared={1}" -f $decorative.Count, $count)
  exit 2
}

if (-not (Test-Path -LiteralPath $BASELINE_FILE)) {
  @{ generated = (Get-Date).ToString('s'); undeclared = $count
     note = 'HIGH-WATER MARK for prose risk assertions no fact_claims list declares. May only go DOWN.' } |
    ConvertTo-Json -Depth 3 | Set-Content $BASELINE_FILE -Encoding UTF8
  Write-Output ("fact-claims: baseline written at {0} undeclared assertion(s). From here the number may only go DOWN." -f $count)
  Write-GuardComplete -Name 'fact-claims' -Summary ("baseline={0}" -f $count)
  exit 0
}
$base = [int]((Get-Content $BASELINE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json).undeclared)
if ($count -gt $base) {
  Write-Output ("FACT-CLAIMS AUDIT FAILED: {0} undeclared risk assertion(s) in card prose, against a baseline of {1}. A NEW claim was published that the writer did not declare and nothing verified - storage durations, store carriage and price comparisons are the three the estate has no other check for." -f $count, $base)
  Write-GuardComplete -Name 'fact-claims' -Summary ("undeclared={0} baseline={1}" -f $count, $base)
  exit 2
}
if ($count -lt $base) {
  @{ generated = (Get-Date).ToString('s'); undeclared = $count
     note = 'HIGH-WATER MARK for prose risk assertions no fact_claims list declares. May only go DOWN.' } |
    ConvertTo-Json -Depth 3 | Set-Content $BASELINE_FILE -Encoding UTF8
  Write-Output ("fact-claims: PASSED and TIGHTENED - {0} undeclared assertion(s), down from {1}. Baseline lowered; it can never rise again." -f $count, $base)
  Write-GuardComplete -Name 'fact-claims' -Summary ("undeclared={0} tightened-from={1}" -f $count, $base)
  exit 0
}
Write-Output ("fact-claims: PASSED - {0} undeclared assertion(s), unchanged from the baseline. These are claims on live cards that no audit verifies; each one declared or removed lowers the mark permanently." -f $count)
Write-GuardComplete -Name 'fact-claims' -Summary ("undeclared={0} baseline={1}" -f $count, $base)
exit 0
