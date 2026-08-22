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

# --- INFORMATION ONLY: how much of the live board's linked cells pu-lib can judge today. Never a failure:
# live data changes daily and is not a fixture. A rising unresolved count is worth a look, not a red build.
try {
  $cmpF = (Get-ChildItem (Join-Path $root 'out\comparison-*.json') -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1)
  if ($cmpF) {
    $all = @((Get-Content $cmpF.FullName -Raw | ConvertFrom-Json).comparison)
    $pd = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items
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

if ($afail) { Write-Output "PU-LIB FAILED ($afail) - pu-lib no longer agrees with its frozen expected values."; exit 1 }
Write-Output "PU-LIB PASSED ($($cases.Count) frozen cases)"
exit 0
