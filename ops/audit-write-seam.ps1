<#
  audit-write-seam.ps1 - the E1 safety layer is only as good as its chokepoint being the ONLY door.

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

  Self-test: powershell -File ops\audit-write-seam.ps1 -SelfTest
#>
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

$BASELINE_FILE = Join-Path $repo 'ops\write-seam-baseline.json'

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
  T 'CLEAN TWIN a file with only reads yields nothing' ((@($r0)).Count -eq 0) ("Count=" + @($r0).Count)

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: 6 must-fire bypass shapes, 4 clean twins including a store search POST, plus the scanner and its return arity'
  exit 0
}

# ------------------------------------------------------------------------------------- live run
# NEVER SCAN YOURSELF. This file's own self-test carries verbatim bypass fixtures as CODE - they are
# arguments to Test-TcSeamBypass, not comments, so the comment filter does not reach them and the
# detector would report six bypasses inside its own must-fire cases. run-gates carries the same rule for
# the same reason. The cost is that a genuine bypass added to this file is missed; it makes no HTTP
# calls, so that is a trade worth taking rather than mangling the fixtures to hide from the matcher.
$files = @(Get-ChildItem $repo -Recurse -File -Filter *.ps1 -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -notmatch $EXCLUDE -and $_.FullName -ne $PSCommandPath } | ForEach-Object { $_.FullName })
if (-not $files.Count) {
  Write-Output 'WRITE-SEAM AUDIT BLIND: found zero .ps1 files to scan, which means the discovery is broken rather than the tree being clean.'
  Write-GuardComplete -Name 'write-seam' -Summary 'blind=no-files'
  exit 3
}
$hits = Get-TcSeamBypasses -Files $files -ReadLines { param($p) [IO.File]::ReadAllLines($p) }
$hits = @($hits)
$count = $hits.Count

if (-not (Test-Path -LiteralPath $BASELINE_FILE)) {
  @{ generated = (Get-Date).ToString('s'); sites = $count
     note = 'HIGH-WATER MARK for mutating calls to our own surfaces that bypass Invoke-GhostApi. This number may only go DOWN. A run above it is a NEW bypass and hard-fails.' } |
    ConvertTo-Json -Depth 3 | Set-Content $BASELINE_FILE -Encoding UTF8
  Write-Output ("write-seam: baseline written at {0} site(s). From here the number may only go DOWN." -f $count)
  Write-GuardComplete -Name 'write-seam' -Summary ("baseline={0}" -f $count)
  exit 0
}
$base = [int]((Get-Content $BASELINE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json).sites)

foreach ($h in ($hits | Sort-Object File, Line)) {
  Write-Output ("  bypass  {0}:{1}" -f $h.File.Replace($repo, '').TrimStart('\'), $h.Line)
}
if ($count -gt $base) {
  Write-Output ("WRITE-SEAM AUDIT FAILED: {0} mutating call(s) to our own surfaces now bypass Invoke-GhostApi, against a baseline of {1}. A NEW irreversible write was added outside the E1 safety layer - the staging gate and the journal cannot see it. Route it through Invoke-GhostApi." -f $count, $base)
  Write-GuardComplete -Name 'write-seam' -Summary ("sites={0} baseline={1}" -f $count, $base)
  exit 2
}
if ($count -lt $base) {
  @{ generated = (Get-Date).ToString('s'); sites = $count
     note = 'HIGH-WATER MARK for mutating calls to our own surfaces that bypass Invoke-GhostApi. This number may only go DOWN. A run above it is a NEW bypass and hard-fails.' } |
    ConvertTo-Json -Depth 3 | Set-Content $BASELINE_FILE -Encoding UTF8
  Write-Output ("write-seam: PASSED and TIGHTENED - {0} bypass(es), down from {1}. Baseline lowered; it can never rise again." -f $count, $base)
  Write-GuardComplete -Name 'write-seam' -Summary ("sites={0} tightened-from={1}" -f $count, $base)
  exit 0
}
Write-Output ("write-seam: PASSED - {0} known bypass(es), unchanged from the baseline. These are irreversible writes the E1 safety layer does NOT cover; each one migrated to Invoke-GhostApi lowers the mark permanently." -f $count)
Write-GuardComplete -Name 'write-seam' -Summary ("sites={0} baseline={1}" -f $count, $base)
exit 0
