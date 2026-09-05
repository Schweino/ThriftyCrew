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

  Every entry carries basis=derived, the term that was searched, the outcome, the row count, the capture
  file it came from, and the date. Entries expire after recheck_days (90, following capture-policy.ps1's
  QuarterDays) - a store not stocking something today says nothing about next quarter.

  DECLARED entries (basis=declared) are written by hand for stores that cannot yet derive. This script
  never invents one, never edits one, and never deletes one - it only refreshes what it can observe. A
  human assertion and a machine observation live in the same file and are never allowed to look alike.

  Read-only unless -Apply.
#>
param([switch]$Apply, [string]$OutDir = '')
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }

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

# per store: commodity id -> its capture_terms record, from that store's NEWEST regular file
$evidence = @{}; $noEvidenceStores = New-Object System.Collections.Generic.List[string]
foreach ($st in $STORE_PREFIX.Keys) {
  $f = Get-ChildItem (Join-Path $OutDir ('regular\' + $STORE_PREFIX[$st] + '-*.json')) -ErrorAction SilentlyContinue |
       Sort-Object Name -Descending | Select-Object -First 1
  $evidence[$st] = @{ file = $null; terms = @{} }
  if (-not $f) { $noEvidenceStores.Add("$st (no regular capture)"); continue }
  $evidence[$st].file = $f.Name
  try { $d = Read-JsonFile $f.FullName } catch { $noEvidenceStores.Add("$st (unreadable capture)"); continue }
  # @($d.capture_terms) on a MISSING property yields @($null) - an array of Count 1 - so a store that
  # records nothing looked populated, the blocker report stayed silent, and the null went on to throw
  # inside the loop below. Filter before counting; an array of nothing must count as nothing.
  $ct = @(@($d.capture_terms) | Where-Object { $_ })
  if (-not $ct.Count) { $noEvidenceStores.Add("$st (capture records no per-term outcomes)"); continue }
  foreach ($t in $ct) {
    if ($null -eq $t) { continue }
    $cid = $null
    # A capture row that carries neither key is not evidence of anything, and indexing a null PSObject
    # here throws - which is how the first run died on a store whose capture_terms array holds nulls.
    $tk = if ($t.PSObject.Properties.Name -contains 'term_key') { [string]$t.term_key } else { '' }
    $tm = if ($t.PSObject.Properties.Name -contains 'term')     { [string]$t.term }     else { '' }
    if ($tk) { $cid = $tk } elseif ($tm) { $cid = $cidOfTerm[$tm.Trim().ToLower()] }
    if ($cid) { $evidence[$st].terms[$cid] = $t }
  }
}

$cmpF = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1
$cmp = (Read-JsonFile $cmpF.FullName).comparison
$allow = @{}
foreach ($a in (Read-JsonFile (Join-Path $root 'coverage-gap-allowlist.json')).allow) {
  $allow[([string]$a.commodity + '|' + [string]$a.store)] = $true
}

$today = (Get-Date).ToString('yyyy-MM-dd')
$derived = New-Object System.Collections.Generic.List[object]
$stat = [ordered]@{ 'NOT CARRIED (rows returned, none matched)' = 0; 'NOT CARRIED (search returned nothing)' = 0
                    'no evidence (store records no term outcome)' = 0; 'inconclusive (not attempted / rejected)' = 0
                    'already allowlisted as unpriceable' = 0 }
foreach ($r in $cmp) {
  $have = @{}; foreach ($s in $r.stores) { $have[[string]$s.store] = $true }
  foreach ($st in $STORE_PREFIX.Keys) {
    if ($have.ContainsKey($st)) { continue }
    if ($allow.ContainsKey([string]$r.id + '|' + $st)) { $stat['already allowlisted as unpriceable']++; continue }
    $t = $evidence[$st].terms[[string]$r.id]
    if (-not $t) { $stat['no evidence (store records no term outcome)']++; continue }
    $oc = [string]$t.outcome; $rc = [int]$t.row_count
    if ($oc -eq 'success' -and $rc -gt 0) {
      $stat['NOT CARRIED (rows returned, none matched)']++
      $derived.Add([ordered]@{ commodity=[string]$r.id; store=$st; basis='derived'; verdict='not-carried'
        evidence=("searched '" + $termOf[[string]$r.id] + "': the store returned $rc row(s) and none matched this commodity")
        outcome=$oc; row_count=$rc; source=$evidence[$st].file; checked=$today })
    } elseif ($oc -eq 'empty') {
      $stat['NOT CARRIED (search returned nothing)']++
      $derived.Add([ordered]@{ commodity=[string]$r.id; store=$st; basis='derived'; verdict='not-carried'
        evidence=("searched '" + $termOf[[string]$r.id] + "': the store's own search returned no rows at all. A poor search term looks identical from here - overturn this entry rather than the term if the store does stock it")
        outcome=$oc; row_count=$rc; source=$evidence[$st].file; checked=$today })
    } else { $stat['inconclusive (not attempted / rejected)']++ }
  }
}

# Hand-written entries are never touched. Only derived rows are replaced, so a re-run always restamps
# `checked` from today's captures and an entry that stops being observable simply ages out.
$kept = @(@($doc.entries) | Where-Object { $_ -and [string]$_.basis -ne 'derived' })
$missing = ($stat['no evidence (store records no term outcome)'] + $stat['inconclusive (not attempted / rejected)'])

Write-Output ("not-carried: missing board cells classified from {0} store capture(s)" -f $STORE_PREFIX.Count)
foreach ($k in $stat.Keys) { Write-Output ("   {0,5}  {1}" -f $stat[$k], $k) }
Write-Output ("   {0,5}  {1}" -f $derived.Count, 'DERIVED entries written by this run')
Write-Output ("   {0,5}  {1}" -f $kept.Count, 'declared entries kept untouched')
if ($noEvidenceStores.Count) {
  Write-Output ''
  Write-Output 'THE ACTUAL BLOCKER - these stores cannot be derived from at all, so their gaps stay unexplained:'
  foreach ($s in $noEvidenceStores) { Write-Output ("   " + $s) }
  Write-Output 'Fix is capture-side: write {term_key, outcome, row_count} per search the way bakers-regular does,'
  Write-Output ("and " + $missing + " of these cells answer themselves on the next pull.")
}
if (-not $Apply) { Write-Output ''; Write-Output 'DRY RUN. Pass -Apply to write not-carried.json.'; exit 0 }

$doc.entries = @($kept + $derived)
$doc | ConvertTo-Json -Depth 6 | Set-Content $ncFile -Encoding UTF8
$null = Read-JsonFile $ncFile      # validate round-trip
Write-Output ''
Write-Output ("WROTE not-carried.json - {0} entries ({1} derived, {2} declared), recheck_days={3}" -f @($doc.entries).Count, $derived.Count, $kept.Count, $recheck)
