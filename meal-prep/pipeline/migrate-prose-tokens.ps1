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
      $back = Expand-SpecTokens -Text $r.Text -Spec $spec
      if ($back -ne $cur) { throw ("{0}/{1}: token round-trip does not reproduce the original - refusing (got '{2}')" -f $file.BaseName, $k, $back) }
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
