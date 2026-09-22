# add-recipesdb-rows.ps1 - the recipes-db.json rows for the four legacy rebuilds (2026-09-22, ruling A).
# build-card2 now REFUSES a card with no row (a missing row used to mean "paid" silently, and the free alfredo shipped a
# paywall claim). Every field is DERIVED from the built spec in db\recipes - nothing typed here but the visibility, which
# is the live post's own (free-chicken-alfredo public, the other three paid) and the old post's publish date read off
# its live page. archive\r10\update-recipes-db.ps1 is NOT used: it hard-codes paid.
# Idempotent: a row already present for a slug is replaced, never duplicated. Usage: run from the repo, no arguments.
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$mp = Split-Path -Parent (Split-Path -Parent $here)
. (Join-Path (Split-Path -Parent $mp) 'lib\json-io.ps1')
$vis = [ordered]@{ 'free-chicken-alfredo' = 'public'; 'shredded-bbq-chicken-sammies' = 'paid'; 'beef-protein-pasta' = 'paid'; 'chicken-marinara-pasta' = 'paid' }
$dbPath = Join-Path $mp 'recipes-db.json'
$db = Read-JsonFile $dbPath
$keep = @($db.recipes | Where-Object { -not $vis.Contains([string]$_.slug) })
$new = @()
foreach ($slug in $vis.Keys) {
  $s = Read-JsonFile (Join-Path $mp ("db\recipes\" + $slug + ".json"))
  $bids = @($s.scaler.ing | ForEach-Object { [string]$_.bid })
  $disp = @($s.ingredients_display)
  $ing = @(); $i = 0
  foreach ($g in @($s.ingredients_grams)) {
    $buy = [regex]::Match([regex]::Replace([string]$disp[$i], '<[^>]+>', ''), ':\s*(.*?)\s*\(\d+ g\)\s*$').Groups[1].Value
    $ing += [ordered]@{ item = [string]$g.item; grams = [int]$g.grams; buy = $buy; item_id = $(if ($i -lt $bids.Count) { $bids[$i] } else { '' }) }
    $i++
  }
  $pubd = ''
  try { $h = (Invoke-WebRequest -Uri ("https://www.thriftycrew.com/$slug/") -UseBasicParsing -TimeoutSec 45).Content; $pubd = [regex]::Match($h, 'article:published_time" content="(\d{4}-\d{2}-\d{2})').Groups[1].Value } catch { }
  $ps = [ordered]@{ calories = [int]$s.stat.cal; protein_g = [int]$s.stat.protein; carbs_g = [int]$s.stat.carbs; fat_g = [int]$s.stat.fat }
  $new += [ordered]@{
    name = [string]$s.name; slug = $slug; visibility = $vis[$slug]; cuisine = ([string]$s.cuisine).ToLower(); servings = [int]$s.servings
    ingredients = $ing; per_serving = $ps
    batch = [ordered]@{ calories = 14 * $ps.calories; protein_g = 14 * $ps.protein_g; carbs_g = 14 * $ps.carbs_g; fat_g = 14 * $ps.fat_g }
    cost_per_serving = $s.cost_per_serving; cost_batch = $s.cost_batch; cost_batch_true = $s.cost_batch_true; cost_per_serving_true = $s.cost_per_serving_true
    cost_pantry_add = $s.cost_pantry_add; cost_first_run = $s.cost_first_run
    published = $pubd; source_url = [string]$s.source_url; source_site = [string]$s.source_site
    notes = 'Legacy rebuild 2026-09-22 (ruling A): the pre-engine post rebuilt as an engine recipe at its own URL; row derived from db\recipes by add-recipesdb-rows.ps1.'
    protein = [string]$s.protein
  }
}
# APPENDED AS TEXT, the way every build since r100 appends its rows: a ConvertTo-Json round trip of the whole file rewrote
# 8,722 lines of an unchanged catalogue. A slug already present is refused, never duplicated (re-running is a no-op error).
$present = @($new | Where-Object { $s0 = $_.slug; @($db.recipes | Where-Object { [string]$_.slug -eq $s0 }).Count -gt 0 } | ForEach-Object { $_.slug })
if ($present.Count) { throw ("recipes-db already has a row for: " + ($present -join ', ') + " - nothing written") }
$txt = [IO.File]::ReadAllText($dbPath)
$end = $txt.LastIndexOf(']')
$rowsTxt = ($new | ForEach-Object { ([pscustomobject]$_ | ConvertTo-Json -Depth 10 -Compress) }) -join ','
$txt = $txt.Substring(0, $end).TrimEnd() + ',' + $rowsTxt + "`n    " + $txt.Substring($end)
$raw = [IO.File]::ReadAllBytes($dbPath); $bom = ($raw.Length -ge 3 -and $raw[0] -eq 0xEF)
[IO.File]::WriteAllText($dbPath, $txt, (New-Object Text.UTF8Encoding($bom)))
$chk = Read-JsonFile $dbPath
foreach ($r in $new) { "{0,-30} {1,-7} published={2} ingredients={3} cps={4}" -f $r.slug, $r.visibility, $r.published, @($r.ingredients).Count, $r.cost_per_serving }
"recipes-db rows: " + @($chk.recipes).Count