# build-stretcher-data.ps1 - generates the compact embedded dataset for the
# "Payday Stretcher" tool from recipes-db.json. Output: stretcher-data.js
# (a JS const, paste into payday-stretcher-tool.html) plus a primary-protein
# classification review table on stdout. Also cross-checks every slug against
# the live feed so the tool's live-price lookups will actually hit.
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
# $PSScriptRoot, not a hard-coded path (2026-09-01): this now runs from the daily chain, and the cloud
# runner's checkout is not C:\Codex.
$dir  = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\meal-prep' }
$repo = Split-Path $dir -Parent
$tool = Join-Path $repo 'site\tools\payday-stretcher-tool.html'
$db  = Read-JsonFile "$dir\recipes-db.json"
# v2 manifest: current-cheapest whole-package per serving per slug (2026-07-26 basis switch)
$script:cheapPs=@{}
try { (Read-JsonFile (Join-Path $dir 'pipeline\v2-perserving.json')) | ForEach-Object { $script:cheapPs[[string]$_.slug]=[math]::Round([double]$_.cheapest_ps,2) } } catch { Write-Warning 'v2-perserving.json unreadable - legacy cost fallback in effect' }

# live feed check (BOM gotcha: TrimStart the FEFF before ConvertFrom-Json)
$feedRec = @{}
try {
  $raw = (Invoke-WebRequest -Uri "https://feed.thriftycrew.com/smp-feed.json" -UseBasicParsing -TimeoutSec 30).Content.TrimStart([char]0xFEFF)
  $feed = $raw | ConvertFrom-Json
  foreach($k in $feed.recipes.PSObject.Properties.Name){ $feedRec[$k] = $true }
  "live feed OK: week_of=$($feed.week_of), $($feedRec.Count) recipes"
} catch {
  "WARN: live feed unreachable ($($_.Exception.Message)) - slug check skipped"
}

# ---- primary protein: name first, then protein-bearing ingredients ----
# broth/stock excluded so a pork recipe with chicken broth stays pork.
function Get-Protein([object]$r){
  $texts = @($r.name)
  foreach($i in $r.ingredients){
    if($i.item -notmatch 'Broth|Stock|Bouillon|Base'){ $texts += $i.item }
  }
  foreach($t in $texts){
    if($t -match 'Chicken'){ return 'c' }
    if($t -match 'Beef|Chuck Roast|Steak|Sirloin|Barbacoa'){ return 'b' }
    if($t -match 'Turkey'){ return 't' }
    if($t -match 'Pork|Carnitas|Sausage|Bacon(?! Bits)|Ham\b|Kielbasa'){ return 'p' }
  }
  return 'o'
}

# ---- collect recipes ----
$recs = @()
foreach($r in $db.recipes){
  # 2026-07-26: current-cheapest whole-package per serving (v2 manifest) first; legacy only if absent
  $cps = if($script:cheapPs -and $script:cheapPs.ContainsKey([string]$r.slug)){ $script:cheapPs[[string]$r.slug] }
         elseif($r.PSObject.Properties['cost_per_serving_true'] -and $r.cost_per_serving_true){ $r.cost_per_serving_true } else { $r.cost_per_serving }
  $cb  = if($r.PSObject.Properties['cost_batch_true'] -and $r.cost_batch_true){ $r.cost_batch_true }
         elseif($r.PSObject.Properties['cost_batch'] -and $r.cost_batch){ $r.cost_batch }
         else { [math]::Round($cps * $r.servings, 2) }
  $recs += ,@{ n=$r.name; s=$r.slug; v=[int]$r.servings; b=[math]::Round($cb,2); c=[math]::Round($cps,2);
               p=[int]$r.per_serving.protein_g; k=[int]$r.per_serving.calories; pr=(Get-Protein $r) }
  if($feedRec.Count -gt 0 -and -not $feedRec.ContainsKey($r.slug)){ "WARN: slug not in live feed: $($r.slug)" }
}

# ---- emit JS (unquoted keys keep the payload small; valid JS object literals) ----
# b is the batch cost with the full fallback chain baked in:
# cost_batch_true, else cost_batch, else cost_per_serving x servings.
function JStr([string]$s){ '"' + ($s -replace '\\','\\\\' -replace '"','\"') + '"' }
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append('var PSD={rec:[')
$first = $true
foreach($r in $recs){
  if(-not $first){ [void]$sb.Append(',') }; $first = $false
  [void]$sb.Append('{n:'+(JStr $r.n)+',s:'+(JStr $r.s)+',v:'+$r.v+',b:'+$r.b+',p:'+$r.p+',k:'+$r.k+',pr:"'+$r.pr+'"}')
}
[void]$sb.Append(']};')
$js = $sb.ToString()
[IO.File]::WriteAllText("$dir\stretcher-data.js", $js, (New-Object System.Text.UTF8Encoding($false)))

# ---- SPLICE INTO THE TOOL (2026-09-01) ----------------------------------------------------------
# The header said "paste into payday-stretcher-tool.html". Nobody pasted: stretcher-data.js was last
# written 2026-07-26, the live tool was 74 recipes behind and still listed 7 retired ones, and 299 of
# its 513 baked rows carried one identical batch cost. A build step whose last mile is a person's
# memory is not a build step.
$spliced = $false
if (Test-Path $tool) {
  $html = [IO.File]::ReadAllText($tool)
  $m1 = '/*PSD-DATA*/'; $m2 = '/*PSD-END*/'
  $a = $html.IndexOf($m1); $b = $html.IndexOf($m2)
  if ($a -ge 0 -and $b -gt $a) {
    $html = $html.Substring(0, $a + $m1.Length) + $js + $html.Substring($b)
    [IO.File]::WriteAllText($tool, $html, (New-Object System.Text.UTF8Encoding($false)))
    $spliced = $true
  }
}

"WROTE stretcher-data.js  ($([math]::Round((Get-Item "$dir\stretcher-data.js").Length/1KB,1)) KB)  recipes=$($recs.Count)"
if ($spliced) { "SPLICED into payday-stretcher-tool.html  ($([math]::Round((Get-Item $tool).Length/1KB,1)) KB total)" }
else { "WARNING: markers not found in $tool - data NOT spliced, the live tool will stay behind" }
""
"--- PRIMARY PROTEIN REVIEW (eyeball for misfits) ---"
foreach($c in 'c','b','t','p','o'){
  $label = @{c='CHICKEN';b='BEEF';t='TURKEY';p='PORK';o='OTHER'}[$c]
  $hits = @($recs | Where-Object { $_.pr -eq $c })
  ""; "== $label ($($hits.Count)) =="
  ($hits | ForEach-Object { "  $($_.n)  [`$$($_.c)/sv, batch `$$($_.b)]" }) -join "`n"
}