<#
  member-cohorts.ps1 - what fraction of each month's signups is still paying?

  SCOPE OF A CLEAN REPORT: SOUND over the members Ghost returns, silent about everything else. It
    counts every member in the paged response, so its buckets really are the whole membership as of
    the run. It says nothing about WHEN anyone left - see the standing limit below, which is the
    single most important thing about this file.

  WHY THIS EXISTS (2026-09-08, backlog I97). This is a live paid membership and nobody knew what
  fraction of each month's intake was still paying. Every Ghost members call in the tree was
  TRANSACTIONAL - find one member, PUT a label, gate paid content, email the list - and `created_at`
  was never read for a member anywhere. There was no member export, no cohort table, no retention
  curve, no churn figure and no LTV number in this repo. Two businesses acquiring identically diverge
  entirely on that number, and every acquisition-side item in the backlog sits on top of it.

  ================================ THE PRIVACY BOUNDARY ================================
  RULED BY BRAD, 2026-09-08, option B of three: an aggregate-only pull may happen. Per-member rows on
  disk were considered and REFUSED at any price.

  MEMBER EMAILS HAVE NEVER TOUCHED THIS REPO AND THIS SCRIPT DOES NOT START. Four rules, and each one
  is ENFORCED here rather than intended:

    1. Only three properties are ever read off a member: created_at, status, id. `id` is used solely
       to count and is never stored. The email property is never referenced by name anywhere below.
    2. The aggregate is built from integers and 'yyyy-MM' strings ONLY, so no address can reach the
       output structurally rather than by care.
    3. NO TEMP FILE, EVER. There is no intermediate write of any kind - the response lives in memory
       and the only thing that touches disk is the bucketed count.
    4. THE OUTPUT PATH IS ASSERTED BEFORE THE FIRST API CALL. If the destination is wrong, nothing is
       fetched at all. Fetching first and validating afterwards would mean a bad path is discovered
       with the data already in hand, which is the wrong order for exactly this kind of data.

  It is also run BY HAND. It is not in the daily chain, not in run-gates, and has no schedule.
  ======================================================================================

  THE LIMIT THAT DECIDES WHAT THIS CAN ANSWER, and it is not a caveat, it is the shape of the result.
  Ghost's members API gives CURRENT status, not a status history. So this can say how many January
  signups are still paid; it CANNOT distinguish a member who cancelled in month 2 from one who
  cancelled in month 8. That yields ONE ENDPOINT PER COHORT AND NOT A CURVE - and the curve shapes
  (a cliff drop against gradual churn, and which period the cliff lands in) are where all the
  diagnostic value is. Backlog I98 is the fix - a monthly committed snapshot, a few dozen bytes -
  and every month it is deferred is a month of curve that can never be recovered. I98 WAS NOT
  AUTHORISED IN THE SAME RULING and is deliberately not started here.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 done, 2 hard finding, 3 could-not-evaluate.
  Read the verdict LINE, not the number (backlog E2).

  Usage:   powershell -File ops\member-cohorts.ps1            (fetch, aggregate, write the counts)
           powershell -File ops\member-cohorts.ps1 -WhatIf    (assert the path, fetch NOTHING)
           powershell -File ops\member-cohorts.ps1 -SelfTest  (pure, touches no network)
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param([switch]$SelfTest, [switch]$WhatIf, [string]$OutFile = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

# The three properties this script is permitted to touch on a member. Written as data so the
# self-test can assert the list has not grown - a fourth entry here is a privacy change and should
# read as one in a diff.
$ALLOWED_MEMBER_FIELDS = @('id', 'created_at', 'status')

function Get-TcCohortKey {
  <# A signup timestamp to its 'yyyy-MM' bucket. Returns '' when the stamp is unusable, so the caller
     can COUNT the unusable ones rather than silently dropping them into a wrong month. Pure. #>
  param([string]$CreatedAt)
  if (-not $CreatedAt) { return '' }
  $d = [datetime]::MinValue
  # ParseExact would be brittle across Ghost's ISO variants; TryParse with a round-trip-friendly
  # style is what actually holds. A failure returns '' and is counted, never guessed at.
  if ([datetime]::TryParse($CreatedAt, [Globalization.CultureInfo]::InvariantCulture,
                           [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$d)) {
    return $d.ToString('yyyy-MM')
  }
  return ''
}

function Get-TcCohortTable {
  <# The whole aggregation, as a pure function over (created_at, status) pairs, so the fixtures drive
     the privacy-critical logic without a network call.

     Returns @{ Buckets = @{ 'yyyy-MM' = @{ status = count } }; Total; Undated; Statuses }.

     NOTE WHAT IS NOT IN THE RETURN: no id, no address, no member object. The output structure can
     only hold month strings, status strings and integers, which is rule 2 of the privacy boundary
     expressed as a type rather than as a promise. #>
  param([object[]]$Pairs)
  $buckets = @{}
  $statuses = @{}
  $total = 0; $undated = 0
  foreach ($p in @($Pairs)) {
    if ($null -eq $p) { continue }
    $total++
    $st = [string]$p.status
    if (-not $st) { $st = 'unknown' }
    if (-not $statuses.ContainsKey($st)) { $statuses[$st] = 0 }
    $statuses[$st]++
    $k = Get-TcCohortKey ([string]$p.created_at)
    if (-not $k) { $undated++; continue }
    if (-not $buckets.ContainsKey($k)) { $buckets[$k] = @{} }
    if (-not $buckets[$k].ContainsKey($st)) { $buckets[$k][$st] = 0 }
    $buckets[$k][$st]++
  }
  return @{ Buckets = $buckets; Total = $total; Undated = $undated; Statuses = $statuses }
}

function Test-TcOutputPathSafe {
  <# RULE 4. Asserted BEFORE the first API call: fetching and then discovering the destination is
     wrong means the data is already in hand. Returns '' when safe, or the reason it is not. Pure. #>
  param([string]$Path, [string]$Repo)
  if (-not $Path) { return 'no output path was given' }
  if (-not [IO.Path]::IsPathRooted($Path)) { return "output path '$Path' is not absolute" }
  if ([IO.Path]::GetExtension($Path) -ne '.json') { return "output path '$Path' is not a .json file" }
  $full = [IO.Path]::GetFullPath($Path)
  $root = [IO.Path]::GetFullPath($Repo).TrimEnd('\') + '\'
  if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
    return "output path '$full' is outside the repo, and this file may only write inside it"
  }
  if ($full -match '\\\.git\\') { return "output path '$full' is inside .git" }
  $dir = Split-Path $full -Parent
  if (-not (Test-Path -LiteralPath $dir)) { return "output directory '$dir' does not exist" }
  return ''
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0
  function T($m, $cond, $got) { if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }

  # EVERY FIXTURE IS A SINGLE-QUOTED LITERAL where it is a string.
  $pairs = @(
    [pscustomobject]@{ created_at = '2026-01-14T10:00:00.000Z'; status = 'paid' },
    [pscustomobject]@{ created_at = '2026-01-20T10:00:00.000Z'; status = 'free' },
    [pscustomobject]@{ created_at = '2026-01-28T10:00:00.000Z'; status = 'paid' },
    [pscustomobject]@{ created_at = '2026-02-03T10:00:00.000Z'; status = 'paid' },
    [pscustomobject]@{ created_at = 'not a date';               status = 'paid' },
    [pscustomobject]@{ created_at = '2026-02-09T10:00:00.000Z'; status = '' }
  )
  $t = Get-TcCohortTable -Pairs $pairs
  T 'MUST NOT FIRE  members bucket by signup MONTH and by status: January is 2 paid, 1 free' `
    (($t.Buckets['2026-01']['paid'] -eq 2) -and ($t.Buckets['2026-01']['free'] -eq 1)) `
    ("jan paid=" + $t.Buckets['2026-01']['paid'])
  T 'MUST FIRE  THE ONE THAT KEEPS THE NUMBER HONEST - an unparseable signup date is COUNTED as undated, never guessed into a month' `
    (($t.Undated -eq 1) -and ($t.Total -eq 6)) ("undated=" + $t.Undated + " total=" + $t.Total)
  T 'MUST NOT FIRE  a blank status becomes "unknown" rather than vanishing, so the statuses sum to the total' `
    ((($t.Statuses.Values | Measure-Object -Sum).Sum -eq 6) -and ($t.Statuses['unknown'] -eq 1)) `
    ("sum=" + ($t.Statuses.Values | Measure-Object -Sum).Sum)
  $empty = Get-TcCohortTable -Pairs @()
  T 'MUST NOT FIRE  an EMPTY membership totals 0, not 1 - @($null).Count is 1 in PS 5.1 and would have invented a member' `
    (($empty.Total -eq 0) -and ($empty.Buckets.Keys.Count -eq 0)) ("total=" + $empty.Total)

  # THE PRIVACY ASSERTIONS. These are the cases that matter most in this file.
  $withEmail = @([pscustomobject]@{ created_at = '2026-03-01T00:00:00Z'; status = 'paid'
                                    email = 'someone@example.com'; name = 'A Person' })
  $t2 = Get-TcCohortTable -Pairs $withEmail
  $blob = ($t2 | ConvertTo-Json -Depth 6)
  T 'MUST FIRE  THE FOUNDING CONSTRAINT - even when the input row CARRIES an email, no address reaches the aggregate, because the output can structurally only hold months, statuses and integers' `
    (($blob -notmatch 'example\.com') -and ($blob -notmatch '@') -and ($blob -notmatch 'A Person')) `
    'an address or a name survived into the aggregate'
  T 'CLEAN TWIN the permitted-field list has not grown - a fourth entry is a privacy change and must read as one' `
    (($ALLOWED_MEMBER_FIELDS.Count -eq 3) -and ($ALLOWED_MEMBER_FIELDS -notcontains 'email')) `
    ($ALLOWED_MEMBER_FIELDS -join ',')

  $r = 'C:\Codex\ThriftyCrew'
  T 'MUST FIRE  an output path OUTSIDE the repo is refused' `
    ((Test-TcOutputPathSafe -Path 'C:\Temp\members.json' -Repo $r) -like '*outside the repo*') `
    (Test-TcOutputPathSafe -Path 'C:\Temp\members.json' -Repo $r)
  T 'MUST FIRE  a non-.json destination is refused, so this cannot be pointed at a log or a csv' `
    ((Test-TcOutputPathSafe -Path 'C:\Codex\ThriftyCrew\ops\members.csv' -Repo $r) -like '*not a .json*') `
    (Test-TcOutputPathSafe -Path 'C:\Codex\ThriftyCrew\ops\members.csv' -Repo $r)
  T 'MUST FIRE  a relative path is refused rather than resolved against whatever the cwd happens to be' `
    ((Test-TcOutputPathSafe -Path 'members.json' -Repo $r) -like '*not absolute*') `
    (Test-TcOutputPathSafe -Path 'members.json' -Repo $r)
  T 'MUST NOT FIRE  the real destination under ops\ is accepted' `
    ((Test-TcOutputPathSafe -Path (Join-Path $r 'ops\member-cohorts.json') -Repo $r) -eq '') `
    (Test-TcOutputPathSafe -Path (Join-Path $r 'ops\member-cohorts.json') -Repo $r)

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: 5 must-fire cases led by the founding privacy constraint (an input row carrying an email produces an aggregate that cannot contain one) and the undated-signup count, 4 must-not-fire cases including the empty membership, and 1 clean twin pinning the permitted-field list at three'
  exit 0
}

# ------------------------------------------------------------------------------- the live run
if (-not $OutFile) { $OutFile = Join-Path $repo 'ops\member-cohorts.json' }

# RULE 4: ASSERT THE DESTINATION BEFORE ANYTHING IS FETCHED.
$why = Test-TcOutputPathSafe -Path $OutFile -Repo $repo
if ($why) {
  Write-Output ("MEMBER COHORTS REFUSED: {0}. Nothing was fetched - the path is checked BEFORE the first API call, on purpose." -f $why)
  Write-GuardComplete -Name 'member-cohorts' -Summary 'refused=bad-output-path'
  exit 2
}
Write-Output ("output path asserted safe BEFORE any fetch: {0}" -f $OutFile)
if ($WhatIf) {
  Write-Output 'WHATIF: the path is valid and NOTHING was fetched. Re-run without -WhatIf to pull.'
  Write-GuardComplete -Name 'member-cohorts' -Summary 'whatif=path-ok'
  exit 0
}

$adminKey = $env:GHOST_ADMIN_KEY
if (-not $adminKey) {
  $kf = Join-Path $repo 'meal-prep\.ghostkey'
  if (Test-Path $kf) { $adminKey = (Get-Content $kf -Raw).Trim() }
}
if (-not $adminKey) {
  Write-Output 'MEMBER COHORTS BLIND: no GHOST_ADMIN_KEY and no meal-prep\.ghostkey, so nothing was read. That is could-not-evaluate, never "no members".'
  Write-GuardComplete -Name 'member-cohorts' -Summary 'blind=no-key'
  exit 3
}
. (Join-Path $repo 'lib\ghost-lib.ps1')
$apiUrl = 'https://map-to-success.ghost.io'

# Only the three permitted properties are requested. If Ghost ignores `fields` the extra properties
# arrive in memory and are simply never referenced - rules 1 and 2 hold either way.
$pairs = New-Object System.Collections.ArrayList
$page = 1; $limit = 500; $pagesRead = 0; $lastPages = $null
try {
  while ($true) {
    $jwt = Get-GhostJWT -Key $adminKey
    $hdr = @{ Authorization = "Ghost $jwt"; 'Accept-Version' = 'v5.0' }
    $uri = ($apiUrl + '/ghost/api/admin/members/?limit=' + $limit + '&page=' + $page +
            '&fields=' + ($ALLOWED_MEMBER_FIELDS -join ','))
    $res = Invoke-RestMethod -Uri $uri -Headers $hdr -TimeoutSec 60
    $batch = @($res.members)
    foreach ($m in $batch) {
      # THE ONLY TWO PROPERTIES EVER READ. Nothing else on $m is touched, and $m is not retained.
      [void]$pairs.Add([pscustomobject]@{ created_at = [string]$m.created_at; status = [string]$m.status })
    }
    $pagesRead++
    if ($res.meta -and $res.meta.pagination) { $lastPages = $res.meta.pagination.pages }
    if ($batch.Count -lt $limit) { break }
    $page++
    if ($page -gt 200) { break }   # a bound, so a pagination bug cannot loop forever
  }
} catch {
  Write-Output ("MEMBER COHORTS BLIND: the members read failed ({0}). Nothing was written." -f $_.Exception.Message)
  Write-GuardComplete -Name 'member-cohorts' -Summary 'blind=read-failed'
  exit 3
}

$t = Get-TcCohortTable -Pairs $pairs.ToArray()
if ($t.Total -eq 0) {
  Write-Output 'MEMBER COHORTS BLIND: the API returned zero members. That is not "nobody signed up" - it is a read that produced nothing, and no file was written.'
  Write-GuardComplete -Name 'member-cohorts' -Summary 'blind=zero-members'
  exit 3
}

# ---- report. Every rate prints with its denominator (.claude\rules\measurement.md). ----
$statusNames = @($t.Statuses.Keys | Sort-Object)
Write-Output ''
Write-Output ("MEMBER COHORTS - signup month against CURRENT status. {0} member(s) over {1} page(s)." -f $t.Total, $pagesRead)
Write-Output ("statuses present: {0}" -f (($statusNames | ForEach-Object { "$_=$($t.Statuses[$_])" }) -join ', '))
if ($t.Undated) { Write-Output ("  {0} member(s) had an unreadable signup date and are counted here but in NO month bucket." -f $t.Undated) }
Write-Output ''
Write-Output ("{0,-10} {1,7}  {2}" -f 'cohort', 'total', (($statusNames | ForEach-Object { "{0,10}" -f $_ }) -join ''))
Write-Output ('-' * (20 + 10 * $statusNames.Count))
$months = @($t.Buckets.Keys | Sort-Object)
foreach ($m in $months) {
  $row = $t.Buckets[$m]
  $n = ($row.Values | Measure-Object -Sum).Sum
  Write-Output ("{0,-10} {1,7}  {2}" -f $m, $n, (($statusNames | ForEach-Object { "{0,10}" -f $(if ($row.ContainsKey($_)) { $row[$_] } else { 0 }) }) -join ''))
}
Write-Output ('-' * (20 + 10 * $statusNames.Count))
Write-Output ''
Write-Output 'READ THIS BEFORE READING THE TABLE. These are ENDPOINTS, not a curve. Ghost gives current'
Write-Output 'status and not a status history, so a member who cancelled in month 2 and one who cancelled'
Write-Output 'in month 8 are indistinguishable here. The shapes that carry the diagnostic value - a cliff'
Write-Output 'drop against gradual churn, and which period the cliff lands in - CANNOT be produced from a'
Write-Output 'single snapshot. Backlog I98 is the fix and it is NOT started: a monthly committed snapshot,'
Write-Output 'a few dozen bytes, and every month it waits is a month of curve that cannot be recovered.'
if ($months.Count -lt 6) {
  Write-Output ''
  Write-Output ("AND THE SAMPLE IS SMALL: {0} cohort month(s). With a membership this size a difference" -f $months.Count)
  Write-Output 'between two months may have no power at all. Report the counts, and be willing to say the'
  Write-Output 'question is not answerable yet rather than reading a trend into single digits.'
}

# ---- write ONLY the bucketed counts ----
$out = [ordered]@{
  readme = 'Aggregate member cohorts: signup month against CURRENT status, counts only. NO PER-MEMBER ROW AND NO EMAIL ADDRESS IS STORED HERE OR ANYWHERE - ruled by Brad 2026-09-08, backlog I97, and enforced by ops/member-cohorts.ps1, which reads only created_at and status off a member and builds this from month strings, status strings and integers. These are ENDPOINTS, not a retention curve: Ghost gives current status and not a status history, so this cannot say WHEN anyone left. Backlog I98 is the monthly snapshot that would fix that and it is not started.'
  generated = (Get-Date -Format 'yyyy-MM-dd HH:mm')
  members_counted = $t.Total
  members_with_unreadable_signup_date = $t.Undated
  statuses = ([ordered]@{})
  cohorts = ([ordered]@{})
}
foreach ($s in $statusNames) { $out.statuses[$s] = $t.Statuses[$s] }
foreach ($m in $months) {
  $row = [ordered]@{}
  foreach ($s in $statusNames) { $row[$s] = $(if ($t.Buckets[$m].ContainsKey($s)) { $t.Buckets[$m][$s] } else { 0 }) }
  $out.cohorts[$m] = $row
}
$json = $out | ConvertTo-Json -Depth 6

# LAST LINE OF DEFENCE, and it is cheap: refuse to write anything that looks like an address. The
# structure cannot produce one, and this asserts that rather than trusting it.
if ($json -match '@' -and $json -notmatch '^[^@]*$') {
  if ($json -match '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}') {
    Write-Output 'MEMBER COHORTS REFUSED TO WRITE: the aggregate contains something shaped like an email address. That should be structurally impossible; investigate before re-running. Nothing was written.'
    Write-GuardComplete -Name 'member-cohorts' -Summary 'refused=address-shaped-content'
    exit 2
  }
}
Set-Content -LiteralPath $OutFile -Value $json -Encoding UTF8
Write-Output ''
Write-Output ("wrote {0} - {1} cohort month(s), counts only." -f $OutFile, $months.Count)
Write-GuardComplete -Name 'member-cohorts' -Summary ("members={0} cohorts={1} undated={2}" -f $t.Total, $months.Count, $t.Undated)
exit 0
