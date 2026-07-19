# build-meal-planner.ps1 - Concats meal-plan-builder-template.html with meal-prep\planner-data.js
# at the //__DATA__ marker -> meal-plan-builder-tool.html (UTF-8 no BOM). Sanity: marker present,
# data starts with "var MPP=[", no em dashes, output ends </script></div>.
$ErrorActionPreference='Stop'
$dir='C:\Codex\income'
$tpl=[IO.File]::ReadAllText((Join-Path $dir 'meal-plan-builder-template.html'))
$data=[IO.File]::ReadAllText((Join-Path $dir 'meal-prep\planner-data.js')).TrimStart([char]0xFEFF).Trim()
if($tpl -notmatch '//__DATA__'){ throw 'marker //__DATA__ not found' }
if($data -notmatch '^var MPP=\['){ throw 'planner-data.js malformed' }
$out=$tpl.Replace('//__DATA__',$data)
if($out -match [char]0x2014 -or $out -match [char]0x2013){ throw 'EM/EN DASH found' }
if($out.TrimEnd() -notmatch '</script>\s*</div>$'){ throw 'output does not end with </script></div>' }
[IO.File]::WriteAllText((Join-Path $dir 'meal-plan-builder-tool.html'),$out,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("meal-plan-builder-tool.html: " + [Math]::Round((Get-Item (Join-Path $dir 'meal-plan-builder-tool.html')).Length/1024,0) + " KB")
