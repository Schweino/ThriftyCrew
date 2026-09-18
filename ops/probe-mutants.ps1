# probe-mutants.ps1
# ---------------------------------------------------------------------------------------------------
# A committed mutation harness: apply named mutants, each drawn from a CATALOGUED OPERATOR, to one
# PowerShell script inside a temp mirror, run that script's own -SelfTest against each, and report
# killed / survived per mutant and per operator class (2026-09-18, backlog I204).
#
# WHY THIS EXISTS. Measured 2026-09-18 (backlog I204): 27 lines in 20 tracked files record the result of
# a hand-run mutation probe, and no tracked file had `mutat` in its name - every probe was a temp mirror,
# run once and described. `.claude\rules\measurement.md` says a measurement that may recur COMMITS its
# harness, and `ops-and-gates.md` says a mutation probe is worth re-running against any detector whose
# logic was just rewritten, so this one recurs by the estate's own rule. And most recorded probes name
# the MUTANT ("the ^ anchor dropped") but not the OPERATOR it was drawn from, so "killed 9 of 9" had no
# stated population and a later probe could not tell whether it covered the same ground. Papadakis et
# al. (Mutation Testing Advances, 2019) ask any claim made with mutants to name its operators, its tool
# and version, how redundancy was controlled, and its granularity. This harness makes the first two
# structural: an operator outside the catalogue below is REFUSED, and every row names its operator,
# this file's blob and the commit it ran at.
#
# THE OPERATOR CATALOGUE is drawn from this estate's own recorded scars, each already a rule in
# `.claude\rules\ops-and-gates.md`. `literal-value` is the one addition beyond the list I204 proposed.
#
# GRANULARITY AND WHAT IS COUNTED. One mutant is ONE textual replacement at ONE site, written by a
# person in a spec file (the harness generates nothing, so selection is the spec author's and is stated
# by the spec). The report's denominator is non-equivalent mutants that COMPILED and RAN:
#   killed           the suite exited non-zero, or said FAIL at exit 0 (lib\selftest-verdict.ps1's rule)
#   killed-noverdict exit 0 with no self-test verdict line - run-gates scores that 3, never ok, so detected
#   killed-timeout   the child outlived -TimeoutSec and was killed; a hang guard, never a speed bar
#   survived         exit 0 with a passing verdict. A survivor names the exact case the suite is missing.
# And, NOT in the denominator, always printed beside it:
#   equivalent       the spec JUDGED it equivalent (behaviour-identical). It is still run; one that is
#                    killed anyway is flagged EQUIVALENT-BUT-KILLED, because the judgement was wrong.
#   stillborn        the mutated text does not parse, so it tests the parser rather than the suite
#   invalid          the find text is absent, ambiguous without an occurrence, or the replace is a no-op
#
# EACH MUTANT GETS ITS OWN FRESH MIRROR under %TEMP% (a per-run guid name), holding every lib\ file, every
# file beside the target (not recursive), and any -Include paths. A child that writes into its mirror
# cannot leak state into the next mutant. The UNMUTATED control runs first in the same kind of mirror,
# and a red control is exit 3 - "every mutant was killed" means nothing over a suite that fails anyway,
# and a red control is usually a mirror that lacks a file (pass it with -Include).
# THE ORIGINAL is hashed (MD5) before and after; a changed original is exit 3, never a report.
#
# CONCURRENCY: ONE CHILD AT A TIME, deliberately, and at most $script:MAX_MUTANTS mutants per run. A
# mutant run is a whole self-test, several are powershell.exe trees, and this box is shared by every
# session's gate (CLAUDE.md: deliberate load goes through ops\cpu-load.ps1). Serial is the cap.
#
# IT IS A REPORT, NEVER A GATE. A bar on kill rate would be red on day one, and the survey reports that a
# score below some level carries no information about faults at all. Exit 0 whatever the score.
#
# SCOPE OF A CLEAN REPORT: UNSOUND. It runs only the mutants the spec names, at the sites the spec names,
#   and only .ps1 targets with a -SelfTest. "Killed K of K" says those K would have been noticed; it says
#   nothing about a mutant nobody wrote, and a survivor-free report is not evidence the suite is adequate.
#
# THE SPEC is a JSON array; each entry:
#   { "name": "anchor dropped", "operator": "regex-anchor", "find": "'^### I'", "replace": "'### I'",
#     "occurrence": 1, "equivalent": false, "note": "why this site" }
#   `occurrence` (1-based) is required only when `find` occurs more than once. `find` is LITERAL text.
#
#   .\probe-mutants.ps1 -Target ops\audit-backlog-status.ps1 -Spec <spec.json> [-Include 'a;b'] [-OutFile rows.jsonl]
#   .\probe-mutants.ps1 -ListOperators
#   .\probe-mutants.ps1 -SelfTest
# -Include takes ONE string split on ';' (a list into -File arrives as one string, ops-and-gates.md).
# Exit 0 report produced, 3 could not evaluate (bad target or spec, red control, original changed).
# ---------------------------------------------------------------------------------------------------
[CmdletBinding()]
param(
  [string]$Target = '',
  [string]$Spec = '',
  [string]$Include = '',
  [string]$OutFile = '',
  [int]$TimeoutSec = 600,
  [switch]$ListOperators,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$runSelfTest = [bool]$SelfTest

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $here
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\selftest-verdict.ps1')

$script:MAX_MUTANTS = 50   # a cap on processes launched per run, not a tuned value: 50 x a slow suite is already an hour

# The closed vocabulary. Key = operator class; value = what it does and the scar it comes from.
$script:OPERATORS = [ordered]@{
  'ror-boundary'     = 'a relational operator swapped (-gt/-ge, -lt/-le, -eq/-ne): the ROR analogue, a boundary no case sits on'
  'lcr-connector'    = 'a logical connector swapped or one operand dropped (-and/-or): the LCR analogue'
  'regex-anchor'     = 'a regex anchor or boundary deleted (^, $, \b): the audit-backlog-status survivor, backlog I37'
  'array-wrap'       = 'an @() wrap removed or added: ps-null-count-is-one and the List[object] wrap that throws'
  'ordinal-compare'  = 'an Ordinal comparison replaced by the culture-sensitive default: -ne ignores a NUL byte'
  'erroraction-stop' = 'an -ErrorAction Stop or $ErrorActionPreference = Stop deleted: a bare refusal is silent'
  'exit-deleted'     = 'an exit (or return out of a self-test block) deleted: the pull-grocery-ads fall-through'
  'guard-deleted'    = 'a whole guard statement deleted: the survey finds deletion operators give fewest equivalents'
  'literal-value'    = 'a constant changed (a threshold, a count, a string the code keys on)'
}

function Get-PmMd5([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm MD5).Hash.ToLowerInvariant() }

function Get-PmCommit([string]$Root) {
  # A fixture root is not a checkout, and a git call there only prints a fatal line; say 'none' instead.
  if (-not (Test-Path -LiteralPath (Join-Path $Root '.git'))) { return 'none' }
  $c = & git -C $Root rev-parse --short=9 HEAD
  if ($LASTEXITCODE -ne 0 -or -not $c) { return 'unknown' }
  return [string]$c
}

function Read-PmSpec([string]$Path) {
  # ASSIGN, THEN WRAP. Under PS 5.1 `@(... | ConvertFrom-Json)` reads a JSON array as ONE element, which made
  # the first live run see one mutant whose name was every name joined (ps-json-array-collapse).
  $parsed = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
  $rows = @($parsed)
  return ,$rows
}

function Get-PmIncludeList([string]$Text) {
  $list = New-Object System.Collections.Generic.List[string]
  foreach ($p in ($Text -split ';')) { $t = $p.Trim(); if ($t) { $list.Add($t) } }
  return ,$list.ToArray()
}

function New-PmMirror {
  # A fresh mirror: every lib\ file (recursive), every FILE beside the target, and each -Include path.
  param([string]$Root, [string]$TargetRel, [string[]]$Includes, [string]$Base)
  $m = Join-Path $Base ('m' + [guid]::NewGuid().ToString('N').Substring(0, 6))
  New-Item -ItemType Directory -Path $m -ErrorAction Stop | Out-Null
  $lib = Join-Path $Root 'lib'
  if (Test-Path -LiteralPath $lib) { Copy-Item -LiteralPath $lib -Destination (Join-Path $m 'lib') -Recurse -Force }
  $tDirRel = Split-Path -Parent $TargetRel
  $tDirSrc = if ($tDirRel) { Join-Path $Root $tDirRel } else { $Root }
  $tDirDst = if ($tDirRel) { Join-Path $m $tDirRel } else { $m }
  if (-not (Test-Path -LiteralPath $tDirDst)) { New-Item -ItemType Directory -Path $tDirDst -Force | Out-Null }
  foreach ($f in @(Get-ChildItem -LiteralPath $tDirSrc -File)) { Copy-Item -LiteralPath $f.FullName -Destination $tDirDst -Force }
  foreach ($inc in @($Includes)) {
    if (-not $inc) { continue }
    $src = Join-Path $Root $inc
    if (-not (Test-Path -LiteralPath $src)) { throw "include not found: $inc" }
    $dst = Join-Path $m $inc
    $dstDir = Split-Path -Parent $dst
    if ($dstDir -and -not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
  }
  return $m
}

function Invoke-PmChild {
  # Run one script's -SelfTest in its mirror, stdout kept, with a hang guard. Returns exit, lines, timedOut.
  param([string]$Mirror, [string]$TargetRel, [int]$TimeoutSec)
  $script = Join-Path $Mirror $TargetRel
  $out = Join-Path $Mirror ('_pm-out-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
  $err = Join-Path $Mirror ('_pm-err-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
  $psExe = Join-Path $PSHOME 'powershell.exe'
  $argList = '-NoProfile -ExecutionPolicy Bypass -File "' + $script + '" -SelfTest'
  $p = Start-Process -FilePath $psExe -ArgumentList $argList -WorkingDirectory $Mirror -NoNewWindow -PassThru `
         -RedirectStandardOutput $out -RedirectStandardError $err
  $null = $p.Handle   # without touching Handle, ExitCode reads $null under PS 5.1 (memory: ps-start-process-exitcode-needs-handle)
  $timedOut = $false
  if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    $timedOut = $true
    & taskkill.exe /T /F /PID $p.Id | Out-Null
    $null = $p.WaitForExit(30000)
  }
  $code = if ($timedOut) { -1 } else { [int]$p.ExitCode }
  $lines = @()
  if (Test-Path -LiteralPath $out) { $lines = @(Get-Content -LiteralPath $out -Encoding UTF8) }
  return [pscustomobject]@{ Exit = $code; Lines = $lines; TimedOut = $timedOut }
}

function Get-PmMutatedText {
  # Apply one literal replacement at one site. Returns @{ Ok; Text; Why }.
  param([string]$Original, [string]$Find, [string]$Replace, [int]$Occurrence)
  if (-not $Find) { return @{ Ok = $false; Text = $null; Why = 'find is empty' } }
  if ([string]::Equals($Find, $Replace, [StringComparison]::Ordinal)) { return @{ Ok = $false; Text = $null; Why = 'replace equals find (a no-op mutant)' } }
  $at = New-Object System.Collections.Generic.List[int]
  $i = $Original.IndexOf($Find, [StringComparison]::Ordinal)
  while ($i -ge 0) { $at.Add($i); $i = $Original.IndexOf($Find, $i + 1, [StringComparison]::Ordinal) }
  if ($at.Count -eq 0) { return @{ Ok = $false; Text = $null; Why = 'find text not present' } }
  if ($Occurrence -le 0) {
    if ($at.Count -ne 1) { return @{ Ok = $false; Text = $null; Why = ("find text occurs {0} times; give an occurrence" -f $at.Count) } }
    $Occurrence = 1
  }
  if ($Occurrence -gt $at.Count) { return @{ Ok = $false; Text = $null; Why = ("occurrence {0} of {1}" -f $Occurrence, $at.Count) } }
  $pos = $at[$Occurrence - 1]
  $text = $Original.Substring(0, $pos) + $Replace + $Original.Substring($pos + $Find.Length)
  return @{ Ok = $true; Text = $text; Why = '' }
}

function Test-PmParses([string]$Text) {
  $tokens = $null; $errors = $null
  $null = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
  return (@($errors).Count -eq 0)
}

function Get-PmRedLines([object[]]$Lines) {
  $red = @(@($Lines) | Where-Object { $null -ne $_ } | ForEach-Object { ([string]$_).Trim() } |
           Where-Object { $_ -cmatch '^FAIL' -or $_ -cmatch 'SELF-?TEST FAIL' })
  return ,@($red | Select-Object -First 5)
}

function Invoke-TcMutationProbe {
  <# The harness. Takes the ROOT so the self-test can point it at a fixture tree. Never writes the original.
     Returns Status 'ok' with Rows, or Status 'refused' with Reason (the caller exits 3). #>
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$TargetRel,
    [Parameter(Mandatory = $true)][object[]]$Mutants,
    [string[]]$Includes = @(),
    [int]$TimeoutSec = 600
  )
  $refuse = { param($why) [pscustomobject]@{ Status = 'refused'; Reason = $why; Rows = @(); Control = $null; OriginalIdentical = $null } }
  $targetFull = Join-Path $Root $TargetRel
  if (-not (Test-Path -LiteralPath $targetFull)) { return (& $refuse "target not found: $TargetRel") }
  if ($TargetRel -notmatch '\.ps1$') { return (& $refuse "only .ps1 targets are supported: $TargetRel") }
  $all = @($Mutants)
  if ($all.Count -eq 0) { return (& $refuse 'the spec names no mutants') }
  if ($all.Count -gt $script:MAX_MUTANTS) { return (& $refuse ("{0} mutants exceeds the cap of {1} per run" -f $all.Count, $script:MAX_MUTANTS)) }
  $seen = @{}
  foreach ($mu in $all) {
    $n = [string]$mu.name; $op = [string]$mu.operator
    if (-not $n) { return (& $refuse 'a mutant has no name') }
    if ($seen.ContainsKey($n)) { return (& $refuse "mutant name used twice: $n") }
    $seen[$n] = $true
    if (-not $script:OPERATORS.Contains($op)) { return (& $refuse ("mutant '{0}' names operator '{1}', which is not in the catalogue ({2})" -f $n, $op, (@($script:OPERATORS.Keys) -join ', '))) }
  }

  $md5Before = Get-PmMd5 $targetFull
  $original = [IO.File]::ReadAllText($targetFull)
  $commit = Get-PmCommit $Root
  $base = Join-Path $env:TEMP ('pm-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $base -ErrorAction Stop | Out-Null
  $rows = New-Object System.Collections.Generic.List[object]
  $control = $null
  try {
    # CONTROL: the unmutated suite in a mirror. Red here means the mirror, not the mutants, is the story.
    $cm = New-PmMirror -Root $Root -TargetRel $TargetRel -Includes $Includes -Base $base
    $cr = Invoke-PmChild -Mirror $cm -TargetRel $TargetRel -TimeoutSec $TimeoutSec
    $cs = if ($cr.TimedOut) { 'timeout' } else { (Get-TcSelfTestScore -ExitCode $cr.Exit -Lines $cr.Lines).Score }
    $control = [pscustomobject]@{ Exit = $cr.Exit; Score = $cs; Red = (Get-PmRedLines $cr.Lines) }
    Remove-Item -LiteralPath $cm -Recurse -Force -ErrorAction SilentlyContinue
    if ($cs -ne 'ok') {
      return [pscustomobject]@{ Status = 'refused'; Reason = ("control is not green in the mirror (exit {0}, score {1}); a missing file wants -Include" -f $cr.Exit, $cs); Rows = @(); Control = $control; OriginalIdentical = ((Get-PmMd5 $targetFull) -eq $md5Before) }
    }

    foreach ($mu in $all) {
      $occ = 0; if ($null -ne $mu.occurrence) { $occ = [int]$mu.occurrence }
      $equiv = [bool]$mu.equivalent
      $row = [ordered]@{
        target = $TargetRel; target_md5 = $md5Before; commit = $commit
        mutant = [string]$mu.name; operator = [string]$mu.operator; equivalent = $equiv
        outcome = ''; exit = $null; red_lines = @(); why = ''; elapsed_ms = 0
      }
      $mt = Get-PmMutatedText -Original $original -Find ([string]$mu.find) -Replace ([string]$mu.replace) -Occurrence $occ
      if (-not $mt.Ok) { $row.outcome = 'invalid'; $row.why = $mt.Why; $rows.Add([pscustomobject]$row); continue }
      if (-not (Test-PmParses $mt.Text)) { $row.outcome = 'stillborn'; $row.why = 'mutated text does not parse'; $rows.Add([pscustomobject]$row); continue }
      $mm = New-PmMirror -Root $Root -TargetRel $TargetRel -Includes $Includes -Base $base
      [IO.File]::WriteAllText((Join-Path $mm $TargetRel), $mt.Text, (New-Object Text.UTF8Encoding($true)))
      $sw = [Diagnostics.Stopwatch]::StartNew()
      $r = Invoke-PmChild -Mirror $mm -TargetRel $TargetRel -TimeoutSec $TimeoutSec
      $sw.Stop()
      Remove-Item -LiteralPath $mm -Recurse -Force -ErrorAction SilentlyContinue
      $row.exit = $r.Exit; $row.elapsed_ms = [int]$sw.ElapsedMilliseconds
      $row.red_lines = Get-PmRedLines $r.Lines
      if ($r.TimedOut) { $row.outcome = 'killed-timeout' }
      else {
        $s = (Get-TcSelfTestScore -ExitCode $r.Exit -Lines $r.Lines).Score
        $row.outcome = switch ($s) { 'ok' { 'survived' } 'fail' { 'killed' } default { 'killed-noverdict' } }
      }
      if ($equiv -and $row.outcome -ne 'survived') { $row.why = 'EQUIVALENT-BUT-KILLED: the equivalence judgement was wrong' }
      $rows.Add([pscustomobject]$row)
    }
  } finally {
    Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
  }
  $md5After = Get-PmMd5 $targetFull
  return [pscustomobject]@{
    Status = 'ok'; Reason = ''; Rows = $rows.ToArray(); Control = $control
    OriginalIdentical = ($md5After -eq $md5Before); Md5 = $md5Before; Commit = $commit
    MirrorRemoved = (-not (Test-Path -LiteralPath $base))
  }
}

function Get-TcMutationSummary {
  # Per operator class and overall: killed K of N non-equivalent, E judged equivalent, S stillborn, I invalid.
  param([object[]]$Rows)
  $groups = [ordered]@{}
  foreach ($r in @($Rows)) {
    foreach ($key in @([string]$r.operator, '(all)')) {
      if (-not $groups.Contains($key)) { $groups[$key] = [ordered]@{ killed = 0; n = 0; equivalent = 0; stillborn = 0; invalid = 0; survivors = @() } }
      $g = $groups[$key]
      if ($r.outcome -eq 'invalid') { $g.invalid++ }
      elseif ($r.outcome -eq 'stillborn') { $g.stillborn++ }
      elseif ($r.equivalent) { $g.equivalent++ }
      else {
        $g.n++
        if ($r.outcome -eq 'survived') { $g.survivors += [string]$r.mutant } else { $g.killed++ }
      }
    }
  }
  # The overall line prints LAST, after every operator class.
  $ordered = [ordered]@{}
  foreach ($k in @($groups.Keys)) { if ($k -ne '(all)') { $ordered[$k] = $groups[$k] } }
  if ($groups.Contains('(all)')) { $ordered['(all)'] = $groups['(all)'] }
  return $ordered
}

function Format-TcMutationSummaryLine([string]$Key, $G) {
  "{0}: killed {1} of {2} non-equivalent, {3} judged equivalent, {4} stillborn, {5} invalid" -f $Key, $G.killed, $G.n, $G.equivalent, $G.stillborn, $G.invalid
}

# ---- self-test -------------------------------------------------------------------------------------
if ($runSelfTest) {
  $script:pmBad = 0; $script:pmRan = 0
  function Test-PmCase([string]$Label, [scriptblock]$Check) {
    # A case that THROWS is a counted failure, never a skipped line.
    $script:pmRan++
    $ok = $false
    try { $ok = [bool](& $Check) } catch { $ok = $false; Write-Output ("      threw: {0}" -f $_.Exception.Message) }
    if ($ok) { Write-Output ("ok    {0}" -f $Label) } else { Write-Output ("FAIL  {0}" -f $Label); $script:pmBad++ }
  }

  # A fixture tree with its own lib\ and one target whose suite has NO case on the boundary at 10.
  $fx = Join-Path $env:TEMP ('pmst-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    New-Item -ItemType Directory -Path (Join-Path $fx 'lib') -Force -ErrorAction Stop | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fx 'tools') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $fx 'lib\fx-lib.ps1'), "function Get-FxLimit { return 10 }`n")
    $tLines = @(
      'param([switch]$SelfTest)',
      '. (Join-Path (Split-Path -Parent $PSScriptRoot) ''lib\fx-lib.ps1'')',
      'function Test-Big([int]$n) { return ($n -gt (Get-FxLimit)) }',
      'if ($SelfTest) {',
      '  $bad = 0',
      '  if (-not (Test-Big 11)) { Write-Output ''FAIL  eleven is big''; $bad++ } else { Write-Output ''ok    eleven is big'' }',
      '  if (Test-Big 5) { Write-Output ''FAIL  five is small''; $bad++ } else { Write-Output ''ok    five is small'' }',
      '  if ($bad -gt 0) { Write-Output ''fixture SELF-TEST FAIL''; exit 1 }',
      '  Write-Output ''fixture SELF-TEST PASS''; exit 0',
      '}'
    )
    $targetRel = 'tools\fx-target.ps1'
    $targetFull = Join-Path $fx $targetRel
    [IO.File]::WriteAllText($targetFull, (($tLines -join "`n") + "`n"))
    $md5Fixture = Get-PmMd5 $targetFull

    $specs = @(
      [pscustomobject]@{ name = 'boundary -gt to -ge'; operator = 'ror-boundary'; find = '-gt (Get-FxLimit)'; replace = '-ge (Get-FxLimit)'; equivalent = $false },
      [pscustomobject]@{ name = 'sense -gt to -lt';    operator = 'ror-boundary'; find = '-gt (Get-FxLimit)'; replace = '-lt (Get-FxLimit)'; equivalent = $false },
      [pscustomobject]@{ name = 'return dropped';      operator = 'guard-deleted'; find = 'return ($n'; replace = '($n'; equivalent = $true },
      [pscustomobject]@{ name = 'unbalanced paren';    operator = 'literal-value'; find = '(Get-FxLimit)) }'; replace = '(Get-FxLimit) }'; equivalent = $false },
      [pscustomobject]@{ name = 'absent site';         operator = 'literal-value'; find = 'no such text'; replace = 'x'; equivalent = $false },
      [pscustomobject]@{ name = 'ambiguous site';      operator = 'literal-value'; find = 'Test-Big'; replace = 'Test-Bog'; equivalent = $false }
    )
    $main = Invoke-TcMutationProbe -Root $fx -TargetRel $targetRel -Mutants $specs -TimeoutSec 120
    $byName = @{}; foreach ($r in @($main.Rows)) { $byName[[string]$r.mutant] = $r }

    Test-PmCase 'CLEAN TWIN: the unmutated control is green in the mirror, so the probe reports' { $main.Status -eq 'ok' -and $main.Control.Score -eq 'ok' }
    Test-PmCase 'MUST FIRE: a boundary mutant the suite has no case for is reported SURVIVED' { $byName['boundary -gt to -ge'].outcome -eq 'survived' }
    Test-PmCase 'CLEAN TWIN: a mutant the suite does catch is KILLED, and the killing case is named' {
      $r = $byName['sense -gt to -lt']; $r.outcome -eq 'killed' -and (@($r.red_lines) -contains 'FAIL  eleven is big') }
    # Both cases below were written after the harness's first run over ITSELF reported them SURVIVED.
    Test-PmCase 'CLEAN TWIN: a killed NON-equivalent mutant carries no equivalence warning' { [string]$byName['sense -gt to -lt'].why -eq '' }
    Test-PmCase 'MUST NOT FIRE: a passing case whose LABEL says FAIL is not a red line; a line starting FAIL is' {
      $red = Get-PmRedLines @('ok    MUST FIRE: a FAIL case', 'FAIL  real one')
      @($red).Count -eq 1 -and $red[0] -eq 'FAIL  real one' }
    Test-PmCase 'CLEAN TWIN: the original fixture is byte-identical afterwards (md5), and the harness says so' {
      ((Get-PmMd5 $targetFull) -eq $md5Fixture) -and $main.OriginalIdentical -eq $true }
    Test-PmCase 'CLEAN TWIN: the per-run temp mirror is removed' { $main.MirrorRemoved -eq $true }
    Test-PmCase 'a judged-equivalent mutant runs, survives, and is kept out of the denominator' { $byName['return dropped'].outcome -eq 'survived' -and $byName['return dropped'].equivalent }
    Test-PmCase 'MUST FIRE: a mutant that does not parse is STILLBORN and never run' { $byName['unbalanced paren'].outcome -eq 'stillborn' -and $null -eq $byName['unbalanced paren'].exit }
    Test-PmCase 'MUST FIRE: an absent find text is INVALID' { $byName['absent site'].outcome -eq 'invalid' -and $byName['absent site'].why -match 'not present' }
    Test-PmCase 'MUST FIRE: an ambiguous find text without an occurrence is INVALID' { $byName['ambiguous site'].outcome -eq 'invalid' -and $byName['ambiguous site'].why -match 'occurs \d+ times' }
    $sum = Get-TcMutationSummary -Rows $main.Rows
    Test-PmCase 'the summary counts per operator: ror-boundary killed 1 of 2, overall 1 equivalent 1 stillborn 2 invalid' {
      $g = $sum['ror-boundary']; $a = $sum['(all)']
      $g.killed -eq 1 -and $g.n -eq 2 -and (@($g.survivors) -contains 'boundary -gt to -ge') -and
      $a.n -eq 2 -and $a.equivalent -eq 1 -and $a.stillborn -eq 1 -and $a.invalid -eq 2 }
    Test-PmCase 'every row names its operator, the target md5 and the commit' {
      @($main.Rows | Where-Object { -not $_.operator -or $_.target_md5 -ne $md5Fixture -or -not $_.commit }).Count -eq 0 }

    # The hang: the function spins forever. -TimeoutSec is a hang guard; the spin never ends on its own, so the
    # guard fires however loaded the box is (no upper wall-clock bar on the code under test).
    $hangSpec = @([pscustomobject]@{ name = 'hang'; operator = 'exit-deleted'; find = 'return ($n -gt'; replace = 'while ($true) { Start-Sleep -Milliseconds 200 }; return ($n -gt'; equivalent = $false })
    $hang = Invoke-TcMutationProbe -Root $fx -TargetRel $targetRel -Mutants $hangSpec -TimeoutSec 8
    Test-PmCase 'MUST FIRE: a mutant that hangs is killed by the hang guard, KILLED-TIMEOUT' { $hang.Status -eq 'ok' -and @($hang.Rows)[0].outcome -eq 'killed-timeout' }

    # The spec loader, from a real file: the founding bug of the first live run read a 9-entry array as 1.
    $specFile = Join-Path $fx 'spec.json'
    [IO.File]::WriteAllText($specFile, '[{"name":"a","operator":"literal-value","find":"x","replace":"y"},{"name":"b","operator":"exit-deleted","find":"x","replace":"z"}]')
    $loaded = Read-PmSpec $specFile
    Test-PmCase 'MUST FIRE: a two-entry spec file loads as TWO mutants, each with its own name' {
      @($loaded).Count -eq 2 -and [string]$loaded[0].name -eq 'a' -and [string]$loaded[1].name -eq 'b' }

    $unknown = Invoke-TcMutationProbe -Root $fx -TargetRel $targetRel -Mutants @([pscustomobject]@{ name = 'x'; operator = 'made-up-op'; find = 'a'; replace = 'b' })
    Test-PmCase 'MUST FIRE: an operator outside the catalogue is REFUSED before anything runs' { $unknown.Status -eq 'refused' -and $unknown.Reason -match 'not in the catalogue' }

    # A red control: break the fixture's lib in a SECOND tree so the unmutated suite fails.
    $fx2 = Join-Path $env:TEMP ('pmst-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
      Copy-Item -LiteralPath $fx -Destination $fx2 -Recurse
      [IO.File]::WriteAllText((Join-Path $fx2 'lib\fx-lib.ps1'), "function Get-FxLimit { return 100 }`n")
      $red = Invoke-TcMutationProbe -Root $fx2 -TargetRel $targetRel -Mutants ($specs[0..1]) -TimeoutSec 120
      Test-PmCase 'MUST FIRE: a control that is red in the mirror REFUSES, and scores no mutant' { $red.Status -eq 'refused' -and $red.Reason -match 'control is not green' -and @($red.Rows).Count -eq 0 }
    } finally { Remove-Item -LiteralPath $fx2 -Recurse -Force -ErrorAction SilentlyContinue }
  } finally {
    Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue
  }
  $expected = 17
  if ($script:pmRan -ne $expected) { Write-Output ("FAIL  ran {0} of {1} literal cases" -f $script:pmRan, $expected); $script:pmBad++ }
  if ($script:pmBad -gt 0) { Write-Output ("probe-mutants SELF-TEST FAIL ({0} of {1})" -f $script:pmBad, $script:pmRan); exit 1 }
  Write-Output ("probe-mutants SELF-TEST PASS: {0} of {1} case(s)" -f $script:pmRan, $expected)
  exit 0
}

# ---- report ----------------------------------------------------------------------------------------
if ($ListOperators) {
  foreach ($k in $script:OPERATORS.Keys) { Write-Output ("{0,-17} {1}" -f $k, $script:OPERATORS[$k]) }
  Write-GuardComplete -Name 'probe-mutants' -Summary ("operators={0}" -f $script:OPERATORS.Count)
  exit 0
}
if (-not $Target -or -not $Spec) {
  Write-Output 'usage: probe-mutants.ps1 -Target <repo-relative .ps1> -Spec <spec.json> [-Include ''a;b''] [-OutFile rows.jsonl]'
  Write-GuardComplete -Name 'probe-mutants' -Summary 'blind=no-target'
  exit 3
}
if (-not (Test-Path -LiteralPath $Spec)) {
  Write-Output "spec not found: $Spec"; Write-GuardComplete -Name 'probe-mutants' -Summary 'blind=no-spec'; exit 3
}
$specRows = Read-PmSpec $Spec
$includes = Get-PmIncludeList $Include
$res = Invoke-TcMutationProbe -Root $repo -TargetRel $Target -Mutants $specRows -Includes $includes -TimeoutSec $TimeoutSec
if ($res.Status -ne 'ok') {
  Write-Output ("REFUSED: {0}" -f $res.Reason)
  if ($res.Control) { foreach ($l in @($res.Control.Red)) { Write-Output ("  control: {0}" -f $l) } }
  Write-GuardComplete -Name 'probe-mutants' -Summary 'blind=refused'
  exit 3
}
$harnessBlob = 'uncommitted'
if (Test-Path -LiteralPath (Join-Path $repo '.git')) {
  $tracked = & git -C $repo ls-files -- ops/probe-mutants.ps1
  if ($tracked) {
    $b = & git -C $repo rev-parse HEAD:ops/probe-mutants.ps1
    if ($LASTEXITCODE -eq 0 -and $b) { $harnessBlob = ([string]$b).Substring(0, 9) }
  }
  $dirty = & git -C $repo status --porcelain -- ops/probe-mutants.ps1
  if ($dirty) { $harnessBlob = $harnessBlob + '+modified' }
}
Write-Output ("probe-mutants target={0} md5={1} commit={2} harness_blob={3} mutants={4}" -f $Target, $res.Md5, $res.Commit, $harnessBlob, @($res.Rows).Count)
foreach ($r in @($res.Rows)) {
  $tag = if ($r.equivalent) { ' (judged equivalent)' } else { '' }
  Write-Output ("  {0,-16} {1,-17} {2}{3}" -f $r.outcome.ToUpper(), $r.operator, $r.mutant, $tag)
  foreach ($l in @($r.red_lines)) { Write-Output ("      red: {0}" -f $l) }
  if ($r.why) { Write-Output ("      {0}" -f $r.why) }
}
$sum = Get-TcMutationSummary -Rows $res.Rows
foreach ($k in $sum.Keys) {
  Write-Output (Format-TcMutationSummaryLine $k $sum[$k])
  foreach ($s in @($sum[$k].survivors)) { if ($k -ne '(all)') { Write-Output ("    SURVIVED: {0} - name the case the suite is missing" -f $s) } }
}
if ($OutFile) {
  $lines = @($res.Rows | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 4 })
  # .NET resolves a relative path against the PROCESS directory, not the PowerShell location, so root it here.
  $outFull = if ([IO.Path]::IsPathRooted($OutFile)) { $OutFile } else { Join-Path (Get-Location).ProviderPath $OutFile }
  [IO.File]::WriteAllText($outFull,(($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
  Write-Output ("rows written: {0} ({1})" -f $lines.Count, $OutFile)
}
if (-not $res.OriginalIdentical) {
  Write-Output 'ORIGINAL CHANGED during the probe - the report is void'
  Write-GuardComplete -Name 'probe-mutants' -Summary 'blind=original-changed'
  exit 3
}
$all = $sum['(all)']
Write-GuardComplete -Name 'probe-mutants' -Summary ("mutants={0} killed={1} of={2} equivalent={3} stillborn={4} invalid={5} original=identical" -f @($res.Rows).Count, $all.killed, $all.n, $all.equivalent, $all.stillborn, $all.invalid)
exit 0
