# build-protein-data.ps1
# Rebuilds the embedded JS data block for the Cheapest Protein leaderboard tool
# (C:\Codex\income\protein-leaderboard-tool.html).
#
# Reads:
#   - food-macros-db.json   (protein_g / serving_grams per item, label-accurate)
#   - ingredient-map.json   (item -> feed board_id + grams_per_unit)
#   - live smp-feed.json    (this week's cheapest price per unit, baked in as fallback)
#
# Math: cost per 30g protein = (price_per_unit / grams_per_unit) / (protein_g / serving_grams) * 30
#
# Emits the "var PL={...};" line to stdout and writes it to protein-data.generated.js
# in this folder. Paste that line over the existing "var PL=" line in the tool HTML,
# then republish. Nothing here touches the live site.

$ErrorActionPreference = 'Stop'
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\lib\ghost-lib.ps1')   # Invoke-GhostApi: timeout+retry on the public feed GET (was a hang-class bare Invoke-WebRequest)
$dbPath  = Join-Path $here 'food-macros-db.json'
$mapPath = Join-Path $here 'ingredient-map.json'
$outPath = Join-Path $here 'protein-data.generated.js'
$feedUrl = 'https://feed.thriftycrew.com/smp-feed.json'

$db  = (Get-Content -Raw $dbPath)  | ConvertFrom-Json
$map = (Get-Content -Raw $mapPath) | ConvertFrom-Json

$raw  = (Invoke-GhostApi -Uri $feedUrl -Web -BasicParsing -TimeoutSec 30).Content
$raw  = $raw.TrimStart([char]0xFEFF)   # feed starts with a BOM
$feed = $raw | ConvertFrom-Json

# Candidates: DB item name -> friendly display name + raw-weight flag.
# Only items that resolve to a feed price AND a clean grams_per_unit make the cut.
$candidates = @(
    @{ item = 'Boneless Skinless Chicken Breast'; n = 'Chicken breast';           raw = $true  }
    @{ item = 'Boneless Skinless Chicken Thigh';  n = 'Chicken thighs';           raw = $true  }
    @{ item = 'Pork Loin';                        n = 'Pork loin';                raw = $true  }
    @{ item = 'Pork Tenderloin';                  n = 'Pork tenderloin';          raw = $true  }
    @{ item = '93/7 Ground Beef';                 n = '93/7 ground beef';         raw = $true  }
    @{ item = '93/7 Ground Turkey';               n = '93/7 ground turkey';       raw = $true  }
    @{ item = 'Beef Chuck Roast';                 n = 'Beef chuck roast';         raw = $true  }
    @{ item = 'Greek Yogurt';                     n = 'Greek yogurt';             raw = $false }
    @{ item = 'Cottage Cheese';                   n = 'Cottage cheese';           raw = $false }
    # Milk: the DB label is Fairlife ULTRA-FILTERED (13g/cup) but the board's $/gallon price is
    # REGULAR gallon milk - pairing them would fake the cost per protein. Override to the standard
    # fat-free milk label (8g protein per 240g cup) so the protein matches the priced product.
    @{ item = 'Milk';                             n = 'Milk (fat free)';          raw = $false; pgOverride = 8; sgOverride = 240 }
    @{ item = 'Peanut Butter';                    n = 'Peanut butter';            raw = $false }
    @{ item = 'Cheddar Cheese, Shredded';         n = 'Shredded cheddar';         raw = $false }
    @{ item = 'Seasoned Black Beans';             n = 'Canned black beans';       raw = $false }
    @{ item = 'Cannellini Beans';                 n = 'Canned cannellini beans';  raw = $false }
    @{ item = 'Kidney Beans';                     n = 'Canned kidney beans';      raw = $false }
)

# PRODUCT PINS - these WIN over the ingredient-map row (2026-07-26). The map is derived from the recipe
# specs by MAJORITY, and the spec majority prices several items at a cheaper DIFFERENT product (93/7 beef
# at the 80/20 row, boneless-skinless thighs at the bone-in row, Greek yogurt at regular yogurt). That is
# a recipe-card consistency question - but THIS tool pairs each row's label-accurate macros with the
# price, so the priced product MUST be the macro'd product or cost-per-30g-protein is faked (the same
# Fairlife-vs-regular-milk lesson already encoded in the candidates list above).
$mapOverrides = @{
    'Cottage Cheese'                   = @{ board_id = 'cottage-cheese';                  grams_per_unit = 28.3495;  unit = 'oz' }
    '93/7 Ground Beef'                 = @{ board_id = '93-7-ground-beef';                grams_per_unit = 453.592;  unit = 'lb' }
    '93/7 Ground Turkey'               = @{ board_id = '93-7-ground-turkey';              grams_per_unit = 453.592;  unit = 'lb' }
    'Boneless Skinless Chicken Thigh'  = @{ board_id = 'boneless-skinless-chicken-thigh'; grams_per_unit = 453.592;  unit = 'lb' }
    'Greek Yogurt'                     = @{ board_id = 'greek-yogurt';                    grams_per_unit = 28.3495;  unit = 'oz' }
    'Cheddar Cheese, Shredded'         = @{ board_id = 'cheddar-cheese-shredded';         grams_per_unit = 28.3495;  unit = 'oz' }
}

$rows = @()
foreach ($c in $candidates) {
    $dbItem = $db.items | Where-Object { $_.item -eq $c.item } | Select-Object -First 1
    if (-not $dbItem) { Write-Warning "SKIP $($c.item): not in food-macros-db"; continue }

    # pins first (product-accuracy), then the derived map for everything else
    $m = $null
    if ($mapOverrides.ContainsKey($c.item)) {
        $o = $mapOverrides[$c.item]
        $m = [pscustomobject]@{ board_id = $o.board_id; grams_per_unit = $o.grams_per_unit; unit = $o.unit }
    }
    if (-not $m) { $m = $map.mappings | Where-Object { $_.item -eq $c.item } | Select-Object -First 1 }
    if (-not $m) { Write-Warning "SKIP $($c.item): no pin and no ingredient-map row"; continue }

    $f = $feed.ingredients.($m.board_id)
    if (-not $f -or -not $f.cheapest) { Write-Warning "SKIP $($c.item): board_id $($m.board_id) not priced in feed"; continue }
    if ($f.unit -ne $m.unit) { Write-Warning "SKIP $($c.item): unit mismatch (feed $($f.unit) vs map $($m.unit))"; continue }

    $pgVal = if ($c.pgOverride) { [double]$c.pgOverride } else { [double]$dbItem.protein_g }
    $sgVal = if ($c.sgOverride) { [double]$c.sgOverride } else { [double]$dbItem.serving_grams }
    $rows += [pscustomobject]@{
        n   = $c.n
        b   = $m.board_id
        gpu = [double]$m.grams_per_unit
        pg  = $pgVal
        sg  = $sgVal
        f   = [double]$f.cheapest
        fs  = [string]$f.store
        u   = [string]$f.unit
        r   = [bool]$c.raw
    }
}

if ($rows.Count -lt 8) { throw "Only $($rows.Count) rows survived; something is off, not writing." }

# Sort by fallback cost per 30g so the baked-in order is already correct.
$rows = $rows | Sort-Object { ($_.f / $_.gpu) / ($_.pg / $_.sg) * 30 }

$parts = foreach ($r in $rows) {
    $cost = [Math]::Round((($r.f / $r.gpu) / ($r.pg / $r.sg) * 30), 4)
    Write-Host ("  {0,-26} {1,8:F4} per 30g  ({2} {3}/{4} at {5})" -f $r.n, $cost, '$', $r.f, $r.u, $r.fs)
    $rawFlag = if ($r.r) { 'true' } else { 'false' }
    '{{"n":"{0}","b":"{1}","gpu":{2},"pg":{3},"sg":{4},"f":{5},"fs":"{6}","u":"{7}","r":{8}}}' -f `
        $r.n, $r.b, $r.gpu, $r.pg, $r.sg, $r.f, $r.fs, $r.u, $rawFlag
}

$js = 'var PL={week:"' + $feed.week_of + '",rows:[' + ($parts -join ',') + ']};'
Set-Content -Path $outPath -Value $js -Encoding utf8
Write-Host ""
Write-Host "Wrote $($rows.Count) rows to $outPath (week of $($feed.week_of))."
Write-Host "Paste the var PL= line over the one in protein-leaderboard-tool.html."
$js
