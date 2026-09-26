<#
  derive-not-carried.ps1 - decide, from the stores' OWN captures, which missing board cells are missing
  because the store does not stock the item.

  THE PROBLEM THIS SOLVES. The board holds 3,020 of a possible 3,766 store cells. audit-coverage-gaps
  exists to catch a store silently vanishing from an item it sells - but with 638 missing cells carrying
  no explanation, that signal is buried. Aldi has never stocked achiote paste; that is a fact about Aldi,
  not a defect, and until it is written down as a fact it costs a human the same attention as a real
  disappearance.

  WHY THIS IS DERIVED AND NOT A HAND LIST. A hand list of 638 rows would be wrong within a quarter and
  nobody would know which rows. The captures already contain the answer for any store that records what
  it searched for: bakers-regular writes {term_key, outcome, row_count} per commodity, so "we asked Baker's
  for beef-chuck-roast and it returned nothing" is an OBSERVATION, dated, re-made every pull, free.

  WHAT COUNTS AS EVIDENCE, and what does not:

    outcome=success, row_count>0   the store answered with rows and none of them matched the commodity
                                   -> NOT CARRIED. The strongest form: the store had things to show and
                                      none of them was this.
    outcome=empty,   row_count=0   the store's own search found nothing
                                   -> NOT CARRIED, weaker. A bad search term looks identical from here,
                                      so it is recorded with its term for a human to overturn.
    outcome=not_attempted          the budget rotation never asked -> proves NOTHING. Not written.
    outcome=rejected               the request failed or was throttled -> proves NOTHING. Not written.
    no capture_terms at all        the store records nothing -> proves NOTHING. Counted and REPORTED,
                                   because that count is the actual blocker and hiding it would make this
                                   script look more capable than it is.

  ONE SEARCH IS NEVER ENOUGH (backlog I221, 2026-09-18). Until this date either line above wrote an entry off
  ONE query, and all 24 entries of 2026-08-21 rest on one: 12 empty, 12 with rows our matcher rejected - among
  them pork tenderloin, fresh parsley, jicama and pesto at a Kroger store. A poor term looks identical to an
  absent product (search-verdict-lib.ps1's header: four of ten terms mis-ruled on the first query in the
  2026-08-15 trial), and .claude\rules\grocery.md says UNCHECKED IS NEVER NOT-CARRIED. So a candidate is now
  written ONLY when the store's captures inside recheck_days hold AT LEAST TWO DIFFERENTLY WORDED searches for
  it, each empty or with no matching row. New-TcNotCarriedEntry in not-carried-lib.ps1 decides, and it is the
  same rule build-deals-page uses to decide whether to show "Doesn't carry". A candidate with one wording is
  REFUSED, counted and listed; nothing is written for it. The same term asked on thirteen days is one wording.
  Capture records that carry no `term` text (Baker's before mid-September) cannot say what was searched, so
  they are not evidence of a wording.

  Every entry carries basis=derived, each search it rests on (term, outcome, row count, capture file), and the
  date. Entries expire after recheck_days (90, following capture-policy.ps1's QuarterDays) - a store not
  stocking something today says nothing about next quarter.

  DECLARED entries (basis=declared) are written by hand for stores that cannot yet derive. This script
  never invents one, never edits one, and never deletes one - it only refreshes what it can observe. A
  human assertion and a machine observation live in the same file and are never allowed to look alike.

  Read-only unless -Apply. -GroceryRoot and -Today exist for the self-test, which runs this script as a child
  against a temp tree; production passes neither.
#>
# Self-test: runs this script as a child over a temp grocery tree it writes itself; nothing under the real grocery\ is read.
# gate-inputs: grocery\derive-not-carried.ps1
param([switch]$Apply, [string]$OutDir = '', [string]$GroceryRoot = '', [string]$Today = '', [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\lf-write.ps1')  # Write-TcLfFile: the file is tracked eol=lf
. (Join-Path $PSScriptRoot 'not-carried-lib.ps1')                     # New-TcNotCarriedEntry: the two-wording rule
$root = if ($GroceryRoot) { $GroceryRoot } elseif ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

if ($SelfTest) {
  # Runs THIS script as a child over a temp grocery tree, so the refusal is proved on the real code path and the
  # write is proved by reading the file it wrote. Nothing under the real grocery\ is read or written.
  $pass = 0; $fail = 0
  function DncCheck([string]$Name, [bool]$Ok, [string]$Got) {
    if ($Ok) { $script:pass++; Write-Output ("  ok    " + $Name) } else { $script:fail++; Write-Output ("  FAIL  " + $Name + "  got: " + $Got) }
  }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('dnc-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
  try {
    $utf8 = New-Object Text.UTF8Encoding($false)
    New-Item -ItemType Directory -Path (Join-Path $tmp 'out\regular') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $tmp 'commodity-search.json'), '{"terms":{"achiote-paste":["achiote paste"],"pork-tenderloin":["pork tenderloin"],"milk":["whole milk"]}}', $utf8)
    [IO.File]::WriteAllText((Join-Path $tmp 'coverage-gap-allowlist.json'), '{"allow":[]}', $utf8)
    [IO.File]::WriteAllText((Join-Path $tmp 'not-carried.json'), '{"recheck_days":90,"entries":[{"commodity":"fennel","store":"Aldi","basis":"declared","verdict":"not-carried","evidence":"looked","checked":"2026-09-01"},{"commodity":"achiote-paste","store":"Baker''s","basis":"derived","verdict":"not-carried","evidence":"searched ''achiote paste'': none","outcome":"empty","row_count":0,"checked":"2026-08-21"}]}', $utf8)
    # Board: none of the three is priced at Baker's except milk, which must never become an entry.
    [IO.File]::WriteAllText((Join-Path $tmp 'out\comparison-2026-09-18.json'), '{"comparison":[{"id":"achiote-paste","stores":[{"store":"Hy-Vee"}]},{"id":"pork-tenderloin","stores":[{"store":"Walmart"}]},{"id":"milk","stores":[{"store":"Baker''s"}]}]}', $utf8)
    # Two Baker's captures. achiote paste: the SAME wording asked twice (the 2026-08-21 shape, one search however
    # often it is repeated). pork tenderloin: two different wordings, one empty and one with rows none matched.
    [IO.File]::WriteAllText((Join-Path $tmp 'out\regular\bakers-regular-2026-09-10.json'), '{"capture_terms":[{"term_key":"achiote-paste","term":"achiote paste","outcome":"empty","row_count":0},{"term_key":"pork-tenderloin","term":"pork tenderloin whole boneless","outcome":"empty","row_count":0}]}', $utf8)
    [IO.File]::WriteAllText((Join-Path $tmp 'out\regular\bakers-regular-2026-09-17.json'), '{"capture_terms":[{"term_key":"achiote-paste","term":"Achiote Paste","outcome":"empty","row_count":0},{"term_key":"pork-tenderloin","term":"pork tenderloin","outcome":"success","row_count":3},{"term_key":"milk","term":"whole milk","outcome":"success","row_count":9}]}', $utf8)
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # A native child's stderr under EAP=Stop is a terminating throw (.claude\rules\ops-and-gates.md), so the call
    # runs under Continue and the preference is restored whatever happens. The child's output goes to a file and
    # its exit code is read from the call itself, never from a pipe.
    $logF = Join-Path $tmp 'child.log'
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $ps -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Apply -GroceryRoot $tmp -OutDir (Join-Path $tmp 'out') -Today '2026-09-18' > $logF 2>&1; $rc = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prevEap }
    $log = @([IO.File]::ReadAllLines($logF))
    DncCheck 'CLEAN TWIN the child ran -Apply and exited 0' ($rc -eq 0) ("rc=$rc; " + ($log -join ' | '))
    $doc = Read-JsonFile (Join-Path $tmp 'not-carried.json')
    $es = @(@($doc.entries) | Where-Object { $_ })
    $ach = @($es | Where-Object { $_.commodity -eq 'achiote-paste' })
    $pork = @($es | Where-Object { $_.commodity -eq 'pork-tenderloin' })
    DncCheck 'MUST FIRE  one wording asked twice (achiote paste) is REFUSED: no entry is written for it' ($ach.Count -eq 0) ("achiote entries=" + $ach.Count)
    DncCheck 'MUST FIRE  the refusal is SPOKEN with its count, never silent' ((@($log | Where-Object { $_ -match '^REFUSED 1 candidate' }).Count -eq 1) -and (@($log | Where-Object { $_ -match "achiote-paste @ Baker's" }).Count -eq 1)) ($log -join ' | ')
    DncCheck 'CLEAN TWIN two different wordings (pork tenderloin) write ONE entry carrying both searches' (($pork.Count -eq 1) -and (@($pork[0].searches).Count -eq 2)) ("pork entries=" + $pork.Count)
    DncCheck 'CLEAN TWIN the written entry passes the rule build-deals-page reads it by' (($pork.Count -eq 1) -and (Test-TcNotCarriedEntry $pork[0] ([datetime]'2026-09-18') 90).Ok) 'not trusted'
    DncCheck 'MUST NOT FIRE a store priced on the board (milk at Baker''s) never becomes an entry' (@($es | Where-Object { $_.commodity -eq 'milk' }).Count -eq 0) ("entries=" + $es.Count)
    DncCheck 'CLEAN TWIN the declared (hand-written) entry is kept untouched' (@($es | Where-Object { $_.basis -eq 'declared' -and $_.commodity -eq 'fennel' -and $_.evidence -eq 'looked' }).Count -eq 1) ("entries=" + $es.Count)
    $raw = [IO.File]::ReadAllBytes((Join-Path $tmp 'not-carried.json'))
    DncCheck 'MUST NOT FIRE the file carries no CR byte (it is tracked eol=lf)' (@($raw | Where-Object { $_ -eq 13 }).Count -eq 0) 'CR bytes present'
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  if (($pass + $fail) -ne 8) { Write-Output ("  FAIL  expected 8 cases, ran " + ($pass + $fail)); $fail++ }
  if ($fail -eq 0) { Write-Output ("derive-not-carried SELF-TEST PASS ({0} of {0} cases)" -f $pass); exit 0 }
  Write-Output ("derive-not-carried SELF-TEST FAIL ({0} of {1} cases failed)" -f $fail, ($pass + $fail)); exit 1
}

if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$todayDt = if ($Today) { [datetime]::ParseExact($Today, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) } else { (Get-Date).Date }

$STORE_PREFIX = [ordered]@{
  'Aldi' = 'aldi-regular'; "Baker's" = 'bakers-regular'; 'Family Fare' = 'family-fare-regular'
  'Fareway' = 'fareway-regular'; 'Hy-Vee' = 'hyvee-regular'; "Sam's Club" = 'sams-regular'; 'Walmart' = 'walmart-regular'
}

$ncFile = Join-Path $root 'not-carried.json'
$doc = Read-JsonFile $ncFile
$recheck = if ($doc.PSObject.Properties['recheck_days']) { [int]$doc.recheck_days } else { 90 }

# commodity id -> the term the pulls search for. Family Fare keys its capture_terms by the PHRASE, so the
# reverse map is what lets its evidence be read at all (593 of 593 of its terms map back cleanly).
$termOf = @{}; $cidOfTerm = @{}
$cs = Read-JsonFile (Join-Path $root 'commodity-search.json')
foreach ($p in $cs.terms.PSObject.Properties) {
  $vals = @($p.Value)
  $termOf[$p.Name] = [string]$vals[0]
  foreach ($v in $vals) { $cidOfTerm[([string]$v).Trim().ToLower()] = $p.Name }
}

# per store: commodity id -> every search its regular captures INSIDE recheck_days record, oldest first. One day's
# file holds one search per term, so a second WORDING can only come from another day's file (or a future capture
# that asks twice); the newest file alone could never satisfy the rule.
$evidence = @{}; $noEvidenceStores = New-Object System.Collections.Generic.List[string]
foreach ($st in $STORE_PREFIX.Keys) {
  $files = @(Get-ChildItem (Join-Path $OutDir ('regular\' + $STORE_PREFIX[$st] + '-*.json')) -ErrorAction SilentlyContinue |
       Where-Object { $_.Name -match '(\d{4}-\d{2}-\d{2})\.json$' -and ($todayDt - [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)).TotalDays -le $recheck } |
       Sort-Object Name)
  $evidence[$st] = @{ file = $null; terms = @{} }
  if (-not $files.Count) { $noEvidenceStores.Add("$st (no regular capture inside $recheck days)"); continue }
  $evidence[$st].file = $files[-1].Name
  $anyTerms = $false
  foreach ($f in $files) {
    try { $d = Read-JsonFile $f.FullName } catch { continue }
    # @($d.capture_terms) on a MISSING property yields @($null) - an array of Count 1 - so a store that
    # records nothing looked populated, the blocker report stayed silent, and the null went on to throw
    # inside the loop below. Filter before counting; an array of nothing must count as nothing.
    $ct = @(@($d.capture_terms) | Where-Object { $_ })
    if (-not $ct.Count) { continue }
    $anyTerms = $true
    foreach ($t in $ct) {
      if ($null -eq $t) { continue }
      $cid = $null
      # A capture row that carries neither key is not evidence of anything, and indexing a null PSObject
      # here throws - which is how the first run died on a store whose capture_terms array holds nulls.
      $tk = if ($t.PSObject.Properties.Name -contains 'term_key') { [string]$t.term_key } else { '' }
      $tm = if ($t.PSObject.Properties.Name -contains 'term')     { [string]$t.term }     else { '' }
      if ($tk) { $cid = $tk } elseif ($tm) { $cid = $cidOfTerm[$tm.Trim().ToLower()] }
      if (-not $cid) { continue }
      if (-not $evidence[$st].terms.ContainsKey($cid)) { $evidence[$st].terms[$cid] = New-Object System.Collections.ArrayList }
      [void]$evidence[$st].terms[$cid].Add([pscustomobject]@{ term = $tm; outcome = [string]$t.outcome; row_count = [int]$t.row_count; source = $f.Name })
    }
  }
  if (-not $anyTerms) { $noEvidenceStores.Add("$st (capture records no per-term outcomes)") }
}

$cmpF = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1
$cmp = (Read-JsonFile $cmpF.FullName).comparison
$allow = @{}
foreach ($a in @((Read-JsonFile (Join-Path $root 'coverage-gap-allowlist.json')).allow | Where-Object { $_ })) {
  $allow[([string]$a.commodity + '|' + [string]$a.store)] = $true
}

$todayS = $todayDt.ToString('yyyy-MM-dd')
$derived = New-Object System.Collections.Generic.List[object]
$refusedList = New-Object System.Collections.Generic.List[string]
$stat = [ordered]@{ 'NOT CARRIED (two or more wordings, none found it)' = 0; 'REFUSED (one wording only - a second, differently worded search is owed)' = 0
                    'no evidence (store records no term outcome)' = 0; 'inconclusive (never asked, rejected, or the capture kept no search text)' = 0
                    'already allowlisted as unpriceable' = 0 }
foreach ($r in $cmp) {
  $have = @{}; foreach ($s in @($r.stores)) { $have[[string]$s.store] = $true }
  foreach ($st in $STORE_PREFIX.Keys) {
    if ($have.ContainsKey($st)) { continue }
    if ($allow.ContainsKey([string]$r.id + '|' + $st)) { $stat['already allowlisted as unpriceable']++; continue }
    $ts = $evidence[$st].terms[[string]$r.id]
    if (-not $ts) { $stat['no evidence (store records no term outcome)']++; continue }
    $res = New-TcNotCarriedEntry ([string]$r.id) $st @($ts) $evidence[$st].file $todayS
    if ($res.Entry) { $stat['NOT CARRIED (two or more wordings, none found it)']++; $derived.Add($res.Entry); continue }
    if ($res.Refused -eq 'single-search') {
      $stat['REFUSED (one wording only - a second, differently worded search is owed)']++
      $refusedList.Add(([string]$r.id + ' @ ' + $st))
    } else { $stat['inconclusive (never asked, rejected, or the capture kept no search text)']++ }
  }
}

# Hand-written entries are never touched. Only derived rows are replaced, so a re-run always restamps
# `checked` from today's captures and an entry that stops being observable simply ages out.
$kept = @(@($doc.entries) | Where-Object { $_ -and [string]$_.basis -ne 'derived' })
$missing = ($stat['no evidence (store records no term outcome)'] + $stat['inconclusive (never asked, rejected, or the capture kept no search text)'])

Write-Output ("not-carried: missing board cells classified from {0} store capture(s), searches inside {1} days of {2}" -f $STORE_PREFIX.Count, $recheck, $todayS)
foreach ($k in $stat.Keys) { Write-Output ("   {0,5}  {1}" -f $stat[$k], $k) }
Write-Output ("   {0,5}  {1}" -f $derived.Count, 'DERIVED entries written by this run')
Write-Output ("   {0,5}  {1}" -f $kept.Count, 'declared entries kept untouched')
if ($refusedList.Count) {
  Write-Output ''
  Write-Output ("REFUSED {0} candidate(s) resting on ONE wording - nothing is written for them. UNCHECKED IS NEVER NOT-CARRIED:" -f $refusedList.Count)
  foreach ($x in $refusedList) { Write-Output ("   " + $x) }
  Write-Output 'Give the capture a second, differently worded search (search-verdict-lib Get-RetryLadder) and they answer themselves.'
}
if ($noEvidenceStores.Count) {
  Write-Output ''
  Write-Output 'THE ACTUAL BLOCKER - these stores cannot be derived from at all, so their gaps stay unexplained:'
  foreach ($s in $noEvidenceStores) { Write-Output ("   " + $s) }
  Write-Output 'Fix is capture-side: write {term_key, term, outcome, row_count} per search the way bakers-regular does,'
  Write-Output ("and " + $missing + " of these cells answer themselves on the next pull.")
}
if (-not $Apply) { Write-Output ''; Write-Output 'DRY RUN. Pass -Apply to write not-carried.json.'; exit 0 }

$doc.entries = @($kept + @($derived | ForEach-Object { [pscustomobject]$_ }))
[void](Write-TcLfFile -Path $ncFile -Text ($doc | ConvertTo-Json -Depth 8))
$null = Read-JsonFile $ncFile      # validate round-trip
Write-Output ''
Write-Output ("WROTE not-carried.json - {0} entries ({1} derived, {2} declared), recheck_days={3}" -f @($doc.entries).Count, $derived.Count, $kept.Count, $recheck)
