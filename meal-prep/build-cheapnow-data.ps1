# build-cheapnow-data.ps1 - generates the compact embedded recipe constants for the
# "Cheap Dinners Right Now" tool from recipes-db.json (name, slug, servings,
# calories, protein, fallback cost per serving). Writes cheapnow-data.js AND
# splices the constant into cheap-dinners-tool.html between the
# /*CN-DATA*/ ... /*CN-END*/ markers. Prints per-threshold counts at baked
# (fallback) prices so you can sanity-check before publishing.
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
# $PSScriptRoot, not a hard-coded path (2026-09-01): this now runs from the daily chain, and the cloud
# runner's checkout is not C:\Codex.
$dir  = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\meal-prep' }
$tool = Join-Path (Split-Path $dir -Parent) 'site\tools\cheap-dinners-tool.html'
$db = (Get-Content "$dir\recipes-db.json" -Raw).TrimStart([char]0xFEFF) | ConvertFrom-Json
# v2 manifest: current-cheapest whole-package per serving per slug (2026-07-26 basis switch)
# 2026-09-22 (queue 2026-09-21-115180, RCA F1): the fallback is the value the tool SHOWS. liveCost() reads
# feed.recipes[slug].per_serving at view time, so the baked fallback is that same field from the canonical feed this build
# read, stamped with the feed's generated time. It was v2-perserving cheapest_ps, a second producer that disagreed with the
# feed on 100 of 577 recipes by a cent or more (max 49 cents) on 2026-09-22. v2 stays only for a slug the feed lacks.
$script:cheapPs=@{}; $script:feedAsof=''; $script:fromV2=0
try { $fd = Read-JsonFile (Join-Path (Split-Path $dir -Parent) 'grocery\out\smp-feed.json'); $script:feedAsof=[string]$fd.generated; foreach ($p in $fd.recipes.PSObject.Properties) { if ([double]$p.Value.per_serving -gt 0) { $script:cheapPs[$p.Name]=[math]::Round([double]$p.Value.per_serving,2) } } } catch { Write-Warning 'smp-feed.json unreadable - v2 fallback in effect' }
try { (Read-JsonFile (Join-Path $dir 'pipeline\v2-perserving.json')) | ForEach-Object { if (-not $script:cheapPs.ContainsKey([string]$_.slug)) { $script:cheapPs[[string]$_.slug]=[math]::Round([double]$_.cheapest_ps,2); $script:fromV2++ } } } catch { Write-Warning 'v2-perserving.json unreadable - legacy cost fallback in effect' }

# ---- recipes: compact constants (fallback costs baked in; live feed overrides at runtime) ----
$recs = @()
foreach($r in $db.recipes){
  # 2026-07-26: fallback cost = current-cheapest whole-package per serving (v2 manifest); legacy only if absent
  $cost = if($script:cheapPs -and $script:cheapPs.ContainsKey([string]$r.slug)){ $script:cheapPs[[string]$r.slug] }
          elseif($r.cost_per_serving_true){ $r.cost_per_serving_true } else { $r.cost_per_serving }
  $recs += ,@{ n=$r.name; s=$r.slug; sv=$r.servings; cal=$r.per_serving.calories; p=$r.per_serving.protein_g; c=[math]::Round($cost,2) }
}

# ---- emit JS (manual JSON to keep it compact + avoid PS5.1 quirks) ----
function JStr([string]$s){ '"' + ($s -replace '\\','\\\\' -replace '"','\"') + '"' }
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append('var CN={asof:' + (JStr $script:feedAsof) + ',') ; [void]$sb.Append('rec:[')
$first = $true
foreach($r in $recs){
  if(-not $first){ [void]$sb.Append(',') }; $first = $false
  [void]$sb.Append('{"n":'+(JStr $r.n)+',"s":'+(JStr $r.s)+',"sv":'+$r.sv+',"cal":'+$r.cal+',"p":'+$r.p+',"c":'+$r.c+'}')
}
[void]$sb.Append(']};')
$js = $sb.ToString()
[IO.File]::WriteAllText("$dir\cheapnow-data.js", $js, (New-Object System.Text.UTF8Encoding($false)))

# ---- splice into the tool between markers (literal string ops, no regex) ----
$spliced = $false
if (Test-Path $tool){
  $html = [IO.File]::ReadAllText($tool)
  $m1 = '/*CN-DATA*/'; $m2 = '/*CN-END*/'
  $a = $html.IndexOf($m1); $b = $html.IndexOf($m2)
  if ($a -ge 0 -and $b -gt $a){
    $html = $html.Substring(0, $a + $m1.Length) + $js + $html.Substring($b)
    [IO.File]::WriteAllText($tool, $html, (New-Object System.Text.UTF8Encoding($false)))
    $spliced = $true
  }
}

# ---- report ----
$u150 = @($recs | Where-Object { $_.c -lt 1.50 }).Count
$u200 = @($recs | Where-Object { $_.c -lt 2.00 }).Count
$u250 = @($recs | Where-Object { $_.c -lt 2.50 }).Count
"WROTE cheapnow-data.js  ($([math]::Round((Get-Item "$dir\cheapnow-data.js").Length/1KB,1)) KB)  recipes=$($recs.Count)"
if ($spliced){ "SPLICED into cheap-dinners-tool.html  ($([math]::Round((Get-Item $tool).Length/1KB,1)) KB total)" }
else { "WARNING: markers not found in $tool - data NOT spliced" }
""
"--- COUNTS AT BAKED (FALLBACK) PRICES ---"
"Under `$1.50: $u150"
"Under `$2.00: $u200"
"Under `$2.50: $u250"
"All:         $($recs.Count)"
""
"--- 5 CHEAPEST AT BAKED PRICES ---"
$recs | Sort-Object { $_.c } | Select-Object -First 5 | ForEach-Object { ('{0,6:N2}  {1}' -f $_.c, $_.n) }
