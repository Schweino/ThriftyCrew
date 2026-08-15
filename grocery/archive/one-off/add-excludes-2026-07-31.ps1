<#
  Insert exclude patterns into named commodities in commodities.json by TARGETED TEXT EDIT.
  Same method (and same reasons) as add-excludes-2026-07-29.ps1: this file is ~2 MB, a ConvertFrom/ConvertTo
  round trip reformats every line, and a bare regex -replace on a file full of backslashes has already
  produced a literal '\\b' once. Patterns are written FILE-ESCAPED (backslashes doubled) because JSON
  unescapes them on load, and every one is proven against the product it must kill AND a product it must
  NOT kill before a byte is written.

  TRIAGE 2026-07-31, plan-2026-07-31.json items fa3102 + f3fd16.

  1. FORM-SILENT BRANDS (fa3102). The exclusion system is token-based, and a frozen or canned product whose
     label carries no form word ('frozen', 'canned', 'pickled') can win any FRESH commodity. Two did:
       - 'Pictsweet Family Size Chopped Spinach' (32 oz, Walmart, $0.115/oz) held the CROWN on fresh spinach,
         at half the real fresh crown. Pictsweet is a frozen-vegetable brand; the name never says so.
       - 'San Marcos Traditional Recipe Crunchy Whole Jalapenos Peppers 26 Oz' (Family Fare, $1.3477/lb) held
         the CROWN on fresh jalapenos, beating six rows of actual fresh peppers. San Marcos is a canned
         escabeche brand; the name never says so.
     The estate's existing answer to this class is to name the BRAND (spinach already excludes 'birds eye').
     These are two more form-silent brands. Kept PER-COMMODITY, never global: Pictsweet legitimately belongs
     to frozen-chopped-spinach and San Marcos to the chipotle/pickled commodities.
     sweet-potatoes is PREVENTIVE, measured: 'Pictsweet Farms Sweet Potatoes' 18 oz sits in the Fareway
     capture at $3.09/lb and is form-silent too; it loses to fresh at $0.97-1.79/lb today, but only by price.

  2. CONJUNCTION-DEPENDENT EXCLUDES THAT STOPPED FIRING (f3fd16). Store catalogs strip punctuation on rename.
     Aldi's 07-29 capture renamed 'Mushrooms Pieces & Stems' to 'Mushrooms Pieces Stems', and every one of
     mushrooms' three protective excludes requires the conjunction - so the CANNED product fell into the
     FRESH commodity (array index 51, ahead of canned-mushrooms at 192), where first-match-wins kept it and
     canned-mushrooms lost its Aldi cell entirely. The engine's normalization deliberately does not apply to
     excludes (normalizing an exclude could UN-exclude), so the fix is to spell the stripped form out.
     MEASURED over 28,316 distinct product names across out\regular + out\sams + out\bakers + out\fareway:
     10 conjunction-dependent excludes exist estate-wide and exactly TWO have a live name demonstrating the
     stripped form - mushrooms (1 name) and rice (2 names that reach the commodity):
       'Kroger 90 Second Roasted Chicken Rice' and 'Progresso Traditional Chicken Rice with Vegetables Soup'
     are both CLAIMED by the raw-rice commodity today (rice does not exclude 'soup'), because its
     'chicken\s+and\s+rice' exclude cannot see 'Chicken Rice'. Neither holds the cell, so no board number
     changes; the rule is simply doing what it was written to do again.
     The other 8 have ZERO matching names and are deliberately left alone - a rule with nothing to match is
     speculation, and speculation in this file is how commodities start eating each other.
     'stems\s+pieces' is added alongside 'pieces\s+stems' with no live name of its own because mushrooms
     already carries BOTH conjunction spellings; leaving the pair half-mirrored is how the next rename wins.
#>
param([switch]$Apply)
$ErrorActionPreference = 'Stop'
$path = 'C:\Codex\ThriftyCrew\grocery\commodities.json'

# id -> file-escaped patterns to add
$adds = [ordered]@{
  'spinach'        = @('\\bpictsweet\\b')
  'sweet-potatoes' = @('\\bpictsweet\\b')
  'jalapenos'      = @('\\bsan\\s*marcos\\b')
  'mushrooms'      = @('pieces\\s+stems', 'stems\\s+pieces')
  'rice'           = @('chicken\\s+rice')
}

# (id, product that MUST be killed, product that must SURVIVE) - all read from live captures
$proofs = @(
  @('spinach',        'Pictsweet Family Size Chopped Spinach',                                 'Little Salad Bar Spinach 8 OZ'),
  @('spinach',        'Pictsweet Family Size Chopped Spinach',                                 'Fresh Express Salad, Baby Spinach 10 Oz'),
  @('sweet-potatoes', 'Pictsweet Farms Sweet Potatoes',                                        'Sweet Potatoes Whole Fresh, 3 lb Bag'),
  @('jalapenos',      'San Marcos Traditional Recipe Crunchy Whole Jalapenos Peppers 26 Oz',   'Fresh Jalapenos, Each'),
  @('jalapenos',      'San Marcos Traditional Recipe Crunchy Whole Jalapeno Peppers 11 Oz',    'Jalapeno Peppers, Package'),
  @('mushrooms',      'Happy Harvest Mushrooms Pieces Stems 4 OZ',                             'White Mushroom 8 OZ'),
  @('mushrooms',      'Happy Harvest Mushrooms Pieces Stems 4 OZ',                             'Whole White Mushrooms 24 oz.'),
  @('rice',           'Kroger 90 Second Roasted Chicken Rice',                                 'Kroger Enriched Long Grain White Rice'),
  @('rice',           'Progresso Traditional Chicken Rice with Vegetables Soup',               "Member's Mark Long Grain White Rice, 50 lbs.")
)

$text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
$lines = $text -split "`r?`n"

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
  else { Write-Output ("ok    [$id] '$($killed[0])' kills the intruder, '$keep' survives") }
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
