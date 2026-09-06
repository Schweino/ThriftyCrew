<#
  audit-feed-week-parity.ps1 - the board and the feed must be quoting the SAME WEEK.

  WHY THIS EXISTS (2026-09-06, backlog E1's daily half). Earlier today guards.ps1 hard-failed at
  08:15:51, so the daily run's publish stage staged INPUTS ONLY and shipped neither public\** nor the
  recipe files. Triage then unblocked the guard and republished the BOARD twice - and did not re-export
  the FEED. The board page went live at week_of 2026-09-06 while feed.thriftycrew.com still served
  2026-09-02, four days stale, and 583 recipe pages price off that feed.

  The board page and 583 recipe pages quoted DIFFERENT WEEKS for four and a half hours, on a live paid
  site, and nothing anywhere said so.

  WHY A DETERMINISTIC RULE AND NOT THE PRE-PUBLISH REVIEWER. E1's staging gate shows a reviewer what IS
  about to be sent. This failure was an OMISSION - the feed export simply did not run - and an omission
  is invisible to a queue: there is no wrong call to look at, only a missing one. A reviewer would have
  had to KNOW a feed publish was expected. So this asks the question directly, costs no agent call, and
  adds no dependency to the daily chain.

  THE ASYMMETRY IS THE REPAIR, and the triage commit that fixed today's incident says so in as many
  words: regenerated pipeline output "is the pipeline's to commit, not yours" on an ordinary day, and
  WRONG on the day you unblock a guards failure - because on that day the pipeline deliberately shipped
  none of it. That is precisely when the two drift, and precisely when nobody is looking for it.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 hard finding, 3 could-not-evaluate.
  Read the verdict LINE, not the number (backlog E2).

  Self-test: powershell -File grocery\audit-feed-week-parity.ps1 -SelfTest
#>
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

function Test-TcFeedWeekParity {
  <# Pure. $BoardWeek is the week the newest comparison board carries; $FeedWeek is what smp-feed.json
     says. Returns the verdict and, when they differ, how far apart they are - because "one day" and
     "four days" are different conversations and the number is what makes it obvious which. #>
  param([string]$BoardWeek, [string]$FeedWeek)
  if (-not $BoardWeek) { return ([pscustomobject]@{ Ok = $false; Blind = $true; Detail = 'no comparison board found, so the board week is unknown - nothing was compared' }) }
  if (-not $FeedWeek)  { return ([pscustomobject]@{ Ok = $false; Blind = $true; Detail = 'the feed carries no week_of, so nothing could be compared against it' }) }
  if ($BoardWeek -eq $FeedWeek) {
    return ([pscustomobject]@{ Ok = $true; Blind = $false; Detail = ("board and feed both at " + $BoardWeek) })
  }
  $gap = ''
  try {
    $d1 = [datetime]::ParseExact($BoardWeek, 'yyyy-MM-dd', $null)
    $d2 = [datetime]::ParseExact($FeedWeek, 'yyyy-MM-dd', $null)
    $gap = (" - {0} day(s) apart" -f [math]::Abs(($d1 - $d2).Days))
  } catch { $gap = '' }
  return ([pscustomobject]@{ Ok = $false; Blind = $false
    Detail = ("the board is at " + $BoardWeek + " and the feed is at " + $FeedWeek + $gap +
              ". Every recipe page prices off the feed, so the board page and the recipe pages are quoting different weeks right now. Re-run export-feed.ps1 against the CURRENT comparison and commit smp-feed.json.") })
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0
  function T($m, $cond, $got) { if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }

  $r1 = Test-TcFeedWeekParity -BoardWeek '2026-09-06' -FeedWeek '2026-09-06'
  T 'CLEAN TWIN board and feed on the same week passes' ($r1.Ok -eq $true) $r1.Detail

  # THE FOUNDING CASE, frozen with the real dates: board 09-06, feed 09-02, four days.
  $r2 = Test-TcFeedWeekParity -BoardWeek '2026-09-06' -FeedWeek '2026-09-02'
  T 'MUST FIRE  the 2026-09-06 incident - board republished, feed not - is a finding' `
    ($r2.Ok -eq $false -and -not $r2.Blind) $r2.Detail
  T 'MUST FIRE  ...and it says HOW FAR apart, because one day and four days are different conversations' `
    ($r2.Detail -like '*4 day(s) apart*') $r2.Detail

  # One day apart is still wrong. A tolerance here would swallow the ordinary rollover case.
  $r3 = Test-TcFeedWeekParity -BoardWeek '2026-09-06' -FeedWeek '2026-09-05'
  T 'MUST FIRE  one day apart is still a finding - no tolerance, or the ordinary case slips through' ($r3.Ok -eq $false) $r3.Detail

  # BLIND is not clean and is not a finding. Both halves matter: a missing board must not read as pass,
  # and it must not read as a mismatch either.
  $r4 = Test-TcFeedWeekParity -BoardWeek '' -FeedWeek '2026-09-06'
  T 'MUST FIRE  no board at all is BLIND, never a pass' ($r4.Blind -eq $true -and $r4.Ok -eq $false) $r4.Detail
  $r5 = Test-TcFeedWeekParity -BoardWeek '2026-09-06' -FeedWeek ''
  T 'MUST FIRE  a feed with no week_of is BLIND, never a pass' ($r5.Blind -eq $true -and $r5.Ok -eq $false) $r5.Detail

  # An unparseable date must not crash the comparison - it is still a mismatch, just without the gap.
  $r6 = Test-TcFeedWeekParity -BoardWeek '2026-09-06' -FeedWeek 'not-a-date'
  T 'CLEAN TWIN an unparseable week is still a mismatch and does not throw' ($r6.Ok -eq $false -and -not $r6.Blind) $r6.Detail

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: the frozen 2026-09-06 incident with its day gap, the no-tolerance case, both blind halves, and an unparseable date'
  exit 0
}

# ------------------------------------------------------------------------------------- live run
$out = Join-Path $here 'out'
$cmp = @(Get-ChildItem $out -Filter 'comparison-*.json' -File -ErrorAction SilentlyContinue |
  Sort-Object Name -Descending | Select-Object -First 1)
$boardWeek = ''
if ($cmp.Count) { if ($cmp[0].BaseName -match 'comparison-(\d{4}-\d{2}-\d{2})') { $boardWeek = $Matches[1] } }

$feedWeek = ''
$feedFile = Join-Path $out 'smp-feed.json'
if (Test-Path -LiteralPath $feedFile) {
  try { $feedWeek = [string]((Get-Content $feedFile -Raw -Encoding UTF8 | ConvertFrom-Json).week_of) } catch { $feedWeek = '' }
}

$v = Test-TcFeedWeekParity -BoardWeek $boardWeek -FeedWeek $feedWeek
if ($v.Blind) {
  Write-Output ("FEED-WEEK-PARITY BLIND: {0}. Unknown is not a pass." -f $v.Detail)
  Write-GuardComplete -Name 'feed-week-parity' -Summary 'blind=1'
  exit 3
}
if (-not $v.Ok) {
  Write-Output ("FEED-WEEK-PARITY FAILED: {0}" -f $v.Detail)
  Write-GuardComplete -Name 'feed-week-parity' -Summary ("board={0} feed={1}" -f $boardWeek, $feedWeek)
  exit 2
}
Write-Output ("feed-week-parity: PASSED - {0}." -f $v.Detail)
Write-GuardComplete -Name 'feed-week-parity' -Summary ("week={0}" -f $boardWeek)
exit 0
