<#
  test-derived-band.ps1 -SelfTest - frozen fixtures for derived-band-lib.ps1 (Brad's ruling "Derive from data" on
  queue 2026-09-21-6b17b1). Evidence frozen from comparison-2026-09-22 (08:13 generation, the cells as published).
#>
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
if (-not $SelfTest) { Write-Output 'test-derived-band: run with -SelfTest'; exit 3 }
. (Join-Path $PSScriptRoot 'derived-band-lib.ps1')
$script:bad = 0; $script:n = 0
function Tc([string]$label, [bool]$ok) { $script:n++; if ($ok) { Write-Output ('ok    ' + $label) } else { Write-Output ('FAIL  ' + $label); $script:bad++ } }
try {
  $oil = @(
    [pscustomobject]@{ id = 'vegetable-oil'; store = 'Walmart'; per_unit = 0.0686 }, [pscustomobject]@{ id = 'vegetable-oil'; store = "Sam's Club"; per_unit = 0.0723 },
    [pscustomobject]@{ id = 'vegetable-oil'; store = 'Aldi'; per_unit = 0.074 }, [pscustomobject]@{ id = 'vegetable-oil'; store = 'Fareway'; per_unit = 0.0741 },
    [pscustomobject]@{ id = 'vegetable-oil'; store = "Baker's"; per_unit = 0.0804 }, [pscustomobject]@{ id = 'vegetable-oil'; store = 'Hy-Vee'; per_unit = 0.0873 },
    [pscustomobject]@{ id = 'vegetable-oil'; store = 'Family Fare'; per_unit = 0.096 })
  $b = Get-TcDerivedBands -Rows $oil
  $vb = $b['vegetable-oil']
  Tc 'MECHANISM  the reference is the median of the 7 store numbers (0.0741)' ($null -ne $vb -and [math]::Abs([double]$vb.reference - 0.0741) -lt 0.000001)
  Tc 'MUST NOT FIRE  Sam''s $7.16 / 192 fl oz canola (0.0373/fl oz), refused by the typed 0.04 floor, is inside the derived band' (Test-TcInBand $vb 0.0373)
  Tc 'MUST FIRE  a factor-of-10 basis error the other way (0.0074/fl oz, a dropped decimal) is refused' (-not (Test-TcInBand $vb 0.0074))
  Tc 'MUST FIRE  a factor-of-10 error upward (0.741/fl oz, a per-piece price read as per-ounce) is refused' (-not (Test-TcInBand $vb 0.741))
  # AT THE BAR, binary-exact: reference 1.0, K 5 -> floor exactly 0.2
  $flat = @('A','B','C') | ForEach-Object { [pscustomobject]@{ id = 'x'; store = $_; per_unit = 1.0 } }
  $fb = (Get-TcDerivedBands -Rows $flat)['x']
  Tc 'BAR  a price exactly AT the floor (0.2 = 1.0 / 5) is admitted' (Test-TcInBand $fb 0.2)
  Tc 'BAR  one step past (0.1999) is refused' (-not (Test-TcInBand $fb 0.1999))
  # the grits founding error ($0.0023/oz on a real 0.12-0.19/oz board) is refused by the derived band too
  $grits = @(@('Fareway', 0.1246), @('Walmart', 0.135), @("Baker's", 0.1662), @('Family Fare', 0.1871)) | ForEach-Object { [pscustomobject]@{ id = 'grits'; store = $_[0]; per_unit = $_[1] } }
  Tc 'MUST FIRE  the 2026-07-27 grits decimal-drop ($0.0023/oz) is refused' (-not (Test-TcInBand (Get-TcDerivedBands -Rows $grits)['grits'] 0.0023))
  $two = @([pscustomobject]@{ id = 'y'; store = 'A'; per_unit = 1.0 }, [pscustomobject]@{ id = 'y'; store = 'B'; per_unit = 2.0 })
  Tc 'MUST NOT FIRE  two rows from two stores are not enough evidence: no band is derived' (-not (Get-TcDerivedBands -Rows $two).ContainsKey('y'))
  $one = @(0.9, 1.0, 1.1, 50.0) | ForEach-Object { [pscustomobject]@{ id = 'z'; store = 'OnlyStore'; per_unit = $_ } }
  Tc 'CLEAN TWIN  one store with 4 rows still derives a band from the median of rows (1.05)' ([math]::Abs([double](Get-TcDerivedBands -Rows $one)['z'].reference - 1.05) -lt 0.000001)
  # WAREHOUSE REFERENCE GROUP (Brad's rollout ruling, 2026-09-22). Store numbers frozen from the derived-arm board of
  # 2026-09-22 (compare-deals -OutName armD, TC_DERIVED_BANDS=enforce): every retail store's cell and Sam's Club's cell.
  $grp = @{ "Sam's Club" = 'warehouse' }
  function WhRows([string]$id, [double[]]$retail, [double]$sams) {
    $i = 0; $o = @()
    foreach ($p in $retail) { $i++; $o += [pscustomobject]@{ id = $id; store = ('Retail' + $i); per_unit = $p } }
    $o += [pscustomobject]@{ id = $id; store = "Sam's Club"; per_unit = $sams }
    return $o
  }
  $real = @(
    @('rice', @(0.573, 0.798, 0.895, 0.938, 1.0), 0.4596, 'Member''s Mark Long Grain White Rice, 50 lbs.'),
    @('curry-powder', @(1.06, 1.395, 1.69, 2.8514), 0.4989, 'Member''s Mark Salt-Free Curry Powder, 18 oz.'),
    @('dried-thyme', @(1.9857, 3.1087, 5.7), 0.8776, 'Member''s Mark Thyme Leaves, 8.25 oz.'),
    @('bay-leaves', @(7.9733, 25.1667, 31.9333), 4.27, 'Member''s Mark Whole Bay Leaves, 2 oz.'),
    @('yeast', @(1.3575, 1.37, 1.4533, 1.4975, 1.4975), 0.215, 'Fleischmann''s Instant Dry Yeast, 16 oz., 2 pk.'))
  foreach ($x in $real) {
    $wb = (Get-TcDerivedBands -Rows (WhRows $x[0] ([double[]]$x[1]) $x[2]) -Groups $grp)[$x[0]]
    Tc ('MUST NOT FIRE  real Sam''s bulk ' + $x[3] + ' at ' + $x[2] + ' is admitted at the warehouse floor') (Test-TcInBand $wb $x[2] 'warehouse')
  }
  $yb = (Get-TcDerivedBands -Rows (WhRows 'yeast' ([double[]]@(1.3575, 1.37, 1.4533, 1.4975, 1.4975)) 0.215) -Groups $grp)['yeast']
  Tc 'MECHANISM  the same yeast row judged as a RETAIL row is refused (6.76x under the reference, past K = 5): the warehouse group is what admits it' (-not (Test-TcInBand $yb 0.215 'retail'))
  Tc 'MECHANISM  the warehouse row does not move the reference: it is the median of the 5 retail stores (1.4533)' ([math]::Abs([double]$yb.reference - 1.4533) -lt 0.000001)
  $bb = (Get-TcDerivedBands -Rows (WhRows 'bread' ([double[]]@(1.19, 1.45, 1.48, 1.88, 1.99, 1.99)) 0.1753) -Groups $grp)['bread']
  Tc 'MUST FIRE  Sam''s "Rotella''s Italian Vienna Bread 17 oz." at 0.1753 per loaf (17 oz read as 17 loaves, 9.58x under) is refused at the warehouse floor' (-not (Test-TcInBand $bb 0.1753 'warehouse'))
  $fb2 = (Get-TcDerivedBands -Rows (WhRows 'x10' ([double[]]@(1.0, 1.0, 1.0)) 1.0) -Groups $grp)['x10']
  Tc 'MUST FIRE  a factor-of-10 basis error of a warehouse price AT the reference (0.1 against 1.0) is refused: K * W = 7.5 < 10' (-not (Test-TcInBand $fb2 0.1 'warehouse'))
  # AT THE BAR, binary-exact: K 4, W 2, reference 1.0 -> warehouse floor exactly 0.125
  $eb = (Get-TcDerivedBands -Rows (WhRows 'bar' ([double[]]@(1.0, 1.0, 1.0)) 1.0) -Groups $grp -K 4 -W 2)['bar']
  Tc 'BAR  a warehouse price exactly AT its floor (0.125 = 1.0 / (4 x 2)) is admitted' (Test-TcInBand $eb 0.125 'warehouse')
  Tc 'BAR  one step past the warehouse floor (0.1249) is refused' (-not (Test-TcInBand $eb 0.1249 'warehouse'))
  $sdoc = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'stores.json')) | ConvertFrom-Json
  $g = Get-TcStoreReferenceGroups $sdoc
  Tc 'CLEAN TWIN  the groups come from stores.json: Sam''s Club reads warehouse and Walmart reads retail' (($g["Sam's Club"] -eq 'warehouse') -and ($g['Walmart'] -eq 'retail'))
} catch { Write-Output ('FAIL  a case threw: ' + $_.Exception.Message); $script:bad++ }
Write-Output ('test-derived-band self-test ' + $(if ($script:bad -eq 0 -and $script:n -eq 21) { 'pass' } else { 'FAIL' }) + ': ' + ($script:n - $script:bad) + ' of ' + $script:n + ' case(s) passed (21 expected)')
exit $(if ($script:bad -eq 0 -and $script:n -eq 21) { 0 } else { 1 })
