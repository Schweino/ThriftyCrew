<#
  test-pulib.ps1 - known-answer tests for Get-LinkPerUnit, the ONE per-unit function.

  Every case below is either arithmetic I can check by hand or a REAL bug this repo already shipped. The
  differential test (test-pulib-differential.ps1) proves a change did not move existing answers; this proves
  the answers are right in the first place. Neither replaces the other: a differential is happy when a wrong
  answer stays wrong.

  Exit 0 = all pass, 1 = any fail.
#>
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $root 'pu-lib.ps1')

# size, unit, price, expected (or $null), why
$cases = @(
  # --- volume spellings. "2 ltr" returned null until 2026-07-16: the converter knew litres, the SIZE regex
  #     did not, because a bare 'l\b' cannot match the 'l' in "ltr".
  @{ s = '2 ltr'; u = 'floz'; p = 3.49; e = 0.0516; why = 'litre spelled ltr -> 67.63 floz' }
  @{ s = '2 liter bottle'; u = 'floz'; p = 3.49; e = 0.0516; why = 'litre spelled out' }
  @{ s = '2 l'; u = 'floz'; p = 3.49; e = 0.0516; why = 'bare l still works' }
  @{ s = '500 ml'; u = 'floz'; p = 1.69; e = 0.1; why = 'ml must not be eaten by the l branch' }

  # --- multipack forms. All three spell the same thing; each was broken separately at some point.
  @{ s = '12 x 12 fl oz'; u = 'floz'; p = 4.72; e = 0.0328; why = 'N x M -> 144 floz, NOT 12 (live 12x bug)' }
  @{ s = '12 pk 12 fl oz'; u = 'floz'; p = 3.97; e = 0.0276; why = 'N pk M -> 144 floz' }
  @{ s = '144 fl oz'; u = 'floz'; p = 3.79; e = 0.0263; why = 'plain total' }

  # --- an each-commodity must NOT have its pack collapsed into a weight (the fruit-cups regression)
  @{ s = '4 pk 4 oz'; u = 'each'; p = 2.00; e = 0.5; why = 'each commodity: 4 pk = 4 ITEMS, not 16 oz' }

  # --- explicit unit price in the size field wins outright
  @{ s = '$0.07/oz'; u = 'oz'; p = 5.00; e = 0.07; why = 'stated unit price beats the pack math' }

  # --- plain conversions
  @{ s = '24 oz'; u = 'oz'; p = 2.00; e = 0.0833; why = 'oz -> oz' }
  @{ s = '1 lb'; u = 'oz'; p = 3.20; e = 0.2; why = 'lb -> oz' }
  @{ s = 'dozen'; u = 'dozen'; p = 3.00; e = 3.00; why = 'bare dozen' }

  # --- honest nulls: these carry no basis, and $null means UNKNOWN. Callers must never read it as zero.
  @{ s = '.'; u = 'oz'; p = 2.00; e = $null; why = 'a lone dot must not throw ([double]"." does)' }
  @{ s = ''; u = 'oz'; p = 2.00; e = $null; why = 'empty size is unknown, not free' }
  @{ s = '48 ct'; u = 'oz'; p = 9.98; e = $null; why = 'a count gives no ounces - refuse rather than guess' }
  @{ s = '16 oz'; u = 'oz'; p = 0; e = $null; why = 'no price -> no per-unit' }
)

$pass = 0; $fail = 0
foreach ($c in $cases) {
  $got = Get-LinkPerUnit -size $c.s -unit $c.u -price $c.p -name ''
  $ok = if ($null -eq $c.e) { $null -eq $got } else { ($null -ne $got) -and ([math]::Abs($got - $c.e) -lt 0.001) }
  $gs = if ($null -eq $got) { 'null' } else { [math]::Round($got, 4).ToString() }
  $es = if ($null -eq $c.e) { 'null' } else { $c.e.ToString() }
  if ($ok) { $pass++; Write-Output ("  PASS  [{0,-16}] {1,-6} `${2,-6} -> {3,-8} {4}" -f $c.s, $c.u, $c.p, $gs, $c.why) }
  else { $fail++; Write-Output ("  FAIL  [{0,-16}] {1,-6} `${2,-6} -> {3,-8} EXPECTED {4}  ({5})" -f $c.s, $c.u, $c.p, $gs, $es, $c.why) }
}
Write-Output ''
Write-Output ("pu-lib tests: " + $pass + " passed, " + $fail + " failed")
if ($fail) { exit 1 }
exit 0
