<#
  audit-recost-freshness.ps1 - the recipe costs must be priced off the board that is live now.

  WHY THIS EXISTS (2026-09-07). The open half of the 2026-09-06 incident. That day guards.ps1
  hard-failed at 08:15, so the daily run's publish stage staged INPUTS ONLY - "guards BLOCKED this
  board, so public\** and the recipe files are NOT shipped". Triage then unblocked the guard and
  rebuilt the board at 11:55. The FEED half of the asymmetry was caught the same day and fixed: after a
  republish, re-run export-feed against the CURRENT comparison. The RECOST half was not. db\costed.json
  stayed at 09:51, priced off the superseded board, for twenty hours, and nothing in the estate could
  say so.

  WHY NO CLOCK CAN ANSWER THIS, which is the whole reason a stamp had to be added first. cost-recipes
  picks its board by filename descending, and a rebuild REUSES the filename: comparison-2026-09-06.json
  at 05:24 and the corrected one at 11:55 are the same name with different bytes. So a filename
  comparison sees nothing. An mtime comparison is worse than nothing - this estate has a standing scar
  about mtime moving on files whose content did not change. The only thing that identifies a build of
  the board is the board's own built_at, and until 2026-09-07 the recost recorded nothing at all.

  IT COMPARES IDENTITIES, NOT AGE. db\costed.stamp.json records the built_at of the board the whole
  catalog was priced from; this reads the newest board's built_at and requires them to match.

  A PARTIAL RECOST IS NOT FRESHNESS. cost-recipes -Slugs re-prices a handful of recipes and splices
  them in, and deliberately does not advance the stamp. A catalog is not priced off today's board
  because three of its rows are, and a guard that accepted that would lie in the reassuring direction.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 hard finding, 3 could-not-evaluate.
  Read the verdict LINE, not the number (backlog E2).

  Self-test: powershell -File meal-prep\pipeline\audit-recost-freshness.ps1 -SelfTest
#>
param([switch]$SelfTest, [string]$DbRoot = '', [string]$GroceryOut = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\meal-prep\pipeline' }
$mp = Split-Path $here -Parent
$repo = Split-Path $mp -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

function Test-RecostFresh {
  <# (Verdict, Message) from a stamp and a board document.

     Verdicts: 'fresh', 'stale', 'unknown'. 'unknown' is NOT a pass - a missing stamp means the recost
     predates this guard or the stamp write failed, and either way the question is unanswered. #>
  param($Stamp, $BoardBuiltAt, [string]$BoardFile)

  if (-not $BoardBuiltAt) {
    return @('unknown', 'the newest board records no built_at, so there is nothing to compare a recost against')
  }
  if (-not $Stamp) {
    return @('unknown', ("db\costed.stamp.json does not exist, so which board the catalog was priced from is unrecorded. That is the state every recost before 2026-09-07 is in - it is not evidence that the costs are current. Run cost-recipes.ps1 to stamp it."))
  }
  $was = [string]$Stamp.board_built_at
  if (-not $was) {
    return @('unknown', 'the stamp exists but records no board_built_at, so the comparison cannot be made')
  }
  if ($was -eq [string]$BoardBuiltAt) {
    $scope = [string]$Stamp.scope
    return @('fresh', ("the catalog was priced from the board that is live now ({0}, built {1}, last full recost {2})" -f $BoardFile, $BoardBuiltAt, $scope))
  }
  return @('stale', ("the catalog was priced from a board built {0}; the board live now was built {1}. The filename is the same either way, which is why nothing noticed on 2026-09-06 - a rebuild reuses it. Re-run meal-prep\engine\cost-recipes.ps1 against the current board before any recipe ships." -f $was, $BoardBuiltAt))
}

if ($SelfTest) {
  $fail = 0
  function T($n, $c, $g = '') { if ($c) { Write-Output ("ok    " + $n) } else { Write-Output ("FAIL  " + $n + "   got: " + $g); $script:fail++ } }

  $stampFull = [pscustomobject]@{ scope = 'full'; board_built_at = '2026-09-06T11:55:42'; board_file = 'comparison-2026-09-06.json' }

  $v, $m = Test-RecostFresh $stampFull '2026-09-06T11:55:42' 'comparison-2026-09-06.json'
  T 'CLEAN TWIN a catalog priced from the live board is fresh' ($v -eq 'fresh') "$v $m"

  # THE FOUNDING CASE, with the real numbers. Same filename, different build - which is exactly why
  # nothing in the estate noticed for twenty hours.
  $stampOld = [pscustomobject]@{ scope = 'full'; board_built_at = '2026-09-06T05:24:48'; board_file = 'comparison-2026-09-06.json' }
  $v, $m = Test-RecostFresh $stampOld '2026-09-06T11:55:42' 'comparison-2026-09-06.json'
  T 'MUST FIRE  a recost priced from an EARLIER build of the SAME filename is stale' ($v -eq 'stale') "$v"
  T 'the message says the filename is the same, which is why it went unseen' ($m -like '*rebuild reuses it*') $m

  # A missing stamp must not read as a pass. Every recost before this guard is in that state.
  $v, $m = Test-RecostFresh $null '2026-09-06T11:55:42' 'comparison-2026-09-06.json'
  T 'MUST FIRE  no stamp is UNKNOWN, not fresh' ($v -eq 'unknown') $v
  T 'and it says an absent stamp is not evidence the costs are current' ($m -like '*not evidence*') $m

  $v, $m = Test-RecostFresh $stampFull $null 'comparison-2026-09-06.json'
  T 'MUST FIRE  a board with no built_at is UNKNOWN rather than fresh' ($v -eq 'unknown') $v

  $v, $m = Test-RecostFresh ([pscustomobject]@{ scope = 'full' }) '2026-09-06T11:55:42' 'x.json'
  T 'a stamp with no board_built_at cannot answer the question' ($v -eq 'unknown') $v

  # A PARTIAL recost carries the OLD board stamp by design, so it must still read stale against a new
  # board. This is the case where a guard could most easily be made to lie in the reassuring direction.
  $stampPartial = [pscustomobject]@{ scope = 'partial'; board_built_at = '2026-09-06T05:24:48'; partial_priced_from = '2026-09-06T11:55:42' }
  $v, $m = Test-RecostFresh $stampPartial '2026-09-06T11:55:42' 'comparison-2026-09-06.json'
  T 'MUST FIRE  a -Slugs recost does not make the CATALOG fresh' ($v -eq 'stale') "$v"

  if ($fail -gt 0) { Write-Output ("SELF-TEST FAIL: {0} case(s)" -f $fail); Write-GuardComplete -Name 'recost-freshness' -Summary ("selftest-fail={0}" -f $fail); exit 2 }
  Write-Output 'SELF-TEST PASS: the founding case where the same filename holds a different build, the absent stamp that must not read as a pass, and the partial recost that must not launder the catalog'
  Exit-Guard -Name 'recost-freshness' -Summary 'selftest=pass' -Code 0
}

$db = if ($DbRoot) { $DbRoot } else { Join-Path $mp 'db' }
$gout = if ($GroceryOut) { $GroceryOut } else { Join-Path $repo 'grocery\out' }

$boardFile = Get-ChildItem (Join-Path $gout 'comparison-*.json') -File -ErrorAction SilentlyContinue |
  Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
if (-not $boardFile) {
  Write-Output ("RECOST FRESHNESS COULD NOT EVALUATE: no comparison board under {0}. The boards are gitignored, so a worktree, a CI runner or a clean checkout lands here - that is blindness, NOT a clean tree." -f $gout)
  Exit-Guard -Name 'recost-freshness' -Summary 'blind=no-board' -Code 3
}
try { $boardDoc = Get-Content $boardFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
  Write-Output ("RECOST FRESHNESS COULD NOT EVALUATE: {0} did not parse: {1}" -f $boardFile.Name, $_.Exception.Message)
  Exit-Guard -Name 'recost-freshness' -Summary 'blind=board-unparsed' -Code 3
}

$stampPath = Join-Path $db 'costed.stamp.json'
$stamp = $null
if (Test-Path $stampPath) { try { $stamp = Get-Content $stampPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $stamp = $null } }

$verdict, $msg = Test-RecostFresh $stamp ([string]$boardDoc.built_at) $boardFile.Name

if ($verdict -eq 'stale') {
  Write-Output ("RECOST FRESHNESS AUDIT FAILED: " + $msg)
  Exit-Guard -Name 'recost-freshness' -Summary ("stale board_now={0}" -f $boardDoc.built_at) -Code 2
}
if ($verdict -eq 'unknown') {
  Write-Output ("RECOST FRESHNESS COULD NOT EVALUATE: " + $msg)
  Exit-Guard -Name 'recost-freshness' -Summary 'blind=no-stamp' -Code 3
}
Write-Output ("recost-freshness: PASSED - " + $msg)
Exit-Guard -Name 'recost-freshness' -Summary ("fresh built_at={0}" -f $boardDoc.built_at) -Code 0
