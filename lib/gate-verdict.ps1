<#
  gate-verdict.ps1 - a green run-gates verdict, kept for the exact content it judged, so that content is not judged twice.

  Dot-source:  . (Join-Path $repoRoot 'lib\gate-verdict.ps1')
  Self-test:   powershell -File lib\gate-verdict.ps1 -SelfTest

  WHY (2026-09-11). The machine-wide gate budget was saturated all afternoon (design\MEASURE-gate-slot-starvation-
  2026-09-11.md), and part of the demand was one tree judged twice. About half of the completed runs that day were a
  session's own run-gates rather than a push - 19 of about 37 in the 15:00 hour - and the shape in the process table
  was a session that runs the gate, reads its exit code and then pushes, so the pre-push hook runs the identical tree
  again. Of 205 completed runs in the live worktrees, 32 ran over the same HEAD as that checkout's previous completed
  run. That is not a clean duplicate count in either direction: an uncommitted edit between two such runs makes the
  second one needed, and a commit of exactly the tree just gated is a duplicate a HEAD comparison cannot see.

  THE RULE. run-gates records a verdict only when it EXITS 0 and the checkout's fingerprint after the run is the one
  it took before. A later run in the SAME checkout whose fingerprint matches, within $TcGateVerdictMaxAgeMin, prints
  PASSED with the recorded count and dispatches nothing. A red or could-not-evaluate run over that content WITHDRAWS
  the recorded pass: gates that disagree with themselves over one tree have not given a verdict worth reusing.
  run-gates -NoReuse always runs them.

  THE FINGERPRINT (Get-TcGateFingerprint) is SHA-256 over two things:
    1. A CONTENT MAP of the checkout, path to hash. It starts as `git ls-tree -r HEAD` - what the commit holds - and
       every path `git status` reports takes its WORKING TREE value instead, hashed by git itself through the filters
       a commit would apply, while a path that is gone leaves the map. A path git does not track and does not ignore
       enters it the same way. So the map is CONTENT, not history: the fingerprint of a dirty tree and of the commit
       that records exactly those bytes is the SAME, which is what makes the common shape - gate, commit, push - pay
       once. The HEAD tree id is deliberately NOT in the key: two commits holding identical content are one job.
    2. The RAW BYTES of every script the gate's own discovery walked. That covers an IGNORED script discovery would
       still run, and a line-ending flip: CLAUDE.md records golden-test and ghost-drift going red over bytes alone,
       and git's own hash would normalise that away for a path with an eol attribute.
  Whatever the caller adds (run-gates adds the PowerShell and Python it runs with) is hashed too. git status runs with
  --no-optional-locks, so taking a fingerprint never takes the index lock a session's own commit needs.

  THE GAP, stated rather than papered over: for a tracked file that is NOT a script, the map holds git's hash, so a
  change git's own filters normalise away reads as the same content. That is git's view of the file too. Byte
  sensitivity is kept exactly where this estate has been bitten by it, which is the scripts.

  SAME CHECKOUT ONLY. An ignored file that is not a script - a gitignored corpus, the root debris the stray-artifacts
  audit reads, a venv - is outside the fingerprint. The gates are hermetic by design, so those should not move a
  verdict; the rule leans on that only inside one checkout (the verdict records its repo path and lives in that
  checkout's ignored ops\out) and only for $TcGateVerdictMaxAgeMin.

  THE TUNING CONSTANT: 180 minutes. The first plausible number, NOT a sweep: long enough to span a session's own run
  and its push through the queue as measured that day (a push waited up to 1,010 s for a slot and then ran for up to
  1,864 s), short enough that an ignored input rarely moves under it. When the producer stops - no green run - there is
  no verdict and every run runs.

  SCOPE OF A CLEAN REPORT: a reuse proves the fingerprinted inputs matched a run that exited 0. It proves nothing
  about an input outside the fingerprint, and a nondeterministic gate that passed once stays passed for that content
  until a red run over it withdraws the verdict. The self-test drives every rule against a real git checkout in a
  per-run temp directory.

  NO param() BLOCK: dot-sourced under PS 5.1 a param() block runs in the CALLER's scope (lib\guard-contract.ps1).
#>
$__gvSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')
. (Join-Path $PSScriptRoot 'atomic-write.ps1')   # Write-TcAtomicFile

$script:TcGateVerdictMaxAgeMin = 180

function Get-TcBytesSha256 {
  <# SHA-256 of a file's bytes; 'absent' for no file, 'unreadable' when it cannot be opened. Opened with Delete
     sharing, so a writer replacing the file through a temp rename is never blocked by this read. #>
  param([string]$Path)
  if (-not [IO.File]::Exists($Path)) { return 'absent' }
  $fs = $null; $sha = $null
  try {
    $share = [IO.FileShare]([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    $sha = [Security.Cryptography.SHA256]::Create()
    return ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLowerInvariant()
  } catch {
    return 'unreadable'
  } finally {
    if ($fs) { $fs.Dispose() }
    if ($sha) { $sha.Dispose() }
  }
}

function Get-TcGitBlobHashes {
  <# git's own blob hash for each path's WORKING TREE bytes, through the filters a commit would apply, so a hash taken
     before a commit equals the blob that commit stores. Returns a path -> hash table; a path git could not hash is
     absent, and the caller must fall back rather than keep a stale value. Batched, because a command line is bounded. #>
  param([string]$Repo, [string[]]$Paths)
  $map = New-Object Collections.Hashtable ([StringComparer]::Ordinal)
  $list = @($Paths | Where-Object { $_ })
  if ($list.Count -eq 0) { return $map }
  $eap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $i = 0
    while ($i -lt $list.Count) {
      $last = [Math]::Min($i + 199, $list.Count - 1)
      $batch = @($list[$i..$last])
      $res = @(& git -C $Repo hash-object -- @batch 2>$null)
      if ($LASTEXITCODE -eq 0 -and $res.Count -eq $batch.Count) {
        for ($k = 0; $k -lt $batch.Count; $k++) { $map[$batch[$k]] = ([string]$res[$k]).Trim() }
      }
      $i = $last + 1
    }
  } catch {
    # A path git cannot hash is simply absent from the map; Get-TcGateFingerprint hashes its bytes instead.
  } finally {
    $ErrorActionPreference = $eap
  }
  return $map
}

function Get-TcGateFingerprint {
  <# Fingerprint (hex, or $null when git cannot read the checkout, with Reason saying why), Entries and Tree. #>
  param([Parameter(Mandatory = $true)][string]$Repo, [string[]]$Files = @(), [string[]]$Extra = @())
  $treeId = ''; $lsTree = @(); $status = @(); $why = ''
  $eap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $tree = @(& git -C $Repo rev-parse --verify -q 'HEAD^{tree}' 2>$null)
    if ($LASTEXITCODE -ne 0 -or $tree.Count -lt 1 -or ([string]$tree[0]).Trim() -notmatch '^[0-9a-f]{40}([0-9a-f]{24})?$') {
      $why = 'git could not name the HEAD tree of this checkout'
    } else {
      $treeId = ([string]$tree[0]).Trim()
      $lsTree = @(& git -C $Repo ls-tree -r -z HEAD 2>$null)
      if ($LASTEXITCODE -ne 0) {
        $why = 'git ls-tree failed in this checkout'
      } else {
        $status = @(& git --no-optional-locks -C $Repo status --porcelain=v1 -z --untracked-files=all --no-renames 2>$null)
        if ($LASTEXITCODE -ne 0) { $why = 'git status failed in this checkout' }
      }
    }
  } catch {
    $why = 'git could not be run: ' + $_.Exception.Message
  } finally {
    $ErrorActionPreference = $eap
  }
  if ($why) { return [pscustomobject]@{ Fingerprint = $null; Reason = $why; Entries = 0; Tree = '' } }

  # THE CONTENT MAP: what the commit holds, then what the working tree says instead.
  $content = New-Object Collections.Hashtable ([StringComparer]::Ordinal)
  foreach ($e in (($lsTree -join "`n") -split [char]0)) {
    if (-not $e) { continue }
    $tab = $e.IndexOf("`t")
    if ($tab -lt 1) { continue }
    $meta = @(($e.Substring(0, $tab)) -split '\s+')
    if ($meta.Count -lt 3) { continue }
    $content[$e.Substring($tab + 1)] = [string]$meta[2]
  }
  $changed = [Collections.Generic.List[string]]::new()
  foreach ($e in (($status -join "`n") -split [char]0)) {
    if ($e.Length -lt 4) { continue }
    $rel = $e.Substring(3)
    if (-not $rel) { continue }
    if ([IO.File]::Exists((Join-Path $Repo ($rel -replace '/', '\')))) { $changed.Add($rel) }
    else { [void]$content.Remove($rel) }   # gone from the working tree, exactly as committing its deletion leaves it
  }
  if ($changed.Count) {
    $blobs = Get-TcGitBlobHashes -Repo $Repo -Paths $changed.ToArray()
    foreach ($rel in $changed) {
      if ($blobs.ContainsKey($rel)) { $content[$rel] = [string]$blobs[$rel] }
      else { $content[$rel] = 'raw:' + (Get-TcBytesSha256 (Join-Path $Repo ($rel -replace '/', '\'))) }
    }
  }

  $rows = [Collections.Generic.List[string]]::new()
  foreach ($k in @($content.Keys)) { $rows.Add('content ' + $k + ' ' + [string]$content[$k]) }
  $repoFull = [IO.Path]::GetFullPath($Repo).TrimEnd('\')
  foreach ($f in @($Files)) {
    if (-not $f) { continue }
    $full = [IO.Path]::GetFullPath([string]$f)
    $name = if ($full.StartsWith($repoFull + '\', [StringComparison]::OrdinalIgnoreCase)) { $full.Substring($repoFull.Length + 1) } else { $full }
    $rows.Add('file ' + $name + ' ' + (Get-TcBytesSha256 $full))
  }
  $sorted = $rows.ToArray()
  [Array]::Sort($sorted, [StringComparer]::Ordinal)
  $lines = [Collections.Generic.List[string]]::new()
  foreach ($r in $sorted) { $lines.Add($r) }
  foreach ($x in @($Extra)) { $lines.Add('extra ' + [string]$x) }
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $fp = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))) -replace '-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
  return [pscustomobject]@{ Fingerprint = $fp; Reason = ''; Entries = $lines.Count; Tree = $treeId }
}

function Get-TcWorkingTreeState {
  <# What checkout a path is standing in, and what content it holds, in the SAME key the push reuse uses.

     WHY IT LIVES HERE (2026-09-12). ops\observe-gate-queue.ps1 dot-sourced `lib\gate-pass-reuse.ps1` and called
     this function; NEITHER existed. `git grep` over origin/main found no definition anywhere and no such file,
     so every mode of the observer died on the dot-source and exited 3 - the estate's own no-load tool for
     "is the gate queue backing up" could not answer it, on the morning a queue was 9 deep with the oldest push
     waiting 13 minutes. The content key belongs beside the fingerprint the reuse keys on, which is here, so
     "the same tree twice" in the observer means exactly what it means at push time.

     Returns Ok, Top (the checkout root), HeadTree, ContentKey, Dirty (the porcelain lines) and Why. A checkout
     git cannot read comes back Ok=$false with Why saying so, never a guess: the observer prints these, and a
     fabricated key would read as a repeated tree that never happened.

     -ScratchDir is accepted because the caller passes it and ignored because nothing here needs a temp file. #>
  param([string]$Top, [string]$ScratchDir = '')
  $bad = { param($w) [pscustomobject]@{ Ok = $false; Top = ''; HeadTree = ''; ContentKey = $null; Dirty = @(); Why = $w } }
  if (-not $Top) { return (& $bad 'no path given') }
  if (-not [IO.Directory]::Exists($Top)) { return (& $bad ("not a directory: " + $Top)) }
  $root = ''
  $eap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = @(& git -C $Top rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -eq 0 -and $out.Count) { $root = ([string]$out[0]).Trim() -replace '/', '\' }
  } catch { } finally { $ErrorActionPreference = $eap }
  if (-not $root) { return (& $bad ("git could not name a checkout at " + $Top)) }
  $fp = Get-TcGateFingerprint -Repo $root
  $dirty = @()
  $eap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $st = @(& git --no-optional-locks -C $root status --porcelain 2>$null)
    if ($LASTEXITCODE -eq 0) { $dirty = @($st | Where-Object { $_ }) }
  } catch { } finally { $ErrorActionPreference = $eap }
  if (-not $fp.Fingerprint) {
    return [pscustomobject]@{ Ok = $false; Top = $root; HeadTree = $fp.Tree; ContentKey = $null; Dirty = $dirty; Why = $fp.Reason }
  }
  return [pscustomobject]@{ Ok = $true; Top = $root; HeadTree = $fp.Tree; ContentKey = $fp.Fingerprint; Dirty = $dirty; Why = '' }
}

function Read-TcGateVerdict {
  <# The recorded verdict, or $null for no file, an unreadable one, or one without a fingerprint. #>
  param([string]$Path)
  if (-not $Path -or -not [IO.File]::Exists($Path)) { return $null }
  try {
    $o = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    if ($null -eq $o -or -not $o.fingerprint) { return $null }
    return $o
  } catch {
    return $null
  }
}

function Test-TcGateVerdictReuse {
  <# Reuse (bool), Reason (the words run-gates prints either way), Passed and At. #>
  param([object]$Verdict, [string]$Fingerprint, [string]$Repo, [DateTime]$NowUtc, [int]$MaxAgeMin = $script:TcGateVerdictMaxAgeMin)
  $no = { param($w) [pscustomobject]@{ Reuse = $false; Reason = $w; Passed = 0; At = '' } }
  if (-not $Fingerprint) { return (& $no 'no fingerprint could be taken of this checkout') }
  if ($null -eq $Verdict) { return (& $no 'no green verdict is recorded in this checkout') }
  if (-not [string]::Equals([string]$Verdict.result, 'passed', [StringComparison]::Ordinal)) { return (& $no 'the recorded verdict is not a pass') }
  if (-not [string]::Equals([string]$Verdict.repo, $Repo, [StringComparison]::OrdinalIgnoreCase)) { return (& $no 'the recorded verdict belongs to another checkout') }
  if (-not [string]::Equals([string]$Verdict.fingerprint, $Fingerprint, [StringComparison]::Ordinal)) { return (& $no 'the content has changed since the last green run') }
  $ticks = 0L
  if (-not [long]::TryParse([string]$Verdict.utc_ticks, [ref]$ticks) -or $ticks -le 0) { return (& $no 'the recorded verdict carries no readable time') }
  $ageMin = ($NowUtc.Ticks - $ticks) / [TimeSpan]::TicksPerMinute
  if ($ageMin -lt 0) { return (& $no 'the recorded verdict is stamped in the future') }
  if ($ageMin -gt $MaxAgeMin) { return (& $no ('the last green run over this content is {0:N0} min old, over the {1}-minute limit' -f $ageMin, $MaxAgeMin)) }
  $passed = 0
  if (-not [int]::TryParse([string]$Verdict.passed, [ref]$passed) -or $passed -lt 1) { return (& $no 'the recorded verdict names no gate that passed') }
  return [pscustomobject]@{ Reuse = $true; Reason = ('the same content passed {0} gate(s) {1:N0} min ago' -f $passed, $ageMin); Passed = $passed; At = [string]$Verdict.utc }
}

function Save-TcGateVerdict {
  <# Records a green verdict for reuse, and returns what it did:
       recorded       exit 0, and the content did not move while the gates ran
       content-moved  exit 0, but the fingerprint after the run differs, so the pass describes neither version
       withdrawn      not exit 0, over the very content a recorded pass names: that pass is deleted
       not-green      not exit 0 over other content, or no gate passed; nothing recorded #>
  param([string]$Path, [int]$ExitCode, [string]$Before, [string]$After, [string]$Repo, [int]$Passed, [string]$Commit = '', [DateTime]$NowUtc = [DateTime]::UtcNow)
  if ($ExitCode -ne 0) {
    $old = Read-TcGateVerdict -Path $Path
    if ($old -and $Before -and [string]::Equals([string]$old.fingerprint, $Before, [StringComparison]::Ordinal)) {
      [IO.File]::Delete($Path)
      return 'withdrawn'
    }
    return 'not-green'
  }
  if (-not $Before -or -not [string]::Equals($Before, $After, [StringComparison]::Ordinal)) { return 'content-moved' }
  if ($Passed -lt 1) { return 'not-green' }
  $dir = Split-Path -Parent $Path
  if ($dir -and -not [IO.Directory]::Exists($dir)) { $null = [IO.Directory]::CreateDirectory($dir) }
  $rec = [ordered]@{ result = 'passed'; fingerprint = $Before; repo = $Repo; passed = $Passed; commit = $Commit; utc = $NowUtc.ToString('o'); utc_ticks = $NowUtc.Ticks; harness = 'ops\run-gates.ps1' }
  $null = Write-TcAtomicFile -Path $Path -Text ($rec | ConvertTo-Json -Compress) -NoBom -NoNewline
  return 'recorded'
}

if ($__gvSelfTest) {
  $ErrorActionPreference = 'Stop'
  $script:gvCases = 0; $script:gvFail = 0
  function Check([string]$Label, [bool]$Ok, [string]$Got = '') {
    $script:gvCases++
    if ($Ok) { Write-Output ('ok    ' + $Label) } else { Write-Output ('FAIL  ' + $Label + '   got: ' + $Got); $script:gvFail++ }
  }
  function Invoke-SandboxGit {
    $ErrorActionPreference = 'Continue'
    $o = & git @args 2>$null
    return [pscustomobject]@{ Rc = $LASTEXITCODE; Out = ((@($o) -join "`n").Trim()) }
  }
  $sb = Join-Path $env:TEMP ('tc-gv-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  try {
    $null = New-Item -ItemType Directory -Path $sb -ErrorAction Stop
    . (Join-Path $PSScriptRoot 'git-repo-env.ps1')
    Clear-TcGitRepoEnv
    $w = Join-Path $sb 'w'
    $utf8 = New-Object Text.UTF8Encoding($false)
    function Set-SandboxFile([string]$Rel, [string]$Text) { [IO.File]::WriteAllText((Join-Path $w $Rel), $Text, $utf8) }
    $null = Invoke-SandboxGit init -q $w
    $null = Invoke-SandboxGit -C $w config user.email t@t
    $null = Invoke-SandboxGit -C $w config user.name t
    $null = Invoke-SandboxGit -C $w config commit.gpgsign false
    $null = Invoke-SandboxGit -C $w config core.autocrlf false
    Set-SandboxFile 'gate.ps1' "Write-Output 'gate'`n"
    Set-SandboxFile 'data.json' "{`"v`":1}`n"
    Set-SandboxFile 'spare.json' "{`"s`":1}`n"
    Set-SandboxFile '.gitignore' "ignored.ps1`n"
    $null = Invoke-SandboxGit -C $w add -A
    $null = Invoke-SandboxGit -C $w commit -q -m seed
    Set-SandboxFile 'ignored.ps1' "Write-Output 'ignored'`n"
    $files = @((Join-Path $w 'gate.ps1'), (Join-Path $w 'ignored.ps1'))
    $extra = @('python=3.12.0')

    # ---- the fingerprint ----
    $fp0 = Get-TcGateFingerprint -Repo $w -Files $files -Extra $extra
    $fp0b = Get-TcGateFingerprint -Repo $w -Files $files -Extra $extra
    Check 'CLEAN TWIN  one checkout fingerprinted twice gives one real fingerprint' `
      (([string]$fp0.Fingerprint).Length -eq 64 -and $fp0.Fingerprint -eq $fp0b.Fingerprint) ("{0} / {1} ({2})" -f $fp0.Fingerprint, $fp0b.Fingerprint, $fp0.Reason)
    Set-SandboxFile 'data.json' "{`"v`":2}`n"
    $fpDirty = Get-TcGateFingerprint -Repo $w -Files $files -Extra $extra
    Check 'MUST FIRE  an uncommitted edit to a TRACKED data file changes the fingerprint - a gate reads that file' ($fpDirty.Fingerprint -and $fpDirty.Fingerprint -ne $fp0.Fingerprint) $fpDirty.Fingerprint
    # THE INVARIANCE THE WHOLE SAVING RESTS ON: the estate's habit is to gate a dirty tree and then commit it, so a
    # commit of exactly the bytes just fingerprinted must not change the fingerprint. The content map is keyed on
    # content, and git hashes the working tree the way the commit will store it.
    $null = Invoke-SandboxGit -C $w commit -q -am two
    $fpCommitted = Get-TcGateFingerprint -Repo $w -Files $files -Extra $extra
    $cleanNow = (Invoke-SandboxGit -C $w status --porcelain).Out
    Check 'CLEAN TWIN  committing the very bytes that were fingerprinted keeps the fingerprint - a commit moves history, not content' `
      ($fpCommitted.Fingerprint -eq $fpDirty.Fingerprint -and $cleanNow -eq '') ("dirty={0} committed={1} status=[{2}]" -f $fpDirty.Fingerprint, $fpCommitted.Fingerprint, $cleanNow)
    Set-SandboxFile 'data.json' "{`"v`":1}`n"
    $null = Invoke-SandboxGit -C $w commit -q -am back
    $fp = Get-TcGateFingerprint -Repo $w -Files $files -Extra $extra
    Check 'CLEAN TWIN  putting the same bytes back gives the first fingerprint again' ($fp.Fingerprint -eq $fp0.Fingerprint) $fp.Fingerprint
    Set-SandboxFile 'new.txt' "x`n"
    $fp = Get-TcGateFingerprint -Repo $w -Files $files -Extra $extra
    Check 'MUST FIRE  a new untracked file changes it' ($fp.Fingerprint -and $fp.Fingerprint -ne $fp0.Fingerprint) $fp.Fingerprint
    Remove-Item -LiteralPath (Join-Path $w 'new.txt')
    Remove-Item -LiteralPath (Join-Path $w 'spare.json')
    $fpDeleted = Get-TcGateFingerprint -Repo $w -Files $files -Extra $extra
    Check 'MUST FIRE  deleting a tracked file changes it, before anyone commits the deletion' ($fpDeleted.Fingerprint -and $fpDeleted.Fingerprint -ne $fp0.Fingerprint) $fpDeleted.Fingerprint
    $null = Invoke-SandboxGit -C $w commit -q -am 'drop spare'
    $fp = Get-TcGateFingerprint -Repo $w -Files $files -Extra $extra
    Check 'CLEAN TWIN  committing that deletion keeps the fingerprint the deletion already had' ($fp.Fingerprint -eq $fpDeleted.Fingerprint) ("deleted={0} committed={1}" -f $fpDeleted.Fingerprint, $fp.Fingerprint)
    $fpBase = $fp.Fingerprint
    Set-SandboxFile 'ignored.ps1' "Write-Output 'changed'`n"
    $fp = Get-TcGateFingerprint -Repo $w -Files $files -Extra $extra
    Check 'MUST FIRE  an edit to an IGNORED script that discovery would run changes it - git status cannot see that file' ($fp.Fingerprint -and $fp.Fingerprint -ne $fpBase) $fp.Fingerprint
    Set-SandboxFile 'ignored.ps1' "Write-Output 'ignored'`n"
    Set-SandboxFile 'gate.ps1' "Write-Output 'gate'`r`n"
    $fp = Get-TcGateFingerprint -Repo $w -Files $files -Extra $extra
    Check 'MUST FIRE  a line-ending flip of a script changes it - the gates read bytes' ($fp.Fingerprint -and $fp.Fingerprint -ne $fpBase) $fp.Fingerprint
    Set-SandboxFile 'gate.ps1' "Write-Output 'gate'`n"
    $fp = Get-TcGateFingerprint -Repo $w -Files $files -Extra @('python=3.13.0')
    Check 'MUST FIRE  a different interpreter changes it' ($fp.Fingerprint -and $fp.Fingerprint -ne $fpBase) $fp.Fingerprint
    $nr = Join-Path $sb 'not-a-repo'
    $null = New-Item -ItemType Directory -Path $nr
    $oldCeiling = $env:GIT_CEILING_DIRECTORIES
    $env:GIT_CEILING_DIRECTORIES = $sb
    try { $fpNr = Get-TcGateFingerprint -Repo $nr } finally { $env:GIT_CEILING_DIRECTORIES = $oldCeiling }
    Check 'MUST FIRE  a directory git cannot read gets NO fingerprint and a reason, never one that could match' ($null -eq $fpNr.Fingerprint -and [bool]$fpNr.Reason) ("fp={0} reason={1}" -f $fpNr.Fingerprint, $fpNr.Reason)

    # ---- recording and reusing a verdict ----
    $key = $fpBase
    $other = 'f' * 64
    $now = [DateTime]::UtcNow
    $vp = Join-Path $sb 'out-a\gate-verdict.json'
    $saved = Save-TcGateVerdict -Path $vp -ExitCode 0 -Before $key -After $key -Repo $w -Passed 7 -Commit 'abc1234' -NowUtc $now
    $v = Read-TcGateVerdict -Path $vp
    $t = Test-TcGateVerdictReuse -Verdict $v -Fingerprint $key -Repo $w -NowUtc $now.AddMinutes(5)
    Check 'CLEAN TWIN  a green run over unchanged content is recorded, and that content in that checkout reuses it with the recorded count' ($saved -eq 'recorded' -and $t.Reuse -and $t.Passed -eq 7) ("saved={0} reuse={1} reason={2}" -f $saved, $t.Reuse, $t.Reason)
    $t = Test-TcGateVerdictReuse -Verdict $v -Fingerprint $other -Repo $w -NowUtc $now.AddMinutes(5)
    Check 'MUST FIRE  changed content is never given the recorded pass' (-not $t.Reuse) $t.Reason
    $t = Test-TcGateVerdictReuse -Verdict $v -Fingerprint $key -Repo (Join-Path $sb 'elsewhere') -NowUtc $now.AddMinutes(5)
    Check 'MUST FIRE  another checkout is never given it - its ignored files are not these' (-not $t.Reuse) $t.Reason
    $t = Test-TcGateVerdictReuse -Verdict $v -Fingerprint $key -Repo $w -NowUtc $now.AddMinutes($script:TcGateVerdictMaxAgeMin + 1)
    Check 'MUST FIRE  a pass older than the age limit is not reused' (-not $t.Reuse) $t.Reason
    $t = Test-TcGateVerdictReuse -Verdict $v -Fingerprint $key -Repo $w -NowUtc $now.AddMinutes(-1)
    Check 'MUST FIRE  a pass stamped in the future is not reused' (-not $t.Reuse) $t.Reason
    $vp2 = Join-Path $sb 'out-b\gate-verdict.json'
    $r = Save-TcGateVerdict -Path $vp2 -ExitCode 1 -Before $key -After $key -Repo $w -Passed 7 -NowUtc $now
    Check 'MUST FIRE  a RED run records nothing' ($r -eq 'not-green' -and -not (Test-Path -LiteralPath $vp2)) $r
    $r = Save-TcGateVerdict -Path $vp2 -ExitCode 3 -Before $key -After $key -Repo $w -Passed 7 -NowUtc $now
    Check 'MUST FIRE  a could-not-evaluate run records nothing' ($r -eq 'not-green' -and -not (Test-Path -LiteralPath $vp2)) $r
    $r = Save-TcGateVerdict -Path $vp2 -ExitCode 0 -Before $key -After $other -Repo $w -Passed 7 -NowUtc $now
    Check 'MUST FIRE  content that moved while the gates ran records nothing - the pass describes neither version' ($r -eq 'content-moved' -and -not (Test-Path -LiteralPath $vp2)) $r
    $r = Save-TcGateVerdict -Path $vp -ExitCode 1 -Before $other -After $other -Repo $w -Passed 7 -NowUtc $now
    $still = Test-TcGateVerdictReuse -Verdict (Read-TcGateVerdict -Path $vp) -Fingerprint $key -Repo $w -NowUtc $now.AddMinutes(5)
    Check 'MUST NOT FIRE  a red run over OTHER content leaves the recorded pass for this content alone' ($r -eq 'not-green' -and $still.Reuse) ("result={0} stillReused={1}" -f $r, $still.Reuse)
    $r = Save-TcGateVerdict -Path $vp -ExitCode 1 -Before $key -After $key -Repo $w -Passed 7 -NowUtc $now
    Check 'MUST FIRE  a red run over content that once passed WITHDRAWS that pass - gates that disagree over one tree are no verdict' ($r -eq 'withdrawn' -and -not (Test-Path -LiteralPath $vp)) $r
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $vp2)
    [IO.File]::WriteAllText($vp2, 'not json {', $utf8)
    $vc = Read-TcGateVerdict -Path $vp2
    $t = Test-TcGateVerdictReuse -Verdict $vc -Fingerprint $key -Repo $w -NowUtc $now
    Check 'MUST FIRE  a corrupt verdict file reads as no verdict, never as a pass' ($null -eq $vc -and -not $t.Reuse) $t.Reason

    # ---- Get-TcWorkingTreeState: what ops\observe-gate-queue.ps1 asks, and it asked a file that did not exist ----
    # The observer dot-sourced lib\gate-pass-reuse.ps1 and called this; neither existed anywhere in the tree, so every
    # mode died on the dot-source and exited 3 (2026-09-12). These cases pin the shape the observer reads.
    $stRoot = Get-TcWorkingTreeState -Top $w
    $fpNow = Get-TcGateFingerprint -Repo $w
    Check 'CLEAN TWIN  a checkout reports its root, its HEAD tree and the SAME content key the reuse keys on' `
      ($stRoot.Ok -and $stRoot.ContentKey -eq $fpNow.Fingerprint -and $stRoot.HeadTree -eq $fpNow.Tree -and $stRoot.Top.TrimEnd('\') -ieq $w.TrimEnd('\')) `
      ("ok={0} key={1} top={2}" -f $stRoot.Ok, $stRoot.ContentKey, $stRoot.Top)
    # The observer hands it a process's CWD, which is usually BELOW the root - it must resolve, not refuse.
    $sub = Join-Path $w 'sub'
    $null = New-Item -ItemType Directory -Force -Path $sub
    $stSub = Get-TcWorkingTreeState -Top $sub
    Check 'CLEAN TWIN  a path BELOW the checkout resolves to the checkout root, which is what a process CWD gives it' `
      ($stSub.Ok -and $stSub.Top.TrimEnd('\') -ieq $w.TrimEnd('\')) ("ok={0} top={1}" -f $stSub.Ok, $stSub.Top)
    # MUST FIRE: a path git cannot name is NOT a content key. A guess here would read in the observer as two runs
    # over the same tree that never happened.
    $stNo = Get-TcWorkingTreeState -Top $sb
    Check 'MUST FIRE  a directory that is not a checkout comes back NOT ok, with a reason and no content key' `
      ((-not $stNo.Ok) -and $null -eq $stNo.ContentKey -and $stNo.Why) ("ok={0} key={1} why={2}" -f $stNo.Ok, $stNo.ContentKey, $stNo.Why)
  } catch {
    $script:gvFail++
    Write-Output ('FAIL  the self-test threw: ' + $_.Exception.Message)
  } finally {
    Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue
  }
  # A SUITE CAN RUN ZERO CASES AND EXIT 0: the count is asserted, so a block that stops early cannot read as a pass.
  if ($script:gvCases -lt 25) { $script:gvFail++; Write-Output ('FAIL  only {0} of 25 cases ran' -f $script:gvCases) }
  if ($script:gvFail) { Write-Output ('gate-verdict SELF-TEST FAIL: {0} failure(s) over {1} case(s)' -f $script:gvFail, $script:gvCases); exit 1 }
  Write-Output ('gate-verdict SELF-TEST PASS: {0} cases - led by a commit of the very bytes already fingerprinted keeping the fingerprint, a red run withdrawing the pass it contradicts, and an edit to an ignored script changing it' -f $script:gvCases)
  exit 0
}
