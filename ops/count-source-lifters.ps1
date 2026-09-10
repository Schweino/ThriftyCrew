<#
  count-source-lifters.ps1 - how many files read another script's SOURCE, and how many execute it.

  WHY THIS EXISTS. On 2026-09-08 the same quantity - "how many things lift
  compare-deals.ps1's functions" - was counted SIX times and returned six answers:

      .claude/rules/grocery.md, before          3   (stood for months)
      a course agent, morning                  17 read / 12 execute
      .claude/rules/grocery.md, after that     17 read / 14 execute
      the command that file itself quoted      53 name it / 13 execute
      a tighter Get-Content test               18 read / 12 execute (15 outside out\)
      a second course agent, afternoon         54 name it / 17 read / 12 execute

  NOT ONE of those disagreements was about the code. Every one was about the TEST, and
  no two writers used the same one. The estate's own rule in that file says "count it,
  never quote it" - and then quoted a number the command beside it does not produce.

  So the count moves out of prose entirely. Cite this script, not a digit.

  THE FOUR TESTS, because the answer depends entirely on which you mean:

    NAMES     the file's text contains the target's filename anywhere. Widest. Includes
              comments and doc strings, so it is an upper bound on coupling, not a
              measure of it.
    READS     a Get-Content whose target, within 200 characters, names the target file.
              This is "reads its source", the thing the architectural claim is about.
    EXECUTES  READS, and the text that Get-Content returned REACHES a call that runs it:
              Invoke-Expression, iex, [scriptblock]::Create, .InvokeScript or .NewScriptBlock.
              The text is followed through assignments, foreach, [regex]::Match and -match into
              $Matches, in source order, so a variable reassigned from another file stops
              carrying it. This is the real lifting, and each is printed with the line that runs it.
    Each is reported with and without one-off scratch scripts under grocery\out\, which
    is where several of the historical disagreements came from.

  EXECUTES WAS A CO-OCCURRENCE UNTIL 2026-09-10, AND IT WAS WRONG IN BOTH DIRECTIONS. It
  was "READS, plus Invoke-Expression or iex ANYWHERE in the file". Over 592 files that named
  grocery\test-auditors.ps1 as the one script executing compare-deals.ps1 source - but
  test-auditors reads compare-deals only to -match its text, and every Invoke-Expression it
  makes runs text read from guards.ps1, check-ad-cycles.ps1 and two sampling scripts. The
  same test could not see a lift that runs through [scriptblock]::Create at all. Two words
  in one file are not a data flow.

  IT WAS ALSO BLIND IN EVERY WORKTREE until the same day. The exclusions matched the FULL
  path, a worktree lives under .claude\worktrees\, so every file was excluded and the run
  exited 3. They match the path below -Root now.

  SCOPE OF A CLEAN REPORT: UNSOUND for all three tests, so a zero proves nothing.
    NAMES misses nothing that spells the filename, and overcounts by design.
    READS misses a read through a path held in a variable or built by concatenation, and
      any reader that is not Get-Content ([IO.File]::ReadAllText is invisible to it).
    EXECUTES follows the text within ONE file, in source order. It misses text handed
      through a function parameter, a pipeline $_, a loop that assigns after its sink, a
      temp file that is then dot-sourced, and any runner outside the five above. It also
      over-follows: an index or a length computed from the text carries it too, so a
      reported executor is confirmed by reading the printed line, not by the count.

  Exit 0 = counted. Exit 3 = could not evaluate (no such target, or nothing scanned).

  Params: -Script <filename>, -Root, -SelfTest
#>
[CmdletBinding()]
param(
  [string]$Script = 'compare-deals.ps1',
  [string]$Root = '',
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Root) { $Root = Split-Path -Parent $here }

function Get-ExecuteLine {
  param([string]$Text, [string]$Target)
  <# The 1-based line of the first call, in source order, that RUNS text read from the target. 0 if none. #>
  $tok = $null; $perr = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tok, [ref]$perr)
  # Variable names currently holding the target's text, or something cut out of it. Keyed on UserPath with
  # any scope prefix stripped, so $script:x and $x are one name. NOT VariablePath.UnqualifiedPath: that
  # member is not public in PowerShell 5.1, reads as $null, and the first cut of this filed every
  # variable under the one $null key - so all of them carried, and the must-not-fire cases caught it.
  $carrying = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $carries = {
    param($node)
    if ($null -eq $node) { return $false }
    $hit = $node.Find({
      param($n)
      if ($n -is [System.Management.Automation.Language.VariableExpressionAst]) { return $carrying.Contains(($n.VariablePath.UserPath -replace '^\w+:', '')) }
      if ($n -is [System.Management.Automation.Language.CommandAst]) {
        return (($n.GetCommandName() -eq 'Get-Content') -and ($n.Extent.Text.IndexOf($Target, [StringComparison]::OrdinalIgnoreCase) -ge 0))
      }
      return $false
    }, $true)
    return ($null -ne $hit)
  }
  $found = $ast.FindAll({
    param($n)
    ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) -or
    ($n -is [System.Management.Automation.Language.ForEachStatementAst]) -or
    ($n -is [System.Management.Automation.Language.CommandAst]) -or
    ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) -or
    (($n -is [System.Management.Automation.Language.BinaryExpressionAst]) -and (@('Imatch', 'Cmatch') -contains [string]$n.Operator))
  }, $true)
  $events = @($found | Sort-Object { $_.Extent.StartOffset })

  foreach ($e in $events) {
    if ($e -is [System.Management.Automation.Language.AssignmentStatementAst]) {
      $left = $e.Left
      if ($left -is [System.Management.Automation.Language.AttributedExpressionAst]) { $left = $left.Child }
      if ($left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
      $name = $left.VariablePath.UserPath -replace '^\w+:', ''
      if (-not $name) { continue }
      if (& $carries $e.Right) { [void]$carrying.Add($name) }
      elseif ([string]$e.Operator -eq 'Equals') { [void]$carrying.Remove($name) }   # += keeps what it had
    }
    elseif ($e -is [System.Management.Automation.Language.ForEachStatementAst]) {
      $name = $e.Variable.VariablePath.UserPath -replace '^\w+:', ''
      if (& $carries $e.Condition) { [void]$carrying.Add($name) } else { [void]$carrying.Remove($name) }
    }
    elseif ($e -is [System.Management.Automation.Language.BinaryExpressionAst]) {
      # -match fills $Matches from its left side, and a later -match over other text replaces it.
      if (& $carries $e.Left) { [void]$carrying.Add('Matches') } else { [void]$carrying.Remove('Matches') }
    }
    elseif ($e -is [System.Management.Automation.Language.CommandAst]) {
      $cn = $e.GetCommandName()
      if ($cn -ne 'Invoke-Expression' -and $cn -ne 'iex') { continue }
      $inputs = New-Object System.Collections.ArrayList
      foreach ($el in @($e.CommandElements | Select-Object -Skip 1)) { [void]$inputs.Add($el) }
      # `$src | Invoke-Expression`: what runs is whatever came down the pipeline before it.
      foreach ($pe in $e.Parent.PipelineElements) {
        if ([object]::ReferenceEquals($pe, $e)) { break }
        [void]$inputs.Add($pe)
      }
      foreach ($inp in $inputs) { if (& $carries $inp) { return $e.Extent.StartLineNumber } }
    }
    else {
      $member = [string]$e.Member.Extent.Text
      $runs = ($e.Static -and $member -eq 'Create' -and
               $e.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
               $e.Expression.TypeName.FullName -match '^(System\.Management\.Automation\.)?ScriptBlock$') -or
              ((-not $e.Static) -and ($member -eq 'InvokeScript' -or $member -eq 'NewScriptBlock'))
      if (-not $runs) { continue }
      foreach ($a in @($e.Arguments)) { if (& $carries $a) { return $e.Extent.StartLineNumber } }
    }
  }
  return 0
}

function Get-Lifters {
  param([string]$RootDir, [string]$Target)
  <# @{Names=[];Reads=[];Executes=[];Sites=@{rel=line};Scanned=n} - the four tests, one pass. #>
  $rootFull = (Resolve-Path -LiteralPath $RootDir).ProviderPath.TrimEnd('\')
  # Exclusions match the path BELOW the root. Matching the full path excluded everything when the
  # root itself sits under .claude\worktrees\, and every spawned session runs from exactly there.
  $files = @(Get-ChildItem -LiteralPath $rootFull -Filter *.ps1 -Recurse -File -ErrorAction SilentlyContinue |
             Where-Object {
               $_.Extension -eq '.ps1' -and
               $_.FullName.Substring($rootFull.Length).TrimStart('\') -notmatch '(^|\\)(\.git|archive|node_modules|worktrees)\\' })
  $names = New-Object System.Collections.ArrayList
  $reads = New-Object System.Collections.ArrayList
  $execs = New-Object System.Collections.ArrayList
  $sites = @{}
  foreach ($f in $files) {
    # The target never counts as its own caller.
    if ($f.Name -eq $Target) { continue }
    try { $t = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop } catch { continue }
    $t = $t + ''
    if ($t.IndexOf($Target, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
    $rel = $f.FullName.Substring($rootFull.Length).TrimStart('\')
    [void]$names.Add($rel)
    # READS: a Get-Content whose target within 200 chars names the file.
    $isRead = $false
    foreach ($m in [regex]::Matches($t, 'Get-Content')) {
      $tail = $t.Substring($m.Index + $m.Length, [Math]::Min(200, $t.Length - $m.Index - $m.Length))
      if ($tail.IndexOf($Target, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $isRead = $true; break }
    }
    if (-not $isRead) { continue }
    [void]$reads.Add($rel)
    $line = Get-ExecuteLine -Text $t -Target $Target
    if ($line -gt 0) { [void]$execs.Add($rel); $sites[$rel] = $line }
  }
  return @{ Names = $names; Reads = $reads; Executes = $execs; Sites = $sites; Scanned = $files.Count }
}

function Split-Scratch([System.Collections.ArrayList]$rows) {
  $out = @($rows | Where-Object { $_ -match '^grocery\\out\\' })
  $main = @($rows | Where-Object { $_ -notmatch '^grocery\\out\\' })
  return @{ Main = $main; Scratch = $out }
}

if ($SelfTest) {
  $tmp = Join-Path $env:TEMP ('csl-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $tmp 'grocery\out') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $tmp 'archive') -Force | Out-Null
  $pass = 0; $fails = New-Object System.Collections.ArrayList
  function _C($label, $name, $ok, $detail) {
    if ($ok) { $script:pass++ } else { [void]$script:fails.Add("$label $name") }
    Write-Output ("  {0,-14} {1,-60} {2}" -f $label, $name, $(if ($ok) { 'ok' } else { "FAIL $detail" }))
  }
  function _W($rel, $body) {
    $p = Join-Path $tmp $rel
    New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force | Out-Null
    [IO.File]::WriteAllText($p, $body, (New-Object Text.UTF8Encoding($false)))
  }

  try {
  # Fixtures are single-quoted literals with doubled inner quotes, never built by
  # concatenation: a concatenated fixture passes THREE positional arguments and the case
  # then runs against a truncated line, which has passed for the wrong reason here before.
  _W 'grocery\target.ps1'      'function Get-Thing { 1 }'
  _W 'grocery\lifter.ps1'      '$src = Get-Content "$PSScriptRoot\target.ps1" -Raw; Invoke-Expression $src'
  _W 'grocery\reader.ps1'      '$src = Get-Content "$PSScriptRoot\target.ps1" -Raw; $src.Length'
  _W 'grocery\mentioner.ps1'   '# see target.ps1 for the shared helper, we do not read it'
  _W 'grocery\out\scratch.ps1' '$s = Get-Content "..\target.ps1" -Raw; Invoke-Expression $s'
  _W 'grocery\faraway.ps1'     ('$x = Get-Content "other.txt"' + ("`n# filler" * 40) + "`n# target.ps1 mentioned far below")
  _W 'archive\old.ps1'         '$src = Get-Content "target.ps1" -Raw; Invoke-Expression $src'
  # The founding false positive (2026-09-10): test-auditors read compare-deals.ps1 only to -match
  # its text, and every Invoke-Expression it made ran text cut out of a DIFFERENT file.
  _W 'grocery\matcher.ps1'     '$src = Get-Content "$PSScriptRoot\target.ps1" -Raw
if ($src -match "function Get-Thing") { "the engine still defines it" }
$other = Get-Content "$PSScriptRoot\guards.ps1" -Raw
$m = [regex]::Match($other, "(?ms)^function Get-Guard.*?^\}")
Invoke-Expression $m.Value'
  _W 'grocery\reuser.ps1'      '$m = [regex]::Match((Get-Content "$PSScriptRoot\target.ps1" -Raw), "Get-Thing")
$m = [regex]::Match((Get-Content "$PSScriptRoot\other.ps1" -Raw), "(?ms)^function.*?^\}")
Invoke-Expression $m.Value'
  # The live lift's shape (import-walmart-batch.ps1 cutting Build-Row out of build-walmart-deals.ps1).
  _W 'grocery\regexlifter.ps1' '$builderSrc = Get-Content (Join-Path $PSScriptRoot "target.ps1") -Raw
foreach ($fn in @("Get-Thing")) {
  $m = [regex]::Match($builderSrc, "(?ms)^function\s+$fn\s*\{.*?^\}")
  if (-not $m.Success) { throw "could not lift $fn" }
  Invoke-Expression $m.Value
}'
  _W 'grocery\matcheslifter.ps1' '$s = Get-Content "$PSScriptRoot\target.ps1" -Raw
if ($s -match "(?ms)^function Get-Thing.*?\}") { iex $Matches[0] }'
  _W 'grocery\sblifter.ps1'    '$src = Get-Content "$PSScriptRoot\target.ps1" -Raw
$block = $src.Substring(0, $src.IndexOf("}") + 1)
. ([scriptblock]::Create($block))'
  # A worktree BELOW the root is excluded; a root that IS a worktree is scanned.
  _W '.claude\worktrees\wt1\grocery\target.ps1' 'function Get-Thing { 1 }'
  _W '.claude\worktrees\wt1\grocery\lifter.ps1' '$src = Get-Content "$PSScriptRoot\target.ps1" -Raw; Invoke-Expression $src'

  $r = Get-Lifters -RootDir $tmp -Target 'target.ps1'
  $sN = Split-Scratch $r.Names; $sR = Split-Scratch $r.Reads; $sE = Split-Scratch $r.Executes

  _C 'MUST FIRE' 'a Get-Content whose text reaches Invoke-Expression is EXECUTES' ($r.Executes -contains 'grocery\lifter.ps1') ($r.Executes -join ',')
  _C 'MUST FIRE' 'a Get-Content with no Invoke-Expression is READS but not EXECUTES' (($r.Reads -contains 'grocery\reader.ps1') -and ($r.Executes -notcontains 'grocery\reader.ps1')) 'reader misclassified'
  _C 'MUST FIRE' 'a function cut out by [regex]::Match and run is EXECUTES, at its line' (($r.Executes -contains 'grocery\regexlifter.ps1') -and ($r.Sites['grocery\regexlifter.ps1'] -eq 5)) ("line=" + $r.Sites['grocery\regexlifter.ps1'])
  _C 'MUST FIRE' 'text reaching iex through -match and $Matches is EXECUTES' ($r.Executes -contains 'grocery\matcheslifter.ps1') ($r.Executes -join ',')
  _C 'MUST FIRE' 'text reaching [scriptblock]::Create is EXECUTES' ($r.Executes -contains 'grocery\sblifter.ps1') ($r.Executes -join ',')
  _C 'MUST NOT FIRE' 'reading the target to -match it, then iex-ing ANOTHER file, is READS only' (($r.Reads -contains 'grocery\matcher.ps1') -and ($r.Executes -notcontains 'grocery\matcher.ps1')) 'a co-occurrence counted as a lift'
  _C 'MUST NOT FIRE' 'a variable reassigned from another file stops carrying the target' (($r.Reads -contains 'grocery\reuser.ps1') -and ($r.Executes -notcontains 'grocery\reuser.ps1')) 'reassignment did not clear it'
  _C 'MUST NOT FIRE' 'a bare MENTION in a comment is NAMES but never READS' (($r.Names -contains 'grocery\mentioner.ps1') -and ($r.Reads -notcontains 'grocery\mentioner.ps1')) 'a comment counted as reading source'
  _C 'MUST NOT FIRE' 'a Get-Content of something ELSE, with the name far below, is not READS' ($r.Reads -notcontains 'grocery\faraway.ps1') 'the 200-char window is not bounding anything'
  _C 'MUST NOT FIRE' 'the target is never its own caller' (($r.Names -notcontains 'grocery\target.ps1')) 'target counted itself'
  _C 'MUST NOT FIRE' 'archive is excluded' (($r.Names -notcontains 'archive\old.ps1')) 'archive was scanned'
  _C 'MUST NOT FIRE' 'a worktree below the root is excluded' ($r.Names -notcontains '.claude\worktrees\wt1\grocery\lifter.ps1') 'a sibling worktree was scanned'
  _C 'MUST FIRE' 'scratch under grocery\out is counted but reported SEPARATELY' (($sE.Scratch -contains 'grocery\out\scratch.ps1') -and ($sE.Main -notcontains 'grocery\out\scratch.ps1')) 'scratch not split out'
  $w = Get-Lifters -RootDir (Join-Path $tmp '.claude\worktrees\wt1') -Target 'target.ps1'
  _C 'MUST FIRE' 'a root that IS a worktree is scanned, not excluded whole' (($w.Scanned -gt 0) -and ($w.Executes -contains 'grocery\lifter.ps1')) ("scanned=" + $w.Scanned)
  # CLEAN TWIN: the three tests nest. Every EXECUTES is a READS is a NAMES - the property
  # that makes the four numbers comparable rather than three unrelated counts.
  $nested = $true
  foreach ($e in $r.Executes) { if ($r.Reads -notcontains $e) { $nested = $false } }
  foreach ($rd in $r.Reads) { if ($r.Names -notcontains $rd) { $nested = $false } }
  _C 'CLEAN TWIN' 'EXECUTES is a subset of READS is a subset of NAMES' $nested 'the tests do not nest'
  # Two assertions, two labels. They used to share one, and the shared label fitted neither.
  $z = Get-Lifters -RootDir $tmp -Target 'no-such-file-anywhere.ps1'
  # MUST NOT FIRE: a target nobody references is a legal input and the counter stays silent.
  _C 'MUST NOT FIRE' 'a target nobody references returns zero' (@($z.Names).Count -eq 0) (@($z.Names).Count)
  # CLEAN TWIN: and it still reports what it examined. This is the load-bearing half -
  # "0 found" and "0 scanned" are the same output from a working detector and a blind one,
  # so the scanned count is what makes the zero mean anything.
  _C 'CLEAN TWIN' 'and it still reports the population it examined, so 0 found is not 0 scanned' ($z.Scanned -gt 0) ("scanned=" + $z.Scanned)
  }
  finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

  Write-Output ''
  $total = $pass + $fails.Count
  if ($fails.Count) {
    Write-Output ("SELF-TEST FAIL: {0} case(s) of {1}" -f $fails.Count, $total)
    foreach ($f in $fails) { Write-Output ("  " + $f) }
    Write-Output 'COUNT-SOURCE-LIFTERS-COMPLETE'
    exit 1
  }
  Write-Output ("count-source-lifters self-test: {0} of {0} cases pass" -f $total)
  Write-Output 'COUNT-SOURCE-LIFTERS-COMPLETE'
  exit 0
}

if (-not (Test-Path -LiteralPath $Root)) {
  Write-Output ("count-source-lifters: BLIND - no such root " + $Root)
  Write-Output 'COUNT-SOURCE-LIFTERS-COMPLETE'
  exit 3
}
$r = Get-Lifters -RootDir $Root -Target $Script
if ($r.Scanned -eq 0) {
  Write-Output ("count-source-lifters: BLIND - 0 .ps1 files under " + $Root + ". Nothing was examined; this proves nothing.")
  Write-Output 'COUNT-SOURCE-LIFTERS-COMPLETE'
  exit 3
}

$sN = Split-Scratch $r.Names
$sR = Split-Scratch $r.Reads
$sE = Split-Scratch $r.Executes

Write-Output ("count-source-lifters: target " + $Script + ", scanned " + $r.Scanned +
              " .ps1 file(s) under " + $Root + " (.git, archive, node_modules and worktrees below it excluded)")
Write-Output ''
Write-Output ("  NAMES     {0,3}  ({1} outside grocery\out, {2} scratch)  - filename appears anywhere, comments included. An upper bound on coupling, not a measure of it." -f @($r.Names).Count, @($sN.Main).Count, @($sN.Scratch).Count)
Write-Output ("  READS     {0,3}  ({1} outside grocery\out, {2} scratch)  - a Get-Content whose target within 200 chars names it. THIS is 'reads its source'." -f @($r.Reads).Count, @($sR.Main).Count, @($sR.Scratch).Count)
Write-Output ("  EXECUTES  {0,3}  ({1} outside grocery\out, {2} scratch)  - READS, and the text read reaches Invoke-Expression, iex or [scriptblock]::Create. This is the actual lifting." -f @($r.Executes).Count, @($sE.Main).Count, @($sE.Scratch).Count)
Write-Output ''
Write-Output "  EXECUTES, named with the line that runs the lifted text:"
if (@($r.Executes).Count -eq 0) { Write-Output "    (none of a shape this test follows)" }
foreach ($x in ($r.Executes | Sort-Object)) { Write-Output ("    " + $x + ":" + $r.Sites[$x]) }
Write-Output ''
Write-Output "  SCOPE OF A CLEAN REPORT: UNSOUND. A zero means no read or run of a shape this script"
Write-Output "  follows, not none at all; the header lists what each test cannot see."
Write-Output "  Quote this script and the test you mean, never a bare digit. Six writers counted"
Write-Output "  this quantity on 2026-09-08 and produced six answers; every disagreement was the"
Write-Output "  test and none was the code."
Write-Output 'COUNT-SOURCE-LIFTERS-COMPLETE'
exit 0
