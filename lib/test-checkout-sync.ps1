<#
  test-checkout-sync.ps1 - the self-test of lib\checkout-sync.ps1 (design\PLAN-bot-checkout-self-heal-2026-09-23.md, W3.1).

  EVERY REPO HERE IS A THROWAWAY under one per-run directory in %TEMP%: a bare "remote", an "up" clone standing in for
  every session that pushes, and a "bot" clone standing in for the shared main checkout. The repository environment
  is cleared first (lib\git-repo-env.ps1), nothing opens a production lock, carry file or sync file, and the run's
  directory is removed in `finally`. The one file of this checkout it reads is grocery\capture-run.ps1, copied into
  the run's directory, for the startup-file drift case.

  WHAT IT CARRIES. The prototype's sync cases (sync-proto.ps1 blob 3ddd9f98c415, fixtures.ps1 blob 0b261c3cb365), with
  F8, F8b and F2 rewritten to the FOREIGN rule (a session's file is never merged into), plus every case the plan's W3.1
  lists and the claims section 14 says nobody had proved: the partial sync's tip selection, a session commit through
  the REAL index between read-tree and update-ref, and a modify/delete replay. The prototype's eight F9 size-gate cases
  are not here: they judge grocery\commit-size-lib.ps1 (W2.1), which is another lane's file.

  SEAMS RUN INSIDE THE LIBRARY'S FUNCTION SCOPE, and PowerShell resolves a variable by the call stack, so a seam that
  read `$p` or `$e` would find the library's own. Every variable a seam reads is `$script:fx...`.

  Run:   powershell -NoProfile -File lib\checkout-sync.ps1 -SelfTest   (or this file directly)
  Exit:  0 every case passed and the count is the literal below; 1 otherwise. The last line is the verdict.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'git-repo-env.ps1'); Clear-TcGitRepoEnv
. (Join-Path $PSScriptRoot 'checkout-sync.ps1')
$env:GIT_TERMINAL_PROMPT = '0'

$EXPECTED_CASES = 162
$script:pass = 0; $script:fail = 0
function T([string]$Label, [bool]$Cond, [string]$Got = '') {
  if ($Cond) { $script:pass++; Write-Output ('  ok    ' + $Label) }
  else { $script:fail++; Write-Output ('  FAIL  ' + $Label + '   got: ' + $Got) }
}
function Invoke-Group([string]$Name, [scriptblock]$Body) {
  Write-Output $Name
  try { & $Body } catch { $script:fail++; Write-Output ('  FAIL  the group threw: ' + $_.Exception.Message + ' (at ' + $_.InvocationInfo.ScriptLineNumber + ')') }
}

$script:fxRoot = Join-Path $env:TEMP ('tc-cs-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
New-Item -ItemType Directory -Path $script:fxRoot -ErrorAction Stop | Out-Null
$script:fxOwned = @('grocery', 'public')
$script:fxEstateN = 0
$script:fxUtf8 = New-Object Text.UTF8Encoding($false)

function GitR([string]$Dir, [string[]]$A) {
  $g = Invoke-GitCaptured -Repo $Dir -GitArgs (@('-c', 'core.quotePath=false', '--literal-pathspecs') + $A)
  return [pscustomobject]@{ rc = [int]$g.rc; out = ([string]$g.stdout).Trim(); raw = [string]$g.stdout; err = ([string]$g.stderr).Trim() }
}
function GitOk([string]$Dir, [string[]]$A) { $g = GitR $Dir $A; if ($g.rc -ne 0) { throw ('git ' + ($A -join ' ') + ' exited ' + $g.rc + ': ' + $g.err) }; return $g.out }
function W([string]$Dir, [string]$Rel, [string]$Text) {
  $p = Join-Path $Dir ($Rel -replace '/', '\'); New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) | Out-Null
  [IO.File]::WriteAllText($p, $Text, $script:fxUtf8)
}
function ReadOr([string]$P) { if (Test-Path -LiteralPath $P) { return [IO.File]::ReadAllText($P) } else { return '(absent)' } }
function Md5([string]$P) { if (-not (Test-Path -LiteralPath $P)) { return 'absent' }; return (Get-FileHash -LiteralPath $P -Algorithm MD5).Hash }
function Mtime([string]$P) { return (Get-Item -LiteralPath $P).LastWriteTimeUtc.Ticks }
function Snap([string]$Dir) {
  $lines = [System.Collections.Generic.List[string]]::new()
  foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force)) {
    $rel = $f.FullName.Substring($Dir.Length)
    if ($rel -match '^\\\.git\\') { continue }
    $lines.Add(($rel + ' ' + (Get-FileHash -LiteralPath $f.FullName -Algorithm MD5).Hash))
  }
  $lines.Add('INDEX ' + (Md5 (Join-Path $Dir '.git\index')))
  $lines.Add('HEAD ' + (GitR $Dir @('rev-parse', 'HEAD')).out)
  return (($lines | Sort-Object) -join "`n")
}
# From the RAW output: a trimmed one loses the leading space of ` M` on its first line.
function Status([string]$Dir) { $g = GitR $Dir @('--no-optional-locks', 'status', '--porcelain=v1', '--no-renames', '--untracked-files=all'); return (@($g.raw -split "`r?`n" | Where-Object { $_ }) -join ' | ') }

# A bare remote, an 'up' clone for every other pusher, and a 'bot' clone for the shared main checkout. Base tree: a
# code file, a derived file, a ledger, the verifier the F1 hook reads, and an ignore list naming the default quarantine.
function New-Estate([string]$Name, [switch]$AutoCrlf) {
  $script:fxEstateN++
  $d = Join-Path $script:fxRoot ('' + $script:fxEstateN + '-' + $Name); New-Item -ItemType Directory -Path $d | Out-Null
  $remote = Join-Path $d 'remote.git'
  $null = GitOk $d @('init', '-q', '--bare', '-b', 'main', $remote)
  $up = Join-Path $d 'up'; $bot = Join-Path $d 'bot'
  $null = GitOk $d @('-c', 'core.autocrlf=false', 'clone', '-q', $remote, $up)
  foreach ($kv in @(@('core.autocrlf', 'false'), @('user.name', 'fx'), @('user.email', 'fx@x'))) { $null = GitOk $up (@('config') + $kv) }
  W $up 'lib/code.ps1' "line1`nline2`nline3`nline4`nline5`n"
  W $up 'public/derived.json' "{`n  ""v"": 1`n}`n"
  W $up 'grocery/ledger.json' "a`nb`nc`n"
  W $up 'tools/verifier.txt' "strict`n"
  W $up '.gitignore' "ign/`n/q/`n"
  $null = GitOk $up @('add', '-A'); $null = GitOk $up @('commit', '-q', '-m', 'base'); $null = GitOk $up @('push', '-q', '-u', 'origin', 'HEAD:main')
  $crlf = if ($AutoCrlf) { 'true' } else { 'false' }
  $null = GitOk $d @('-c', ('core.autocrlf=' + $crlf), 'clone', '-q', $remote, $bot)
  foreach ($kv in @(@('core.autocrlf', $crlf), @('user.name', 'fx'), @('user.email', 'fx@x'))) { $null = GitOk $bot (@('config') + $kv) }
  if ((GitR $bot @('rev-parse', '--abbrev-ref', 'HEAD')).out -ne 'main') { throw 'the bot clone is not on main' }
  return [pscustomobject]@{ dir = $d; remote = $remote; up = $up; bot = $bot; q = (Join-Path $d 'quarantine') }
}
function Push-Up($E, [string]$Rel, [string]$Text, [string]$Msg) { W $E.up $Rel $Text; $null = GitOk $E.up @('add', '-A'); $null = GitOk $E.up @('commit', '-q', '-m', $Msg); $null = GitOk $E.up @('push', '-q', 'origin', 'HEAD:main') }
function Sync($E, [hashtable]$More = @{}) {
  $a = @{ Repo = $E.bot; OwnedPaths = $script:fxOwned; QuarantineRoot = $E.q; IndexLockWaitSec = 0; InProgressWaitSec = 0
          HeldRetrySec = 0; PollSec = 0; FetchAttempts = 1; FetchRetrySec = 0; StartupFiles = @() }
  foreach ($k in $More.Keys) { $a[$k] = $More[$k] }
  return (Invoke-TcCheckoutSync @a)
}
function OwnBlob($E, [string]$Rel) { return (GitR $E.bot @('hash-object', '--', $Rel)).out }
# A path inside a sync's dated tree, or one that cannot exist when the sync made no tree: a case then fails on its own
# assertion instead of throwing out of its group (M6 showed the throw, which only the case count caught).
function InTree($Rec, [string]$Rel) { if ($Rec -and $Rec.tree) { return (Join-Path $Rec.tree $Rel) }; return (Join-Path $script:fxRoot 'no-dated-tree') }

try {
  Invoke-Group 'F4 MUST NOT FIRE - a checkout already at origin is left byte-identical' {
    $E = New-Estate 'f4'; W $E.bot 'lib/code.ps1' "session edit`n"; $b4 = Snap $E.bot
    $s = Sync $E
    T 'outcome is current' ($s.outcome -eq 'current') ($s.outcome + ': ' + $s.why)
    T 'tree, index and HEAD byte-identical' ((Snap $E.bot) -eq $b4)
  }

  Invoke-Group 'F5 MUST NOT FIRE - local work on paths upstream did not touch keeps every status code, staged blob and mtime' {
    $E = New-Estate 'f5'
    Push-Up $E 'lib/other.ps1' "upstream`n" 'up: new file'
    W $E.bot 'grocery/ledger.json' "a`nb`nc`nd`n"; $null = GitOk $E.bot @('add', 'grocery/ledger.json')
    W $E.bot 'lib/code.ps1' "S`n"; $null = GitOk $E.bot @('add', 'lib/code.ps1'); W $E.bot 'lib/code.ps1' "W`n"
    W $E.bot 'grocery/cap/cap-2026-09-22.csv' "day1`n"
    W $E.bot 'grocery/new-staged.txt' "n`n"; $null = GitOk $E.bot @('add', 'grocery/new-staged.txt')
    $null = GitOk $E.bot @('rm', '-q', '--cached', 'tools/verifier.txt')
    $st0 = Status $E.bot; $idx0 = (GitR $E.bot @('ls-files', '-s', '--', 'lib/code.ps1', 'grocery/ledger.json', 'grocery/new-staged.txt')).out
    $paths = @('grocery/ledger.json', 'lib/code.ps1', 'grocery/cap/cap-2026-09-22.csv', 'grocery/new-staged.txt', 'tools/verifier.txt')
    $mt0 = @($paths | ForEach-Object { Mtime (Join-Path $E.bot $_) }) -join ','
    $s = Sync $E
    T 'outcome is synced' ($s.outcome -eq 'synced') ($s.outcome + ': ' + $s.why)
    T 'every status line identical' ((Status $E.bot) -eq $st0) ((Status $E.bot) + ' VS ' + $st0)
    T 'staged blobs identical, including the MM file''s staged version' ((GitR $E.bot @('ls-files', '-s', '--', 'lib/code.ps1', 'grocery/ledger.json', 'grocery/new-staged.txt')).out -eq $idx0)
    T 'every dirty file''s mtime identical (bar B4 on its mechanism)' ((@($paths | ForEach-Object { Mtime (Join-Path $E.bot $_) }) -join ',') -eq $mt0)
    T 'upstream file arrived' (Test-Path (Join-Path $E.bot 'lib/other.ps1'))
  }

  Invoke-Group 'F3 MUST FIRE - a foreign edit that overlaps upstream blocks the sync and changes NOTHING' {
    $E = New-Estate 'f3'
    Push-Up $E 'lib/code.ps1' "line1-UP`nline2`nline3`nline4`nline5`n" 'up: code'
    W $E.bot 'lib/code.ps1' "line1-SESSION`nline2`nline3`nline4`nline5`n"; W $E.bot 'grocery/cap/cap-2026-09-22.csv' "day1`n"
    $b4 = Snap $E.bot
    $s = Sync $E
    T 'blocked class foreign, naming the path' (($s.outcome -eq 'blocked') -and ($s.class -eq 'foreign') -and (($s.foreign -join ' ') -match 'lib/code\.ps1')) ($s.outcome + '/' + $s.class + ' ' + ($s.foreign -join ' '))
    T 'tree, index and HEAD byte-identical' ((Snap $E.bot) -eq $b4)
    T 'no quarantine or set-aside directory was created' (-not (Test-Path $E.q))
  }

  Invoke-Group 'F3b MUST FIRE - a STAGED change on a path upstream changed is FOREIGN, even inside an owned, vouched path' {
    $E = New-Estate 'f3b'
    Push-Up $E 'grocery/ledger.json' "a-UP`nb`nc`n" 'up: ledger'
    W $E.bot 'grocery/ledger.json' "a`nb`nc-S`n"; $null = GitOk $E.bot @('add', 'grocery/ledger.json'); $b4 = Snap $E.bot
    $s = Sync $E @{ OwnBlobs = @{ 'grocery/ledger.json' = (OwnBlob $E 'grocery/ledger.json') } }
    T 'outcome is blocked class foreign' (($s.outcome -eq 'blocked') -and ($s.class -eq 'foreign')) ($s.outcome + '/' + $s.class + ': ' + $s.why)
    # ON THE MECHANISM, NOT THE AGGREGATE: read-tree's own refusal plus the put-back would also leave the tree
    # identical, so the identical-tree assertion alone cannot tell which guard worked.
    T 'blocked BY THE PLAN, before any write - not rescued by read-tree''s refusal' ((($s.foreign -join ' ') -match '\(M \)') -and ($s.why -notmatch 'read-tree')) ($s.why + ' | ' + ($s.foreign -join ' '))
    T 'tree, index and HEAD byte-identical' ((Snap $E.bot) -eq $b4)
  }

  Invoke-Group 'F8 MUST FIRE (rewritten to the FOREIGN rule) - a session''s NON-overlapping edit on a path upstream changed is never merged' {
    $E = New-Estate 'f8'
    Push-Up $E 'lib/code.ps1' "line1`nline2`nline3`nline4`nline5-UP`n" 'up: code tail'
    W $E.bot 'lib/code.ps1' "line1-SESSION`nline2`nline3`nline4`nline5`n"
    $f = Join-Path $E.bot 'lib\code.ps1'; (Get-Item $f).LastWriteTime = [datetime]'2020-01-01T00:00:00'
    $md0 = Md5 $f; $mt0 = Mtime $f; $h0 = (GitR $E.bot @('rev-parse', 'HEAD')).out
    $s = Sync $E
    T 'blocked class foreign: no push tip was observed before the touching commit' (($s.outcome -eq 'blocked') -and ($s.class -eq 'foreign')) ($s.outcome + '/' + $s.class + ': ' + $s.why)
    T 'the session file''s bytes are identical (never merged)' ((Md5 $f) -eq $md0) (ReadOr $f)
    T 'the session file''s mtime is identical' ((Mtime $f) -eq $mt0)
    T 'HEAD did not move' ((GitR $E.bot @('rev-parse', 'HEAD')).out -eq $h0)
  }

  Invoke-Group 'F8b - a ledger both sides only APPENDED to, owned and vouched, is carried whole; not owned, it is FOREIGN' {
    foreach ($arm in 'owned', 'foreign', 'overlap') {
      $E = New-Estate ('f8b-' + $arm)
      $rel = if ($arm -eq 'foreign') { 'ops/history.jsonl' } else { 'grocery/history.jsonl' }
      W $E.up $rel "{""d"":1}`n"; $null = GitOk $E.up @('add', $rel); $null = GitOk $E.up @('commit', '-q', '-m', 'up: ledger'); $null = GitOk $E.up @('push', '-q', 'origin', 'HEAD:main')
      $null = GitOk $E.bot @('pull', '-q', 'origin', 'main')
      Push-Up $E $rel "{""d"":1}`n{""d"":2,""by"":""session""}`n" 'up: a session appended'
      $local = if ($arm -eq 'overlap') { "{""d"":1,""edited"":true}`n{""d"":2,""by"":""this checkout""}`n" } else { "{""d"":1}`n{""d"":2,""by"":""this checkout""}`n" }
      W $E.bot $rel $local; $b4 = Snap $E.bot
      $s = Sync $E @{ OwnBlobs = @{ $rel = (OwnBlob $E $rel) } }
      $ht = ReadOr (Join-Path $E.bot $rel)
      if ($arm -eq 'owned') {
        T 'CLEAN TWIN: an owned append-only ledger is MERGED, upstream''s row then this checkout''s' (($s.outcome -eq 'synced') -and ($ht -eq "{""d"":1}`n{""d"":2,""by"":""session""}`n{""d"":2,""by"":""this checkout""}`n") -and (@($s.merged) -contains $rel)) ($s.outcome + ' | ' + $ht + ' | merged=' + (@($s.merged) -join ','))
      } elseif ($arm -eq 'foreign') {
        T 'MUST FIRE: the same ledger outside the owned paths is FOREIGN: blocked, nothing written' (($s.outcome -eq 'blocked') -and ($s.class -eq 'foreign') -and ((Snap $E.bot) -eq $b4)) ($s.outcome + '/' + $s.class + ': ' + $s.why)
      } else {
        $sa = ReadOr (InTree $s ('set-aside\' + ($rel -replace '/', '\')))
        T 'MUST FIRE: an owned EDIT plus an append overlaps: set aside, upstream wins, the copy is this checkout''s bytes' (($s.outcome -eq 'synced') -and ($ht -eq "{""d"":1}`n{""d"":2,""by"":""session""}`n") -and ($sa -eq $local)) ($s.outcome + ' | ' + $ht + ' | ' + $sa)
      }
    }
  }

  Invoke-Group 'F2 MUST FIRE - the incident: the bot''s own uncommitted derived output against a deliberate upstream commit' {
    $E = New-Estate 'f2'
    Push-Up $E 'public/derived.json' "{`n  ""v"": 2, ""by"": ""other lane""`n}`n" 'up: another lane rebuilt derived.json'
    W $E.bot 'public/derived.json' "{`n  ""v"": 1, ""bot"": ""refused day""`n}`n"
    $localMd5 = Md5 (Join-Path $E.bot 'public/derived.json')
    $s = Sync $E @{ OwnBlobs = @{ 'public/derived.json' = (OwnBlob $E 'public/derived.json') } }
    T 'outcome is synced' ($s.outcome -eq 'synced') ($s.outcome + ': ' + $s.why)
    T 'upstream version in place' ((ReadOr (Join-Path $E.bot 'public/derived.json')) -match 'other lane')
    T 'set-aside copy is byte-identical to the displaced local bytes' ((Md5 (InTree $s 'set-aside\public\derived.json')) -eq $localMd5)
    T 'no unmerged entry, clean path, and the undo copies were removed after verify' ((-not (GitR $E.bot @('ls-files', '-u')).out) -and -not (Status $E.bot) -and -not (Test-Path (InTree $s 'undo'))) (Status $E.bot)
    $E = New-Estate 'f2c'
    Push-Up $E 'grocery/ledger.json' "a-UP`nb`nc`n" 'up: another lane edited the ledger head'
    W $E.bot 'grocery/ledger.json' "a`nb`nc`nday-2026-09-22`n"
    $s = Sync $E @{ OwnBlobs = @{ 'grocery/ledger.json' = (OwnBlob $E 'grocery/ledger.json') } }
    $lt = ReadOr (Join-Path $E.bot 'grocery/ledger.json')
    T 'the pipeline''s own NON-overlapping edit is merged: upstream''s line and the carried day, nothing set aside' (($s.outcome -eq 'synced') -and ($lt -eq "a-UP`nb`nc`nday-2026-09-22`n") -and (@($s.merged) -contains 'grocery/ledger.json') -and (@($s.set_aside).Count -eq 0)) ($s.outcome + ' | ' + $lt)
    $E = New-Estate 'f2n'
    Push-Up $E 'public/derived.json' "{`n  ""v"": 2, ""by"": ""other lane""`n}`n" 'up: derived'
    W $E.bot 'public/derived.json' "{`n  ""v"": 1, ""bot"": ""refused day""`n}`n"; $b4 = Snap $E.bot
    $s = Sync $E @{ OwnBlobs = @{} }
    T 'the same bytes NOT vouched by the journal are FOREIGN: blocked, nothing changes' (($s.outcome -eq 'blocked') -and ($s.class -eq 'foreign') -and ((Snap $E.bot) -eq $b4)) ($s.outcome + '/' + $s.class + ': ' + $s.why)
  }

  Invoke-Group 'F7 MUST FIRE - untracked AND ignored files at paths upstream adds are moved to the dated quarantine, never overwritten' {
    $E = New-Estate 'f7'
    Push-Up $E 'grocery/cap/report.json' "upstream report`n" 'up: add report'
    W $E.up 'ign/tracked-now.txt' "upstream ignored`n"; $null = GitOk $E.up @('add', '-f', 'ign/tracked-now.txt'); $null = GitOk $E.up @('commit', '-q', '-m', 'up: track an ignored path'); $null = GitOk $E.up @('push', '-q', 'origin', 'HEAD:main')
    W $E.bot 'grocery/cap/report.json' "LOCAL untracked`n"; W $E.bot 'ign/tracked-now.txt' "LOCAL ignored`n"
    $s = Sync $E @{ QuarantineRoot = (Join-Path $E.bot 'q') }
    T 'outcome is synced' ($s.outcome -eq 'synced') ($s.outcome + ': ' + $s.why)
    T 'both local files kept in quarantine with their bytes' (((ReadOr (InTree $s 'quarantine\grocery\cap\report.json')) -eq "LOCAL untracked`n") -and ((ReadOr (InTree $s 'quarantine\ign\tracked-now.txt')) -eq "LOCAL ignored`n")) ($s.tree)
    T 'upstream versions in place' (((ReadOr (Join-Path $E.bot 'ign/tracked-now.txt')) -eq "upstream ignored`n") -and ((ReadOr (Join-Path $E.bot 'grocery/cap/report.json')) -eq "upstream report`n"))
    T 'the in-repo quarantine tree is ignored: git status is clean' (-not (Status $E.bot)) (Status $E.bot)
  }

  Invoke-Group 'F10 MUST FIRE - a session writes a changed path mid-sync: read-tree refuses and every displaced byte goes back' {
    $E = New-Estate 'f10'
    $null = GitOk $E.up @('rm', '-q', 'tools/verifier.txt')
    W $E.up 'public/derived.json' "{`n  ""v"": 2, ""by"": ""other lane""`n}`n"; W $E.up 'grocery/cap/report.json' "upstream report`n"; W $E.up 'lib/code.ps1' "line1`nline2`nline3`nline4`nline5-UP`n"
    $null = GitOk $E.up @('add', '-A'); $null = GitOk $E.up @('commit', '-q', '-m', 'up: three paths'); $null = GitOk $E.up @('push', '-q', 'origin', 'HEAD:main')
    W $E.bot 'public/derived.json' "{`n  ""v"": 1, ""bot"": ""refused day""`n}`n"; W $E.bot 'grocery/cap/report.json' "LOCAL untracked`n"
    $derivedLocal = ReadOr (Join-Path $E.bot 'public/derived.json')
    $script:fxBot = $E.bot
    $s = Sync $E @{ OwnBlobs = @{ 'public/derived.json' = (OwnBlob $E 'public/derived.json') }; BeforeMove = { W $script:fxBot 'lib/code.ps1' "line1-SESSION-MIDSYNC`nline2`nline3`nline4`nline5`n" } }
    T 'blocked class read-tree by read-tree''s own refusal' (($s.outcome -eq 'blocked') -and ($s.class -eq 'read-tree')) ($s.outcome + '/' + $s.class + ': ' + $s.why)
    T 'the quarantined untracked file is back where it was, bytes intact' ((ReadOr (Join-Path $E.bot 'grocery/cap/report.json')) -eq "LOCAL untracked`n") (ReadOr (Join-Path $E.bot 'grocery/cap/report.json'))
    T 'the set-aside derived file is back with the local bytes' ((ReadOr (Join-Path $E.bot 'public/derived.json')) -eq $derivedLocal) (ReadOr (Join-Path $E.bot 'public/derived.json'))
    T 'the session''s mid-sync write is intact and HEAD did not move' (((ReadOr (Join-Path $E.bot 'lib/code.ps1')) -match 'MIDSYNC') -and ((GitR $E.bot @('rev-parse', 'HEAD')).out -eq $s.H0))
  }

  Invoke-Group 'F11 MUST FIRE - a lane commits (private index) between the tree move and the ref swap: ONE recovery keeps its commit' {
    $E = New-Estate 'f11'
    Push-Up $E 'lib/code.ps1' "line1`nline2-FIX`nline3`nline4`nline5`n" 'up: code fix'
    W $E.bot 'lib/wip.ps1' "session wip`n"
    $script:fxBot = $E.bot; $script:fxLaneDir = $E.dir
    $s = Sync $E @{ BeforeRef = {
      $li = Join-Path $script:fxLaneDir ('lane-idx-' + [guid]::NewGuid().ToString('N')); $env:GIT_INDEX_FILE = $li
      try { $null = GitOk $script:fxBot @('read-tree', 'HEAD'); W $script:fxBot 'graph/lane.json' "lane`n"; $null = GitOk $script:fxBot @('add', 'graph/lane.json'); $null = GitOk $script:fxBot @('commit', '-q', '-m', 'Graph nightly (lands mid-sync)') }
      finally { Remove-Item Env:\GIT_INDEX_FILE; Remove-Item -LiteralPath $li -Force -ErrorAction SilentlyContinue }
    } }
    $subjects = (GitR $E.bot @('log', '--format=%s', 'origin/main..HEAD')).out -replace "`r?`n", ' | '
    T 'the swap lost and recovered, outcome synced' (($s.outcome -eq 'synced') -and $s.cas_recovered) ($s.outcome + ': ' + $s.why)
    T 'the lane commit is NOT orphaned: it sits on top of origin' ($subjects -match 'lands mid-sync') $subjects
    T 'upstream fix present, session WIP the only dirt' (((ReadOr (Join-Path $E.bot 'lib/code.ps1')) -match 'line2-FIX') -and ((Status $E.bot) -eq '?? lib/wip.ps1')) (Status $E.bot)
    # CLEAN TWIN: the lane commits a file that was DIRTY when the sync planned. It ends clean, which is the lane's doing,
    # and step 10's untouched-fingerprint check must not read that as a write by the sync.
    $E = New-Estate 'f11c'
    Push-Up $E 'lib/code.ps1' "line1`nline2-FIX`nline3`nline4`nline5`n" 'up: code fix'
    W $E.bot 'grocery/ledger.json' "a`nb`nc`nlane day`n"
    $script:fxBot = $E.bot; $script:fxLaneDir = $E.dir
    $s = Sync $E @{ BeforeRef = {
      $li = Join-Path $script:fxLaneDir ('lane-idx-' + [guid]::NewGuid().ToString('N')); $env:GIT_INDEX_FILE = $li
      try { $null = GitOk $script:fxBot @('read-tree', 'HEAD'); $null = GitOk $script:fxBot @('add', 'grocery/ledger.json'); $null = GitOk $script:fxBot @('commit', '-q', '-m', 'Lane commits a file dirty at plan time') }
      finally { Remove-Item Env:\GIT_INDEX_FILE; Remove-Item -LiteralPath $li -Force -ErrorAction SilentlyContinue }
    } }
    $laneBlob = (GitR $E.bot @('rev-parse', 'HEAD:grocery/ledger.json')).out
    T 'CLEAN TWIN: a lane committing a file dirty at plan time still ends synced, the index holding the lane''s blob' (($s.outcome -eq 'synced') -and $s.cas_recovered -and ((GitR $E.bot @('show', 'HEAD:grocery/ledger.json')).out -match 'lane day') -and ((GitR $E.bot @('ls-files', '-s', '--', 'grocery/ledger.json')).out -match [regex]::Escape($laneBlob))) ($s.outcome + '/' + $s.class + ': ' + $s.why + ' | ' + (Status $E.bot))
  }

  Invoke-Group 'F11b MUST FIRE (owed) - a SESSION commits through the REAL index between read-tree and update-ref: the recovery keeps it' {
    $E = New-Estate 'f11b'
    Push-Up $E 'lib/code.ps1' "line1`nline2-FIX`nline3`nline4`nline5`n" 'up: code fix'
    W $E.bot 'lib/wip.ps1' "session wip`n"
    $script:fxBot = $E.bot
    $s = Sync $E @{ BeforeRef = { W $script:fxBot 'docs/session.md' "a session note`n"; $null = GitOk $script:fxBot @('add', 'docs/session.md'); $null = GitOk $script:fxBot @('commit', '-q', '-m', 'Session commit through the real index') } }
    $subjects = (GitR $E.bot @('log', '--format=%s', 'origin/main..HEAD')).out -replace "`r?`n", ' | '
    T 'the swap lost and recovered, outcome synced' (($s.outcome -eq 'synced') -and $s.cas_recovered) ($s.outcome + ': ' + $s.why)
    T 'the session commit sits on top of origin, holding its file and upstream''s fix' (($subjects -eq 'Session commit through the real index') -and ((GitR $E.bot @('cat-file', '-e', 'HEAD:docs/session.md')).rc -eq 0) -and ((GitR $E.bot @('show', 'HEAD:lib/code.ps1')).out -match 'line2-FIX')) $subjects
    T 'the index and tree hold HEAD: WIP the only dirt' ((Status $E.bot) -eq '?? lib/wip.ps1') (Status $E.bot)
  }

  Invoke-Group 'F2d MUST NOT FIRE - a journal entry for a path OUTSIDE the owned paths vouches for nothing' {
    $E = New-Estate 'f2d'
    Push-Up $E 'lib/code.ps1' "line1-UP`nline2`nline3`nline4`nline5`n" 'up: code'
    W $E.bot 'lib/code.ps1' "line1-SESSION`nline2`nline3`nline4`nline5`n"; $b4 = Snap $E.bot
    $s = Sync $E @{ OwnBlobs = @{ 'lib/code.ps1' = (OwnBlob $E 'lib/code.ps1') } }
    T 'blocked class foreign, and nothing changed' (($s.outcome -eq 'blocked') -and ($s.class -eq 'foreign') -and ((Snap $E.bot) -eq $b4)) ($s.outcome + '/' + $s.class + ': ' + $s.why)
  }

  Invoke-Group 'F6 CLEAN TWIN - the success path: a local bot commit plus a local graph commit, replayed -X theirs, then pushed' {
    $E = New-Estate 'f6'
    Push-Up $E 'public/derived.json' "{`n  ""v"": 9, ""by"": ""other lane""`n}`n" 'up: derived'
    Push-Up $E 'lib/code.ps1' "line1`nline2-FIX`nline3`nline4`nline5`n" 'up: code fix'
    W $E.bot 'graph/nightly.json' "graph`n"; $null = GitOk $E.bot @('add', 'graph/nightly.json'); $null = GitOk $E.bot @('commit', '-q', '-m', 'Graph nightly (local)')
    W $E.bot 'public/derived.json' "{`n  ""v"": 10, ""by"": ""bot today""`n}`n"; W $E.bot 'grocery/cap/cap-2026-09-23.csv' "day2`n"
    $null = GitOk $E.bot @('add', 'public/derived.json', 'grocery/cap/cap-2026-09-23.csv'); $null = GitOk $E.bot @('commit', '-q', '-m', 'Daily pipeline (local)')
    W $E.bot 'lib/wip.ps1' "session wip`n"
    $h0 = (GitR $E.bot @('rev-parse', 'HEAD')).out
    $s = Sync $E @{ Phase = 'tail' }
    T 'outcome is synced, 2 replayed' (($s.outcome -eq 'synced') -and ($s.replayed -eq 2)) ($s.outcome + ' replayed=' + $s.replayed + ': ' + $s.why)
    T 'the bot''s derived version wins, as -X theirs did' ((ReadOr (Join-Path $E.bot 'public/derived.json')) -match 'bot today')
    T 'upstream code fix arrived' ((ReadOr (Join-Path $E.bot 'lib/code.ps1')) -match 'line2-FIX')
    T 'session WIP untouched' ((Status $E.bot) -eq '?? lib/wip.ps1') (Status $E.bot)
    $cmp = Join-Path $E.dir 'cmp'; $null = GitOk $E.dir @('-c', 'core.autocrlf=false', 'clone', '-q', $E.bot, $cmp)
    $null = GitOk $cmp @('config', 'user.name', 'fx'); $null = GitOk $cmp @('config', 'user.email', 'fx@x')
    $null = GitOk $cmp @('fetch', '-q', $E.remote, 'main'); $null = GitOk $cmp @('checkout', '-q', '-B', 'viarebase', $h0)
    $null = GitOk $cmp @('rebase', '-q', '-X', 'theirs', 'FETCH_HEAD')
    T 'tree equals what git rebase -X theirs builds' ((GitR $cmp @('rev-parse', 'HEAD^{tree}')).out -eq (GitR $E.bot @('rev-parse', 'HEAD^{tree}')).out)
    $pu = GitR $E.bot @('push', '-q', 'origin', 'HEAD:main')
    T 'push lands' (($pu.rc -eq 0) -and ((GitR $E.bot @('rev-parse', 'HEAD')).out -eq @((GitR $E.bot @('ls-remote', 'origin', 'refs/heads/main')).out -split "`t")[0])) ('rc ' + $pu.rc + ' ' + $pu.err)
  }

  Invoke-Group 'F6md MUST FIRE (owed) - a local commit that deletes a file upstream modified cannot replay: degraded, nothing moves' {
    $E = New-Estate 'f6md'
    Push-Up $E 'grocery/ledger.json' "a-UP`nb`nc`n" 'up: ledger'
    $null = GitOk $E.bot @('rm', '-q', 'grocery/ledger.json'); $null = GitOk $E.bot @('commit', '-q', '-m', 'local deletes the ledger')
    $local = (GitR $E.bot @('rev-parse', 'HEAD')).out; $b4 = Snap $E.bot
    $s = Sync $E @{ Phase = 'tail' }
    T 'degraded class replay, naming the local commit' (($s.outcome -eq 'degraded') -and ($s.class -eq 'replay') -and ($s.why -match [regex]::Escape($local.Substring(0, 9)))) ($s.outcome + '/' + $s.class + ': ' + $s.why)
    T 'tree, index and HEAD byte-identical' ((Snap $E.bot) -eq $b4)
  }

  Invoke-Group 'F1 MUST FIRE - the founding bug over two runs: a refused commit still syncs, so a later run gets the fix and lands BOTH days' {
    function Invoke-MiniPublish($E, [string]$Day, [switch]$OldOrder) {
      W $E.bot ('grocery/cap/cap-' + $Day + '.csv') ('capture ' + $Day + "`n"); W $E.bot 'grocery/ledger.json' ("a`nb`nc`n" + $Day + "`n")
      $tmp = Join-Path $E.dir ('idx-' + [guid]::NewGuid().ToString('N')); $env:GIT_INDEX_FILE = $tmp
      try { $null = GitOk $E.bot @('read-tree', 'HEAD'); $null = GitOk $E.bot @('add', '-A', '--', 'grocery'); $c = GitR $E.bot @('commit', '-q', '-m', ('Daily pipeline (' + $Day + ')')) }
      finally { Remove-Item Env:\GIT_INDEX_FILE; Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
      $landed = ($c.rc -eq 0)
      if ($landed) { foreach ($cf in @((GitR $E.bot @('show', '--no-renames', '--name-only', '--pretty=format:', 'HEAD')).out -split "`r?`n" | Where-Object { $_ })) { $null = GitR $E.bot @('reset', '-q', '--', $cf) } }
      $sy = $null
      if ($landed -or -not $OldOrder) { $sy = Sync $E @{ Phase = 'tail'; OwnBlobs = @{ 'grocery/ledger.json' = (OwnBlob $E 'grocery/ledger.json') } } }
      if ($landed -and $sy -and ($sy.outcome -in @('synced', 'current'))) { $null = GitR $E.bot @('push', '-q', 'origin', 'HEAD:main') }
      # MEASURED AGAINST THE REMOTE, NOT THE TRACKING REF: a checkout that never fetches has an origin/main as stale as
      # its HEAD, and HEAD..origin/main then reads an agreeing 0.
      $null = GitOk $E.bot @('fetch', '-q', 'origin', '+refs/heads/main:refs/fx/remote-main')
      return [pscustomobject]@{ landed = $landed; sync = $sy; behind = [int](GitR $E.bot @('rev-list', '--count', 'HEAD..refs/fx/remote-main')).out }
    }
    foreach ($arm in @('old', 'new')) {
      $E = New-Estate ('f1-' + $arm)
      $hook = Join-Path $E.bot '.git\hooks\pre-commit'
      [IO.File]::WriteAllText($hook, "#!/bin/sh`nv=`$(cat tools/verifier.txt)`nif [ ""`$v"" = strict ]; then echo 'pre-commit: BLOCKED (verifier strict)' >&2; exit 1; fi`nexit 0`n", $script:fxUtf8)
      $r1 = Invoke-MiniPublish $E '2026-09-22' -OldOrder:($arm -eq 'old')
      Push-Up $E 'tools/verifier.txt' "fixed`n" 'up: the verifier fix lands after run 1'
      $r2 = Invoke-MiniPublish $E '2026-09-23' -OldOrder:($arm -eq 'old')
      $r3 = Invoke-MiniPublish $E '2026-09-23' -OldOrder:($arm -eq 'old')
      $originFiles = (GitR $E.bot @('ls-tree', '-r', '--name-only', 'refs/fx/remote-main', '--', 'grocery/cap')).out -replace "`r?`n", ','
      if ($arm -eq 'old') {
        T 'OLD ORDER (the mutant): runs 2 and 3 are refused again, still behind, day 1 never lands' ((-not $r2.landed) -and (-not $r3.landed) -and ($r3.behind -ge 1) -and ($originFiles -notmatch '2026-09-22')) ('landed=' + $r3.landed + ' behind=' + $r3.behind + ' origin=' + $originFiles)
      } else {
        T 'run 1 refused; its sync ran anyway (nothing upstream yet: current)' ((-not $r1.landed) -and ($r1.sync.outcome -eq 'current')) ('landed=' + $r1.landed + ' sync=' + $r1.sync.outcome + ' ' + $r1.sync.why)
        T 'run 2 ran the STALE verifier (a tail-only sync lags a run) and was refused, but its sync pulled the fix' ((-not $r2.landed) -and ($r2.sync.outcome -eq 'synced') -and ($r2.behind -eq 0)) ('landed=' + $r2.landed + ' sync=' + $r2.sync.outcome + ' behind=' + $r2.behind + ' ' + $r2.sync.why)
        T 'run 3 ran the FIXED verifier and landed' ($r3.landed) ('landed=' + $r3.landed)
        T 'both days of captures are on origin in run 3''s commit' (($originFiles -match 'cap-2026-09-22\.csv') -and ($originFiles -match 'cap-2026-09-23\.csv')) $originFiles
      }
    }
  }

  Invoke-Group 'PARTIAL MUST FIRE (owed) - two pushes, the second touching a session''s dirty file: the sync lands on the first push''s tip' {
    $E = New-Estate 'partial'
    W $E.up 'lib/a1.ps1' "a1`n"; $null = GitOk $E.up @('add', '-A'); $null = GitOk $E.up @('commit', '-q', '-m', 'push 1, commit a')
    $c1a = (GitR $E.up @('rev-parse', 'HEAD')).out
    W $E.up 'lib/a2.ps1' "a2`n"; $null = GitOk $E.up @('add', '-A'); $null = GitOk $E.up @('commit', '-q', '-m', 'push 1, commit b')
    $c1b = (GitR $E.up @('rev-parse', 'HEAD')).out; $null = GitOk $E.up @('push', '-q', 'origin', 'HEAD:main')
    $null = GitOk $E.bot @('fetch', '-q', 'origin')   # this checkout OBSERVES push 1's tip, and only its tip
    W $E.bot 'lib/code.ps1' "line1-SESSION`nline2`nline3`nline4`nline5`n"
    $f = Join-Path $E.bot 'lib\code.ps1'; $md0 = Md5 $f; $mt0 = Mtime $f
    # Push 2 is TWO commits, and only the second touches the session's file: the first is an intermediate commit that
    # was never a push tip, so a target of "the touching commit's parent" would land on a tree nobody gated.
    W $E.up 'lib/b1.ps1' "b1`n"; $null = GitOk $E.up @('add', '-A'); $null = GitOk $E.up @('commit', '-q', '-m', 'push 2, commit a (touches nothing dirty)')
    $p2a = (GitR $E.up @('rev-parse', 'HEAD')).out
    Push-Up $E 'lib/code.ps1' "line1`nline2`nline3`nline4`nline5-UP`n" 'push 2, commit b touches the session''s file'
    $p2 = (GitR $E.up @('rev-parse', 'HEAD')).out
    $s = Sync $E
    T 'outcome is partial' ($s.outcome -eq 'partial') ($s.outcome + '/' + $s.class + ': ' + $s.why)
    T 'HEAD is push 1''s OBSERVED tip: never an unobserved commit inside push 1 or push 2' (((GitR $E.bot @('rev-parse', 'HEAD')).out -eq $c1b) -and ($s.partial_target -eq $c1b) -and ($c1a -ne $c1b) -and ($p2a -ne $c1b)) ((GitR $E.bot @('rev-parse', 'HEAD')).out)
    T 'behind_after is one push''s worth of commits (push 2 carried 2)' ($s.behind_after -eq 2) ('behind_after=' + $s.behind_after)
    T 'the page names the file and the blocking commit' ($s.page -and ($s.why -match 'lib/code\.ps1') -and ($s.why -match [regex]::Escape($p2.Substring(0, 9)))) $s.why
    T 'the session file is byte- and mtime-identical, and push 1''s files arrived' (((Md5 $f) -eq $md0) -and ((Mtime $f) -eq $mt0) -and (Test-Path (Join-Path $E.bot 'lib/a2.ps1'))) (Status $E.bot)
  }

  function New-HeldEstate([string]$Name, [switch]$Delete) {
    $E = New-Estate $Name
    W $E.up 'lib/a.txt' "base-a`n"; W $E.up 'lib/held.json' "base-held`n"; W $E.up 'lib/z.txt' "base-z`n"
    $null = GitOk $E.up @('add', '-A'); $null = GitOk $E.up @('commit', '-q', '-m', 'held base'); $null = GitOk $E.up @('push', '-q', 'origin', 'HEAD:main')
    $null = GitOk $E.bot @('pull', '-q', 'origin', 'main')
    W $E.up 'lib/a.txt' "up-a`n"; W $E.up 'lib/z.txt' "up-z`n"
    if ($Delete) { $null = GitOk $E.up @('rm', '-q', 'lib/held.json') } else { W $E.up 'lib/held.json' "up-held`n" }
    $null = GitOk $E.up @('add', '-A'); $null = GitOk $E.up @('commit', '-q', '-m', 'upstream changes three'); $null = GitOk $E.up @('push', '-q', 'origin', 'HEAD:main')
    W $E.bot 'lib/code.ps1' "a session edit outside the move`n"
    $cf = Join-Path $E.bot 'lib\code.ps1'; (Get-Item $cf).LastWriteTime = [datetime]'2020-01-01T00:00:00'
    return $E
  }

  Invoke-Group 'HELD FORWARD MUST FIRE - a reader holds a file through the first read-tree only: the forward retry completes the move' {
    $E = New-HeldEstate 'held-fwd'
    $script:fxHeldPath = Join-Path $E.bot 'lib\held.json'; $script:fxHold = $null
    $s = Sync $E @{ BeforeMove = { $script:fxHold = [IO.File]::Open($script:fxHeldPath, 'Open', 'Read', 'Read') }; AfterReadTree = { if ($script:fxHold) { $script:fxHold.Dispose(); $script:fxHold = $null } } }
    if ($script:fxHold) { $script:fxHold.Dispose(); $script:fxHold = $null }
    T 'outcome is synced, and the record names the held file' (($s.outcome -eq 'synced') -and ($s.held -eq 'lib/held.json')) ($s.outcome + '/' + $s.class + ' held=' + $s.held + ': ' + $s.why)
    T 'the worktree holds NEW on all three paths' (((ReadOr (Join-Path $E.bot 'lib/a.txt')) -eq "up-a`n") -and ((ReadOr (Join-Path $E.bot 'lib/held.json')) -eq "up-held`n") -and ((ReadOr (Join-Path $E.bot 'lib/z.txt')) -eq "up-z`n"))
    T 'the only dirt is the session edit outside the move' ((Status $E.bot) -eq ' M lib/code.ps1') (Status $E.bot)
  }

  Invoke-Group 'HELD THROUGHOUT MUST FIRE - the reader never lets go: blocked class held-file, every path back at its H0 bytes' {
    $E = New-HeldEstate 'held-all'
    $cf = Join-Path $E.bot 'lib\code.ps1'; $cmd0 = Md5 $cf; $cmt0 = Mtime $cf
    $script:fxHeldPath = Join-Path $E.bot 'lib\held.json'; $script:fxHold = $null
    try { $s = Sync $E @{ BeforeMove = { $script:fxHold = [IO.File]::Open($script:fxHeldPath, 'Open', 'Read', 'Read') } } }
    finally { if ($script:fxHold) { $script:fxHold.Dispose(); $script:fxHold = $null } }
    T 'blocked class held-file naming lib/held.json' (($s.outcome -eq 'blocked') -and ($s.class -eq 'held-file') -and ($s.held -eq 'lib/held.json')) ($s.outcome + '/' + $s.class + ': ' + $s.why)
    T 'every changed path holds its H0 bytes' (((ReadOr (Join-Path $E.bot 'lib/a.txt')) -eq "base-a`n") -and ((ReadOr (Join-Path $E.bot 'lib/held.json')) -eq "base-held`n") -and ((ReadOr (Join-Path $E.bot 'lib/z.txt')) -eq "base-z`n"))
    T 'HEAD is H0 and the only dirt is the session edit' (((GitR $E.bot @('rev-parse', 'HEAD')).out -eq $s.H0) -and ((Status $E.bot) -eq ' M lib/code.ps1')) (Status $E.bot)
    T 'the foreign dirty file outside the move is byte- and mtime-identical' (((Md5 $cf) -eq $cmd0) -and ((Mtime $cf) -eq $cmt0))
  }

  # The reader shape here is lib\json-io.ps1's: FileShare.ReadWrite with NO Delete. Over a path upstream DELETES, git's
  # unlink only warns and read-tree exits 0 (review finding 1), which the 'Read'-shared modify cases above never reach.
  Invoke-Group 'HELD-DELETE FORWARD MUST FIRE - a reader holds a file upstream DELETES through the first read-tree only: the one delete completes the move' {
    $E = New-HeldEstate 'hdel-fwd' -Delete
    $script:fxHeldPath = Join-Path $E.bot 'lib\held.json'; $script:fxHold = $null
    $s = Sync $E @{ BeforeMove = { $script:fxHold = [IO.File]::Open($script:fxHeldPath, 'Open', 'Read', 'ReadWrite') }; AfterReadTree = { if ($script:fxHold) { $script:fxHold.Dispose(); $script:fxHold = $null } } }
    if ($script:fxHold) { $script:fxHold.Dispose(); $script:fxHold = $null }
    T 'outcome is synced, and the record names the held file' (($s.outcome -eq 'synced') -and ($s.held -eq 'lib/held.json')) ($s.outcome + '/' + $s.class + ' held=' + $s.held + ': ' + $s.why)
    T 'the deleted file is gone and the two modified paths hold NEW' ((-not (Test-Path -LiteralPath $script:fxHeldPath)) -and ((ReadOr (Join-Path $E.bot 'lib/a.txt')) -eq "up-a`n") -and ((ReadOr (Join-Path $E.bot 'lib/z.txt')) -eq "up-z`n")) (Status $E.bot)
    T 'HEAD is origin and the only dirt is the session edit outside the move (no stranded untracked file)' (((GitR $E.bot @('rev-parse', 'HEAD')).out -eq $s.O) -and ((Status $E.bot) -eq ' M lib/code.ps1')) (Status $E.bot)
  }

  Invoke-Group 'HELD-DELETE THROUGHOUT MUST FIRE - the reader never lets go of a file upstream deletes: blocked class held-file, HEAD, index and tree at H0' {
    $E = New-HeldEstate 'hdel-all' -Delete
    $cf = Join-Path $E.bot 'lib\code.ps1'; $cmd0 = Md5 $cf; $cmt0 = Mtime $cf
    $script:fxHeldPath = Join-Path $E.bot 'lib\held.json'; $script:fxHold = $null
    try { $s = Sync $E @{ BeforeMove = { $script:fxHold = [IO.File]::Open($script:fxHeldPath, 'Open', 'Read', 'ReadWrite') } } }
    finally { if ($script:fxHold) { $script:fxHold.Dispose(); $script:fxHold = $null } }
    T 'blocked class held-file naming lib/held.json' (($s.outcome -eq 'blocked') -and ($s.class -eq 'held-file') -and ($s.held -eq 'lib/held.json')) ($s.outcome + '/' + $s.class + ': ' + $s.why)
    T 'every changed path holds its H0 bytes, the held file included' (((ReadOr (Join-Path $E.bot 'lib/a.txt')) -eq "base-a`n") -and ((ReadOr (Join-Path $E.bot 'lib/held.json')) -eq "base-held`n") -and ((ReadOr (Join-Path $E.bot 'lib/z.txt')) -eq "base-z`n"))
    T 'HEAD is H0, the held file is tracked again, and the only dirt is the session edit' (((GitR $E.bot @('rev-parse', 'HEAD')).out -eq $s.H0) -and ((Status $E.bot) -eq ' M lib/code.ps1') -and ((GitR $E.bot @('ls-files', '--', 'lib/held.json')).out -eq 'lib/held.json')) (Status $E.bot)
    T 'the foreign dirty file outside the move is byte- and mtime-identical' (((Md5 $cf) -eq $cmd0) -and ((Mtime $cf) -eq $cmt0))
  }

  Invoke-Group 'HELD IN-THE-WAY MUST FIRE - an untracked owned file where upstream adds the path, held open by a reader: blocked class held-file, bytes kept' {
    $E = New-Estate 'held-quar'
    Push-Up $E 'grocery/new.json' "upstream new`n" 'up: add grocery/new.json'
    W $E.bot 'grocery/new.json' "LOCAL new`n"
    $nf = Join-Path $E.bot 'grocery\new.json'; $h0 = (GitR $E.bot @('rev-parse', 'HEAD')).out
    $hold = [IO.File]::Open($nf, 'Open', 'Read', 'ReadWrite')
    try { $s = Sync $E } finally { $hold.Dispose() }
    T 'blocked class held-file naming the path, not failed/exception' (($s.outcome -eq 'blocked') -and ($s.class -eq 'held-file') -and ($s.held -eq 'grocery/new.json')) ($s.outcome + '/' + $s.class + ': ' + $s.why)
    T 'the local bytes are where they were, untracked, and HEAD is H0' (((ReadOr $nf) -eq "LOCAL new`n") -and ((Status $E.bot) -eq '?? grocery/new.json') -and ((GitR $E.bot @('rev-parse', 'HEAD')).out -eq $h0)) (Status $E.bot)
  }

  Invoke-Group 'M2 TARGET MUST FIRE - an index at NEW over H0 bytes on disk (the checkout -B shape) is a mixed tree' {
    $E = New-HeldEstate 'stale-index'
    $script:fxBot = $E.bot
    $script:fxH0Bytes = [IO.File]::ReadAllBytes((Join-Path $E.bot 'lib\a.txt'))
    $null = GitOk $E.bot @('fetch', '-q', 'origin')
    $script:fxNewBlob = (GitR $E.bot @('rev-parse', 'refs/remotes/origin/main:lib/a.txt')).out
    $s = Sync $E @{ AfterReadTree = {
      [IO.File]::WriteAllBytes((Join-Path $script:fxBot 'lib\a.txt'), $script:fxH0Bytes)
      $null = GitOk $script:fxBot @('update-index', '--cacheinfo', ('100644,' + $script:fxNewBlob + ',lib/a.txt'))
    } }
    T 'failed class mixed-tree' (($s.outcome -eq 'failed') -and ($s.class -eq 'mixed-tree')) ($s.outcome + '/' + $s.class + ': ' + $s.why)
    T 'the verdict names the stale path' ($s.why -match 'lib/a\.txt') $s.why
  }

  Invoke-Group 'AUTOSTASH-ONLY (E1 shape) - at exactly the 300 s bar it waits and falls to 1c; one second past it recovers with --quit' {
    $E = New-Estate 'autostash'
    W $E.bot 'grocery/ledger.json' "a`nb`nc-dirty`n"
    $sha = GitOk $E.bot @('stash', 'create')
    $rm = Join-Path $E.bot '.git\rebase-merge'; New-Item -ItemType Directory -Path $rm | Out-Null
    [IO.File]::WriteAllText((Join-Path $rm 'autostash'), ($sha + "`n"), $script:fxUtf8)
    $t0 = [datetime]::new(2026, 9, 23, 12, 0, 0, [DateTimeKind]::Utc)
    (Get-Item (Join-Path $rm 'autostash')).LastWriteTimeUtc = $t0; (Get-Item $rm).LastWriteTimeUtc = $t0
    $s = Sync $E @{ Now = $t0.AddSeconds(300); AutostashAgeSec = 300 }
    T 'AT THE BAR (age exactly 300 s): degraded class in-progress naming rebase-merge' (($s.outcome -eq 'degraded') -and ($s.class -eq 'in-progress') -and ($s.why -match 'rebase-merge')) ($s.outcome + '/' + $s.class + ': ' + $s.why)
    T 'AT THE BAR: the directory is left alone' (Test-Path (Join-Path $rm 'autostash'))
    $s = Sync $E @{ Now = $t0.AddSeconds(301); AutostashAgeSec = 300 }
    T 'ONE PAST (301 s): recovered, and the note names the kept stash' (((@($s.notes) -join ' ') -match ('recovered half-started rebase, autostash kept as stash ' + $sha)) -and ($s.outcome -eq 'current')) ($s.outcome + ': ' + $s.why + ' | ' + (@($s.notes) -join ' '))
    T 'ONE PAST: the rebase-merge directory is gone' (-not (Test-Path $rm))
    T 'ONE PAST: stash@{0} equals the recorded autostash sha' ((GitR $E.bot @('stash', 'list', '-n', '1', '--format=%H')).out -eq $sha)
  }

  Invoke-Group 'ANOTHER OWNER''S MERGE MUST FIRE - MERGE_HEAD with a 0 s wait is degraded and never touched' {
    $E = New-Estate 'merge-head'
    $mh = Join-Path $E.bot '.git\MERGE_HEAD'; [IO.File]::WriteAllText($mh, ((GitR $E.bot @('rev-parse', 'HEAD')).out + "`n"), $script:fxUtf8)
    $s = Sync $E
    T 'degraded class in-progress naming MERGE_HEAD' (($s.outcome -eq 'degraded') -and ($s.class -eq 'in-progress') -and ($s.why -match 'MERGE_HEAD')) ($s.outcome + '/' + $s.class + ': ' + $s.why)
    T 'MERGE_HEAD still exists' (Test-Path $mh)
  }

  Invoke-Group 'DETACHED DURING A STOPPED REBASE MUST FIRE - 1c speaks before the branch check, never skipped' {
    $E = New-Estate 'detached'
    $null = GitOk $E.bot @('checkout', '-q', '--detach')
    $rm = Join-Path $E.bot '.git\rebase-merge'; New-Item -ItemType Directory -Path $rm | Out-Null
    [IO.File]::WriteAllText((Join-Path $rm 'head-name'), "refs/heads/main`n", $script:fxUtf8); [IO.File]::WriteAllText((Join-Path $rm 'onto'), ((GitR $E.bot @('rev-parse', 'HEAD')).out + "`n"), $script:fxUtf8)
    $s = Sync $E
    T 'degraded class in-progress naming rebase-merge, not the branch' (($s.outcome -eq 'degraded') -and ($s.class -eq 'in-progress') -and ($s.why -match 'rebase-merge') -and ($s.why -notmatch 'HEAD is not')) ($s.outcome + '/' + $s.class + ': ' + $s.why)
    T 'never skipped' ($s.outcome -ne 'skipped') $s.outcome
  }

  Invoke-Group 'MARKERS IN JSON MUST FIRE - after a git reset (ls-files -u reads 0) a non-owned file blocks; an owned one is set aside and restored' {
    $E = New-Estate 'markers'
    W $E.bot 'config/settings.json' "{`n  ""k"": 1`n}`n"; $null = GitOk $E.bot @('add', '-A'); $null = GitOk $E.bot @('commit', '-q', '-m', 'settings')
    $null = GitOk $E.bot @('checkout', '-q', '-b', 'side'); W $E.bot 'config/settings.json' "{`n  ""k"": 2`n}`n"; $null = GitOk $E.bot @('commit', '-q', '-am', 'side')
    $null = GitOk $E.bot @('checkout', '-q', 'main'); W $E.bot 'config/settings.json' "{`n  ""k"": 3`n}`n"; $null = GitOk $E.bot @('commit', '-q', '-am', 'main')
    $null = GitR $E.bot @('merge', 'side'); $null = GitOk $E.bot @('reset', '-q')
    $mh = Join-Path $E.bot '.git\MERGE_HEAD'; foreach ($x in 'MERGE_HEAD', 'MERGE_MSG', 'MERGE_MODE', 'AUTO_MERGE') { $p = Join-Path $E.bot ('.git\' + $x); if (Test-Path $p) { Remove-Item $p } }
    $unmergedOut = (GitR $E.bot @('ls-files', '-u')).out
    $b4 = Snap $E.bot
    $s = Sync $E
    T 'precondition: ls-files -u reads nothing, and the markers are in the JSON' ((-not $unmergedOut) -and ((ReadOr (Join-Path $E.bot 'config/settings.json')) -match '(?m)^<<<<<<< ')) $unmergedOut
    T 'blocked class conflict naming the JSON file' (($s.outcome -eq 'blocked') -and ($s.class -eq 'conflict') -and ($s.why -match 'config/settings\.json')) ($s.outcome + '/' + $s.class + ': ' + $s.why)
    T 'nothing was written' ((Snap $E.bot) -eq $b4)
    $E = New-Estate 'markers-owned'
    $marked = "{`n<<<<<<< HEAD`n  ""v"": 3`n=======`n  ""v"": 2`n>>>>>>> side`n}`n"
    W $E.bot 'public/derived.json' $marked
    $s = Sync $E @{ OwnBlobs = @{ 'public/derived.json' = 'named by the journal' } }
    $sa = ReadOr (InTree $s 'set-aside\public\derived.json')
    T 'owned and named: not blocked, the marked bytes are set aside' (($s.outcome -eq 'current') -and ($sa -eq $marked)) ($s.outcome + '/' + $s.class + ': ' + $s.why)
    T 'owned and named: the path is restored from HEAD' (((ReadOr (Join-Path $E.bot 'public/derived.json')) -eq "{`n  ""v"": 1`n}`n") -and (-not (Status $E.bot))) (Status $E.bot)
    T 'owned and named: the set-aside is a write, so the outcome pages and says so (never "nothing was written" alone)' ($s.page -and ($s.why -match 'set aside and restored from HEAD') -and ($s.why -match 'public/derived\.json')) ('page=' + $s.page + ' ' + $s.why)
  }

  Invoke-Group 'CONFLICT VOUCHING MUST FIRE - an owned file with markers the journal does not name, or that is staged, blocks and stays identical' {
    foreach ($arm in 'unnamed', 'staged') {
      $E = New-Estate ('vouch-' + $arm)
      $marked = "a`n<<<<<<< HEAD`nb`n=======`nb-S`n>>>>>>> stash`nc`n"
      W $E.bot 'grocery/ledger.json' $marked
      $f = Join-Path $E.bot 'grocery\ledger.json'
      $more = @{ OwnBlobs = @{} }
      if ($arm -eq 'staged') { $null = GitOk $E.bot @('add', 'grocery/ledger.json'); $more = @{ OwnBlobs = @{ 'grocery/ledger.json' = 'named by the journal' } } }
      (Get-Item $f).LastWriteTime = [datetime]'2020-01-01T00:00:00'; $md0 = Md5 $f; $mt0 = Mtime $f; $st0 = Status $E.bot; $b4 = Snap $E.bot
      $s = Sync $E $more
      T ('MUST FIRE (' + $arm + '): blocked class conflict naming the path, and nothing set aside') (($s.outcome -eq 'blocked') -and ($s.class -eq 'conflict') -and ($s.why -match 'grocery/ledger\.json') -and (@($s.set_aside).Count -eq 0)) ($s.outcome + '/' + $s.class + ': ' + $s.why)
      T ('MUST FIRE (' + $arm + '): the file''s bytes, mtime, status and the index are identical') (((Md5 $f) -eq $md0) -and ((Mtime $f) -eq $mt0) -and ((Status $E.bot) -eq $st0) -and ((Snap $E.bot) -eq $b4)) ((Status $E.bot) + ' VS ' + $st0)
    }
  }

  Invoke-Group 'MARKERS MUST NOT FIRE - a doc that already quoted a triple at HEAD, and a lone setext underline' {
    $E = New-Estate 'markers-quiet'
    $quoted = "# Notes`n`n``````n<<<<<<< ours`nx`n=======`ny`n>>>>>>> theirs`n```````n"
    W $E.bot 'docs/notes.md' $quoted; W $E.bot 'docs/title.md' "Intro`n"; $null = GitOk $E.bot @('add', '-A'); $null = GitOk $E.bot @('commit', '-q', '-m', 'docs')
    W $E.bot 'docs/notes.md' ($quoted + "`nedited elsewhere`n"); W $E.bot 'docs/title.md' "Title`n=======`n`nIntro`n"
    $s = Sync $E
    T 'a doc whose HEAD already quotes one triple, edited elsewhere, is not flagged' ($s.outcome -eq 'current') ($s.outcome + '/' + $s.class + ': ' + $s.why)
    T 'a lone ======= setext underline is not flagged' ($s.why -notmatch 'title\.md') $s.why
    $crlf = [Text.Encoding]::ASCII.GetBytes("<<<<<<< a`r`nx`r`n=======`r`ny`r`n>>>>>>> b`r`n")
    T 'Get-TcCsMarkerTriples: a CRLF triple counts 1' ((Get-TcCsMarkerTriples $crlf) -eq 1) ('' + (Get-TcCsMarkerTriples $crlf))
    $eight = [Text.Encoding]::ASCII.GetBytes("<<<<<<<< a`n=======`n>>>>>>> b`n")
    T 'Get-TcCsMarkerTriples: eight < is not a start marker' ((Get-TcCsMarkerTriples $eight) -eq 0) ('' + (Get-TcCsMarkerTriples $eight))
    $eqText = [Text.Encoding]::ASCII.GetBytes("<<<<<<< a`n======= no`n>>>>>>> b`n")
    T 'Get-TcCsMarkerTriples: ======= followed by text is not a separator' ((Get-TcCsMarkerTriples $eqText) -eq 0) ('' + (Get-TcCsMarkerTriples $eqText))
  }

  Invoke-Group 'MARKER SCAN AT THE BAR - a 52,428,800-byte dirty file is scanned; at 52,428,801 bytes it is listed unscanned' {
    $E = New-Estate 'marker-cap'
    W $E.bot 'data/big.txt' "small`n"; $null = GitOk $E.bot @('add', '-A'); $null = GitOk $E.bot @('commit', '-q', '-m', 'big file, small at HEAD')
    $head = [Text.Encoding]::ASCII.GetBytes("<<<<<<< a`n=======`n>>>>>>> b`n")
    $bar = 52428800
    $buf = [Text.Encoding]::ASCII.GetBytes(('a' * $bar)); [Array]::Copy($head, $buf, $head.Length)
    $big = Join-Path $E.bot 'data\big.txt'; [IO.File]::WriteAllBytes($big, $buf)
    $s = Sync $E
    T ('AT THE BAR: exactly ' + $bar + ' bytes is scanned and its triple blocks') (($s.outcome -eq 'blocked') -and ($s.class -eq 'conflict') -and ((New-Object IO.FileInfo($big)).Length -eq $bar)) ($s.outcome + '/' + $s.class + ': ' + $s.why)
    $fs = [IO.File]::Open($big, 'Append'); try { $fs.WriteByte(97) } finally { $fs.Dispose() }
    $s = Sync $E
    T ('ONE PAST: ' + ($bar + 1) + ' bytes is listed unscanned and never blocked') (($s.outcome -eq 'current') -and (@($s.unscanned) -contains 'data/big.txt')) ($s.outcome + '/' + $s.class + ' unscanned=' + (@($s.unscanned) -join ','))
  }

  Invoke-Group 'STARTUP PARSE - a startup file that does not parse at NEW moves nothing; one that parses reports startup_changed' {
    $E = New-Estate 'startup-bad'
    Push-Up $E 'grocery/capture-run.ps1' "function Broken {`n  if (`$true) {`n" 'up: a capture-run that does not parse'
    $b4 = Snap $E.bot
    $s = Sync $E @{ StartupFiles = $script:TcCheckoutSyncStartupFiles }
    T 'MUST FIRE: degraded class startup-parse naming the file' (($s.outcome -eq 'degraded') -and ($s.class -eq 'startup-parse') -and ($s.why -match 'grocery/capture-run\.ps1')) ($s.outcome + '/' + $s.class + ': ' + $s.why)
    T 'MUST FIRE: HEAD, index and tree byte-identical' ((Snap $E.bot) -eq $b4)
    $E = New-Estate 'startup-good'
    Push-Up $E 'grocery/capture-run.ps1' "param([string]`$Kind = 'daily')`nWrite-Output `$Kind`n" 'up: a capture-run that parses'
    $s = Sync $E @{ StartupFiles = $script:TcCheckoutSyncStartupFiles }
    T 'CLEAN TWIN: synced, startup_changed true, naming the file' (($s.outcome -eq 'synced') -and $s.startup_changed -and (@($s.startup_files) -contains 'grocery/capture-run.ps1')) ($s.outcome + ' changed=' + $s.startup_changed + ' ' + (@($s.startup_files) -join ','))
  }

  Invoke-Group 'THROW AFTER READ-TREE (M10 target) - an exception between the move and the ref leaves the undo copies on disk' {
    $E = New-Estate 'throw'
    Push-Up $E 'public/derived.json' "{`n  ""v"": 2, ""by"": ""other lane""`n}`n" 'up: derived'
    W $E.bot 'public/derived.json' "{`n  ""v"": 1, ""bot"": ""refused day""`n}`n"
    $localBytes = [IO.File]::ReadAllBytes((Join-Path $E.bot 'public/derived.json'))
    $s = Sync $E @{ OwnBlobs = @{ 'public/derived.json' = (OwnBlob $E 'public/derived.json') }; AfterReadTree = { throw 'injected after read-tree' } }
    T 'failed class mixed-tree, naming the injected throw' (($s.outcome -eq 'failed') -and ($s.class -eq 'mixed-tree') -and ($s.why -match 'injected after read-tree')) ($s.outcome + '/' + $s.class + ': ' + $s.why)
    $undo = if ($s.tree) { Join-Path $s.tree 'undo\public\derived.json' } else { '(no tree)' }
    T 'the undo copy is on disk and equals the displaced bytes' ((Test-Path -LiteralPath $undo) -and ([Convert]::ToBase64String([IO.File]::ReadAllBytes($undo)) -eq [Convert]::ToBase64String($localBytes))) $undo
    T 'HEAD did not move' ((GitR $E.bot @('rev-parse', 'HEAD')).out -eq $s.H0)
  }

  Invoke-Group 'FINGERPRINT MUST FIRE - a write to a dirty path OUTSIDE the move during the sync is caught (bar B4''s detector)' {
    $E = New-Estate 'fingerprint'
    Push-Up $E 'lib/code.ps1' "line1`nline2-FIX`nline3`nline4`nline5`n" 'up: code fix'
    W $E.bot 'grocery/ledger.json' "a`nb`nc`nsession day`n"
    $script:fxTouch = Join-Path $E.bot 'grocery\ledger.json'
    $s = Sync $E @{ BeforeRef = { (Get-Item -LiteralPath $script:fxTouch).LastWriteTime = [datetime]'2020-01-01T00:00:00' } }
    T 'failed class verify, naming the path whose mtime moved' (($s.outcome -eq 'failed') -and ($s.class -eq 'verify') -and ($s.why -match 'grocery/ledger\.json')) ($s.outcome + '/' + $s.class + ': ' + $s.why)
  }

  Invoke-Group 'ALREADY-UPSTREAM MUST NOT FIRE - a session file already holding upstream''s bytes is carried through untouched' {
    $E = New-Estate 'already'
    Push-Up $E 'lib/code.ps1' "line1`nline2-SAME`nline3`nline4`nline5`n" 'up: code'
    W $E.bot 'lib/code.ps1' "line1`nline2-SAME`nline3`nline4`nline5`n"
    $f = Join-Path $E.bot 'lib\code.ps1'; (Get-Item $f).LastWriteTime = [datetime]'2020-01-01T00:00:00'; $mt0 = Mtime $f
    $s = Sync $E
    T 'outcome is synced, listing it already upstream' (($s.outcome -eq 'synced') -and (@($s.already_upstream) -contains 'lib/code.ps1')) ($s.outcome + ': ' + $s.why)
    T 'its mtime is unchanged' ((Mtime $f) -eq $mt0)
    T 'it ends clean' (-not (Status $E.bot)) (Status $E.bot)
  }

  Invoke-Group '-z MUST NOT FIRE - a path holding a DEL byte, a space, an apostrophe and a non-ASCII letter round-trips exactly' {
    # NTFS forbids a double quote in a name; DEL (0x7F) is the character git still C-quotes with core.quotePath=false.
    # Under an OWNED path, so the untracked copy is the bot's and is quarantined (a non-owned one is FOREIGN, finding 3).
    $odd = 'grocery/odd dir/a b''s' + [char]0x7f + ' caf' + [char]0xe9 + '.json'
    $E = New-Estate 'nul-z'
    Push-Up $E $odd "upstream odd`n" 'up: an oddly named file'
    W $E.bot $odd "LOCAL odd`n"
    $s = Sync $E
    T 'synced, and the record names the path exactly' (($s.outcome -eq 'synced') -and (@($s.quarantined).Count -eq 1) -and [string]::Equals([string]@($s.quarantined)[0], $odd, [StringComparison]::Ordinal)) ($s.outcome + ': ' + (@($s.quarantined) -join ','))
    T 'the quarantined copy sits at the exact name with its bytes' ((ReadOr (InTree $s ('quarantine\' + ($odd -replace '/', '\')))) -eq "LOCAL odd`n")
  }

  Invoke-Group 'KILL SWITCH MUST FIRE - disabled with zero writes, paging once per date' {
    $E = New-Estate 'kill'
    Push-Up $E 'lib/other.ps1' "upstream`n" 'up: something to sync'
    $ks = Join-Path $E.bot '.git\tc-checkout-sync.disabled'; [IO.File]::WriteAllText($ks, "off`n", $script:fxUtf8)
    $b4 = Snap $E.bot; $d1 = [datetime]'2026-09-23T09:00:00'
    $s1 = Sync $E @{ Now = $d1 }
    T 'disabled, and nothing in the tree, the index or HEAD changed' (($s1.outcome -eq 'disabled') -and ((Snap $E.bot) -eq $b4)) ($s1.outcome + ': ' + $s1.why)
    T 'the first call on a date pages' ($s1.page -eq $true)
    $s2 = Sync $E @{ Now = $d1.AddHours(2) }
    T 'the second call on the same date does not' (($s2.outcome -eq 'disabled') -and ($s2.page -eq $false)) ('page=' + $s2.page)
    $s3 = Sync $E @{ Now = $d1.AddDays(1) }
    T 'CLEAN TWIN: the next date pages again' ($s3.page -eq $true) ('page=' + $s3.page)
  }

  Invoke-Group 'STARTUP FILES - the literal list equals what capture-run.ps1 dot-sources, and the scan can tell when it does not' {
    $crSrc = Join-Path (Split-Path -Parent $PSScriptRoot) 'grocery\capture-run.ps1'
    $crDir = Join-Path $script:fxRoot 'cr\grocery'; New-Item -ItemType Directory -Path $crDir | Out-Null
    $crCopy = Join-Path $crDir 'capture-run.ps1'; [IO.File]::Copy($crSrc, $crCopy)
    $scan = Get-TcCaptureRunDotSources -ScriptPath $crCopy
    $listed = @($script:TcCheckoutSyncStartupFiles | Sort-Object); $found = @($scan.files | Sort-Object)
    $diff = @(Compare-Object -ReferenceObject $listed -DifferenceObject $found -CaseSensitive | ForEach-Object { $_.SideIndicator + ' ' + $_.InputObject })
    T 'CLEAN TWIN: $script:TcCheckoutSyncStartupFiles equals the AST scan of capture-run.ps1' ($scan.ok -and (($listed -join ',') -ceq ($found -join ','))) ('ok=' + $scan.ok + ' ' + ($diff -join '; ') + ' ' + ($scan.unresolved -join '; '))
    $extra = Join-Path $crDir 'capture-run-extra.ps1'
    [IO.File]::WriteAllText($extra, ([IO.File]::ReadAllText($crSrc) + "`n. (Join-Path `$root 'extra-lib.ps1')`n"), $script:fxUtf8)
    $scan2 = Get-TcCaptureRunDotSources -ScriptPath $extra -ScriptRelName 'capture-run.ps1'
    T 'MUST FIRE: a new dot-source makes the scan differ from the list, naming it' (@($scan2.files) -contains 'grocery/extra-lib.ps1') (@($scan2.files) -join ',')
    $odd = Join-Path $crDir 'capture-run-odd.ps1'
    [IO.File]::WriteAllText($odd, ([IO.File]::ReadAllText($crSrc) + "`n. (Join-Path `$elsewhere 'x.ps1')`n"), $script:fxUtf8)
    $scan3 = Get-TcCaptureRunDotSources -ScriptPath $odd -ScriptRelName 'capture-run.ps1'
    T 'MUST FIRE: a dot-source on a base the scan does not read is reported unresolved, never guessed' ((-not $scan3.ok) -and ((@($scan3.unresolved) -join ' ') -match 'elsewhere')) ((@($scan3.unresolved) -join ' '))
  }

  Invoke-Group 'BOT COMMIT RESYNC (addendum) - a deletion a rename pairing hid from the old resync leaves the real index, and stays off disk' {
    $E = New-Estate 'resync'
    $flag = "capture due`nlanes: three`nsince 2026-09-18 07:00`n"
    W $E.up 'grocery/cap/due-2026-09-18.flag' $flag; $null = GitOk $E.up @('add', '-A'); $null = GitOk $E.up @('commit', '-q', '-m', 'flag'); $null = GitOk $E.up @('push', '-q', 'origin', 'HEAD:main')
    $null = GitOk $E.bot @('pull', '-q', 'origin', 'main')
    Remove-Item (Join-Path $E.bot 'grocery\cap\due-2026-09-18.flag'); W $E.bot 'grocery/cap/due-2026-09-23.flag' ($flag -replace '09-18', '09-23')
    $tmp = Join-Path $E.dir ('idx-' + [guid]::NewGuid().ToString('N')); $env:GIT_INDEX_FILE = $tmp
    try { $null = GitOk $E.bot @('read-tree', 'HEAD'); $null = GitOk $E.bot @('add', '-A', '--', 'grocery'); $null = GitOk $E.bot @('commit', '-q', '-m', 'Daily pipeline (private index)') }
    finally { Remove-Item Env:\GIT_INDEX_FILE; Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    # capture-run.ps1:1159's resync as it stands: `git show --name-only` pairs the deletion with the add as a rename.
    foreach ($cf in @((GitR $E.bot @('show', '--name-only', '--pretty=format:', 'HEAD')).out -split "`r?`n" | Where-Object { $_ })) { $null = GitR $E.bot @('reset', '-q', '--', $cf) }
    $pre = (GitR $E.bot @('ls-files', '--', 'grocery/cap/due-2026-09-18.flag')).out
    T 'precondition: the old resync leaves the deleted flag in the real index' ($pre -eq 'grocery/cap/due-2026-09-18.flag') $pre
    Push-Up $E 'lib/other.ps1' "upstream`n" 'up: moves on'
    $s = Sync $E @{ Phase = 'tail'; BotCommit = 'HEAD' }
    T 'synced, and index_resynced names the deleted flag' (($s.outcome -eq 'synced') -and (@($s.index_resynced) -contains 'grocery/cap/due-2026-09-18.flag')) ($s.outcome + ': ' + $s.why + ' resynced=' + (@($s.index_resynced) -join ','))
    T 'the deleted flag is absent from the index AND the disk, and the tree is clean' ((-not (GitR $E.bot @('ls-files', '--', 'grocery/cap/due-2026-09-18.flag')).out) -and -not (Test-Path (Join-Path $E.bot 'grocery\cap\due-2026-09-18.flag')) -and -not (Status $E.bot)) (Status $E.bot)
    $null = GitOk $E.bot @('push', '-q', 'origin', 'HEAD:main')
    $remoteTree = (GitR $E.remote @('ls-tree', '-r', '--name-only', 'refs/heads/main')).out -replace "`r?`n", ','
    T 'after the push, the remote tree lacks the deleted flag and holds the new one' (($remoteTree -notmatch 'due-2026-09-18') -and ($remoteTree -match 'due-2026-09-23')) $remoteTree
  }

  Invoke-Group 'GUARDS - the environment, a linked worktree, index.lock, a failed fetch, a local merge, an owned deletion' {
    $E = New-Estate 'guards'
    Push-Up $E 'public/derived.json' "{`n  ""v"": 2`n}`n" 'up: derived'
    $b4 = Snap $E.bot
    $env:GIT_INDEX_FILE = Join-Path $E.dir 'private-index'
    try { $s = Sync $E } finally { Remove-Item Env:\GIT_INDEX_FILE }
    T 'GIT_INDEX_FILE set: failed class environment, and nothing written' (($s.outcome -eq 'failed') -and ($s.class -eq 'environment') -and ((Snap $E.bot) -eq $b4)) ($s.outcome + '/' + $s.class + ': ' + $s.why)
    $logFile = Join-Path $E.bot '.git\tc-checkout-sync-log.jsonl'
    $rowsBefore = if (Test-Path $logFile) { @([IO.File]::ReadAllLines($logFile)).Count } else { 0 }
    $env:GIT_DIR = Join-Path $E.bot '.git'
    try { $s = Sync $E } finally { Remove-Item Env:\GIT_DIR }
    $rowsAfter = if (Test-Path $logFile) { @([IO.File]::ReadAllLines($logFile)).Count } else { 0 }
    T 'GIT_DIR set: skipped, and no log row written' (($s.outcome -eq 'skipped') -and ($rowsAfter -eq $rowsBefore)) ($s.outcome + ' rows ' + $rowsBefore + '->' + $rowsAfter)
    $wt = Join-Path $E.dir 'bot-wt'; $null = GitOk $E.bot @('worktree', 'add', '-q', '-b', 'wt', $wt)
    # A real fetch first, so FETCH_HEAD exists and its mtime can move: two absences would be an agreeing answer.
    $null = GitOk $E.bot @('fetch', '-q', 'origin'); $fh = Join-Path $E.bot '.git\FETCH_HEAD'; $fh0 = Mtime $fh
    $s = Invoke-TcCheckoutSync -Repo $wt -OwnedPaths $script:fxOwned -QuarantineRoot $E.q -IndexLockWaitSec 0 -InProgressWaitSec 0 -PollSec 0 -FetchAttempts 1 -StartupFiles @()
    T 'a linked worktree: skipped class linked-worktree' (($s.outcome -eq 'skipped') -and ($s.class -eq 'linked-worktree')) ($s.outcome + '/' + $s.class + ': ' + $s.why)
    T 'a linked worktree: never fetched (FETCH_HEAD''s mtime unchanged)' ((Mtime $fh) -eq $fh0)
    $lock = Join-Path $E.bot '.git\index.lock'; [IO.File]::WriteAllText($lock, '', $script:fxUtf8)
    try {
      $s = Sync $E
      T 'index.lock: degraded class index-lock, naming its age' (($s.outcome -eq 'degraded') -and ($s.class -eq 'index-lock') -and ($s.why -match 's old')) ($s.outcome + '/' + $s.class + ': ' + $s.why)
      T 'index.lock: never deleted' (Test-Path $lock)
    } finally { Remove-Item -LiteralPath $lock -Force }
    $url = (GitR $E.bot @('remote', 'get-url', 'origin')).out
    $null = GitOk $E.bot @('remote', 'set-url', 'origin', (Join-Path $E.dir 'no-such-remote.git'))
    $fd = [datetime]'2026-09-23T07:00:00'
    try { $s = Sync $E @{ Now = $fd }; $s2 = Sync $E @{ Now = $fd.AddHours(3) } } finally { $null = GitOk $E.bot @('remote', 'set-url', 'origin', $url) }
    T 'a failed fetch: degraded class fetch' (($s.outcome -eq 'degraded') -and ($s.class -eq 'fetch')) ($s.outcome + '/' + $s.class + ': ' + $s.why)
    T 'a failed fetch pages once a date (finding 12: nothing else pages it until the watchdog floor lands), and not twice' (($s.page -eq $true) -and ($s2.outcome -eq 'degraded') -and ($s2.page -eq $false)) ('page=' + $s.page + ' then ' + $s2.page)
    Remove-Item (Join-Path $E.bot 'public\derived.json')
    $s = Sync $E
    T 'an owned deletion on a path upstream changed: synced, listed own_deleted' (($s.outcome -eq 'synced') -and (@($s.own_deleted) -contains 'public/derived.json')) ($s.outcome + '/' + $s.class + ': ' + $s.why)
    T 'an owned deletion: upstream''s version comes back' ((ReadOr (Join-Path $E.bot 'public/derived.json')) -eq "{`n  ""v"": 2`n}`n")
    $null = GitOk $E.bot @('checkout', '-q', '-b', 'topic'); W $E.bot 'lib/t.ps1' "t`n"; $null = GitOk $E.bot @('add', '-A'); $null = GitOk $E.bot @('commit', '-q', '-m', 'topic')
    $null = GitOk $E.bot @('checkout', '-q', 'main'); $null = GitOk $E.bot @('merge', '-q', '--no-ff', '-m', 'local merge', 'topic')
    Push-Up $E 'lib/other.ps1' "upstream`n" 'up: moves on'
    $s = Sync $E @{ Phase = 'tail' }
    T 'a local merge commit: degraded class merge, never linearised' (($s.outcome -eq 'degraded') -and ($s.class -eq 'merge')) ($s.outcome + '/' + $s.class + ': ' + $s.why)
  }

  Invoke-Group 'RECORD - the state file and one log row per sync, carrying this file''s blob' {
    $E = New-Estate 'record'
    Push-Up $E 'lib/other.ps1' "upstream`n" 'up: something to sync'
    $s = Sync $E @{ Kind = 'daily' }
    $state = [IO.File]::ReadAllText((Join-Path $E.bot '.git\tc-checkout-sync.json')) | ConvertFrom-Json
    T 'the state file''s last record is this sync' (($s.outcome -eq 'synced') -and ($state.last.outcome -eq 'synced') -and ($state.last.NEW -eq $s.NEW)) ($s.outcome + ' state=' + $state.last.outcome)
    $rows = @([IO.File]::ReadAllLines((Join-Path $E.bot '.git\tc-checkout-sync-log.jsonl')) | Where-Object { $_ })
    $row = if ($rows.Count) { $rows[0] | ConvertFrom-Json } else { $null }
    T 'one log row, with kind, phase, outcome and behind_after' (($rows.Count -eq 1) -and ($row.kind -eq 'daily') -and ($row.phase -eq 'start') -and ($row.outcome -eq 'synced') -and ($row.behind_after -eq 0)) ('rows=' + $rows.Count)
    $want = (Invoke-GitCaptured -Repo $PSScriptRoot -GitArgs @('hash-object', '--', (Join-Path $PSScriptRoot 'checkout-sync.ps1'))).stdout.Trim()
    T 'lib_blob is the hash-object of lib\checkout-sync.ps1' ($row -and ($row.lib_blob -eq $want) -and ($want.Length -eq 40)) ('row=' + $(if ($row) { $row.lib_blob } else { '' }) + ' want=' + $want)
  }

  Invoke-Group 'CORE.AUTOCRLF=TRUE CLEAN TWIN - the production config: a CRLF owned merge keeps CRLF, a CRLF session copy of upstream is already upstream' {
    $E = New-Estate 'crlf' -AutoCrlf
    Push-Up $E 'grocery/ledger.json' "a-UP`nb`nc`n" 'up: ledger head'
    Push-Up $E 'lib/code.ps1' "line1`nline2-SAME`nline3`nline4`nline5`n" 'up: code'
    [IO.File]::WriteAllText((Join-Path $E.bot 'grocery\ledger.json'), "a`r`nb`r`nc`r`nday`r`n", $script:fxUtf8)
    [IO.File]::WriteAllText((Join-Path $E.bot 'lib\code.ps1'), "line1`r`nline2-SAME`r`nline3`r`nline4`r`nline5`r`n", $script:fxUtf8)
    $f = Join-Path $E.bot 'lib\code.ps1'; (Get-Item $f).LastWriteTime = [datetime]'2020-01-01T00:00:00'; $mt0 = Mtime $f
    $s = Sync $E @{ OwnBlobs = @{ 'grocery/ledger.json' = (OwnBlob $E 'grocery/ledger.json') } }
    T 'the owned CRLF edit merges cleanly and keeps CRLF' (($s.outcome -eq 'synced') -and ((ReadOr (Join-Path $E.bot 'grocery/ledger.json')) -eq "a-UP`r`nb`r`nc`r`nday`r`n")) ($s.outcome + ': ' + $s.why + ' | ' + ((ReadOr (Join-Path $E.bot 'grocery/ledger.json')) -replace "`r", '\r' -replace "`n", '\n'))
    T 'the CRLF session copy of upstream is already upstream, mtime unchanged' ((@($s.already_upstream) -contains 'lib/code.ps1') -and ((Mtime $f) -eq $mt0)) ((@($s.already_upstream) -join ','))
  }

  Invoke-Group 'IN-THE-WAY FOREIGN MUST FIRE - a session''s untracked draft OUTSIDE the owned paths where upstream adds the path is never moved' {
    $E = New-Estate 'itw-foreign'
    Push-Up $E 'lib/new.ps1' "upstream version`n" 'up: add lib/new.ps1'
    W $E.bot 'lib/new.ps1' "session draft`n"
    $f = Join-Path $E.bot 'lib\new.ps1'; (Get-Item $f).LastWriteTime = [datetime]'2020-01-01T00:00:00'; $md0 = Md5 $f; $mt0 = Mtime $f; $b4 = Snap $E.bot
    $s = Sync $E
    T 'MUST FIRE: blocked class foreign naming the draft, nothing quarantined' (($s.outcome -eq 'blocked') -and ($s.class -eq 'foreign') -and (($s.foreign -join ' ') -match 'lib/new\.ps1') -and (@($s.quarantined).Count -eq 0)) ($s.outcome + '/' + $s.class + ': ' + $s.why)
    T 'MUST FIRE: the draft''s bytes and mtime, the index and HEAD are identical' (((Md5 $f) -eq $md0) -and ((Mtime $f) -eq $mt0) -and ((Snap $E.bot) -eq $b4)) (ReadOr $f)
    $E = New-Estate 'itw-same'
    Push-Up $E 'lib/new.ps1' "upstream version`n" 'up: add lib/new.ps1'
    W $E.bot 'lib/new.ps1' "upstream version`n"
    $f = Join-Path $E.bot 'lib\new.ps1'; (Get-Item $f).LastWriteTime = [datetime]'2020-01-01T00:00:00'; $mt0 = Mtime $f
    $s = Sync $E
    T 'CLEAN TWIN: the same untracked file already holding upstream''s blob is carried by an index update, mtime unchanged, clean' (($s.outcome -eq 'synced') -and (@($s.already_upstream) -contains 'lib/new.ps1') -and ((Mtime $f) -eq $mt0) -and -not (Status $E.bot)) ($s.outcome + ': ' + $s.why + ' | ' + (Status $E.bot))
  }

  Invoke-Group 'SESSION SAVE CLEAN TWIN - a session saving its OWN dirty file outside the move mid-sync is a note, not a verify failure' {
    $E = New-Estate 'save-outside'
    Push-Up $E 'lib/code.ps1' "line1`nline2-FIX`nline3`nline4`nline5`n" 'up: code fix'
    W $E.bot 'tools/verifier.txt' "session edit`n"
    $script:fxTouch = Join-Path $E.bot 'tools\verifier.txt'; (Get-Item $script:fxTouch).LastWriteTime = [datetime]'2020-01-01T00:00:00'
    $s = Sync $E @{ BeforeRef = { [IO.File]::WriteAllText($script:fxTouch, "session edit, saved again mid-sync`n", $script:fxUtf8) } }
    T 'synced, with a note naming the saved path' (($s.outcome -eq 'synced') -and ((@($s.notes) -join ' ') -match 'saved by someone else during the sync.*tools/verifier\.txt')) ($s.outcome + '/' + $s.class + ': ' + $s.why + ' | ' + (@($s.notes) -join ' '))
    T 'the session''s save is intact and upstream''s fix arrived' (((ReadOr $script:fxTouch) -eq "session edit, saved again mid-sync`n") -and ((ReadOr (Join-Path $E.bot 'lib/code.ps1')) -match 'line2-FIX'))
  }

  Invoke-Group 'MARKER SCAN SHARES MUST NOT FIRE - a lane holding a dirty tracked file open for WRITING does not break the step 1e read' {
    $E = New-Estate 'scan-shared'
    W $E.bot 'grocery/ledger.json' "a`nb`nc`nlane writing`n"
    $lf = Join-Path $E.bot 'grocery\ledger.json'
    $w = New-Object IO.FileStream($lf, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    try { $s = Sync $E } finally { $w.Dispose() }
    T 'outcome is current, never failed/exception' ($s.outcome -eq 'current') ($s.outcome + '/' + $s.class + ': ' + $s.why)
  }

  Invoke-Group 'REF-LOCK MUST FIRE - update-ref cannot lock the branch and nothing committed on top: HEAD, index and tree all end at H0, and the next sync heals' {
    $E = New-Estate 'reflock'
    Push-Up $E 'lib/code.ps1' "line1`nline2-FIX`nline3`nline4`nline5`n" 'up: code fix'
    Push-Up $E 'grocery/cap/report.json' "upstream report`n" 'up: add report'
    W $E.bot 'grocery/cap/report.json' "LOCAL untracked`n"; W $E.bot 'tools/verifier.txt' "session edit`n"
    $st0 = Status $E.bot; $h0 = (GitR $E.bot @('rev-parse', 'HEAD')).out
    $script:fxLock = Join-Path $E.bot '.git\refs\heads\main.lock'
    try {
      $s = Sync $E @{ BeforeRef = { [IO.File]::WriteAllText($script:fxLock, '', $script:fxUtf8) } }
      T 'degraded class ref-lock, not failed/mixed-tree' (($s.outcome -eq 'degraded') -and ($s.class -eq 'ref-lock')) ($s.outcome + '/' + $s.class + ': ' + $s.why)
      T 'HEAD is H0, the status is exactly what it was, and every changed path holds its H0 or local bytes' (((GitR $E.bot @('rev-parse', 'HEAD')).out -eq $h0) -and ((Status $E.bot) -eq $st0) -and ((ReadOr (Join-Path $E.bot 'lib/code.ps1')) -eq "line1`nline2`nline3`nline4`nline5`n") -and ((ReadOr (Join-Path $E.bot 'grocery/cap/report.json')) -eq "LOCAL untracked`n")) ((Status $E.bot) + ' VS ' + $st0)
    } finally { Remove-Item -LiteralPath $script:fxLock -Force -ErrorAction SilentlyContinue }
    $s = Sync $E
    T 'CLEAN TWIN: with the lock gone the next sync ends synced, never blocked/foreign' (($s.outcome -eq 'synced') -and ((GitR $E.bot @('rev-parse', 'HEAD')).out -eq $s.O) -and ((ReadOr (Join-Path $E.bot 'lib/code.ps1')) -match 'line2-FIX')) ($s.outcome + '/' + $s.class + ': ' + $s.why)
  }

  function Write-FxIntent($E, [string]$H0, [string]$New, [int]$FakePid) {
    $doc = [ordered]@{ schema = 1; last = $null; intent = [ordered]@{ pid = $FakePid; phase = 'start'; started = '2026-09-23T07:00:00.0000000-05:00'; H0 = $H0; O = $New; NEW = $New; plan = @() }; disabled_paged_on = '' }
    [IO.File]::WriteAllText((Join-Path $E.bot '.git\tc-checkout-sync.json'), ($doc | ConvertTo-Json -Depth 6), $script:fxUtf8)
  }
  function Get-FxIntent($E) { $j = [IO.File]::ReadAllText((Join-Path $E.bot '.git\tc-checkout-sync.json')) | ConvertFrom-Json; return $j.intent }

  Invoke-Group 'INTERRUPTED MUST FIRE - a sync killed between read-tree and update-ref is FINISHED by the next one, never misread as a session''s work' {
    $E = New-Estate 'killed'
    Push-Up $E 'lib/code.ps1' "line1`nline2-FIX`nline3`nline4`nline5`n" 'up: code fix'
    W $E.bot 'lib/wip.ps1' "session wip`n"
    $null = GitOk $E.bot @('fetch', '-q', 'origin')
    $h0 = (GitR $E.bot @('rev-parse', 'HEAD')).out; $o = (GitR $E.bot @('rev-parse', 'refs/remotes/origin/main')).out
    $null = GitOk $E.bot @('read-tree', '-m', '-u', $h0, $o)   # exactly what a kill after 9e leaves
    Write-FxIntent $E $h0 $o 4242
    $s = Sync $E
    T 'the next sync finishes it: HEAD is origin, and a note names the interrupted run' (((GitR $E.bot @('rev-parse', 'HEAD')).out -eq $o) -and ($s.outcome -eq 'current') -and ((@($s.notes) -join ' ') -match 'finished a sync interrupted earlier \(pid 4242')) ($s.outcome + '/' + $s.class + ': ' + $s.why + ' | ' + (@($s.notes) -join ' '))
    T 'the tree is clean but the session WIP, and the resolved intent is cleared' (((Status $E.bot) -eq '?? lib/wip.ps1') -and ($null -eq (Get-FxIntent $E))) (Status $E.bot)
  }

  Invoke-Group 'INTERRUPTED LEFTOVER MUST FIRE - an intent the next sync cannot finish is named on its page and KEPT, never erased' {
    $E = New-Estate 'killed-mixed'
    Push-Up $E 'lib/code.ps1' "line1`nline2-FIX`nline3`nline4`nline5`n" 'up: code fix'
    $null = GitOk $E.bot @('fetch', '-q', 'origin')
    $h0 = (GitR $E.bot @('rev-parse', 'HEAD')).out; $o = (GitR $E.bot @('rev-parse', 'refs/remotes/origin/main')).out
    $null = GitOk $E.bot @('read-tree', '-m', $h0, $o)   # the index at NEW, the tree still at H0: not finishable
    Write-FxIntent $E $h0 $o 4343
    $b4 = Snap $E.bot
    $s = Sync $E
    $kept = Get-FxIntent $E
    T 'not clean, and the page names the interrupted run' (($s.outcome -ne 'synced') -and ($s.outcome -ne 'current') -and $s.page -and ($s.why -match 'pid 4343')) ($s.outcome + '/' + $s.class + ': ' + $s.why)
    T 'the leftover intent is kept, and nothing in the tree, the index or HEAD changed' ($kept -and ([int]$kept.pid -eq 4343) -and ((Snap $E.bot) -eq $b4)) ('intent=' + $(if ($kept) { $kept.pid } else { 'null' }))
  }

  Invoke-Group 'HEAD-MOVED AND BEFORE-MOVE THROW MUST FIRE - every displaced byte is put back with its mtime (the two put-backs no case reached)' {
    foreach ($arm in 'head-moved', 'throws') {
      $E = New-Estate ('putback-' + $arm)
      Push-Up $E 'public/derived.json' "{`n  ""v"": 2, ""by"": ""other lane""`n}`n" 'up: derived'
      Push-Up $E 'grocery/cap/report.json' "upstream report`n" 'up: add report'
      W $E.bot 'public/derived.json' "{`n  ""v"": 1, ""bot"": ""refused day""`n}`n"; W $E.bot 'grocery/cap/report.json' "LOCAL untracked`n"
      $df = Join-Path $E.bot 'public\derived.json'; $rf = Join-Path $E.bot 'grocery\cap\report.json'
      foreach ($x in $df, $rf) { (Get-Item $x).LastWriteTime = [datetime]'2020-01-01T00:00:00' }
      $dmd = Md5 $df; $dmt = Mtime $df; $rmd = Md5 $rf; $rmt = Mtime $rf
      $script:fxBot = $E.bot
      $bm = if ($arm -eq 'head-moved') { { W $script:fxBot 'docs/s.md' "a session note`n"; $null = GitOk $script:fxBot @('add', 'docs/s.md'); $null = GitOk $script:fxBot @('commit', '-q', '-m', 'Session commit while the sync planned') } } else { { throw 'injected before the move' } }
      $s = Sync $E @{ OwnBlobs = @{ 'public/derived.json' = (OwnBlob $E 'public/derived.json') }; BeforeMove = $bm }
      $want = if ($arm -eq 'head-moved') { ($s.outcome -eq 'degraded') -and ($s.class -eq 'head-moved') } else { ($s.outcome -eq 'failed') -and ($s.class -eq 'exception') -and ($s.why -match 'injected before the move') }
      T ('MUST FIRE (' + $arm + '): the outcome names it, and a set-aside and a quarantine had both happened') ($want -and (@($s.set_aside) -contains 'public/derived.json') -and (@($s.quarantined) -contains 'grocery/cap/report.json')) ($s.outcome + '/' + $s.class + ': ' + $s.why)
      T ('MUST FIRE (' + $arm + '): both displaced files are back, byte- and mtime-identical') (((Md5 $df) -eq $dmd) -and ((Mtime $df) -eq $dmt) -and ((Md5 $rf) -eq $rmd) -and ((Mtime $rf) -eq $rmt)) ((ReadOr $df) + ' | ' + (ReadOr $rf))
    }
  }

  Invoke-Group 'FETCH BOUND MUST FIRE - a remote that never answers is cut off at -FetchTimeoutSec: degraded class fetch' {
    $E = New-Estate 'fetch-hang'
    Push-Up $E 'lib/other.ps1' "upstream`n" 'up: something to sync'
    # The stall is an MSYS `sleep`, which the shell forks then execs, so its Windows parent is a transient sh outside the
    # tree taskkill /T walks: it is orphaned and ends on its own, hence 20 s and not longer (git's own transports are direct
    # children of git.exe and are killed).
    $null = GitOk $E.bot @('config', 'remote.origin.uploadpack', 'sleep 20; git-upload-pack')
    $s = Sync $E @{ FetchTimeoutSec = 3 }
    T 'degraded class fetch, naming the timeout (a 20 s stall that finished would read synced)' (($s.outcome -eq 'degraded') -and ($s.class -eq 'fetch') -and ($s.why -match 'timed out')) ($s.outcome + '/' + $s.class + ': ' + $s.why)
  }

  Invoke-Group 'STATE HELD MUST FIRE - a reader holding the state file open does not cost the log row' {
    $E = New-Estate 'state-held'
    $null = Sync $E
    $logFile = Join-Path $E.bot '.git\tc-checkout-sync-log.jsonl'; $rows0 = @([IO.File]::ReadAllLines($logFile) | Where-Object { $_ }).Count
    $hold = [IO.File]::Open((Join-Path $E.bot '.git\tc-checkout-sync.json'), 'Open', 'Read', 'ReadWrite')
    try { $s = Sync $E } finally { $hold.Dispose() }
    $rows1 = @([IO.File]::ReadAllLines($logFile) | Where-Object { $_ }).Count
    T 'the row count rose by one and the record says it logged' (($rows1 -eq $rows0 + 1) -and $s.logged -and ($s.outcome -eq 'current')) ('rows ' + $rows0 + '->' + $rows1 + ' logged=' + $s.logged + ' ' + $s.outcome)
  }
} finally {
  if ($script:fxHold) { try { $script:fxHold.Dispose() } catch { } }
  Remove-Item -LiteralPath $script:fxRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$ran = $script:pass + $script:fail
Write-Output ''
Write-Output ('checkout-sync: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $ran + ' of ' + $EXPECTED_CASES + ' literal cases ran')
if ($script:fail -or $ran -ne $EXPECTED_CASES) {
  if ($ran -ne $EXPECTED_CASES) { Write-Output ('  FAIL  the suite ran ' + $ran + ' cases where the file declares ' + $EXPECTED_CASES) }
  Write-Output 'CHECKOUT-SYNC SELF-TEST FAIL'
  exit 1
}
Write-Output 'CHECKOUT-SYNC SELF-TEST PASS'
exit 0
