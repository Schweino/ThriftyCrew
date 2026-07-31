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
#  EXIT CODES (this audit is ADVISORY - it must never hold a board):
#    0 = ran, board and links agree
#    1 = ran, found disagreements. NOT a failure. Measured 2026-07-31: 5 findings, none on a pinned cell,
#        and a prior investigation of a 43-finding day found only 3 were wrong NUMBERS - in the other 40 the
#        BOARD was right and the LINK was stale. Blocking a publish on that would hold a correct board.
#    3 = could not evaluate (it had cells to check and checked none). The house rule: a check that examined
#        nothing must never report ok.
param([string]$OutDir = "")
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }

# -OutDir exists so a frozen fixture can point this at synthetic inputs. It had NO param() block at all,
# which is why it had no must-fire fixture: there was no way to feed it anything but the live board.
$cmpF = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -EA SilentlyContinue | Sort-Object Name -Desc | Select-Object -First 1
if (-not $cmpF) { Write-Output 'everyday-mismatch: COULD NOT EVALUATE - no comparison-*.json to read the board from'; exit 3 }
# -OutDir WINS. Production has product-urls.json at $root and nothing at out\, so this falls through to the
# real file exactly as before. A fixture directory that ships its own copy overrides it - which is the whole
# point, and the reason this order is not the other way round: $root's copy always exists, so checking it
# first would make every fixture silently read the LIVE links and prove nothing.
$puF = Join-Path $OutDir 'product-urls.json'
if (-not (Test-Path $puF)) { $puF = Join-Path $root 'product-urls.json' }
if (-not (Test-Path $puF)) { Write-Output 'everyday-mismatch: COULD NOT EVALUATE - no product-urls.json to compare the board against'; exit 3 }
$cmp = Get-Content $cmpF.FullName -Raw | ConvertFrom-Json
$pu  = (Get-Content $puF -Raw | ConvertFrom-Json).items

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
$checked = 0; $saleSkipped = 0; $noLink = 0; $uncomputable = 0; $noBoardPu = 0

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
    # COUNT THIS SKIP TOO. It used to `continue` silently, so a board that somehow published no per_unit at
    # all would drain every cell out of $checked and still print a confident "MISMATCHES: 0". Every path out
    # of an eligible cell is now counted, which is what makes the blind test below trustworthy.
    if ($boardPu -le 0) { $noBoardPu++; continue }
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
        # $sp, NOT [double]$e.price. 579 of the 2,987 stored link prices are strings like "$1.88", and
        # [double] on one of those throws - inside the record for the FIRST bug found, under EAP=Stop, so
        # this audit died on its own first finding and reported nothing at all. $sp is that same price
        # already parsed safely at the top of this iteration, so there is nothing to re-derive here.
        price=$sp; size=[string]$e.size
        boardItem=[string]$s.item; linkItem=[string]$e.name
      })
    }
  }
}

Write-Output ("everyday cells with a link, checked : $checked")
Write-Output ("sale cells skipped (expected diff)  : $saleSkipped")
Write-Output ("uncomputable size                   : $uncomputable")
Write-Output ("board published no per-unit         : $noBoardPu")
Write-Output ("")

# COVERAGE, so the ledger can see this check going quiet the way it sees every other one. Eligible is every
# everyday cell we HELD A LINK FOR - the cells we intended to check - so the count does not move just because
# the board gained sale cells or linkless ones.
$eligible = $checked + $uncomputable + $noBoardPu
try {
  $covLib = Join-Path $root 'coverage-lib.ps1'
  if (Test-Path $covLib) {
    . $covLib
    if ($checked -le 0 -and $eligible -gt 0) {
      Write-CoverageRecord -Check 'audit-everyday-mismatch' -OutDir $OutDir -Eligible $eligible -Examined $checked -Detail 'everyday board cells compared against their own linked product' -Blind
    } else {
      Write-CoverageRecord -Check 'audit-everyday-mismatch' -OutDir $OutDir -Eligible $eligible -Examined $checked -Detail 'everyday board cells compared against their own linked product'
    }
  }
} catch { }

# NEVER REPORT A CLEAN BOARD OVER AN EMPTY EXAMINATION. If there were eligible everyday cells and not one of
# them survived to be compared, this audit proved nothing, and "MISMATCHES: 0" would be the most misleading
# line it could print. $eligible -eq 0 is a different thing - a board with no linked everyday cells at all -
# and that is a genuine, honest zero, so it stays a clean exit rather than crying wolf.
if ($eligible -gt 0 -and $checked -eq 0) {
  Write-Output ("everyday-mismatch: COULD NOT EVALUATE - " + $eligible + " everyday cell(s) had a link and NONE of them could be compared (uncomputable size " + $uncomputable + ", no board per-unit " + $noBoardPu + ")")
  exit 3
}

Write-Output ("EVERYDAY MISMATCHES (board disagrees with its own linked product): " + $bugs.Count)
foreach ($b in ($bugs | Sort-Object { -[math]::Abs($_.ratio - 1) })) {
  Write-Output ("  {0,-24} {1,-12} board={2,-9} link={3,-9} x{4,-6} `${5} [{6}]" -f $b.id, $b.store, $b.board, $b.link, $b.ratio, $b.price, $b.size)
  if ($b.boardItem -ne $b.linkItem) { Write-Output ("      board item: " + $b.boardItem) ; Write-Output ("      link  item: " + $b.linkItem) }
}
# .ToArray() on the ArrayList, not @( ). See the audit-ff-carry note: in PS 5.1 the array subexpression @( )
# around a List[object] throws ArgumentException, and it also keeps the JSON shape right at every size -
# [] at zero and [ {..} ] at one, where a bare list would unwrap a single finding into an object.
$outF = Join-Path $OutDir 'everyday-mismatches.json'
$bugs.ToArray() | ConvertTo-Json -Depth 5 | Set-Content $outF -Encoding UTF8
Write-Output ''
Write-Output ('saved -> ' + $outF)

# ADVISORY. Exit 1 says "I found disagreements", NOT "hold the board" - see the exit-code note at the top.
if ($bugs.Count -gt 0) { exit 1 }
exit 0


