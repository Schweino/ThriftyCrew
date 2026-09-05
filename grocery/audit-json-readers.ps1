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
#   .\audit-json-readers.ps1              audit and compare against the ratchet
#   .\audit-json-readers.ps1 -Baseline    (re-)write the high-water mark from the current count
#   .\audit-json-readers.ps1 -SelfTest    frozen must-fire + clean twins
# Exit 0 = at or below the baseline. Exit 2 = ratchet broken, or a self-test regression. Exit 3 = BLIND.
param([string]$Root = '', [string]$OutDir = '', [switch]$Baseline, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
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
  if ($r.Count -eq 1) { Write-Output '  PASS  MUST FIRE: a bare `Get-Content -Raw | ConvertFrom-Json` is reported' }
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

  if ($fail) { Write-Output "SELF-TEST FAILED ($fail)"; exit 2 }
  Write-Output 'SELF-TEST PASS - founding bug armed, four clean twins and the ratchet hold'
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
  Write-GuardComplete -Name 'json-readers' -Summary ('BLIND on ' + $unscanned.Count + ' file(s)')
  exit 3
}
$count = $findings.Count
$byFile = $findings | Group-Object file | Sort-Object Count -Descending

Write-Output ("audit-json-readers: $($files.Count) script(s) scanned, $count bare JSON read(s) that PS 5.1 will decode with the ANSI codepage on a BOM-less file")
foreach ($g in ($byFile | Select-Object -First 15)) {
  Write-Output ("  {0,-34} {1,3} site(s)   lines {2}" -f $g.Name, $g.Count, ((@($g.Group | Select-Object -First 8 | ForEach-Object { $_.line }) -join ', ')))
}
if ($byFile.Count -gt 15) { Write-Output ("  ... and " + ($byFile.Count - 15) + " more file(s)") }

$blF = Join-Path $OutDir 'json-readers-baseline.json'
$base = $null
if ((Test-Path $blF) -and -not $Baseline) { try { $base = [int]((Read-JsonFile $blF).count) } catch { $base = $null } }
$verdict = Get-RatchetVerdict $count $base
if ($Baseline -or $verdict -eq 'first') {
  @{ generated = (Get-Date).ToString('s'); count = $count; note = 'High-water mark for the bare-JSON-reader ratchet, set 2026-09-05 when PS 5.1 codepage decoding was found corrupting live board names. This number may only go DOWN. A run above it is a NEW bare reader and hard-fails.' } |
    ConvertTo-Json -Depth 3 | Set-Content $blF -Encoding UTF8
  Write-Output ("  baseline written: $count site(s). From here the number may only go DOWN.")
  Write-GuardComplete -Name 'json-readers' -Summary "baseline $count"
  exit 0
}
@{ generated = (Get-Date).ToString('s'); count = $count; findings = @($findings) } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutDir 'json-readers.json') -Encoding UTF8
if ($verdict -eq 'break') {
  Write-Output ("audit-json-readers: RATCHET BROKEN - $count site(s) now, baseline $base. A NEW bare JSON read has been added. On a BOM-less file it will silently mangle every non-ASCII character and bake the damage into the bytes. Use Read-JsonFile from lib\json-io.ps1.")
  Write-GuardComplete -Name 'json-readers' -Summary "$count over a baseline of $base"
  exit 2
}
if ($verdict -eq 'tighten') {
  @{ generated = (Get-Date).ToString('s'); count = $count; note = 'High-water mark for the bare-JSON-reader ratchet. This number may only go DOWN.' } |
    ConvertTo-Json -Depth 3 | Set-Content $blF -Encoding UTF8
  Write-Output ("  ratchet tightened: $count site(s), was $base. New baseline written.")
}
Write-Output ("audit-json-readers: $count site(s) against a baseline of $base - the known backlog, not a regression. Convert them with Read-JsonFile (lib\json-io.ps1).")
Write-GuardComplete -Name 'json-readers' -Summary "$count site(s), baseline $base"
exit 0
