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
$ok=0; $err=@()
foreach($sf in $specFiles){
  try{ & (Join-Path $mp 'pipeline\build-card2.ps1') -SpecFile $sf.FullName -CostedFile (Join-Path $mp 'db\costed.json') -OutDir (Join-Path $mp 'db\built') *>$null; $ok++ }
  catch{ $err += ("{0} :: {1}" -f $sf.BaseName, $_.Exception.Message) }
}
Write-Output ("built {0}/{1}  errors {2}" -f $ok, @($specFiles).Count, $err.Count)
$err | ForEach-Object { Write-Output ("  X " + $_) }
if($err.Count){ exit 1 }