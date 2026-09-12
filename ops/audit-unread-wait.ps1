<#
  audit-unread-wait.ps1 - the answer a TIMED wait gives is read on some path.

  WHY THIS EXISTS (2026-09-12). `WaitOne($ms)` returns $false when the wait TIMED OUT, which means the caller does
  NOT hold the lock. A caller that discards that answer carries on into the critical section having taken nothing,
  and nothing errors. grocery\send-alert.ps1 stored `WaitOne(10000)` and never read it, so a timed-out waiter
  rewrote the whole triage queue UNLOCKED over the writer that did hold the lock. The rule went into
  .claude\rules\ops-and-gates.md as "a timed lock wait is a BRANCH" on 2026-09-11. A rule in a file reaches
  whoever opens the file, and the 2026-09-12 review of this estate's own learning system measured what that is
  worth: the tree-walk rule sat written and unread for two weeks while twelve detectors returned nothing, and
  started working the day it became a gate. This reaches the next unread wait at push time.

  WHAT COUNTS AS READ. The value has to reach something that can branch on it:
    - a condition (if/while/until/switch), a -not or comparison, a boolean operator, a return, an argument;
    - an assignment whose variable is READ again somewhere in the same file.
  What counts as DISCARDED is the whole finding list: a bare call as its own statement, a call cast to [void] or
  piped to Out-Null/$null, and an assignment to a variable that never appears again.

  ONLY TIMED WAITS. `WaitOne()` with no argument blocks until it is signalled, so it has no answer to discard -
  it either returns having taken the handle or it never returns. Flagging those would be noise on a call that
  cannot carry the defect. `WaitOne(0)` IS timed and IS included: a poll that ignores its answer is the same bug
  in a hurry, and lib\gate-slots.ps1's own history is that a WaitOne(0) poll was mistaken for a queue.

  SCOPE OF A CLEAN REPORT: UNSOUND. It reads the AST of tracked .ps1 and .psm1 and follows the value of a timed
  WaitOne only within the FILE it is written in. A clean report means no such call in those files visibly throws
  its answer away. It cannot see: a wait reached through Invoke-Expression or a script block built at run time; a
  variable read only in another file or in a string the caller expands; a handle waited on by WaitAny/WaitAll or
  by a .NET method other than WaitOne; or a variable that is read but read into another discard. It also cannot
  tell a READ from a CORRECT read - a caller that branches on the answer and then proceeds anyway is outside what
  a static check can judge. A REPORTED site is real: the value is not used anywhere in its file.

  EXIT CODES: 0 clean, 1 at least one discarded wait, 2 self-test regression, 3 BLIND (discovery resolved no
  tracked scripts, or the anchor file is missing from them, so its silence would mean nothing).

    ops\audit-unread-wait.ps1             scan the tracked tree
    ops\audit-unread-wait.ps1 -SelfTest   frozen founding shape, the fixed form, and the forms that must stay quiet
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

$SELF_REL = 'ops/audit-unread-wait.ps1'
# A tracked script the discovery must resolve, or it found some other tree (or none) and its silence means nothing.
$script:UW_ANCHOR_FILE = 'ops/run-gates.ps1'

function Get-UwFindings {
  <# Findings for ONE file's text. @{ Findings = @(@{Line;Col;Why;Expr}); ParseErrors = [bool] }.
     Takes text rather than a path so every fixture is a string literal and no case needs a file on disk. #>
  param([string]$Text)

  $tokens = $null; $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
  $parseErrors = ($null -ne $errors -and @($errors).Count -gt 0)
  $out = New-Object System.Collections.ArrayList
  if ($null -eq $ast) { return [pscustomobject]@{ Findings = @(); ParseErrors = $true } }

  # Every timed WaitOne call: a method invocation named WaitOne carrying at least one argument.
  $calls = @($ast.FindAll({
    param($n)
    $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
    [string]::Equals($n.Member.Value, 'WaitOne', [StringComparison]::OrdinalIgnoreCase) -and
    $null -ne $n.Arguments -and @($n.Arguments).Count -ge 1
  }, $true))
  if (-not $calls.Count) { return [pscustomobject]@{ Findings = @(); ParseErrors = $parseErrors } }

  # Every variable NAME read anywhere in the file, so an assignment can be told from a dead store. The scope is
  # deliberately the whole file and not the enclosing function: a wider read set can only make this quieter, and
  # a detector that reports a real defect is worth more than one that reports a suspicion.
  $reads = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($v in @($ast.FindAll({
      param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst]
    }, $true))) {
    $p = $v.Parent
    # The left-hand side of an assignment is a WRITE, not a read. Every other appearance counts as a read.
    if ($p -is [System.Management.Automation.Language.AssignmentStatementAst] -and $p.Left -eq $v) { continue }
    [void]$reads.Add([string]$v.VariablePath.UserPath)
  }

  foreach ($c in $calls) {
    $why = ''
    $p = $c.Parent

    # THE PARENT CHAIN HAS A RUNG THAT IS EASY TO MISS, and missing it costs the detector every positive case
    # while leaving every negative one green - the shape that reads as "nearly working". An expression used as a
    # statement is wrapped in a CommandExpressionAst inside a PipelineAst, so an InvokeMemberExpressionAst is
    # never the direct child of a PipelineAst or of an AssignmentStatementAst. The first cut of this file checked
    # for those directly, and its five MUST FIRE cases all failed while all six MUST NOT FIRE cases passed.
    if ($p -is [System.Management.Automation.Language.ConvertExpressionAst]) {
      if ($p.Type -and [string]::Equals([string]$p.Type.TypeName.FullName, 'void', [StringComparison]::OrdinalIgnoreCase)) {
        $why = 'cast to [void]'
      }
    }
    elseif ($p -is [System.Management.Automation.Language.CommandExpressionAst]) {
      $up = $p.Parent
      # AN ASSIGNMENT'S RIGHT IS THE CommandExpressionAst ITSELF, with NO PipelineAst between them, while a bare
      # statement or a pipe DOES get one. Assuming the pipeline rung on both paths is what left the assignment
      # cases - the founding bug's own shape - failing after the first repair had fixed the other three.
      if ($up -is [System.Management.Automation.Language.AssignmentStatementAst] -and $up.Right -eq $p -and
          $up.Left -is [System.Management.Automation.Language.VariableExpressionAst]) {
        # $held = $m.WaitOne($ms) - a read only if that variable is read somewhere in the file.
        $name = [string]$up.Left.VariablePath.UserPath
        if (-not $reads.Contains($name)) { $why = "assigned to `$$name, which is never read again" }
      }
      elseif ($up -is [System.Management.Automation.Language.PipelineAst]) {
        $pipe = $up
        if (@($pipe.PipelineElements).Count -gt 1) {
          $tail = [string]$pipe.Extent.Text
          if ($tail -match '(?i)\|\s*Out-Null' -or $tail -match '(?i)>\s*\$null') { $why = 'piped to Out-Null' }
        }
        elseif ($pipe.Parent -is [System.Management.Automation.Language.StatementBlockAst] -or
                $pipe.Parent -is [System.Management.Automation.Language.NamedBlockAst]) {
          $why = 'called as a bare statement, so the answer goes nowhere'
        }
      }
    }

    if ($why) {
      [void]$out.Add([pscustomobject]@{
        Line = $c.Extent.StartLineNumber
        Col  = $c.Extent.StartColumnNumber
        Why  = $why
        Expr = ([string]$c.Extent.Text)
      })
    }
  }
  return [pscustomobject]@{ Findings = @($out.ToArray()); ParseErrors = $parseErrors }
}

function Get-UwScanFiles {
  <# The TRACKED .ps1/.psm1 under $RootDir, repo-relative with forward slashes, never $SelfRel. `git ls-files`
     rather than a directory walk, for the reason ops\audit-cmdlet-shadow.ps1 gives: it lists paths relative to
     the checkout it runs in, so a linked worktree reads whole and a sibling worktree below it is never read.
     Returns @{ Ok; Files; Error }. #>
  param([string]$RootDir, [string]$SelfRel = '')
  $ErrorActionPreference = 'Continue'   # git's stderr under Stop is a terminating error in PS 5.1
  $lines = @(& git -C $RootDir -c core.quotepath=off ls-files -- '*.ps1' '*.psm1' 2>$null)
  $rc = $LASTEXITCODE
  if ($rc -ne 0) { return [pscustomobject]@{ Ok = $false; Files = @(); Error = ("git ls-files exited {0} in {1}" -f $rc, $RootDir) } }
  $files = @($lines | ForEach-Object { ([string]$_).Trim() } |
             Where-Object { $_ -and ($_ -match '(?i)\.psm?1$') -and -not [string]::Equals($_, $SelfRel, [StringComparison]::OrdinalIgnoreCase) })
  return [pscustomobject]@{ Ok = $true; Files = $files; Error = '' }
}

# ------------------------------------------------------------------------------------------------ self-test
if ($SelfTest) {
  $script:cases = 0; $script:fail = 0
  function Invoke-UwCase {
    param([string]$Label, [string]$What, [bool]$Ok)
    $script:cases++
    if (-not $Ok) { $script:fail++ }
    Write-Output ("  {0,-14} {1,-62} {2}" -f $Label, $What, $(if ($Ok) { 'ok' } else { 'FAIL' }))
  }

  # Fixtures are SINGLE-QUOTED LITERALS with doubled inner quotes, never built by concatenation: a fixture
  # assembled from pieces is passed as several arguments and the case runs against a fragment (2026-09-07).

  # --- MUST FIRE: the founding bug, send-alert.ps1's stored-and-never-read wait ---------------------
  $founding = 'try { $qHeld = $qMutex.WaitOne(10000) } catch { }
Set-Content -Path $queue -Value $rows'
  $r = Get-UwFindings -Text $founding
  Invoke-UwCase 'MUST FIRE' 'a wait assigned to a variable never read again is found' (@($r.Findings).Count -eq 1)

  $bare = '$mx.WaitOne(5000)
Write-Output ''in the critical section'''
  $r = Get-UwFindings -Text $bare
  Invoke-UwCase 'MUST FIRE' 'a bare WaitOne statement is found' (@($r.Findings).Count -eq 1)

  $voided = '[void]$mx.WaitOne(5000)'
  $r = Get-UwFindings -Text $voided
  Invoke-UwCase 'MUST FIRE' 'a wait cast to [void] is found' (@($r.Findings).Count -eq 1)

  $nulled = '$mx.WaitOne(5000) | Out-Null'
  $r = Get-UwFindings -Text $nulled
  Invoke-UwCase 'MUST FIRE' 'a wait piped to Out-Null is found' (@($r.Findings).Count -eq 1)

  $poll = '$got = $mx.WaitOne(0)'
  $r = Get-UwFindings -Text $poll
  Invoke-UwCase 'MUST FIRE' 'a WaitOne(0) poll whose answer is dropped is found' (@($r.Findings).Count -eq 1)

  # --- MUST NOT FIRE: legal inputs. The detector is SILENT, or it is crying wolf. -------------------
  $fixed = 'try { $qHeld = $qMutex.WaitOne(10000) } catch { $qHeld = $true }
if (-not $qHeld) { Write-Output ''could not take the lock''; exit 3 }
Set-Content -Path $queue -Value $rows'
  $r = Get-UwFindings -Text $fixed
  Invoke-UwCase 'MUST NOT FIRE' 'the FIXED form, whose answer is branched on, is quiet' (@($r.Findings).Count -eq 0)

  $inCond = 'while (-not $async.AsyncWaitHandle.WaitOne(5000)) { Write-Output ''waiting'' }'
  $r = Get-UwFindings -Text $inCond
  Invoke-UwCase 'MUST NOT FIRE' 'a wait used directly as a loop condition is quiet' (@($r.Findings).Count -eq 0)

  $inIf = 'if ($m.WaitOne(100)) { Write-Output ''got it'' }'
  $r = Get-UwFindings -Text $inIf
  Invoke-UwCase 'MUST NOT FIRE' 'a wait used directly as an if condition is quiet' (@($r.Findings).Count -eq 0)

  $untimed = '$m.WaitOne()'
  $r = Get-UwFindings -Text $untimed
  Invoke-UwCase 'MUST NOT FIRE' 'an UNTIMED WaitOne() has no answer to discard' (@($r.Findings).Count -eq 0)

  $returned = 'function Get-Lock { param($m) return $m.WaitOne(500) }'
  $r = Get-UwFindings -Text $returned
  Invoke-UwCase 'MUST NOT FIRE' 'a wait whose answer is RETURNED is quiet' (@($r.Findings).Count -eq 0)

  $other = '$x = $thing.WaitAll(500)'
  $r = Get-UwFindings -Text $other
  Invoke-UwCase 'MUST NOT FIRE' 'a method that is not WaitOne is not judged' (@($r.Findings).Count -eq 0)

  # --- CLEAN TWIN: adjacent behaviour that must STILL WORK (a POSITIVE assertion) -------------------
  # A DISTANT READ, AS A PAIR. Asserting only the silence would be a CLEAN TWIN over an ABSENCE,
  # which ops\audit-fixture-vocabulary.ps1 fails and is right to: a silence proves nothing on its
  # own, because a detector that simply failed to look is silent too. The pair says WHICH.
  # The two texts differ by the read ALONE, so the change in verdict can have no other cause.
  $laterRead = '$held = $mx.WaitOne(1000)
Start-Sleep -Milliseconds 5
if ($held) { $mx.ReleaseMutex() }'
  $r = Get-UwFindings -Text $laterRead
  Invoke-UwCase 'MUST NOT FIRE' 'a read FAR from the assignment still counts as read' (@($r.Findings).Count -eq 0)

  $noRead = '$held = $mx.WaitOne(1000)
Start-Sleep -Milliseconds 5
$mx.ReleaseMutex()'
  $r = Get-UwFindings -Text $noRead
  $nr = @($r.Findings)
  Invoke-UwCase 'CLEAN TWIN' 'take that distant read away and it FIRES, naming the variable' (
    $nr.Count -eq 1 -and $nr[0].Why -match 'held')

  $two = '$a = $m1.WaitOne(10)
$b = $m2.WaitOne(10)
if ($a) { Write-Output ''one'' }'
  $r = Get-UwFindings -Text $two
  $only = @($r.Findings)
  Invoke-UwCase 'CLEAN TWIN' 'with two waits it names the UNREAD one only' (
    $only.Count -eq 1 -and $only[0].Why -match 'b')

  $r = Get-UwFindings -Text 'this is not ( valid powershell'
  Invoke-UwCase 'CLEAN TWIN' 'a parse error is reported, never read as clean' ($r.ParseErrors)

  # The discovery is real, and it must resolve this tree or its silence means nothing.
  $scan = Get-UwScanFiles -RootDir $repo -SelfRel $SELF_REL
  Invoke-UwCase 'CLEAN TWIN' 'the discovery resolves the tracked tree' ($scan.Ok -and @($scan.Files).Count -gt 100)
  Invoke-UwCase 'MUST NOT FIRE' 'the discovery never returns this file itself' (
    -not (@($scan.Files) | Where-Object { [string]::Equals($_, $SELF_REL, [StringComparison]::OrdinalIgnoreCase) }))

  # The verdict line is LAST and names the self-test, and the block EXITS on every path: run-gates scores a
  # self-test that exits 0 without its own verdict as 3, and a block that can fall through reaches live code.
  if ($script:fail) {
    Exit-Guard -Name 'UNREAD-WAIT-SELFTEST' -Code 2 -Summary ("failed={0} of {1}" -f $script:fail, $script:cases)
  }
  Exit-Guard -Name 'UNREAD-WAIT-SELFTEST' -Code 0 -Summary ("cases={0}" -f $script:cases)
}

# ---------------------------------------------------------------------------------------------- live run
$scan = Get-UwScanFiles -RootDir $repo -SelfRel $SELF_REL
if (-not $scan.Ok -or -not @($scan.Files).Count) {
  Exit-Guard -Name 'AUDIT-UNREAD-WAIT' -Code 3 -Summary ("blind=discovery {0}" -f $scan.Error)
}
if (-not (@($scan.Files) | Where-Object { [string]::Equals($_, $script:UW_ANCHOR_FILE, [StringComparison]::OrdinalIgnoreCase) })) {
  Exit-Guard -Name 'AUDIT-UNREAD-WAIT' -Code 3 -Summary ("blind=anchor-missing files={0}" -f @($scan.Files).Count)
}

$all = New-Object System.Collections.ArrayList
$read = 0; $absent = 0; $parseErrorFiles = @()
foreach ($rel in @($scan.Files)) {
  $full = Join-Path $repo ($rel -replace '/', '\')
  if (-not (Test-Path -LiteralPath $full)) { $absent++; continue }
  $r = Get-UwFindings -Text ([IO.File]::ReadAllText($full))
  $read++
  if ($r.ParseErrors) { $parseErrorFiles += $rel }
  foreach ($h in $r.Findings) {
    [void]$all.Add([pscustomobject]@{ File = $rel; Line = $h.Line; Why = $h.Why; Expr = $h.Expr })
  }
}

# The rate carries its DENOMINATOR, always (.claude\rules\measurement.md).
Write-Output ("audit-unread-wait: {0} tracked .ps1/.psm1 resolved, {1} read ({2} absent in this checkout, {3} with a parse error); {4} timed wait(s) discard their answer" -f @($scan.Files).Count, $read, $absent, $parseErrorFiles.Count, $all.Count)
foreach ($p in $parseErrorFiles) { Write-Output ('  parse error (partial AST read)  ' + $p) }
foreach ($f in $all) { Write-Output ("  UNREAD WAIT  {0}:{1}  {2}  -  {3}" -f $f.File, $f.Line, $f.Expr, $f.Why) }

$summary = "scanned={0} findings={1}" -f $read, $all.Count
if ($all.Count) {
  Write-Output '  A timed WaitOne returns $false when it TIMED OUT, which means this caller does not hold the lock.'
  Write-Output '  Discarding that answer walks into the critical section having taken nothing, and nothing errors.'
  Write-Output '  On 2026-09-11 that let a timed-out waiter rewrite the whole triage queue over the writer holding'
  Write-Output '  the lock. Branch on it: if (-not $held) { refuse, and SAY so }. A refusal nobody can see is a'
  Write-Output '  run that declined to act and is indistinguishable from a run with nothing to do.'
  Exit-Guard -Name 'AUDIT-UNREAD-WAIT' -Code 1 -Summary $summary
}
Exit-Guard -Name 'AUDIT-UNREAD-WAIT' -Code 0 -Summary $summary
