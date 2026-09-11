# audit-cross-module-reach.ps1
# ---------------------------------------------------------------------------------------------------
# A module reaches into another module's WORKING DIRECTORY by writing a path string, and nothing in this
# estate declares that (2026-09-09, backlog I90).
#
# THE DISTINCTION THIS DETECTOR EXISTS FOR, and it is not "does meal-prep mention grocery":
#   * `public/board.json` and `content/` are PUBLISHED artefacts. Reading one is the contract working.
#   * `grocery/out/`, `meal-prep/db/`, `graph/state/` are INTERNALS. They are gitignored or churn daily,
#     which is exactly why a worktree, a CI runner or a clean checkout prices nothing and exits 0.
# A reach into another module's internals is the finding. A reach into its published artefact is not.
#
# SCOPE OF A CLEAN REPORT: UNSOUND, so a clean report proves nothing. This is a pattern matcher over
# source text and it finds the spellings it knows - a literal path with a module-internals prefix, in
# either slash direction. It cannot see a path assembled at run time (`Join-Path $mp $sub`), one read
# from config, or one reached through a variable set three files away. A reported reach is real; the
# absence of one is not evidence there is none. The number it prints is a FLOOR, exactly as the
# founding grep's 36 was.
#
# WHAT IT IMPROVES ON THE FOUNDING MEASUREMENT. `grep -rl` counted a mention in a comment the same as a
# read, and counted a file once however many times it reached. This counts SITES, not files, and splits
# them into `code` and `comment`. Only the CODE count is ratcheted, because a comment naming a path is
# documentation and gating it would push people to delete the explanation rather than the coupling.
#
# DELIBERATELY A RATCHET, NOT A GATE. The number is what it is today and a gate red on day one teaches
# people to ignore red. The high-water mark may only go DOWN.
#
#   .\audit-cross-module-reach.ps1                 report + ratchet
#   .\audit-cross-module-reach.ps1 -UpdateBaseline lower the high-water mark (refuses to raise it)
#   .\audit-cross-module-reach.ps1 -SelfTest
# Exit 0 clean, 2 the ratchet rose, 3 could not evaluate.
# ---------------------------------------------------------------------------------------------------
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param(
  [switch]$UpdateBaseline,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$runSelfTest = [bool]$SelfTest; $runUpdate = [bool]$UpdateBaseline

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $here
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\tree-walk.ps1')   # Get-TcPathBelowRoot: exclusions match below the root, so a worktree root is not excluded whole

$BASELINE = Join-Path $here 'cross-module-reach-baseline.json'

# A module's INTERNALS. Reaching one of these from outside that module is the finding.
$script:INTERNALS = @{
  'grocery'   = @('grocery/out')
  'meal-prep' = @('meal-prep/db')
  'graph'     = @('graph/state', 'graph/learning')
  'sidecar'   = @('sidecar/out')
}
# PUBLISHED artefacts, named here so the reader can see they were considered and excluded on purpose.
$script:PUBLISHED = @('public/', 'content/', 'site/')

function Get-ModuleOfPath {
  param([string]$RelPath)
  if (-not $RelPath) { return '' }
  $p = $RelPath -replace '\\', '/'
  $p = $p -replace '^\./', ''
  $seg = ($p -split '/')[0]
  return $seg
}

function Test-IsCommentSite {
  param([string]$Line, [int]$MatchIndex)
  # A site is a COMMENT site when a `#` opens before it on the line. Not perfect - a `#` inside a string
  # earlier on the line fools this - but it is deliberately biased toward calling a site CODE, so the
  # ratcheted number is never understated by a misread comment.
  if ($null -eq $Line) { return $false }
  $hash = $Line.IndexOf('#')
  if ($hash -lt 0) { return $false }
  return ($hash -lt $MatchIndex)
}

function Get-ReachSites {
  param([string]$Text, [string]$OwnModule)
  # Returns an array of @{ target=; module=; line=; comment=<bool> } for every internals path literal in
  # $Text that belongs to a module OTHER than $OwnModule.
  $out = @()
  if (-not $Text) { return $out }
  $lines = $Text -split "`r?`n"
  foreach ($owner in $script:INTERNALS.Keys) {
    if ($owner -eq $OwnModule) { continue }
    foreach ($int in $script:INTERNALS[$owner]) {
      # match either slash direction
      $pat = [regex]::Escape($int) -replace '/', '[\\/]'
      for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($m in [regex]::Matches($lines[$i], $pat)) {
          # AN ENTRY POINT IS NOT A DATA REACH (2026-09-09). This audit exists to separate a module's
          # published contract from its internals, and a script's command line IS an interface: calling
          # `graph\learning\promote_aliases.py --recheck-holds` is using graph's front door, while
          # reading `graph\learning\promotion-holds.json` is reaching past it. Both spell the same
          # directory prefix, so only what FOLLOWS the prefix can tell them apart. Found when the
          # watchdog started invoking that script and this ratchet - correctly, by its old rule -
          # called it a new reach.
          $rest = $lines[$i].Substring($m.Index + $m.Length)
          $tail = [regex]::Match($rest, '^[\\/][A-Za-z0-9_.\-]+')
          if ($tail.Success -and $tail.Value -match '\.(ps1|py)$') { continue }
          # A QUOTED FIXTURE LITERAL IS NOT A DATA REACH (2026-09-09, queue 2026-09-09-a95022). Same shape
          # as the entry-point rule directly above, and the same reason the scan already refuses to read
          # this file: a fixture is FULL of the literals the detector hunts, and quoting a path is not
          # opening one. The 09-09 case: lib\git-blob-lib.ps1's frozen must-fire reproduces the pre-commit
          # hook's own stderr, 'BOM CHANGED grocery/out/json-readers-baseline.json', and the throwaway
          # repo in its clean twin is seeded with 'grocery/out/x.json'. Neither line reads grocery's
          # internals - one is a string the hook printed, the other a file inside a %TEMP% repo - and the
          # ratchet counted both as new coupling.
          #
          # OPT-IN, PER LINE, AND IT MUST CARRY A REASON. Not a file-type exemption: excusing every
          # test-*.ps1 would have dropped 20 sites in ops\test-precommit-hook.ps1 alone out of the
          # measurement, which is lowering the baseline by changing what is counted rather than by
          # removing coupling. Nothing in the tree carried this marker when it was added, so the 133
          # high-water mark it was measured against is untouched - it can only ever exclude a line an
          # author wrote it on, in a diff a reviewer reads.
          if ($lines[$i] -match 'reach-fixture-ok:\s*\S') { continue }
          $out += @{ target = $int; module = $owner; line = ($i + 1)
                     comment = (Test-IsCommentSite -Line $lines[$i] -MatchIndex $m.Index) }
        }
      }
    }
  }
  return $out
}

function Get-ReachSourceFiles {
  <# Every first-party .ps1 the sweep reads under $RootDir, excluded on the path BELOW the root
     (lib\tree-walk.ps1). On the full path a root under .claude\worktrees\ excluded itself whole, and this
     ratchet exited 3 from every spawned session (2026-09-11). #>
  param([string]$RootDir)
  $rootFull = Get-TcRootFull $RootDir
  Get-ChildItem $rootFull -Recurse -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
    Where-Object { (Get-TcPathBelowRoot $_.FullName $rootFull) -notmatch '\\\.claude\\worktrees\\|\\grocery\\out\\|\\archive\\|\\node_modules\\' }
}

# ---- self-test -------------------------------------------------------------------------------------
if ($runSelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ("  ok    " + $n) } else { Write-Output ("  X     " + $n + "   got: " + $got); $script:bad++ }
  }

  # MUST FIRE - the founding shape: meal-prep reaching into grocery's working directory.
  $s1 = @(Get-ReachSites -Text '$b = Get-ChildItem "grocery/out/comparison-2026-09-08.json"' -OwnModule 'meal-prep')
  T 'MUST FIRE  a meal-prep read of grocery/out is a reach' ($s1.Count -eq 1 -and $s1[0].module -eq 'grocery' -and -not $s1[0].comment) ([string]$s1.Count)

  # MUST FIRE - the other slash direction, because this is Windows and both spellings are live.
  $s2 = @(Get-ReachSites -Text '$b = "grocery\out\price-table.json"' -OwnModule 'meal-prep')
  T 'MUST FIRE  a backslash spelling is the same reach' ($s2.Count -eq 1) ([string]$s2.Count)

  # MUST NOT FIRE - reading the PUBLISHED artefact is the contract working, not a finding.
  $s3 = @(Get-ReachSites -Text '$b = Get-Content "public/board.json"' -OwnModule 'meal-prep')
  T 'MUST NOT FIRE  reading the published board.json is not a reach' ($s3.Count -eq 0) ([string]$s3.Count)

  # MUST NOT FIRE - invoking another module's SCRIPT is using its front door, not reaching past it.
  $sE = @(Get-ReachSites -Text '$p = Join-Path $root ''graph\learning\promote_aliases.py''' -OwnModule 'grocery')
  T 'MUST NOT FIRE  invoking another module''s script is an ENTRY POINT, not a data reach' ($sE.Count -eq 0) ([string]$sE.Count)

  # ---- THE FIXTURE MARKER (2026-09-09, queue 2026-09-09-a95022) ------------------------------------
  # MUST FIRE first, so the marker is proved to be doing the work rather than the line being uncounted
  # anyway. This is the exact line lib\git-blob-lib.ps1's frozen must-fire carries.
  $sF0 = @(Get-ReachSites -Text '$f = ''grocery/out/json-readers-baseline.json''' -OwnModule 'lib')
  T 'MUST FIRE  an UNMARKED fixture literal is still counted (the marker, not the file, does the work)' ($sF0.Count -eq 1 -and -not $sF0[0].comment) ([string]$sF0.Count)
  # MUST NOT FIRE with the marker and a reason.
  $sF1 = @(Get-ReachSites -Text '$f = ''grocery/out/json-readers-baseline.json''   # reach-fixture-ok: frozen hook stderr, nothing here opens it' -OwnModule 'lib')
  T 'MUST NOT FIRE  a marked fixture literal with a reason is not a data reach' ($sF1.Count -eq 0) ([string]$sF1.Count)
  # A MARKER WITH NO REASON IS NOT AN EXEMPTION - the same rule stores.json allowed_subsets gets wrong.
  $sF2 = @(Get-ReachSites -Text '$f = ''grocery/out/json-readers-baseline.json''   # reach-fixture-ok:' -OwnModule 'lib')
  T 'MUST FIRE  a marker with no reason exempts nothing' ($sF2.Count -eq 1) ([string]$sF2.Count)
  # AND IT IS PER LINE. A marker on one line must not excuse the next, or one fixture silences a file.
  $sF3 = @(Get-ReachSites -Text (@(
      '$a = ''grocery/out/x.json''   # reach-fixture-ok: throwaway repo seed',
      '$b = ''grocery/out/comparison-2026-09-08.json''') -join "`n") -OwnModule 'lib')
  T 'MUST FIRE  the marker is per LINE - the unmarked line below it is still counted' ($sF3.Count -eq 1 -and $sF3[0].line -eq 2) ([string]$sF3.Count)

  # MUST FIRE - the same directory prefix, but a DATA file behind it, is still a reach. This is the
  # pair that proves the entry-point rule did not just switch the check off.
  $sD = @(Get-ReachSites -Text '$h = Get-Content ''graph\learning\promotion-holds.json''' -OwnModule 'grocery')
  T 'MUST FIRE  reading a DATA file under the same directory is still a reach' ($sD.Count -eq 1) ([string]$sD.Count)

  # MUST NOT FIRE - a module touching its OWN internals is not a cross-module reach.
  $s4 = @(Get-ReachSites -Text '$b = "grocery/out/comparison.json"' -OwnModule 'grocery')
  T 'MUST NOT FIRE  a module reading its own internals is not a reach' ($s4.Count -eq 0) ([string]$s4.Count)

  # The code/comment split, which is the whole improvement over the founding grep.
  $s5 = @(Get-ReachSites -Text '# historical note: this used to read grocery/out directly' -OwnModule 'meal-prep')
  T 'a comment mention is a COMMENT site, not a code site' ($s5.Count -eq 1 -and $s5[0].comment) ("count=$($s5.Count)")
  $s6 = @(Get-ReachSites -Text '$p = "grocery/out/x.json"   # reads the internals' -OwnModule 'meal-prep')
  T 'MUST FIRE  code before a trailing comment is still a CODE site' ($s6.Count -eq 1 -and -not $s6[0].comment) ("comment=$($s6[0].comment)")

  # SITES, not files. The founding grep -rl counted this file once; it is two reaches.
  $s7 = @(Get-ReachSites -Text "`$a = 'grocery/out/one.json'`n`$b = 'grocery/out/two.json'" -OwnModule 'meal-prep')
  T 'two reaches on two lines count as two SITES, not one file' ($s7.Count -eq 2) ([string]$s7.Count)

  # MUST FIRE - the reach runs both directions, which is the half RUNTIME-MAP.md did not say.
  $s8 = @(Get-ReachSites -Text '$db = "meal-prep/db/recipes.json"' -OwnModule 'grocery')
  T 'MUST FIRE  grocery reaching into meal-prep/db is a reach too' ($s8.Count -eq 1 -and $s8[0].module -eq 'meal-prep') ([string]$s8.Count)

  T 'the module of a path is its first segment' ((Get-ModuleOfPath 'meal-prep\pipeline\x.ps1') -eq 'meal-prep') (Get-ModuleOfPath 'meal-prep\pipeline\x.ps1')
  T 'a leading ./ does not become the module' ((Get-ModuleOfPath './ops/x.ps1') -eq 'ops') (Get-ModuleOfPath './ops/x.ps1')

  # MUST NOT FIRE - an unrelated script with no cross-module path is silent. This asserts an ABSENCE,
  # so it is a negative assertion and NOT a clean twin, whatever it feels like.
  $s9 = @(Get-ReachSites -Text '$x = 1; Write-Output "hello"' -OwnModule 'meal-prep')
  T 'MUST NOT FIRE  a script with no cross-module path yields nothing' ($s9.Count -eq 0) ([string]$s9.Count)

  # CLEAN TWIN - the adjacent behaviour most likely to have broken while adding the comment split:
  # a code site and a comment site on the SAME line pair must still both be found and classified.
  $s10 = @(Get-ReachSites -Text "`$p = 'grocery/out/a.json'`n# and grocery/out/b.json is the old one" -OwnModule 'meal-prep')
  T 'CLEAN TWIN  code and comment sites are both still found, and split correctly' ($s10.Count -eq 2 -and @($s10 | Where-Object { -not $_.comment }).Count -eq 1) ([string]$s10.Count)

  # THE WALK, FROM A WORKTREE ROOT (2026-09-11, lib\tree-walk.ps1). Matched on the FULL path, every file under
  # .claude\worktrees\<name> was excluded and this ratchet exited 3 from every spawned session.
  $wtFx = New-TcWorktreeFixture -Files @{ 'ops\a.ps1' = 'Write-Output 1'; 'meal-prep\b.ps1' = 'Write-Output 2' }
  try {
    $wtFound = @(Get-ReachSourceFiles -RootDir $wtFx.Root)
    $wtHits = Measure-TcWorktreeFixture -Fixture $wtFx -Found $wtFound
    T 'MUST FIRE  a root that IS a worktree is scanned, not excluded whole' ($wtHits.Root -eq 2) ("root=" + $wtHits.Root)
    T 'MUST NOT FIRE  a sibling worktree BELOW that root is still excluded' ($wtHits.Sibling -eq 0) ("sibling=" + $wtHits.Sibling)
  } finally { Remove-Item -LiteralPath $wtFx.Temp -Recurse -Force -ErrorAction SilentlyContinue }

  if ($bad -gt 0) { Write-Output ("cross-module-reach SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'cross-module-reach SELF-TEST PASS'
  Exit-Guard -Name 'cross-module-reach' -Summary 'selftest pass' -Code 0
}

# ---- sweep -----------------------------------------------------------------------------------------
$files = @(Get-ReachSourceFiles -RootDir $repo)
# `archive\` is excluded on purpose: retired code is not a live dependency, and counting it would let a
# ratchet rise because somebody filed something away. Everything else is in scope, TEST scripts included -
# a test that builds a path into another module's internals still breaks when that directory moves.
if (-not $files.Count) { Write-Output 'cross-module-reach: no .ps1 files found - discovery is broken, not clean.'; exit 3 }

$codeSites = 0; $commentSites = 0
$byPair = @{}
$fileHits = @{}
foreach ($f in $files) {
  $rel = $f.FullName.Substring($repo.Length).TrimStart('\','/')
  $own = Get-ModuleOfPath $rel
  if (-not $script:INTERNALS.ContainsKey($own) -and $own -ne 'ops' -and $own -ne 'lib') { continue }
  # A detector must never scan itself: its own fixtures are full of the literals it hunts.
  if ($rel -replace '\\','/' -eq 'ops/audit-cross-module-reach.ps1') { continue }
  $text = [IO.File]::ReadAllText($f.FullName)
  $sites = @(Get-ReachSites -Text $text -OwnModule $own)
  foreach ($s in $sites) {
    if ($s.comment) { $commentSites++ } else {
      $codeSites++
      $k = "$own -> $($s.module)"
      if (-not $byPair.ContainsKey($k)) { $byPair[$k] = 0 }
      $byPair[$k]++
      if (-not $fileHits.ContainsKey($rel)) { $fileHits[$rel] = 0 }
      $fileHits[$rel]++
    }
  }
}

Write-Output ("cross-module-reach: scanned {0} first-party .ps1 file(s)" -f $files.Count)
Write-Output ("  code sites    {0}   (in {1} file(s))" -f $codeSites, $fileHits.Count)
Write-Output ("  comment sites {0}   (not ratcheted - a comment naming a path is documentation)" -f $commentSites)
foreach ($k in ($byPair.Keys | Sort-Object { -$byPair[$_] })) {
  Write-Output ("    {0,-26} {1}" -f $k, $byPair[$k])
}
Write-Output '  top files:'
foreach ($k in (@($fileHits.Keys | Sort-Object { -$fileHits[$_] }) | Select-Object -First 8)) {
  Write-Output ("    {0,-58} {1}" -f $k, $fileHits[$k])
}

if ($runUpdate) {
  $prev = if (Test-Path $BASELINE) { (Get-Content $BASELINE -Raw | ConvertFrom-Json).code_sites } else { [int]::MaxValue }
  if ($codeSites -gt $prev) {
    Write-Output ("cross-module-reach: REFUSING to raise the high-water mark from {0} to {1}. A ratchet may only go DOWN." -f $prev, $codeSites)
    exit 2
  }
  $obj = [pscustomobject]@{
    code_sites = $codeSites
    recorded   = (Get-Date -Format 'yyyy-MM-dd')
    note       = 'HIGH-WATER MARK, MAY ONLY GO DOWN. Cross-module reaches into another module internals directory, counted as SITES in code (comments excluded). Backlog I90.'
  }
  [IO.File]::WriteAllText($BASELINE, ($obj | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
  Write-Output ("cross-module-reach: baseline set to {0}" -f $codeSites)
  Exit-Guard -Name 'cross-module-reach' -Summary ("baseline={0}" -f $codeSites) -Code 0
}

if (-not (Test-Path $BASELINE)) {
  Write-Output 'cross-module-reach: no baseline recorded. Run -UpdateBaseline once to set the high-water mark.'
  exit 3
}
$base = [int]((Get-Content $BASELINE -Raw | ConvertFrom-Json).code_sites)
if ($codeSites -gt $base) {
  Write-Output ("cross-module-reach: RATCHET ROSE. baseline {0}, now {1}. A new cross-module reach was added." -f $base, $codeSites)
  Write-Output '  Read the published artefact (public/board.json) instead, or lower the baseline deliberately with a reason.'
  Exit-Guard -Name 'cross-module-reach' -Summary ("ROSE base={0} now={1}" -f $base, $codeSites) -Code 2
}
if ($codeSites -lt $base) {
  Write-Output ("cross-module-reach: below the high-water mark ({0} < {1}). Lower it with -UpdateBaseline." -f $codeSites, $base)
}
Exit-Guard -Name 'cross-module-reach' -Summary ("code={0} comment={1} base={2}" -f $codeSites, $commentSites, $base) -Code 0
