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
$script:TcGateDataRx = '(?i)(grocery\\out|meal-prep\\db|meal-prep\\out|graph\\(gold|learning|out)|public\\|content\\|site\\|run\\waves|\.git\\)'   # reach-fixture-ok: the shape this rule REFUSES, named in a pattern or written into a temp sandbox; nothing here opens a real data file
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

function Test-TcGateCacheable {
  <# Pure over TEXT. Why is returned even on success, so a run can print WHY a gate was refused rather than
     leaving a reader to guess which of the two rules bit. #>
  param([string]$Text)
  if ([regex]::IsMatch($Text, $script:TcGateDataRx)) {
    return [pscustomobject]@{ Ok = $false; Why = 'reads a data directory, whose bytes change with no commit' }
  }
  if ([regex]::IsMatch($Text, $script:TcGateComputedRx)) {
    return [pscustomobject]@{ Ok = $false; Why = 'builds a repo path from a variable, which a source key cannot watch' }
  }
  return [pscustomobject]@{ Ok = $true; Why = '' }
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
  $can = Test-TcGateCacheable -Text $text
  if (-not $can.Ok) { return [pscustomobject]@{ Ok = $false; Key = ''; Why = $can.Why; Files = @() } }

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
        # A LIBRARY THAT READS DATA POISONS EVERY GATE THAT LOADS IT, so the refusal travels up the graph.
        $subCan = Test-TcGateCacheable -Text $sub
        if (-not $subCan.Ok) {
          return [pscustomobject]@{ Ok = $false; Key = ''; Why = ('a file it loads (' + $rel + ') ' + $subCan.Why); Files = @() }
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

function Get-TcGateCachePath {
  <# One file per gate under the COMMON git directory, so every worktree on this box shares the answers: the
     same bytes are the same bytes wherever they are checked out. #>
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
  if ($cases -lt 19) { $f++; Write-Output ("FAIL  only {0} of 19 cases ran" -f $cases) }
  if ($f) { Write-Output ("gate-input-key SELF-TEST FAIL: {0} of {1} case(s)" -f $f, $cases); exit 1 }
  Write-Output ("gate-input-key SELF-TEST PASS: {0} cases - led by every input moving the key one at a time, including two hops down a library graph, and by the three refusals that keep a stale pass impossible" -f $cases)
  exit 0
}
