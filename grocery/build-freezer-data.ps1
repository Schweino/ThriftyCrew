# build-freezer-data.ps1
# Computes the two savings channels behind the Freezer Math tool:
#   1) Stock-up spread: (avg weekly cheapest - record low) / avg weekly cheapest, per freezable, from price-history.json
#   2) Bulk spread: Sam's Club bulk price vs the average non-bulk store price, from the newest out\comparison-*.json
# Emits out\freezer-data.json plus a ready-to-paste JS constants block.
# When the history deepens (more weeks_on_record), rerun this and swap the DATA constant in
# C:\Codex\ThriftyCrew\site\tools\freezer-math-tool.html with the emitted block.

$ErrorActionPreference = 'Stop'
$root = 'C:\Codex\ThriftyCrew\grocery'

# The freezables. Things a chest freezer actually lets you stockpile.
$freezables = @('chicken-breast','chicken-thighs','ground-beef-8020','ground-turkey','bacon','pork-chops','butter','shredded-cheese','bread')

# ---------- Channel 1: stock-up spread from price history ----------
$hist = Get-Content (Join-Path $root 'price-history.json') -Raw | ConvertFrom-Json
$weeks = $hist.weeks_on_record
$rows = @()
foreach ($id in $freezables) {
    $c = $hist.commodities | Where-Object { $_.id -eq $id }
    if (-not $c) { Write-Warning "No history for $id, skipping"; continue }
    $prices = @($c.history | ForEach-Object { $_.cheapest_price })
    $avg = ($prices | Measure-Object -Average).Average
    $low = $c.record_low.price
    $spread = 0
    if ($avg -gt 0) { $spread = ($avg - $low) / $avg }
    $rows += [pscustomobject]@{
        id      = $id
        label   = $c.label
        unit    = $c.unit
        weeks   = $prices.Count
        avg     = [math]::Round($avg, 4)
        low     = $low
        lowStore = $c.record_low.store
        spread  = [math]::Round($spread, 4)
    }
}
$stockupBlend = [math]::Round((($rows | ForEach-Object { $_.spread }) | Measure-Object -Average).Average, 4)

# ---------- Channel 2: bulk spread from the newest comparison file ----------
$compFile = Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name | Select-Object -Last 1
$comp = Get-Content $compFile.FullName -Raw | ConvertFrom-Json
$bulkRows = @()
foreach ($id in $freezables) {
    $entry = $comp.comparison | Where-Object { $_.id -eq $id }
    if (-not $entry) { continue }
    $sams = $entry.stores | Where-Object { $_.store -eq "Sam's Club" } | Select-Object -First 1
    if (-not $sams) { continue }
    # Compare against the plain, non-bulk, no-membership stores: what a normal weekly shopper pays.
    $regular = @($entry.stores | Where-Object { -not $_.bulk -and -not $_.membership })
    if ($regular.Count -eq 0) { $regular = @($entry.stores | Where-Object { $_.store -ne "Sam's Club" }) }
    if ($regular.Count -eq 0) { continue }
    $regAvg = ($regular | ForEach-Object { $_.per_unit } | Measure-Object -Average).Average
    $raw = 0
    if ($regAvg -gt 0) { $raw = ($regAvg - $sams.per_unit) / $regAvg }
    $bulkRows += [pscustomobject]@{
        id       = $id
        label    = $entry.commodity
        sams     = $sams.per_unit
        regAvg   = [math]::Round($regAvg, 4)
        regCount = $regular.Count
        rawSpread = [math]::Round($raw, 4)
        # If bulk is MORE expensive for an item, you just skip bulk on that item. So the
        # usable spread floors at zero. We report the raw number too, no hiding.
        # NOTE: 0.0 not 0 -- [math]::Max(0, $double) binds the int overload in PS 5.1 and truncates.
        usedSpread = [math]::Round([math]::Max(0.0, $raw), 4)
    }
}
$bulkBlend = 0
if ($bulkRows.Count -gt 0) {
    $bulkBlend = [math]::Round((($bulkRows | ForEach-Object { $_.usedSpread }) | Measure-Object -Average).Average, 4)
}

# ---------- Emit ----------
# Merge bulk numbers into the per-commodity rows for the tool's receipts table.
foreach ($r in $rows) {
    $b = $bulkRows | Where-Object { $_.id -eq $r.id }
    if ($b) {
        $r | Add-Member -NotePropertyName bulkSams -NotePropertyValue $b.sams
        $r | Add-Member -NotePropertyName bulkRegAvg -NotePropertyValue $b.regAvg
        $r | Add-Member -NotePropertyName bulkSpread -NotePropertyValue $b.usedSpread
        $r | Add-Member -NotePropertyName bulkRaw -NotePropertyValue $b.rawSpread
    } else {
        $r | Add-Member -NotePropertyName bulkSams -NotePropertyValue $null
        $r | Add-Member -NotePropertyName bulkRegAvg -NotePropertyValue $null
        $r | Add-Member -NotePropertyName bulkSpread -NotePropertyValue $null
        $r | Add-Member -NotePropertyName bulkRaw -NotePropertyValue $null
    }
}

$out = [pscustomobject]@{
    built_at       = (Get-Date -Format 'yyyy-MM-dd')
    weeks_on_record = $weeks
    history_updated = $hist.updated
    comparison_file = $compFile.Name
    stockup_blend  = $stockupBlend
    bulk_blend     = $bulkBlend
    commodities    = $rows
}
$outPath = Join-Path $root 'out\freezer-data.json'
$out | ConvertTo-Json -Depth 5 | Out-File $outPath -Encoding utf8

# ---------- Console report ----------
Write-Host ""
Write-Host "FREEZER MATH DATA  (weeks on record: $weeks, comparison: $($compFile.Name))"
Write-Host ""
Write-Host ("{0,-20} {1,8} {2,8} {3,9} | {4,8} {5,9} {6,9}" -f 'commodity','avg wk','rec low','stock-up','sams','reg avg','bulk')
foreach ($r in $rows) {
    $bulkTxt = if ($null -ne $r.bulkSpread) { ('{0,8:N2} {1,9:N2} {2,8:P1}' -f $r.bulkSams, $r.bulkRegAvg, $r.bulkSpread) } else { '     (no Sam''s price)' }
    Write-Host ("{0,-20} {1,8:N2} {2,8:N2} {3,9:P1} | {4}" -f $r.id, $r.avg, $r.low, $r.spread, $bulkTxt)
}
Write-Host ""
Write-Host ("BLENDED stock-up spread : {0:P2}" -f $stockupBlend)
Write-Host ("BLENDED bulk spread     : {0:P2}" -f $bulkBlend)
Write-Host ""
Write-Host "Wrote $outPath"
Write-Host ""

# JS constants block for the tool (paste over the DATA object in freezer-math-tool.html)
$jsRows = ($rows | ForEach-Object {
    if ($null -eq $_.bulkSpread) { $bs = 'null' } else { $bs = $_.bulkSpread }
    "    {id:'$($_.id)',label:'$($_.label -replace "'","\'")',unit:'$($_.unit)',avg:$($_.avg),low:$($_.low),lowStore:'$($_.lowStore -replace "'","\'")',spread:$($_.spread),bulkSpread:$bs}"
}) -join ",`n"
$js = "var DATA = {`n  updated:'$($hist.updated)', weeks:$weeks,`n  stockup:$stockupBlend, bulk:$bulkBlend,`n  rows:[`n$jsRows`n  ]`n};"
Write-Host "---- JS constants (paste into freezer-math-tool.html) ----"
Write-Host $js
