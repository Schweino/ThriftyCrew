<#
  test-price-mode-scope.ps1 -SelfTest - audit-price-mode.ps1 names each store it fails in the QUARANTINE-STORE protocol
  (queue 2026-09-22-6e6a3b, Brad 2026-09-21: one bad item must not hold the board; a wrong fulfillment mode is a whole
  store). Each case runs the real audit as a child with -RegularDir at a per-run fixture directory and reads its output
  through the same Get-TcChildQuarantineScope guards.ps1 uses. The founding shape is 2026-07-14's Aldi file pulled in
  Delivery mode.
#>
[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
if (-not $SelfTest) { Write-Output 'test-price-mode-scope: run with -SelfTest'; exit 3 }
. (Join-Path $PSScriptRoot 'cell-quarantine-lib.ps1')
$script:bad = 0; $script:n = 0
function Pmc([string]$label, [bool]$ok, [string]$got) { $script:n++; if ($ok) { Write-Output ('ok    ' + $label) } else { Write-Output ('FAIL  ' + $label + ' :: ' + $got); $script:bad++ } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('pms-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
$audit = Join-Path $PSScriptRoot 'audit-price-mode.ps1'
$utf8 = New-Object Text.UTF8Encoding($false)
function Invoke-Pm([string]$name, [string]$aldiMode) {
  $d = Join-Path $tmp $name
  New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null
  [IO.File]::WriteAllText((Join-Path $d 'aldi-regular-2026-09-25.json'), ('{"store":"Aldi","week_of":"2026-09-25","price_mode":"' + $aldiMode + '","mode_verified":"2026-09-25","deals":[]}'), $utf8)
  [IO.File]::WriteAllText((Join-Path $d 'fareway-regular-2026-09-25.json'), '{"store":"Fareway","week_of":"2026-09-25","price_mode":"in-store","mode_verified":"2026-09-25","deals":[]}', $utf8)
  $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $audit -RegularDir $d)
  return [pscustomobject]@{ rc = $LASTEXITCODE; out = $o; text = ($o -join ' / ') }
}
try {
  New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
  # MUST FIRE: the founding Delivery-mode Aldi file names the store Aldi, scope complete with no cell.
  $r = Invoke-Pm 'fire' 'delivery'
  $sc = Get-TcChildQuarantineScope $r.out
  $st = @(); if ($sc) { $st = @($sc.stores) }
  Pmc 'MUST FIRE  a Delivery-mode Aldi file exits 2 and is named for guards as the store Aldi, scope complete' (($r.rc -eq 2) -and ($null -ne $sc) -and ($st.Count -eq 1) -and ([string]$st[0] -eq 'Aldi') -and (@($sc.cells).Count -eq 0)) ('rc=' + $r.rc + ' ' + $r.text)
  # CLEAN TWIN: the in-store Fareway file beside it is still checked and reported OK, and never named.
  Pmc 'CLEAN TWIN  the in-store Fareway file beside it is still read as OK and is not named' (($r.text -match 'OK    Fareway: in-store') -and (@($r.out | Where-Object { $_ -match '^QUARANTINE-STORE Fareway' }).Count -eq 0)) ('rc=' + $r.rc + ' ' + $r.text)
  # MUST NOT FIRE: both stores in-store exits 0 and prints no quarantine line.
  $r = Invoke-Pm 'clean' 'in-store'
  Pmc 'MUST NOT FIRE  both stores in-store exits 0 and prints no QUARANTINE line' (($r.rc -eq 0) -and (@($r.out | Where-Object { $_ -match '^QUARANTINE-' }).Count -eq 0)) ('rc=' + $r.rc + ' ' + $r.text)
} catch { Write-Output ('FAIL  a case threw: ' + $_.Exception.Message); $script:bad++ }
finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } }
Write-Output ('test-price-mode-scope self-test ' + $(if ($script:bad -eq 0 -and $script:n -eq 3) { 'pass' } else { 'FAIL' }) + ': ' + ($script:n - $script:bad) + ' of ' + $script:n + ' case(s) passed (3 expected)')
exit $(if ($script:bad -eq 0 -and $script:n -eq 3) { 0 } else { 1 })
