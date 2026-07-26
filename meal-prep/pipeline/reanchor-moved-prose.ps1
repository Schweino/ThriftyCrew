# reanchor-moved-prose.ps1 - after the spice-price fix moved some everyday_ps values, update the PROSE
# dollar figure in the recipes that moved. Field-scoped (only intro_html/cost_closing_html/upsell_html/
# head.description) via a JSON-string-aware regex + MatchEvaluator, so shop_smart per-line dollars and
# any coincidental same-value elsewhere are never touched. Compares the current manifest to the pre-fix
# backup; only recipes whose everyday_ps changed by >= $0.005 are edited. Parse-verifies each.
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp = Split-Path -Parent $here
$new = Get-Content (Join-Path $here 'v2-perserving.json') -Raw | ConvertFrom-Json
$old = Get-Content (Join-Path $here 'v2-perserving.bak-prespicefix.json') -Raw | ConvertFrom-Json
$om=@{}; foreach($r in $old){ $om[$r.slug]=$r }
$fields = 'intro_html','cost_closing_html','upsell_html','description'
$edited=0
foreach($run in @('db')){
  foreach($sf in (Get-ChildItem (Join-Path $mp "db\recipes\*.json"))){
    $slug=$sf.BaseName; $ne=$new | Where-Object slug -eq $slug; $oe=$om[$slug]
    if(-not $ne -or -not $oe){ continue }
    $oldS = ('{0:0.00}' -f [double]$oe.everyday_ps); $newS = ('{0:0.00}' -f [double]$ne.everyday_ps)
    if($oldS -eq $newS){ continue }
    $raw = [IO.File]::ReadAllText($sf.FullName)
    $before = $raw
    foreach($f in $fields){
      $rx = [regex]('("' + [regex]::Escape($f) + '":\s*")((?:[^"\\]|\\.)*)(")')
      $raw = $rx.Replace($raw, [System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        $body = $m.Groups[2].Value.Replace('$'+$oldS, '$'+$newS)
        $m.Groups[1].Value + $body + $m.Groups[3].Value
      })
    }
    if($raw -ne $before){
      $null = $raw | ConvertFrom-Json
      [IO.File]::WriteAllText($sf.FullName, $raw, (New-Object Text.UTF8Encoding($false)))
      $edited++
    }
  }
}
Write-Output ("prose dollar re-anchored on {0} moved recipes" -f $edited)