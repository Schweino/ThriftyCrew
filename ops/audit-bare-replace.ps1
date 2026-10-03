<#
  audit-bare-replace.ps1 - a temp file moved over a live file goes through lib\atomic-write.ps1.

  SCOPE OF A CLEAN REPORT: UNSOUND, and a RATCHET rather than a proof for exactly that reason. It finds
    `Move-Item ... -Force` commands in parsed PowerShell. A clean report means no NEW such command exists
    outside the helper. It cannot see a Force passed by splatting, a move performed through [IO.File] or
    Python, or a caller that invokes Move-Item by a name held in a variable.

  WHY THIS EXISTS (2026-09-11). While any process holds a file open without FILE_SHARE_DELETE - and
  Get-Content, [IO.File]::ReadAllText, Python's open() and lib\json-io.ps1 all open that way - a
  `Move-Item tmp dest -Force` over it is REFUSED, and that write is lost. Under the default
  ErrorActionPreference the refusal does not even throw: the script carries on as if the write landed.
  lib\atomic-write.ps1's Write-TcAtomicFile waits a reader out for a bounded time and throws when it cannot;
  a site whose bytes were BOM-less passes -NoBom -NoNewline.
  Twenty-seven files carried the bare form the day this was written.

  WHAT IT COUNTS: every Move-Item command (or its aliases move, mv, mi) carrying -Force, outside the helper
  itself. That includes moves into an archive directory, which are not replaces of a live file - they are
  counted anyway, because the only thing -Force adds to a move is permission to replace an existing file,
  and the command cannot tell a log nobody reads from a ledger a daemon polls. A line that is a deliberate
  exception says so with `# atomic-replace:allow <reason>` on the command's first line.

  RATCHET, NOT A HARD FAIL, for the reason ops-and-gates.md gives: the sites nobody is about to convert
  would make it red on day one. The baseline is a HIGH-WATER MARK that may only go DOWN, through
  lib\ratchet.ps1, so a detector that suddenly finds nothing KEEPS the old mark instead of recording 0.

  A RUN THAT IS NOT ASKED TO RECORD WRITES NOTHING (2026-09-12, the rule 740c82af6 gave seven other ratchets
  and this one did not get). run-gates runs this with NO arguments on every pre-push, and a fall used to rewrite
  the TRACKED baseline right there: the lower mark never rode that push, so it protected only the checkout that
  happened to run it, it left that checkout ` M` mid-push, and a count taken over uncommitted edits is not a
  baseline anyway. It also costs the pass its reuse record - run-gates then reports "the checkout changed while
  the gates ran" and the next push pays for every gate again. So a fall is SPOKEN and the committed mark KEPT;
  -Tighten records it, through lib\ratchet.ps1's plausibility bar and in the bytes git stores (lib\lf-write.ps1).

  THE SECOND COUNT: A JSON FILE REPLACED IN CRLF (2026-10-03). `... | ConvertTo-Json | Set-Content` (or Out-File) is
  the other bare replace of a whole file. Under PS 5.1 ConvertTo-Json joins its lines with CRLF and the cmdlet adds one
  more, so over a TRACKED file, stored eol=lf, it leaves ` M` with a zero-line `git diff` and push-main refuses the dirty
  tree. lib\lf-write.ps1 (Write-TcLfFile) and lib\atomic-write.ps1 (Write-TcAtomicFile -Lf) are the replacements, and
  both take the same pipeline (`... | ConvertTo-Json | Write-TcLfFile -Path $p`). The sweep that day converted the 130
  production sites whose target resolved to a tracked path; the rest write gitignored or temp files, and are the
  backlog this mark holds. Counted from the AST: a pipeline whose LAST command is Set-Content, sc or Out-File (not
  -Append) and whose earlier text calls ConvertTo-Json, outside every self-test body (lib\selftest-lib.ps1's
  Get-SelfTestSpans, the rule audit-write-only-reports and audit-mustfire-census read). A deliberate exception carries
  `# crlf-json:allow <reason>` on the pipeline's first line. Its own mark, `crlf_json_sites`, may only go DOWN too, and
  a plain run never writes it: a baseline with no such key is SPOKEN and passes, and -Tighten records it. Same scope
  limits as the first count, plus: a JSON text built into a variable first and written on a later line is not seen.
  Cost: one more AST walk over files this already parses, measured in the commit that added it.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 hard finding, 3 could-not-evaluate.
  Read the verdict LINE, not the number.

    ops\audit-bare-replace.ps1              scan the tree, hold the ratchet; writes NOTHING
    ops\audit-bare-replace.ps1 -Tighten     the same, and record a believable FALL as the new high-water mark
    ops\audit-bare-replace.ps1 -AcceptDrop  record a fall lib\ratchet.ps1 would otherwise refuse
  Self-test: powershell -File ops\audit-bare-replace.ps1 -SelfTest
#>
# The self-test uses literal fixtures and runs this script against temp trees and baselines, so it reads only its libraries:
# gate-inputs: lib\guard-contract.ps1, lib\ratchet.ps1, lib\lf-write.ps1, lib\tree-walk.ps1, lib\selftest-lib.ps1
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param([switch]$SelfTest, [switch]$AcceptDrop, [switch]$Tighten, [string]$Root = '', [string]$BaselineFile = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ratchet.ps1')
. (Join-Path $repo 'lib\lf-write.ps1')    # Write-TcLfFile: the baseline is TRACKED and stored eol=lf
. (Join-Path $repo 'lib\tree-walk.ps1')   # exclusions match below the root, so a worktree root is not excluded whole
. (Join-Path $repo 'lib\selftest-lib.ps1')   # Get-SelfTestSpans: a CRLF JSON write inside a self-test body is a fixture, not a site

# -Root and -BaselineFile exist for the self-test, so the three live-path cases drive THIS script against a
# temp tree and a temp baseline rather than a copy of its logic. Production passes neither.
$BASELINE_FILE = if ($BaselineFile) { $BaselineFile } else { Join-Path $repo 'ops\bare-replace-baseline.json' }

# The helper itself, plus the trees run-gates excludes everywhere else.
$EXCLUDE = '\\archive\\|\\worktrees\\|\\out\\|node_modules|\\lib\\atomic-write\.ps1$'
$MOVE_NAMES = @('move-item', 'move', 'mv', 'mi')

function Get-TcBareReplaceScan {
  <# Pure, ONE parse and ONE walk for both counts: .Bare holds the 1-based line of every Move-Item -Force command,
     .CrlfJson the line of every `... | ConvertTo-Json ... | Set-Content/sc/Out-File` pipeline (not -Append) outside a
     self-test body, each skipping its own allow marker. -Path is only for the whole-file test-*.ps1 rule.
     PARSED, NOT MATCHED. The parser already knows a comment, a string and a here-string from a command, and
     it joins a backtick continuation, so none of those needs a regex of its own here.
     ONE WALK, MEASURED (2026-10-03): a second parse and a second FindAll for the CRLF count took this gate from a
     median 7.7 s to 16.3 s over three interleaved rounds each. The CRLF candidates are Set-Content commands the
     Move-Item walk already visits, so they cost a name test each. #>
  param([string]$Text, [string]$Path = '')
  $tokens = $null; $errs = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errs)
  $lines = $Text -split "`r?`n"
  $bare = @(); $cj = @()
  $spans = $null
  $cmds = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true)
  foreach ($c in @($cmds)) {
    $name = $c.GetCommandName()
    if (-not $name) { continue }
    $lname = $name.ToLower()
    if ($MOVE_NAMES -contains $lname) {
      $forced = $false
      foreach ($el in @($c.CommandElements)) {
        if ($el -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
        # -Fo, -For, -Forc, -Force: PowerShell accepts any unambiguous prefix. A lone -F is ambiguous with
        # -Filter on Move-Item and does not run at all, so it is not counted.
        if ($el.ParameterName -notmatch '(?i)^fo(r(ce?)?)?$') { continue }
        # -Force:$false forces nothing.
        if ($el.Argument -and $el.Argument.Extent.Text -match '(?i)^\$false$') { continue }
        $forced = $true
      }
      if (-not $forced) { continue }
      $ln = $c.Extent.StartLineNumber
      if ($ln -ge 1 -and $ln -le $lines.Count -and $lines[$ln - 1] -match 'atomic-replace:allow') { continue }
      $bare += $ln
      continue
    }
    if ($lname -ne 'set-content' -and $lname -ne 'sc' -and $lname -ne 'out-file') { continue }
    # THE SECOND COUNT: this command must END a pipeline whose earlier elements call ConvertTo-Json.
    $p = $c.Parent
    if ($p -isnot [System.Management.Automation.Language.PipelineAst]) { continue }
    $els = $p.PipelineElements
    if ($els.Count -lt 2 -or -not [object]::ReferenceEquals($els[$els.Count - 1], $c)) { continue }
    $append = $false
    foreach ($el in @($c.CommandElements)) {
      if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and $el.ParameterName -match '^(?i)ap(p(e(nd?)?)?)?$') { $append = $true }
    }
    if ($append) { continue }
    $headText = $Text.Substring($p.Extent.StartOffset, $els[$els.Count - 2].Extent.EndOffset - $p.Extent.StartOffset)
    if ($headText.IndexOf('ConvertTo-Json', [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
    $json = $false
    for ($i = 0; $i -lt $els.Count - 1 -and -not $json; $i++) {
      if ($els[$i].Find({ param($a) $a -is [System.Management.Automation.Language.CommandAst] -and $a.GetCommandName() -eq 'ConvertTo-Json' }, $true)) { $json = $true }
    }
    if (-not $json) { continue }
    $ln = $p.Extent.StartLineNumber
    if ($ln -ge 1 -and $ln -le $lines.Count -and $lines[$ln - 1] -match 'crlf-json:allow') { continue }
    # A self-test body is a fixture. Spans are the shared rule (lib\selftest-lib.ps1) and cost about 80 ms a file, so
    # they are computed only for a pipeline that could sit in one (Test-TcCrlfJsonMaybeFixture), once per file.
    $inBody = $false
    $fx = Test-TcCrlfJsonMaybeFixture -Pipeline $p -Text $Text -Path $Path
    if ($fx -eq 'yes') { $inBody = $true }
    elseif ($fx -eq 'maybe') {
      if ($null -eq $spans) { try { $spans = @(Get-SelfTestSpans -Text $Text -Path $Path) } catch { $spans = @() } }
      $off = $p.Extent.StartOffset
      foreach ($sp in $spans) { if ($off -ge $sp.S -and $off -lt $sp.E) { $inBody = $true; break } }
    }
    if ($inBody) { continue }
    $cj += $ln
  }
  return [pscustomobject]@{ Bare = @($bare); CrlfJson = @($cj) }
}

function Get-TcBareReplaceLines {
  <# The Move-Item -Force lines of $Text (Get-TcBareReplaceScan's .Bare), as an ARRAY even when it holds one. #>
  param([string]$Text)
  $r = Get-TcBareReplaceScan -Text $Text
  return ,@($r.Bare)
}

function Test-TcCrlfJsonMaybeFixture {
  <# Cheap: could this pipeline sit in a self-test body at all? Only a yes pays for Get-SelfTestSpans, which stays
     the authority. A no is: not a test-*.ps1, no enclosing if whose condition names SelfTest, no enclosing function
     named *SelfTest, and no `if (-not $...SelfTest` guard anywhere in the file. A self-test variable whose NAME does
     not say SelfTest slips this test, so its fixture is COUNTED: an over-count, never a hidden site, and the mark is
     recorded over the same rule. #>
  param($Pipeline, [string]$Text, [string]$Path)
  # Returns 'yes' (certainly a self-test body), 'maybe' (ask Get-SelfTestSpans) or 'no'. 'yes' is the one shape the
  # shared rule has always counted and nothing else can mean: the pipeline sits in the BODY of a clause whose whole
  # condition is a $...SelfTest variable. It spares the spans for most of the tree's 136 fixture writes (measured
  # on adding it: spans for those files were most of a 4.4 s cost on every push).
  $off = $Pipeline.Extent.StartOffset
  $maybe = $false
  if ($Path -and (Split-Path $Path -Leaf) -like 'test-*.ps1') { $maybe = $true }
  if ($Text -match '(?i)if\s*\(\s*-not\s+\$[\w:]*SelfTest') { $maybe = $true }
  $a = $Pipeline.Parent
  while ($a) {
    if ($a -is [System.Management.Automation.Language.IfStatementAst]) {
      foreach ($cl in @($a.Clauses)) {
        $cond = $cl.Item1.Extent.Text.Trim()
        if ($cond -notmatch '(?i)SelfTest') { continue }
        $body = $cl.Item2.Extent
        if ($cond -match '^(?i)\$(script:)?\w*SelfTest$' -and $off -ge $body.StartOffset -and $off -lt $body.EndOffset) { return 'yes' }
        $maybe = $true
      }
    }
    if ($a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -match '(?i)SelfTest$') { $maybe = $true }
    $a = $a.Parent
  }
  if ($maybe) { return 'maybe' }
  return 'no'
}

function Get-TcCrlfJsonWriteLines {
  <# The CRLF JSON lines of $Text (Get-TcBareReplaceScan's .CrlfJson), as an ARRAY even when it holds one. #>
  param([string]$Text, [string]$Path = '')
  $r = Get-TcBareReplaceScan -Text $Text -Path $Path
  return ,@($r.CrlfJson)
}

function Get-BareReplaceScanFiles {
  <# Every .ps1 the live run reads under $RootDir, never $Self. $EXCLUDE matches the path BELOW the root
     (lib\tree-walk.ps1), so a root that is itself a linked worktree is scanned rather than excluded whole. #>
  param([string]$RootDir, [string]$Self = '')
  $rootFull = Get-TcRootFull $RootDir
  Get-TcTreeFiles -RootFull $rootFull -Filter *.ps1 -PruneBelow $EXCLUDE |
    Where-Object { (Get-TcPathBelowRoot $_.FullName $rootFull) -notmatch $EXCLUDE -and $_.FullName -ne $Self } |
    ForEach-Object { $_.FullName }
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0; $n = 0
  function T($m, $cond, $got) { $script:n++; if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }
  function Count-Hits([string]$Text) { $r = Get-TcBareReplaceLines -Text $Text; return @($r).Count }

  # MUST FIRE - the shapes the live tree carried the day this was written.
  T 'MUST FIRE  the named-parameter temp-then-rename form' `
    ((Count-Hits 'Move-Item -Path $tmpf -Destination $Store -Force') -eq 1) 'missed'
  T 'MUST FIRE  the positional form' `
    ((Count-Hits 'Move-Item $tmpS $SuppressionsFile -Force') -eq 1) 'missed'
  T 'MUST FIRE  a Move-Item at the end of a pipeline' `
    ((Count-Hits 'Get-ChildItem -Path $GenDir -Filter *.html -File | Move-Item -Destination $doneDir -Force') -eq 1) 'missed'
  T 'MUST FIRE  -Force on a backtick-continued line' `
    ((Count-Hits ('Move-Item -LiteralPath $tmp -Destination $ledger ' + [char]96 + "`n  -Force")) -eq 1) 'a continuation hid it'
  T 'MUST FIRE  the mv alias with an abbreviated -Forc' `
    ((Count-Hits 'mv $a $b -Forc') -eq 1) 'missed'
  T 'MUST FIRE  -Force:$true still forces' `
    ((Count-Hits 'Move-Item $a $b -Force:$true') -eq 1) 'missed'

  # MUST NOT FIRE - legal inputs the matcher must stay silent on.
  T 'MUST NOT FIRE  a Move-Item without -Force cannot replace a file' `
    ((Count-Hits 'Move-Item $a $b') -eq 0) 'counted'
  T 'MUST NOT FIRE  a comment describing the bare form' `
    ((Count-Hits '# the old code did Move-Item $tmp $dest -Force here') -eq 0) 'a comment was counted'
  T 'MUST NOT FIRE  a string carrying the bare form' `
    ((Count-Hits '$fixture = ''Move-Item $tmp $dest -Force''') -eq 0) 'a string was counted'
  T 'MUST NOT FIRE  a here-string carrying the bare form' `
    ((Count-Hits ("`$h = @'`nMove-Item `$tmp `$dest -Force`n'@")) -eq 0) 'a here-string was counted'
  T 'MUST NOT FIRE  a line marked atomic-replace:allow' `
    ((Count-Hits 'Move-Item $d $arch -Force   # atomic-replace:allow archive of a log nobody holds open') -eq 0) 'the marker was ignored'
  T 'MUST NOT FIRE  Copy-Item -Force is a different command' `
    ((Count-Hits 'Copy-Item $a $b -Force') -eq 0) 'counted'
  T 'MUST NOT FIRE  the helper call itself' `
    ((Count-Hits 'Write-TcAtomicFile -Path $dest -Text $json -NoBom -NoNewline') -eq 0) 'counted'
  T 'MUST NOT FIRE  -Force:$false' `
    ((Count-Hits 'Move-Item $a $b -Force:$false') -eq 0) 'counted'

  # CLEAN TWIN - line reporting still works with an allowed line and a comment around a real site.
  $mixed = "`$x = 1`n# Move-Item `$a `$b -Force`nMove-Item `$d `$arch -Force # atomic-replace:allow archive`nMove-Item -Path `$t -Destination `$p -Force"
  $ml = Get-TcBareReplaceLines -Text $mixed
  T 'CLEAN TWIN  the one real site is reported at its own line, 4' ((@($ml).Count -eq 1) -and ($ml[0] -eq 4)) ("lines=" + (@($ml) -join ','))
  T 'MUST FIRE  a single finding comes back as an ARRAY, not unrolled to a bare number' ($ml -is [array]) ($ml.GetType().FullName)

  # ---- THE SECOND COUNT: a JSON file replaced in CRLF (2026-10-03) ----
  function Count-Cj([string]$Text, [string]$Path = 'grocery\x.ps1') { $r = Get-TcCrlfJsonWriteLines -Text $Text -Path $Path; return @($r).Count }
  # MUST FIRE - the founding shapes, verbatim from the four grocery writers fixed that morning and the sweep after.
  T 'MUST FIRE  the bare pipe: $doc | ConvertTo-Json | Set-Content' `
    ((Count-Cj '$doc | ConvertTo-Json -Depth 6 | Set-Content $regPath -Encoding UTF8') -eq 1) 'missed'
  T 'MUST FIRE  the parenthesised head: ($x | ConvertTo-Json) | Set-Content' `
    ((Count-Cj '($rb | ConvertTo-Json -Depth 8) | Set-Content $rbPath -Encoding UTF8') -eq 1) 'missed'
  T 'MUST FIRE  Out-File is the same write' `
    ((Count-Cj '$out | ConvertTo-Json -Depth 7 | Out-File $costedPath -Encoding utf8') -eq 1) 'missed'
  T 'MUST FIRE  a pipe continued onto the next line' `
    ((Count-Cj ('$doc | ConvertTo-Json -Depth 4 |' + "`n" + '  Set-Content -LiteralPath $p -Encoding UTF8')) -eq 1) 'a continuation hid it'
  T 'MUST FIRE  inside an if block, as the -Apply writers spell it' `
    ((Count-Cj 'if ($Apply) { ($pu | ConvertTo-Json -Depth 8) | Set-Content $puPath -Encoding UTF8 }') -eq 1) 'missed'
  # MUST NOT FIRE - legal inputs.
  T 'MUST NOT FIRE  the converted form, piped into Write-TcLfFile' `
    ((Count-Cj '$null = $doc | ConvertTo-Json -Depth 6 | Write-TcLfFile -Path $p') -eq 0) 'counted'
  T 'MUST NOT FIRE  the converted form, piped into Write-TcAtomicFile -Lf' `
    ((Count-Cj '$null = ($rb | ConvertTo-Json -Depth 8) | Write-TcAtomicFile -Path $rbPath -Lf') -eq 0) 'counted'
  T 'MUST NOT FIRE  Set-Content of text that never passed through ConvertTo-Json' `
    ((Count-Cj '$lines | Set-Content $p -Encoding UTF8') -eq 0) 'counted'
  T 'MUST NOT FIRE  -Append is an append, not a replace (lib\append-line.ps1 owns that)' `
    ((Count-Cj '$row | ConvertTo-Json -Compress | Out-File $log -Append -Encoding utf8') -eq 0) 'counted'
  T 'MUST NOT FIRE  a comment describing the shape' `
    ((Count-Cj '# the old code did $doc | ConvertTo-Json | Set-Content $p here') -eq 0) 'a comment was counted'
  T 'MUST NOT FIRE  a string carrying the shape' `
    ((Count-Cj '$fx = ''$doc | ConvertTo-Json | Set-Content $p''') -eq 0) 'a string was counted'
  T 'MUST NOT FIRE  a line marked crlf-json:allow' `
    ((Count-Cj '$doc | ConvertTo-Json | Set-Content $p   # crlf-json:allow a gitignored scratch report') -eq 0) 'the marker was ignored'
  $cjBody = "param([switch]`$SelfTest)`nif (`$SelfTest) {`n  `$doc | ConvertTo-Json | Set-Content `$tmp -Encoding UTF8`n  exit 0`n}`n"
  T 'MUST NOT FIRE  the same write inside a self-test body is a fixture' ((Count-Cj $cjBody) -eq 0) 'the self-test body was counted'
  # CLEAN TWIN - the self-test exclusion must not hide the identical line in production code below it.
  $cjMixed = $cjBody + "`$doc | ConvertTo-Json | Set-Content `$p -Encoding UTF8`n"
  $cjL = Get-TcCrlfJsonWriteLines -Text $cjMixed -Path 'grocery\x.ps1'
  T 'CLEAN TWIN  the production twin of a self-test write is counted, at its own line, 6' ((@($cjL).Count -eq 1) -and ($cjL[0] -eq 6)) ("lines=" + (@($cjL) -join ','))
  T 'CLEAN TWIN  the Move-Item count does not see a CRLF JSON write, so the two marks stay apart' ((Count-Hits '$doc | ConvertTo-Json | Set-Content $p -Encoding UTF8') -eq 0) 'counted as a bare replace'
  $cjOr = "param([switch]`$SelfTest, [switch]`$Apply)`nif (`$SelfTest -or `$Apply) {`n  `$doc | ConvertTo-Json | Set-Content `$p -Encoding UTF8`n}`n"
  T 'CLEAN TWIN  `if ($SelfTest -or $Apply)` runs in production too, so its write is COUNTED (the shortcut must not take it)' ((Count-Cj $cjOr) -eq 1) 'a production write was hidden as a fixture'
  $cjElse = "param([switch]`$SelfTest)`nif (`$SelfTest) {`n  `$x = 1`n} else {`n  `$doc | ConvertTo-Json | Set-Content `$p -Encoding UTF8`n}`n"
  T 'CLEAN TWIN  the ELSE of `if ($SelfTest)` is production, so its write is COUNTED' ((Count-Cj $cjElse) -eq 1) 'the else branch was hidden as a fixture'

  # THE WALK, FROM A WORKTREE ROOT (lib\tree-walk.ps1): the root is scanned, a sibling below it is not.
  $wtFx = New-TcWorktreeFixture -Files @{ 'grocery\a.ps1' = 'Move-Item $t $p -Force'; 'lib\atomic-write.ps1' = 'Move-Item $t $p -Force' }
  try {
    $wtFound = @(Get-BareReplaceScanFiles -RootDir $wtFx.Root)
    $wtHits = Measure-TcWorktreeFixture -Fixture $wtFx -Found $wtFound
    $wtNames = @($wtFound | Where-Object { ([string]$_).StartsWith($wtFx.Root + '\', [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { Split-Path $_ -Leaf })
    T 'MUST FIRE  a root that IS a worktree is scanned, not excluded whole' ($wtNames -contains 'a.ps1') ("root files=" + ($wtNames -join ','))
    T 'MUST NOT FIRE  the helper lib\atomic-write.ps1 is not scanned - it is the one sanctioned Move-Item -Force' ($wtNames -notcontains 'atomic-write.ps1') ("root files=" + ($wtNames -join ','))
    T 'MUST NOT FIRE  a sibling worktree below that root is excluded' ($wtHits.Sibling -eq 0) ("sibling=" + $wtHits.Sibling)
  } finally { Remove-Item -LiteralPath $wtFx.Temp -Recurse -Force -ErrorAction SilentlyContinue }

  # ---- THE LIVE PATH, DRIVEN (2026-09-12) -------------------------------------------------------------
  # The founding shape is a pre-push run-gates pass whose count FELL: it rewrote the TRACKED baseline in the
  # checkout being pushed, without riding the push, and cost that pass its reuse record. These three run THIS
  # script as a child against a one-file temp tree and a temp baseline, so they exercise the code a gate runs.
  # ONE DIRECTORY PER RUN, removed in finally: concurrent pushes run this suite in the same %TEMP%.
  $brWt = Join-Path $env:TEMP ('br-live-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $brWt -ErrorAction Stop | Out-Null
  try {
    $brTree = Join-Path $brWt 'tree'
    New-Item -ItemType Directory -Path (Join-Path $brTree 'grocery') -ErrorAction Stop -Force | Out-Null
    # EXACTLY ONE bare replace, so the counts below are the fixture's and not the tree's.
    [IO.File]::WriteAllText((Join-Path $brTree 'grocery\one.ps1'), 'Move-Item $t $p -Force', (New-Object Text.UTF8Encoding($false)))
    $brNote = 'fixture note (keep me)'
    $brBl = Join-Path $brWt 'baseline.json'
    $brSeed = [pscustomobject]@{ generated = '2026-01-01T00:00:00'; sites = 2
                                 history = @([pscustomobject]@{ date = '2026-01-01T00:00:00'; count = 2 }); note = $brNote }
    $null = Write-TcLfFile -Path $brBl -Text ($brSeed | ConvertTo-Json -Depth 5) -NoBom
    $brSeedB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($brBl))

    $bo1 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $brTree -BaselineFile $brBl)
    $brc1 = $LASTEXITCODE
    $brSame1 = [string]::Equals($brSeedB64, [Convert]::ToBase64String([IO.File]::ReadAllBytes($brBl)), [StringComparison]::Ordinal)
    T 'MUST FIRE  a FALL (1 site, baseline 2) with no -Tighten is SPOKEN and the baseline left byte-identical, so a gate run leaves its checkout clean' `
      ($brc1 -eq 0 -and $brSame1 -and (($bo1 -join "`n") -match 'CAN tighten')) ("rc=$brc1 baselineUnchanged=$brSame1")

    $null = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $brTree -BaselineFile $brBl -Tighten)
    $brc2 = $LASTEXITCODE
    $bb2 = [IO.File]::ReadAllBytes($brBl)
    $bcr2 = 0; foreach ($x in $bb2) { if ($x -eq 13) { $bcr2++ } }
    $bbom2 = ($bb2.Length -ge 3 -and $bb2[0] -eq 0xEF -and $bb2[1] -eq 0xBB -and $bb2[2] -eq 0xBF)
    $bdoc2 = $null
    try { $bdoc2 = [Text.Encoding]::UTF8.GetString($bb2) | ConvertFrom-Json } catch { }
    T '-Tighten records the fall in the bytes git stores: no CR, no BOM (the committed blob has none), one trailing LF, sites lowered, and the note kept' `
      ($brc2 -eq 0 -and $bcr2 -eq 0 -and (-not $bbom2) -and $bb2[-1] -eq 10 -and $null -ne $bdoc2 -and
       [int]$bdoc2.sites -eq 1 -and [string]$bdoc2.note -eq $brNote -and @($bdoc2.history).Count -eq 2) `
      ("rc=$brc2 cr=$bcr2 bom=$bbom2 sites=$(if ($bdoc2) { $bdoc2.sites }) note=$(if ($bdoc2) { $bdoc2.note })")

    # CLEAN TWIN: not writing on a fall must not have disarmed the ratchet in the direction that matters.
    $brRise = Join-Path $brWt 'baseline-rise.json'
    $null = Write-TcLfFile -Path $brRise -Text ([pscustomobject]@{ generated = '2026-01-01T00:00:00'; sites = 0; history = @(); note = $brNote } | ConvertTo-Json -Depth 5) -NoBom
    $brRiseB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($brRise))
    $null = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $brTree -BaselineFile $brRise)
    $brc3 = $LASTEXITCODE
    $brSame3 = [string]::Equals($brRiseB64, [Convert]::ToBase64String([IO.File]::ReadAllBytes($brRise)), [StringComparison]::Ordinal)
    T 'CLEAN TWIN  a count that ROSE still exits 2 and writes nothing, so not recording a fall did not disarm the ratchet' `
      ($brc3 -eq 2 -and $brSame3) ("rc=$brc3 baselineUnchanged=$brSame3")

    # THE CRLF JSON MARK, AT ITS BAR AND ONE STEP PAST IT (og-06). A second tree holds one bare replace and ONE CRLF
    # JSON write, so the Move-Item mark sits at its bar of 1 in every case below and only the second mark moves.
    $cjTree = Join-Path $brWt 'tree-cj'
    New-Item -ItemType Directory -Path (Join-Path $cjTree 'grocery') -ErrorAction Stop -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $cjTree 'grocery\one.ps1'), 'Move-Item $t $p -Force', (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $cjTree 'grocery\cj.ps1'), '$doc | ConvertTo-Json -Depth 4 | Set-Content $p -Encoding UTF8', (New-Object Text.UTF8Encoding($false)))
    $cjAt = Join-Path $brWt 'baseline-cj-at.json'
    $null = Write-TcLfFile -Path $cjAt -Text ([pscustomobject]@{ generated = '2026-01-01T00:00:00'; sites = 1; crlf_json_sites = 1; history = @(); note = $brNote } | ConvertTo-Json -Depth 5) -NoBom
    $cjAtB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($cjAt))
    $cjo1 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $cjTree -BaselineFile $cjAt)
    $cjc1 = $LASTEXITCODE
    $cjSame1 = [string]::Equals($cjAtB64, [Convert]::ToBase64String([IO.File]::ReadAllBytes($cjAt)), [StringComparison]::Ordinal)
    T 'CLEAN TWIN  AT THE BAR: 1 CRLF JSON write against a mark of 1 passes, writes nothing, and names the site' `
      ($cjc1 -eq 0 -and $cjSame1 -and (($cjo1 -join "`n") -match 'crlf-json\s+grocery\\cj\.ps1:1')) ("rc=$cjc1 baselineUnchanged=$cjSame1")
    $cjPast = Join-Path $brWt 'baseline-cj-past.json'
    $null = Write-TcLfFile -Path $cjPast -Text ([pscustomobject]@{ generated = '2026-01-01T00:00:00'; sites = 1; crlf_json_sites = 0; history = @(); note = $brNote } | ConvertTo-Json -Depth 5) -NoBom
    $cjPastB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($cjPast))
    $cjo2 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $cjTree -BaselineFile $cjPast)
    $cjc2 = $LASTEXITCODE
    $cjSame2 = [string]::Equals($cjPastB64, [Convert]::ToBase64String([IO.File]::ReadAllBytes($cjPast)), [StringComparison]::Ordinal)
    T 'MUST FIRE  ONE STEP PAST THE BAR: 1 CRLF JSON write against a mark of 0 exits 2, names the cause, and writes nothing' `
      ($cjc2 -eq 2 -and $cjSame2 -and (($cjo2 -join "`n") -match 'ConvertTo-Json \| Set-Content/Out-File')) ("rc=$cjc2 baselineUnchanged=$cjSame2")
    $cjFall = Join-Path $brWt 'baseline-cj-fall.json'
    $null = Write-TcLfFile -Path $cjFall -Text ([pscustomobject]@{ generated = '2026-01-01T00:00:00'; sites = 1; crlf_json_sites = 2; history = @([pscustomobject]@{ date = '2026-01-01T00:00:00'; count = 1 }); note = $brNote } | ConvertTo-Json -Depth 5) -NoBom
    $null = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $cjTree -BaselineFile $cjFall -Tighten)
    $cjc3 = $LASTEXITCODE
    $cjDoc3 = $null
    try { $cjDoc3 = [IO.File]::ReadAllText($cjFall) | ConvertFrom-Json } catch { }
    T '-Tighten records a CRLF JSON fall (2 -> 1) and leaves the Move-Item mark and its history as they were' `
      ($cjc3 -eq 0 -and $null -ne $cjDoc3 -and [int]$cjDoc3.crlf_json_sites -eq 1 -and [int]$cjDoc3.sites -eq 1 -and @($cjDoc3.history).Count -eq 1 -and [string]$cjDoc3.note -eq $brNote) `
      ("rc=$cjc3 crlf=$(if ($cjDoc3) { $cjDoc3.crlf_json_sites }) sites=$(if ($cjDoc3) { $cjDoc3.sites }) history=$(if ($cjDoc3) { @($cjDoc3.history).Count })")
  } finally { Remove-Item -LiteralPath $brWt -Recurse -Force -ErrorAction SilentlyContinue }

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} of {1} check(s)" -f $f, $n); exit 1 }
  Write-Output ("SELF-TEST PASS: {0} checks - 6 must-fire shapes, 8 must-not-fire inputs, line reporting and return arity, the CRLF JSON count's 5 must-fire and 8 must-not-fire shapes, the walk from a worktree root, and the live path driven against a temp tree and baseline, the CRLF JSON mark at its bar and one step past it" -f $n)
  exit 0
}

# ------------------------------------------------------------------------------------- live run
# NEVER SCAN YOURSELF, by the rule audit-write-seam states. The parser would not count the fixtures above
# (they are strings), so this is convention rather than necessity here, and it costs nothing.
if (-not $Root) { $Root = $repo }
$files = @(Get-BareReplaceScanFiles -RootDir $Root -Self $PSCommandPath)
if (-not $files.Count) {
  Write-Output 'BARE-REPLACE AUDIT BLIND: found zero .ps1 files to scan, which means the discovery is broken rather than the tree being clean.'
  Exit-Guard -Name 'bare-replace' -Summary 'blind=no-files' -Code 3
}
$hits = @()
$cjHits = @()
foreach ($p in $files) {
  $scan = Get-TcBareReplaceScan -Text ([IO.File]::ReadAllText($p)) -Path $p
  foreach ($ln in @($scan.Bare)) { $hits += [pscustomobject]@{ File = $p; Line = $ln } }
  foreach ($ln in @($scan.CrlfJson)) { $cjHits += [pscustomobject]@{ File = $p; Line = $ln } }
}
$count = $hits.Count
$cj = $cjHits.Count

$BR_NOTE = 'HIGH-WATER MARK for Move-Item -Force commands outside lib\atomic-write.ps1. This number may only go DOWN, and a fall to zero or a fall over 60% in one run is REFUSED as a probably-broken detector (lib\ratchet.ps1).'
$blDoc = $null
if (Test-Path -LiteralPath $BASELINE_FILE) {
  try { $blDoc = Get-Content -LiteralPath $BASELINE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $blDoc = $null }
}
function Write-BrBaseline([int]$Sites, $CrlfJson) {
  <# The recorded marks, in the bytes git stores. The committed blob carries NO BOM, so -NoBom. The NOTE the
     file already carries is KEPT rather than replaced, and the key order is the committed one, so the diff
     of a record is only what moved. The history is the Move-Item mark's, and gains a row only when that mark moves.
     $CrlfJson is the second mark, or $null to leave the key out. #>
  $keepNote = if ($blDoc -and $blDoc.note) { [string]$blDoc.note } else { $BR_NOTE }
  $srcDoc = if ($blDoc) { $blDoc } else { [pscustomobject]@{} }
  $hist = if ($blDoc -and [int]$blDoc.sites -eq $Sites -and $blDoc.PSObject.Properties['history']) { @($blDoc.history) } else { Add-RatchetHistory -Doc $srcDoc -Count $Sites }
  $doc = [ordered]@{ generated = (Get-Date).ToString('s'); sites = $Sites }
  if ($null -ne $CrlfJson) { $doc['crlf_json_sites'] = [int]$CrlfJson }
  $doc['history'] = $hist
  $doc['note'] = $keepNote
  $null = Write-TcLfFile -Path $BASELINE_FILE -Text ([pscustomobject]$doc | ConvertTo-Json -Depth 5) -NoBom
  return $hist
}
$summary = { param($extra) ("scanned={0} sites={1} crlf_json={2}" -f $files.Count, $count, $cj) + $(if ($extra) { ' ' + $extra } else { '' }) }
if (-not $blDoc) {
  # SEEDING IS NOT RECORDING A FALL. With no baseline there is nothing to protect and nothing to compare
  # against, so the first run writes one - which in production cannot happen, the file being tracked.
  # The day-one count goes into the history as well, so every later fall is read against what was first measured.
  $null = Write-BrBaseline $count $cj
  Write-Output ("bare-replace: baseline written at {0} site(s) and {1} CRLF JSON write(s) over {2} file(s). From here both numbers may only go DOWN." -f $count, $cj, $files.Count)
  Exit-Guard -Name 'bare-replace' -Summary (& $summary 'seeded') -Code 0
}
$base = [int]$blDoc.sites
$cjBase = if ($blDoc.PSObject.Properties['crlf_json_sites']) { [int]$blDoc.crlf_json_sites } else { $null }

foreach ($h in ($hits | Sort-Object File, Line)) {
  Write-Output ("  bare  {0}:{1}" -f (Get-TcPathBelowRoot $h.File (Get-TcRootFull $Root)).TrimStart('\'), $h.Line)
}
foreach ($h in ($cjHits | Sort-Object File, Line)) {
  Write-Output ("  crlf-json  {0}:{1}" -f (Get-TcPathBelowRoot $h.File (Get-TcRootFull $Root)).TrimStart('\'), $h.Line)
}
$rose = $false
if ($count -gt $base) {
  Write-Output ("BARE-REPLACE AUDIT FAILED: {0} Move-Item -Force command(s) outside lib\atomic-write.ps1, against a baseline of {1}. A NEW one was added: a reader holding that destination open makes it lose the write, silently under the default ErrorActionPreference. Use Write-TcAtomicFile, or mark a deliberate exception with '# atomic-replace:allow <reason>'." -f $count, $base)
  $rose = $true
}
if ($null -ne $cjBase -and $cj -gt $cjBase) {
  Write-Output ("BARE-REPLACE AUDIT FAILED: {0} ConvertTo-Json | Set-Content/Out-File write(s) outside a self-test body, against a baseline of {1}. A NEW one was added: under PS 5.1 it writes CRLF, which over a tracked file leaves the checkout dirty with a zero-line diff. Pipe into Write-TcLfFile (lib\lf-write.ps1) or Write-TcAtomicFile -Lf (lib\atomic-write.ps1) instead, matching the file's BOM, or mark a deliberate exception with '# crlf-json:allow <reason>'." -f $cj, $cjBase)
  $rose = $true
}
if ($rose) { Exit-Guard -Name 'bare-replace' -Summary (& $summary ("baseline={0} crlf_json_baseline={1}" -f $base, $cjBase)) -Code 2 }

$move = Test-RatchetMove -Name 'bare-replace' -Count $count -Baseline $base -AcceptDrop:$AcceptDrop
$cjMove = if ($null -ne $cjBase) { Test-RatchetMove -Name 'crlf-json' -Count $cj -Baseline $cjBase -AcceptDrop:$AcceptDrop } else { $null }
foreach ($m in @($move, $cjMove)) {
  if ($m -and $m.Verdict -eq 'implausible') {
    Write-Output $m.Message
    Exit-Guard -Name 'bare-replace' -Summary (& $summary 'refused-to-lower') -Code 2
  }
}
# A FALL IS SPOKEN, NOT WRITTEN, unless this run was asked to record it (see the header). -AcceptDrop is
# such an ask: it has always recorded the fall it names. A baseline without the second key is spoken the same way,
# and -Tighten records it at today's count.
$record = ($Tighten -or $AcceptDrop)
$newSites = $base; $newCj = $cjBase; $moved = @()
if ($move.Verdict -eq 'tightened') { if ($record) { $newSites = [int]$move.NewBaseline; $moved += $move.Message } else { Write-Output ("bare-replace: the Move-Item ratchet CAN tighten - {0} site(s), baseline {1}." -f $count, $base) } }
if ($cjMove -and $cjMove.Verdict -eq 'tightened') { if ($record) { $newCj = [int]$cjMove.NewBaseline; $moved += $cjMove.Message } else { Write-Output ("bare-replace: the CRLF JSON ratchet CAN tighten - {0} write(s), baseline {1}." -f $cj, $cjBase) } }
if ($null -eq $cjBase) { if ($record) { $newCj = $cj; $moved += ("crlf-json: mark recorded at {0}" -f $cj) } else { Write-Output ("bare-replace: NO CRLF JSON MARK in the baseline yet - {0} write(s) today. Record it with -Tighten." -f $cj) } }
if ($moved.Count) {
  $hist = Write-BrBaseline $newSites $newCj
  foreach ($m in $moved) { Write-Output ("PASSED and TIGHTENED - " + $m) }
  Write-Output ("  " + (Get-RatchetTrend -History $hist))
  Write-Output '  New baseline written - commit ops\bare-replace-baseline.json, or it protects only this checkout.'
  Exit-Guard -Name 'bare-replace' -Summary (& $summary ("tightened-from={0} crlf_json_from={1}" -f $base, $cjBase)) -Code 0
}
if ($count -lt $base -or ($null -ne $cjBase -and $cj -lt $cjBase)) {
  Write-Output ("bare-replace: PASSED, and the ratchet CAN tighten - {0} site(s) against {1}, {2} CRLF JSON write(s) against {3}. NOT written: this may be a pre-push gate, and a rewrite here dirties the checkout being pushed without riding the push. Record it with -Tighten and commit ops\bare-replace-baseline.json." -f $count, $base, $cj, $cjBase)
  Exit-Guard -Name 'bare-replace' -Summary (& $summary ("baseline={0} crlf_json_baseline={1} can-tighten" -f $base, $cjBase)) -Code 0
}
Write-Output ("bare-replace: PASSED - {0} known Move-Item -Force command(s) and {1} CRLF JSON write(s) over {2} file(s), at their marks. Converting one lowers its mark permanently." -f $count, $cj, $files.Count)
Exit-Guard -Name 'bare-replace' -Summary (& $summary ("baseline={0} crlf_json_baseline={1}" -f $base, $cjBase)) -Code 0
