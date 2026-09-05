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
  -SelfTest runs frozen fixtures.

  THE WRITE MODES (2026-09-05, queue 2026-09-05-5650ce). -Sync used to be ONE button doing three things
  with three different risk profiles, and because the riskiest of them writes into a PUBLIC repository the
  whole button could not be automated. So this audit printed the same seven findings every morning for 13
  days and nothing moved: the recipe writer ran Opus-pinned at high effort in two of the three copies, the
  dedup selector carried no precedents contract, and the recipe-hunter SKILL was missing Brad's 09-04
  browser-pricing ruling - for every session whose working directory sits outside the repo. An alarm whose
  only follower is a human typing a command is an alarm with no repair lane.
    -SyncScopes  project scope -> user scope. LOCAL ONLY: nothing is published, and this is the half that
                 decides WHICH PROMPT ACTUALLY RUNS. Safe to automate, and run daily from capture-run.ps1.
    -SyncMirror  live -> ops\prompt-backup, but ONLY where a mirror ALREADY EXISTS. Refreshing a copy of a
                 file that is already public publishes nothing new. Safe to automate.
    -Adopt       live -> ops\prompt-backup for a file that has NO mirror yet. This is the only mode that
                 turns a private file into a public one, so it stays a deliberate act with a name attached:
                 -Adopt recipe-writer.md, or -Adopt skill|recipe-hunter. -Adopt * means all of them.
    -Sync        = -SyncScopes -SyncMirror -Adopt *. Kept verbatim: every design doc and every habit in
                 this estate says "run -Sync", and that must keep meaning exactly what it always meant.
  NO BACKUP therefore stays the one finding that still needs a person, which is the point.
#>
# [CmdletBinding()] IS LOAD-BEARING HERE. Without it PS 5.1 drops an unrecognised -Arg into $args and runs
# on: a typo'd -SyncMirrors would have made a read-only report look like a completed sync, and the daily
# hook would have "run" every morning writing nothing. See the [[arg-silently-ignored]] class - a scoping
# flag that falls into $args exits 0 having done the unscoped thing, or nothing at all.
[CmdletBinding()]
param([switch]$Sync, [switch]$SyncScopes, [switch]$SyncMirror, [string[]]$Adopt, [switch]$SelfTest)
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

# ---- THE WRITE SIDE, SPLIT BY RISK (2026-09-05, queue 2026-09-05-5650ce) -------------------------------
# The whole point of the split is the line drawn inside Copy-PromptToMirror: REFRESHING a mirror that
# already exists publishes nothing that is not already public, while CREATING one publishes a file for the
# first time. Those were one command, so the safe half could not be automated and the drift lived 13 days.
# The write side is a function taking explicit roots (not the module-scope $PROJ/$USER/...) for one reason:
# a fix nobody can test is a fix nobody can trust, and -SelfTest below drives these exact code paths over a
# temp fixture. See [[fix-needs-reachable-selftest]].

# -Adopt matches a bare name ('recipe-writer.md', 'recipe-hunter') or the kind|name form ('skill|recipe-hunter'),
# so the name a person reads in a NO BACKUP line is a name they can paste straight back in. '*' means all.
function Test-AdoptName {
  param([string[]]$AdoptNames, [string]$Kind, [string]$Name)
  foreach ($a in @($AdoptNames)) {
    $t = ([string]$a).Trim()
    if (-not $t) { continue }
    if ($t -eq '*') { return $true }
    if ($t -ieq $Name) { return $true }
    if ($t -ieq ($Kind + '|' + $Name)) { return $true }
  }
  return $false
}

# Returns 'refreshed' | 'adopted' | 'held' | '' (nothing to do).
# 'held' is the deliberate outcome, not a failure: the file has no mirror, nothing named it for adoption,
# so it stays local and the report keeps saying NO BACKUP until a person decides.
function Copy-PromptToMirror {
  param([string]$Src, [string]$Dst, [switch]$DoMirror, [string[]]$AdoptNames, [string]$Kind, [string]$Name)
  if (Test-Path $Dst) {
    if (-not $DoMirror) { return '' }
    if ((FileHash1 $Src) -eq (FileHash1 $Dst)) { return '' }
    Copy-Item $Src $Dst -Force
    return 'refreshed'
  }
  # NO MIRROR YET. -SyncMirror must never reach past this line: ops\prompt-backup is tracked in a repository
  # that loads without a login, and "the mirror is stale" and "this file has never been published" are not
  # the same decision. Only -Adopt crosses it.
  if (-not (Test-AdoptName $AdoptNames $Kind $Name)) { return 'held' }
  $d = Split-Path $Dst -Parent
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
  Copy-Item $Src $Dst -Force
  return 'adopted'
}

function Invoke-PromptSync {
  param(
    [string]$Proj, [string]$UserDir, [string]$Tasks, [string]$Backup, [string]$Skills = '',
    [hashtable]$Exempt = $null,
    [switch]$DoScopes, [switch]$DoMirror, [string[]]$AdoptNames = @()
  )
  if ($null -eq $Exempt) { $Exempt = @{} }
  $log = New-Object System.Collections.Generic.List[string]
  $mirrored = 0; $adopted = 0; $scoped = 0; $held = 0
  $agentBk = Join-Path $Backup 'agents'
  $taskBk  = Join-Path $Backup 'scheduled-tasks'
  $skillBk = Join-Path $Backup 'skills'
  # Only ever create the mirror ROOTS. The per-file directories are created by Copy-PromptToMirror, and only
  # on the adopt path - so a -SyncMirror run cannot leave an empty scheduled-tasks\<private-task>\ behind it
  # naming a task it was never allowed to publish.
  if ($DoMirror -or (@($AdoptNames).Count)) {
    New-Item -ItemType Directory -Force $agentBk | Out-Null
    New-Item -ItemType Directory -Force $taskBk | Out-Null
  }

  foreach ($f in @(Get-ChildItem (Join-Path $Proj '*.md') -ErrorAction SilentlyContinue)) {
    $r = Copy-PromptToMirror $f.FullName (Join-Path $agentBk $f.Name) -DoMirror:$DoMirror -AdoptNames $AdoptNames -Kind 'agent' -Name $f.Name
    if ($r -eq 'refreshed') { $mirrored++; $log.Add("  mirror refreshed  agents\$($f.Name)") }
    elseif ($r -eq 'adopted') { $adopted++; $log.Add("  ADOPTED into the public mirror  agents\$($f.Name)") }
    elseif ($r -eq 'held') { $held++ }
    # project scope is canonical (it is what wins when the session sits in the project); make user match.
    # A user-scope file that does not exist is NOT created here: this mode exists to end a disagreement
    # between two live copies, not to mint a second copy of a prompt that only has one.
    if ($DoScopes) {
      $u = Join-Path $UserDir $f.Name
      if ((Test-Path $u) -and ((FileHash1 $f.FullName) -ne (FileHash1 $u))) {
        Copy-Item $f.FullName $u -Force; $scoped++
        $log.Add("  scope-synced user copy of $($f.Name) from project scope")
      }
    }
  }
  foreach ($f in @(Get-ChildItem (Join-Path $UserDir '*.md') -ErrorAction SilentlyContinue)) {
    if (Test-Path (Join-Path $Proj $f.Name)) { continue }
    $r = Copy-PromptToMirror $f.FullName (Join-Path $agentBk $f.Name) -DoMirror:$DoMirror -AdoptNames $AdoptNames -Kind 'agent' -Name $f.Name
    if ($r -eq 'refreshed') { $mirrored++; $log.Add("  mirror refreshed  agents\$($f.Name) (user scope only)") }
    elseif ($r -eq 'adopted') { $adopted++; $log.Add("  ADOPTED into the public mirror  agents\$($f.Name) (user scope only)") }
    elseif ($r -eq 'held') { $held++ }
  }
  foreach ($d in @(Get-ChildItem $Tasks -Directory -ErrorAction SilentlyContinue)) {
    $s = Join-Path $d.FullName 'SKILL.md'
    if (-not (Test-Path $s)) { continue }
    # THE EXEMPTION IS ENFORCED HERE, NOT ONLY REPORTED, AND IN EVERY MODE. Without this line the finding
    # would say "deliberately not mirrored" and the very next sync would mirror it anyway - into a public
    # repo. This loop is the only thing that can mint that leak, so this is where it is refused.
    if ($Exempt.ContainsKey('scheduled-task|' + $d.Name.ToLower())) {
      $log.Add('  skipped scheduled-tasks\' + $d.Name + '\SKILL.md - EXEMPT (' + $Exempt['scheduled-task|' + $d.Name.ToLower()] + ')')
      continue
    }
    $dst = Join-Path (Join-Path $taskBk $d.Name) 'SKILL.md'
    $r = Copy-PromptToMirror $s $dst -DoMirror:$DoMirror -AdoptNames $AdoptNames -Kind 'scheduled-task' -Name $d.Name
    if ($r -eq 'refreshed') { $mirrored++; $log.Add("  mirror refreshed  scheduled-tasks\$($d.Name)\SKILL.md") }
    elseif ($r -eq 'adopted') { $adopted++; $log.Add("  ADOPTED into the public mirror  scheduled-tasks\$($d.Name)\SKILL.md") }
    elseif ($r -eq 'held') { $held++ }
    # e.g. SKILL.monolith-fallback.md - same file, same rules, one per file
    foreach ($extra in @(Get-ChildItem (Join-Path $d.FullName '*.md') -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'SKILL.md' })) {
      $r = Copy-PromptToMirror $extra.FullName (Join-Path (Join-Path $taskBk $d.Name) $extra.Name) -DoMirror:$DoMirror -AdoptNames $AdoptNames -Kind 'scheduled-task' -Name $d.Name
      if ($r -eq 'refreshed') { $mirrored++ } elseif ($r -eq 'adopted') { $adopted++ } elseif ($r -eq 'held') { $held++ }
    }
  }
  if ($Skills) {
    foreach ($d in @(Get-ChildItem $Skills -Directory -ErrorAction SilentlyContinue)) {
      $s = Join-Path $d.FullName 'SKILL.md'
      if (-not (Test-Path $s)) { continue }
      $dst = Join-Path (Join-Path $skillBk $d.Name) 'SKILL.md'
      $r = Copy-PromptToMirror $s $dst -DoMirror:$DoMirror -AdoptNames $AdoptNames -Kind 'skill' -Name $d.Name
      if ($r -eq 'refreshed') { $mirrored++; $log.Add("  mirror refreshed  skills\$($d.Name)\SKILL.md") }
      elseif ($r -eq 'adopted') { $adopted++; $log.Add("  ADOPTED into the public mirror  skills\$($d.Name)\SKILL.md") }
      elseif ($r -eq 'held') { $held++ }
      foreach ($extra in @(Get-ChildItem (Join-Path $d.FullName '*.md') -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'SKILL.md' })) {
        $r = Copy-PromptToMirror $extra.FullName (Join-Path (Join-Path $skillBk $d.Name) $extra.Name) -DoMirror:$DoMirror -AdoptNames $AdoptNames -Kind 'skill' -Name $d.Name
        if ($r -eq 'refreshed') { $mirrored++ } elseif ($r -eq 'adopted') { $adopted++ } elseif ($r -eq 'held') { $held++ }
      }
    }
  }
  return @{ mirrored = $mirrored; adopted = $adopted; scoped = $scoped; held = $held; log = $log }
}

if ($SelfTest) {
  $fail = 0
  # THE CASE COUNT IS COUNTED, NOT TYPED (2026-09-05). The closing line read "20 prompt-backup cases" over a
  # body holding 19: a hand-maintained tally is one more copy of a fact, and the copy that nobody re-derives
  # is the one that goes stale. Same lesson as [[same-fact-published-twice]], applied to the suite's own size.
  $cases = 0
  function _C($label, $cond) { $script:cases++; if ($cond) { Write-Output "ok    $label" } else { Write-Output "FAIL  $label"; $script:fail++ } }
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

    # ---- THE WRITE MODES, SPLIT BY RISK (2026-09-05, queue 2026-09-05-5650ce) --------------------------
    # Founding case, frozen: this audit printed the same seven findings every morning for 13 days and
    # nothing moved, because its only remedy - -Sync - ALSO publishes files into a repository that loads
    # without a login, so no automation was allowed anywhere near it. The split makes the safe half
    # automatable, and these cases pin exactly where the line falls: refreshing a mirror that already
    # exists publishes nothing new, CREATING one publishes a file for the first time, and the scope follow
    # touches nothing public at all. Every mode is driven here over a temp fixture, because a repair lane
    # nobody can test is a repair lane nobody will let run unattended.
    $s2 = Join-Path $tmp 'sync'
    $sp = Join-Path $s2 'proj'; $su = Join-Path $s2 'user'; $st = Join-Path $s2 'tasks'; $sb = Join-Path $s2 'backup'
    foreach ($d in @($sp, $su, (Join-Path $st 'mirrored-task'), (Join-Path $st 'private-task'),
                     (Join-Path $sb 'agents'), (Join-Path $sb 'scheduled-tasks\mirrored-task'))) {
      New-Item -ItemType Directory -Force $d | Out-Null
    }
    Set-Content (Join-Path $sp 'drifted.md') "project v2 - edited in the repo" -Encoding UTF8   # STALE BACKUP + SCOPE DRIFT
    Set-Content (Join-Path $su 'drifted.md') "project v1" -Encoding UTF8
    Set-Content (Join-Path $sb 'agents\drifted.md') "project v1" -Encoding UTF8
    Set-Content (Join-Path $sp 'fresh.md') "a prompt that has never been mirrored" -Encoding UTF8  # NO BACKUP
    Set-Content (Join-Path $st 'mirrored-task\SKILL.md') "task v1" -Encoding UTF8
    Set-Content (Join-Path $sb 'scheduled-tasks\mirrored-task\SKILL.md') "task v1" -Encoding UTF8
    Set-Content (Join-Path $st 'private-task\SKILL.md') "private v1" -Encoding UTF8               # NO BACKUP
    $r = Compare-Prompts $sp $su $st $sb
    _C 'must-fire: before any sync the drifted agent is BOTH stale in the mirror and drifted across scopes' `
      ((($r.issues -join ' ') -match 'STALE BACKUP  agents\\drifted\.md') -and (($r.issues -join ' ') -match 'SCOPE DRIFT  drifted\.md'))
    # MUST-FIRE: -SyncMirror must never adopt. This is the line the whole split exists to draw.
    $null = Invoke-PromptSync $sp $su $st $sb '' @{} -DoMirror
    _C 'must-fire: -SyncMirror does NOT adopt a live scheduled-task SKILL that has no mirror' `
      (-not (Test-Path (Join-Path $sb 'scheduled-tasks\private-task\SKILL.md')))
    _C 'must-fire: -SyncMirror does NOT adopt a live agent prompt that has no mirror either' `
      (-not (Test-Path (Join-Path $sb 'agents\fresh.md')))
    $r = Compare-Prompts $sp $su $st $sb
    _C '  ...and both are still reported NO BACKUP afterwards, so the person still gets the decision' `
      ((($r.issues -join ' ') -match 'NO BACKUP  scheduled-tasks\\private-task') -and (($r.issues -join ' ') -match 'NO BACKUP  agents\\fresh\.md'))
    # CLEAN TWIN: the file that DOES have a mirror is refreshed by that same call, and only that half moved.
    _C 'clean twin: -SyncMirror DOES refresh a mirror that already exists (STALE BACKUP goes quiet)' `
      (($r.issues -join ' ') -notmatch 'STALE BACKUP  agents\\drifted\.md')
    _C '  ...and -SyncMirror alone leaves user scope alone (SCOPE DRIFT still reported)' `
      (($r.issues -join ' ') -match 'SCOPE DRIFT  drifted\.md')
    # MUST-FIRE then CLEAN: SCOPE DRIFT is reported before -SyncScopes and silent after - and the backup
    # directory is byte-for-byte unchanged across it, or "local only" is a claim rather than a property.
    $bkBefore = ((Get-ChildItem $sb -Recurse -File | Sort-Object FullName | ForEach-Object { $_.FullName + '|' + (FileHash1 $_.FullName) }) -join "`n")
    $null = Invoke-PromptSync $sp $su $st $sb '' @{} -DoScopes
    $r = Compare-Prompts $sp $su $st $sb
    _C 'clean twin: SCOPE DRIFT reported before -SyncScopes is silent after it' (($r.issues -join ' ') -notmatch 'SCOPE DRIFT')
    $bkAfter = ((Get-ChildItem $sb -Recurse -File | Sort-Object FullName | ForEach-Object { $_.FullName + '|' + (FileHash1 $_.FullName) }) -join "`n")
    _C '  ...and -SyncScopes wrote NOTHING into the public mirror (identical file set and hashes)' ($bkBefore -eq $bkAfter)
    # -Adopt is NAMED, so it adopts what was named and nothing else. A mode that quietly adopted its
    # neighbours would be -Sync again under a safer-sounding flag.
    $null = Invoke-PromptSync $sp $su $st $sb '' @{} -AdoptNames @('fresh.md')
    _C 'clean twin: -Adopt <name> publishes the file it names' (Test-Path (Join-Path $sb 'agents\fresh.md'))
    _C 'must-fire: -Adopt <name> publishes NOTHING ELSE (the unnamed private task stays local)' `
      (-not (Test-Path (Join-Path $sb 'scheduled-tasks\private-task\SKILL.md')))
    # CLEAN TWIN: the EXEMPT task is untouched by EVERY mode, -Sync's own -Adopt * included. The exemption
    # is the only thing standing between a personal scheduled task and a public repo, so it is asserted
    # against the mode that adopts everything, not only against the cautious ones.
    $exSync = @{ 'scheduled-task|private-task' = 'personal, carries travel dates; the mirror is public' }
    $null = Invoke-PromptSync $sp $su $st $sb '' $exSync -DoScopes -DoMirror -AdoptNames @('*')
    _C 'clean twin: an EXEMPT task is untouched by -SyncScopes, -SyncMirror AND -Adopt * (the -Sync alias)' `
      (-not (Test-Path (Join-Path $sb 'scheduled-tasks\private-task')))
    # ...and the identical call WITHOUT the exemption does publish it. Without this, the case above would
    # also pass for a mode that adopts nothing at all - a guard proving its own inaction.
    $null = Invoke-PromptSync $sp $su $st $sb '' @{} -AdoptNames @('*')
    _C '  ...and the same call with no exemption DOES adopt it, so the case above proves the exemption' `
      (Test-Path (Join-Path $sb 'scheduled-tasks\private-task\SKILL.md'))

    # BLIND: nothing to check is not a pass
    $empty = Join-Path $tmp 'empty'; New-Item -ItemType Directory -Force $empty | Out-Null
    $r = Compare-Prompts $empty $empty $empty $b $empty
    _C 'blind: zero prompts found is reported as checked=0, not as clean' ($r.checked -eq 0)
  } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  Write-Output ''
  if ($fail -gt 0) { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
  Write-Output "SELF-TEST PASS ($cases prompt-backup cases)"
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

# -Sync KEEPS ITS OLD MEANING EXACTLY: all three halves, adopt everything. Expanded here rather than left as
# a fourth code path, so there is one implementation of each write and no chance of the compatibility alias
# drifting away from the thing it aliases.
if ($Sync) { $SyncScopes = $true; $SyncMirror = $true; if (-not $Adopt -or -not @($Adopt).Count) { $Adopt = @('*') } }
$adoptList = @($Adopt | Where-Object { $_ })
if ($SyncScopes -or $SyncMirror -or $adoptList.Count) {
  $sr = Invoke-PromptSync $PROJ $USER $TASKS $backup $SKILLS $script:PromptExempt -DoScopes:$SyncScopes -DoMirror:$SyncMirror -AdoptNames $adoptList
  foreach ($l in $sr.log) { Write-Output $l }
  Write-Output ("prompt-backup: " + $sr.scoped + " user-scope copy/copies refreshed from project scope, " + $sr.mirrored + " mirror file(s) refreshed, " + $sr.adopted + " newly adopted into ops\prompt-backup")
  # ops\prompt-backup is a TRACKED path and the daily pipeline stages pipeline-owned data paths only, so a
  # mirror this run rewrote is sitting dirty in the working tree until a human commits it. Say so out loud:
  # a repair lane that leaves its repair uncommitted is the same silence this split was built to end.
  if ($sr.mirrored -or $sr.adopted) { Write-Output '  commit ops\prompt-backup - the mirror changed on disk and nothing else will stage it' }
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
# THE REMEDY IS PRINTED BY RISK, NOT AS ONE BUTTON (2026-09-05). The old line said "-Sync", and -Sync also
# mirrors files into a PUBLIC repo - so test-auditors had to counter-print "do NOT reflexively -Sync" and the
# real repair went unmade for 13 days. STALE BACKUP and SCOPE DRIFT have a safe, automated lane now.
# NO BACKUP is the one finding that still needs a person, and it says so.
Write-Output '  Fix: -SyncScopes (project -> user, local only) and -SyncMirror (refresh mirrors that already exist) are safe and run daily from capture-run.ps1; then commit ops\prompt-backup.'
if (($res.issues -join ' ') -match 'NO BACKUP') {
  Write-Output '       A NO BACKUP line is a DECISION, not a chore: adopting publishes that file into a repo that loads without a login. Adopt it deliberately (-Adopt <name>, e.g. -Adopt recipe-writer.md or -Adopt skill|recipe-hunter) or exempt it in ops\prompt-backup-exempt.json.'
}
Write-GuardComplete -Name 'prompt-backup'; exit 2
