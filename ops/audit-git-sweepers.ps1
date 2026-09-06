# audit-git-sweepers.ps1 - no tracked script may stage by SWEEP. `git add -A` needs a `--` pathspec.
#
# WHY THIS EXISTS (2026-09-06, PLAN-top5-2026-09-06 area 3). Four incidents, one shape:
#
#   2026-07-23  the walmart flood
#   2026-08-22  d2a864c0 - 4,388 files / 797,640 insertions, 191 MB of seeded Chrome cookies
#   2026-08-25  0c47012c - a shared index carried an unrelated unit into a bot commit
#   2026-09-05  3c44d0c1 - push-data.ps1's `git add -A` put 325 files on main, 192 of them .ps1 files
#               MID-EDIT, 27 of which threw at startup, and left them there for 59 minutes
#
# Every one of them was fixed IN THE SCRIPT THAT DID IT, and the estate has carried a correctly worded
# warning about the shape since 2026-08-22 ("*** STAGE PIPELINE-OWNED PATHS ONLY - NEVER git add -A ***",
# capture-run.ps1:618). A warning in one file's comments does not reach the next file. This does: it is the
# enumeration, run on every push, over every tracked script.
#
# THE RULE, AND WHY IT IS THIS ONE. `git add -A` with a `--` pathspec is an OWNERSHIP list - it can only
# stage under paths the author named, and the author had to name them. `git add -A` without one takes
# whatever the tree happens to hold, which on a shared working tree is always somebody else's half-finished
# work. So the finding is the missing pathspec, not the flag.
#
# WHAT IT DELIBERATELY DOES NOT SEE. Comments (including the four accounts above), a line where the phrase
# appears after a `#`, and - in a .ps1 only - the phrase inside a quoted STRING. That last one is not
# fastidiousness: this estate documents its incidents inside its own assertion labels, and test-guards.ps1
# carries the sentence "...can still leave a mutated production file staged by git add -A" inside a
# Write-Output. A guard that fires on the account of the incident makes the account unwritable, and the
# next person deletes the guard rather than the sentence.
#
# THE COST IS RECORDED, NOT PAPERED OVER: a PowerShell command ASSEMBLED out of a string (`iex "git add -A"`)
# is invisible here. String-stripping is therefore applied to .ps1 only - a .py or .sh that shells out
# through a string is scanned whole, because that IS how those two languages call git.
#
#   ops\audit-git-sweepers.ps1              scan the tree
#   ops\audit-git-sweepers.ps1 -SelfTest    frozen must-fire fixtures + clean twins
# Exit 0 = no sweeper. 1 = at least one. 2 = self-test regression. 3 = BLIND (found no scripts to scan).
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

# ALLOWLISTED, AND EACH LINE IS A DECISION SOMEBODY DEFENDS IN A DIFF - never a way to make the gate quiet.
# All four are repos that are THROWAWAY by construction: a sweep there cannot reach anyone's working tree.
$ALLOW = @{
  '.github\workflows\daily.yml'    = 'the cloud backup runs in a fresh clone it created seconds earlier; there is no other work in that tree'
  'grocery\test-commit-size-gate.ps1' = 'builds fixture repos in %TEMP% to drive capture-run''s size gate'
  'grocery\test-push-data.ps1'        = 'builds fixture repos in %TEMP% to drive push-data''s commit lane'
  'ops\test-precommit-hook.ps1'       = 'builds fixture repos in %TEMP% to drive the pre-commit hook'
  'grocery\triage-due.ps1'            = 'its -SelfTest builds a one-file repo in %TEMP% to date an emitter commit'
}

function Remove-ScriptComments {
  <# PowerShell block comments first, then anything after a `#` on a line. With -PowerShell, quoted string
     literals are blanked too (see the header). Pure, so the fixture drives the same stripper the live scan
     does. Blanked rather than deleted, so line NUMBERS survive and a finding can be opened. #>
  param([string]$Text, [switch]$PowerShell)
  $t = [regex]::Replace($Text, '(?s)<#.*?#>', { param($m) ($m.Value -replace '[^\r\n]', ' ') })
  $out = New-Object System.Collections.ArrayList
  foreach ($l in ($t -split "`r?`n")) {
    $s = $l
    if ($PowerShell) {
      $s = [regex]::Replace($s, "'(?:[^']|'')*'", "''")
      $s = [regex]::Replace($s, '"(?:[^"]|"")*"', '""')
    }
    $h = $s.IndexOf('#')
    [void]$out.Add($(if ($h -ge 0) { $s.Substring(0, $h) } else { $s }))
  }
  return ($out.ToArray() -join "`n")
}

function Get-SweeperFindings {
  <# One line per swept `git add`. A `--` anywhere after the flag means the author named what they own. #>
  param([string]$Text, [switch]$PowerShell)
  $code = Remove-ScriptComments -Text $Text -PowerShell:$PowerShell
  $findings = New-Object System.Collections.ArrayList
  $ln = 0
  foreach ($l in ($code -split "`n")) {
    $ln++
    $m = [regex]::Match($l, 'git\s+(?:-C\s+\S+\s+)?add\s+(-A\b|--all\b|\.(?:\s|$))')
    if (-not $m.Success) { continue }
    $rest = $l.Substring($m.Index + $m.Length)
    if ($rest -match '(^|\s)--(\s|$)') { continue }
    [void]$findings.Add([pscustomobject]@{ Line = $ln; Text = $l.Trim() })
  }
  return ,@($findings.ToArray())
}

if ($SelfTest) {
  $fail = 0
  function GsT([string]$m, [bool]$c) { if ($c) { Write-Output ('  PASS  ' + $m) } else { Write-Output ('  FAIL  ' + $m); $script:fail++ } }

  GsT 'MUST FIRE: a bare `git add -A` is a finding (this is 3c44d0c1)' `
      ((Get-SweeperFindings -Text "  git add -A`n").Count -eq 1)
  GsT 'MUST FIRE: `git add .` is the same sweep with a different spelling' `
      ((Get-SweeperFindings -Text "git add .`n").Count -eq 1)
  GsT 'MUST FIRE: `git add --all` is too' ((Get-SweeperFindings -Text "git add --all`n").Count -eq 1)
  GsT 'MUST FIRE: `git -C $repo add -A` is the same call with a directory argument' `
      ((Get-SweeperFindings -Text 'git -C $repo add -A').Count -eq 1)
  GsT 'CLEAN TWIN: `git add -A -- grocery/out` names what it owns and is silent' `
      ((Get-SweeperFindings -Text 'git add -A -- grocery/out').Count -eq 0)
  GsT 'CLEAN TWIN: `git -C $repo add -A -- $paths` is silent' `
      ((Get-SweeperFindings -Text 'git -C $repo add -A -- $paths').Count -eq 0)
  # THE EXACT SHAPE THIS FILE IS FULL OF: the warning written as prose. A guard that fires on the account
  # of the incident makes every future account unwritable.
  GsT 'CLEAN TWIN: the phrase in a line comment is not a call' `
      ((Get-SweeperFindings -Text '# NEVER git add -A on a shared tree').Count -eq 0)
  GsT 'CLEAN TWIN: the phrase in a PowerShell block comment is not a call' `
      ((Get-SweeperFindings -Text "<#`n  its `git add -A` put 325 files on main`n#>`n").Count -eq 0)
  GsT 'CLEAN TWIN: the phrase after code on the same line is a trailing comment' `
      ((Get-SweeperFindings -Text '$x = 1   # was: git add -A').Count -eq 0)
  # THE test-guards.ps1 SHAPE, and this file's own self-test: the phrase inside a quoted string in a .ps1.
  # Needles built by concatenation so THIS line cannot be the thing it is testing for.
  $needle = 'git ' + 'add ' + '-A'
  GsT 'CLEAN TWIN: the phrase inside a single-quoted string in a .ps1 is not a call' `
      ((Get-SweeperFindings -PowerShell -Text ("Write-Output 'a run can still leave a file staged by " + $needle + "'")).Count -eq 0)
  GsT 'CLEAN TWIN: the phrase inside a double-quoted string in a .ps1 is not a call' `
      ((Get-SweeperFindings -PowerShell -Text ('$m = "' + $needle + ' is the sweep"')).Count -eq 0)
  # ...AND STRIPPING STRINGS MUST NOT BLIND THE REAL CALL. This is the pair that matters: same file kind,
  # same flag, unquoted. If this ever goes silent the whole audit has quietly become decoration.
  GsT 'MUST FIRE: an UNQUOTED call in the same .ps1 mode is still a finding' `
      ((Get-SweeperFindings -PowerShell -Text ('& git -C $repo ' + 'add ' + '-A | Out-Null')).Count -eq 1)
  # A .py or .sh calls git THROUGH a string, so string-stripping must not apply there.
  GsT 'MUST FIRE: a shell-out through a string in a .py/.sh is still seen (no -PowerShell)' `
      ((Get-SweeperFindings -Text ('subprocess.run("' + $needle + '", shell=True)')).Count -eq 1)
  # `git add -Ax` is not `git add -A`, and `git addendum` is not git add.
  GsT 'CLEAN TWIN: a longer flag that merely starts with -A is not the sweep' `
      ((Get-SweeperFindings -Text 'git add -Antelope').Count -eq 0)
  GsT 'MUST FIRE: the line NUMBER is reported so the finding can be opened' `
      ((Get-SweeperFindings -Text "one`ntwo`ngit add -A").Count -eq 1 -and (Get-SweeperFindings -Text "one`ntwo`ngit add -A")[0].Line -eq 3)
  # Two on one file are both reported: a first finding must not mask the rest.
  GsT 'MUST FIRE: every swept call is reported, not just the first' `
      ((Get-SweeperFindings -Text "git add -A`ngit add .").Count -eq 2)

  if ($fail) { Write-Output "GIT-SWEEPERS SELF-TEST FAILED ($fail)"; exit 2 }
  Write-Output 'GIT-SWEEPERS SELF-TEST PASSED (every spelling of the sweep armed, and every clean twin holds - including the prose and the assertion labels that document the incidents)'
  exit 0
}

# ---- live path: every tracked script in the tree -------------------------------------------------------
$exts = @('.ps1', '.yml', '.yaml', '.sh', '.py')
$files = @(Get-ChildItem $repo -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object { $exts -contains $_.Extension.ToLower() } |
  Where-Object { $_.FullName -notmatch '\\worktrees\\|\\archive\\|node_modules|\.venv|\\\.git\\' } |
  Sort-Object FullName)
if (-not $files.Count) {
  Write-Output 'audit-git-sweepers: BLIND - found no scripts to scan, which means this discovery is broken, not that the tree is clean'
  Write-GuardComplete -Name 'audit-git-sweepers' -Summary 'blind=no-scripts'
  exit 3
}

$findings = New-Object System.Collections.ArrayList
$allowed = 0
foreach ($f in $files) {
  $rel = $f.FullName.Replace($repo, '').TrimStart('\')
  $hits = Get-SweeperFindings -Text ([IO.File]::ReadAllText($f.FullName)) -PowerShell:($f.Extension -ieq '.ps1')
  if (-not $hits.Count) { continue }
  if ($ALLOW.ContainsKey($rel)) { $allowed++; continue }
  foreach ($h in $hits) { [void]$findings.Add(("{0}:{1}  {2}" -f $rel, $h.Line, $h.Text)) }
}

Write-Output ("audit-git-sweepers: {0} script(s) scanned, {1} allowlisted throwaway-repo file(s), {2} finding(s)" -f $files.Count, $allowed, $findings.Count)
foreach ($x in $findings) { Write-Output ('  ! ' + $x) }
if ($findings.Count) {
  Write-Output '  A `git add` with no `--` pathspec stages whatever the tree happens to hold. On a shared working'
  Write-Output '  tree that is somebody else''s half-finished work: 2026-09-05 put 192 mid-edit .ps1 files on main.'
  Write-Output '  Fix: name what the script owns - `git add -A -- $paths` - and take $paths from lib\bot-paths.ps1'
  Write-Output '  if the script is part of the pipeline. Allowlist only a repo that is THROWAWAY by construction.'
}
Write-GuardComplete -Name 'audit-git-sweepers' -Summary ("{0} finding(s) over {1} script(s)" -f $findings.Count, $files.Count)
if ($findings.Count) { exit 1 }
exit 0
