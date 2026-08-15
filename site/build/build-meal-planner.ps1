# build-meal-planner.ps1 - Builds meal-plan-builder-tool.html from meal-plan-builder-template.html.
# SCALE (2026-07-26): the per-recipe data (var MPP) is NO LONGER embedded at //__DATA__. The tool now
# fetches public\planner-data.json from the Worker at load time (gen-planner-data.ps1 writes both the
# served JSON and the legacy planner-data.js), so the published post stays template-size (~30 KB) no
# matter how large the catalog grows - Ghost Pro 503s on a lexical card near ~1.6 MB, which the embedded
# data was heading toward (815 KB at 513 recipes, ~2.35 MB at 1500). The //__DATA__ marker is retired to
# a harmless comment; if still present it is replaced with nothing meaningful.
$ErrorActionPreference='Stop'
$dir='C:\Codex\ThriftyCrew'
$tpl=[IO.File]::ReadAllText((Join-Path $dir 'site\tools\meal-plan-builder-template.html'))
$out=$tpl.Replace('//__DATA__','// planner data fetched from the Worker at runtime (see gen-planner-data.ps1)')
# sanity: the tool must fetch the served data, and must NOT carry an embedded MPP array (the thing we removed)
if($out -notmatch 'planner-data\.json'){ throw 'template does not fetch planner-data.json - the async data load is missing' }
if($out -match 'var MPP=\[\s*\{'){ throw 'template still EMBEDS the MPP data array - the whole point was to stop embedding it' }
if($out -match [char]0x2014 -or $out -match [char]0x2013){ throw 'EM/EN DASH found' }
if($out.TrimEnd() -notmatch '</script>\s*</div>$'){ throw 'output does not end with </script></div>' }
[IO.File]::WriteAllText((Join-Path $dir 'site\tools\meal-plan-builder-tool.html'),$out,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("meal-plan-builder-tool.html: " + [Math]::Round((Get-Item (Join-Path $dir 'site\tools\meal-plan-builder-tool.html')).Length/1024,0) + " KB (data now Worker-served, was ~815 KB embedded)")
