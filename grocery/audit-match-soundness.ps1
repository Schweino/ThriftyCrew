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
  [switch]$ForceAccept,
  # -SelfTest: this guard had NONE until 2026-09-05, which is why the drift check could count seven
  # disagreements and name none of them for a whole day without anything noticing.
  [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
# Alerts go out through Send-Alert (alert-lib.ps1), never as `powershell -File send-alert.ps1 -Body $long`:
# Windows refuses to start a process whose command line passes 32767 chars, so an oversized body did not
# arrive truncated - it did not arrive at all, and the launch error read like the CHECK had crashed. Three
# consecutive guard-blind days went unpaged that way on 2026-08-03/04/05. See alert-lib.ps1.
. (Join-Path $root 'alert-lib.ps1')

function Get-DriftRows {
  <#
    WHERE THIS MATCHER AND THE ENGINE DISAGREE, BY NAME - not just how many.

    Pure, and a parameter rather than a file read, so the rule can be driven by a fixture instead of
    by whatever candidates-*.json happens to be on disk. It was inline and counted only: on
    2026-09-05 it reported "matcher disagrees with the engine on 7 products - investigate" and gave
    the reader nothing to investigate WITH, and naming them from outside would have meant a second
    copy of Get-Eligible, which is the rule this estate keeps in exactly one file.

    `<unmatched>` counts as a disagreement on purpose: a product the engine assigned to a commodity
    and this matcher now assigns to nothing is precisely the rule improvement (or regression) worth
    seeing - all seven on 2026-09-05 were that shape, and all seven were the matcher being RIGHT
    against a candidates file from the previous board week.
  #>
  param($Names, $Commodities)
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($cm in @($Commodities)) {
    foreach ($cd in @($cm.candidates)) {
      $nm = [string]$cd.name
      if ($Names.ContainsKey($nm) -and [string]$Names[$nm] -ne [string]$cm.id) {
        $out.Add([pscustomobject]@{ name = $nm; engine = [string]$cm.id; matcher = [string]$Names[$nm] })
      }
    }
  }
  return $out
}

if ($SelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  $names = @{ 'Honey Boy Pink Salmon' = 'canned-salmon'; 'Sue Bee Honey' = 'honey'
              'Steak Tips With Gravy' = '<unmatched>' }
  $cands = @(
    [pscustomobject]@{ id = 'honey'; candidates = @(
      [pscustomobject]@{ name = 'Honey Boy Pink Salmon' }, [pscustomobject]@{ name = 'Sue Bee Honey' }) },
    [pscustomobject]@{ id = 'jarred-gravy'; candidates = @(
      [pscustomobject]@{ name = 'Steak Tips With Gravy' }) })
  $rows = Get-DriftRows $names $cands
  T 'MUST FIRE  a drift is NAMED, with both opinions - the count alone is what made 7 uninvestigable' `
    (@($rows).Count -eq 2 -and (@($rows | Where-Object { $_.name -eq 'Honey Boy Pink Salmon' -and $_.engine -eq 'honey' -and $_.matcher -eq 'canned-salmon' }).Count -eq 1)) `
    (($rows | ForEach-Object { $_.name + ':' + $_.engine + '->' + $_.matcher }) -join ' | ')
  T 'MUST FIRE  a product the matcher now leaves UNMATCHED is a disagreement, not a pass - that is the rule-improvement shape, and all 7 on 2026-09-05 were it' `
    (@($rows | Where-Object { $_.matcher -eq '<unmatched>' }).Count -eq 1) `
    (($rows | ForEach-Object { $_.matcher }) -join ',')
  T 'CLEAN TWIN a product both sides agree on is NOT reported' `
    (@($rows | Where-Object { $_.name -eq 'Sue Bee Honey' }).Count -eq 0) 'agreed product was reported as drift'
  T 'CLEAN TWIN a product the engine names that this matcher never saw is not a disagreement - it is silence, and silence is not evidence' `
    ((Get-DriftRows @{} $cands).Count -eq 0) 'an unseen product counted as drift'
  T 'MUST FIRE  the report and the console both carry the NAMES, not just the count' `
    (((Get-Content $PSCommandPath -Raw) -match ('drift_' + 'products')) -and ((Get-Content $PSCommandPath -Raw) -match ('DRIFT    engine says'))) `
    'the names are collected and then never rendered'
  if ($bad -eq 0) { Write-Output 'match-soundness SELF-TEST PASS'; exit 0 }
  Write-Output ("match-soundness SELF-TEST FAIL: $bad case(s)"); exit 2
}

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
# The FEED SELECTION happens once, here, and is the SINGLE source of truth for both the sweep below and the
# fingerprint that guards it. Deriving the hash from a second, hand-maintained file list is exactly how a
# cache key silently stops covering an input it is supposed to cover.
$feedFiles = New-Object System.Collections.Generic.List[object]
Get-ChildItem (Join-Path $OutDir 'regular\*.json') -EA SilentlyContinue | Group-Object { ($_.BaseName -replace '-regular-.*$', '') } | ForEach-Object {
  [void]$feedFiles.Add(($_.Group | Sort-Object Name -Descending | Select-Object -First 1))
}
$adsF = Get-ChildItem (Join-Path $OutDir 'ads-*.json') -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if ($adsF) { [void]$feedFiles.Add($adsF) }
foreach ($pat in @('bakers\bakers-deals-*.json', 'sams\sams-deals-*.json', 'fareway\fareway-deals-*.json')) {
  $df = Get-ChildItem (Join-Path $OutDir $pat) -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  if ($df) { [void]$feedFiles.Add($df) }
}

# ---- INPUT FINGERPRINT ----------------------------------------------------------------------------------
# The Ingest sweep below is 97% of this script's runtime (measured 2026-07-30: 51.5s of a 53.0s run) and it is
# a PURE FUNCTION of a closed input set, so re-deriving it on byte-identical inputs is wasted wall clock in
# the publish critical path - and this script is the gate the agent waits on to learn whether publish HOLDs.
# The hash covers every file that can change $names/$contest:
#   * THIS SCRIPT and the lib it dot-sources. A cache keyed on data but not on code is a gate that can never
#     arm after a logic change: edit the matcher, get yesterday's answer back.
#   * commodities.json and compare-deals.ps1. Only the $GLOBAL_EXCLUDE block of compare-deals is parsed, but
#     the WHOLE file is hashed: over-keying costs at most an extra miss, under-keying returns a WRONG answer.
#   * every feed file actually selected above (not a re-listed guess at them).
# Deliberately NOT in the key, because they are never served from cache: candidates-*.json (the self-check
# below always re-runs live, so the matcher-vs-engine assertion can never be skipped) and match-baseline.json
# + verify-verdicts-*.json (the baseline diff and the -Accept verdict gate always run live).
$msCacheF = Join-Path $audDir 'match-sweep-cache.json'
$fpFiles = New-Object System.Collections.Generic.List[string]
$selfF = if ($PSCommandPath) { $PSCommandPath } else { Join-Path $root 'audit-match-soundness.ps1' }
foreach ($sf in @($selfF, (Join-Path $root 'verdict-lib.ps1'), (Join-Path $root 'commodities.json'), (Join-Path $root 'compare-deals.ps1'))) { [void]$fpFiles.Add([string]$sf) }
foreach ($ffi in $feedFiles) { [void]$fpFiles.Add([string]$ffi.FullName) }
$fp = ''
try {
  $fpSha = [Security.Cryptography.SHA1]::Create()
  $fpAcc = New-Object Text.StringBuilder
  foreach ($fpp in ($fpFiles | Sort-Object)) {
    $fps = [IO.File]::OpenRead($fpp); try { $fph = $fpSha.ComputeHash($fps) } finally { $fps.Dispose() }
    [void]$fpAcc.Append($fpp).Append('=').Append([BitConverter]::ToString($fph).Replace('-', '')).Append(';')
  }
  $fp = [BitConverter]::ToString($fpSha.ComputeHash([Text.Encoding]::UTF8.GetBytes($fpAcc.ToString()))).Replace('-', '')
} catch { $fp = '' }   # could not hash an input => cannot prove it unchanged => no cache, run the real sweep

# CACHE READ. Skipped entirely for -Accept/-ForceAccept: those WRITE the baseline out of $names and a wrong
# $names there is permanent and invisible afterwards. Any doubt at all - no stamp, unreadable stamp, a stamp
# whose '' parses to $null WITHOUT throwing, a count that does not survive the round trip - falls through to
# the real sweep, because a skip that cannot prove its inputs are unchanged must run the real thing.
$msHit = $false
if ($fp -and -not $Accept -and -not $ForceAccept -and (Test-Path $msCacheF)) {
  try {
    $cj = ConvertFrom-Json ([IO.File]::ReadAllText($msCacheF))
    if ($cj -and ([string]$cj.fp) -eq $fp -and ([int]$cj.count) -gt 0) {
      $nk = @($cj.names_k); $nv = @($cj.names_v); $ck = @($cj.contest_k); $cv = @($cj.contest_v)
      if ($nk.Count -eq ([int]$cj.count) -and $nv.Count -eq $nk.Count -and $ck.Count -eq $cv.Count) {
        for ($i = 0; $i -lt $nk.Count; $i++) { $names[[string]$nk[$i]] = [string]$nv[$i] }
        for ($i = 0; $i -lt $ck.Count; $i++) { $contest[[string]$ck[$i]] = [string]$cv[$i] }
        # names are stored as PARALLEL ARRAYS, never as JSON object keys: PSObject property names are
        # case-INSENSITIVE, so two products differing only in case would silently merge on reload. The count
        # check below is the belt to that braces - a map that did not survive the round trip is discarded.
        if ($names.Count -eq ([int]$cj.count) -and $contest.Count -eq $ck.Count) { $msHit = $true }
      }
    }
  } catch { }
  if (-not $msHit) { $names = @{}; $contest = @{} }
}

if (-not $msHit) {
  foreach ($ffr in $feedFiles) { foreach ($d in (ConvertFrom-Json ([IO.File]::ReadAllText($ffr.FullName))).deals) { Ingest ([string]$d.item) } }
  # Never cache an EMPTY sweep. A stamp saying "0 products, all clear" would let a run that read nothing be
  # served back forever as a clean bill of health.
  if ($fp -and $names.Count -gt 0 -and -not $Accept -and -not $ForceAccept) {
    try {
      $nkL = New-Object System.Collections.Generic.List[string]; $nvL = New-Object System.Collections.Generic.List[string]
      foreach ($kv in $names.GetEnumerator()) { [void]$nkL.Add([string]$kv.Key); [void]$nvL.Add([string]$kv.Value) }
      $ckL = New-Object System.Collections.Generic.List[string]; $cvL = New-Object System.Collections.Generic.List[string]
      foreach ($kv in $contest.GetEnumerator()) { [void]$ckL.Add([string]$kv.Key); [void]$cvL.Add([string]$kv.Value) }
      Set-Content $msCacheF -Value ([ordered]@{ fp = $fp; count = $names.Count; names_k = $nkL.ToArray(); names_v = $nvL.ToArray(); contest_k = $ckL.ToArray(); contest_v = $cvL.ToArray() } | ConvertTo-Json -Depth 4 -Compress) -Encoding UTF8
    } catch { }
  }
}

# ---- SELF-CHECK: matcher vs the engine's candidates (must be 0 disagreements) ----
$drift = 0
# NAME THEM, DO NOT JUST COUNT THEM (2026-09-05). This check counted disagreements and then told the
# reader to "investigate compare-deals vs commodities.json" without saying WHICH products - so the one
# thing needed to investigate was the one thing it withheld. On 2026-09-05 it reported 7 and nobody
# could act on it: naming them from outside would mean a second copy of Get-Eligible, which is the
# rule this estate deliberately keeps in one file. The count is unchanged; only the legibility is.
$driftRows = New-Object System.Collections.Generic.List[object]
try {
  $candF = Get-ChildItem (Join-Path $OutDir 'candidates-*.json') | Sort-Object Name -Descending | Select-Object -First 1
  if ($candF) {
    # WRAPPED AT THE CALL SITE. PowerShell unrolls a List returned from a function, so a single-row
    # result arrives as a bare PSCustomObject and .Count/.ToArray() are gone. Assign then wrap.
    $driftRows = @(Get-DriftRows $names @((ConvertFrom-Json ([IO.File]::ReadAllText($candF.FullName))).commodities))
    $drift = $driftRows.Count
  }
} catch {}

# ---- BLIND GUARD: a check that examined NOTHING must say so ----------------------------------------------
# With every feed missing this script used to print "MOVED=0  DROPPED=0" and exit 0 - a clean bill of health
# over zero products - because the report loop only walks names it actually ingested. Worse, -Accept in that
# state rewrote the baseline as an EMPTY map (measured 2026-07-30: 18,123 names / 1.70 MB -> 0 names / 129
# bytes, "baseline ACCEPTED (0 product names)", exit 0). match-baseline.json is a TRACKED file, so that empty
# map commits, and every later run diffs against nothing and reports all-clear forever.
# Exit 3 is the estate's could-not-evaluate code. On today's real inputs $names.Count is 18,123, so this can
# only fire on a genuinely empty read - no cry-wolf on a healthy run.
if ($names.Count -eq 0) {
  Write-Output 'match-soundness: BLIND - ZERO products were ingested, so nothing this run proves about any commodity matching. This is NOT a clean board: check out\regular\, out\ads-*.json and the per-store deals files.'
  if ($Accept -or $ForceAccept) { Write-Output 'ACCEPT REFUSED - baselining an empty sweep would erase the reviewed baseline and blind this audit permanently.' }
  exit 3
}

# ---- ACCEPT: write current as baseline ----
if ($Accept -or $ForceAccept) {
  # ---- THE VERDICT GATE: -Accept must not bless a mapping a DROP verdict already rejected ----
  # -Accept snapshots name -> commodity wholesale, and everything in the snapshot becomes invisible to this
  # audit forever after (it is a CHANGE detector). So one careless accept converts "judged wrong last week"
  # into "reviewed and correct". That happened: bacon/Sam's and broccoli/Sam's were dropped by the verify pass
  # in THREE separate weeks, got baselined anyway, and sailed through publish as crowns on 2026-07-29.
  #
  # WHICH ITEM a verdict judged comes from Get-VerdictIdentity in verdict-lib: the entry's own 'item' field
  # first, the name quoted in its reason only as a fallback. This gate used to read the quote ONLY, and that
  # premise expired on 2026-08-05 when verdict files started carrying a structured item field:
  #  * FALSE BLOCK - the 2026-08-15 garlic verdict judged 'Marketside Tandoori Style Garlic Naan Bites,
  #    7.05 oz, 15 Count' while its reason quotes the flavour word 'Garlic'. Key garlic|garlic resolved to
  #    Aldi's real Garlic and this gate refused -Accept naming an innocent product (and, from the verdict's
  #    own store field, the wrong store). A false block is how people learn to reach for -ForceAccept.
  #  * SILENT UNDER-BLOCK - a quote can capture a SIZE ('169 FL OZ') or a reordered name ('red butter
  #    lettuce' vs the feed's 'Lettuce Red Butter'), matching no feed name at all, so a reviewed DROP was
  #    never enforced and nothing said so.
  # Two hard-won details survive in the fallback:
  #  * The closing quote is only a closing quote when followed by space/punctuation/end. Product names carry
  #    apostrophes ("Member's Mark ..."), and a naive [^']+ capture truncates at the possessive - which fails
  #    SILENT (the truncated name matches nothing, the drop is skipped, the gate under-blocks on exactly the
  #    Member's Mark rows the founding bug was about).
  #  * Matching is on a NORMALISED name (lowercase, alphanumerics only), because the feed and the reason
  #    spell the same product with and without commas ("Pinto Beans, 12 lbs." vs "Pinto Beans 12 lbs.").
  # A verdict with NO identity at all (no item field, no recoverable quote - 352 of 407 stored entries, all
  # pre-2026-08-05) is skipped rather than guessed at.
  # LATEST WORD WINS: files are walked oldest -> newest, so a later verdict on the same (commodity, item)
  # overrides an earlier one - a drop that was re-reviewed and kept stops blocking.
  # Normalisation + quote recovery live in verdict-lib.ps1, SHARED with verify-apply's suppression logic.
  # Both must agree on what "the same item" means, or a product suppressed by one is invisible to the other.
  . (Join-Path $root 'verdict-lib.ps1')
  function NormName2([string]$s) { return (Get-VerdictNorm $s) }
  $verdictByKey = @{}   # "<commodity>|<normalised item>" -> latest verdict info
  foreach ($vf in (Get-ChildItem (Join-Path $OutDir 'verify-verdicts-*.json') -EA SilentlyContinue | Sort-Object Name)) {
    try { $vj = ConvertFrom-Json ([IO.File]::ReadAllText($vf.FullName)) } catch { continue }
    foreach ($vc in @($vj.verdicts)) {
      foreach ($ve in @($vc.entries)) {
        $vident = Get-VerdictIdentity $ve
        if (-not $vident) { continue }
        $vkey = ([string]$vc.id) + '|' + (NormName2 $vident)
        $verdictByKey[$vkey] = @{ keep = ($ve.keep -ne $false); week = [string]$vj.week_of; store = [string]$ve.store; judged = $vident }
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
    Write-GuardComplete -Name 'match-soundness'; exit 2
  }
  if ($blocked.Count -gt 0) {
    Write-Output ("match-soundness: FORCE-ACCEPT overriding $($blocked.Count) outstanding DROP verdict(s):")
    foreach ($b in ($blocked | Sort-Object commodity)) { Write-Output ("  [{0}] '{1}'  (dropped {2}, {3})" -f $b.commodity, $b.item, $b.week, $b.store) }
  }
  $obj = [ordered]@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); names = $names; contested = @($contest.Keys | Sort-Object) }
  Set-Content $baseF -Value ($obj | ConvertTo-Json -Depth 4) -Encoding UTF8
  Write-Output ("match-soundness: baseline ACCEPTED ($($names.Count) product names, $($contest.Count) contested). drift-vs-engine=$drift")
  Write-GuardComplete -Name 'match-soundness'; exit 0
}

if (-not (Test-Path $baseF)) { Write-Output 'match-soundness: NO baseline yet - run with -Accept to establish one. (skipping gate)'; Write-GuardComplete -Name 'match-soundness'; exit 0 }
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

$report = [ordered]@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); drift_vs_engine = $drift; drift_products = $driftRows; moved = $moved; dropped = $dropped; new_contested = $newContest }
Set-Content (Join-Path $audDir 'soundness-report.json') -Value ($report | ConvertTo-Json -Depth 4) -Encoding UTF8

$regr = $moved.Count + $dropped.Count
Write-Output ("match-soundness: MOVED=$($moved.Count)  DROPPED=$($dropped.Count)  new-contested=$($newContest.Count)  drift-vs-engine=$drift")
if ($drift -gt 0) {
  Write-Output ("  WARNING: matcher disagrees with the engine on $drift products - this guard may be stale; investigate compare-deals vs commodities.json.")
  foreach ($dr in ($driftRows | Select-Object -First 25)) { Write-Output ("  DRIFT    engine says $($dr.engine)  /  this matcher says $($dr.matcher)   '$($dr.name)'") }
  if ($driftRows.Count -gt 25) { Write-Output ("  ...and $($driftRows.Count - 25) more, all of them in out\audit\soundness-report.json") }
}
foreach ($d in $dropped) { Write-Output ("  DROPPED  $($d.from)  ->  <unmatched>   '$($d.name)'") }
foreach ($mv in $moved)  { Write-Output ("  MOVED    $($mv.from) -> $($mv.to)   '$($mv.name)'") }
if ($newContest.Count) { Write-Output ("  new-contested (order-dependence to review): " + (($newContest | Select-Object -First 25) -join ' | ')) }

if ($Alert -and ($regr -gt 0 -or $newContest.Count -gt 0 -or $drift -gt 0)) {
  $sig = ([string]$drift + '|' + (($dropped | ForEach-Object { $_.name }) -join ';') + '|' + (($moved | ForEach-Object { $_.name }) -join ';') + '|' + ($newContest -join ';'))
  $sigHash = [BitConverter]::ToString((New-Object Security.Cryptography.SHA256Managed).ComputeHash([Text.Encoding]::UTF8.GetBytes($sig))).Replace('-', '').Substring(0, 16)
  $sigF = Join-Path $audDir 'soundness-alert-sig.txt'
  $last = if (Test-Path $sigF) { (Get-Content $sigF -Raw).Trim() } else { '' }
  if ($sigHash -ne $last) {
    $body = "Matching soundness found changes:`nMOVED=$($moved.Count) DROPPED=$($dropped.Count) new-contested=$($newContest.Count) drift=$drift`n`n" + (($dropped | ForEach-Object { "DROPPED $($_.from): $($_.name)" }) -join "`n") + "`n" + (($moved | ForEach-Object { "MOVED $($_.from)->$($_.to): $($_.name)" }) -join "`n") + "`n" + (($driftRows | Select-Object -First 25 | ForEach-Object { "DRIFT engine=$($_.engine) matcher=$($_.matcher): $($_.name)" }) -join "`n") + "`nReview, then accept with: audit-match-soundness.ps1 -Accept"
    try { Send-Alert -Subject "Grocery matching soundness - review needed" -Body $body | Out-Null; Set-Content $sigF -Value $sigHash -Encoding UTF8 } catch {}
  }
}
# regressions (moved/dropped of an existing product) HOLD the publish until reviewed+accepted
if ($regr -gt 0) { Write-GuardComplete -Name 'match-soundness'; exit 2 } else { Write-GuardComplete -Name 'match-soundness'; exit 0 }
