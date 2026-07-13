# Round-2 fixes: remaining thefts/globals + unit-shape data fixes in store files.
$ErrorActionPreference = 'Stop'
$root = 'C:\Codex\income\grocery'
$cf = Join-Path $root 'commodities.json'
$tmp = ConvertFrom-Json ([IO.File]::ReadAllText($cf)); $commods = @($tmp)
$byId = @{}; foreach ($c in $commods) { $byId[[string]$c.id] = $c }
function AddInc([string]$id, [string[]]$pats) { $c = $byId[$id]; if ($c) { foreach ($p in $pats) { if (@($c.include) -notcontains $p) { $c.include = @($c.include) + @($p) } } } }
function AddExc([string]$id, [string[]]$pats) { $c = $byId[$id]; if ($c) { foreach ($p in $pats) { if (@($c.exclude) -notcontains $p) { $c.exclude = @($c.exclude) + @($p) } } } }
function AddRelax([string]$id, [string[]]$pats) { $c = $byId[$id]; if (-not $c) { return }; if (-not $c.PSObject.Properties['relax_global']) { $c | Add-Member relax_global @() }; foreach ($p in $pats) { if (@($c.relax_global) -notcontains $p) { $c.relax_global = @($c.relax_global) + @($p) } } }

AddExc 'rice'          @('rice\s+cakes?', '\bdog\b', '\bcat\b', 'chicken\s+and\s+rice')
AddExc 'eggs'          @('\bpasta\b', 'sandwich', 'croissant', 'biscuit')
AddExc 'mushrooms'     @('pieces\s*(?:&|and)\s*stems', 'stems\s*(?:&|and)\s*pieces')
AddExc 'strawberries'  @('unsweetened')
AddExc 'bottled-water' @('\bwash\b', '\bsoap\b', 'body')
AddExc 'watermelon'    @('\bpops?\b', 'fruity')
AddExc 'shrimp'        @('\bcat\b', '\bflavors\b')
AddExc 'butter'        @('croissant')
$cr = $byId['croissants']; if ($cr) { $cr.exclude = @($cr.exclude | ForEach-Object { if ($_ -eq 'sandwich') { 'breakfast\s+sandwich' } else { $_ } }) }
AddRelax 'baby-back-ribs'    @('\bfrozen\b')
AddRelax 'chicken-wings'     @('\bfrozen\b')
AddRelax 'stuffing-mix'      @('flavored')
AddRelax 'microwave-popcorn' @('flavored')
AddRelax 'frozen-vegetables' @('\bmeal\b')
AddRelax 'sandwich-bags'     @('\bsnack\b')
AddRelax 'cat-food'          @('\bmix\b(?!\s*(?:&|and)\s*match)')
AddRelax 'dog-food'          @('\bmix\b(?!\s*(?:&|and)\s*match)')
AddInc 'lasagna-noodles' @('oven\s+ready\b.{0,20}lasagna', 'no\s+boil\b.{0,15}lasagna', 'lasagna\s+pasta')
$c = $byId['batteries']; if ($c) { $c.band_min = 0.15 }
ConvertTo-Json @($commods) -Depth 6 | Set-Content $cf -Encoding UTF8
Write-Output 'r2 rules applied'

# ---- data shape fixes (unit-each items recorded with oz/sq-ft/lb sizes -> counts) ----
function FixRows([string]$file, $fixes) {
  $t = ConvertFrom-Json ([IO.File]::ReadAllText($file)); $rows = @($t)
  foreach ($r in $rows) { $k = [string]$r.id; if ($fixes.ContainsKey($k) -and [string]$r.size -eq $fixes[$k][0]) { $r.size = $fixes[$k][1] } }
  ConvertTo-Json @($rows) -Depth 4 | Set-Content $file -Encoding UTF8
}
# fareway shop file (regenerates regular)
FixRows (Join-Path $root 'out\fareway\fareway-shop-verify.json') @{ 'string-cheese' = @('12 ct','12 oz') }
# hyvee regular-source agent file then re-append is complex; fix the REGULAR files directly by item name:
function FixReg([string]$file, $nameFixes) {
  $doc = ConvertFrom-Json ([IO.File]::ReadAllText($file))
  foreach ($d in $doc.deals) { $k = [string]$d.item; if ($nameFixes.ContainsKey($k)) { $d.size = $nameFixes[$k] } }
  $doc | ConvertTo-Json -Depth 6 | Set-Content $file -Encoding UTF8
}
FixReg (Join-Path $root 'out\regular\hyvee-regular-2026-07-12.json') @{
  'Duncan Hines Family Size Chewy Fudge Brownie Mix, 18.3 oz.' = '1 ct'
  'Hy-Vee Plastic Wrap' = '1 ct' }
FixReg (Join-Path $root 'out\regular\aldi-regular-2026-07-12.json') @{
  "L'oven Fresh Plain English Muffins" = '6 ct'
  'Bake Shop Blueberry Muffins' = '4 ct'
  "L'oven Fresh Hot Dog Buns" = '8 ct'
  'Boulder Parchment Paper' = '1 ct' }
FixReg (Join-Path $root 'out\regular\bakers-regular-2026-07-12.json') @{
  "Totino's Party Pizza Pepperoni Thin Crust" = '1 ct' }
$smF = Get-ChildItem (Join-Path $root 'out\sams\sams-deals-*.json') | Sort-Object Name -Descending | Select-Object -First 1
FixReg $smF.FullName @{
  'Frigo Cheese Heads String Cheese' = '48 oz'
  'Kingsford Original Charcoal Briquets' = '40 lb' }
Write-Output 'data shapes fixed'
