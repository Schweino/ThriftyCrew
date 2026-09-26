<#
  publish-journal.ps1 - the ONE writer of db\published-hashes.json entries that record what is live.

  WHY THIS EXISTS (2026-09-26). The publish journal is GITIGNORED, so it reaches a checkout only by copy, and a
  publish from a linked worktree (.claude\worktrees\<name>) wrote only THAT worktree's copy. On 2026-09-22 23:43 and
  2026-09-23 08:26 two worktree publishes put 13 recipes live and journalled them where nothing else reads. The main
  checkout kept the older hashes, so on 2026-09-26 publish.ps1's live-drift guard read all 13 as "changed outside
  this journal" and refused them. Every one was our own verified publish (its live hash was in a worktree journal).
  A second half of the same defect: publish.ps1 wrote the whole in-memory journal with Set-Content, no lock, from a
  copy it read at start, so two publishers on one checkout each erased the other's entries (a lost update).

  THE RULE. A caller passes only the keys IT changed (-Set slug=hash, -Remove slug). For each target file, one at a
  time and never nested: take the ledger lock (lib\ledger-lock.ps1), READ the file inside the lock, apply only those
  keys, replace it with Write-TcAtomicFile (lib\atomic-write.ps1), release. The targets are the caller's own journal
  and, when the caller's journal sits inside a LINKED worktree, the same repo-relative path under the MAIN checkout
  (lib\main-checkout.ps1). From the main checkout, or from a directory git cannot see (a self-test sandbox), the only
  target is the caller's own file.

  A MIRROR FAILURE NEVER FAILS THE CALLER. The local write keeps the caller's old semantics (publish.ps1 warns and
  carries on), and a main-checkout write that cannot happen is REPORTED in .mirror so the caller can say so; the
  entry is still in the worktree journal and reconcile-publish-journal.ps1's journal-elsewhere proof recovers it.

  Idempotent: setting the same key to the same hash twice leaves identical bytes, so a retry is safe.
  Lock order (ops rule og-27, level 4): one ledger lock at a time, local first, then main; never both held.

  Dot-source:  . (Join-Path $repoRoot 'meal-prep\lib\publish-journal.ps1')
  Self-test:   powershell -NoProfile -File meal-prep\lib\publish-journal.ps1 -SelfTest

  NO param() BLOCK, DELIBERATELY - dot-sourced under PS 5.1 a param() block runs in the CALLER's scope.
#>
# gate-inputs: lib\*.ps1
$__pjSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')
$__pjRepo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $__pjRepo 'lib\ledger-lock.ps1')
. (Join-Path $__pjRepo 'lib\atomic-write.ps1')
. (Join-Path $__pjRepo 'lib\main-checkout.ps1')

function Read-TcPublishJournal {
  <# The journal at $Path as an ordered slug -> hash map. A missing or empty file is an empty map. Throws on a file
     that exists and does not parse: a writer must never replace a journal it could not read. #>
  param([Parameter(Mandatory = $true)][string]$Path)
  $m = [ordered]@{}
  if (-not (Test-Path -LiteralPath $Path)) { return $m }
  $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
  if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
  if (-not $raw.Trim()) { return $m }
  $o = $raw | ConvertFrom-Json
  foreach ($p in $o.PSObject.Properties) { $m[[string]$p.Name] = [string]$p.Value }
  return $m
}

function Update-TcPublishJournal {
  <# Read-modify-write of ONE journal under its ledger lock. Returns the number of keys that changed. Throws when the
     lock cannot be taken or the file cannot be read or written; nothing is written in that case. #>
  param([Parameter(Mandatory = $true)][string]$Path, [hashtable]$Set = @{}, [string[]]$Remove = @())
  $lock = Enter-TcLedgerLock -Path $Path
  try {
    $j = Read-TcPublishJournal -Path $Path
    $changed = 0
    foreach ($k in @($Set.Keys)) {
      $v = [string]$Set[$k]
      if (-not $j.Contains([string]$k) -or -not [string]::Equals([string]$j[[string]$k], $v, [StringComparison]::Ordinal)) { $j[[string]$k] = $v; $changed++ }
    }
    foreach ($k in @($Remove | Where-Object { $_ })) { if ($j.Contains([string]$k)) { $j.Remove([string]$k); $changed++ } }
    if ($changed -gt 0 -or -not (Test-Path -LiteralPath $Path)) {
      $dir = Split-Path -Parent $Path
      if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop) }
      # The byte shape publish.ps1's Set-Content -Encoding UTF8 wrote (BOM, trailing newline), so readers see no change.
      [void](Write-TcAtomicFile -Path $Path -Text ([pscustomobject]$j | ConvertTo-Json))
    }
    return $changed
  } finally { Exit-TcLedgerLock $lock }
}

function Get-TcPublishJournalMirror {
  <# The main checkout's copy of $JournalPath when $JournalPath sits in a LINKED worktree, else ''. #>
  param([Parameter(Mandatory = $true)][string]$JournalPath)
  $full = [IO.Path]::GetFullPath($JournalPath)
  $dir = Split-Path -Parent $full
  while ($dir -and -not (Test-Path -LiteralPath $dir)) { $dir = Split-Path -Parent $dir }
  if (-not $dir) { return '' }
  $r = Resolve-TcMainQueueFile -Dir $dir -LocalQueue $full
  if (-not $r.routed) { return '' }
  if ([string]::Equals([IO.Path]::GetFullPath($r.path), $full, [StringComparison]::OrdinalIgnoreCase)) { return '' }
  return [string]$r.path
}

function Save-TcPublishJournal {
  <# Applies -Set/-Remove to the caller's journal and to its main-checkout mirror. Never throws.
     Returns [pscustomobject]@{ local; localError; mirror; mirrorPath; mirrorError }. #>
  param([Parameter(Mandatory = $true)][string]$JournalPath, [hashtable]$Set = @{}, [string[]]$Remove = @(), [switch]$NoMirror)
  $res = [pscustomobject]@{ local = 0; localError = ''; mirror = 0; mirrorPath = ''; mirrorError = '' }
  try { $res.local = Update-TcPublishJournal -Path $JournalPath -Set $Set -Remove $Remove } catch { $res.localError = $_.Exception.Message }
  if ($NoMirror) { return $res }
  try { $res.mirrorPath = Get-TcPublishJournalMirror -JournalPath $JournalPath } catch { $res.mirrorError = ('could not name the main checkout: ' + $_.Exception.Message); return $res }
  if (-not $res.mirrorPath) { return $res }
  try { $res.mirror = Update-TcPublishJournal -Path $res.mirrorPath -Set $Set -Remove $Remove } catch { $res.mirrorError = $_.Exception.Message }
  return $res
}

if ($__pjSelfTest) {
  $ErrorActionPreference = 'Stop'
  $script:pjN = 0; $script:pjBad = 0
  function PjCase([string]$Name, [bool]$Ok, [string]$Got) {
    $script:pjN++
    if ($Ok) { Write-Output ('  ok    ' + $Name) } else { $script:pjBad++; Write-Output ('  X     ' + $Name + '   got: ' + $Got) }
  }
  . (Join-Path $__pjRepo 'lib\git-repo-env.ps1'); Clear-TcGitRepoEnv
  $pjRoot = Join-Path ([IO.Path]::GetTempPath()) ('tc-pj-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  $pjMain = Join-Path $pjRoot 'main'; $pjWt = Join-Path $pjRoot 'wt'; $pjPlain = Join-Path $pjRoot 'plain'
  $rel = 'meal-prep\db\published-hashes.json'
  try {
    [void](New-Item -ItemType Directory -Path (Join-Path $pjMain 'meal-prep\db') -Force -ErrorAction Stop)
    [void](New-Item -ItemType Directory -Path (Join-Path $pjPlain 'meal-prep\db') -Force -ErrorAction Stop)
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
      & git -C $pjMain init -q 2>$null | Out-Null
      & git -C $pjMain -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>$null | Out-Null
      & git -C $pjMain worktree add -q $pjWt 2>$null | Out-Null
    } finally { $ErrorActionPreference = $prevEap }
    [void](New-Item -ItemType Directory -Path (Join-Path $pjWt 'meal-prep\db') -Force -ErrorAction Stop)
    $mainJ = Join-Path $pjMain $rel; $wtJ = Join-Path $pjWt $rel; $plainJ = Join-Path $pjPlain $rel
    [IO.File]::WriteAllText($mainJ, '{"old-slug":"H-MAIN-OLD","other":"H-OTHER"}', [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($wtJ, '{"old-slug":"H-MAIN-OLD","other":"H-STALE-COPY"}', [Text.Encoding]::UTF8)

    # MUST FIRE - the founding bug: a publish from a linked worktree leaves the main checkout's journal stale.
    $r = Save-TcPublishJournal -JournalPath $wtJ -Set @{ 'old-slug' = 'H-NEW' }
    $m = Read-TcPublishJournal -Path $mainJ
    PjCase 'MUST FIRE  a worktree save writes the entry into the MAIN checkout journal' (([string]$m['old-slug']) -ceq 'H-NEW') ("main has " + $m['old-slug'] + ' mirrorPath=' + $r.mirrorPath + ' err=' + $r.mirrorError)
    PjCase 'MUST FIRE  ...and names the main journal as the mirror it wrote' ($r.mirror -eq 1 -and [string]::Equals([IO.Path]::GetFullPath($r.mirrorPath), [IO.Path]::GetFullPath($mainJ), [StringComparison]::OrdinalIgnoreCase)) ($r | ConvertTo-Json -Compress)
    # CLEAN TWIN - only the touched key crosses: the worktree's stale copy of an UNTOUCHED key must not overwrite main's.
    PjCase 'CLEAN TWIN  an untouched key keeps the MAIN value, not the worktree copy' (([string]$m['other']) -ceq 'H-OTHER') ("main other=" + $m['other'])
    $w = Read-TcPublishJournal -Path $wtJ
    PjCase 'CLEAN TWIN  the worktree journal itself took the entry and kept its other keys' ((([string]$w['old-slug']) -ceq 'H-NEW') -and (([string]$w['other']) -ceq 'H-STALE-COPY')) ($w | ConvertTo-Json -Compress)

    # MUST FIRE - the lost update: another writer adds a key after this caller loaded its copy; the save must keep it,
    # because the read happens inside the lock and only the caller's own keys are applied.
    [IO.File]::WriteAllText($mainJ, '{"old-slug":"H-NEW","other":"H-OTHER","written-meanwhile":"H-THEIRS"}', [Text.Encoding]::UTF8)
    $null = Save-TcPublishJournal -JournalPath $wtJ -Set @{ 'second' = 'H-2' }
    $m = Read-TcPublishJournal -Path $mainJ
    PjCase 'MUST FIRE  a key another writer added since is kept (read inside the lock, merge not overwrite)' ((([string]$m['written-meanwhile']) -ceq 'H-THEIRS') -and (([string]$m['second']) -ceq 'H-2')) ($m | ConvertTo-Json -Compress)

    # -Remove crosses too (a hold or a retire taken from a worktree).
    $null = Save-TcPublishJournal -JournalPath $wtJ -Remove @('second')
    $m = Read-TcPublishJournal -Path $mainJ
    PjCase 'MUST FIRE  a removal from a worktree removes the key in main too' (-not $m.Contains('second')) ($m | ConvertTo-Json -Compress)

    # MUST NOT FIRE - from the main checkout itself there is no mirror, and a directory git cannot see has none either.
    $before = [IO.File]::ReadAllBytes($wtJ)
    $r2 = Save-TcPublishJournal -JournalPath $mainJ -Set @{ 'main-only' = 'H-M' }
    PjCase 'MUST NOT FIRE  a save FROM the main checkout names no mirror' (-not $r2.mirrorPath -and $r2.local -eq 1) ($r2 | ConvertTo-Json -Compress)
    PjCase 'MUST NOT FIRE  ...and leaves the worktree journal byte-identical' ([Convert]::ToBase64String($before) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($wtJ))) 'worktree journal changed'
    $r3 = Save-TcPublishJournal -JournalPath $plainJ -Set @{ 'sandbox' = 'H-S' }
    PjCase 'MUST NOT FIRE  a sandbox outside git writes only its own file' (-not $r3.mirrorPath -and ([string](Read-TcPublishJournal -Path $plainJ)['sandbox']) -ceq 'H-S') ($r3 | ConvertTo-Json -Compress)
    $r4 = Save-TcPublishJournal -JournalPath $wtJ -Set @{ 'nomirror' = 'H-N' } -NoMirror
    PjCase 'MUST NOT FIRE  -NoMirror keeps the write in the worktree' (-not (Read-TcPublishJournal -Path $mainJ).Contains('nomirror') -and $r4.local -eq 1) ($r4 | ConvertTo-Json -Compress)

    # CLEAN TWIN - byte shape: BOM + JSON + newline, the shape Set-Content -Encoding UTF8 wrote, and it parses back.
    $b = [IO.File]::ReadAllBytes($mainJ)
    PjCase 'CLEAN TWIN  the written journal keeps the BOM and parses back' (($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) -and ((Read-TcPublishJournal -Path $mainJ).Count -ge 4)) ('first bytes ' + $b[0] + ',' + $b[1])
    # CLEAN TWIN - an identical re-save changes nothing and reports 0 (idempotent retry).
    $r5 = Save-TcPublishJournal -JournalPath $wtJ -Set @{ 'old-slug' = 'H-NEW' }
    PjCase 'CLEAN TWIN  re-saving the same hash is a no-op on both files' ($r5.local -eq 0 -and $r5.mirror -eq 0 -and -not $r5.mirrorError) ($r5 | ConvertTo-Json -Compress)

    # MUST FIRE - a journal that does not parse is never replaced; the caller hears about it.
    [IO.File]::WriteAllText($plainJ, '{ not json', [Text.Encoding]::UTF8)
    $r6 = Save-TcPublishJournal -JournalPath $plainJ -Set @{ 'x' = 'y' }
    PjCase 'MUST FIRE  an unreadable journal is reported and left exactly as it was' (($r6.localError -ne '') -and ([IO.File]::ReadAllText($plainJ) -ceq '{ not json')) ($r6 | ConvertTo-Json -Compress)

    # MUST FIRE - the lock is real: held from another process, the write waits past a short timeout and refuses.
    $lockName = Get-TcLedgerLockName -Path $mainJ
    $holder = Join-Path $pjRoot 'hold.ps1'; $stop = Join-Path $pjRoot 'stop'; $ready = Join-Path $pjRoot 'ready'
    [IO.File]::WriteAllText($holder, ("`$m = New-Object System.Threading.Mutex(`$false, '" + $lockName + "'); [void]`$m.WaitOne(); [IO.File]::WriteAllText('" + $ready + "', 'r'); while (-not (Test-Path '" + $stop + "')) { Start-Sleep -Milliseconds 50 }; `$m.ReleaseMutex()"), [Text.Encoding]::UTF8)
    $hp = Start-Process -FilePath (Get-Command powershell).Source -ArgumentList @('-NoProfile', '-File', $holder) -PassThru -WindowStyle Hidden
    try {
      $deadline = (Get-Date).AddSeconds(60)
      while (-not (Test-Path $ready) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
      # Update-TcPublishJournal waits the library's default (minutes); the same lock with a short timeout keeps this fast.
      $threw2 = ''
      try { $l = Enter-TcLedgerLock -Path $mainJ -TimeoutMs 300; Exit-TcLedgerLock $l } catch { $threw2 = $_.Exception.Message }
      PjCase 'MUST FIRE  the journal lock is the ledger lock: held elsewhere, a writer is refused' ((Test-Path $ready) -and ($threw2 -match 'could not take the lock')) ('ready=' + (Test-Path $ready) + ' threw=' + $threw2)
    } finally { [IO.File]::WriteAllText($stop, 's'); if (-not $hp.WaitForExit(30000)) { $hp.Kill() } }
  } catch {
    $script:pjBad++; Write-Output ('  X     self-test threw: ' + $_.Exception.Message)
  } finally {
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & git -C $pjMain worktree remove --force $pjWt 2>$null | Out-Null } catch {} finally { $ErrorActionPreference = $prevEap }
    Remove-Item -LiteralPath $pjRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($script:pjN -ne 14) { $script:pjBad++; Write-Output ('  X     expected 14 cases, ran ' + $script:pjN) }
  if ($script:pjBad -eq 0) { Write-Output ('publish-journal self-test pass: ' + $script:pjN + ' of ' + $script:pjN + ' cases'); exit 0 }
  Write-Output ('publish-journal self-test FAILED: ' + $script:pjBad + ' of ' + $script:pjN + ' cases'); exit 1
}
