<#
  audit-match-soundness.ps1 - STANDING guard for the commodity MATCHING logic (the class of bug the
  2026-07-13 audit found: a WRONG product silently landing in a commodity, or a rule change quietly
  moving/dropping an existing product). None of the other guards catch this.

  It rebuilds every store product's commodity assignment with an engine-FAITHFUL replica of
  compare-deals Match-Category, then:
    * REGRESSION: compares to a committed known-good baseline (out\audit\match-baseline.json). Any product
      NAME that used to map to commodity A and now maps to B (MOVED) or to nothing (DROPPED) is a
      rule-change effect a human must review. Exit 2 (so publish HOLDS) if there are un-accepted changes.
    * SOUNDNESS: flags products where >1 commodity's include is eligible (order-dependence / theft risk)
      that are not already in the baseline's reviewed contested list. Advisory.
    * SELF-CHECK: asserts this matcher still agrees with the real engine's candidates-*.json (0
      disagreements). If it drifts, it says so instead of trusting itself.

  Modes:  (default)  report + exit 2 on un-accepted regressions, else 0
          -Accept    bless the CURRENT state as the new baseline (run after an intended rule change)
          -Alert     send-alert.ps1 once per NEW issue-set (signature de-dup) - for the daily pipeline
#>
param([switch]$Accept, [switch]$Alert, [string]$OutDir = "")
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$audDir = Join-Path $OutDir 'audit'
if (-not (Test-Path $audDir)) { New-Item -ItemType Directory -Path $audDir | Out-Null }
$baseF = Join-Path $audDir 'match-baseline.json'

# ---- faithful matcher (mirrors compare-deals Match-Category) ----
$tmp = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $root 'commodities.json'))); $commods = @($tmp)
$cdtxt = [IO.File]::ReadAllText((Join-Path $root 'compare-deals.ps1'))
$m = [regex]::Match($cdtxt, '\$GLOBAL_EXCLUDE = @\((?<b>[\s\S]*?)\r?\n\)')
$GLOBAL = @(); foreach ($line in ($m.Groups['b'].Value -split "`n")) { if ($line -match '^\s*#') { continue }; foreach ($mm in [regex]::Matches($line, "'([^']*)'")) { $GLOBAL += $mm.Groups[1].Value } }
function Get-Eligible([string]$name) {
  $n = $name.ToLower(); $gh = @(); foreach ($g in $GLOBAL) { try { if ($n -match $g) { $gh += $g } } catch {} }
  $elig = @()
  foreach ($c in $commods) {
    $hit = $false; foreach ($inc in $c.include) { try { if ($n -match $inc) { $hit = $true; break } } catch {} }
    if (-not $hit) { continue }
    if ($gh.Count) { $rx = @($c.relax_global | Where-Object { $_ }); $blk = $false; foreach ($g in $gh) { if ($rx -notcontains $g) { $blk = $true; break } }; if ($blk) { continue } }
    $bad = $false; foreach ($e in $c.exclude) { try { if ($n -match $e) { $bad = $true; break } } catch {} }
    if ($bad) { continue }
    $elig += [string]$c.id
  }
  return $elig
}

# ---- gather every raw product (same inputs compare-deals reads) ----
$names = @{}   # name -> commodity ('<unmatched>' if none)
$contest = @{} # name -> "a > b > c" when >1 eligible
function Ingest([string]$item) {
  if (-not $item -or $names.ContainsKey($item)) { return }
  $e = @(Get-Eligible $item)   # @() forces array: a single-eligible result must NOT unroll to a scalar string (then $e[0] would be its first CHARACTER)
  $names[$item] = if ($e.Count) { [string]$e[0] } else { '<unmatched>' }
  if ($e.Count -gt 1) { $contest[$item] = ($e -join ' > ') }
}
Get-ChildItem (Join-Path $OutDir 'regular\*.json') -EA SilentlyContinue | Group-Object { ($_.BaseName -replace '-regular-.*$', '') } | ForEach-Object {
  $f = ($_.Group | Sort-Object Name -Descending | Select-Object -First 1)
  foreach ($d in (ConvertFrom-Json ([IO.File]::ReadAllText($f.FullName))).deals) { Ingest ([string]$d.item) }
}
$adsF = Get-ChildItem (Join-Path $OutDir 'ads-*.json') -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if ($adsF) { foreach ($d in (ConvertFrom-Json ([IO.File]::ReadAllText($adsF.FullName))).deals) { Ingest ([string]$d.item) } }
foreach ($g in @('bakers\bakers-deals-*.json', 'sams\sams-deals-*.json', 'fareway\fareway-deals-*.json')) {
  $f = Get-ChildItem (Join-Path $OutDir $g) -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  if ($f) { foreach ($d in (ConvertFrom-Json ([IO.File]::ReadAllText($f.FullName))).deals) { Ingest ([string]$d.item) } }
}

# ---- SELF-CHECK: matcher vs the engine's candidates (must be 0 disagreements) ----
$drift = 0
try {
  $candF = Get-ChildItem (Join-Path $OutDir 'candidates-*.json') | Sort-Object Name -Descending | Select-Object -First 1
  if ($candF) { foreach ($cm in @((ConvertFrom-Json ([IO.File]::ReadAllText($candF.FullName))).commodities)) { foreach ($cd in @($cm.candidates)) { $nm = [string]$cd.name; if ($names.ContainsKey($nm) -and $names[$nm] -ne [string]$cm.id) { $drift++ } } } }
} catch {}

# ---- ACCEPT: write current as baseline ----
if ($Accept) {
  $obj = [ordered]@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); names = $names; contested = @($contest.Keys | Sort-Object) }
  Set-Content $baseF -Value ($obj | ConvertTo-Json -Depth 4) -Encoding UTF8
  Write-Output ("match-soundness: baseline ACCEPTED ($($names.Count) product names, $($contest.Count) contested). drift-vs-engine=$drift")
  exit 0
}

if (-not (Test-Path $baseF)) { Write-Output 'match-soundness: NO baseline yet - run with -Accept to establish one. (skipping gate)'; exit 0 }
$base = ConvertFrom-Json ([IO.File]::ReadAllText($baseF))
$baseNames = @{}; foreach ($p in $base.names.PSObject.Properties) { $baseNames[$p.Name] = [string]$p.Value }
$baseContest = @{}; foreach ($x in @($base.contested)) { $baseContest[[string]$x] = $true }

$moved = New-Object System.Collections.Generic.List[object]
$dropped = New-Object System.Collections.Generic.List[object]
foreach ($nm in $baseNames.Keys) {
  if (-not $names.ContainsKey($nm)) { continue }   # product no longer pulled this week - not a regression
  $b = $baseNames[$nm]; $a = $names[$nm]
  if ($b -eq $a) { continue }
  if ($a -eq '<unmatched>') { $dropped.Add([pscustomobject]@{ name = $nm; from = $b }) }
  elseif ($b -ne '<unmatched>') { $moved.Add([pscustomobject]@{ name = $nm; from = $b; to = $a }) }
}
$newContest = @($contest.Keys | Where-Object { -not $baseContest.ContainsKey($_) } | Sort-Object)

$report = [ordered]@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); drift_vs_engine = $drift; moved = $moved; dropped = $dropped; new_contested = $newContest }
Set-Content (Join-Path $audDir 'soundness-report.json') -Value ($report | ConvertTo-Json -Depth 4) -Encoding UTF8

$regr = $moved.Count + $dropped.Count
Write-Output ("match-soundness: MOVED=$($moved.Count)  DROPPED=$($dropped.Count)  new-contested=$($newContest.Count)  drift-vs-engine=$drift")
if ($drift -gt 0) { Write-Output ("  WARNING: matcher disagrees with the engine on $drift products - this guard may be stale; investigate compare-deals vs commodities.json.") }
foreach ($d in $dropped) { Write-Output ("  DROPPED  $($d.from)  ->  <unmatched>   '$($d.name)'") }
foreach ($mv in $moved)  { Write-Output ("  MOVED    $($mv.from) -> $($mv.to)   '$($mv.name)'") }
if ($newContest.Count) { Write-Output ("  new-contested (order-dependence to review): " + (($newContest | Select-Object -First 25) -join ' | ')) }

if ($Alert -and ($regr -gt 0 -or $newContest.Count -gt 0 -or $drift -gt 0)) {
  $sig = ([string]$drift + '|' + (($dropped | ForEach-Object { $_.name }) -join ';') + '|' + (($moved | ForEach-Object { $_.name }) -join ';') + '|' + ($newContest -join ';'))
  $sigHash = [BitConverter]::ToString((New-Object Security.Cryptography.SHA256Managed).ComputeHash([Text.Encoding]::UTF8.GetBytes($sig))).Replace('-', '').Substring(0, 16)
  $sigF = Join-Path $audDir 'soundness-alert-sig.txt'
  $last = if (Test-Path $sigF) { (Get-Content $sigF -Raw).Trim() } else { '' }
  if ($sigHash -ne $last) {
    $body = "Matching soundness found changes:`nMOVED=$($moved.Count) DROPPED=$($dropped.Count) new-contested=$($newContest.Count) drift=$drift`n`n" + (($dropped | ForEach-Object { "DROPPED $($_.from): $($_.name)" }) -join "`n") + "`n" + (($moved | ForEach-Object { "MOVED $($_.from)->$($_.to): $($_.name)" }) -join "`n") + "`nReview, then accept with: audit-match-soundness.ps1 -Accept"
    try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject "Grocery matching soundness - review needed" -Body $body | Out-Null; Set-Content $sigF -Value $sigHash -Encoding UTF8 } catch {}
  }
}
# regressions (moved/dropped of an existing product) HOLD the publish until reviewed+accepted
if ($regr -gt 0) { exit 2 } else { exit 0 }
