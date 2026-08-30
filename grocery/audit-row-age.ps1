# audit-row-age.ps1 - the PER-ROW staleness guard.
#
# WHY THIS EXISTS (2026-08-07 grocery architecture review). guards.ps1 guard 9 tests the AGE OF THE FILE.
# The pullers rewrite their file every day, so that test passes every single run - while the rows INSIDE
# age independently, because every store carries rows forward that it could not re-verify this run.
# Measured the day this was written, on the newest engine file per store:
#     Hy-Vee     26.9% of rows older than 14 days, oldest 24d   (414 rows it cannot re-ask about)
#     Sam's      12.5%                                          (a 60-row orphan slice)
#     Fareway     5.6%
#     Walmart    ZERO rows carried a date AT ALL - 11,092 of them, freshness was the filename
# That is the tolerance-wider-than-period class at row granularity: the writer's cadence keeps the clock
# check green while individual prices drift for weeks, and those prices are on 542 live recipe pages.
#
# TWO CHECKS, and the first is the one that matters:
#   UNDATED  a store's newest engine file must date its rows. Without it nothing downstream CAN measure
#            age, and the store silently opts out of every staleness check forever. HARD.
#   RATCHET  the share of rows older than -MaxDays, per store, must not get WORSE than the recorded
#            baseline. A flat threshold would either fire on every store or none - Hy-Vee sits at 27% for
#            a structural reason (rows with no product_id cannot be re-verified) while Baker's sits at 0.
#            The ratchet lets a known-bad store be known-bad without going quiet about it getting worse.
#
# Deliberately NOT done: failing on the absolute number. Deleting or capping the carried rows would turn
# honest stale prices into silent CELL DROPS, which guards.ps1 documents as strictly worse (twice).
#
# Run:  .\audit-row-age.ps1               exit 0 clean, 1 = hard finding or ratchet regression
#       .\audit-row-age.ps1 -Baseline     re-record the baseline (do this only after a deliberate change)
#       .\audit-row-age.ps1 -SelfTest
param([switch]$SelfTest,[switch]$Baseline,[int]$MaxDays=0,[double]$Tolerance=2.0,[string]$OutDir)
# MaxDays defaults to the capture policy's carry (90) - Brad 2026-08-22: no 14-day window anywhere. The
# self-test passes 14 explicitly because it tests the profiler's arithmetic, not the policy.
if (-not $MaxDays) {
  . (Join-Path $PSScriptRoot 'capture-policy-lib.ps1')
  $MaxDays = [int](Get-PolicyMaxCarryDays)
  if (-not $MaxDays) { throw 'audit-row-age: capture policy carry window unreadable' }
}
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root = if($PSScriptRoot){ $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' }
if(-not $OutDir){ $OutDir = Join-Path $root 'out' }
$baselinePath = Join-Path $OutDir 'row-age-baseline.json'

# MEASURE THE FILE THE ENGINE ACTUALLY PRICED FROM. Three stores do NOT reach the board through
# out\regular\<store>-regular-<date>.json. Sam's in particular: out\regular\sams-regular-*.json is a one-off
# hand promotion from 2026-07-14 that NOTHING refreshes, while the real prices arrive via out\sams\. The
# first draft of this guard globbed out\regular\ alone and duly reported "UNDATED: Sam's Club has 12 of 60
# rows with no as_of" - a hard finding about an orphan file the board never reads, while the 7,000-row file
# it does read went unmeasured. guards.ps1 (see its note at the $altGlob switch) had already been burned by
# exactly this and fixed it the same way; this is the two-copies-of-a-rule class, so the mapping is declared
# here explicitly rather than re-derived by feel.
# COPIED FROM THE AUTHORITY, not re-derived. build-deals-page.ps1's $storeFiles is what the board actually
# prices from, and several stores price from TWO files. A first draft of this guard measured one file per
# store and got it wrong twice over: it read Sam's from out\regular\ (a 60-row hand promotion from
# 2026-07-14 that nothing refreshes) and it never opened ads-*.json at all, which is half of what Hy-Vee,
# Aldi and Family Fare are priced from. Both mistakes make the guard report confidently about the wrong
# rows. If build-deals-page's mapping moves, this must move with it - see the drift check in -SelfTest.
$script:STORE_FILES = @{
  'Hy-Vee'      = @('ads-*.json','regular\hyvee-regular-*.json')
  'Aldi'        = @('ads-*.json','regular\aldi-regular-*.json')
  'Family Fare' = @('ads-*.json','regular\family-fare-regular-*.json')
  "Baker's"     = @('bakers\bakers-deals-*.json','regular\bakers-regular-*.json')
  "Sam's Club"  = @('sams\sams-deals-*.json')
  'Walmart'     = @('regular\walmart-regular-*.json')
  'Fareway'     = @('fareway\fareway-deals-*.json','regular\fareway-regular-*.json')
}

# WEEKLY-AD FILES ARE AGED BY THEIR WINDOW, NOT BY A PER-ROW DATE. out\bakers\bakers-deals-*.json and
# out\fareway\fareway-deals-*.json are ad captures: they carry ad_from/ad_to in the header and their rows
# carry no as_of. The first instinct was to stamp a per-row as_of the way Walmart and Sam's now do - that is
# WRONG here, and audit-asof-evidence.ps1 is a whole guard explaining why: writing a date the row did not
# earn is worse than having none, because every freshness check in the estate then reads a number the
# builder wrote to be true. An ad price's honest expiry is the day its window closes, which is a sharper
# test than "capture + 14 days" and is already on disk.
function Test-AdWindowExpired { param($Header,[datetime]$Today)
  if(-not $Header.ad_to){ return $false }
  try { return ([datetime]$Header.ad_to -lt $Today) } catch { return $false }
}

# A row is WINDOW-DATED when its own ad_to, or its file header's ad_to, says when it expires. That is a real
# date the row earned, just not a per-row capture stamp, and it is the ONLY honest one an ad row can carry
# (see the block above and audit-asof-evidence).
function Test-RowIsWindowDated { param($Row,$Header)
  if($Row -and $Row.PSObject.Properties['ad_to'] -and [string]$Row.ad_to){ return $true }
  if($Header -and $Header.PSObject.Properties['ad_to'] -and [string]$Header.ad_to){ return $true }
  return $false
}

# WINDOW-DATED ROWS ARE NOT UNDATED (2026-08-30, queue 2026-08-30-fec3dc). Ad rows must never carry as_of -
# the block above is a whole essay on why - yet this function counted every one of them as undated, so the
# UNDATED GREW arm was measuring FLYER SIZE against the flyer sizes frozen into the baseline on 2026-08-07
# (Aldi 60, Family Fare 1100, Hy-Vee 641, Baker's 39, Fareway 11). Every week with a bigger flyer read as
# "a writer that was stamping as_of has stopped". It fired on five stores every day from 2026-08-15 to
# 2026-08-30 while all five regular files were 0-undated and no writer had stopped anything: 682/682 Hy-Vee,
# 86/86 Aldi, 1400/1400 Family Fare ad rows, plus Baker's 108 and Fareway 218 whole ad captures. That is
# exactly the guard-people-learn-to-scroll-past failure this file's own comments warn about, and it buries
# the signal the tier exists to catch - a REGULAR-file writer actually stopping.
#
# WHAT DOES NOT CHANGE: `dated` still counts only rows with a per-row as_of, so the zero-dated hard check
# above ("the whole store opts out of every staleness check") still fires for a store whose only source is
# an ad file. A window is an expiry, not a capture stamp, and Test-AdWindowExpired owns it wholesale.
function Get-AgeProfile { param($Rows,[datetime]$Today,[int]$MaxDays,[int]$WindowDated=0)
  $all = @($Rows); $dated = @($all | Where-Object { $_.as_of })
  $ages = @($dated | ForEach-Object { ($Today - [datetime]$_.as_of).Days })
  $over = @($ages | Where-Object { $_ -gt $MaxDays }).Count
  $und = $all.Count - $dated.Count - $WindowDated
  if($und -lt 0){ $und = 0 }
  return [pscustomobject]@{
    rows=$all.Count; dated=$dated.Count; undated=$und; windowDated=$WindowDated
    over=$over; pct=$(if($ages.Count){ [math]::Round(100*$over/$ages.Count,1) } else { 0 })
    oldest=$(if($ages.Count){ ($ages|Measure-Object -Maximum).Maximum } else { 0 }) }
}

if($SelfTest){
  $f=0
  function T($m,$c,$g){ if($c){ Write-Output ("ok    "+$m) } else { Write-Output ("FAIL  "+$m+"   got: "+$g); $script:f++ } }
  $today=[datetime]'2026-08-07'
  # FROZEN FIXTURE: Walmart as it actually shipped - 11k rows, not one date. The whole store opted out of
  # every staleness check and nothing noticed, because the FILE was rewritten daily.
  $walmart = @(1..5 | ForEach-Object { [pscustomobject]@{ item="x$_" } })
  $p = Get-AgeProfile $walmart $today 14
  T 'MUST FIRE  a store whose rows carry no date at all (Walmart, 11,092 rows)' ($p.undated -eq 5 -and $p.dated -eq 0) "undated=$($p.undated)"
  # FROZEN FIXTURE: Hy-Vee's real shape - most rows fresh, a hard core it cannot re-verify aging forever.
  $hyvee = @(@(1..7 | ForEach-Object { [pscustomobject]@{ as_of='2026-08-07' } }) + @(1..3 | ForEach-Object { [pscustomobject]@{ as_of='2026-07-14' } }))
  $p2 = Get-AgeProfile $hyvee $today 14
  T 'MUST FIRE  rows aged past the window are counted, not hidden by a fresh file' ($p2.over -eq 3 -and $p2.pct -eq 30) "over=$($p2.over) pct=$($p2.pct)"
  T 'the oldest row is reported, not averaged away'                               ($p2.oldest -eq 24) "oldest=$($p2.oldest)"
  # CLEAN TWIN: a store refreshed today.
  $bakers = @(1..10 | ForEach-Object { [pscustomobject]@{ as_of='2026-08-07' } })
  $p3 = Get-AgeProfile $bakers $today 14
  T 'CLEAN TWIN a fully refreshed store reports 0% and 0 undated'                 ($p3.pct -eq 0 -and $p3.undated -eq 0) "pct=$($p3.pct)"
  # CLEAN TWIN: inside the window is not stale.
  $edge = @(1..4 | ForEach-Object { [pscustomobject]@{ as_of='2026-07-25' } })
  $p4 = Get-AgeProfile $edge $today 14
  T 'CLEAN TWIN a row exactly inside the window is not counted stale'             ($p4.over -eq 0) "over=$($p4.over)"
  # FROZEN FIXTURE: Fareway's ad file as it stood on 2026-08-07 - window closed 08-01, 11 rows, and the live
  # board still crowned its $1.99 "All-Natural Iowa Pork Chops" as the cheapest pork chops in Omaha six days
  # after the sale ended. These rows carry no as_of and never should: the ad window is the honest expiry.
  T 'MUST FIRE  an ad file whose window has closed (Fareway 2026-07-26..08-01, read on 08-07)' `
    (Test-AdWindowExpired ([pscustomobject]@{ ad_from='2026-07-26'; ad_to='2026-08-01' }) $today) 'expired ad read as current'
  # CLEAN TWIN: Baker's on the same day, still inside its window.
  T 'CLEAN TWIN an ad still inside its window (Baker''s 2026-08-05..08-11)' `
    (-not (Test-AdWindowExpired ([pscustomobject]@{ ad_from='2026-08-05'; ad_to='2026-08-11' }) $today)) 'spurious finding'
  T 'CLEAN TWIN a non-ad file with no window is never called expired'             (-not (Test-AdWindowExpired ([pscustomobject]@{ store='Walmart' }) $today)) 'spurious finding'
  # ---- WINDOW-DATED ROWS (2026-08-30, queue 2026-08-30-fec3dc) --------------------------------------
  # MUST FIRE, unchanged: the founding Walmart shape above still reports 5 undated. Re-asserted here
  # explicitly because it is the case the new WindowDated parameter could most easily break.
  T 'MUST FIRE  an undated NON-ad row is still undated when no window is in play' ((Get-AgeProfile $walmart $today 14 0).undated -eq 5) "undated=$((Get-AgeProfile $walmart $today 14 0).undated)"
  # MUST FIRE: a regular-file store whose undated backlog GREW is still the defect this tier exists for.
  $grew = @(1..9 | ForEach-Object { [pscustomobject]@{ item="r$_" } })
  $pg = Get-AgeProfile $grew $today 14 0
  T 'MUST FIRE  a regular-file store whose undated count grew is still counted (9 > baseline)' ($pg.undated -eq 9) "undated=$($pg.undated)"
  # CLEAN TWIN: bakers-deals-2026-08-26 as it really shipped - 108 rows, not one as_of, window 08-26..09-01
  # in the FILE HEADER. Before this change those 108 rows read as 108 undated and fired UNDATED GREW against
  # a baseline frozen when Baker's flyer had 39 rows.
  $bakersAd = @(1..108 | ForEach-Object { [pscustomobject]@{ item="b$_"; ad_price='$1.99' } })
  $bakersHdr = [pscustomobject]@{ store="Baker's"; ad_from='2026-08-26'; ad_to='2026-09-01' }
  $winCount = @($bakersAd | Where-Object { -not $_.as_of -and (Test-RowIsWindowDated $_ $bakersHdr) }).Count
  $pb = Get-AgeProfile $bakersAd $today 14 $winCount
  T 'CLEAN TWIN a header-windowed ad capture (Baker''s 108 rows) reports 0 undated' ($pb.undated -eq 0 -and $pb.windowDated -eq 108) "undated=$($pb.undated) windowDated=$($pb.windowDated)"
  # CLEAN TWIN: ads-2026-08-30 as it really shipped - NO header window, ad_from/ad_to on every ROW. This is
  # the shape behind the Hy-Vee 682 / Aldi 86 / Family Fare 1400 counts in the alert.
  $ffAd = @(1..1400 | ForEach-Object { [pscustomobject]@{ item="f$_"; store='Family Fare'; ad_from='2026-08-03'; ad_to='2026-08-30' } })
  $ffHdr = [pscustomobject]@{ pulled_at='2026-08-30'; deal_count=2168 }
  $winFF = @($ffAd | Where-Object { -not $_.as_of -and (Test-RowIsWindowDated $_ $ffHdr) }).Count
  $pf = Get-AgeProfile $ffAd $today 14 $winFF
  T 'CLEAN TWIN a row-windowed ads file (Family Fare 1400 rows) reports 0 undated' ($pf.undated -eq 0 -and $pf.windowDated -eq 1400) "undated=$($pf.undated) windowDated=$($pf.windowDated)"
  # CLEAN TWIN: a BIGGER flyer than the baseline is not a stopped writer. 1400 window-dated rows against a
  # baseline of 1100 must produce no growth in the undated count at all - that comparison is what fired
  # every day from 2026-08-15.
  T 'CLEAN TWIN a flyer bigger than the baseline does not read as a stopped writer' ($pf.undated -le 1100) "undated=$($pf.undated)"
  # MUST FIRE: a window-dated row does NOT count as dated, so a store whose only source is an ad file still
  # trips the zero-dated hard check. If this ever passes, the fix has laundered a window into a capture stamp.
  T 'MUST FIRE  window-dated rows do not satisfy per-row dating (dated stays 0)' ($pb.dated -eq 0) "dated=$($pb.dated)"
  # A HALF-STAMPED row keeps its own date: as_of wins over the window, so a real capture stamp is never
  # reclassified away.
  $mixed = @([pscustomobject]@{ as_of='2026-08-07'; ad_to='2026-09-01' })
  $winMix = @($mixed | Where-Object { -not $_.as_of -and (Test-RowIsWindowDated $_ $null) }).Count
  $pm = Get-AgeProfile $mixed $today 14 $winMix
  T 'CLEAN TWIN a row carrying BOTH as_of and a window is counted dated, not window-dated' ($pm.dated -eq 1 -and $pm.windowDated -eq 0) "dated=$($pm.dated) windowDated=$($pm.windowDated)"
  # DRIFT CHECK, not a frozen copy. $STORE_FILES is duplicated from build-deals-page.ps1's $storeFiles, and a
  # duplicated rule that nothing compares is the two-copies-of-a-rule class: the board starts pricing from a
  # file this guard never opens, and the guard keeps reporting confidently about the wrong rows. That is not
  # hypothetical - the first draft of this guard read Sam's from out\regular\ (a 60-row hand promotion from
  # 2026-07-14 that nothing refreshes) and never opened ads-*.json at all. So parse the AUTHORITY and compare.
  $bdp = Join-Path $root 'build-deals-page.ps1'
  if(Test-Path $bdp){
    $txt = [IO.File]::ReadAllText($bdp)
    $blk = [regex]::Match($txt, '\$storeFiles\s*=\s*@\{(.+?)\n\s*\}', 'Singleline')
    $theirs = @{}
    if($blk.Success){
      foreach($ln in ($blk.Groups[1].Value -split "`n")){
        # three key forms, and the double-quoted one MATTERS: "Baker's" and "Sam's Club" carry an apostrophe
        # inside double quotes, so a single character-class pattern silently parsed 5 of the 7 stores and the
        # drift check then reported the two it could not read as "missing from the board's mapping".
        $mm = [regex]::Match($ln, "^\s*(?:'([^']+)'|`"([^`"]+)`"|(\w+))\s*=\s*@\((.+)\)\s*$")
        if($mm.Success){
          $key = @($mm.Groups[1].Value, $mm.Groups[2].Value, $mm.Groups[3].Value | Where-Object { $_ })[0]
          $globs = @([regex]::Matches($mm.Groups[4].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
          $theirs[$key.Trim()] = ($globs -join '|')
        }
      }
    }
    $mine = @{}; foreach($k in $script:STORE_FILES.Keys){ $mine[$k] = ($script:STORE_FILES[$k] -join '|') }
    $drift = @()
    foreach($k in $theirs.Keys){ if($mine[$k] -ne $theirs[$k]){ $drift += ("{0}: board='{1}' guard='{2}'" -f $k,$theirs[$k],$mine[$k]) } }
    foreach($k in $mine.Keys){ if(-not $theirs.ContainsKey($k)){ $drift += ("{0}: not in the board's mapping at all" -f $k) } }
    T 'MUST FIRE  the store->source-file mapping still matches build-deals-page.ps1 (the board decides, not this guard)' `
      ($theirs.Count -ge 7 -and $drift.Count -eq 0) (($drift + ("parsed " + $theirs.Count + " store(s) from the authority")) -join ' ; ')
  } else {
    T 'the authority build-deals-page.ps1 is readable for the drift check' $false 'not found'
  }
  if($f -eq 0){ Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $f case(s)"; exit 1 }
}

$today = (Get-Date).Date
$profiles = @{}
$sources  = @{}
$expired  = @()
foreach($store in ($script:STORE_FILES.Keys | Sort-Object)){
  $rows = New-Object System.Collections.Generic.List[object]
  $used = @()
  $winDated = 0
  foreach($g in $script:STORE_FILES[$store]){
    # newest DATED file matching this glob - an undated filename is a scratch one-off, never a board source
    $fl = @(Get-ChildItem (Join-Path $OutDir $g) -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -match '\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1)
    if(-not $fl.Count){ continue }
    $j = Get-Content $fl[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    # ads-*.json carries EVERY store's ad rows, so filter to this store; the per-store files carry only their
    # own and their rows may omit a store field entirely.
    # TWO SHAPES OF AD FILE, and the fix must cover both or it covers none of the alert: ads-*.json carries
    # no header window at all but stamps ad_from/ad_to on EVERY row (2,168 of 2,168 on 2026-08-30, which is
    # where the Hy-Vee 682 / Aldi 86 / Family Fare 1400 counts come from), while bakers-deals and
    # fareway-deals carry the window in the HEADER and nothing on the row.
    foreach($r in @($j.deals)){
      $rs = [string]$r.store
      if($rs -and $rs -ne $store){ continue }
      if(-not $rs -and [string]$j.store -and [string]$j.store -ne $store){ continue }
      $rows.Add($r)
      if(-not $r.as_of -and (Test-RowIsWindowDated $r $j)){ $winDated++ }
    }
    # an ad file past its window is stale WHOLESALE - every row in it, regardless of as_of
    if(Test-AdWindowExpired $j $today){
      $expired += [pscustomobject]@{ store=$store; file=$fl[0].Name; to=[string]$j.ad_to; rows=@($j.deals).Count
                                     days=[int]($today - [datetime]$j.ad_to).TotalDays }
    }
    $used += $fl[0].Name
  }
  if(-not $rows.Count){ continue }
  # .ToArray(), not the List itself: @() does not unroll a generic List in PS 5.1, so Get-AgeProfile's own
  # @($Rows) threw "Argument types do not match" on the first live run. Documented estate trap.
  $profiles[$store] = Get-AgeProfile $rows.ToArray() $today $MaxDays $winDated
  $sources[$store]  = ($used -join ' + ')
}

if($Baseline){
  # record BOTH dimensions: the age distribution and the size of the undated backlog. Recording only the pct
  # let an undated backlog grow invisibly, since undated rows are excluded from the pct denominator entirely.
  $out = [ordered]@{}
  foreach($s in ($profiles.Keys | Sort-Object)){ $out[$s] = [ordered]@{ pct = $profiles[$s].pct; undated = $profiles[$s].undated } }
  ($out | ConvertTo-Json -Depth 4) | Out-File $baselinePath -Encoding utf8
  Write-Output ("row-age baseline recorded for {0} store(s) -> {1}" -f $profiles.Count, $baselinePath)
  foreach($s in ($profiles.Keys | Sort-Object)){ Write-Output ("  {0,-14} {1}% over {2}d, {3} undated" -f $s, $profiles[$s].pct, $MaxDays, $profiles[$s].undated) }
  exit 0
}

$base = $null
if(Test-Path $baselinePath){ $base = Get-Content $baselinePath -Raw -Encoding UTF8 | ConvertFrom-Json }
$hard = New-Object System.Collections.Generic.List[string]
$info = New-Object System.Collections.Generic.List[string]
foreach($s in ($profiles.Keys | Sort-Object)){
  $p = $profiles[$s]
  # UNDATED is tiered, because a flat "any undated row is a hard finding" fires on five stores every single
  # day for a backlog nobody is working that night, and a guard that always fires is one people learn to
  # scroll past. The two cases that are NOT routine:
  #   * a store with ZERO dated rows has opted out of staleness checking entirely - never acceptable, and it
  #     is how Walmart's 11,092 rows and Sam's 1,808 hid in the first place;
  #   * an undated count that GREW means a writer stopped stamping, which is the defect arriving, not sitting.
  # Everything else is printed in the table above every run, so the backlog stays visible without paging.
  $baseUndated = $null
  if($base -and $base.PSObject.Properties[$s] -and $base.$s.PSObject.Properties['undated']){ $baseUndated = [int]$base.$s.undated }
  if($p.rows -gt 0 -and $p.dated -eq 0){
    $hard.Add(("UNDATED: {0} dates NONE of its {1} rows - the whole store opts out of every staleness check silently" -f $s,$p.rows))
  }
  elseif($p.undated -gt 0 -and $null -ne $baseUndated -and $p.undated -gt $baseUndated){
    $hard.Add(("UNDATED GREW: {0} now has {1} undated rows, up from {2} - a writer that was stamping as_of has stopped" -f $s,$p.undated,$baseUndated))
  }
  if($base -and $base.PSObject.Properties[$s] -and $base.$s.PSObject.Properties['pct']){
    $was = [double]$base.$s.pct
    if($p.pct -gt $was + $Tolerance){
      $hard.Add(("RATCHET: {0} is {1}% older than {2}d, worse than the {3}% baseline (oldest {4}d) - prices are aging faster than the puller refreshes them" -f $s,$p.pct,$MaxDays,$was,$p.oldest))
    }
  }
  # A store with ZERO dated rows must not print "0 (0%) oldest 0d" - that is the best-looking line in the
  # table, printed for the store that cannot be checked at all.
  $undTxt = if($p.undated -gt 0){ ("  undated {0}" -f $p.undated) } else { '' }
  if($p.dated -eq 0){
    $info.Add(("  {0,-14} rows {1,6}  over {2}d:   n/a         oldest n/a   (no row carries a date){3}" -f $s,$p.rows,$MaxDays,$undTxt))
  } else {
    $info.Add(("  {0,-14} rows {1,6}  over {2}d: {3,5} ({4}%)  oldest {5}d{6}" -f $s,$p.rows,$MaxDays,$p.over,$p.pct,$p.oldest,$undTxt))
  }
}
foreach($x in $expired){
  # Wording matters here. compare-deals.ps1 now REFUSES to price from an expired ad, so this is no longer
  # "the board is publishing a dead sale" - that hole is closed. What it means now is that the store's ad
  # coverage is GONE until a pull lands: its {rows} sale rows are excluded, those cells fall back to
  # everyday prices or to other stores, and the store looks less competitive than it is. Overstating the
  # risk would be its own defect, because a guard that cries louder than the facts is one people stop reading.
  $hard.Add(("AD COVERAGE GONE: {0}'s newest ad file {1} closed {2} ({3} day(s) ago), so its {4} sale row(s) are now excluded from the board (compare-deals refuses expired ads). Its ad cells fall back to everyday prices until a fresh pull lands." -f $x.store,$x.file,$x.to,$x.days,$x.rows))
}
Write-Output ("row-age: {0} hard finding(s) across {1} store(s)" -f $hard.Count, $profiles.Count)
$info | ForEach-Object { Write-Output $_ }
$hard | ForEach-Object { Write-Output ("  ! " + $_) }
if(-not $base){ Write-Output '  (no baseline recorded yet - run -Baseline once to arm the ratchet)' }
Write-GuardComplete -Name 'row-age' -Summary ("stores={0} hard={1}" -f $profiles.Count, $hard.Count)
exit $(if($hard.Count){ 1 } else { 0 })
