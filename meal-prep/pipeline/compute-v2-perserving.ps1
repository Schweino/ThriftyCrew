# compute-v2-perserving.ps1 - the single source of truth for the redesign's per-serving numbers.
# For every r100+r300 recipe, computes (whole-package model, matching the card widget exactly):
#   everyday_ps  = sum(ceil(grams/pkg_g -0.02) * pkg_p) / 14           (== cost_first_run/14, the "at everyday cost" stat)
#   cheapest_ps  = sum(k * (pkg_g/gpu) * feed.cheapest, else k*pkg_p) / 14   (the headline "cheapest everywhere" number)
# Emits pipeline/v2-perserving.json (manifest: slug,name,protein,protein_g,old_ps,everyday_ps,cheapest_ps,
# protein_rank,is_protein_rank1) - the input for BOTH the prose writer wave and the site-surface switch.
# -FeedPath DEFAULTS TO EMPTY ON PURPOSE (2026-08-15). It used to default to meal-prep\scratch-smpfeed.json
# and download to it only when that file was MISSING, so once the file existed it was never refreshed again
# and the whole catalog was priced on a 2026-07-27 snapshot for nineteen days. Empty now means "resolve it",
# and pipeline\feed-freshness.ps1 owns that rule: canonical feed on disk first, cache only inside a window
# narrower than the daily export period. Callers with a feed of their own still pass -FeedPath.
# -NoAlert exists so the REFUSAL PATH ITSELF is reachable by a test without mailing Brad and filing a
# triage-queue entry. A safety branch nothing can exercise is a branch nothing has proved; test-auditors
# runs the real script this way daily. No production caller passes it.
# -CrossCheck re-derives every recipe's cheapest total straight from the BUILT CARD's own data block and
# demands it match this manifest. That is what keeps the PowerShell mirror of the pricing rule honest
# against the JS that actually prices the page - run it after any change to either side. Not daily: it
# reads 544 built cards.
param([string]$FeedPath = '', [switch]$SelfTest, [switch]$NoAlert, [switch]$CrossCheck)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp = Split-Path -Parent $here
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
# ONE PowerShell copy of the card's pricing rule AND of the scaler-gpu basis rule. Dot-sourced up here
# rather than beside its first pricing use, because -SelfTest returns long before that point and a
# fixture that cannot reach the function it pins is the 2026-07-29 class this file already carries a
# scar from (the covered_by skip below).
. (Join-Path $mp 'lib\package-cost-lib.ps1')

# BLOCK-BEFORE-SHIP (2026-07-27, overhaul-1): a 'cheapest' HIGHER than 'everyday' is nonsensical on every
# manifest surface (rankings, top5, meal-planner), so we CLAMP the shipped cheapest to everyday - the valid
# bound: never inverted, never overstated. Both numbers are real shopping plans, so min() of them is
# achievable. The clamp is the block; the flag is the alert. Pure function (no globals) so it is
# self-testable without the feed/db.
#
# THE ALERT'S PREMISE CHANGED ON 2026-08-15 AND THE THRESHOLD MOVED WITH IT. The original reasoning was
# that cheapest "is by construction the floor over the same aligned product the db everyday bid prices",
# so ANY inversion beyond rounding meant a wrong price - true while cheapest_ps was min-per-unit times the
# RECIPE's package size, i.e. the same package basis on both sides. cheapest_ps is now whole-package cost
# at the STORE's package size (aligned to what the cards charge), while everyday_ps is still the recipe's
# own authored package basis - it feeds stat.cost_ps and therefore every {{cost_ps}} token in the prose,
# so it deliberately did NOT move. Two different package bases means an inversion is now an ordinary
# PACKAGING artifact: the smallest package a store actually sells can be bigger and dearer than the
# package the recipe assumed. 50 of 544 recipes invert that way on the first run, none by more than 41%.
# Alerting on those would file 50 false "root price bug" tickets and train everyone to ignore the alert.
# So the flag threshold is now 0.50: still catches an inversion too large to be explained by packaging
# (the wrong-price/gpu case it was written for), and stays quiet about the expected ones. The exact check
# that this manifest agrees with the cards is -CrossCheck, which is exhaustive rather than heuristic.
function Resolve-Inversions($rows, $tol, $alertFrac){
  $flagged = New-Object System.Collections.Generic.List[object]
  foreach($r in $rows){
    $ev = [double]$r.everyday_ps; $ch = [double]$r.cheapest_ps
    if($ch -gt $ev + $tol){
      $frac = ($ch - $ev) / [math]::Max(0.01,$ev)
      if($frac -gt $alertFrac){ $flagged.Add([pscustomobject]@{ slug=$r.slug; everyday_ps=$ev; raw_cheapest_ps=$ch; over_frac=[math]::Round($frac,3) }) }
    }
    if($ch -gt $ev){ $r.cheapest_ps = $r.everyday_ps }   # clamp EVERY inversion so cheapest<=everyday holds exactly
  }
  return ,$flagged
}

# ONE COPY OF THE PACKAGE DECISION, lifted out of the pricing loop 2026-09-01 (queue b5b8e0) so the
# self-test below exercises THE SAME BYTES the manifest runs. It was inline, ~90 lines past the point
# where -SelfTest returns, so the covered_by skip that shipped at 08:20 (2190d28b) had no test that could
# reach it - the fix-needs-a-reachable-self-test class that regressed two same-day fixes on 2026-07-29.
# Re-implementing the predicate inside the test instead would have been the other trap: two copies of a
# rule drift, and this one decides whether a line adds package cost.
#
# Returns $null for a line that contributes NO package, or the {n, cost, pkg_g} it contributes.
# A COVERED LINE HAS NO PACKAGE BY DESIGN - its unit is bought under another ingredient, so it adds
# NOTHING to a per-serving package total. Both tiers already count the coverer's own purchase; charging
# this line again would double it, which is the very over-buy covered_by exists to remove. compute-v2 was
# the fifth consumer of a costed line to assume every line has a package.
# pkg_gross_g rides along from 2026-09-02 (corn04): it is the PHYSICAL package the reader buys, which
# on a drained line is not pkg_g, and cheapest_ps needs it to put its `required` on the same basis the
# everyday lane below already uses. A row written before the field carries none, and pkg_g is then the
# gross weight by definition, so the fallback is exact rather than a guess.
function Resolve-LinePackage($cl, [string]$key){
  $n = if($cl.buy_n){ [int]$cl.buy_n } else { [int]$cl.starter_n }
  $c = if($cl.buy_cost){ [double]$cl.buy_cost } else { [double]$cl.starter_cost }
  $pkgG = if($cl.pkg_g){ [double]$cl.pkg_g } else { [double]$cl.starter_pkg_g }
  if(($cl.PSObject.Properties.Name -contains 'covered_by') -and $cl.covered_by){ return $null }
  if($n -lt 1 -or $c -le 0 -or $pkgG -le 0){ throw "bad pkg data on '$key'" }
  $gross = if(($cl.PSObject.Properties.Name -contains 'pkg_gross_g') -and $cl.pkg_gross_g){ [double]$cl.pkg_gross_g } else { [double]$pkgG }
  return [pscustomobject]@{ n = $n; cost = $c; pkg_g = $pkgG; pkg_gross_g = $gross }
}
# THE CROSS-CHECK'S SECOND QUESTION (2026-09-02, corn04). -CrossCheck compared TOTALS and could never
# see this class: it read the built block and inherited whatever basis the block carried, so a card
# whose widget bought three cans where its own cost line said four agreed with itself perfectly.
#
# READ THIS BEFORE "TIGHTENING" IT. The obvious extension - compare the block's own count at the
# block's own authored package, ceil((grams/gpu)/(pkg_g/gpu) - 0.02), against the engine's Buy N - is
# a TAUTOLOGY IN gpu: the gpu cancels, so the expression is ceil(grams/pkg_g - 0.02) whatever basis
# gpu is on, and it returned 4 for street corn's block both before and after the fix. It was written
# that way first and the self-test below caught it; the fixture keeps that fact on the record so
# nobody re-derives the same dead check. What it IS worth against a card on disk is staleness: the
# card that shipped can carry a pkg_g the costed row has since moved off.
function Get-BlockPkgCount([double]$Grams, [double]$Gpu, [double]$PkgG){
  if($Gpu -le 0 -or $PkgG -le 0){ return 0 }
  $required = $Grams / $Gpu
  $basis    = $PkgG / $Gpu
  return [int][math]::Max(1, [math]::Ceiling($required / $basis - 0.02))
}
if($SelfTest){
  $t = @(
    [pscustomobject]@{slug='inv-real'; everyday_ps=3.00; cheapest_ps=3.30},   # 10% inverted -> flag + clamp
    [pscustomobject]@{slug='inv-round';everyday_ps=3.00; cheapest_ps=3.01},   # rounding only -> clamp, no flag
    [pscustomobject]@{slug='ok';       everyday_ps=3.00; cheapest_ps=2.50}    # valid -> untouched
  )
  $fl = Resolve-Inversions $t 0.02 0.03
  $pass = ($t[0].cheapest_ps -eq 3.00) -and ($t[1].cheapest_ps -eq 3.00) -and ($t[2].cheapest_ps -eq 2.50) -and ($fl.Count -eq 1) -and ($fl[0].slug -eq 'inv-real')
  if(-not $pass){ Write-Output ("SELFTEST FAIL: clamped=[{0},{1},{2}] flagged={3}" -f $t[0].cheapest_ps,$t[1].cheapest_ps,$t[2].cheapest_ps,$fl.Count); exit 1 }
  Write-Output 'SELFTEST PASS: cheapest<=everyday clamp + real-inversion flag correct'

  # COVERED_BY REACHABILITY (2026-09-01, queue 2026-09-01-b5b8e0). FROZEN from the real line that killed
  # the 08:00 manifest: db\costed.json, slug no-boil-chicken-pasta-casserole-with-artichokes-and-peas,
  # item 'Lemon Zest', covered_by 'Fresh Lemon Juice', with buy_n / buy_cost / pkg_g all null BY DESIGN
  # since d1e5cd89 (07:48) - a lemon yields juice AND zest, so the zest is bought under the juice.
  # compute-v2 ran at 08:06 with the pre-07:48 code and threw at its pkg check.
  # NEVER regenerate these two objects from live data: costed.json holds exactly ONE covered_by line
  # today, so a regenerated fixture would go empty the moment that recipe changes, and this case would
  # pass by testing nothing.
  $coveredLine = [pscustomobject]@{ item = 'Lemon Zest'; covered_by = 'Fresh Lemon Juice'
                                    buy_n = $null; buy_cost = $null; pkg_g = $null
                                    starter_n = $null; starter_cost = $null; starter_pkg_g = $null }
  # CLEAN TWIN: byte-identical except that it is NOT covered. The same null package data must STILL
  # throw, or the skip has been widened into a blanket "ignore bad package data" and the guard is gone.
  $bareLine    = [pscustomobject]@{ item = 'Lemon Zest'
                                    buy_n = $null; buy_cost = $null; pkg_g = $null
                                    starter_n = $null; starter_cost = $null; starter_pkg_g = $null }
  $covRes = 'unset'; $covThrew = $false
  try { $covRes = Resolve-LinePackage $coveredLine 'Lemon Zest' } catch { $covThrew = $true }
  $bareThrew = $false
  try { [void](Resolve-LinePackage $bareLine 'Lemon Zest') } catch { $bareThrew = $true }
  $mustFire  = ((-not $covThrew) -and ($null -eq $covRes))   # covered: no throw, and contributes NO package
  $cleanTwin = $bareThrew                                     # not covered: the bad-pkg error must survive
  if(-not ($mustFire -and $cleanTwin)){
    Write-Output ("SELFTEST FAIL: covered_by path - covered threw={0} covered_result={1} bare_threw={2} (want threw=False result=null bare_threw=True)" -f $covThrew, $covRes, $bareThrew)
    exit 1
  }
  Write-Output 'SELFTEST PASS: a covered_by line with null package fields is skipped and adds zero package cost, and the same nulls WITHOUT covered_by still throw'

  # WIDGET-COUNT BASIS (2026-09-02, queue 2026-09-02-corn04). FROZEN from the block
  # street-corn-chicken-rice-bowls shipped: grams 1148 and pkg_g 298 on the DRAINED basis, gpu 28.35
  # on the GROSS one, against a costed row whose physical can is 432 g and whose Buy N is 4.
  # Frozen inline: once the emit is fixed no live row carries these numbers any more, and a fixture
  # rebuilt from db\built would pass by finding nothing.

  # (1) THE DEAD CHECK, pinned as dead. The count at the block's own authored package is blind to gpu
  #     because gpu cancels - 4 before the fix and 4 after. Anyone who re-adds it as the count guard
  #     is re-adding a check that reported clean through 88 short lines on 76 live cards.
  $kShipped = Get-BlockPkgCount 1148 28.35   298
  $kFixed   = Get-BlockPkgCount 1148 19.5563 298
  $tautOk = ($kShipped -eq 4 -and $kFixed -eq 4)

  # (2) THE CHECK THAT ACTUALLY FIRES. The block's authored FALLBACK package does not cancel, and it
  #     is a fact about the world: a 15.25 oz can. The shipped block's works out at 10.51 oz.
  $mmShipped = Get-ScalerBasisMismatch 298 28.35   432 28.35
  $mmFixed   = Get-ScalerBasisMismatch 298 19.5563 432 28.35
  $basisOk = ($null -ne $mmShipped) -and ($null -eq $mmFixed)

  # (3) STALENESS, which is what the count comparison IS good for against a card on disk: a block
  #     built when the package was 255 g still says 5 where the engine now says 4.
  $kStale = Get-BlockPkgCount 1148 19.5563 255
  # (4) CLEAN TWINS: a non-drained line, and the zero guards that must not divide.
  $kPlain = Get-BlockPkgCount 454 28.3495 454
  $kZero  = Get-BlockPkgCount 1148 0 298
  $staleOk = ($kStale -eq 5) -and ($kPlain -eq 1) -and ($kZero -eq 0)

  if(-not ($tautOk -and $basisOk -and $staleOk)){
    Write-Output ("SELFTEST FAIL: widget-count basis - block count shipped={0}/fixed={1} (both want 4), basis shipped={2}/fixed={3} (want fired/null), stale={4} (want 5), non-drained={5} (want 1), gpu 0={6} (want 0)" -f `
      $kShipped,$kFixed,$(if($mmShipped){'fired'}else{'null'}),$(if($mmFixed){'fired'}else{'null'}),$kStale,$kPlain,$kZero)
    exit 1
  }
  Write-Output ("SELFTEST PASS: the block-count comparison is gpu-blind by construction (4 both ways) and catches a stale package; the FALLBACK-PACKAGE check is the one that fires on street corn's shipped block ({0:N2} units against a {1:N2} unit can)" -f $mmShipped.fallback, $mmShipped.physical)
  exit 0
}

# ---- THE FEED THIS RUN IS ALLOWED TO PRICE ON (2026-08-15) -----------------------------------------
# Was: `if(-not (Test-Path $FeedPath)){ download }` - which downloaded the feed exactly once, ever, and
# then priced every recipe in the catalog against that first snapshot forever. Measured when it was found:
# the snapshot was 19 days old, 264 of 564 shared prices had moved (mean 27%), and 534 of 544 recipes'
# cheapest_ps was wrong on the manifest sitting on disk. Deleting the snapshot was NOT the fix - that makes
# the next run correct and every later run silently wrong again, the same bug with a longer fuse.
# The rule and the guard both live in feed-freshness.ps1; this is its production caller, and the verdict
# line prints on EVERY run so a silent one is itself the failure.
. (Join-Path $here 'feed-freshness.ps1')
$feedInfo = Resolve-AndCheckFeed -Explicit $FeedPath
Write-Output ("feed: {0}`n      source: {1}`n      freshness: {2} - {3}" -f $feedInfo.path, $feedInfo.source_why, $feedInfo.verdict, $feedInfo.reason)
if(Test-FeedVerdictFatal $feedInfo.verdict){
  # REFUSE, and leave the existing manifest alone. Writing a stale manifest is the harm: every surface
  # (cards, hub grid, meal planner, top5, the free-dinner rotation, the daily reel) reads cheapest_ps out
  # of it, and the last writer wins - which is exactly how a wave publish overwrote a correct morning
  # manifest with July prices. A refused run keeps yesterday's numbers; it does not manufacture new ones.
  Write-Output ("REFUSING TO WRITE THE MANIFEST: {0}" -f $feedInfo.reason)
  $alertLib = Join-Path $mp '..\grocery\alert-lib.ps1'
  if((-not $NoAlert) -and (Test-Path $alertLib)){
    . $alertLib
    Send-Alert -Subject 'Recipe per-serving manifest: REFUSED, stale price feed' -Body ("compute-v2-perserving.ps1 refused to recompute pipeline\v2-perserving.json because the feed it resolved is not current.`n`nfeed: $($feedInfo.path)`nsource: $($feedInfo.source_why)`nverdict: $($feedInfo.verdict)`nage: $($feedInfo.age_hours)h`n`n$($feedInfo.reason)`n`nThe manifest was NOT overwritten, so the surfaces keep their previous numbers rather than gaining wrong ones. Fix the feed (check the daily pipeline / grocery\out\smp-feed.json) and re-run.") -What 'v2 stale feed' | Out-Null
  }
  exit 2
}
$feedDoc = Get-Content $feedInfo.path -Raw -Encoding utf8 | ConvertFrom-Json
$feed = $feedDoc.ingredients
$feedMap = @{}; foreach($p in $feed.PSObject.Properties){ $feedMap[$p.Name] = $p.Value }
# THE CARD'S OWN PRICING INPUTS (2026-08-15). cheapest_ps used to be k * (pkg_g/gpu) * feed.cheapest -
# the minimum PER-UNIT price times the RECIPE's package size. That is the same defect the cards carried:
# the cheapest store per unit is not the cheapest store to BUY at, because you buy whole packages and a
# warehouse pack wins per-unit with a huge one. Now it computes what the card computes: scan every store
# cell and keep the minimum COST, on the STORE's package size where the board knows one.
# NOTE the two are only the same question when the package size is fixed - keeping the recipe's own
# package size and merely picking the min-cost store is algebraically identical to min per-unit, so
# "align the selection" without "align the basis" is a no-op. This changes the basis.
$piMap = @{}
if($feedDoc.PSObject.Properties['pricing_inputs']){ foreach($p in $feedDoc.pricing_inputs.PSObject.Properties){ $piMap[$p.Name] = $p.Value } }
# ONE PowerShell copy of the rule, shared with grocery\measure-cheapest-selection.ps1. Do not transcribe
# costAt() again here: the JS in tpl2-scaler-prefix.html is the authority, this lib is its single server
# -side mirror, and -CrossCheck below proves the two agree against the built cards.
# (Dot-sourced at the top of this file since 2026-09-02 so -SelfTest can reach it.)
function Get-CheapestCost($bid,[double]$req,[double]$fallbackBasis){
  if(-not $bid -or -not $piMap.ContainsKey($bid)){ return $null }
  $r = Get-PkgCheapestAcross $piMap[$bid] $req $fallbackBasis
  if($null -eq $r){ return $null }
  return [double]$r.cost
}

function Slugify([string]$s){ (($s.ToLower() -replace "[^a-z0-9]+","-").Trim('-')) }

# 2026-07-26 engine consolidation: reads the canonical stores (db\recipes + db\costed) - run-agnostic,
# any catalog size. db\costed.json is produced by engine\cost-recipes.ps1.
$dbCosted = @{}
foreach($c in (Get-Content (Join-Path $mp 'db\costed.json') -Raw | ConvertFrom-Json)){ $dbCosted[[string]$c.slug]=$c }
# COLLECT-AND-REPORT (2026-07-26 scale hardening): a single malformed spec/costed line used to `throw`
# and kill the WHOLE manifest (all 513, soon 1500), which then went stale while top5/rotation/surfaces
# silently served yesterday's numbers. Now a bad recipe is skipped and named; the manifest is still
# written for every good recipe, and the run exits 1 with the list so check-ad-cycles alerts.
$rows = @()
$bad = @()
# WHAT THE BUILT BLOCK'S OWN COUNT MUST COME OUT AS, recorded per slug in scaler order while the spec
# and its costed row are both already open (2026-09-02, corn04). -CrossCheck reads the built cards long
# after this loop and has only a slug to go on; joining costed lines back to block lines by NAME there
# would be wrong on every canon'd line, so the join is made HERE, where build-card2's own key rule
# (canon ?? item) is available, and carried by INDEX - which is exactly how build-card2 emits them.
$blockExpect = @{}
foreach($run in @('db')){
  foreach($sf in (Get-ChildItem (Join-Path $mp "db\recipes\*.json"))){
    try {
      $spec = Get-Content $sf.FullName -Raw | ConvertFrom-Json
      $cr = $dbCosted[[string]$spec.slug]
      if(-not $cr){ throw "no db\costed entry" }
      $clines = @{}; foreach($l in $cr.lines){ $clines[$l.item] = $l }
      $ev = 0.0; $ch = 0.0
      $expLines = New-Object System.Collections.Generic.List[object]
      foreach($ing in $spec.scaler.ing){
        $key = if($ing.PSObject.Properties.Name -contains 'canon' -and $ing.canon){ $ing.canon } else { $ing.item }
        $cl = $clines[$key]; if(-not $cl){ throw "no costed line '$key'" }
        # The covered_by skip and the bad-package throw both live in Resolve-LinePackage near the top of
        # this file, so -SelfTest exercises THIS decision rather than a second copy of it.
        $pk = Resolve-LinePackage $cl $key
        # RECORDED BEFORE THE SKIP, so the list stays index-aligned with the block. A covered line has
        # no package and therefore no count to compare; it is carried as a null and skipped downstream,
        # never dropped, because dropping it would slide every later line onto the wrong row.
        [void]$expLines.Add([pscustomobject]@{ item = [string]$ing.item; key = [string]$key
                                              n = $(if($null -eq $pk){ $null } else { [int]$pk.n })
                                              pkg_gross_g = $(if($null -eq $pk){ 0.0 } else { [double]$pk.pkg_gross_g })
                                              spec_gpu = $(if($ing.PSObject.Properties.Name -contains 'gpu' -and $ing.gpu){ [double]$ing.gpu } else { 0.0 }) })
        if($null -eq $pk){ continue }
        $n = $pk.n; $c = $pk.cost; $pkgG = $pk.pkg_g
        $pkgP = $c / $n
        $k = [math]::Max(1,[math]::Ceiling([double]$ing.grams / $pkgG - 0.02))
        $ev += $k * $pkgP
        $bid = if($ing.PSObject.Properties.Name -contains 'bid'){ [string]$ing.bid } else { '' }
        $gpuRaw = if($ing.PSObject.Properties.Name -contains 'gpu' -and $ing.gpu){ [double]$ing.gpu } else { 0 }
        # THE SAME BASIS THE CARD NOW EMITS (2026-09-02, corn04). One recipe row used to carry two:
        # everyday_ps above pairs grams with pkg_g (both drained, correct), cheapest_ps below paired
        # the same grams with the ingredient row's GROSS gpu and under-bought on 88 of 105 same-package
        # drained lines. build-card2 writes gpu_eff into the block; this reads the identical transform
        # off the identical costed row, so the manifest and the card cannot disagree by construction.
        $gpu = Get-ScalerGpu $gpuRaw ([double]$pkgG) ([double]$pk.pkg_gross_g)
        # [int]$ing.grams ON PURPOSE: build-card2 emits the scaler data block with `[int]$ing.grams`, so
        # the card's `required` is computed from the ROUNDED grams. Using the unrounded double here would
        # put this number a cent off the card's on some recipes, which is exactly the kind of drift the
        # cross-check below exists to catch.
        $req = if($gpu -gt 0){ [double][int]$ing.grams / $gpu } else { 0.0 }
        $fallback = if($gpu -gt 0 -and $pkgG -gt 0){ $pkgG/$gpu } else { 0.0 }
        $cc = Get-CheapestCost $bid $req $fallback
        # No priceable cell for this bid (no board price, or an allowlisted no-board-price ingredient):
        # fall back to the recipe's own everyday package cost, exactly as before.
        if($null -ne $cc){ $ch += $cc } else { $ch += $k * $pkgP }
      }
      $blockExpect[[string]$spec.slug] = $expLines
      $rows += [pscustomobject]@{
        slug=$spec.slug; name=$spec.name; run=$run; protein=$spec.protein
        protein_g=[int]$spec.stat.protein
        old_ps=[double]$spec.stat.cost_ps
        everyday_ps=[math]::Round($ev/14,2)
        cheapest_ps=[math]::Round($ch/14,2)
      }
    } catch {
      $bad += ("{0}: {1}" -f $sf.BaseName, $_.Exception.Message)
    }
  }
}
# protein-class ranks (for the writer wave's superlative decisions), by protein grams desc
foreach($grp in ($rows | Group-Object protein)){
  $sorted = $grp.Group | Sort-Object -Property @{e={-$_.protein_g}}, name
  for($i=0;$i -lt $sorted.Count;$i++){
    $sorted[$i] | Add-Member -NotePropertyName protein_rank -NotePropertyValue ($i+1) -Force
    $sorted[$i] | Add-Member -NotePropertyName is_protein_rank1 -NotePropertyValue ($i -eq 0) -Force
  }
}
# block-before-ship: clamp any cheapest>everyday inversion to the valid bound BEFORE the manifest is
# written, and collect real (beyond-rounding) inversions to alert triage.
$inverted = Resolve-Inversions $rows 0.02 0.50
$clampedCount = @($rows | Where-Object { [double]$_.cheapest_ps -eq [double]$_.everyday_ps }).Count
. (Join-Path $mp 'lib\json-db-io.ps1')
# SNAPSHOT THE PRIOR MANIFEST BEFORE OVERWRITING IT (2026-08-07).
# reanchor-moved-prose.ps1 needs the PRE-recompute manifest to diff against and refuses to run without one,
# so the estate's documented procedure was "remember to copy v2-perserving.json aside first". A manual step
# that must happen BEFORE the thing that destroys the evidence is a step that gets skipped, and when it is
# skipped the recovery is ugly: you cannot reconstruct the old values from anywhere, so the baseline has to
# be synthesised by scraping each spec's own prose. Worse, the naive recovery (snapshot AFTER the recompute)
# produces a zero delta and reports "0 moved recipes" - true, and completely misleading.
# The writer now takes its own before-picture. Nothing to remember.
$prevPath = Join-Path $here 'v2-perserving.prev.json'
$curPath  = Join-Path $here 'v2-perserving.json'
if(Test-Path $curPath){ Copy-Item $curPath $prevPath -Force }
Save-JsonArray -Array $rows -Path $curPath -Depth 4 | Out-Null
$evAll = $rows | ForEach-Object { $_.everyday_ps }; $chAll = $rows | ForEach-Object { $_.cheapest_ps }
Write-Output ("computed {0} recipes -> pipeline\v2-perserving.json" -f $rows.Count)
Write-Output ("everyday_ps  range `${0}-`${1}  mean `${2}" -f ($evAll|Measure-Object -Minimum).Minimum,($evAll|Measure-Object -Maximum).Maximum,[math]::Round(($evAll|Measure-Object -Average).Average,2))
Write-Output ("cheapest_ps  range `${0}-`${1}  mean `${2}" -f ($chAll|Measure-Object -Minimum).Minimum,($chAll|Measure-Object -Maximum).Maximum,[math]::Round(($chAll|Measure-Object -Average).Average,2))
Write-Output ("cheapest_ps clamped to everyday_ps on {0} recipe(s) (expected: the store's smallest package can be bigger than the package the recipe assumed - see the note on Resolve-Inversions)" -f $clampedCount)
# WRITE THE REPORT EVERY RUN, INCLUDING WHEN IT IS EMPTY. This file used to be written only when there was
# something to say, so it could only ever grow: after the 2026-08-15 threshold change it sat on disk
# holding 50 rows from the previous run while the current run had found none, which reads as 50 outstanding
# price bugs. An uncleared output is only correct while output grows.
# The empty case is written as a literal '[]': PS 5.1 turns `,@() | ConvertTo-Json` into
# {"value":[],"Count":0}, which is not the empty LIST any reader of this file expects.
$invJson = if($inverted.Count -eq 0){ '[]' } elseif($inverted.Count -eq 1){ '[' + ($inverted[0] | ConvertTo-Json -Depth 4) + ']' } else { $inverted.ToArray() | ConvertTo-Json -Depth 4 }
Set-Content (Join-Path $here 'v2-inversions.json') -Value $invJson -Encoding utf8
if($inverted.Count){
  Write-Output ("BLOCK-BEFORE-SHIP: {0} recipe(s) inverted by more than 50%, too much to be a packaging artifact (likely a wrong feed price or gpu - triage):" -f $inverted.Count)
  $inverted | ForEach-Object { Write-Output ("  {0}: everyday `${1} but feed-cheapest `${2} ({3:P0} over)" -f $_.slug,$_.everyday_ps,$_.raw_cheapest_ps,$_.over_frac) }
  # Alerts go out through Send-Alert (grocery\alert-lib.ps1), never as `powershell -File send-alert.ps1
  # -Body $long`: Windows refuses to start a process whose command line passes 32767 chars, so an oversized
  # body did not arrive truncated - it did not arrive at all. See alert-lib.ps1.
  $alertLib = Join-Path $mp '..\grocery\alert-lib.ps1'
  if(Test-Path $alertLib){
    . $alertLib
    $body = "compute-v2 found recipes whose 'cheapest everywhere' price computed MORE THAN 50% HIGHER than the everyday price. Since 2026-08-15 a modest inversion is expected (cheapest_ps prices the STORE's package, everyday_ps the recipe's own authored package, so a store whose smallest pack is bigger than the assumed one legitimately costs more) - but an inversion this large is too big to be packaging and points at a wrong feed price or a wrong gpu. The shipped number was clamped to everyday (safe), but the underlying price must be fixed. Rows: " + (($inverted | Select-Object -First 12 | ForEach-Object { "$($_.slug) ev=$($_.everyday_ps) ch=$($_.raw_cheapest_ps)" }) -join ' | ')
    Send-Alert -Subject ("Recipe price inversion: {0} clamped" -f $inverted.Count) -Body $body -What 'v2 price inversion' | Out-Null
  }
}
if($CrossCheck){
  # Recompute each recipe's cheapest batch total from the BUILT CARD's baked data block - the exact bytes
  # the browser reads - and compare to this manifest. The typed script tag is the anchor; do NOT search for
  # the bare class name, the template's own JS contains that literal.
  $re = [regex]'(?s)<script type="application/json" class="smp-sc-data">(.*?)</script>'
  $builtDir = Join-Path $mp 'db\built'
  $checked = 0; $mismatch = New-Object System.Collections.Generic.List[string]; $noCard = 0
  # THE SECOND QUESTION (2026-09-02, corn04). The total comparison below asks whether the manifest and
  # the card price the same basket the same way - and both read the SAME data block, so a block on the
  # wrong basis agrees with itself and this cross-check stayed green through 88 short lines on 76 live
  # cards. This asks whether the block's own package count, at the block's own authored package, is the
  # count the ENGINE arrived at. Nothing here reads the feed, so it is true whenever it is run.
  $countBad = New-Object System.Collections.Generic.List[string]
  $countChecked = 0; $countSkipped = 0
  foreach($r in $rows){
    $cf = Join-Path $builtDir ($r.slug + '.body.html')
    if(-not (Test-Path $cf)){ $noCard++; continue }
    $m = $re.Match([IO.File]::ReadAllText($cf))
    if(-not $m.Success){ $noCard++; continue }
    try { $d = $m.Groups[1].Value | ConvertFrom-Json } catch { $noCard++; continue }

    $exp = $blockExpect[[string]$r.slug]
    if($null -eq $exp){ $countSkipped += @($d.ing).Count }
    else {
      $bIng = @($d.ing)
      if($bIng.Count -ne $exp.Count){
        # A card built from a different spec revision than this run read. Say so rather than comparing
        # row 4 against row 5 and reporting a count bug that is really a staleness bug.
        $countBad.Add(("{0}: the built card has {1} ingredient line(s), the spec {2} - the card is stale, rebuild before trusting any count" -f $r.slug, $bIng.Count, $exp.Count))
      } else {
        for($i=0; $i -lt $bIng.Count; $i++){
          $it = $bIng[$i]; $e = $exp[$i]
          if($null -eq $e.n){ $countSkipped++; continue }                       # covered line: no package
          if([string]$it.item -ne [string]$e.item){ $countSkipped++; continue } # not the row we recorded
          $kBlock = Get-BlockPkgCount ([double]$it.grams) ([double]$it.gpu) ([double]$it.pkg_g)
          if($kBlock -eq 0){ $countSkipped++; continue }                        # no gpu or no package
          $countChecked++
          # STALENESS: the card on disk against the costed row this run read.
          if($kBlock -ne [int]$e.n){
            $countBad.Add(("{0} :: {1}: the card's own block buys {2} package(s) at its authored size, the cost line says {3} (grams {4}, gpu {5}, pkg_g {6}) - rebuild the card" -f `
              $r.slug, $it.item, $kBlock, [int]$e.n, $it.grams, $it.gpu, $it.pkg_g))
          }
          # BASIS: the block's fallback package against the package a reader actually buys. THIS is
          # the one that sees a card built by the old renderer, because the count above cannot.
          $bad = Get-ScalerBasisMismatch ([double]$it.pkg_g) ([double]$it.gpu) ([double]$e.pkg_gross_g) ([double]$e.spec_gpu)
          if($null -ne $bad){
            $countBad.Add(("{0} :: {1}: the block's authored fallback package is {2:N2} units but the package is {3:N2} units - gpu is on the wrong basis, so the widget, the print list and the store picker all under-buy" -f `
              $r.slug, $it.item, $bad.fallback, $bad.physical))
          }
        }
      }
    }

    $tot = 0.0; $ok = $true
    foreach($it in $d.ing){
      $gpu = [double]$it.gpu
      if($gpu -le 0){ $ok = $false; break }
      $req = [double]$it.grams / $gpu
      $fb = if([double]$it.pkg_g -gt 0){ [double]$it.pkg_g / $gpu } else { 0.0 }
      $bid = [string]$it.bid
      $cc = if($bid -and $piMap.ContainsKey($bid)){ Get-PkgCheapestAcross $piMap[$bid] $req $fb } else { $null }
      # a line the card cannot price is a line this comparison cannot speak to
      if($null -eq $cc){ $ok = $false; break }
      $tot += [double]$cc.cost
    }
    if(-not $ok){ continue }
    $checked++
    $mine = [double]$r.cheapest_ps * 14
    # tolerance covers the clamp (cheapest is pinned to everyday on inversions) and 2dp rounding
    if([math]::Abs($mine - $tot) -gt 0.25 -and [double]$r.cheapest_ps -lt [double]$r.everyday_ps){
      $mismatch.Add(("{0}: manifest `${1} vs card `${2}" -f $r.slug, [math]::Round($mine,2), [math]::Round($tot,2)))
    }
  }
  Write-Output ("CROSS-CHECK counts: {0} block line(s) compared against the engine's Buy N, {1} disagreement(s), {2} line(s) not comparable" -f $countChecked, $countBad.Count, $countSkipped)
  foreach($x in ($countBad | Select-Object -First 20)){ Write-Output ('  ' + $x) }
  if($countBad.Count -gt 20){ Write-Output ("  ... and {0} more" -f ($countBad.Count - 20)) }
  Write-Output ("CROSS-CHECK vs built cards: {0} recipe(s) fully comparable, {1} disagreement(s), {2} card(s) not comparable" -f $checked, $mismatch.Count, $noCard)
  foreach($x in ($mismatch | Select-Object -First 12)){ Write-Output ('  ' + $x) }
  if($countBad.Count){
    Write-Output 'CROSS-CHECK FAILED: a recipe card''s cost widget and its own cost line do not agree on how many packages the batch needs.'
    exit 2
  }
  if($mismatch.Count){
    Write-Output 'CROSS-CHECK FAILED: the manifest and the recipe cards are pricing the same basket differently.'
    exit 2
  }
}
if($bad.Count){
  Write-Output ("SKIPPED {0} recipe(s) with bad cost data (manifest still written for the other {1}):" -f $bad.Count, $rows.Count)
  $bad | ForEach-Object { Write-Output ("  " + $_) }
  exit 1
}