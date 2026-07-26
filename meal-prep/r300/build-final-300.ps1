# build-final-300.ps1 - Merges selected.json + harvest H1-H8 into FINAL-300.json
# in the FINAL-100 shape (source_ingredients as {item, qty} pairs) so the r100
# normalize/parse pipeline ports directly. Verbatim lines are preserved in raw_line.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$sel = (Get-Content (Join-Path $here 'selected.json') -Raw -Encoding utf8 | ConvertFrom-Json).selected
$harvest = @{}
foreach ($f in Get-ChildItem (Join-Path $here 'harvest\H*.json') | Where-Object { $_.Name -match '^H\d\.json$' }) {
    foreach ($r in ((Get-Content $f.FullName -Raw -Encoding utf8 | ConvertFrom-Json).recipes)) { $harvest[$r.slug] = $r }
}

$UNITS = @('lb','lbs','pound','pounds','oz','ounce','ounces','cup','cups','tbsp','tbs','tablespoon','tablespoons','tsp','teaspoon','teaspoons','g','gram','grams','kg','kilo','kilogram','kilograms','ml','l','liter','liters','litre','litres','quart','quarts','pint','pints','can','cans','jar','jars','package','packages','pkg','packet','packets','box','boxes','bag','bags','slice','slices','clove','cloves','bunch','bunches','head','heads','stalk','stalks','rib','ribs','sprig','sprigs','stick','sticks','piece','pieces','fillet','fillets','link','links','ear','ears','knob','dash','dashes','pinch','pinches','handful','handfuls','block','blocks','container','sheet','sheets','cube','cubes','strip','strips','bottle','bottles','tin','tins')
$SIZEADJ = @('large','medium','small','extra-large','xl','heaping','scant','level','generous','big','thick','thin','whole','half','baby')
$unitSet = @{}; foreach ($u in $UNITS) { $unitSet[$u] = 1 }
$sizeSet = @{}; foreach ($s in $SIZEADJ) { $sizeSet[$s] = 1 }

function NormalizeLine([string]$t) {
    $t = $t -replace [char]0x25A2, ''            # checkbox glyph
    $t = $t -replace [char]0x2013, '-' -replace [char]0x2014, '-'
    $t = $t -replace [char]0x00BD, ' 1/2' -replace [char]0x00BC, ' 1/4' -replace [char]0x00BE, ' 3/4'
    $t = $t -replace [char]0x2153, ' 1/3' -replace [char]0x2154, ' 2/3' -replace [char]0x215B, ' 1/8' -replace [char]0x215C, ' 3/8' -replace [char]0x215D, ' 5/8' -replace [char]0x215E, ' 7/8'
    $t = $t -replace '\(\$[0-9][^)]*\)', ''       # Budget Bytes inline costs
    ($t -replace '\s+', ' ').Trim()
}

function IsHeader([string]$t) {
    if ($t -match '\d') { return $false }
    if ($t -match ':\s*$') { return $true }
    if ($t.Length -le 30 -and $t -ceq $t.ToUpper() -and $t -match '[A-Z]') { return $true }
    if ($t -match '^(?i)for the\b[^,]*$' -and $t.Split(' ').Count -le 5) { return $true }
    return $false
}

function IsNumTok([string]$tok) {
    return ($tok -match '^\d+([./]\d+)?(-\d+([./]\d+)?)?$' -or $tok -match '^\d+\s*$')
}

function SplitLine([string]$line) {
    # returns @{qty; item}
    $toks = $line.Split(' ')
    $i = 0; $qtyToks = @()
    $sawNum = $false
    while ($i -lt $toks.Count) {
        $tok = $toks[$i]; $lower = $tok.ToLower().Trim(',').TrimEnd('.')
        if ($tok -match '^\(') {
            # consume balanced parenthetical only if we are already inside a qty prefix
            if ($qtyToks.Count -eq 0) { break }
            $depth = 0; $j = $i
            while ($j -lt $toks.Count) {
                $depth += ([regex]::Matches($toks[$j], '\(')).Count - ([regex]::Matches($toks[$j], '\)')).Count
                $qtyToks += $toks[$j]; $j++
                if ($depth -le 0) { break }
            }
            $i = $j; continue
        }
        if (IsNumTok $lower) { $qtyToks += $tok; $sawNum = $true; $i++; continue }
        if ($lower -match '^\d+(\.\d+)?(g|kg|ml|l|oz|lb|lbs)$') { $qtyToks += $tok; $sawNum = $true; $i++; continue }  # "500g"
        if ($sawNum -and ($lower -eq 'to' -or $lower -eq 'or' -or $lower -eq '-') -and ($i + 1) -lt $toks.Count -and (IsNumTok $toks[$i+1].ToLower())) { $qtyToks += $tok; $i++; continue }
        if ($sawNum -and $unitSet.ContainsKey($lower)) { $qtyToks += $tok; $i++;
            if ($i -lt $toks.Count -and $toks[$i].ToLower() -eq 'of') { $qtyToks += $toks[$i]; $i++ }
            continue }
        if ($sawNum -and $sizeSet.ContainsKey($lower)) { $qtyToks += $tok; $i++; continue }
        if (-not $sawNum -and ($lower -eq 'a' -or $lower -eq 'an')) { $qtyToks += $tok; $sawNum = $true; $i++; continue }
        break
    }
    $qty = ($qtyToks -join ' ').Trim()
    $item = (($toks | Select-Object -Skip ($qtyToks.Count)) -join ' ').Trim()
    if (-not $item) { $item = $qty; $qty = '' }   # line was all qty-ish (rare); keep as item
    return @{ qty = $qty; item = $item }
}

$out = @(); $headerCount = 0; $noQty = 0; $lineCount = 0
foreach ($s in $sel) {
    $h = $harvest[$s.slug]
    if (-not $h) { throw "no harvest record for $($s.slug)" }
    $ings = @()
    foreach ($lineRaw in $h.ingredients) {
        $line = NormalizeLine ([string]$lineRaw)
        if (-not $line) { continue }
        if (IsHeader $line) { $headerCount++; continue }
        $split = SplitLine $line
        if (-not $split.qty) { $noQty++ }
        $ings += [pscustomobject]@{ item = $split.item; qty = $split.qty; raw_line = [string]$lineRaw }
        $lineCount++
    }
    $site = ([uri]$s.source_url).Host -replace '^www\.', ''
    $out += [pscustomobject]@{
        proposed_name = $s.name; slug = $s.slug; pk = $s.protein; cuisine = $s.cuisine
        format = $h.method; source_url = $s.source_url; source_site = $site
        source_servings = $h.source_servings
        source_nutrition_per_serving = $h.nutrition
        est_cal_per_serving = $s.est_cal
        notes = ("SELECTOR: " + $s.why + " | HARVEST: " + $h.notes)
        unmapped_flags = $s.unmapped_flags
        source_ingredients = $ings
    }
}
$out | ConvertTo-Json -Depth 8 | Out-File (Join-Path $here 'FINAL-300.json') -Encoding utf8
Write-Output ("recipes: {0}  ingredient lines: {1}  headers skipped: {2}  lines w/o qty: {3}" -f $out.Count, $lineCount, $headerCount, $noQty)
