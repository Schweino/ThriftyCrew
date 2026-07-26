# build-all.ps1 - Builds body+head for every guard-validated spec (specs-ready.txt) via build-card.ps1.
# Sets the TC og image on each head. Output: built\<slug>.body.html + .head.html
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$TC_OG = 'https://storage.ghost.io/c/4b/5b/4b5b2999-07b7-4733-88cc-1bc0e25912c6/content/images/2026/07/tc-og-1200x630.png'
$ready = Get-Content (Join-Path $here 'specs-ready.txt') | Where-Object { $_ }
$outDir = Join-Path $here 'built'
if(-not (Test-Path $outDir)){ New-Item -ItemType Directory $outDir | Out-Null }
$n=0
foreach($slug in $ready){
  $sf = Join-Path $here ("specs\$slug.json")
  $spec = Get-Content $sf -Raw | ConvertFrom-Json
  if(-not $spec.head.image){ $spec.head.image = $TC_OG; $spec | ConvertTo-Json -Depth 8 | Out-File $sf -Encoding utf8 }
  & (Join-Path $here 'build-card.ps1') -SpecFile $sf -OutDir $outDir | Out-Null
  $n++
}
Write-Output ("built $n cards -> built\")
# structural lint on every built body
$bad=0
foreach($slug in $ready){
  $b = [IO.File]::ReadAllText((Join-Path $outDir "$slug.body.html"), [Text.Encoding]::UTF8)
  $checks = @(
    ($b -match '<!--SMP-SCALER-->'), ($b -match 'smp-sc-data'),
    ($b -match '<h2>Ingredients</h2>'), ($b -match '<h2>Estimated Everyday Cost</h2>'),
    ($b -match '<h2>Shop Smart</h2>'), ($b -match '<h2>Make It</h2>'), ($b -match '<h2>Portion It</h2>'),
    ($b -match 'Recipe adapted from'), ($b -match 'True shopping cost')
  )
  if($checks -contains $false){ Write-Output ("LINT FAIL: $slug"); $bad++ }
  if($b -match [char]0x2014){ Write-Output ("EMDASH IN BODY: $slug"); $bad++ }
}
Write-Output ("lint failures: $bad")
