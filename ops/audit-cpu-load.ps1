<#
  audit-cpu-load.ps1 - a committed script that starts CPU burners takes its cores from the machine-wide budget.

  WHY THIS EXISTS (2026-09-11, Brad: "fix the code so it doesnt do this again and honors the cap"). Sessions
  fixing tests that fail under load kept building their own load to reproduce it - 32 Python burners, then
  run-gates three at a time back to back, then 32 more burners, then an endless run-gates loop - and the shared
  32-processor box sat at 100% for over an hour. run-gates already takes a share of a machine-wide budget of 10
  (lib\gate-slots.ps1). ops\cpu-load.ps1 is the sanctioned way to add load, drawing on that same budget. This
  gate holds the line for committed code: burners started any other way are a finding.

  THE RULE. A .ps1 or .py whose CODE both names a burner and launches a process either runs ops\cpu-load.ps1 or
  takes its slots itself with Enter-TcGateSlots -Exact.

  SCOPE OF A CLEAN REPORT: UNSOUND. A burner is recognised by its spelling: the word burner or burners, a file
  called burn.py, Python's endless `iter(int, 1)` generator, `while True: pass`, or an empty PowerShell
  `while ($true) {}`. A launch is Start-Process, a ProcessStartInfo, Process.Start, Start-Job, subprocess,
  multiprocessing or os.system. A busy loop under any other name, launched any other way, is not seen. It
  checks the compliant call is PRESENT in the file, not that the burners run inside it. PowerShell comments are
  stripped before matching; in Python only whole-line comments are, so a docstring naming burners in a file that
  also launches processes can be a false finding. SCRATCH SCRIPTS OUTSIDE THE REPO, where every burner of
  2026-09-11 lived, are out of reach entirely - for those the CLAUDE.md rule is the whole prevention. \out\,
  \archive\ and worktrees below the root are not scanned. A reported finding is real.

  Exit 0 clean, 1 a script starts burners outside the budget, 2 self-test regression, 3 BLIND (no scripts, or no
  burner-starting script at all - ops\cpu-load.ps1 is one, so zero is the matcher broken, not the tree clean).
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\tree-walk.ps1')     # Get-TcPathBelowRoot: exclusions match below the root, so a worktree root is scanned
. (Join-Path $repo 'lib\ps-source.ps1')     # Get-PsCodeOnly: prose about a burner is not a burner

$script:BurnerRx = @(
  '(?i)\bburners?\b',
  '(?i)\bburn\.py\b',
  'iter\(\s*int\s*,\s*1\s*\)',
  '(?m)while\s+(?:True|1)\s*:\s*pass\b',
  '(?i)while\s*\(\s*\$true\s*\)\s*\{\s*\}'
)
$script:LaunchRx = '(?i)\bStart-Process\b|ProcessStartInfo|\[Diagnostics\.Process\]::Start|\bStart-Job\b|\bsubprocess\.|\bmultiprocessing\b|\bos\.system\('
$script:CompliantRx = '(?i)\bcpu-load\.ps1\b|(?<!function\s+)\bEnter-TcGateSlots\b[^\r\n]*-Exact\b'

function Get-CodeText {
  <# The code of one file, prose removed: Get-PsCodeOnly for PowerShell, whole-line # comments for Python. #>
  param([string]$Text, [string]$Extension)
  if ($Extension -ieq '.py') {
    return (($Text -split "`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
  }
  return (Get-PsCodeOnly -Text $Text)
}

function Get-CpuLoadState {
  <# Pure over one file's text, so the self-test drives the rule the live scan uses. Starts = the code names a
     burner AND launches a process; Honors = it runs cpu-load.ps1 or takes slots with Enter-TcGateSlots -Exact;
     Line = the first burner line, trimmed. #>
  param([string]$Text, [string]$Extension = '.ps1')
  $code = Get-CodeText -Text $Text -Extension $Extension
  $burnLine = ''
  foreach ($l in ($code -split "`n")) {
    foreach ($rx in $script:BurnerRx) { if ($l -match $rx) { $burnLine = $l.Trim(); break } }
    if ($burnLine) { break }
  }
  $launches = [bool]($code -match $script:LaunchRx)
  return [pscustomobject]@{
    Starts = ([bool]$burnLine -and $launches)
    Honors = [bool]($code -match $script:CompliantRx)
    Line   = $burnLine
  }
}

function Get-CpuLoadScripts {
  <# Every .ps1 and .py under $RootDir except $Self, excluded on the path BELOW the root (lib\tree-walk.ps1). #>
  param([string]$RootDir, [string]$Self = '')
  $rootFull = Get-TcRootFull $RootDir
  Get-ChildItem $rootFull -Recurse -File -Include *.ps1, *.py -ErrorAction SilentlyContinue |
    Where-Object { ($_.Extension -ieq '.ps1' -or $_.Extension -ieq '.py') -and $_.FullName -ne $Self -and
                   (Get-TcPathBelowRoot $_.FullName $rootFull) -notmatch '\\worktrees\\|\\archive\\|node_modules|\\\.venv\\|\\\.git\\|\\out\\' } |
    Sort-Object FullName
}

if ($SelfTest) {
  $ErrorActionPreference = 'Continue'
  $fail = 0; $cases = 0
  function T([string]$m, [bool]$c, [string]$got = '') {
    $script:cases++
    if ($c) { Write-Output ('  ok    ' + $m) } else { Write-Output ('  FAIL  ' + $m + '   got: ' + $got); $script:fail++ }
  }
  # NEEDLES ARE BUILT BY CONCATENATION, so this file's own source never spells a burner it looks for.
  $bw = 'bur' + 'ners'
  $iterInt = 'it' + 'er(int, 1)'
  # The two harness shapes of 2026-09-11, cut down to their launching lines.
  $tMontalcini = 'param([int]$' + $bw + ' = 32)' + "`n" + 'foreach ($b in 1..$' + $bw + ') { $procs += Start-Process -FilePath python.exe -ArgumentList @((Join-Path $sp ''bu' + 'rn.py''), $stop) -PassThru }'
  $tLichterman = '$psi = New-Object Diagnostics.ProcessStartInfo' + "`n" + '$psi.Arguments = ''-c "import time; e=time.time()+900; any(time.time()>e for _ in ' + $iterInt + ')"''' + "`n" + '[Diagnostics.Process]::Start($psi)'
  $tPy = 'import subprocess' + "`n" + 'for _ in range(32):' + "`n" + '    subprocess.Popen(["python", "-c", "while True: pa' + 'ss"])'
  $tPsLoop = 'Start-Job { wh' + 'ile ($true) {} }'

  $s = Get-CpuLoadState -Text $tMontalcini
  T 'MUST FIRE  THE ONE THIS EXISTS FOR - N burners launched with Start-Process from a -Burners loop, outside the budget' ($s.Starts -and -not $s.Honors) ("starts=$($s.Starts) honors=$($s.Honors)")
  $s = Get-CpuLoadState -Text $tLichterman
  T 'MUST FIRE  an inline Python iter(int, 1) burner started through a ProcessStartInfo' ($s.Starts -and -not $s.Honors) ("starts=$($s.Starts) honors=$($s.Honors)")
  $s = Get-CpuLoadState -Text $tPy -Extension '.py'
  T 'MUST FIRE  a .py that spawns while-True-pass children through subprocess' ($s.Starts -and -not $s.Honors) ("starts=$($s.Starts) honors=$($s.Honors)")
  $s = Get-CpuLoadState -Text $tPsLoop
  T 'MUST FIRE  an empty endless PowerShell loop in a Start-Job' ($s.Starts -and -not $s.Honors) ("starts=$($s.Starts) honors=$($s.Honors)")
  $tCommentOk = '# runs ops\cpu' + '-load.ps1 somewhere else' + "`n" + $tMontalcini
  $s = Get-CpuLoadState -Text $tCommentOk
  T 'MUST FIRE  naming cpu-load.ps1 only in a COMMENT does not make the burners honor the budget' ($s.Starts -and -not $s.Honors) ("starts=$($s.Starts) honors=$($s.Honors)")
  $tNoExact = 'Enter-TcGate' + 'Slots -Want 4' + "`n" + $tMontalcini
  $s = Get-CpuLoadState -Text $tNoExact
  T 'MUST FIRE  taking slots WITHOUT -Exact does not count - a partial grant would run fewer burners than the rows claim' ($s.Starts -and -not $s.Honors) ("starts=$($s.Starts) honors=$($s.Honors)")

  $tCaller = '& powershell -NoProfile -File (Join-Path $repo ''ops\cpu' + '-load.ps1'') -Cores 4 -Seconds 300 -ReadyFile $rf' + "`n" + 'Start-Process powershell -ArgumentList $x'
  $s = Get-CpuLoadState -Text $tCaller
  T 'MUST NOT FIRE  a harness that gets its load from cpu-load.ps1 is not a finding' (-not ($s.Starts -and -not $s.Honors)) ("starts=$($s.Starts) honors=$($s.Honors)")
  $tExact = '$lease = Enter-TcGate' + 'Slots -Want $Cores -Exact -WaitSec 600' + "`n" + $tMontalcini
  $s = Get-CpuLoadState -Text $tExact
  T 'MUST NOT FIRE  burners launched after taking their cores with Enter-TcGateSlots -Exact are not a finding' (-not ($s.Starts -and -not $s.Honors)) ("starts=$($s.Starts) honors=$($s.Honors)")
  T 'CLEAN TWIN  that file is still COUNTED as one that starts burners, so the live floor includes it' ($s.Starts) ("starts=$($s.Starts)")
  T 'CLEAN TWIN  the reported line is the first burner line itself, trimmed' ($s.Line -eq ('param([int]$' + $bw + ' = 32)')) $s.Line
  $tProse = '# measured under 32 CPU ' + $bw + ' with every writer''s output kept' + "`n" + 'Start-Process powershell -ArgumentList $a'
  $s = Get-CpuLoadState -Text $tProse
  T 'MUST NOT FIRE  burners named only in a comment, in a file that launches processes, are prose (the ledgers'' measurement notes)' (-not $s.Starts) ("starts=$($s.Starts)")
  $tReel = '& ffmpeg -i $in -vf "subtitles=$srt" -c:a copy $out   # bu' + 'rn-in captions' + "`n" + '$p = Start-Process ffmpeg -ArgumentList $a -PassThru' + "`n" + '$burnIn = $true'
  $s = Get-CpuLoadState -Text $tReel
  T 'MUST NOT FIRE  burning captions into a video is not a CPU burner (media\reels)' (-not $s.Starts) ("starts=$($s.Starts) line=$($s.Line)")
  $tNoLaunch = '$' + $bw + ' = 32   # a parameter nobody launches'
  $s = Get-CpuLoadState -Text $tNoLaunch
  T 'MUST NOT FIRE  naming burners without launching any process starts nothing' (-not $s.Starts) ("starts=$($s.Starts)")
  $tDaemon = 'import subprocess, time' + "`n" + 'while True:' + "`n" + '    time.sleep(5)' + "`n" + '    subprocess.run(["git", "status"])'
  $s = Get-CpuLoadState -Text $tDaemon -Extension '.py'
  T 'MUST NOT FIRE  a Python daemon whose while True loop sleeps is not a burner' (-not $s.Starts) ("starts=$($s.Starts)")

  # ---- A WORKTREE ROOT IS SCANNED AND A SIBLING BELOW IT IS NOT (lib\tree-walk.ps1) ----
  $wtFx = New-TcWorktreeFixture -Files @{ 'ops\a.ps1' = 'Write-Output 1'; 'grocery\b.py' = 'print(2)' }
  try {
    $found = Get-CpuLoadScripts -RootDir $wtFx.Root
    $found = @($found)
    $hits = Measure-TcWorktreeFixture -Fixture $wtFx -Found $found
    T 'MUST FIRE  a root that IS a worktree is scanned, .ps1 and .py both, not excluded whole' ($hits.Root -eq 2) ("root=" + $hits.Root)
    T 'MUST NOT FIRE  a sibling worktree BELOW that root is still excluded' ($hits.Sibling -eq 0) ("sibling=" + $hits.Sibling)
  } finally { Remove-Item -LiteralPath $wtFx.Temp -Recurse -Force -ErrorAction SilentlyContinue }

  # ---- THE SANCTIONED TOOL IS ITSELF A BURNER-STARTER THAT HONORS THE BUDGET, or the live floor means nothing ----
  $tool = Join-Path $repo 'ops\cpu-load.ps1'
  if (Test-Path -LiteralPath $tool) {
    $s = Get-CpuLoadState -Text ([IO.File]::ReadAllText($tool))
    T 'CLEAN TWIN  ops\cpu-load.ps1 is recognised as starting burners AND as honoring the budget' ($s.Starts -and $s.Honors) ("starts=$($s.Starts) honors=$($s.Honors)")
  } else {
    T 'ops\cpu-load.ps1 exists to be recognised' $false 'missing'
  }

  ''
  if ($fail) {
    Write-Output ("cpu-load audit selftest: $fail FAILED of $cases")
    Exit-Guard -Name 'CPU-LOAD-AUDIT-SELFTEST' -Code 2 -Summary "failed=$fail of $cases"
  }
  Write-Output ("cpu-load audit selftest: $cases of $cases cases pass")
  Exit-Guard -Name 'CPU-LOAD-AUDIT-SELFTEST' -Code 0 -Summary "cases=$cases"
}

# ---- live path: every .ps1 and .py in the tree ---------------------------------------------------------
$rootFull = Get-TcRootFull $repo
$files = Get-CpuLoadScripts -RootDir $repo -Self $PSCommandPath
$files = @($files)
if (-not $files.Count) {
  Write-Output 'audit-cpu-load: BLIND - found no .ps1 or .py to scan, which means this discovery is broken, not that the tree is clean'
  Exit-Guard -Name 'AUDIT-CPU-LOAD' -Code 3 -Summary 'blind=no-scripts'
}
$starters = 0
$findings = New-Object System.Collections.ArrayList
foreach ($f in $files) {
  $st = Get-CpuLoadState -Text ([IO.File]::ReadAllText($f.FullName)) -Extension $f.Extension
  if (-not $st.Starts) { continue }
  $starters++
  if (-not $st.Honors) { [void]$findings.Add(((Get-TcPathBelowRoot $f.FullName $rootFull).TrimStart('\') + '   ' + $st.Line)) }
}
# A FLOOR THAT FIRES ON NOTHING HAPPENING (ops-and-gates, backlog I80). ops\cpu-load.ps1 starts burners by
# design, so a scan that recognises no burner-starter at all is the matcher broken, not the tree clean.
if ($starters -eq 0) {
  Write-Output ("audit-cpu-load: BLIND - scanned {0} scripts and recognised NO burner-starter; ops\cpu-load.ps1 is one, so the matcher is broken, not the tree clean" -f $files.Count)
  Exit-Guard -Name 'AUDIT-CPU-LOAD' -Code 3 -Summary ("blind=no-starters scanned={0}" -f $files.Count)
}
Write-Output ("audit-cpu-load: {0} .ps1/.py scanned, {1} start CPU burners, {2} of those take no cores from the machine-wide budget" -f $files.Count, $starters, $findings.Count)
foreach ($x in $findings) { Write-Output ('  ! ' + $x) }
if ($findings.Count) {
  Write-Output '  This box is shared by every session and every push''s gate: on 2026-09-11 load tests like this held it at 100% for over an hour.'
  Write-Output '  Fix: get the load from ops\cpu-load.ps1 -Cores N -Seconds S, or take the cores with Enter-TcGateSlots -Exact first.'
  Exit-Guard -Name 'AUDIT-CPU-LOAD' -Code 1 -Summary ("findings={0} starters={1} scanned={2}" -f $findings.Count, $starters, $files.Count)
}
Exit-Guard -Name 'AUDIT-CPU-LOAD' -Code 0 -Summary ("findings=0 starters={0} scanned={1}" -f $starters, $files.Count)
