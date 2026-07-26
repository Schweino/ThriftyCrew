# port-planner-packages.ps1 - ports r300 cost-engine $PKG entries (and label-file package sizes)
# into planner-extra-packages.json for the 48 items gen-planner-data reported missing.
# TEXT-SAFE editing (never round-trips the json through ConvertTo-Json - the PS5.1 wrap trap).
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp = Split-Path -Parent $here
$LB = 453.592

$missing = @('Aji Amarillo Paste','Almonds','Apple Juice','Artichoke Hearts','Baked Beans','Baking Powder','Baking Soda','Basil Pesto','Beef Flank/Sirloin Steak','Blackberries','Bratwurst','Brown Gravy Mix','Brussels Sprouts','Bulgur Wheat','Caraway Seeds','Chicken Livers','Cocoa Powder','Cream of Chicken Soup','Cream of Mushroom Soup','Diced Ham','Doubanjiang','Dried Ancho Chiles','Dried Arbol Chiles','Dried Guajillo Chiles','Eggplant','Gingersnap Cookies','Ground Fennel','Horseradish Sauce','Kale','Keto Bun','Korean Rice Cakes','Onion Soup Mix','Pasta Shells - jumbo','Pigeon Peas','Pork Shoulder','Poultry Seasoning','Pumpkin Puree','Rye Bread','Sandwich Bread','Sauerkraut','Sazon Seasoning','Snow Peas','Stuffing Mix','Sumac','Sweet Soy Sauce','Tater Tots','Turkey Breast','Wild Rice')

# source 1: r300 cost-engine $PKG block
$src = Get-Content (Join-Path $here 'cost-engine.ps1') -Raw
$pkgBlock = [regex]::Match($src, '(?s)\$PKG = @\{(.*?)\r?\n\}').Groups[1].Value
$found = @{}
foreach ($m in [regex]::Matches($pkgBlock, "'([^']+)'\s*=\s*@\{g=([^;]+);label='([^']+)'\}")) {
    $g = $m.Groups[2].Value.Trim()
    if ($g -eq '$LB') { $g = $LB }
    $found[$m.Groups[1].Value] = @{ g = [double]$g; label = $m.Groups[3].Value }
}
# source 2: r300 pantry-packages (bulk staples)
foreach ($p in ((Get-Content (Join-Path $here 'pantry-packages.json') -Raw | ConvertFrom-Json).packages).PSObject.Properties) {
    if (-not $found.ContainsKey($p.Name)) { $found[$p.Name] = @{ g = [double]$p.Value.g; label = [string]$p.Value.label } }
}
# source 3: labels-r300 package sizes
foreach ($r in (Get-Content (Join-Path $here 'labels-r300.json') -Raw | ConvertFrom-Json)) {
    if (-not $found.ContainsKey($r.item)) {
        $sz = [string]$r.package_size
        $g = $null
        if ($sz -match '([\d.]+)\s*oz') { $g = [double]$Matches[1] * 28.3495 }
        if ($g) { $found[$r.item] = @{ g = [math]::Round($g,1); label = $sz } }
    }
}

$add = @(); $unresolved = @()
foreach ($item in $missing) {
    if ($found.ContainsKey($item)) {
        $e = $found[$item]
        $add += ('    "' + $item + '": { "g": ' + $e.g + ', "label": "' + $e.label + '" }')
    } else { $unresolved += $item }
}
if ($unresolved.Count -gt 0) { Write-Output ("UNRESOLVED (no r300 basis): " + ($unresolved -join ', ')) }

$pePath = Join-Path $mp 'planner-extra-packages.json'
$raw = Get-Content $pePath -Raw -Encoding utf8
# skip items already present
$add = @($add | Where-Object { $nm = ($_ -split '"')[1]; $raw -notmatch ('"' + [regex]::Escape($nm) + '"') })
if ($add.Count -eq 0) { Write-Output 'nothing to add'; exit 0 }
# insert before the final closing brace of "packages" (last occurrence of a line with only spaces+})
$insertAt = $raw.LastIndexOf('}')          # end of file object
$insertAt = $raw.LastIndexOf('}', $insertAt - 1)   # end of packages object
# find the last entry line end before that
$before = $raw.Substring(0, $insertAt).TrimEnd()
if (-not $before.EndsWith(',')) { $before += ',' }
$newText = $before + "`r`n" + (($add) -join ",`r`n") + "`r`n  }" + $raw.Substring($raw.LastIndexOf('}'))
[System.IO.File]::WriteAllText($pePath, $newText, (New-Object System.Text.UTF8Encoding($true)))
$chk = Get-Content $pePath -Raw -Encoding utf8 | ConvertFrom-Json
Write-Output ("planner-extra-packages now {0} entries (+{1})" -f @($chk.packages.PSObject.Properties).Count, $add.Count)
