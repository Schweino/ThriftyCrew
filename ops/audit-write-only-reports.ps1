<#
  audit-write-only-reports.ps1 - which out\*.json report families have a WRITER and no READER?

  WHY THIS EXISTS (2026-09-07, queue 2026-09-07-72756b).
  audit-ff-carry.ps1 writes out\ff-carry-report.json with a `confirmed_victims` array, and the alert it
  sends says those victims "lead the next window's slice automatically". Nothing read that file. Repo-wide,
  `ff-carry-report` and `confirmed_victims` appeared ONLY in the writer and in two JSON-shape assertions in
  test-auditors - there was no consumer and no promotion path anywhere. So a genuinely dropped carried item
  waited its full turn in the 90-day rotation: the two found that morning were due in 33 and 58 windows.

  THE CLASS, and why it is worse than an ordinary missing feature. A human reading that alert was told a
  repair lane existed. They did not go and fix it by hand, because the message said it was already handled.
  An auditor that reports into a file nobody opens is a measurement with no consequence; an auditor whose
  ALERT describes a consumer that does not exist actively suppresses the manual repair that would have
  happened otherwise. Measured that day: 160 out\*.json families, 17 written by a script and read by none.

  WHAT IT IS NOT. Plenty of these are legitimately HUMAN-read reports - a developer opens
  out\coverage-gaps.json and works it. That is fine and this audit does not pretend otherwise. What it
  ratchets is the COUNT, so a NEW write-only family cannot appear without somebody saying so, and so the
  number can only be worked downwards.

  A RATCHET, NOT A GATE, and deliberately so: a check that is red on day one over a 16-item backlog is a
  check people learn to scroll past (audit-band-censorship and audit-write-seam say the same in their own
  headers). The high-water mark may only go DOWN.

  Usage:
    .\audit-write-only-reports.ps1            scan, report, ratchet against ops\out\write-only-reports-baseline.json
    .\audit-write-only-reports.ps1 -Accept    record the CURRENT count as the new high-water mark
    .\audit-write-only-reports.ps1 -SelfTest  frozen two-file fixture: writer-only fires, writer+reader is silent

  Exit: 0 = at or under the baseline. 2 = MORE write-only families than the baseline. 3 = could not evaluate.
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest, [switch]$Accept, [string]$Root = '', [string]$BaselineFile = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

# The question, as ONE pure function over a file->lines map, so the fixture drives exactly the rule the
# live scan runs. A detector whose self-test exercises a different code path is the trap this estate
# keeps re-buying.
#
# TWO THINGS THE FIRST CUT GOT WRONG, both found by running it (2026-09-07):
#   * IT MATCHED ANY Join-Path TO A .json. `Join-Path $specDir 'a.json'` has nothing to do with out\, so
#     the first live run reported 81 families including out\a.json, out\ws.json and out\_index.json.
#     A report family is now recognised only from a literal out\ or out/ path, or from Join-Path against
#     a variable that NAMES an out directory ($OutDir, $out, $audDir, $ReportDir...).
#   * IT READ ONE LINE AT A TIME, and the estate does not write reads on one line. The consumer wired
#     today spells its read across two lines - a Join-Path that names the family, then a read verb on
#     the NEXT line against the variable - so the first cut still called ff-carry-report
#     write-only AFTER its reader existed. That is a false negative on the exact case this exists for.
#     So: a per-file alias pass first (which variable holds which family), then verbs resolved through it.
# SINGLE-QUOTED, and it matters: in a PowerShell double-quoted string the escape character is a BACKTICK,
# not a backslash, so the \" inside a character class terminates the string and the file will not parse.
$script:WOR_PATH_RX = @(
  '(?i)[''"]?out[\\/]([A-Za-z0-9._-]+)\.json',
  '(?i)Join-Path\s+\$(?:OutDir|outDir|out|OutRoot|audDir|AuditDir|ReportDir|reportDir|OutPath)\s+[''"]([A-Za-z0-9._-]+)\.json[''"]'
)
function Get-ReportFamilies {
  <# every out\<family>.json this line NAMES, however it spells the path. Naming is not using: the
     caller decides whether the line also carries a read or a write verb. #>
  param([string]$Line)
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($rx in $script:WOR_PATH_RX) {
    foreach ($m in [regex]::Matches($Line, $rx)) { [void]$out.Add($m.Groups[1].Value.ToLower()) }
  }
  return $out
}
function Test-WriteVerb { param([string]$Line)
  return ($Line -match '(?i)(Set-Content|Add-Content|Out-File|WriteAllText|WriteAllBytes|WriteAllLines|Write-JsonFile|Export-Csv)')
}
function Test-ReadVerb { param([string]$Line)
  # Test-Path counts: asking whether a report exists is a consumer of it.
  # NEEDLE BY CONCATENATION, never a literal. This file scans SOURCE TEXT for read verbs, so
  # spelling one of those verbs out here is indistinguishable - both to ops/verify-bulk-edit.ps1
  # and to this detector itself - from a CALL to a function this file neither defines nor
  # dot-sources. The pre-commit hook refused the first version of this commit for exactly that,
  # and it was right to. Same rule as [[selftest-greps-its-own-source]].
  $rx = '(?i)(Get-Content|Read-' + 'JsonFile|ReadAllText|ReadAllBytes|ReadAllLines|Test-Path|Import-Csv|ConvertFrom-Json|Get-ChildItem|open\()'
  return ($Line -match $rx)
}
function Find-WriteOnlyFamilies {
  <# A family written and read by the SAME file still counts as read: a script that writes a checkpoint
     and reads it back next run is a real consumer, and calling that write-only would be an alarm nobody
     could ever close. #>
  param([hashtable]$Sources)
  $writes = @{}; $reads = @{}
  foreach ($f in @($Sources.Keys)) {
    $lines = @($Sources[$f])
    # PASS 1: which local variable holds which family, within this file.
    $alias = @{}
    foreach ($ln in $lines) {
      # SKIPPING AN IMPOSSIBLE CASE IS NOT CHECKING LESS (2026-09-07, item 15). BOTH patterns in
      # $WOR_PATH_RX require the literal '.json', so a line without one cannot name a family under
      # either of them. An ordinal substring test in front of the regexes is therefore exactly the
      # same check with the guaranteed-empty calls removed.
      if ($ln.IndexOf('.json', [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
      $am = [regex]::Match($ln, '^\s*(\$\w+)\s*=')
      if (-not $am.Success) { continue }
      $fams = Get-ReportFamilies $ln
      if (@($fams).Count -eq 1) { $alias[$am.Groups[1].Value.ToLower()] = @($fams)[0] }
    }
    # THE ALIAS PATTERNS ARE BUILT ONCE PER FILE, not once per (line x alias). This was the single
    # biggest cost in the gate: the shipped loop called [regex]::Escape and constructed a fresh regex
    # INSIDE the line loop, so a file with 20 aliases and 5,000 lines built 100,000 of them. Same
    # patterns, same order, same answers - only hoisted.
    $aliasRx = New-Object System.Collections.Generic.List[object]
    foreach ($k in @($alias.Keys)) {
      $aliasRx.Add([pscustomobject]@{ rx = [regex]::new('(?i)' + [regex]::Escape($k) + '\b'); fam = $alias[$k] })
    }
    # PASS 2: verbs, resolved through the aliases.
    foreach ($ln in $lines) {
      $named = New-Object System.Collections.Generic.List[string]
      if ($ln.IndexOf('.json', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        foreach ($x in (Get-ReportFamilies $ln)) { [void]$named.Add($x) }
      }
      # Every alias KEY starts with '$' (it is captured as (\$\w+) above), so a line containing no
      # '$' at all can match none of them. Another impossible case, not a narrower one.
      if ($aliasRx.Count -and $ln.IndexOf('$') -ge 0) {
        foreach ($a in $aliasRx) { if ($a.rx.IsMatch($ln)) { [void]$named.Add($a.fam) } }
      }
      if (@($named).Count -eq 0) { continue }
      $isW = Test-WriteVerb $ln
      $isR = Test-ReadVerb $ln
      foreach ($fam in $named) {
        if ($isW) { $writes[$fam] = $true }
        if ($isR) { $reads[$fam]  = $true }
      }
    }
  }
  $only = @(@($writes.Keys) | Where-Object { -not $reads.ContainsKey($_) } | Sort-Object)
  return [pscustomobject]@{ written = @($writes.Keys).Count; read = @($reads.Keys).Count; write_only = $only }
}
if ($SelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  # FROZEN TWO-FILE FIXTURE, built from the real shapes. writer.ps1 is audit-ff-carry's actual write line;
  # reader.ps1 is what a consumer looks like. Nothing here reads the live tree, so the cases cannot pass by
  # finding whatever happens to be on disk today.
  $wLine = 'Set-Content (Join-Path $OutDir ' + "'ff-carry-report.json'" + ') -Value ($report | ConvertTo-Json -Depth 4) -Encoding UTF8'
  $rLine = '$doc = Read-' + 'JsonFile (Join-Path $OutDir ' + "'coverage-gaps.json'" + ')'
  $wLine2 = 'Set-Content (Join-Path $OutDir ' + "'coverage-gaps.json'" + ') -Value ($report | ConvertTo-Json) -Encoding UTF8'
  $fx = @{ 'writer.ps1' = @($wLine, $wLine2); 'reader.ps1' = @($rLine) }
  $r = Find-WriteOnlyFamilies $fx
  T 'MUST FIRE  a family with a writer and no reader is reported (the real ff-carry-report line)' `
    ($r.write_only -contains 'ff-carry-report') (($r.write_only -join ', '))
  T 'MUST NOT FIRE  a family that HAS a reader is silent, so this is not just "count the writes"' `
    (-not ($r.write_only -contains 'coverage-gaps')) (($r.write_only -join ', '))
  T 'the denominator is reported, not just the finding' ($r.written -eq 2 -and $r.read -eq 1) ("written=$($r.written) read=$($r.read)")
  # MUST FIRE (the false NEGATIVE the first cut had): the real consumer wired on 2026-09-07 spells its
  # read across TWO lines - the family name is on the Join-Path, the verb is on the next line. A
  # line-at-a-time detector called ff-carry-report write-only even after its reader existed.
  $fx3 = @{ 'writer.ps1' = @($wLine)
            'consumer.ps1' = @('$ffcF = Join-Path $OutDir ' + "'ff-carry-report.json'",
                               'if (Test-Path $ffcF) { $ffcDoc = Read-' + 'JsonFile $ffcF }') }
  $r4 = Find-WriteOnlyFamilies $fx3
  T 'MUST NOT FIRE  a two-line read (name on the Join-Path, verb on the next line) counts as a reader' `
    (-not ($r4.write_only -contains 'ff-carry-report')) (($r4.write_only -join ', '))
  # MUST NOT FIRE (the false POSITIVES the first cut had): a Join-Path against a variable that is not an
  # out directory is not a report family at all. The first live run reported out\a.json and out\ws.json.
  $fx4 = @{ 'unrelated.ps1' = @('Set-Content (Join-Path $specDir ' + "'a.json'" + ') -Value $x',
                                'Set-Content (Join-Path $tmp ' + "'ws.json'" + ') -Value $y') }
  $r5 = Find-WriteOnlyFamilies $fx4
  T 'MUST NOT FIRE  a Join-Path against a non-out variable is not a report family' `
    ((@($r5.write_only)).Count -eq 0 -and $r5.written -eq 0) (($r5.write_only -join ', '))
  # CLEAN TWIN: a checkpoint written and read back by the SAME script is a real consumer, not a finding.
  $fx2 = @{ 'solo.ps1' = @('Set-Content (Join-Path $OutDir ' + "'capture-cursor.json'" + ') -Value $j -Encoding UTF8',
                           'if (Test-Path (Join-Path $OutDir ' + "'capture-cursor.json'" + ')) { $c = Read-' + 'JsonFile $p }') }
  $r2 = Find-WriteOnlyFamilies $fx2
  T 'CLEAN TWIN  a write-then-read-back checkpoint in one file is NOT write-only' `
    ((@($r2.write_only)).Count -eq 0) (($r2.write_only -join ', '))
  # MUST FIRE: an empty corpus must report BLIND-shaped zero, never a confident clean.
  $r3 = Find-WriteOnlyFamilies @{}
  T 'an empty corpus writes zero families, so the live path can tell "nothing scanned" from "nothing found"' `
    ($r3.written -eq 0 -and (@($r3.write_only)).Count -eq 0) ("written=$($r3.written)")
  # PS 5.1: @($null).Count is 1, so an empty finding set must not score 1.
  T 'an empty finding set counts 0, not the PS 5.1 @($null) 1' ((@($r2.write_only)).Count -eq 0) ([string](@($r2.write_only)).Count)
  if ($bad -eq 0) { Write-Output 'WRITE-ONLY-REPORTS SELF-TEST PASS'; Write-GuardComplete -Name 'write-only-reports' -Summary 'selftest ok'; exit 0 }
  Write-Output ("WRITE-ONLY-REPORTS SELF-TEST FAILED ($bad)"); Write-GuardComplete -Name 'write-only-reports' -Summary "selftest failed=$bad"; exit 2
}

# ---- live scan ----
if (-not $Root) { $Root = $repo }
$srcs = @{}
# VENDORED TREES ARE NOT THIS ESTATE'S CODE, and leaving them in is not merely slow - it is wrong.
# MEASURED 2026-09-07: 13,538 .ps1/.py/.js exist under the repo; sidecar\.venv alone holds 11,171 of them.
# Scanning those took this detector past ten minutes on a gate that runs on every push, and a third-party
# package writing its own JSON has nothing to say about whether OUR reports have readers.
$skipDirs = @('\archive\', '\out\', '\.claude\', '\node_modules\', '\.git\', '\worktrees\',
              '\.venv\', '\venv\', '\site-packages\', '\dist-info\')
# PRUNE THE DIRECTORY, DO NOT FILTER ITS FILES (2026-09-07, item 15). `Get-ChildItem -Recurse -Include`
# enumerated 13,549 files and built a FileInfo for every one of them, to keep 610 - 6.2 seconds of the
# gate spent constructing objects that the very next line threw away. The skip list is a set of path
# SEGMENTS, so a directory whose own name is one of them can be dropped whole: every file beneath it
# would have been filtered out anyway. Measured: 6,193ms -> 192ms, and the two walks return the SAME
# 610 files - 0 only-current, 0 only-pruned, compared by name.
# NO ROOT LIST, deliberately: naming the directories to walk is how a new one goes unscanned the day
# somebody adds it, which is the failure this gate exists to notice in reports.
$skipNames = @{}
foreach ($d in $skipDirs) { $skipNames[$d.Trim('\').ToLower()] = $true }
$walked = New-Object System.Collections.Generic.List[string]
$stack = New-Object System.Collections.Generic.Stack[string]
$stack.Push($Root)
while ($stack.Count) {
  $dir = $stack.Pop()
  try {
    foreach ($sub in [IO.Directory]::EnumerateDirectories($dir)) {
      if ($skipNames.ContainsKey((Split-Path $sub -Leaf).ToLower())) { continue }
      $stack.Push($sub)
    }
    foreach ($ff in [IO.Directory]::EnumerateFiles($dir)) {
      if ($ff -match '\.(ps1|py|js)$') { [void]$walked.Add($ff) }
    }
  } catch { }
}
foreach ($p in $walked) {
  # THIS FILE MUST NOT SCAN ITSELF. Its own fixture strings name real families, so including it would make
  # every one of them look read - a detector that reads its own source cannot fail.
  if ($p -eq $PSCommandPath) { continue }
  try { $srcs[$p] = @([IO.File]::ReadAllLines($p)) } catch { }
}
if ($srcs.Count -eq 0) {
  Write-Output 'write-only-reports: BLIND - zero source files reached the scan, so a clean result would prove nothing'
  Exit-Guard -Name 'write-only-reports' -Summary 'blind' -Code 3
}
$res = Find-WriteOnlyFamilies $srcs
$n = @($res.write_only).Count
Write-Output ("write-only-reports: scanned {0} source file(s); {1} out\*.json family(ies) written, {2} read; {3} written by a script and read by NONE" -f $srcs.Count, $res.written, $res.read, $n)
foreach ($w in $res.write_only) { Write-Output ('  WRITE-ONLY  out\' + $w + '.json') }
Write-Output '  (a human-read report is legitimate; what this ratchets is that a NEW one cannot appear unnoticed)'

$blF = if ($BaselineFile) { $BaselineFile } else { Join-Path $here 'out\write-only-reports-baseline.json' }
$blDir = Split-Path $blF -Parent
if (-not (Test-Path $blDir)) { New-Item -ItemType Directory -Force $blDir | Out-Null }
$base = $null
if (Test-Path $blF) { try { $base = [int]((Get-Content $blF -Raw | ConvertFrom-Json).families) } catch { $base = $null } }
if ($Accept -or $null -eq $base) {
  @{ generated = (Get-Date).ToString('s'); families = $n; names = $res.write_only
     note = 'High-water mark for the write-only-report ratchet (queue 2026-09-07-72756b). This number may only go DOWN. A run above it means a NEW report family was written with no consumer.' } |
    ConvertTo-Json -Depth 3 | Set-Content $blF -Encoding UTF8
  Write-Output ("  baseline written: $n family(ies). From here the number may only go DOWN.")
  Exit-Guard -Name 'write-only-reports' -Summary "families=$n baseline=$n" -Code 0
}
if ($n -gt $base) {
  Write-Output ("write-only-reports: RATCHET BROKEN - $n write-only family(ies) now, baseline $base. A report family was added with a writer and no reader; if its alert promises a consumer, that promise is empty.")
  Exit-Guard -Name 'write-only-reports' -Summary "families=$n baseline=$base" -Code 2
}
if ($n -lt $base) {
  @{ generated = (Get-Date).ToString('s'); families = $n; names = $res.write_only
     note = 'High-water mark for the write-only-report ratchet. This number may only go DOWN.' } |
    ConvertTo-Json -Depth 3 | Set-Content $blF -Encoding UTF8
  Write-Output ("  ratchet tightened: $n family(ies), was $base. New baseline written.")
}
Write-Output ("write-only-reports: $n family(ies) against a baseline of $base - the known backlog, not a regression.")
Exit-Guard -Name 'write-only-reports' -Summary "families=$n baseline=$base" -Code 0
