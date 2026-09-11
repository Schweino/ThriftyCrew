<#
  audit-bare-replace.ps1 - a temp file moved over a live file goes through lib\atomic-write.ps1.

  SCOPE OF A CLEAN REPORT: UNSOUND, and a RATCHET rather than a proof for exactly that reason. It finds
    `Move-Item ... -Force` commands in parsed PowerShell. A clean report means no NEW such command exists
    outside the helper. It cannot see a Force passed by splatting, a move performed through [IO.File] or
    Python, or a caller that invokes Move-Item by a name held in a variable.

  WHY THIS EXISTS (2026-09-11). While any process holds a file open without FILE_SHARE_DELETE - and
  Get-Content, [IO.File]::ReadAllText, Python's open() and lib\json-io.ps1 all open that way - a
  `Move-Item tmp dest -Force` over it is REFUSED, and that write is lost. Under the default
  ErrorActionPreference the refusal does not even throw: the script carries on as if the write landed.
  lib\atomic-write.ps1's Write-TcAtomicFile waits a reader out for a bounded time and throws when it cannot;
  a site whose bytes were BOM-less passes -NoBom -NoNewline.
  Twenty-seven files carried the bare form the day this was written.

  WHAT IT COUNTS: every Move-Item command (or its aliases move, mv, mi) carrying -Force, outside the helper
  itself. That includes moves into an archive directory, which are not replaces of a live file - they are
  counted anyway, because the only thing -Force adds to a move is permission to replace an existing file,
  and the command cannot tell a log nobody reads from a ledger a daemon polls. A line that is a deliberate
  exception says so with `# atomic-replace:allow <reason>` on the command's first line.

  RATCHET, NOT A HARD FAIL, for the reason ops-and-gates.md gives: the sites nobody is about to convert
  would make it red on day one. The baseline is a HIGH-WATER MARK that may only go DOWN, through
  lib\ratchet.ps1, so a detector that suddenly finds nothing KEEPS the old mark instead of recording 0.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 hard finding, 3 could-not-evaluate.
  Read the verdict LINE, not the number.

  Self-test: powershell -File ops\audit-bare-replace.ps1 -SelfTest
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param([switch]$SelfTest, [switch]$AcceptDrop)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ratchet.ps1')
. (Join-Path $repo 'lib\tree-walk.ps1')   # exclusions match below the root, so a worktree root is not excluded whole

$BASELINE_FILE = Join-Path $repo 'ops\bare-replace-baseline.json'

# The helper itself, plus the trees run-gates excludes everywhere else.
$EXCLUDE = '\\archive\\|\\worktrees\\|\\out\\|node_modules|\\lib\\atomic-write\.ps1$'
$MOVE_NAMES = @('move-item', 'move', 'mv', 'mi')

function Get-TcBareReplaceLines {
  <# Pure: the 1-based line numbers of every Move-Item -Force command in $Text, skipping allow-marked ones.
     PARSED, NOT MATCHED. The parser already knows a comment, a string and a here-string from a command, and
     it joins a backtick continuation, so none of those needs a regex of its own here. #>
  param([string]$Text)
  $tokens = $null; $errs = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errs)
  $lines = $Text -split "`r?`n"
  $found = @()
  $cmds = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] }, $true)
  foreach ($c in @($cmds)) {
    $name = $c.GetCommandName()
    if (-not $name -or ($MOVE_NAMES -notcontains $name.ToLower())) { continue }
    $forced = $false
    foreach ($el in @($c.CommandElements)) {
      if ($el -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
      # -Fo, -For, -Forc, -Force: PowerShell accepts any unambiguous prefix. A lone -F is ambiguous with
      # -Filter on Move-Item and does not run at all, so it is not counted.
      if ($el.ParameterName -notmatch '(?i)^fo(r(ce?)?)?$') { continue }
      # -Force:$false forces nothing.
      if ($el.Argument -and $el.Argument.Extent.Text -match '(?i)^\$false$') { continue }
      $forced = $true
    }
    if (-not $forced) { continue }
    $ln = $c.Extent.StartLineNumber
    if ($ln -ge 1 -and $ln -le $lines.Count -and $lines[$ln - 1] -match 'atomic-replace:allow') { continue }
    $found += $ln
  }
  return ,@($found)
}

function Get-BareReplaceScanFiles {
  <# Every .ps1 the live run reads under $RootDir, never $Self. $EXCLUDE matches the path BELOW the root
     (lib\tree-walk.ps1), so a root that is itself a linked worktree is scanned rather than excluded whole. #>
  param([string]$RootDir, [string]$Self = '')
  $rootFull = Get-TcRootFull $RootDir
  Get-ChildItem $rootFull -Recurse -File -Filter *.ps1 -ErrorAction SilentlyContinue |
    Where-Object { (Get-TcPathBelowRoot $_.FullName $rootFull) -notmatch $EXCLUDE -and $_.FullName -ne $Self } |
    ForEach-Object { $_.FullName }
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0; $n = 0
  function T($m, $cond, $got) { $script:n++; if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }
  function Count-Hits([string]$Text) { $r = Get-TcBareReplaceLines -Text $Text; return @($r).Count }

  # MUST FIRE - the shapes the live tree carried the day this was written.
  T 'MUST FIRE  the named-parameter temp-then-rename form' `
    ((Count-Hits 'Move-Item -Path $tmpf -Destination $Store -Force') -eq 1) 'missed'
  T 'MUST FIRE  the positional form' `
    ((Count-Hits 'Move-Item $tmpS $SuppressionsFile -Force') -eq 1) 'missed'
  T 'MUST FIRE  a Move-Item at the end of a pipeline' `
    ((Count-Hits 'Get-ChildItem -Path $GenDir -Filter *.html -File | Move-Item -Destination $doneDir -Force') -eq 1) 'missed'
  T 'MUST FIRE  -Force on a backtick-continued line' `
    ((Count-Hits ('Move-Item -LiteralPath $tmp -Destination $ledger ' + [char]96 + "`n  -Force")) -eq 1) 'a continuation hid it'
  T 'MUST FIRE  the mv alias with an abbreviated -Forc' `
    ((Count-Hits 'mv $a $b -Forc') -eq 1) 'missed'
  T 'MUST FIRE  -Force:$true still forces' `
    ((Count-Hits 'Move-Item $a $b -Force:$true') -eq 1) 'missed'

  # MUST NOT FIRE - legal inputs the matcher must stay silent on.
  T 'MUST NOT FIRE  a Move-Item without -Force cannot replace a file' `
    ((Count-Hits 'Move-Item $a $b') -eq 0) 'counted'
  T 'MUST NOT FIRE  a comment describing the bare form' `
    ((Count-Hits '# the old code did Move-Item $tmp $dest -Force here') -eq 0) 'a comment was counted'
  T 'MUST NOT FIRE  a string carrying the bare form' `
    ((Count-Hits '$fixture = ''Move-Item $tmp $dest -Force''') -eq 0) 'a string was counted'
  T 'MUST NOT FIRE  a here-string carrying the bare form' `
    ((Count-Hits ("`$h = @'`nMove-Item `$tmp `$dest -Force`n'@")) -eq 0) 'a here-string was counted'
  T 'MUST NOT FIRE  a line marked atomic-replace:allow' `
    ((Count-Hits 'Move-Item $d $arch -Force   # atomic-replace:allow archive of a log nobody holds open') -eq 0) 'the marker was ignored'
  T 'MUST NOT FIRE  Copy-Item -Force is a different command' `
    ((Count-Hits 'Copy-Item $a $b -Force') -eq 0) 'counted'
  T 'MUST NOT FIRE  the helper call itself' `
    ((Count-Hits 'Write-TcAtomicFile -Path $dest -Text $json -NoBom -NoNewline') -eq 0) 'counted'
  T 'MUST NOT FIRE  -Force:$false' `
    ((Count-Hits 'Move-Item $a $b -Force:$false') -eq 0) 'counted'

  # CLEAN TWIN - line reporting still works with an allowed line and a comment around a real site.
  $mixed = "`$x = 1`n# Move-Item `$a `$b -Force`nMove-Item `$d `$arch -Force # atomic-replace:allow archive`nMove-Item -Path `$t -Destination `$p -Force"
  $ml = Get-TcBareReplaceLines -Text $mixed
  T 'CLEAN TWIN  the one real site is reported at its own line, 4' ((@($ml).Count -eq 1) -and ($ml[0] -eq 4)) ("lines=" + (@($ml) -join ','))
  T 'MUST FIRE  a single finding comes back as an ARRAY, not unrolled to a bare number' ($ml -is [array]) ($ml.GetType().FullName)

  # THE WALK, FROM A WORKTREE ROOT (lib\tree-walk.ps1): the root is scanned, a sibling below it is not.
  $wtFx = New-TcWorktreeFixture -Files @{ 'grocery\a.ps1' = 'Move-Item $t $p -Force'; 'lib\atomic-write.ps1' = 'Move-Item $t $p -Force' }
  try {
    $wtFound = @(Get-BareReplaceScanFiles -RootDir $wtFx.Root)
    $wtHits = Measure-TcWorktreeFixture -Fixture $wtFx -Found $wtFound
    $wtNames = @($wtFound | Where-Object { ([string]$_).StartsWith($wtFx.Root + '\', [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { Split-Path $_ -Leaf })
    T 'MUST FIRE  a root that IS a worktree is scanned, not excluded whole' ($wtNames -contains 'a.ps1') ("root files=" + ($wtNames -join ','))
    T 'MUST NOT FIRE  the helper lib\atomic-write.ps1 is not scanned - it is the one sanctioned Move-Item -Force' ($wtNames -notcontains 'atomic-write.ps1') ("root files=" + ($wtNames -join ','))
    T 'MUST NOT FIRE  a sibling worktree below that root is excluded' ($wtHits.Sibling -eq 0) ("sibling=" + $wtHits.Sibling)
  } finally { Remove-Item -LiteralPath $wtFx.Temp -Recurse -Force -ErrorAction SilentlyContinue }

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} of {1} check(s)" -f $f, $n); exit 1 }
  Write-Output ("SELF-TEST PASS: {0} checks - 6 must-fire shapes, 8 must-not-fire inputs, line reporting and return arity, and the walk from a worktree root" -f $n)
  exit 0
}

# ------------------------------------------------------------------------------------- live run
# NEVER SCAN YOURSELF, by the rule audit-write-seam states. The parser would not count the fixtures above
# (they are strings), so this is convention rather than necessity here, and it costs nothing.
$files = @(Get-BareReplaceScanFiles -RootDir $repo -Self $PSCommandPath)
if (-not $files.Count) {
  Write-Output 'BARE-REPLACE AUDIT BLIND: found zero .ps1 files to scan, which means the discovery is broken rather than the tree being clean.'
  Exit-Guard -Name 'bare-replace' -Summary 'blind=no-files' -Code 3
}
$hits = @()
foreach ($p in $files) {
  $found = Get-TcBareReplaceLines -Text ([IO.File]::ReadAllText($p))
  foreach ($ln in @($found)) { $hits += [pscustomobject]@{ File = $p; Line = $ln } }
}
$count = $hits.Count

if (-not (Test-Path -LiteralPath $BASELINE_FILE)) {
  # The day-one count goes into the history as well, so every later fall is read against what was first measured.
  $hist = Add-RatchetHistory -Doc ([pscustomobject]@{}) -Count $count
  $doc = [pscustomobject]@{ generated = (Get-Date).ToString('s'); sites = $count; history = $hist
    note = 'HIGH-WATER MARK for Move-Item -Force commands outside lib\atomic-write.ps1. This number may only go DOWN. A run above it is a NEW bare replace and hard-fails.' }
  # LF, no BOM: PS 5.1's ConvertTo-Json writes CRLF, and main is LF (a CRLF flip is invisible in git diff).
  [IO.File]::WriteAllText($BASELINE_FILE, (($doc | ConvertTo-Json -Depth 5) -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
  Write-Output ("bare-replace: baseline written at {0} site(s) over {1} file(s). From here the number may only go DOWN." -f $count, $files.Count)
  Exit-Guard -Name 'bare-replace' -Summary ("scanned={0} baseline={1}" -f $files.Count, $count) -Code 0
}
$base = [int]((Get-Content $BASELINE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json).sites)

foreach ($h in ($hits | Sort-Object File, Line)) {
  Write-Output ("  bare  {0}:{1}" -f (Get-TcPathBelowRoot $h.File (Get-TcRootFull $repo)).TrimStart('\'), $h.Line)
}
if ($count -gt $base) {
  Write-Output ("BARE-REPLACE AUDIT FAILED: {0} Move-Item -Force command(s) outside lib\atomic-write.ps1, against a baseline of {1}. A NEW one was added: a reader holding that destination open makes it lose the write, silently under the default ErrorActionPreference. Use Write-TcAtomicFile, or mark a deliberate exception with '# atomic-replace:allow <reason>'." -f $count, $base)
  Exit-Guard -Name 'bare-replace' -Summary ("scanned={0} sites={1} baseline={2}" -f $files.Count, $count, $base) -Code 2
}
$move = Test-RatchetMove -Name 'bare-replace' -Count $count -Baseline $base -AcceptDrop:$AcceptDrop
if ($move.Verdict -eq 'implausible') {
  Write-Output $move.Message
  Exit-Guard -Name 'bare-replace' -Summary ("scanned={0} sites={1} baseline={2} refused-to-lower" -f $files.Count, $count, $base) -Code 2
}
if ($move.Verdict -eq 'tightened') {
  $doc = $null
  try { $doc = Get-Content $BASELINE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
  if (-not $doc) { $doc = [pscustomobject]@{} }
  $hist = Add-RatchetHistory -Doc $doc -Count $count
  $newDoc = [pscustomobject]@{ generated = (Get-Date).ToString('s'); sites = $move.NewBaseline; history = $hist
    note = 'HIGH-WATER MARK for Move-Item -Force commands outside lib\atomic-write.ps1. This number may only go DOWN, and a fall to zero or a fall over 60% in one run is REFUSED as a probably-broken detector.' }
  [IO.File]::WriteAllText($BASELINE_FILE, (($newDoc | ConvertTo-Json -Depth 5) -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
  Write-Output ("PASSED and TIGHTENED - " + $move.Message)
  Write-Output ("  " + (Get-RatchetTrend -History $hist))
  Exit-Guard -Name 'bare-replace' -Summary ("scanned={0} sites={1} tightened-from={2}" -f $files.Count, $count, $base) -Code 0
}
Write-Output ("bare-replace: PASSED - {0} known Move-Item -Force command(s) over {1} file(s), unchanged from the baseline. Each is a write a held reader can refuse; converting one to lib\atomic-write.ps1 lowers the mark permanently." -f $count, $files.Count)
Exit-Guard -Name 'bare-replace' -Summary ("scanned={0} sites={1} baseline={2}" -f $files.Count, $count, $base) -Code 0
