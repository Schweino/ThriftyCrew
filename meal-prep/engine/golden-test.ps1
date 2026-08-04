# golden-test.ps1 - proves the unified engine reproduces the retired per-run engines. Compares
# db\costed.json against the three per-run recipes-costed.json files, per slug:
#   totals: cost_batch, cost_batch_true, cost_pantry_add, cost_first_run (tolerance 0.5c)
#   lines:  per-item buy_n/buy_cost/pkg_g/starter_n/starter_cost/starter_pkg_g
# Every diff is listed with its cause-class so nothing resolves silently.
#
# EXPIRY (2026-08-04). This compares a DAILY-REGENERATED file (db\costed.json) against a FROZEN
# snapshot (archive\*\recipes-costed.json, untouched since the 2026-07-26 consolidation commit). It
# proved the port on the day of that commit, at the same moment, and it CANNOT pass again: every
# daily recost moves cost_batch, and a board switching to a different cheapest package size moves
# pkg_g/buy_n with it. Run cold on 2026-08-04 it emitted 10,339 diffs across all 513 recipes, which
# reads as a catastrophic regression and is in fact nine days of grocery prices.
#
# A check whose verdict carries no information is worse than no check, because it teaches you to
# ignore its output (the mirror of the gates-that-can-never-arm class). So it now refuses by default
# and says why. -Force runs it anyway and splits the result into PRICE-DRIVEN (expected, ignore) and
# STRUCTURAL (buy_n/pkg_g/starter_*/missing lines - the only class that could still be a port bug).
param([switch]$Force)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp = Split-Path -Parent $here

$BaselineFrozen = Get-Date '2026-07-26'
$costedFile = Join-Path $mp 'db\costed.json'
if (-not $Force -and (Test-Path $costedFile) -and (Get-Item $costedFile).LastWriteTime.Date -gt $BaselineFrozen.Date) {
  $age = ((Get-Item $costedFile).LastWriteTime.Date - $BaselineFrozen.Date).Days
  Write-Output ''
  Write-Output 'GOLDEN: EXPIRED - not run.'
  Write-Output ("  baseline archive\*\recipes-costed.json is frozen at {0:yyyy-MM-dd}" -f $BaselineFrozen)
  Write-Output ("  db\costed.json was rebuilt {0} day(s) later with current board prices" -f $age)
  Write-Output '  Any diff it reports now is price movement, not a port regression.'
  Write-Output '  The port was proven on 2026-07-26 (see engine\README.md). Nothing re-proves it.'
  Write-Output '  Use -Force to run anyway; output is split into PRICE-DRIVEN and STRUCTURAL.'
  return
}
function Slugify([string]$s){ (($s.ToLower() -replace "[^a-z0-9]+","-").Trim('-')) }
$new=@{}
foreach($r in (Get-Content (Join-Path $mp 'db\costed.json') -Raw | ConvertFrom-Json)){ $new[[string]$r.slug]=$r }
$specSlugs=@{}
foreach($sf in (Get-ChildItem (Join-Path $mp 'db\recipes\*.json'))){ $specSlugs[$sf.BaseName]=1 }

$totalDiffs=New-Object System.Collections.Generic.List[string]
$lineDiffs=New-Object System.Collections.Generic.List[string]
$checked=0; $matched=0
foreach($run in 'r100','r300','orig'){
  $old = Get-Content (Join-Path $mp "archive\$run\recipes-costed.json") -Raw | ConvertFrom-Json
  foreach($o in $old){
    $slug = if($o.PSObject.Properties.Name -contains 'slug' -and $o.slug){ [string]$o.slug } else { $null }
    if(-not $slug){
      # r100 costed rows lack slug: resolve via slugified name against the spec store
      $cand = Slugify ([string]$o.proposed_name)
      if($specSlugs.ContainsKey($cand)){ $slug=$cand }
      else {
        $hit = $specSlugs.Keys | Where-Object { $_ -eq $cand } | Select-Object -First 1
        if(-not $hit){
          # match by name through the new costed set
          $hit = ($new.Values | Where-Object { $_.proposed_name -eq $o.proposed_name } | Select-Object -First 1)
          if($hit){ $slug = [string]$hit.slug }
        }
      }
    }
    if(-not $slug -or -not $new.ContainsKey($slug)){ $totalDiffs.Add(("[$run] NO NEW MATCH for '{0}'" -f $o.proposed_name)); continue }
    $n = $new[$slug]; $checked++
    $ok=$true
    foreach($f in 'cost_batch','cost_batch_true','cost_pantry_add','cost_first_run'){
      $ov=[double]$o.$f; $nv=[double]$n.$f
      if([math]::Abs($ov-$nv) -gt 0.005){ $ok=$false; $totalDiffs.Add(("[$run] {0} .{1}: old {2} new {3}" -f $slug,$f,$ov,$nv)) }
    }
    # line-level compare keyed by item
    $om=@{}; foreach($l in $o.lines){ $om[[string]$l.item]=$l }
    foreach($l in $n.lines){
      $ol = $om[[string]$l.item]
      if(-not $ol){ $ok=$false; $lineDiffs.Add(("[$run] {0} :: {1} :: line only in NEW" -f $slug,$l.item)); continue }
      foreach($f in 'buy_n','buy_cost','pkg_g','starter_n','starter_cost','starter_pkg_g','util_cost'){
        $ov = $ol.PSObject.Properties[$f].Value; $nv = $l.PSObject.Properties[$f].Value
        $ovS = if($null -eq $ov){''}else{('{0:0.###}' -f [double]$ov)}
        $nvS = if($null -eq $nv){''}else{('{0:0.###}' -f [double]$nv)}
        if($ovS -ne $nvS){ $ok=$false; $lineDiffs.Add(("[$run] {0} :: {1} .{2}: old '{3}' new '{4}'" -f $slug,$l.item,$f,$ovS,$nvS)) }
      }
    }
    foreach($l in $o.lines){ if(-not ($n.lines | Where-Object { $_.item -eq $l.item })){ $ok=$false; $lineDiffs.Add(("[$run] {0} :: {1} :: line only in OLD" -f $slug,$l.item)) } }
    if($ok){ $matched++ }
  }
}
Write-Output ("GOLDEN: checked {0} recipes; EXACT match {1}; recipes with diffs {2}" -f $checked,$matched,($checked-$matched))

# Split by cause. A price move is expected against a frozen baseline; only STRUCTURAL drift
# (package counts/sizes, or a line appearing on one side only) could still mean a port bug.
$all = @($totalDiffs) + @($lineDiffs)
$structural = @($all | Where-Object { $_ -match '\.(buy_n|pkg_g|starter_n|starter_pkg_g):' -or $_ -match 'line only in (NEW|OLD)' -or $_ -match 'NO NEW MATCH' })
$price      = @($all | Where-Object { $structural -notcontains $_ })
Write-Output ("  PRICE-DRIVEN (expected vs a frozen baseline): {0}" -f $price.Count)
Write-Output ("  STRUCTURAL   (the only class worth reading) : {0}" -f $structural.Count)

$out = @('==== STRUCTURAL (package counts/sizes, missing lines) ====') + $structural +
       @('', '==== PRICE-DRIVEN (expected: baseline frozen 2026-07-26) ====') + $price
[IO.File]::WriteAllLines((Join-Path $mp 'db\golden-diffs.txt'), $out, (New-Object Text.UTF8Encoding($false)))
Write-Output "full detail -> db\golden-diffs.txt (structural section first)"
# summarize line diffs by item for triage
$byItem = $lineDiffs | ForEach-Object { if($_ -match ':: ([^:]+) \.'){ $Matches[1].Trim() } } | Group-Object | Sort-Object Count -Descending
$byItem | Select-Object -First 15 | ForEach-Object { Write-Output ("  {0,4}x {1}" -f $_.Count,$_.Name) }