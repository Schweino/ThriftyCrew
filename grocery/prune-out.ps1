# prune-out.ps1 - retention for grocery\out's dated file families. 960 MB and growing, with 18-27
# generations of files whose consumers read at most a few weeks back.
#
# THE DESIGN RULE: a family is only listed here after its READERS were enumerated, and its window is set
# past the deepest historical read found (audit-walmart-fullpull evaluated 18 boards ~3 weeks; the arrivals
# docket and cell-drops walk recent boards; capture-eviction unions dated candidate rows). Directories that
# serve as EVIDENCE for other guards are not listed at all: out\regular\ (regular-fileset-lib walks
# history), out\sams|bakers|fareway\ (compare-deals unions windows; audit-asof-evidence proves as_of dates
# against extracts). When in doubt a family stays unlisted and unpruned - disk is cheaper than a blinded
# guard (the stray-board lesson, in both directions).
#
# Read-only unless -Apply. After an -Apply, run guards.ps1 + test-auditors.ps1: if a deletion blinded a
# watcher, those must say so TODAY, not on the day the watcher mattered.
#
# Usage: .\prune-out.ps1 [-Apply] | -SelfTest
param([switch]$Apply, [switch]$SelfTest, [string]$OutDir = "")
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }

# glob (relative to out\), keep-window in days, and a MINIMUM generation count kept regardless of age -
# so a family that stops being written keeps its newest N forever instead of eroding to nothing.
$script:FAMILIES = @(
  @{ glob = 'comparison-*.json';                 days = 45; min = 20 }
  @{ glob = 'candidates-*.json';                 days = 21; min = 5 }
  @{ glob = 'recipe-sales-candidates-*.json';    days = 21; min = 3 }
  @{ glob = 'ads-*.json';                        days = 30; min = 5 }
  @{ glob = 'product-urls.backup-*.json';        days = 30; min = 5 }
  @{ glob = 'flags-*.json';                      days = 30; min = 5 }
  @{ glob = 'captures\*.csv';                    days = 45; min = 3 }
  @{ glob = 'throttled\*.throttled.json';        days = 21; min = 2 }
)

function Get-PruneList { param($Files, [datetime]$Today, [int]$Days, [int]$Min)
  # newest-first by the DATE IN THE NAME (never mtime - a git checkout rewrites mtimes); undated files in a
  # dated family are skipped entirely rather than guessed at.
  $dated = @()
  foreach ($f in $Files) {
    $m = [regex]::Match($f.Name, '(\d{4}-\d{2}-\d{2})')
    if ($m.Success) { try { $dated += [pscustomobject]@{ File = $f; Date = [datetime]$m.Groups[1].Value } } catch {} }
  }
  $dated = @($dated | Sort-Object Date -Descending)
  $out = @()
  for ($i = 0; $i -lt $dated.Count; $i++) {
    if ($i -lt $Min) { continue }                                  # newest N always survive
    if (($Today - $dated[$i].Date).TotalDays -gt $Days) { $out += $dated[$i].File }
  }
  return $out
}

if ($SelfTest) {
  $f = 0
  function T($m, $c, $g) { if ($c) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $g); $script:f++ } }
  $today = [datetime]'2026-08-08'
  function Fx([string]$n) { [pscustomobject]@{ Name = $n } }
  $files = @((Fx 'comparison-2026-08-07.json'), (Fx 'comparison-2026-07-01.json'), (Fx 'comparison-2026-05-01.json'), (Fx 'comparison-undated.json'))
  $p = @(Get-PruneList $files $today 45 1)
  T 'MUST FIRE  a generation past the window is pruned (05-01 at 45d)' ($p.Count -eq 1 -and $p[0].Name -eq 'comparison-2026-05-01.json') (@($p | ForEach-Object { $_.Name }) -join ',')
  T 'CLEAN TWIN inside-window generations survive'                     (@(Get-PruneList $files $today 45 1 | Where-Object { $_.Name -eq 'comparison-2026-07-01.json' }).Count -eq 0) 'pruned in-window'
  T 'an UNDATED file in a dated family is never touched'               (@(Get-PruneList $files $today 0 0 | Where-Object { $_.Name -eq 'comparison-undated.json' }).Count -eq 0) 'guessed at undated'
  # the erosion case: a family nobody writes anymore keeps its newest N forever
  $old = @((Fx 'x-2026-01-03.json'), (Fx 'x-2026-01-02.json'), (Fx 'x-2026-01-01.json'))
  $p2 = @(Get-PruneList $old $today 45 2)
  T 'MIN-KEEP   a dead family keeps its newest N regardless of age'    ($p2.Count -eq 1 -and $p2[0].Name -eq 'x-2026-01-01.json') (@($p2 | ForEach-Object { $_.Name }) -join ',')
  if ($f -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $f case(s)"; exit 1 }
}

# ---- live -----------------------------------------------------------------------------------------------
$today = (Get-Date).Date
$totalFiles = 0; $totalMB = 0.0
foreach ($fam in $script:FAMILIES) {
  $files = @(Get-ChildItem (Join-Path $OutDir $fam.glob) -File -ErrorAction SilentlyContinue)
  if (-not $files.Count) { continue }
  $prune = @(Get-PruneList $files $today $fam.days $fam.min)
  if (-not $prune.Count) { continue }
  $mb = [math]::Round((($prune | Measure-Object Length -Sum).Sum) / 1MB, 1)
  $totalFiles += $prune.Count; $totalMB += $mb
  Write-Output ("  {0,-38} prune {1,3} of {2,3} generation(s), {3,8} MB  (keep {4}d / min {5})" -f $fam.glob, $prune.Count, $files.Count, $mb, $fam.days, $fam.min)
  if ($Apply) { $prune | Remove-Item -Force }
}
Write-Output ("prune-out: {0} file(s), {1} MB{2}" -f $totalFiles, [math]::Round($totalMB, 1), $(if ($Apply) { ' DELETED' } else { ' would be deleted (dry run - pass -Apply)' }))
if ($Apply -and $totalFiles -gt 0) { Write-Output 'now run guards.ps1 + test-auditors.ps1 - a deletion that blinded a watcher must say so TODAY' }
exit 0
