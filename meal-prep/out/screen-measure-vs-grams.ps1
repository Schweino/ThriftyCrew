# SCREEN ONLY - not a verdict. For every ingredient label that states a MEASURING unit we can weigh,
# compare the grams the label implies against the grams the recipe actually uses. A large disagreement
# is the same shape as the seven "(scaled ~N)" rows, minus the writer's note that made those findable.
# cook-measure-lib refuses to auto-fix this class on purpose: either side can be the wrong one, and the
# grams drive cost and macros. So this only sizes the problem and ranks it - every row needs a source check.
#
# 2026-08-04 CORRECTION - THE SCREEN WAS MISREADING ITS OWN INPUT. The first version rolled its own
# quantity regex, and its decimal branch was guarded by `-and -not $m.Groups['w'].Success`, so the whole
# part swallowed the decimal: "1.5 tsp" parsed as 1, "3.75 cups dry" as 3, "2.5 tsp" as 2. Every ratio it
# reported for a decimal-quantity label was inflated - Salt "1.5 tsp" @ 23 g read as 3.83x when it is
# 2.56x. cook-measure-lib.ps1 has parsed this correctly all along (Get-CmQty / Get-CmUnit), so the parser
# is now that library's, not a second copy. A screen that cannot read a label has no business grading one.
#
# It also reports the band BELOW its own threshold. The 2x bar hides part of the same class: Rice "1 lb"
# against 700 g is 1.54 and passes silently while the identical label against 1000 g is flagged.
param([double]$Bar = 2.0)
$mp = 'C:\Codex\ThriftyCrew\meal-prep'
. (Join-Path $mp 'pipeline\cook-measure-lib.ps1')
$dens = (Get-Content "$mp\db\densities.json" -Raw | ConvertFrom-Json).items
$LB = 453.592; $OZ = 28.3495

function UnitGrams($item, [string]$unit) {
    switch -regex ($unit) {
        '^lbs?$'            { return $LB }
        '^(oz|ounces?)$'    { return $OZ }
        default {
            $u = $unit -replace 's$', ''
            # Get-CmDensity, not a raw lookup: an item present-but-empty in densities.json must fall
            # through to its alias, which is the Fat Free Cheddar lesson the library already learned.
            $dm = Get-CmDensity $dens $item
            if ($dm -and ($dm.PSObject.Properties.Name -contains $u)) { return [double]$dm.$u }
            return $null
        }
    }
}

$rows = @()
foreach ($f in Get-ChildItem "$mp\db\recipes\*.json" | Where-Object { $_.Name -ne '_index.json' }) {
    $s = Get-Content $f.FullName -Raw | ConvertFrom-Json
    if (-not $s.scaler.ing) { continue }
    foreach ($i in @($s.scaler.ing)) {
        $buy = [string]$i.buy; $g = [double]$i.grams; $item = [string]$i.item
        if ($g -le 0 -or -not $buy) { continue }
        $unit = Get-CmUnit $buy
        if (-not $unit) { continue }
        $unit = $unit.ToLower()
        if ($unit -notmatch '^(tsp|tbsp|cup|cups|oz|ounce|ounces|lb|lbs)$') { continue }
        $q = Get-CmQty $buy
        if (-not $q -or $q -le 0) { continue }
        $per = UnitGrams $item $unit
        if (-not $per -or $per -le 0) { continue }
        $implied = $q * $per
        $ratio = $g / $implied
        $rows += [pscustomobject]@{
            Slug=$f.BaseName; Item=$item; Buy=$buy; Grams=[int]$g
            Implied=[math]::Round($implied,1); Ratio=[math]::Round($ratio,2)
            SourceUrl=[string]$s.source_url
        }
    }
}
$over  = @($rows | Where-Object { $_.Ratio -ge $Bar -or $_.Ratio -le (1/$Bar) })
$under = @($rows | Where-Object { ($_.Ratio -gt $Bar*0.625 -and $_.Ratio -lt $Bar) -or ($_.Ratio -gt (1/$Bar) -and $_.Ratio -lt 0.8) })

"measurable rows across the catalog: {0}" -f $rows.Count
"  label agrees with grams (within 25%):        {0}" -f (@($rows | Where-Object { $_.Ratio -ge 0.8 -and $_.Ratio -le 1.25 })).Count
"  DISAGREE by >={0}x either way:                 {1}  across {2} recipes" -f $Bar, $over.Count, (@($over | Group-Object Slug)).Count
"  drifting, 1.25x-{0}x - BELOW the bar, same class: {1}" -f $Bar, $under.Count
""
"worst 20 by ratio (grams / label-implied grams):"
"{0,-40} {1,-22} {2,-26} {3,7} {4,9} {5,7}" -f 'SLUG','ITEM','LABEL','GRAMS','IMPLIED','RATIO'
foreach ($r in ($over | Sort-Object { [math]::Max($_.Ratio, 1/$_.Ratio) } -Descending | Select-Object -First 20)) {
    "{0,-40} {1,-22} {2,-26} {3,7} {4,9} {5,7}" -f $r.Slug, $r.Item, $r.Buy, $r.Grams, $r.Implied, $r.Ratio
}
$over  | Sort-Object Slug, Item | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $mp 'out\measure-vs-grams-screen.csv')
$under | Sort-Object Slug, Item | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $mp 'out\measure-vs-grams-underbar.csv')
"`nover the bar  -> out\measure-vs-grams-screen.csv"
"below the bar -> out\measure-vs-grams-underbar.csv"
