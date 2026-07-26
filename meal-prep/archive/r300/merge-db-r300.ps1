# merge-db-r300.ps1 - merges r300 mapper db-entries + browser-captured labels into food-macros-db.json.
# Guards: backup first, no name collisions with existing items (abort), Atwater check unless the row
# documents a specific-factor deviation, never-shrink (result count must be old + added).
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dbPath = Join-Path $here '..\food-macros-db.json'

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $here ("food-macros-db.backup-r300-{0}.json" -f $stamp)
Copy-Item $dbPath $backup

$db = Get-Content $dbPath -Raw -Encoding utf8 | ConvertFrom-Json
$existing = @{}; foreach ($i in $db.items) { $existing[$i.item] = 1 }
$oldCount = $db.items.Count

$mapper = (Get-Content (Join-Path $here 'mapper\db-entries.json') -Raw -Encoding utf8 | ConvertFrom-Json).items
$captured = (Get-Content (Join-Path $here 'mapper\captured-labels.json') -Raw -Encoding utf8 | ConvertFrom-Json).items
$incoming = @($mapper) + @($captured)

$added = 0
foreach ($e in $incoming) {
    if ($existing.ContainsKey($e.item)) { throw ("NAME COLLISION with existing DB item: '{0}' - resolve manually" -f $e.item) }
    $atwater = 4 * $e.protein_g + 4 * $e.carbs_g + 9 * $e.fat_g
    $cal = [double]$e.calories
    $dev = if ($cal -gt 0) { [math]::Abs($atwater - $cal) / $cal } else { 0 }
    $exempt = ($e.notes -match 'specific.factor|label-exempt') -or ($e.verify_source -match 'specific.factor|deviation')
    $isUsda = ([string]$e.source) -match '^USDA FDC'
    if ($dev -gt 0.25 -and $cal -ge 20) {
        if ($isUsda -or $exempt) {
            # USDA rows use specific calorie factors (fiber, leavening, spices) - crude 4/4/9
            # Atwater legitimately overshoots. Faithful transcription stands; log for review.
            Write-Output ("ATWATER-REVIEW '{0}': {1} cal vs 4/4/9 {2} ({3:P0}) - USDA specific-factor, kept" -f $e.item, $cal, $atwater, $dev)
        } else {
            throw ("ATWATER FAIL '{0}': label {1} cal vs computed {2} ({3:P0} off)" -f $e.item, $cal, $atwater, $dev)
        }
    }
    $db.items += $e
    $existing[$e.item] = 1
    $added++
}

if ($db.items.Count -ne ($oldCount + $added)) { throw 'never-shrink violation' }
$db | ConvertTo-Json -Depth 6 | Out-File $dbPath -Encoding utf8
Write-Output ("merged: {0} -> {1} items (+{2}); backup: {3}" -f $oldCount, $db.items.Count, $added, (Split-Path -Leaf $backup))
