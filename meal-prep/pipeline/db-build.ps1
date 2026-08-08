# db-build.ps1 - rebuild db\thriftycrew.db from the JSON stores, with foreign keys ENFORCED.
#
# WHY THIS WRAPPER EXISTS. The build itself is db\build_db.py (sqlite3 is Python stdlib; nothing else on
# this machine can speak SQLite - see the note below). This script is what the estate calls: it finds the
# interpreter, runs the build, and turns a constraint refusal into the estate's own finding format so the
# daily chain can log and alert on it like any other guard.
#
# THE INTERPRETER IS NOT ON PATH, and that is not fixable by adding it. Windows ships App Execution Aliases
# that shadow `python` with a 0-byte Store stub, so `python` resolves to something that prints "Python was
# not found" and exits 49. The real 3.12.10 install lives at C:\Codex\Python312\ and is recorded in the
# registry under HKCU:\SOFTWARE\Python\PythonCore\3.12\InstallPath - which is what this reads, so a
# reinstall to a different path keeps working and the stub can never be picked up by accident.
#
# WHAT A FAILURE MEANS. Exit 1 is a REFUSED WRITE: some reference in the JSON does not resolve (a bid naming
# no commodity, a recipe costing an item with no price row). That is the class that pointed Turkey Bacon at
# PORK for weeks and dropped Garlic Powder from a recipe total. The message names the row.
#
# Usage: .\db-build.ps1 [-VerifyOnly] | -SelfTest
param([switch]$VerifyOnly, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here
$g    = Join-Path (Split-Path $mp -Parent) 'grocery'

function Get-PythonExe {
  # registry first (survives a reinstall), then the known path, NEVER a bare 'python' (Store alias)
  foreach ($hive in 'HKCU:\SOFTWARE\Python\PythonCore', 'HKLM:\SOFTWARE\Python\PythonCore') {
    foreach ($v in (Get-ChildItem $hive -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
      $ip = (Get-ItemProperty (Join-Path $v.PSPath 'InstallPath') -ErrorAction SilentlyContinue).'(default)'
      if ($ip) {
        $exe = Join-Path $ip 'python.exe'
        if ((Test-Path $exe) -and ((Get-Item $exe).Length -gt 10000)) { return $exe }   # >10KB = not a stub
      }
    }
  }
  foreach ($p in @('C:\Codex\Python312\python.exe')) {
    if ((Test-Path $p) -and ((Get-Item $p).Length -gt 10000)) { return $p }
  }
  return $null
}

if ($SelfTest) {
  $f = 0
  function T($m, $c, $gv) { if ($c) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $gv); $script:f++ } }
  $exe = Get-PythonExe
  T 'a REAL python is found (not the 0-byte Store alias)' ($exe -and (Get-Item $exe).Length -gt 10000) "$exe"
  T 'sqlite3 is importable and enforces foreign keys' `
    ((& $exe -c "import sqlite3;c=sqlite3.connect(':memory:');c.execute('PRAGMA foreign_keys=ON');print(c.execute('PRAGMA foreign_keys').fetchone()[0])") -eq '1') 'fk pragma did not stick'
  T 'the schema and builder are both present' ((Test-Path (Join-Path $mp 'db\schema.sql')) -and (Test-Path (Join-Path $mp 'db\build_db.py'))) 'missing'
  if ($f -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $f case(s)"; exit 1 }
}

$py = Get-PythonExe
if (-not $py) {
  Write-Output '  ! DB BUILD SKIPPED: no real Python found (the `python` on PATH is a 0-byte Store alias).'
  Write-Output '    Install with: winget install --id Python.Python.3.12 --scope user'
  exit 3            # the estate's could-not-evaluate code: proves nothing, must not read as clean
}

$argsList = @((Join-Path $mp 'db\build_db.py'), '--mp', $mp, '--grocery', $g)
if ($VerifyOnly) { $argsList += '--verify-only' }
$out = & $py @argsList
$rc = $LASTEXITCODE
foreach ($l in @($out)) { Write-Output ("  " + $l) }
if ($rc -ne 0) {
  Write-Output '  ! a write was REFUSED by a database constraint - see the named row above'
  exit 1
}
exit 0
