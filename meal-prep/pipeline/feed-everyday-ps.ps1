# feed-everyday-ps.ps1 - writes recipes[slug].everyday_ps into smp-feed.json: each recipe's per-serving price ON THE
# BASIS ITS OWN CARD FILLS WITH (2026-09-23, batch 3 landing).
#
# WHY. A recipe's price on a page that is NOT its card - an article ("{{live-recipe:cottage-pie}} a serving"), welcome,
# the homepage quote - is a data-tc-live-price span that public\tc-live-price.js fills from feed.recipes[slug].everyday_ps.
# The card computes that number itself from pricing_inputs (totalAt(n,'everyday')/n); a second implementation here would
# be RCA F1's two copies of one rule. So this runs THE CARD'S OWN SCRIPT, through the same jsdom harness the stamper and
# the live monitor use (live-price-fill.js), against the feed it is about to extend, and writes what the card filled.
#
# FAILS CLOSED PER RECIPE. A card whose script refuses the fill (a line with no everyday cell), a recipe with no built card,
# or a fill that disagrees with itself leaves that recipe WITHOUT the key, never 0: tc-live-price.js then keeps the span's
# stamped fallback. With no node, or a harness that dies, the feed is left byte-identical (exit 3).
# Exit 0 = written (coverage printed with its denominator), 3 = could not run. Last line: FEED-EVERYDAY-PS-COMPLETE.
# Called by grocery\export-feed.ps1 after it writes the feed. Self-test: -SelfTest
[CmdletBinding()]
param([string]$FeedPath = '', [string]$PublicPath = '', [string]$BuiltDir = '', [string]$NodeExe = '',
      [string]$JsdomEnv = 'C:\Codex\tools\jsdom-env', [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
. (Join-Path $repo 'lib\guard-contract.ps1')
if (-not $PublicPath) { $PublicPath = Join-Path $repo 'public\smp-feed.json' }
if (-not $BuiltDir) { $BuiltDir = Join-Path $mp 'db\built' }

# Pure: the harness results -> slug -> value, only where every span on the card filled with ONE positive value.
function Get-TcEverydayValues { param([hashtable]$Results)
  $out = @{}
  foreach ($k in $Results.Keys) {
    $r = $Results[$k]; if (-not $r -or -not $r.ok) { continue }
    $sp = @($r.spans); if ($sp.Count -eq 0) { continue }
    $vals = @($sp | ForEach-Object { [string]$_.filled } | Select-Object -Unique)
    if ($vals.Count -ne 1 -or -not $vals[0]) { continue }
    $d = 0.0
    if ([double]::TryParse($vals[0], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d) -and $d -gt 0) { $out[$k] = [math]::Round($d, 2) }
  }
  return $out
}

# RECIPE_STATS (2026-09-23, Brad on Q-homepage-two-more-literals, verbatim: "Make them live"). The homepage's
# "this week's cheapest lands at $X" and "most land at $A to $B a plate" read these, through tc-live-price.js
# (fields cheapest_ps and ps_range, registry meal-prep\lib\render-tokens.ps1). DEFINITIONS, stated once here:
#   population  recipes with an everyday_ps THIS run wrote (the card-fill basis: everyday prices, whole packages, per
#               serving), that are PUBLISHED (db\published-hashes.json) and NOT HELD (db\held-recipes.json).
#   cheapest    the minimum everyday_ps over the population (ties: the slug that sorts first, ordinal).
#   p25, p75    the 25th and 75th percentiles, linear interpolation between order statistics (h = (n-1)p), to the
#               cent. The fill rounds each to a whole dollar, so "most" is the middle half of the catalogue.
# Pure. $null when the population is empty, so the caller writes NO recipe_stats and every span keeps its fallback.
function Get-TcRecipePriceStats { param([hashtable]$Values, [hashtable]$Published, [hashtable]$Held)
  $rows = @(foreach ($k in $Values.Keys) { if ($Published.ContainsKey($k) -and -not $Held.ContainsKey($k)) { [pscustomobject]@{ s = [string]$k; v = [double]$Values[$k] } } })
  if ($rows.Count -eq 0) { return $null }
  $sorted = [Collections.Generic.List[object]]::new()
  foreach ($r in ($rows | Sort-Object -Property @{ Expression = { $_.v } }, @{ Expression = { $_.s } })) { $sorted.Add($r) }
  $n = $sorted.Count
  $q = { param([double]$p) $h = ($n - 1) * $p; $lo = [math]::Floor($h); $hi = [math]::Ceiling($h); [math]::Round($sorted[$lo].v + ($h - $lo) * ($sorted[$hi].v - $sorted[$lo].v), 2, [MidpointRounding]::AwayFromZero) }
  # the ordinal tie-break: Sort-Object is culture-aware, so re-pick the cheapest among exact ties by ordinal compare
  $min = $sorted[0].v; $cs = $sorted[0].s
  foreach ($r in $sorted) { if ($r.v -eq $min -and [string]::CompareOrdinal($r.s, $cs) -lt 0) { $cs = $r.s } }
  return [ordered]@{
    basis = 'feed-everyday-whole-package'
    population = 'published, not held, with everyday_ps'
    n = $n
    cheapest = [ordered]@{ slug = $cs; everyday_ps = [math]::Round($min, 2) }
    p25 = (& $q 0.25)
    p75 = (& $q 0.75)
  }
}

if ($SelfTest.IsPresent) {
  $script:fl = 0; $script:n = 0
  function T($m, $c, $g) { $script:n++; if ($c) { Write-Output ('ok    ' + $m) } else { Write-Output ('FAIL  ' + $m + '   got: ' + $g); $script:fl++ } }
  $mk = { param($ok, $vals) [pscustomobject]@{ ok = $ok; spans = @($vals | ForEach-Object { [pscustomobject]@{ filled = $_ } }) } }
  $v = Get-TcEverydayValues @{ a = (& $mk $true @('2.51', '2.51')); b = (& $mk $true @($null, $null)); c = (& $mk $true @('2.00', '2.10')); d = (& $mk $false @('3.00')); e = (& $mk $true @('0.00')) }
  T 'CLEAN TWIN  a card that filled every span with one value writes that value (2.51)' ($v.ContainsKey('a') -and $v['a'] -eq 2.51) ($v.Keys -join ',')
  T 'MUST NOT FIRE  a refused fill writes NO key, never 0 (the span keeps its stamped fallback)' (-not $v.ContainsKey('b')) ($v.Keys -join ',')
  T 'MUST NOT FIRE  a card that disagrees with itself (2.00 and 2.10) writes no key' (-not $v.ContainsKey('c')) ($v.Keys -join ',')
  T 'MUST NOT FIRE  a harness failure and a 0.00 fill write no key' (-not $v.ContainsKey('d') -and -not $v.ContainsKey('e')) ($v.Keys -join ',')
  $st = Get-TcRecipePriceStats -Values @{ a = 1.0; b = 2.0; c = 3.0; d = 4.0; e = 0.25; f = 0.5 } -Published @{ a = 1; b = 1; c = 1; d = 1; e = 1 } -Held @{ e = 1 }
  T 'CLEAN TWIN  recipe_stats over a,b,c,d: n 4, cheapest a 1.00, p25 1.75 and p75 3.25 (linear interpolation, h=(n-1)p)' ($null -ne $st -and $st.n -eq 4 -and $st.cheapest.slug -eq 'a' -and $st.cheapest.everyday_ps -eq 1.0 -and $st.p25 -eq 1.75 -and $st.p75 -eq 3.25) ($st | ConvertTo-Json -Compress)
  T 'MUST FIRE  a HELD recipe (e 0.25) and an UNPUBLISHED one (f 0.50), both cheaper, never become the cheapest' ($null -ne $st -and $st.cheapest.slug -eq 'a') ($st | ConvertTo-Json -Compress)
  $st0 = Get-TcRecipePriceStats -Values @{ e = 0.25 } -Published @{ e = 1 } -Held @{ e = 1 }
  T 'MUST NOT FIRE  an empty population writes NO stats (the spans keep their fallbacks), never a 0' ($null -eq $st0) ($st0 | ConvertTo-Json -Compress)
  $stT = Get-TcRecipePriceStats -Values @{ zz = 1.5; aa = 1.5; mm = 2.0 } -Published @{ zz = 1; aa = 1; mm = 1 } -Held @{}
  T 'CLEAN TWIN  a tie for cheapest is broken by ordinal slug (aa before zz)' ($stT.cheapest.slug -eq 'aa') ($stT | ConvertTo-Json -Compress)
  if ($script:fl -eq 0) { Write-Output ("feed-everyday-ps self-test PASS ($script:n cases)"); exit 0 } else { Write-Output ("feed-everyday-ps self-test FAIL ($script:fl of $script:n)"); exit 1 }
}

if (-not $FeedPath) { Write-Output 'no -FeedPath: export-feed names the feed it just wrote'; Exit-Guard -Name 'feed-everyday-ps' -Summary 'blind=no-feed-path' -Code 3 }
$node = $NodeExe
if (-not $node) { $p = Get-ChildItem 'C:\Codex\tools' -Filter 'node-*-win-x64' -Directory -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1; if ($p) { $node = Join-Path $p.FullName 'node.exe' } }
if (-not $node -or -not (Test-Path $node) -or -not (Test-Path (Join-Path $JsdomEnv 'node_modules\jsdom'))) { Write-Output 'BLIND  node or jsdom missing: the feed is left as written'; Exit-Guard -Name 'feed-everyday-ps' -Summary 'blind=no-node' -Code 3 }
$raw = [IO.File]::ReadAllText($FeedPath)
$feed = $raw.TrimStart([char]0xFEFF) | ConvertFrom-Json
$slugs = @($feed.recipes.PSObject.Properties | ForEach-Object { $_.Name })
if ($slugs.Count -eq 0) { Write-Output 'BLIND  the feed carries no recipes, so there is nothing to price: the feed is left as written'; Exit-Guard -Name 'feed-everyday-ps' -Summary 'blind=no-recipes' -Code 3 }
$cards = @(); foreach ($s in $slugs) { $b = Join-Path $BuiltDir ($s + '.body.html'); if (Test-Path $b) { $cards += @{ slug = $s; htmlPath = $b; kind = 'body' } } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('tc-fep-' + [guid]::NewGuid().ToString('N') + '.json')
try {
  [IO.File]::WriteAllText($tmp, (@{ jsdom = $JsdomEnv; feedPath = $FeedPath; feedMode = 'ok'; waitMs = 4000; cards = $cards } | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
  $lines = & $node (Join-Path $here 'live-price-fill.js') $tmp
} finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
$res = @{}; $done = $false
foreach ($l in @($lines)) { if ($l -match '^LIVE-PRICE-FILL-COMPLETE') { $done = $true } elseif ($l -match '^\{') { $o = $l | ConvertFrom-Json; $res[[string]$o.key] = $o } }
if (-not $done) { Write-Output 'BLIND  live-price-fill.js died before its completion marker: the feed is left as written'; Exit-Guard -Name 'feed-everyday-ps' -Summary 'blind=harness' -Code 3 }
$vals = Get-TcEverydayValues $res
foreach ($s in $slugs) {
  $r = $feed.recipes.$s
  if ($vals.ContainsKey($s)) { $r | Add-Member -NotePropertyName everyday_ps -NotePropertyValue $vals[$s] -Force }
  elseif ($r.PSObject.Properties['everyday_ps']) { $r.PSObject.Properties.Remove('everyday_ps') }
}
# recipe_stats: the homepage fields. Published and held sets are read here; a set that cannot be read writes NO stats
# (named, never guessed), and the spans keep their stamped fallbacks.
$feed.PSObject.Properties.Remove('recipe_stats')
$pubF = Join-Path $mp 'db\published-hashes.json'; $heldF = Join-Path $mp 'db\held-recipes.json'
$statsNote = ''
try {
  $pubSet = @{}; foreach ($pp in (([IO.File]::ReadAllText($pubF)).TrimStart([char]0xFEFF) | ConvertFrom-Json).PSObject.Properties) { $pubSet[$pp.Name] = 1 }
  $heldSet = @{}; foreach ($hh in @((([IO.File]::ReadAllText($heldF)).TrimStart([char]0xFEFF) | ConvertFrom-Json).held)) { if ($hh.slug) { $heldSet[[string]$hh.slug] = 1 } }
  if ($pubSet.Count -eq 0) { throw ($pubF + ' lists no published recipe') }
  $stats = Get-TcRecipePriceStats -Values $vals -Published $pubSet -Held $heldSet
  if ($null -eq $stats) { $statsNote = 'recipe_stats NOT written: no published, non-held recipe has an everyday_ps' }
  else {
    $feed | Add-Member -NotePropertyName recipe_stats -NotePropertyValue ([pscustomobject]$stats) -Force
    $statsNote = ('recipe_stats over {0} of {1} priced recipes (published, not held): cheapest {2} {3:0.00}, p25 {4:0.00}, p75 {5:0.00}' -f $stats.n, $vals.Count, $stats.cheapest.slug, $stats.cheapest.everyday_ps, $stats.p25, $stats.p75)
  }
} catch { $statsNote = ('recipe_stats NOT written: ' + $_.Exception.Message) }
$json = $feed | ConvertTo-Json -Depth 8 -Compress
[IO.File]::WriteAllText($FeedPath, $json, (New-Object Text.UTF8Encoding($true)))
if ($PublicPath) { [IO.File]::WriteAllText($PublicPath, $json, (New-Object Text.UTF8Encoding($false))) }
Write-Output ('feed-everyday-ps: ' + $statsNote)
Write-Output ("feed-everyday-ps: everyday_ps for {0} of {1} recipes ({2} have a built card; {3} fills refused, left to their fallback)" -f $vals.Count, $slugs.Count, $cards.Count, ($cards.Count - $vals.Count))
Exit-Guard -Name 'feed-everyday-ps' -Summary ("recipes={0} cards={1} written={2}" -f $slugs.Count, $cards.Count, $vals.Count) -Code 0
