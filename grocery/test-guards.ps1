<#
  test-guards.ps1 - negative tests. A guard that cannot fail is worthless, so break each invariant on
  purpose, assert guards.ps1 exits 2, then restore and assert it exits 0 again.
  Every mutation is made on a COPY-then-restore basis; nothing is left changed.
#>
param([switch]$SelfTest, [switch]$AllowLiveTree)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root = $PSScriptRoot
$pass = 0; $failed = 0

# ---- CRASH-SAFE RESTORE (2026-07-28) -------------------------------------------------------------------
# This suite tests by BREAKING live production files and putting them back: 16 mutation windows, 13 of them
# on git-tracked files, and until now not one was protected. Every restore was a bare sequential statement,
# so a Ctrl-C during a slow guards run (they shell out over a 6 MB Baker's file), a hung child, or any throw
# left the mutation on disk. That matters because push-data.ps1 runs `git add -A` and pushes: an abandoned
# mutation gets committed unreviewed on the next refresh. The worst case is commodities.json with its
# cleaner excludes stripped, which re-creates the founding bathroom-cleaner-priced-as-fruit bug AND is
# invisible, because audit-household-in-food reads the same file the engine does - the two would agree with
# each other. Register every backup the moment it is taken; the finally block puts them all back on any exit
# path. Idempotent: restoring an already-restored file is a no-op write of identical bytes.
$script:Restores = New-Object System.Collections.Generic.List[object]
function Backup([string]$path) {
  # returns the content so callers can keep using their existing $bak variables unchanged.
  # BYTES are what RestoreAll writes back: the string round-trip is not identity. Measured 2026-07-30:
  # extra-deals-2026-07-29.json (tracked, BOM-less) came back 1861 -> 1864 bytes - Set-Content -Encoding
  # UTF8 in PS 5.1 prepends a BOM the original never had, and push-data's `git add -A` would commit that.
  # Worse latent case: bare Get-Content on a BOM-less file reads ANSI, so any high byte would come back
  # double-encoded - the exact mojibake class guard 0d hunts in commodities.json.
  # FIRST REGISTRATION WINS: three files are Backed-up twice per run (board-price-overrides.json,
  # product-urls.json, the newest comparison-*.json), and the second call lands AFTER an inline
  # Set-Content restore that may have ADDED a BOM. RestoreAll writes in list order, so a second snapshot
  # would overwrite the true pre-run bytes with that BOM'd intermediate (measured: it re-creates the exact
  # +3-byte residue this function exists to kill). Register a path once, at its first touch.
  # THE TIMESTAMP IS PART OF THE FILE (2026-08-30). audit-tile-integrity refuses to run when
  # out\name-drift.json is older than product-urls.json, on the sound ground that its wrong-product flags
  # would then describe links that have since changed. Restoring product-urls.json rewrites its mtime, so
  # a case that merely touched it left that audit HELD - and therefore guards exiting 2 - for every case
  # after it. Two of the five undiagnosed failures were that, and nothing about the file's CONTENT was
  # wrong. A restore that leaves the file newer than it found it has not restored the file.
  $bytes = [IO.File]::ReadAllBytes($path)
  $content = Get-Content $path -Raw
  $mtime = (Get-Item $path).LastWriteTimeUtc
  foreach ($r in $script:Restores) { if ($r.path -eq $path) { return $content } }
  $script:Restores.Add([pscustomobject]@{ path = $path; content = $content; bytes = $bytes; mtime = $mtime })
  JournalSnapshot $path $bytes
  return $content
}

# DURABLE RESTORE JOURNAL (2026-08-08). Everything above lives in MEMORY: $script:Restores holds the only
# copy of the original bytes, so the finally block and the PowerShell.Exiting handler are the ONLY things
# that can put a mutated production file back - and neither survives a HARD kill (a timeout that taskkills
# the process, a closed window, a reboot). Measured twice on 2026-08-08: a killed run left guard 19's stderr
# probe injected into the LIVE audit-price-mode.ps1, and push-data.ps1 runs `git add -A`, so the next refresh
# would have committed a production guard with a debug write in it. The comment above says the finally block
# covers "any exit path"; a killed process has no exit path. So persist each snapshot to disk the moment it
# is taken, and replay whatever a previous run abandoned before this one touches anything.
$script:JournalDir = Join-Path $env:TEMP 'tg-restore-journal'
function JournalKey([string]$path) {
  return [BitConverter]::ToString((New-Object Security.Cryptography.SHA256Managed).ComputeHash(
    [Text.Encoding]::UTF8.GetBytes($path.ToLower()))).Replace('-', '').Substring(0, 16)
}
function JournalSnapshot([string]$path, $bytes) {
  # never let journalling break the suite: it is a safety net, not a dependency
  try {
    if (-not (Test-Path $script:JournalDir)) { New-Item -ItemType Directory -Force $script:JournalDir | Out-Null }
    $k = JournalKey $path
    [IO.File]::WriteAllBytes((Join-Path $script:JournalDir ($k + '.bak')), $bytes)
    [IO.File]::WriteAllText((Join-Path $script:JournalDir ($k + '.path')), $path)
  } catch { }
}
function JournalClear { try { if (Test-Path $script:JournalDir) { Remove-Item $script:JournalDir -Recurse -Force -ErrorAction SilentlyContinue } } catch { } }
function JournalRecover {
  if (-not (Test-Path $script:JournalDir)) { return 0 }
  $n = 0
  foreach ($pf in (Get-ChildItem (Join-Path $script:JournalDir '*.path') -ErrorAction SilentlyContinue)) {
    try {
      $target = [IO.File]::ReadAllText($pf.FullName)
      $bak = Join-Path $script:JournalDir ($pf.BaseName + '.bak')
      if (-not (Test-Path $bak) -or -not (Test-Path $target)) { continue }
      $orig = [IO.File]::ReadAllBytes($bak)
      if (@(Compare-Object ([IO.File]::ReadAllBytes($target)) $orig -SyncWindow 0).Count -ne 0) {
        [IO.File]::WriteAllBytes($target, $orig)
        $n++
        Write-Output ("  RECOVERED an abandoned mutation from a killed run: " + $target)
      }
    } catch { }
  }
  JournalClear
  return $n
}
$script:Created = New-Object System.Collections.Generic.List[string]
function MarkCreated([string]$path) { $script:Created.Add($path) }

# THE INLINE RESTORE, BYTE-ACCURATE (2026-08-30, queue 2026-08-27-a0aeb1).
# Every case used to undo its own mutation with `Set-Content $f $bak -Encoding UTF8 -NoNewline`, where
# $bak came from `Get-Content -Raw`. On a BOM-LESS file that pair does not restore anything - it
# CORRUPTS. Measured today on the real commodities.json: Get-Content -Raw reads a BOM-less file in the
# ANSI codepage (Windows-1252), Set-Content -Encoding UTF8 writes it back as UTF-8 with a BOM, and every
# one of its 66,170 bytes >= 0x80 is double-encoded. Original 3,213,023 bytes; after the "restore"
# 3,294,142 - LARGER than the mutated version it was undoing, mojibake throughout, plus a BOM the file
# never had. Re-encoding the original through Windows-1252 -> UTF-8 reproduces 3,294,142 to the byte.
#
# That is the whole reason five cases had been failing since 2026-08-29 with nobody able to say why:
# case 2 mutates commodities.json, its restore silently corrupted it, and every guard from case 16
# onward was reading the corrupted file instead of its own fixture. RestoreAll never showed it, because
# RestoreAll writes BYTES and puts the file back correctly at the very end - after the damage.
#
# Backup() already keeps the exact pre-run bytes. Use them.
function RestoreNow([string]$path) {
  foreach ($r in $script:Restores) {
    if ($r.path -eq $path) {
      [IO.File]::WriteAllBytes($r.path, $r.bytes)
      # and the mtime with it - see the note in Backup() on audit-tile-integrity's staleness hold
      try { (Get-Item $r.path).LastWriteTimeUtc = $r.mtime } catch { }
      return
    }
  }
  throw "RestoreNow: $path was never registered with Backup() - nothing to restore it from"
}
function RestoreAll {
  foreach ($c in $script:Created) { try { Remove-Item $c -Force -ErrorAction SilentlyContinue } catch {} }
  foreach ($r in $script:Restores) {
    try {
      [IO.File]::WriteAllBytes($r.path, $r.bytes)
      try { (Get-Item $r.path).LastWriteTimeUtc = $r.mtime } catch { }
    } catch { Write-Warning ("RESTORE FAILED for " + $r.path + " - fix this by hand before committing: " + $_.Exception.Message) }
  }
  JournalClear   # the on-disk net is only needed while mutations are outstanding
}

if ($SelfTest) {
  # frozen founding bug: a BOM-less file must survive Backup->mutate->RestoreAll BYTE-identical, and a
  # MarkCreated file must be gone - on the finally path AND after a mid-run throw. The second Backup of
  # the same path (mutation in between) freezes the double-registration variant: first snapshot must win
  # or RestoreAll ships the mutated intermediate as "restored".
  $td = Join-Path $env:TEMP ('tg-selftest-' + [guid]::NewGuid())
  New-Item -ItemType Directory $td | Out-Null
  $f1 = Join-Path $td 'bomless.json'; [IO.File]::WriteAllBytes($f1, [Text.Encoding]::ASCII.GetBytes('{"a":1}'))
  $orig = [IO.File]::ReadAllBytes($f1)
  $null = Backup $f1; '{"a":2}' | Set-Content $f1 -Encoding UTF8
  $null = Backup $f1; '{"a":3}' | Set-Content $f1 -Encoding UTF8   # double-registration: first snapshot must win
  $f2 = Join-Path $td 'stray.tmp'; MarkCreated $f2; 'x' | Set-Content $f2
  try { throw 'simulated mid-run crash' } catch {} finally { RestoreAll }
  $ok = (@(Compare-Object ([IO.File]::ReadAllBytes($f1)) $orig -SyncWindow 0).Count -eq 0) -and (-not (Test-Path $f2))

  # MUST FIRE, frozen from the 2026-08-08 incident: a run that is KILLED never reaches finally, so the
  # in-memory snapshot dies with the process and the mutation stays on disk. Simulate exactly that - take a
  # snapshot, mutate, then throw the snapshot away without restoring - and assert the next run's startup
  # recovery puts the file back from the on-disk journal.
  $f3 = Join-Path $td 'killed.ps1'
  New-Item -ItemType Directory -Force $td | Out-Null
  [IO.File]::WriteAllBytes($f3, [Text.Encoding]::ASCII.GetBytes("# clean production file`r`n"))
  $clean = [IO.File]::ReadAllBytes($f3)
  $null = Backup $f3                                              # journals to disk
  [IO.File]::WriteAllText($f3, "# clean production file`r`n[Console]::Error.WriteLine('probe')")
  $script:Restores.Clear()                                        # <- the kill: memory is gone, disk is not
  $null = JournalRecover
  $okKill = (@(Compare-Object ([IO.File]::ReadAllBytes($f3)) $clean -SyncWindow 0).Count -eq 0)
  $okClear = -not (Test-Path $script:JournalDir)                  # recovery must not leave the journal armed

  Remove-Item $td -Recurse -Force
  if ($ok -and $okKill -and $okClear) { Write-Output 'SELFTEST PASS: byte-identical restore + created-file cleanup + killed-run recovery from the on-disk journal'; exit 0 }
  if (-not $ok)      { Write-Output 'SELFTEST FAIL: restore is not byte-faithful or a created file survived' }
  if (-not $okKill)  { Write-Output 'SELFTEST FAIL: a killed run''s mutation was NOT recovered from the journal - a taskkill can still leave a mutated production file staged by git add -A' }
  if (-not $okClear) { Write-Output 'SELFTEST FAIL: the journal survived recovery - the next run would replay stale bytes over current work' }
  exit 1
}
# Ctrl-C does not run finally in every host, so also arm an engine-exit handler.
$null = Register-EngineEvent PowerShell.Exiting -Action { RestoreAll } -ErrorAction SilentlyContinue

# BEFORE anything is mutated: put back whatever a previously killed run abandoned. This runs first on purpose
# - a leftover mutation would otherwise become THIS run's "original", and the snapshot taken over it would
# make the damage permanent at the next restore.
$recovered = JournalRecover
if ($recovered -gt 0) { Write-Output ("test-guards: recovered $recovered abandoned mutation(s) before starting - run ``git status`` and confirm the tree is clean") }

# ---- REFUSE TO MUTATE THE LIVE TREE (2026-08-08) --------------------------------------------------------
# This suite tests by BREAKING production files and putting them back, so run-test-guards-weekly.ps1 exists
# to robocopy the tree into %TEMP% and run it there - a crash then costs a temp directory instead of a
# mutated repo. That runner has been right since 2026-07-30. The hole was that NOTHING stopped anyone from
# invoking this file directly against the real tree, which is exactly what happened on 2026-08-08: a direct
# run was killed by a 10-minute timeout and left guard 19's price_mode='delivery' fixture on the LIVE
# out\regular\aldi-regular-2026-08-05.json. out\ is gitignored, so no `git status` showed it; the next
# guards run read it and hard-failed "Aldi is shipping delivery prices - Board NOT safe to publish", which
# reads as a bad pull and nearly bought a pointless browser re-pull of the store.
# The hermetic copy lives under %TEMP%, so "am I under %TEMP%?" is the whole test.
$underTemp = $PSScriptRoot.TrimEnd('\').ToLower().StartsWith(([IO.Path]::GetTempPath()).TrimEnd('\').ToLower())
if (-not $underTemp -and -not $AllowLiveTree) {
  Write-Output 'test-guards: REFUSING to run against the live tree.'
  Write-Output ("  This suite mutates production files and restores them, and a killed run leaves the mutation behind - " +
                "including under out\, which is gitignored and so shows in no git status.")
  Write-Output '  Use the hermetic runner instead:   .\run-test-guards-weekly.ps1'
  Write-Output '  (It robocopies the tree to %TEMP% and runs the suite in the copy; a crash costs a temp directory.)'
  Write-Output '  To override deliberately, re-run with -AllowLiveTree.'
  exit 3
}

function RunGuardsOut {
  # -Quiet still prints every HARD FAIL line (guards.ps1's report loop emits fail lines with bare
  # Write-Output; ok AND warn lines go through Say), so the failure text is capturable without the noise.
  # NO 2>&1 HERE, DELIBERATELY: this file sets $ErrorActionPreference='Stop', and in PS 5.1 redirecting a
  # native command's stderr wraps each line in an ErrorRecord whose FIRST line THROWS (NativeCommandError)
  # under Stop - measured 2026-07-30 - which would abort the whole suite mid-mutation. Everything we match
  # on is stdout (a full failing guards run measured 0 stderr bytes); stderr passes through to the console
  # exactly as it did before this change.
  $o = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'guards.ps1') -Quiet | ForEach-Object { [string]$_ }) -join "`n"
  return [pscustomobject]@{ rc = $LASTEXITCODE; text = $o }
}
function RunGuards { return (RunGuardsOut).rc }

# ---- EVIDENCE ON FAIL + THE RESIDUE TRIPWIRE (2026-08-30, queue 2026-08-27-a0aeb1) -------------------
# Check/CheckLoud/CheckScript/CheckWarn used to DISCARD the captured child output the moment a case
# failed, so a failing case could only ever say "expected exit 0, got 2". It could NOT name the guard that
# actually fired. Five order-dependent failures (cases 16, 17, 26, 28, 29) sat undiagnosed from 2026-08-29
# for exactly that reason: the instrument was blind to its own failure cause, and every isolation probe of
# the individual cases came back green. So print the verdict lines the child produced.
#
# And print what is STILL MUTATED, because that is the other half of the same blindness. A leaked
# restore from an EARLIER case is indistinguishable, by exit code alone, from a genuine failure of THIS
# one - both are "expected 0, got 2". Every mutation in this suite goes through Backup(), which keeps the
# pre-run BYTES, so "is a production file still mutated right now" is a hash comparison over that same
# list. A case that restored correctly leaves this empty.
function ResidueList {
  $out = New-Object System.Collections.Generic.List[string]
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    foreach ($r in $script:Restores) {
      try {
        if (-not (Test-Path $r.path)) { [void]$out.Add('DELETED  ' + $r.path); continue }
        $now = [IO.File]::ReadAllBytes($r.path)
        $hNow = [BitConverter]::ToString($sha.ComputeHash($now))
        $hWas = [BitConverter]::ToString($sha.ComputeHash($r.bytes))
        if ($hNow -ne $hWas) {
          [void]$out.Add(('MUTATED  {0}  ({1} bytes now vs {2} pre-run)' -f $r.path, $now.Length, $r.bytes.Length))
        }
      } catch { [void]$out.Add('UNREADABLE  ' + $r.path + '  ' + $_.Exception.Message) }
    }
  } finally { $sha.Dispose() }
  return $out
}
function FailEvidence($text) {
  $t = [string]$text
  if ($t) {
    $lines = @($t -split "`r?`n" | Where-Object { $_ -match 'HARD FAIL|GUARDS FAILED|ACCURACY|FAIL' })
    if ($lines.Count -eq 0) { $lines = @($t -split "`r?`n" | Where-Object { $_ -match 'WARN' }) }
    if ($lines.Count -eq 0) { Write-Output '        | (the child produced no FAIL or WARN line at all)' }
    else { foreach ($l in ($lines | Select-Object -First 12)) { Write-Output ('        | ' + $l.Trim()) } }
  }
  $res = @(ResidueList)
  if ($res.Count -gt 0) {
    Write-Output '        RESIDUE - production file(s) still mutated at this point. A leaked restore from an'
    Write-Output '        EARLIER case fails every case after it, and it is not this case that is broken:'
    foreach ($r in $res) { Write-Output ('          ' + $r) }
  }
}
function Skip($m) {
  # THE ZERO-ROWS RULE, applied to this suite. A case that examined nothing must not let the run end
  # green: 'baker rounding' SKIPped silently from 2026-07-24 to 2026-07-30 while the summary said
  # '13 passed' - the suite stopped covering a store and nothing said so. A SKIP means the case's
  # precondition rotted away, and this file's own household-in-food essay already names the fix:
  # a negative test must CREATE its own fixture, not hope one still exists in rotating data.
  Write-Output ('  FAIL  SKIP(' + $m + ') - this case examined NOTHING; rebuild its fixture (inject the row/cell it needs instead of depending on live data)')
  $script:failed++
}
function Check($name, $expect, $sig) {
  # $sig: regex that must appear in guards' own output - the SPECIFIC invariant's failure text. Exit code
  # alone passed 12 vacuous cases on 2026-07-30 while an unrelated guard (audit-coverage-regression) was red;
  # the signature proves the mutation fired ITS guard, and also catches a previous case's mutation leaking
  # forward (the step-8/8b in-memory-object bug this file already documents).
  $r = RunGuardsOut
  $sigOk = if ($sig) { $r.text -match $sig } else { $true }
  if ($r.rc -eq $expect -and $sigOk) { Write-Output ("  PASS  {0}  (exit {1})" -f $name, $r.rc); $script:pass++ }
  elseif ($r.rc -ne $expect) { Write-Output ("  FAIL  {0}  expected exit {1}, got {2}" -f $name, $expect, $r.rc); FailEvidence $r.text; $script:failed++ }
  else { Write-Output ("  FAIL  {0}  exit {1} as expected BUT its own failure text /{2}/ is absent - a DIFFERENT guard failed, this one proved nothing" -f $name, $r.rc, $sig); FailEvidence $r.text; $script:failed++ }
}
function CheckLoud($name, $expect, $sig) {
  # LIKE Check, BUT WITHOUT -Quiet. An ADVISORY finding is emitted through guards' Say(), which -Quiet
  # suppresses - so an advisory gate asserted through Check() would match nothing and "pass" by exiting 0
  # for reasons that have nothing to do with it. Advisory gates are exactly the ones whose text IS the
  # whole verdict, so they have to be read from a loud run.
  $o = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'guards.ps1') | ForEach-Object { [string]$_ }) -join "`n"
  $rc = $LASTEXITCODE
  $sigOk = if ($sig) { $o -match $sig } else { $true }
  if ($rc -eq $expect -and $sigOk) { Write-Output ("  PASS  {0}  (exit {1})" -f $name, $rc); $script:pass++ }
  elseif ($rc -ne $expect) { Write-Output ("  FAIL  {0}  expected exit {1}, got {2}" -f $name, $expect, $rc); FailEvidence $o; $script:failed++ }
  else { Write-Output ("  FAIL  {0}  exit {1} as expected BUT its own text /{2}/ is absent - this case proved nothing" -f $name, $rc, $sig); FailEvidence $o; $script:failed++ }
}
# Some invariants live in their own gate rather than guards.ps1 (tile-integrity's ACCURACY check). Assert those
# against the script that actually owns them - Check() always runs guards.ps1, so passing a script name to it
# would silently test the wrong thing and "pass" for the wrong reason.
function CheckScript($name, $expect, $script, $sig) {
  # keep -Quiet: audit-tile-integrity's $Quiet gates only the per-store summary; its ACCURACY fail text
  # prints unconditionally, so the signature is still capturable.
  $o = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root $script) -Quiet | ForEach-Object { [string]$_ }) -join "`n"
  $rc = $LASTEXITCODE
  $sigOk = if ($sig) { $o -match $sig } else { $true }
  if ($rc -eq $expect -and $sigOk) { Write-Output ("  PASS  {0}  (exit {1})" -f $name, $rc); $script:pass++ }
  elseif ($rc -ne $expect) { Write-Output ("  FAIL  {0}  expected exit {1}, got {2}" -f $name, $expect, $rc); FailEvidence $o; $script:failed++ }
  else { Write-Output ("  FAIL  {0}  exit {1} as expected BUT its own failure text /{2}/ is absent - a DIFFERENT check failed, this one proved nothing" -f $name, $rc, $sig); FailEvidence $o; $script:failed++ }
}

# ---- 0. THE EMPTY-STAMP-FILE THROW (2026-07-30) ------------------------------------------------------
# `[string]$null` is $null in PowerShell, NOT '' - so `([string](Get-Content $f -Raw)).Trim()` THROWS
# "You cannot call a method on a null-valued expression" the moment $f is a ZERO-BYTE file. Eleven live
# sites used that idiom to read stamp/signature files. Measured on 2026-07-29: meal-prep\db\cost-flags.txt
# was empty, so check-ad-cycles logged 'cost-flag alert threw' and jumped the whole block - including the
# stale-signature cleanup, which is what re-arms that alert. Two of the other sites sit in publish scripts
# where the throw would take the publish down. An empty file is not an exotic state: it is what a crashed
# or interrupted write leaves behind.
# MUST-FIRE + CLEAN TWIN on a real zero-byte file, then a source scan so the idiom cannot creep back.
# Runs BEFORE the guards baseline on purpose - it is independent of the board, so a red board must not
# make it unevaluable.
$nz = Join-Path $env:TEMP ('tg-empty-' + [guid]::NewGuid().ToString('N') + '.txt')
Set-Content -Path $nz -Value '' -NoNewline -Encoding ASCII
try {
  if ((Get-Item $nz).Length -ne 0) { Write-Output '  FAIL  empty-stamp: fixture is not zero bytes - the case proves nothing'; $script:failed++ }
  else {
    $threw = $false
    try { $null = ([string](Get-Content $nz -Raw)).Trim() } catch { $threw = $true }
    if ($threw) { Write-Output '  PASS  empty-stamp: the OLD [string](...)  idiom still throws on a zero-byte file (case is live)'; $script:pass++ }
    else { Write-Output '  FAIL  empty-stamp: the old idiom no longer throws - this fixture can no longer prove the bug'; $script:failed++ }
    $safe = $null; $ok = $true
    try { $safe = ((Get-Content $nz -Raw) + '').Trim() } catch { $ok = $false }
    if ($ok -and $safe -eq '') { Write-Output '  PASS  empty-stamp: the shipped idiom returns empty string, no throw'; $script:pass++ }
    else { Write-Output '  FAIL  empty-stamp: the shipped idiom did not survive a zero-byte file'; $script:failed++ }
  }
} finally { Remove-Item $nz -Force -ErrorAction SilentlyContinue }
# source scan: no LIVE script may read a stamp file through the throwing idiom again (archive\ is frozen).
function Test-HasThrowingIdiom([string]$path) {
  # ONE definition of the scan, so the fixture below exercises the SAME expression the sweep uses.
  # LINE-WISE AND COMMENT-SKIPPING ON PURPOSE. The -Raw version matched the COMMENT in
  # publish-deals-page.ps1 that DOCUMENTS this trap (line 29; the code on line 31 is already the safe
  # form), so test-guards reported "1 failed" on a completely healthy tree - measured 2026-07-30, the
  # only failing case in the whole suite. A gate that cries wolf is a gate that gets switched off, and
  # this one was crying wolf at the essay written to stop the bug.
  $lines = @(Get-Content $path -ErrorAction SilentlyContinue)
  return @($lines | Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\(\[string\]\(Get-Content [^)]*\)\)\.Trim\(\)' }).Count -gt 0
}
# MUST-FIRE + CLEAN TWIN for the scan itself, on frozen synthetic files - the founding false positive and
# the real bug it is supposed to catch, side by side. bad.ps1 going unflagged means the sweep below can no
# longer fire at all; ok.ps1 getting flagged is the publish-deals-page false positive, reproduced.
$scanDir = Join-Path $env:TEMP ('tg-scan-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $scanDir | Out-Null
try {
  $scanBad = Join-Path $scanDir 'bad.ps1'
  $scanOk  = Join-Path $scanDir 'ok.ps1'
  $scanQ   = [char]39
  Set-Content $scanBad -Value '$p = ([string](Get-Content $f -Raw)).Trim()' -Encoding ASCII
  Set-Content $scanOk -Value @('# PS 5.1: ([string](Get-Content -Raw)).Trim() THROWS on a zero-byte stamp.', ('$p = ((Get-Content $f -Raw) + ' + $scanQ + $scanQ + ').Trim()')) -Encoding ASCII
  if (Test-HasThrowingIdiom $scanBad) { Write-Output '  PASS  empty-stamp: the source scan still flags the throwing idiom in real CODE'; $script:pass++ }
  else { Write-Output '  FAIL  empty-stamp: the source scan no longer flags the idiom in real code - the sweep below cannot fire'; $script:failed++ }
  if (-not (Test-HasThrowingIdiom $scanOk)) { Write-Output '  PASS  empty-stamp: the source scan ignores the idiom quoted inside a COMMENT'; $script:pass++ }
  else { Write-Output '  FAIL  empty-stamp: the source scan flags a COMMENT that merely documents the trap - the publish-deals-page false positive is back'; $script:failed++ }
} finally { Remove-Item $scanDir -Recurse -Force -ErrorAction SilentlyContinue }
$badIdiom = @()
foreach ($f in (Get-ChildItem (Join-Path $root '*.ps1') -File)) {
  # this file is exempt by construction: the must-fire case above HAS to contain the throwing idiom to run it.
  if ($f.Name -eq 'test-guards.ps1') { continue }
  if (Test-HasThrowingIdiom $f.FullName) { $badIdiom += $f.Name }
}
if ($badIdiom.Count -eq 0) { Write-Output '  PASS  empty-stamp: no live script reads a stamp file through the throwing idiom'; $script:pass++ }
else { Write-Output ('  FAIL  empty-stamp: throwing idiom is back in ' + ($badIdiom -join ', ') + " - use ((Get-Content `$f -Raw) + '').Trim()"); $script:failed++ }

# baseline - and ABORT if it is dirty. Measured 2026-07-30: with a real coverage regression on the board
# (Family Fare 256->208), guards exits 2 no matter what a case mutates, so 12 of the 13 expect-2 cases
# 'passed' while proving nothing - the exit code cannot distinguish 'my mutation fired' from 'already
# failing'. (The 13th, tile-integrity, runs its OWN gate via CheckScript and genuinely fired; the abort
# still applies - a red board means none of the guards.ps1 cases can be evaluated, and no mutation
# window should open for zero evidence.)
# A dirty baseline means the suite CANNOT evaluate those invariants: say so, touch nothing, exit 3
# ('could not evaluate' - the same code the delegated audits use for it in guards.ps1).
$rcBase = RunGuards
if ($rcBase -ne 0) {
  Write-Output ("  ABORT baseline: guards already exit " + $rcBase + " on the UNMUTATED board - every guards-based expect-fail case would pass vacuously. Fix the real failure first; no file was mutated. (exit 3 = could not evaluate)")
  exit 3
}
Write-Output '  PASS  baseline: guards pass on the current board  (exit 0)'; $script:pass++
try {

# ---- 1. price-mode -----------------------------------------------------------------
$f = (Get-ChildItem (Join-Path $root 'out\regular\aldi-regular-*.json') | Sort-Object Name -Desc | Select-Object -First 1).FullName
$bak = Backup $f
$d = $bak | ConvertFrom-Json; $d.price_mode = 'delivery'
($d | ConvertTo-Json -Depth 6) | Set-Content $f -Encoding UTF8
Check 'price-mode: Aldi flipped to the marked-up DELIVERY catalogue' 2 'HARD FAIL: price-mode \(in-store pricing\)'
RestoreNow $f

# ---- 2. household-in-food ----------------------------------------------------------
# INJECT the offending row rather than relying on one existing in a store file: the Family Fare file is
# regenerated daily, so the original "Lysol Mango & Hibiscus" row vanished and this test silently
# stopped testing anything (it passed by finding nothing). A negative test must create its own fixture.
$cf = Join-Path $root 'commodities.json'
$cbak = Backup $cf
$c = $cbak | ConvertFrom-Json
$m = $c | Where-Object { $_.id -eq 'mangoes' }
# strip EVERY cleaner-ish exclude, including the category-library ones (\bcleaner\b, disinfect, ...) baked in
# by apply-category-excludes on 2026-07-15 - with any one of them present the Lysol fixture can't even land in
# the commodity, so the bug this test rebuilds can no longer form (that's the library doing its job; the test
# must remove the whole defense to prove the AUDIT layer catches what gets through).
$m.exclude = @($m.exclude | Where-Object { $_ -notmatch 'lysol|cleaner|disinfect|clorox|wipes' })
($c | ConvertTo-Json -Depth 6) | Set-Content $cf -Encoding UTF8

$wf = (Get-ChildItem (Join-Path $root 'out\regular\walmart-regular-*.json') | Sort-Object Name -Desc | Select-Object -First 1).FullName
$wbak = Backup $wf
$w = $wbak | ConvertFrom-Json
$rows = New-Object System.Collections.ArrayList
foreach ($r in $w.deals) { [void]$rows.Add($r) }
[void]$rows.Add([ordered]@{ store='Walmart'; item='Lysol Mango & Hibiscus Bathroom Cleaner 32 fl oz'; ad_price='$3.39'; size='32 fl oz'; regular=$null; source_ad='NEGATIVE TEST FIXTURE' })
$w.deals = $rows.ToArray()
($w | ConvertTo-Json -Depth 6) | Set-Content $wf -Encoding UTF8

Check 'household-in-food: a Lysol MANGO cleaner priced as fruit' 2 'HARD FAIL: household-in-food'

RestoreNow $wf
RestoreNow $cf

# ---- 3. rogue pin ------------------------------------------------------------------
$of = Join-Path $root 'board-price-overrides.json'
$obak = Backup $of
$o = $obak | ConvertFrom-Json
$cells = New-Object System.Collections.ArrayList
foreach ($x in $o.cells) { [void]$cells.Add($x) }
[void]$cells.Add([ordered]@{ id='eggs'; store='Walmart'; per_unit=99.0; source='NEGATIVE TEST'; set='test' })
$o.cells = $cells.ToArray()
($o | ConvertTo-Json -Depth 6) | Set-Content $of -Encoding UTF8
Check 'rogue pin: a pin that overrides the engine ($99/dozen eggs)' 2 'HARD FAIL: pin.*eggs / Walmart'
RestoreNow $of

# ---- 4. factor mismatch ------------------------------------------------------------
$pf = Join-Path $root 'product-urls.json'
$pbak = Backup $pf
$p = $pbak | ConvertFrom-Json
# halve a link's recorded size -> its per-unit doubles vs the board = the 2x pack bug
$target = $p.items.'white-vinegar'.'Sam''s Club'
if ($target) { $target.size = '1 gal' }   # the truth is "2 pk 1 gal"
($p | ConvertTo-Json -Depth 8) | Set-Content $pf -Encoding UTF8
Check 'factor mismatch: Sam''s 2-pack vinegar recorded as ONE gallon (2x)' 2 'x factor\s+white-vinegar'
RestoreNow $pf

# ---- 5. multipack size -------------------------------------------------------------
$sf = (Get-ChildItem (Join-Path $root 'out\regular\sams-regular-*.json') | Sort-Object Name -Desc | Select-Object -First 1).FullName
$sbak = Backup $sf
$s = $sbak | ConvertFrom-Json
foreach ($r in $s.deals) { if ($r.item -match 'ReaLemon') { $r.size = '48 fl oz' } }   # truth: "2 pk 48 fl oz"
($s | ConvertTo-Json -Depth 6) | Set-Content $sf -Encoding UTF8
Check 'multipack size: Sam''s 2-pack ReaLemon recorded as ONE bottle' 2 'multipack size.*ReaLemon'
RestoreNow $sf

# ---- 6. stray file in out\regular --------------------------------------------------
# The one that actually bit us: a throttled 0-row diagnostic named "family-fare-regular-<date>.PARTIAL.json"
# both matched the store glob AND sorted after the real file ('p' > 'j'), so every consumer read the empty
# file as Family Fare's catalogue. Family Fare fell to ZERO everyday cells and the pull still logged success.
$strayF = Join-Path $root 'out\regular\family-fare-regular-2026-07-14.PARTIAL.json'
MarkCreated $strayF
'{"store":"Family Fare","week_of":"2026-07-14","price_type":"everyday","deal_count":0,"deals":[]}' |
  Set-Content $strayF -Encoding UTF8
Check 'stray file: an empty .PARTIAL that outsorts the real Family Fare data' 2 'stray file in out\\regular.*PARTIAL'
Remove-Item $strayF -Force

# ---- 7. stale undated discount published as a live sale -----------------------------
# Brad caught this one on the live board: Hy-Vee sirloin at $6.99/lb, flagged Cheapest, badged "Sale thru
# Jul 19", when the store was charging $11.99/lb. It came from a 2-day-old undated "Aisles Online markdown"
# in extra-deals. Because the cell is typed `sale`, every price audit skips it BY DESIGN - so this class was
# invisible to all seven other guards. Rebuild the exact shape and prove guard 8 sees it.
#
# THIS TEST INJECTS ITS OWN extra-deals ROW, and must. It used to mutate only the BOARD and rely on a matching
# markdown still existing in out\extra-deals-*.json. That file rotates: on 2026-07-16 the newest one had ZERO
# rows, so guard 8's suspect list was empty, nothing matched, the guard passed, and the test failed - having
# proved nothing about guard 8 for however long the file had been empty. Exactly the trap called out on the
# household-in-food test above: A NEGATIVE TEST MUST CREATE ITS OWN FIXTURE. (Guard 8 only looks at extra-deals
# files dated BEFORE today, which is the point - a markdown captured today is still live.)
$cmpF = (Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Desc | Select-Object -First 1).FullName
$cbak2 = Backup $cmpF
$cmpD  = $cbak2 | ConvertFrom-Json
$sirloin = $cmpD.comparison | Where-Object { $_.id -eq 'sirloin-steak' } | Select-Object -First 1
$hv = $sirloin.stores | Where-Object { $_.store -eq 'Hy-Vee' } | Select-Object -First 1
if ($hv) {
  $stale = 'Hy-Vee Angus Reserve Beef Loin Boneless Sirloin Steak'
  # The fixture must go into the NEWEST extra-deals file, because that is the only one guard 8 reads
  # (Sort-Object Name -Descending | Select -First 1). My first attempt wrote a fresh <today-2> file and the
  # test still failed - the real, EMPTY <yesterday> file outsorted it and the guard read that instead.
  #
  # THIRD occurrence of the rotating-data trap (2026-07-23): a file dated TODAY defeats this test outright.
  # Guard 8's rule honours an undated discount ON its capture day (a markdown seen today IS live), so when the
  # weekly hygiene file extra-deals-<today>.json exists, the fixture lands in a today-dated file, reads as
  # LIVE, the guard correctly stays quiet, and the test fails while proving nothing. Move any today-dated file
  # ASIDE for the duration so the fixture lands in a genuinely PRE-today file (creating one if none remains).
  $exTodayF = Join-Path $root ('out\extra-deals-' + (Get-Date -Format 'yyyy-MM-dd') + '.json')
  $exTodayBak = $null
  if (Test-Path $exTodayF) { $exTodayBak = Backup $exTodayF; Remove-Item $exTodayF -Force }   # RestoreAll re-creates a deleted file from its registered bytes
  $exCreated = $false
  $exNewest = Get-ChildItem (Join-Path $root 'out\extra-deals-*.json') | Sort-Object Name -Descending | Select-Object -First 1
  if ($exNewest) { $exF = $exNewest.FullName; $exBak = Backup $exF; $exD = $exBak | ConvertFrom-Json }
  else {
    $exF = Join-Path $root ('out\extra-deals-' + (Get-Date).AddDays(-1).ToString('yyyy-MM-dd') + '.json')
    $exBak = $null; $exCreated = $true; MarkCreated $exF
    $exD = [pscustomobject]@{ price_type = 'sale'; deals = @() }
  }
  # an UNDATED markdown (no sale_end) cheaper than its own regular - the exact shape of the sirloin bug
  $exD.deals = @(@($exD.deals) + ([pscustomobject]@{ store = 'Hy-Vee'; item = $stale; ad_price = '$6.99'; regular = 11.99; size = 'lb' }))
  ($exD | ConvertTo-Json -Depth 6) | Set-Content $exF -Encoding UTF8

  $hv.type     = 'sale'
  $hv.per_unit = 6.99
  $hv.ad       = '$6.99'
  $hv.item     = $stale
  ($cmpD | ConvertTo-Json -Depth 8) | Set-Content $cmpF -Encoding UTF8
  Check 'stale sale: a 2-day-old undated markdown republished as a live sale' 2 'stale undated discount published as a live sale\s+sirloin-steak / Hy-Vee'
  RestoreNow $cmpF
  if ($exCreated) { Remove-Item $exF -Force -ErrorAction SilentlyContinue }
  else { RestoreNow $exF }
  if ($null -ne $exTodayBak) { RestoreNow $exTodayF }
} else {
  Skip 'stale sale: no Hy-Vee sirloin cell to mutate - inject a synthetic sirloin row into the board copy'
}

# ---- 8. publishing the REGULAR price over a live discount ---------------------------
# The bug Brad found, as a test. Take a Hy-Vee row that IS marked down and flip its published price back up
# to the regular price - exactly what reading `basePrice` instead of `price` does - and prove guard 10 sees it.
$hf = (Get-ChildItem (Join-Path $root 'out\regular\hyvee-regular-*.json') |
  Where-Object { $_.BaseName -match '^hyvee-regular-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Desc | Select-Object -First 1).FullName
$hbak = Backup $hf
$hd = $hbak | ConvertFrom-Json
$md = @($hd.deals | Where-Object { $_.marked_down -and $_.base_price -and $_.current_price }) | Select-Object -First 1
if ($md) {
  # Do exactly what reading `basePrice` instead of `price` does: publish the REGULAR price while the store is
  # still charging the marked-down one. Note this makes ad_price EQUAL to base_price, not greater - which is
  # why the first version of guard 10 (ad_price <= base_price) sailed straight past it. current_price is the
  # field that makes the lie visible.
  $md.ad_price = ('$' + [string]$md.base_price)
  ($hd | ConvertTo-Json -Depth 6) | Set-Content $hf -Encoding UTF8
  Check 'basePrice bug: a marked-down item republished at its REGULAR price' 2 'publishing a price the store is NOT charging'
  RestoreNow $hf
} else {
  Skip 'basePrice bug: no marked-down Hy-Vee row - the puller contract (record both prices) has broken'
}

# ---- 8b. the MULTIBUY reconciliation must not become a way to launder a wrong price ------------------
# Guard 10 compares ad_price * price_multiple against current_price, because a "3 for $4" row legitimately
# publishes $1.3333 while the store's headline is $4. That reconciliation is a hole if it is not checked: a
# wrong price_multiple would make any ad_price "agree" with any current_price. So plant one and prove the guard
# still fires. (This exists because the raw comparison hard-failed 18 rows of CORRECT multibuy data, and the
# fix for a false positive is the easiest place in a gate to accidentally open a real one.)
# RE-READ FROM THE RESTORED FILE (2026-07-28). The line above restored $hf on disk, but $hd was still the
# MUTATED in-memory object from step 8, so the write below shipped BOTH mutations - and guard 10 hard-failed
# on the leftover step-8 row no matter what this test did to price_multiple. This case has therefore been
# passing for the wrong reason and has never once exercised the price_multiple reconciliation path.
$hd = $hbak | ConvertFrom-Json
$mb = @($hd.deals | Where-Object { $_.price_multiple -and $_.current_price -and $_.ad_price }) | Select-Object -First 1
if ($mb) {
  $mb.price_multiple = ([double]$mb.price_multiple) + 1     # a divisor the store never quoted
  ($hd | ConvertTo-Json -Depth 6) | Set-Content $hf -Encoding UTF8
  Check 'multibuy: a price_multiple that does not reconcile ad_price to current_price' 2 'multibuy'
  RestoreNow $hf
} else {
  Skip 'multibuy: no price_multiple row - inject one (store=Hy-Vee, ad_price=1.3333, price_multiple=3, current_price=4)'
}

# ---- 8c. a shipped link that disagrees with its tile -------------------------------------------------
# Brad's bar: a shopper must never click "See item" and land on a different product or price. That is the ONE
# thing on this board that is a lie rather than a gap, so audit-tile-integrity gates ACCURACY hard (no
# baseline, no ratchet, no -Strict flag - there is no version of this repo where a wrong link is tolerable).
# A gate that reports zero is worthless if it cannot fail, so plant one and prove it fires.
$puF2 = Join-Path $root 'product-urls.json'
$pubak = Backup $puF2
$pud = $pubak | ConvertFrom-Json
$victim = $null
foreach ($n in @('bananas', 'milk', 'eggs', 'butter')) { if ($pud.items.$n.'Hy-Vee'.url) { $victim = $pud.items.$n.'Hy-Vee'; break } }
if ($victim) {
  $victim.price = 99.99          # a real link, a price the store does not charge
  ($pud | ConvertTo-Json -Depth 8) | Set-Content $puF2 -Encoding UTF8
  CheckScript 'tile-integrity: a shipped link whose price disagrees with the tile' 2 'audit-tile-integrity.ps1' 'LINKED tile\(s\) disagree'
  RestoreNow $puF2
} else {
  Skip 'tile-integrity: no Hy-Vee link on bananas/milk/eggs/butter - widen the victim search to any linked id'
}

# ---- 9. Baker's price PROVENANCE must WARN when rows stop arriving verbatim from the Kroger API -------
# The old case here ('baker rounding', expect exit 2) is dead twice over. Its row filter requires $_.upc,
# and since the 2026-07-24 Kroger-API switch all rows carry product_id (measured 2026-07-30: 0 of 6,960
# rows match, so the case has been silently SKIPping). And guard 11 itself was RETIRED 2026-07-30: the
# rounded-unit-price reconstruction cannot happen on verbatim API prices, so guards.ps1 now only WARNS
# when provenance changes; the reconcile class lives in audit-basis-reconcile, whose must-fire fixtures
# already run daily in test-auditors.ps1 (cases 1/1b/1c - one rule, one home; do not duplicate them here).
# What had NO must-fire proof was the provenance warn itself. Flip provenance on purpose and prove it.
function CheckWarn($name, $pattern) {
  # warns are Say-gated, so this one helper runs guards WITHOUT -Quiet. Do NOT capture stderr with 2>&1:
  # this file runs under $ErrorActionPreference='Stop', and in PS 5.1 redirecting a native child's stderr
  # wraps each line in an ErrorRecord that EAP=Stop turns into a terminating throw (reproduced 2026-07-30),
  # so the suite would CRASH mid-run instead of printing FAIL. The warn line arrives on stdout via Say.
  $o = (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'guards.ps1') | ForEach-Object { [string]$_ }) -join "`n"
  if ($LASTEXITCODE -eq 0 -and $o -match $pattern) { Write-Output ("  PASS  {0}  (exit 0 + warn fired)" -f $name); $script:pass++ }
  else { Write-Output ("  FAIL  {0}  expected exit 0 with warn /{1}/, got exit {2} (warn present: {3})" -f $name, $pattern, $LASTEXITCODE, ($o -match $pattern)); FailEvidence $o; $script:failed++ }
}
$bkf = (Get-ChildItem (Join-Path $root 'out\regular\bakers-regular-*.json') |
  Where-Object { $_.BaseName -match '^bakers-regular-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Desc | Select-Object -First 1).FullName
$bkbak = Backup $bkf
$bkd = $bkbak | ConvertFrom-Json
$flip = @($bkd.deals | Select-Object -First 10)
if ($flip.Count -gt 0) {
  foreach ($r in $flip) { $r.source_ad = 'bakersplus-scrape' }   # the pre-API provenance guard 11 must notice
  ($bkd | ConvertTo-Json -Depth 6) | Set-Content $bkf -Encoding UTF8
  CheckWarn 'bakers provenance: rows no longer verbatim from the sanctioned API must WARN' 'price provenance CHANGED'
  RestoreNow $bkf
} else {
  Write-Output '  FAIL  bakers provenance: newest bakers-regular parsed to ZERO rows - nothing to flip'; $script:failed++
}

# ---- 10. food commodity matched a wrong-CLASS product (the blueberries-as-Bai-beverage bug) ----------
# Family Fare blueberries went LIVE priced as a "Bai Brasilia Blueberry Antioxidant BEVERAGE" and every guard
# stayed green - household-in-food only knows cleaning products, and the factor guard only sees link drift.
# Rebuild the exact shape (a produce cell whose matched item is a beverage) and prove audit-food-category
# sees it.
$cmpF2 = (Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Desc | Select-Object -First 1).FullName
$cbak3 = Backup $cmpF2
$cmpD2 = $cbak3 | ConvertFrom-Json
$bb = $cmpD2.comparison | Where-Object { $_.id -eq 'blueberries' } | Select-Object -First 1
$bbCell = $null
if ($bb) { $bbCell = $bb.stores | Where-Object { [double]$_.per_unit -gt 0 } | Select-Object -First 1 }
if ($bbCell) {
  $bbCell.item = 'Bai Brasilia Blueberry Antioxidant Beverage 18 Fl Oz'
  ($cmpD2 | ConvertTo-Json -Depth 8) | Set-Content $cmpF2 -Encoding UTF8
  Check 'food-class: blueberries priced as a Bai antioxidant BEVERAGE' 2 'HARD FAIL: no food commodity matched a wrong-class product'
  RestoreNow $cmpF2
} else {
  Skip 'food-class: no priced blueberries cell - inject one into the board copy'
}

# ---- 12/13. override pins must be DERIVABLE from their own link -----------------------
# Guard 3 was rewritten 2026-07-16 because the old invariant ("a pin must not disagree with the engine") both
# contradicted generate-board-overrides (whose whole job is to emit pins that DO disagree - the board is stale,
# the link is right) and was a NO-OP anyway: it read only comparison-*.json while every pin in the file is a
# RECIPE-board id, so it skipped all 20 and reported "ok". These two cases are what stop it going quiet again.
$of = Join-Path $root 'board-price-overrides.json'
if (Test-Path $of) {
  $obak = Backup $of
  $o = $obak | ConvertFrom-Json
  if (@($o.cells).Count -gt 0) {
    # 12. a HAND-EDITED pin: doubling per_unit must no longer match the link it claims to be derived from
    $o.cells[0].per_unit = [math]::Round([double]$o.cells[0].per_unit * 2, 4)
    ($o | ConvertTo-Json -Depth 6) | Set-Content $of -Encoding UTF8
    Check 'pin: hand-edited per_unit no longer matches its own verified link' 2 'pin does NOT match its own link'
    RestoreNow $of

    # 13. an UNSOURCED pin: a pin beats the engine, so one with no link is a number nothing can correct
    $o2 = $obak | ConvertFrom-Json
    $fake = $o2.cells[0].PSObject.Copy()
    $fake.id = 'milk'; $fake.store = 'Nonexistent Store'; $fake.per_unit = 1.23
    $o2.cells = @(@($o2.cells) + $fake)
    ($o2 | ConvertTo-Json -Depth 6) | Set-Content $of -Encoding UTF8
    Check 'pin: unsourced pin (no product-urls link to derive from)' 2 'pin has NO LINK to derive from'
    RestoreNow $of
  } else {
    Skip 'pin: overrides file has no cells - inject a synthetic derivable pin, then hand-edit it'
  }

  # ---- 14. guard 3's WRONG-PRODUCT clause, END TO END --------------------------------------------------
  # Until 2026-07-30 this clause could not fire AT ALL: audit-name-drift read out\comparison-*.json only while
  # every pin is a recipe-board-only id, so $pinDrift never held a key matching a pin and guards printed
  # "ok ... 16 checked" with the product-identity half proving nothing. Nothing is hand-injected into
  # name-drift.json here - that would pass on the OLD code too and prove nothing. The mutation is on the LINK,
  # and the REAL audit has to turn it into a flag. Only the NAME changes, so the pin still derives from its own
  # link and the only new fault is product identity. Both mutated files are registered with Backup, so the
  # finally-block RestoreAll puts them back on any exit path (out\name-drift.json is gitignored + regenerable).
  #
  # WHY THE NAME SAYS "FROZEN", AND WHY THE CANDIDATE IS NOT JUST cand[0]: audit-name-drift only flags a
  # token mismatch when the BOARD item has a distinctive (non-commodity) word to miss. Measured 2026-07-30,
  # au-jus-gravy-mix/Hy-Vee is a live pin whose board item is "Hy-Vee Au Jus Sauce Mix" - every word is a stop
  # word or <=3 chars, so $btoks is empty, the audit says "no opinion", and renaming its link to an unrelated
  # product produces NO flag at all. cand[0] is whichever pin sorts first in a file that regenerates daily,
  # so a fixture that picked it blindly would go RED on healthy code the day the pin set shifts - the same
  # depends-on-rotating-data trap this file's own Skip() essay condemns. "Frozen" routes through the FORM-FLIP
  # clause, which is deliberately independent of the token test (that independence IS the Aldi blueberry fix),
  # and the loop then PROVES the audit flagged the cell before asserting on guards. Measured: the frozen
  # rename flags all 6 of today's examinable pins, au-jus included.
  $ndFx = Join-Path $root 'out\name-drift.json'
  if (Test-Path $ndFx) {
    $ndFxBak = Backup $ndFx
    $ndFxScanned = @{}
    foreach ($k in @(($ndFxBak | ConvertFrom-Json).examined_cells)) { if ($k) { $ndFxScanned[[string]$k] = $true } }
    $ndFxCand = @(@((Get-Content $of -Raw | ConvertFrom-Json).cells) | Where-Object { $ndFxScanned.ContainsKey([string]$_.id + '|' + [string]$_.store) })
    $ndFxFired = $false
    if ($ndFxCand.Count -gt 0) {
      $pfx = Join-Path $root 'product-urls.json'
      $pfxBak = Backup $pfx
      foreach ($ndFxPin in $ndFxCand) {
        $pfxDoc = $pfxBak | ConvertFrom-Json
        $pfxDoc.items.([string]$ndFxPin.id).([string]$ndFxPin.store).name = 'Zzz Frozen Unrelated Fixture Product'
        ($pfxDoc | ConvertTo-Json -Depth 8) | Set-Content $pfx -Encoding UTF8
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'audit-name-drift.ps1') | Out-Null
        $ndFxKey = [string]$ndFxPin.id + '|' + [string]$ndFxPin.store
        $ndFxNow = try { (Get-Content $ndFx -Raw | ConvertFrom-Json) } catch { $null }
        $ndFxHit = @(@($ndFxNow.flags) | Where-Object { $_ -and ([string]$_.id + '|' + [string]$_.store) -eq $ndFxKey }).Count
        if ($ndFxHit -gt 0) {
          Check ('pin: ' + $ndFxKey + ' pinned to a link that is now a DIFFERENT product') 2 'pin derived from a WRONG-PRODUCT link'
          $ndFxFired = $true
        }
        RestoreNow $pfx
        if ($ndFxFired) { break }
      }
      & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'audit-name-drift.ps1') | Out-Null
    }
    if (-not $ndFxFired) {
      Skip ('pin: could not make audit-name-drift flag ANY of the ' + $ndFxCand.Count + ' pin(s) it records having examined (out\name-drift.json examined_cells) - the WRONG-PRODUCT clause has nothing that can arm it, which IS the bug')
    }
  }
}

# ---- 15. guard 6: a THROTTLED capture must not become a store's source of truth ----------------------
# THE FAMILY FARE COLLAPSE, FROM THE OTHER SIDE. Case 6 above covers guard 7 - the stray '.PARTIAL' NAME.
# Guard 6 is the half that catches the same incident when the thin file is named CANONICALLY (a throttled
# pull that wrote <store>-regular-<date>.json holding a fraction of the catalogue), and it had NO negative
# test at all: 177 -> 55 rows is the founding bug of this whole file and nothing proved the check built for
# it could still fire. Measured 2026-07-30 in a hermetic copy: truncating the newest capture to 10 rows
# makes guards exit 2 with this text and nothing else.
# THE VICTIM IS DERIVED, NEVER NAMED. This re-runs guard 6's own selection rule (2+ captures for the
# prefix, best of the previous four > 100 rows) so the fixture cannot rot when the pull order or the store
# set changes - the rotating-data trap the Skip() essay above condemns.
$g6All = @(Get-ChildItem (Join-Path $root 'out\regular\*-regular-*.json') -ErrorAction SilentlyContinue |
  Where-Object { $_.BaseName -match '^[a-z0-9-]+-regular-\d{4}-\d{2}-\d{2}$' })
$g6Pick = $null
foreach ($g6Grp in (@($g6All | Group-Object { ($_.BaseName -replace '-regular-.*$','') }) | Sort-Object Name)) {
  $g6Ord = @($g6Grp.Group | Sort-Object Name -Descending)
  if ($g6Ord.Count -lt 2) { continue }
  $g6Best = 0
  foreach ($g6Old in ($g6Ord | Select-Object -Skip 1 -First 4)) {
    try { $g6N = @((Get-Content $g6Old.FullName -Raw | ConvertFrom-Json).deals).Count; if ($g6N -gt $g6Best) { $g6Best = $g6N } } catch {}
  }
  if ($g6Best -gt 100) { $g6Pick = $g6Ord[0]; break }
}
if ($g6Pick) {
  $g6Prefix = ($g6Pick.BaseName -replace '-regular-.*$','')
  $g6Bak = Backup $g6Pick.FullName
  $g6Doc = $g6Bak | ConvertFrom-Json
  $g6Doc.deals = @(@($g6Doc.deals) | Select-Object -First 10)   # 10 is under half of any >100-row history
  ($g6Doc | ConvertTo-Json -Depth 8) | Set-Content $g6Pick.FullName -Encoding UTF8
  Check ('store collapse: ' + $g6Prefix + "'s newest capture holds 10 rows against its own recent history") 2 ('store data collapsed\s+\[' + [regex]::Escape($g6Prefix) + '\]')
  RestoreNow $g6Pick.FullName
} else {
  Skip 'store collapse: no out\regular prefix has 2+ captures with a >100-row recent best, so guard 6 cannot be armed against this tree at all - which IS the finding'
}

# ---- 16. guard 9: a store nobody has looked at in over two weeks --------------------------------------
# "SAFE IS NOT A SYNONYM FOR ACCURATE" is guards.ps1's own heading here, and its >14-day HARD FAIL had no
# negative test. It is also the site most at risk of going quiet: guard 9's own header records how the
# Sam's alt-feed redirect made this fail structurally unreachable for 60 rows behind 22 live board cells.
# THIS CASE CREATES ITS OWN STORE. Every real store's newest capture is dated today or yesterday, so
# ageing a real one means deleting a rotating number of real files - the depends-on-live-data trap. The
# synthetic prefix is canonical so guard 7 stays quiet, carries ONE row because guard 9's zero-rows warn
# `continue`s past the age test on an empty deals array, and stamps price_mode so audit-price-mode does
# not co-fire. Measured 2026-07-30 in a hermetic copy: exit 2, this text, nothing else.
# 100 days: past the capture policy's 90-day carry (guard 9 reads that window; it was 14 until 2026-08-22)
$g9Date = (Get-Date).AddDays(-100).ToString('yyyy-MM-dd')
$g9F = Join-Path $root ('out\regular\zzstaleguard-regular-' + $g9Date + '.json')
if (Test-Path $g9F) {
  Skip 'stale prices: the fixture path already exists on disk - refusing to overwrite it'
} else {
  MarkCreated $g9F
  ([pscustomobject]@{
    store = 'ZZ Stale Guard Fixture'; week_of = $g9Date; price_type = 'everyday'
    price_mode = 'in-store'; mode_verified = $g9Date; deal_count = 1
    deals = @([pscustomobject]@{ store = 'ZZ Stale Guard Fixture'; item = 'Negative Test Filler 16 oz'; ad_price = '$1.00'; size = '16 oz'; regular = $null; source_ad = 'NEGATIVE TEST FIXTURE' })
  } | ConvertTo-Json -Depth 6) | Set-Content $g9F -Encoding UTF8
  Check 'stale prices: a store whose newest capture is 100 days old (past the 90-day carry)' 2 'ZZ Stale Guard Fixture price data is 100 days old'
  Remove-Item $g9F -Force -ErrorAction SilentlyContinue
}

# ---- 17. guard 12: the board must be built from TODAY'S ads -------------------------------------------
# A TWO-DAY-OLD BOARD went to the live site on 2026-07-17. out\comparison-*.json is gitignored on purpose,
# so `git pull` brings today's ADS and leaves yesterday's BOARD, and every downstream step then uses the
# newest board it can SEE rather than the newest that EXISTS. This is the gate that refuses that, and it
# had no negative test. Measured 2026-07-30 in a hermetic copy: exit 2, this text, nothing else.
$g12Cmp = Get-ChildItem (Join-Path $root 'out\comparison-*.json') -ErrorAction SilentlyContinue |
  Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Desc | Select-Object -First 1
$g12Ads = Get-ChildItem (Join-Path $root 'out\ads-*.json') -ErrorAction SilentlyContinue |
  Where-Object { $_.BaseName -match '^ads-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Desc | Select-Object -First 1
if ($g12Cmp -and $g12Ads) {
  $g12Date = ([datetime]($g12Cmp.BaseName -replace '^comparison-','')).AddDays(1).ToString('yyyy-MM-dd')
  $g12F = Join-Path $root ('out\ads-' + $g12Date + '.json')
  if (Test-Path $g12F) {
    Skip 'stale board: an ads file already sits after the newest board, so guard 12 should already be red and this case can prove nothing'
  } else {
    MarkCreated $g12F
    Copy-Item $g12Ads.FullName $g12F -Force
    Check 'stale board: an ads file dated after the newest board' 2 ('the board is STALE - ads-' + [regex]::Escape($g12Date))
    Remove-Item $g12F -Force -ErrorAction SilentlyContinue
  }
} else {
  Skip 'stale board: no dated ads/comparison pair on disk to build the fixture from'
}

# ---- 18. delegated audit: a store QUIETLY LOSING coverage between boards ------------------------------
# Sam's Club fell from 251 priced cells to 116 on a bare compare-deals re-run and every guard stayed green;
# Brad found it by eye. audit-coverage-regression is the ONLY check that can see that class - the publish
# gate enforces a FLOOR, which 116 clears - and nothing proved guards actually BLOCKS on it. Strip half of
# one store's cells out of the newest board and prove the delegating wrapper turns it into a hard fail.
# THE VICTIM IS THE LARGEST STORE NOT ALREADY ACKNOWLEDGED in out\coverage-ack.json: an acked store is
# silenced by design (Family Fare carries a live ack today), so naming one builds a fixture that can never
# fire. Measured 2026-07-30 in a hermetic copy: halving Fareway gives exit 2 with this text and nothing else.
$g18F = (Get-ChildItem (Join-Path $root 'out\comparison-*.json') |
  Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Desc | Select-Object -First 1).FullName
$g18Bak = Backup $g18F
$g18Rep = Join-Path $root 'out\coverage-regression.json'
if (Test-Path $g18Rep) { $null = Backup $g18Rep }   # the audit rewrites its own report; put it back too
$g18Acked = @{}
$g18AckF = Join-Path $root 'out\coverage-ack.json'
if (Test-Path $g18AckF) { foreach ($g18A in @((Get-Content $g18AckF -Raw | ConvertFrom-Json).acks)) { if ($g18A.store) { $g18Acked[[string]$g18A.store] = $true } } }
$g18Doc = $g18Bak | ConvertFrom-Json
$g18Count = @{}
foreach ($g18R in $g18Doc.comparison) { foreach ($g18S in $g18R.stores) { $g18K = [string]$g18S.store; $g18Count[$g18K] = 1 + [int]$g18Count[$g18K] } }
$g18Pick = @($g18Count.GetEnumerator() | Where-Object { -not $g18Acked.ContainsKey([string]$_.Key) -and [int]$_.Value -ge 40 } | Sort-Object Value -Descending | Select-Object -First 1)
if ($g18Pick.Count) {
  $g18Store = [string]$g18Pick[0].Key
  $g18Target = [int][math]::Ceiling([int]$g18Pick[0].Value * 0.5)
  $g18Gone = 0
  foreach ($g18R in $g18Doc.comparison) {
    if ($g18Gone -ge $g18Target) { break }
    $g18Keep = @(); $g18Hit = $false
    foreach ($g18S in $g18R.stores) { if (-not $g18Hit -and ([string]$g18S.store) -eq $g18Store) { $g18Hit = $true; $g18Gone++ } else { $g18Keep += $g18S } }
    if ($g18Hit) { $g18R.stores = $g18Keep }
  }
  ($g18Doc | ConvertTo-Json -Depth 10) | Set-Content $g18F -Encoding UTF8
  Check ('coverage regression: ' + $g18Store + ' loses half its priced cells between boards') 2 'HARD FAIL: no store lost coverage vs the previous board'
  RestoreNow $g18F
} else {
  Skip 'coverage regression: no un-acked store on the board carries 40+ priced cells to halve - inject a synthetic store into the board copy'
}

# ---- 19. a delegated audit writing to stderr must NOT disarm the gate ---------------------------------
# MUST-FIRE fixture for the delegated-audit call in guards.ps1. It ran the child as
#     & powershell ... -File $p 2>$null
# and in PS 5.1 redirecting a NATIVE child's stderr wraps its first line in an ErrorRecord that
# $ErrorActionPreference='Stop' turns into a TERMINATING throw - the exact trap RunGuardsOut and CheckWarn
# in this very file are commented to avoid. That call is the ONE delegate invocation NOT inside a
# try/catch, so any audit writing a single benign diagnostic line killed guards right there with exit 1:
# its own HARD FAIL text never printed, and guards 3 through 12 never ran at all. MEASURED 2026-07-30 on a
# GREEN hermetic tree - one injected stderr line -> exit 1; the same line plus a REAL price-mode violation
# -> still exit 1, with no 'HARD FAIL: price-mode' anywhere. Fail-closed on the exit code, blind on
# everything after it.
# BOTH HALVES SHIP TOGETHER ON PURPOSE. The exit-0 half alone would also pass on a build that swallowed
# the child's exit code; the exit-2 half is what proves the delegated hard fail still ARMS through stderr.
$g19A = Join-Path $root 'audit-price-mode.ps1'
$g19Src = Backup $g19A
$g19Anchor = "`$ErrorActionPreference = 'Stop'"
if ($g19Src.Contains($g19Anchor)) {
  $g19At = $g19Src.IndexOf($g19Anchor) + $g19Anchor.Length
  $g19Mut = $g19Src.Substring(0, $g19At) + "`r`n[Console]::Error.WriteLine('test-guards stderr probe - a delegated audit is allowed to write to stderr')" + $g19Src.Substring($g19At)
  # MUTATION, not a restore. Written BOM-less on purpose: this is a live .ps1 that guards.ps1 is about
  # to dot-source, and the old Set-Content -Encoding UTF8 here prepended a BOM the file never had - the
  # +3 bytes the residue tripwire reported against audit-price-mode.ps1.
  [IO.File]::WriteAllText($g19A, $g19Mut, (New-Object System.Text.UTF8Encoding($false)))
  Check 'delegate stderr: a benign diagnostic line from a delegated audit must not crash the gate' 0 $null
  $g19Aldi = (Get-ChildItem (Join-Path $root 'out\regular\aldi-regular-*.json') |
    Where-Object { $_.BaseName -match '^aldi-regular-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Desc | Select-Object -First 1).FullName
  $g19Bak = Backup $g19Aldi
  $g19Doc = $g19Bak | ConvertFrom-Json; $g19Doc.price_mode = 'delivery'
  ($g19Doc | ConvertTo-Json -Depth 8) | Set-Content $g19Aldi -Encoding UTF8
  Check 'delegate stderr: the delegated HARD FAIL still arms while that audit writes to stderr' 2 'HARD FAIL: price-mode \(in-store pricing\)'
  RestoreNow $g19Aldi
  RestoreNow $g19A
} else {
  Skip 'delegate stderr: audit-price-mode.ps1 no longer sets $ErrorActionPreference - re-anchor the stderr probe'
}

# ---- 20. BOARD vs PRODUCT IDENTITY TABLE (2026-08-22, guard 13) -----------------------------------
# The gate that replaces audit-match-soundness's self-check. It compares each board cell against the
# assignment the ENGINE ITSELF recorded in graph\identity\, so there is no second implementation to drift.
# A gate that cannot fail is worthless, so: take a real row out of the staple table, point it at a
# commodity that is definitely not the one the board priced, and demand the gate names that exact cell.
#
# IT SHIPS ADVISORY (PLAN section 10.17: promotion to blocking is Brad's, after clean real mornings), so
# the expected exit code is 0 and what is asserted is the WARN text. $g20Expect is the ONE thing to change
# on promotion - flip it to 2 and the same case proves the hard fail.
$g20Expect = 0
$g20Dir = Join-Path (Split-Path $root -Parent) 'graph\identity\staple'
$g20F = $null
if (Test-Path $g20Dir) { $g20F = Get-ChildItem (Join-Path $g20Dir '*.jsonl') -ErrorAction SilentlyContinue | Sort-Object Length -Desc | Select-Object -First 1 }
if (-not $g20F) {
  Skip 'board-vs-identity: no graph\identity\staple table in this tree, so the parity gate could not be exercised (the hermetic runner copies graph\identity for exactly this reason)'
} else {
  # The mutated row must be one the BOARD ACTUALLY PRICED, or the gate correctly says nothing and the
  # case passes vacuously - the "SKIP is a failure" rule this suite already enforces, applied to a join.
  $g20Cmp = Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Desc | Select-Object -First 1
  $g20Board = Get-Content $g20Cmp.FullName -Raw | ConvertFrom-Json
  . (Join-Path $root 'match-lib.ps1')     # Get-MatchTexts - the same normalisation the gate joins on
  $g20Want = @{}
  foreach ($g20Row in @($g20Board.comparison)) {
    foreach ($g20S in @($g20Row.stores)) {
      if ($g20S.item) { $g20Want[([string]$g20S.store + '|' + (Get-MatchTexts ([string]$g20S.item))[1])] = [string]$g20Row.id }
    }
  }
  $g20Src = Backup $g20F.FullName
  $g20Lines = @($g20Src -split "`r?`n" | Where-Object { $_ -and $_.Trim() })
  $g20Hit = -1
  for ($i = 0; $i -lt $g20Lines.Count; $i++) {
    $g20R = $null
    try { $g20R = $g20Lines[$i] | ConvertFrom-Json } catch { continue }
    if ($g20Want.ContainsKey([string]$g20R.store + '|' + [string]$g20R.name_key)) { $g20Hit = $i; break }
  }
  if ($g20Hit -lt 0) {
    Skip 'board-vs-identity: no row in the identity table joins to a cell on today''s board, so a forced disagreement could not be made visible - the join key drifted and the gate is structurally unfirable'
  } else {
    $g20Orig = $g20Lines[$g20Hit] | ConvertFrom-Json
    $g20Name = [string]$g20Orig.name
    $g20Orig.commodity = 'commodity:staple:test-guards-forced-disagreement'
    $g20Lines[$g20Hit] = ($g20Orig | ConvertTo-Json -Depth 6 -Compress)
    [IO.File]::WriteAllText($g20F.FullName, (($g20Lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    CheckLoud 'board-vs-identity: a table row pointed at the wrong commodity is NAMED by the gate' $g20Expect ([regex]::Escape($g20Name))
    # CLEAN TWIN: restore and prove the gate goes quiet again, so the case above cannot be passing on
    # some unrelated permanent disagreement.
    RestoreNow $g20F.FullName
    CheckLoud 'board-vs-identity: with the row restored, the gate reports agreement again' 0 'board-vs-identity \[staple\]: all \d+ cell'
  }
}

# ---- THE RESIDUE TRIPWIRE, ARMED (2026-08-30, queue 2026-08-27-a0aeb1) ------------------------------
# Read BEFORE the finally block, on purpose. RestoreAll below puts every registered file back from its
# pre-run BYTES, so by the time the trailing 'restored:' case runs, any leak is already gone - which is
# exactly why five order-dependent failures could sit here for a day looking like five unrelated bugs.
# This is the one moment where a case that did NOT restore itself is still visible.
$tripwire = @(ResidueList)
if ($tripwire.Count -gt 0) {
  Write-Output ('  FAIL  residue tripwire: {0} production file(s) were left mutated by the cases above. Every case that ran after the leak was measuring THAT file, not its own mutation:' -f $tripwire.Count)
  foreach ($t in $tripwire) { Write-Output ('          ' + $t) }
  $script:failed++
} else {
  Write-Output '  PASS  residue tripwire: every case restored the files it mutated (checked byte-for-byte against the pre-run snapshot, before RestoreAll)'
  $script:pass++
}

} finally {
  # every mutation above is undone here, on ANY exit path - normal, thrown, or aborted.
  RestoreAll
}
# ---- restored? ---------------------------------------------------------------------
Check 'restored: guards pass again after every mutation is reverted' 0

Write-Output ''
Write-Output ("negative tests: $pass passed, $failed failed")
if ($failed -gt 0) { Write-GuardComplete -Name 'guards'; exit 1 }
Write-GuardComplete -Name 'guards'; exit 0
