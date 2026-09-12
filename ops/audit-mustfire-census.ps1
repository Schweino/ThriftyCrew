# audit-mustfire-census.ps1 - a must-fire assertion may not quietly leave the tree.
#
# SCOPE OF A CLEAN REPORT: UNSOUND, and it is the more useful direction here. It counts
#   assertions carrying the labels it knows, so a clean report means the LABELLED census did
#   not shrink. A must-fire whose sense lives only in its prose is outside its reach - exactly
#   the limit audit-fixture-vocabulary.ps1 states about itself.
#
# WHY THIS EXISTS (2026-09-06, PLAN-top5-2026-09-06 area 4). The estate's rule is that every guard ships
# with two fixtures: one where it MUST FIRE - and that one is the bug that caused the guard to be written -
# and one where it must stay silent. The whole scheme rests on those lines still being there.
#
# A BROKEN MUST-FIRE ANNOUNCES ITSELF. It flips to FAIL and the suite goes red, which is the design working.
# A DELETED ONE DOES NOT. The suite goes green with fewer cases, the tally moves by one, and nobody counts
# tallies. This estate has already paid for exactly that arithmetic twice:
#
#   [[exit-code-first-tally-second]]   a case was deleted and the run still exited 0
#   [[names-gate-cannot-see-a-lost-flag]]  a suite compared CASES and could not see a lost flag
#
# So: count them per file, and ratchet. A file whose must-fire count DROPS is a hard fail that names the
# file; a file whose count RISES is the estate getting better and is reported so the baseline is retrained.
# The count is deliberately per FILE rather than per case name: case labels are prose and get reworded all
# the time, and a ratchet that fails on a reworded label is a ratchet people delete.
#
# WHAT IT COUNTS. Lines inside a script's self-test body - every body lib\selftest-lib.ps1's Get-SelfTestBlock
# returns: a gated if, the code after a guard-return, an Invoke-*SelfTest function, or a whole test-*.ps1 suite
# (2026-09-11; grocery\test-auditors.ps1 declares no switch at all) - that carry MUST FIRE / MUST-FIRE /
# MUST NOT FIRE in any case, written as SEPARATE words: a run-together identifier ($mustFire, a function
# named for must-fires, a 'mustfire' fixture name) is not counted. That includes the assertion label, which
# is where this estate writes it. It
# does NOT run anything - run-gates already runs every self-test, and this answers the different question
# run-gates cannot: is the same set of must-fires still THERE.
#
# TWO SHAPES THIS FILE ADDS, WHERE THE BODY IS NOT THE WHOLE CASE (2026-09-11, later). Measured over this walk at
# bf0a9bcf8: 8 files of 577 carried 44 labelled lines outside every body the finder returns. THE RUBRIC applied to
# each of the 8: count a line only where DELETING IT WOULD REMOVE A CASE FROM A SUITE SOMETHING RUNS, and where the
# text it sits in cannot also run as production. By that test 31 of the 44 are cases and 13 are not.
#
#   a called fixtures function   a labelled function whose EVERY call site in the walk lies inside an accepted
#                                body, to a fixed point. meal-prep\pipeline\selftest-names-lib.ps1's
#                                Invoke-NamesFixtures is called from hunt-run.ps1 and harvest-crawl.ps1, both
#                                inside their self-test bodies, and carried 5 uncounted lines. The NAME is not the
#                                rule here - Invoke-*SelfTest already is, in the lib - the CALL SITES are, which
#                                is why grocery\audit-alert-registry.ps1's Test-InsideSelfTest stays out: its live
#                                path calls it.
#   a table a body reads         a labelled top-level assignment ($name = or $name +=) overlapping no body, whose
#                                variable a body READS and no body re-assigns with = (a body that assigns it reads
#                                its own copy). The 26 rows of meal-prep\pipeline\test-scaler-labels.ps1's $CASES
#                                are that file's fixtures: its gate loops over them at :273 and :294, and deleting
#                                a row deleted a case with the suite still green. That its page lane reads the same
#                                table at :389 does not make the rows production - the file says so itself at :57,
#                                "THE FROZEN TABLE. One copy, read by both lanes."
#
# Both are appended AFTER the lib's body text and never merged into it, so every per-file count keeps the bytes it
# had and no count can FALL because of this change.
#
# THE LIMIT OF THE FIRST RULE, stated because it is easy to read as stronger than it is: the fixed point promotes
# LABELLED functions only. A labelled fixture reached through an UNLABELLED middle helper is still outside, because
# making every function in the walk a candidate would mean a call-site scan per function over 577 files. Nothing in
# the tree had that shape at bf0a9bcf8; a new suite that does will be counted as 0 and will not say so.
#
# WHAT IS DELIBERATELY STILL NOT COUNTED, each of the 13 read by hand at bf0a9bcf8:
#   a production script's MESSAGES   this file's own 5 (:200 and the four-line explanation under a LOST),
#                                    ops\run-gates.ps1's gate-list entry naming this very audit,
#                                    ops\audit-fixture-vocabulary.ps1's failure line, and
#                                    grocery\validate-triage-plan.ps1's problem text inside Test-Plan, which its
#                                    live path calls. None is an assertion: no fixture's removal could change one.
#   a runner's report                meal-prep\pipeline\run-scaler-pricing-test.ps1's 3 lines count and report
#                                    another suite's must-fires. It is a daily fan-out lane
#                                    (grocery\check-ad-cycles.ps1:1491), and its text carries no case of its own.
#   prose inside a <# #> comment     the line rule skips a line that STARTS with #, so block-comment prose inside a
#                                    GATE BODY is still counted. Left that way on purpose: changing it would move
#                                    counts this change promised not to move, and it can only hold a count UP, never
#                                    hide a deletion. But the spans this file ADDS are comment-blanked, because there
#                                    the same prose decides whether a span is taken at all: the first live run of the
#                                    rule above read ops\probe-hostile-input.ps1 10 -> 11 on line 62, the opening line
#                                    of a <# #> comment inside Test-TcTextDiffers, and promoted a prose-only function.
#   grocery\test-guards.ps1's live suite  2 labelled lines (:834, :840) in the mutating suite that runs WITHOUT
#                                    -SelfTest, through grocery\run-test-guards-weekly.ps1. They are real
#                                    assertions; the lib reads that file's gated body alone because the rest of it
#                                    mutates a live tree. Counting them needs the whole file, which would swallow
#                                    its mutation helpers too. Left outside, and named here so the next reader can
#                                    see it was decided rather than missed.
#
#   ops\audit-mustfire-census.ps1            scan against ops\mustfire-census-baseline.json
#   ops\audit-mustfire-census.ps1 -Update    rewrite the baseline (deliberate, after a real change)
#   ops\audit-mustfire-census.ps1 -SelfTest  frozen must-fire fixtures + clean twins
# Exit 0 = nothing lost. 1 = a file lost must-fire assertions. 2 = self-test regression. 3 = BLIND.
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest, [switch]$Update)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\json-io.ps1')
. (Join-Path $repo 'lib\lf-write.ps1')       # Write-TcLfFile: the baseline is a TRACKED eol=lf blob
. (Join-Path $repo 'lib\selftest-lib.ps1')   # Get-SelfTestBlock: PowerShell's own parser, shared with audit-fixture-inputs
. (Join-Path $repo 'lib\tree-walk.ps1')      # Get-TcPathBelowRoot: exclusions match below the root, so a worktree root is not excluded whole

function Get-MustFireCount {
  <# Pure. How many must-fire assertions does this self-test body carry? #>
  param([string]$Text)
  if (-not $Text) { return 0 }
  $n = 0
  foreach ($l in ($Text -split "`r?`n")) {
    # A COMMENT ABOUT must-fires is not a must-fire, or the essays this estate writes above its fixtures
    # would inflate the count and the ratchet would fail the day someone tidied the prose.
    if ($l.TrimStart().StartsWith('#')) { continue }
    # The SEPARATOR IS REQUIRED and MUST may not follow a word character or a hyphen. With the separator
    # optional, a case-insensitive match counted identifiers - $mustFire, Get-MustFireCount, a
    # 'feedfresh-mustfire.json' fixture name - so renaming a variable read as a LOST assertion. Measured
    # 2026-09-11: 19 such lines in 6 files. The boundary keeps a name like Get-Must-Fire-Thing out too.
    if ($l -match '(?i)(?<![\w-])MUST[ -](NOT[ -])?FIRE') { $n++ }
  }
  return $n
}

function Get-MustFireCensusScripts {
  <# Every .ps1 the census reads under $RootDir, excluded on the path BELOW the root (lib\tree-walk.ps1).
     On the full path a root under .claude\worktrees\ excluded itself whole: the census found no must-fire
     assertion anywhere and exited 3 from every spawned session (2026-09-11). #>
  param([string]$RootDir)
  $rootFull = Get-TcRootFull $RootDir
  $exclude = '\\worktrees\\|\\archive\\|node_modules|\.venv|\\out\\'
  Get-TcTreeFiles -RootFull $rootFull -Filter *.ps1 -PruneBelow $exclude |
    Where-Object { (Get-TcPathBelowRoot $_.FullName $rootFull) -notmatch $exclude } |
    Sort-Object FullName
}

# ---- WHERE A CASE LIVES OUTSIDE THE BODY (2026-09-11) ---------------------------------------------------
# Both rules below need the WHOLE walk, not one file, which is why they are here and not in lib\selftest-lib.ps1:
# a function's call sites are in other files, and the lib answers one file at a time for two different audits.

function Test-McInside {
  <# Pure. Is $Offset inside one of these spans? #>
  param($Spans, [int]$Offset)
  foreach ($s in $Spans) { if ($Offset -ge $s.S -and $Offset -lt $s.E) { return $true } }
  return $false
}

# STANDING RULE OVER THE FUNCTION BELOW, AND IT BINDS THE NEXT PERSON TO REWRITE IT (Brad's ruling,
# 2026-09-12, backlog I154). This is the THIRD source reducer in the estate, beside lib\ps-source.ps1
# (tokens, blanks block comments and drops whole-line ones) and lib\production-text.ps1 (AST, drops the
# body of a self-test clause). Measured 2026-09-12 by reading all three: NOT ONE OF THEM BLANKS A STRING
# LITERAL, which is why .claude\rules\ops-and-gates.md has to carry "a self-test that greps its own
# source cannot fail - build needles by concatenation". That rule is a WORKAROUND FOR A MISSING LEXER.
# Brad ruled: do NOT retrofit the switch now and do NOT re-fixture the callers for it alone, because the
# change it was written to protect has already shipped. What he ruled is the trigger - THE NEXT REWRITE
# OF ANY OF THE THREE, FOR ANY REASON, CONSOLIDATES THEM INTO ONE TOKEN-BASED REDUCER IN lib\ THAT
# BLANKS COMMENTS BY DEFAULT AND STRING-LITERAL CONTENTS BEHIND A SWITCH, AND MOVES THE CALLERS IT
# TOUCHES ONTO IT IN THE SAME CHANGE. Adding the string half later costs a SECOND re-fixturing of every
# caller. This function is the one that would move first: it is a private copy of a lib\ job, and its
# blank-in-place-and-keep-offsets behaviour is a THIRD mode that lib\ps-source.ps1 does not export today.
function Get-McBlankedText {
  <# $Text with every COMMENT token replaced by spaces of the same length, so offsets do not move. Only the spans
     this file ADDS are read from it; a gate body is still counted raw, so no existing count can move.

     WHY (2026-09-11, found by the first live run of the rule above). ops\probe-hostile-input.ps1 went 10 -> 11 on
     line 62, which is the FIRST line of a BLOCK COMMENT inside Test-TcTextDiffers - prose about a must-fire, not an
     assertion. Get-MustFireCount only skips a line that STARTS with #, so the opening line of a block comment reads
     as code. That made a prose-only function look labelled, and the rule promoted it.

     And a block comment may not carry the block-comment CLOSE sequence: writing that pair here ended this comment
     early, and the prose below it ran as commands until a word was not a cmdlet. Parse errors: none. #>
  param([string]$Text)
  if (-not $Text) { return '' }
  $errs = $null
  $toks = [System.Management.Automation.PSParser]::Tokenize($Text, [ref]$errs)
  $sb = New-Object System.Text.StringBuilder $Text
  foreach ($t in $toks) {
    if ($t.Type -ne [System.Management.Automation.PSTokenType]::Comment) { continue }
    for ($i = $t.Start; $i -lt ($t.Start + $t.Length) -and $i -lt $sb.Length; $i++) {
      if ($sb[$i] -ne "`r" -and $sb[$i] -ne "`n") { $sb[$i] = ' ' }
    }
  }
  return $sb.ToString()
}

function Get-McSpanText {
  <# The text of $Kind's spans in source order, joined by newlines so two labelled lines can never be glued
     into one. -Blanked reads the comment-blanked copy, which is what every ADDED shape is counted from. #>
  param($Rec, [string]$Kind, [switch]$Blanked)
  $sel = @($Rec.Accepted | Where-Object { $_.Kind -eq $Kind } | Sort-Object S)
  if (-not $sel.Count) { return '' }
  $src = if ($Blanked) { $Rec.Blank } else { $Rec.Text }
  return ((@($sel | ForEach-Object { $src.Substring($_.S, $_.E - $_.S) })) -join "`n")
}

function Get-McFileRecords {
  <# One record per file, carrying the lib's own body spans as Kind 'body'. A file that does not parse gets no
     spans and no Ast, exactly as the lib treats it. Blank is the comment-blanked copy, same length. #>
  param($Files)
  $recs = New-Object System.Collections.ArrayList
  foreach ($f in $Files) {
    $text = [string]$f.Text
    $spans = Get-SelfTestSpans -Text $text -Path ([string]$f.Path)
    $spans = @($spans)
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count) { $ast = $null }
    $acc = New-Object System.Collections.ArrayList
    foreach ($s in $spans) { [void]$acc.Add([pscustomobject]@{ S = $s.S; E = $s.E; Kind = 'body' }) }
    [void]$recs.Add([pscustomobject]@{
      Rel = $f.Rel; Path = $f.Path; Text = $text; Blank = (Get-McBlankedText $text); Ast = $ast; Accepted = $acc })
  }
  return $recs
}

function Add-McCalledFixtureBodies {
  <# A labelled function whose EVERY call site in the walk lies inside an accepted body, to a fixed point, so a
     fixture helper called only by another accepted helper counts too. A function nothing calls runs nowhere and
     is refused; one call from a live path and it is refused as well. #>
  param($Recs)
  $cands = New-Object System.Collections.ArrayList
  foreach ($r in $Recs) {
    if (-not $r.Ast) { continue }
    foreach ($fd in $r.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
      if (Test-McInside $r.Accepted $fd.Body.Extent.StartOffset) { continue }
      # Comment-blanked: a function whose only label is <# #> prose is not a fixture (see Get-McBlankedText).
      $bodyText = $r.Blank.Substring($fd.Body.Extent.StartOffset, $fd.Body.Extent.EndOffset - $fd.Body.Extent.StartOffset)
      if ((Get-MustFireCount -Text $bodyText) -le 0) { continue }
      [void]$cands.Add([pscustomobject]@{
        Rec = $r; Name = ($fd.Name -replace '^(global|local|script|private):', '')
        S = $fd.Body.Extent.StartOffset; E = $fd.Body.Extent.EndOffset
        FnS = $fd.Extent.StartOffset; FnE = $fd.Extent.EndOffset; Done = $false })
    }
  }
  if (-not $cands.Count) { return }
  do {
    $grew = $false
    foreach ($c in $cands) {
      if ($c.Done) { continue }
      $sites = 0; $allInside = $true
      foreach ($r in $Recs) {
        if (-not $r.Ast) { continue }
        # Call sites are read only from files that SPELL the name: 577 files, and a handful mention any one of them.
        if ($r.Text.IndexOf($c.Name, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        foreach ($cmd in $r.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
          $nm = $cmd.GetCommandName()
          if (-not $nm) { continue }
          if (-not [string]::Equals($nm, $c.Name, [StringComparison]::OrdinalIgnoreCase)) { continue }
          # A recursive call inside the candidate itself says nothing about who runs it.
          if ([object]::ReferenceEquals($r, $c.Rec) -and $cmd.Extent.StartOffset -ge $c.FnS -and $cmd.Extent.EndOffset -le $c.FnE) { continue }
          $sites++
          if (-not (Test-McInside $r.Accepted $cmd.Extent.StartOffset)) { $allInside = $false }
        }
      }
      if ($sites -gt 0 -and $allInside) {
        [void]$c.Rec.Accepted.Add([pscustomobject]@{ S = $c.S; E = $c.E; Kind = 'called-fixture-fn' })
        $c.Done = $true; $grew = $true
      }
    }
  } while ($grew)
}

function Add-McTablesABodyReads {
  <# A labelled top-level assignment ($name = or $name +=) overlapping no accepted body, whose variable a body
     READS and no body re-assigns with = - a body that assigns it is reading its own copy, not this table. That
     the live path reads the same table as well does not matter: the rows are still the suite's cases. #>
  param($Recs)
  $assignType = [System.Management.Automation.Language.AssignmentStatementAst]
  $attrType = [System.Management.Automation.Language.AttributedExpressionAst]
  $varType = [System.Management.Automation.Language.VariableExpressionAst]
  $tkEquals = [System.Management.Automation.Language.TokenKind]::Equals
  $tkPlusEquals = [System.Management.Automation.Language.TokenKind]::PlusEquals
  foreach ($r in $Recs) {
    if (-not $r.Ast -or -not $r.Ast.EndBlock) { continue }
    $bodies = @($r.Accepted)
    if (-not $bodies.Count) { continue }
    $vars = $null
    foreach ($st in @($r.Ast.EndBlock.Statements)) {
      if ($st -isnot $assignType) { continue }
      if (($st.Operator -ne $tkEquals) -and ($st.Operator -ne $tkPlusEquals)) { continue }
      $left = $st.Left
      while ($left -is $attrType) { $left = $left.Child }   # [object[]]$CASES = ... is still $CASES
      if ($left -isnot $varType) { continue }
      $s0 = $st.Extent.StartOffset; $e0 = $st.Extent.EndOffset
      $overlaps = $false
      foreach ($b in $bodies) { if (($s0 -lt $b.E) -and ($b.S -lt $e0)) { $overlaps = $true; break } }
      if ($overlaps) { continue }   # an assignment that CONTAINS a gate is never a table
      # Comment-blanked: a row whose label lives in a trailing comment is prose, not a case (see Get-McBlankedText).
      $rhs = $r.Blank.Substring($st.Right.Extent.StartOffset, $st.Right.Extent.EndOffset - $st.Right.Extent.StartOffset)
      if ((Get-MustFireCount -Text $rhs) -le 0) { continue }
      $vn = Get-SelfTestVariableName $left
      if ($null -eq $vars) { $vars = @($r.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) }
      $reads = 0; $sets = 0
      foreach ($v in $vars) {
        if (-not (Test-McInside $bodies $v.Extent.StartOffset)) { continue }
        if (-not [string]::Equals((Get-SelfTestVariableName $v), $vn, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $node = $v; $up = $v.Parent
        while ($up -is $attrType) { $node = $up; $up = $up.Parent }
        if (($up -is $assignType) -and [object]::ReferenceEquals($up.Left, $node) -and ($up.Operator -eq $tkEquals)) { $sets++ } else { $reads++ }
      }
      if ($reads -le 0 -or $sets -gt 0) { continue }
      [void]$r.Accepted.Add([pscustomobject]@{ S = $s0; E = $e0; Kind = 'table-a-body-reads' })
    }
  }
}

function Get-McBodies {
  <# rel -> { Text; Body; Added }. Body is the lib's answer, byte for byte; Text is Body with the extra shapes
     appended after it, so every per-file count keeps the bytes it had and none can fall. #>
  param($Files)
  $recs = Get-McFileRecords -Files $Files
  Add-McCalledFixtureBodies -Recs $recs
  Add-McTablesABodyReads -Recs $recs
  $out = [ordered]@{}
  foreach ($r in $recs) {
    $body = Get-McSpanText -Rec $r -Kind 'body'
    $added = [ordered]@{}
    foreach ($kind in @('called-fixture-fn', 'table-a-body-reads')) {
      $t = Get-McSpanText -Rec $r -Kind $kind -Blanked
      if ($t) { $added[$kind] = $t }
    }
    $text = $body
    foreach ($k in $added.Keys) { if ($text) { $text = $text + "`n" + $added[$k] } else { $text = $added[$k] } }
    $out[$r.Rel] = [pscustomobject]@{ Text = $text; Body = $body; Added = $added }
  }
  return $out
}

if ($SelfTest) {
  $fail = 0
  function McT([string]$m, [bool]$c) { if ($c) { Write-Output ('  PASS  ' + $m) } else { Write-Output ('  FAIL  ' + $m); $script:fail++ } }
  # Needles built by concatenation, or these fixture lines would be counted by the very scan they test
  # ([[selftest-greps-its-own-source]]).
  $MF = 'MUST' + ' FIRE'
  $MNF = 'MUST' + ' NOT ' + 'FIRE'

  McT 'MUST FIRE: an assertion label carrying the marker is counted' `
      ((Get-MustFireCount -Text ("T '" + $MF + ": a stripped BOM is reported' `$x")) -eq 1)
  McT 'MUST FIRE: the negative form is counted too - it is the same kind of assertion' `
      ((Get-MustFireCount -Text ("T '" + $MNF + ": a bid whose value is the string null' `$x")) -eq 1)
  McT 'MUST FIRE: the hyphenated spelling this estate also uses is counted' `
      ((Get-MustFireCount -Text ("Write-Output '  X MUST" + "-FIRE: a fresh finding must be actionable'")) -eq 1)
  McT 'CLEAN TWIN: a COMMENT about must-fires is prose, not an assertion' `
      ((Get-MustFireCount -Text ("# the " + $MF + " fixture below is the founding bug")) -eq 0)
  McT 'CLEAN TWIN: an empty body counts nothing' ((Get-MustFireCount -Text '') -eq 0)
  McT 'MUST FIRE: every assertion is counted, not just the first' `
      ((Get-MustFireCount -Text ("T '" + $MF + " one'`nT '" + $MF + " two'")) -eq 2)
  # THE WHOLE POINT: a deleted line changes the count. Written as a comparison so the ratchet's own
  # arithmetic is asserted rather than assumed.
  $two = "T '" + $MF + " one'`nT '" + $MF + " two'"
  $one = "T '" + $MF + " one'"
  McT 'MUST FIRE: deleting an assertion LOWERS the count - which is the thing the ratchet reads' `
      ((Get-MustFireCount -Text $one) -lt (Get-MustFireCount -Text $two))
  # And only the SELF-TEST body is counted: a must-fire label in the production path is not a fixture.
  $src = "if (`$SelfTest) {`n  T '" + $MF + " inside'`n}`nWrite-Output '" + $MF + " outside, in the live path'"
  McT 'CLEAN TWIN: a must-fire label OUTSIDE the self-test body is not a fixture' `
      ((Get-MustFireCount -Text (Get-SelfTestBlock -Text $src)) -eq 1)
  # THE CAPTURED SWITCH (2026-09-11). Get-SelfTestBlock read only `if ($SelfTest)`, so every must-fire under the
  # meal-prep\pipeline idiom `$runSelfTest = [bool]$SelfTest` was outside the census and could be deleted with
  # it green. lib\selftest-lib.ps1 carries the shapes; this pins the census end to end on the founding one.
  $capSrc = "param([switch]`$SelfTest)`n`$runSelfTest = [bool]`$SelfTest`nif (`$runSelfTest) {`n  T '" + $MF + " one'`n  T '" + $MF + " two'`n}`n"
  McT 'MUST FIRE: must-fires under a variable captured from the -SelfTest switch are counted' `
      ((Get-MustFireCount -Text (Get-SelfTestBlock -Text $capSrc)) -eq 2)
  # THE WHOLE-FILE SUITE (2026-09-11, later). grocery\test-auditors.ps1 declares no self-test switch, so every must-fire
  # in it was outside the census. The live path passes -Path, which is what that rule keys on.
  $wfSrc = "[CmdletBinding()]`nparam([string]`$SkipUnitsFile = '')`nOk '" + $MF + " one'`nOk '" + $MNF + " two'`n"
  McT 'MUST FIRE: must-fires in a whole-file test-*.ps1 suite are counted when its path is passed' `
      ((Get-MustFireCount -Text (Get-SelfTestBlock -Text $wfSrc -Path 'grocery\test-auditors.ps1')) -eq 2)

  # IDENTIFIERS ARE NOT LABELS (2026-09-11). With the separator optional the match counted names, so renaming
  # a $mustFire variable read as a LOST assertion and the ratchet went red on a rename. Each needle is built by
  # concatenation: this body is itself in the census, and a literal would be counted by the scan under test.
  McT 'MUST NOT FIRE: a run-together variable name is not an assertion label' `
      ((Get-MustFireCount -Text ('$must' + 'Fire = @(')) -eq 0)
  McT 'MUST NOT FIRE: a call to the counting function is not an assertion label' `
      ((Get-MustFireCount -Text ('$c = Get-Must' + 'FireCount -Text $blk')) -eq 0)
  McT 'MUST NOT FIRE: a hyphenated name with the words inside it is not a label' `
      ((Get-MustFireCount -Text ('$r = Get-Must-' + 'Fire-Thing -Path $x')) -eq 0)
  McT 'MUST NOT FIRE: a run-together banner is not an assertion label' `
      ((Get-MustFireCount -Text ("Write-Output 'MUST" + "FIRE-CENSUS SELF-TEST PASSED'")) -eq 0)
  $spellings = "T '" + $MF + ": a'`nT 'MUST" + "-FIRE: b'`nT '" + $MNF + ": c'"
  McT 'CLEAN TWIN: all three separated spellings still count, one per line' `
      ((Get-MustFireCount -Text $spellings) -eq 3)

  # THE WALK, FROM A WORKTREE ROOT (2026-09-11, lib\tree-walk.ps1). Matched on the FULL path, every file under
  # .claude\worktrees\<name> was excluded: the census counted nothing and exited 3 from every spawned session.
  $wtFx = New-TcWorktreeFixture -Files @{ 'ops\a.ps1' = 'Write-Output 1'; 'grocery\b.ps1' = 'Write-Output 2' }
  try {
    $wtFound = @(Get-MustFireCensusScripts -RootDir $wtFx.Root)
    $wtHits = Measure-TcWorktreeFixture -Fixture $wtFx -Found $wtFound
    McT ($MF + ': a root that IS a worktree is scanned, not excluded whole') ($wtHits.Root -eq 2)
    McT ($MNF + ': a sibling worktree BELOW that root is still excluded') ($wtHits.Sibling -eq 0)
  } finally { Remove-Item -LiteralPath $wtFx.Temp -Recurse -Force -ErrorAction SilentlyContinue }

  # ---- THE TWO SHAPES OUTSIDE THE BODY (2026-09-11) ------------------------------------------------------
  # Every fixture INPUT below builds its label by concatenation: this file is in the census, and a literal would be
  # counted by the very scan under test ([[selftest-greps-its-own-source]]). The case labels stay literal.
  function McCount($files, $rel) {
    $b = Get-McBodies -Files $files
    if (-not $b.Contains($rel)) { return 0 }
    return (Get-MustFireCount -Text $b[$rel].Text)
  }
  $MFH = 'MUST' + '-FIRE'
  $LIB = 'meal-prep\pipeline\probe-names-lib.ps1'
  $CALLER = 'meal-prep\pipeline\probe-hunt.ps1'
  $fnLib = "function Invoke-NamesFixtures {`n  param(`$TBlock)`n  & `$TBlock '" + $MF + "  a MISSING reference is a could-not-look'`n}`n"
  $gateCaller = "param([switch]`$SelfTest)`nif (`$SelfTest) {`n  . (Join-Path `$here 'probe-names-lib.ps1')`n  Invoke-NamesFixtures -TBlock `${function:T}`n}`n"
  $liveCaller = "param([switch]`$SelfTest)`nInvoke-NamesFixtures -TBlock `${function:T}`n"
  $pair = @(@{ Rel = $LIB; Path = $LIB; Text = $fnLib }, @{ Rel = $CALLER; Path = $CALLER; Text = $gateCaller })
  McT 'MUST FIRE: a labelled function whose every call site is inside a self-test body is counted (the selftest-names-lib shape)' `
      ((McCount $pair $LIB) -eq 1)
  $pairLive = @(@{ Rel = $LIB; Path = $LIB; Text = $fnLib }, @{ Rel = $CALLER; Path = $CALLER; Text = $liveCaller })
  McT 'MUST NOT FIRE: one call site in a live path and the function is production, not a fixture (the validate-triage-plan shape)' `
      ((McCount $pairLive $LIB) -eq 0)
  $alone = @(@{ Rel = $LIB; Path = $LIB; Text = $fnLib })
  McT 'MUST NOT FIRE: a labelled function nothing in the walk calls runs nowhere, so it is not counted (the carriage-lib shape)' `
      ((McCount $alone $LIB) -eq 0)
  # THE FIXED POINT: a labelled helper called only from another ACCEPTED labelled fixture function. The promotion is
  # what makes the second one reachable, so one pass would count 1 and the fixed point counts both.
  $inner = "function Invoke-NamesFixtures {`n  param(`$TBlock)`n  & `$TBlock '" + $MF + "  a MISSING reference is a could-not-look'`n  Assert-Vector `$TBlock`n}`n" +
           "function Assert-Vector {`n  param(`$TBlock)`n  & `$TBlock '" + $MF + "  the Python twin answers identically'`n}`n"
  $pairInner = @(@{ Rel = $LIB; Path = $LIB; Text = $inner }, @{ Rel = $CALLER; Path = $CALLER; Text = $gateCaller })
  McT 'MUST FIRE: a labelled helper called only from another accepted fixture function is counted too, to a fixed point' `
      ((McCount $pairInner $LIB) -eq 2)

  # A TABLE A BODY READS: meal-prep\pipeline\test-scaler-labels.ps1 keeps 26 of its 30 labelled lines as rows of a
  # top-level $CASES its gate loops over, and its page lane reads the same table by design.
  $TBL = 'meal-prep\pipeline\probe-labels.ps1'
  $row1 = "  @{ id='F01'; kind='" + $MFH + "'; buy='2 lb 5 oz' }`n"
  $row2 = "  @{ id='F02'; kind='" + $MFH + "'; buy='1 lb 2 1/2 oz' }`n"
  $rowTwin = "  @{ id='F07'; kind='CLEAN TWIN'; buy='2 pk 12 oz' }`n"
  $tblGate = "if (`$SelfTest) {`n  foreach (`$c in `$CASES) { if (`$c.kind -eq '" + $MFH + "') { `$n++ } }`n  exit 0`n}`n"
  $tblLive = "foreach (`$c in `$CASES) { `$page += `$c.buy }`n"
  $tblSrc = "param([switch]`$SelfTest)`n`$CASES = @(`n" + $row1 + $row2 + $rowTwin + ")`n" + $tblGate + $tblLive
  $tblFiles = @(@{ Rel = $TBL; Path = $TBL; Text = $tblSrc })
  McT 'MUST FIRE: rows of a top-level table the gate loops over are counted, though the live page lane reads it too' `
      ((McCount $tblFiles $TBL) -eq 3)
  $tblOneGone = "param([switch]`$SelfTest)`n`$CASES = @(`n" + $row1 + $rowTwin + ")`n" + $tblGate + $tblLive
  McT 'MUST FIRE: deleting a row from that table LOWERS the count, which is the thing the ratchet reads' `
      ((McCount @(@{ Rel = $TBL; Path = $TBL; Text = $tblOneGone }) $TBL) -lt (McCount $tblFiles $TBL))
  $liveOnly = "param([switch]`$SelfTest)`n`$CASES = @(`n" + $row1 + $row2 + ")`nif (`$SelfTest) {`n  Write-Output `$other.Count`n  exit 0`n}`n" + $tblLive
  McT 'MUST NOT FIRE: a labelled top-level table only the LIVE path reads is production text' `
      ((McCount @(@{ Rel = $TBL; Path = $TBL; Text = $liveOnly }) $TBL) -eq 0)
  $ownCopy = "param([switch]`$SelfTest)`n`$CASES = @(`n" + $row1 + $row2 + ")`nif (`$SelfTest) {`n  `$CASES = @(@{ kind = 'x' })`n  foreach (`$c in `$CASES) { `$n++ }`n}`n"
  McT 'MUST NOT FIRE: a body that assigns the variable itself reads its own copy, not the top-level table' `
      ((McCount @(@{ Rel = $TBL; Path = $TBL; Text = $ownCopy }) $TBL) -eq 0)
  $appended = "param([switch]`$SelfTest)`n`$CASES = @()`n`$CASES += @{ kind='" + $MFH + "'; buy='1 cup' }`n" + $tblGate
  McT 'MUST FIRE: rows appended at top level with += are the same table' `
      ((McCount @(@{ Rel = $TBL; Path = $TBL; Text = $appended }) $TBL) -eq 2)
  $exprIf = "param([switch]`$SelfTest)`n`$runLog = if (`$SelfTest) { `$null } else { Write-Output '" + $MF + " live text' }`nif (`$SelfTest) {`n  T '" + $MF + ": the real case'`n}`n"
  McT 'MUST NOT FIRE: an assignment that CONTAINS a gate is never a table, so its live else branch is not counted' `
      ((McCount @(@{ Rel = $TBL; Path = $TBL; Text = $exprIf }) $TBL) -eq 1)

  # PROSE IS NOT A LABEL IN AN ADDED SPAN (2026-09-11, found by the first live run). ops\probe-hostile-input.ps1 rose
  # 10 -> 11 on line 62, the opening line of a <# #> comment inside Test-TcTextDiffers, whose call sites are all in
  # its gate. The line rule only skips a line STARTING with #, so the prose made the function look labelled.
  $proseFn = "param([switch]`$SelfTest)`nfunction Test-Differs {`n  <# ORDINAL comparison, found by this file's own " +
             $MF.ToLower() + " #>`n  return `$true`n}`nif (`$SelfTest) {`n  `$x = Test-Differs`n}`n"
  McT 'MUST NOT FIRE: a function whose only label is prose in a <# #> comment is not a fixture (the probe-hostile-input shape)' `
      ((McCount @(@{ Rel = $LIB; Path = $LIB; Text = $proseFn }) $LIB) -eq 0)
  $realFn = "param([switch]`$SelfTest)`nfunction Test-Differs {`n  T '" + $MF + ": Ordinal comparison DOES see a NUL'`n}`n" +
            "if (`$SelfTest) {`n  `$x = Test-Differs`n}`n"
  McT 'CLEAN TWIN: the same function with a REAL assertion line in it is still counted, so blanking took only the prose' `
      ((McCount @(@{ Rel = $LIB; Path = $LIB; Text = $realFn }) $LIB) -eq 1)
  $trailTbl = "param([switch]`$SelfTest)`n`$CASES = @(`n  @{ id='F01'; buy='2 lb' }   # " + $MFH + " note about this row`n)`n" +
              "if (`$SelfTest) {`n  foreach (`$c in `$CASES) { `$n++ }`n}`n"
  McT 'MUST NOT FIRE: a table row whose label sits in a TRAILING comment is prose, not a case' `
      ((McCount @(@{ Rel = $TBL; Path = $TBL; Text = $trailTbl }) $TBL) -eq 0)
  # AND THE SPAN IS NOT EVEN TAKEN. The two cases above assert the COUNT, and comments are blanked twice over - once
  # when deciding whether a span is labelled, once when counting it - so either half alone keeps the count at 0 and
  # neither case can see which half worked. A mutation probe on 2026-09-11 proved exactly that: both single-half
  # mutants SURVIVED those two cases. These two read the promotion itself, so each half is separately pinned.
  $pb = Get-McBodies -Files @(@{ Rel = $LIB; Path = $LIB; Text = $proseFn })
  McT 'MUST NOT FIRE: a prose-only function is never PROMOTED, so no span is added for it at all' `
      (-not $pb[$LIB].Added.Contains('called-fixture-fn'))
  $tb2 = Get-McBodies -Files @(@{ Rel = $TBL; Path = $TBL; Text = $trailTbl })
  McT 'MUST NOT FIRE: a trailing-comment-only table is never promoted either, so no table span is added' `
      (-not $tb2[$TBL].Added.Contains('table-a-body-reads'))

  # THE BYTES OF EVERY EXISTING COUNT: Body is still exactly what the lib returns, and it LEADS the combined text.
  $gateOnly = "param([switch]`$SelfTest)`nif (`$SelfTest) {`n  T '" + $MF + ": one'`n}`nWrite-Output '" + $MF + " in the live path'`n"
  $gb = Get-McBodies -Files @(@{ Rel = $TBL; Path = $TBL; Text = $gateOnly })
  McT 'CLEAN TWIN: a file with no extra shape counts exactly what it counted before, and Body is the lib''s own bytes' `
      (((Get-MustFireCount -Text $gb[$TBL].Text) -eq 1) -and
       [string]::Equals($gb[$TBL].Body, (Get-SelfTestBlock -Text $gateOnly -Path $TBL), [StringComparison]::Ordinal))
  $tb = Get-McBodies -Files $tblFiles
  McT 'CLEAN TWIN: where a table IS added, the lib''s body text still leads the combined text byte for byte' `
      ($tb[$TBL].Text.StartsWith((Get-SelfTestBlock -Text $tblSrc -Path $TBL), [StringComparison]::Ordinal))

  if ($fail) { Write-Output "MUSTFIRE-CENSUS SELF-TEST FAILED ($fail)"; exit 2 }
  Write-Output 'MUSTFIRE-CENSUS SELF-TEST PASSED (every spelling counted, prose excluded, and a deletion provably moves the number)'
  exit 0
}

# ---- live path -----------------------------------------------------------------------------------------
$scripts = @(Get-MustFireCensusScripts -RootDir $repo)

$inputs = New-Object System.Collections.ArrayList
foreach ($s in $scripts) {
  [void]$inputs.Add([pscustomobject]@{
    Rel  = $s.FullName.Replace($repo, '').TrimStart('\')
    Path = $s.FullName                                     # -Path: a whole-file test-*.ps1 suite is read by its name
    Text = [IO.File]::ReadAllText($s.FullName)
  })
}
$bodies = Get-McBodies -Files $inputs.ToArray()

$now = [ordered]@{}
$total = 0
$byAdded = [ordered]@{}
foreach ($rel in $bodies.Keys) {
  $c = Get-MustFireCount -Text $bodies[$rel].Text
  if ($c -le 0) { continue }
  $now[$rel] = $c
  $total += $c
  foreach ($k in $bodies[$rel].Added.Keys) {
    $ac = Get-MustFireCount -Text $bodies[$rel].Added[$k]
    if ($ac -le 0) { continue }
    if (-not $byAdded.Contains($k)) { $byAdded[$k] = @(0, 0) }
    $byAdded[$k] = @(($byAdded[$k][0] + 1), ($byAdded[$k][1] + $ac))
  }
}
if (-not $now.Count) {
  Write-Output 'audit-mustfire-census: BLIND - found no must-fire assertions anywhere, which means this discovery is broken, not that the estate has none'
  Exit-Guard -Name 'audit-mustfire-census' -Summary 'blind=no-mustfires' -Code 3
}

$baseFile = Join-Path $PSScriptRoot 'mustfire-census-baseline.json'
if ($Update) {
  # LF, WITH the BOM the committed blob carries (2026-09-11). This was Write-JsonFile, which writes ConvertTo-Json's
  # CRLF: the -Update that day left 208 CR bytes over an LF blob, the shape lib\lf-write.ps1 exists for, and
  # 3176eb82b moved the other baseline writers without this one.
  $null = Write-TcLfFile -Path $baseFile -Text ([ordered]@{
    readme  = 'Baseline for ops\audit-mustfire-census.ps1: how many must-fire assertions each self-test carries. A DROP is a hard fail - a must-fire that breaks goes red on its own, and a must-fire that is DELETED goes green with one fewer case and nobody counts tallies. A RISE is the estate getting better; re-run with -Update to retrain. Counting is per FILE, not per case name, because case labels are prose and a ratchet that fails on a reworded label is a ratchet people delete.'
    written = (Get-Date).ToString('yyyy-MM-dd')
    total   = $total
    files   = $now
  } | ConvertTo-Json -Depth 6)
  Write-Output ("audit-mustfire-census: baseline rewritten - {0} file(s), {1} must-fire assertion(s)" -f $now.Count, $total)
  exit 0
}

$base = $null
if (Test-Path -LiteralPath $baseFile) { try { $base = (Read-JsonFile $baseFile).files } catch { $base = $null } }
if ($null -eq $base) {
  Write-Output ("audit-mustfire-census: no baseline at {0} - run with -Update once to record today's census. {1} file(s), {2} assertion(s) counted." -f $baseFile, $now.Count, $total)
  Exit-Guard -Name 'audit-mustfire-census' -Summary 'no baseline' -Code 3
}

$lost = New-Object System.Collections.ArrayList
$gained = New-Object System.Collections.ArrayList
foreach ($p in $base.PSObject.Properties) {
  $was = [int]$p.Value
  $isNow = if ($now.Contains($p.Name)) { [int]$now[$p.Name] } else { 0 }
  if ($isNow -lt $was) { [void]$lost.Add(("{0}  {1} -> {2}" -f $p.Name, $was, $isNow)) }
  elseif ($isNow -gt $was) { [void]$gained.Add(("{0}  {1} -> {2}" -f $p.Name, $was, $isNow)) }
}
foreach ($k in $now.Keys) {
  if (-not ($base.PSObject.Properties.Name -contains $k)) { [void]$gained.Add(("{0}  new, {1}" -f $k, $now[$k])) }
}

Write-Output ("audit-mustfire-census: {0} self-test(s) carry {1} must-fire assertion(s); {2} lost, {3} gained" -f $now.Count, $total, $lost.Count, $gained.Count)
if ($byAdded.Count) {
  Write-Output ('  of which OUTSIDE the body the finder returns: ' +
    ((@($byAdded.Keys | ForEach-Object { '{0} {1} file(s) {2} assertion(s)' -f $_, $byAdded[$_][0], $byAdded[$_][1] })) -join '; '))
}
foreach ($g in $gained) { Write-Output ('  + ' + $g) }
foreach ($l in $lost) { Write-Output ('  ! LOST: ' + $l) }
if ($lost.Count) {
  Write-Output '  A must-fire assertion is the bug that caused its guard to be written. One that BREAKS turns red'
  Write-Output '  and everybody sees it; one that is DELETED leaves a green suite with one fewer case, and a tally'
  Write-Output '  nobody reads. If the removal is right - the rule it guarded was genuinely retired - say so in the'
  Write-Output '  commit and re-run with -Update. Do not retrain the baseline to make a red go away.'
}
if ($gained.Count -and -not $lost.Count) { Write-Output '  (a rise is the estate getting better - re-run with -Update to retrain the baseline)' }
Write-GuardComplete -Name 'audit-mustfire-census' -Summary ("{0} assertion(s), {1} lost" -f $total, $lost.Count)
if ($lost.Count) { exit 1 }
exit 0
