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

  # ---- THE ALIAS RESOLUTION, frozen against the row that motivated it ------------------------------------
  # 2026-08-28: this build refused baked-cauliflower-mac-smoked-sausage because the spec costs "Smoked
  # Sausage" and item(name) held only row names. That string is not a missing row, it is an ALIAS on the
  # Pork Smoked Sausage row - an adjudicated identity every other reader in the estate already resolves.
  # The fix taught this builder the same rule, so the rule is pinned HERE, in fixtures, not only in the
  # live data: delete build_alias_map or resolve_item and these cases go red without needing 587 specs.
  # Ruling 9 (Brad, 2026-08-16) is one of them: the smoked-sausage aliases land on PORK, never on Smoked
  # Turkey Sausage, because stamping protein off the turkey row would corrupt every recipe that uses it.
  # NO DOUBLE QUOTES IN THIS PROBE. PowerShell strips them when it hands a string to a native exe, so a
  # double-quoted Python literal arrives as a bare word and the probe dies with a SyntaxError - which reads
  # as nine failing cases about aliases rather than one about quoting.
  $probe = @'
import sys
sys.path.insert(0, sys.argv[1])
import build_db as b
fx  = [{'item': 'Pork Smoked Sausage', 'bid': 'kielbasa', 'aliases': ['Smoked Sausage', 'Andouille Smoked Sausage']},
       {'item': 'Smoked Turkey Sausage', 'bid': 'turkey-sausage'},
       {'item': 'Salt', 'bid': 'salt'},
       {'item': '_r300_note', 'aliases': ['Smoked Sausage']}]
names = set(r['item'] for r in fx if not r['item'].startswith('_'))
m, contested = b.build_alias_map(fx)
out = [str(b.resolve_item('Smoked Sausage', names, m)),
       str(b.resolve_item('Andouille Smoked Sausage', names, m)),
       str(b.resolve_item('Salt', names, m)),
       str(b.resolve_item('Unicorn Loin', names, m)),
       str(len(m)), str(len(contested))]
fx2 = [{'item': 'Broccoli'}, {'item': 'Broccoli Florets', 'aliases': ['Broccoli']}]
m2, _ = b.build_alias_map(fx2)
out.append(str(b.resolve_item('Broccoli', set(['Broccoli', 'Broccoli Florets']), m2)))
m3, c3 = b.build_alias_map([{'item': 'A', 'aliases': ['X']}, {'item': 'B', 'aliases': ['X']}])
out.append(str(len(c3)))
print('|'.join(out))
'@
  $r = @((& $exe -c $probe (Join-Path $mp 'db')) -split '\|')
  if ($r.Count -ne 8) { T 'the alias probe ran at all' $false ("got " + ($r -join '|')); $r = @('', '', '', '', '', '', '', '') }
  T 'CLEAN TWIN a spec costing by an ALIAS resolves to its price row'     ($r[0] -eq 'Pork Smoked Sausage') $r[0]
  T 'RULING 9   the smoked-sausage aliases land on PORK, not turkey'      ($r[1] -eq 'Pork Smoked Sausage') $r[1]
  T 'CLEAN TWIN a plain row name still resolves to itself'                ($r[2] -eq 'Salt') $r[2]
  T 'MUST FIRE  a name that is neither row nor alias resolves to nothing' ($r[3] -eq 'None') $r[3]
  T 'a comment row owns no aliases'                                       ($r[4] -eq '2') $r[4]
  T 'an uncontested alias map reports no contest'                         ($r[5] -eq '0') $r[5]
  T 'a ROW NAME wins over another row claiming it as an alias'            ($r[6] -eq 'Broccoli') $r[6]
  T 'MUST FIRE  one alias claimed by two rows is reported contested'      ($r[7] -eq '1') $r[7]

  # ---- and the whole build, end to end, over the live stores (verify-only: writes nothing) ---------------
  # The fixtures prove the rule; this proves the rule is WIRED IN. A build that still refuses a real
  # alias-costed spec fails here even with every fixture green.
  $g2 = Join-Path (Split-Path $mp -Parent) 'grocery'
  if (Test-Path (Join-Path $g2 'out\smp-feed.json')) {
    # $ErrorActionPreference IS 'Stop' UP THERE, AND 2>&1 ON A NATIVE EXE IS A TRAP UNDER IT. PowerShell
    # 5.1 wraps each stderr line from a native command in an ErrorRecord, which under Stop THROWS - so a
    # build that correctly refused a row killed this script mid-case instead of reporting a red one. The
    # refusal text is the whole point of the case, so relax the preference across the call, not the check.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $bout = & $exe (Join-Path $mp 'db\build_db.py') --mp $mp --grocery $g2 --verify-only 2>&1
    $brc = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP
    T 'the live build accepts every alias-costed spec' ($brc -eq 0) (@($bout | ForEach-Object { [string]$_ }) -join ' ' -replace '\s+', ' ')
    T 'the build materialises the alias namespace'     ([bool](@($bout) -match 'item_alias')) 'no item_alias count in the report'
  } else {
    # NOT A PASS. smp-feed.json is a build output, absent in a fresh clone or a worktree; without it the
    # commodity namespace collapses to the roster and ~900 real bids read as broken. Saying so beats a
    # green tick that measured nothing.
    Write-Output '  (skipped the end-to-end case: no grocery\out\smp-feed.json in this tree)'
  }
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
