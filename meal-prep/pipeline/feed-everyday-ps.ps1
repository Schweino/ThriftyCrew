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

if ($SelfTest.IsPresent) {
  $script:fl = 0; $script:n = 0
  function T($m, $c, $g) { $script:n++; if ($c) { Write-Output ('ok    ' + $m) } else { Write-Output ('FAIL  ' + $m + '   got: ' + $g); $script:fl++ } }
  $mk = { param($ok, $vals) [pscustomobject]@{ ok = $ok; spans = @($vals | ForEach-Object { [pscustomobject]@{ filled = $_ } }) } }
  $v = Get-TcEverydayValues @{ a = (& $mk $true @('2.51', '2.51')); b = (& $mk $true @($null, $null)); c = (& $mk $true @('2.00', '2.10')); d = (& $mk $false @('3.00')); e = (& $mk $true @('0.00')) }
  T 'CLEAN TWIN  a card that filled every span with one value writes that value (2.51)' ($v.ContainsKey('a') -and $v['a'] -eq 2.51) ($v.Keys -join ',')
  T 'MUST NOT FIRE  a refused fill writes NO key, never 0 (the span keeps its stamped fallback)' (-not $v.ContainsKey('b')) ($v.Keys -join ',')
  T 'MUST NOT FIRE  a card that disagrees with itself (2.00 and 2.10) writes no key' (-not $v.ContainsKey('c')) ($v.Keys -join ',')
  T 'MUST NOT FIRE  a harness failure and a 0.00 fill write no key' (-not $v.ContainsKey('d') -and -not $v.ContainsKey('e')) ($v.Keys -join ',')
  if ($script:fl -eq 0) { Write-Output ("feed-everyday-ps self-test PASS ($script:n cases)"); exit 0 } else { Write-Output ("feed-everyday-ps self-test FAIL ($script:fl of $script:n)"); exit 1 }
}

if (-not $FeedPath) { Write-Output 'no -FeedPath: export-feed names the feed it just wrote'; Exit-Guard -Name 'feed-everyday-ps' -Summary 'blind=no-feed-path' -Code 3 }
$node = $NodeExe
if (-not $node) { $p = Get-ChildItem 'C:\Codex\tools' -Filter 'node-*-win-x64' -Directory -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1; if ($p) { $node = Join-Path $p.FullName 'node.exe' } }
if (-not $node -or -not (Test-Path $node) -or -not (Test-Path (Join-Path $JsdomEnv 'node_modules\jsdom'))) { Write-Output 'BLIND  node or jsdom missing: the feed is left as written'; Exit-Guard -Name 'feed-everyday-ps' -Summary 'blind=no-node' -Code 3 }
$raw = [IO.File]::ReadAllText($FeedPath)
$feed = $raw.TrimStart([char]0xFEFF) | ConvertFrom-Json
$slugs = @($feed.recipes.PSObject.Properties.Name)
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
$json = $feed | ConvertTo-Json -Depth 8 -Compress
[IO.File]::WriteAllText($FeedPath, $json, (New-Object Text.UTF8Encoding($true)))     # out\ copy: export-feed writes it with a BOM
if ($PublicPath) { [IO.File]::WriteAllText($PublicPath, $json, (New-Object Text.UTF8Encoding($false))) }   # public\: BOM-less, as served
Write-Output ("feed-everyday-ps: everyday_ps for {0} of {1} recipes ({2} have a built card; {3} fills refused, left to their fallback)" -f $vals.Count, $slugs.Count, $cards.Count, ($cards.Count - $vals.Count))
Exit-Guard -Name 'feed-everyday-ps' -Summary ("recipes={0} cards={1} written={2}" -f $slugs.Count, $cards.Count, $vals.Count) -Code 0
