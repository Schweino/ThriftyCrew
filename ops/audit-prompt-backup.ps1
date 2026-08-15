<#
  audit-prompt-backup.ps1 - the agent prompts and scheduled-task SKILLs are CODE. Back them up, and prove
  the backup is current.

  WHY (2026-07-31): everything the triage agents depend on is versioned, self-tested and gated - and the
  agents' own instructions were not in git at all. They live in C:\Codex\ThriftyCrew\.claude\agents (project scope),
  C:\Users\Owner\.claude\agents (user scope) and C:\Users\Owner\.claude\scheduled-tasks\<task>\SKILL.md,
  none of which is a repository. A machine failure, or one bad overwrite, and the reasoning is gone.

  It also found the drift it was built to prevent, on its first run: SIX of the eight agent prompts already
  differed between project scope and user scope. Same name, two files, quietly disagreeing - and which one
  runs depends on where the session's working directory is. That is the same two-copies-of-one-truth trap
  this estate has paid for in pu-lib and in the category-exclude bake.

  Three checks:
    1. BACKUP CURRENCY  - repo copy matches the live project-scope file
    2. SCOPE AGREEMENT  - the user-scope copy matches the project-scope copy (where both exist)
    3. COVERAGE         - every live agent + SKILL has a backup at all
  Exit 0 clean, 2 drift/missing, 3 BLIND (nothing found to check - a pass that proves nothing).
  -Sync copies live -> repo and project -> user, then re-checks. -SelfTest runs frozen fixtures.
#>
param([switch]$Sync, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root   = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$backup = Join-Path $root 'prompt-backup'
$PROJ   = 'C:\Codex\ThriftyCrew\.claude\agents'
$USER   = 'C:\Users\Owner\.claude\agents'
$TASKS  = 'C:\Users\Owner\.claude\scheduled-tasks'
# PROJECT-SCOPE SKILLS, added 2026-08-15. This was a whole class the audit could not see: recipe-hunter,
# lesson and meal-macro live here, and recipe-hunter\SKILL.md alone is 12KB of the flow's operating rules -
# which stages stream, why the price lane is a singleton, which gate must never be weakened. None of it was
# in git. It was found while looking for that file to edit it, not by this guard, which is the tell that a
# coverage check enumerating three known directories can only ever be as complete as that list.
$SKILLS = 'C:\Codex\ThriftyCrew\.claude\skills'

function FileHash1([string]$p) { if (Test-Path $p) { return (Get-FileHash $p -Algorithm MD5).Hash } return $null }

function Compare-Prompts {
  param([string]$Proj, [string]$UserDir, [string]$Tasks, [string]$Backup, [string]$Skills = '')
  $issues = New-Object System.Collections.Generic.List[string]
  $checked = 0
  $agentBk = Join-Path $Backup 'agents'
  $taskBk  = Join-Path $Backup 'scheduled-tasks'

  foreach ($f in @(Get-ChildItem (Join-Path $Proj '*.md') -ErrorAction SilentlyContinue)) {
    $checked++
    $b = Join-Path $agentBk $f.Name
    if (-not (Test-Path $b)) { $issues.Add("NO BACKUP  agents\$($f.Name) - the live prompt exists only on this machine") }
    elseif ((FileHash1 $f.FullName) -ne (FileHash1 $b)) { $issues.Add("STALE BACKUP  agents\$($f.Name) - repo copy differs from the live project-scope file") }
    $u = Join-Path $UserDir $f.Name
    if (Test-Path $u) {
      if ((FileHash1 $f.FullName) -ne (FileHash1 $u)) { $issues.Add("SCOPE DRIFT  $($f.Name) - the user-scope copy differs from the project-scope copy, so which prompt runs depends on the session's working directory") }
    }
  }
  # a user-scope agent with no project twin is still live and still needs a backup
  foreach ($f in @(Get-ChildItem (Join-Path $UserDir '*.md') -ErrorAction SilentlyContinue)) {
    if (Test-Path (Join-Path $Proj $f.Name)) { continue }
    $checked++
    if (-not (Test-Path (Join-Path $agentBk $f.Name))) { $issues.Add("NO BACKUP  agents\$($f.Name) (user scope only)") }
  }
  foreach ($d in @(Get-ChildItem $Tasks -Directory -ErrorAction SilentlyContinue)) {
    $s = Join-Path $d.FullName 'SKILL.md'
    if (-not (Test-Path $s)) { continue }
    $checked++
    $b = Join-Path (Join-Path $taskBk $d.Name) 'SKILL.md'
    if (-not (Test-Path $b)) { $issues.Add("NO BACKUP  scheduled-tasks\$($d.Name)\SKILL.md") }
    elseif ((FileHash1 $s) -ne (FileHash1 $b)) { $issues.Add("STALE BACKUP  scheduled-tasks\$($d.Name)\SKILL.md") }
  }
  # project-scope skills: <skills>\<name>\SKILL.md, same shape as scheduled tasks
  if ($Skills) {
    $skillBk = Join-Path $Backup 'skills'
    foreach ($d in @(Get-ChildItem $Skills -Directory -ErrorAction SilentlyContinue)) {
      $s = Join-Path $d.FullName 'SKILL.md'
      if (-not (Test-Path $s)) { continue }
      $checked++
      $b = Join-Path (Join-Path $skillBk $d.Name) 'SKILL.md'
      if (-not (Test-Path $b)) { $issues.Add("NO BACKUP  skills\$($d.Name)\SKILL.md - the live skill exists only on this machine") }
      elseif ((FileHash1 $s) -ne (FileHash1 $b)) { $issues.Add("STALE BACKUP  skills\$($d.Name)\SKILL.md - repo copy differs from the live skill") }
    }
  }
  return @{ issues = $issues; checked = $checked }
}

if ($SelfTest) {
  $fail = 0
  function _C($label, $cond) { if ($cond) { Write-Output "ok    $label" } else { Write-Output "FAIL  $label"; $script:fail++ } }
  $tmp = Join-Path $env:TEMP ('promptbk-' + [guid]::NewGuid().ToString('N').Substring(0,8))
  $p = Join-Path $tmp 'proj'; $u = Join-Path $tmp 'user'; $t = Join-Path $tmp 'tasks'; $b = Join-Path $tmp 'backup'
  foreach ($d in @($p,$u,(Join-Path $t 'demo-task'),(Join-Path $b 'agents'),(Join-Path $b 'scheduled-tasks\demo-task'))) { New-Item -ItemType Directory -Force $d | Out-Null }
  try {
    Set-Content (Join-Path $p 'a.md') "prompt v1" -Encoding UTF8
    Set-Content (Join-Path $u 'a.md') "prompt v1" -Encoding UTF8
    Set-Content (Join-Path $b 'agents\a.md') "prompt v1" -Encoding UTF8
    Set-Content (Join-Path $t 'demo-task\SKILL.md') "skill v1" -Encoding UTF8
    Set-Content (Join-Path $b 'scheduled-tasks\demo-task\SKILL.md') "skill v1" -Encoding UTF8
    # CLEAN TWIN: everything in sync stays silent
    $r = Compare-Prompts $p $u $t $b
    _C 'clean twin: matching live/backup/scope reports no issue' ($r.issues.Count -eq 0 -and $r.checked -eq 2)
    # MUST-FIRE 1: the live prompt is edited and the backup is not
    Set-Content (Join-Path $p 'a.md') "prompt v2 - edited live" -Encoding UTF8
    Set-Content (Join-Path $u 'a.md') "prompt v2 - edited live" -Encoding UTF8
    $r = Compare-Prompts $p $u $t $b
    _C 'must-fire: an edited live prompt with a stale repo copy is caught' (($r.issues -join ' ') -match 'STALE BACKUP  agents\\a\.md')
    # MUST-FIRE 2: the two scopes disagree (the drift this found on its first real run)
    Set-Content (Join-Path $b 'agents\a.md') "prompt v2 - edited live" -Encoding UTF8
    Set-Content (Join-Path $u 'a.md') "prompt v1" -Encoding UTF8
    $r = Compare-Prompts $p $u $t $b
    _C 'must-fire: project and user scope disagreeing is caught' (($r.issues -join ' ') -match 'SCOPE DRIFT')
    # MUST-FIRE 3: a live prompt with no backup at all
    Set-Content (Join-Path $u 'a.md') "prompt v2 - edited live" -Encoding UTF8
    Set-Content (Join-Path $p 'b.md') "new prompt nobody backed up" -Encoding UTF8
    $r = Compare-Prompts $p $u $t $b
    _C 'must-fire: a live prompt with no backup is caught' (($r.issues -join ' ') -match 'NO BACKUP  agents\\b\.md')
    # MUST-FIRE 4: a SKILL edited without its backup
    Remove-Item (Join-Path $p 'b.md') -Force
    Set-Content (Join-Path $t 'demo-task\SKILL.md') "skill v2" -Encoding UTF8
    $r = Compare-Prompts $p $u $t $b
    _C 'must-fire: an edited scheduled-task SKILL with a stale backup is caught' (($r.issues -join ' ') -match 'STALE BACKUP  scheduled-tasks')
    # MUST-FIRE 5: a project-scope SKILL with no backup. THE FOUNDING CASE of this class, frozen: on
    # 2026-08-15 C:\Codex\ThriftyCrew\.claude\skills held three live skills (recipe-hunter, lesson, meal-macro) and
    # this audit reported "every live agent prompt and scheduled-task SKILL is backed up" - true, and
    # blind, because the sentence enumerated only what the guard knew to look at.
    Set-Content (Join-Path $t 'demo-task\SKILL.md') "skill v1" -Encoding UTF8
    $sk = Join-Path $tmp 'skills'; New-Item -ItemType Directory -Force (Join-Path $sk 'demo-skill') | Out-Null
    Set-Content (Join-Path $sk 'demo-skill\SKILL.md') "project skill v1" -Encoding UTF8
    $r = Compare-Prompts $p $u $t $b $sk
    _C 'must-fire: a project-scope SKILL with no backup is caught' (($r.issues -join ' ') -match 'NO BACKUP  skills\\demo-skill')
    # ...and once backed up it goes quiet, then fires again when the live copy is edited
    New-Item -ItemType Directory -Force (Join-Path $b 'skills\demo-skill') | Out-Null
    Set-Content (Join-Path $b 'skills\demo-skill\SKILL.md') "project skill v1" -Encoding UTF8
    $r = Compare-Prompts $p $u $t $b $sk
    _C 'clean twin: a backed-up project-scope SKILL reports no issue' (($r.issues -join ' ') -notmatch 'skills\\demo-skill')
    Set-Content (Join-Path $sk 'demo-skill\SKILL.md') "project skill v2 - edited live" -Encoding UTF8
    $r = Compare-Prompts $p $u $t $b $sk
    _C 'must-fire: an edited project-scope SKILL with a stale backup is caught' (($r.issues -join ' ') -match 'STALE BACKUP  skills\\demo-skill')
    # and the skills dir counts toward `checked`, or a skills-only machine would report BLIND as clean
    _C 'project-scope skills count toward the coverage tally' ($r.checked -ge 3)

    # BLIND: nothing to check is not a pass
    $empty = Join-Path $tmp 'empty'; New-Item -ItemType Directory -Force $empty | Out-Null
    $r = Compare-Prompts $empty $empty $empty $b $empty
    _C 'blind: zero prompts found is reported as checked=0, not as clean' ($r.checked -eq 0)
  } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  Write-Output ''
  if ($fail -gt 0) { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
  Write-Output 'SELF-TEST PASS (10 prompt-backup cases)'
  exit 0
}

if ($Sync) {
  New-Item -ItemType Directory -Force (Join-Path $backup 'agents') | Out-Null
  New-Item -ItemType Directory -Force (Join-Path $backup 'scheduled-tasks') | Out-Null
  $n = 0
  foreach ($f in @(Get-ChildItem (Join-Path $PROJ '*.md') -ErrorAction SilentlyContinue)) {
    Copy-Item $f.FullName (Join-Path $backup ('agents\' + $f.Name)) -Force; $n++
    # project scope is canonical (it is what wins when the session sits in the project); make user match
    $u = Join-Path $USER $f.Name
    if (Test-Path $u) { if ((FileHash1 $f.FullName) -ne (FileHash1 $u)) { Copy-Item $f.FullName $u -Force; Write-Output ("  scope-synced user copy of " + $f.Name + " from project scope") } }
  }
  foreach ($f in @(Get-ChildItem (Join-Path $USER '*.md') -ErrorAction SilentlyContinue)) {
    if (Test-Path (Join-Path $PROJ $f.Name)) { continue }
    Copy-Item $f.FullName (Join-Path $backup ('agents\' + $f.Name)) -Force; $n++
  }
  foreach ($d in @(Get-ChildItem $TASKS -Directory -ErrorAction SilentlyContinue)) {
    $s = Join-Path $d.FullName 'SKILL.md'
    if (-not (Test-Path $s)) { continue }
    $dst = Join-Path $backup ('scheduled-tasks\' + $d.Name)
    New-Item -ItemType Directory -Force $dst | Out-Null
    Copy-Item $s (Join-Path $dst 'SKILL.md') -Force; $n++
    foreach ($extra in @(Get-ChildItem (Join-Path $d.FullName '*.md') -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'SKILL.md' })) {
      Copy-Item $extra.FullName (Join-Path $dst $extra.Name) -Force   # e.g. SKILL.monolith-fallback.md
    }
  }
  foreach ($d in @(Get-ChildItem $SKILLS -Directory -ErrorAction SilentlyContinue)) {
    $s = Join-Path $d.FullName 'SKILL.md'
    if (-not (Test-Path $s)) { continue }
    $dst = Join-Path $backup ('skills\' + $d.Name)
    New-Item -ItemType Directory -Force $dst | Out-Null
    Copy-Item $s (Join-Path $dst 'SKILL.md') -Force; $n++
    foreach ($extra in @(Get-ChildItem (Join-Path $d.FullName '*.md') -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'SKILL.md' })) {
      Copy-Item $extra.FullName (Join-Path $dst $extra.Name) -Force
    }
  }
  Write-Output ("prompt-backup: synced $n file(s) into ops\prompt-backup")
}

$res = Compare-Prompts $PROJ $USER $TASKS $backup $SKILLS
Write-Output ("prompt-backup: checked " + $res.checked + " live prompt(s) against ops\prompt-backup")
if ($res.checked -eq 0) {
  Write-Output 'PROMPT-BACKUP BLIND: found ZERO live prompts to check. Either the .claude paths moved or this ran somewhere without them - a clean result here would mean nothing.'
  exit 3
}
if ($res.issues.Count -eq 0) { Write-Output '  ok - every live agent prompt, scheduled-task SKILL and project-scope skill is backed up, current, and identical across scopes'; Write-GuardComplete -Name 'prompt-backup'; exit 0 }
Write-Output ("  " + $res.issues.Count + " issue(s):")
foreach ($i in $res.issues) { Write-Output ("    " + $i) }
Write-Output '  Fix: run this with -Sync (live -> repo, and project scope -> user scope), then commit ops\prompt-backup.'
Write-GuardComplete -Name 'prompt-backup'; exit 2
