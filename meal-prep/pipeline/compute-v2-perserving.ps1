# compute-v2-perserving.ps1 - the single source of truth for the redesign's per-serving numbers.
# For every r100+r300 recipe, computes (whole-package model, matching the card widget exactly):
#   everyday_ps  = sum(ceil(grams/pkg_g -0.02) * pkg_p) / 14           (== cost_first_run/14, the "at everyday cost" stat)
#   cheapest_ps  = sum(k * (pkg_g/gpu) * feed.cheapest, else k*pkg_p) / 14   (the headline "cheapest everywhere" number)
# Emits pipeline/v2-perserving.json (manifest: slug,name,protein,protein_g,old_ps,everyday_ps,cheapest_ps,
# protein_rank,is_protein_rank1) - the input for BOTH the prose writer wave and the site-surface switch.
param([string]$FeedPath = 'C:\Codex\income\meal-prep\scratch-smpfeed.json', [switch]$SelfTest)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp = Split-Path -Parent $here
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

# BLOCK-BEFORE-SHIP (2026-07-27, overhaul-1): cheapest_ps can never legitimately exceed everyday_ps -
# 'cheapest everywhere' is by construction the floor over the same aligned product the db everyday bid
# prices. A row where cheapest > everyday means the two pricing paths disagree (a stale/wrong feed price,
# or a residual gpu/unit mismatch surviving the 07-26 reconciliation). Shipping it puts a 'cheapest' HIGHER
# than 'everyday' on every manifest surface (rankings, top5, meal-planner) - visibly nonsensical to a
# shopper and an accuracy violation. We CLAMP the shipped cheapest to everyday (the valid bound: never
# inverted, never overstated) so the bad number can't reach a surface, and separately flag rows whose RAW
# inversion is beyond rounding so triage fixes the underlying price. The clamp is the block; the flag is
# the alert. Pure function (no globals) so it is self-testable without the feed/db.
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

if(-not (Test-Path $FeedPath)){
  Invoke-WebRequest -Uri 'https://smp-feed.ancient-snow-93df.workers.dev/smp-feed.json' -OutFile $FeedPath -TimeoutSec 40 -UseBasicParsing
}
$feed = (Get-Content $FeedPath -Raw -Encoding utf8 | ConvertFrom-Json).ingredients
$feedMap = @{}; foreach($p in $feed.PSObject.Properties){ $feedMap[$p.Name] = $p.Value }

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
        $fe = if($bid -and $feedMap.ContainsKey($bid)){ $feedMap[$bid] } else { $null }
        if($fe -and [double]$fe.cheapest -gt 0 -and $gpu -gt 0){ $ch += $k * ($pkgG/$gpu) * [double]$fe.cheapest }
        else { $ch += $k * $pkgP }
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
$inverted = Resolve-Inversions $rows 0.02 0.03
. (Join-Path $mp 'lib\json-db-io.ps1')
Save-JsonArray -Array $rows -Path (Join-Path $here 'v2-perserving.json') -Depth 4 | Out-Null
$evAll = $rows | ForEach-Object { $_.everyday_ps }; $chAll = $rows | ForEach-Object { $_.cheapest_ps }
Write-Output ("computed {0} recipes -> pipeline\v2-perserving.json" -f $rows.Count)
Write-Output ("everyday_ps  range `${0}-`${1}  mean `${2}" -f ($evAll|Measure-Object -Minimum).Minimum,($evAll|Measure-Object -Maximum).Maximum,[math]::Round(($evAll|Measure-Object -Average).Average,2))
Write-Output ("cheapest_ps  range `${0}-`${1}  mean `${2}" -f ($chAll|Measure-Object -Minimum).Minimum,($chAll|Measure-Object -Maximum).Maximum,[math]::Round(($chAll|Measure-Object -Average).Average,2))
if($inverted.Count){
  Write-Output ("BLOCK-BEFORE-SHIP: clamped {0} recipe(s) where cheapest_ps exceeded everyday_ps (root price bug - triage):" -f $inverted.Count)
  $inverted | ForEach-Object { Write-Output ("  {0}: everyday `${1} but feed-cheapest `${2} ({3:P0} over)" -f $_.slug,$_.everyday_ps,$_.raw_cheapest_ps,$_.over_frac) }
  Set-Content (Join-Path $here 'v2-inversions.json') -Value (($inverted | ConvertTo-Json -Depth 4)) -Encoding utf8
  # Alerts go out through Send-Alert (grocery\alert-lib.ps1), never as `powershell -File send-alert.ps1
  # -Body $long`: Windows refuses to start a process whose command line passes 32767 chars, so an oversized
  # body did not arrive truncated - it did not arrive at all. See alert-lib.ps1.
  $alertLib = Join-Path $mp '..\grocery\alert-lib.ps1'
  if(Test-Path $alertLib){
    . $alertLib
    $body = "compute-v2 found recipes whose 'cheapest everywhere' price computed HIGHER than the everyday price - impossible on an aligned product, so a feed price or gpu is wrong. The shipped number was clamped to everyday (safe), but the underlying price must be fixed. Rows: " + (($inverted | Select-Object -First 12 | ForEach-Object { "$($_.slug) ev=$($_.everyday_ps) ch=$($_.raw_cheapest_ps)" }) -join ' | ')
    Send-Alert -Subject ("Recipe price inversion: {0} clamped" -f $inverted.Count) -Body $body -What 'v2 price inversion' | Out-Null
  }
}
if($bad.Count){
  Write-Output ("SKIPPED {0} recipe(s) with bad cost data (manifest still written for the other {1}):" -f $bad.Count, $rows.Count)
  $bad | ForEach-Object { Write-Output ("  " + $_) }
  exit 1
}