<#
  audit-board-clock.ps1 - the AD SET's date is a NAME, never "now".

  SCOPE OF A CLEAN REPORT: UNSOUND and INCOMPLETE.
    UNSOUND: it reads the PowerShell AST of tracked .ps1 files under grocery\, ops\, lib\, graph\ and meal-prep\ and
    follows the ad-set date only along the roads listed under SOURCES and PROPAGATION. A date that reaches a clock use
    any other way is invisible, so silence is not proof: through a function's RETURN value (the founding C10 shape in
    ops\rehearse-chain.ps1 returned the name-parsed date from Get-RhNewestBoardDate), through a hashtable or object
    field other than week_of, through an index read ($x['week_of']), through $Matches, across files, or out of a
    Python script (.py is out of scope in v1). Source (d) of the plan, a date regex-captured out of a comparison-,
    ads-, candidates-, flagged-, provenance-withheld- or price-table- FILE NAME, is NOT implemented: the real shape
    (a [regex]::Match on .Name, then .Groups[1].Value, then a function return) crosses three statements and a return,
    and no cheap same-statement rule caught it. The taint is keyed by variable NAME and file-wide, so a name tainted
    in one function is tainted in every function of that file.
    INCOMPLETE: a finding is a CANDIDATE. The rule is syntactic: an ad-set date compared with a value that is not
    another ad-set date and not a literal, used in date arithmetic, or passed to a clock-named parameter. Whether
    that is a real clock use is a reading, which is why `# board-clock:allow <reason>` exists.

  WHY THIS EXISTS (2026-09-26, design\PLAN-board-clock-2026-09-26.md, W6). A board's file name comparison-<D>.json
  and its week_of field are the AD SET's date: D is the newest ads-<D>.json's `today`, written only on a day a
  weekly ad is pulled, so it lags the real date. On 2026-09-26 it lagged 3 days and every consumer that used it as
  "now" went wrong: ended sales stayed priced (C1), the 90-day window stretched to 93 (C5), the chain rehearsal
  refused every push on a false blind (C10), and a stopped-feed audit read fresh (C11). The branch gave the board
  three named dates - week_of (which ad set), judged_on (the real date validity was judged at, compare-deals
  -JudgeDate) and per-cell as_of (when a price was read) - and lib\board-clock.ps1 is their one reader. This file
  stops the NEXT script from borrowing the ad set's name as a clock. Line regexes were measured and rejected
  first: the date flows through a variable ($today = $ads.today ... hundreds of lines later -BoardDate
  ([string]$today)), and a per-line pattern missed every real defect.

  SOURCES (an expression whose VALUE is an ad-set date):
    (a) a member read of week_of - never an assignment's left side, and a hashtable literal's key is not a member
    (b) a member read of today, the ads file's field ($ads.today). A STATIC member is not one: [datetime]::Today is
        the real clock. (a) and (b) match the member name CASE-SENSITIVELY, as the JSON fields are spelled: a
        PascalCase .Today is a PowerShell object's property (grocery\capture-policy-lib.ps1's $plan.Today is the
        real date), and matching it was measured as a false positive on the first run. A JSON field read under
        another casing is therefore missed - one more reason silence proves nothing.
    (c) any variable named BoardToday (compare-deals' script-scoped copy). NOTE: on this branch the engine assigns
        it the JUDGE date, so its own reads are findings by name; they are counted in the mark, see THE MARK.
  PROPAGATION, to a fixpoint within one file: a variable assigned (or a parameter defaulted) from an expression
    whose VALUE carries a source. Value-preserving wrappers carry it: parens, casts ([string], [datetime]), "$x",
    $(...), .Date, .ToString(), .Substring(), .Trim*(), .Add*(), [datetime]::Parse/ParseExact(arg 0), Get-Date
    -Date/positional, and an if/else whose any branch carries. A value merely BUILT from one does NOT carry: a
    Join-Path, a '+' concatenation or a hashtable holding it is a path or a record, not a date. That is the line
    between a clock use and the ~60 name-only readers (newest-file pick, sibling lookup) the plan left alone.
  SINKS (each is a finding with file:line and the expression):
    (s1) compare   -lt/-le/-gt/-ge (either case form) with exactly ONE side carrying, and the other side not a
                   literal. Ad-set vs ad-set, or vs a literal, is ORDERING and is silent. -eq is NOT a sink (2026-09-26,
                   measured on its first run): all 8 -eq findings on the tree asked "is this the same ad set?" through a
                   second name this detector cannot follow (a file-name regex, $Matches, a parameter, a record field),
                   and an equality cannot express an age or an expiry, which is the defect this hunts.
    (s2) date-math .AddDays/.AddMonths/.AddYears/.AddHours/.Subtract on or with a carrier; New-TimeSpan with a
                   carrier; a '-' with exactly one side carrying. The brief's narrower '-' conditions (a .TotalDays
                   read, a [datetime] operand) are subsumed: a string date cannot be subtracted from anything, so a
                   carrying operand of '-' is date arithmetic whatever else is on the line.
    (s3) param     a carrier passed to -Today, -BoardDate, -AsOf, -Now, -JudgeDate, -WallClock or -Date. Get-Date's
                   own -Date is a CONVERSION, not a sink: its result carries, so a later sink still sees it.
  ALLOW: `# board-clock:allow <reason>` on the finding's line or the line above it removes that finding. It is read
    from COMMENT tokens, so a string that spells it is not a marker. A marker with no reason silences nothing and
    is itself a finding (allow-no-reason).

  THE WALK. `git ls-files '*.ps1'`, then the files under the root whose path BELOW the root (lib\tree-walk.ps1)
  starts \grocery\, \ops\, \lib\, \graph\ or \meal-prep\, pruning grocery\archive\, grocery\out\, nested worktrees
  and .git, and never this file. A file that spells no source and no marker is WALKED but not PARSED (it cannot
  hold a finding). A parsed file with a parse error is a COULD-NOT-LOOK: the run exits 3 and names it, never clean.

  THE MARK (ops\audit-board-clock-mark.json). A ratchet, og-11: it holds the COUNT and the KEY of every known
  finding, the key being the path below the root, the sink kind and the whitespace-normalised expression - never a
  line number, so an edit that moves lines is not a new finding. A plain run never writes the mark. A NEW key exits 1
  and names only the new findings (lib\ratchet.ps1 Compare-TcRatchetSites, so a fix plus a new site in one change is
  still red). A fall is SPOKEN and the mark kept; -Tighten records a believable fall (Test-RatchetMove), -AcceptDrop
  one it would refuse. An absent or unreadable mark is a could-not-look (exit 3) unless -Tighten seeds it.
  DAY ONE, measured 2026-09-26 on claude/board-clock-detector (branched from a47a2fe43, the board-clock W1-W5 fixes)
  through this file from a linked worktree: git listed 891 tracked .ps1, 712 in scope, 75 parsed, 0 parse failures,
  17 findings, about 12 s. The mark starts at 17 and is NOT near zero, and the reason is the rule, not the tree:
    3 real clock uses, all low severity: grocery\sanity-check.ps1:65 (the look-back window, the plan's C14, named
      and left) and grocery\update-history.ps1:295 and :320 (the 21-day daily-history compaction window judges a
      history entry's age by its week_of against the real date; the survey did not list it).
    14 false positives. 8 are -eq identity checks between two ad-set names where the second name reached its
      variable by a road this file does not follow (a file-name regex, $Matches, a parameter, a record field):
      audit-coverage-gaps:580, audit-feed-week-parity:45, guards:702, purge-verdict-lows:142, sanity-check:99,
      update-history:93 and :94 (self-test lookups), rotate-free-dinners:132. Two more are ORDERING and distance
      between two ad-set names by the same blindness: board-drops:59 and audit-feed-week-parity:52. update-history:325
      buckets a week_of to its Monday. audit-price-mode:69 reads a per-store REGULAR file's week_of, which is that
      file's capture date, not an ad set. compare-deals:2435 reads BoardToday, which on this branch holds the JUDGE
      date (source (c) is by name). compare-deals:3696 passes the ad date to -BoardDate of Save-IdentityManifest,
      which only records it as a label.
  They are held by KEY, so none of them can hide a new one, and each fix or allow comment lowers the mark by -Tighten.

  EXIT CODES: 0 no new finding, 1 at least one new finding (or a -Tighten refused as implausible), 3 could not
  evaluate (nothing walked, a parse failure, no readable mark). Read the verdict LINE, not the number.

    ops\audit-board-clock.ps1              scan the tracked tree, hold the mark; writes NOTHING
    ops\audit-board-clock.ps1 -Tighten     the same, and record a believable fall (or seed an absent mark)
    ops\audit-board-clock.ps1 -AcceptDrop  record a fall lib\ratchet.ps1 would refuse
    ops\audit-board-clock.ps1 -SelfTest    the founding shapes, the name-only reads, the clean twins, the allow
                                           marker, the walk, and this script's live path against a temp tree
#>
# Declared inputs of its -SelfTest (lib\gate-input-key.ps1): every fixture is text in this file, written under a per-run
# temp dir, and the live-path cases run THIS script as a child against that temp tree and a temp mark. It reads nothing
# else of this repo. Verify with: powershell -File lib\gate-input-key.ps1 -VerifyDeclared <this file>
# gate-inputs: ops\audit-board-clock.ps1, lib\guard-contract.ps1, lib\ratchet.ps1, lib\lf-write.ps1, lib\tree-walk.ps1
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param([switch]$SelfTest, [switch]$Tighten, [switch]$AcceptDrop, [string]$Root = '', [string]$MarkFile = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ratchet.ps1')
. (Join-Path $repo 'lib\lf-write.ps1')    # Write-TcLfFile: the mark is TRACKED and stored LF
. (Join-Path $repo 'lib\tree-walk.ps1')   # Get-TcTreeFiles, Get-TcPathBelowRoot, New-TcWorktreeFixture

$MARK_FILE = if ($MarkFile) { $MarkFile } else { Join-Path $repo 'ops\audit-board-clock-mark.json' }

# THE NEEDLES ARE BUILT BY CONCATENATION, so no literal in this file spells what it hunts for (og-03).
$script:BC_SOURCE_MEMBERS = @(('week' + '_of'), ('to' + 'day'))
$script:BC_SOURCE_VARS = @('Board' + 'Today')
$script:BC_SINK_PARAMS = @(('To' + 'day'), ('Board' + 'Date'), ('As' + 'Of'), ('N' + 'ow'), ('Judge' + 'Date'), ('Wall' + 'Clock'), ('Da' + 'te'))
$script:BC_CMP_OPS = @('Ilt', 'Clt', 'Ile', 'Cle', 'Igt', 'Cgt', 'Ige', 'Cge')   # no -eq: see (s1) in the header
$script:BC_DATE_MATH = @('AddDays', 'AddMonths', 'AddYears', 'AddHours', 'Subtract')
$script:BC_CARRY_CALLS = @('ToString', 'Substring', 'Trim', 'TrimEnd', 'TrimStart', 'AddDays', 'AddMonths', 'AddYears', 'AddHours', 'ToShortDateString')
$script:BC_MARKER = 'board-clock' + ':allow'
$script:BC_ALLOW_RX = '(?i)^<?#\s*' + [regex]::Escape($script:BC_MARKER) + '(?![\w-])(.*?)(?:#>)?$'
# A file that spells none of these cannot hold a finding, so it is walked and not parsed.
$script:BC_PREFILTER = '(?i)week' + '_of|\.to' + 'day\b|Board' + 'Today|' + [regex]::Escape($script:BC_MARKER)
$script:BC_SCOPE_RX = '(?i)^\\(grocery|ops|lib|graph|meal-prep)\\'
$script:BC_WALK_EXCLUDE = '(?i)\\work' + 'trees\\|\\\.git\\|node_modules|^\\grocery\\archive\\|^\\grocery\\out\\'
$script:BC_KINDS = @('AssignmentStatementAst', 'ParameterAst', 'BinaryExpressionAst', 'InvokeMemberExpressionAst', 'CommandAst')

function Get-BcVarName {
  <# 'x' for $x or $script:x; '' for anything that is not a variable. #>
  param($Node)
  if ($null -eq $Node -or $Node.GetType().Name -ne 'VariableExpressionAst') { return '' }
  return ([string]$Node.VariablePath.UserPath -replace '^(?i)(script|global|local|private|using):', '')
}

function Get-BcMemberName {
  param($Node)
  if ($null -eq $Node.Member -or $Node.Member.GetType().Name -ne 'StringConstantExpressionAst') { return '' }
  return [string]$Node.Member.Value
}

function Test-BcDateType {
  param($TypeExpr)
  return ([string]$TypeExpr.TypeName.FullName -match '^(?i)(System\.)?DateTime$')
}

function Test-BcCarries {
  <# Does this expression's VALUE carry an ad-set date? Value-preserving wrappers only; a value BUILT from one
     (a path, a concatenation, a record) does not carry. $Tainted holds the tainted variable names. #>
  param($Node, $Tainted, [int]$Depth = 0)
  if ($null -eq $Node -or $Depth -gt 48) { return $false }
  $d = $Depth + 1
  switch -CaseSensitive ($Node.GetType().Name) {
    'PipelineAst' {
      $els = @($Node.PipelineElements)
      if ($els.Count -eq 1) { return (Test-BcCarries $els[0] $Tainted $d) }
      return $false
    }
    'CommandExpressionAst' { return (Test-BcCarries $Node.Expression $Tainted $d) }
    'ParenExpressionAst' { return (Test-BcCarries $Node.Pipeline $Tainted $d) }
    'ConvertExpressionAst' { return (Test-BcCarries $Node.Child $Tainted $d) }
    'SubExpressionAst' {
      $st = @($Node.SubExpression.Statements)
      if ($st.Count -eq 1) { return (Test-BcCarries $st[0] $Tainted $d) }
      return $false
    }
    'ExpandableStringExpressionAst' {
      $ne = @($Node.NestedExpressions)
      if ($ne.Count -eq 1 -and [string]::Equals([string]$Node.Value, [string]$ne[0].Extent.Text, [StringComparison]::Ordinal)) { return (Test-BcCarries $ne[0] $Tainted $d) }
      return $false
    }
    'VariableExpressionAst' {
      $v = Get-BcVarName $Node
      if (-not $v) { return $false }
      foreach ($s in $script:BC_SOURCE_VARS) { if ($v -ieq $s) { return $true } }
      return $Tainted.Contains($v)
    }
    'MemberExpressionAst' {
      if ($Node.Static) { return $false }   # [datetime]::Today is the REAL clock
      $m = Get-BcMemberName $Node
      foreach ($s in $script:BC_SOURCE_MEMBERS) { if ($m -ceq $s) { return $true } }   # case-SENSITIVE: see SOURCES
      if ($m -ieq 'Date') { return (Test-BcCarries $Node.Expression $Tainted $d) }
      return $false
    }
    'InvokeMemberExpressionAst' {
      $m = Get-BcMemberName $Node
      if ($Node.Static) {
        if ($Node.Expression.GetType().Name -eq 'TypeExpressionAst' -and (Test-BcDateType $Node.Expression) -and
            ($m -ieq 'Parse' -or $m -ieq 'ParseExact') -and @($Node.Arguments).Count -ge 1) { return (Test-BcCarries @($Node.Arguments)[0] $Tainted $d) }
        return $false
      }
      foreach ($c in $script:BC_CARRY_CALLS) { if ($m -ieq $c) { return (Test-BcCarries $Node.Expression $Tainted $d) } }
      return $false
    }
    'CommandAst' {
      # Get-Date -Date X (or positional X) converts; it does not judge.
      if ([string]$Node.GetCommandName() -ine 'Get-Date') { return $false }
      $els = @($Node.CommandElements)
      for ($k = 1; $k -lt $els.Count; $k++) {
        $e = $els[$k]
        if ($e.GetType().Name -eq 'CommandParameterAst') {
          if ([string]$e.ParameterName -ieq 'Date') {
            if ($null -ne $e.Argument) { return (Test-BcCarries $e.Argument $Tainted $d) }
            if ($k + 1 -lt $els.Count) { return (Test-BcCarries $els[$k + 1] $Tainted $d) }
          }
          continue
        }
        if ($k -eq 1) { return (Test-BcCarries $e $Tainted $d) }
      }
      return $false
    }
    'IfStatementAst' {
      foreach ($cl in @($Node.Clauses)) { if (Test-BcCarries $cl.Item2 $Tainted $d) { return $true } }
      if ($null -ne $Node.ElseClause) { return (Test-BcCarries $Node.ElseClause $Tainted $d) }
      return $false
    }
    'StatementBlockAst' {
      foreach ($st in @($Node.Statements)) { if (Test-BcCarries $st $Tainted $d) { return $true } }
      return $false
    }
    default { return $false }   # safe unmatched: any other shape builds something new from the date, not the date
  }
}

function Test-BcLiteral {
  <# Is this operand a literal: a string or number constant, $null/$true/$false, or an array of those? #>
  param($Node, [int]$Depth = 0)
  if ($null -eq $Node -or $Depth -gt 32) { return $false }
  $d = $Depth + 1
  switch -CaseSensitive ($Node.GetType().Name) {
    'PipelineAst' { $els = @($Node.PipelineElements); if ($els.Count -eq 1) { return (Test-BcLiteral $els[0] $d) }; return $false }
    'CommandExpressionAst' { return (Test-BcLiteral $Node.Expression $d) }
    'ParenExpressionAst' { return (Test-BcLiteral $Node.Pipeline $d) }
    'ConvertExpressionAst' { return (Test-BcLiteral $Node.Child $d) }
    'UnaryExpressionAst' { return (Test-BcLiteral $Node.Child $d) }
    'StringConstantExpressionAst' { return $true }
    'ConstantExpressionAst' { return $true }
    'ExpandableStringExpressionAst' { return (@($Node.NestedExpressions).Count -eq 0) }
    'VariableExpressionAst' { $v = Get-BcVarName $Node; return ($v -ieq 'null' -or $v -ieq 'true' -or $v -ieq 'false') }
    'ArrayLiteralAst' { foreach ($e in @($Node.Elements)) { if (-not (Test-BcLiteral $e $d)) { return $false } }; return $true }
    default { return $false }   # safe unmatched: anything else is a value, which is what s1 is looking for
  }
}

function Get-BcFindings {
  <# Pure over one file's text, so the self-test drives exactly what the live scan runs.
     Returns @{ Parsed; ParseErrors; Tainted; Findings (each @{ Line; Kind; Text }) }. Parsed is false when the
     text spells no source and no marker. $NoPropagation exists for the mutation probe only. #>
  param([string]$Text, [switch]$NoPropagation)
  $empty = [pscustomobject]@{ Parsed = $false; ParseErrors = 0; Tainted = @(); Findings = @() }
  if ($null -eq $Text -or $Text -notmatch $script:BC_PREFILTER) { return $empty }
  $tok = $null; $err = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tok, [ref]$err)
  $pe = @($err).Count
  if ($null -eq $ast -or $pe -gt 0) { return [pscustomobject]@{ Parsed = $true; ParseErrors = [Math]::Max(1, $pe); Tainted = @(); Findings = @() } }
  $kinds = $script:BC_KINDS
  $all = @($ast.FindAll({ param($x) $kinds -contains $x.GetType().Name }, $true))

  # ---- PROPAGATION: name-keyed, file-wide, to a fixpoint ----
  $tainted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $binds = [System.Collections.Generic.List[object]]::new()
  foreach ($a in $all) {
    $tn = $a.GetType().Name
    if ($tn -eq 'AssignmentStatementAst') {
      $left = $a.Left
      while ($null -ne $left -and $left.GetType().Name -eq 'ConvertExpressionAst') { $left = $left.Child }
      $nm = Get-BcVarName $left
      if ($nm) { $binds.Add([pscustomobject]@{ Name = $nm; Value = $a.Right }) }
    } elseif ($tn -eq 'ParameterAst' -and $null -ne $a.DefaultValue) {
      $nm = Get-BcVarName $a.Name
      if ($nm) { $binds.Add([pscustomobject]@{ Name = $nm; Value = $a.DefaultValue }) }
    }
  }
  if (-not $NoPropagation) {
    $changed = $true; $rounds = 0
    while ($changed -and $rounds -lt 32) {
      $changed = $false; $rounds++
      foreach ($b in $binds) {
        if ($tainted.Contains($b.Name)) { continue }
        if (Test-BcCarries $b.Value $tainted) { [void]$tainted.Add($b.Name); $changed = $true }
      }
    }
  }

  # ---- ALLOW markers, from COMMENT tokens only ----
  $allowed = New-Object 'System.Collections.Generic.HashSet[int]'
  $found = [System.Collections.Generic.List[object]]::new()
  foreach ($t in @($tok)) {
    if ([string]$t.Kind -ne 'Comment') { continue }
    $mm = [regex]::Match([string]$t.Text, $script:BC_ALLOW_RX)
    if (-not $mm.Success) { continue }
    if ($mm.Groups[1].Value.Trim().Length -gt 0) { [void]$allowed.Add([int]$t.Extent.StartLineNumber) }
    else { $found.Add([pscustomobject]@{ Line = [int]$t.Extent.StartLineNumber; Kind = 'allow-no-reason'; Text = [string]$t.Text; Node = $null }) }
  }

  # ---- SINKS ----
  $sinks = [System.Collections.Generic.List[object]]::new()
  foreach ($a in $all) {
    $tn = $a.GetType().Name
    if ($tn -eq 'BinaryExpressionAst') {
      $op = $a.Operator.ToString()
      if ($script:BC_CMP_OPS -contains $op) {
        $l = Test-BcCarries $a.Left $tainted; $r = Test-BcCarries $a.Right $tainted
        if ($l -ne $r) {
          $other = if ($l) { $a.Right } else { $a.Left }
          if (-not (Test-BcLiteral $other)) { $sinks.Add([pscustomobject]@{ Kind = 'compare'; Node = $a }) }
        }
      } elseif ($op -eq 'Minus') {
        $l = Test-BcCarries $a.Left $tainted; $r = Test-BcCarries $a.Right $tainted
        if ($l -ne $r) { $sinks.Add([pscustomobject]@{ Kind = 'date-math'; Node = $a }) }
      }
    } elseif ($tn -eq 'InvokeMemberExpressionAst') {
      if ($a.Static) { continue }
      $m = Get-BcMemberName $a
      $isMath = $false; foreach ($c in $script:BC_DATE_MATH) { if ($m -ieq $c) { $isMath = $true } }
      if (-not $isMath) { continue }
      $hit = Test-BcCarries $a.Expression $tainted
      if (-not $hit) { foreach ($x in @($a.Arguments)) { if (Test-BcCarries $x $tainted) { $hit = $true; break } } }
      if ($hit) { $sinks.Add([pscustomobject]@{ Kind = 'date-math'; Node = $a }) }
    } elseif ($tn -eq 'CommandAst') {
      $cn = [string]$a.GetCommandName()
      $els = @($a.CommandElements)
      if ($cn -ieq 'New-TimeSpan') {
        $hit = $false
        for ($k = 1; $k -lt $els.Count; $k++) {
          $e = $els[$k]
          $v = if ($e.GetType().Name -eq 'CommandParameterAst') { $e.Argument } else { $e }
          if ($null -ne $v -and (Test-BcCarries $v $tainted)) { $hit = $true; break }
        }
        if ($hit) { $sinks.Add([pscustomobject]@{ Kind = 'date-math'; Node = $a }) }
        continue
      }
      for ($k = 1; $k -lt $els.Count; $k++) {
        $e = $els[$k]
        if ($e.GetType().Name -ne 'CommandParameterAst') { continue }
        $pn = [string]$e.ParameterName
        $isSink = $false; foreach ($s in $script:BC_SINK_PARAMS) { if ($pn -ieq $s) { $isSink = $true } }
        if (-not $isSink) { continue }
        if ($cn -ieq 'Get-Date' -and $pn -ieq 'Date') { continue }   # a conversion; its result carries
        $v = $e.Argument
        if ($null -eq $v -and $k + 1 -lt $els.Count -and $els[$k + 1].GetType().Name -ne 'CommandParameterAst') { $v = $els[$k + 1] }
        if ($null -ne $v -and (Test-BcCarries $v $tainted)) { $sinks.Add([pscustomobject]@{ Kind = 'param'; Node = $e; Arg = $v }) }
      }
    }
  }
  foreach ($s in $sinks) {
    $ln = [int]$s.Node.Extent.StartLineNumber
    if ($allowed.Contains($ln) -or $allowed.Contains($ln - 1)) { continue }
    $txt = if ($s.Kind -eq 'param') { ('-' + [string]$s.Node.ParameterName + ' ' + [string]$s.Arg.Extent.Text) } else { [string]$s.Node.Extent.Text }
    $found.Add([pscustomobject]@{ Line = $ln; Kind = $s.Kind; Text = $txt; Node = $s.Node })
  }
  $out = @($found.ToArray() | Sort-Object Line | ForEach-Object { [pscustomobject]@{ Line = $_.Line; Kind = $_.Kind; Text = (($_.Text -replace '\s+', ' ').Trim()) } })
  return [pscustomobject]@{ Parsed = $true; ParseErrors = 0; Tainted = @($tainted); Findings = $out }
}

function Get-BcKey {
  <# The stable key: path below the root, sink kind, normalised text. Never the line number. #>
  param([string]$Rel, $Finding)
  $t = [string]$Finding.Text
  if ($t.Length -gt 240) { $t = $t.Substring(0, 240) }
  return ($Rel + ' | ' + [string]$Finding.Kind + ' | ' + $t)
}

function Get-BcScanFiles {
  <# Tracked .ps1 files in the five scoped directories, excluded on the path BELOW the root, never $Self. #>
  param([string]$RootDir, [string]$Self = '', $Tracked = $null)
  $rootFull = Get-TcRootFull $RootDir
  Get-TcTreeFiles -RootFull $rootFull -Filter *.ps1 -PruneBelow $script:BC_WALK_EXCLUDE |
    Where-Object {
      $below = Get-TcPathBelowRoot $_.FullName $rootFull
      ($_.Extension -ieq '.ps1') -and ($below -match $script:BC_SCOPE_RX) -and ($below -notmatch $script:BC_WALK_EXCLUDE) -and
      (-not [string]::Equals($_.FullName, $Self, [StringComparison]::OrdinalIgnoreCase)) -and
      ($null -eq $Tracked -or $Tracked.Contains($below.TrimStart('\')))
    } |
    Sort-Object FullName
}

# ------------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $script:fail = 0; $script:cases = 0
  $BC_EXPECTED_CASES = 25
  function BcT([string]$m, [bool]$c, [string]$got = '') {
    $script:cases++
    if ($c) { Write-Output ('  ok    ' + $m) } else { Write-Output ('  FAIL  ' + $m + '   got: ' + $got); $script:fail++ }
  }
  function BcGot($r) { return ('parsed=' + $r.Parsed + ' perr=' + $r.ParseErrors + ' n=' + @($r.Findings).Count + ' ' + ((@($r.Findings) | ForEach-Object { [string]$_.Line + ':' + $_.Kind }) -join ',')) }
  function BcShape($r) { return ((@($r.Findings) | ForEach-Object { [string]$_.Line + ':' + $_.Kind }) -join ',') }
  $nl = "`n"
  # Needles, concatenated so this file never spells them.
  $wk = 'week' + '_of'; $td = 'to' + 'day'; $bt = 'Board' + 'Today'; $mk = '# ' + 'board-clock' + ':allow'

  $bcTmp = Join-Path $env:TEMP ('bc-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $bcTmp -ErrorAction Stop | Out-Null
  try {
    # ---- MUST FIRE: the founding shapes ----------------------------------------------------------------------------
    $fxC1 = @(('$today = $ads.' + $td), ('$script:' + $bt + ' = [string]$today'), ('if ([string]$AdTo -lt [string]$script:' + $bt + ') { return }')) -join $nl
    $r = Get-BcFindings -Text $fxC1
    BcT 'MUST FIRE  C1: the ended-sale check compares a row''s ad_to with the engine''s copy of the ad date (line 3, compare)' ((BcShape $r) -eq '3:compare') (BcGot $r)
    # og-18: C1 is caught twice (the name source AND propagation), so a case per copy. This one only propagation reaches.
    $fxC1b = @(('$today = $ads.' + $td), '$script:JudgeAt = [string]$today', 'if ([string]$AdTo -lt [string]$script:JudgeAt) { return }') -join $nl
    $r = Get-BcFindings -Text $fxC1b
    BcT 'MUST FIRE  C1 through PROPAGATION alone: the engine''s copy renamed, reached only by $today -> $script:JudgeAt (line 3)' ((BcShape $r) -eq '3:compare') (BcGot $r)
    $fxC11 = @(('$bd = [string]$Board.' + $wk), '$boardD = [datetime]::ParseExact($bd, ''yyyy-MM-dd'', $null)', '$age = ($boardD - [datetime]$nw).TotalDays') -join $nl
    $r = Get-BcFindings -Text $fxC11
    BcT 'MUST FIRE  C11: a store''s newest read aged against week_of through ParseExact (line 3, date-math)' ((BcShape $r) -eq '3:date-math') (BcGot $r)
    $fxC5 = @(('$today = $ads.' + $td), '$x = 1', ('Test-X -' + 'Board' + 'Date ([string]$today)')) -join $nl
    $r = Get-BcFindings -Text $fxC5
    BcT 'MUST FIRE  C5: the ad date handed to a -BoardDate parameter through a variable (line 3, param)' ((BcShape $r) -eq '3:param') (BcGot $r)
    $fxAdd = @(('$cut = ([datetime]$board.' + $wk + ').AddDays(-90)')) -join $nl
    $r = Get-BcFindings -Text $fxAdd
    BcT 'MUST FIRE  a 90-day window computed from week_of with .AddDays (line 1, date-math)' ((BcShape $r) -eq '1:date-math') (BcGot $r)

    # ---- MUST NOT FIRE: the name-only reads ---------------------------------------------------------------------
    $fxNames = @(
      '$f = Get-ChildItem (Join-Path $OutDir ''comparison-*.json'') | Sort-Object Name -Descending | Select-Object -First 1',
      '$board = Get-Content $f.FullName -Raw | ConvertFrom-Json',
      ('$wh = Join-Path $OutDir (''provenance-withheld-'' + $board.' + $wk + ' + ''.json'')'),
      'if (Test-Path $wh) { $w = Get-Content $wh -Raw | ConvertFrom-Json }',
      ('if ([string]$h.' + $wk + ' -lt [string]$other.' + $wk + ') { $older++ }'),
      ('$doc = [ordered]@{ ' + $wk + ' = $board.' + $wk + '; n = 1 }'),
      ('if ($board.' + $wk + ' -eq ''2026-09-23'') { $pinned = $true }')
    ) -join $nl
    $r = Get-BcFindings -Text $fxNames
    BcT 'MUST NOT FIRE  a newest-file pick, a sibling lookup, history ordering, a record field and a literal compare' ((@($r.Findings).Count -eq 0) -and $r.Parsed) (BcGot $r)
    BcT 'MUST NOT FIRE  ...and the file WAS parsed and judged: the sibling path is not tainted, the history compare saw two carriers' ((-not (@($r.Tainted) -contains 'wh')) -and $r.Parsed) ('tainted=' + (@($r.Tainted) -join ','))
    # SAME AD SET, through a second name the detector cannot follow (guards.ps1:702's shape, one of 8 on the first run).
    $r = Get-BcFindings -Text (@(('$bwk = [string]$board.' + $wk), '$m = [regex]::Match($f.BaseName, ''(\d{4}-\d{2}-\d{2})$'')', 'if ($bwk -eq $m.Groups[1].Value) { $same = $true }') -join $nl)
    BcT 'MUST NOT FIRE  an EQUALITY with the ad set ("is this the same ad set?") is not a clock use, whatever the other side is' ((@($r.Findings).Count -eq 0) -and $r.Parsed) (BcGot $r)
    $r = Get-BcFindings -Text ('$x = [datetime]::' + 'Today' + $nl + 'if ($x -lt $y) { $z = $x.AddDays(-1) }')
    BcT 'MUST NOT FIRE  [datetime]::Today is the real clock, not the ads file''s field' (@($r.Findings).Count -eq 0) (BcGot $r)
    $r = Get-BcFindings -Text (@(('$wkName = $ads.' + $td), '$ad = Get-Owed -OutDir $o -Date $plan.Today') -join $nl)
    BcT 'MUST NOT FIRE  a PascalCase .Today is an object''s property (capture-policy-lib''s real-date plan), not the ads field' ((@($r.Findings).Count -eq 0) -and $r.Parsed) (BcGot $r)

    # ---- CLEAN TWIN: the real date and the board's other two dates ---------------------------------------------------
    $fxJudge = @(('$wkName = $ads.' + $td), '$judge = (Get-Date).ToString(''yyyy-MM-dd'')', ('Test-X -' + 'Board' + 'Date ([string]$judge)')) -join $nl
    $r = Get-BcFindings -Text $fxJudge
    BcT 'MUST NOT FIRE  the judge date from Get-Date passed to -BoardDate is silent, beside a parsed ad-date read' ((@($r.Findings).Count -eq 0) -and $r.Parsed) (BcGot $r)
    $fxJudged = @(('$wkName = [string]$board.' + $wk), '$j = [string]$board.judged_on', 'if ([string]$x.as_of -lt $j) { $old++ }') -join $nl
    $r = Get-BcFindings -Text $fxJudged
    BcT 'MUST NOT FIRE  judged_on compared with a cell''s as_of is silent' ((@($r.Findings).Count -eq 0) -and $r.Parsed) (BcGot $r)

    # ---- the ALLOW marker -------------------------------------------------------------------------------------------
    $r = Get-BcFindings -Text (@(('$today = $ads.' + $td), ('if ([string]$AdTo -lt [string]$today) { return } ' + $mk)) -join $nl)
    BcT 'MUST FIRE  an allow comment with no reason is a finding, and silences nothing (line 2: allow-no-reason and compare)' (((@($r.Findings) | ForEach-Object { $_.Kind }) -join ',') -match '^(allow-no-reason,compare|compare,allow-no-reason)$') (BcGot $r)
    $r = Get-BcFindings -Text (@(('$today = $ads.' + $td), ($mk + ' a pinned fixture date, never a clock'), 'if ([string]$AdTo -lt [string]$today) { return }') -join $nl)
    BcT 'MUST NOT FIRE  an allow comment WITH a reason on the line above silences its line' ((@($r.Findings).Count -eq 0) -and $r.Parsed) (BcGot $r)
    $r = Get-BcFindings -Text (@(('$today = $ads.' + $td), ('Write-Output ''' + $mk + ' not a comment'''), 'if ([string]$AdTo -lt [string]$today) { return }') -join $nl)
    BcT 'MUST FIRE  the marker spelled inside a STRING is not a comment and silences nothing (line 3)' ((BcShape $r) -eq '3:compare') (BcGot $r)

    # ---- could not look ---------------------------------------------------------------------------------------------
    $r = Get-BcFindings -Text ('$x = $b.' + $wk + $nl + 'if ($x -lt { ')
    BcT 'MUST FIRE  a file that fails to parse is counted as a parse failure, never as clean' ($r.ParseErrors -gt 0) (BcGot $r)

    # ---- THE WALK, FROM A WORKTREE ROOT ---------------------------------------------------------------------------
    $wtFx = New-TcWorktreeFixture -Files @{ 'ops\a.ps1' = 'Write-Output 1'; 'grocery\out\b.ps1' = 'Write-Output 2'
                                            'grocery\archive\c.ps1' = 'Write-Output 3'; 'sidecar\d.ps1' = 'Write-Output 4'
                                            'ops\me.ps1' = 'Write-Output 5'; 'meal-prep\e.ps1' = 'Write-Output 6'; 'ops\f.py' = 'print(1)' }
    try {
      $self = Join-Path $wtFx.Root 'ops\me.ps1'
      $wtFound = @(Get-BcScanFiles -RootDir $wtFx.Root -Self $self)
      $wtHits = Measure-TcWorktreeFixture -Fixture $wtFx -Found $wtFound
      BcT 'MUST FIRE  a worktree root is walked: ops\a.ps1 and meal-prep\e.ps1 only (no out\, archive\, unscoped dir, .py or itself)' ($wtHits.Root -eq 2) ('root=' + $wtHits.Root + ' ' + (($wtFound | ForEach-Object { $_.Name }) -join ','))
      BcT 'MUST NOT FIRE  a sibling worktree below that root is pruned' ($wtHits.Sibling -eq 0) ('sibling=' + $wtHits.Sibling)
    } finally { Remove-Item -LiteralPath $wtFx.Temp -Recurse -Force -ErrorAction SilentlyContinue }

    # ---- THE LIVE PATH, DRIVEN: this script as a child against a temp tree and a temp mark ---------------------------
    $tree = Join-Path $bcTmp 'tree'
    New-Item -ItemType Directory -Path (Join-Path $tree 'ops') -Force -ErrorAction Stop | Out-Null
    $enc = New-Object Text.UTF8Encoding($false)
    $one = Join-Path $tree 'ops\one.ps1'; $two = Join-Path $tree 'ops\two.ps1'
    [IO.File]::WriteAllText($one, $fxC1, $enc)
    $k1 = Get-BcKey 'ops\one.ps1' @((Get-BcFindings -Text $fxC1).Findings)[0]
    $markAt = Join-Path $bcTmp 'mark-at.json'
    $null = Write-TcLfFile -Path $markAt -Text ([pscustomobject]@{ generated = '2026-01-01T00:00:00'; sites = 1; keys = @($k1); history = @(); note = 'fixture' } | ConvertTo-Json -Depth 5) -NoBom
    $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $tree -MarkFile $markAt); $rc = $LASTEXITCODE
    BcT 'MUST NOT FIRE  ratchet AT the mark (1 finding, mark 1, same key) exits 0' ($rc -eq 0) ("rc=$rc " + ($o[-1]))

    [IO.File]::WriteAllText($two, $fxC5, $enc)
    $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $tree -MarkFile $markAt); $rc = $LASTEXITCODE
    $newLines = @($o | Where-Object { $_ -match '^\s+NEW\s' })
    BcT 'MUST FIRE  ratchet one step PAST the mark (2 findings, mark 1) exits 1 and names ONLY the new finding' (($rc -eq 1) -and ($newLines.Count -eq 1) -and ($newLines[0] -match 'two\.ps1')) ("rc=$rc new=" + ($newLines -join ' | '))

    Remove-Item -LiteralPath $two -Force
    [IO.File]::WriteAllText($one, ("# moved`n`n`n" + $fxC1), $enc)
    $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $tree -MarkFile $markAt); $rc = $LASTEXITCODE
    BcT 'MUST NOT FIRE  a known finding moved down three lines is still known (the key carries no line number)' ($rc -eq 0) ("rc=$rc " + ($o[-1]))

    $markFall = Join-Path $bcTmp 'mark-fall.json'
    $null = Write-TcLfFile -Path $markFall -Text ([pscustomobject]@{ generated = '2026-01-01T00:00:00'; sites = 2; keys = @($k1, 'ops\gone.ps1 | compare | x'); history = @(); note = 'fixture' } | ConvertTo-Json -Depth 5) -NoBom
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($markFall))
    $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $tree -MarkFile $markFall); $rc = $LASTEXITCODE
    $same = [string]::Equals($b64, [Convert]::ToBase64String([IO.File]::ReadAllBytes($markFall)), [StringComparison]::Ordinal)
    BcT 'MUST FIRE  a FALL with no -Tighten is SPOKEN and the mark left byte-identical (og-11)' (($rc -eq 0) -and $same -and (($o -join "`n") -match 'CAN tighten')) ("rc=$rc same=$same")

    $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $tree -MarkFile $markFall -Tighten); $rc = $LASTEXITCODE
    $bytes = [IO.File]::ReadAllBytes($markFall)
    $cr = 0; foreach ($x in $bytes) { if ($x -eq 13) { $cr++ } }
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)
    $doc = $null; try { $doc = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json } catch { $doc = $null }
    BcT 'CLEAN TWIN  -Tighten records the fall LF with no BOM: sites 1, the gone key dropped, the note kept' (($rc -eq 0) -and ($cr -eq 0) -and (-not $bom) -and ($null -ne $doc) -and ([int]$doc.sites -eq 1) -and (@($doc.keys).Count -eq 1) -and ([string]$doc.note -eq 'fixture')) ("rc=$rc cr=$cr bom=$bom sites=$(if ($doc) { $doc.sites })")

    $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $tree -MarkFile (Join-Path $bcTmp 'no-mark.json')); $rc = $LASTEXITCODE
    BcT 'MUST FIRE  no readable mark is a could-not-look (exit 3), never a pass' ($rc -eq 3) ("rc=$rc")

    [IO.File]::WriteAllText((Join-Path $tree 'ops\broken.ps1'), ('$x = $b.' + $wk + $nl + 'if ($x -lt { '), $enc)
    $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $tree -MarkFile $markAt); $rc = $LASTEXITCODE
    BcT 'MUST FIRE  a scoped file that fails to parse makes the run exit 3 and names it' (($rc -eq 3) -and (($o -join "`n") -match 'broken\.ps1')) ("rc=$rc")
  } catch {
    $script:cases++; $script:fail++
    Write-Output ('  FAIL  the suite threw: ' + $_.Exception.Message + ' at line ' + $_.InvocationInfo.ScriptLineNumber)
  } finally {
    Remove-Item -LiteralPath $bcTmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($script:cases -ne $BC_EXPECTED_CASES) {
    Write-Output ("  FAIL  ran {0} case(s), expected {1}: a case was lost or added without updating the count" -f $script:cases, $BC_EXPECTED_CASES)
    $script:fail++
  }
  if ($script:fail) { Write-Output ("BOARD-CLOCK SELF-TEST FAILED ({0} failure(s) over {1} case(s))" -f $script:fail, $script:cases); exit 1 }
  Write-Output ("BOARD-CLOCK SELF-TEST PASSED ({0} case(s): the founding shapes fire, the name-only reads and the real clock stay silent, the allow marker needs a reason, and the ratchet holds at and past its mark)" -f $script:cases)
  exit 0
}

# ------------------------------------------------------------------------------------------- live run
$useGit = -not $Root
if (-not $Root) { $Root = $repo }
$rootFull = Get-TcRootFull $Root
$tracked = $null
if ($useGit) {
  $listed = $null
  try { $listed = & git -C $rootFull -c core.quotepath=off ls-files -- '*.ps1' } catch { $listed = $null }
  $gitRc = $LASTEXITCODE
  $listed = @($listed | Where-Object { $_ })
  if ($gitRc -ne 0 -or $listed.Count -eq 0) {
    Write-Output ("BOARD-CLOCK AUDIT BLIND: git ls-files exited {0} and listed {1} .ps1 path(s), so there is no tracked set to read." -f $gitRc, $listed.Count)
    Exit-Guard -Name 'audit-board-clock' -Summary 'files=0 blind=no-git-list' -Code 3
  }
  $tracked = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($p in $listed) { [void]$tracked.Add(([string]$p -replace '/', '\')) }
}
$files = @(Get-BcScanFiles -RootDir $rootFull -Self $PSCommandPath -Tracked $tracked)
if ($files.Count -eq 0) {
  Write-Output 'BOARD-CLOCK AUDIT BLIND: the walk resolved no scoped .ps1 file, which means the discovery is broken rather than the tree being clean.'
  Exit-Guard -Name 'audit-board-clock' -Summary 'files=0 blind=walk-resolved-none' -Code 3
}
$parsed = 0; $failed = [System.Collections.Generic.List[string]]::new()
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($f in $files) {
  $rel = (Get-TcPathBelowRoot $f.FullName $rootFull).TrimStart('\')
  $r = Get-BcFindings -Text ([IO.File]::ReadAllText($f.FullName))
  if (-not $r.Parsed) { continue }
  $parsed++
  if ($r.ParseErrors) { $failed.Add($rel); continue }
  foreach ($h in @($r.Findings)) { $rows.Add([pscustomobject]@{ Rel = $rel; Line = $h.Line; Kind = $h.Kind; Text = $h.Text; Key = (Get-BcKey $rel $h) }) }
}
$count = $rows.Count
Write-Output ("board-clock: RESOLVED {0} tracked .ps1 in grocery\ ops\ lib\ graph\ meal-prep\ (git listed {1}); walked {0}, parsed {2} that spell a source or marker, {3} parse failure(s); {4} finding(s)" -f $files.Count, $(if ($tracked) { $tracked.Count } else { 'n/a' }), $parsed, $failed.Count, $count)
foreach ($x in $rows) { Write-Output ("  finding  {0}:{1}  [{2}]  {3}" -f $x.Rel, $x.Line, $x.Kind, $x.Text) }
$summary = "files={0} parsed={1} parse_failures={2} findings={3}" -f $files.Count, $parsed, $failed.Count, $count
if ($failed.Count) {
  foreach ($x in $failed) { Write-Output ('  parse-failure  ' + $x) }
  Write-Output ("BOARD-CLOCK AUDIT COULD NOT LOOK: {0} scoped file(s) failed to parse, so their clock uses are unknown - never clean." -f $failed.Count)
  Exit-Guard -Name 'audit-board-clock' -Summary ($summary + ' blind=parse-failure') -Code 3
}

$keys = [string[]]@($rows | ForEach-Object { [string]$_.Key })
$note = 'HIGH-WATER MARK for code that treats the AD SET date (week_of, the ads file today, BoardToday, or a variable carrying one) as now: a compare with a non-literal, date arithmetic, or a clock-named parameter. keys are path | kind | normalised expression, never a line. It may only go DOWN (ops\audit-board-clock.ps1 -Tighten).'
$bl = Read-TcRatchetBaseline -Path $MARK_FILE -Field 'sites'
function Write-BcMark([string[]]$Keys) {
  $srcDoc = if ($bl.Doc) { $bl.Doc } else { [pscustomobject]@{} }
  $keepNote = if ($bl.Doc -and $bl.Doc.PSObject.Properties['note'] -and $bl.Doc.note) { [string]$bl.Doc.note } else { $note }
  $hist = Add-RatchetHistory -Doc $srcDoc -Count @($Keys).Count
  $sorted = [string[]]@($Keys | Sort-Object)
  $doc = [pscustomobject]@{ generated = (Get-Date).ToString('s'); sites = @($Keys).Count; keys = $sorted; history = $hist; note = $keepNote }
  $null = Write-TcLfFile -Path $MARK_FILE -Text ($doc | ConvertTo-Json -Depth 5) -NoBom
}
if ($bl.State -ne 'read') {
  if ($Tighten -or $AcceptDrop) {
    Write-BcMark $keys
    Write-Output ("board-clock: mark SEEDED at {0} finding(s) in {1}. From here it may only go DOWN; commit the file." -f $count, $MARK_FILE)
    Exit-Guard -Name 'audit-board-clock' -Summary ("{0} mark={1} seeded" -f $summary, $count) -Code 0
  }
  Write-Output ("BOARD-CLOCK AUDIT COULD NOT LOOK: the mark {0} is {1} ({2}), so there is nothing to hold the count against." -f $MARK_FILE, $bl.State, $bl.Why)
  Exit-Guard -Name 'audit-board-clock' -Summary ("{0} blind={1}" -f $summary, (Get-TcRatchetBlindToken $bl.State)) -Code 3
}
$base = [int]$bl.Value
$baseKeys = [string[]]@(); if ($bl.Doc.PSObject.Properties['keys']) { $baseKeys = [string[]]@($bl.Doc.keys | Where-Object { $_ }) }
$cmp = Compare-TcRatchetSites -Current $keys -Baseline $baseKeys
if (@($cmp.New).Count -gt 0) {
  $left = [System.Collections.Generic.List[string]]::new(); foreach ($k in @($cmp.New)) { $left.Add($k) }
  foreach ($x in $rows) { if ($left.Remove([string]$x.Key)) { Write-Output ("  NEW  {0}:{1}  [{2}]  {3}" -f $x.Rel, $x.Line, $x.Kind, $x.Text) } }
  Write-Output ("BOARD-CLOCK AUDIT FAILED: {0} NEW finding(s) against a mark of {1}. The ad set's date (week_of, the ads file's today, BoardToday) is a NAME: it lags the real date by however many days no weekly ad was pulled." -f @($cmp.New).Count, $base)
  Write-Output '  Judge an age or an expiry against the REAL date (compare-deals -JudgeDate, the board''s judged_on) or against the evidence'
  Write-Output '  (a cell''s as_of, lib\board-clock.ps1 Get-TcBoardClock). If this use is deliberate, say so on its line or the one above:'
  Write-Output ('  # ' + $script:BC_MARKER + ' <reason>')
  Exit-Guard -Name 'audit-board-clock' -Summary ("{0} mark={1} new={2}" -f $summary, $base, @($cmp.New).Count) -Code 1
}
$move = Test-RatchetMove -Name 'board-clock' -Count $count -Baseline $base -AcceptDrop:$AcceptDrop
if ($move.Verdict -eq 'implausible') {
  Write-Output $move.Message
  if ($Tighten) { Exit-Guard -Name 'audit-board-clock' -Summary ("{0} mark={1} refused-to-lower" -f $summary, $base) -Code 1 }
  Exit-Guard -Name 'audit-board-clock' -Summary ("{0} mark={1} can-tighten={2} implausible" -f $summary, $base, $count) -Code 0
}
if ($move.Verdict -eq 'tightened') {
  if ($Tighten -or $AcceptDrop) {
    Write-BcMark $keys
    Write-Output ('PASSED and TIGHTENED - ' + $move.Message + ' Commit ' + $MARK_FILE + '.')
    Exit-Guard -Name 'audit-board-clock' -Summary ("{0} tightened-from={1}" -f $summary, $base) -Code 0
  }
  foreach ($k in @($cmp.Gone)) { Write-Output ('  gone  ' + $k) }
  $spoken = [string]$move.Message -replace 'Baseline lowered; it can never rise again\.', 'NOT written.'
  Write-Output ('board-clock: PASSED, and the ratchet CAN tighten - ' + $spoken + ' Record it with -Tighten and commit the mark.')
  Exit-Guard -Name 'audit-board-clock' -Summary ("{0} mark={1} can-tighten={2}" -f $summary, $base, $count) -Code 0
}
Write-Output ("board-clock: PASSED - {0} known finding(s), no new one, against a mark of {1}." -f $count, $base)
Exit-Guard -Name 'audit-board-clock' -Summary ("{0} mark={1}" -f $summary, $base) -Code 0
