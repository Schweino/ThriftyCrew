# propagate-recipes.ps1 - ONE command that carries a spec change through every derived copy, or fails loudly.
#
# WHY THIS EXISTS (2026-08-08 architecture review). db\recipes is the master, and it feeds a chain of
# derived copies - recipes-db.json, planner-data, built cards, the live Ghost posts - each refreshed by a
# separate script that a human (or an agent) had to REMEMBER to run in the right order. Every derived copy
# someone forgot became an incident with its own name in the memory files: the og descriptions frozen at
# post creation (~140 pages quoting a wrong price), the R300 cost stamp that sat 10 days across 405 rows,
# and the repair-stops-at-source-of-truth class, twice. The publish step's content-hash gate already proved
# the cure at the last hop; this applies it to the whole chain.
#
# HOW IT DECIDES WHAT IS DIRTY. A SHA1 of each spec's bytes, compared to pipeline\propagate-stamps.json.
# The stamp for a slug is rewritten ONLY after every stage has succeeded for it - a failing run leaves the
# slug dirty, so the next run retries it (the checkpoint-before-durable lesson: a watermark committed
# before the work it certifies turns a failure into silently skipped work).
#
# THE CHAIN (existing, gated scripts - this runner adds ordering + dirt tracking, not new logic):
#   1. sync-recipesdb-buy -Apply     carry label classes into recipes-db.json
#   2. audit-db-agreement            HARD GATE - the two masters must agree before anything renders
#   3. gen-planner-data              the Meal Plan Builder feed
#   4. build-cards -Slugs <dirty>    render only what moved
#   5. publish -Slugs <dirty>        content-hash gated, so unchanged cards cost one skipped GET
#
# Usage:  .\propagate-recipes.ps1            propagate everything dirty
#         .\propagate-recipes.ps1 -DryRun    list dirty slugs, run nothing
#         .\propagate-recipes.ps1 -Baseline  stamp the current state WITHOUT running (first arming only,
#                                            on a catalog independently verified in sync - as on 2026-08-08)
#         .\propagate-recipes.ps1 -SelfTest
param([switch]$DryRun, [switch]$Baseline, [switch]$SelfTest, [string]$Root = "")
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = if ($Root) { $Root } else { Split-Path -Parent $here }
$stampPath = Join-Path $here 'propagate-stamps.json'

function Get-SpecHash([string]$Path) {
  $sha = [System.Security.Cryptography.SHA1]::Create()
  return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path))) -replace '-', '')
}
function Get-DirtySlugs { param([hashtable]$Stamps, $Files)
  $d = New-Object System.Collections.Generic.List[string]
  foreach ($f in $Files) {
    $h = Get-SpecHash $f.FullName
    if (-not $Stamps.ContainsKey($f.BaseName) -or $Stamps[$f.BaseName] -ne $h) { $d.Add($f.BaseName) }
  }
  return $d
}

if ($SelfTest) {
  $f = 0
  function T($m, $c, $g) { if ($c) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $g); $script:f++ } }
  $tmp = Join-Path $env:TEMP ("propagate-selftest-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force $tmp | Out-Null
  try {
    Set-Content (Join-Path $tmp 'a.json') '{"x":1}' -Encoding UTF8
    Set-Content (Join-Path $tmp 'b.json') '{"x":2}' -Encoding UTF8
    $files = @(Get-ChildItem "$tmp\*.json")
    $stamps = @{}
    T 'MUST FIRE  with no stamps, every spec is dirty' ((Get-DirtySlugs $stamps $files).Count -eq 2) 'missed'
    foreach ($x in $files) { $stamps[$x.BaseName] = Get-SpecHash $x.FullName }
    T 'CLEAN TWIN stamped specs are clean' ((Get-DirtySlugs $stamps $files).Count -eq 0) 'spurious dirt'
    # the founding class: an edit AFTER stamping is dirt, byte-precise
    Set-Content (Join-Path $tmp 'a.json') '{"x":1,"y":3}' -Encoding UTF8
    $d = Get-DirtySlugs $stamps @(Get-ChildItem "$tmp\*.json")
    T 'MUST FIRE  an edited spec is dirty again, and ONLY it' ($d.Count -eq 1 -and $d[0] -eq 'a') ($d -join ',')
    # a NEW spec (never stamped) is dirty - the append case cost-recipes once silently dropped
    Set-Content (Join-Path $tmp 'c.json') '{"x":9}' -Encoding UTF8
    $d2 = Get-DirtySlugs $stamps @(Get-ChildItem "$tmp\*.json")
    T 'MUST FIRE  a brand-new spec is dirty (the silent-append class)' ($d2 -contains 'c') ($d2 -join ',')
  } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  if ($f -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $f case(s)"; exit 1 }
}

# ---- live -----------------------------------------------------------------------------------------------
$files = @(Get-ChildItem (Join-Path $mp 'db\recipes\*.json'))
$stamps = @{}
if (Test-Path $stampPath) {
  $o = Get-Content $stampPath -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($p in $o.PSObject.Properties) { $stamps[$p.Name] = [string]$p.Value }
}

if ($Baseline) {
  foreach ($x in $files) { $stamps[$x.BaseName] = Get-SpecHash $x.FullName }
  ($stamps | ConvertTo-Json -Depth 3) | Out-File $stampPath -Encoding utf8
  Write-Output ("propagate baseline stamped for {0} spec(s) - use this ONLY on a catalog independently verified in sync" -f $files.Count)
  exit 0
}

$dirty = @(Get-DirtySlugs $stamps $files)
Write-Output ("propagate: {0} dirty spec(s) of {1}" -f $dirty.Count, $files.Count)
if ($DryRun) { $dirty | Select-Object -First 30 | ForEach-Object { Write-Output ("  " + $_) }; exit 0 }
if (-not $dirty.Count) { Write-Output 'nothing to propagate'; exit 0 }

# each stage runs as a child so its exit code is its verdict; a failure stops the chain BEFORE the stamp.
function Invoke-Stage { param([string]$Label, [scriptblock]$Run)
  Write-Output ("-- " + $Label)
  & $Run
  if ($LASTEXITCODE -ne 0) { throw ("propagate: stage '{0}' failed (rc={1}) - stamps NOT advanced, the next run retries" -f $Label, $LASTEXITCODE) }
}

Invoke-Stage 'sync-recipesdb-buy' { & powershell -ExecutionPolicy Bypass -File (Join-Path $here 'sync-recipesdb-buy.ps1') -Apply | Select-Object -Last 1 }
Invoke-Stage 'audit-db-agreement (hard gate)' { & powershell -ExecutionPolicy Bypass -File (Join-Path $mp 'engine\audit-db-agreement.ps1') | Select-Object -Last 1 }
Invoke-Stage 'gen-planner-data' { & powershell -ExecutionPolicy Bypass -File (Join-Path $mp 'gen-planner-data.ps1') | Select-Object -Last 1 }
# -Slugs IN-PROCESS for build/publish (engine\README: `powershell -File` marshals an array as one string)
Write-Output '-- build-cards (dirty slugs)'
Push-Location $mp
try {
  & '.\engine\build-cards.ps1' -Slugs $dirty | Select-Object -Last 1
  if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw 'propagate: build-cards failed - stamps NOT advanced' }
  Write-Output '-- publish (dirty slugs; hash-gated)'
  $pubOut = & '.\engine\publish.ps1' -Slugs $dirty
  $pubOut | Select-Object -Last 1
  if (@($pubOut | Where-Object { $_ -match 'published\+verified OK' }).Count -eq 0) { throw 'propagate: publish did not report its verified-OK line - stamps NOT advanced' }
} finally { Pop-Location }

# stamps advance ONLY here, after every stage above succeeded.
foreach ($x in $files) { if ($dirty -contains $x.BaseName) { $stamps[$x.BaseName] = Get-SpecHash $x.FullName } }
($stamps | ConvertTo-Json -Depth 3) | Out-File $stampPath -Encoding utf8
Write-Output ("propagate COMPLETE: {0} spec(s) carried through recipes-db, planner, cards and publish; stamps advanced" -f $dirty.Count)
exit 0
