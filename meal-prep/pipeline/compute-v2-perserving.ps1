# compute-v2-perserving.ps1 - the single source of truth for the redesign's per-serving numbers.
# For every r100+r300 recipe, computes (whole-package model, matching the card widget exactly):
#   everyday_ps  = sum(ceil(grams/pkg_g -0.02) * pkg_p) / 14           (== cost_first_run/14, the "at everyday cost" stat)
#   cheapest_ps  = sum(k * (pkg_g/gpu) * feed.cheapest, else k*pkg_p) / 14   (the headline "cheapest everywhere" number)
# Emits pipeline/v2-perserving.json (manifest: slug,name,protein,protein_g,old_ps,everyday_ps,cheapest_ps,
# protein_rank,is_protein_rank1) - the input for BOTH the prose writer wave and the site-surface switch.
param([string]$FeedPath = 'C:\Codex\income\meal-prep\scratch-smpfeed.json')
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp = Split-Path -Parent $here
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

if(-not (Test-Path $FeedPath)){
  Invoke-WebRequest -Uri 'https://smp-feed.ancient-snow-93df.workers.dev/smp-feed.json' -OutFile $FeedPath -TimeoutSec 40 -UseBasicParsing
}
$feed = (Get-Content $FeedPath -Raw -Encoding utf8 | ConvertFrom-Json).ingredients
$feedMap = @{}; foreach($p in $feed.PSObject.Properties){ $feedMap[$p.Name] = $p.Value }

function Slugify([string]$s){ (($s.ToLower() -replace "[^a-z0-9]+","-").Trim('-')) }

$rows = @()
foreach($run in 'r100','r300'){
  $costed = Get-Content (Join-Path $mp "$run\recipes-costed.json") -Raw | ConvertFrom-Json
  foreach($sf in (Get-ChildItem (Join-Path $mp "$run\specs\*.json") | Where-Object Name -ne '_index.json')){
    $spec = Get-Content $sf.FullName -Raw | ConvertFrom-Json
    $cr = $costed | Where-Object { $_.proposed_name -eq $spec.name }
    if(-not $cr){ $cr = $costed | Where-Object { (Slugify $_.proposed_name) -eq $spec.slug } }
    if(($cr | Measure-Object).Count -ne 1){ throw "costed match failed for $($spec.slug) ($((@($cr)).Count))" }
    $clines = @{}; foreach($l in $cr.lines){ $clines[$l.item] = $l }
    $ev = 0.0; $ch = 0.0
    foreach($ing in $spec.scaler.ing){
      $key = if($ing.PSObject.Properties.Name -contains 'canon' -and $ing.canon){ $ing.canon } else { $ing.item }
      $cl = $clines[$key]; if(-not $cl){ throw "no line $key in $($spec.slug)" }
      $n = if($cl.buy_n){ [int]$cl.buy_n } else { [int]$cl.starter_n }
      $c = if($cl.buy_cost){ [double]$cl.buy_cost } else { [double]$cl.starter_cost }
      $pkgG = if($cl.pkg_g){ [double]$cl.pkg_g } else { [double]$cl.starter_pkg_g }
      if($n -lt 1 -or $c -le 0 -or $pkgG -le 0){ throw "bad pkg data $key in $($spec.slug)" }
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
. (Join-Path $mp 'lib\json-db-io.ps1')
Save-JsonArray -Array $rows -Path (Join-Path $here 'v2-perserving.json') -Depth 4 | Out-Null
$evAll = $rows | ForEach-Object { $_.everyday_ps }; $chAll = $rows | ForEach-Object { $_.cheapest_ps }
Write-Output ("computed {0} recipes -> pipeline\v2-perserving.json" -f $rows.Count)
Write-Output ("everyday_ps  range \${0}-\${1}  mean \${2}" -f ($evAll|Measure-Object -Minimum).Minimum,($evAll|Measure-Object -Maximum).Maximum,[math]::Round(($evAll|Measure-Object -Average).Average,2))
Write-Output ("cheapest_ps  range \${0}-\${1}  mean \${2}" -f ($chAll|Measure-Object -Minimum).Minimum,($chAll|Measure-Object -Maximum).Maximum,[math]::Round(($chAll|Measure-Object -Average).Average,2))
Write-Output ("old_ps       mean \${0}" -f [math]::Round((($rows|ForEach-Object{$_.old_ps})|Measure-Object -Average).Average,2))