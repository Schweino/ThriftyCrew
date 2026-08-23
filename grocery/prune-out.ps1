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
  # ---- added 2026-08-22 after out\ reached 2.8 GB (the review's item 16) ----------------------------
  # price-history.backup-* : 49 x 14 MB = ~700 MB of a file git already versions on every bot commit
  @{ glob = 'price-history.backup-*.json';       days = 14; min = 5 }
  # one-off experiment dumps from July/August sessions (detA/detB, r300*, clean-base, after-primer,
  # final-batch, cmp-min1, hfbase/hftort, regr-check): 20-26 MB each, read by nothing after their day
  @{ glob = 'det?-candidates-*.json';            days = 7;  min = 0 }
  @{ glob = 'r300*-candidates-*.json';           days = 7;  min = 0 }
  @{ glob = 'clean-base-candidates-*.json';      days = 7;  min = 0 }
  @{ glob = 'after-primer*-candidates-*.json';   days = 7;  min = 0 }
  @{ glob = 'final-batch*-candidates-*.json';    days = 7;  min = 0 }
  @{ glob = 'cmp-min1-candidates-*.json';        days = 7;  min = 0 }
  @{ glob = 'hf*-candidates-*.json';             days = 7;  min = 0 }
  @{ glob = 'regr-check-candidates-*.json';      days = 7;  min = 0 }
)
# DIRECTORY families are ARCHIVED (moved under out\archive\), never deleted: raw browser capture
# sessions (captures\v2-manual-<date>\, 400+ MB each) are evidence of what a store showed on a day,
# already reduced into out\regular, and read by nothing afterwards - measured 2026-08-22: 824 MB across
# two sessions with zero consumers in the tree. Newest MIN survive in place regardless of age.
$script:DIR_FAMILIES = @(
  @{ glob = 'captures\v2-manual-*';              days = 14; min = 1 }
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
foreach ($fam in $script:DIR_FAMILIES) {
  $dirs = @(Get-ChildItem (Join-Path $OutDir $fam.glob) -Directory -ErrorAction SilentlyContinue)
  if (-not $dirs.Count) { continue }
  $prune = @(Get-PruneList $dirs $today $fam.days $fam.min)
  if (-not $prune.Count) { continue }
  $mb = 0.0
  foreach ($d in $prune) { $mb += [math]::Round(((Get-ChildItem $d.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) / 1MB, 1) }
  $totalFiles += $prune.Count; $totalMB += $mb
  Write-Output ("  {0,-38} archive {1,1} of {2,1} session dir(s), {3,8} MB  (keep {4}d / min {5}) -> archive\" -f $fam.glob, $prune.Count, $dirs.Count, $mb, $fam.days, $fam.min)
  if ($Apply) {
    $arch = Join-Path $OutDir 'archive'
    if (-not (Test-Path $arch)) { New-Item -ItemType Directory -Path $arch -Force | Out-Null }
    foreach ($d in $prune) { Move-Item -Path $d.FullName -Destination (Join-Path $arch $d.Name) -Force -ErrorAction SilentlyContinue }
  }
}
# ---- THE ARCHIVE ITSELF NEEDS A CLOCK (2026-08-23) -------------------------------------------------
# Everything above either deletes on a window or MOVES to outrchive\, and "archived, never deleted"
# was the whole rule. Measured 2026-08-23: 91 MB, 57 files, oldest 2026-07-05, and NOTHING in the estate
# reads it - the one other reference is test-precedence-ladders EXCLUDING it from a robocopy. Most of it
# is not even a retained family: after-wm5-*, vettmp, scratch-out, one-off experiment output archived
# once and forgotten.
#
# "Never" is not a retention policy, it is the absence of one, and it is the same reasoning error in the
# other direction from the one this file exists to fix. So the archive gets the same days/min shape as
# every other family - a QUARTER, matching capture-policy's QuarterDays, which is the longest window
# anything in this estate legitimately looks back over. min = 5 so a quiet archive never erodes to
# nothing, exactly as the file families above.
#
# DELETED here, not moved: this IS the place things get moved to. There is nowhere further to go, and a
# second archive-of-the-archive would just restate the problem one directory deeper.
$ARCHIVE_DAYS = 90; $ARCHIVE_MIN = 5
$archDir = Join-Path $OutDir 'archive'
if (Test-Path $archDir) {
  $archFiles = @(Get-ChildItem $archDir -File -ErrorAction SilentlyContinue)
  if ($archFiles.Count) {
    $prune = @(Get-PruneList $archFiles $today $ARCHIVE_DAYS $ARCHIVE_MIN)
    if ($prune.Count) {
      $mb = [math]::Round((($prune | Measure-Object Length -Sum).Sum) / 1MB, 1)
      $totalFiles += $prune.Count; $totalMB += $mb
      Write-Output ("  {0,-38} prune {1,3} of {2,3} archived file(s), {3,8} MB  (keep {4}d / min {5})" -f 'archive\*', $prune.Count, $archFiles.Count, $mb, $ARCHIVE_DAYS, $ARCHIVE_MIN)
      if ($Apply) { $prune | Remove-Item -Force }
    }
  }
  # Session DIRECTORIES moved here by DIR_FAMILIES above age out on the same clock.
  $archDirs = @(Get-ChildItem $archDir -Directory -ErrorAction SilentlyContinue)
  if ($archDirs.Count) {
    $pruneD = @(Get-PruneList $archDirs $today $ARCHIVE_DAYS $ARCHIVE_MIN)
    if ($pruneD.Count) {
      $mbD = 0.0
      foreach ($d in $pruneD) { $mbD += [math]::Round(((Get-ChildItem $d.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum) / 1MB, 1) }
      $totalFiles += $pruneD.Count; $totalMB += $mbD
      Write-Output ("  {0,-38} prune {1,3} of {2,3} archived session(s), {3,8} MB  (keep {4}d / min {5})" -f 'archive\<session>', $pruneD.Count, $archDirs.Count, $mbD, $ARCHIVE_DAYS, $ARCHIVE_MIN)
      if ($Apply) { foreach ($d in $pruneD) { Remove-Item $d.FullName -Recurse -Force -ErrorAction SilentlyContinue } }
    }
  }
}

Write-Output ("prune-out: {0} file(s), {1} MB{2}" -f $totalFiles, [math]::Round($totalMB, 1), $(if ($Apply) { ' DELETED' } else { ' would be deleted (dry run - pass -Apply)' }))
if ($Apply -and $totalFiles -gt 0) { Write-Output 'now run guards.ps1 + test-auditors.ps1 - a deletion that blinded a watcher must say so TODAY' }
exit 0
