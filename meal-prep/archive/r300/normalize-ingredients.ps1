# normalize-ingredients.ps1 (r300) - Applies canon rules to FINAL-300.json source ingredients.
# Rules = r100 canon-rules.json + r300-canon-rules.json (r300 rules FIRST - more specific,
# and order inside each file is preserved; both are ordered regex lists).
# Outputs (this folder): recipes-canon.json, new-items.json, unmapped report to stdout.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\lib\json-db-io.ps1')   # Save-JsonArray: top-level array always, no PS5.1 wrap/collapse
$r100 = Join-Path $here '..\r100'

$rulesRaw = @()
$r300rules = Join-Path $here 'r300-canon-rules.json'
if (Test-Path $r300rules) { $rulesRaw += (Get-Content $r300rules -Raw -Encoding utf8 | ConvertFrom-Json).rules }
$rulesRaw += (Get-Content (Join-Path $r100 'canon-rules.json') -Raw -Encoding utf8 | ConvertFrom-Json).rules
$rules = @()
foreach ($r in $rulesRaw) { $rules += ,@([regex]::new($r[0], 'IgnoreCase'), $r[1]) }
$dbItems = ((Get-Content (Join-Path $here '..\food-macros-db.json') -Raw -Encoding utf8 | ConvertFrom-Json).items | ForEach-Object { $_.item })
$dbSet = @{}; foreach ($i in $dbItems) { $dbSet[$i] = 1 }

function CleanItem([string]$t) {
    $t = $t.ToLower().Trim()
    $t = $t -replace '\([^)]*\)', ''
    $t = $t -replace ',\s*(diced|minced|chopped|sliced|grated|shredded|julienned|cut[^,]*|thinly[^,]*|finely[^,]*|divided|drained[^,]*|rinsed[^,]*|softened|melted|beaten|to taste|optional|for serving|for garnish|plus more[^,]*|at room temperature|trimmed[^,]*|peeled[^,]*|crushed|halved|quartered|cubed|torn|packed|freshly ground|uncooked|cooked[^,]*|warmed|cold|hot)\s*$', ''
    $t.Trim(' ,.')
}

$all = Get-Content (Join-Path $here 'FINAL-300.json') -Raw -Encoding utf8 | ConvertFrom-Json
$unmapped = @{}; $newItems = @{}; $canonRecipes = @()
foreach ($r in $all) {
    $canon = @()
    foreach ($si in $r.source_ingredients) {
        $raw = CleanItem ([string]$si.item)
        if (-not $raw) { continue }
        $hit = $null
        foreach ($rule in $rules) { if ($rule[0].IsMatch($raw)) { $hit = $rule[1]; break } }
        if (-not $hit) { if ($unmapped.ContainsKey($raw)) { $unmapped[$raw]++ } else { $unmapped[$raw] = 1 }; continue }
        if ($hit -eq 'DROP') { continue }
        $isNew = $hit.StartsWith('NEW:')
        $name = if ($isNew) { $hit.Substring(4) } else { $hit }
        if (-not $isNew -and -not $dbSet.ContainsKey($name)) { throw ("rule maps to non-DB item: '{0}' (from '{1}')" -f $name, $raw) }
        if ($isNew) { if ($newItems.ContainsKey($name)) { $newItems[$name]++ } else { $newItems[$name] = 1 } }
        $canon += [pscustomobject]@{ canon = $name; is_new = $isNew; source_item = [string]$si.item; source_qty = [string]$si.qty }
    }
    $grouped = $canon | Group-Object canon | ForEach-Object {
        [pscustomobject]@{
            canon = $_.Name; is_new = ($_.Group[0].is_new)
            sources = @($_.Group | ForEach-Object { [pscustomobject]@{ item = $_.source_item; qty = $_.source_qty } })
        } }
    $canonRecipes += [pscustomobject]@{
        proposed_name = $r.proposed_name; slug = $r.slug; protein = $r.pk; cuisine = $r.cuisine; format = $r.format
        source_url = $r.source_url; source_site = $r.source_site; source_servings = $r.source_servings
        source_nutrition = $r.source_nutrition_per_serving; est_cal = $r.est_cal_per_serving; notes = $r.notes
        ingredients = @($grouped)
    }
}
Save-JsonArray -Array $canonRecipes -Path (Join-Path $here 'recipes-canon.json') -Depth 8 | Out-Null
$newList = $newItems.GetEnumerator() | Sort-Object -Property @{e={-$_.Value}} | ForEach-Object { [pscustomobject]@{ item = $_.Name; uses = $_.Value } }
Save-JsonArray -Array $newList -Path (Join-Path $here 'new-items.json') -Depth 3 | Out-Null

Write-Output ("recipes: {0}   new canonical items: {1}" -f $canonRecipes.Count, $newItems.Count)
Write-Output ("UNMAPPED distinct: " + $unmapped.Count)
$unmapped.GetEnumerator() | Sort-Object -Property @{e={-$_.Value}}, Name | ForEach-Object { Write-Output ("  {0,2}  {1}" -f $_.Value, $_.Name) }
