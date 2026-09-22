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
} catch { Write-Output ('FAIL  a case threw: ' + $_.Exception.Message); $script:bad++ }
Write-Output ('test-derived-band self-test ' + $(if ($script:bad -eq 0 -and $script:n -eq 9) { 'pass' } else { 'FAIL' }) + ': ' + ($script:n - $script:bad) + ' of ' + $script:n + ' case(s) passed (9 expected)')
exit $(if ($script:bad -eq 0 -and $script:n -eq 9) { 0 } else { 1 })
