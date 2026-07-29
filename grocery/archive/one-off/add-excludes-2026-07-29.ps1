<#
  Insert exclude patterns into named commodities in commodities.json by TARGETED TEXT EDIT.

  Not ConvertFrom-Json / ConvertTo-Json: this file is ~1 MB with 34,889 exclude patterns and a round trip
  would reformat every line, so a one-line rule change would arrive as a whole-file diff nobody can review.
  Not a regex -replace either: the patterns themselves are full of backslashes, and a text -replace on this
  file has already produced a literal '\\b' once today.

  Patterns are written here EXACTLY as they must appear in the FILE, i.e. with backslashes doubled, because
  JSON unescapes them on load. Every one is verified against its target product and against a product it must
  NOT kill before anything is written.
#>
param([switch]$Apply)
$ErrorActionPreference = 'Stop'
$path = 'C:\Codex\income\grocery\commodities.json'

# id -> file-escaped patterns to add
$adds = [ordered]@{
  'pomegranates'       = @('\\bchews?\\b', '\\bsupplements?\\b', '\\bsuperbeets\\b', '\\bgumm(?:y|ies)\\b')
  'beef-jerky'         = @('\\bwaggin', 'skin\\s*&?\\s*coat', '\\bfor\\s+(?:dogs?|cats?|pets?)\\b')
  'butter'             = @('\\balternatives?\\b', '\\bsubstitutes?\\b', '\\bwhirl\\b')
  'jalapenos'          = @('\\bseasonings?\\b', '\\brubs?\\b', '\\bchophouse\\b')
  'canned-black-beans' = @('\\b\\d{2,}\\s*lbs?\\.?\\b')
  'canned-pinto-beans' = @('\\b\\d{2,}\\s*lbs?\\.?\\b')
  'bacon'              = @('\\bmacaroni\\b', '\\bmac\\s+(?:and|&)\\s+cheese\\b', '\\bpork\\s+loin\\b')
  'coffee'             = @('coffee\\s*mate', 'half\\s*&?\\s*half', '\\bcreamers?\\b')
  'peaches'            = @('\\bbeauty\\s+bars?\\b', '\\bsoaps?\\b', '\\bbody\\s+wash\\b')
  'pears'              = @('in\\s+(?:heavy|light)\\s+syrup', '\\bfruit\\s+bowls?\\b')
  'clementines'        = @('\\bfruit\\s+bowls?\\b', '\\bin\\s+gel\\b', '\\bcups?\\b')
  'chocolate-chips'    = @('\\bloaf\\b', '\\bbrioche\\b')
  'fresh-ginger'       = @('\\bsqueeze\\b', '\\bminced\\b', '\\bpastes?\\b')
  'tomatoes'           = @('\\bchopped\\s+tomatoes\\b', '\\bpomi\\b')
  'rice'               = @('\\bready\\s+rice\\b', '\\bready\\s+to\\s+heat\\b', '\\bpouch\\b')
}

# (id, product that MUST be killed, product that must SURVIVE)
$proofs = @(
  @('pomegranates',       'Humann SuperBeets Heart Chews, Pomegranate Berry 90 ct.',                'Pomegranates'),
  @('beef-jerky',         "Waggin' Train, Salmon Jerky Tenders for Skin & Coat Support, 36 oz.",    'Jack Links Original Beef Jerky 10 oz'),
  @('butter',             'Whirl Butter Alternative, 128 oz.',                                      'Kroger Unsalted Butter 1 lb'),
  @('jalapenos',          'Chophouse Cajun Seasoning with Jalapeno',                                'Fresh Jalapeno Peppers'),
  @('canned-black-beans', "Member's Mark Black Beans 12 lbs.",                                      'Kroger Black Beans 15 oz Can'),
  @('canned-pinto-beans', "Member's Mark Pinto Beans 12 lbs.",                                      'Rosarita Pinto Beans 16 oz'),
  @('bacon',              'Private Selection Gruyere and Bacon White Cheddar Macaroni and Cheese',  'Oscar Mayer Center Cut Bacon 12 oz'),
  @('bacon',              'Smithfield Applewood Smoked Bacon Fresh Pork Loin Filet, 23 oz, 2 Pk.',  'Hormel Black Label Original Bacon 16 oz'),
  @('coffee',             'NESTLE COFFEE MATE Half & Half Tubs (24x0.304floz) Box',                 'Folgers Classic Roast Ground Coffee 30.5 oz'),
  @('peaches',            'Caress Silkening Daily Silk Beauty Bar, White Peach & Orange Blossom',   'Fresh Yellow Peaches'),
  @('pears',              'Del Monte Sliced Bartlett Pears in Heavy Syrup',                         'Fresh Bartlett Pears'),
  @('clementines',        'Dole Fruit Bowls Peaches, Mandarin Oranges, and Mixed Fruit in Gel, 4.3 oz Cups (12 Pack)', 'Halos Mandarins 3 lb Bag'),
  @('chocolate-chips',    'Specially Selected Chocolate Chip Sliced Brioche Loaf 17.6 OZ',          'Nestle Toll House Semi-Sweet Chocolate Chips 12 oz'),
  @('fresh-ginger',       'Spice World Squeeze Minced Ginger Seasoning 22.75 oz.',                  'Fresh Ginger Root'),
  @('tomatoes',           'Pomi Chopped Tomatoes, 26.46 oz',                                        'Fresh Roma Tomatoes'),
  @('rice',              "Ben's Original Ready Rice Jasmine Rice, 17.3 oz Pouch",                   'Kroger Long Grain White Rice 32 oz')
)

$text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
$lines = $text -split "`r?`n"

# ---- locate each commodity's "exclude": [ line
function Get-ExcludeLineIndex([string[]]$L, [string]$id) {
  $idIdx = -1
  for ($i = 0; $i -lt $L.Count; $i++) {
    if ($L[$i] -match ('^\s*"id":\s*"' + [regex]::Escape($id) + '",\s*$')) { $idIdx = $i; break }
  }
  if ($idIdx -lt 0) { throw "commodity not found: $id" }
  for ($j = $idIdx; $j -lt [Math]::Min($idIdx + 40, $L.Count); $j++) {
    if ($L[$j] -match '^\s*"exclude":\s*\[\s*$') { return $j }
  }
  throw "no exclude array within 40 lines of id $id"
}

# ---- PROVE every pattern before writing anything
$bad = 0
foreach ($p in $proofs) {
  $id = $p[0]; $kill = $p[1]; $keep = $p[2]
  $pats = @($adds[$id]) | ForEach-Object { $_ -replace '\\\\', '\' }   # file-escaped -> real regex
  $killed = @($pats | Where-Object { $kill -imatch $_ })
  $keptHit = @($pats | Where-Object { $keep -imatch $_ })
  if ($killed.Count -eq 0) { Write-Output ("FAIL  [$id] nothing kills: $kill"); $bad++ }
  elseif ($keptHit.Count -gt 0) { Write-Output ("FAIL  [$id] '$($keptHit -join ',')' would ALSO kill a legit item: $keep"); $bad++ }
  else { Write-Output ("ok    [$id] '$($killed[0])' kills the intruder, legit item survives") }
}
if ($bad) { Write-Output "$bad proof(s) FAILED - writing nothing."; exit 1 }

# ---- insert, deepest line first so earlier indexes stay valid
$plan = @()
foreach ($id in $adds.Keys) { $plan += [pscustomobject]@{ id = $id; idx = (Get-ExcludeLineIndex $lines $id) } }
$plan = @($plan | Sort-Object idx -Descending)

$out = New-Object System.Collections.Generic.List[string]
$out.AddRange([string[]]$lines)
$added = 0
foreach ($p in $plan) {
  $existing = @()
  for ($j = $p.idx + 1; $j -lt $out.Count; $j++) { if ($out[$j] -match '^\s*\]') { break }; $existing += $out[$j].Trim().TrimEnd(',').Trim('"') }
  $ins = @()
  foreach ($pat in @($adds[$p.id])) {
    if ($existing -contains $pat) { Write-Output ("  skip [$($p.id)] already present: $pat"); continue }
    $ins += ('                        "' + $pat + '",')
    $added++
  }
  if ($ins.Count) { $out.InsertRange($p.idx + 1, [string[]]$ins) }
}
Write-Output ("inserted $added exclude pattern(s) across $($plan.Count) commodities")
if (-not $Apply) { Write-Output 'DRY RUN - pass -Apply to write.'; exit 0 }

$new = [string]::Join("`r`n", $out.ToArray())
$null = $new | ConvertFrom-Json          # parse gate: refuse to write invalid JSON
[IO.File]::WriteAllText($path, $new, (New-Object Text.UTF8Encoding($true)))
Write-Output 'commodities.json written and re-parsed clean.'
