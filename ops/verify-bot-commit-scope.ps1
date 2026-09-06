# verify-bot-commit-scope.ps1 - an AUTOMATED commit may only touch what lib\bot-paths.ps1 declares it owns.
#
# WHY THIS EXISTS (2026-09-06, PLAN-top5-2026-09-06 area 3). On 2026-09-05 push-data.ps1 ran `git add -A`
# on Brad's REAL working tree - the one interactive sessions and headless agents edit at the same time -
# and committed AND PUSHED 325 files to main, 192 of them .ps1 files mid-edit, 27 of which threw at
# startup. That is the fourth time this estate has paid for an automated sweep (2026-07-23, 2026-08-22,
# 2026-08-25, 2026-09-05).
#
# THE SCRIPTS ARE FIXED, AND THAT IS NOT THE STOP. Telling a script - or a spawned agent - "never
# git add -A" does nothing about the next script, and the four disabled scheduled-task prompts in this
# estate still contain the instruction. A hook is the only thing in the path of BOTH a careless human and
# an automated one, and this is the half of the hook that knows the difference between them.
#
# SESSIONS ARE UNAFFECTED. A person committing a .ps1 is ordinary work. Only a commit that identifies
# itself as the pipeline - author `smp-pipeline-bot`, or TC_BOT_COMMIT=1 in the environment - is held to
# the ownership list. That is why capture-run and push-data both commit under that identity: an automated
# commit that cannot be told apart from a session cannot be governed, and until 2026-09-06 push-data's
# commits went out as `Schweino`, which is why the 14:40 owner could not be named the next day.
#
#   ops\verify-bot-commit-scope.ps1              judge the staged set (what the pre-commit hook runs)
#   ops\verify-bot-commit-scope.ps1 -SelfTest    frozen must-fire fixtures + clean twins
# Exit 0 = in scope, or not a bot commit at all. 1 = a bot commit strays outside the list (REFUSE).
#      2 = self-test regression. 3 = BLIND (could not read the staged set).
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'lib\bot-paths.ps1')

function Test-IsBotCommit {
  <# Pure, so the fixture can drive both arms without a repo. The env flag is the stated way for a bot that
     has a reason not to change its author; the author name is what the two real pipeline commits carry. #>
  param([string]$AuthorName, [string]$EnvFlag, [string[]]$BotNames = @('smp-pipeline-bot'))
  if ($EnvFlag -eq '1') { return $true }
  foreach ($b in $BotNames) { if ($AuthorName -and $AuthorName.Trim() -eq $b) { return $true } }
  return $false
}

function Get-UnownedStagedPaths {
  <# Pure. The staged set minus everything lib\bot-paths.ps1 declares. #>
  param([string[]]$Staged, [string[]]$Owned)
  $out = New-Object System.Collections.ArrayList
  foreach ($s in @($Staged)) {
    if (-not $s) { continue }
    $args2 = @{ Path = $s }
    if ($PSBoundParameters.ContainsKey('Owned')) { $args2['Owned'] = $Owned }
    if (-not (Test-BotPathOwned @args2)) { [void]$out.Add($s) }
  }
  return ,@($out.ToArray())
}

if ($SelfTest) {
  $fail = 0
  function BsT([string]$m, [bool]$cond) {
    if ($cond) { Write-Output ('  PASS  ' + $m) } else { Write-Output ('  FAIL  ' + $m); $script:fail++ }
  }

  BsT 'MUST FIRE: the pipeline author is recognised as a bot commit' `
      (Test-IsBotCommit -AuthorName 'smp-pipeline-bot' -EnvFlag '')
  BsT 'MUST FIRE: TC_BOT_COMMIT=1 is recognised whatever the author says' `
      (Test-IsBotCommit -AuthorName 'Schweino' -EnvFlag '1')
  BsT 'CLEAN TWIN: an ordinary session author is NOT a bot commit (a person committing a .ps1 is work)' `
      (-not (Test-IsBotCommit -AuthorName 'Schweino' -EnvFlag ''))
  BsT 'CLEAN TWIN: an unset environment and an empty author is not a bot commit' `
      (-not (Test-IsBotCommit -AuthorName '' -EnvFlag ''))
  # A name that merely CONTAINS the bot's name is not the bot - exact match, or a nickname could opt a
  # person into a refusal they cannot explain.
  BsT 'CLEAN TWIN: an author whose name merely contains the bot name is not the bot' `
      (-not (Test-IsBotCommit -AuthorName 'not-smp-pipeline-bot' -EnvFlag ''))

  # THE FOUNDING SET: the real 3c44d0c1 shape - source files and data in one commit.
  $u = Get-UnownedStagedPaths -Staged @('grocery/push-data.ps1', 'grocery/out/regular/2026-09-05.json')
  BsT 'MUST FIRE: a .ps1 staged alongside data is named as out of scope (this is 3c44d0c1)' `
      (($u.Count -eq 1) -and ($u[0] -eq 'grocery/push-data.ps1'))
  $u = Get-UnownedStagedPaths -Staged @('grocery/out/regular/2026-09-05.json', 'grocery/carriage.json', 'public/board.json')
  BsT 'CLEAN TWIN: a commit of nothing but owned paths is silent' ($u.Count -eq 0)
  $u = Get-UnownedStagedPaths -Staged @('design/PLAN-x.md', 'meal-prep/pipeline/harvest-crawl.ps1', 'graph/identity/table.json')
  BsT 'MUST FIRE: every out-of-scope path is named, not just the first' `
      (($u.Count -eq 2) -and ($u -contains 'design/PLAN-x.md') -and ($u -contains 'meal-prep/pipeline/harvest-crawl.ps1'))
  $u = Get-UnownedStagedPaths -Staged @('grocery\out\regular\x.json')
  BsT 'CLEAN TWIN: a Windows-slashed staged path is the same path' ($u.Count -eq 0)
  $u = Get-UnownedStagedPaths -Staged @()
  BsT 'CLEAN TWIN: an empty staged set has nothing out of scope' ($u.Count -eq 0)

  if ($fail) { Write-Output "BOT-COMMIT-SCOPE SELF-TEST FAILED ($fail)"; exit 2 }
  Write-Output 'BOT-COMMIT-SCOPE SELF-TEST PASSED (bot recognised two ways, sessions untouched, every stray path named)'
  exit 0
}

# ---- live path: the staged set, judged only if this commit says it is the pipeline --------------------
# NO EAP=STOP AROUND A NATIVE CHILD. In PS 5.1 a single stderr line from git becomes a NativeCommandError
# and, under EAP=Stop, terminates the CALLER. This estate has paid for that trap four times.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  # `git var GIT_AUTHOR_IDENT` is the resolved identity: it honours GIT_AUTHOR_NAME in the environment AND
  # a `-c user.name=` passed to the committing git, which is exactly how capture-run and push-data set it.
  # Reading `git config user.name` alone would miss the environment form.
  $ident = (@(& git -C $repo var GIT_AUTHOR_IDENT) -join ' ')
  $author = if ($ident -match '^(.*?)\s+<') { $Matches[1] } else { '' }
  $staged = @(& git -C $repo diff --cached --name-only --diff-filter=ACMR | Where-Object { $_ })
} finally { $ErrorActionPreference = $prevEap }

if (-not (Test-IsBotCommit -AuthorName $author -EnvFlag $env:TC_BOT_COMMIT)) {
  Write-Output ("bot-commit-scope: not a bot commit (author '" + $author + "') - nothing to enforce")
  exit 0
}
if (-not $staged.Count) {
  Write-Output 'bot-commit-scope: BLIND - a bot commit with an empty staged set'
  exit 3
}
$unowned = Get-UnownedStagedPaths -Staged $staged
if (-not $unowned.Count) {
  Write-Output ("bot-commit-scope: ok - all " + $staged.Count + " staged path(s) are inside lib\bot-paths.ps1's ownership list")
  exit 0
}
Write-Output ("bot-commit-scope: REFUSING - this commit identifies as the pipeline (author '" + $author + "') but stages " + $unowned.Count + " path(s) it does not own:")
$unowned | Select-Object -First 30 | ForEach-Object { Write-Output ('    ' + $_) }
if ($unowned.Count -gt 30) { Write-Output ('    ...and ' + ($unowned.Count - 30) + ' more') }
Write-Output '  An automated commit stages its OWN outputs and nothing else - a shared working tree always'
Write-Output '  holds somebody else''s half-finished work (2026-09-05: 192 .ps1 files mid-edit, 27 of them'
Write-Output '  throwing at startup, on main for 59 minutes).'
Write-Output '  If a path above genuinely belongs to the pipeline, declare it in lib\bot-paths.ps1 with the'
Write-Output '  writer''s name and the reason. Do not widen the list to make one run go through.'
exit 1
