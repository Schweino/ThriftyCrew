# migrate-prose-tokens.ps1 - the ONE-TIME literal->token rewrite of the catalog's prose money and macros.
#
# WHAT IT DOES. For every spec, in the five reader-prose surfaces (intro_html, portion_html,
# cost_closing_html, upsell_html, head.description), replace each figure that PROVABLY equals the spec's
# own stat with the corresponding token:
#     $3.58            -> ${{cost_ps}}     when 3.58  == stat.cost_ps
#     610 calories     -> {{cal}} calories when 610   == stat.cal
#     57 grams of protein / 57g protein -> {{protein}} ...  when 57 == stat.protein
#     40 grams of carbs -> {{carbs}} ...   when 40    == stat.carbs   (added 2026-09-01)
#     10 grams of fat   -> {{fat}} ...     when 10    == stat.fat     (added 2026-09-01)
#
# CARBS AND FAT WERE ADDED LAST AND THAT IS WHY THEY DRIFTED. lib\render-tokens.ps1 grew {{carbs}} and
# {{fat}} on 2026-08-31 and nothing swept the literals behind them, so three live cards spent a day
# stating a fat number that was not theirs: bbq-chicken-rice-bowls said "just 4 grams of fat" on a
# 10 g stat, hot-honey-chicken-bowls said 3 on a 10, ground-beef-gyro-bowls said 11 on a 13. A token
# that exists but that no migration reaches is a token nobody uses.
# lib\render-tokens.ps1 substitutes them back at render, so the rewrite is a NO-OP on every built card -
# and that is the acceptance test: rebuild the catalog and byte-compare against the pre-migration baseline.
#
# WHY THE EQUALITY GATE MAKES THIS SAFE. The estate's own gates prove the invariant today: reanchor-all's
# verify reports 0 prose/stat money disagreements across 542 specs, and the contradiction gate holds for
# exact macro figures. A literal that equals the stat IS the stat, written down; swapping it for a
# reference loses nothing. A literal that does NOT equal the stat is left alone and reported - it is either
# a bound, a different quantity, or a defect, and all three deserve eyes, not a sweep.
#
# BOUNDS ARE NEVER TOKENIZED, even when numerically equal. buffalo-chicken-burrito says "under 357
# calories" and its stat IS 357 - tokenize that and the promise silently rewrites itself the day the stat
# moves to 360, which is the exact corruption the 2026-08-07 prose disaster produced. A figure preceded
# (within 26 chars) by under/below/beneath/less than/fewer than/no more than/at most stays a literal; the
# bounded-claim gate keeps checking its truth.
#
# Read-only unless -Apply.  Usage: .\migrate-prose-tokens.ps1 [-Slugs a,b] [-Apply] | -SelfTest
param([string[]]$Slugs, [switch]$Apply, [switch]$SelfTest, [string]$Root = "")
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = if ($Root) { $Root } else { Split-Path -Parent $here }
# CAPTURE THE SWITCHES BEFORE DOT-SOURCING ANY LIB. A dot-sourced script executes in THIS scope, and its
# own param() block binds its parameters HERE - so lib\spec-edit.ps1's param([switch]$SelfTest), invoked
# with no arguments, silently reset this script's $SelfTest to FALSE. The first -SelfTest run of this
# migration therefore executed the LIVE dry-run path instead of its fixtures. PS 5.1 trap; now on the list.
$runSelfTest = [bool]$SelfTest; $runApply = [bool]$Apply
. (Join-Path $mp 'lib\spec-edit.ps1')

$script:RX_BOUND = '(?i)\b(?:under|below|beneath|less\s+than|fewer\s+than|no\s+more\s+than|at\s+most)\s*$'

function Test-BoundContext { param([string]$Text, [int]$MatchIndex)
  $start = [Math]::Max(0, $MatchIndex - 26)
  return ([regex]::IsMatch($Text.Substring($start, $MatchIndex - $start), $script:RX_BOUND))
}

# A BOUND CAN SIT ON EITHER SIDE OF THE NUMBER, and this catalog writes both. The leading form is
# "with under 20 grams of carbs"; the TRAILING form is "with 15 grams of carbs or less", which is the
# keto sentence - hatch-green-chile-chicken-casserole and keto-cheeseburger-skillet both carry it.
# In both of those the figure EQUALS the stat, so the equality gate above would have tokenized a
# deliberate promise into a live-tracking number: the day the stat moved to 22 the card would read
# "22 grams of carbs or less", a claim nobody wrote. That is precisely the corruption the leading-bound
# rule exists to prevent, arriving through the side door because the rule only looked left.
# Measured 2026-09-01 before this was added: 4 occurrences across 2 specs, every one of them a bound.
#
# The window stops at the first sentence end so a bound belonging to the NEXT sentence cannot reach
# back and silently exempt this one - the mirror of the 24-char lookback the leading form uses.
$script:RX_BOUND_TRAIL = '(?i)\bor\s+(?:less|fewer|under|below)\b'

function Test-TrailingBoundContext { param([string]$Text, [int]$MatchIndex, [int]$MatchLength)
  $from = $MatchIndex + $MatchLength
  if ($from -ge $Text.Length) { return $false }
  $tail = $Text.Substring($from, [Math]::Min(30, $Text.Length - $from))
  $dot  = $tail.IndexOf('.')
  if ($dot -ge 0) { $tail = $tail.Substring(0, $dot) }
  return ([regex]::IsMatch($tail, $script:RX_BOUND_TRAIL))
}

function Convert-MacroPass {
  <#
    ONE macro pass, shared by cal/protein/carbs/fat. It is a function rather than four near-identical
    [regex]::Replace blocks because this estate's most productive bug source is a rule written down
    twice - and the decimal fix below is exactly the kind of tightening that would have reached one
    copy and not the other three.

    A DECIMAL IS NEVER A COPY OF THE STAT, so it is left alone. "42.4 grams of protein" carries a
    precision {{protein}} cannot express (the token renders the rounded 42), so tokenizing it would
    CHANGE the rendered page - the one thing this migration promises never to do.

    AND THE OLD PATTERN COULD NOT EVEN SEE THAT. It was `\b(\d{1,3})`, whose \b sits happily between
    the '.' and the '4' of "42.4", so it captured "4" and the lookahead still matched " grams of
    protein". On a spec whose stat.protein was 4 that swap would have written "42.{{protein}} grams",
    i.e. "42.4" -> "42.4" only by luck and "42.4" -> "42.{{protein}}" in fact. The (?<![\d.]) guard is
    the same one spec-contradiction-lib carries for the same reason, and the capture takes the WHOLE
    decimal rather than exempting it so the "is this a copy" question is asked about the real figure.
  #>
  param([string]$Text, [string]$Pattern, [int]$Stat, [string]$Token)
  return [regex]::Replace($Text, $Pattern, {
    param($m)
    $lit = $m.Groups[1].Value
    if ($lit -match '\.') { return $m.Value }
    if ([int]$lit -ne $Stat) { return $m.Value }
    # The bound checks read $Text - THIS pass's own parameter - and not the $script:stage the caller
    # happens to have set. Both hold the same string today, but reading a script-scoped variable that a
    # caller is trusted to have updated first is the exact shape of the bug the three-passes comment
    # above describes: a regex checked against the wrong text.
    if (Test-BoundContext -Text $Text -MatchIndex $m.Index) { return $m.Value }
    if (Test-TrailingBoundContext -Text $Text -MatchIndex $m.Index -MatchLength $m.Length) { return $m.Value }
    $script:sw++
    return $Token
  })
}

# Tokenize one plain-text field. Returns @{ Text=..; Swaps=..; Left=.. } where Left counts figures that
# LOOK like stat figures but did not qualify (unequal or bounded) - reported, never touched.
function Convert-FieldToTokens { param([string]$Text, [string]$CostPs, [int]$Cal, [int]$Protein, $Carbs = $null, $Fat = $null)
  if ([string]::IsNullOrEmpty($Text)) { return @{ Text = $Text; Swaps = 0; Left = @() } }

  # THREE PASSES, and each pass's bound-context check reads the string THAT PASS is scanning. An earlier
  # draft checked context against the original text in every pass - but the money pass changes the string
  # length ("$3.58" -> "${{cost_ps}}"), so by the calorie pass every match index pointed 7+ chars off in
  # the original, and the bound guard was reading the wrong window. The bug class this migration exists to
  # end (regex against the wrong text) almost shipped inside the migration itself.

  # money: every $N.NN literal. Equal + unbounded -> token; anything else -> reported for eyes.
  $script:stage = $Text
  $out = [regex]::Replace($script:stage, '\$(\d+\.\d{2})', {
    param($m)
    if ($m.Groups[1].Value -eq $CostPs -and -not (Test-BoundContext -Text $script:stage -MatchIndex $m.Index)) { $script:sw++; return '${{cost_ps}}' }
    $script:lf += ('$' + $m.Groups[1].Value); return $m.Value
  })

  # Bounds and non-stat figures stay silently in every macro pass - they are claims, not copies.

  # calories: a bare integer immediately followed by cal/calories.
  $script:stage = $out
  $out = Convert-MacroPass -Text $script:stage -Stat $Cal -Token '{{cal}}' `
           -Pattern '(?<![\d.])(\d{2,4}(?:\.\d+)?)(?=\s*calories?\b|\s*cal\b)'

  # protein: integer followed by g/grams (of) protein.
  $script:stage = $out
  $out = Convert-MacroPass -Text $script:stage -Stat $Protein -Token '{{protein}}' `
           -Pattern '(?<![\d.])(\d{1,3}(?:\.\d+)?)(?=\s*g(?:rams)?\s*(?:of\s*)?protein\b)'

  # carbs / fat: only when this spec actually HAS the stat. Writing {{carbs}} against a spec with no
  # stat.carbs does not render a blank, it THROWS at the render boundary (render-tokens refuses to
  # print a hole), so a missing stat must skip the pass rather than mint a token nothing can expand.
  if ($null -ne $Carbs) {
    $script:stage = $out
    $out = Convert-MacroPass -Text $script:stage -Stat ([int]$Carbs) -Token '{{carbs}}' `
             -Pattern '(?<![\d.])(\d{1,3}(?:\.\d+)?)(?=\s*g(?:rams)?\s*(?:of\s*)?(?:carbs?|carbohydrates?)\b)'
  }
  if ($null -ne $Fat) {
    $script:stage = $out
    $out = Convert-MacroPass -Text $script:stage -Stat ([int]$Fat) -Token '{{fat}}' `
             -Pattern '(?<![\d.])(\d{1,3}(?:\.\d+)?)(?=\s*g(?:rams)?\s*(?:of\s*)?fat\b)'
  }
  return @{ Text = $out; Swaps = 0; Left = @() }   # counts live in $script:sw / $script:lf (see NOTE below)
}
# NOTE on $script:sw / $script:lf: [regex]::Replace evaluators cannot write a local of the enclosing
# function in PS 5.1 (dynamic scoping reads work; writes create a NEW variable in the evaluator's scope and
# vanish). Script-scoped accumulators are the one reliable channel; reset around each call below.
function Test-TokenSwapIsNoOp {
  <#
    DID TOKENIZING CHANGE ANYTHING A READER WILL SEE? Returns $null when the swap is a pure no-op,
    and the offending RENDERED text when it is not.

    IT LIVES IN A FUNCTION SO A FIXTURE CAN REACH IT. The proof used to be two inline lines in the
    live run, which -SelfTest never executes - so when the comparison basis was wrong, every case
    passed and a real publish paid for it. Neutering the basis back to its old form left the suite
    green, which is how it got there in the first place.

    THE BASIS, AND WHY IT IS THIS ONE. Comparing Expand(after) to the SOURCE assumes the source was
    entirely literal. It is not: the writer writes `${{cost_ps}}` itself and all 574 live specs carry
    that token, so a field that also holds a swappable literal expands two tokens on one side and
    none on the other. Expand(before) == Expand(after) is the invariant that was always meant, and on
    a fully literal original it reduces to the old check exactly.
  #>
  param([string]$Before, [string]$After, $Spec)
  $bOld = Expand-SpecTokens -Text $Before -Spec $Spec
  $bNew = Expand-SpecTokens -Text $After  -Spec $Spec
  if ($bNew -eq $bOld) { return $null }
  return $bNew
}

function Invoke-FieldTokenize { param([string]$Text, [string]$CostPs, [int]$Cal, [int]$Protein, $Carbs = $null, $Fat = $null)
  $script:sw = 0; $script:lf = @()
  $r = Convert-FieldToTokens -Text $Text -CostPs $CostPs -Cal $Cal -Protein $Protein -Carbs $Carbs -Fat $Fat
  return @{ Text = $r.Text; Swaps = $script:sw; Left = $script:lf }
}

$FIELDS = @('intro_html','portion_html','cost_closing_html','upsell_html','description')

if ($runSelfTest) {
  $f = 0
  function T($m, $c, $g) { if ($c) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $g); $script:f++ } }

  # the founding shapes, frozen
  $r = Invoke-FieldTokenize 'Every bowl lands near 460 calories with 38 grams of protein, at roughly $5.76 a bowl.' '5.76' 460 38
  T 'exact stat figures become tokens (money, cal, protein)' `
    ($r.Text -eq 'Every bowl lands near {{cal}} calories with {{protein}} grams of protein, at roughly ${{cost_ps}} a bowl.') $r.Text

  # MUST NOT FIRE: the buffalo-chicken case - a bound EQUAL to the stat stays a literal.
  $r2 = Invoke-FieldTokenize 'Comes in under 357 calories.' '9.99' 357 30
  T 'MUST NOT FIRE a bound equal to the stat is NEVER tokenized (buffalo-chicken 357)' ($r2.Text -eq 'Comes in under 357 calories.') $r2.Text

  # MUST NOT FIRE: a figure that does not equal the stat is left and money is reported.
  $r3 = Invoke-FieldTokenize 'was $2.00 a bowl' '3.58' 610 57
  T 'MUST NOT FIRE an unequal money figure stays, and is REPORTED for eyes' ($r3.Text -eq 'was $2.00 a bowl' -and $r3.Left -contains '$2.00') "$($r3.Text) / left=$($r3.Left -join ',')"

  # membership prices carry no decimals and are untouched by the money regex at all.
  $r4 = Invoke-FieldTokenize 'all for $1 a month' '3.58' 610 57
  T 'CLEAN TWIN "$1 a month" (no decimals) is untouched' ($r4.Text -eq 'all for $1 a month') $r4.Text

  # "57g protein" (no space) and "57 grams of protein" both tokenize.
  $r5 = Invoke-FieldTokenize '57g protein and later 57 grams of protein' '1.00' 500 57
  T 'both protein spellings tokenize' ($r5.Text -eq '{{protein}}g protein and later {{protein}} grams of protein') $r5.Text

  # ---- CARBS AND FAT (2026-09-01) ------------------------------------------------------------------
  $rF = Invoke-FieldTokenize 'lands near 435 calories with 34 grams of protein at 10 grams of fat' '2.00' 435 34 50 10
  T 'carbs/fat pass: a fat figure equal to the stat becomes {{fat}}' `
    ($rF.Text -eq 'lands near {{cal}} calories with {{protein}} grams of protein at {{fat}} grams of fat') $rF.Text
  $rC = Invoke-FieldTokenize 'a serving with 40 grams of carbs and 24 g fat' '2.00' 435 34 40 24
  T 'carbs/fat pass: "40 grams of carbs" and "24 g fat" both tokenize' `
    ($rC.Text -eq 'a serving with {{carbs}} grams of carbs and {{fat}} g fat') $rC.Text
  # MUST NOT FIRE: the founding defect. A fat figure that is NOT the stat is a defect for a human to
  # read, never a copy to swap - swapping it would have silently "fixed" bbq-chicken-rice-bowls' false
  # 4 g into a true 10 g and buried the fact that a card had been lying about a nutrition number.
  $rFbad = Invoke-FieldTokenize 'the leanest bowl at just 4 grams of fat' '2.00' 435 34 50 10
  T 'MUST NOT FIRE a fat figure UNEQUAL to the stat is left alone (bbq-chicken-rice-bowls 4 vs 10)' `
    ($rFbad.Text -eq 'the leanest bowl at just 4 grams of fat' -and $rFbad.Swaps -eq 0) $rFbad.Text
  # MUST NOT FIRE: a spec with no carbs/fat stat must not mint a token nothing can expand.
  $rNo = Invoke-FieldTokenize 'with 40 grams of carbs and 10 grams of fat' '2.00' 435 34 $null $null
  T 'MUST NOT FIRE with no carbs/fat stat the passes are skipped, not run against zero' `
    ($rNo.Text -eq 'with 40 grams of carbs and 10 grams of fat' -and $rNo.Swaps -eq 0) $rNo.Text

  # ---- TRAILING BOUNDS (2026-09-01) ----------------------------------------------------------------
  # The keto sentence, frozen from hatch-green-chile-chicken-casserole and keto-cheeseburger-skillet:
  # the figure EQUALS the stat, so only the trailing-bound reading stops it being tokenized.
  $rT = Invoke-FieldTokenize 'a serving, with 15 grams of carbs or less.' '2.00' 435 34 15 10
  T 'MUST NOT FIRE a TRAILING bound "15 grams of carbs or less" equal to the stat stays a literal' `
    ($rT.Text -eq 'a serving, with 15 grams of carbs or less.' -and $rT.Swaps -eq 0) $rT.Text
  $rT2 = Invoke-FieldTokenize 'with 6 grams of carbs or fewer' '2.00' 435 34 6 10
  T 'MUST NOT FIRE "or fewer" is the same bound' ($rT2.Text -eq 'with 6 grams of carbs or fewer' -and $rT2.Swaps -eq 0) $rT2.Text
  # CLEAN TWIN: a bound in the NEXT sentence must not reach back and exempt this figure.
  $rT3 = Invoke-FieldTokenize 'with 15 grams of carbs. Buy two or less.' '2.00' 435 34 15 10
  T 'CLEAN TWIN a bound after the sentence end does NOT exempt the figure - it still tokenizes' `
    ($rT3.Text -eq 'with {{carbs}} grams of carbs. Buy two or less.') $rT3.Text
  # CLEAN TWIN: the LEADING bound still works for the new macros too.
  $rT4 = Invoke-FieldTokenize 'with under 20 grams of carbs' '2.00' 435 34 20 10
  T 'CLEAN TWIN a LEADING bound equal to the stat is still never tokenized, carbs included' `
    ($rT4.Text -eq 'with under 20 grams of carbs' -and $rT4.Swaps -eq 0) $rT4.Text

  # ---- THE DECIMAL, which the old \b pattern read as a FRAGMENT (2026-09-01) ------------------------
  # `\b(\d{1,3})` sits between the '.' and the '4' of "42.4 grams of protein" and captures "4". On a
  # spec whose stat.protein is 4 the old code wrote "42.{{protein}} grams of protein", which renders
  # "42.4" today and whatever the stat becomes tomorrow, from a sentence nobody edited.
  $rD1 = Invoke-FieldTokenize 'packs 42.4 grams of protein' '2.00' 435 4 50 10
  T 'MUST NOT FIRE "42.4 grams of protein" is never read as the "4" the old pattern captured' `
    ($rD1.Text -eq 'packs 42.4 grams of protein' -and $rD1.Swaps -eq 0) $rD1.Text
  # ...and a decimal that ROUNDS to the stat is still not a copy of it: the token renders 42, the page
  # says 42.4, so tokenizing would change what a reader sees. Left alone, deliberately.
  $rD2 = Invoke-FieldTokenize 'packs 42.4 grams of protein' '2.00' 435 42 50 10
  T 'MUST NOT FIRE a decimal that rounds to the stat is still left alone (the token cannot say .4)' `
    ($rD2.Text -eq 'packs 42.4 grams of protein' -and $rD2.Swaps -eq 0) $rD2.Text
  $rD3 = Invoke-FieldTokenize 'a 8.5 g fat serving' '2.00' 435 34 50 8
  T 'MUST NOT FIRE "8.5 g fat" is not the "5" a leading \b would have captured' `
    ($rD3.Text -eq 'a 8.5 g fat serving' -and $rD3.Swaps -eq 0) $rD3.Text
  # CLEAN TWIN: whole numbers still tokenize, so the decimal guard did not blind the migration.
  $rD4 = Invoke-FieldTokenize 'packs 42 grams of protein' '2.00' 435 42 50 10
  T 'CLEAN TWIN a WHOLE-NUMBER protein figure still tokenizes - the guard did not switch the pass off' `
    ($rD4.Text -eq 'packs {{protein}} grams of protein') $rD4.Text

  # idempotence: running over already-tokenized text changes nothing.
  $r6 = Invoke-FieldTokenize 'near {{cal}} calories at ${{cost_ps}} a bowl' '3.58' 610 57
  T 'idempotent over already-tokenized text' ($r6.Text -eq 'near {{cal}} calories at ${{cost_ps}} a bowl' -and $r6.Swaps -eq 0) $r6.Text

  # ---- THE HALF-TOKENIZED FIELD, which is the shape the live writer actually produces. ------------
  # The idempotence case above has NOTHING left to swap, so it never reaches the round-trip proof.
  # This one does: the text already carries ${{cost_ps}} (the house convention, in all 574 live
  # specs) AND a literal "52 grams of protein" for the tokenizer to take. Under the old
  # Expand(after) -ne $original proof this refused, and it cost a real publish.
  . (Join-Path $mp 'lib\render-tokens.ps1')
  $specFx = [pscustomobject]@{ stat = [pscustomobject]@{ cost_ps = '4.04'; cal = 561; protein = 52 } }
  $mixed  = 'comes out to ${{cost_ps}} per serving, with 52 grams of protein'
  $rMix   = Invoke-FieldTokenize $mixed '4.04' 561 52
  T 'the literal is tokenized even though the field already holds a token' `
    ($rMix.Text -eq 'comes out to ${{cost_ps}} per serving, with {{protein}} grams of protein') $rMix.Text
  $bNew = Expand-SpecTokens -Text $rMix.Text -Spec $specFx
  $bOld = Expand-SpecTokens -Text $mixed     -Spec $specFx
  T 'MUST FIRE  a half-tokenized field round-trips: rendered-before equals rendered-after' `
    ($bNew -eq $bOld) ("before='" + $bOld + "' after='" + $bNew + "'")
  T '  and the OLD proof really would have refused it, so this case is not decorative' `
    ($bNew -ne $mixed) ("expanded='" + $bNew + "' original='" + $mixed + "'")
  # ...AND THROUGH THE FUNCTION THE LIVE RUN ACTUALLY CALLS, which is the part the fixtures kept
  # missing: three separate neuters of a comparison basis left this suite green because every case
  # re-implemented the comparison instead of calling it.
  T 'MUST FIRE  the live proof passes the half-tokenized field - the exact refusal that cost a publish' `
    ($null -eq (Test-TokenSwapIsNoOp -Before $mixed -After $rMix.Text -Spec $specFx)) `
    ([string](Test-TokenSwapIsNoOp -Before $mixed -After $rMix.Text -Spec $specFx))
  $badSpecFx = [pscustomobject]@{ stat = [pscustomobject]@{ cost_ps = '9.99'; cal = 561; protein = 52 } }
  T 'CLEAN TWIN the live proof still REFUSES a swap that lands a different number' `
    ($null -ne (Test-TokenSwapIsNoOp -Before 'costs $4.04 a serving' -After 'costs ${{cost_ps}} a serving' -Spec $badSpecFx)) `
    ([string](Test-TokenSwapIsNoOp -Before 'costs $4.04 a serving' -After 'costs ${{cost_ps}} a serving' -Spec $badSpecFx))
  # CLEAN TWIN. The guard must still catch a swap that changes what a reader sees.
  $badSpec = [pscustomobject]@{ stat = [pscustomobject]@{ cost_ps = '9.99'; cal = 561; protein = 52 } }
  $bBad = Expand-SpecTokens -Text 'costs ${{cost_ps}} a serving' -Spec $badSpec
  T 'CLEAN TWIN rendering still substitutes the stat, so a swap landing a DIFFERENT number is caught' `
    ($bBad -eq 'costs $9.99 a serving') $bBad

  if ($f -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $f case(s)"; exit 1 }
}

# ---- live run --------------------------------------------------------------------------------------------
. (Join-Path $mp 'lib\render-tokens.ps1')   # (safe here: $runSelfTest already captured)
$files = @(Get-ChildItem (Join-Path $mp 'db\recipes\*.json'))
if ($Slugs) { $files = @($files | Where-Object { $Slugs -contains $_.BaseName }) }

$changed = 0; $totalSwaps = 0; $leftReport = @()
foreach ($file in $files) {
  $raw = [IO.File]::ReadAllText($file.FullName)
  $spec = $raw | ConvertFrom-Json
  $cps = [string]$spec.stat.cost_ps; $cal = [int]$spec.stat.cal; $pro = [int]$spec.stat.protein
  if (-not $cps) { continue }
  # $null when the spec has no such stat, which SKIPS that pass. PS 5.1 trap: [int]$null is 0, so
  # reading these with a cast would turn "no carbs stat" into "a carbs stat of 0" and any prose
  # saying "0 grams of carbs" would tokenize against a stat that does not exist.
  $carb = if ($null -ne $spec.stat.carbs) { [int]$spec.stat.carbs } else { $null }
  $fat  = if ($null -ne $spec.stat.fat)   { [int]$spec.stat.fat }   else { $null }

  $edits = @{}
  foreach ($k in $FIELDS) {
    $cur = if ($k -eq 'description') { [string]$spec.head.description } else { [string]$spec.$k }
    if (-not $cur) { continue }
    $r = Invoke-FieldTokenize -Text $cur -CostPs $cps -Cal $cal -Protein $pro -Carbs $carb -Fat $fat
    foreach ($l in $r.Left) { $leftReport += ('{0} {1} still holds {2} (stat says ${3})' -f $file.BaseName, $k, $l, $cps) }
    if ($r.Swaps -gt 0 -and $r.Text -ne $cur) {
      # PROOF OF NO-OP before anything is written: expanding the tokenized text against this spec's own
      # stat must reproduce the original byte-for-byte. If it cannot, the swap was not a pure copy.
      # COMPARE RENDERED AGAINST RENDERED, NOT RENDERED AGAINST SOURCE (fixed 2026-08-27).
      #
      # This proof used to be `Expand(tokenized) -ne $cur`, which silently assumed the ORIGINAL text
      # was entirely literal. It is not, and the house convention is why: the writer writes
      # `${{cost_ps}}` itself - all 574 live specs carry that token in cost_closing_html - so a field
      # that ALSO contains a swappable literal ("52 grams of protein") expands BOTH tokens on the left
      # of the comparison and neither on the right. The check then refuses a perfectly correct swap.
      # It cost mediterranean-chicken-w-marinade a publish: "token round-trip does not reproduce the
      # original", on a field whose only sin was already being half-tokenized.
      #
      # THE INVARIANT WAS NEVER "the tokenized text expands to the source string". It is "tokenizing
      # changed nothing a READER will see", and that is exactly Expand(before) == Expand(after). On a
      # fully literal original Expand(before) IS the original, so every case this guard used to catch
      # it still catches - including the one it exists for, a swap that lands a different number.
      #
      # THE SELF-TEST'S IDEMPOTENCE CASE DID NOT COVER THIS, and that is worth naming: its text is
      # already tokenized and has no literal left to swap, so Swaps is 0 and this branch never runs.
      # A guard needs a fixture that reaches IT, not one that merely resembles the situation.
      $backBad = Test-TokenSwapIsNoOp -Before $cur -After $r.Text -Spec $spec
      if ($backBad) { throw ("{0}/{1}: token round-trip does not reproduce the original - refusing (got '{2}')" -f $file.BaseName, $k, $backBad) }
      $edits[$k] = $r.Text
      $totalSwaps += $r.Swaps
    }
  }
  if (-not $edits.Count) { continue }
  $changed++
  if ($runApply) { Set-SpecFields -Path $file.FullName -Edits $edits }
}

Write-Output ("{0} spec(s) tokenized, {1} literal(s) swapped{2}" -f $changed, $totalSwaps, $(if ($runApply) { ' - APPLIED' } else { ' (dry run - pass -Apply)' }))
if ($leftReport.Count) {
  Write-Output ("{0} money literal(s) left un-tokenized (unequal to stat - bounds, batch totals, or defects):" -f $leftReport.Count)
  $leftReport | Select-Object -First 25 | ForEach-Object { Write-Output ("    " + $_) }
}
exit 0
