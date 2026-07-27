# reanchor-machine-fields.ps1 - deterministic, prose-safe re-anchor of the two DISPLAY number fields to
# the new everyday basis (from v2-perserving.json): stat.cost_ps and head.costPerServing. Static/prose
# surfaces use the STABLE everyday number (labeled "at everyday cost"); the dynamic cheapest number lives
# in the live rectangle + refreshed site surfaces, never baked into static text. Targeted key-scoped text
# edits only (NEVER re-serialize the whole spec - the prose carries \uXXXX escapes). Parse-verifies each.
param([string[]]$Slugs)   # optional: re-anchor only these slugs (a targeted fix), else the whole catalog
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp = Split-Path -Parent $here
$man = Get-Content (Join-Path $here 'v2-perserving.json') -Raw | ConvertFrom-Json
$bySlug=@{}; foreach($r in $man){ $bySlug[$r.slug]=$r }
$done=0; $skip=0
foreach($run in @('db')){
  foreach($sf in (Get-ChildItem (Join-Path $mp "db\recipes\*.json"))){
    $slug = $sf.BaseName
    if($Slugs -and ($Slugs -notcontains $slug)){ continue }
    $e = $bySlug[$slug]; if(-not $e){ Write-Warning "no manifest for $slug"; $skip++; continue }
    $new = ('{0:0.00}' -f [double]$e.everyday_ps)
    $raw = [IO.File]::ReadAllText($sf.FullName)
    $raw = [regex]::Replace($raw, '("cost_ps":\s*")[^"]*(")', ('${1}' + $new + '${2}'))
    $raw = [regex]::Replace($raw, '("costPerServing":\s*)[0-9]+(?:\.[0-9]+)?', ('${1}' + $new))
    $null = $raw | ConvertFrom-Json   # parse-verify
    [IO.File]::WriteAllText($sf.FullName, $raw, (New-Object Text.UTF8Encoding($false)))
    $done++
  }
}
Write-Output ("re-anchored cost_ps + costPerServing on {0} specs (skipped {1})" -f $done,$skip)