# validate-prose-reanchor.ps1 - the gate after the writer wave, BEFORE rebuild/publish.
# For every r100+r300 spec, compares the current file against its committed (HEAD) pre-wave version and
# asserts the writers touched ONLY allowed prose fields, then checks the numbers landed. Reports every
# failure with slug + reason; exit-clean means safe to rebuild.
#   ALLOWED to change: intro_html, cost_closing_html, upsell_html, shop_smart, head.description
#   (stat.cost_ps + head.costPerServing already changed by the machine re-anchor - also allowed.)
# CHECKS per spec:
#   1. parses as JSON (both versions)
#   2. NO disallowed top-level field changed (ingredients_display, scaler, make_it, portion_html,
#      cost_lines, stat.cal/protein/carbs/fat, cost_batch/*, etc.)
#   3. everyday_ps string present in intro_html or cost_closing_html
#   4. prose does NOT still contain the OLD per-serving figures ($cost_per_serving / $cost_per_serving_true)
#   5. no em dash / connector dash introduced into the edited prose
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp = Split-Path -Parent $here
$man = Get-Content (Join-Path $here 'v2-perserving.json') -Raw | ConvertFrom-Json
$bySlug=@{}; foreach($r in $man){ $bySlug[$r.slug]=$r }
Push-Location $mp
$allowed = @('intro_html','cost_closing_html','upsell_html','shop_smart')  # + head.description + stat.cost_ps + head.costPerServing handled specially
$proseFields = @('intro_html','cost_closing_html','upsell_html')
$fails=@(); $ok=0
# 2026-07-26 consolidation: specs live in db\recipes (runs archived); count is derived, never hardcoded
foreach($run in @('db')){
  foreach($sf in (Get-ChildItem (Join-Path $mp "db\recipes\*.json"))){
    $slug=$sf.BaseName; $rel="meal-prep/db/recipes/$slug.json"
    $e=$bySlug[$slug]
    try { $cur = Get-Content $sf.FullName -Raw | ConvertFrom-Json } catch { $fails += "$slug :: CURRENT does not parse as JSON"; continue }
    $headRaw = (git show "HEAD:$rel" 2>$null) -join "`n"
    if(-not $headRaw){ $fails += "$slug :: no HEAD version"; continue }
    $head = $headRaw | ConvertFrom-Json
    # (2) disallowed-field integrity
    $bad=@()
    foreach($k in $cur.PSObject.Properties.Name){
      if($k -in @('intro_html','cost_closing_html','upsell_html','shop_smart','head','stat')){ continue }
      $a=($cur.$k | ConvertTo-Json -Depth 12 -Compress); $b=($head.$k | ConvertTo-Json -Depth 12 -Compress)
      if($a -ne $b){ $bad += $k }
    }
    # stat: only cost_ps may differ
    foreach($sk in $cur.stat.PSObject.Properties.Name){ if($sk -eq 'cost_ps'){continue}; if("$($cur.stat.$sk)" -ne "$($head.stat.$sk)"){ $bad += "stat.$sk" } }
    # head: only description + costPerServing may differ
    foreach($hk in $cur.head.PSObject.Properties.Name){ if($hk -in @('description','costPerServing')){continue}; $a=($cur.head.$hk|ConvertTo-Json -Depth 10 -Compress); $b=($head.head.$hk|ConvertTo-Json -Depth 10 -Compress); if($a -ne $b){ $bad += "head.$hk" } }
    if($bad.Count){ $fails += ("$slug :: DISALLOWED field(s) changed: " + ($bad -join ', ')) }
    # (3) everyday_ps present
    $ev = ('{0:0.00}' -f [double]$e.everyday_ps)
    $introClose = "$($cur.intro_html) $($cur.cost_closing_html)"
    if($introClose -notmatch [regex]::Escape('$'+$ev)){ $fails += "$slug :: everyday_ps `$$ev not found in intro/closing" }
    # (4) old per-serving figures gone from prose
    $oldPs = ('{0:0.00}' -f [double]$head.cost_per_serving); $oldTrue = ('{0:0.00}' -f [double]$head.cost_per_serving_true)
    $proseAll = ($proseFields | ForEach-Object { $cur.$_ }) -join ' '
    $proseAll += ' ' + $cur.head.description
    foreach($old in @($oldPs,$oldTrue)){ if($old -ne $ev -and $proseAll -match [regex]::Escape('$'+$old+' ') ){ $fails += "$slug :: stale `$$old still in prose" } }
    # (5) dash check on edited prose
    if($proseAll -match '—' -or $proseAll -match '\S\s-\s\S'){ $fails += "$slug :: em/connector dash in prose" }
    if(-not ($fails | Where-Object { $_ -like "$slug ::*" })){ $ok++ }
  }
}
Pop-Location
Write-Output ("PASS: {0} / {1}    FAILURES: {2}" -f $ok, ($ok + @($fails | ForEach-Object { ($_ -split ' ')[0] } | Sort-Object -Unique).Count), $fails.Count)
$fails | ForEach-Object { Write-Output ("  X " + $_) }
if($fails.Count -eq 0){ Write-Output "GATE OPEN - safe to rebuild + publish" }