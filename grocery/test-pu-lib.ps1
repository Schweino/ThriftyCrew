<#
  test-pu-lib.ps1 - frozen fixtures for pu-lib.ps1 (Get-LinkPerUnit), the ONE per-unit implementation.

  WHAT THIS USED TO BE, AND WHY IT WAS PERMANENTLY RED (fixed 2026-08-22). This file was written as a
  differential test: run the new shared Get-LinkPerUnit beside a verbatim copy of the OLD LinkPU over every
  linked board cell and exit 1 on any disagreement - "pu-lib is NOT safe to wire in". That was the right
  test on the day pu-lib was born. It became the wrong one the day pu-lib fixed a bug LinkPU had: from then
  on every CORRECT answer ("1/2 gal" -> 0.078/fl oz, "12 x 12 fl oz" -> 0.0328) was reported as a
  REGRESSION against the buggy baseline, the suite went red, and a red suite nobody can turn green is a
  suite nobody reads. The baseline was the thing under test's own defects, frozen.

  Now the baseline is a table of FROZEN EXPECTED VALUES, each one a real shape the board has priced and
  each one independently derivable by hand. The test exits 0 while pu-lib agrees with them and 1 the day
  it stops - which is what "fail if pu-lib regresses" has to mean. The live sweep at the bottom is kept as
  INFORMATION (how many linked cells resolve today) and never fails the run: live data is not a fixture.

  Run: test-pu-lib.ps1        (exit 0 clean, 1 on any failure)
#>
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = $PSScriptRoot
. (Join-Path $root 'pu-lib.ps1')

# --- frozen expected values. want=$null means "genuinely cannot be priced; must stay null, never zero" ---
$cases = @(
  # the founding shapes
  @{ size='6 pk 4 oz';     unit='oz';     price=2.50; name='';                  want=0.104167 }  # pack-first multipack
  @{ size='2 pk 48 fl oz'; unit='floz';   price=4.00; name='';                  want=0.041667 }  # fl oz multipack -> per fl oz
  @{ size='2 pk 1 gal';    unit='gallon'; price=6.00; name='';                  want=3.0      }  # gallon multipack
  @{ size='16 oz 6 pk';    unit='oz';     price=3.00; name='';                  want=0.03125  }  # weight-first pack (no double-multiply)
  @{ size='6 pk 16 oz';    unit='oz';     price=3.00; name='';                  want=0.03125  }  # pack-first, same product -> same answer
  @{ size='4 pk 4 oz';     unit='each';   price=2.78; name='';                  want=0.695    }  # 'each' commodity: N pk = N items, price/4 (NOT per-oz)
  @{ size='3 oz';          unit='oz';     price=2.18; name='';                  want=0.726667 }  # plain single, unchanged
  @{ size='each';          unit='each';   price=6.00; name='Water 24 Pack';     want=0.25     }  # multipack-in-name (bare-each size + count in name)
  @{ size='lb';            unit='lb';     price=4.99; name='';                  want=4.99     }  # bare unit
  # A BUNCH IS A PURCHASE, NOT A WEIGHT (2026-08-31). Hy-Vee prices green onions "$1.49 / bunch" and
  # green-onions is an `each` commodity; the token was unknown, the row got no per-unit, and the cell
  # dropped off the board with nothing saying why.
  @{ size='bunch';         unit='each';   price=1.49; name='';                  want=1.49     }  # bunch = one purchase on a count commodity
  @{ size='1 bunch';       unit='each';   price=1.49; name='';                  want=1.49     }  # ...and the numbered spelling agrees
  # MUST STAY NULL: a bunch says nothing about WEIGHT, so guessing an ounce count is the one thing
  # that would be worse than dropping the cell.
  @{ size='bunch';         unit='oz';     price=1.49; name='';                  want=$null    }  # bunch on a weight commodity is uncomputable
  @{ size='bunch';         unit='lb';     price=1.49; name='';                  want=$null    }  # ...same for lb
  @{ size='$0.07/oz';      unit='oz';     price=5.00; name='';                  want=0.07     }  # explicit unit price
  @{ size='16 oz';         unit='each';   price=2.49; name='';                  want=$null    }  # genuine unit mismatch stays null
  # THE TWO CORRECT ANSWERS THE OLD BASELINE CALLED REGRESSIONS (the reason this file was red for weeks):
  @{ size='1/2 gal';       unit='floz';   price=4.99; name='';                  want=0.077969 }  # half-and-half/Baker's: 64 fl oz, NOT "2 gal"
  @{ size='12 x 12 fl oz'; unit='floz';   price=4.72; name='';                  want=0.032778 }  # soda/Hy-Vee: 144 fl oz, NOT 12
  @{ size='1/2 gal';       unit='gallon'; price=3.99; name='';                  want=7.98     }  # the same fraction on a gallon commodity
  @{ size='6/4 oz';        unit='oz';     price=3.49; name='';                  want=0.145417 }  # count/size idiom: 6 cups of 4 oz = 24 oz
  @{ size='2 ltr';         unit='floz';   price=1.99; name='';                  want=0.029426 }  # litre spelled 'ltr' (67.628 fl oz)
  @{ size='12 pk 2 oz';    unit='dozen';  price=3.49; name='';                  want=3.49     }  # Kroger-API canonical egg shape: 12 items = 1 dozen
  @{ size='18 ct';         unit='dozen';  price=4.50; name='';                  want=3.0      }  # 18 eggs = 1.5 dozen
  # F(1) 2026-08-22: a per-each marker in the NAME must not stop the pack count from dividing (engine parity)
  @{ size='each';          unit='each';   price=3.87; name='Bottled Water 24 Pack, $3.87 each'; want=0.16125 }
  @{ size='24 ct';         unit='each';   price=3.87; name='Bottled Water, $3.87 each';         want=0.16125 }
  @{ size='each';          unit='each';   price=3.87; name='Bottled Water, $3.87 each';         want=3.87    }  # no pack anywhere -> per-each
  # F(2) 2026-08-22: litre / ml / quart multipacks multiply in BOTH orderings (engine parity)
  @{ size='2 l 6 pk';      unit='floz';   price=6.00; name='';                  want=0.014787 }  # 12 l = 405.77 fl oz
  @{ size='6 pk 2 l';      unit='floz';   price=6.00; name='';                  want=0.014787 }
  @{ size='500 ml 24 pk';  unit='floz';   price=4.87; name='';                  want=0.012002 }  # 12,000 ml = 405.77 fl oz
  @{ size='24 pk 500 ml';  unit='floz';   price=4.87; name='';                  want=0.012002 }
  @{ size='1 qt 4 pk';     unit='floz';   price=8.00; name='';                  want=0.0625   }  # 128 fl oz
  @{ size='4 pk 1 qt';     unit='floz';   price=8.00; name='';                  want=0.0625   }
  @{ size='2 ltr 6 pk';    unit='floz';   price=6.00; name='';                  want=0.014787 }
)
$afail = 0
foreach ($c in $cases) {
  $got = Get-LinkPerUnit -size $c.size -unit $c.unit -price $c.price -name $c.name
  $ok = if ($null -eq $c.want) { $null -eq $got } else { ($null -ne $got) -and ([math]::Abs([double]$got - [double]$c.want) -lt 0.0005) }
  if ($ok) { Write-Output ("ok    size=`"$($c.size)`" unit=$($c.unit) price=$($c.price)" + $(if ($c.name) { " name=`"$($c.name)`"" }) + "  -> $got") }
  else { $afail++; Write-Output ("FAIL  size=`"$($c.size)`" unit=$($c.unit) price=$($c.price)" + $(if ($c.name) { " name=`"$($c.name)`"" }) + "  want=$($c.want)  got=$got") }
}
Write-Output ''

# ==== pricing-math-lib's OTHER pure functions, frozen the same way (2026-09-11) =======================
# Two ingest-seam rules whose whole job is to be pure and testable without a board:
#   Split-TwoProductAdLine  - queue 2026-09-10-582032, the two-product weekly-ad line
#   Get-DerivedRoundingPct  - queue 2026-09-10-c8eb72, the error bar on a Sam's derived size
# Hand-written from real rows, never generated: every case below is a line that exists in
# bakers-deals-2026-09-09 or ads-2026-09-11, or a Sam's row that held a cell on comparison-2026-09-11.
. (Join-Path $root 'pricing-math-lib.ps1')
$splitCases = @(
  # MUST FIRE: the founding line. The whole line routed to CEREAL and divided by the ORANGE JUICE's 46 fl oz.
  @{ name='Simply Orange Juice, 46 fl oz or Post Large Size Cereal, 13.5-20.5 oz'; want=@('Simply Orange Juice, 46 fl oz','Post Large Size Cereal, 13.5-20.5 oz') }
  # MUST FIRE: the two lines that hold a Baker's cell today - the price does not move, the text does.
  @{ name='Farmland Bacon, 12-16 oz or Oscar Mayer Beef Franks, 15 oz'; want=@('Farmland Bacon, 12-16 oz','Oscar Mayer Beef Franks, 15 oz') }
  @{ name='Downy Fabric Softener, 93-130 fl oz or Fabric Rinse, 48 fl oz'; want=@('Downy Fabric Softener, 93-130 fl oz','Fabric Rinse, 48 fl oz') }
  # MUST FIRE: the row whose SIZE FIELD belongs to the second product, which is why the size is re-cut per part
  @{ name='Nature Valley Bars, 5-12 ct or Pepperidge Farm Goldfish, 4.8-8 oz'; want=@('Nature Valley Bars, 5-12 ct','Pepperidge Farm Goldfish, 4.8-8 oz') }
  # MUST FIRE: same size on both sides is still two products
  @{ name='Private Selection Fresh Baked Butter Croissants, Large, 4 ct or Bakery Fresh Muffins, 4 ct'; want=@('Private Selection Fresh Baked Butter Croissants, Large, 4 ct','Bakery Fresh Muffins, 4 ct') }
  # MUST FIRE: a variety alternation glued INSIDE part 1, with a real second product after it
  @{ name="Simply Fruit Drink or Ade, 52 fl oz or GT's Kombucha, 16 fl oz"; want=@('Simply Fruit Drink or Ade, 52 fl oz',"GT's Kombucha, 16 fl oz") }
  # MUST NOT FIRE: one product, two flavours, one size. Splitting it would invent a sizeless product.
  @{ name='Simply Fruit Drink or Ade, 52 fl oz'; want=@('Simply Fruit Drink or Ade, 52 fl oz') }
  # MUST NOT FIRE: no size on either side (25 of the 70 ' or ' Baker's lines are this shape)
  @{ name='Raspberries or Blackberries'; want=@('Raspberries or Blackberries') }
  @{ name='Garnier Fructis Shampoo or Conditioner'; want=@('Garnier Fructis Shampoo or Conditioner') }
  # MUST NOT FIRE: 'or' inside a colour list on one product
  @{ name='Kroger Red, Green or Black Seedless Grapes'; want=@('Kroger Red, Green or Black Seedless Grapes') }
  # MUST NOT FIRE: no ' or ' at all - the single-product line every other flyer row is
  @{ name='Kroger Pasta Sauce, 24 oz'; want=@('Kroger Pasta Sauce, 24 oz') }
  # MUST NOT FIRE, AND THIS IS THE EXPENSIVE ONE. Hy-Vee's shape is "A size, B size, $price", where 'or' also
  # joins SIZE OPTIONS of one product. The loose rule that split these was measured and rejected: it produced
  # parts like "cans 12 fl. oz., $9.99" and would have crowned coffee off a wrong-product part (Hy-Vee 0.3857
  # -> 0.0657). These 10 lines are refused by Get-UnitPrice instead, never split.
  @{ name='Sparkling Ice Sparkling Water, 6 pk. bottles 17 fl. oz. or 10 pk. mini cans 7.5 fl. oz., $6.99'; want=@('Sparkling Ice Sparkling Water, 6 pk. bottles 17 fl. oz. or 10 pk. mini cans 7.5 fl. oz., $6.99') }
  # MUST NOT FIRE: a Sam's ', priced per pound' name carries no ' or ' and must be untouched
  @{ name="Member's Mark Beef Brisket, priced per pound"; want=@("Member's Mark Beef Brisket, priced per pound") }
)
foreach ($c in $splitCases) {
  $got = Split-TwoProductAdLine $c.name
  $got = @($got)
  $ok = (@($got).Count -eq @($c.want).Count)
  if ($ok) { for ($i = 0; $i -lt $got.Count; $i++) { if ([string]$got[$i] -ne [string]$c.want[$i]) { $ok = $false } } }
  if ($ok) { Write-Output ("ok    split[" + $got.Count + "]  " + $c.name) }
  else { $afail++; Write-Output ("FAIL  split  " + $c.name + "`n        want: " + (($c.want | ForEach-Object { "'$_'" }) -join ' | ') + "`n        got : " + (($got | ForEach-Object { "'$_'" }) -join ' | ')) }
}
# the size a part is priced by: the file row's size only when it states that part's own size expression
$sizeCases = @(
  @{ part='Farmland Bacon, 12-16 oz';            file='12-16 oz'; want='12-16 oz' }   # the file size IS this part's
  @{ part='Oscar Mayer Beef Franks, 15 oz';      file='12-16 oz'; want='15 oz'    }   # ...and is NOT the sibling's
  @{ part='Post Large Size Cereal, 13.5-20.5 oz';file='46 fl oz'; want='13.5-20.5 oz' }
  @{ part='Simply Orange Juice, 46 fl oz';       file='46 fl oz'; want='46 fl oz' }
  @{ part='Claussen Pickles, 20-32 fl oz';       file='7-9 oz';   want='20-32 fl oz' }
  @{ part='Bakery Fresh Muffins, 4 ct';          file='4 ct';     want='4 ct'     }
  @{ part='Mystery Item';                        file='12 oz';    want=''         }   # no readable tail -> no size invented
)
foreach ($c in $sizeCases) {
  $got = Get-SplitPartSizeText $c.part $c.file
  if ([string]$got -eq [string]$c.want) { Write-Output ("ok    partsize '" + $c.part + "' + file '" + $c.file + "' -> '" + $got + "'") }
  else { $afail++; Write-Output ("FAIL  partsize '" + $c.part + "' + file '" + $c.file + "'  want='" + $c.want + "' got='" + $got + "'") }
}
$roundCases = @(
  # MUST FIRE: the bbq-sauce crown's own row. 0.005/0.07 = 7.14%, which is wider than its 6% margin.
  @{ basis='package; qty derived lp/up'; up='$0.07/oz'; want=7.14 }
  # the pickles crown: a WIDER band (10%) on a crown that is still safe, because the runner-up is outside it
  @{ basis='package; qty derived lp/up'; up='$0.05/oz'; want=10.0 }
  # case 8d's ranch row: derived, so it carries a band even though the engine prices it from the name volume
  @{ basis='package; qty derived lp/up'; up='$0.09/oz'; want=5.56 }
  @{ basis='per-unit; qty derived lp/up'; up='$0.07/oz'; want=7.14 }   # the per-unit shape has the same rounding
  # MUST STAY NULL: a size the NAME stated has no quotient in it, so it has no rounding error
  @{ basis="package; qty name (reproduces Sam's unit price)"; up='$0.09/oz'; want=$null }
  @{ basis="package; qty name hint (reproduces Sam's unit price)"; up='$0.07/oz'; want=$null }
  @{ basis=''; up='$0.07/oz'; want=$null }                              # no basis at all
  @{ basis='package; qty derived lp/up'; up=''; want=$null }            # derived but no printed unit price to divide
  @{ basis='package; qty derived lp/up'; up='$0.00/oz'; want=$null }    # never divide by zero
)
foreach ($c in $roundCases) {
  $got = Get-DerivedRoundingPct $c.basis $c.up
  $ok = if ($null -eq $c.want) { $null -eq $got } else { ($null -ne $got) -and ([math]::Abs([double]$got - [double]$c.want) -lt 0.005) }
  if ($ok) { Write-Output ("ok    roundpct basis='" + $c.basis + "' up='" + $c.up + "' -> " + $(if ($null -eq $got) { 'null' } else { $got })) }
  else { $afail++; Write-Output ("FAIL  roundpct basis='" + $c.basis + "' up='" + $c.up + "'  want=" + $(if ($null -eq $c.want) { 'null' } else { $c.want }) + " got=" + $(if ($null -eq $got) { 'null' } else { $got })) }
}
# --- the crown test itself: which stores sit inside the winner's rounding band -----------------------
# Frozen from the real comparison-2026-09-11 rows. This is the decision the board publishes, so it gets its
# own cases rather than being inferred from the percentage above.
$bandCases = @(
  # MUST FIRE: bbq-sauce. Sam's wins by 6% with a 7.14% band, and Walmart's 0.0743 is inside it.
  @{ why='bbq-sauce: Walmart inside the band'
     win=@{ store="Sam's Club"; unit_price=0.07; basis='size 171.143 oz'; pu_rounding_pct=7.14 }
     rest=@(@{ store='Walmart'; unit_price=0.0743 }, @{ store="Baker's"; unit_price=0.1106 })
     want=@('Walmart') }
  # MUST FIRE: glass-cleaner, the second live one, and the reason "gallon jugs" was too narrow a framing.
  @{ why='glass-cleaner: Walmart inside the band'
     win=@{ store="Sam's Club"; unit_price=0.07; basis='size 167.429 floz'; pu_rounding_pct=7.14 }
     rest=@(@{ store='Walmart'; unit_price=0.0713 }, @{ store="Baker's"; unit_price=0.1073 })
     want=@('Walmart') }
  # MUST NOT FIRE: pickles has a WIDER band (10%) and its runner-up is still outside it. The margin is what
  # is judged, not the mere presence of a derived Sam's size.
  @{ why='pickles: runner-up outside a wider band'
     win=@{ store="Sam's Club"; unit_price=0.05; basis='size 126.8 oz'; pu_rounding_pct=10.0 }
     rest=@(@{ store='Walmart'; unit_price=0.0745 }, @{ store="Baker's"; unit_price=0.0934 })
     want=@() }
  # MUST NOT FIRE: ranch-dressing. The row IS derived, so it carries a rounding percentage - but the engine
  # priced the cell from the NAME's volume, so the quotient's error does not describe this number at all.
  # If this ever fires, the 2026-09-10 gallon-jug path has been handed an uncertainty it does not have.
  @{ why='ranch-dressing: priced from the NAME volume, so no band applies'
     win=@{ store="Sam's Club"; unit_price=0.0858; basis="size 128 floz from the NAME volume (size field '122 oz' is a bare-oz label on a fl-oz commodity)"; pu_rounding_pct=5.56 }
     rest=@(@{ store='Walmart'; unit_price=0.0863 })
     want=@() }
  # MUST NOT FIRE: no rounding field at all - every store but Sam's, and every board built before this shipped
  @{ why='no band on the winner'
     win=@{ store='Aldi'; unit_price=3.95; basis='size 1 lb' }
     rest=@(@{ store='Walmart'; unit_price=3.96 })
     want=@() }
)
foreach ($c in $bandCases) {
  $win = [pscustomobject]$c.win
  $rest = @($c.rest | ForEach-Object { [pscustomobject]$_ })
  $got = Get-RoundingBandTies $win $rest
  $got = @($got)
  $ok = ((@($got) -join ',') -eq (@($c.want) -join ','))
  if ($ok) { Write-Output ("ok    band  " + $c.why + " -> [" + (@($got) -join ', ') + "]") }
  else { $afail++; Write-Output ("FAIL  band  " + $c.why + "  want=[" + (@($c.want) -join ', ') + "] got=[" + (@($got) -join ', ') + "]") }
}
Write-Output ''

# --- INFORMATION ONLY: how much of the live board's linked cells pu-lib can judge today. Never a failure:
# live data changes daily and is not a fixture. A rising unresolved count is worth a look, not a red build.
try {
  # LIVE-TWIN on purpose (ops\audit-fixture-inputs.ps1, 2026-09-11): this sweep is informational and never fails (above).
  $cmpF = (Get-ChildItem (Join-Path $root 'out\comparison-*.json') -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1)
  if ($cmpF) {
    $all = @((Read-JsonFile $cmpF.FullName).comparison)
    $pd = (Read-JsonFile (Join-Path $root 'product-urls.json')).items   # LIVE-TWIN: the same informational sweep
    $res = 0; $unres = New-Object System.Collections.Generic.List[string]
    foreach ($it in $all) {
      $id = [string]$it.id; $unit = [string]$it.unit
      foreach ($s in $it.stores) {
        $e = $pd.$id.([string]$s.store); if (-not ($e -and $e.url)) { continue }
        $sp = 0.0; [void][double]::TryParse((([string]$e.price) -replace '[^0-9.]', ''), [ref]$sp)
        $n = Get-LinkPerUnit -size ([string]$e.size) -unit $unit -price $sp -name ([string]$e.name)
        if ($null -ne $n) { $res++ } else { $unres.Add(('{0}/{1}  unit={2}  size="{3}"' -f $id, $s.store, $unit, [string]$e.size)) }
      }
    }
    Write-Output ("live sweep ($($cmpF.Name)): $res linked cell(s) resolve, $($unres.Count) cannot be judged (informational)")
    foreach ($x in ($unres | Select-Object -First 8)) { Write-Output ('   ' + $x) }
    Write-Output ''
  }
} catch { Write-Output ("live sweep skipped: " + $_.Exception.Message) }

if ($afail) { Write-Output "PU-LIB FAILED ($afail) - pu-lib or pricing-math-lib no longer agrees with its frozen expected values."; exit 1 }
Write-Output "PU-LIB PASSED ($($cases.Count) pu-lib + $($splitCases.Count) ad-split + $($sizeCases.Count) part-size + $($roundCases.Count) rounding-pct + $($bandCases.Count) rounding-band frozen cases)"
exit 0
