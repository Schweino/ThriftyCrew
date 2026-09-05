<#
  test-match-lib.ps1 - proves match-lib decides EXACTLY as the original Match-Category, on the real corpus.

  THE CONTRACT. match-lib exists for speed (see its header: 139 of 159 seconds per board build was the
  matcher). Speed bought by a second implementation is worthless the moment the two implementations
  disagree, because which product owns a cell IS the board's correctness. So this does not test
  match-lib against a description of the rule - it runs the ORIGINAL function, extracted verbatim from
  compare-deals.ps1 at test time, side by side with the new one, over every distinct product name the
  engine currently feeds the matcher, and demands the same answer for all of them.

  "Extracted at test time" is the point: if someone edits Match-Category in compare-deals and forgets
  match-lib (or the reverse), this goes red on the next suite run rather than the two drifting for a
  quarter. That is the `two copies of a rule` discipline applied to the one copy that was made on
  purpose.

  THE CORPUS IS NOT NEGOTIABLE. It is every distinct name, and it stays that way. The day the two
  implementations disagree it will be on some odd name - a size suffix, an ampersand, an empty string -
  which is exactly the name a sampled corpus drops. When this file got too slow (2026-08-23: 174 of
  test-auditors' 467 seconds) the answer was to split the WORK, never to shrink the corpus.

  *** AND THE SPLIT HAS TO BE PROCESSES, NOT RUNSPACES. *** Measured 2026-08-23, 3,000 names, the
  original Match-Category pass, run in an in-process runspace pool:
        1 runspace    8.9s CPU      2 runspaces   19.3s      4 runspaces   38.9s
        8 runspaces  79.5s CPU     16 runspaces  215.5s
  Wall clock sat at ~14s for every one of them. That is not sublinear scaling, it is NEGATIVE: the work
  is fully serialised and each extra thread only adds contention. The cause is that the original rule is
  written with PowerShell's `-match` and `-replace` operators, which call the STATIC Regex methods, and
  in .NET Framework every static Regex call goes through one process-wide pattern cache behind one lock.
  Sixteen threads in one process therefore queue on that lock forever. Sixteen PROCESSES each have their
  own cache and their own lock, and actually run at once. Anyone tempted to "simplify" this back to a
  runspace pool should re-measure first; the numbers above are what that costs.

  Exit 0 = identical on every name. Exit 1 = any divergence (listed). Exit 3 = could not extract the
  original, or a shard could not be run (then nothing is proven and the caller must treat match-lib as
  unverified - a corpus that quietly got smaller is the failure mode this whole file exists against).
#>
param([switch]$Quiet, [int]$MaxNames = 0, [int]$Workers = 0,
      # SHARD MODE - set by the parent on its own children, never by a human. The parent hands over the
      # exact name list it built (so a shard can never be measuring a different corpus than its siblings),
      # the shard takes every ChunkOf'th name from ChunkIx, and writes its verdicts to OutFile as JSON.
      [string]$ChunkFile = '', [int]$ChunkOf = 0, [int]$ChunkIx = -1, [string]$OutFile = '')
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path (Split-Path $root -Parent) 'lib\guard-contract.ps1')
$isShard = [bool]$ChunkFile

# ---- 1. the ORIGINAL, verbatim, from compare-deals.ps1 -------------------------------------------
$src = Get-Content (Join-Path $root 'compare-deals.ps1') -Raw
$a = $src.IndexOf('$GLOBAL_EXCLUDE = @(')
$b = $src.IndexOf('# ---------------------------------------------------------------- -Explain')
if ($a -lt 0 -or $b -lt 0 -or $b -le $a) {
  Write-Output 'match-lib: BLIND - could not locate GLOBAL_EXCLUDE..Match-Category in compare-deals.ps1; nothing proven'
  if (-not $isShard) { Write-GuardComplete -Name 'match-lib' -Summary 'BLIND: extraction failed' }
  exit 3
}
$block = $src.Substring($a, $b - $a)
$block = ($block -split "`n" | Where-Object { $_ -notmatch '\$GEX_OVERRIDE' }) -join "`n"
$commodities = Read-JsonFile (Join-Path $root 'commodities.json')
. ([scriptblock]::Create($block))      # defines $GLOBAL_EXCLUDE, Get-MatchTexts, Match-Category (original)
$origMatch = ${function:Match-Category}
$origTexts = ${function:Get-MatchTexts}

# ---- 2. the NEW one --------------------------------------------------------------------------------
. (Join-Path $root 'match-lib.ps1')    # redefines Get-MatchTexts identically; adds New-CommodityMatcher/Resolve-Commodity
$matcher = New-CommodityMatcher -Commodities $commodities -GlobalExclude $GLOBAL_EXCLUDE

# Get-MatchTexts must be byte-identical too, or the include texts differ before any regex runs.
$t1 = & $origTexts 'Member''s Mark Boneless and Skinless Chicken Breast, priced per pound'
$t2 = Get-MatchTexts 'Member''s Mark Boneless and Skinless Chicken Breast, priced per pound'
if (($t1 -join '|') -ne ($t2 -join '|')) { Write-Output "FAIL  Get-MatchTexts diverged: '$($t1 -join '|')' vs '$($t2 -join '|')'"; if (-not $isShard) { Write-GuardComplete -Name 'match-lib' -Summary 'failed=1 (texts)' }; exit 1 }

# ---- 3. the corpus: every distinct name the engine feeds the matcher today -------------------------
# A SHARD DOES NOT REBUILD THE CORPUS, IT IS HANDED ONE. Rebuilding it per process would be both slower
# and unsound: the capture files underneath are live, so two shards started a second apart could enumerate
# different name sets and the union of their answers would silently cover neither corpus.
if ($isShard) {
  $list = @([string[]](Read-JsonFile $ChunkFile))
} else {
  . (Join-Path $root 'capture-depth-lib.ps1')
  . (Join-Path $root 'regular-fileset-lib.ps1')
  $names = @{}
  $cmp = Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1
  $today = if ($cmp -and $cmp.BaseName -match '(\d{4}-\d{2}-\d{2})$') { [datetime]$Matches[1] } else { Get-Date }
  foreach ($rf in (Select-RegularFileSet (Get-ChildItem (Join-Path $root 'out\regular\*-regular-*.json')) $today (Get-RegularUnionDays))) {
    $ex = Read-JsonFile $rf.FullName
    foreach ($d in $ex.deals) { if ($d.item) { $names[[string]$d.item] = 1 } }
  }
  $adsF = Get-ChildItem (Join-Path $root 'out\ads-*.json') | Sort-Object Name -Descending | Select-Object -First 1
  if ($adsF) { foreach ($d in (Read-JsonFile $adsF.FullName).deals) { if ($d.item) { $names[[string]$d.item] = 1 } } }
  foreach ($f in (Get-ChildItem (Join-Path $root 'out\sams\sams-deals-*.json') -EA SilentlyContinue)) { foreach ($d in (Read-JsonFile $f.FullName).deals) { if ($d.item) { $names[[string]$d.item] = 1 } } }
  foreach ($sub in @('bakers\bakers-deals-*.json', 'fareway\fareway-deals-*.json')) {
    $f = Get-ChildItem (Join-Path $root ('out\' + $sub)) -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if ($f) { foreach ($d in (Read-JsonFile $f.FullName).deals) { if ($d.item) { $names[[string]$d.item] = 1 } } }
  }
  # Adversarial names the corpus may not contain today: the shapes that broke matchers before.
  foreach ($x in @('Hy-Vee butter, 16 oz., $2.48', 'GO2snax Mild Cheddar Cheese & Salami Tray', 'Marketside Tandoori Style Garlic Naan Bites',
                   'Wish-Bone Chunky Blue Cheese Salad Dressing', 'Red Apple Cheese Gruyere Cheese', 'mix & match bagels', 'Chunk Light Tuna in Water 5 oz',
                   'Simple Truth Protein Black Pepper Lentils Brown Rice and Quinoa Blend', 'Fresh Red Cherries, 2.25 lb Bag', '')) { $names[$x] = 1 }
  $list = @($names.Keys)
  if ($MaxNames -gt 0 -and $list.Count -gt $MaxNames) { $list = $list[0..($MaxNames - 1)] }
}

# ---- 3b. SHARD MODE: the four passes over my slice, then hand the verdicts back ---------------------
# Every comparison the single-threaded version made is made here, on a subset of the names: the original,
# the compiled path, the PowerShell fallback, and the detail scan. Matching a name is a pure function of
# (name, catalog) - no shared state, no order dependence, no writes - so which shard evaluates a name
# cannot change its answer. Each verdict carries its GLOBAL index so the parent can restore the exact
# single-threaded reporting order.
if ($isShard) {
  $ix = New-Object System.Collections.Generic.List[int]
  for ($i = $ChunkIx; $i -lt $list.Count; $i += $ChunkOf) { $ix.Add($i) }
  $n = $ix.Count
  $orig = New-Object 'string[]' $n; $new = New-Object 'string[]' $n; $newPs = New-Object 'string[]' $n
  $hasCore = ($null -ne $matcher.core)
  # BOTH paths are proven, separately. The compiled core is what production runs; the PowerShell path is
  # the fallback when Add-Type is unavailable. A harness that only tested "whichever loaded" would leave
  # one of them unverified, and the unverified one is exactly the one that runs on the day something is
  # different about the machine.
  $psOnly = [pscustomobject]@{ gex = $matcher.gex; entries = $matcher.entries; core = $null }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  for ($k = 0; $k -lt $n; $k++) { $c = & $origMatch $list[$ix[$k]]; $orig[$k] = $(if ($c) { [string]$c.id } else { '' }) }
  $tO = $sw.Elapsed.TotalSeconds; $sw.Restart()
  for ($k = 0; $k -lt $n; $k++) { $c = Resolve-Commodity -Matcher $matcher -Name $list[$ix[$k]]; $new[$k] = $(if ($c) { [string]$c.id } else { '' }) }
  $tN = $sw.Elapsed.TotalSeconds; $sw.Restart()
  for ($k = 0; $k -lt $n; $k++) { $c = Resolve-Commodity -Matcher $psOnly -Name $list[$ix[$k]]; $newPs[$k] = $(if ($c) { [string]$c.id } else { '' }) }
  $tP = $sw.Elapsed.TotalSeconds; $sw.Restart()
  # THE DETAIL SCAN MUST AGREE WITH THE ANSWER. Resolve-CommodityDetail is the second scan added for the
  # identity table (PLAN section 10.6): it does not stop at the first winner, so it can also report the
  # contested set. That makes it a THIRD copy of the one rule that decides which product owns a cell - and
  # this file's whole argument is that a second copy is only allowed to exist if it is proven against the
  # first on the real corpus, every suite run. So:
  #   * its winner must be the ORIGINAL Match-Category's answer, on every name;
  #   * a name it says is matched must NAME the include that fired - an empty include_hit would put a blank
  #     provenance line on a board cell, which is worse than none because it reads as "checked".
  $detailDiff = New-Object System.Collections.ArrayList
  $detailNoHit = New-Object System.Collections.ArrayList
  for ($k = 0; $k -lt $n; $k++) {
    $d = Resolve-CommodityDetail -Matcher $matcher -Name $list[$ix[$k]]
    $did = $(if ($d.commodity) { [string]$d.commodity.id } else { '' })
    if ($orig[$k] -ne $did) { [void]$detailDiff.Add([pscustomobject]@{ ix = $ix[$k]; name = $list[$ix[$k]]; original = $orig[$k]; detail = $did }) }
    elseif ($did -and -not $d.include_hit) { [void]$detailNoHit.Add([pscustomobject]@{ ix = $ix[$k]; name = $list[$ix[$k]] }) }
  }
  $tD = $sw.Elapsed.TotalSeconds
  # key = ix*2 (+1 for the fallback entry) reproduces the single-threaded emission order exactly: one pass
  # over the names, and for each name the fast-path divergence before the powershell-fallback one.
  $diff = New-Object System.Collections.ArrayList
  $matched = 0
  for ($k = 0; $k -lt $n; $k++) {
    if ($orig[$k]) { $matched++ }
    if ($orig[$k] -ne $new[$k])   { [void]$diff.Add([pscustomobject]@{ key = ($ix[$k] * 2);     name = $list[$ix[$k]]; original = $orig[$k]; fast = $new[$k];   path = $(if ($hasCore) { 'compiled' } else { 'powershell' }) }) }
    if ($orig[$k] -ne $newPs[$k]) { [void]$diff.Add([pscustomobject]@{ key = ($ix[$k] * 2 + 1); name = $list[$ix[$k]]; original = $orig[$k]; fast = $newPs[$k]; path = 'powershell-fallback' }) }
  }
  ([pscustomobject]@{
    names = $n; core = $hasCore; matched = $matched; diff = @($diff.ToArray()); detailDiff = @($detailDiff.ToArray())
    detailNoHit = @($detailNoHit.ToArray()); tO = $tO; tN = $tN; tP = $tP; tD = $tD
  } | ConvertTo-Json -Depth 6 -Compress) | Set-Content -LiteralPath $OutFile -Encoding UTF8
  exit 0
}

# ---- 4. PARENT: run the shards, then merge their verdicts -------------------------------------------
# The children are ordinary powershell children, spawned through native-lib's Invoke-NativeScript exactly
# like every other child in this estate - the redirect happens inside a call that has forced EAP to
# 'Continue', so a shard writing to stderr cannot terminate this script. The runspace pool here is only a
# way to have several of those calls in flight at once; no matching happens on these threads, which is
# the entire point (see the header).
. (Join-Path $root 'native-lib.ps1')
$hasCore = ($null -ne $matcher.core)
$W = $Workers
if ($W -le 0) { $W = [Math]::Min(16, [Math]::Max(1, [Environment]::ProcessorCount - 2)) }
if ($W -gt $list.Count) { $W = [Math]::Max(1, $list.Count) }
$shardDir = Join-Path $env:TEMP ('matchlib-shard-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $shardDir -Force
$corpusFile = Join-Path $shardDir 'corpus.json'
(ConvertTo-Json @($list) -Compress) | Set-Content -LiteralPath $corpusFile -Encoding UTF8

# The shard runs THIS file, by the path this file was actually invoked as - never a path rebuilt from
# $root. A copy of this harness under another name (which is how the parallel rewrite was proved against
# the single-threaded one) must shard ITSELF, not whatever test-match-lib.ps1 happens to be next to it.
$selfPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
$shardSb = {
  param([string]$Lib, [string]$Path, [object[]]$Argv)
  $ErrorActionPreference = 'Continue'
  . $Lib
  $r = Invoke-NativeScript $Path @Argv
  [pscustomobject]@{ rc = $r.ExitCode; text = ((@($r.Lines) | ForEach-Object { [string]$_ }) -join "`n") }
}
$swAll = [Diagnostics.Stopwatch]::StartNew()
$pool = [runspacefactory]::CreateRunspacePool(1, $W)
$pool.Open()
$jobs = @()
for ($k = 0; $k -lt $W; $k++) {
  $of = Join-Path $shardDir ("shard-$k.json")
  $ps = [powershell]::Create()
  $ps.RunspacePool = $pool
  [void]$ps.AddScript([string]$shardSb).AddArgument((Join-Path $root 'native-lib.ps1')).AddArgument($selfPath).AddArgument(
    [object[]]@('-ChunkFile', $corpusFile, '-ChunkOf', $W, '-ChunkIx', $k, '-OutFile', $of))
  $jobs += [pscustomobject]@{ ps = $ps; handle = $ps.BeginInvoke(); out = $of; ix = $k }
}
$results = @()
$shardErr = $null
foreach ($j in $jobs) {
  $res = $null
  try { $res = @($j.ps.EndInvoke($j.handle))[0] } catch { $res = [pscustomobject]@{ rc = -1; text = $_.Exception.Message } }
  $j.ps.Dispose()
  if ($null -eq $shardErr) {
    if ($null -eq $res -or $res.rc -ne 0) { $shardErr = ("shard {0} exited {1}: {2}" -f $j.ix, $(if ($res) { $res.rc } else { -1 }), $(if ($res) { $res.text } else { '' })) }
    elseif (-not (Test-Path $j.out)) { $shardErr = ("shard {0} exited 0 but wrote no verdicts" -f $j.ix) }
    else { $results += (Read-JsonFile $j.out) }
  }
}
$pool.Close(); $pool.Dispose()
Remove-Item $shardDir -Recurse -Force -ErrorAction SilentlyContinue
$tWall = $swAll.Elapsed.TotalSeconds

# A SHARD THAT DIED PROVES NOTHING, and must never be able to shrink the corpus quietly - the union of
# the survivors' answers would read as a clean run over a corpus nobody chose. Same verdict as a failed
# extraction: exit 3, and the caller treats match-lib as unverified.
if ($null -ne $shardErr) {
  Write-Output ('match-lib: BLIND - part of the corpus was never compared: ' + $shardErr)
  Write-GuardComplete -Name 'match-lib' -Summary 'BLIND: shard failed'
  exit 3
}
$seen = 0; foreach ($r in $results) { $seen += [int]$r.names }
if ($seen -ne $list.Count) {
  Write-Output ('match-lib: BLIND - the shards between them compared {0} of {1} names' -f $seen, $list.Count)
  Write-GuardComplete -Name 'match-lib' -Summary 'BLIND: corpus not covered'
  exit 3
}
# EVERY SHARD MUST HAVE HAD THE SAME MATCHER AS THIS PROCESS. If one of them failed to Add-Type, its
# "compiled" pass was actually the interpreted one: the run would still go green while leaving the path
# production uses unproven, and any divergence it did find would be filed against the wrong path.
$badCore = @($results | Where-Object { [bool]$_.core -ne $hasCore })
if ($badCore.Count) {
  Write-Output ('match-lib: BLIND - {0} of {1} shards disagreed with this process about the compiled core (hasCore={2})' -f $badCore.Count, $results.Count, $hasCore)
  Write-GuardComplete -Name 'match-lib' -Summary 'BLIND: shard core mismatch'
  exit 3
}
# The four phase timings are the SUM of the shards' own stopwatches - the same CPU seconds the
# single-threaded version reported, so the speedup ratio below still compares the two matchers against
# each other and not against the core count. Wall clock is reported on its own line.
$tO = ($results | Measure-Object -Property tO -Sum).Sum
$tN = ($results | Measure-Object -Property tN -Sum).Sum
$tP = ($results | Measure-Object -Property tP -Sum).Sum
$tD = ($results | Measure-Object -Property tD -Sum).Sum
# Merged and re-sorted into the single-threaded order by the global name index, so every line printed
# below is the line the single-threaded version would have printed, in the order it would have printed it.
# (Gathered element by element rather than with a pipeline: ConvertFrom-Json can hand back $null for an
# empty list, and a $null flowing through ForEach-Object would be COUNTED as a divergence.)
function Gather($rs, $prop) {
  $acc = New-Object System.Collections.ArrayList
  foreach ($r in $rs) { foreach ($x in @($r.$prop)) { if ($null -ne $x) { [void]$acc.Add($x) } } }
  return @($acc.ToArray())
}
$detailDiff  = @(Gather $results 'detailDiff'  | Sort-Object ix)
$detailNoHit = @(Gather $results 'detailNoHit' | Sort-Object ix | ForEach-Object { $_.name })
$diff        = @(Gather $results 'diff'        | Sort-Object key)
$matched     = 0; foreach ($r in $results) { $matched += [int]$r.matched }

if (-not $Quiet) {
  Write-Output ("match-lib identity: {0} distinct names ({1} matched by the original)" -f $list.Count, $matched)
  Write-Output ("  original Match-Category : {0,7:N1}s" -f $tO)
  Write-Output ("  match-lib (compiled={2}) : {0,7:N1}s   ({1:N1}x faster)" -f $tN, $(if ($tN -gt 0) { $tO / $tN } else { 0 }), $hasCore)
  Write-Output ("  match-lib (ps fallback) : {0,7:N1}s   ({1:N1}x faster)" -f $tP, $(if ($tP -gt 0) { $tO / $tP } else { 0 }))
  Write-Output ("  detail scan (identity)  : {0,7:N1}s   ({1} winner divergence(s), {2} matched name(s) with no include_hit)" -f $tD, $detailDiff.Count, $detailNoHit.Count)
  Write-Output ("  shards                  : {0,7:N1}s wall across {1} process(es)" -f $tWall, $W)
  Write-Output ("  divergences             : {0}" -f $diff.Count)
  foreach ($d in ($diff | Select-Object -First 15)) { Write-Output ("     [{3}] '{0}'  original={1}  fast={2}" -f $d.name, $(if ($d.original) { $d.original } else { '<none>' }), $(if ($d.fast) { $d.fast } else { '<none>' }), $d.path) }
  foreach ($d in ($detailDiff | Select-Object -First 15)) { Write-Output ("     [detail] '{0}'  original={1}  detail={2}" -f $d.name, $(if ($d.original) { $d.original } else { '<none>' }), $(if ($d.detail) { $d.detail } else { '<none>' })) }
  foreach ($n in ($detailNoHit | Select-Object -First 10)) { Write-Output ("     [detail] '{0}' matched but named no include pattern" -f $n) }
}
if ($diff.Count -or $detailDiff.Count -or $detailNoHit.Count) {
  $total = $diff.Count + $detailDiff.Count + $detailNoHit.Count
  Write-Output ("MATCH-LIB FAILED ({0} divergence(s): {1} fast-path, {2} detail-winner, {3} detail-no-include-hit) - match-lib must not be used by the engine until it decides identically" -f $total, $diff.Count, $detailDiff.Count, $detailNoHit.Count)
  Write-GuardComplete -Name 'match-lib' -Summary "names=$($list.Count) divergences=$total"
  exit 1
}
Write-Output 'MATCH-LIB PASSED'
Write-GuardComplete -Name 'match-lib' -Summary ("names=" + $list.Count + " divergences=0 detail=0 speedup=" + [math]::Round($(if ($tN -gt 0) { $tO / $tN } else { 0 }), 1) + "x")
exit 0
