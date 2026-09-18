<#
  report-safety-liveness.ps1 - how many of this estate's detectors can fire when NOTHING HAPPENS.

  Backlog I129. Two shapes of correctness requirement: SAFETY (something bad never happens) and
  LIVENESS (something good eventually happens). A detector that cannot fire on nothing happening is a
  safety check, however it is worded. `.claude\rules\ops-and-gates.md` (I80) says every threshold here
  is an upper bound; this report is that sentence turned into a count with its denominator.

  THE TEST, stated once so the verdicts can be checked: FREEZE EVERY INPUT AND ADVANCE THE CLOCK. If
  the detector's verdict can move from clean to a finding, a warning or a non-zero exit, it is
  LIVENESS. If advancing the clock can only drop records out of a window (fewer findings, never more),
  or the clock only stamps a report, it is SAFETY. A check that compares the ages of TWO artefacts
  against each other is SAFETY under this test: with both frozen it never moves, so it cannot see the
  whole estate stop, only one producer fall behind another.

  HOW IT DECIDES. Mechanically it can only find the files that READ THE CLOCK (Get-Date,
  [DateTime]::Now, time.time(), date.today() and kin), minus lines that only write a report stamp
  (`generated = (Get-Date -Format ...)`), plus the files that CALL a function in `lib\*.ps1` or a
  `*-lib.ps1` whose own body reads the clock. A file that never reaches the clock by either road cannot
  pass the test above, so it is SAFETY by construction. Every other file is a CANDIDATE and needs a hand verdict in
  `ops\safety-liveness-register.json`, keyed on file, with a reason and a signature of its clock-reading
  lines: when those lines change the verdict reads STALE and the file is counted UNRULED until somebody
  re-reads it. An unruled candidate is never folded into either bucket.

  LIVENESS is graded on the file alone. EXIT: the finding can turn the detector's own exit non-zero.
  PRINT: it prints a warning or a listing and the exit cannot move. Whether a CALLER treats a non-zero
  exit as blocking is the caller's business and is not read here.

  SCOPE OF A CLEAN REPORT: UNSOUND in one named direction. The library road is followed ONE level, for
  PowerShell only: a clock reached through a library function that calls another function, a Python
  import, or a spawned child is not seen, and that file is counted SAFETY here when it may not be; so a
  LIVENESS count here is a floor, never a ceiling. The hand verdicts are exactly as good as the reading
  behind them. The population is the named families below and nothing else: gates in `run-gates` are
  self-tests over frozen fixtures and are SAFETY by construction, and alert conditions that are not a
  detector file are not counted.

  Usage:  powershell -NoProfile -File ops\report-safety-liveness.ps1 [-OutFile <path>] [-List]
  It writes -OutFile if given and nothing else. By hand; nothing schedules it.
  EXIT: 0 a report was produced, 3 the population resolved empty (could not look).
#>
[CmdletBinding()]
param([switch]$SelfTest, [string]$OutFile = '', [switch]$List, [string]$Register = '')

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
if (-not $Register) { $Register = Join-Path $here 'safety-liveness-register.json' }

# The detector families. A path is in the population when it matches one of these and is not archived
# and not a library. Order is the order families print in.
$script:FAMILIES = [ordered]@{
  'ops/audit-*.ps1'           = '^ops/audit-[^/]+\.ps1$'
  'ops/audit_*.py'            = '^ops/audit_[^/]+\.py$'
  'grocery/audit-*.ps1'       = '^grocery/audit-[^/]+\.ps1$'
  'meal-prep/**/audit*'       = '^meal-prep/(?:[^/]+/)*audit[-_][^/]+\.(?:ps1|py)$'
  'graph/**/audit_*.py'       = '^graph/(?:[^/]+/)*audit_[^/]+\.py$'
}

function Get-DetectorFamily([string]$Path) {
  $p = $Path.Replace('\', '/')
  if ($p -match '(^|/)archive/') { return $null }
  if ($p -match '-lib\.ps1$') { return $null }
  foreach ($k in $script:FAMILIES.Keys) { if ($p -match $script:FAMILIES[$k]) { return $k } }
  return $null
}

# A clock read. PowerShell and Python spellings; comments are stripped before this is applied.
$script:CLOCK_RX = 'Get-Date(?![\w-])|\[(?:System\.)?DateTime(?:Offset)?\]::(?:Utc)?(?:Now|Today)|time\.time\(\)|datetime\.(?:utc)?now\(|datetime\.today\(|date\.today\('
# A line that only stamps a report: the clock read feeds a stamp key and nothing else on the line reads it.
$script:STAMP_RX = '(?:\b(?:generated|updated|recorded|written|reviewed|accepted|captured_at|timestamp|set|at|date)\b[''"]?\]?\s*[=:]\s*\(?\s*(?:Get-Date\s+-Format|\(Get-Date\)\.ToString\(|date\.today\(\)\.isoformat\(\)|(?:datetime\.)?datetime\.(?:utc)?now\(\)\.(?:isoformat|strftime)\())'

function Get-ClockReadLines([string]$Text, [string]$Ext) {
  $out = New-Object System.Collections.Generic.List[string]
  $inBlock = $false
  foreach ($raw in ($Text -split "`r?`n")) {
    $line = $raw.Trim()
    if ($Ext -eq '.ps1') {
      if ($inBlock) { if ($line -match '#>') { $inBlock = $false }; continue }
      if ($line.StartsWith('<#')) { if ($line -notmatch '#>') { $inBlock = $true }; continue }
    }
    if ($line.StartsWith('#')) { continue }
    if ($line -notmatch $script:CLOCK_RX) { continue }
    $stamps = ([regex]::Matches($line, $script:STAMP_RX, 'IgnoreCase')).Count
    $reads = ([regex]::Matches($line, $script:CLOCK_RX, 'IgnoreCase')).Count
    if ($stamps -ge $reads) { continue }
    $out.Add($line)
  }
  return ,$out.ToArray()
}

function Get-ClockSignature([string[]]$Lines) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $b = [Text.Encoding]::UTF8.GetBytes((@($Lines) -join "`n"))
    return (-join ($sha.ComputeHash($b) | ForEach-Object { $_.ToString('x2') })).Substring(0, 16)
  } finally { $sha.Dispose() }
}

# Library functions that read the clock themselves. $Libs is a list of @{ path; text }. One level only:
# a library function that reaches the clock through ANOTHER function is not found (the unsound direction
# the header names). Found on the first live run: graph-gates' freshness gate reads the clock only inside
# lib\input-assert.ps1's Test-TcInput, and ghost-drift's stale-page line only inside Test-LivePageStale.
function Get-ClockLibFunctions($Libs) {
  $fns = @{}
  foreach ($lib in @($Libs)) {
    $ast = [Management.Automation.Language.Parser]::ParseInput([string]$lib.text, [ref]$null, [ref]$null)
    foreach ($fd in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
      $ls = Get-ClockReadLines $fd.Extent.Text '.ps1'
      if (@($ls).Count -gt 0) { $fns[$fd.Name] = [string]$lib.path }
    }
  }
  return $fns
}

# Evidence lines for the calls a detector makes to those functions, sorted so the signature is stable.
function Get-LibClockCalls([string]$Text, $Fns) {
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($name in ($Fns.Keys | Sort-Object)) {
    if ($Text -match ('(?<![\w-])' + [regex]::Escape($name) + '(?![\w-])')) { $out.Add(('calls {0} ({1})' -f $name, $Fns[$name])) }
  }
  return ,$out.ToArray()
}

# One row per detector. $ClockLines is the evidence: direct clock reads plus library calls. $Verdicts is a
# hashtable file -> register entry.
function Get-Classification([string]$File, [string]$Family, [string[]]$ClockLines, $Verdicts) {
  $sig = Get-ClockSignature $ClockLines
  $row = [ordered]@{ file = $File; family = $Family; clock_lines = @($ClockLines).Count; sig = $sig; evidence = @($ClockLines)
                     bucket = ''; grade = ''; reason = '' }
  if (@($ClockLines).Count -eq 0) { $row.bucket = 'SAFETY'; $row.reason = 'reads no clock, directly or through a library function'; return [pscustomobject]$row }
  if (-not $Verdicts.ContainsKey($File)) { $row.bucket = 'UNRULED'; $row.reason = 'clock-reading candidate with no hand verdict'; return [pscustomobject]$row }
  $v = $Verdicts[$File]
  if ([string]$v.sig -ne $sig) { $row.bucket = 'UNRULED'; $row.reason = ('STALE verdict: clock lines changed since it was ruled (was {0})' -f $v.sig); return [pscustomobject]$row }
  $okVerdict = ([string]$v.verdict -eq 'SAFETY') -or ([string]$v.verdict -eq 'LIVENESS' -and @('EXIT', 'PRINT') -contains [string]$v.grade)
  if (-not $okVerdict -or -not [string]$v.reason) { $row.bucket = 'UNRULED'; $row.reason = ('MALFORMED verdict: {0}/{1}; needs SAFETY, or LIVENESS with grade EXIT or PRINT, and a reason' -f $v.verdict, $v.grade); return [pscustomobject]$row }
  $row.bucket = [string]$v.verdict; $row.grade = [string]$v.grade; $row.reason = [string]$v.reason
  return [pscustomobject]$row
}

function Format-Rate([int]$a, [int]$b) { if ($b -eq 0) { 'n/a (0 of 0)' } else { '{0} of {1} ({2:N1}%)' -f $a, $b, (100.0 * $a / $b) } }

if ($SelfTest) {
  $ran = New-Object System.Collections.Generic.List[string]
  $fails = New-Object System.Collections.Generic.List[string]
  function Case([string]$Label, [string]$Name, [bool]$Ok, [string]$Detail = '') {
    [void]$ran.Add($Name)
    if (-not $Ok) { [void]$fails.Add("$Label $Name") }
    Write-Output ("  {0,-14} {1,-70} {2}" -f $Label, $Name, $(if ($Ok) { 'ok' } else { "FAIL $Detail" }))
  }
  try {
    # Needles are built by concatenation so this file's own source is never a fixture for itself.
    $gd = 'Get-' + 'Date'
    $ageLine = 'if (((' + $gd + ') - $f.LastWriteTime).TotalHours -gt 26) { $findings += ''stale'' }'
    $stampLine = '$report = [ordered]@{ generated = (' + $gd + ' -Format ''yyyy-MM-dd HH:mm''); n = 3 }'
    $commentLine = '# ((' + $gd + ') - $x) is how a stale file would be found'
    $logicToday = '$todayS = if ($Today) { $Today } else { (' + $gd + ').ToString(''yyyy-MM-dd'') }'
    $pyAge = 'if time.' + 'time() - os.stat(p).st_mtime > 86400: fail("stale")'
    $pyStamp = '    "generated": datetime.' + 'now().isoformat(),'

    $r = Get-ClockReadLines $ageLine '.ps1'
    Case 'MUST FIRE' 'an age compared against a limit is a clock read' (@($r).Count -eq 1) ("got " + @($r).Count)
    $r = Get-ClockReadLines $pyAge '.py'
    Case 'MUST FIRE' 'a Python time.time() age is a clock read' (@($r).Count -eq 1) ("got " + @($r).Count)
    $r = Get-ClockReadLines $logicToday '.ps1'
    Case 'MUST FIRE' 'a formatted today used for LOGIC is still a clock read' (@($r).Count -eq 1) ("got " + @($r).Count)
    # 2026-09-18, the first live run: [regex]::Matches is case-SENSITIVE where -match is not, so this
    # spelling passed the line filter, counted zero reads, and a known liveness check read SAFETY.
    $lowerToday = '$today = [date' + 'time]::Today'
    $r = Get-ClockReadLines $lowerToday '.ps1'
    Case 'MUST FIRE' 'a lower-case [datetime]::Today is a clock read' (@($r).Count -eq 1) ("got " + @($r).Count)
    $mixed = $stampLine + ' ; ' + $ageLine
    $r = Get-ClockReadLines $mixed '.ps1'
    Case 'MUST FIRE' 'a stamp sharing a line with a real read keeps the line' (@($r).Count -eq 1) ("got " + @($r).Count)
    $r = Get-ClockReadLines $stampLine '.ps1'
    Case 'MUST NOT FIRE' 'a report stamp alone is not a clock read' (@($r).Count -eq 0) ("got " + @($r).Count)
    $r = Get-ClockReadLines $pyStamp '.py'
    Case 'MUST NOT FIRE' 'a Python generated stamp alone is not a clock read' (@($r).Count -eq 0) ("got " + @($r).Count)
    $upd = '  updated = (' + $gd + ').ToString(''s''); board = $cmpFile.Name'
    $r = Get-ClockReadLines $upd '.ps1'
    Case 'MUST NOT FIRE' 'an updated stamp in ISO form is not a clock read' (@($r).Count -eq 0) ("got " + @($r).Count)
    $idx = '  $doc[''generated''] = (' + $gd + ').ToString(''s'')'
    $r = Get-ClockReadLines $idx '.ps1'
    Case 'MUST NOT FIRE' 'an indexer stamp is not a clock read' (@($r).Count -eq 0) ("got " + @($r).Count)
    $pyNested = '    "date": datetime.datetime.' + 'now().isoformat(timespec="seconds"),'
    $r = Get-ClockReadLines $pyNested '.py'
    Case 'MUST NOT FIRE' 'a module-qualified Python datetime stamp is not a clock read' (@($r).Count -eq 0) ("got " + @($r).Count)
    $dc = '$cR = Get-' + 'DatedClaims -Text $text -StaleDays 90'
    $r = Get-ClockReadLines $dc '.ps1'
    Case 'MUST NOT FIRE' 'a function whose name starts with the cmdlet is not a clock read' (@($r).Count -eq 0) ("got " + @($r).Count)
    $r = Get-ClockReadLines $commentLine '.ps1'
    Case 'MUST NOT FIRE' 'a comment naming the clock is not a clock read' (@($r).Count -eq 0) ("got " + @($r).Count)
    $blk = "<#`n  " + $ageLine + "`n#>`n`$x = 1"
    $r = Get-ClockReadLines $blk '.ps1'
    Case 'MUST NOT FIRE' 'a block comment naming the clock is not a clock read' (@($r).Count -eq 0) ("got " + @($r).Count)

    Case 'MUST FIRE' 'an ops audit script is in the population' ((Get-DetectorFamily 'ops/audit-x.ps1') -eq 'ops/audit-*.ps1')
    Case 'MUST FIRE' 'a nested meal-prep audit is in the population' ((Get-DetectorFamily 'meal-prep/pipeline/audit-y.ps1') -eq 'meal-prep/**/audit*')
    Case 'MUST NOT FIRE' 'an archived audit is not in the population' ($null -eq (Get-DetectorFamily 'grocery/archive/one-off/audit-z.ps1'))
    Case 'MUST NOT FIRE' 'an audit library is not in the population' ($null -eq (Get-DetectorFamily 'meal-prep/pipeline/audit-blocker-lib.ps1'))
    Case 'MUST NOT FIRE' 'a non-audit script is not in the population' ($null -eq (Get-DetectorFamily 'grocery/compare-deals.ps1'))

    $libAge = 'function Test-Aged { param($p) return (((' + $gd + ') - (Get-Item $p).LastWriteTime).TotalHours -gt 26) }'
    $libStamp = 'function Add-Stamp { param($d) $d.generated = (' + $gd + ' -Format ''yyyy-MM-dd HH:mm''); $d }'
    $libFns = Get-ClockLibFunctions @(@{ path = 'lib/x.ps1'; text = ($libAge + "`n" + $libStamp) })
    Case 'MUST FIRE' 'a library function that reads the clock is found' ($libFns.ContainsKey('Test-Aged')) (($libFns.Keys) -join ',')
    Case 'MUST NOT FIRE' 'a library function that only stamps is not' (-not $libFns.ContainsKey('Add-Stamp')) (($libFns.Keys) -join ',')
    $calls = Get-LibClockCalls '$ok = Test-Aged $f' $libFns
    Case 'MUST FIRE' 'a detector calling a clock-reading library function is a candidate' (@($calls).Count -eq 1) ("got " + @($calls).Count)
    $calls = Get-LibClockCalls '$ok = Test-AgedTwice $f' $libFns
    Case 'MUST NOT FIRE' 'a longer name that starts with that function is not a call to it' (@($calls).Count -eq 0) ("got " + @($calls).Count)

    $lines = Get-ClockReadLines $ageLine '.ps1'
    $sig = Get-ClockSignature $lines
    $ruled = @{ 'a.ps1' = [pscustomobject]@{ verdict = 'LIVENESS'; grade = 'EXIT'; reason = 'r'; sig = $sig } }
    $row = Get-Classification 'a.ps1' 'fam' $lines $ruled
    Case 'CLEAN TWIN' 'a verdict whose signature matches is honoured' ($row.bucket -eq 'LIVENESS' -and $row.grade -eq 'EXIT') ($row.bucket)
    $moved = Get-ClockReadLines ($ageLine.Replace('26', '48')) '.ps1'
    $row = Get-Classification 'a.ps1' 'fam' $moved $ruled
    Case 'MUST FIRE' 'a verdict over clock lines that changed reads UNRULED' ($row.bucket -eq 'UNRULED' -and $row.reason -match 'STALE') ($row.bucket)
    $bad = @{ 'a.ps1' = [pscustomobject]@{ verdict = 'LIVENESS'; grade = 'BLOCKING'; reason = 'r'; sig = $sig } }
    $row = Get-Classification 'a.ps1' 'fam' $lines $bad
    Case 'MUST FIRE' 'a verdict with a grade outside EXIT or PRINT reads UNRULED' ($row.bucket -eq 'UNRULED' -and $row.reason -match 'MALFORMED') ($row.bucket)
    $row = Get-Classification 'b.ps1' 'fam' $lines $ruled
    Case 'MUST FIRE' 'a clock-reading file with no verdict reads UNRULED' ($row.bucket -eq 'UNRULED') ($row.bucket)
    $row = Get-Classification 'c.ps1' 'fam' @() $ruled
    Case 'CLEAN TWIN' 'a file that reads no clock is SAFETY with no verdict needed' ($row.bucket -eq 'SAFETY') ($row.bucket)
    Case 'CLEAN TWIN' 'a rate carries its denominator' ((Format-Rate 3 132) -eq '3 of 132 (2.3%)') (Format-Rate 3 132)
  } catch {
    [void]$fails.Add('THREW ' + $_.Exception.Message)
    Write-Output ("  THREW {0}" -f $_.Exception.Message)
  }
  $expected = 28
  if ($ran.Count -ne $expected) { [void]$fails.Add("ran $($ran.Count) of $expected cases") }
  if ($fails.Count) {
    Write-Output ("report-safety-liveness self-test: FAIL ({0} of {1}): {2}" -f $fails.Count, $ran.Count, ($fails -join '; '))
    exit 1
  }
  Write-Output ("report-safety-liveness self-test: PASS ({0} of {0} cases)" -f $ran.Count)
  exit 0
}

# ------------------------------------------------------------------------------------------ live run
$tracked = @(& git -C $repo ls-files)
$pop = New-Object System.Collections.Generic.List[object]
foreach ($t in $tracked) { $fam = Get-DetectorFamily $t; if ($fam) { $pop.Add([pscustomobject]@{ file = $t; family = $fam }) } }
if ($pop.Count -eq 0) {
  Write-Output 'report-safety-liveness: BLIND - the detector population resolved EMPTY; that is not a clean portfolio.'
  Write-Output 'SAFETY-LIVENESS-COMPLETE detectors=0 blind=1'
  exit 3
}
$verdicts = @{}
if (Test-Path -LiteralPath $Register) {
  $reg = [IO.File]::ReadAllText($Register) | ConvertFrom-Json
  foreach ($e in @($reg.entries)) { $verdicts[[string]$e.file] = $e }
}
$head = (& git -C $repo rev-parse --short HEAD)
$libs = New-Object System.Collections.Generic.List[object]
foreach ($t in $tracked) {
  if ($t -match '(^|/)archive/') { continue }
  if ($t -match '^lib/[^/]+\.ps1$' -or $t -match '-lib\.ps1$') {
    $libs.Add(@{ path = $t; text = [IO.File]::ReadAllText((Join-Path $repo ($t.Replace('/', '\')))) })
  }
}
$clockFns = Get-ClockLibFunctions $libs.ToArray()
$rows = New-Object System.Collections.Generic.List[object]
foreach ($p in $pop) {
  $full = Join-Path $repo ($p.file.Replace('/', '\'))
  $ext = [IO.Path]::GetExtension($full)
  $text = [IO.File]::ReadAllText($full)
  # Assign, then wrap: both return a comma-wrapped array, which @() would read as ONE element.
  $direct = Get-ClockReadLines $text $ext
  $ev = @($direct)
  if ($ext -eq '.ps1') { $viaLib = Get-LibClockCalls $text $clockFns; $ev += @($viaLib) }
  $rows.Add((Get-Classification $p.file $p.family ([string[]]$ev) $verdicts))
}
$n = $rows.Count
$live = @($rows | Where-Object { $_.bucket -eq 'LIVENESS' })
$safe = @($rows | Where-Object { $_.bucket -eq 'SAFETY' })
$unr = @($rows | Where-Object { $_.bucket -eq 'UNRULED' })
$cand = @($rows | Where-Object { $_.clock_lines -gt 0 })
$orphans = @($verdicts.Keys | Where-Object { $k = $_; -not ($rows | Where-Object { $_.file -eq $k }) })

Write-Output ("SAFETY vs LIVENESS over the detector population at {0}" -f $head)
Write-Output ("  population       {0} detector file(s)" -f $n)
foreach ($k in $script:FAMILIES.Keys) {
  $fr = @($rows | Where-Object { $_.family -eq $k })
  $fl = @($fr | Where-Object { $_.bucket -eq 'LIVENESS' }).Count
  Write-Output ("    {0,-22} {1,3} file(s), liveness {2}" -f $k, $fr.Count, $fl)
}
Write-Output ("  read the clock   {0}  (candidates, each hand-ruled)" -f (Format-Rate $cand.Count $n))
Write-Output ("  LIVENESS         {0}" -f (Format-Rate $live.Count $n))
Write-Output ("    can move exit  {0}" -f (Format-Rate @($live | Where-Object { $_.grade -eq 'EXIT' }).Count $n))
Write-Output ("    print only     {0}" -f (Format-Rate @($live | Where-Object { $_.grade -eq 'PRINT' }).Count $n))
Write-Output ("  SAFETY           {0}" -f (Format-Rate $safe.Count $n))
Write-Output ("  UNRULED          {0}  (never counted in either bucket)" -f (Format-Rate $unr.Count $n))
foreach ($r in $live) { Write-Output ("    LIVENESS {0,-8} {1} - {2}" -f $r.grade, $r.file, $r.reason) }
foreach ($r in $unr) { Write-Output ("    UNRULED  {0} - {1}" -f $r.file, $r.reason) }
foreach ($o in $orphans) { Write-Output ("    ORPHAN VERDICT {0} - no longer in the population; remove it from the register" -f $o) }
if ($List) { foreach ($r in ($rows | Where-Object { $_.clock_lines -gt 0 -and $_.bucket -eq 'SAFETY' })) { Write-Output ("    SAFETY   {0} - {1}" -f $r.file, $r.reason) } }
if ($OutFile) {
  $doc = [ordered]@{ head = $head; population = $n; liveness = $live.Count; safety = $safe.Count; unruled = $unr.Count
                     candidates = $cand.Count; rows = $rows.ToArray() }
  [IO.File]::WriteAllText($OutFile, ($doc | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
  Write-Output ("  wrote {0}" -f $OutFile)
}
Write-Output ("SAFETY-LIVENESS-COMPLETE detectors={0} liveness={1} safety={2} unruled={3} candidates={4}" -f $n, $live.Count, $safe.Count, $unr.Count, $cand.Count)
exit 0
