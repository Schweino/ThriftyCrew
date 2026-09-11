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
#     time; one opened ReadWrite+Delete-shared does not. An exclusive holder (FileShare.None) fails it too.
#   * Micro-repro (scratch harness, 400 replaces of a 140 KB ledger against a lock-free Get-Content
#     reader in a tight loop, under the same load): a bare Move-Item landed 387 of 400, all 13 failures
#     that message; Move-Item RETRIED landed 400 of 400, 47 needing a retry and at most 5 attempts.
#
# THE SILENT HALF (2026-09-11, measured on this box). Under the DEFAULT ErrorActionPreference (Continue)
# that refusal is NON-TERMINATING: a bare Move-Item prints an error and the script CARRIES ON as if the
# write landed, and a try/catch around it never fires. A writer that sets no preference of its own inherits
# its caller's. So the move here always passes -ErrorAction Stop, and a refusal it gives up on always THROWS.
#
# THE RULE. The caller still holds its own mutex - this is not a lock, it is the last step inside one.
# The text goes to <path>.tmp with the bytes `Set-Content -Encoding utf8` writes under PS 5.1 (UTF-8 BOM,
# the text, CRLF), so no reader or byte-comparing gate sees a change of format. The move is then retried
# with a growing sleep until a reader lets go. If the budget runs out it THROWS, naming the path and the
# attempts: the previous file is intact and the caller must say the write was NOT recorded.
#
# THE OTHER BYTE SHAPE IN THIS TREE (2026-09-11). Half the replace sites never used Set-Content: they wrote
# `[IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding($false)))` - no BOM, and nothing
# appended. Routing those through the default would put a BOM and a CRLF into files that never had them,
# which a byte-comparing gate reads as a change and a BOM-strict reader can choke on. So the two
# differences are two explicit switches, named for the one byte each controls: -NoBom drops the BOM and
# -NoNewline drops the CRLF (Set-Content's own word for it). Such a site passes BOTH and keeps its bytes.
# The default is unchanged, so no existing caller moves.
#
# RETRY ONLY A REFUSAL, DECIDED BY STATE AND NOT BY EXCEPTION TYPE (2026-09-11). A temp file that has gone,
# or a destination directory that is not there, will not come back by waiting, so those throw at once rather
# than after ~7 s. Typing the exception is not enough, measured on this box: a missing source under
# -LiteralPath raises PSInvalidOperationException, and a missing directory raises DirectoryNotFoundException,
# which IS an IOException. So a failed move is retried only when it is an IOException AND the temp file still
# exists AND the destination's directory exists (Test-TcReplaceRefusal). UnauthorizedAccessException is not
# retried: it was not the measured failure, and waiting does not fix a read-only file or an ACL.
#
# -UniqueTemp names the temp file <path>.<8 hex>.tmp instead of <path>.tmp, for a file written by several
# processes with NO mutex between them (capture-run's status, which a skipped-locked occurrence writes while
# the holder runs): two such writers sharing <path>.tmp collide on the temp file itself. The default stays
# <path>.tmp, because the ledgers' own fixtures watch for that name to know a child has reached its replace,
# and a ledger behind lib\ledger-lock.ps1's lock needs no unique name.
#
# -OnRefusal { param($attempt) ... } runs after every refused attempt, before the retry sleeps. It exists so a
# test can PROVE a replace met a reader instead of timing it (a hermetic self-test proves overlap, never an
# upper wall-clock bar), and a caller may use it to log. It must not throw.
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
# missing ledger as an empty one; that is the reader's contract, not this writer's. And it merges nothing:
# processes that read-modify-write one file need a lock around the whole cycle (lib\ledger-lock.ps1).
#
# THE TUNING CONSTANTS, AND WHAT THEY ARE: 40 attempts with a sleep of 25 ms x min(attempt, 8), about
# 7.3 s in all. The first plausible number, NOT the survivor of a sweep: it is 8x the worst attempt count
# measured (5) and it stays well inside the 15 s mutex timeout the waiting writers are held to. A sibling
# fix the same day carried a 5 s time budget; nothing between or above was tried. What it does when the
# producer stops: nothing - it only runs when a writer calls it.
#
# THE SELF-TEST PROVES OVERLAP BY RENDEZVOUS, NOT BY A CLOCK. Its reader lets go on a SIGNAL - the writer's
# first refusal (through -OnRefusal) or the parent saying it is finished - never on a timer, so on a loaded
# box a case can only get slower. The one clock left is a 60 s hang guard. Its fail-fast cases assert what
# the retry did (how many refusals it counted, which error came through), never how quickly it threw.
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

function Test-TcReplaceRefusal {
  <# $true when a failed move is the transient refusal worth waiting out: an IOException that is not a missing
     file or directory, with the temp file still present and the destination's directory present. Full paths in. #>
  param($Exception, [string]$Source, [string]$Destination)
  if ($Exception -isnot [IO.IOException]) { return $false }
  if (($Exception -is [IO.DirectoryNotFoundException]) -or ($Exception -is [IO.FileNotFoundException])) { return $false }
  if (-not [IO.File]::Exists($Source)) { return $false }
  $dir = [IO.Path]::GetDirectoryName($Destination)
  if ($dir -and -not [IO.Directory]::Exists($dir)) { return $false }
  return $true
}

function Remove-TcAtomicDebris {
  <# After a failure: the destination is still there, so the temp copy is debris - drop it. If the destination
     is gone, the temp copy is the only one left, so it stays, and the returned text says where. #>
  param([string]$Source, [string]$Destination)
  if ([IO.File]::Exists($Destination)) { Remove-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue; return '' }
  if ([IO.File]::Exists($Source)) { return (' The destination is MISSING; the new text is still at {0}.' -f $Source) }
  return ''
}

function Write-TcAtomicFile {
  <# Replaces $Path with $Text. Returns the number of move attempts it took (1 when nothing was in the
     way). Throws at once on a failure waiting cannot fix, and after the budget on a refusal that outlasts
     it, with the previous file left exactly as it was. #>
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text,
    [int]$MaxAttempts = $script:TcAtomicAttempts,
    [int]$BaseSleepMs = $script:TcAtomicBaseSleepMs,
    # The WriteAllText byte shape: see THE OTHER BYTE SHAPE in the header. A converted site passes both.
    [switch]$NoBom,
    [switch]$NoNewline,
    # Writers that share no mutex: see -UniqueTemp in the header.
    [switch]$UniqueTemp,
    # Runs after each refused attempt with the attempt number: see -OnRefusal in the header.
    [scriptblock]$OnRefusal = $null
  )
  # PowerShell LOCATION semantics for a relative path, the way Set-Content resolved it - [IO.File] alone
  # would resolve against the process working directory (lib\json-io.ps1, Resolve-JioPath).
  $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
  $tmp = if ($UniqueTemp) { '{0}.{1}.tmp' -f $full, [guid]::NewGuid().ToString('N').Substring(0, 8) } else { $full + '.tmp' }
  $body = if ($NoNewline) { $Text } else { $Text + "`r`n" }
  [IO.File]::WriteAllText($tmp, $body, (New-Object Text.UTF8Encoding(-not $NoBom)))
  # A budget that reads as zero must still try once: an attempt count of 0 would throw without ever moving.
  if ($MaxAttempts -lt 1) { $MaxAttempts = 1 }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $last = ''
  for ($a = 1; $a -le $MaxAttempts; $a++) {
    try {
      # -ErrorAction Stop IS WHAT MAKES A REFUSAL VISIBLE AT ALL: under a caller's default EAP=Continue the
      # refusal is otherwise non-terminating and this catch never runs.
      Move-Item -LiteralPath $tmp -Destination $full -Force -ErrorAction Stop
      return $a
    } catch {
      $ex = $_.Exception
      $last = $ex.Message
      if (-not (Test-TcReplaceRefusal -Exception $ex -Source $tmp -Destination $full)) {
        $null = Remove-TcAtomicDebris -Source $tmp -Destination $full
        throw
      }
      if ($OnRefusal) { $null = & $OnRefusal $a }
      if ($a -lt $MaxAttempts) { Start-Sleep -Milliseconds ($BaseSleepMs * [Math]::Min($a, 8)) }
    }
  }
  $kept = Remove-TcAtomicDebris -Source $tmp -Destination $full
  throw ("Write-TcAtomicFile: could not replace {0} after {1} attempt(s) over {2} ms - another handle kept it open. The previous file is intact and this write is NOT on disk.{3} Last error: {4}" -f $full, $MaxAttempts, $sw.ElapsedMilliseconds, $kept, $last.Trim())
}

function Start-TcFileHold {
  <# Test helper: holds $Path open the way Get-Content does (read, shared ReadWrite, no Delete) from a SECOND
     runspace, and returns once the handle is really open. It lets go on a SIGNAL, never on a clock:
       -UntilFile <path>   once that file exists (the parent writes it, or a writer's -OnRefusal hook does,
                           or it is the writer's own temp file)
       -UntilGlob <glob>   once a file matching it exists (a writer's temp file when its name is unknown)
     then waits -GraceMs more. Stop-TcFileHold sets .Saw to whether the signal arrived before the 60 s hang
     guard. -Ms holds for a fixed time instead; a timed hold is what lets a loaded box turn a green case red. #>
  param([string]$Path, [int]$Ms = 0, [string]$UntilFile = '', [string]$UntilGlob = '', [int]$GraceMs = 0, [int]$DeadlineMs = 60000)
  $ready = $Path + '.held'
  $ps = [powershell]::Create()
  [void]$ps.AddScript({
    param($p, $ms, $untilFile, $untilGlob, $graceMs, $deadlineMs, $ready)
    $saw = $false
    $fs = New-Object IO.FileStream($p, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
      [IO.File]::WriteAllText($ready, 'x')
      if ($untilFile -or $untilGlob) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt $deadlineMs) {
          if ($untilFile -and [IO.File]::Exists($untilFile)) { $saw = $true; break }
          if ($untilGlob -and @(Get-ChildItem -Path $untilGlob -File -ErrorAction SilentlyContinue).Count -gt 0) { $saw = $true; break }
          Start-Sleep -Milliseconds 5
        }
        if ($saw -and $graceMs -gt 0) { Start-Sleep -Milliseconds $graceMs }
      } else { Start-Sleep -Milliseconds $ms }
    } finally { $fs.Dispose() }
    $saw
  }).AddArgument($Path).AddArgument($Ms).AddArgument($UntilFile).AddArgument($UntilGlob).AddArgument($GraceMs).AddArgument($DeadlineMs).AddArgument($ready)
  $h = $ps.BeginInvoke()
  # A hang guard, not a bar: runspace start-up on a loaded box is slow, and slow must never read as not-opened.
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while (-not (Test-Path -LiteralPath $ready) -and $sw.ElapsedMilliseconds -lt 60000) { Start-Sleep -Milliseconds 5 }
  return [pscustomobject]@{ PS = $ps; Handle = $h; Ready = $ready; Opened = (Test-Path -LiteralPath $ready); Saw = $false }
}

function Stop-TcFileHold {
  <# Waits for the hold to let go and records on the hold whether its signal arrived. Writes nothing to output. #>
  param($Hold)
  $out = $null
  try { $out = $Hold.PS.EndInvoke($Hold.Handle) } catch { }
  $Hold.Saw = [bool](@($out) | Select-Object -Last 1)
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
  $bomless = New-Object Text.UTF8Encoding($false)
  # A signal file per case. The refusal hook writes a "released" signal on the FIRST refusal, so a reader that
  # lets go does so only after the replace has provably met it; the parent writes a "done" signal after a call
  # the reader must outlast.
  function New-Signal([string]$Name) { return (Join-Path $dir ($Name + '.signal')) }
  try {
    $text = '{"domains":[{"domain":"caf' + [char]0x00E9 + '.test","ok":1}]}'

    # ---- the bytes are the bytes Set-Content -Encoding utf8 writes, so no reader sees a format change ----
    $viaSc = Join-Path $dir 'via-set-content.json'
    $text | Set-Content -Path $viaSc -Encoding utf8
    $viaAw = Join-Path $dir 'via-atomic.json'
    [IO.File]::WriteAllText($viaAw, 'old', $bomless)
    $n = Write-TcAtomicFile -Path $viaAw -Text $text
    $same = [Convert]::ToBase64String([IO.File]::ReadAllBytes($viaSc)) -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($viaAw))
    Case 'CLEAN TWIN' 'with nothing in the way it lands on the first attempt, byte-identical to Set-Content -Encoding utf8 (BOM, text, CRLF)' ($same -and $n -eq 1) ("same=$same attempts=$n")

    # ---- the WriteAllText shape: a no-BOM site converted with -NoBom -NoNewline keeps its bytes ----
    $noBomEnc = New-Object Text.UTF8Encoding($false)
    $viaWat = Join-Path $dir 'via-writealltext.json'
    [IO.File]::WriteAllText($viaWat, $text, $noBomEnc)
    $viaAw2 = Join-Path $dir 'via-atomic-nobom.json'
    [IO.File]::WriteAllText($viaAw2, 'old', $noBomEnc)
    [void](Write-TcAtomicFile -Path $viaAw2 -Text $text -NoBom -NoNewline)
    $watB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($viaWat))
    $aw2B64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($viaAw2))
    Case 'MUST FIRE' '-NoBom -NoNewline is byte-identical to WriteAllText with UTF8Encoding($false): no BOM appears and no CRLF is appended' ($watB64 -eq $aw2B64) ("writealltext=$watB64 atomic=$aw2B64")
    # Each switch moves only its own byte, so neither can quietly stand in for the other.
    $viaAw3 = Join-Path $dir 'via-atomic-nobom-only.json'
    [void](Write-TcAtomicFile -Path $viaAw3 -Text $text -NoBom)
    $scBytes = [IO.File]::ReadAllBytes($viaSc)
    $aw3Bytes = [IO.File]::ReadAllBytes($viaAw3)
    $scNoBom = [Convert]::ToBase64String($scBytes, 3, $scBytes.Length - 3)
    Case 'MUST FIRE' '-NoBom alone drops exactly the three BOM bytes and keeps the CRLF' ($scBytes[0] -eq 0xEF -and $scNoBom -eq [Convert]::ToBase64String($aw3Bytes)) ("atomic=" + [Convert]::ToBase64String($aw3Bytes))
    $viaAw4 = Join-Path $dir 'via-atomic-nonewline-only.json'
    [void](Write-TcAtomicFile -Path $viaAw4 -Text $text -NoNewline)
    $scNoCrlf = [Convert]::ToBase64String($scBytes, 0, $scBytes.Length - 2)
    $aw4Bytes = [IO.File]::ReadAllBytes($viaAw4)
    Case 'MUST FIRE' '-NoNewline alone drops exactly the trailing CRLF and keeps the BOM' ($scBytes[$scBytes.Length - 1] -eq 0x0A -and $scNoCrlf -eq [Convert]::ToBase64String($aw4Bytes)) ("atomic=" + [Convert]::ToBase64String($aw4Bytes))

    # ---- the founding shape: a reader that LETS GO ----
    # The premise first, asserted rather than trusted, so a Windows that stops failing this says so here.
    $premise = Join-Path $dir 'premise.json'
    [IO.File]::WriteAllText($premise, 'old', (New-Object Text.UTF8Encoding($true)))
    [IO.File]::WriteAllText($premise + '.tmp', 'new', (New-Object Text.UTF8Encoding($true)))
    $done = New-Signal 'premise-done'
    $hold = Start-TcFileHold -Path $premise -UntilFile $done
    $bareErr = ''
    try { Move-Item -LiteralPath ($premise + '.tmp') -Destination $premise -Force -ErrorAction Stop } catch { $bareErr = $_.Exception.Message }
    [IO.File]::WriteAllText($done, 'x'); Stop-TcFileHold $hold
    Case 'MUST FIRE' 'PREMISE: a bare Move-Item -Force fails while a Get-Content-shaped reader holds the file' ($hold.Opened -and $bareErr -ne '') ("opened=$($hold.Opened) error='$bareErr'")

    $lands = Join-Path $dir 'lands.json'
    [IO.File]::WriteAllText($lands, 'old', (New-Object Text.UTF8Encoding($true)))
    $released = New-Signal 'lands-released'
    $hold = Start-TcFileHold -Path $lands -UntilFile $released
    $err = ''; $n = 0
    try { $n = Write-TcAtomicFile -Path $lands -Text $text -OnRefusal { param($at) if ($at -eq 1) { [IO.File]::WriteAllText($released, 'x') } } } catch { $err = $_.Exception.Message }
    if (-not (Test-Path -LiteralPath $released)) { [IO.File]::WriteAllText($released, 'x') }
    Stop-TcFileHold $hold
    $landed = ([IO.File]::ReadAllText($lands)).Trim() -eq $text
    Case 'MUST FIRE' 'a write that met a reader LANDS once the reader lets go (a single Move-Item loses it)' ($hold.Opened -and $hold.Saw -and $err -eq '' -and $landed -and $n -gt 1) ("opened=$($hold.Opened) refused_first=$($hold.Saw) attempts=$n landed=$landed error='$err'")

    # ---- a reader that does NOT let go within the budget: the refusal is loud and costs nothing ----
    $stuck = Join-Path $dir 'stuck.json'
    [IO.File]::WriteAllText($stuck, 'old', (New-Object Text.UTF8Encoding($true)))
    $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($stuck))
    $done = New-Signal 'stuck-done'
    $hold = Start-TcFileHold -Path $stuck -UntilFile $done
    $err = ''
    try { [void](Write-TcAtomicFile -Path $stuck -Text $text -MaxAttempts 3 -BaseSleepMs 10) } catch { $err = $_.Exception.Message }
    [IO.File]::WriteAllText($done, 'x'); Stop-TcFileHold $hold
    Case 'MUST FIRE' 'an exhausted budget THROWS, naming the file and the attempts, and says the write is not on disk' ($hold.Opened -and $err -match 'after 3 attempt\(s\)' -and $err -match 'NOT on disk' -and $err.Contains($stuck)) ("opened=$($hold.Opened) error='$err'")
    Case 'CLEAN TWIN' 'and the refused file still holds exactly its previous bytes' ([Convert]::ToBase64String([IO.File]::ReadAllBytes($stuck)) -eq $before) 'bytes changed'
    Case '' 'and the temp copy of a refused write is removed rather than left as debris' (-not (Test-Path -LiteralPath ($stuck + '.tmp'))) 'tmp left behind'

    # ---- THE SILENT HALF: under the DEFAULT ErrorActionPreference a refusal does not throw at all ----
    # The premise is asserted, then the helper is driven under the same preference: it must still throw.
    $silent = Join-Path $dir 'silent.json'
    [IO.File]::WriteAllText($silent, 'old', $bomless)
    [IO.File]::WriteAllText($silent + '.bare.tmp', 'new', $bomless)
    $done = New-Signal 'silent-done'
    $hold = Start-TcFileHold -Path $silent -UntilFile $done
    $bareThrew = $false
    try { & { $ErrorActionPreference = 'Continue'; Move-Item -LiteralPath ($silent + '.bare.tmp') -Destination $silent -Force 2>$null } } catch { $bareThrew = $true }
    $bareLanded = ([IO.File]::ReadAllText($silent)) -eq 'new'
    $helperErr = ''
    try { & { $ErrorActionPreference = 'Continue'; [void](Write-TcAtomicFile -Path $silent -Text 'new' -MaxAttempts 3 -BaseSleepMs 10) } } catch { $helperErr = $_.Exception.Message }
    [IO.File]::WriteAllText($done, 'x'); Stop-TcFileHold $hold
    Case 'MUST FIRE' 'PREMISE: under EAP=Continue a bare Move-Item -Force over a held file does NOT throw and does NOT land - the write is lost silently' ($hold.Opened -and -not $bareThrew -and -not $bareLanded) ("opened=$($hold.Opened) threw=$bareThrew landed=$bareLanded")
    Case 'MUST FIRE' 'under EAP=Continue the helper still THROWS when its budget runs out, and the file keeps its old content' ($helperErr -match 'after 3 attempt\(s\)' -and ([IO.File]::ReadAllText($silent)) -eq 'old') ("error='$helperErr'")

    # ---- failures waiting cannot fix are NOT retried: proven by what the retry DID, never by a clock ----
    # The refusal predicate, driven directly on every shape it has to tell apart.
    $pSrc = Join-Path $dir 'pred-src.tmp'; [IO.File]::WriteAllText($pSrc, 'x', $bomless)
    $pDst = Join-Path $dir 'pred-dst.json'
    $pNoDir = Join-Path $dir 'no-such-dir\pred-dst.json'
    $pGone = Join-Path $dir 'never-written.tmp'
    $ioEx = New-Object IO.IOException 'Cannot create a file when that file already exists.'
    Case 'MUST FIRE' 'Test-TcReplaceRefusal: an IOException with the temp file and the destination directory both present is a refusal worth waiting out' (Test-TcReplaceRefusal -Exception $ioEx -Source $pSrc -Destination $pDst) 'not a refusal'
    $notRefusals = @(
      (Test-TcReplaceRefusal -Exception $ioEx -Source $pGone -Destination $pDst),
      (Test-TcReplaceRefusal -Exception $ioEx -Source $pSrc -Destination $pNoDir),
      (Test-TcReplaceRefusal -Exception (New-Object IO.DirectoryNotFoundException 'x') -Source $pSrc -Destination $pDst),
      (Test-TcReplaceRefusal -Exception (New-Object UnauthorizedAccessException 'x') -Source $pSrc -Destination $pDst))
    Case 'MUST NOT FIRE' 'Test-TcReplaceRefusal: a missing temp file, a missing destination directory, a DirectoryNotFoundException and an UnauthorizedAccessException are not refusals' (@($notRefusals | Where-Object { $_ }).Count -eq 0) ("verdicts=" + ($notRefusals -join ','))
    # And inside the loop: the hook removes the temp file after the first refusal, so the second attempt meets a
    # failure no wait can fix. It must throw THAT error at once - one refusal counted, not forty, and not the
    # exhausted-budget message.
    $ff = Join-Path $dir 'fail-fast.json'
    [IO.File]::WriteAllText($ff, 'old', $bomless)
    $done = New-Signal 'fail-fast-done'
    $hold = Start-TcFileHold -Path $ff -UntilFile $done
    $script:refusals = 0; $ffType = ''; $ffMsg = ''
    try { [void](Write-TcAtomicFile -Path $ff -Text $text -OnRefusal { param($at) $script:refusals++; if ($at -eq 1) { Remove-Item -LiteralPath ($ff + '.tmp') -Force } }) } catch { $ffType = $_.Exception.GetType().Name; $ffMsg = $_.Exception.Message }
    [IO.File]::WriteAllText($done, 'x'); Stop-TcFileHold $hold
    Case 'MUST NOT FIRE' 'the retry does not keep waiting once waiting cannot help: a temp file gone mid-wait throws its own error on the next attempt' ($hold.Opened -and $script:refusals -eq 1 -and $ffType -ne '' -and $ffMsg -notmatch 'attempt\(s\)' -and ([IO.File]::ReadAllText($ff)) -eq 'old') ("refusals=$($script:refusals) threw=$ffType msg='$ffMsg'")

    # ---- a first write, a relative path, and a bracketed name ----
    $fresh = Join-Path $dir 'fresh.json'
    $n = Write-TcAtomicFile -Path $fresh -Text $text
    Case 'CLEAN TWIN' 'a file that does not exist yet is created' ((Test-Path -LiteralPath $fresh) -and ([IO.File]::ReadAllText($fresh)).Trim() -eq $text) ("attempts=$n")
    Push-Location $dir
    try { [void](Write-TcAtomicFile -Path 'relative.json' -Text $text) } finally { Pop-Location }
    Case 'MUST FIRE' 'a RELATIVE path resolves against the PowerShell location, not the process working directory' (Test-Path -LiteralPath (Join-Path $dir 'relative.json')) 'written somewhere else'
    # Under CONTENTION too: the refusal check must see the temp file where the move looks for it, or a relative
    # write reads its own temp file as missing and fails fast instead of waiting the reader out.
    $rel = Join-Path $dir 'relative-held.json'
    [IO.File]::WriteAllText($rel, 'old', $bomless)
    $released = New-Signal 'relative-released'
    $hold = Start-TcFileHold -Path $rel -UntilFile $released
    $err = ''; $n = 0
    Push-Location $dir
    try { $n = Write-TcAtomicFile -Path 'relative-held.json' -Text $text -OnRefusal { param($at) if ($at -eq 1) { [IO.File]::WriteAllText($released, 'x') } } } catch { $err = $_.Exception.Message } finally { Pop-Location }
    if (-not (Test-Path -LiteralPath $released)) { [IO.File]::WriteAllText($released, 'x') }
    Stop-TcFileHold $hold
    Case 'CLEAN TWIN' 'a relative path after Push-Location is still waited out under a held reader, and lands' ($hold.Opened -and $err -eq '' -and $n -gt 1 -and ([IO.File]::ReadAllText($rel)).Trim() -eq $text) ("attempts=$n error='$err'")
    $brk = Join-Path $dir 'we[i]rd.json'
    [IO.File]::WriteAllText($brk, 'old', $bomless)
    [void](Write-TcAtomicFile -Path $brk -Text 'new' -NoBom -NoNewline)
    Case 'CLEAN TWIN' 'a file name containing [ ] still replaces - literal paths, no wildcard expansion' (([IO.File]::ReadAllText($brk)) -eq 'new') 'not replaced'

    # ---- -UniqueTemp: writers with no mutex between them must not collide on the temp name itself ----
    $ut = Join-Path $dir 'unique.json'
    [IO.File]::WriteAllText($ut, 'old', $bomless)
    [IO.File]::WriteAllText($ut + '.tmp', 'a sibling writer mid-write', $bomless)
    $sib = New-Object IO.FileStream(($ut + '.tmp'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $shared = ''; $uniqueErr = ''
    try {
      try { [void](Write-TcAtomicFile -Path $ut -Text 'through the shared temp') } catch { $shared = $_.Exception.Message }
      try { [void](Write-TcAtomicFile -Path $ut -Text $text -UniqueTemp) } catch { $uniqueErr = $_.Exception.Message }
    } finally { $sib.Dispose() }
    $leftUnique = @(Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Name -match '^unique\.json\.[0-9a-f]{8}\.tmp$' })
    Case 'MUST FIRE' 'PREMISE: a sibling writer holding the shared <path>.tmp costs a plain write' ($shared -ne '') 'the shared temp did not collide'
    Case 'MUST FIRE' '-UniqueTemp: the same write lands beside that sibling, through a temp name of its own' ($uniqueErr -eq '' -and ([IO.File]::ReadAllText($ut)).Trim() -eq $text) ("error='$uniqueErr'")
    Case 'MUST NOT FIRE' 'and no temp file of its own is left behind once the write lands' ($leftUnique.Count -eq 0) ("left=" + $leftUnique.Count)
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
