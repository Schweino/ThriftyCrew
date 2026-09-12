<#
  audit-crossroad-reads.ps1 - a test-auditors case may not decide its verdict by comparing a file that
  reaches a checkout by COMMIT with one that reaches it by COPY.

  SCOPE OF A CLEAN REPORT: UNSOUND. It resolves LITERAL path expressions out of the PowerShell AST of
    grocery\test-auditors.ps1 - Join-Path and Split-Path -Parent off $root or $repo, followed through
    variable assignments to a fixpoint - and classifies each resolved path with git. A reported unit is
    real. Silence is not proof: a path built from a computed leaf, a path a CHILD script opens, a path
    held in a here-string, and a read reached through a helper this file does not follow are all
    invisible to it. It also cannot tell a unit that COMPARES its two roads from one that merely reads
    both, so an entry here is a site to look at, not a proven defect. It is a ratchet BY NAME rather
    than a gate at zero, because the population it measured on its first day is 1 and that one is
    deliberate.

  WHY THIS EXISTS (2026-09-11). A push touching lib\event-bus.ps1 and four unrelated files passed
  ops\run-gates.ps1 357 of 357 and was then REFUSED by ops\prepush-test-auditors.ps1, naming one case:

      capture-evictions.json audited comparison-2026-09-09.json but the newest board is
      comparison-2026-09-11.json

  Neither the artifact nor the audit that reads it was in the push. grocery\out\capture-evictions.json
  is TRACKED; grocery\out\comparison-*.json is gitignored and reaches a worktree by copy through
  .worktreeinclude. A hand-run triage chain rebuilt the board at 14:27, ran the eviction pass at 14:32
  in the MAIN checkout and committed its source only - so every worktree that held the new board was
  judged against a committed report naming the old one, and every push from one was refused, for a
  reason the pusher did not cause and could not fix by editing code. It would have stayed that way
  until the next morning's bot commit. design\PLAN-capture-eviction-stamp-2026-09-11.md has the
  timeline, the repair (the pass now also writes a gitignored STAMP that travels with the board) and
  the two repairs that were measured and refused.

  WHY A DETECTOR AND NOT A LINE IN THE RULES. .claude\rules\ops-and-gates.md says twice, in its own
  words, that a rule in a file is not a block, and both times the estate's answer was a ratchet at push
  time (audit-full-path-excludes, audit-fixed-temp-names). The shape here is cheap to recreate: any new
  case that reads a tracked artifact under out\ beside a board has it, and the cost lands on whoever
  pushes next from a worktree rather than on whoever wrote the case.

  THE RULE. Within one unit - `if (Use-Unit '<id>' ...) { ... }` - it is a finding to read BOTH:
    * a file that reaches a checkout by COMMIT: tracked, and DERIVED rather than source or rulings,
      which here means it lives under a directory named out\ or public\. Tracked SOURCE (.ps1) and
      tracked RULE files (commodities.json, stores.json) are not in the class: they travel by the same
      road as the code being tested, so they cannot lag behind it.
    * a file that reaches a checkout by COPY: gitignored, so a worktree gets it from
      ops\seed-worktree.ps1 and .worktreeinclude, or not at all.
  The two roads move independently, and the case then measures which road ran last rather than the
  property it was written to assert.

  THE REPAIR when it fires is not to weaken the case. It is to put both inputs on ONE road: have the
  producer also write a gitignored stamp beside the copied file and read that (u108's repair), or read
  the tracked artifact against something else tracked. Untracking the artifact is a third option and
  was measured and refused for capture-evictions.json, because the daily bot commits that file and the
  untrack commit collides with the bot's own autostash rebase.

    ops\audit-crossroad-reads.ps1            scan against ops\crossroad-reads-baseline.json
    ops\audit-crossroad-reads.ps1 -Update    rewrite the baseline (deliberate, after a real repair)
    ops\audit-crossroad-reads.ps1 -SelfTest  frozen fixtures, discovered by ops\run-gates.ps1
  Exit 0 = no NEW unit on both roads. 1 = a NEW one. 2 = self-test regression. 3 = BLIND (the suite
  could not be parsed, or no units resolved at all, which means this discovery is broken rather than
  that the suite is clean).
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param([switch]$SelfTest, [switch]$Update, [string]$SuitePath)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot is empty inside a param() default under [CmdletBinding()], so the root is resolved here.
$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $repoRoot 'lib\guard-contract.ps1')
. (Join-Path $repoRoot 'lib\json-io.ps1')
. (Join-Path $repoRoot 'lib\lf-write.ps1')       # the baseline is TRACKED: LF bytes, or every push reads ' M' with a zero-line diff
. (Join-Path $repoRoot 'lib\git-repo-env.ps1')   # a hook in a linked worktree exports GIT_DIR to everything it spawns

$BASELINE_FILE = Join-Path $PSScriptRoot 'crossroad-reads-baseline.json'
$DEFAULT_SUITE = Join-Path $repoRoot 'grocery\test-auditors.ps1'

# ---- the resolver, pure ---------------------------------------------------------------------------
# A path expression is LIVE when its root is the tree under test. $root is grocery\, $repo is the repo,
# and any variable assigned a live path is itself live - followed to a fixpoint so a two-level join
# (out\audit, then match-baseline.json under it) resolves. A fixture root under $env:TEMP or $fix never
# resolves, which is what keeps frozen inputs out of the population.

function Resolve-TcLivePath {
  <# Repo-relative path for $Expr, or $null when it is not rooted in the live tree. $Known maps a
     variable name to the repo-relative path it holds. #>
  param($Expr, [hashtable]$Known)
  if ($null -eq $Expr) { return $null }
  if ($Expr -is [System.Management.Automation.Language.ParenExpressionAst]) { return Resolve-TcLivePath -Expr $Expr.Pipeline -Known $Known }
  if ($Expr -is [System.Management.Automation.Language.PipelineAst]) {
    if ($Expr.PipelineElements.Count -ne 1) { return $null }
    return Resolve-TcLivePath -Expr $Expr.PipelineElements[0] -Known $Known
  }
  if ($Expr -is [System.Management.Automation.Language.CommandExpressionAst]) { return Resolve-TcLivePath -Expr $Expr.Expression -Known $Known }
  if ($Expr -is [System.Management.Automation.Language.VariableExpressionAst]) {
    $n = $Expr.VariablePath.UserPath -replace '^(script|global|local|private):', ''   # UnqualifiedPath is INTERNAL under PS 5.1 and reads as $null
    if ($Known.ContainsKey($n)) { return [string]$Known[$n] }
    return $null
  }
  if ($Expr -is [System.Management.Automation.Language.CommandAst]) {
    $name = $Expr.GetCommandName()
    $el = @($Expr.CommandElements)
    if ($name -eq 'Join-Path' -and $el.Count -ge 3) {
      $base = Resolve-TcLivePath -Expr $el[1] -Known $Known
      if ($null -eq $base) { return $null }
      if ($el[2] -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $null }
      $leaf = ($el[2].Value -replace '/', '\').Trim('\')
      if ($base -eq '') { return $leaf }
      return ($base + '\' + $leaf)
    }
    if ($name -eq 'Split-Path' -and $el.Count -ge 2) {
      $parent = @($el | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -match '^Par' })
      if ($parent.Count -eq 0) { return $null }
      $base = Resolve-TcLivePath -Expr $el[1] -Known $Known
      if ($null -eq $base) { return $null }
      if ($base -match '^(.*)\\[^\\]+$') { return $Matches[1] }
      return ''
    }
  }
  return $null
}

function Get-TcLiveReads {
  <# Every live-rooted path expression in $Text, with the line it sits on and the unit that encloses it.
     $RootVar / $RepoVar name the seed variables (the suite's grocery root and repo root). #>
  param([Parameter(Mandatory=$true)][string]$Text, [string]$RootVar = 'root', [string]$RepoVar = 'repo', [string]$RootRel = 'grocery')
  $tok = $null; $errs = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tok, [ref]$errs)
  if ($errs -and $errs.Count) { return $null }

  $known = @{}
  $known[$RootVar] = $RootRel
  $known[$RepoVar] = ''
  $assigns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))
  # A fixpoint rather than one pass: an assignment may read a variable assigned further down the file.
  for ($pass = 1; $pass -le 6; $pass++) {
    $grew = $false
    foreach ($a in $assigns) {
      if ($a.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
      $nm = $a.Left.VariablePath.UserPath -replace '^(script|global|local|private):', ''
      if ($known.ContainsKey($nm)) { continue }
      $r = Resolve-TcLivePath -Expr $a.Right -Known $known
      if ($null -ne $r) { $known[$nm] = $r; $grew = $true }
    }
    if (-not $grew) { break }
  }

  # Unit spans: the if-statement that encloses each literal Use-Unit declaration.
  $units = New-Object System.Collections.ArrayList
  foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Use-Unit' }, $true)) {
    $el = @($c.CommandElements)
    if ($el.Count -lt 2) { continue }
    $id = if ($el[1] -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $el[1].Value } else { '<computed>' }
    $p = $c.Parent
    while ($p -and -not ($p -is [System.Management.Automation.Language.IfStatementAst])) { $p = $p.Parent }
    if ($p) { [void]$units.Add([pscustomobject]@{ Id = $id; Start = $p.Extent.StartLineNumber; End = $p.Extent.EndLineNumber }) }
  }

  $reads = New-Object System.Collections.ArrayList
  foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Join-Path' }, $true)) {
    $rel = Resolve-TcLivePath -Expr $c -Known $known
    if ($null -eq $rel -or $rel -eq '' -or $rel -eq $RootRel) { continue }
    $line = $c.Extent.StartLineNumber
    $hits = @($units | Where-Object { $line -ge $_.Start -and $line -le $_.End })
    $unit = '<outside-any-unit>'
    if ($hits.Count) {
      $best = $hits[0]
      foreach ($h in $hits) { if (($h.End - $h.Start) -lt ($best.End - $best.Start)) { $best = $h } }
      $unit = $best.Id
    }
    [void]$reads.Add([pscustomobject]@{ Rel = $rel; Line = $line; Unit = $unit })
  }
  return [pscustomobject]@{ Reads = @($reads.ToArray()); Units = @($units.ToArray()); Vars = $known }
}

# A DERIVED artifact lives under a directory named out\ or public\. Source and rule files do not, and
# they are deliberately outside the class: they travel by the same road as the code under test.
$script:TcDerivedRe = '(^|\\)(out|public)(\\|$)'

function Get-TcPathRoad {
  <# Which road does $Path reach a checkout by: TRACKED (commit), IGNORED (copy), or OTHER.

     THE GLOB RULE, and it is the part that needed measuring (2026-09-11). A case that enumerates
     out\comparison-*.json reads whatever is ON DISK, so the pattern is classified by its matches rather
     than by the pattern text. grocery\out\comparison-2026-08-08.json is TRACKED - one stray board
     committed before the ignore pattern existed, and .gitignore does not untrack a file already in the
     index - so "does any tracked path match this glob" answers TRACKED for the board glob and is wrong:
     the board the case actually picks is the NEWEST, which on every live machine is an ignored one. A
     detector cannot know a case's sort order, so the conservative and correct reading is that if ANY
     match on disk arrives by copy, the glob arrives by copy.

     $DiskMatches and $IsIgnored are parameters so this is decidable from frozen inputs - the verdict
     turns on this function, and a rule that only the live tree can exercise has no fixture. #>
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)]$TrackedSet,
    [Parameter(Mandatory=$true)][scriptblock]$DiskMatches,
    [Parameter(Mandatory=$true)][scriptblock]$IsIgnored
  )
  if ($Path -notmatch '[*?]') {
    if ($TrackedSet.Contains($Path)) { return 'TRACKED' }
    if (& $IsIgnored $Path) { return 'IGNORED' }
    return 'OTHER'
  }
  $onDisk = @(& $DiskMatches $Path)
  foreach ($d in $onDisk) { if (& $IsIgnored $d) { return 'IGNORED' } }
  foreach ($d in $onDisk) { if ($TrackedSet.Contains([string]$d)) { return 'TRACKED' } }
  # Nothing on disk - a bare checkout. Fall back to the pattern text, which .gitignore's own wildcards
  # match, so the class is still decidable where the data has not been seeded. IGNORED is asked FIRST for
  # the same reason as above, and the case that asserts it caught this arm second: the stray tracked
  # comparison-2026-08-08.json also matches the glob here, so a tracked-first order answered TRACKED for
  # the board glob in every unseeded checkout - the live tree hid it, because there the disk branch ran.
  if (& $IsIgnored $Path) { return 'IGNORED' }
  foreach ($t in $TrackedSet) { if ($t -like $Path) { return 'TRACKED' } }
  return 'OTHER'
}

function Get-TcCrossRoadUnits {
  <# The units that read a tracked DERIVED artifact AND a gitignored path. $Classify takes a
     repo-relative path and returns 'TRACKED', 'IGNORED' or 'OTHER'. It is a parameter so the self-test
     can freeze the answer instead of resting on this checkout's git state. #>
  param([Parameter(Mandatory=$true)]$Reads, [Parameter(Mandatory=$true)][scriptblock]$Classify)
  $rows = New-Object System.Collections.ArrayList
  foreach ($r in $Reads) {
    $cls = [string](& $Classify $r.Rel)
    [void]$rows.Add([pscustomobject]@{ Class = $cls; Rel = $r.Rel; Line = $r.Line; Unit = $r.Unit })
  }
  $out = New-Object System.Collections.ArrayList
  foreach ($g in ($rows | Group-Object Unit)) {
    $byCommit = @($g.Group | Where-Object { $_.Class -eq 'TRACKED' -and $_.Rel -match $script:TcDerivedRe })
    $byCopy   = @($g.Group | Where-Object { $_.Class -eq 'IGNORED' })
    if ($byCommit.Count -gt 0 -and $byCopy.Count -gt 0) {
      [void]$out.Add([pscustomobject]@{
        Unit = $g.Name
        ByCommit = @($byCommit | ForEach-Object { $_.Rel } | Sort-Object -Unique)
        ByCopy   = @($byCopy   | ForEach-Object { $_.Rel } | Sort-Object -Unique)
      })
    }
  }
  return [pscustomobject]@{ Rows = @($rows.ToArray()); Findings = @($out.ToArray()) }
}

# ---- self-test ------------------------------------------------------------------------------------
if ($SelfTest) {
  $fail = 0
  function XrT([string]$m, [bool]$cond, [string]$got) {
    if ($cond) { Write-Output ('  ok    ' + $m) }
    else { Write-Output ('  FAILED  ' + $m + '   got: ' + $got); $script:fail++ }
  }

  # THE EXPECTED PATHS, NAMED ONCE. These are fixture VALUES this suite compares against - nothing here
  # opens any of them, and the detector under test never touches a disk path of its own. Hoisted to
  # variables rather than repeated inline for two reasons: several of the assertions below are
  # line-continued, where a trailing comment is not legal, and one spelling of each path is easier to
  # keep true than seven. ops\audit-cross-module-reach.ps1's per-line opt-out is the sanctioned
  # declaration for exactly this, and it requires a reason.
  $fxMatchBaseline = 'grocery\out\audit\match-baseline.json'      # reach-fixture-ok: expected VALUE of a resolver assertion; nothing here opens it
  $fxBoardGlob     = 'grocery\out\comparison-*.json'              # reach-fixture-ok: frozen fixture path handed to a pure classifier; nothing here opens it
  $fxStrayBoard    = 'grocery\out\comparison-2026-08-08.json'     # reach-fixture-ok: the real stray TRACKED board, frozen as fixture data
  $fxNewBoard      = 'grocery\out\comparison-2026-09-11.json'     # reach-fixture-ok: frozen fixture data for the glob rule
  $fxReport        = 'grocery\out\capture-evictions.json'         # reach-fixture-ok: frozen fixture data for the glob rule
  $fxPublicBoard   = 'public\board.json'                          # a published artefact, not a module internal

  # A FROZEN CLASSIFIER. The fixtures must not rest on this checkout's git state: the same text has to
  # score the same in a bare checkout, in a worktree and on the bot's box.
  $frozen = {
    param($p)
    switch -Regex ($p) {
      '\\out\\comparison-'            { 'IGNORED'; break }
      '\\out\\capture-evictions-stamp' { 'IGNORED'; break }
      '\\out\\recipe-board\.json$'    { 'IGNORED'; break }
      default                         { 'TRACKED' }
    }
  }

  # MUST FIRE: the founding shape, frozen from u108 as it stood before the 2026-09-11 repair - a TRACKED
  # report under out\ decided against a board that arrives by copy. Single-quoted literals with doubled
  # inner quotes: a fixture built by concatenation binds as several arguments and runs on a fragment.
  $mfLines = @(
    'if (Use-Unit ''u-founding'') {'
    '$ceReport = Join-Path $root ''out\capture-evictions.json'''
    '$ceCmps = Get-ChildItem (Join-Path $root ''out\comparison-*.json'')'
    '}'
  )
  $mf = ($mfLines -join "`n")
  $mfReads = Get-TcLiveReads -Text $mf
  XrT 'MUST FIRE: the pre-repair u108 shape parses and both of its reads resolve' `
      ($null -ne $mfReads -and $mfReads.Reads.Count -eq 2) `
      ("reads=" + $(if ($null -eq $mfReads) { 'PARSE-FAILED' } else { $mfReads.Reads.Count }))
  $mfRes = Get-TcCrossRoadUnits -Reads $mfReads.Reads -Classify $frozen
  XrT 'MUST FIRE: a tracked report under out\ decided against a copied board is flagged, and the unit is NAMED' `
      ($mfRes.Findings.Count -eq 1 -and $mfRes.Findings[0].Unit -eq 'u-founding') `
      ("findings=" + $mfRes.Findings.Count)
  XrT 'MUST FIRE: the finding says WHICH file travels by each road, so the repair is readable from the report' `
      ($mfRes.Findings.Count -eq 1 -and ($mfRes.Findings[0].ByCommit -join ',') -match 'capture-evictions\.json' -and ($mfRes.Findings[0].ByCopy -join ',') -match 'comparison-') `
      ('byCommit=' + ($mfRes.Findings | ForEach-Object { $_.ByCommit -join ',' }))

  # MUST NOT FIRE: the REPAIRED shape. Both inputs arrive by copy, which is the whole point of the stamp,
  # so this legal input must be silent or the detector argues against the fix that created it.
  $okLines = @(
    'if (Use-Unit ''u-repaired'') {'
    '$ceStamp = Join-Path $root ''out\capture-evictions-stamp.json'''
    '$ceCmps = Get-ChildItem (Join-Path $root ''out\comparison-*.json'')'
    '}'
  )
  $okReads = Get-TcLiveReads -Text ($okLines -join "`n")
  $okRes = Get-TcCrossRoadUnits -Reads $okReads.Reads -Classify $frozen
  XrT 'MUST NOT FIRE: a unit whose two inputs BOTH arrive by copy (the stamp repair) is silent' `
      ($okRes.Findings.Count -eq 0) ("findings=" + $okRes.Findings.Count)

  # MUST NOT FIRE: tracked SOURCE and tracked RULE files beside a copied board. This is most of the suite
  # (139 of 147 literal reads on 2026-09-11), and counting it would make the report a list nobody reads.
  $srcLines = @(
    'if (Use-Unit ''u-source-only'') {'
    '$a = Get-Content (Join-Path $root ''compare-deals.ps1'') -Raw'
    '$b = Get-Content (Join-Path $root ''commodities.json'') -Raw'
    '$c = Get-ChildItem (Join-Path $root ''out\comparison-*.json'')'
    '}'
  )
  $srcReads = Get-TcLiveReads -Text ($srcLines -join "`n")
  $srcRes = Get-TcCrossRoadUnits -Reads $srcReads.Reads -Classify $frozen
  XrT 'MUST NOT FIRE: tracked SOURCE and RULE files beside a copied board are not the class - they travel with the code under test' `
      ($srcRes.Findings.Count -eq 0) ("findings=" + $srcRes.Findings.Count)

  # MUST NOT FIRE: a FIXTURE root. A frozen input under $fix or a temp directory is not a live read at
  # all, and a detector that resolved it would flag every hermetic case in the suite.
  $fxLines = @(
    'if (Use-Unit ''u-fixture'') {'
    '$fx = Join-Path $env:TEMP ''probe'''
    '$p = Join-Path $fx ''out\capture-evictions.json'''
    '$q = Join-Path $fx ''out\comparison-2026-01-01.json'''
    '}'
  )
  $fxReads = Get-TcLiveReads -Text ($fxLines -join "`n")
  XrT 'MUST NOT FIRE: a path under a TEMP fixture root resolves to nothing, so frozen inputs stay out of the population' `
      ($fxReads.Reads.Count -eq 0) ("reads=" + $fxReads.Reads.Count)

  # CLEAN TWIN: the TRANSITIVE root resolution still works. This is the mechanism the whole population
  # rests on - it took the census from 147 reads to 253 - and a one-pass resolver would silently shrink
  # the population to the paths that happen to be joined straight off $root. A POSITIVE assertion: the
  # two-level path is RESOLVED, and to the right place.
  $twLines = @(
    'if (Use-Unit ''u-two-level'') {'
    '$auditDir = Join-Path $root ''out\audit'''
    '$base = Join-Path $auditDir ''match-baseline.json'''
    '}'
  )
  $twReads = Get-TcLiveReads -Text ($twLines -join "`n")
  $twRels = @($twReads.Reads | ForEach-Object { $_.Rel })
  XrT ('CLEAN TWIN: a path joined off a variable that was itself joined off $root still resolves, to ' + $fxMatchBaseline) `
      ($twRels -contains $fxMatchBaseline) ('resolved=' + ($twRels -join '; '))

  # CLEAN TWIN: the resolver reaches a FIXPOINT rather than making one pass. Found by a mutation probe
  # (2026-09-11), and it took two attempts to write, which is the useful part. The two-level case above
  # resolves under a single pass because its assignments happen to sit in dependency order, so `$pass -le 1`
  # SURVIVED. The first repair put the dependency the other way round and STILL survived: the reads are
  # collected AFTER the loop, so a read off a variable that one pass did resolve comes out whatever the
  # loop did. The case has to be deep enough that the READ ITSELF depends on the second pass - $mid is
  # read by the last line and is assigned from $deep, which is declared below it. A POSITIVE assertion:
  # the path still comes out, and to the right place.
  $fpLines = @(
    'if (Use-Unit ''u-fixpoint'') {'
    '$mid = Join-Path $deep ''audit'''
    '$deep = Join-Path $root ''out'''
    '$f = Join-Path $mid ''match-baseline.json'''
    '}'
  )
  $fpReads = Get-TcLiveReads -Text ($fpLines -join "`n")
  $fpRels = @($fpReads.Reads | ForEach-Object { $_.Rel })
  XrT 'CLEAN TWIN: a variable assigned from one declared LATER in the file still resolves, so the resolver runs to a fixpoint rather than one pass' `
      ($fpRels -contains $fxMatchBaseline) ('resolved=' + ($fpRels -join '; '))

  # MUST NOT FIRE: a tracked DERIVED artifact read with NO copied path beside it. Also found by the
  # mutation probe: with no such case, widening the by-copy arm to accept TRACKED survived. This is the
  # live u085 shape - out\verification-history.json is tracked and derived, and its case asks a property
  # of that file ALONE (does every banked run declare its store_scope). Nothing about it can lag behind a
  # board, so it is not the class, and firing on it would put an unrepairable entry in the baseline.
  $soloLines = @(
    'if (Use-Unit ''u-tracked-alone'') {'
    '$vh = Join-Path $root ''out\verification-history.json'''
    '$src = Get-Content (Join-Path $root ''build-verification-sample.ps1'') -Raw'
    '}'
  )
  $soloReads = Get-TcLiveReads -Text ($soloLines -join "`n")
  $soloRes = Get-TcCrossRoadUnits -Reads $soloReads.Reads -Classify $frozen
  XrT 'MUST NOT FIRE: a tracked artifact under out\ read with NO copied path beside it is not the class - there is no second road for it to disagree with' `
      ($soloRes.Findings.Count -eq 0 -and $soloReads.Reads.Count -eq 2) `
      ('findings=' + $soloRes.Findings.Count + ' reads=' + $soloReads.Reads.Count)

  # CLEAN TWIN: Split-Path $root -Parent still reaches the repo root, which is how the suite names
  # public\ and meal-prep\ files. Positive: the resolved path is the repo-relative one, not $null.
  $spLines = @(
    'if (Use-Unit ''u-parent'') {'
    '$rr = Split-Path $root -Parent'
    '$pb = Join-Path $rr ''public\board.json'''   # reach-fixture-ok: fixture TEXT handed to the parser, not a path this file opens
    '}'
  )
  $spReads = Get-TcLiveReads -Text ($spLines -join "`n")
  $spRels = @($spReads.Reads | ForEach-Object { $_.Rel })
  XrT 'CLEAN TWIN: Split-Path $root -Parent still resolves to the repo root, so public\board.json is reached as public\board.json' `
      ($spRels -contains $fxPublicBoard) ('resolved=' + ($spRels -join '; '))

  # A unit id must be attributed to the INNERMOST enclosing unit, or a finding names the wrong case and
  # the baseline entry cannot be found by whoever has to repair it.
  $nestLines = @(
    'if (Use-Unit ''u-outer'') {'
    '$x = Join-Path $root ''compare-deals.ps1'''
    'if (Use-Unit ''u-inner'') {'
    '$r = Join-Path $root ''out\capture-evictions.json'''
    '$b = Get-ChildItem (Join-Path $root ''out\comparison-*.json'')'
    '}'
    '}'
  )
  $nestReads = Get-TcLiveReads -Text ($nestLines -join "`n")
  $nestRes = Get-TcCrossRoadUnits -Reads $nestReads.Reads -Classify $frozen
  XrT 'a finding is attributed to the INNERMOST unit that encloses it, so the baseline entry names the case somebody has to repair' `
      ($nestRes.Findings.Count -eq 1 -and $nestRes.Findings[0].Unit -eq 'u-inner') `
      ('units=' + (($nestRes.Findings | ForEach-Object { $_.Unit }) -join ','))

  # ---- the glob rule, on frozen inputs --------------------------------------------------------------
  # The live verdict turns on Get-TcPathRoad, so it is driven here from frozen sets rather than from this
  # checkout's git state. The tracked set holds the REAL stray: grocery\out\comparison-2026-08-08.json is
  # committed, because .gitignore does not untrack a file already in the index.
  $frozenTracked = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  [void]$frozenTracked.Add($fxStrayBoard)
  [void]$frozenTracked.Add($fxReport)
  $frozenIgnored = { param($p) return ([string]$p -match 'comparison-2026-09' -or [string]$p -match 'comparison-\*' -or [string]$p -match 'capture-evictions-stamp') }
  $frozenDisk = {
    param($p)
    if ([string]$p -eq $fxBoardGlob) {
      return @($fxStrayBoard, $fxNewBoard)
    }
    return @()
  }

  # MUST FIRE: the stray tracked board must NOT make the board glob read as arriving by commit. This is
  # the bug this function was factored out to fix: "does any tracked path match the glob" answered
  # TRACKED for out\comparison-*.json, which dropped u108 out of the findings and invented a different
  # one - a detector quietly measuring something else.
  XrT 'MUST FIRE: a glob matching ONE stray tracked board and one ignored board arrives by COPY, not by COMMIT' `
      ((Get-TcPathRoad -Path $fxBoardGlob -TrackedSet $frozenTracked -DiskMatches $frozenDisk -IsIgnored $frozenIgnored) -eq 'IGNORED') `
      ('road=' + (Get-TcPathRoad -Path $fxBoardGlob -TrackedSet $frozenTracked -DiskMatches $frozenDisk -IsIgnored $frozenIgnored))

  # CLEAN TWIN: a plain tracked path still reads as arriving by COMMIT. The positive the glob rule was
  # most likely to have broken on its way past.
  XrT 'CLEAN TWIN: a literal tracked path still reads as arriving by COMMIT' `
      ((Get-TcPathRoad -Path $fxReport -TrackedSet $frozenTracked -DiskMatches $frozenDisk -IsIgnored $frozenIgnored) -eq 'TRACKED') `
      ('road=' + (Get-TcPathRoad -Path $fxReport -TrackedSet $frozenTracked -DiskMatches $frozenDisk -IsIgnored $frozenIgnored))

  # A BARE CHECKOUT still decides. With nothing on disk the pattern text is matched against .gitignore's
  # own wildcards, so a worktree that was never seeded does not silently drop the class.
  XrT 'a glob with NOTHING on disk still resolves its road from the pattern, so an unseeded checkout is not silently clean' `
      ((Get-TcPathRoad -Path $fxBoardGlob -TrackedSet $frozenTracked -DiskMatches { @() } -IsIgnored $frozenIgnored) -eq 'IGNORED') `
      ('road=' + (Get-TcPathRoad -Path $fxBoardGlob -TrackedSet $frozenTracked -DiskMatches { @() } -IsIgnored $frozenIgnored))

  # A file this detector cannot parse is BLIND, never clean. The live path turns this into exit 3.
  $badParse = Get-TcLiveReads -Text "if (Use-Unit 'u-broken') { `$x = Join-Path `$root 'a.json'"
  XrT 'a suite that does not parse returns BLIND rather than an empty, clean-looking answer' `
      ($null -eq $badParse) ('got=' + $(if ($null -eq $badParse) { 'null' } else { 'a result' }))

  if ($fail) { Write-Output ("crossroad-reads self-test: FAIL ({0} of 15 cases failed)" -f $fail); exit 2 }
  Write-Output 'crossroad-reads self-test: PASS (15 cases - the founding cross-road shape fires, the stamp repair and tracked source stay silent, and both root resolutions hold)'
  exit 0
}

# ---- live path ------------------------------------------------------------------------------------
Clear-TcGitRepoEnv   # a pre-push hook in a linked worktree exports GIT_DIR to everything it spawns

$suite = if ($SuitePath) { $SuitePath } else { $DEFAULT_SUITE }
if (-not (Test-Path -LiteralPath $suite)) {
  Write-Output ("crossroad-reads: BLIND - the suite {0} is not here, so nothing was examined. That is not a clean report." -f $suite)
  Exit-Guard -Name 'crossroad-reads' -Summary 'blind=no-suite' -Code 3
}
$suiteText = [IO.File]::ReadAllText($suite)
$parsed = Get-TcLiveReads -Text $suiteText
if ($null -eq $parsed) {
  Write-Output ("crossroad-reads: BLIND - {0} did not parse, so its reads could not be resolved. A parse failure is not an empty finding list." -f (Split-Path $suite -Leaf))
  Exit-Guard -Name 'crossroad-reads' -Summary 'blind=parse-error' -Code 3
}
if ($parsed.Units.Count -eq 0) {
  Write-Output 'crossroad-reads: BLIND - no Use-Unit declaration resolved, which means this discovery is broken rather than that the suite is clean.'
  Exit-Guard -Name 'crossroad-reads' -Summary 'blind=no-units' -Code 3
}

# THE CLASSIFIER, git, AND IT REDIRECTS NOTHING. Under $ErrorActionPreference = 'Stop' every redirect of
# a native child's stderr makes its first stderr line a terminating throw, and a catch around it keeps
# the caller alive while throwing the child's answer away (.claude\rules\ops-and-gates.md). So neither
# call here is one that TALKS on stderr in the ordinary case: the tracked set is read ONCE from a plain
# `git ls-files`, and `check-ignore -q` is silent on both of its answers and exits 1 rather than writing.
# `ls-files --error-unmatch` is deliberately not used - a pathspec miss is its stderr, and a miss is the
# ANSWER here rather than a failure.
# A MISSING git is a could-not-evaluate, not a finding. Under EAP=Stop `& git` on a box without it throws
# CommandNotFoundException, which leaves this script exiting 1 - and 1 here means "a NEW cross-road unit".
# That is the decode-the-number trap ops-and-gates.md names, so the absence is asked about directly.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Write-Output 'crossroad-reads: BLIND - git is not on PATH, so which road a file travels by could not be established.'
  Exit-Guard -Name 'crossroad-reads' -Summary 'blind=no-git' -Code 3
}
$lsOut = @(& git -C $repoRoot ls-files)
if ($LASTEXITCODE -ne 0 -or $lsOut.Count -eq 0) {
  Write-Output 'crossroad-reads: BLIND - git ls-files returned nothing, so tracked and copied could not be told apart. An empty tracked set is a broken read, not a clean tree.'
  Exit-Guard -Name 'crossroad-reads' -Summary 'blind=no-tracked-set' -Code 3
}
# [StringComparer]::Ordinal: a bare @{} is case-insensitive, and these keys arrived from outside.
$trackedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
foreach ($t in $lsOut) { [void]$trackedSet.Add(([string]$t -replace '/', '\')) }

$script:gitFailed = $false
$isIgnored = {
  param($p)
  & git -C $repoRoot check-ignore -q -- ([string]$p)
  $ig = $LASTEXITCODE
  if ($ig -gt 1) { $script:gitFailed = $true; return $false }
  return ($ig -eq 0)
}
$diskMatches = {
  param($p)
  $dir = Join-Path $repoRoot (Split-Path $p -Parent)
  if (-not (Test-Path -LiteralPath $dir)) { return @() }
  $m = @(Get-ChildItem -LiteralPath $dir -Filter (Split-Path $p -Leaf) -File -ErrorAction SilentlyContinue)
  return @($m | ForEach-Object { $_.FullName.Substring($repoRoot.Length + 1) })
}
$classify = {
  param($p)
  return (Get-TcPathRoad -Path $p -TrackedSet $trackedSet -DiskMatches $diskMatches -IsIgnored $isIgnored)
}

$result = Get-TcCrossRoadUnits -Reads $parsed.Reads -Classify $classify

if ($script:gitFailed) {
  Write-Output 'crossroad-reads: BLIND - git check-ignore exited above 1, so tracked and copied could not be told apart.'
  Exit-Guard -Name 'crossroad-reads' -Summary 'blind=git-failed' -Code 3
}

$now = @($result.Findings | ForEach-Object { $_.Unit } | Sort-Object -Unique)
$derivedTracked = @($result.Rows | Where-Object { $_.Class -eq 'TRACKED' -and $_.Rel -match $script:TcDerivedRe } | ForEach-Object { $_.Rel } | Sort-Object -Unique)
$copied = @($result.Rows | Where-Object { $_.Class -eq 'IGNORED' } | ForEach-Object { $_.Rel } | Sort-Object -Unique)

$NOTE = 'Baseline for ops\audit-crossroad-reads.ps1: the grocery\test-auditors.ps1 units that read BOTH a tracked artifact under out\ or public\ (which reaches a checkout by COMMIT) and a gitignored path (which reaches it by COPY). Written by -Update, a deliberate act after a real repair. The ratchet is BY NAME: a new unit fails the audit, and a unit that disappears is reported so this file can be trimmed. It may only ever get shorter.'

if ($Update) {
  # THE DEFENCE SURVIVES AN UPDATE. Every entry here is a site somebody decided to keep, and the reason
  # is the only part of the record a re-run cannot regenerate. -Update carries `why` forward for a unit
  # that is still on both roads and drops it with the unit; a new entry gets the placeholder, which is
  # what makes an undefended one visible in the diff that adds it.
  $priorWhy = @{}
  if (Test-Path -LiteralPath $BASELINE_FILE) {
    try {
      foreach ($u in (Read-JsonFile $BASELINE_FILE).units) {
        if ($u -and $u.unit -and $u.why) { $priorWhy[[string]$u.unit] = [string]$u.why }
      }
    } catch { }
  }
  $doc = [ordered]@{
    readme  = $NOTE
    written = (Get-Date).ToString('yyyy-MM-dd')
    units   = @($result.Findings | Sort-Object Unit | ForEach-Object {
      $why = if ($priorWhy.ContainsKey($_.Unit)) { $priorWhy[$_.Unit] } else { 'UNDEFENDED - say here why this unit keeps both roads, or repair it.' }
      [ordered]@{ unit = $_.Unit; why = $why; by_commit = @($_.ByCommit); by_copy = @($_.ByCopy) }
    })
  }
  [void](Write-TcLfFile -Path $BASELINE_FILE -Text (($doc | ConvertTo-Json -Depth 6)))
  Write-Output ("crossroad-reads: baseline rewritten with {0} unit(s)" -f $now.Count)
  exit 0
}

$base = @()
if (Test-Path -LiteralPath $BASELINE_FILE) {
  try { $base = @((Read-JsonFile $BASELINE_FILE).units | Where-Object { $_ } | ForEach-Object { [string]$_.unit }) } catch { $base = @() }
}
$added   = @($now  | Where-Object { $base -notcontains $_ })
$cleared = @($base | Where-Object { $now  -notcontains $_ })

# A DISCOVERED target set prints what it RESOLVED: "no findings" and "the walk matched nothing" are the
# same bytes otherwise, and that shape has bitten this estate at least five separate times.
Write-Output ("crossroad-reads: {0} unit(s) and {1} live path expression(s) resolved in {2}; {3} tracked artifact(s) under out\ or public\ read live, {4} copied path(s); {5} unit(s) on both roads, baseline {6}" -f `
  $parsed.Units.Count, $parsed.Reads.Count, (Split-Path $suite -Leaf), $derivedTracked.Count, $copied.Count, $now.Count, $base.Count)
foreach ($d in $derivedTracked) { Write-Output ('  by COMMIT: ' + $d) }
foreach ($c in $cleared) { Write-Output ('  cleared: ' + $c + '  (ratchet tightened - re-run with -Update to trim the baseline)') }
foreach ($f in ($result.Findings | Sort-Object Unit)) {
  $tag = if ($added -contains $f.Unit) { '  ! NEW: ' } else { '  known: ' }
  Write-Output ($tag + $f.Unit)
  foreach ($x in $f.ByCommit) { Write-Output ('        by COMMIT  ' + $x) }
  foreach ($x in $f.ByCopy)   { Write-Output ('        by COPY    ' + $x) }
}
if ($added.Count) {
  Write-Output '  This case decides its verdict by comparing a file that reaches a checkout by COMMIT with one that'
  Write-Output '  reaches it by COPY. The two roads move independently, so the case measures which road ran last:'
  Write-Output '  a chain that regenerates the tracked artifact in the main checkout and commits its source only'
  Write-Output '  refuses every push from every worktree holding the newer copied file, for a reason no pusher'
  Write-Output '  caused and none can fix by editing code. That happened on 2026-09-11 and cost about 17 hours.'
  Write-Output '  Fix: put both inputs on ONE road. Have the producer write a gitignored STAMP beside the copied'
  Write-Output '  file, list it in .worktreeinclude, and read that - grocery\audit-capture-eviction.ps1 and unit'
  Write-Output '  u108 are the exemplar (design\PLAN-capture-eviction-stamp-2026-09-11.md). Do NOT repair it by'
  Write-Output '  untracking an artifact the daily bot commits: that was measured, and the untrack commit collides'
  Write-Output '  with the bot''s own autostash rebase and leaves the main checkout unable to commit at all.'
}
Write-GuardComplete -Name 'crossroad-reads' -Summary ("resolved={0} reads={1} tracked-derived={2} copied={3} both-roads={4} new={5}" -f `
  $parsed.Units.Count, $parsed.Reads.Count, $derivedTracked.Count, $copied.Count, $now.Count, $added.Count)
if ($added.Count) { exit 1 }
exit 0
