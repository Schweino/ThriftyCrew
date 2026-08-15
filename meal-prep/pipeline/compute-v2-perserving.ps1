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
if($SelfTest){
  $t = @(
    [pscustomobject]@{slug='inv-real'; everyday_ps=3.00; cheapest_ps=3.30},   # 10% inverted -> flag + clamp
    [pscustomobject]@{slug='inv-round';everyday_ps=3.00; cheapest_ps=3.01},   # rounding only -> clamp, no flag
    [pscustomobject]@{slug='ok';       everyday_ps=3.00; cheapest_ps=2.50}    # valid -> untouched
  )
  $fl = Resolve-Inversions $t 0.02 0.03
  $pass = ($t[0].cheapest_ps -eq 3.00) -and ($t[1].cheapest_ps -eq 3.00) -and ($t[2].cheapest_ps -eq 2.50) -and ($fl.Count -eq 1) -and ($fl[0].slug -eq 'inv-real')
  if($pass){ Write-Output 'SELFTEST PASS: cheapest<=everyday clamp + real-inversion flag correct'; exit 0 }
  Write-Output ("SELFTEST FAIL: clamped=[{0},{1},{2}] flagged={3}" -f $t[0].cheapest_ps,$t[1].cheapest_ps,$t[2].cheapest_ps,$fl.Count); exit 1
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
. (Join-Path $mp 'lib\package-cost-lib.ps1')
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
foreach($run in @('db')){
  foreach($sf in (Get-ChildItem (Join-Path $mp "db\recipes\*.json"))){
    try {
      $spec = Get-Content $sf.FullName -Raw | ConvertFrom-Json
      $cr = $dbCosted[[string]$spec.slug]
      if(-not $cr){ throw "no db\costed entry" }
      $clines = @{}; foreach($l in $cr.lines){ $clines[$l.item] = $l }
      $ev = 0.0; $ch = 0.0
      foreach($ing in $spec.scaler.ing){
        $key = if($ing.PSObject.Properties.Name -contains 'canon' -and $ing.canon){ $ing.canon } else { $ing.item }
        $cl = $clines[$key]; if(-not $cl){ throw "no costed line '$key'" }
        $n = if($cl.buy_n){ [int]$cl.buy_n } else { [int]$cl.starter_n }
        $c = if($cl.buy_cost){ [double]$cl.buy_cost } else { [double]$cl.starter_cost }
        $pkgG = if($cl.pkg_g){ [double]$cl.pkg_g } else { [double]$cl.starter_pkg_g }
        if($n -lt 1 -or $c -le 0 -or $pkgG -le 0){ throw "bad pkg data on '$key'" }
        $pkgP = $c / $n
        $k = [math]::Max(1,[math]::Ceiling([double]$ing.grams / $pkgG - 0.02))
        $ev += $k * $pkgP
        $bid = if($ing.PSObject.Properties.Name -contains 'bid'){ [string]$ing.bid } else { '' }
        $gpu = if($ing.PSObject.Properties.Name -contains 'gpu' -and $ing.gpu){ [double]$ing.gpu } else { 0 }
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
  foreach($r in $rows){
    $cf = Join-Path $builtDir ($r.slug + '.body.html')
    if(-not (Test-Path $cf)){ $noCard++; continue }
    $m = $re.Match([IO.File]::ReadAllText($cf))
    if(-not $m.Success){ $noCard++; continue }
    try { $d = $m.Groups[1].Value | ConvertFrom-Json } catch { $noCard++; continue }
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
  Write-Output ("CROSS-CHECK vs built cards: {0} recipe(s) fully comparable, {1} disagreement(s), {2} card(s) not comparable" -f $checked, $mismatch.Count, $noCard)
  foreach($x in ($mismatch | Select-Object -First 12)){ Write-Output ('  ' + $x) }
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