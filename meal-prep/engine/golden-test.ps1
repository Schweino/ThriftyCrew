# golden-test.ps1 - proves the unified engine reproduces the retired per-run engines. Compares
# db\costed.json against the three per-run recipes-costed.json files, per slug:
#   totals: cost_batch, cost_batch_true, cost_pantry_add, cost_first_run (tolerance 0.5c)
#   lines:  per-item buy_n/buy_cost/pkg_g/starter_n/starter_cost/starter_pkg_g
# Every diff is listed with its cause-class so nothing resolves silently.
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp = Split-Path -Parent $here
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
Write-Output ("total-level diffs: {0}" -f $totalDiffs.Count)
Write-Output ("line-level diffs:  {0}" -f $lineDiffs.Count)
[IO.File]::WriteAllLines((Join-Path $mp 'db\golden-diffs.txt'), @($totalDiffs) + @('---- lines ----') + @($lineDiffs), (New-Object Text.UTF8Encoding($false)))
Write-Output "full detail -> db\golden-diffs.txt"
# summarize line diffs by item for triage
$byItem = $lineDiffs | ForEach-Object { if($_ -match ':: ([^:]+) \.'){ $Matches[1].Trim() } } | Group-Object | Sort-Object Count -Descending
$byItem | Select-Object -First 15 | ForEach-Object { Write-Output ("  {0,4}x {1}" -f $_.Count,$_.Name) }