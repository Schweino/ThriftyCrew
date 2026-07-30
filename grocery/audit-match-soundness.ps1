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
param([switch]$Accept, [switch]$Alert, [string]$OutDir = "",
  # -ForceAccept: bless the baseline EVEN OVER outstanding DROP verdicts. The gate below exists because
  # -Accept used to be a rubber stamp: on 2026-07-29 it baselined "Smithfield ... Pork Loin Filet -> bacon"
  # and "Member's Mark Broccoli Normandy -> broccoli" AFTER the verify pass had already rejected both, which
  # made them permanently invisible to this audit - and they published as crowns. Forcing must be a loud,
  # deliberate act, never the default.
  [switch]$ForceAccept)
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
if ($Accept -or $ForceAccept) {
  # ---- THE VERDICT GATE: -Accept must not bless a mapping a DROP verdict already rejected ----
  # -Accept snapshots name -> commodity wholesale, and everything in the snapshot becomes invisible to this
  # audit forever after (it is a CHANGE detector). So one careless accept converts "judged wrong last week"
  # into "reviewed and correct". That happened: bacon/Sam's and broccoli/Sam's were dropped by the verify pass
  # in THREE separate weeks, got baselined anyway, and sailed through publish as crowns on 2026-07-29.
  #
  # A verdict names (commodity, store) but NOT the item - the judged item has to be recovered from the quote
  # inside the reason text. Two hard-won details in that recovery:
  #  * The closing quote is only a closing quote when followed by space/punctuation/end. Product names carry
  #    apostrophes ("Member's Mark ..."), and a naive [^']+ capture truncates at the possessive - which fails
  #    SILENT (the truncated name matches nothing, the drop is skipped, the gate under-blocks on exactly the
  #    Member's Mark rows the founding bug was about).
  #  * Matching is on a NORMALISED name (lowercase, alphanumerics only), because the feed and the reason
  #    spell the same product with and without commas ("Pinto Beans, 12 lbs." vs "Pinto Beans 12 lbs.").
  # A drop with NO recoverable quote is skipped rather than guessed at: this gate blocks a human action, so a
  # false block teaches people to reach for -ForceAccept, which un-teaches the whole gate.
  # LATEST WORD WINS: files are walked oldest -> newest, so a later verdict on the same (commodity, item)
  # overrides an earlier one - a drop that was re-reviewed and kept stops blocking.
  $q1 = [char]0x0027; $q2 = [char]0x2018; $q3 = [char]0x2019; $q4 = [char]0x201C; $q5 = [char]0x201D
  $quotePat = "[$q1$q2$q4](.{6,}?)[$q1$q3$q5](?=\s|$|[,.;:!?)\]])"
  function NormName2([string]$s) { return (($s.ToLower() -replace '[^a-z0-9]+', ' ').Trim()) }
  $verdictByKey = @{}   # "<commodity>|<normalised item>" -> latest verdict info
  foreach ($vf in (Get-ChildItem (Join-Path $OutDir 'verify-verdicts-*.json') -EA SilentlyContinue | Sort-Object Name)) {
    try { $vj = ConvertFrom-Json ([IO.File]::ReadAllText($vf.FullName)) } catch { continue }
    foreach ($vc in @($vj.verdicts)) {
      foreach ($ve in @($vc.entries)) {
        $qm = [regex]::Match([string]$ve.reason, $quotePat)
        if (-not $qm.Success) { continue }
        $vkey = ([string]$vc.id) + '|' + (NormName2 $qm.Groups[1].Value)
        $verdictByKey[$vkey] = @{ keep = ($ve.keep -ne $false); week = [string]$vj.week_of; store = [string]$ve.store; judged = $qm.Groups[1].Value }
      }
    }
  }
  $normToNames = @{}
  foreach ($nk in $names.Keys) {
    $nn = NormName2 $nk
    if (-not $normToNames.ContainsKey($nn)) { $normToNames[$nn] = New-Object System.Collections.ArrayList }
    [void]$normToNames[$nn].Add($nk)
  }
  $blocked = New-Object System.Collections.ArrayList
  foreach ($kv in $verdictByKey.GetEnumerator()) {
    if ($kv.Value.keep) { continue }
    $vid, $nitem = $kv.Key -split '\|', 2
    if (-not $normToNames.ContainsKey($nitem)) { continue }         # product gone from every feed
    foreach ($actual in $normToNames[$nitem]) {
      # outstanding = the judged item STILL maps to the very commodity it was dropped from. If the rules have
      # since moved it elsewhere (or to <unmatched>), the verdict was honoured and there is nothing to block.
      if ([string]$names[$actual] -eq $vid) {
        [void]$blocked.Add([pscustomobject]@{ commodity = $vid; item = $actual; store = $kv.Value.store; week = $kv.Value.week })
      }
    }
  }
  if ($blocked.Count -gt 0 -and -not $ForceAccept) {
    Write-Output ("match-soundness: ACCEPT REFUSED - $($blocked.Count) mapping(s) an outstanding DROP verdict already judged WRONG would be blessed into the baseline and become invisible to this audit:")
    foreach ($b in ($blocked | Sort-Object commodity)) { Write-Output ("  [{0}] '{1}'  (dropped {2}, {3})" -f $b.commodity, $b.item, $b.week, $b.store) }
    Write-Output 'Fix the rules so these products stop matching (add an exclude), or re-review the verdict. If the VERDICT is the thing that is wrong, -ForceAccept overrides - loudly and on your judgment.'
    exit 2
  }
  if ($blocked.Count -gt 0) {
    Write-Output ("match-soundness: FORCE-ACCEPT overriding $($blocked.Count) outstanding DROP verdict(s):")
    foreach ($b in ($blocked | Sort-Object commodity)) { Write-Output ("  [{0}] '{1}'  (dropped {2}, {3})" -f $b.commodity, $b.item, $b.week, $b.store) }
  }
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
