# fetch-recipe.ps1
# ---------------------------------------------------------------------------------------------------
# Fetches a recipe page ONCE, caches the body content-addressed, and prefers the page's own JSON-LD
# `Recipe` block over its rendered prose. Serves the sourcer, the extractor and the page cache.
#
# THE TWO WASTES THIS KILLS (measured on run wf_11382034-6fd, lane-tokens.ps1):
#   The hunt lane spent 325,543,422 tokens - 43.3% of the entire run. A rendered recipe page is
#   20-50K tokens of context, and one sourcer did 11 searches and 6 fetches to return a couple of
#   candidates: most of what it pulled into context it then threw away.
#   The same page was then fetched AGAIN by the extractor to transcribe it. 47 transcriptions, 47
#   redundant fetches. And when a URL 404'd between those two moments, work that had already
#   succeeded was destroyed - that is how greek-pork-chops-zucchini-feta-skillet and
#   jamaican-brown-stew-beef died, after a sourcer had read both pages successfully.
#
# JSON-LD AND TRANSCRIPTION INTEGRITY. schema.org `Recipe` is the page's OWN machine-readable statement
# of its recipe - recipeIngredient, recipeInstructions, nutrition. Transcribing from it is still
# transcribing the page, at a fraction of the tokens and MORE reliably than prose-reading a rendered
# blog. What remains forbidden is transcribing from the sourcer's DESCRIPTION of a page. If the JSON-LD
# and the visible page disagree, that is a finding to report, never a silent preference.
#
#   .\fetch-recipe.ps1 -Url https://... [-Refresh]      fetch (or serve from cache), emit JSON-LD if present
#   .\fetch-recipe.ps1 -Url https://... -BodyPath       just print the cached body path
#   .\fetch-recipe.ps1 -Stats
#   .\fetch-recipe.ps1 -SelfTest
# ---------------------------------------------------------------------------------------------------
param(
  [string]$Url = '', [switch]$Refresh, [switch]$BodyPath, [switch]$Stats, [switch]$Json, [switch]$SelfTest,
  [string]$CacheDir = '', [int]$TimeoutSec = 30
)
$ErrorActionPreference = 'Stop'
$runRefresh=[bool]$Refresh; $runBodyPath=[bool]$BodyPath; $runStats=[bool]$Stats; $runJson=[bool]$Json; $runSelfTest=[bool]$SelfTest

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mp   = Split-Path -Parent $here
$repo = Split-Path -Parent $mp
. (Join-Path $repo 'lib\guard-contract.ps1')
if (-not $CacheDir) { $CacheDir = Join-Path $mp 'db\page-cache' }

function Get-UrlKey {
  param([string]$U)
  # Content-addressed by URL so two sourcers finding the same page share one cache entry for free.
  $norm = ($U -replace '#.*$', '').Trim().ToLower()
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $bytes = [Text.Encoding]::UTF8.GetBytes($norm)
  $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
  $sha.Dispose()
  return $hash.Substring(0, 32)
}

function Get-JsonLdBlocks {
  param([string]$Html)
  # Returns the raw contents of every <script type="application/ld+json"> block.
  $out = @()
  if (-not $Html) { return $out }
  $rx = [regex]'(?is)<script[^>]*type\s*=\s*["'']application/ld\+json["''][^>]*>(.*?)</script>'
  foreach ($m in $rx.Matches($Html)) { $out += $m.Groups[1].Value }
  return $out
}

function Find-RecipeNode {
  param($Node, [int]$Depth = 0)
  # schema.org Recipe can sit at the root, inside @graph, or inside an array - all three occur in the
  # wild, so all three are searched rather than assuming one shape.
  if ($Depth -gt 6 -or $null -eq $Node) { return $null }
  if ($Node -is [System.Object[]]) {
    foreach ($n in $Node) { $r = Find-RecipeNode $n ($Depth + 1); if ($r) { return $r } }
    return $null
  }
  if ($Node -is [psobject]) {
    $names = $Node.PSObject.Properties.Name
    if ($names -contains '@type') {
      $t = $Node.'@type'
      $types = if ($t -is [System.Object[]]) { @($t) } else { @([string]$t) }
      if ($types -contains 'Recipe') { return $Node }
    }
    if ($names -contains '@graph') { $r = Find-RecipeNode $Node.'@graph' ($Depth + 1); if ($r) { return $r } }
  }
  return $null
}

if ($runSelfTest) {
  $bad = 0
  function T([string]$n,[bool]$ok,[string]$got){ if($ok){Write-Output ("  ok    "+$n)}else{Write-Output ("  X     "+$n+"   got: "+$got); $script:bad++} }

  T 'the same URL keys to the same cache entry' ((Get-UrlKey 'https://x.com/a') -eq (Get-UrlKey 'https://x.com/a')) 'differs'
  T 'a fragment does not create a second cache entry' ((Get-UrlKey 'https://x.com/a#print') -eq (Get-UrlKey 'https://x.com/a')) 'differs'
  T 'MUST FIRE  different URLs key differently' ((Get-UrlKey 'https://x.com/a') -ne (Get-UrlKey 'https://x.com/b')) 'collided'

  $html = '<html><head><script type="application/ld+json">{"@type":"Recipe","name":"Test","recipeIngredient":["1 cup x"]}</script></head><body>prose</body></html>'
  $blocks = @(Get-JsonLdBlocks $html)
  T 'a JSON-LD block is extracted' ($blocks.Count -eq 1) ([string]$blocks.Count)
  T 'MUST FIRE  a page with no JSON-LD yields none (and must fall back, not crash)' ((@(Get-JsonLdBlocks '<html><body>nothing</body></html>')).Count -eq 0) 'found some'

  $node = Find-RecipeNode ($blocks[0] | ConvertFrom-Json)
  T 'the Recipe node is found at the root' ($node -and $node.name -eq 'Test') 'not found'
  $graph = '{"@graph":[{"@type":"WebSite"},{"@type":"Recipe","name":"Deep"}]}' | ConvertFrom-Json
  T 'MUST FIRE  the Recipe node is found inside @graph (the common WordPress shape)' ((Find-RecipeNode $graph).name -eq 'Deep') 'missed @graph'
  $arr = '[{"@type":"Article"},{"@type":"Recipe","name":"InArray"}]' | ConvertFrom-Json
  T 'the Recipe node is found inside a top-level array' ((Find-RecipeNode $arr).name -eq 'InArray') 'missed array'
  $multi = '{"@type":["Recipe","NewsArticle"],"name":"MultiType"}' | ConvertFrom-Json
  T 'MUST FIRE  a multi-valued @type containing Recipe still matches' ((Find-RecipeNode $multi).name -eq 'MultiType') 'missed multi-type'
  T 'CLEAN TWIN a non-Recipe page yields no node' ($null -eq (Find-RecipeNode ('{"@type":"Article","name":"No"}' | ConvertFrom-Json))) 'false positive'

  if ($bad -gt 0) { Write-Output ("fetch-recipe SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'fetch-recipe SELF-TEST PASS'
  Write-GuardComplete -Name 'fetch-recipe' -Summary 'selftest pass'; exit 0
}

if ($runStats) {
  if (-not (Test-Path $CacheDir)) { Write-Output 'fetch-recipe: cache is empty'; exit 0 }
  $f = @(Get-ChildItem $CacheDir -Filter '*.html' -ErrorAction SilentlyContinue)
  $mb = if ($f.Count) { [Math]::Round((($f | Measure-Object -Property Length -Sum).Sum / 1MB), 2) } else { 0 }
  Write-Output ("fetch-recipe cache: {0} page(s), {1} MB, at {2}" -f $f.Count, $mb, $CacheDir)
  exit 0
}

if (-not $Url) { Write-Output 'fetch-recipe: -Url is required'; exit 1 }
if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null }
$key = Get-UrlKey $Url
$bodyFile = Join-Path $CacheDir ($key + '.html')
$metaFile = Join-Path $CacheDir ($key + '.meta.json')

if ($runBodyPath) { Write-Output $bodyFile; exit $(if (Test-Path $bodyFile) { 0 } else { 1 }) }

$fromCache = $false
if ((Test-Path $bodyFile) -and -not $runRefresh) {
  $html = Get-Content $bodyFile -Raw -Encoding utf8
  $fromCache = $true
} else {
  try {
    $resp = Invoke-WebRequest -Uri $Url -TimeoutSec $TimeoutSec -UseBasicParsing -Headers @{ 'User-Agent' = 'Mozilla/5.0 (compatible; ThriftyCrew recipe pipeline)' }
    $html = [string]$resp.Content
  } catch {
    # Record the failure against the publisher so the pipeline stops re-learning which domains fail.
    $sd = Join-Path $here 'source-domains.ps1'
    if (Test-Path $sd) {
      $outcome = if ($_.Exception.Message -match '404|NotFound') { '404' } else { 'fail' }
      & powershell -NoProfile -File $sd -Record -Domain $Url -Outcome $outcome -Note ("fetch-recipe: " + $_.Exception.Message.Substring(0, [Math]::Min(120, $_.Exception.Message.Length))) | Out-Null
    }
    Write-Output ("fetch-recipe: FETCH FAILED {0} - {1}" -f $Url, $_.Exception.Message)
    exit 1
  }
  Set-Content -Path $bodyFile -Value $html -Encoding utf8
}

$jsonld = $null; $hasLd = $false
foreach ($b in (Get-JsonLdBlocks $html)) {
  try { $n = Find-RecipeNode ($b | ConvertFrom-Json) } catch { $n = $null }
  if ($n) { $jsonld = $n; $hasLd = $true; break }
}

if (-not $fromCache) {
  $sd = Join-Path $here 'source-domains.ps1'
  if (Test-Path $sd) {
    $a = @('-Record', '-Domain', $Url, '-Outcome', 'ok')
    if ($hasLd) { $a += '-HasJsonLd' }
    & powershell -NoProfile -File $sd @a | Out-Null
  }
  ([pscustomobject]@{ url=$Url; fetched=(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'); bytes=$html.Length; has_jsonld=$hasLd } | ConvertTo-Json) | Set-Content $metaFile -Encoding utf8
}

if ($runJson) {
  ([pscustomobject]@{ url=$Url; from_cache=$fromCache; body=$bodyFile; has_jsonld=$hasLd; recipe=$jsonld } | ConvertTo-Json -Depth 8)
  exit 0
}
Write-Output ("fetch-recipe: {0}  ({1}, {2:N0} bytes)" -f $Url, $(if($fromCache){'FROM CACHE - no network, no second fetch'}else{'fetched'}), $html.Length)
Write-Output ("  body: {0}" -f $bodyFile)
if ($hasLd) {
  Write-Output '  JSON-LD Recipe FOUND - transcribe from this rather than the rendered page (it is the page''s own statement, at a fraction of the tokens):'
  Write-Output ($jsonld | ConvertTo-Json -Depth 6)
} else {
  Write-Output '  no JSON-LD Recipe block - fall back to reading the cached body above. Do NOT transcribe from a summary.'
}
exit 0
