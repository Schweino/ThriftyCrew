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
#
# GIT'S LINE-ENDING WARNINGS ARE NOT THE REFUSAL, AND THEY USED TO HIDE IT (2026-09-11). Git writes a
# `warning: in the working copy of '<file>', CRLF will be replaced by LF` line for every staged CRLF file to the
# same stderr, BEFORE the hook runs - one each in the 09-09 and 09-10 logs, and two each on a pathspec commit in a
# 2026-09-11 sandbox (50 lines for 25 files). This kept the first 20 lines, so a lane staging more than about 20 CRLF files
# reported 20 warnings and no reason: grocery\ad-cycle-log.txt at 2026-09-10T11:50:57 is exactly that, and
# its summary named the first 12 WARNED files, which the hook may never have refused. The warnings are now
# folded into one count line, and the lines that carry the reason are kept ahead of everything else.
#
# THE REFUSED PATHS ARE OFTEN NOT ON THE MARKER LINE. bot-commit-scope prints
#     bot-commit-scope: REFUSING - ... but stages 2 path(s) it does not own:
#         meal-prep/db/candidate-pool.json
# with the paths indented BELOW a line that carries none, then prose that mentions lib\bot-paths.ps1. With no
# path on any marker line the old second tier took every file-like token from every line, warnings and prose
# included, so grocery\out\logs\harvest-crawl-2026-09-09.log named source-domains.json (only ever WARNED about)
# and lib\bot-paths.ps1 (prose) as refused. A path line is now read as one: indented DEEPER than the marker
# above it, and nothing on it but the path.
function Format-GitRefusal {
  param(
    [int]$Rc,
    [string]$Stderr,
    # The cap on the OTHER lines: prose, checker headers, completion markers.
    [int]$MaxLines = 20,
    # The cap on REASON lines (a marker, and the path lines and '...and N more' indented under it), which are
    # kept first. 40 is the first plausible number, not the survivor of a sweep: the largest block a checker
    # prints today is bot-commit-scope's, 33 lines (REFUSING, its 30-path list, '...and N more', BLOCKED).
    # verify-bulk-edit prints one finding per file and has no list cap, so past 40 the first 35 and the last 5
    # reason lines are kept - the last is the hook's own BLOCKED - and the omission is counted. `files` is
    # never capped; the summary lists 12 and says how many more.
    [int]$MaxReasonLines = 40
  )
  $lines = @()
  if ($Stderr) { $lines = @(($Stderr -split "`r?`n") | Where-Object { $_.Trim().Length -gt 0 }) }
  # The five refusal exits the hook can take, plus git's own.
  #
  # TWO TIERS, AND THE SECOND ONE IS THE POINT. Keying extraction solely on the markers the hook writes
  # TODAY is the [[rules-that-silently-disarm]] shape aimed at our own diagnostics: the day someone adds a
  # sixth refusal exit, or rewords one, the alert silently goes back to naming no file and nothing says so.
  # So: prefer a path on a marker line or indented under one (high confidence), and if there is none, take
  # any token from any non-warning line that looks like a repo FILE - a separator plus a real extension. That
  # last clause is what keeps `error: cannot lock ref 'refs/heads/main'` from being reported as a file.
  $rx     = 'BOM CHANGED|PARSE FAIL|DEPENDENCY|FROZEN LITERAL|REFUSING|BLOCKED'
  $tok    = '[A-Za-z0-9_.\-]+(?:[\\/][A-Za-z0-9_.\-]+)+'
  $warnRx = '^warning: in the working copy of ''|^warning: (CR)?LF will be replaced by (CR)?LF|^The file will have its original line endings in your working directory'
  $moreRx = '^\.\.\.and \d+ more$'
  # A token on a marker or path line is a file when it has an extension or at least two separators. The
  # separator alone was not enough: the 2026-09-09 BOM CHANGED line's own prose, 'a read/write pair', was
  # named as a file beside the real one.
  $fileRx = '\.[A-Za-z0-9]{1,6}$|^[^\\/]+[\\/][^\\/]+[\\/]'

  # ---- classify every line: warn | marker | path | more | other ----
  $kind = New-Object 'string[]' $lines.Count
  $blockIndent = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = [string]$lines[$i]
    if ($l -match $warnRx) { $kind[$i] = 'warn'; continue }
    $indent = $l.Length - $l.TrimStart().Length
    # Inside a marker's block, a deeper line holding nothing but a path is a PATH even if its name happens to
    # contain a marker word. Checked before the marker test for that reason.
    if ($blockIndent -ge 0 -and $indent -gt $blockIndent) {
      $t = $l.Trim().Trim('"')
      if ($t -match ('^' + $tok + '$')) { $kind[$i] = 'path'; continue }
      if ($t -match $moreRx) { $kind[$i] = 'more'; continue }
    }
    if ($l -match $rx) { $kind[$i] = 'marker'; $blockIndent = $indent; continue }
    if (-not ($blockIndent -ge 0 -and $indent -gt $blockIndent)) { $blockIndent = -1 }
    $kind[$i] = 'other'
  }

  # ---- files ----
  $files = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($kind[$i] -eq 'path') {
      $v = ([string]$lines[$i]).Trim().Trim('"').TrimEnd('.', ',', ')')
      if ($v -and $v -match $fileRx -and -not $files.Contains($v)) { [void]$files.Add($v) }
    } elseif ($kind[$i] -eq 'marker') {
      foreach ($m in [regex]::Matches([string]$lines[$i], $tok)) {
        $v = $m.Value.TrimEnd('.', ',', ')')
        if ($v -and $v -match $fileRx -and -not $files.Contains($v)) { [void]$files.Add($v) }
      }
    }
  }
  if (-not $files.Count) {
    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($kind[$i] -eq 'warn') { continue }   # a warned file is a staged file, not a refused one
      foreach ($m in [regex]::Matches([string]$lines[$i], $tok)) {
        $v = $m.Value.TrimEnd('.', ',', ')')
        if ($v -notmatch '\.[A-Za-z0-9]{1,6}$') { continue }   # a ref or a URL path is not a file to go and fix
        if ($v -and -not $files.Contains($v)) { [void]$files.Add($v) }
      }
    }
  }

  # ---- transcript: reason lines first, then other lines while room remains, in the hook's own order ----
  $reasons = New-Object 'System.Collections.Generic.List[int]'
  $others  = New-Object 'System.Collections.Generic.List[int]'
  $warnCount = 0
  for ($i = 0; $i -lt $lines.Count; $i++) {
    switch ($kind[$i]) {
      'warn'  { $warnCount++ }
      'other' { $others.Add($i) }
      default { $reasons.Add($i) }
    }
  }
  $keep = New-Object 'bool[]' $lines.Count
  if ($reasons.Count -le $MaxReasonLines) {
    foreach ($i in $reasons) { $keep[$i] = $true }
    $keptReasons = $reasons.Count
  } else {
    $tail = [Math]::Min(5, [int][Math]::Floor($MaxReasonLines / 2))
    $head = $MaxReasonLines - $tail
    for ($k = 0; $k -lt $head; $k++) { $keep[$reasons[$k]] = $true }
    for ($k = $reasons.Count - $tail; $k -lt $reasons.Count; $k++) { $keep[$reasons[$k]] = $true }
    $keptReasons = $MaxReasonLines
  }
  $room = $MaxLines - $keptReasons
  for ($k = 0; ($k -lt $others.Count) -and ($k -lt $room); $k++) { $keep[$others[$k]] = $true }

  $transcript = New-Object 'System.Collections.Generic.List[string]'
  $warnNoted = $false; $shown = 0
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($kind[$i] -eq 'warn') {
      if (-not $warnNoted) {
        $transcript.Add(('commit:hook> ({0} git line-ending warning(s) omitted - "in the working copy of ''<file>'', CRLF will be replaced by LF" - git prints these for staged CRLF files before the hook runs, and none of them is the refusal)' -f $warnCount))
        $warnNoted = $true
      }
      continue
    }
    if ($keep[$i]) { $transcript.Add('commit:hook> ' + $lines[$i]); $shown++ }
  }
  $hookLines = $lines.Count - $warnCount
  if ($shown -lt $hookLines) {
    $transcript.Add(('commit:hook> ({0} of {1} hook line(s) not shown - the refusal''s marker and path lines are kept first, up to {2})' -f ($hookLines - $shown), $hookLines, $MaxReasonLines))
  }

  $summary = if ($files.Count -gt 12) {
               'files named by the hook: ' + ($files.GetRange(0, 12).ToArray() -join ', ') + (' ... and {0} more ({1} in all)' -f ($files.Count - 12), $files.Count)
             } elseif ($files.Count) { 'files named by the hook: ' + ($files.ToArray() -join ', ') }
             else { 'files named by the hook: none - the refusal named no path (read the commit:hook> lines above)' }
  return @{
    rc         = $Rc
    transcript = @($transcript.ToArray())
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
  # New-HookRepo below builds temp repos. Cleared HERE and never at load: capture-run dot-sources this file and runs
  # its commit under a private GIT_INDEX_FILE (2026-09-10; lib\git-repo-env.ps1).
  . (Join-Path $PSScriptRoot 'git-repo-env.ps1'); Clear-TcGitRepoEnv
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

  # ---- THE REASON SURVIVES GIT'S LINE-ENDING WARNINGS (2026-09-11) ------------------------------------
  # FROZEN from grocery\out\logs\harvest-crawl-2026-09-09.log (untracked; read in the main checkout), with the
  # commit:hook> prefix stripped and the hook's own `echo ""` restored. Git writes one CRLF warning per staged
  # CRLF file BEFORE the hook runs, and bot-commit-scope prints its REFUSING line with NO path and the refused
  # paths indented BELOW it. The code this replaced named source-domains.json, which only a WARNING mentions,
  # and lib\bot-paths.ps1, which only the prose mentions, as refused files.
  $fxPool   = 'meal-prep/db/candidate-pool.json'   # reach-fixture-ok: quoted from the 2026-09-09 hook stderr; nothing here opens it
  $fxState  = 'meal-prep/db/harvest-state.json'    # reach-fixture-ok: quoted from the 2026-09-09 hook stderr; nothing here opens it
  $fxDomain = 'meal-prep/db/source-domains.json'   # reach-fixture-ok: quoted from the 2026-09-09 git warning; nothing here opens it
  function GbWarn([string]$p) { return ("warning: in the working copy of '" + $p + "', CRLF will be replaced by LF the next time Git touches it") }
  $scopeTail = @(
    '  An automated commit stages its OWN outputs and nothing else - a shared working tree always',
    '  holds somebody else''s half-finished work (2026-09-05: 192 .ps1 files mid-edit, 27 of them',
    '  throwing at startup, on main for 59 minutes).',
    '  If a path above genuinely belongs to the pipeline, declare it in lib\bot-paths.ps1 with the',
    '  writer''s name and the reason. Do not widen the list to make one run go through.',
    '',
    'pre-commit: BLOCKED. This commit identifies as the pipeline but stages paths outside',
    '            lib\bot-paths.ps1. An automated commit stages its OWN outputs and nothing else.',
    '            Fix the staging, declare the path in lib\bot-paths.ps1, or use --no-verify.'
  )
  $harvestStderr = (@(
    (GbWarn $fxPool), (GbWarn $fxState), (GbWarn $fxDomain),
    'bot-commit-scope: REFUSING - this commit identifies as the pipeline (author ''smp-pipeline-bot'') but stages 2 path(s) it does not own:',
    ('    ' + $fxPool),
    ('    ' + $fxState)) + $scopeTail) -join "`n"
  $hv = Format-GitRefusal -Rc 1 -Stderr $harvestStderr
  $hvFiles = @($hv.files)
  GbT 'MUST FIRE  the 2026-09-09 harvest refusal names exactly the two paths bot-commit-scope refused, not a warned file or a prose path' `
      (($hvFiles.Count -eq 2) -and ($hvFiles -contains $fxPool) -and ($hvFiles -contains $fxState)) ($hvFiles -join ', ')
  GbT 'MUST FIRE  and its summary names those two and nothing else' `
      ($hv.summary -eq ('files named by the hook: ' + $fxPool + ', ' + $fxState)) $hv.summary
  GbT 'MUST FIRE  its transcript keeps REFUSING, both indented paths and BLOCKED, and folds the 3 CRLF warnings into one count line' `
      ((@($hv.transcript | Where-Object { $_ -like 'commit:hook> bot-commit-scope: REFUSING*' }).Count -eq 1) -and
       ($hv.transcript -contains ('commit:hook>     ' + $fxPool)) -and
       ($hv.transcript -contains ('commit:hook>     ' + $fxState)) -and
       (@($hv.transcript | Where-Object { $_ -like 'commit:hook> pre-commit: BLOCKED*' }).Count -eq 1) -and
       (@($hv.transcript | Where-Object { $_ -like 'commit:hook> warning:*' }).Count -eq 0) -and
       (@($hv.transcript | Where-Object { $_ -like 'commit:hook> (3 git line-ending warning(s) omitted*' }).Count -eq 1)) `
      ($hv.transcript -join ' ~ ')

  # MUST FIRE: the 2026-09-10T11:50:57 check-ad-cycles shape in grocery\ad-cycle-log.txt, where 20 kept lines were all
  # warnings and the reason was cut. 25 warnings, then the refusal; the two refused files are among the warned ones, as
  # they are in life, so naming them proves they came from the indented block and not from a warning.
  $manyWarn = @(1..25 | ForEach-Object { GbWarn ('lane/out/f{0:D2}.json' -f $_) })
  $s25 = (@($manyWarn) + @(
    'bot-commit-scope: REFUSING - this commit identifies as the pipeline (author ''smp-pipeline-bot'') but stages 2 path(s) it does not own:',
    '    lane/out/f24.json',
    '    lane/out/f25.json') + $scopeTail) -join "`n"
  $r25 = Format-GitRefusal -Rc 1 -Stderr $s25
  GbT 'MUST FIRE  25 CRLF warnings ahead of the hook no longer push its REFUSING, path and BLOCKED lines past the 20-line cap' `
      ((@($r25.transcript | Where-Object { $_ -like 'commit:hook> bot-commit-scope: REFUSING*' }).Count -eq 1) -and
       ($r25.transcript -contains 'commit:hook>     lane/out/f24.json') -and
       ($r25.transcript -contains 'commit:hook>     lane/out/f25.json') -and
       (@($r25.transcript | Where-Object { $_ -like 'commit:hook> pre-commit: BLOCKED*' }).Count -eq 1) -and
       (@($r25.transcript | Where-Object { $_ -like 'commit:hook> warning:*' }).Count -eq 0)) `
      ($r25.transcript -join ' ~ ')
  GbT 'MUST FIRE  and the files are the two it refused, not the first twelve it warned about' `
      ((@($r25.files).Count -eq 2) -and ($r25.files -contains 'lane/out/f24.json') -and ($r25.files -contains 'lane/out/f25.json')) (@($r25.files) -join ', ')

  # MUST FIRE: bot-commit-scope lists up to 30 paths and then '...and N more'. Every one of those lines, and BLOCKED
  # below them, outranks the 20-line cap; the prose is what gives way, and the transcript says how much it dropped.
  $p30 = @(1..30 | ForEach-Object { 'lane/out/r{0:D2}.json' -f $_ })
  $s30 = (@($manyWarn) +
    @('bot-commit-scope: REFUSING - this commit identifies as the pipeline (author ''smp-pipeline-bot'') but stages 34 path(s) it does not own:') +
    @($p30 | ForEach-Object { '    ' + $_ }) + @('    ...and 4 more') + $scopeTail) -join "`n"
  $r30 = Format-GitRefusal -Rc 1 -Stderr $s30
  $kept30 = @($p30 | Where-Object { $r30.transcript -contains ('commit:hook>     ' + $_) })
  GbT 'MUST FIRE  a 30-path refusal keeps all 30 path lines, its ...and 4 more line and BLOCKED although that is past 20 lines' `
      (($kept30.Count -eq 30) -and ($r30.transcript -contains 'commit:hook>     ...and 4 more') -and
       (@($r30.transcript | Where-Object { $_ -like 'commit:hook> pre-commit: BLOCKED*' }).Count -eq 1)) `
      ('kept ' + $kept30.Count + ' of 30 path lines; transcript ' + $r30.transcript.Count + ' lines')
  GbT 'MUST FIRE  and a trimmed transcript says how many hook lines it left out, with the denominator' `
      (@($r30.transcript | Where-Object { $_ -eq 'commit:hook> (7 of 40 hook line(s) not shown - the refusal''s marker and path lines are kept first, up to 40)' }).Count -eq 1) `
      ($r30.transcript[-1])
  GbT 'MUST FIRE  and a summary listing 12 of 30 files says how many it did not list' `
      ($r30.summary -like '* ... and 18 more (30 in all)') $r30.summary

  # MUST NOT FIRE: a path counts as refused only when it sits DEEPER than its marker. A line at the marker's own depth
  # holding nothing but a path is not part of the list. (Named by a surviving mutant, 2026-09-11: -gt read as -ge.)
  $depth = (@(
    'bot-commit-scope: REFUSING - this commit identifies as the pipeline (author ''smp-pipeline-bot'') but stages 1 path(s) it does not own:',
    '    lane/out/a.json',
    'lane/out/not-refused.json') -join "`n")
  $rd = Format-GitRefusal -Rc 1 -Stderr $depth
  GbT 'MUST NOT FIRE  a lone path at the marker''s own depth is not read as one of the paths it refused' `
      ((@($rd.files).Count -eq 1) -and ($rd.files -contains 'lane/out/a.json')) (@($rd.files) -join ', ')

  # MUST NOT FIRE: warnings ahead of a refusal that names no path at all - ops\hooks\pre-commit's no-working-tree
  # branch, verbatim. The fallback tier must not hand the WARNED files back as the answer. (Named by a surviving
  # mutant, 2026-09-11: every other warning fixture had a tier-1 path, so the fallback never ran beside a warning.)
  $noPath = (@(
    (GbWarn 'lane/out/w1.json'), (GbWarn 'lane/out/w2.json'),
    'pre-commit: REFUSING - git could not resolve this checkout''s working tree, so nothing verified this commit.',
    '            If ''git config core.bare'' says true in a checkout, the shared config is damaged: repair that first.',
    '            Bypass with: git commit --no-verify') -join "`n")
  $rn = Format-GitRefusal -Rc 1 -Stderr $noPath
  GbT 'MUST NOT FIRE  warnings ahead of a refusal that names no path report none, never the warned files' `
      ((@($rn.files).Count -eq 0) -and ($rn.summary -like '*none*')) $rn.summary

  # CLEAN TWIN: a verify-bulk-edit finding carries its path on the marker line itself. With CRLF warnings ahead of it,
  # one of them for that very file, it is still named, and named once.
  $twin = (@(
    (GbWarn $fxBomFile), (GbWarn 'lane/out/other.json'),
    'verify-bulk-edit: 2 modified tracked file(s) compared against HEAD; 0 .ps1 parsed clean; 1 finding(s)',
    ('  BOM CHANGED   ' + $fxBomFile + ' - a read/write pair stripped or added a byte-order mark'),
    'VERIFY-BULK-EDIT-COMPLETE 1 finding(s) over 2 file(s)',
    '',
    'pre-commit: BLOCKED. The staged set fails a bulk-edit invariant (BOM state, line-ending style,',
    '            a clean parse, or a call to a function the file cannot resolve).') -join "`n")
  $tw = Format-GitRefusal -Rc 1 -Stderr $twin
  GbT 'CLEAN TWIN a BOM CHANGED line carrying its own path still names that one file, and the line reaches the transcript' `
      ((@($tw.files).Count -eq 1) -and ($tw.files -contains $fxBomFile) -and
       ($tw.transcript -contains ('commit:hook>   BOM CHANGED   ' + $fxBomFile + ' - a read/write pair stripped or added a byte-order mark'))) `
      ((@($tw.files) -join ', ') + ' | ' + ($tw.transcript -join ' ~ '))

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

  # LIVE TWIN OF THE FROZEN WARNING CASES, against this box's real git (2026-09-11). Those fixtures freeze git's wording
  # as it was on 2026-09-09; if a git upgrade rewords 'in the working copy of', the warnings stop folding and the reason
  # is pushed past the cap again, with nothing saying so. So here git prints the warnings itself: CRLF files in the
  # working copy under eol=lf, which is the estate's shape (core.autocrlf=true does NOT print this warning - measured
  # the same day), committed with a pathspec as lib\pipeline-commit.ps1 commits.
  $repoCrlf = New-HookRepo ("#!/usr/bin/env bash`n" +
    "echo `"bot-commit-scope: REFUSING - this commit identifies as the pipeline (author 'smp-pipeline-bot') but stages 2 path(s) it does not own:`" >&2`n" +
    "echo `"    lane/out/f24.json`" >&2`n" +
    "echo `"    lane/out/f25.json`" >&2`n" +
    "echo `"`" >&2`n" +
    "echo `"pre-commit: BLOCKED. This commit identifies as the pipeline but stages paths outside`" >&2`n" +
    "exit 1`n")
  [IO.File]::WriteAllText((Join-Path $repoCrlf '.gitattributes'), "* text=auto eol=lf`n")
  New-Item -ItemType Directory (Join-Path $repoCrlf 'lane\out') -Force | Out-Null
  foreach ($n in 1..25) { [IO.File]::WriteAllText((Join-Path $repoCrlf ('lane\out\f{0:D2}.json' -f $n)), ("{`"n`":" + $n + "}`r`n")) }
  [void](Invoke-GitCaptured -Repo $repoCrlf -GitArgs @('add', '--', '.gitattributes', 'lane/out'))
  $rCrlf = Invoke-GitCaptured -Repo $repoCrlf -GitArgs @('-c', 'user.name=smp-pipeline-bot', '-c', 'user.email=actions@users.noreply.github.com', 'commit', '-m', 'crlf', '--', 'lane/out')
  $crlfErr = @(([string]$rCrlf.stderr -split "`r?`n") | Where-Object { $_.Trim().Length })
  $gitWarned = @($crlfErr | Where-Object { $_ -like 'warning: in the working copy of*' }).Count
  GbT 'MUST FIRE  real git still prints its CRLF warnings on a refused commit''s stderr in the wording this file folds (red here means git reworded them: read the first line and fix the warning pattern)' `
      (($rCrlf.rc -ne 0) -and ($gitWarned -ge 25)) ('rc=' + $rCrlf.rc + ' warnings=' + $gitWarned + ' first=' + $(if ($crlfErr.Count) { $crlfErr[0] } else { '(no stderr)' }))
  $refCrlf = Format-GitRefusal -Rc $rCrlf.rc -Stderr $rCrlf.stderr
  GbT 'MUST FIRE  and behind real git''s warnings the refusal keeps REFUSING and BLOCKED, shows no warning line, and names only the two refused files' `
      ((@($refCrlf.files).Count -eq 2) -and ($refCrlf.files -contains 'lane/out/f24.json') -and ($refCrlf.files -contains 'lane/out/f25.json') -and
       (@($refCrlf.transcript | Where-Object { $_ -like 'commit:hook> bot-commit-scope: REFUSING*' }).Count -eq 1) -and
       (@($refCrlf.transcript | Where-Object { $_ -like 'commit:hook> pre-commit: BLOCKED*' }).Count -eq 1) -and
       (@($refCrlf.transcript | Where-Object { $_ -like 'commit:hook> warning:*' }).Count -eq 0)) `
      ((@($refCrlf.files) -join ', ') + ' | ' + ($refCrlf.transcript -join ' ~ '))

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
  # Every one of these 4,000 lines carries a marker, so since 2026-09-11 they are all REASON lines and the cap
  # that binds is MaxReasonLines (40), not MaxLines (20): 35 from the head, 5 from the tail, and one line
  # counting what was left out. 41 is the whole transcript; the old bar of 20 predates reason lines.
  $loudRef = Format-GitRefusal -Rc 1 -Stderr $rLoud.stderr
  GbT 'MUST FIRE  and the report is CAPPED so a chatty hook cannot flood the alert body' `
      (($loudRef.transcript.Count -le 41) -and ($loudRef.transcript[-1] -match '^commit:hook> \(\d+ of \d+ hook line\(s\) not shown')) `
      ('lines=' + $loudRef.transcript.Count + ' last=' + $loudRef.transcript[-1])
  GbT 'MUST FIRE  and a capped flood still keeps its LAST reason line, where a checker''s verdict sits' `
      (@($loudRef.transcript | Where-Object { $_ -like 'commit:hook> noisy line 4000 *' }).Count -eq 1) `
      ($loudRef.transcript[-2])

  # COULD-NOT-RUN IS NOT A REFUSAL. rc -1 means git never started; a caller that read that as "the hook
  # said no" would report a false diagnosis, which is the defect class this whole change is about.
  $rMissing = Invoke-GitCaptured -Repo (Join-Path $env:TEMP ('nope-' + [guid]::NewGuid().ToString('N'))) -GitArgs @('rev-parse', 'HEAD')
  GbT 'MUST NOT FIRE  a repo that does not exist is a nonzero rc with git''s own words, never a silent 0' `
      ($rMissing.rc -ne 0) ("rc=$($rMissing.rc)")

  foreach ($z in @($repoNo, $repoCrlf, $repoOk, $repoLoud)) { Remove-Item $z -Recurse -Force -ErrorAction SilentlyContinue }

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
