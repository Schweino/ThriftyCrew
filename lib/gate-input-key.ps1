<#
  gate-input-key.ps1 - the INPUT KEY of one gate, so a gate that already passed over exactly these bytes is not
  run again.

  Self-test:   powershell -File lib\gate-input-key.ps1 -SelfTest

  WHY (2026-09-12, Brad: "1141s per run is insane. If I have 20 sessions, they would be waiting a while to
  push"). lib\gate-verdict.ps1 already reuses a WHOLE run when the tree is byte-identical, which is why a
  re-push costs 3s. It cannot help the ordinary case: a session commits two files and every one of the 383
  gates runs again, including the 279 self-tests that could not have been affected. MEASURED that morning:
  874s of gate work in an up-to-date checkout and 1,141s estate-wide, against a median commit of 2 files. At
  10 slots that is 90 to 115s of machine time per push, and the push lock makes it serial: twenty sessions
  wait half an hour for the last one.

  THE KEY IS EVERY FILE THE GATE READS, and that is the whole safety argument. A gate is cached under a key
  built from its own bytes, the bytes of every library it dot-sources (transitively), the bytes of every
  repo file its source names as a literal, its argument, and the runner's own bytes. Change any of them and
  the key changes and the gate runs. The danger of a cache is a STALE PASS - a gate reported green over
  content it never saw - so the refusals below matter more than the hits.

  IT REFUSES MORE THAN IT ACCEPTS, DELIBERATELY. Measured over the 279 self-tests in the tree:
    185 cacheable      - every file they read is named in their source and goes into the key
     83 refused        - they read a DATA directory (grocery\out, meal-prep\db, public\, ...). Those bytes   # reach-fixture-ok: the shape this rule REFUSES, named in a pattern or written into a temp sandbox; nothing here opens a real data file
                         change with no commit at all, so no key over source could watch them.
     11 refused        - they build a path from a variable, and a key cannot watch what it cannot name.
  A refusal costs one gate run. A wrong acceptance costs the property the whole estate rests on, so anything
  this file cannot resolve is refused, and the refusals are counted in the run's own output.

  NOT AN EXPIRY, AND NOT A CLOCK. The key is content, so an entry is valid until its content changes. A max
  age is kept anyway as a backstop against a machine whose PowerShell or OS moved under it, and it is long.
#>
$__gikSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

# A DATA DIRECTORY IS BYTES THAT CHANGE WITHOUT A COMMIT. A gate that reads one cannot be keyed on source.
# reach-fixture-ok: these are the NAMES this rule refuses, not a reach - nothing here opens any of them, and a
# detector that names the directories it excludes cannot avoid spelling them.
# The DIRECTORIES whose bytes move without a commit. Kept as a body so the two rules below can ask a different
# question of the same list: one about a path joined to THIS repo, one about a drive-rooted literal.
$script:TcGateDataBody = '(?:grocery\\out|meal-prep\\db|meal-prep\\out|graph\\(?:gold|learning|out)|public\\|content\\|site\\|run\\waves|\.git\\)'   # reach-fixture-ok: the shape this rule REFUSES, named in a pattern; nothing here opens a real data file
$script:TcGateDataRx = '(?i)' + $script:TcGateDataBody
# Join-Path $repo $something: the second part is a variable, so the file it names cannot be read from source.
$script:TcGateComputedRx = '(?i)Join-Path\s+\$(repo|root|RepoRoot|here)\s+\$'
# Join-Path $repo 'a\b.ps1': a literal the key can resolve and hash.
$script:TcGateLiteralRx = '(?i)Join-Path\s+\$(?:repo|root|RepoRoot|here)\s+''([^'']+)'''
# A dot-sourced library, in the one spelling this estate uses.
$script:TcGateLibRx = '(?i)Join-Path\s+\$(?:repo|root|RepoRoot)\s+''(lib\\[^'']+\.ps1)'''
$script:TcGateKeyMaxAgeHours = 72

function Get-TcFileSha256 {
  param([string]$Path)
  if (-not [IO.File]::Exists($Path)) { return 'absent' }
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try { return ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLowerInvariant() }
    finally { $fs.Dispose() }
  } catch { return 'unreadable' } finally { $sha.Dispose() }
}

function Get-TcGateReferencedPaths {
  <# Pure over TEXT. Every repo-relative path the source names as a literal, plus the libs it dot-sources.
     Returns Paths (repo-relative, de-duplicated, ordered) and Computed ($true when it builds one from a
     variable, which is what makes a gate uncacheable). #>
  param([string]$Text)
  $paths = [Collections.Generic.List[string]]::new()
  $seen = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
  foreach ($m in [regex]::Matches($Text, $script:TcGateLiteralRx)) {
    $p = $m.Groups[1].Value
    if (-not $p) { continue }
    if (-not $seen.ContainsKey($p)) { $seen[$p] = $true; $paths.Add($p) }
  }
  $sorted = $paths.ToArray()
  [Array]::Sort($sorted, [StringComparer]::OrdinalIgnoreCase)
  return [pscustomobject]@{ Paths = @($sorted); Computed = [regex]::IsMatch($Text, $script:TcGateComputedRx) }
}

function Remove-TcGateComments {
  <# Pure. Drops whole-line comments before the refusal rules read the text. A comment cannot open a file, and
     a header that DESCRIBES the data a script avoids would otherwise refuse it: measured 2026-09-12, 12 of the
     279 self-tests were refused for a data path that appears only in prose or on a fixture line. #>
  param([string]$Text)
  $out = [Collections.Generic.List[string]]::new()
  foreach ($l in ($Text -split "`n")) {
    $t = $l.TrimStart()
    if ($t.StartsWith('#')) { continue }
    if ($l -match 'reach-fixture-ok') { continue }
    $out.Add($l)
  }
  return ($out -join "`n")
}

function Test-TcGateCacheable {
  <# Pure over TEXT. Why is returned even on success, so a run can print WHY a gate was refused rather than
     leaving a reader to guess which of the two rules bit.

     IT ASKS WHAT THE PATH IS JOINED TO (2026-09-12). The first version matched a data directory ANYWHERE in
     the text, so a suite that builds a sandbox repo under %TEMP% and writes `Join-Path $main '.git\...'` was
     refused as a data reader. That is how the most expensive gates on the box - the ones that test the push
     and commit hooks, 54s and 34s - stayed uncacheable while reading nothing of this estate's data at all.
     A read of THIS repo's data is joined to the repo root; a path joined to some other variable is a sandbox
     the suite made itself. A bare literal with no join is still refused, because it names a real place. #>
  param([string]$Text)
  $code = Remove-TcGateComments -Text $Text
  if ([regex]::IsMatch($code, ('(?i)Join-Path\s+\$(?:repo|root|RepoRoot|here)\s+''' + $script:TcGateDataBody))) {
    return [pscustomobject]@{ Ok = $false; Why = 'reads a data directory under this repo, whose bytes change with no commit' }
  }
  # A DRIVE-ROOTED literal names a real place on this box whatever it is joined to, so it is still refused.
  # A relative literal is NOT, because that is what a sandbox path looks like: 'Join-Path $main ''.git\hooks'''
  # builds a temp repo, and refusing it cost the two hook suites - the most expensive gates here - for nothing.
  if ([regex]::IsMatch($code, ('(?i)''[A-Za-z]:\\[^'']*' + $script:TcGateDataBody))) {
    return [pscustomobject]@{ Ok = $false; Why = 'names a data path on this box as an absolute literal' }
  }
  if ([regex]::IsMatch($Text, $script:TcGateComputedRx)) {
    return [pscustomobject]@{ Ok = $false; Why = 'builds a repo path from a variable, which a source key cannot watch' }
  }
  return [pscustomobject]@{ Ok = $true; Why = '' }
}

# A GATE MAY DECLARE WHAT IT READS, instead of being guessed at (Brad, 2026-09-12). One line in its own source:
#
#     # gate-inputs: lib\*.ps1, ops\hooks\pre-push, ops\prepush-test-auditors.ps1
#
# WHY IT EXISTS. The rules below INFER a gate's inputs from its source text, and inference has exactly two failure
# directions. Guessing too wide refuses a gate that reads nothing of the kind - 53 of 293 on 2026-09-12, among them
# every expensive suite on the box, and ops\test-prepush-hook.ps1 (67s) which cannot EVER be inferred because it
# copies lib\*.ps1 by DIRECTORY ENUMERATION and no source key can name a listing. Guessing too narrow would reuse a
# stale pass, which is why the inference is deliberately conservative and why its refusals are not a bug.
# A declaration replaces the guess with an assertion the author signed, visible in a diff and reviewable as code.
#
# WHAT IT DOES NOT DO. It does not shorten the key: every declared path is hashed, globs and all, and the transitive
# walk still follows a declared .ps1 into what IT loads, so a library two hops away still moves the key.
# A DECLARED PATH THAT MATCHES NOTHING IS A REFUSAL, never an empty set: a typo'd or stale declaration would
# otherwise narrow the input set silently, which is the one direction that turns into a stale pass.
$script:TcGateDeclRx = '(?im)^[ \t]*#[ \t]*gate-inputs:[ \t]*(.+?)[ \t]*$'

function Get-TcGateDeclaredInputs {
  <# The declared input patterns, in source order, or an empty array when the gate declares none. Pure over text so
     the fixture drives it without a disk. #>
  param([string]$Text)
  $out = [Collections.Generic.List[string]]::new()
  foreach ($m in [regex]::Matches($Text, $script:TcGateDeclRx)) {
    foreach ($p in ($m.Groups[1].Value -split ',')) {
      $t = $p.Trim()
      if ($t) { [void]$out.Add($t) }
    }
  }
  return @($out)
}

function Resolve-TcGateDeclaredInputs {
  <# Expand declared patterns against the repo root. Returns Ok and either Paths (relative, sorted ordinally) or
     Why. A pattern matching nothing refuses the whole gate; so does one that escapes the repo. #>
  param([string]$Repo, [string[]]$Patterns)
  $repoFull = [IO.Path]::GetFullPath($Repo).TrimEnd('\')
  $seen = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
  $paths = [Collections.Generic.List[string]]::new()
  foreach ($pat in @($Patterns)) {
    if ($pat -match '(?i)^[a-z]:\\' -or $pat -match '\.\.') {
      return [pscustomobject]@{ Ok = $false; Paths = @(); Why = ("the declared input '" + $pat + "' is not a path inside this repo") }
    }
    $rel = $pat -replace '/', '\'
    $full = [IO.Path]::Combine($repoFull, $rel)
    $hits = @()
    if ($rel -match '[\*\?]') {
      $dir = [IO.Path]::GetDirectoryName($full)
      $leaf = [IO.Path]::GetFileName($full)
      if ($dir -and [IO.Directory]::Exists($dir)) {
        $hits = @([IO.Directory]::GetFiles($dir, $leaf) | Sort-Object)
      }
    } elseif ([IO.File]::Exists($full)) {
      $hits = @($full)
    }
    if (-not $hits.Count) {
      return [pscustomobject]@{ Ok = $false; Paths = @(); Why = ("the declared input '" + $pat + "' matches no file, so the declaration is stale or misspelt") }
    }
    foreach ($h in $hits) {
      $r = $h.Substring($repoFull.Length).TrimStart('\')
      if (-not $seen.ContainsKey($r)) { $seen[$r] = $true; [void]$paths.Add($r) }
    }
  }
  $sorted = $paths.ToArray()
  [Array]::Sort($sorted, [StringComparer]::OrdinalIgnoreCase)
  return [pscustomobject]@{ Ok = $true; Paths = @($sorted); Why = '' }
}

function Get-TcGateInputKey {
  <# The key for ONE gate. $Repo is the checkout, $GateFile its full path, $GateArg the argument it runs with
     (so `-SelfTest` and a renamed switch are different entries), $RunnerFiles the bytes of whatever dispatches
     it - change the runner and every key changes, which is the conservative direction.

     Returns Ok, Key, Why and Files (what went into it, for the fixture and for a reader). NOT cacheable comes
     back Ok=$false with Why, and the caller must then run the gate. #>
  param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [Parameter(Mandatory = $true)][string]$GateFile,
    [string]$GateArg = '',
    [string[]]$RunnerFiles = @()
  )
  if (-not [IO.File]::Exists($GateFile)) {
    return [pscustomobject]@{ Ok = $false; Key = ''; Why = 'the gate file does not exist'; Files = @() }
  }
  $text = ''
  try { $text = [IO.File]::ReadAllText($GateFile) } catch {
    return [pscustomobject]@{ Ok = $false; Key = ''; Why = 'the gate file could not be read'; Files = @() }
  }
  # A DECLARATION OUTRANKS THE INFERENCE, because the author knows what the gate reads and the regex is guessing.
  # Only the REFUSAL is lifted: every declared path is still hashed below, and the transitive walk still runs.
  $declared = Get-TcGateDeclaredInputs -Text $text
  $declResolved = $null
  # A GATE THAT IS NOT POWERSHELL MUST DECLARE, OR IT IS NOT KEYED (2026-09-12). The inference below reads PowerShell
  # spellings - Join-Path literals, dot-sourced lib\ paths - and a Python suite has neither. Handed a .py, it finds
  # nothing to refuse and nothing to follow, and would key the file on its own bytes alone: an `import hunt_lib` or an
  # open() of a board would be invisible, and a pass would replay after either changed. That is the unsafe direction,
  # so for anything but PowerShell the only road to a key is the author's own list.
  if (-not $declared.Count -and $GateFile -notmatch '(?i)\.psm?1$') {
    return [pscustomobject]@{ Ok = $false; Key = ''; Why = 'is not PowerShell and declares no inputs, and the inference cannot see what it imports or opens'; Files = @() }
  }
  if ($declared.Count) {
    $declResolved = Resolve-TcGateDeclaredInputs -Repo $Repo -Patterns $declared
    if (-not $declResolved.Ok) { return [pscustomobject]@{ Ok = $false; Key = ''; Why = $declResolved.Why; Files = @() } }
  } else {
    $can = Test-TcGateCacheable -Text $text
    if (-not $can.Ok) { return [pscustomobject]@{ Ok = $false; Key = ''; Why = $can.Why; Files = @() } }
  }

  $repoFull = [IO.Path]::GetFullPath($Repo).TrimEnd('\')
  $rows = [Collections.Generic.List[string]]::new()
  $files = [Collections.Generic.List[string]]::new()
  $rows.Add('gate ' + [IO.Path]::GetFileName($GateFile) + ' ' + (Get-TcFileSha256 $GateFile))
  $files.Add($GateFile)
  $rows.Add('arg ' + $GateArg)

  # TRANSITIVE, because a library that dot-sources another is exactly how a change reaches a gate without
  # touching it. The walk is breadth-first over literal lib\ spellings and stops at what it has already seen.
  $queue = [Collections.Generic.Queue[string]]::new()
  $seen = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
  foreach ($m in [regex]::Matches($text, $script:TcGateLibRx)) { $queue.Enqueue($m.Groups[1].Value) }
  $refs = Get-TcGateReferencedPaths -Text $text
  foreach ($p in $refs.Paths) { if ($p -notmatch '(?i)^lib\\') { $queue.Enqueue($p) } }
  # The declared set joins the same queue, so a declared .ps1 is walked into exactly like an inferred one.
  if ($declResolved) { foreach ($p in $declResolved.Paths) { $queue.Enqueue($p) } }
  while ($queue.Count) {
    $rel = $queue.Dequeue()
    if ($seen.ContainsKey($rel)) { continue }
    $seen[$rel] = $true
    $full = [IO.Path]::Combine($repoFull, $rel)
    $rows.Add('ref ' + $rel + ' ' + (Get-TcFileSha256 $full))
    $files.Add($full)
    if ($rel -match '(?i)\.ps1$' -and [IO.File]::Exists($full)) {
      $sub = ''
      try { $sub = [IO.File]::ReadAllText($full) } catch { $sub = '' }
      if ($sub) {
        # A LIBRARY THAT READS DATA POISONS EVERY GATE THAT LOADS IT, so the refusal travels up the graph - UNLESS
        # this gate declared its inputs, in which case the author has already answered the question the inference
        # was asking, and the contagion is the inference's uncertainty rather than a fact about the library.
        # This is what unblocks the 8 gates refused on 2026-09-12 only because something they load was unkeyable.
        # A DECLARING LIBRARY DOES NOT POISON ITS CALLERS EITHER, and that is the half that matters: on
        # 2026-09-12 lib\gate-slots.ps1 alone refused four gates that merely dot-source it. Its own declaration
        # answers the question the inference was guessing at, so the contagion stops there - and the library's
        # declared inputs join this walk, or a caller's key would be blind to what the library reads.
        $subDecl = Get-TcGateDeclaredInputs -Text $sub
        if ($subDecl.Count) {
          $subRes = Resolve-TcGateDeclaredInputs -Repo $Repo -Patterns $subDecl
          if (-not $subRes.Ok) {
            return [pscustomobject]@{ Ok = $false; Key = ''; Why = ('a file it loads (' + $rel + ') ' + $subRes.Why); Files = @() }
          }
          foreach ($p in $subRes.Paths) { $queue.Enqueue($p) }
        } elseif (-not $declResolved) {
          $subCan = Test-TcGateCacheable -Text $sub
          if (-not $subCan.Ok) {
            return [pscustomobject]@{ Ok = $false; Key = ''; Why = ('a file it loads (' + $rel + ') ' + $subCan.Why); Files = @() }
          }
        }
        foreach ($m in [regex]::Matches($sub, $script:TcGateLibRx)) { $queue.Enqueue($m.Groups[1].Value) }
      }
    }
  }
  foreach ($rf in @($RunnerFiles)) {
    if (-not $rf) { continue }
    $rows.Add('runner ' + [IO.Path]::GetFileName($rf) + ' ' + (Get-TcFileSha256 $rf))
    $files.Add($rf)
  }
  # The interpreter is part of the answer: the same bytes on a different PowerShell are a different run.
  $rows.Add('ps ' + $PSVersionTable.PSVersion.ToString())
  $sorted = $rows.ToArray()
  [Array]::Sort($sorted, [StringComparer]::Ordinal)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $key = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($sorted -join "`n")))) -replace '-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
  return [pscustomobject]@{ Ok = $true; Key = $key; Why = ''; Files = @($files) }
}

function Get-TcGateCachedVerdict {
  <# The gate's OWN last line, stored beside the key and replayed when the entry is reused.

     WHY IT IS STORED AT ALL (2026-09-12, found by running it). run-gates scores a self-test that exits 0
     without naming its own verdict as a 3 (lib\selftest-verdict.ps1), so a reused gate that printed a
     invented line scored could-not-evaluate: 182 of them in one run. A reused gate must say what it said
     when it ran, not what the cache thinks of it. Everything after the third field is that line. #>
  param([string]$Line)
  if (-not $Line) { return '' }
  $t = $Line.Trim()
  $parts = $t -split '\s+', 4
  if ($parts.Count -lt 4) { return '' }
  return $parts[3]
}

function Get-TcGateCacheId {
  <# What a cache entry is NAMED by: the gate's path BELOW its checkout, its switch, and its key.

     THE CACHE WAS NEVER SHARED, although the comment on Get-TcGateCachePath said it was (found 2026-09-12). run-gates
     named each entry from the gate's FULL path, so C:\Codex\ThriftyCrew\ops\x.ps1 and
     ...\.claude\worktrees\w1\ops\x.ps1 were two entries. The KEY inside was already path-independent - its rows are a
     file name, a repo-relative path and a SHA - so the answer was right and simply unreachable from any other checkout.
     Measured with the main checkout and a worktree at the SAME commit: 5 of 7 keyable gates had identical keys and
     different cache files, and the directory held 4,551 entries, 18.6 per keyable gate, across 138 worktrees. A push
     from any checkout that had not itself passed that content ran cold: 93 to 373 s of wall that day against 43 to 71 s
     warm.

     THE KEY IS IN THE NAME, not just in the line, so two checkouts at DIFFERENT commits do not overwrite each other's
     entry and evict it on every alternate push. One entry per (gate, content) is shared by every checkout that holds
     that content, which is what the cache was for.

     NOT NORMALISED: the key still hashes raw bytes. The same day, three tracked files read clean in `git status` in both
     checkouts with different bytes on disk (line endings), so gates reading them do not share between those two. That
     is the conservative direction on purpose - several gates here read other files' BYTES, and a key that folded CRLF
     into LF would replay a pass across a difference such a gate would see. #>
  param([string]$Repo, [string]$GateFile, [string]$GateArg, [string]$Key)
  $root = [IO.Path]::GetFullPath($Repo).TrimEnd('\')
  $full = [IO.Path]::GetFullPath(($GateFile -replace '/', '\'))
  $rel = $full
  if ($full.Length -gt $root.Length -and $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
    $rel = $full.Substring($root.Length + 1)
  }
  # A gate outside its own checkout keeps its full path, so it simply does not share - it never collides.
  return ($rel.ToLowerInvariant() + '|' + $GateArg + '|' + $Key)
}

function Remove-TcGateStaleEntries {
  <# Delete cache entries past the age backstop, and nothing else. Returns how many were removed.

     NOTHING PRUNED THIS DIRECTORY BEFORE, and naming entries by their key means one per (gate, content), so it would
     otherwise only grow. It is safe BY THE HIT RULE: Test-TcGateCacheHit refuses an entry whose recorded time is older
     than the backstop, and an entry's recorded time is written in the same write as the file, so a file whose write
     time is past the backstop can never be a hit. Removing it changes no answer any run could get. A delete that races
     another run's is caught and ignored; a reader that loses the race reads a miss and runs the gate. #>
  param([string]$CacheDir, [DateTime]$NowUtc, [int]$MaxAgeHours = $script:TcGateKeyMaxAgeHours)
  if (-not $CacheDir -or -not [IO.Directory]::Exists($CacheDir)) { return 0 }
  $cut = $NowUtc.AddHours(-$MaxAgeHours)
  $removed = 0
  foreach ($p in [IO.Directory]::EnumerateFiles($CacheDir, '*.pass')) {
    try {
      if ([IO.File]::GetLastWriteTimeUtc($p) -lt $cut) { [IO.File]::Delete($p); $removed++ }
    } catch { }
  }
  return $removed
}

function Get-TcGateCachePath {
  <# The file for one cache id under the COMMON git directory. Pass it Get-TcGateCacheId's answer, never a full path:
     a full path is one checkout's name for a gate, and that is exactly how the cache stopped being shared. #>
  param([string]$CacheDir, [string]$GateId)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $h = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($GateId))) -replace '-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
  return (Join-Path $CacheDir ($h.Substring(0, 32) + '.pass'))
}

function Test-TcGateCacheHit {
  <# Pure over the stored LINE, so the fixture drives it without a disk. A hit needs the same key, a recorded
     exit 0, and an age inside the backstop. Anything else is a miss with a reason. #>
  param([string]$Line, [string]$Key, [DateTime]$NowUtc, [int]$MaxAgeHours = $script:TcGateKeyMaxAgeHours)
  if (-not $Line) { return [pscustomobject]@{ Hit = $false; Why = 'no entry' } }
  $p = $Line.Trim() -split '\s+'
  if ($p.Count -lt 3) { return [pscustomobject]@{ Hit = $false; Why = 'entry is not three fields' } }
  if (-not [string]::Equals($p[0], $Key, [StringComparison]::Ordinal)) { return [pscustomobject]@{ Hit = $false; Why = 'the inputs changed' } }
  if ($p[1] -ne '0') { return [pscustomobject]@{ Hit = $false; Why = 'the recorded run did not pass' } }
  $at = [DateTime]::MinValue
  if (-not [DateTime]::TryParse($p[2], [ref]$at)) { return [pscustomobject]@{ Hit = $false; Why = 'unreadable timestamp' } }
  if (($NowUtc - $at.ToUniversalTime()).TotalHours -gt $MaxAgeHours) { return [pscustomobject]@{ Hit = $false; Why = 'older than the backstop' } }
  return [pscustomobject]@{ Hit = $true; Why = '' }
}

if ($__gikSelfTest) {
  $f = 0; $cases = 0
  function T([string]$m, [bool]$c, [string]$got = '') {
    $script:cases++
    if ($c) { Write-Output ('ok    ' + $m) } else { Write-Output ('FAIL  ' + $m + '   got: ' + $got); $script:f++ }
  }
  $sb = Join-Path $env:TEMP ('tc-gik-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  $utf8 = New-Object Text.UTF8Encoding($false)
  try {
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $sb 'lib')
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $sb 'ops')
    $gate = Join-Path $sb 'ops\audit-thing.ps1'
    $lib = Join-Path $sb 'lib\helper.ps1'
    $lib2 = Join-Path $sb 'lib\deeper.ps1'
    $other = Join-Path $sb 'ops\caller.ps1'
    $runner = Join-Path $sb 'ops\run-gates.ps1'
    [IO.File]::WriteAllText($lib2, "# deeper`n", $utf8)
    [IO.File]::WriteAllText($lib, ". (Join-Path `$repo 'lib\deeper.ps1')`n", $utf8)
    [IO.File]::WriteAllText($other, "# the production caller this gate asserts`n", $utf8)
    [IO.File]::WriteAllText($runner, "# the runner`n", $utf8)
    $gateText = @'
. (Join-Path $repo 'lib\helper.ps1')
$caller = Join-Path $repo 'ops\caller.ps1'
if ($SelfTest) { Write-Output 'cases' }
'@
    [IO.File]::WriteAllText($gate, $gateText, $utf8)
    $k1 = Get-TcGateInputKey -Repo $sb -GateFile $gate -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'CLEAN TWIN a gate whose inputs are all named resolves to a key, and names what went into it' `
      ($k1.Ok -and $k1.Key.Length -eq 64 -and @($k1.Files).Count -eq 5) ("ok={0} files={1} why={2}" -f $k1.Ok, @($k1.Files).Count, $k1.Why)
    $k1b = Get-TcGateInputKey -Repo $sb -GateFile $gate -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'CLEAN TWIN the same bytes twice give the same key, or nothing could ever be reused' ($k1.Key -eq $k1b.Key) ("{0} / {1}" -f $k1.Key, $k1b.Key)

    # MUST FIRE - each input, one at a time. These are the cases that make a stale pass impossible.
    [IO.File]::WriteAllText($gate, $gateText + "# edited`n", $utf8)
    $kGate = Get-TcGateInputKey -Repo $sb -GateFile $gate -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  editing the GATE changes its key' ($kGate.Key -ne $k1.Key) 'key survived an edit to the gate'
    [IO.File]::WriteAllText($gate, $gateText, $utf8)
    [IO.File]::WriteAllText($lib, ". (Join-Path `$repo 'lib\deeper.ps1')`n# edited`n", $utf8)
    $kLib = Get-TcGateInputKey -Repo $sb -GateFile $gate -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  editing a LIBRARY it dot-sources changes its key' ($kLib.Key -ne $k1.Key) 'key survived an edit to a library'
    [IO.File]::WriteAllText($lib2, "# deeper edited`n", $utf8)
    $kDeep = Get-TcGateInputKey -Repo $sb -GateFile $gate -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  editing a library TWO hops away changes its key - the walk is transitive, which is how a change reaches a gate that never named it' `
      ($kDeep.Key -ne $kLib.Key) 'key survived an edit two hops down'
    [IO.File]::WriteAllText($other, "# caller edited`n", $utf8)
    $kOther = Get-TcGateInputKey -Repo $sb -GateFile $gate -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  editing a repo file the gate NAMES changes its key' ($kOther.Key -ne $kDeep.Key) 'key survived an edit to a named file'
    [IO.File]::WriteAllText($runner, "# runner edited`n", $utf8)
    $kRun = Get-TcGateInputKey -Repo $sb -GateFile $gate -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  editing the RUNNER changes every key - the dispatcher is part of what a pass means' ($kRun.Key -ne $kOther.Key) 'key survived an edit to the runner'
    $kArg = Get-TcGateInputKey -Repo $sb -GateFile $gate -GateArg '-OtherSwitch' -RunnerFiles @($runner)
    T 'MUST FIRE  the same file run with a different switch is a different gate' ($kArg.Key -ne $kRun.Key) 'the argument did not reach the key'

    # MUST NOT FIRE - a file it never reads must NOT change the key, or nothing is ever reused.
    [IO.File]::WriteAllText((Join-Path $sb 'ops\unrelated.ps1'), "# nothing to do with the gate`n", $utf8)
    $kUnrel = Get-TcGateInputKey -Repo $sb -GateFile $gate -GateArg '-OtherSwitch' -RunnerFiles @($runner)
    T 'MUST NOT FIRE  a file the gate never names does not change its key, which is the whole point of caching per gate' `
      ($kUnrel.Key -eq $kArg.Key) 'an unrelated file moved the key'

    # ---- A GATE MAY DECLARE ITS INPUTS (Brad, 2026-09-12) ----
    # The declaration exists for gates the inference cannot key, so every case here starts from a gate the
    # inference REFUSES and asks what the declaration does to it.
    $decl = Join-Path $sb 'ops\test-hooky.ps1'
    $declBody = "`$p = Join-Path `$repo `$whatever   # the inference cannot follow this`nif (`$SelfTest) { }`n"
    [IO.File]::WriteAllText($decl, $declBody, $utf8)
    $kNoDecl = Get-TcGateInputKey -Repo $sb -GateFile $decl -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  without a declaration the inference still refuses a variable-built path, so nothing is weakened by default' `
      ((-not $kNoDecl.Ok) -and $kNoDecl.Why -match 'variable') ("ok={0} why={1}" -f $kNoDecl.Ok, $kNoDecl.Why)
    [IO.File]::WriteAllText($decl, ("# gate-inputs: lib\*.ps1, ops\unrelated.ps1`n" + $declBody), $utf8)
    $kDecl = Get-TcGateInputKey -Repo $sb -GateFile $decl -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  a gate that DECLARES what it reads is keyable although the inference refused it' `
      ($kDecl.Ok) ("ok={0} why={1}" -f $kDecl.Ok, $kDecl.Why)
    # THE DECLARED FILES ARE HASHED, not merely listed - the point is that a change to one still moves the key.
    [IO.File]::WriteAllText((Join-Path $sb 'ops\unrelated.ps1'), "# edited after the declaration`n", $utf8)
    $kDeclEdit = Get-TcGateInputKey -Repo $sb -GateFile $decl -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  editing a DECLARED file moves the key, so a declaration shortens nothing' `
      ($kDeclEdit.Ok -and $kDeclEdit.Key -ne $kDecl.Key) 'a declared file was not in the key'
    # A GLOB MEANS THE DIRECTORY, which is the only form that can cover ops\test-prepush-hook.ps1 - it copies
    # lib\*.ps1 by enumeration, so a NEW library must move its key without anyone editing the declaration.
    [IO.File]::WriteAllText((Join-Path $sb 'lib\brand-new.ps1'), "# a library that did not exist a moment ago`n", $utf8)
    $kDeclNew = Get-TcGateInputKey -Repo $sb -GateFile $decl -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  a NEW file appearing under a declared glob moves the key, which a hand list could never do' `
      ($kDeclNew.Ok -and $kDeclNew.Key -ne $kDeclEdit.Key) 'a new file under the declared glob did not reach the key'
    # THE SAFETY PROPERTY. A declaration that matches nothing is the one way this could narrow an input set in
    # silence, and silence here is a STALE PASS - so it refuses instead.
    [IO.File]::WriteAllText($decl, ("# gate-inputs: lib\typo-*.ps1`n" + $declBody), $utf8)
    $kStale = Get-TcGateInputKey -Repo $sb -GateFile $decl -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  a declared pattern matching NO file is refused, never read as an empty input set' `
      ((-not $kStale.Ok) -and $kStale.Why -match 'matches no file') ("ok={0} why={1}" -f $kStale.Ok, $kStale.Why)
    [IO.File]::WriteAllText($decl, ("# gate-inputs: ..\outside.ps1`n" + $declBody), $utf8)
    $kEsc = Get-TcGateInputKey -Repo $sb -GateFile $decl -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  a declaration cannot name a path outside this repo' `
      ((-not $kEsc.Ok) -and $kEsc.Why -match 'inside this repo') ("ok={0} why={1}" -f $kEsc.Ok, $kEsc.Why)
    $declPure = Get-TcGateDeclaredInputs -Text "# gate-inputs: a.ps1 , b.ps1`n# gate-inputs: c.ps1`n"
    T 'CLEAN TWIN  the declaration parser splits on commas, trims, and reads more than one declaration line' `
      ($declPure.Count -eq 3 -and $declPure[0] -eq 'a.ps1' -and $declPure[2] -eq 'c.ps1') ($declPure -join '|')
    T 'MUST NOT FIRE  a gate with no declaration line declares nothing, rather than declaring everything' `
      ((Get-TcGateDeclaredInputs -Text "# just a comment`n").Count -eq 0) 'a gate without a declaration was read as declaring something'
    # THE CONTAGION STOPS AT A DECLARATION. An undeclared gate that loads an unkeyable library is refused, and
    # must stay refused; the same gate loading a library that DECLARES is keyable, because the library has
    # answered the question the inference could not. On 2026-09-12 one library refused four gates this way.
    $poisonLib = Join-Path $sb 'lib\poisons.ps1'
    [IO.File]::WriteAllText($poisonLib, "`$q = Join-Path `$repo `$whatever`n", $utf8)
    $caller = Join-Path $sb 'ops\loads-poison.ps1'
    [IO.File]::WriteAllText($caller, ". (Join-Path `$repo 'lib\poisons.ps1')`nif (`$SelfTest) { }`n", $utf8)
    $kPoisoned = Get-TcGateInputKey -Repo $sb -GateFile $caller -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  a gate that loads an UNKEYABLE library is still refused, so the contagion rule is not lost' `
      ((-not $kPoisoned.Ok) -and $kPoisoned.Why -match 'a file it loads') ("ok={0} why={1}" -f $kPoisoned.Ok, $kPoisoned.Why)
    [IO.File]::WriteAllText($poisonLib, ("# gate-inputs: lib\poisons.ps1`n`$q = Join-Path `$repo `$whatever`n"), $utf8)
    $kCured = Get-TcGateInputKey -Repo $sb -GateFile $caller -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  the same gate is keyable once the library it loads DECLARES, so one file stops refusing its callers' `
      ($kCured.Ok) ("ok={0} why={1}" -f $kCured.Ok, $kCured.Why)
    [IO.File]::WriteAllText($poisonLib, ("# gate-inputs: lib\never-existed-*.ps1`n`$q = Join-Path `$repo `$whatever`n"), $utf8)
    $kBadSub = Get-TcGateInputKey -Repo $sb -GateFile $caller -GateArg '-SelfTest' -RunnerFiles @($runner)
    T 'MUST FIRE  a STALE declaration in a loaded library refuses its callers too, rather than quietly keying them' `
      ((-not $kBadSub.Ok) -and $kBadSub.Why -match 'matches no file') ("ok={0} why={1}" -f $kBadSub.Ok, $kBadSub.Why)

    # MUST FIRE - the refusals. A gate we cannot key must never be cached.
    $dataGate = Join-Path $sb 'ops\audit-data.ps1'
    # reach-fixture-ok: the fixture GATE's source, written into a temp sandbox - it is the input this refusal
    # exists to detect, so the case cannot be written without naming the shape it refuses.
    [IO.File]::WriteAllText($dataGate, "`$b = Join-Path `$repo 'grocery\out\comparison-2026-01-01.json'`nif (`$SelfTest) { }`n", $utf8)   # reach-fixture-ok: the shape this rule REFUSES, named in a pattern or written into a temp sandbox; nothing here opens a real data file
    $kData = Get-TcGateInputKey -Repo $sb -GateFile $dataGate -GateArg '-SelfTest'
    T 'MUST FIRE  a gate that reads a DATA directory is refused, because those bytes change with no commit' `
      ((-not $kData.Ok) -and $kData.Why -match 'data directory') ("ok={0} why={1}" -f $kData.Ok, $kData.Why)
    $compGate = Join-Path $sb 'ops\audit-computed.ps1'
    [IO.File]::WriteAllText($compGate, "`$p = Join-Path `$repo `$someVar`nif (`$SelfTest) { }`n", $utf8)
    $kComp = Get-TcGateInputKey -Repo $sb -GateFile $compGate -GateArg '-SelfTest'
    T 'MUST FIRE  a gate that builds a repo path from a VARIABLE is refused - a key cannot watch what it cannot name' `
      ((-not $kComp.Ok) -and $kComp.Why -match 'variable') ("ok={0} why={1}" -f $kComp.Ok, $kComp.Why)
    # MUST FIRE - and the refusal travels UP: a clean-looking gate that loads a data-reading library is refused too.
    $poison = Join-Path $sb 'lib\reads-data.ps1'
    # reach-fixture-ok: the fixture LIBRARY's source, in a temp sandbox - the case exists to prove a data read
    # one hop down still refuses the gate above it, and it cannot be written without naming that shape.
    [IO.File]::WriteAllText($poison, "`$x = Join-Path `$repo 'meal-prep\db\costed.json'`n", $utf8)   # reach-fixture-ok: the shape this rule REFUSES, named in a pattern or written into a temp sandbox; nothing here opens a real data file
    $viaLib = Join-Path $sb 'ops\audit-vialib.ps1'
    [IO.File]::WriteAllText($viaLib, ". (Join-Path `$repo 'lib\reads-data.ps1')`nif (`$SelfTest) { }`n", $utf8)
    $kVia = Get-TcGateInputKey -Repo $sb -GateFile $viaLib -GateArg '-SelfTest'
    T 'MUST FIRE  a gate is refused when a LIBRARY it loads reads data - the refusal travels up the graph, or the key would vouch for bytes nobody watched' `
      ((-not $kVia.Ok) -and $kVia.Why -match 'a file it loads') ("ok={0} why={1}" -f $kVia.Ok, $kVia.Why)
    $kMissing = Get-TcGateInputKey -Repo $sb -GateFile (Join-Path $sb 'ops\not-here.ps1') -GateArg ''
    T 'MUST FIRE  a gate file that is not there is refused, never keyed as absent' `
      ((-not $kMissing.Ok) -and $kMissing.Why -match 'does not exist') $kMissing.Why

    # ---- the stored entry ----
    $now = [DateTime]::UtcNow
    T 'CLEAN TWIN a stored pass over the same key, inside the backstop, is a hit' `
      ((Test-TcGateCacheHit -Line ($k1.Key + ' 0 ' + $now.AddMinutes(-5).ToString('o')) -Key $k1.Key -NowUtc $now).Hit) 'a fresh identical pass missed'
    T 'MUST FIRE  a stored entry for DIFFERENT inputs is a miss, and says so' `
      (-not (Test-TcGateCacheHit -Line ('deadbeef 0 ' + $now.ToString('o')) -Key $k1.Key -NowUtc $now).Hit) 'a different key was reused'
    T 'MUST FIRE  a recorded FAILURE is never reused - a red gate runs again every time' `
      (-not (Test-TcGateCacheHit -Line ($k1.Key + ' 1 ' + $now.ToString('o')) -Key $k1.Key -NowUtc $now).Hit) 'a red result was reused'
    T 'MUST FIRE  an entry older than the backstop is a miss' `
      (-not (Test-TcGateCacheHit -Line ($k1.Key + ' 0 ' + $now.AddHours(-1000).ToString('o')) -Key $k1.Key -NowUtc $now).Hit) 'an ancient entry was reused'
    T 'MUST FIRE  a truncated entry is a miss, never a pass' `
      (-not (Test-TcGateCacheHit -Line ($k1.Key + ' 0') -Key $k1.Key -NowUtc $now).Hit) 'a half-written entry was reused'
    T 'MUST NOT FIRE  no entry at all is simply a miss with a reason' `
      ((-not (Test-TcGateCacheHit -Line '' -Key $k1.Key -NowUtc $now).Hit) -and (Test-TcGateCacheHit -Line '' -Key $k1.Key -NowUtc $now).Why -eq 'no entry') 'an empty entry did not say why'
    # THE VERDICT TRAVELS WITH THE ENTRY. run-gates scores a self-test that exits 0 without naming its own
    # verdict as a 3, so an entry that cannot replay the gate's last line is not a usable answer - measured
    # the first time this ran, when 182 reused gates all scored could-not-evaluate.
    $stored = $k1.Key + ' 0 ' + $now.ToString('o') + ' SELF-TEST PASS: 14 cases - the founding bug and its twin'
    T 'CLEAN TWIN the gate''s own last line comes back with the entry, whitespace and all' `
      ((Get-TcGateCachedVerdict -Line $stored) -eq 'SELF-TEST PASS: 14 cases - the founding bug and its twin') (Get-TcGateCachedVerdict -Line $stored)
    T 'MUST FIRE  an entry with no verdict line yields nothing, so the caller runs the gate rather than replaying silence' `
      ((Get-TcGateCachedVerdict -Line ($k1.Key + ' 0 ' + $now.ToString('o'))) -eq '') 'invented a verdict from an entry that had none'
    # ---- A NON-POWERSHELL GATE KEYS ONLY ON WHAT IT DECLARES (2026-09-12) ----
    $pyGate = Join-Path $sb 'ops\suite_thing.py'
    $pyHelper = Join-Path $sb 'ops\helper_lib.py'
    [IO.File]::WriteAllText($pyHelper, "VALUE = 1`n", $utf8)
    [IO.File]::WriteAllText($pyGate, "import helper_lib`nif '--selftest' in __import__('sys').argv: pass`n", $utf8)
    $kPyBare = Get-TcGateInputKey -Repo $sb -GateFile $pyGate -GateArg '--selftest' -RunnerFiles @($runner)
    T 'MUST FIRE  a Python suite with no declaration is refused, because the inference cannot see an import' `
      ((-not $kPyBare.Ok) -and $kPyBare.Why -match 'not PowerShell') ("ok={0} why={1}" -f $kPyBare.Ok, $kPyBare.Why)
    [IO.File]::WriteAllText($pyGate, "# gate-inputs: ops\helper_lib.py`nimport helper_lib`nif '--selftest' in __import__('sys').argv: pass`n", $utf8)
    $kPyDecl = Get-TcGateInputKey -Repo $sb -GateFile $pyGate -GateArg '--selftest' -RunnerFiles @($runner)
    T 'CLEAN TWIN  the same Python suite is keyable once it declares what it imports' ($kPyDecl.Ok) ("ok={0} why={1}" -f $kPyDecl.Ok, $kPyDecl.Why)
    [IO.File]::WriteAllText($pyHelper, "VALUE = 2`n", $utf8)
    $kPyEdit = Get-TcGateInputKey -Repo $sb -GateFile $pyGate -GateArg '--selftest' -RunnerFiles @($runner)
    T 'MUST FIRE  editing the module a Python suite imports moves its key, so an import is never a stale pass' `
      ($kPyEdit.Ok -and $kPyEdit.Key -ne $kPyDecl.Key) 'editing an imported module left the key unchanged'

    # ---- ONE ENTRY PER GATE AND CONTENT, SHARED BY EVERY CHECKOUT (2026-09-12) ----
    # The founding defect, end to end rather than through the id function alone: two byte-identical checkouts at two
    # different paths. Before the fix they computed the same key and wrote two different cache files.
    $twinGate = Join-Path $sb 'ops\audit-twin.ps1'
    [IO.File]::WriteAllText($twinGate, "# a gate with nothing to read`nif (`$SelfTest) { }`n", $utf8)
    $sb2 = $sb + '-twin'
    Copy-Item -LiteralPath $sb -Destination $sb2 -Recurse -Force
    try {
      $twinGate2 = Join-Path $sb2 'ops\audit-twin.ps1'
      $kTwinA = Get-TcGateInputKey -Repo $sb -GateFile $twinGate -GateArg '-SelfTest' -RunnerFiles @($runner)
      $kTwinB = Get-TcGateInputKey -Repo $sb2 -GateFile $twinGate2 -GateArg '-SelfTest' -RunnerFiles @((Join-Path $sb2 'ops\run-gates.ps1'))
      $cA = Get-TcGateCachePath -CacheDir 'C:\c' -GateId (Get-TcGateCacheId -Repo $sb -GateFile $twinGate -GateArg '-SelfTest' -Key $kTwinA.Key)
      $cB = Get-TcGateCachePath -CacheDir 'C:\c' -GateId (Get-TcGateCacheId -Repo $sb2 -GateFile $twinGate2 -GateArg '-SelfTest' -Key $kTwinB.Key)
      T 'MUST FIRE  byte-identical checkouts at two different paths compute one key AND land on one cache file' `
        ($kTwinA.Ok -and $kTwinB.Ok -and $kTwinA.Key -eq $kTwinB.Key -and $cA -eq $cB) ("okA={0} okB={1} sameKey={2} sameFile={3}" -f $kTwinA.Ok, $kTwinB.Ok, ($kTwinA.Key -eq $kTwinB.Key), ($cA -eq $cB))
    } finally {
      Remove-Item -LiteralPath $sb2 -Recurse -Force -ErrorAction SilentlyContinue
    }
    $idA = Get-TcGateCacheId -Repo 'C:\box\main' -GateFile 'C:\box\main\ops\audit-thing.ps1' -GateArg '-SelfTest' -Key 'k1'
    $idC = Get-TcGateCacheId -Repo 'C:\box\main' -GateFile 'C:\box\main\ops\audit-thing.ps1' -GateArg '-SelfTest' -Key 'k2'
    T 'MUST FIRE  different inputs are a different entry, so checkouts at two commits never evict each other' ($idA -ne $idC) "$idA / $idC"
    $idD = Get-TcGateCacheId -Repo 'C:\Box\Main' -GateFile 'c:\box\main\OPS/audit-thing.ps1' -GateArg '-SelfTest' -Key 'k1'
    T 'MUST NOT FIRE  case and separator spelling do not split one gate into two entries' ($idA -eq $idD) "$idA / $idD"

    # ---- PRUNING, which is only safe because it agrees with the hit rule ----
    $pc = Join-Path $sb 'cache'
    $null = New-Item -ItemType Directory -Force -Path $pc
    $oldE = Join-Path $pc 'old.pass'; $freshE = Join-Path $pc 'fresh.pass'; $notMine = Join-Path $pc 'readme.txt'
    foreach ($x in @($oldE, $freshE, $notMine)) { [IO.File]::WriteAllText($x, 'x', $utf8) }
    $nowP = [DateTime]::UtcNow
    $pastBackstop = $nowP.AddHours(-($script:TcGateKeyMaxAgeHours + 1))
    [IO.File]::SetLastWriteTimeUtc($oldE, $pastBackstop)
    [IO.File]::SetLastWriteTimeUtc($notMine, $pastBackstop)
    $gone = Remove-TcGateStaleEntries -CacheDir $pc -NowUtc $nowP
    T 'MUST FIRE  an entry past the backstop is removed, because it can never be a hit again' `
      ((-not (Test-Path -LiteralPath $oldE)) -and $gone -eq 1) ("removed={0} oldStillThere={1}" -f $gone, (Test-Path -LiteralPath $oldE))
    T 'CLEAN TWIN  an entry inside the backstop is still there to be reused' (Test-Path -LiteralPath $freshE) 'a fresh entry was pruned'
    T 'CLEAN TWIN  a file that is not a cache entry is kept, however old it is' (Test-Path -LiteralPath $notMine) 'pruning removed a file it does not own'
    $staleLine = 'kX 0 ' + $pastBackstop.ToString('o') + ' SELF-TEST PASS: x'
    T 'MUST NOT FIRE  an entry old enough to prune is one the hit rule already refuses, so pruning changes no answer' `
      (-not (Test-TcGateCacheHit -Line $staleLine -Key 'kX' -NowUtc $nowP).Hit) 'an entry past the backstop still read as a hit'

    $p1 = Get-TcGateCachePath -CacheDir 'C:\c' -GateId 'ops\a.ps1|-SelfTest'
    $p2 = Get-TcGateCachePath -CacheDir 'C:\c' -GateId 'ops\a.ps1|-Other'
    T 'MUST FIRE  two arguments of one file are two cache entries, never one' ($p1 -ne $p2) "$p1 / $p2"
  } catch {
    $script:f++
    Write-Output ('FAIL  the self-test threw: ' + $_.Exception.Message)
  } finally {
    Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue
  }
  # A SUITE CAN RUN ZERO CASES AND EXIT 0, so the count is asserted.
  if ($cases -lt 43) { $f++; Write-Output ("FAIL  only {0} of 43 cases ran" -f $cases) }
  if ($f) { Write-Output ("gate-input-key SELF-TEST FAIL: {0} of {1} case(s)" -f $f, $cases); exit 1 }
  Write-Output ("gate-input-key SELF-TEST PASS: {0} cases - led by every input moving the key one at a time, including two hops down a library graph, and by the three refusals that keep a stale pass impossible" -f $cases)
  exit 0
}
