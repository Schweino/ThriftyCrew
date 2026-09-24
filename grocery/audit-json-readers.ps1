# audit-json-readers.ps1 - does any live script still read JSON in a way PowerShell 5.1 decodes wrongly?
#
# WHY THIS EXISTS (2026-09-05). Five live board cells across three stores carried mangled product names
# while every guard read green, and the file that produced the worst of them - sams-deals-2026-07-29.json -
# is CLEAN ON DISK. The engine manufactured the corruption at read time, because PS 5.1's Get-Content
# decodes a file with no byte-order mark using the system ANSI codepage rather than UTF-8. Proven in
# lib\json-io.ps1's own self-test, which asserts the bug still exists before claiming to fix it.
#
# THE HAZARD IS A PAIR, and neither half is wrong on its own: a writer that emits BOM-less UTF-8 (Python's
# json.dump, .NET WriteAllText with UTF8Encoding($false)) and a reader that omits -Encoding. Measured the
# day this was written: 45 of 359 capture files carry no BOM, and 683 JSON reads across the estate omit an
# encoding against 55 that specify one. The five corrupted cells were just the intersection that was live.
# Each round trip through a bad pair adds ONE GENERATION - the Campbell's row was five deep, 117 characters
# for a 36-character name, and commodities.json once reached eight to ten (audit-json-encoding.ps1).
#
# WHY THIS GUARD IS ON THE READER SIDE. Requiring every writer to emit a BOM is unenforceable at the edges
# (Python tools, browser downloads, anything we do not own) and it CONFLICTS with a policy this estate
# already depends on: audit-json-encoding pins commodities.json to pure ASCII with NO BOM, deliberately,
# because pure ASCII decodes identically under UTF-8 and cp1252. A correct READER is compatible with every
# shape and needs no cooperation from anyone.
#
# WHAT IT FLAGS. A line that reads JSON and states no encoding:
#     Get-Content <path> -Raw | ConvertFrom-Json          <- flagged
#     Get-Content <path> -Raw -Encoding UTF8 | ...        <- fine (narrower than the lib, but correct)
#     Read-JsonFile <path>                                 <- fine (lib\json-io.ps1, handles every shape)
#     [IO.File]::ReadAllText(<path>)                       <- fine (the primitive the lib wraps)
# KNOWN LIMIT, STATED RATHER THAN HIDDEN: it is a line-level scan, so a read split across two lines is not
# seen. That is a floor on what this can prove, not a claim that the rest is clean. It is still worth having:
# every one of the sites it found on day one was real.
#
# IT IS A RATCHET, not a gate, for the same reason audit-tile-integrity is: there were dozens of these on
# day one and a gate that fails from day one is a gate that gets switched off. The baseline may only go
# DOWN. A NEW bare reader hard-fails, because that is a regression rather than the known backlog.
#
#   .\audit-json-readers.ps1              audit and compare against the ratchet; never lowers the mark
#   .\audit-json-readers.ps1 -Tighten     the same, and record a believable FALL as the new high-water mark
#   .\audit-json-readers.ps1 -Baseline    (re-)write the high-water mark from the current count
#   .\audit-json-readers.ps1 -SelfTest    frozen must-fire + clean twins, plus the live path against a temp tree
# Exit 0 = at or below the baseline. Exit 2 = ratchet broken, or a self-test regression. Exit 3 = BLIND.
#
# A PLAIN RUN WRITES NEITHER THE MARK NOR A CHANGED-NOTHING REPORT (backlog I227, 2026-09-18). The tighten
# branch lowered the tracked baseline on every plain run, against "a plain run of a ratchet never writes its
# mark" (.claude\rules\ops-and-gates.md; design\MEASURE-ratchet-plain-run-writes-2026-09-12.md named this file
# as the one left standing). A fall is now SPOKEN and the mark KEPT; -Tighten records it. And the tracked
# report out\json-readers.json was rewritten on EVERY run, with a fresh `generated` time and in CRLF over an
# eol=lf blob, so a hand run left the checkout ` M` even when nothing changed. It now carries no clock and goes
# through lib\lf-write.ps1, which keeps the committed BOM and skips identical bytes: an unchanged tree leaves
# it untouched, and a changed finding still lands in it for the daily commit.
# SCOPE OF A CLEAN REPORT: UNSOUND. A line-level text scan of grocery\*.ps1 and lib\*.ps1 for the spellings
# under WHAT IT FLAGS; a clean report means none of those spellings is present, not that every JSON read in
# the estate states its encoding.
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([string]$Root = '', [string]$OutDir = '', [switch]$Baseline, [switch]$SelfTest, [switch]$AcceptDrop, [switch]$Tighten)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
# THIS GUARD READ ITS OWN BASELINE THROUGH A FUNCTION IT NEVER LOADED (found 2026-09-05). The baseline read
# below is Read-JsonFile wrapped in a try/catch, and this file did not dot-source the lib that defines it -
# so EVERY run threw, caught, set $base to $null, scored the verdict as 'first' and REWROTE the high-water
# mark from the current count. A ratchet that re-baselines itself can never break: it would have accepted
# any number of new bare readers in silence, which is exactly the [[guard-blindness-family]] shape this file
# was written to catch elsewhere. A corrupt baseline file is still never a crash, but since 2026-09-24 it is not a
# first run either (design\backlog-inbox\pd-currency-2026-09-23.md): a missing or unreadable mark is exit 3 with
# blind=baseline-missing or blind=baseline-unreadable and nothing written, because a "first run" over a baseline a
# botched rebase left holding conflict markers accepted whatever count the push carried, a rise included. -Baseline
# is the one deliberate way to write a mark over it (lib\ratchet.ps1's Read-TcRatchetBaseline decides the state).
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
if (-not (Get-Command Read-JsonFile -ErrorAction SilentlyContinue)) { throw 'audit-json-readers: Read-JsonFile is not loaded, so the baseline read would fail-open and re-baseline the ratchet.' }
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\lf-write.ps1')   # Write-TcLfFile: the report and baseline are tracked, stored eol=lf with a BOM
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Root)   { $Root = $here }
if (-not $OutDir) { $OutDir = Join-Path $here 'out' }

# ONE implementation, driven by the self-test with frozen text and by the live path with real files.
function Find-BareJsonReads {
  # [AllowEmptyString()] IS LOAD-BEARING. In PS 5.1 a Mandatory [string[]] rejects the whole binding when
  # ANY element is an empty string, and every source file has blank lines - so this threw on the first real
  # file, the loop below carried on, and the guard reported a count that was silently missing whatever it
  # could not scan. An undercount in a ratchet is worse than no ratchet: it lowers the baseline and then
  # calls the next real regression "the known backlog".
  param([Parameter(Mandatory=$true)][AllowEmptyString()][string[]]$Lines, [string]$File = '')
  $out = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $Lines.Count; $i++) {
    $ln = [string]$Lines[$i]
    $t = $ln.TrimStart()
    if ($t.StartsWith('#')) { continue }                       # a comment describing the bug is not the bug
    if ($ln -notmatch 'Get-Content') { continue }
    if ($ln -notmatch 'ConvertFrom-Json') { continue }         # only JSON reads; plain text has its own rules
    if ($ln -match '-Encoding') { continue }                   # states an encoding: correct, if narrower
    # A DOCUMENTED EXEMPTION, because some bare reads are the POINT. lib\json-io.ps1's must-fire case has to
    # perform the broken read to prove the PS 5.1 bug still exists, and test fixtures deliberately write and
    # read cp1252 to reproduce a founding bug. Without this the guard flags its own proof, and the only ways
    # out are to delete the fixture or to let the count sit permanently above zero - both of which end with
    # the guard being ignored.
    # It requires a REASON on the same line, so an exemption cannot be a bare silencer: `# json-readers:allow
    # <why>`. An empty marker is NOT honoured, for the same reason a half-written ruling covers nothing in
    # derived-size-density-rulings.json.
    $ex = [regex]::Match($ln, 'json-readers:allow\s+(?<why>\S.*)$')
    if ($ex.Success) { continue }
    [void]$out.Add([pscustomobject]@{ file = $File; line = $i + 1; text = $t.Substring(0, [Math]::Min(120, $t.Length)) })
  }
  return @($out)
}

function Get-RatchetVerdict([int]$Count, $Base) {
  if ($null -eq $Base) { return 'first' }
  if ($Count -gt [int]$Base) { return 'break' }
  if ($Count -lt [int]$Base) { return 'tighten' }
  return 'hold'
}

if ($SelfTest) {
  $fail = 0
  # MUST FIRE - the exact shape that corrupted the board, frozen.
  # FROZEN, AND ASSEMBLED FROM PIECES ON PURPOSE (2026-09-05). The first version of this fixture spelled the
  # bad shape out as one literal - and the estate-wide sweep that converted 608 real call sites converted
  # THIS STRING TOO, silently turning the must-fire case into `Read-JsonFile $path` so the guard reported 0
  # and passed. An automated fix rewriting the test that proves the bug is the [[guard-fixture-rule]] failure
  # exactly: a frozen fixture edited to satisfy a different tool is how a watcher goes blind. Built by
  # concatenation so no regex looking for the literal pattern can match it here.
  $badShape = '$doc = Get-Content $path -Raw ' + '|' + ' ConvertFrom' + '-Json'
  $r = @(Find-BareJsonReads -Lines @($badShape) -File 'fx.ps1')
  if ($r.Count -eq 1) { Write-Output '  PASS  MUST FIRE: a bare `Get-Content -Raw | ConvertFrom-Json` is reported' }   # json-readers:allow the PASS message names the shape this guard hunts; it is output text, not a read
  else { Write-Output "  FAIL  MUST FIRE: the founding shape was not reported (got $($r.Count))"; $fail++ }

  # CLEAN TWIN - states an encoding. Narrower than the lib but correct, so it must not be flagged or the
  # count becomes noise and the ratchet stops meaning anything.
  $r = @(Find-BareJsonReads -Lines @('$doc = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json') -File 'fx.ps1')
  if ($r.Count -eq 0) { Write-Output '  PASS  CLEAN TWIN: a read that states -Encoding is not flagged' }
  else { Write-Output '  FAIL  a correctly-encoded read was flagged - the ratchet would never reach zero'; $fail++ }

  # CLEAN TWIN - the lib, and the primitive it wraps.
  $r = @(Find-BareJsonReads -Lines @('$doc = Read-JsonFile $path', '$s = [IO.File]::ReadAllText($p) | ConvertFrom-Json') -File 'fx.ps1')
  if ($r.Count -eq 0) { Write-Output '  PASS  CLEAN TWIN: Read-JsonFile and [IO.File]::ReadAllText are not flagged' }
  else { Write-Output '  FAIL  the fixed shapes are still being flagged'; $fail++ }

  # CLEAN TWIN - a COMMENT describing the bug. This file, lib\json-io.ps1 and audit-json-encoding.ps1 all
  # quote the broken shape in prose; flagging those would make the count grow every time someone documents
  # the problem, which is the perverse incentive that kills a guard.
  $r = @(Find-BareJsonReads -Lines @('  # Read-JsonFile $x is how this went wrong') -File 'fx.ps1')
  if ($r.Count -eq 0) { Write-Output '  PASS  CLEAN TWIN: a comment quoting the bad shape is not counted as a violation' }
  else { Write-Output '  FAIL  a comment was counted - documenting the bug would raise the count'; $fail++ }

  # CLEAN TWIN - Get-Content with no ConvertFrom-Json. Plain text reads are a different question with a
  # different answer; folding them in here would swamp the signal this guard exists for.
  $r = @(Find-BareJsonReads -Lines @('$src = Get-Content $file -Raw') -File 'fx.ps1')
  if ($r.Count -eq 0) { Write-Output '  PASS  CLEAN TWIN: a non-JSON Get-Content is out of scope, not a finding' }
  else { Write-Output '  FAIL  a plain text read was flagged as a JSON reader'; $fail++ }

  # The ratchet verdict itself, same three cases as every other ratchet here.
  if ((Get-RatchetVerdict 11 10) -eq 'break' -and (Get-RatchetVerdict 10 10) -eq 'hold' -and (Get-RatchetVerdict 9 10) -eq 'tighten' -and (Get-RatchetVerdict 5 $null) -eq 'first') {
    Write-Output '  PASS  RATCHET: one more is a break, equal holds, fewer tightens, no baseline is a first run'
  } else { Write-Output '  FAIL  the ratchet verdict is wrong'; $fail++ }

  # THE LIVE PATH, run as a child against a temp tree and a temp out\ (backlog I227). The founding defect is
  # a PLAIN run lowering the tracked mark and rewriting the tracked report, so only a real run can show it.
  $ajrTmp = Join-Path $env:TEMP ('ajr-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  $ajrG = Join-Path $ajrTmp 'g'; $ajrO = Join-Path $ajrTmp 'o'
  try {
    New-Item -ItemType Directory -Path $ajrG, $ajrO -Force -ErrorAction Stop | Out-Null
    $ajrBad = '$d = Get-Content $p -Raw ' + '|' + ' ConvertFrom' + '-Json'    # built from pieces, as above
    [IO.File]::WriteAllText((Join-Path $ajrG 'fx.ps1'), ($ajrBad + "`n" + $ajrBad + "`n"), (New-Object Text.UTF8Encoding($false)))
    $ajrBl = Join-Path $ajrO 'json-readers-baseline.json'
    $ajrRep = Join-Path $ajrO 'json-readers.json'
    function AjrBase([int]$n) { $null = Write-TcLfFile -Path $ajrBl -Text (([ordered]@{ generated = 'fixture'; count = $n; note = 'fixture' }) | ConvertTo-Json) }
    function AjrRun([string[]]$extra) {
      $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $ajrG -OutDir $ajrO @extra)
      return [pscustomobject]@{ rc = $LASTEXITCODE; text = (@($o) -join "`n") }
    }
    # MUST FIRE (the defect): a FALL, 2 sites against a mark of 3, on a PLAIN run. The mark stays byte-identical.
    AjrBase 3
    $before = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ajrBl))
    $r = AjrRun @()
    $same = [string]::Equals($before, [Convert]::ToBase64String([IO.File]::ReadAllBytes($ajrBl)), [StringComparison]::Ordinal)
    if ($r.rc -eq 0 -and $same -and $r.text -match 'CAN tighten') { Write-Output '  PASS  MUST FIRE live: a fall on a PLAIN run is spoken ("CAN tighten") and the mark is left byte-identical' }
    else { Write-Output ('  FAIL  MUST FIRE live: a plain run moved the mark or did not speak the fall (rc=' + $r.rc + ' markUnchanged=' + $same + ')'); $fail++ }
    # CLEAN TWIN: -Tighten still records that fall, in the bytes git stores (BOM, no CR).
    $r = AjrRun @('-Tighten')
    $blB = [IO.File]::ReadAllBytes($ajrBl); $cr = @($blB | Where-Object { $_ -eq 13 }).Count
    $newCount = [int]((Read-JsonFile $ajrBl).count)
    if ($r.rc -eq 0 -and $newCount -eq 2 -and $cr -eq 0 -and $blB[0] -eq 0xEF) { Write-Output '  PASS  CLEAN TWIN live: -Tighten records the fall (3 -> 2) with the BOM and no CR' }
    else { Write-Output ('  FAIL  CLEAN TWIN live: -Tighten did not record the fall cleanly (rc=' + $r.rc + ' count=' + $newCount + ' cr=' + $cr + ')'); $fail++ }
    # MUST FIRE (the report half): the tree has not changed since the last run, so the report must not be rewritten.
    $repT = (Get-Item -LiteralPath $ajrRep).LastWriteTimeUtc
    $repB = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ajrRep))
    Start-Sleep -Milliseconds 50
    $r = AjrRun @()
    $repSame = ((Get-Item -LiteralPath $ajrRep).LastWriteTimeUtc -eq $repT) -and [string]::Equals($repB, [Convert]::ToBase64String([IO.File]::ReadAllBytes($ajrRep)), [StringComparison]::Ordinal)
    if ($r.rc -eq 0 -and $repSame -and $r.text -match 'unchanged, not rewritten') { Write-Output '  PASS  MUST FIRE live: a run over an unchanged tree leaves the report untouched (no clock, identical bytes skipped)' }
    else { Write-Output ('  FAIL  MUST FIRE live: an unchanged tree rewrote the report (rc=' + $r.rc + ' untouched=' + $repSame + ')'); $fail++ }
    # CLEAN TWIN: a RISE still hard-fails - 2 sites against a mark of 1.
    AjrBase 1
    $r = AjrRun @()
    if ($r.rc -eq 2 -and $r.text -match 'RATCHET BROKEN') { Write-Output '  PASS  CLEAN TWIN live: a rise over the mark still exits 2' }
    else { Write-Output ('  FAIL  CLEAN TWIN live: a rise did not exit 2 (rc=' + $r.rc + ')'); $fail++ }
    # FAIL CLOSED (2026-09-24, pd-currency-2026-09-23.md). MUST FIRE: conflict markers and an absent mark each exit 3
    # naming which, and write nothing. CLEAN TWIN: -Baseline still records one.
    [IO.File]::WriteAllText($ajrBl, ('<' * 7) + " HEAD`n{ ""count"": 2 }`n" + ('=' * 7) + "`n{ ""count"": 9 }`n" + ('>' * 7) + " theirs`n", (New-Object Text.UTF8Encoding($false)))
    $confB = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ajrBl))
    $r = AjrRun @()
    $confSame = [string]::Equals($confB, [Convert]::ToBase64String([IO.File]::ReadAllBytes($ajrBl)), [StringComparison]::Ordinal)
    if ($r.rc -eq 3 -and $confSame -and $r.text -match 'blind=baseline-unreadable') { Write-Output '  PASS  MUST FIRE live: a mark holding conflict markers exits 3, blind=baseline-unreadable, bytes unchanged' }
    else { Write-Output ('  FAIL  MUST FIRE live: a conflicted mark did not fail closed (rc=' + $r.rc + ' unchanged=' + $confSame + ')'); $fail++ }
    Remove-Item -LiteralPath $ajrBl -Force
    $r = AjrRun @('-Tighten')
    if ($r.rc -eq 3 -and -not (Test-Path -LiteralPath $ajrBl) -and $r.text -match 'blind=baseline-missing') { Write-Output '  PASS  MUST FIRE live: an ABSENT mark under -Tighten exits 3, blind=baseline-missing, and no file is created' }
    else { Write-Output ('  FAIL  MUST FIRE live: an absent mark did not fail closed (rc=' + $r.rc + ' created=' + (Test-Path -LiteralPath $ajrBl) + ')'); $fail++ }
    $r = AjrRun @('-Baseline')
    $wrote = if (Test-Path -LiteralPath $ajrBl) { [int]((Read-JsonFile $ajrBl).count) } else { -1 }
    if ($r.rc -eq 0 -and $wrote -eq 2) { Write-Output '  PASS  CLEAN TWIN live: -Baseline over an absent mark records the current count (2) and exits 0' }
    else { Write-Output ('  FAIL  CLEAN TWIN live: -Baseline did not record the count (rc=' + $r.rc + ' count=' + $wrote + ')'); $fail++ }
  } catch { Write-Output ('  FAIL  the live-path cases threw: ' + $_.Exception.Message); $fail++ }
  finally { Remove-Item -LiteralPath $ajrTmp -Recurse -Force -ErrorAction SilentlyContinue }

  if ($fail) { Write-Output "SELF-TEST FAILED ($fail)"; exit 2 }
  Write-Output 'SELF-TEST PASS - founding bug armed, four clean twins, the ratchet hold, and seven live-path cases'
  exit 0
}


# ---- live path ----
$files = @(Get-ChildItem (Join-Path $Root '*.ps1') -ErrorAction SilentlyContinue)
$libDir = Join-Path (Split-Path $Root -Parent) 'lib'
if (Test-Path $libDir) { $files += @(Get-ChildItem (Join-Path $libDir '*.ps1') -ErrorAction SilentlyContinue) }
if (-not $files.Count) { Write-Output 'BLIND: no .ps1 files found to scan'; exit 3 }

$findings = New-Object System.Collections.ArrayList
# FAIL CLOSED ON A FILE WE COULD NOT SCAN. A ratchet built from a partial scan is a lie that tightens
# itself: every unscanned file lowers the count, the baseline follows it down, and the next genuine
# regression reads as "at or below the backlog". Counting is the whole job here, so a file that cannot be
# counted is a BLIND run, not a smaller number.
$unscanned = New-Object System.Collections.ArrayList
foreach ($f in $files) {
  try {
    foreach ($x in (Find-BareJsonReads -Lines @([IO.File]::ReadAllLines($f.FullName)) -File $f.Name)) { [void]$findings.Add($x) }
  } catch { [void]$unscanned.Add($f.Name + ' (' + $_.Exception.Message + ')') }
}
if ($unscanned.Count) {
  Write-Output ("BLIND: " + $unscanned.Count + " of " + $files.Count + " script(s) could not be scanned, so this count is a floor, not a measurement:")
  $unscanned | Select-Object -First 10 | ForEach-Object { Write-Output ('  ' + $_) }
  Exit-Guard -Name 'json-readers' -Summary ('BLIND on ' + $unscanned.Count + ' file(s)') -Code 3
}
$count = $findings.Count
$byFile = $findings | Group-Object file | Sort-Object Count -Descending

Write-Output ("audit-json-readers: $($files.Count) script(s) scanned, $count bare JSON read(s) that PS 5.1 will decode with the ANSI codepage on a BOM-less file")
foreach ($g in ($byFile | Select-Object -First 15)) {
  Write-Output ("  {0,-34} {1,3} site(s)   lines {2}" -f $g.Name, $g.Count, ((@($g.Group | Select-Object -First 8 | ForEach-Object { $_.line }) -join ', ')))
}
if ($byFile.Count -gt 15) { Write-Output ("  ... and " + ($byFile.Count - 15) + " more file(s)") }

$blF = Join-Path $OutDir 'json-readers-baseline.json'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\ratchet.ps1')   # Read-TcRatchetBaseline: read, absent or unreadable
$blRead = Read-TcRatchetBaseline -Path $blF -Field 'count'
if (-not $Baseline -and $blRead.State -ne 'read') {
  $blTok = Get-TcRatchetBlindToken $blRead.State
  Write-Output ("! audit-json-readers: COULD NOT EVALUATE - the baseline $blF is $($blRead.State) ($($blRead.Why)), so there is no mark to hold $count against. Nothing was written: a plain run and -Tighten never record a mark. Restore it from git, or record the current count on purpose with -Baseline.")
  Exit-Guard -Name 'json-readers' -Summary "$count site(s), blind=$blTok" -Code 3
}
$base = $blRead.Value
$verdict = Get-RatchetVerdict $count $base
if ($Baseline) {
  $null = Write-TcLfFile -Path $blF -Text (([ordered]@{ generated = (Get-Date).ToString('s'); count = $count; note = 'High-water mark for the bare-JSON-reader ratchet, set 2026-09-05 when PS 5.1 codepage decoding was found corrupting live board names. This number may only go DOWN. A run above it is a NEW bare reader and hard-fails.' }) | ConvertTo-Json -Depth 3)
  Write-Output ("  baseline written: $count site(s). From here the number may only go DOWN.")
  Exit-Guard -Name 'json-readers' -Summary "baseline $count" -Code 0
}
# NO CLOCK IN THE REPORT: a `generated` time made every run a rewrite of a tracked file. The commit that
# carries a change is its timestamp.
$reportWritten = Write-TcLfFile -Path (Join-Path $OutDir 'json-readers.json') -Text (([ordered]@{ count = $count; findings = @($findings) }) | ConvertTo-Json -Depth 5)
Write-Output ('  report out\json-readers.json: ' + $(if ($reportWritten) { 'written (its findings changed)' } else { 'unchanged, not rewritten' }))
if ($verdict -eq 'break') {
  Write-Output ("audit-json-readers: RATCHET BROKEN - $count site(s) now, baseline $base. A NEW bare JSON read has been added. On a BOM-less file it will silently mangle every non-ASCII character and bake the damage into the bytes. Use Read-JsonFile from lib\json-io.ps1.")
  Exit-Guard -Name 'json-readers' -Summary "$count over a baseline of $base" -Code 2
}
if ($verdict -eq 'tighten') {
  # THE FALL IS THE DIRECTION THAT CANNOT BE TRUSTED ON ITS OWN (2026-09-09, backlog I93). This branch
  # used to lower the high-water mark UNCONDITIONALLY, which is the exact defect lib\ratchet.ps1 was
  # built for and which this file never adopted: a run that scanned fewer files, or matched nothing
  # because the pattern rotted, would write its own blindness in as a permanent ceiling and print a
  # pass forever afterwards. Found by ops\audit-one-way-actuators.ps1 on its first sweep.
  # AND A PLAIN RUN DOES NOT RECORD IT (backlog I227): the fall is spoken, the committed mark kept, and
  # -Tighten is the deliberate record. Same rule and wording as ops\audit-write-only-reports.ps1.
  if (-not $Tighten) {
    Write-Output ("  ratchet CAN tighten: $count site(s), baseline $base. NOT written: a rewrite here dirties the checkout that ran it and rides no commit. Record it with -Tighten and commit out\json-readers-baseline.json.")
    Exit-Guard -Name 'json-readers' -Summary "$count site(s), baseline $base, can-tighten" -Code 0
  }
  . (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\ratchet.ps1')
  $move = Test-RatchetMove -Name 'json-readers' -Count $count -Baseline ([int]$base) -AcceptDrop:$AcceptDrop
  Write-Output ("  " + $move.Message)
  if ($move.Verdict -eq 'implausible') {
    Write-Output '  Baseline KEPT. Check the scan actually ran over the same tree before accepting this.'
    Exit-Guard -Name 'json-readers' -Summary "implausible fall $count from $base, baseline kept" -Code 2
  }
  $null = Write-TcLfFile -Path $blF -Text (([ordered]@{ generated = (Get-Date).ToString('s'); count = $move.NewBaseline; note = 'High-water mark for the bare-JSON-reader ratchet. This number may only go DOWN, and a fall to zero or over -MaxDropPct is refused rather than recorded (backlog I93).' }) | ConvertTo-Json -Depth 3)
  Write-Output ("  ratchet tightened: $($move.NewBaseline) site(s), was $base. New baseline written - commit it, or it protects only this checkout.")
}
Write-Output ("audit-json-readers: $count site(s) against a baseline of $base - the known backlog, not a regression. Convert them with Read-JsonFile (lib\json-io.ps1).")
Exit-Guard -Name 'json-readers' -Summary "$count site(s), baseline $base" -Code 0
