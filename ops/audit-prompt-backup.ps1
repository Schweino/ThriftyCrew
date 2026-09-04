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

# ---- THE EXEMPTION LIST (2026-09-04, queue 2026-09-04-0b63d3) -------------------------------------------
# ops\prompt-backup is TRACKED IN A PUBLIC REPOSITORY. "NO BACKUP" is therefore not always a defect to fix
# by copying: some live prompts must never be mirrored there. On 2026-09-04 this audit reported NO BACKUP on
# a personal flight-price watch (travel dates, alert recipients) and the remedy it printed - -Sync - would
# have committed it to github.com/Schweino/ThriftyCrew. An exemption says "deliberately not mirrored", and
# -Sync honours it, so the exemption cannot be undone by the command the finding recommends.
# MISSING FILE = NO EXEMPTIONS (the audit behaves exactly as it did before this existed).
# UNREADABLE OR MALFORMED FILE = THROW, and the caller exits 3 BLIND. A typo in this file must never read as
# "nothing is exempt" and must never read as "everything is exempt": it must read as "I cannot judge".
function Get-PromptExemptions([string]$Path) {
  $map = @{}
  if (-not $Path -or -not (Test-Path $Path)) { return $map }
  $raw = [IO.File]::ReadAllText($Path)     # let an IO error throw: unreadable is not empty
  $doc = ConvertFrom-Json $raw             # let a parse error throw: malformed is not empty
  foreach ($e in @($doc.exempt)) {
    $n = ([string]$e.name).Trim()
    if (-not $n) { throw ('prompt-backup-exempt.json holds an entry with no name - refusing to guess what it exempts') }
    $k = (([string]$e.kind).Trim().ToLower()) + '|' + $n.ToLower()
    $map[$k] = ([string]$e.reason)
  }
  return $map
}

function Compare-Prompts {
  param([string]$Proj, [string]$UserDir, [string]$Tasks, [string]$Backup, [string]$Skills = '', [hashtable]$Exempt = $null)
  $issues = New-Object System.Collections.Generic.List[string]
  $notes  = New-Object System.Collections.Generic.List[string]
  if ($null -eq $Exempt) { $Exempt = @{} }
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
    # AN EXEMPTED TASK STILL COUNTS IN `checked`. It was examined and a decision was reached about it; the
    # coverage tally is what stops this audit reporting clean over a directory it never opened, and dropping
    # an exempted task out of it would shrink the very number that proves the audit looked.
    $checked++
    $ekey = 'scheduled-task|' + $d.Name.ToLower()
    if ($Exempt.ContainsKey($ekey)) {
      $notes.Add("EXEMPT  scheduled-tasks\$($d.Name)\SKILL.md - " + $Exempt[$ekey])
      continue
    }
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
  return @{ issues = $issues; checked = $checked; notes = $notes }
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

    # ---- THE EXEMPTION LIST (2026-09-04, queue 2026-09-04-0b63d3) --------------------------------------
    # Founding case, frozen: a PERSONAL scheduled task (a flight-price watch carrying travel dates and alert
    # recipients) was reported NO BACKUP, and the remedy this audit prints - -Sync - would have copied it
    # into ops\prompt-backup, which is tracked in a repository that loads without a login.
    # MUST FIRE: a live task with no mirror and NO exemption is still a finding. The whole exemption
    # mechanism is worthless if it can be reached accidentally, so the unexempted twin is asserted first.
    $t2 = Join-Path $tmp 'tasks2'
    New-Item -ItemType Directory -Force (Join-Path $t2 'personal-watch') | Out-Null
    Set-Content (Join-Path $t2 'personal-watch\SKILL.md') "private task v1" -Encoding UTF8
    $r = Compare-Prompts $p $u $t2 $b
    _C 'must-fire: a live scheduled-task SKILL with no backup and NO exemption still reports NO BACKUP' `
      (($r.issues -join ' ') -match 'NO BACKUP  scheduled-tasks\\personal-watch')
    # CLEAN TWIN: the same task, exempted. EXEMPT is a note, not an issue - and it still COUNTS as checked,
    # because dropping it out of the tally would shrink the number that proves this audit looked at all.
    $exMap = @{ 'scheduled-task|personal-watch' = 'personal, carries travel dates; the mirror is public' }
    $r = Compare-Prompts $p $u $t2 $b '' $exMap
    _C 'clean twin: an EXEMPT scheduled task is not an issue' (($r.issues -join ' ') -notmatch 'personal-watch')
    _C '  ...and it prints an EXEMPT line naming its reason' (($r.notes -join ' ') -match 'EXEMPT  scheduled-tasks\\personal-watch\\SKILL\.md - personal, carries travel dates')
    _C '  ...and it still counts toward the coverage tally' ($r.checked -ge 1)
    # The exemption is keyed on KIND as well as name: an agent prompt of the same name is NOT exempted by a
    # scheduled-task entry, or one line in this file could quietly cover files nobody meant it to.
    $exWrongKind = @{ 'skill|personal-watch' = 'wrong kind' }
    $r = Compare-Prompts $p $u $t2 $b '' $exWrongKind
    _C 'must-fire: an exemption of a DIFFERENT kind does not exempt the task' (($r.issues -join ' ') -match 'NO BACKUP  scheduled-tasks\\personal-watch')
    # MUST FIRE: the LIST ITSELF. A missing list is "nothing exempt"; an unreadable or malformed one is a
    # question this audit cannot answer, and it must say so rather than default either way.
    $exDir = Join-Path $tmp 'exempt'; New-Item -ItemType Directory -Force $exDir | Out-Null
    $exOk = Join-Path $exDir 'good.json'
    Set-Content $exOk '{ "exempt": [ { "kind": "scheduled-task", "name": "personal-watch", "reason": "personal" } ] }' -Encoding UTF8
    $exBad = Join-Path $exDir 'bad.json'
    Set-Content $exBad '{ "exempt": [ { "kind": "scheduled-task", ' -Encoding UTF8      # truncated on purpose
    $exNoName = Join-Path $exDir 'noname.json'
    Set-Content $exNoName '{ "exempt": [ { "kind": "scheduled-task", "reason": "oops" } ] }' -Encoding UTF8
    _C 'clean twin: a MISSING exemption list means nothing is exempt, not everything' ((Get-PromptExemptions (Join-Path $exDir 'does-not-exist.json')).Count -eq 0)
    _C 'clean twin: a well-formed list parses to exactly its entries, keyed kind|name' `
      ((Get-PromptExemptions $exOk).ContainsKey('scheduled-task|personal-watch'))
    $threw = $false; try { $null = Get-PromptExemptions $exBad } catch { $threw = $true }
    _C 'must-fire: a MALFORMED exemption list throws (the caller exits 3 BLIND, never clean)' $threw
    $threw = $false; try { $null = Get-PromptExemptions $exNoName } catch { $threw = $true }
    _C 'must-fire: an entry with no name throws rather than exempting nothing silently' $threw

    # BLIND: nothing to check is not a pass
    $empty = Join-Path $tmp 'empty'; New-Item -ItemType Directory -Force $empty | Out-Null
    $r = Compare-Prompts $empty $empty $empty $b $empty
    _C 'blind: zero prompts found is reported as checked=0, not as clean' ($r.checked -eq 0)
  } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  Write-Output ''
  if ($fail -gt 0) { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
  Write-Output 'SELF-TEST PASS (20 prompt-backup cases)'
  exit 0
}

# LOAD THE EXEMPTIONS BEFORE ANYTHING WRITES. -Sync consults the same map the report does, so the two can
# never disagree about what is exempt. An unreadable or malformed list is BLIND (exit 3), never clean and
# never "nothing exempt": this file is the only thing standing between a personal scheduled task and a
# public repo, and a check that cannot read it has not checked anything.
$script:PromptExempt = @{}
try { $script:PromptExempt = Get-PromptExemptions (Join-Path $root 'prompt-backup-exempt.json') }
catch {
  Write-Output ('PROMPT-BACKUP BLIND: ops\prompt-backup-exempt.json could not be read or parsed (' + $_.Exception.Message + '). Refusing to run: an unreadable exemption list cannot be treated as an empty one, and -Sync would mirror files this list exists to keep out of a public repo.')
  exit 3
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
    # THE EXEMPTION IS ENFORCED HERE, NOT ONLY REPORTED. Without this line the finding would say "deliberately
    # not mirrored" and the very next -Sync would mirror it anyway - into a public repo. This loop is the only
    # thing that can mint that leak, so this is where it is refused.
    if ($script:PromptExempt.ContainsKey('scheduled-task|' + $d.Name.ToLower())) {
      Write-Output ('  skipped scheduled-tasks\' + $d.Name + '\SKILL.md - EXEMPT (' + $script:PromptExempt['scheduled-task|' + $d.Name.ToLower()] + ')')
      continue
    }
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

$res = Compare-Prompts $PROJ $USER $TASKS $backup $SKILLS $script:PromptExempt
Write-Output ("prompt-backup: checked " + $res.checked + " live prompt(s) against ops\prompt-backup")
if ($res.checked -eq 0) {
  Write-Output 'PROMPT-BACKUP BLIND: found ZERO live prompts to check. Either the .claude paths moved or this ran somewhere without them - a clean result here would mean nothing.'
  exit 3
}
# The EXEMPT lines print on every run, clean or not. A deliberate non-mirror that nobody can see turns back
# into an accident the first time someone new reads this output and "fixes" it.
foreach ($n in $res.notes) { Write-Output ("  " + $n) }
if ($res.issues.Count -eq 0) { Write-Output '  ok - every live agent prompt, scheduled-task SKILL and project-scope skill is backed up, current, and identical across scopes'; Write-GuardComplete -Name 'prompt-backup'; exit 0 }
Write-Output ("  " + $res.issues.Count + " issue(s):")
foreach ($i in $res.issues) { Write-Output ("    " + $i) }
Write-Output '  Fix: run this with -Sync (live -> repo, and project scope -> user scope), then commit ops\prompt-backup.'
Write-GuardComplete -Name 'prompt-backup'; exit 2
