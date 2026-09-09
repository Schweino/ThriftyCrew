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
param([switch]$SelfTest, [switch]$WhatIf, [string]$OutFile = '',
      [switch]$AppendHistory, [switch]$CheckFresh, [switch]$Force, [string]$HistoryFile = '')
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

# ============================================================================== I98: the MONTHLY SERIES
# Ruled by Brad 2026-09-09: start it now, automated, aggregate counts only.
#
# WHY A SERIES AND NOT A BETTER QUERY. Ghost returns CURRENT status and no status history, so a single
# pull can say how many January signups are still paid but cannot tell someone who cancelled in month 2
# from someone who cancelled in month 8. That is one endpoint per cohort and never a curve. Taking the
# same aggregate every month and keeping the old ones is the ONLY way to recover the shape, and it is
# strictly forward-looking: a month not snapshotted is a month of curve that cannot be reconstructed
# later from anything Ghost holds.
#
# THE PRIVACY BOUNDARY IS UNCHANGED AND IS THE SAME ONE BRAD RULED ON FOR I97. The history rows are
# built from the SAME aggregate table, so they can hold only month strings, status strings and integers.
# No member id, no address, no per-member row - here or anywhere.
#
# ONE ROW PER CASE (backlog E24): a row is (snapshot, signup_month, status, count), so every total is
# derived from the file and a question nobody has asked yet can still be asked of the same data.

# The snapshot is monthly, so a run is stale once a whole month plus slack has passed without one.
# WHAT ELSE WAS TRIED: nothing. 40 is the FIRST PLAUSIBLE VALUE - 31 days plus about a week of slack so
# a chain that misses a day or a long weekend does not cry wolf. It is not the survivor of a sweep, and
# nothing here establishes that 30 or 50 would behave worse.
$HISTORY_MAX_AGE_DAYS = 40

# ---- I99: the price-alert exposure signal, pre-registered in design/EVAL-alert-retention-2026-09-09.md
# Ruled by Brad 2026-09-09: pre-register the design and snapshot the counts monthly.
#
# WHAT IS READ AND WHAT IS KEPT. The members read adds `include=labels` - labels are a RELATION and do
# not come back through `fields`. What is derived per member is a SINGLE INTEGER, how many `alert-*`
# labels they carry, and it is bucketed immediately. NO LABEL STRING IS EVER KEPT: the label names a
# commodity, so pairing it with a member would be behavioural data about a person, and the pre-
# registered question does not need it.
$ALLOWED_MEMBER_INCLUDES = @('labels')

function Get-TcAlertCount {
  <# How many alert-* labels a member object carries. The ONLY thing derived from labels. Pure. #>
  param([object]$Member)
  $n = 0
  foreach ($l in @($Member.labels)) {
    if ($null -eq $l) { continue }
    if (([string]$l.name -match '^alert-') -or ([string]$l.slug -match '^alert-')) { $n++ }
  }
  return $n
}

function Get-TcAlertBucket {
  <# The pre-registered cut, and it is NOT tunable: >= 1 alert, or none. Choosing the cut that produces
     the biggest gap is selection on noise, so the cut is fixed here and in the pre-registration. #>
  param([int]$Count)
  if ($Count -ge 1) { return '1+' }
  return '0'
}

function Get-TcAlertTable {
  <# signup month -> bucket -> count, over (created_at, alerts) pairs. Pure, and it can only emit month
     strings, the two bucket strings, and integers. #>
  param([object[]]$Pairs)
  $buckets = @{}
  $exposed = 0; $total = 0
  foreach ($p in @($Pairs)) {
    if ($null -eq $p) { continue }
    $total++
    $b = Get-TcAlertBucket -Count ([int]$p.alerts)
    if ($b -eq '1+') { $exposed++ }
    $k = Get-TcCohortKey ([string]$p.created_at)
    if (-not $k) { $k = '(undated)' }
    if (-not $buckets.ContainsKey($k)) { $buckets[$k] = @{} }
    if (-not $buckets[$k].ContainsKey($b)) { $buckets[$k][$b] = 0 }
    $buckets[$k][$b]++
  }
  return @{ Buckets = $buckets; Exposed = $exposed; Total = $total }
}

function New-TcAlertHistoryRows {
  param([hashtable]$Table, [string]$Snapshot, [string]$Generated)
  $rows = @()
  $monthKeys = $Table.Buckets.Keys | Sort-Object
  foreach ($m in $monthKeys) {
    $bkeys = $Table.Buckets[$m].Keys | Sort-Object
    foreach ($b in $bkeys) {
      $rows += [ordered]@{ snapshot = $Snapshot; generated = $Generated; signup_month = $m
                           alert_bucket = [string]$b; count = [int]$Table.Buckets[$m][$b] }
    }
  }
  return $rows
}

function Get-TcSnapshotMonth {
  <# The calendar month a snapshot belongs to. Pure. #>
  param([datetime]$When)
  return $When.ToString('yyyy-MM')
}

function New-TcHistoryRows {
  <# The aggregate table, flattened to one row per (signup_month, status). Pure, and it can only emit
     strings and integers - the privacy boundary expressed as a type, exactly as Get-TcCohortTable is. #>
  param([hashtable]$Table, [string]$Snapshot, [string]$Generated)
  $rows = @()
  $monthKeys = $Table.Buckets.Keys | Sort-Object
  foreach ($m in $monthKeys) {
    $statusKeys = $Table.Buckets[$m].Keys | Sort-Object
    foreach ($s in $statusKeys) {
      $rows += [ordered]@{ snapshot = $Snapshot; generated = $Generated; signup_month = $m
                           status = [string]$s; count = [int]$Table.Buckets[$m][$s] }
    }
  }
  # A member with an unreadable signup date belongs to no month bucket, so without this row the series
  # would silently under-count the membership and nothing in the file would say so.
  if ([int]$Table.Undated -gt 0) {
    $rows += [ordered]@{ snapshot = $Snapshot; generated = $Generated; signup_month = '(undated)'
                         status = 'any'; count = [int]$Table.Undated }
  }
  return $rows
}

function Get-TcHistoryRows {
  <# Reads the .jsonl. A line that does not parse is SKIPPED AND COUNTED, never silently dropped. #>
  param([string]$Path)
  $rows = @(); $badLines = 0
  if (-not (Test-Path -LiteralPath $Path)) { return @{ Rows = $rows; Bad = 0; Exists = $false } }
  foreach ($line in [IO.File]::ReadAllLines($Path)) {
    $l = $line.Trim()
    if (-not $l) { continue }
    try { $rows += ($l | ConvertFrom-Json) } catch { $badLines++ }
  }
  return @{ Rows = $rows; Bad = $badLines; Exists = $true }
}

function Test-TcSnapshotAlreadyTaken {
  <# IDEMPOTENCE. The daily chain runs every day and this is a MONTHLY snapshot, so a run that appended
     unconditionally would write ~30 duplicate sets a month and turn the series into noise that still
     looks like data. Pure. #>
  param([object[]]$Rows, [string]$Snapshot)
  foreach ($r in @($Rows)) {
    if ($null -eq $r) { continue }
    if ([string]$r.snapshot -eq $Snapshot) { return $true }
  }
  return $false
}

function Test-TcHistoryStale {
  <# THE ABSENCE CHECK, and it is the whole reason this is safe to automate. Every other threshold in
     this estate is an UPPER bound and cannot fire on nothing happening; the failure mode HERE is the
     producer going quiet, in which case the series just stops and no upper bound would ever notice.
     Returns '' when fresh, or the reason it is not. Pure. #>
  param([object[]]$Rows, [datetime]$Now, [int]$MaxAgeDays)
  $snaps = @(@($Rows) | Where-Object { $null -ne $_ -and $_.generated } | ForEach-Object { [string]$_.generated })
  if (-not $snaps.Count) { return 'no snapshot has ever been taken' }
  $newest = $null
  foreach ($g in $snaps) {
    $d = [datetime]::MinValue
    if ([datetime]::TryParse($g, [ref]$d)) {
      if ($null -eq $newest -or $d -gt $newest) { $newest = $d }
    }
  }
  if ($null -eq $newest) { return 'no snapshot carries a readable date' }
  $age = ($Now - $newest).TotalDays
  if ($age -gt $MaxAgeDays) {
    return ("the newest snapshot is {0:N0} day(s) old, over the {1}-day bar - the monthly series has STOPPED" -f $age, $MaxAgeDays)
  }
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

  # ---------------------------------------------------------------- I98, the monthly series
  $hrows = New-TcHistoryRows -Table $t -Snapshot '2026-09' -Generated '2026-09-09'
  $hjson = ($hrows | ConvertTo-Json -Depth 6)
  T 'MUST FIRE  THE PRIVACY BOUNDARY HOLDS IN THE HISTORY TOO - a history row built from a table whose input carried an email contains no address, no name and no id' `
    ((($New = New-TcHistoryRows -Table $t2 -Snapshot '2026-09' -Generated '2026-09-09') | ConvertTo-Json -Depth 6) -notmatch '@') `
    'an address reached a history row'
  T 'MUST NOT FIRE  a history row carries only month, status and an integer count' `
    (($hjson -match '"signup_month"') -and ($hjson -match '"count"') -and ($hjson -notmatch '"id"')) `
    'a history row carried an unexpected field'
  $undatedRow = @($hrows | Where-Object { $_.signup_month -eq '(undated)' })
  T 'MUST FIRE  the undated member gets its OWN row, so the series cannot silently under-count the membership' `
    (($undatedRow.Count -eq 1) -and ([int]$undatedRow[0].count -eq 1)) `
    ("undated rows=" + $undatedRow.Count)

  # IDEMPOTENCE. This is the founding bug for a MONTHLY job on a DAILY chain.
  T 'MUST FIRE  a snapshot already taken this month is detected, so a daily chain cannot append 30 duplicate sets' `
    (Test-TcSnapshotAlreadyTaken -Rows $hrows -Snapshot '2026-09') 'the duplicate was not detected'
  T 'MUST NOT FIRE  a NEW month is not mistaken for one already taken' `
    (-not (Test-TcSnapshotAlreadyTaken -Rows $hrows -Snapshot '2026-10')) 'a new month read as already taken'
  T 'MUST NOT FIRE  an empty history is not read as already taken - @($null).Count is 1 in PS 5.1 and would have refused the very first snapshot' `
    (-not (Test-TcSnapshotAlreadyTaken -Rows @() -Snapshot '2026-09')) 'an empty history read as already taken'

  # THE ABSENCE CHECK. Every other threshold here is an upper bound and cannot fire on nothing happening.
  T 'MUST FIRE  a series that STOPPED is reported stale - the producer going quiet is the failure mode no upper bound can see' `
    ((Test-TcHistoryStale -Rows $hrows -Now ([datetime]'2026-12-01') -MaxAgeDays 40) -like '*STOPPED*') `
    (Test-TcHistoryStale -Rows $hrows -Now ([datetime]'2026-12-01') -MaxAgeDays 40)
  T 'MUST NOT FIRE  a snapshot taken this month is fresh' `
    ((Test-TcHistoryStale -Rows $hrows -Now ([datetime]'2026-09-20') -MaxAgeDays 40) -eq '') `
    (Test-TcHistoryStale -Rows $hrows -Now ([datetime]'2026-09-20') -MaxAgeDays 40)
  T 'MUST FIRE  a history that has never been written says so, rather than reading as fresh' `
    ((Test-TcHistoryStale -Rows @() -Now ([datetime]'2026-09-20') -MaxAgeDays 40) -like '*has ever been taken*') `
    (Test-TcHistoryStale -Rows @() -Now ([datetime]'2026-09-20') -MaxAgeDays 40)

  # ---------------------------------------------------------------- I99, the alert exposure signal
  $withLabels = [pscustomobject]@{
    created_at = '2026-01-05T00:00:00Z'; status = 'paid'; email = 'person@example.com'
    labels = @([pscustomobject]@{ name = 'alert-eggs-large'; slug = 'alert-eggs-large' },
               [pscustomobject]@{ name = 'newsletter'; slug = 'newsletter' })
  }
  T 'MUST FIRE  only alert-* labels are counted, so an unrelated label does not inflate exposure' `
    ((Get-TcAlertCount -Member $withLabels) -eq 1) ([string](Get-TcAlertCount -Member $withLabels))
  $noLabels = [pscustomobject]@{ created_at = '2026-01-06T00:00:00Z'; status = 'free'; labels = @() }
  T 'MUST NOT FIRE  a member with no labels counts 0, not 1 - @($null).Count is 1 in PS 5.1 and would have exposed everybody' `
    ((Get-TcAlertCount -Member $noLabels) -eq 0) ([string](Get-TcAlertCount -Member $noLabels))
  T 'MUST FIRE  the pre-registered cut is >= 1 and is not tunable' `
    (((Get-TcAlertBucket -Count 0) -eq '0') -and ((Get-TcAlertBucket -Count 1) -eq '1+') -and ((Get-TcAlertBucket -Count 9) -eq '1+')) `
    'the bucket boundary moved'
  $apairs = @(
    [pscustomobject]@{ created_at = '2026-01-05T00:00:00Z'; alerts = 1 },
    [pscustomobject]@{ created_at = '2026-01-09T00:00:00Z'; alerts = 0 },
    [pscustomobject]@{ created_at = '2026-02-02T00:00:00Z'; alerts = 0 }
  )
  $at = Get-TcAlertTable -Pairs $apairs
  T 'MUST NOT FIRE  exposure buckets by signup month: January is 1 exposed and 1 not' `
    (($at.Buckets['2026-01']['1+'] -eq 1) -and ($at.Buckets['2026-01']['0'] -eq 1)) `
    ("jan 1+=" + $at.Buckets['2026-01']['1+'])
  $arows = New-TcAlertHistoryRows -Table $at -Snapshot '2026-09' -Generated '2026-09-09'
  $ajson = ($arows | ConvertTo-Json -Depth 6)
  T 'MUST FIRE  THE BOUNDARY - no label STRING reaches a history row, only a bucket and a count, so a commodity is never paired with a person' `
    (($ajson -notmatch 'alert-eggs') -and ($ajson -notmatch '@') -and ($ajson -match '"alert_bucket"')) `
    'a label string or address reached an alert history row'
  T 'CLEAN TWIN  the alert rows still sum to the same member total the alert table counted' `
    ((($arows | ForEach-Object { [int]$_.count }) | Measure-Object -Sum).Sum -eq $at.Total) `
    ("rows sum vs total=" + $at.Total)
  T 'MUST NOT FIRE  the include list stays at labels alone' `
    (($ALLOWED_MEMBER_INCLUDES.Count -eq 1) -and ($ALLOWED_MEMBER_INCLUDES[0] -eq 'labels')) `
    ($ALLOWED_MEMBER_INCLUDES -join ',')

  # CLEAN TWIN - the adjacent behaviour the flattening was most likely to break: the counts in the rows
  # must still add up to the same membership the table counted. A POSITIVE assertion.
  $rowSum = 0
  foreach ($r in $hrows) { $rowSum += [int]$r.count }
  T 'CLEAN TWIN  the history rows still sum to the same member total the table reported' `
    ($rowSum -eq $t.Total) ("rows sum=" + $rowSum + " table total=" + $t.Total)

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: 27 case(s) resolved - 13 must-fire, 11 must-not-fire, 3 clean twins. Led by the founding privacy constraint (an input row carrying an email produces an aggregate that cannot contain one), the undated-signup count, the monthly idempotence guard, the series-has-stopped absence check, and the I99 boundary that no LABEL STRING reaches a history row. The must-not-fires include the empty membership, the empty history, and a member with no labels counting 0 rather than 1'
  exit 0
}

# ------------------------------------------------------------------------------- the live run
if (-not $OutFile) { $OutFile = Join-Path $repo 'ops\member-cohorts.json' }
$historyPath = if ($HistoryFile) { $HistoryFile } else { Join-Path $repo 'ops\member-cohorts-history.jsonl' }
$alertHistoryPath = Join-Path $repo 'ops\member-alert-history.jsonl'

# ---- I98: the freshness check, which touches NO network and is safe to run anywhere ----
# SCOPE OF A CLEAN REPORT for THIS mode: SOUND over the history file. It reads dates and nothing else,
# so a clean report here means the series really has a recent snapshot. It says nothing about whether
# that snapshot is CORRECT - only that one was taken.
if ($CheckFresh) {
  $h = Get-TcHistoryRows -Path $historyPath
  $reason = Test-TcHistoryStale -Rows $h.Rows -Now (Get-Date) -MaxAgeDays $HISTORY_MAX_AGE_DAYS
  $rowCount = @($h.Rows).Count
  if (-not $h.Exists -or $rowCount -eq 0) {
    Write-Output ("member-cohorts: no snapshot series at {0}. BLIND, not clean - run with -AppendHistory." -f $historyPath)
    Exit-Guard -Name 'member-cohorts' -Summary 'blind=no-history' -Code 3
  }
  $snapCount = @(@($h.Rows) | ForEach-Object { [string]$_.snapshot } | Sort-Object -Unique).Count
  if ($reason) {
    Write-Output ("member-cohorts: THE MONTHLY SERIES HAS STOPPED - {0}." -f $reason)
    Write-Output '  Nothing else in this estate would have noticed: every other threshold is an upper bound'
    Write-Output '  and cannot fire on nothing happening. A month not snapshotted cannot be recovered later.'
    Exit-Guard -Name 'member-cohorts' -Summary ("stale rows={0} snapshots={1}" -f $rowCount, $snapCount) -Code 2
  }
  Write-Output ("member-cohorts: series fresh - {0} row(s) over {1} snapshot(s), newest within {2} days." -f $rowCount, $snapCount, $HISTORY_MAX_AGE_DAYS)
  Exit-Guard -Name 'member-cohorts' -Summary ("fresh rows={0} snapshots={1}" -f $rowCount, $snapCount) -Code 0
}

# RULE 4: ASSERT THE DESTINATION BEFORE ANYTHING IS FETCHED.
$why = Test-TcOutputPathSafe -Path $OutFile -Repo $repo
if ($why) {
  Write-Output ("MEMBER COHORTS REFUSED: {0}. Nothing was fetched - the path is checked BEFORE the first API call, on purpose." -f $why)
  Exit-Guard -Name 'member-cohorts' -Summary 'refused=bad-output-path' -Code 2
}
Write-Output ("output path asserted safe BEFORE any fetch: {0}" -f $OutFile)
if ($WhatIf) {
  Write-Output 'WHATIF: the path is valid and NOTHING was fetched. Re-run without -WhatIf to pull.'
  Exit-Guard -Name 'member-cohorts' -Summary 'whatif=path-ok' -Code 0
}

$adminKey = $env:GHOST_ADMIN_KEY
if (-not $adminKey) {
  $kf = Join-Path $repo 'meal-prep\.ghostkey'
  if (Test-Path $kf) { $adminKey = (Get-Content $kf -Raw).Trim() }
}
if (-not $adminKey) {
  Write-Output 'MEMBER COHORTS BLIND: no GHOST_ADMIN_KEY and no meal-prep\.ghostkey, so nothing was read. That is could-not-evaluate, never "no members".'
  Exit-Guard -Name 'member-cohorts' -Summary 'blind=no-key' -Code 3
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
            '&fields=' + ($ALLOWED_MEMBER_FIELDS -join ',') +
            '&include=' + ($ALLOWED_MEMBER_INCLUDES -join ','))
    $res = Invoke-RestMethod -Uri $uri -Headers $hdr -TimeoutSec 60
    $batch = @($res.members)
    foreach ($m in $batch) {
      # THE ONLY THREE THINGS EVER READ off a member: signup date, current status, and an INTEGER count
      # of alert-* labels. Nothing else on $m is touched, no label string is kept, and $m is not
      # retained past this line.
      [void]$pairs.Add([pscustomobject]@{ created_at = [string]$m.created_at; status = [string]$m.status
                                          alerts = (Get-TcAlertCount -Member $m) })
    }
    $pagesRead++
    if ($res.meta -and $res.meta.pagination) { $lastPages = $res.meta.pagination.pages }
    if ($batch.Count -lt $limit) { break }
    $page++
    if ($page -gt 200) { break }   # a bound, so a pagination bug cannot loop forever
  }
} catch {
  Write-Output ("MEMBER COHORTS BLIND: the members read failed ({0}). Nothing was written." -f $_.Exception.Message)
  Exit-Guard -Name 'member-cohorts' -Summary 'blind=read-failed' -Code 3
}

$t = Get-TcCohortTable -Pairs $pairs.ToArray()
if ($t.Total -eq 0) {
  Write-Output 'MEMBER COHORTS BLIND: the API returned zero members. That is not "nobody signed up" - it is a read that produced nothing, and no file was written.'
  Exit-Guard -Name 'member-cohorts' -Summary 'blind=zero-members' -Code 3
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
Write-Output 'single snapshot. Backlog I98 IS NOW RUNNING (ruled by Brad 2026-09-09): a monthly committed'
Write-Output 'snapshot in ops\member-cohorts-history.jsonl. The curve builds forward from the first'
Write-Output 'snapshot and cannot be backfilled, so the table below is still endpoints until enough'
Write-Output 'months have accumulated. Read the series, not this table, once it has more than one month.'
if ($months.Count -lt 6) {
  Write-Output ''
  Write-Output ("AND THE SAMPLE IS SMALL: {0} cohort month(s). With a membership this size a difference" -f $months.Count)
  Write-Output 'between two months may have no power at all. Report the counts, and be willing to say the'
  Write-Output 'question is not answerable yet rather than reading a trend into single digits.'
}

# ---- write ONLY the bucketed counts ----
$out = [ordered]@{
  readme = 'Aggregate member cohorts: signup month against CURRENT status, counts only. NO PER-MEMBER ROW AND NO EMAIL ADDRESS IS STORED HERE OR ANYWHERE - ruled by Brad 2026-09-08, backlog I97, and enforced by ops/member-cohorts.ps1, which reads only created_at and status off a member and builds this from month strings, status strings and integers. These are ENDPOINTS, not a retention curve: Ghost gives current status and not a status history, so this cannot say WHEN anyone left. Backlog I98 is the monthly snapshot that fixes that and it IS RUNNING as of 2026-09-09 - the series is ops/member-cohorts-history.jsonl, appended once per calendar month. It builds forward and cannot be backfilled, so read the series rather than this file once more than one month has accumulated.'
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
    Exit-Guard -Name 'member-cohorts' -Summary 'refused=address-shaped-content' -Code 2
  }
}
Set-Content -LiteralPath $OutFile -Value $json -Encoding UTF8
Write-Output ''
Write-Output ("wrote {0} - {1} cohort month(s), counts only." -f $OutFile, $months.Count)

# ---- I98: append this month's snapshot to the series ----
if ($AppendHistory) {
  $snapshot = Get-TcSnapshotMonth -When (Get-Date)
  $h = Get-TcHistoryRows -Path $historyPath
  if ($h.Bad -gt 0) {
    Write-Output ("  NOTE {0} unparseable line(s) in the history were skipped and NOT counted." -f $h.Bad)
  }
  $already = Test-TcSnapshotAlreadyTaken -Rows $h.Rows -Snapshot $snapshot
  if ($already -and -not $Force) {
    Write-Output ("  history: {0} already has a snapshot, nothing appended. The chain runs daily; this is monthly." -f $snapshot)
  } else {
    $newRows = New-TcHistoryRows -Table $t -Snapshot $snapshot -Generated (Get-Date -Format 'yyyy-MM-dd')
    $lines = @()
    foreach ($r in $newRows) { $lines += ($r | ConvertTo-Json -Depth 4 -Compress) }
    # A LAST-LINE ADDRESS CHECK ON THE SERIES TOO. The structure cannot produce one; this asserts it
    # rather than trusting it, because an append is harder to notice than a rewrite.
    $joined = ($lines -join "`n")
    if ($joined -match '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}') {
      Write-Output 'MEMBER COHORTS REFUSED TO APPEND: a history row looks like it contains an email address. That should be structurally impossible; investigate. Nothing was appended.'
      Exit-Guard -Name 'member-cohorts' -Summary 'refused=address-shaped-history' -Code 2
    }
    Add-Content -LiteralPath $historyPath -Value $lines -Encoding UTF8
    Write-Output ("  history: appended {0} row(s) for snapshot {1} to {2}" -f $lines.Count, $snapshot, (Split-Path $historyPath -Leaf))

  }

  # ---- I99: the alert-exposure series, same snapshot, same boundary, separate file so the I98 rows
  # keep one stable schema. Pre-registered in design/EVAL-alert-retention-2026-09-09.md.
  # ITS OWN IDEMPOTENCE CHECK, on its own file. Sharing the cohort series' check would mean the alert
  # series could never start in a month whose cohort snapshot was already taken - which is exactly the
  # month it was introduced, so the bug would have shipped looking like success.
  $ah = Get-TcHistoryRows -Path $alertHistoryPath
  $aAlready = Test-TcSnapshotAlreadyTaken -Rows $ah.Rows -Snapshot $snapshot
  if ($aAlready -and -not $Force) {
    Write-Output ("  alerts:  {0} already has a snapshot, nothing appended." -f $snapshot)
  } else {
    $at = Get-TcAlertTable -Pairs $pairs.ToArray()
    $aRows = New-TcAlertHistoryRows -Table $at -Snapshot $snapshot -Generated (Get-Date -Format 'yyyy-MM-dd')
    $aLines = @()
    foreach ($r in $aRows) { $aLines += ($r | ConvertTo-Json -Depth 4 -Compress) }
    $aJoined = ($aLines -join "`n")
    if ($aJoined -match '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' -or $aJoined -match 'alert-') {
      Write-Output 'MEMBER COHORTS REFUSED TO APPEND the alert series: a row contains an address or a LABEL STRING. Only buckets and counts may be written. Investigate.'
      Exit-Guard -Name 'member-cohorts' -Summary 'refused=label-string-in-alert-series' -Code 2
    }
    Add-Content -LiteralPath $alertHistoryPath -Value $aLines -Encoding UTF8
    Write-Output ("  alerts:  appended {0} row(s) - {1} of {2} member(s) carry at least one price alert." -f $aLines.Count, $at.Exposed, $at.Total)
    Write-Output '  THE PRE-REGISTERED BAR IS 91 PER ARM (design/EVAL-alert-retention-2026-09-09.md). Below'
    Write-Output '  that the only permitted output is the counts with denominators and "not answerable yet".'
  }
  Write-Output '  These rows are the ONLY way the retention curve can ever exist: Ghost holds no status'
  Write-Output '  history, so a month that is not snapshotted is a month that cannot be reconstructed.'
}

Exit-Guard -Name 'member-cohorts' -Summary ("members={0} cohorts={1} undated={2}" -f $t.Total, $months.Count, $t.Undated) -Code 0
