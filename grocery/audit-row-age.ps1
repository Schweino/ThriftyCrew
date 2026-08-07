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
param([switch]$SelfTest,[switch]$Baseline,[int]$MaxDays=14,[double]$Tolerance=2.0,[string]$OutDir)
$ErrorActionPreference='Stop'
$root = if($PSScriptRoot){ $PSScriptRoot } else { 'C:\Codex\income\grocery' }
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

function Get-AgeProfile { param($Rows,[datetime]$Today,[int]$MaxDays)
  $all = @($Rows); $dated = @($all | Where-Object { $_.as_of })
  $ages = @($dated | ForEach-Object { ($Today - [datetime]$_.as_of).Days })
  $over = @($ages | Where-Object { $_ -gt $MaxDays }).Count
  return [pscustomobject]@{
    rows=$all.Count; dated=$dated.Count; undated=($all.Count-$dated.Count)
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
foreach($store in ($script:STORE_FILES.Keys | Sort-Object)){
  $rows = New-Object System.Collections.Generic.List[object]
  $used = @()
  foreach($g in $script:STORE_FILES[$store]){
    # newest DATED file matching this glob - an undated filename is a scratch one-off, never a board source
    $fl = @(Get-ChildItem (Join-Path $OutDir $g) -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -match '\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1)
    if(-not $fl.Count){ continue }
    $j = Get-Content $fl[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    # ads-*.json carries EVERY store's ad rows, so filter to this store; the per-store files carry only their
    # own and their rows may omit a store field entirely.
    foreach($r in @($j.deals)){
      $rs = [string]$r.store
      if($rs -and $rs -ne $store){ continue }
      if(-not $rs -and [string]$j.store -and [string]$j.store -ne $store){ continue }
      $rows.Add($r)
    }
    $used += $fl[0].Name
  }
  if(-not $rows.Count){ continue }
  # .ToArray(), not the List itself: @() does not unroll a generic List in PS 5.1, so Get-AgeProfile's own
  # @($Rows) threw "Argument types do not match" on the first live run. Documented estate trap.
  $profiles[$store] = Get-AgeProfile $rows.ToArray() $today $MaxDays
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
Write-Output ("row-age: {0} hard finding(s) across {1} store(s)" -f $hard.Count, $profiles.Count)
$info | ForEach-Object { Write-Output $_ }
$hard | ForEach-Object { Write-Output ("  ! " + $_) }
if(-not $base){ Write-Output '  (no baseline recorded yet - run -Baseline once to arm the ratchet)' }
exit $(if($hard.Count){ 1 } else { 0 })
