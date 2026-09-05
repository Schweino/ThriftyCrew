<#
  audit-coverage-gaps.ps1 - HOLISTIC guard against a store being SILENTLY dropped from a commodity because its
  real product name doesn't fit a too-strict include regex (the Hy-Vee "Pork Loin TOP Loin Chops" bug: the
  matcher wanted "pork chop" contiguous, so a store that clearly sells the item vanished with no signal).

  For every commodity x store where the store is NOT on the board, we scan that store's RAW pulled products
  (the same source files compare-deals reads) for a name that matches a LOOSENED version of the commodity's
  own include patterns (\s+ -> ".{0,25}", so intervening words like "top" no longer break the match) and is not
  an excluded/prepared form. A hit = the store HAS the product but the strict matcher dropped it => a coverage
  gap to fix (usually by widening that commodity's include, exactly as we just did for pork-chops).

  Output: out\coverage-gaps.json { generated, gap_count, actionable_count, by_reason, gaps:[...] } + a summary.
  Every gap now carries the REASON the engine itself gives for the store's absence (CLAIMED-BY /
  RULE-INVISIBLE / BASIS-NULL / BAND-DROPPED) - see the long note at the classification step for why the
  blanket "too-strict include" headline was false for 29 of 36 gaps on 2026-08-02.
  Exit 2 if any ACTIONABLE gap (CLAIMED-BY / RULE-INVISIBLE / PRICED / unclassifiable); 3 = BLIND (zero raw
  products for every store). A gap the engine explains with its own basis or band gate is reported and
  counted but does not page.
  This is what makes "a store that carries an item
  never silently disappears" a checkable invariant for ALL stores, not a thing we notice by eyeballing.
#>
# -CommoditiesFile / -AllowFile / -CandidatesFile / -ReportDir exist so a FROZEN FIXTURE can drive this
# audit end to end without touching live state. They all default to the live paths, so daily behaviour is
# unchanged. -AllowFile matters more than it looks: the live allowlist is keyed commodity|store, so a real
# allowlist entry added tomorrow could silently delete a fixture's gap and the test would pass by finding
# nothing - the exact way the Lysol negative test stopped testing anything.
param([string]$OutDir = "", [string]$CompareFile = "", [string]$CandidatesFile = "", [string]$ReportDir = "",
      [string]$CommoditiesFile = "", [string]$AllowFile = "", [int]$MatchTimeoutMs = 250, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
. (Join-Path $PSScriptRoot 'regular-fileset-lib.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')

# ---- BOUNDED-TIME MATCHING (2026-08-14) ----------------------------------------------------------
# Every match in this script runs under a per-call timeout instead of PowerShell's -imatch, which has none.
# WHY. The commodity loop rewrites each `\s` in an include into `.{0,25}`. A V4-generated include for
# quinoa-uncooked nested a `+` inside a {0,6} group followed by a `*` group; once loosened those elements
# overlap and the match goes exponential - measured at 396-405ms to FAIL a single product name, on every
# name tried. Times 7 stores times thousands of names, one instance of this script consumed 829 CPU-MINUTES
# on a pegged core, wrote nothing for over 24 hours, and blocked the daily pipeline for 11 hours; the board
# went stale and every downstream guard went with it. A second instance of the SAME script finished in about
# three minutes, because whether it hangs depends on which product names that day's capture holds.
# A guard that can hang the pipeline it protects is a worse failure than the gap it looks for.
# The offending pattern was fixed, but the bound stays: it is what makes the NEXT one survivable.
# NOT RegexOptions::Compiled. There are ~49,500 pattern instances across the catalog (~3,200 distinct) and
# Compiled emits IL per pattern at CONSTRUCTION, paid whether or not the pattern ever matches. Measured here
# it was far worse than the interpreted engine it was meant to beat.
# A timed-out match is NOT a silent no-match: it is counted, printed, and written to the report, because
# "could not decide" is not the same answer as "no gap here".
$reOpt = [Text.RegularExpressions.RegexOptions]::IgnoreCase
$reSpan = [TimeSpan]::FromMilliseconds([Math]::Max(25, $MatchTimeoutMs))
$MAXPATTERNTIMEOUTS = 3
# No $script: prefixes: in PS 5.1 a function may MUTATE a parent-scope object (.Add, index assignment)
# but a bare `$x =` inside the function would create a local instead. Both of these are mutated in place.
$reCache = @{}
$reTimeouts = New-Object System.Collections.ArrayList
$reDead = @{}     # pattern -> timeout count; at MAXPATTERNTIMEOUTS the pattern is quarantined
function New-Probe([string]$Pattern) {
  if (-not $reCache.ContainsKey($Pattern)) {
    try { $reCache[$Pattern] = New-Object Text.RegularExpressions.Regex($Pattern, $reOpt, $reSpan) }
    catch { $reCache[$Pattern] = $null }   # illegal pattern: surfaced by the rule editor, not this audit
  }
  return $reCache[$Pattern]
}
# CIRCUIT BREAKER. A per-match timeout alone still costs $MatchTimeoutMs on EVERY name once a pattern is
# pathological, and this loop sees commodities x stores x names - so the bound alone bought a slower hang,
# not a fix. After MAXPATTERNTIMEOUTS timeouts a pattern is quarantined for the rest of the run.
function Test-Probe($Rx, [string]$Name, [string]$Ctx) {
  if (-not $Rx) { return $false }
  $key = $Rx.ToString()
  if ([int]$reDead[$key] -ge $MAXPATTERNTIMEOUTS) { return $false }
  try { return $Rx.IsMatch($Name) }
  catch [Text.RegularExpressions.RegexMatchTimeoutException] { $null = Note-Timeout $Rx $Name $Ctx; return $false }
}
# Records one timeout and returns $true once the pattern has just crossed into quarantine. Split out of
# Test-Probe so the commodity loop below can call $rx.IsMatch directly and pay for bookkeeping ONLY when a
# timeout fires - see the note at that loop.
function Note-Timeout($Rx, [string]$Name, [string]$Ctx) {
  $key = $Rx.ToString()
  $reDead[$key] = [int]$reDead[$key] + 1
  $q = ([int]$reDead[$key] -ge $MAXPATTERNTIMEOUTS)
  [void]$reTimeouts.Add([pscustomobject]@{ context = $Ctx; pattern = $key; name = $Name; quarantined = $q })
  return $q
}
function Live-Probes($Probes) { @($Probes | Where-Object { $_ -and ([int]$reDead[$_.ToString()] -lt $MAXPATTERNTIMEOUTS) }) }

if ($SelfTest) {
  # Hermetic: reads no board, no capture, no commodities file. The founding bug is FROZEN here as the
  # must-fire fixture - the exact loosened shape of the quinoa-uncooked include that burned 829 CPU-minutes
  # on 2026-08-14 - beside a clean twin that must still match normally.
  $bad = 0
  $FOUNDING = '^(?:[\w&.-]+.{0,25}){0,6}(?:(?:organic|whole[- ]grain|white|red|black|tri[- ]?colou?r).{0,25})*quinoa$'
  $VICTIM   = 'Just Bare boneless skinless chicken breasts, 18 oz., $4.99'
  $rxBad = New-Probe $FOUNDING
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $r1 = Test-Probe $rxBad $VICTIM 'selftest|founding'
  $sw.Stop()
  if ($reTimeouts.Count -lt 1) { Write-Output '  X MUST-FIRE: the founding ReDoS pattern did NOT time out - the bound is not armed'; $bad++ }
  if ($r1) { Write-Output '  X the timed-out match returned TRUE; a match it could not decide must not read as a hit'; $bad++ }
  if ($sw.ElapsedMilliseconds -gt ($MatchTimeoutMs * 4)) { Write-Output ("  X the bound did not hold: one match took {0}ms against a {1}ms timeout" -f $sw.ElapsedMilliseconds, $MatchTimeoutMs); $bad++ }
  # circuit breaker: after MAXPATTERNTIMEOUTS the pattern is skipped, so the cost stops growing
  for ($i = 0; $i -lt ($MAXPATTERNTIMEOUTS + 2); $i++) { $null = Test-Probe $rxBad $VICTIM 'selftest|founding' }
  if ($reTimeouts.Count -gt $MAXPATTERNTIMEOUTS) { Write-Output ("  X the breaker never tripped: {0} timeouts recorded past a limit of {1}" -f $reTimeouts.Count, $MAXPATTERNTIMEOUTS); $bad++ }
  $swQ = [Diagnostics.Stopwatch]::StartNew(); $null = Test-Probe $rxBad $VICTIM 'selftest|founding'; $swQ.Stop()
  if ($swQ.ElapsedMilliseconds -ge $MatchTimeoutMs) { Write-Output '  X a quarantined pattern still paid the full timeout'; $bad++ }
  # CLEAN TWIN: the shipped replacement must still decide normally and correctly
  $rxOk = New-Probe '\bquinoa\b'
  $beforeClean = $reTimeouts.Count
  if (-not (Test-Probe $rxOk 'Simple Truth Organic Quinoa' 'selftest|clean')) { Write-Output '  X clean twin failed to match real quinoa'; $bad++ }
  if (Test-Probe $rxOk $VICTIM 'selftest|clean') { Write-Output '  X clean twin matched a chicken breast'; $bad++ }
  if ($reTimeouts.Count -ne $beforeClean) { Write-Output '  X clean twin recorded a timeout'; $bad++ }
  if ($bad -eq 0) { Write-Output 'audit-coverage-gaps SELF-TEST PASS (founding ReDoS times out, breaker quarantines it, clean twin still decides)'; exit 0 }
  Write-Output ("audit-coverage-gaps SELF-TEST FAIL ({0} problem(s))" -f $bad); exit 1
}
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
if (-not $ReportDir) { $ReportDir = $OutDir }
if (-not $CommoditiesFile) { $CommoditiesFile = Join-Path $root 'commodities.json' }
$commods = Read-JsonFile $CommoditiesFile
$stores = @('Hy-Vee','Aldi','Family Fare','Fareway',"Baker's","Sam's Club",'Walmart')
# prepared/different-form words that legitimately are NOT the plain commodity (so a match on them is not a gap)
$GLOBAL = @('seasoning','marinade','\bsauce\b','\brub\b','\bkit\b','bundle','\bmeal\b','wrapped','breaded','\bnugget','\bjerky\b','flavored','\bdip\b','helper','lunchable','\bsoup\b','gravy','stuffing')
# ...and the ENGINE's own global exclusions (pet food, baby food, cleaning supplies, personal care), which
# live in compare-deals.ps1 and were never read here. Without them this audit reports candidates the engine
# deliberately refuses and can never accept - a Happy Tot baby-food pouch was filed as "Baker's is missing
# from spinach" every day (2026-07-28). An auditor that disagrees with the engine is a permanent false alarm,
# so read the real list (same parse audit-match-contested.ps1 uses) instead of keeping a second opinion.
$ENGINE_GLOBAL = @()
try {
  $cdtxt = Get-Content (Join-Path $root 'compare-deals.ps1') -Raw
  $mg = [regex]::Match($cdtxt, '\$GLOBAL_EXCLUDE = @\((?<b>[\s\S]*?)\r?\n\)')
  if ($mg.Success) { $ENGINE_GLOBAL = @(Invoke-Expression ('@(' + $mg.Groups['b'].Value + ')')) }
} catch { Write-Output ('WARN could not read the engine GLOBAL_EXCLUDE (' + $_.Exception.Message + ') - gaps may include engine-excluded products') }
# ...and the engine's IN-STORE gate, for the same reason (see instore-lib.ps1).
. (Join-Path $root 'instore-lib.ps1')

# ---- gather each store's RAW pulled product names (same inputs compare-deals uses) ----
$prod = @{}
function AddP([string]$store,[string]$name) { if (-not $store -or -not $name) { return }; if (-not $prod.ContainsKey($store)) { $prod[$store] = New-Object System.Collections.Generic.List[string] }; $prod[$store].Add($name) }
# weekly ads (flat .deals with {store,item})
$adsF = Get-ChildItem (Join-Path $OutDir 'ads-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if ($adsF) { foreach ($d in (Read-JsonFile $adsF.FullName).deals) { AddP ([string]$d.store) ([string]$d.item) } }
# Everyday shelf files (per store; store on the doc or the deal). NEWEST PER STORE ONLY, and only
# within the same 14-day window the engine itself honours (2026-07-27). Reading EVERY regular file
# ever written - which this did - manufactures false gaps two ways: a product the store has since
# DELISTED still counts as carried (Baker's does a complete daily API pull, so absence from the
# newest file is real), and a file past the freshness cliff counts at all (a Family Fare row from
# 21 days ago). Both then read as "the store carries it but a too-strict regex dropped it", which
# is the opposite of what happened. Every other source below already takes -First 1.
$regNewest = @{}
foreach ($rf in (Get-ChildItem (Join-Path $OutDir 'regular\*.json') -ErrorAction SilentlyContinue)) {
  $m = [regex]::Match($rf.BaseName, '^(.+)-regular-(\d{4}-\d{2}-\d{2})$')
  if (-not $m.Success) { continue }                     # stray file: guard 12 owns that failure
  $pfx = $m.Groups[1].Value; $stamp = $m.Groups[2].Value
  if (-not $regNewest.ContainsKey($pfx) -or $stamp -gt $regNewest[$pfx].stamp) {
    $regNewest[$pfx] = [pscustomobject]@{ stamp = $stamp; file = $rf }
  }
}
# The floor is ASKED FOR, not restated. The comment above says 'the same window the engine itself
# honours' - it said 14 while the engine moved to the 90-day quarter, so this manufactured exactly
# the false gaps it was written to prevent.
$freshFloor = (Get-Date).AddDays(-(Get-RegularUnionDays)).ToString('yyyy-MM-dd')
foreach ($k in $regNewest.Keys) {
  $entry = $regNewest[$k]
  if ($entry.stamp -lt $freshFloor) { continue }        # past the cliff: the engine would not price it either
  try { $doc = Read-JsonFile $entry.file.FullName } catch { continue }
  # ...and skip the rows the ENGINE's in-store gate refuses (2026-08-31). Same reasoning as the
  # $GLOBAL_EXCLUDE lift above: a ship-only or third-party listing can never win a cell, so reporting it as
  # "the store carries this but the board is missing it" is a gap nobody can ever close. Shared rule, not a
  # second opinion - see instore-lib.ps1. Rows with no fulfillment field are unaffected (absent is not a
  # verdict), which is every capture written before 2026-08-30.
  # ...and since 2026-09-01 that agreement has to include the CHANNEL rule, not just the row's own
  # fulfillment word: the engine refuses a blank fulfillment inside a capture that populates the field on
  # the rest of its rows (an unattributed row, over half of them "(N pack)" online bundles - see
  # instore-lib.ps1). Without this, every such row reads here as "the store carries this and the board is
  # missing it", a gap nobody can ever close.
  # SCOPED TO ONE FILE ON PURPOSE, and the limit is worth saying out loud: this reader takes the NEWEST
  # capture per store, so the engine's other shape - a carried pre-field row whose item id is refused in a
  # fresher capture - cannot arise here at all. There is no second file to carry it.
  $cgRows = New-Object System.Collections.Generic.List[object]
  foreach ($d in $doc.deals) {
    $sN = if ($doc.store) { [string]$doc.store } else { [string]$d.store }
    [void]$cgRows.Add([pscustomobject]@{ store = $sN; src_file = $entry.file.BaseName; item_id = ([string]$d.item_id); product_id = ([string]$d.product_id); fulfillment = ([string]$d.fulfillment) })
  }
  $cgIdx = New-ChannelIndex -Rows $cgRows -Allowlist (Get-ChannelAllowlist -Path (Join-Path $root 'instore-channel-allowlist.json'))
  foreach ($d in $doc.deals) {
    $s = if ($doc.store) { [string]$doc.store } else { [string]$d.store }
    $iid = ([string]$d.item_id); if (-not $iid) { $iid = ([string]$d.product_id) }
    if (-not (Get-ChannelVerdict -Index $cgIdx -Store $s -SrcFile ($entry.file.BaseName) -ItemId $iid -Fulfillment $d.fulfillment -ItemName ([string]$d.item)).in_store) { continue }
    AddP $s ([string]$d.item); if ($d.name) { AddP $s ([string]$d.name) }
  }
}
# browser-store deal files
foreach ($glob in @('bakers\bakers-deals-*.json','sams\sams-deals-*.json','fareway\fareway-deals-*.json')) {
  $f = Get-ChildItem (Join-Path $OutDir $glob) -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  if ($f) { foreach ($d in (Read-JsonFile $f.FullName).deals) { AddP ([string]$d.store) ([string]$d.item) } }
}

# reviewed, legitimate exceptions (a store carries the item but it genuinely can't be priced like-for-like:
# a combined "A or B or C" ad line, or a by-volume pack with no comparable weight). Keyed commodity|store so
# the detector only alerts on NEW / unreviewed gaps, never re-cries a known one.
$allow = @{}
$allowF = if ($AllowFile) { $AllowFile } else { Join-Path $root 'coverage-gap-allowlist.json' }
if (Test-Path $allowF) { try { foreach ($a in (Read-JsonFile $allowF).allow) { $allow[([string]$a.commodity + '|' + [string]$a.store)] = $true } } catch {} }
# NOT-CARRIED: the OTHER reason a cell is legitimately missing. The allowlist above says "the store sells
# it and we cannot price it like-for-like"; not-carried.json says "the store does not sell it", derived
# from the store's own capture evidence (see derive-not-carried.ps1). Both explain a gap; conflating them
# would let a measurement failure hide inside a fact about a shelf, so they stay in separate files.
#
# EXPIRY IS ENFORCED HERE, not in the file. An entry older than recheck_days stops explaining anything and
# the gap goes back to being reported - because a store that BEGINS stocking an item is exactly the event
# this audit exists to notice, and a permanent marker would bury it. Silence must be re-earned each quarter.
$ncStale = 0; $ncFresh = 0; $ncDeclaredStale = 0
$ncF = Join-Path $root 'not-carried.json'
if (Test-Path $ncF) {
  try {
    $ncDoc = Read-JsonFile $ncF
    $ncDays = if ($ncDoc.PSObject.Properties.Name -contains 'recheck_days') { [int]$ncDoc.recheck_days } else { 90 }
    $now = Get-Date
    foreach ($e in @(@($ncDoc.entries) | Where-Object { $_ })) {
      $age = $null
      try { $age = ($now - [datetime][string]$e.checked).TotalDays } catch { }
      if ($null -ne $age -and $age -le $ncDays) {
        $allow[([string]$e.commodity + '|' + [string]$e.store)] = $true
        $ncFresh++
      } else {
        $ncStale++
        if ([string]$e.basis -ne 'derived') { $ncDeclaredStale++ }
      }
    }
  } catch { }
}
if ($ncFresh -or $ncStale) {
  Write-Output ("not-carried: {0} entr(y/ies) explain a gap; {1} EXPIRED past {2} days and are being reported again{3}" -f `
    $ncFresh, $ncStale, $ncDays, $(if ($ncDeclaredStale) { " ($ncDeclaredStale of them hand-declared, so nothing will re-observe them - recheck or drop them)" } else { '' }))
}

# ---- which stores are already on the board per commodity ----
if (-not $CompareFile) { $CompareFile = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName }
$present = @{}
foreach ($r in (Read-JsonFile $CompareFile).comparison) { foreach ($s in $r.stores) { $present[([string]$r.id + '|' + [string]$s.store)] = $true } }

# ---- for each missing store, look for a loosened-include match in its raw products ----
$gaps = New-Object System.Collections.Generic.List[object]
# DEDUPE EACH STORE'S PRODUCT LIST ONCE, not inside the commodity x store loop. `$prod[$st] | Select-Object
# -Unique` used to sit on the inner foreach, so it re-sorted the same 7 string lists for every (commodity,
# store) pair that got that far: 673 pairs x up to 6,989 names = 1,644,486 names re-deduplicated per run,
# measured at 140.9s of this script's 181s. Hoisted it is 2.3s. Behaviour is identical - Select-Object -Unique
# is order-preserving and the loop below already stops at MAXCAND. This script runs ~10x/week and every second
# of it is on the critical path: -Phase compare cannot return until it finishes.
$prodUniq = @{}
foreach ($s in $prod.Keys) { $prodUniq[$s] = @($prod[$s] | Select-Object -Unique) }
$noRaw = @($stores | Where-Object { -not $prod.ContainsKey($_) })

foreach ($c in $commods) {
  $id = [string]$c.id
  # loosen the include: allow up to 25 chars where it required whitespace. Handle \s* and \s+ BEFORE bare \s,
  # or "\s*" becomes ".{0,25}*" (a nested quantifier that throws). Order matters.
  $probes = @($c.include | ForEach-Object { New-Probe(((($_ -replace '\\s\*', '.{0,25}') -replace '\\s\+', '.{0,25}') -replace '\\s', '.{0,25}')) })
  $excl = @($c.exclude | Where-Object { $_ } | ForEach-Object { New-Probe ([string]$_) })
  # relax_global waivers (pasta-sauce IS a sauce etc.) are applied ONCE per commodity, not per product name
  $relax = @($c.relax_global | Where-Object { $_ })
  $globP = @($GLOBAL | Where-Object { $relax -notcontains $_ } | ForEach-Object { New-Probe ([string]$_) })
  $engP  = @($ENGINE_GLOBAL | Where-Object { $relax -notcontains $_ } | ForEach-Object { New-Probe ([string]$_) })
  # The four lists below are the LIVE (non-quarantined) probes. They are re-filtered only when a timeout
  # pushes a pattern over MAXPATTERNTIMEOUTS, so the hot loop never consults $reDead.
  $pI = Live-Probes $probes; $pX = Live-Probes $excl; $pG = Live-Probes $globP; $pE = Live-Probes $engP
  foreach ($st in $stores) {
    if ($present.ContainsKey($id + '|' + $st)) { continue }
    if ($allow.ContainsKey($id + '|' + $st)) { continue }
    if (-not $prod.ContainsKey($st)) { continue }
    # Collect up to MAXCAND matching candidates, not just the first. Reporting ONE candidate and stopping
    # led reviewers to write allowlist entries asserting "the only thing at this store matching the include
    # regex is X" - a claim this audit's output could never support. On 2026-07-27 that produced at least
    # five false entries; the worst, tater-tots @ Baker's, was stamped on the strength of a corn-tot match
    # while the store carried SIX real Ore-Ida tater tot products, one of them fully priceable at
    # $5.49/32 oz. A one-day-old entry was hiding the estate's largest store from a commodity it carries.
    # An allowlist decision is only as good as the evidence put in front of the reviewer.
    $MAXCAND = 5
    $found = New-Object System.Collections.Generic.List[string]
    # HOT LOOP (2026-08-22). This block runs ~1.6M (name x store x commodity) times per day. The 2026-08-14
    # ReDoS fix routed every match through Test-Probe, and a PowerShell function call per (name, pattern)
    # - plus a .ToString() and a hashtable lookup inside it - took the script from ~24s to 94-150s. The
    # timeout bound and the breaker are unchanged: every [regex] here was built by New-Probe with the same
    # MatchTimeout, and a RegexMatchTimeoutException still lands in Note-Timeout, which counts it, reports
    # it, and quarantines the pattern (the live lists are rebuilt so the quarantined pattern is skipped).
    # What moved is WHERE the bookkeeping is paid: only on a timeout, never on the millions of clean calls.
    foreach ($nm in $prodUniq[$st]) {
      $hit = $false
      foreach ($p in $pI) {
        try { if ($p.IsMatch($nm)) { $hit = $true; break } }
        catch [Text.RegularExpressions.RegexMatchTimeoutException] { if (Note-Timeout $p $nm ($id + '|include')) { $pI = Live-Probes $probes } }
      }
      if (-not $hit) { continue }
      $bad = $false
      foreach ($x in $pX) {
        try { if ($x.IsMatch($nm)) { $bad = $true; break } }
        catch [Text.RegularExpressions.RegexMatchTimeoutException] { if (Note-Timeout $x $nm ($id + '|exclude')) { $pX = Live-Probes $excl } }
      }
      # honor the commodity's relax_global waivers (pasta-sauce IS a sauce etc.) so those commodities still
      # get coverage-gap protection instead of every candidate being silently global-excluded
      if (-not $bad) { foreach ($x in $pG) {
        try { if ($x.IsMatch($nm)) { $bad = $true; break } }
        catch [Text.RegularExpressions.RegexMatchTimeoutException] { if (Note-Timeout $x $nm ($id + '|global')) { $pG = Live-Probes $globP } }
      } }
      if (-not $bad) { foreach ($x in $pE) {
        try { if ($x.IsMatch($nm)) { $bad = $true; break } }
        catch [Text.RegularExpressions.RegexMatchTimeoutException] { if (Note-Timeout $x $nm ($id + '|engine-global')) { $pE = Live-Probes $engP } }
      } }
      if ($bad) { continue }
      $found.Add($nm)
      if ($found.Count -ge $MAXCAND) { break }
    }
    if ($found.Count -gt 0) {
      $gaps.Add([pscustomobject]@{ commodity = $id; store = $st; candidate = $found[0]
                                   candidates = @($found); candidate_count = $found.Count
                                   truncated = ($found.Count -ge $MAXCAND) })
    }
  }
}

# ---------------------------------------------------------------- WHY is the store absent? (2026-08-02)
# THE FILTER-DIVERGENCE BUG THIS FIXES. Everything above validates a candidate against include/exclude
# regexes only. The ENGINE also requires two more things before a row reaches the board: a basis it can
# express in the commodity's unit, and the sanity band. So this audit has been reporting as "a store was
# DROPPED by a too-strict include" a pile of rows the engine deliberately cannot or will not price, and
# blaming includes that are fine. Measured on 2026-08-02: the top candidate MATCHED and routed to the
# target commodity for 29 of 36 reported gaps. The alert's own headline premise was false for 80 percent
# of its contents, every single day, which is how a real find (salt eating a berbere jar) gets lost.
#
# THE FIX IS NOT A SECOND COPY OF THE ENGINE. compare-deals already writes out\candidates-<date>.json, and
# every row in it carries the engine's OWN verdict in .basis: 'UNPRICED' when Get-UnitPrice returned null,
# 'OUT-OF-BAND' when Test-Band rejected it, otherwise the real basis string. Reading that file classifies
# every candidate with the engine's own gates, run by the engine, on the same board this audit is checking.
# A reimplementation here would be the third copy of the matching math in this estate and would drift.
#
#   CLAIMED-BY      the engine routed this exact name to a DIFFERENT commodity (first-match-wins). A real
#                   rule bug, and the class this audit could never see before, because it never simulates
#                   routing. PAGES.
#   RULE-INVISIBLE  the engine never matched the name to anything. Only the LOOSENED probe saw it, so the
#                   real include genuinely cannot. PAGES - this is the founding pork-chops bug.
#   BASIS-NULL      the engine matched it and could not express a price in the commodity's unit ('Fresh
#                   Lemons, 2 lb Bag' on a per-EACH commodity). Not an include problem. Listed, does not page.
#   BAND-DROPPED    the engine matched and priced it and the sanity band refused the number. A band decision,
#                   not an include problem. Listed with the number so it can be judged. Does not page.
#
# Exit 2 is now reserved for the two actionable classes. This is NOT the gate going soft: every gap is still
# counted, still written to the report, and still printed. What changed is that a daily page now means
# something a rule edit can fix. A run that cannot READ the candidates file classifies nothing and keeps the
# old behaviour of paging on everything, because going quiet on missing evidence is the failure mode that
# started all this.
if (-not $CandidatesFile) {
  $cf = @(Get-ChildItem (Join-Path $OutDir 'candidates-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1)
  if ($cf.Count) { $CandidatesFile = $cf[0].FullName }
}
function CgNorm([string]$s) { return ((($s + '') -replace '\s+', ' ').Trim().ToLower()) }
$engineRow = @{}      # "id|store|name" -> the engine's candidate row
$engineOwner = @{}    # "store|name"    -> list of commodity ids the engine matched it to
$classifiable = $false
if ($CandidatesFile -and (Test-Path $CandidatesFile)) {
  try {
    $cdoc = Read-JsonFile $CandidatesFile
    foreach ($cc in @($cdoc.commodities)) {
      $cid = [string]$cc.id
      foreach ($cr in @($cc.candidates)) {
        $k = $cid + '|' + [string]$cr.store + '|' + (CgNorm ([string]$cr.name))
        if (-not $engineRow.ContainsKey($k)) { $engineRow[$k] = $cr }
        $ok = [string]$cr.store + '|' + (CgNorm ([string]$cr.name))
        if (-not $engineOwner.ContainsKey($ok)) { $engineOwner[$ok] = New-Object System.Collections.Generic.List[string] }
        if (-not $engineOwner[$ok].Contains($cid)) { [void]$engineOwner[$ok].Add($cid) }
      }
    }
    $classifiable = ($engineRow.Count -gt 0)
  } catch { Write-Output ('WARN could not read ' + $CandidatesFile + ' (' + $_.Exception.Message + ') - gaps cannot be classified this run') }
}
function Classify([string]$id, [string]$store, [string]$name) {
  if (-not $classifiable) { return [pscustomobject]@{ reason = 'UNCLASSIFIED'; detail = 'no engine candidates file to read'; actionable = $true } }
  $k = $id + '|' + $store + '|' + (CgNorm $name)
  if ($engineRow.ContainsKey($k)) {
    $b = [string]$engineRow[$k].basis
    if ($b -eq 'UNPRICED')    { return [pscustomobject]@{ reason='BASIS-NULL';   detail=("the engine matched it and could not express a price in this commodity's unit (size '" + [string]$engineRow[$k].size_text + "')"); actionable=$false } }
    if ($b -eq 'OUT-OF-BAND') { return [pscustomobject]@{ reason='BAND-DROPPED'; detail=("the engine matched and priced it; the sanity band refused the number (ad " + [string]$engineRow[$k].price_text + ", size '" + [string]$engineRow[$k].size_text + "')"); actionable=$false } }
    return [pscustomobject]@{ reason='PRICED'; detail=("the engine priced this row (basis '" + $b + "') yet the store is absent from the board - look downstream of matching"); actionable=$true }
  }
  $ok = $store + '|' + (CgNorm $name)
  if ($engineOwner.ContainsKey($ok)) {
    $others = @($engineOwner[$ok] | Where-Object { $_ -ne $id })
    if ($others.Count) { return [pscustomobject]@{ reason='CLAIMED-BY'; detail=("first-match-wins gave this name to '" + ($others -join "', '") + "'"); actionable=$true } }
  }
  return [pscustomobject]@{ reason='RULE-INVISIBLE'; detail='no include of any commodity matched this name (only the loosened probe did)'; actionable=$true }
}
# Rebuilt rather than Add-Member'd: in PS 5.1 Add-Member -Value with an array argument throws
# "Argument types do not match" here, and a classification that dies is worse than one that is verbose.
$classed = New-Object System.Collections.Generic.List[object]
foreach ($gp in $gaps) {
  $verdicts = New-Object System.Collections.Generic.List[object]
  foreach ($nm in @($gp.candidates)) {
    $v = Classify ([string]$gp.commodity) ([string]$gp.store) ([string]$nm)
    [void]$verdicts.Add([pscustomobject]@{ candidate = $nm; reason = $v.reason; detail = $v.detail; actionable = $v.actionable })
  }
  $act = @($verdicts | Where-Object { $_.actionable })
  $pick = $(if ($act.Count) { $act[0] } else { $verdicts[0] })
  [void]$classed.Add([pscustomobject]@{
    commodity = [string]$gp.commodity; store = [string]$gp.store; candidate = [string]$gp.candidate
    candidates = @($gp.candidates); candidate_count = $gp.candidate_count; truncated = $gp.truncated
    reason = [string]$pick.reason; detail = [string]$pick.detail; actionable = ($act.Count -gt 0)
    verdicts = $verdicts.ToArray() })
}
$gaps = $classed
$actionable = @($gaps | Where-Object { $_.actionable })
$quiet      = @($gaps | Where-Object { -not $_.actionable })

$timeouts = @($reTimeouts.ToArray())
$report = [ordered]@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); gap_count = $gaps.Count; actionable_count = $actionable.Count
                      classified_against = $(if ($classifiable) { Split-Path $CandidatesFile -Leaf } else { 'NOTHING - unclassified run' })
                      by_reason = @($gaps | Group-Object reason | ForEach-Object { [pscustomobject]@{ reason = $_.Name; count = @($_.Group).Count } })
                      match_timeout_ms = $MatchTimeoutMs
                      match_timeouts = $timeouts.Count
                      match_timeout_detail = @($timeouts | Group-Object context | ForEach-Object { [pscustomobject]@{ context = $_.Name; count = @($_.Group).Count; sample_name = @($_.Group)[0].name; pattern = @($_.Group)[0].pattern } })
                      stores_scanned = @($stores | Where-Object { $prod.ContainsKey($_) }); stores_not_scanned = $noRaw; gaps = $gaps }
$report | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $ReportDir 'coverage-gaps.json') -Encoding UTF8
if ($timeouts.Count) {
  # Loud on purpose. Each of these is a (pattern, product name) pair this audit could NOT decide, so the
  # store may carry the commodity and this run cannot say. Silence here would read as "no gap".
  Write-Output ("coverage-gaps: {0} match(es) hit the {1}ms regex timeout and were NOT decided - this is not a clean 'no gap'. Fix the commodity's include (a pattern with several \s becomes several .{{0,25}} and can backtrack exponentially):" -f $timeouts.Count, $MatchTimeoutMs)
  foreach ($g in @($report.match_timeout_detail | Select-Object -First 10)) {
    Write-Output ("  TIMEOUT  {0,-28} x{1,-5} e.g. '{2}'" -f $g.context, $g.count, ([string]$g.sample_name).Substring(0, [Math]::Min(60, ([string]$g.sample_name).Length)))
  }
}
if ($gaps.Count) {
  Write-Output ("coverage-gaps: $($gaps.Count) store(s) absent from a commodity whose product they appear to carry - $($actionable.Count) actionable, $($quiet.Count) explained by the engine's own basis/band gates")
  foreach ($grp in @($gaps | Group-Object reason | Sort-Object Name)) { Write-Output ("  {0,-15} {1}" -f $grp.Name, @($grp.Group).Count) }
  if ($noRaw.Count) { Write-Output ("  (NOTE: zero raw products for " + ($noRaw -join ', ') + " - those stores were NOT checked and may hide more gaps)") }
  # print EVERY candidate, not just the first - a reviewer allowlisting this pair is about to make a
  # factual claim about what the store carries, so put the whole evidence set in front of them.
  foreach ($sect in @(@{ t='ACTIONABLE (a rule edit can fix these)'; g=$actionable }, @{ t='EXPLAINED - not include problems, listed for the record'; g=$quiet })) {
    if (-not @($sect.g).Count) { continue }
    Write-Output ''
    Write-Output ('--- ' + $sect.t + ' ---')
    foreach ($gp in $sect.g) {
      # EVERY candidate is printed with ITS OWN verdict, and the headline is the candidate that earned the
      # gap-level reason - not candidates[0]. Pairing a gap-level reason with the first candidate's NAME
      # reads as "'Fresh & Finest French Bread' was CLAIMED-BY garlic" when in fact that row is BASIS-NULL
      # and a different candidate on the same gap is the claimed one. This audit's whole job is to put
      # correct evidence in front of a reviewer who is about to write an allowlist entry from it.
      $ordered = @(@($gp.verdicts | Where-Object { $_.reason -eq $gp.reason }) + @($gp.verdicts | Where-Object { $_.reason -ne $gp.reason }))
      Write-Output ("  {0,-18} {1,-13} [{2}] <- '{3}'" -f $gp.commodity, $gp.store, $gp.reason, $ordered[0].candidate)
      Write-Output ("  {0,-18} {1,-13}    {2}" -f '', '', $gp.detail)
      if (@($ordered).Count -gt 1) {
        foreach ($extra in @($ordered)[1..(@($ordered).Count-1)]) { Write-Output ("  {0,-18} {1,-13}    also: [{2}] '{3}'" -f '', '', $extra.reason, $extra.candidate) }
        if ($gp.truncated) { Write-Output ("  {0,-18} {1,-13}    (list truncated - there may be more)" -f '', '') }
      }
    }
  }
  if ($actionable.Count) { Write-GuardComplete -Name 'coverage-gaps'; exit 2 }
  Write-Output ''
  Write-Output 'coverage-gaps: no ACTIONABLE gap - every absent store above is absent for a reason the engine states itself (basis it cannot express, or a sanity band). Not paging.'
  Write-GuardComplete -Name 'coverage-gaps'; exit 0
} else {
  if ($noRaw.Count -eq $stores.Count) {
    Write-Output 'coverage-gaps: BLIND - ZERO raw products parsed for EVERY store (no ads/regular/deals source yielded a name). Nothing was checked; a no-gaps verdict would be an empty claim.'
    exit 3
  }
  if ($noRaw.Count) {
    Write-Output ("coverage-gaps: none among the " + ($stores.Count - $noRaw.Count) + " store(s) scanned - but ZERO raw products for " + ($noRaw -join ', ') + "; those stores were never checked, so their absence from a commodity proves nothing (check stores.json deals_glob vs this script's hardcoded ads/regular/browser-store globs, and the store labels the files write).")
  } else {
    Write-Output 'coverage-gaps: none - every store that carries a tracked item is on the board'
  }
  Write-GuardComplete -Name 'coverage-gaps'; exit 0
}
