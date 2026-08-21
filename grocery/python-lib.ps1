<#
  python-lib.ps1 - WHERE IS PYTHON? Asked once, answered in one place.

  WHY THIS EXISTS. On 2026-08-21 I searched for a Python interpreter, looked in C:\Codex\tools but not
  in C:\Codex itself, found nothing, and told Brad the machine had no Python and that graduating graph\
  would mean installing it. All of that was wrong: Python 3.12.10 sits at C:\Codex\Python312. A hunt
  that ends in the wrong answer is worse than no hunt, because the wrong answer gets built on - and it
  was, for several minutes, as advice about a real decision.

  SO THIS DISCOVERS RATHER THAN HARDCODES, in this order:
      1. an explicit path the caller passed          - always wins, for pinning and for tests
      2. the Windows registry (HKCU/HKLM PythonCore) - what an installer actually recorded
      3. known install locations                     - C:\Codex\Python312 and the usual suspects
      4. PATH                                        - last, and only a REAL python
  The registry comes before the known path deliberately. Brad said "feel free to move it if its causing
  problems", so a hardcoded literal would break the day he does exactly that, and would break silently:
  the caller would report BLIND and everything downstream would read it as "the check could not run"
  rather than "the path is stale".

  THE PATH ENTRY IS A TRAP AND IS HANDLED. On Windows, `python.exe` on PATH is very often the Microsoft
  Store alias stub in WindowsApps - it exists, it is executable, and running it prints "Python was not
  found" and exits non-zero. Something that merely tests for existence will happily return it. So PATH
  candidates are EXECUTED and must actually answer with a version string before they are believed.

  IT DOES NOT TOUCH THE SIDECAR'S PYTHON. sidecar\.venv\Scripts\python.exe is a virtual environment
  carrying that tool's own ML dependencies; audit-semantic-identity resolves it itself and ran clean on
  2026-08-21. A "one python to rule them all" refactor would put graph's imports and the sidecar's GPU
  stack in the same interpreter, which is the opposite of what a venv is for. Two interpreters, two
  purposes, and this library is only the answer for the first.

  Usage:
      . python-lib.ps1
      $py = Get-GraphPython                # -> full path, or '' if there genuinely is none
      if (-not $py) { ...report BLIND, never block... }
#>

function Test-RealPython {
  <#
    .SYNOPSIS Does this path run and identify itself as Python?
    .DESCRIPTION Existence is not enough - see the WindowsApps stub note in the header. This RUNS it.
  #>
  param([string]$Path)
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $false }
  # The Store alias lives under WindowsApps and is never a real interpreter.
  if ($Path -match '(?i)\\WindowsApps\\') { return $false }
  try {
    $v = & $Path --version 2>&1
    return ([string]$v -match '(?i)^Python\s+\d+\.\d+')
  } catch { return $false }
}

function Get-GraphPython {
  <#
    .SYNOPSIS The interpreter that runs graph\. Returns '' when there genuinely is not one.
    .DESCRIPTION Returns EMPTY rather than throwing, because every caller of this must degrade to BLIND
                 and let the board publish. A missing interpreter is a reason to skip a check, never a
                 reason to stop the pipeline - the same rule audit-semantic-identity already follows.
  #>
  param([string]$Explicit = '')
  if ($Explicit) { if (Test-RealPython $Explicit) { return $Explicit } else { return '' } }

  # 2. the registry - what an installer actually recorded, and it survives Brad moving the folder
  foreach ($hive in @('HKCU:\SOFTWARE\Python\PythonCore', 'HKLM:\SOFTWARE\Python\PythonCore')) {
    if (-not (Test-Path $hive)) { continue }
    # Newest version first: 3.13 before 3.12. Sorted as text, which is wrong at 3.9 -> 3.10, so pad.
    $vers = @(Get-ChildItem $hive -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName } |
              Sort-Object -Property @{ e = { $p = ($_ -split '\.'); '{0:d4}.{1:d4}' -f [int]$p[0], [int]($p[1]) } } -Descending)
    foreach ($v in $vers) {
      $k = Join-Path $hive "$v\InstallPath"
      if (-not (Test-Path $k)) { continue }
      try {
        $props = Get-ItemProperty -Path $k -ErrorAction Stop
        $exe = [string]$props.ExecutablePath
        if (-not $exe -and $props.'(default)') { $exe = Join-Path ([string]$props.'(default)') 'python.exe' }
        if (Test-RealPython $exe) { return $exe }
      } catch { }
    }
  }

  # 3. known locations
  foreach ($p in @(
      'C:\Codex\Python312\python.exe', 'C:\Codex\Python313\python.exe', 'C:\Codex\Python311\python.exe',
      'C:\Python312\python.exe', 'C:\Python313\python.exe', 'C:\Python311\python.exe')) {
    if (Test-RealPython $p) { return $p }
  }

  # 4. PATH, last, and only if it really answers
  try {
    foreach ($c in @(Get-Command python.exe, python -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })) {
      if (Test-RealPython $c) { return $c }
    }
  } catch { }

  return ''
}
