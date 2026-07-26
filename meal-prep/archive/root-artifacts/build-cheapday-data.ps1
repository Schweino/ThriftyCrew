# build-cheapday-data.ps1
# Rebuilds the embedded JS data block for the Cheapest Full Day of Food page
# (C:\Codex\income\cheap-day-tool.html).
#
# Reads:
#   - food-macros-db.json   (label-accurate calories / protein_g / serving_grams)
#   - ingredient-map.json   (item -> feed board_id + grams_per_unit)
#   - live smp-feed.json    (this week's cheapest price per unit, baked in as fallback)
#
# Emits the "var CD={...};" line to cheapday-data.generated.js in this folder.
# Paste it over the existing "var CD=" line in the tool HTML, then republish.
# Nothing here touches the live site.
#
# Documented macro overrides (each one exists because the DB label does not match
# the product the price board actually prices, or the item is priced but not in
# the DB and has an unambiguous standard label):
#   - Milk: DB label is Fairlife ultra-filtered (13g protein/cup) but the board
#     prices a regular gallon. Standard milk label used: 86 cal + 8g protein per 240g.
#   - Eggs: priced on the board ($/dozen, 600g/dozen in the map) but not in the
#     macros DB. USDA large egg: 72 cal + 6.3g protein per 50g egg.
#   - Bananas: priced on the board ($/lb) but not in the DB or map. USDA banana:
#     89 cal + 1.09g protein per 100g. grams_per_unit = 453.592 (per lb).
#   - Vegetable Oil: in the map (28g/floz) but not in the DB. Any cooking oil is
#     pure fat: 884 cal + 0g protein per 100g (matches the DB's Sesame Oil row).

$ErrorActionPreference = 'Stop'
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$dbPath  = Join-Path $here 'food-macros-db.json'
$mapPath = Join-Path $here 'ingredient-map.json'
$outPath = Join-Path $here 'cheapday-data.generated.js'
$feedUrl = 'https://smp-feed.ancient-snow-93df.workers.dev/smp-feed.json'

$db  = (Get-Content -Raw $dbPath)  | ConvertFrom-Json
$map = (Get-Content -Raw $mapPath) | ConvertFrom-Json

$raw  = (Invoke-WebRequest -UseBasicParsing $feedUrl).Content
$raw  = $raw.TrimStart([char]0xFEFF)   # feed starts with a BOM
$feed = $raw | ConvertFrom-Json

# cat: fv = fruit/veg, fat = added cooking fat, cp = complete protein (meat/egg/dairy), st = staple.
# kd/ku: grams per plain-kitchen unit + its name (kd 0 = show grams only).
# raw: price is for raw/uncooked weight.
# calO/pgO/sgO: documented macro overrides (see header). dbSkip = item not in DB at all.
$candidates = @(
    @{ k='rice';     item='Rice';                             n='Jasmine rice (dry)';        cat='st';  kd=66.7; ku='cup, cooked';    raw=$false }
    @{ k='penne';    item='Penne Pasta';                      n='Penne pasta (dry)';         cat='st';  kd=56;   ku='cup, cooked';    raw=$false }
    @{ k='pb';       item='Peanut Butter';                    n='Peanut butter';             cat='st';  kd=16;   ku='tablespoon';     raw=$false }
    @{ k='blkbeans'; item='Seasoned Black Beans';             n='Canned black beans';        cat='st';  kd=130;  ku='half cup';       raw=$false }
    @{ k='kidney';   item='Kidney Beans';                     n='Canned kidney beans';       cat='st';  kd=130;  ku='half cup';       raw=$false }
    @{ k='chickpea'; item='Chickpeas';                        n='Canned chickpeas';          cat='st';  kd=130;  ku='half cup';       raw=$false }
    @{ k='eggs';     item='Eggs';                             n='Eggs';                      cat='cp';  kd=50;   ku='large egg';      raw=$false; dbSkip=$true; calO=72; pgO=6.3; sgO=50 }
    @{ k='milk';     item='Milk';                             n='Milk';                      cat='cp';  kd=240;  ku='cup';            raw=$false; calO=86; pgO=8; sgO=240 }
    @{ k='yogurt';   item='Greek Yogurt';                     n='Greek yogurt';              cat='cp';  kd=0;    ku='';               raw=$false }
    @{ k='cottage';  item='Cottage Cheese';                   n='Cottage cheese';            cat='cp';  kd=0;    ku='';               raw=$false }
    @{ k='chicken';  item='Boneless Skinless Chicken Breast'; n='Chicken breast';            cat='cp';  kd=112;  ku='4 oz portion';   raw=$true }
    @{ k='thigh';    item='Boneless Skinless Chicken Thigh';  n='Chicken thighs';            cat='cp';  kd=112;  ku='4 oz portion';   raw=$true }
    @{ k='porkloin'; item='Pork Loin';                        n='Pork loin';                 cat='cp';  kd=112;  ku='4 oz portion';   raw=$true }
    @{ k='turkey';   item='93/7 Ground Turkey';               n='93/7 ground turkey';        cat='cp';  kd=112;  ku='4 oz portion';   raw=$true }
    @{ k='potato';   item='Potato';                           n='Potatoes';                  cat='fv';  kd=170;  ku='medium potato';  raw=$false }
    @{ k='banana';   item='Bananas';                          n='Bananas';                   cat='fv';  kd=118;  ku='medium banana';  raw=$false; dbSkip=$true; calO=89; pgO=1.09; sgO=100 }
    @{ k='cabbage';  item='Green Cabbage';                    n='Green cabbage';             cat='fv';  kd=0;    ku='';               raw=$false }
    @{ k='onion';    item='Yellow Onion';                     n='Yellow onions';             cat='fv';  kd=0;    ku='';               raw=$false }
    @{ k='peas';     item='Frozen Green Peas';                n='Frozen green peas';         cat='fv';  kd=0;    ku='';               raw=$false }
    @{ k='apple';    item='Apple';                            n='Apples';                    cat='fv';  kd=175;  ku='medium apple';   raw=$false }
    @{ k='butter';   item='Butter';                           n='Butter';                    cat='fat'; kd=14;   ku='tablespoon';     raw=$false }
    @{ k='vegoil';   item='Vegetable Oil';                    n='Vegetable oil';             cat='fat'; kd=14;   ku='tablespoon';     raw=$false; dbSkip=$true; calO=884; pgO=0; sgO=100 }
)

# Items priced on the board with no ingredient-map row. Only safe when grams per
# feed unit is unambiguous (fixed mass unit, or the protein-tool precedent).
$mapOverrides = @{
    'Cottage Cheese' = @{ board_id = 'cottage-cheese'; grams_per_unit = 28.3495;  unit = 'oz' }
    'Bananas'        = @{ board_id = 'bananas';        grams_per_unit = 453.592;  unit = 'lb' }
}

$rows = @()
foreach ($c in $candidates) {
    $dbItem = $db.items | Where-Object { $_.item -eq $c.item } | Select-Object -First 1
    if (-not $dbItem -and -not $c.dbSkip) { Write-Warning "SKIP $($c.item): not in food-macros-db"; continue }

    $m = $map.mappings | Where-Object { $_.item -eq $c.item } | Select-Object -First 1
    if (-not $m -and $mapOverrides.ContainsKey($c.item)) {
        $o = $mapOverrides[$c.item]
        $m = [pscustomobject]@{ board_id = $o.board_id; grams_per_unit = $o.grams_per_unit; unit = $o.unit }
    }
    if (-not $m) { Write-Warning "SKIP $($c.item): no ingredient-map row and no override"; continue }

    $f = $feed.ingredients.($m.board_id)
    if (-not $f -or -not $f.cheapest) { Write-Warning "SKIP $($c.item): board_id $($m.board_id) not priced in feed"; continue }
    if ($f.unit -ne $m.unit) { Write-Warning "SKIP $($c.item): unit mismatch (feed $($f.unit) vs map $($m.unit))"; continue }

    $cal = if ($null -ne $c.calO) { [double]$c.calO } else { [double]$dbItem.calories }
    $pg  = if ($null -ne $c.pgO)  { [double]$c.pgO }  else { [double]$dbItem.protein_g }
    $sg  = if ($null -ne $c.sgO)  { [double]$c.sgO }  else { [double]$dbItem.serving_grams }

    $rows += [pscustomobject]@{
        k   = $c.k
        n   = $c.n
        b   = $m.board_id
        cat = $c.cat
        cpg = [Math]::Round($cal / $sg, 6)   # calories per gram
        ppg = [Math]::Round($pg  / $sg, 6)   # protein grams per gram
        gpu = [double]$m.grams_per_unit
        u   = [string]$f.unit
        f   = [double]$f.cheapest            # baked fallback price per unit
        fs  = [string]$f.store
        kd  = [double]$c.kd
        ku  = [string]$c.ku
        r   = [bool]$c.raw
    }
}

if ($rows.Count -lt 14) { throw "Only $($rows.Count) rows survived; something is off, not writing." }

Write-Host ("{0,-24} {1,10} {2,10} {3,14} {4,14}" -f 'food', 'cal/g', 'prot/g', '$ per 1000kcal', '$ per g prot')
foreach ($r in ($rows | Sort-Object { ($_.f / $_.gpu) / $_.cpg })) {
    $ppgram = $r.f / $r.gpu
    $perK   = $ppgram / $r.cpg * 1000
    $perP   = if ($r.ppg -gt 0) { ('{0:F4}' -f ($ppgram / $r.ppg)) } else { '-' }
    Write-Host ("{0,-24} {1,10:F4} {2,10:F4} {3,14:F4} {4,14}" -f $r.n, $r.cpg, $r.ppg, $perK, $perP)
}

$parts = foreach ($r in $rows) {
    $rawFlag = if ($r.r) { 'true' } else { 'false' }
    '{{"k":"{0}","n":"{1}","b":"{2}","cat":"{3}","cpg":{4},"ppg":{5},"gpu":{6},"u":"{7}","f":{8},"fs":"{9}","kd":{10},"ku":"{11}","r":{12}}}' -f `
        $r.k, $r.n, $r.b, $r.cat, $r.cpg, $r.ppg, $r.gpu, $r.u, $r.f, $r.fs, $r.kd, $r.ku, $rawFlag
}

$js = 'var CD={week:"' + $feed.week_of + '",rows:[' + ($parts -join ',') + ']};'
Set-Content -Path $outPath -Value $js -Encoding utf8
Write-Host ""
Write-Host "Wrote $($rows.Count) rows to $outPath (week of $($feed.week_of))."
Write-Host "Paste the var CD= line over the one in cheap-day-tool.html."
