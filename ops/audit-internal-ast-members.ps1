<#
  audit-internal-ast-members.ps1 - no script reads a PowerShell AST member that is INTERNAL under 5.1.

  WHY THIS EXISTS (2026-09-12). `VariablePath.UnqualifiedPath` is exactly the property an AST walk wants - the
  variable's name with any scope prefix removed - and under Windows PowerShell 5.1 it is INTERNAL, so it reads as
  $null. That is the worst available failure: used as a hashtable key it throws, which is the LUCKY case, and used
  in a `-match` or a comparison it matches nothing, so a walk that collects variable names finds none and returns
  an AGREEING EMPTY. The rule went into .claude\rules\ops-and-gates.md on 2026-09-11 and
  lib\selftest-lib.ps1's Get-SelfTestVariableName is the correct form: read UserPath and strip the scope.

  Measured 2026-09-12 across the tracked tree: four files mentioned the name and THREE of them were comments
  warning against it, sitting directly above the right code - the clearest possible sign that the trap is known,
  is easy to fall into, and that knowing about it in prose does not stop the next call. The fourth,
  ops\prepush-test-auditors.ps1, actually called it, with a fallback to UserPath when it came back empty. That
  file was correct in its RESULT (it strips the scope on the next line), so nothing was broken, but the call was
  dead and indistinguishable at a glance from the version that is not. It was removed in the same change that
  added this file, which is why this gate ships at zero and is not red on day one.

  THE LIST IS PINNED AND SHORT, deliberately. It holds the members this estate has actually been bitten by, and
  a new entry is added when a new one bites - not by enumerating what .NET marks internal, which varies by
  runtime and would make the same tree red on one box and green on another.

  SCOPE OF A CLEAN REPORT: UNSOUND. It reads the AST of tracked .ps1/.psm1 and reports a member ACCESS whose
  member name is on the pinned list. A clean report means no such access is spelled literally. It cannot see a
  member reached by a computed name ($ast.$prop), through Invoke-Expression, or by reflection; nor any internal
  member not on the list. A REPORTED access is real.

  EXIT CODES: 0 clean, 1 at least one access, 2 self-test regression, 3 BLIND (discovery resolved nothing, or the
  anchor file is missing from what it resolved).

    ops\audit-internal-ast-members.ps1             scan the tracked tree
    ops\audit-internal-ast-members.ps1 -SelfTest   the founding member, the correct form, and the near misses
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

$SELF_REL = 'ops/audit-internal-ast-members.ps1'
$script:IAM_ANCHOR_FILE = 'ops/run-gates.ps1'

# member name -> what to do instead. One entry per member this estate has been bitten by.
$script:IAM_MEMBERS = @{
  'UnqualifiedPath' = 'INTERNAL under PS 5.1, so it reads as $null: use VariablePath.UserPath and strip the scope prefix yourself (lib\selftest-lib.ps1 Get-SelfTestVariableName)'
}

function Get-IamFindings {
  <# Findings for ONE file's text. @{ Findings = @(@{Line;Member;Expr}); ParseErrors = [bool] }.
     A COMMENT is not an access: the AST carries no comment nodes, so warning about the trap in prose - which
     three of the four files in this tree do - can never be reported as committing it. That property is why this
     reads the AST rather than grepping, and it is asserted by a MUST NOT FIRE case below. #>
  param([string]$Text)
  $tokens = $null; $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
  $parseErrors = ($null -ne $errors -and @($errors).Count -gt 0)
  $out = New-Object System.Collections.ArrayList
  if ($null -eq $ast) { return [pscustomobject]@{ Findings = @(); ParseErrors = $true } }

  foreach ($m in @($ast.FindAll({
      param($n)
      ($n -is [System.Management.Automation.Language.MemberExpressionAst] -or
       $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) -and
      $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]
    }, $true))) {
    $name = [string]$m.Member.Value
    if ($script:IAM_MEMBERS.ContainsKey($name)) {
      [void]$out.Add([pscustomobject]@{
        Line   = $m.Extent.StartLineNumber
        Member = $name
        Expr   = ([string]$m.Extent.Text)
      })
    }
  }
  return [pscustomobject]@{ Findings = @($out.ToArray()); ParseErrors = $parseErrors }
}

function Get-IamScanFiles {
  <# Tracked .ps1/.psm1 under $RootDir, repo-relative, never $SelfRel. `git ls-files`, for the reason
     ops\audit-cmdlet-shadow.ps1 gives: it is relative to the checkout it runs in, so a linked worktree reads
     whole and a sibling worktree below it is never read. Returns @{ Ok; Files; Error }. #>
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
  function Invoke-IamCase {
    param([string]$Label, [string]$What, [bool]$Ok)
    $script:cases++
    if (-not $Ok) { $script:fail++ }
    Write-Output ("  {0,-14} {1,-64} {2}" -f $Label, $What, $(if ($Ok) { 'ok' } else { 'FAIL' }))
  }

  # Fixtures are SINGLE-QUOTED LITERALS with doubled inner quotes, never built by concatenation (2026-09-07).

  # --- MUST FIRE: the founding member read ---------------------------------------------------------
  $founding = '$up = [string]$vp.UnqualifiedPath'
  $r = Get-IamFindings -Text $founding
  Invoke-IamCase 'MUST FIRE' 'a read of VariablePath.UnqualifiedPath is found' (@($r.Findings).Count -eq 1)

  $guarded = '$up = [string]$vp.UnqualifiedPath; if (-not $up) { $up = [string]$vp.UserPath }'
  $r = Get-IamFindings -Text $guarded
  Invoke-IamCase 'MUST FIRE' 'a read with a UserPath fallback is STILL found (the call is dead)' (
    @($r.Findings).Count -eq 1)

  # --- MUST NOT FIRE: legal inputs. Silent, or it is crying wolf. -----------------------------------
  $correct = '$up = [string]$vp.UserPath
if ($up.Contains('':'')) { $up = $up.Substring($up.LastIndexOf('':'') + 1) }'
  $r = Get-IamFindings -Text $correct
  Invoke-IamCase 'MUST NOT FIRE' 'the CORRECT UserPath form is quiet' (@($r.Findings).Count -eq 0)

  # THE POINT OF READING THE AST RATHER THAN GREPPING. Three of the four files that mention this member only
  # WARN about it. A grep would report all three as committing the very thing they exist to prevent.
  $commentOnly = '# NOT VariablePath.UnqualifiedPath: PS 5.1 has no public one, so it reads as $null.
$up = [string]$vp.UserPath'
  $r = Get-IamFindings -Text $commentOnly
  Invoke-IamCase 'MUST NOT FIRE' 'a COMMENT naming the member is not an access' (@($r.Findings).Count -eq 0)

  $inString = '$msg = ''do not use UnqualifiedPath here'''
  $r = Get-IamFindings -Text $inString
  Invoke-IamCase 'MUST NOT FIRE' 'the member named inside a STRING is not an access' (@($r.Findings).Count -eq 0)

  $otherMember = '$up = [string]$vp.UserPath'
  $r = Get-IamFindings -Text $otherMember
  Invoke-IamCase 'MUST NOT FIRE' 'a member that is not on the list is not judged' (@($r.Findings).Count -eq 0)

  # --- CLEAN TWIN: adjacent behaviour that must STILL WORK (a POSITIVE assertion) -------------------
  $two = '$a = $v1.UnqualifiedPath
$b = $v2.UnqualifiedPath
$c = $v3.UserPath'
  $r = Get-IamFindings -Text $two
  Invoke-IamCase 'CLEAN TWIN' 'two accesses are counted as two, and UserPath is not one' (
    @($r.Findings).Count -eq 2)

  $r = Get-IamFindings -Text 'this is not ( valid powershell'
  Invoke-IamCase 'CLEAN TWIN' 'a parse error is reported, never read as clean' ($r.ParseErrors)

  Invoke-IamCase 'CLEAN TWIN' 'every listed member carries the instead-do-this text' (
    -not (@($script:IAM_MEMBERS.Keys | Where-Object { -not ([string]$script:IAM_MEMBERS[$_]).Trim() })))

  $scan = Get-IamScanFiles -RootDir $repo -SelfRel $SELF_REL
  Invoke-IamCase 'CLEAN TWIN' 'the discovery resolves the tracked tree' ($scan.Ok -and @($scan.Files).Count -gt 100)
  Invoke-IamCase 'MUST NOT FIRE' 'the discovery never returns this file itself' (
    -not (@($scan.Files) | Where-Object { [string]::Equals($_, $SELF_REL, [StringComparison]::OrdinalIgnoreCase) }))

  # The verdict is LAST, names the self-test, and the block EXITS on every path.
  if ($script:fail) {
    Exit-Guard -Name 'INTERNAL-AST-MEMBERS-SELFTEST' -Code 2 -Summary ("failed={0} of {1}" -f $script:fail, $script:cases)
  }
  Exit-Guard -Name 'INTERNAL-AST-MEMBERS-SELFTEST' -Code 0 -Summary ("cases={0}" -f $script:cases)
}

# ---------------------------------------------------------------------------------------------- live run
$scan = Get-IamScanFiles -RootDir $repo -SelfRel $SELF_REL
if (-not $scan.Ok -or -not @($scan.Files).Count) {
  Exit-Guard -Name 'AUDIT-INTERNAL-AST-MEMBERS' -Code 3 -Summary ("blind=discovery {0}" -f $scan.Error)
}
if (-not (@($scan.Files) | Where-Object { [string]::Equals($_, $script:IAM_ANCHOR_FILE, [StringComparison]::OrdinalIgnoreCase) })) {
  Exit-Guard -Name 'AUDIT-INTERNAL-AST-MEMBERS' -Code 3 -Summary ("blind=anchor-missing files={0}" -f @($scan.Files).Count)
}

$all = New-Object System.Collections.ArrayList
$read = 0; $absent = 0; $parseErrorFiles = @()
foreach ($rel in @($scan.Files)) {
  $full = Join-Path $repo ($rel -replace '/', '\')
  if (-not (Test-Path -LiteralPath $full)) { $absent++; continue }
  $r = Get-IamFindings -Text ([IO.File]::ReadAllText($full))
  $read++
  if ($r.ParseErrors) { $parseErrorFiles += $rel }
  foreach ($h in $r.Findings) {
    [void]$all.Add([pscustomobject]@{ File = $rel; Line = $h.Line; Member = $h.Member; Expr = $h.Expr })
  }
}

# The rate carries its DENOMINATOR, always (.claude\rules\measurement.md).
Write-Output ("audit-internal-ast-members: {0} tracked .ps1/.psm1 resolved, {1} read ({2} absent in this checkout, {3} with a parse error) against {4} pinned member name(s); {5} access(es)" -f @($scan.Files).Count, $read, $absent, $parseErrorFiles.Count, $script:IAM_MEMBERS.Count, $all.Count)
foreach ($p in $parseErrorFiles) { Write-Output ('  parse error (partial AST read)  ' + $p) }
foreach ($f in $all) {
  Write-Output ("  INTERNAL MEMBER  {0}:{1}  {2}" -f $f.File, $f.Line, $f.Expr)
  Write-Output ("    {0}" -f $script:IAM_MEMBERS[$f.Member])
}

$summary = "scanned={0} findings={1}" -f $read, $all.Count
if ($all.Count) { Exit-Guard -Name 'AUDIT-INTERNAL-AST-MEMBERS' -Code 1 -Summary $summary }
Exit-Guard -Name 'AUDIT-INTERNAL-AST-MEMBERS' -Code 0 -Summary $summary
