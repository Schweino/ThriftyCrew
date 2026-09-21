# build-cards.ps1 - card stage of the unified engine: renders v2 cards for db\recipes specs using
# pipeline\build-card2.ps1 + db\costed.json -> db\built\<slug>.{body,head}.html. -Slugs for a subset;
# default = the whole catalog, whatever size it is.
param([string[]]$Slugs)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp = Split-Path -Parent $here
$specFiles = Get-ChildItem (Join-Path $mp 'db\recipes\*.json')
# -Slugs UNDER `powershell -File` (2026-09-01): [string[]] does not split a comma list on the -File
# command line, so "a,b,c" arrives as ONE element, matches no BaseName and kills the run on
# 'no specs match -Slugs'. Third script in this estate with the same shape (repair-head-ingredients.ps1
# and engine\publish.ps1 were the other two). Split on commas; a real in-session array is unchanged.
if($Slugs){ $Slugs = @($Slugs | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
if($Slugs){ $specFiles = @($specFiles | Where-Object { $Slugs -contains $_.BaseName }); if(-not $specFiles.Count){ throw 'no specs match -Slugs' } }
New-Item -ItemType Directory -Force (Join-Path $mp 'db\built') | Out-Null
$global:__tcCostedCache=@{}   # fresh cache per run (build-card2 fills it on first parse)
$ok=0; $err=@(); $builtSlugs=@()
foreach($sf in $specFiles){
  try{ & (Join-Path $mp 'pipeline\build-card2.ps1') -SpecFile $sf.FullName -CostedFile (Join-Path $mp 'db\costed.json') -OutDir (Join-Path $mp 'db\built') *>$null; $ok++; $builtSlugs += $sf.BaseName }
  catch{ $err += ("{0} :: {1}" -f $sf.BaseName, $_.Exception.Message) }
}
# LIVE PRICE FALLBACKS ON THE FILL'S OWN BASIS (2026-09-21). build-card2 writes stat.cost_ps into each live
# price span as a PROVISIONAL fallback, and stat.cost_ps is a different everyday from the one the card fills
# with. This runs every freshly built card's own script against the canonical feed and writes what it filled
# back as the fallback (pipeline\stamp-live-price-fallback.ps1). A card it cannot stamp becomes a build error
# here - fail closed - so the gated republish never ships it and the live page keeps what it had.
if($builtSlugs.Count){
  $stampOut = @(& (Join-Path $mp 'pipeline\stamp-live-price-fallback.ps1') -Slugs $builtSlugs)
  $stampRc = $LASTEXITCODE
  $refused = @{}
  foreach($l in $stampOut){ if([string]$l -match '^  X (\S+) :: (.*)$'){ $refused[$Matches[1]] = $Matches[2] } }
  if($stampRc -eq 2 -or -not ($stampOut -match '^STAMP-LIVE-PRICE-FALLBACK-COMPLETE')){
    $why = 'live price stamp could not run: ' + (($stampOut | Select-Object -Last 2) -join ' / ')
    foreach($s in $builtSlugs){ if(-not $refused.ContainsKey($s)){ $refused[$s] = $why } }
  }
  foreach($s in @($refused.Keys)){ if($builtSlugs -contains $s){ $ok--; $err += ("{0} :: {1}" -f $s, $refused[$s]) } }
}
Write-Output ("built {0}/{1}  errors {2}" -f $ok, @($specFiles).Count, $err.Count)
$err | ForEach-Object { Write-Output ("  X " + $_) }
if($err.Count){ exit 1 }