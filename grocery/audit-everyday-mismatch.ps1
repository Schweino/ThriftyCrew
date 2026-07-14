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
# Per-unit math is shared with build-deals-page (the code that actually publishes the number) via
# pu-lib.ps1. This file used to carry its own weaker copy, which returned 0 - "skip this cell" - for
# sizes the published math handles fine ("per lb", a bare "lb", "24 fl oz" on an oz commodity, "dozen",
# a "$0.07/oz" unit price in the size field), silently excluding 8.6% of linked cells from the check.
. (Join-Path $root 'pu-lib.ps1')

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
    $sp = 0.0; [void][double]::TryParse((([string]$e.price) -replace '[^0-9.]',''), [ref]$sp)
    $linkPu = Get-LinkPerUnit -size ([string]$e.size) -unit ([string]$row.unit) -price $sp -name ([string]$e.name)
    if ($null -eq $linkPu) { $uncomputable++; continue }
    $boardPu = [double]$s.per_unit
    if ($boardPu -le 0) { continue }
    $checked++
    $diff = [math]::Abs($linkPu - $boardPu) / $boardPu
    # HALF-CENT RULE. Some links record the STORE'S OWN unit price in the size field ("$0.06/oz"), already
    # rounded to the cent. On a cheap item that rounding is huge in percentage terms and nothing else: a can
    # of beans at $1.00/15.5 oz is $0.0645/oz, which the store prints as "$0.06/oz" - a 7% "mismatch" that
    # is really just two decimal places. Anything agreeing to within half a cent per unit is below the
    # precision either side can express, so it cannot be a real disagreement.
    if ($diff -gt 0.02 -and [math]::Abs($linkPu - $boardPu) -gt 0.005) {
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


