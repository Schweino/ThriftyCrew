<#
  audit-everyday-mismatch.ps1 - the REAL price-accuracy audit.

  audit-links reports 118 "mismatches", but most are not errors: a Hy-Vee cell showing the weekly-ad
  SALE price ($6.99/lb sirloin) legitimately differs from the regular price on the product page the
  link opens ($13.99/lb). That is by design.

  A mismatch is only a BUG when the board cell is an EVERYDAY cell, because then the board and the
  linked product are claiming to be the same number and they disagree. One of them is wrong.

  For each everyday cell with a link we recompute the link's per-unit from its own price+size and
  compare it to what the board publishes.
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$cmp = Get-Content (Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Desc | Select-Object -First 1).FullName -Raw | ConvertFrom-Json
$pu  = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items

# A multipack's total is packs x unit-size, and the pack count often lives in the NAME
# ("Fareway 24 Pack Purified Drinking Water", size="each") rather than the size field. Missing that
# makes a CORRECT board cell look 6x/12x/24x wrong - it was the source of every false positive on
# the first run of this audit. Read the pack count from size OR name.
function Qty([string]$size, [string]$name, [string]$unit) {
  $s = ("" + $size).ToLower()
  $nm = ("" + $name).ToLower()
  # The pack count only MULTIPLIES a weight when it appears in the SIZE field ("6 pk 16 oz"), because
  # our size convention already records the TOTAL when it is a single weight: "Applesauce Cups 6 Count"
  # with size "24 oz" is 24 oz TOTAL, not 6 x 24. Multiplying by a pack read from the NAME made six
  # correct cells look 6x-12x wrong. For an 'each' commodity the pack IS the quantity, so there the
  # name is allowed (Fareway "24 Pack" bottled water, size "each" = 24 bottles).
  $pkSize = 1
  $pmS = [regex]::Match($s, '(\d+)\s*(?:x|pk\b|pack\b|ct\b|count\b)')
  if ($pmS.Success) { $pkSize = [double]$pmS.Groups[1].Value }
  $pkAny = $pkSize
  if ($pkAny -le 1) {
    $pmN = [regex]::Match($nm, '(\d+)\s*(?:x|pk\b|pack\b|ct\b|count\b)')
    if ($pmN.Success) { $pkAny = [double]$pmN.Groups[1].Value }
  }
  $pk = $pkSize
  $m = [regex]::Matches($s, '([\d.]+)\s*(fl\s?oz|floz|oz|lbs?|pound|gal|qt|l|ml|g)\b')
  if ($m.Count -eq 0) {
    if ($unit -eq 'each') { return $pkAny }                               # per-item: qty = item count (name ok)
    if ($unit -eq 'lb'   -and $s -match '^\s*lb\s*$')   { return 1 }      # a per-lb shelf price
    if ($unit -eq 'gallon' -and $s -match '^\s*gal') { return 1 }
    return 0
  }
  $last = $m[$m.Count-1]
  $n = [double]$last.Groups[1].Value
  $u = $last.Groups[2].Value -replace '\s',''
  $base = 0.0
  switch ($unit) {
    'oz'     { if ($u -eq 'oz') { $base=$n } elseif ($u -match '^(lbs?|pound)$') { $base=$n*16 } elseif ($u -eq 'g') { $base=$n*0.035274 } }
    'floz'   { if ($u -match '^(floz|oz)$') { $base=$n } elseif ($u -eq 'l') { $base=$n*33.814 } elseif ($u -eq 'ml') { $base=$n*0.033814 } elseif ($u -eq 'gal') { $base=$n*128 } elseif ($u -eq 'qt') { $base=$n*32 } }
    'lb'     { if ($u -match '^(lbs?|pound)$') { $base=$n } elseif ($u -eq 'oz') { $base=$n/16 } }
    'gallon' { if ($u -eq 'gal') { $base=$n } elseif ($u -match '^(floz|oz)$') { $base=$n/128 } }
    'each'   { return $pkAny }
    'dozen'  { if ($u -match '^(ct|count)$') { $base=$n/12 } else { $base = 0 } }
    default  { $base = 0 }
  }
  if ($base -le 0) { return 0 }
  if ($pk -gt 1) { $base = $base * $pk }        # N pk of M oz = N*M total, however it was written
  return $base
}

$bugs = New-Object System.Collections.ArrayList
$checked = 0; $saleSkipped = 0; $noLink = 0; $uncomputable = 0

foreach ($row in $cmp.comparison) {
  $id = [string]$row.id
  $link = $pu.$id
  if (-not $link) { continue }
  foreach ($s in $row.stores) {
    $store = [string]$s.store
    $e = $link.$store
    if (-not $e -or -not $e.price) { $noLink++; continue }
    if (([string]$s.type) -ne 'everyday') { $saleSkipped++; continue }   # a sale legitimately differs from the shelf price
    $q = Qty ([string]$e.size) ([string]$e.name) ([string]$row.unit)
    if ($q -le 0) { $uncomputable++; continue }
    $linkPu = [double]$e.price / $q
    $boardPu = [double]$s.per_unit
    if ($boardPu -le 0) { continue }
    $checked++
    $diff = [math]::Abs($linkPu - $boardPu) / $boardPu
    if ($diff -gt 0.02) {
      [void]$bugs.Add([pscustomobject]@{
        id=$id; store=$store; unit=[string]$row.unit
        board=[math]::Round($boardPu,4); link=[math]::Round($linkPu,4)
        ratio=[math]::Round($linkPu/$boardPu,2)
        price=[double]$e.price; size=[string]$e.size
        boardItem=[string]$s.item; linkItem=[string]$e.name
      })
    }
  }
}

Write-Output ("everyday cells with a link, checked : $checked")
Write-Output ("sale cells skipped (expected diff)  : $saleSkipped")
Write-Output ("uncomputable size                   : $uncomputable")
Write-Output ("")
Write-Output ("EVERYDAY MISMATCHES (board disagrees with its own linked product): " + $bugs.Count)
foreach ($b in ($bugs | Sort-Object { -[math]::Abs($_.ratio - 1) })) {
  Write-Output ("  {0,-24} {1,-12} board={2,-9} link={3,-9} x{4,-6} `${5} [{6}]" -f $b.id, $b.store, $b.board, $b.link, $b.ratio, $b.price, $b.size)
  if ($b.boardItem -ne $b.linkItem) { Write-Output ("      board item: " + $b.boardItem) ; Write-Output ("      link  item: " + $b.linkItem) }
}
$bugs | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $root 'out\everyday-mismatches.json') -Encoding UTF8
Write-Output ''
Write-Output 'saved -> out\everyday-mismatches.json'


