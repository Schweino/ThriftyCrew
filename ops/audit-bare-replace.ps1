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

  A RUN THAT IS NOT ASKED TO RECORD WRITES NOTHING (2026-09-12, the rule 740c82af6 gave seven other ratchets
  and this one did not get). run-gates runs this with NO arguments on every pre-push, and a fall used to rewrite
  the TRACKED baseline right there: the lower mark never rode that push, so it protected only the checkout that
  happened to run it, it left that checkout ` M` mid-push, and a count taken over uncommitted edits is not a
  baseline anyway. It also costs the pass its reuse record - run-gates then reports "the checkout changed while
  the gates ran" and the next push pays for every gate again. So a fall is SPOKEN and the committed mark KEPT;
  -Tighten records it, through lib\ratchet.ps1's plausibility bar and in the bytes git stores (lib\lf-write.ps1).

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 hard finding, 3 could-not-evaluate.
  Read the verdict LINE, not the number.

    ops\audit-bare-replace.ps1              scan the tree, hold the ratchet; writes NOTHING
    ops\audit-bare-replace.ps1 -Tighten     the same, and record a believable FALL as the new high-water mark
    ops\audit-bare-replace.ps1 -AcceptDrop  record a fall lib\ratchet.ps1 would otherwise refuse
  Self-test: powershell -File ops\audit-bare-replace.ps1 -SelfTest
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param([switch]$SelfTest, [switch]$AcceptDrop, [switch]$Tighten, [string]$Root = '', [string]$BaselineFile = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ratchet.ps1')
. (Join-Path $repo 'lib\lf-write.ps1')    # Write-TcLfFile: the baseline is TRACKED and stored eol=lf
. (Join-Path $repo 'lib\tree-walk.ps1')   # exclusions match below the root, so a worktree root is not excluded whole

# -Root and -BaselineFile exist for the self-test, so the three live-path cases drive THIS script against a
# temp tree and a temp baseline rather than a copy of its logic. Production passes neither.
$BASELINE_FILE = if ($BaselineFile) { $BaselineFile } else { Join-Path $repo 'ops\bare-replace-baseline.json' }

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
  Get-TcTreeFiles -RootFull $rootFull -Filter *.ps1 -PruneBelow $EXCLUDE |
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

  # ---- THE LIVE PATH, DRIVEN (2026-09-12) -------------------------------------------------------------
  # The founding shape is a pre-push run-gates pass whose count FELL: it rewrote the TRACKED baseline in the
  # checkout being pushed, without riding the push, and cost that pass its reuse record. These three run THIS
  # script as a child against a one-file temp tree and a temp baseline, so they exercise the code a gate runs.
  # ONE DIRECTORY PER RUN, removed in finally: concurrent pushes run this suite in the same %TEMP%.
  $brWt = Join-Path $env:TEMP ('br-live-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $brWt -ErrorAction Stop | Out-Null
  try {
    $brTree = Join-Path $brWt 'tree'
    New-Item -ItemType Directory -Path (Join-Path $brTree 'grocery') -ErrorAction Stop -Force | Out-Null
    # EXACTLY ONE bare replace, so the counts below are the fixture's and not the tree's.
    [IO.File]::WriteAllText((Join-Path $brTree 'grocery\one.ps1'), 'Move-Item $t $p -Force', (New-Object Text.UTF8Encoding($false)))
    $brNote = 'fixture note (keep me)'
    $brBl = Join-Path $brWt 'baseline.json'
    $brSeed = [pscustomobject]@{ generated = '2026-01-01T00:00:00'; sites = 2
                                 history = @([pscustomobject]@{ date = '2026-01-01T00:00:00'; count = 2 }); note = $brNote }
    $null = Write-TcLfFile -Path $brBl -Text ($brSeed | ConvertTo-Json -Depth 5) -NoBom
    $brSeedB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($brBl))

    $bo1 = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $brTree -BaselineFile $brBl)
    $brc1 = $LASTEXITCODE
    $brSame1 = [string]::Equals($brSeedB64, [Convert]::ToBase64String([IO.File]::ReadAllBytes($brBl)), [StringComparison]::Ordinal)
    T 'MUST FIRE  a FALL (1 site, baseline 2) with no -Tighten is SPOKEN and the baseline left byte-identical, so a gate run leaves its checkout clean' `
      ($brc1 -eq 0 -and $brSame1 -and (($bo1 -join "`n") -match 'CAN tighten')) ("rc=$brc1 baselineUnchanged=$brSame1")

    $null = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $brTree -BaselineFile $brBl -Tighten)
    $brc2 = $LASTEXITCODE
    $bb2 = [IO.File]::ReadAllBytes($brBl)
    $bcr2 = 0; foreach ($x in $bb2) { if ($x -eq 13) { $bcr2++ } }
    $bbom2 = ($bb2.Length -ge 3 -and $bb2[0] -eq 0xEF -and $bb2[1] -eq 0xBB -and $bb2[2] -eq 0xBF)
    $bdoc2 = $null
    try { $bdoc2 = [Text.Encoding]::UTF8.GetString($bb2) | ConvertFrom-Json } catch { }
    T '-Tighten records the fall in the bytes git stores: no CR, no BOM (the committed blob has none), one trailing LF, sites lowered, and the note kept' `
      ($brc2 -eq 0 -and $bcr2 -eq 0 -and (-not $bbom2) -and $bb2[-1] -eq 10 -and $null -ne $bdoc2 -and
       [int]$bdoc2.sites -eq 1 -and [string]$bdoc2.note -eq $brNote -and @($bdoc2.history).Count -eq 2) `
      ("rc=$brc2 cr=$bcr2 bom=$bbom2 sites=$(if ($bdoc2) { $bdoc2.sites }) note=$(if ($bdoc2) { $bdoc2.note })")

    # CLEAN TWIN: not writing on a fall must not have disarmed the ratchet in the direction that matters.
    $brRise = Join-Path $brWt 'baseline-rise.json'
    $null = Write-TcLfFile -Path $brRise -Text ([pscustomobject]@{ generated = '2026-01-01T00:00:00'; sites = 0; history = @(); note = $brNote } | ConvertTo-Json -Depth 5) -NoBom
    $brRiseB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($brRise))
    $null = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $brTree -BaselineFile $brRise)
    $brc3 = $LASTEXITCODE
    $brSame3 = [string]::Equals($brRiseB64, [Convert]::ToBase64String([IO.File]::ReadAllBytes($brRise)), [StringComparison]::Ordinal)
    T 'CLEAN TWIN  a count that ROSE still exits 2 and writes nothing, so not recording a fall did not disarm the ratchet' `
      ($brc3 -eq 2 -and $brSame3) ("rc=$brc3 baselineUnchanged=$brSame3")
  } finally { Remove-Item -LiteralPath $brWt -Recurse -Force -ErrorAction SilentlyContinue }

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} of {1} check(s)" -f $f, $n); exit 1 }
  Write-Output ("SELF-TEST PASS: {0} checks - 6 must-fire shapes, 8 must-not-fire inputs, line reporting and return arity, the walk from a worktree root, and the live path driven against a temp tree and baseline" -f $n)
  exit 0
}

# ------------------------------------------------------------------------------------- live run
# NEVER SCAN YOURSELF, by the rule audit-write-seam states. The parser would not count the fixtures above
# (they are strings), so this is convention rather than necessity here, and it costs nothing.
if (-not $Root) { $Root = $repo }
$files = @(Get-BareReplaceScanFiles -RootDir $Root -Self $PSCommandPath)
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

$BR_NOTE = 'HIGH-WATER MARK for Move-Item -Force commands outside lib\atomic-write.ps1. This number may only go DOWN, and a fall to zero or a fall over 60% in one run is REFUSED as a probably-broken detector (lib\ratchet.ps1).'
$blDoc = $null
if (Test-Path -LiteralPath $BASELINE_FILE) {
  try { $blDoc = Get-Content -LiteralPath $BASELINE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $blDoc = $null }
}
function Write-BrBaseline([int]$Sites) {
  <# The recorded mark, in the bytes git stores. The committed blob carries NO BOM, so -NoBom. The NOTE the
     file already carries is KEPT rather than replaced, and the key order is the committed one, so the diff
     of a record is only what moved. #>
  $keepNote = if ($blDoc -and $blDoc.note) { [string]$blDoc.note } else { $BR_NOTE }
  $srcDoc = if ($blDoc) { $blDoc } else { [pscustomobject]@{} }
  $hist = Add-RatchetHistory -Doc $srcDoc -Count $Sites
  $doc = [pscustomobject]@{ generated = (Get-Date).ToString('s'); sites = $Sites; history = $hist; note = $keepNote }
  $null = Write-TcLfFile -Path $BASELINE_FILE -Text ($doc | ConvertTo-Json -Depth 5) -NoBom
  return $hist
}
if (-not $blDoc) {
  # SEEDING IS NOT RECORDING A FALL. With no baseline there is nothing to protect and nothing to compare
  # against, so the first run writes one - which in production cannot happen, the file being tracked.
  # The day-one count goes into the history as well, so every later fall is read against what was first measured.
  $null = Write-BrBaseline $count
  Write-Output ("bare-replace: baseline written at {0} site(s) over {1} file(s). From here the number may only go DOWN." -f $count, $files.Count)
  Exit-Guard -Name 'bare-replace' -Summary ("scanned={0} baseline={1}" -f $files.Count, $count) -Code 0
}
$base = [int]$blDoc.sites

foreach ($h in ($hits | Sort-Object File, Line)) {
  Write-Output ("  bare  {0}:{1}" -f (Get-TcPathBelowRoot $h.File (Get-TcRootFull $Root)).TrimStart('\'), $h.Line)
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
  # A FALL IS SPOKEN, NOT WRITTEN, unless this run was asked to record it (see the header). -AcceptDrop is
  # such an ask: it has always recorded the fall it names.
  if (-not ($Tighten -or $AcceptDrop)) {
    Write-Output ("bare-replace: PASSED, and the ratchet CAN tighten - {0} site(s), baseline {1}. NOT written: this may be a pre-push gate, and a rewrite here dirties the checkout being pushed without riding the push. Record it with -Tighten and commit ops\bare-replace-baseline.json." -f $count, $base)
    Exit-Guard -Name 'bare-replace' -Summary ("scanned={0} sites={1} baseline={2} can-tighten={1}" -f $files.Count, $count, $base) -Code 0
  }
  $hist = Write-BrBaseline ([int]$move.NewBaseline)
  Write-Output ("PASSED and TIGHTENED - " + $move.Message)
  Write-Output ("  " + (Get-RatchetTrend -History $hist))
  Write-Output '  New baseline written - commit ops\bare-replace-baseline.json, or it protects only this checkout.'
  Exit-Guard -Name 'bare-replace' -Summary ("scanned={0} sites={1} tightened-from={2}" -f $files.Count, $count, $base) -Code 0
}
Write-Output ("bare-replace: PASSED - {0} known Move-Item -Force command(s) over {1} file(s), unchanged from the baseline. Each is a write a held reader can refuse; converting one to lib\atomic-write.ps1 lowers the mark permanently." -f $count, $files.Count)
Exit-Guard -Name 'bare-replace' -Summary ("scanned={0} sites={1} baseline={2}" -f $files.Count, $count, $base) -Code 0
