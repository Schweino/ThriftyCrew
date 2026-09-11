<#
  audit-write-seam.ps1 - the E1 safety layer is only as good as its chokepoint being the ONLY door.

  SCOPE OF A CLEAN REPORT: UNSOUND, and it is a RATCHET rather than a proof for exactly that
    reason. It finds the spellings of a remote write that bypass the chokepoint. A clean report
    means the known spellings are absent; a new way of reaching the network is a hole this file
    cannot see until somebody teaches it the shape.

  WHY THIS EXISTS (2026-09-06, backlog E1). The safety layer hooks lib\ghost-lib.ps1's Invoke-GhostApi,
  which 29 scripts dot-source, and that reads like coverage. It is not. Measured the day it shipped:

    52  mutating raw Invoke-RestMethod / Invoke-WebRequest call sites outside the seam, in 45 files
    18  of those target a surface WE OWN - Ghost, thriftycrew.com, the Cloudflare API - in 17 files

  Those 18 are real irreversible writes to a live paid site that the staging gate and the journal never
  see. `.claude\skills\lesson` alone carries ten, including PUT, POST and DELETE against Ghost.

  THE OTHER 34 ARE NOT DEFECTS AND ARE DELIBERATELY NOT COUNTED. A POST to a store's search endpoint -
  Family Fare's Freshop, Hy-Vee, Bakers - is a QUERY wearing a mutating verb. It changes nothing of
  ours and needs no undo. A detector that flagged all 52 would be counting third-party reads as estate
  writes, would be ignored inside a week, and the 18 that matter would be lost in it. The discriminator
  is the URI, not the verb.

  RATCHET, NOT A HARD FAIL, and the reason is the same one run-gates gives for excluding test-auditors:
  a gate that is red on day one for a backlog nobody is about to clear trains everyone to ignore a red
  gate. The baseline is a HIGH-WATER MARK that may only go DOWN. A new bypass fails the gate; migrating
  one to Invoke-GhostApi lowers the mark and it can never rise again.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 hard finding, 3 could-not-evaluate.
  Read the verdict LINE, not the number (backlog E2).

  A RUN THAT IS NOT ASKED TO RECORD WRITES NOTHING (2026-09-11). run-gates runs this with no arguments on every
  pre-push, and a fall used to rewrite the TRACKED baseline right there: the pushing checkout was left dirty, the
  lower mark never rode that push, and a count taken over uncommitted edits is not a baseline. So a fall is SPOKEN
  and the committed mark KEPT; -Tighten records it. ops\audit-write-only-reports.ps1 carries the full account.

    ops\audit-write-seam.ps1               scan the tree, hold the ratchet; writes nothing
    ops\audit-write-seam.ps1 -Tighten      the same, and record a believable FALL as the new high-water mark
    ops\audit-write-seam.ps1 -AcceptDrop   record a fall lib\ratchet.ps1 would refuse
    ops\audit-write-seam.ps1 -SelfTest     frozen fixtures, plus this script's live path run against a temp tree
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest, [switch]$AcceptDrop, [switch]$Tighten, [string]$Root = '', [string]$BaselineFile = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ratchet.ps1')
. (Join-Path $repo 'lib\lf-write.ps1')   # Write-TcLfFile: the baseline is tracked and stored eol=lf
. (Join-Path $repo 'lib\tree-walk.ps1')   # Get-TcPathBelowRoot: exclusions match below the root, so a worktree root is not excluded whole

# -Root and -BaselineFile exist so the self-test can drive the LIVE path against a temp tree. A gate passes neither.
$treeRoot = if ($Root) { $Root } else { $repo }
$BASELINE_FILE = if ($BaselineFile) { $BaselineFile } else { Join-Path $treeRoot 'ops\write-seam-baseline.json' }

# The seam itself, plus the trees run-gates already excludes everywhere else.
$EXCLUDE = '\\archive\\|\\worktrees\\|\\out\\|node_modules|\\lib\\ghost-lib\.ps1$'

# SURFACES WE OWN. A mutating call to one of these is an estate write; a mutating call anywhere else is
# somebody else's API and not this gate's business. Kept as a named list because every entry is a
# decision - adding one widens the gate, and removing one silently narrows it.
$OURS = @(
  'ghost\.io'          # the Ghost Admin/Content API host
  'ghost/api'          # the API path, for callers that build the host from a variable
  'thriftycrew'        # the live site, the feed subdomain, the worker routes
  'api\.cloudflare'    # R2, D1, Workers - the estate in ops\cloudflare-estate.json
  'GhostJWT'           # a call minting an admin JWT is a Ghost call whatever the URI looks like
  '\$apiUrl'           # the estate's near-universal variable name for the Ghost host
)

function Test-TcSeamBypass {
  <# Pure, so the self-test drives it with synthetic lines instead of resting on today's tree.
     A line is a bypass when all three hold: it is a raw HTTP call, it carries a mutating verb, and it
     targets a surface we own. #>
  param([string]$Line)
  # COMMENTS FIRST. A header that DESCRIBES a bypass is not one, and this file is full of such prose -
  # the live count read 25 instead of 18 until this line existed, with the extra seven all being
  # documentation. run-gates hit the identical trap: its discovery matched the switch declaration
  # quoted in its own comments and it spawned copies of itself for 39 minutes.
  if ($Line -match '^\s*#') { return $false }
  if ($Line -notmatch 'Invoke-RestMethod|Invoke-WebRequest') { return $false }
  if ($Line -notmatch "(?i)-Method\s+'?(PUT|POST|DELETE|PATCH)\b") { return $false }
  foreach ($o in $OURS) { if ($Line -match "(?i)$o") { return $true } }
  return $false
}

function Get-TcSeamBypasses {
  <# Returns one record per bypassing call site. `,@()` so a single finding does not unroll to a bare
     string - and CALLERS MUST ASSIGN BEFORE WRAPPING, because @(callsite) then reads an EMPTY result as
     one element. Same trap as ops\audit-stray-root-artifacts.ps1 and [[ps-json-array-collapse]]. #>
  param([object[]]$Files, [scriptblock]$ReadLines)
  $hits = @()
  foreach ($f in @($Files)) {
    $n = 0
    foreach ($line in @(& $ReadLines $f)) {
      $n++
      if (Test-TcSeamBypass $line) { $hits += [pscustomobject]@{ File = $f; Line = $n } }
    }
  }
  return ,@($hits)
}

function Get-SeamScanFiles {
  <# Every .ps1 the live run reads under $RootDir, never $Self. $EXCLUDE matches the path BELOW the root
     (lib\tree-walk.ps1): on the full path a root under .claude\worktrees\ excluded itself whole, and this
     ratchet exited 3 BLIND from every spawned session (2026-09-11). #>
  param([string]$RootDir, [string]$Self = '')
  $rootFull = Get-TcRootFull $RootDir
  Get-ChildItem $rootFull -Recurse -File -Filter *.ps1 -ErrorAction SilentlyContinue |
    Where-Object { (Get-TcPathBelowRoot $_.FullName $rootFull) -notmatch $EXCLUDE -and $_.FullName -ne $Self } |
    ForEach-Object { $_.FullName }
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0
  function T($m, $cond, $got) { if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }

  # MUST FIRE - the founding shapes, taken verbatim from what the live tree actually contains.
  T 'MUST FIRE  a raw Ghost PUT is a bypass' `
    (Test-TcSeamBypass 'Invoke-RestMethod -Method Put -Uri "$apiUrl/ghost/api/admin/posts/$id/" -Headers $h -Body $b') 'missed'
  T 'MUST FIRE  a raw Ghost POST is a bypass' `
    (Test-TcSeamBypass 'Invoke-RestMethod -Uri "https://map-to-success.ghost.io/ghost/api/admin/posts/" -Method Post -Body $b') 'missed'
  T 'MUST FIRE  a raw DELETE against our site is a bypass' `
    (Test-TcSeamBypass 'Invoke-RestMethod -Method Delete -Uri "$apiUrl/ghost/api/admin/posts/$id/"') 'missed'
  T 'MUST FIRE  a mutating Cloudflare API call is a bypass' `
    (Test-TcSeamBypass 'Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/accounts/$a/r2/buckets/x/lifecycle" -Method PUT') 'missed'
  T 'MUST FIRE  lower-case verb still counts' `
    (Test-TcSeamBypass 'Invoke-RestMethod -Method put -Uri "$apiUrl/ghost/api/admin/posts/1/"') 'a case-sensitive gate leaks a live write'
  T 'MUST FIRE  Invoke-WebRequest counts too, not just Invoke-RestMethod' `
    (Test-TcSeamBypass 'Invoke-WebRequest -Method Post -Uri "https://www.thriftycrew.com/x" -Body $b') 'missed'

  # CLEAN TWINS - the fix must be scoped to estate writes, or the gate counts other people's APIs.
  T 'CLEAN TWIN a GET against our own Ghost is not a bypass' `
    (-not (Test-TcSeamBypass 'Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/slug/$s/" -Headers $h')) 'a read was counted as a write'
  T 'CLEAN TWIN  THE ONE THAT KEEPS THIS GATE CREDIBLE - a POST to a STORE search API is a query, not an estate write' `
    (-not (Test-TcSeamBypass 'Invoke-RestMethod -Method Post -Uri "https://storefrontgateway.familyfare.com/api/products/search" -Body $q')) 'a third-party search was counted as an estate write'
  T 'CLEAN TWIN a mutating call to some other third party is not ours' `
    (-not (Test-TcSeamBypass 'Invoke-RestMethod -Method Post -Uri "https://oauth2.googleapis.com/token" -Body $b')) 'someone else API counted'
  T 'CLEAN TWIN prose mentioning a PUT is not a call' `
    (-not (Test-TcSeamBypass '# the old code did Invoke-RestMethod -Method Put against ghost.io before the seam existed')) 'a comment was counted'

  # The scanner walks files and reports file+line.
  $fake = { param($p) if ($p -eq 'a.ps1') { @('$x = 1', 'Invoke-RestMethod -Method Put -Uri "$apiUrl/ghost/api/admin/posts/1/"') } else { @('Invoke-RestMethod -Uri "$apiUrl/ghost/api/admin/posts/1/"') } }
  $r = Get-TcSeamBypasses -Files @('a.ps1', 'b.ps1') -ReadLines $fake
  T 'the scanner finds the one bypass and reports its line' (($r.Count -eq 1) -and ($r[0].File -eq 'a.ps1') -and ($r[0].Line -eq 2)) ("Count=" + $r.Count)
  T 'MUST FIRE  a single finding comes back as an ARRAY, not unrolled to a string' ($r -is [array]) ($r.GetType().FullName)
  $r0 = Get-TcSeamBypasses -Files @('b.ps1') -ReadLines $fake
  T 'MUST NOT FIRE a file with only reads yields nothing' ((@($r0)).Count -eq 0) ("Count=" + @($r0).Count)

  # THE WALK, FROM A WORKTREE ROOT (2026-09-11, lib\tree-walk.ps1). $EXCLUDE matched on the FULL path, so run
  # from .claude\worktrees\<name> this ratchet read zero files and exited 3.
  $wtFx = New-TcWorktreeFixture -Files @{ 'ops\a.ps1' = 'Write-Output 1'; 'lib\b.ps1' = 'Write-Output 2' }
  try {
    $wtFound = @(Get-SeamScanFiles -RootDir $wtFx.Root)
    $wtHits = Measure-TcWorktreeFixture -Fixture $wtFx -Found $wtFound
    T 'MUST FIRE  a root that IS a worktree is scanned, not excluded whole' ($wtHits.Root -eq 2) ("root=" + $wtHits.Root)
    T 'MUST NOT FIRE  a sibling worktree BELOW that root is still excluded' ($wtHits.Sibling -eq 0) ("sibling=" + $wtHits.Sibling)
  } finally { Remove-Item -LiteralPath $wtFx.Temp -Recurse -Force -ErrorAction SilentlyContinue }

  # THE LIVE PATH, DRIVEN (2026-09-11). The founding shape is a pre-push run-gates pass whose count FELL: it rewrote
  # the tracked baseline and left the pushing checkout dirty. These run THIS script as a child against a temp tree
  # holding one bypass and a temp baseline, so they exercise the code a gate runs, not a copy of it. One directory
  # per run, removed in finally, because concurrent pushes run this suite in the same %TEMP%.
  $lt = Join-Path $env:TEMP ('ws-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $lt -ErrorAction Stop | Out-Null
  try {
    $ltTree = Join-Path $lt 'tree'
    [void][IO.Directory]::CreateDirectory((Join-Path $ltTree 'ops'))
    $ltBypass = 'Invoke-RestMethod -Method Put -Uri "$apiUrl/ghost/api/admin/posts/1/"'
    [IO.File]::WriteAllText((Join-Path $ltTree 'ops\a.ps1'), $ltBypass, (New-Object Text.UTF8Encoding($false)))   # exactly one bypass
    $ltBl = Join-Path $lt 'baseline.json'
    $ltSeedJson = [ordered]@{ generated = '2026-01-01T00:00:00'; sites = 2; note = 'fixture' } | ConvertTo-Json -Depth 3
    $null = Write-TcLfFile $ltBl $ltSeedJson
    $ltSeed = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ltBl))
    $o1 = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $ltTree -BaselineFile $ltBl
    $rc1 = $LASTEXITCODE
    $o1 = @($o1)
    $same1 = [string]::Equals($ltSeed, [Convert]::ToBase64String([IO.File]::ReadAllBytes($ltBl)), [StringComparison]::Ordinal)
    T 'a FALL (1 bypass, baseline 2) without -Tighten is spoken and NOT written, so a gate run leaves its checkout clean' `
      ($rc1 -eq 0 -and $same1 -and (($o1 -join "`n") -match 'CAN tighten')) ("rc=$rc1 baselineUnchanged=$same1")
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $ltTree -BaselineFile $ltBl -Tighten
    $rc2 = $LASTEXITCODE
    $b2 = [IO.File]::ReadAllBytes($ltBl)
    $cr2 = 0; foreach ($x in $b2) { if ($x -eq 13) { $cr2++ } }
    $bom2 = ($b2.Length -ge 3 -and $b2[0] -eq 0xEF -and $b2[1] -eq 0xBB -and $b2[2] -eq 0xBF)
    $doc2 = $null
    if ($bom2) { $doc2 = [Text.Encoding]::UTF8.GetString($b2, 3, $b2.Length - 3) | ConvertFrom-Json }
    T '-Tighten records the fall in the bytes git stores: no CR, the BOM, one trailing LF, and the new mark of 1' `
      ($rc2 -eq 0 -and $cr2 -eq 0 -and $bom2 -and $b2[-1] -eq 10 -and $null -ne $doc2 -and [int]$doc2.sites -eq 1) `
      ("rc=$rc2 cr=$cr2 bom=$bom2 sites=$(if ($doc2) { $doc2.sites })")
    $ltRise = Join-Path $lt 'baseline-rise.json'
    $ltRiseJson = [ordered]@{ generated = '2026-01-01T00:00:00'; sites = 0; note = 'fixture' } | ConvertTo-Json -Depth 3
    $null = Write-TcLfFile $ltRise $ltRiseJson
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $ltTree -BaselineFile $ltRise
    $rc3 = $LASTEXITCODE
    T 'CLEAN TWIN  a count that ROSE still fails the run with exit 2, so not writing on a fall did not disarm the ratchet' ($rc3 -eq 2) ("rc=$rc3")
  } finally {
    Remove-Item -LiteralPath $lt -Recurse -Force -ErrorAction SilentlyContinue
  }

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: 6 must-fire bypass shapes, 4 clean twins including a store search POST, plus the scanner and its return arity, the walk from a worktree root with a sibling below it, and the live path: a fall is not written without -Tighten, -Tighten writes LF, a rise still fails'
  exit 0
}

# ------------------------------------------------------------------------------------- live run
# NEVER SCAN YOURSELF. This file's own self-test carries verbatim bypass fixtures as CODE - they are
# arguments to Test-TcSeamBypass, not comments, so the comment filter does not reach them and the
# detector would report six bypasses inside its own must-fire cases. run-gates carries the same rule for
# the same reason. The cost is that a genuine bypass added to this file is missed; it makes no HTTP
# calls, so that is a trade worth taking rather than mangling the fixtures to hide from the matcher.
$files = @(Get-SeamScanFiles -RootDir $treeRoot -Self $PSCommandPath)
if (-not $files.Count) {
  Write-Output 'WRITE-SEAM AUDIT BLIND: found zero .ps1 files to scan, which means the discovery is broken rather than the tree being clean.'
  Exit-Guard -Name 'write-seam' -Summary 'blind=no-files' -Code 3
}
$hits = Get-TcSeamBypasses -Files $files -ReadLines { param($p) [IO.File]::ReadAllLines($p) }
$hits = @($hits)
$count = $hits.Count

if (-not (Test-Path -LiteralPath $BASELINE_FILE)) {
  $json = @{ generated = (Get-Date).ToString('s'); sites = $count
     note = 'HIGH-WATER MARK for mutating calls to our own surfaces that bypass Invoke-GhostApi. This number may only go DOWN. A run above it is a NEW bypass and hard-fails.' } | ConvertTo-Json -Depth 3
  # LF with the BOM the committed blob carries, not the CRLF Set-Content writes under PS 5.1 (lib\lf-write.ps1).
  $null = Write-TcLfFile $BASELINE_FILE $json
  Write-Output ("write-seam: baseline written at {0} site(s). From here the number may only go DOWN." -f $count)
  Exit-Guard -Name 'write-seam' -Summary ("baseline={0}" -f $count) -Code 0
}
$base = [int]((Get-Content $BASELINE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json).sites)

foreach ($h in ($hits | Sort-Object File, Line)) {
  Write-Output ("  bypass  {0}:{1}" -f $h.File.Replace($treeRoot, '').TrimStart('\'), $h.Line)
}
if ($count -gt $base) {
  Write-Output ("WRITE-SEAM AUDIT FAILED: {0} mutating call(s) to our own surfaces now bypass Invoke-GhostApi, against a baseline of {1}. A NEW irreversible write was added outside the E1 safety layer - the staging gate and the journal cannot see it. Route it through Invoke-GhostApi." -f $count, $base)
  Exit-Guard -Name 'write-seam' -Summary ("sites={0} baseline={1}" -f $count, $base) -Code 2
}
# THE FALL IS THE DIRECTION THAT CANNOT BE TRUSTED (2026-09-07, backlog I15). This block used to
# lower the baseline unconditionally, so a detector that broke and found NOTHING recorded 0 as the
# permanent ceiling and printed "PASSED and TIGHTENED" forever after. lib\ratchet.ps1 refuses a fall
# to zero or a fall over 60% in one run, KEEPS the old baseline, and says what to check. -AcceptDrop
# records a genuine bulk migration in one flag rather than a hand-edited baseline file.
$move = Test-RatchetMove -Name 'write-seam' -Count $count -Baseline $base -AcceptDrop:$AcceptDrop
if ($move.Verdict -eq 'implausible') {
  Write-Output $move.Message
  Exit-Guard -Name 'write-seam' -Summary ("sites={0} baseline={1} refused-to-lower" -f $count, $base) -Code 2
}
if ($move.Verdict -eq 'tightened') {
  # A FALL IS SPOKEN, NOT WRITTEN, unless this run was asked to record it (2026-09-11, see the header). -AcceptDrop
  # is such an ask: it has always recorded the fall it names.
  if (-not ($Tighten -or $AcceptDrop)) {
    Write-Output ("write-seam: PASSED, and the ratchet CAN tighten - {0} known bypass(es), baseline {1}. NOT written: this may be a pre-push gate, and a rewrite here dirties the checkout being pushed without riding the push. Record it with -Tighten and commit ops\write-seam-baseline.json." -f $count, $base)
    Exit-Guard -Name 'write-seam' -Summary ("sites={0} baseline={1} can-tighten" -f $count, $base) -Code 0
  }
  $doc = $null
  try { $doc = Get-Content $BASELINE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
  if (-not $doc) { $doc = [pscustomobject]@{} }
  $hist = Add-RatchetHistory -Doc $doc -Count $count
  $json = @{ generated = (Get-Date).ToString('s'); sites = $move.NewBaseline; history = $hist
     note = 'HIGH-WATER MARK for mutating calls to our own surfaces that bypass Invoke-GhostApi. This number may only go DOWN, and a fall to zero or a fall over 60% in one run is REFUSED as a probably-broken detector.' } | ConvertTo-Json -Depth 5
  $null = Write-TcLfFile $BASELINE_FILE $json
  # The library message already names the guard; prefixing it again read as "x: ... x: ...".
  Write-Output ("PASSED and TIGHTENED - " + $move.Message)
  Write-Output ("  " + (Get-RatchetTrend -History $hist))
  Exit-Guard -Name 'write-seam' -Summary ("sites={0} tightened-from={1}" -f $count, $base) -Code 0
}
Write-Output ("write-seam: PASSED - {0} known bypass(es), unchanged from the baseline. These are irreversible writes the E1 safety layer does NOT cover; each one migrated to Invoke-GhostApi lowers the mark permanently." -f $count)
Exit-Guard -Name 'write-seam' -Summary ("sites={0} baseline={1}" -f $count, $base) -Code 0
