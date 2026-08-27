# migrate-prose-tokens.ps1 - the ONE-TIME literal->token rewrite of the catalog's prose money and macros.
#
# WHAT IT DOES. For every spec, in the five reader-prose surfaces (intro_html, portion_html,
# cost_closing_html, upsell_html, head.description), replace each figure that PROVABLY equals the spec's
# own stat with the corresponding token:
#     $3.58            -> ${{cost_ps}}     when 3.58  == stat.cost_ps
#     610 calories     -> {{cal}} calories when 610   == stat.cal
#     57 grams of protein / 57g protein -> {{protein}} ...  when 57 == stat.protein
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

# Tokenize one plain-text field. Returns @{ Text=..; Swaps=..; Left=.. } where Left counts figures that
# LOOK like stat figures but did not qualify (unequal or bounded) - reported, never touched.
function Convert-FieldToTokens { param([string]$Text, [string]$CostPs, [int]$Cal, [int]$Protein)
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

  # calories: a bare integer immediately followed by cal/calories.
  $script:stage = $out
  $out = [regex]::Replace($script:stage, '\b(\d{2,4})(?=\s*calories?\b|\s*cal\b)', {
    param($m)
    if ([int]$m.Groups[1].Value -eq $Cal -and -not (Test-BoundContext -Text $script:stage -MatchIndex $m.Index)) { $script:sw++; return '{{cal}}' }
    return $m.Value   # bounds and non-stat figures stay silently - they are claims, not copies
  })

  # protein: integer followed by g/grams (of) protein.
  $script:stage = $out
  $out = [regex]::Replace($script:stage, '\b(\d{1,3})(?=\s*g(?:rams)?\s*(?:of\s*)?protein\b)', {
    param($m)
    if ([int]$m.Groups[1].Value -eq $Protein -and -not (Test-BoundContext -Text $script:stage -MatchIndex $m.Index)) { $script:sw++; return '{{protein}}' }
    return $m.Value
  })
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

function Invoke-FieldTokenize { param([string]$Text, [string]$CostPs, [int]$Cal, [int]$Protein)
  $script:sw = 0; $script:lf = @()
  $r = Convert-FieldToTokens -Text $Text -CostPs $CostPs -Cal $Cal -Protein $Protein
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

  $edits = @{}
  foreach ($k in $FIELDS) {
    $cur = if ($k -eq 'description') { [string]$spec.head.description } else { [string]$spec.$k }
    if (-not $cur) { continue }
    $r = Invoke-FieldTokenize -Text $cur -CostPs $cps -Cal $cal -Protein $pro
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
