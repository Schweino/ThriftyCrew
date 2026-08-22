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

  Exit 0 = identical on every name. Exit 1 = any divergence (listed). Exit 3 = could not extract the
  original (then nothing is proven and the caller must treat match-lib as unverified).
#>
param([switch]$Quiet, [int]$MaxNames = 0)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path (Split-Path $root -Parent) 'lib\guard-contract.ps1')

# ---- 1. the ORIGINAL, verbatim, from compare-deals.ps1 -------------------------------------------
$src = Get-Content (Join-Path $root 'compare-deals.ps1') -Raw
$a = $src.IndexOf('$GLOBAL_EXCLUDE = @(')
$b = $src.IndexOf('# ---------------------------------------------------------------- -Explain')
if ($a -lt 0 -or $b -lt 0 -or $b -le $a) {
  Write-Output 'match-lib: BLIND - could not locate GLOBAL_EXCLUDE..Match-Category in compare-deals.ps1; nothing proven'
  Write-GuardComplete -Name 'match-lib' -Summary 'BLIND: extraction failed'
  exit 3
}
$block = $src.Substring($a, $b - $a)
$block = ($block -split "`n" | Where-Object { $_ -notmatch '\$GEX_OVERRIDE' }) -join "`n"
$commodities = Get-Content (Join-Path $root 'commodities.json') -Raw | ConvertFrom-Json
. ([scriptblock]::Create($block))      # defines $GLOBAL_EXCLUDE, Get-MatchTexts, Match-Category (original)
$origMatch = ${function:Match-Category}
$origTexts = ${function:Get-MatchTexts}

# ---- 2. the NEW one --------------------------------------------------------------------------------
. (Join-Path $root 'match-lib.ps1')    # redefines Get-MatchTexts identically; adds New-CommodityMatcher/Resolve-Commodity
$matcher = New-CommodityMatcher -Commodities $commodities -GlobalExclude $GLOBAL_EXCLUDE

# Get-MatchTexts must be byte-identical too, or the include texts differ before any regex runs.
$t1 = & $origTexts 'Member''s Mark Boneless and Skinless Chicken Breast, priced per pound'
$t2 = Get-MatchTexts 'Member''s Mark Boneless and Skinless Chicken Breast, priced per pound'
if (($t1 -join '|') -ne ($t2 -join '|')) { Write-Output "FAIL  Get-MatchTexts diverged: '$($t1 -join '|')' vs '$($t2 -join '|')'"; Write-GuardComplete -Name 'match-lib' -Summary 'failed=1 (texts)'; exit 1 }

# ---- 3. the corpus: every distinct name the engine feeds the matcher today -------------------------
. (Join-Path $root 'capture-depth-lib.ps1')
. (Join-Path $root 'regular-fileset-lib.ps1')
$names = @{}
$cmp = Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1
$today = if ($cmp -and $cmp.BaseName -match '(\d{4}-\d{2}-\d{2})$') { [datetime]$Matches[1] } else { Get-Date }
foreach ($rf in (Select-RegularFileSet (Get-ChildItem (Join-Path $root 'out\regular\*-regular-*.json')) $today 14)) {
  $ex = Get-Content $rf.FullName -Raw | ConvertFrom-Json
  foreach ($d in $ex.deals) { if ($d.item) { $names[[string]$d.item] = 1 } }
}
$adsF = Get-ChildItem (Join-Path $root 'out\ads-*.json') | Sort-Object Name -Descending | Select-Object -First 1
if ($adsF) { foreach ($d in (Get-Content $adsF.FullName -Raw | ConvertFrom-Json).deals) { if ($d.item) { $names[[string]$d.item] = 1 } } }
foreach ($f in (Get-ChildItem (Join-Path $root 'out\sams\sams-deals-*.json') -EA SilentlyContinue)) { foreach ($d in (Get-Content $f.FullName -Raw | ConvertFrom-Json).deals) { if ($d.item) { $names[[string]$d.item] = 1 } } }
foreach ($sub in @('bakers\bakers-deals-*.json', 'fareway\fareway-deals-*.json')) {
  $f = Get-ChildItem (Join-Path $root ('out\' + $sub)) -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  if ($f) { foreach ($d in (Get-Content $f.FullName -Raw | ConvertFrom-Json).deals) { if ($d.item) { $names[[string]$d.item] = 1 } } }
}
# Adversarial names the corpus may not contain today: the shapes that broke matchers before.
foreach ($x in @('Hy-Vee butter, 16 oz., $2.48', 'GO2snax Mild Cheddar Cheese & Salami Tray', 'Marketside Tandoori Style Garlic Naan Bites',
                 'Wish-Bone Chunky Blue Cheese Salad Dressing', 'Red Apple Cheese Gruyere Cheese', 'mix & match bagels', 'Chunk Light Tuna in Water 5 oz',
                 'Simple Truth Protein Black Pepper Lentils Brown Rice and Quinoa Blend', 'Fresh Red Cherries, 2.25 lb Bag', '')) { $names[$x] = 1 }
$list = @($names.Keys)
if ($MaxNames -gt 0 -and $list.Count -gt $MaxNames) { $list = $list[0..($MaxNames - 1)] }

# ---- 4. side by side --------------------------------------------------------------------------------
$swO = [Diagnostics.Stopwatch]::StartNew()
$orig = @{}
foreach ($n in $list) { $c = & $origMatch $n; $orig[$n] = $(if ($c) { [string]$c.id } else { '' }) }
$tO = $swO.Elapsed.TotalSeconds
# BOTH paths are proven, separately. The compiled core is what production runs; the PowerShell path is
# the fallback when Add-Type is unavailable. A harness that only tested "whichever loaded" would leave
# one of them unverified, and the unverified one is exactly the one that runs on the day something is
# different about the machine.
$hasCore = ($null -ne $matcher.core)
$swN = [Diagnostics.Stopwatch]::StartNew()
$new = @{}
foreach ($n in $list) { $c = Resolve-Commodity -Matcher $matcher -Name $n; $new[$n] = $(if ($c) { [string]$c.id } else { '' }) }
$tN = $swN.Elapsed.TotalSeconds
$psOnly = [pscustomobject]@{ gex = $matcher.gex; entries = $matcher.entries; core = $null }
$swP = [Diagnostics.Stopwatch]::StartNew()
$newPs = @{}
foreach ($n in $list) { $c = Resolve-Commodity -Matcher $psOnly -Name $n; $newPs[$n] = $(if ($c) { [string]$c.id } else { '' }) }
$tP = $swP.Elapsed.TotalSeconds

$diff = @()
foreach ($n in $list) {
  if ($orig[$n] -ne $new[$n]) { $diff += [pscustomobject]@{ name = $n; original = $orig[$n]; fast = $new[$n]; path = $(if ($hasCore) { 'compiled' } else { 'powershell' }) } }
  if ($orig[$n] -ne $newPs[$n]) { $diff += [pscustomobject]@{ name = $n; original = $orig[$n]; fast = $newPs[$n]; path = 'powershell-fallback' } }
}
$matched = @($list | Where-Object { $orig[$_] }).Count

if (-not $Quiet) {
  Write-Output ("match-lib identity: {0} distinct names ({1} matched by the original)" -f $list.Count, $matched)
  Write-Output ("  original Match-Category : {0,7:N1}s" -f $tO)
  Write-Output ("  match-lib (compiled={2}) : {0,7:N1}s   ({1:N1}x faster)" -f $tN, $(if ($tN -gt 0) { $tO / $tN } else { 0 }), $hasCore)
  Write-Output ("  match-lib (ps fallback) : {0,7:N1}s   ({1:N1}x faster)" -f $tP, $(if ($tP -gt 0) { $tO / $tP } else { 0 }))
  Write-Output ("  divergences             : {0}" -f $diff.Count)
  foreach ($d in ($diff | Select-Object -First 15)) { Write-Output ("     [{3}] '{0}'  original={1}  fast={2}" -f $d.name, $(if ($d.original) { $d.original } else { '<none>' }), $(if ($d.fast) { $d.fast } else { '<none>' }), $d.path) }
}
if ($diff.Count) {
  Write-Output ("MATCH-LIB FAILED ({0} divergence(s)) - match-lib must not be used by the engine until it decides identically" -f $diff.Count)
  Write-GuardComplete -Name 'match-lib' -Summary "names=$($list.Count) divergences=$($diff.Count)"
  exit 1
}
Write-Output 'MATCH-LIB PASSED'
Write-GuardComplete -Name 'match-lib' -Summary ("names=" + $list.Count + " divergences=0 speedup=" + [math]::Round($(if ($tN -gt 0) { $tO / $tN } else { 0 }), 1) + "x")
exit 0
