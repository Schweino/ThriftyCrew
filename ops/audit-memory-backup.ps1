<#
  audit-memory-backup.ps1 - the agent memory store is DATA THIS ESTATE REASONS FROM. Version it, prove the
  history is current, and prove it never reaches the public repo.

  WHY (2026-09-03). Two things happened on the same day.

  FIRST, a memory file was destroyed by an ordinary edit. Repairing three mojibake characters, a string
  replacement went through the shell mis-encoded and performed a GLOBAL single-character substitution
  instead: every 'r' became a different character in budget-tracker.md, and every 'M' became 'e' in
  grocery-browser-exfil.md. 2,035 characters damaged by a 3-character repair. Both writes reported success,
  neither changed the file SIZE, and nothing versioned the directory - so recovery meant reconstructing the
  content out of session transcripts and proving the restore by replaying the damage onto it. With a history
  that is a checkout.

  SECOND, the obvious fix was nearly the wrong one. ops\prompt-backup mirrors the agent prompts INTO this
  repo, so mirroring memory the same way looks like the answer. It is not: this repo is PUBLIC (verified by
  an unauthenticated GitHub API call returning private=False), and the memory store carries the business's
  cost and revenue notes, account identifiers and contact addresses. So memory gets its OWN git history,
  local, with NO REMOTE, and this guard exists as much to keep it out of the public repo as to keep it
  backed up. Those are the same job: "memory and git must not drift" cuts both ways.

  Six checks:
    1. HISTORY EXISTS   - the memory directory is a git repository at all
    2. NO REMOTE        - it has no push target, so it cannot leak to a public host
    3. NOT IN THIS REPO - no memory file is tracked by ThriftyCrew
    4. HISTORY CURRENT  - no uncommitted memory changes (-Sync commits them)
    5. INDEX INTEGRITY  - MEMORY.md and the files on disk agree: no links to files that are gone, no
                          duplicate links, and every memo REACHABLE - named by MEMORY.md, or linked as
                          [[slug]] by a memo MEMORY.md names. Reachability, not flat listing: hub routing
                          is the store's documented convention (2026-09-05, queue 2026-09-05-e42efd)
    6. ENCODING INTACT  - no mojibake, the founding damage of this guard
  Exit 0 clean, 2 a real finding, 3 BLIND (nothing to check - a pass that proves nothing).
  -Sync commits pending memory changes, then re-checks. -SelfTest runs frozen fixtures.
#>
param([switch]$Sync, [switch]$SelfTest, [string]$MemoryDir = '')
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$REPO = 'C:\Codex\ThriftyCrew'
if (-not $MemoryDir) { $MemoryDir = 'C:\Users\Owner\.claude\projects\C--Codex\memory' }

# Mojibake is UTF-8 bytes decoded as Windows-1252. Built from CODEPOINTS, never typed: a literal non-ASCII
# needle is re-encoded on its way through the shell, which is the exact mechanism that caused the damage
# this guard was written about.
$MOJI = @(
  ([string][char]0x00E2 + [char]0x20AC + [char]0x2122),   # mangled right single quote
  ([string][char]0x00E2 + [char]0x20AC + [char]0x201C),   # mangled left double quote
  ([string][char]0x00C3 + [char]0x00A9),                  # mangled e-acute
  ([string][char]0x00C3 + [char]0x00B1)                   # mangled n-tilde
)

function Get-GitOut([string]$Dir, [string]$GitArgs) {
  # Read the process stream, never `| Out-String`: PowerShell rejoins native output with CRLF, which on
  # 2026-09-03 added 393 bytes to a 28,965-byte file and silently disabled a comparison in another guard.
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'git'
  $psi.Arguments = ('-C "' + $Dir + '" ' + $GitArgs)
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
  $p = [System.Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEnd(); $null = $p.StandardError.ReadToEnd(); $p.WaitForExit()
  return [pscustomobject]@{ Text = $out; Code = $p.ExitCode }
}

function Test-MemoryStore {
  param([string]$Dir)
  $issues = New-Object System.Collections.Generic.List[string]
  $checked = 0

  if (-not (Test-Path $Dir)) { return @{ rc = 3; issues = @("the memory directory does not exist: $Dir"); checked = 0 } }
  $files = @(Get-ChildItem $Dir -Filter '*.md' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'MEMORY.md' })
  $indexPath = Join-Path $Dir 'MEMORY.md'
  if (-not (Test-Path $indexPath)) { return @{ rc = 3; issues = @('no MEMORY.md - there is no index to check the store against'); checked = 0 } }
  if ($files.Count -eq 0) { return @{ rc = 3; issues = @('zero memory files - a clean result here would prove nothing'); checked = 0 } }

  # 1. HISTORY EXISTS
  $checked++
  if (-not (Test-Path (Join-Path $Dir '.git'))) {
    $issues.Add('the memory store is NOT a git repository - one bad write is unrecoverable, which is the failure this guard exists for')
    return @{ rc = 2; issues = $issues; checked = $checked }
  }

  # 2. NO REMOTE. A remote is how this ends up somewhere public.
  $checked++
  $rem = Get-GitOut $Dir 'remote -v'
  if (($rem.Text).Trim()) {
    $issues.Add('the memory store has a git REMOTE configured, so it can be pushed off this machine: ' + (($rem.Text).Trim() -replace "\r?\n", ' / ') + ' - memory carries cost, revenue and account notes and must stay local')
  }

  # 3. NOT TRACKED BY THE PUBLIC REPO
  $checked++
  if (Test-Path (Join-Path $REPO '.git')) {
    $tracked = Get-GitOut $REPO 'ls-files'
    $leak = @(($tracked.Text -split "`r?`n") | Where-Object { $_ -match 'projects/C--Codex/memory/' })
    if ($leak.Count) { $issues.Add(("$($leak.Count) memory file(s) are TRACKED BY THE PUBLIC ThriftyCrew REPO, e.g. " + ($leak[0]))) }
  }

  # 4. HISTORY CURRENT
  $checked++
  $st = Get-GitOut $Dir 'status --porcelain'
  $dirty = @(($st.Text -split "`r?`n") | Where-Object { $_.Trim() })
  if ($dirty.Count) {
    $issues.Add("$($dirty.Count) memory file(s) are uncommitted, so the history does not hold what the store currently says - run with -Sync")
  }

  # 5. INDEX INTEGRITY
  $checked++
  $idx = [IO.File]::ReadAllText($indexPath, [Text.Encoding]::UTF8) -split "`r?`n"
  $linked = @()
  foreach ($l in $idx) { $m = [regex]::Match($l, '\]\(([^)]+\.md)\)'); if ($m.Success) { $linked += $m.Groups[1].Value } }
  $names = @($files | ForEach-Object { $_.Name })
  $orphans   = @($linked | Where-Object { $names -notcontains $_ })
  $dupes     = @($linked | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })

  # ---- THE CENSUS MEASURES REACHABILITY, NOT DIRECT LISTING (2026-09-05, queue 2026-09-05-e42efd) ------
  # This arm used to ask "does MEMORY.md hold a line for this file", and report every file that did not.
  # On 2026-09-05 it reported 64 files "recall will never surface" and ALL SIXTY-FOUR were wrong: every one
  # of them is one [[wikilink]] hop from a memo MEMORY.md does index. True orphans: 0.
  # The store deliberately stopped honouring the flat-listing contract when HUB memos were introduced, and
  # MEMORY.md's own opening lines say so: "Hub memos carry a Routed from the index section listing sibling
  # memos that no longer hold their own line here. Every memo is still its own file; follow the hub to reach
  # it." The check was never taught the new convention, so it measured listing and called it reachability.
  # The perverse part, and the reason this had to be fixed rather than muted: it got LOUDER the more
  # correctly the store was consolidated. Every memo routed into a hub added one to its count, so keeping
  # the store tidy guaranteed the alert fired forever. A guard that punishes the maintenance it exists to
  # protect gets ignored, and then it is not a guard.
  # ONE HOP ONLY, deliberately. A memo reachable only from a memo that is itself unindexed is still
  # reported, and that is correct: two hops is not recall, it is a chain nobody follows.
  # The counts are reported SEPARATELY (direct / via a hub) so a hub that stops routing its children is
  # still visible - the number that would move is the hub count, and a reader can see it move.
  $hubbed = @{}
  foreach ($l in (@($linked | Sort-Object -Unique))) {
    $p = Join-Path $Dir $l
    if (-not (Test-Path $p)) { continue }
    $t = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
    # [[slug]], [[slug.md]] and [[slug|label]] all name the same memo. The alias and anchor forms are
    # stripped rather than ignored, or a hub that labels its links would read as routing nothing.
    foreach ($m in [regex]::Matches($t, '\[\[([^\]\|#]+?)(?:[|#][^\]]*)?\]\]')) {
      $s = $m.Groups[1].Value.Trim()
      if (-not $s) { continue }
      if ($s -notmatch '(?i)\.md$') { $s = $s + '.md' }
      $hubbed[$s] = $true
    }
  }
  $directCount = @($names | Where-Object { $linked -contains $_ }).Count
  $hubCount    = @($names | Where-Object { ($linked -notcontains $_) -and $hubbed.ContainsKey($_) }).Count
  $unreachable = @($names | Where-Object { ($linked -notcontains $_) -and (-not $hubbed.ContainsKey($_)) })

  if ($orphans.Count)     { $issues.Add("MEMORY.md links $($orphans.Count) file(s) that do not exist: " + (($orphans | Select-Object -First 5) -join ', ')) }
  if ($unreachable.Count) { $issues.Add("$($unreachable.Count) memory file(s) are in no index line and are linked from no indexed memo either, so recall will never surface them: " + (($unreachable | Select-Object -First 5) -join ', ')) }
  if ($dupes.Count)       { $issues.Add("MEMORY.md links the same file more than once: " + (($dupes | Select-Object -First 5) -join ', ')) }

  # 6. ENCODING INTACT - the founding damage
  $checked++
  $bad = New-Object System.Collections.Generic.List[string]
  foreach ($f in @($files + @(Get-Item $indexPath))) {
    $t = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
    foreach ($seq in $MOJI) { if ($t.Contains($seq)) { $bad.Add($f.Name); break } }
  }
  if ($bad.Count) { $issues.Add("$($bad.Count) memory file(s) carry mojibake (UTF-8 read as ANSI): " + (($bad | Select-Object -First 5) -join ', ')) }

  return @{ rc = $(if ($issues.Count) { 2 } else { 0 }); issues = $issues; checked = $checked; files = $files.Count
            direct = $directCount; hub = $hubCount; unreachable = $unreachable.Count }
}

# ------------------------------------------------------------------ self-test
if ($SelfTest) {
  $fail = 0
  # Counted, not typed: a hand-maintained case tally is one more copy of a fact, and it is always the copy
  # nobody re-derives that goes stale.
  $cases = 0
  function T([string]$label, [bool]$cond, [string]$detail) {
    $script:cases++
    if ($cond) { Write-Output "ok    $label" } else { Write-Output "FAIL  $label  - $detail"; $script:fail++ } }

  $fx = Join-Path $env:TEMP ('memaudit-selftest-' + $PID)
  function NewStore {
    if (Test-Path $fx) { Remove-Item $fx -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $fx | Out-Null
    Set-Content (Join-Path $fx 'alpha.md') "---`nname: alpha`n---`nbody" -Encoding UTF8
    Set-Content (Join-Path $fx 'beta.md')  "---`nname: beta`n---`nbody" -Encoding UTF8
    Set-Content (Join-Path $fx 'MEMORY.md') "- [Alpha](alpha.md) - a`n- [Beta](beta.md) - b" -Encoding UTF8
    $null = Get-GitOut $fx 'init'
    $null = Get-GitOut $fx 'config user.name t'
    $null = Get-GitOut $fx 'config user.email t@t'
    $null = Get-GitOut $fx 'add -A'
    $null = Get-GitOut $fx 'commit -m base'
  }

  # CLEAN TWIN: a healthy store passes. Without this the must-fires prove only that it says no to everything.
  NewStore
  $r = Test-MemoryStore $fx
  T 'CLEAN TWIN a committed, fully indexed, well-encoded store passes' ($r.rc -eq 0) ("rc=$($r.rc) " + ($r.issues -join '; '))

  # MUST-FIRE 1: no history at all - the founding condition, an unrecoverable store
  NewStore; Remove-Item (Join-Path $fx '.git') -Recurse -Force
  $r = Test-MemoryStore $fx
  T 'MUST-FIRE a store with no git history is reported' (($r.rc -eq 2) -and (($r.issues -join ' ') -match 'NOT a git repository')) ("rc=$($r.rc)")

  # MUST-FIRE 2: a REMOTE - the leak path this guard exists to block
  NewStore; $null = Get-GitOut $fx 'remote add origin https://github.com/someone/public.git'
  $r = Test-MemoryStore $fx
  T 'MUST-FIRE a configured remote is reported as a leak path' (($r.rc -eq 2) -and (($r.issues -join ' ') -match 'REMOTE')) ("rc=$($r.rc)")

  # MUST-FIRE 3: uncommitted change - the history no longer holds what the store says
  NewStore; Add-Content (Join-Path $fx 'alpha.md') 'edited after the commit'
  $r = Test-MemoryStore $fx
  T 'MUST-FIRE an uncommitted memory edit is reported' (($r.rc -eq 2) -and (($r.issues -join ' ') -match 'uncommitted')) ("rc=$($r.rc)")

  # MUST-FIRE 4: an unindexed file - present on disk, invisible to recall
  NewStore; Set-Content (Join-Path $fx 'gamma.md') 'x' -Encoding UTF8; $null = Get-GitOut $fx 'add -A'; $null = Get-GitOut $fx 'commit -m g'
  $r = Test-MemoryStore $fx
  T 'MUST-FIRE a file in no index line is reported' (($r.rc -eq 2) -and (($r.issues -join ' ') -match 'no index line')) ("rc=$($r.rc)")

  # MUST-FIRE 5: an orphan index line - a link to a file that is gone
  NewStore; Remove-Item (Join-Path $fx 'beta.md'); $null = Get-GitOut $fx 'add -A'; $null = Get-GitOut $fx 'commit -m rm'
  $r = Test-MemoryStore $fx
  T 'MUST-FIRE an index line pointing at a missing file is reported' (($r.rc -eq 2) -and (($r.issues -join ' ') -match 'do not exist')) ("rc=$($r.rc)")

  # MUST-FIRE 6: MOJIBAKE - the damage that caused this guard to be written
  NewStore
  $moji = 'Member' + [string][char]0x00E2 + [char]0x20AC + [char]0x2122 + 's Mark'
  [IO.File]::WriteAllText((Join-Path $fx 'alpha.md'), $moji, (New-Object System.Text.UTF8Encoding($false)))
  $null = Get-GitOut $fx 'add -A'; $null = Get-GitOut $fx 'commit -m moji'
  $r = Test-MemoryStore $fx
  T 'MUST-FIRE mojibake in a memory file is reported' (($r.rc -eq 2) -and (($r.issues -join ' ') -match 'mojibake')) ("rc=$($r.rc)")

  # ---- HUB ROUTING (2026-09-05, queue 2026-09-05-e42efd) ----------------------------------------------
  # FOUNDING BUG, frozen: the census asked whether MEMORY.md held a LINE for each file and called the answer
  # reachability. On 2026-09-05 it named 64 files "recall will never surface" and every one of them was one
  # [[wikilink]] hop from an indexed memo - the store's own documented hub convention. True orphans: 0.
  # This fixture is that shape at minimum size: an indexed hub, a child the hub routes, and a memo nothing
  # points at. The CLEAN TWIN is the same store with the lonely memo deleted - today's code reports 1 there,
  # which is exactly the false positive, so that twin is the case that could not have passed before.
  function NewHubStore([bool]$WithLonely) {
    if (Test-Path $fx) { Remove-Item $fx -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $fx | Out-Null
    Set-Content (Join-Path $fx 'MEMORY.md') "Hub memos route siblings that no longer hold their own line here.`n`n- [Hub](hub.md) - the family index" -Encoding UTF8
    Set-Content (Join-Path $fx 'hub.md') "Routed from the index:`n`n- [[child]] - the routed sibling" -Encoding UTF8
    Set-Content (Join-Path $fx 'child.md') 'holds no line in MEMORY.md; reached through its hub' -Encoding UTF8
    if ($WithLonely) { Set-Content (Join-Path $fx 'lonely.md') 'nothing points at this one' -Encoding UTF8 }
    $null = Get-GitOut $fx 'init'
    $null = Get-GitOut $fx 'config user.name t'
    $null = Get-GitOut $fx 'config user.email t@t'
    $null = Get-GitOut $fx 'add -A'
    $null = Get-GitOut $fx 'commit -m hub'
  }

  NewHubStore $true
  $r = Test-MemoryStore $fx
  T 'MUST-FIRE a memo that neither MEMORY.md nor any indexed memo links is reported, BY NAME' `
    (($r.rc -eq 2) -and (($r.issues -join ' ') -match 'lonely\.md') -and ([int]$r.unreachable -eq 1)) `
    ("rc=$($r.rc) unreachable=$($r.unreachable) " + ($r.issues -join '; '))
  T '  ...and the hub-routed child is NOT reported - it is counted as reached in one hop' `
    ((($r.issues -join ' ') -notmatch 'child\.md') -and ([int]$r.hub -eq 1) -and ([int]$r.direct -eq 1)) `
    ("direct=$($r.direct) hub=$($r.hub) " + ($r.issues -join '; '))

  NewHubStore $false
  $r = Test-MemoryStore $fx
  T 'CLEAN TWIN a store whose only unindexed memo is hub-routed reports ZERO findings (today it reports 1)' `
    (($r.rc -eq 0) -and ([int]$r.unreachable -eq 0)) ("rc=$($r.rc) " + ($r.issues -join '; '))

  # BLIND: an empty store must never read as clean
  if (Test-Path $fx) { Remove-Item $fx -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $fx | Out-Null
  Set-Content (Join-Path $fx 'MEMORY.md') '' -Encoding UTF8
  $r = Test-MemoryStore $fx
  T 'BLIND a store with zero memory files reports rc 3, never a clean pass' ($r.rc -eq 3) ("rc=$($r.rc)")

  if (Test-Path $fx) { Remove-Item $fx -Recurse -Force -ErrorAction SilentlyContinue }
  if ($fail -gt 0) { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
  Write-Output "SELF-TEST PASS ($cases memory-store cases)"
  exit 0
}

# ------------------------------------------------------------------ live
if ($Sync) {
  if (Test-Path (Join-Path $MemoryDir '.git')) {
    $st = Get-GitOut $MemoryDir 'status --porcelain'
    if ((($st.Text) -split "`r?`n" | Where-Object { $_.Trim() }).Count) {
      $null = Get-GitOut $MemoryDir 'add -A'
      $msg = 'Memory sync ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')
      $c = Get-GitOut $MemoryDir ('commit -m "' + $msg + '"')
      Write-Output ('memory-backup: committed pending memory changes (' + $msg + ')')
    } else { Write-Output 'memory-backup: nothing to commit' }
  } else { Write-Output 'memory-backup: -Sync cannot commit - the store is not a git repository yet' }
}

$res = Test-MemoryStore $MemoryDir
Write-Output ("memory-backup: {0} memory file(s), {1} check(s) run against {2}" -f [int]$res.files, [int]$res.checked, $MemoryDir)
# THE TWO ROUTES ARE PRINTED SEPARATELY, CLEAN OR NOT (2026-09-05). Hub routing is the store's convention,
# so "reached via a hub" is a normal, healthy number - but it is also the number that would fall if a hub
# stopped routing its children, and a count nobody prints is a change nobody sees.
if ($null -ne $res.direct) {
  Write-Output ("  index: {0} memo(s) named directly in MEMORY.md, {1} reached in one hop from a hub memo it names, {2} reachable by neither" -f [int]$res.direct, [int]$res.hub, [int]$res.unreachable)
}
if ($res.rc -eq 3) {
  foreach ($i in $res.issues) { Write-Output ('  BLIND  ' + $i) }
  Write-GuardComplete -Name 'memory-backup' -Summary 'blind'
  exit 3
}
if ($res.issues.Count -eq 0) {
  Write-Output '  ok - the memory store is versioned locally, has no remote, is absent from the public repo, is fully committed, its index agrees with the files on disk, and nothing is mojibaked'
  Write-GuardComplete -Name 'memory-backup' -Summary ("files={0} clean" -f [int]$res.files)
  exit 0
}
foreach ($i in $res.issues) { Write-Output ('  ' + $i) }
Write-Output '  Fix: run this with -Sync to commit pending memory changes. A remote, or a memory file tracked by ThriftyCrew, must be removed by hand - that repo is PUBLIC.'
Write-GuardComplete -Name 'memory-backup' -Summary ("files={0} issues={1}" -f [int]$res.files, $res.issues.Count)
exit 2
