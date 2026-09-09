<#
  git-blob-lib.ps1 - read a COMMITTED blob as BYTES, and hash bytes.

  THE CLASS (2026-09-04, queue 2026-09-04-4ec26c). capture-run.ps1's read-after-write asked the right
  question - "is the edge serving the bytes we just pushed?" - and answered it by comparing two different
  DECODINGS of identical bytes:

      $repoBoard = (& git -C $repo show HEAD:public/board.json | Out-String)   # console code page
      $liveBoard = (Invoke-WebRequest ...).Content                            # decoded as UTF-8
      if ($liveBoard -ne $repoBoard) { ...EDGE STALE... }

  A native command's stdout is decoded through [Console]::OutputEncoding on its way into a PowerShell
  string, so every multi-byte UTF-8 sequence in the blob became 2+ characters. Measured on the live board
  that morning: 2,961,318 bytes, 2,959,184 characters when decoded as UTF-8, and exactly 2,134 characters
  above U+007F - 2961318 - 2959184 = 2134. The check could not pass while the board contained a single
  non-ASCII character, and it paged "board.json edge did not pick up today's push" on a board the edge was
  serving byte-for-byte correctly (SHA256 identical on both sides).

  The rule this file exists to enforce: a payload you intend to COMPARE never round-trips through a decoded
  string. Get the bytes, hash the bytes, compare the hashes. Decode only when you actually want text, and
  then say which encoding you mean.

  Used by capture-run.ps1 at BOTH read-after-write call sites (smp-feed and board.json). The smp-feed one
  survived only by accident - it ConvertFrom-Json'd the blob and compared one ASCII field - so the defect
  was latent there and would have fired the moment anyone compared more.
#>

# The blob at <Spec> (e.g. 'HEAD:public/board.json') as [byte[]], or $null if git could not produce it.
#
# WHY System.Diagnostics.Process AND NOT `& git ... `: the call operator hands stdout to PowerShell's TEXT
# pipeline, which is the whole defect. This reads the raw stdout stream instead, so no encoding is applied
# in either direction.
# STDERR IS NOT REDIRECTED, deliberately. Two reasons: this estate runs under $ErrorActionPreference='Stop',
# where merging a native child's stderr turns its first line into a terminating error; and a redirected
# stream nobody drains can fill its buffer and deadlock the child. git's diagnostics go to the console,
# where a human can see them, and the exit code is what this function judges.
function Get-CommittedBlobBytes {
  param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Spec)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'git'
  # cat-file, not show: `show` on a blob spec is equivalent here but `cat-file blob` is the plumbing command
  # and cannot be reshaped by a user's diff/pager configuration.
  # .Arguments, NOT .ArgumentList: this runs on Windows PowerShell 5.1 / .NET Framework, where
  # ProcessStartInfo has no ArgumentList property at all (it is .NET Core+). Both operands are quoted
  # because a repo path can contain spaces.
  $psi.Arguments = '-C "' + $Repo + '" cat-file blob "' + $Spec + '"'
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.CreateNoWindow = $true
  $p = $null
  try {
    $p = [System.Diagnostics.Process]::Start($psi)
    $ms = New-Object System.IO.MemoryStream
    $p.StandardOutput.BaseStream.CopyTo($ms)
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { return $null }   # no such blob / not a repo: could-not-read, never "empty"
    $bytes = $ms.ToArray()
    if ($null -eq $bytes -or $bytes.Length -eq 0) { return $null }
    return , $bytes                            # comma: keep the array from unrolling on the way out
  } catch { return $null }
  finally { if ($p) { $p.Dispose() } }
}

# SHA256 of a byte array, uppercase hex. '' for a null/empty input, so a caller that compares two hashes can
# never read "both unreadable" as "they match" - '' -eq '' would be a false agreement, so the callers test
# for emptiness explicitly and report BLIND.
function Get-Sha256Hex {
  param([byte[]]$Bytes)
  if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '') }
  finally { $sha.Dispose() }
}

# ---- RUN GIT AND KEEP WHAT IT SAID ON *BOTH* STREAMS ---------------------------------------------------
#
# THE CLASS (2026-09-09, queue 2026-09-09-a95022). capture-run.ps1 and lib\pipeline-commit.ps1 both ran
# `git commit` through a STDOUT-ONLY pipe and judged it by $LASTEXITCODE. The pre-commit hook writes its
# ENTIRE diagnosis to stderr - every echo in .git/hooks/pre-commit is `>&2`, and it discards the checkers'
# own stderr with `2>/dev/null` - and a -WindowStyle Hidden transcript never sees a native child's stderr.
# So on 2026-09-09 BOTH scheduled runs (07:02 ad, 08:35 daily) ended at the same single sentence:
#
#     commit: REFUSED (git exit 1) - a hook or git itself rejected this commit.
#
# Five distinct refusal exits (two missing checkers, a bulk-edit invariant, a scope breach, an unreviewed
# rule change) plus git's own errors all collapse into that one line, so a refusal cost a full scratch-index
# reproduction instead of a glance. The hook was RIGHT both times; what was broken is that the artifact a
# human is sent to read could not say WHY, or which file.
#
# WHY A Process AND NOT `& git ... 2>&1`: this estate runs under $ErrorActionPreference='Stop', where
# redirecting a native child's stderr wraps each line in a NativeCommandError and the FIRST one becomes a
# TERMINATING error - the redirect CAUSES the failure it looks like it is preventing. grocery\native-lib.ps1
# has the whole account and the estate has paid for it three times. `2>$null` has the identical defect.
# Reading the streams off a Process object touches neither PowerShell's error pipeline nor its text pipeline.
#
# The child inherits the current process environment, so GIT_INDEX_FILE (the private-index pattern both
# callers use) reaches git exactly as it does today.

# Windows command-line quoting, the CommandLineToArgvW rules. ProcessStartInfo.Arguments is ONE STRING on
# .NET Framework - there is no ArgumentList until .NET Core - so a commit message with spaces, quotes or a
# trailing backslash has to be quoted by hand or git receives a different command than the caller wrote.
function ConvertTo-GitArgString {
  param([string[]]$GitArgs)
  $parts = New-Object System.Collections.ArrayList
  foreach ($a in @($GitArgs)) {
    $s = [string]$a
    if ($s.Length -gt 0 -and $s.IndexOfAny([char[]]@(' ', "`t", '"')) -lt 0) { [void]$parts.Add($s); continue }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($ch in $s.ToCharArray()) {
      if ($ch -eq '\') { $slashes++; continue }
      if ($ch -eq '"') { [void]$sb.Append('\' * ($slashes * 2 + 1)); [void]$sb.Append('"'); $slashes = 0; continue }
      if ($slashes) { [void]$sb.Append('\' * $slashes); $slashes = 0 }
      [void]$sb.Append($ch)
    }
    if ($slashes) { [void]$sb.Append('\' * ($slashes * 2)) }   # a trailing run would escape our own closing quote
    [void]$sb.Append('"')
    [void]$parts.Add($sb.ToString())
  }
  return ($parts -join ' ')
}

# Run `git -C <Repo> <GitArgs>` and return @{ rc; stdout; stderr }. Never throws: a committer that is
# KILLED BY its own reporting has lost the run's work, which is the rule run-log-lib states for logging.
function Invoke-GitCaptured {
  param(
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][string[]]$GitArgs
  )
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'git'
  $psi.Arguments = (ConvertTo-GitArgString -GitArgs (@('-C', $Repo) + @($GitArgs)))
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow = $true
  # git speaks UTF-8; decoding its output through the console code page is the defect this whole file
  # exists for. Say which encoding rather than inheriting whatever the console happens to be.
  $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
  $psi.StandardErrorEncoding  = New-Object System.Text.UTF8Encoding($false)
  $p = $null
  try {
    $p = [System.Diagnostics.Process]::Start($psi)
    # BOTH PIPES ARE DRAINED BEFORE WaitForExit, AND THIS IS THE ONE REAL HAZARD HERE. A pipe buffer is
    # 4-64 KB; a chatty hook that fills it blocks in its own write until somebody reads, and a
    # WaitForExit-then-read would then wait forever on a child that is waiting on us. Start both reads
    # first, so the two streams drain concurrently while the child runs.
    $tOut = $p.StandardOutput.ReadToEndAsync()
    $tErr = $p.StandardError.ReadToEndAsync()
    $tOut.Wait(); $tErr.Wait()
    $p.WaitForExit()
    return @{ rc = $p.ExitCode; stdout = [string]$tOut.Result; stderr = [string]$tErr.Result }
  } catch {
    # rc -1 is "could not run git at all", which is not the same as "git said no" and must not read as one.
    return @{ rc = -1; stdout = ''; stderr = ('Invoke-GitCaptured could not start git: ' + $_.Exception.Message) }
  } finally { if ($p) { $p.Dispose() } }
}

# Turn a refusal's stderr into the two things a human needs at 07:02: the hook's own lines, and WHICH FILE.
# Pure - no git, no clock, no network - so a fixture drives exactly the code the callers run rather than a
# paraphrase of it. Returns @{ transcript = string[]; files = string[]; summary = string }.
function Format-GitRefusal {
  param([int]$Rc, [string]$Stderr, [int]$MaxLines = 20)
  $lines = @()
  if ($Stderr) { $lines = @(($Stderr -split "`r?`n") | Where-Object { $_.Trim().Length -gt 0 }) }
  $transcript = @($lines | ForEach-Object { 'commit:hook> ' + $_ })
  # The five refusal exits the hook can take, plus git's own. A path is a token carrying a separator, so
  # 'BOM CHANGED   grocery/out/json-readers-baseline.json - ...' yields the file and the prose does not.
  #
  # TWO TIERS, AND THE SECOND ONE IS THE POINT. Keying extraction solely on the five markers the hook
  # writes TODAY is the [[rules-that-silently-disarm]] shape aimed at our own diagnostics: the day someone
  # adds a sixth refusal exit, or rewords one, the alert silently goes back to naming no file and nothing
  # says so. So: prefer a path on a marker line (high confidence), and if there is none, take any token
  # from any line that looks like a repo FILE - a separator plus a real extension. That last clause is what
  # keeps `error: cannot lock ref 'refs/heads/main'` from being reported as a file it is not.
  $rx = 'BOM CHANGED|PARSE FAIL|DEPENDENCY|FROZEN LITERAL|REFUSING|BLOCKED'
  $tok = '[A-Za-z0-9_.\-]+(?:[\\/][A-Za-z0-9_.\-]+)+'
  $files = New-Object System.Collections.ArrayList
  foreach ($l in $lines) {
    if ($l -notmatch $rx) { continue }
    foreach ($m in [regex]::Matches($l, $tok)) {
      $v = $m.Value.TrimEnd('.', ',', ')')
      if ($v -and -not $files.Contains($v)) { [void]$files.Add($v) }
    }
  }
  if (-not $files.Count) {
    foreach ($l in $lines) {
      foreach ($m in [regex]::Matches($l, $tok)) {
        $v = $m.Value.TrimEnd('.', ',', ')')
        if ($v -notmatch '\.[A-Za-z0-9]{1,6}$') { continue }   # a ref or a URL path is not a file to go and fix
        if ($v -and -not $files.Contains($v)) { [void]$files.Add($v) }
      }
    }
  }
  $summary = if ($files.Count) { 'files named by the hook: ' + (($files | Select-Object -First 12) -join ', ') }
             else { 'files named by the hook: none - the refusal named no path (read the commit:hook> lines above)' }
  return @{
    rc         = $Rc
    transcript = @($transcript | Select-Object -First $MaxLines)
    files      = @($files.ToArray())
    summary    = $summary
  }
}

# The bytes of an Invoke-WebRequest response, without going through .Content as a string.
# -UseBasicParsing gives .Content as a string on Windows PowerShell 5.1 and as a byte[] in some hosts, so
# BOTH shapes are handled and the string case is re-encoded as UTF-8 - which is what the server sent and
# what the string was decoded from. RawContentStream is preferred when present because it never decoded.
function Get-ResponseBytes {
  param($Response)
  if ($null -eq $Response) { return $null }
  try {
    if ($Response.PSObject.Properties['RawContentStream'] -and $Response.RawContentStream) {
      $ms = New-Object System.IO.MemoryStream
      $Response.RawContentStream.Position = 0
      $Response.RawContentStream.CopyTo($ms)
      $b = $ms.ToArray()
      if ($b -and $b.Length -gt 0) { return , $b }
    }
  } catch { }
  $c = $Response.Content
  if ($null -eq $c) { return $null }
  if ($c -is [byte[]]) { return , $c }
  return , ([Text.Encoding]::UTF8.GetBytes([string]$c))
}

# ---- SELF-TEST -----------------------------------------------------------------------------------------
# NO param() BLOCK IN THIS FILE, DELIBERATELY - same rule as lib\bot-paths.ps1, lib\json-io.ps1 and
# lib\guard-contract.ps1. In PS 5.1 dot-sourcing a script runs its param() block in the CALLER's scope, so
# a param([switch]$SelfTest) here would reset capture-run's own -SelfTest to $false on the line after it
# bound, silently disarming it. Read the switch off $args, and only when this file is RUN, not dot-sourced.
$__gitBlobSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

if ($__gitBlobSelfTest) {
  $ErrorActionPreference = 'Continue'
  $fail = 0; $cases = 0
  function GbT([string]$m, [bool]$cond, [string]$got = '') {
    $script:cases++
    if ($cond) { Write-Output ('  ok    ' + $m) } else { Write-Output ('  FAIL  ' + $m + '   got: ' + $got); $script:fail++ }
  }

  # ---- the Windows quoting, which is where a hand-built argument string goes wrong silently ------------
  GbT 'a plain argument is passed unquoted' ((ConvertTo-GitArgString -GitArgs @('status')) -eq 'status')
  GbT 'a commit message with spaces survives as ONE argument' `
      ((ConvertTo-GitArgString -GitArgs @('-m', 'Daily pipeline: refresh prices + feed (2026-09-09) [daily]')) -eq '-m "Daily pipeline: refresh prices + feed (2026-09-09) [daily]"')
  GbT 'an embedded double quote is escaped, not dropped' `
      ((ConvertTo-GitArgString -GitArgs @('a"b')) -eq '"a\"b"')
  GbT 'a trailing backslash cannot escape our own closing quote' `
      ((ConvertTo-GitArgString -GitArgs @('C:\path with space\')) -eq '"C:\path with space\\"')

  # ---- Format-GitRefusal, driven by TODAY'S REAL STDERR --------------------------------------------
  # FROZEN, transcribed from the 2026-09-09 reproduction of the hook that refused both scheduled runs.
  # Never regenerated from a live run: the bug it encodes would be repaired away and the case would then
  # pass by finding nothing, which is the whole reason a fixture is frozen.
  #
  # THE TWO PATHS ARE NAMED ONCE. They are the text the HOOK printed and the seed file of a %TEMP%
  # throwaway repo; nothing in this file opens either. Hoisted so the literal appears once rather than
  # eight times, which is better fixture code and also keeps ops\audit-cross-module-reach's site count
  # honest - see the reach-fixture-ok rule there.
  $fxBomFile  = 'grocery/out/json-readers-baseline.json'   # reach-fixture-ok: the file the 09-09 hook named in its own stderr; this is quoted text, not a read
  $fxHookFile = 'grocery/out/x.json'                       # reach-fixture-ok: a seed file inside a %TEMP% throwaway repo, never this repo's grocery\out
  $realStderr = @(
    'verify-bulk-edit: 118 modified tracked file(s) compared against HEAD; 0 .ps1 parsed clean; 1 finding(s)',
    ('  BOM CHANGED   ' + $fxBomFile + ' - a read/write pair stripped or added a byte-order mark'),
    'VERIFY-BULK-EDIT-COMPLETE 1 finding(s) over 118 file(s)',
    '',
    'pre-commit: BLOCKED. The staged set fails a bulk-edit invariant (BOM state, line-ending style,',
    '            a clean parse, or a call to a function the file cannot resolve).'
  ) -join "`n"
  $ref = Format-GitRefusal -Rc 1 -Stderr $realStderr
  GbT 'MUST FIRE  the refusal names the offending FILE (this is 2026-09-09-a95022, both scheduled runs)' `
      ($ref.files -contains $fxBomFile) (($ref.files) -join ', ')
  GbT 'MUST FIRE  every hook line reaches the transcript prefixed commit:hook>' `
      ((@($ref.transcript | Where-Object { $_ -like 'commit:hook> *BOM CHANGED*' }).Count -eq 1) -and $ref.transcript.Count -ge 5) `
      ("lines=" + $ref.transcript.Count)
  GbT 'MUST FIRE  the summary line is the one a human reads first' `
      ($ref.summary -like ('*files named by the hook: ' + $fxBomFile + '*')) $ref.summary
  # MUST NOT FIRE: prose that merely discusses the markers is not a path, and a refusal that names no file
  # must SAY it named none rather than inventing one.
  $refNone = Format-GitRefusal -Rc 1 -Stderr "error: cannot lock ref 'refs/heads/main'"
  GbT 'MUST NOT FIRE  a refusal naming no path reports none rather than fabricating one' `
      (($refNone.files.Count -eq 0) -and ($refNone.summary -like '*none*')) $refNone.summary

  # ---- Invoke-GitCaptured against a THROWAWAY repo, never this one -------------------------------------
  function New-HookRepo([string]$HookBody) {
    $c = Join-Path $env:TEMP ('gblob-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory $c -Force | Out-Null
    & git -C $c init -q . | Out-Null
    & git -C $c config user.email t@t | Out-Null
    & git -C $c config user.name t | Out-Null
    # autocrlf off IN THE FIXTURE ONLY: on this box the global is true, and its "LF will be replaced by
    # CRLF" notice goes to STDERR, which would contaminate the clean twin's "stderr is empty" assertion
    # with noise that has nothing to do with what is under test.
    & git -C $c config core.autocrlf false | Out-Null
    'seed' | Set-Content (Join-Path $c 'seed.txt')
    & git -C $c add -- seed.txt | Out-Null
    & git -C $c commit -q -m seed | Out-Null
    if ($HookBody) {
      $h = Join-Path $c '.git\hooks\pre-commit'
      [IO.File]::WriteAllText($h, ($HookBody -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
    }
    'work' | Set-Content (Join-Path $c 'work.txt')
    & git -C $c add -- work.txt | Out-Null
    return $c
  }
  function Get-HeadCount([string]$Repo) { return [int](@(& git -C $Repo rev-list --count HEAD)[0]) }

  # MUST FIRE: the founding shape. A hook that refuses on stderr and exits 1.
  $repoNo = New-HookRepo "#!/usr/bin/env bash`necho 'HOOK-SAYS-NO $fxHookFile' >&2`necho 'pre-commit: BLOCKED.' >&2`nexit 1`n"
  $before = Get-HeadCount $repoNo
  $rNo = Invoke-GitCaptured -Repo $repoNo -GitArgs @('-c', 'user.name=smp-pipeline-bot', '-c', 'user.email=actions@users.noreply.github.com', 'commit', '-m', 'Daily pipeline: refresh prices + feed (2026-09-09) [daily]')
  $afterNo = Get-HeadCount $repoNo
  GbT 'MUST FIRE  a refused commit returns rc<>0 and the hook''s OWN LINE on .stderr' `
      (($rNo.rc -ne 0) -and ($rNo.stderr -match ('HOOK-SAYS-NO ' + [regex]::Escape($fxHookFile)))) ("rc=$($rNo.rc) stderr=$($rNo.stderr)")
  GbT 'MUST FIRE  and HEAD did NOT advance on a refusal' ($afterNo -eq $before) ("before=$before after=$afterNo")
  $refReal = Format-GitRefusal -Rc $rNo.rc -Stderr $rNo.stderr
  GbT 'MUST FIRE  the composed report names the file the hook named and carries the commit:hook> line' `
      (($refReal.files -contains $fxHookFile) -and (@($refReal.transcript | Where-Object { $_ -eq ('commit:hook> HOOK-SAYS-NO ' + $fxHookFile) }).Count -eq 1)) `
      (($refReal.files -join ', ') + ' | ' + ($refReal.transcript -join ' ~ '))

  # CLEAN TWIN: the adjacent behaviour the change was most likely to break - an ORDINARY commit still commits.
  $repoOk = New-HookRepo "#!/usr/bin/env bash`nexit 0`n"
  $beforeOk = Get-HeadCount $repoOk
  $rOk = Invoke-GitCaptured -Repo $repoOk -GitArgs @('commit', '-m', 'an ordinary day')
  $afterOk = Get-HeadCount $repoOk
  GbT 'CLEAN TWIN a permitted commit still returns rc=0 with an EMPTY stderr' `
      (($rOk.rc -eq 0) -and ([string]$rOk.stderr).Trim() -eq '') ("rc=$($rOk.rc) stderr=[$($rOk.stderr)]")
  GbT 'CLEAN TWIN and HEAD advanced by exactly one commit' ($afterOk -eq $beforeOk + 1) ("before=$beforeOk after=$afterOk")
  GbT 'CLEAN TWIN git''s own summary is on .stdout, so nothing is lost by not merging the streams' `
      ($rOk.stdout -match 'an ordinary day') ("stdout=[$($rOk.stdout)]")

  # THE ONE REAL HAZARD THE DESIGN NAMES: a chatty hook. A pipe buffer is 4-64 KB, so a hook that writes
  # more than that blocks in its own write until someone drains it; a WaitForExit-then-read would hang the
  # 07:00 run forever and read as a frozen box. 4,000 lines is comfortably past every buffer size.
  $repoLoud = New-HookRepo "#!/usr/bin/env bash`nfor i in `$(seq 1 4000); do echo `"noisy line `$i BOM CHANGED $fxHookFile`" >&2; done`nexit 1`n"
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $rLoud = Invoke-GitCaptured -Repo $repoLoud -GitArgs @('commit', '-m', 'loud')
  $sw.Stop()
  GbT 'MUST FIRE  a hook writing 4,000 stderr lines returns instead of deadlocking the pipe' `
      (($rLoud.rc -ne 0) -and (@($rLoud.stderr -split "`n").Count -ge 3900) -and ($sw.Elapsed.TotalSeconds -lt 60)) `
      ("rc=$($rLoud.rc) lines=$(@($rLoud.stderr -split "`n").Count) secs=$([math]::Round($sw.Elapsed.TotalSeconds,1))")
  GbT 'MUST FIRE  and the report is CAPPED so a chatty hook cannot flood the alert body' `
      ((Format-GitRefusal -Rc 1 -Stderr $rLoud.stderr).transcript.Count -le 20) `
      ((Format-GitRefusal -Rc 1 -Stderr $rLoud.stderr).transcript.Count)

  # COULD-NOT-RUN IS NOT A REFUSAL. rc -1 means git never started; a caller that read that as "the hook
  # said no" would report a false diagnosis, which is the defect class this whole change is about.
  $rMissing = Invoke-GitCaptured -Repo (Join-Path $env:TEMP ('nope-' + [guid]::NewGuid().ToString('N'))) -GitArgs @('rev-parse', 'HEAD')
  GbT 'MUST NOT FIRE  a repo that does not exist is a nonzero rc with git''s own words, never a silent 0' `
      ($rMissing.rc -ne 0) ("rc=$($rMissing.rc)")

  foreach ($z in @($repoNo, $repoOk, $repoLoud)) { Remove-Item $z -Recurse -Force -ErrorAction SilentlyContinue }

  Write-Output ''
  if ($fail) {
    Write-Output ("GIT-BLOB-LIB SELF-TEST FAILED: {0} of {1} case(s) failed" -f $fail, $cases)
    Write-Output ("GIT-BLOB-LIB-COMPLETE cases={0} failed={1}" -f $cases, $fail)
    exit 1
  }
  Write-Output ("GIT-BLOB-LIB SELF-TEST PASSED: {0}/{1} cases - a refusal keeps the hook's own lines and names the file; an ordinary commit still commits" -f $cases, $cases)
  Write-Output ("GIT-BLOB-LIB-COMPLETE cases={0} failed=0" -f $cases)
  exit 0
}
