# resolve-protein-swaps.ps1 - resolves PROTEIN-SWAP-LAMB sentinels in recipes-canon.json
# per-recipe (rules cannot see the recipe; this transform can). Idempotent; run after every
# normalize-ingredients.ps1 run. Quantities are preserved from the lamb source line.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\lib\json-db-io.ps1')   # Save-JsonArray: top-level array always
$path = Join-Path $here 'recipes-canon.json'
$rc = Get-Content $path -Raw -Encoding utf8 | ConvertFrom-Json

# slug -> replacement canon item (target-protein equivalent of the lamb cut)
$swaps = @{
    'xinjiang-cumin-turkey-stir-fry'   = 'Turkey Breast'      # sliced lamb leg -> sliced turkey breast (stir-fry strips)
    'kafta-bil-sanieh-beef-potato-bake' = '93/7 Ground Beef'  # 'ground lamb or beef' -> beef (target protein, source-sanctioned)
}

$resolved = 0
foreach ($r in $rc) {
    foreach ($ing in $r.ingredients) {
        if ($ing.canon -eq 'PROTEIN-SWAP-LAMB') {
            if (-not $swaps.ContainsKey($r.slug)) { throw ("unresolved PROTEIN-SWAP-LAMB in '{0}' - add to swap table" -f $r.slug) }
            $ing.canon = $swaps[$r.slug]
            $ing.is_new = $false
            $resolved++
        }
    }
}
Save-JsonArray -Array $rc -Path $path -Depth 8 | Out-Null
Write-Output ("PROTEIN-SWAP-LAMB resolved: {0}" -f $resolved)
