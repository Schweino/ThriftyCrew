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
          $out += @{ target = $int; module = $owner; line = ($i + 1)
                     comment = (Test-IsCommentSite -Line $lines[$i] -MatchIndex $m.Index) }
        }
      }
    }
  }
  return $out
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

  if ($bad -gt 0) { Write-Output ("cross-module-reach SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'cross-module-reach SELF-TEST PASS'
  Write-GuardComplete -Name 'cross-module-reach' -Summary 'selftest pass'
  exit 0
}

# ---- sweep -----------------------------------------------------------------------------------------
$files = @(Get-ChildItem $repo -Recurse -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
           Where-Object { $_.FullName -notmatch '\\\.claude\\worktrees\\' -and
                          $_.FullName -notmatch '\\grocery\\out\\' -and
                          $_.FullName -notmatch '\\archive\\' -and
                          $_.FullName -notmatch '\\node_modules\\' })
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
  Write-GuardComplete -Name 'cross-module-reach' -Summary ("baseline={0}" -f $codeSites)
  exit 0
}

if (-not (Test-Path $BASELINE)) {
  Write-Output 'cross-module-reach: no baseline recorded. Run -UpdateBaseline once to set the high-water mark.'
  exit 3
}
$base = [int]((Get-Content $BASELINE -Raw | ConvertFrom-Json).code_sites)
if ($codeSites -gt $base) {
  Write-Output ("cross-module-reach: RATCHET ROSE. baseline {0}, now {1}. A new cross-module reach was added." -f $base, $codeSites)
  Write-Output '  Read the published artefact (public/board.json) instead, or lower the baseline deliberately with a reason.'
  Write-GuardComplete -Name 'cross-module-reach' -Summary ("ROSE base={0} now={1}" -f $base, $codeSites)
  exit 2
}
if ($codeSites -lt $base) {
  Write-Output ("cross-module-reach: below the high-water mark ({0} < {1}). Lower it with -UpdateBaseline." -f $codeSites, $base)
}
Write-GuardComplete -Name 'cross-module-reach' -Summary ("code={0} comment={1} base={2}" -f $codeSites, $commentSites, $base)
exit 0
