# atomic-write.ps1 - replace a whole file with new text without losing the write to a READER.
#
# WHY THIS EXISTS (2026-09-11). Every single-file ledger here writes `Set-Content x.tmp` then
# `Move-Item x.tmp x -Force`, inside a named mutex. The mutex serialises WRITERS. It cannot serialise
# READERS, which take no lock: a sibling's pre-lock read, `-Query`, `-Brief`, the daemon, a sourcer.
# Windows PowerShell 5.1's `Move-Item -Force` over an existing file fails outright when any other
# handle has that file open with FileShare.ReadWrite - which is exactly how `Get-Content` and
# lib\json-io.ps1's Read-TextFile open it - with "Cannot create a file when that file already exists."
# The writer holds the lock, the old file is left intact, and THIS write is simply gone.
#
# MEASURED, not assumed:
#   * run-gates went red twice at 839c5e666 on two different concurrency fixtures
#     (source-domains "ok=7 of 8", ingredient-resolutions "kept 3 of 4"). Driving source-domains' exact
#     fixture shape under 32 CPU burners with every writer's output KEPT, 1 of 10 trials lost a write,
#     and that writer printed wait_ms=43 held=True hold_ms=108 and then the Move-Item error above. Not a
#     lock timeout, and not a writer that missed its barrier.
#   * Deterministically: a handle opened ReadWrite-shared on the destination fails the Move-Item every
#     time; one opened ReadWrite+Delete-shared does not.
#   * Micro-repro (scratch harness, 400 replaces of a 140 KB ledger against a lock-free Get-Content
#     reader in a tight loop, under the same load): a bare Move-Item landed 387 of 400, all 13 failures
#     that message; Move-Item RETRIED landed 400 of 400, 47 needing a retry and at most 5 attempts.
#
# THE RULE. The caller still holds its own mutex - this is not a lock, it is the last step inside one.
# The text goes to <path>.tmp with the bytes `Set-Content -Encoding utf8` writes under PS 5.1 (UTF-8 BOM,
# the text, CRLF), so no reader or byte-comparing gate sees a change of format. The move is then retried
# with a growing sleep until a reader lets go. If the budget runs out it THROWS, naming the path and the
# attempts: the previous file is intact and the caller must say the write was NOT recorded.
#
# WHAT ELSE WAS TRIED, AND WHY NOT:
#   * [IO.File]::Replace with the same retry. It lands too (400 of 400 against Get-Content, at most 4
#     attempts; 400 of 400 against ReadAllText, at most 2), and it keeps the name present - but the lock-
#     free READERS paid for it: 1,344 of 1,934 Get-Content reads and 2,670 of 3,427 ReadAllText reads
#     threw, against 113 of 412 beside the retried Move-Item. source-domains' Read-Store turns a read that
#     throws into an EMPTY ledger, so moving the failure from the writer to its readers is not a fix.
#     (Its first run was void and is not counted: PowerShell hands $null to a .NET string parameter as
#     "", an illegal backup name, so every call threw ArgumentException. [NullString]::Value is right.)
#   * A ReadAllText reader is the harsher neighbour for a bare Move-Item: 312 of 400 landed, 88 failed with
#     the same message. The retried Move-Item landed 400 of 400 beside it, at most 3 attempts.
#   * [IO.File]::Move with an overwrite flag does not exist in .NET Framework, and MoveFileEx through
#     Add-Type compiles C# on every process start, which is too dear for a ledger written per fetch.
#
# WHAT IT DOES NOT FIX. A lock-free reader can still catch the instant between Move-Item's delete and its
# move and find no file at all - exactly as it could before this file existed, since a successful
# Move-Item -Force over a file has always been a delete then a move. Such a reader must not read a
# missing ledger as an empty one; that is the reader's contract, not this writer's.
#
# THE TUNING CONSTANTS, AND WHAT THEY ARE: 40 attempts with a sleep of 25 ms x min(attempt, 8), about
# 7.3 s in all. The first plausible number, NOT the survivor of a sweep: it is 8x the worst attempt count
# measured (5) and it stays well inside the 15 s mutex timeout the waiting writers are held to. What it
# does when the producer stops: nothing - it only runs when a writer calls it.
#
# SCOPE OF A CLEAN REPORT: the self-test drives real handles held from a second runspace on this machine's
# file system. A pass proves the retry outlasts a reader that lets go and refuses one that does not, on
# NTFS under this Windows build. It proves nothing about a network share or a different file system.
#
# Dot-source:  . (Join-Path $repoRoot 'lib\atomic-write.ps1')
# Self-test:   powershell -File lib\atomic-write.ps1 -SelfTest
#
# NO param() BLOCK HERE, DELIBERATELY - dot-sourced under PS 5.1 a param() block runs in the CALLER's
# scope and would reset the caller's own -SelfTest. Same rule as lib\json-io.ps1.
$__awSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

$script:TcAtomicAttempts = 40
$script:TcAtomicBaseSleepMs = 25

function Write-TcAtomicFile {
  <# Replaces $Path with $Text. Returns the number of move attempts it took (1 when nothing was in the
     way). Throws when the budget runs out, with the previous file left exactly as it was. #>
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text,
    [int]$MaxAttempts = $script:TcAtomicAttempts,
    [int]$BaseSleepMs = $script:TcAtomicBaseSleepMs
  )
  # PowerShell LOCATION semantics for a relative path, the way Set-Content resolved it - [IO.File] alone
  # would resolve against the process working directory (lib\json-io.ps1, Resolve-JioPath).
  $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
  $tmp = $full + '.tmp'
  [IO.File]::WriteAllText($tmp, $Text + "`r`n", (New-Object Text.UTF8Encoding($true)))
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $last = ''
  for ($a = 1; $a -le $MaxAttempts; $a++) {
    try {
      Move-Item -LiteralPath $tmp -Destination $full -Force -ErrorAction Stop
      return $a
    } catch {
      $last = $_.Exception.Message
      if ($a -lt $MaxAttempts) { Start-Sleep -Milliseconds ($BaseSleepMs * [Math]::Min($a, 8)) }
    }
  }
  # The destination is still there, so the temp copy is debris: drop it. If the destination is somehow
  # gone, the temp copy is the only one left, so it stays and the message says where.
  $kept = ''
  if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  else { $kept = (' The destination is MISSING; the new text is still at {0}.' -f $tmp) }
  throw ("Write-TcAtomicFile: could not replace {0} after {1} attempt(s) over {2} ms - another handle kept it open. The previous file is intact and this write is NOT on disk.{3} Last error: {4}" -f $full, $MaxAttempts, $sw.ElapsedMilliseconds, $kept, $last.Trim())
}

function Start-TcFileHold {
  <# Self-test helper: holds $Path open the way Get-Content does (read, shared ReadWrite, no Delete) from a
     SECOND runspace for $Ms milliseconds. Returns once the handle is really open. #>
  param([string]$Path, [int]$Ms)
  $ready = $Path + '.held'
  $ps = [powershell]::Create()
  [void]$ps.AddScript({
    param($p, $ms, $ready)
    $fs = New-Object IO.FileStream($p, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { [IO.File]::WriteAllText($ready, 'x'); Start-Sleep -Milliseconds $ms } finally { $fs.Dispose() }
  }).AddArgument($Path).AddArgument($Ms).AddArgument($ready)
  $h = $ps.BeginInvoke()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while (-not (Test-Path -LiteralPath $ready) -and $sw.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 5 }
  return [pscustomobject]@{ PS = $ps; Handle = $h; Ready = $ready; Opened = (Test-Path -LiteralPath $ready) }
}

function Stop-TcFileHold {
  param($Hold)
  try { $Hold.PS.EndInvoke($Hold.Handle) } catch { }
  $Hold.PS.Dispose()
  Remove-Item -LiteralPath $Hold.Ready -Force -ErrorAction SilentlyContinue
}

if ($__awSelfTest) {
  $ErrorActionPreference = 'Stop'
  $script:cases = 0; $script:failed = 0
  function Case([string]$Label, [string]$Name, [bool]$Ok, [string]$Got) {
    $script:cases++
    if ($Ok) { Write-Output ("  ok    {0}  {1}" -f $Label, $Name) }
    else { $script:failed++; Write-Output ("  X     {0}  {1}   got: {2}" -f $Label, $Name, $Got) }
  }
  $dir = Join-Path ([IO.Path]::GetTempPath()) ('tc-aw-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  try {
    $text = '{"domains":[{"domain":"caf' + [char]0x00E9 + '.test","ok":1}]}'

    # ---- the bytes are the bytes Set-Content -Encoding utf8 writes, so no reader sees a format change ----
    $viaSc = Join-Path $dir 'via-set-content.json'
    $text | Set-Content -Path $viaSc -Encoding utf8
    $viaAw = Join-Path $dir 'via-atomic.json'
    [IO.File]::WriteAllText($viaAw, 'old', (New-Object Text.UTF8Encoding($false)))
    $n = Write-TcAtomicFile -Path $viaAw -Text $text
    $same = [Convert]::ToBase64String([IO.File]::ReadAllBytes($viaSc)) -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($viaAw))
    Case 'CLEAN TWIN' 'with nothing in the way it lands on the first attempt, byte-identical to Set-Content -Encoding utf8 (BOM, text, CRLF)' ($same -and $n -eq 1) ("same=$same attempts=$n")

    # ---- the founding shape: a reader that LETS GO ----
    # The premise first, asserted rather than trusted, so a Windows that stops failing this says so here.
    $premise = Join-Path $dir 'premise.json'
    [IO.File]::WriteAllText($premise, 'old', (New-Object Text.UTF8Encoding($true)))
    [IO.File]::WriteAllText($premise + '.tmp', 'new', (New-Object Text.UTF8Encoding($true)))
    $hold = Start-TcFileHold -Path $premise -Ms 400
    $bareErr = ''
    try { Move-Item -LiteralPath ($premise + '.tmp') -Destination $premise -Force -ErrorAction Stop } catch { $bareErr = $_.Exception.Message }
    Stop-TcFileHold $hold
    Case 'MUST FIRE' 'PREMISE: a bare Move-Item -Force fails while a Get-Content-shaped reader holds the file' ($hold.Opened -and $bareErr -ne '') ("opened=$($hold.Opened) error='$bareErr'")

    $lands = Join-Path $dir 'lands.json'
    [IO.File]::WriteAllText($lands, 'old', (New-Object Text.UTF8Encoding($true)))
    $hold = Start-TcFileHold -Path $lands -Ms 600
    $err = ''; $n = 0
    try { $n = Write-TcAtomicFile -Path $lands -Text $text } catch { $err = $_.Exception.Message }
    Stop-TcFileHold $hold
    $landed = ([IO.File]::ReadAllText($lands)).Trim() -eq $text
    Case 'MUST FIRE' 'a write made while a reader holds the file LANDS once the reader lets go (a single Move-Item loses it)' ($hold.Opened -and $err -eq '' -and $landed -and $n -gt 1) ("opened=$($hold.Opened) attempts=$n landed=$landed error='$err'")

    # ---- a reader that does NOT let go within the budget: the refusal is loud and costs nothing ----
    $stuck = Join-Path $dir 'stuck.json'
    [IO.File]::WriteAllText($stuck, 'old', (New-Object Text.UTF8Encoding($true)))
    $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($stuck))
    $hold = Start-TcFileHold -Path $stuck -Ms 3000
    $err = ''
    try { [void](Write-TcAtomicFile -Path $stuck -Text $text -MaxAttempts 3 -BaseSleepMs 10) } catch { $err = $_.Exception.Message }
    Stop-TcFileHold $hold
    Case 'MUST FIRE' 'an exhausted budget THROWS, naming the file and the attempts, and says the write is not on disk' ($hold.Opened -and $err -match 'after 3 attempt\(s\)' -and $err -match 'NOT on disk' -and $err.Contains($stuck)) ("opened=$($hold.Opened) error='$err'")
    Case 'CLEAN TWIN' 'and the refused file still holds exactly its previous bytes' ([Convert]::ToBase64String([IO.File]::ReadAllBytes($stuck)) -eq $before) 'bytes changed'
    Case '' 'and the temp copy of a refused write is removed rather than left as debris' (-not (Test-Path -LiteralPath ($stuck + '.tmp'))) 'tmp left behind'

    # ---- a first write, and a relative path ----
    $fresh = Join-Path $dir 'fresh.json'
    $n = Write-TcAtomicFile -Path $fresh -Text $text
    Case 'CLEAN TWIN' 'a file that does not exist yet is created' ((Test-Path -LiteralPath $fresh) -and ([IO.File]::ReadAllText($fresh)).Trim() -eq $text) ("attempts=$n")
    Push-Location $dir
    try { [void](Write-TcAtomicFile -Path 'relative.json' -Text $text) } finally { Pop-Location }
    Case 'MUST FIRE' 'a RELATIVE path resolves against the PowerShell location, not the process working directory' (Test-Path -LiteralPath (Join-Path $dir 'relative.json')) 'written somewhere else'
  } finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($script:failed) {
    Write-Output ("atomic-write SELF-TEST FAIL ({0} of {1})" -f $script:failed, $script:cases)
    Write-Output ("ATOMIC-WRITE-COMPLETE cases={0} failed={1}" -f $script:cases, $script:failed)
    exit 1
  }
  Write-Output ("atomic-write SELF-TEST PASS ({0} cases)" -f $script:cases)
  Write-Output ("ATOMIC-WRITE-COMPLETE cases={0} failed=0" -f $script:cases)
  exit 0
}
