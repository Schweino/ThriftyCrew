<#
  test-household-in-food-scope.ps1 -SelfTest - audit-household-in-food.ps1 names each finding's cell in the
  QUARANTINE-CELL protocol (queue 2026-09-22-6e6a3b, Brad 2026-09-21: one bad item must not hold the board), and affirms
  no scope when a finding cannot name its store. Each case runs the real audit as a child from a per-run sandbox (the
  audit reads its own directory, so the sandbox carries it, its two libraries and a fixture commodity list) and reads
  its output through the same Get-TcChildQuarantineScope guards.ps1 uses. The founding shape is the 2026-07-14
  "Lysol Mango & Hibiscus Bathroom Cleaner" landing in mangoes.
#>
# The self-test copies the audit, its exclude library and lib\json-io.ps1 into a temp tree and runs the audit there:
# gate-inputs: grocery\cell-quarantine-lib.ps1, lib\json-io.ps1, grocery\audit-household-in-food.ps1, grocery\global-exclude-lib.ps1
[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
if (-not $SelfTest) { Write-Output 'test-household-in-food-scope: run with -SelfTest'; exit 3 }
. (Join-Path $PSScriptRoot 'cell-quarantine-lib.ps1')
$script:bad = 0; $script:n = 0
function Hf([string]$label, [bool]$ok, [string]$got) { $script:n++; if ($ok) { Write-Output ('ok    ' + $label) } else { Write-Output ('FAIL  ' + $label + ' :: ' + $got); $script:bad++ } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('hfs-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
$utf8 = New-Object Text.UTF8Encoding($false)
$repo = Split-Path $PSScriptRoot -Parent
function Invoke-Hf([string]$name, [string]$dealsJson) {
  $r = Join-Path $tmp $name
  $g = Join-Path $r 'grocery'
  New-Item -ItemType Directory -Path (Join-Path $g 'out\regular') -Force -ErrorAction Stop | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $r 'lib') -Force -ErrorAction Stop | Out-Null
  Copy-Item -LiteralPath (Join-Path $repo 'lib\json-io.ps1') -Destination (Join-Path $r 'lib') -ErrorAction Stop
  foreach ($f in @('audit-household-in-food.ps1', 'global-exclude-lib.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $f) -Destination $g -ErrorAction Stop }
  [IO.File]::WriteAllText((Join-Path $g 'commodities.json'), '[{"id":"mangoes","include":["mango"],"exclude":[],"relax_global":[]},{"id":"cleaner","include":["cleaner"],"exclude":[],"relax_global":[]}]', $utf8)
  [IO.File]::WriteAllText((Join-Path $g 'categories.json'), '{"categories":[{"label":"Household","commodities":["cleaner"]},{"label":"Produce","commodities":["mangoes"]}]}', $utf8)
  [IO.File]::WriteAllText((Join-Path $g 'out\regular\walmart-regular-2026-01-02.json'), $dealsJson, $utf8)
  $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $g 'audit-household-in-food.ps1'))
  return [pscustomobject]@{ rc = $LASTEXITCODE; out = $o; text = ($o -join ' / ') }
}
try {
  New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
  # MUST FIRE: the founding Lysol mango cleaner holds ONE cell, mangoes / Walmart, as a value.
  $r = Invoke-Hf 'fire' '{"store":"Walmart","deals":[{"item":"Lysol Mango & Hibiscus Bathroom Cleaner 32 fl oz"},{"item":"Fresh Mangoes"}]}'
  $sc = Get-TcChildQuarantineScope $r.out
  $cells = @(); if ($sc) { $cells = @($sc.cells) }
  Hf 'MUST FIRE  a cleaner in an edible commodity exits 2 and is named for guards as mangoes / Walmart [value], scope complete' (($r.rc -eq 2) -and ($null -ne $sc) -and ($cells.Count -eq 1) -and ([string]$cells[0].id -eq 'mangoes') -and ([string]$cells[0].store -eq 'Walmart') -and ([string]$cells[0].kind -eq 'value')) ('rc=' + $r.rc + ' ' + $r.text)
  # CLEAN TWIN: the same finding in a file that names no store still fails the audit (exit 2, the FAILED line), and
  # affirms no scope, so guards holds the board exactly as before this change.
  $r = Invoke-Hf 'nostore' '{"deals":[{"item":"Lysol Mango & Hibiscus Bathroom Cleaner 32 fl oz"}]}'
  $sc = Get-TcChildQuarantineScope $r.out
  Hf 'CLEAN TWIN  a finding with no store still exits 2 and prints HOUSEHOLD-IN-FOOD AUDIT FAILED, with no scope affirmed' (($r.rc -eq 2) -and ($null -eq $sc) -and ($r.text -match 'HOUSEHOLD-IN-FOOD AUDIT FAILED')) ('rc=' + $r.rc + ' ' + $r.text)
  # MUST NOT FIRE: a clean file exits 0 and prints no quarantine line.
  $r = Invoke-Hf 'clean' '{"store":"Walmart","deals":[{"item":"Fresh Mangoes"},{"item":"Lysol Lemon Bathroom Cleaner"}]}'
  Hf 'MUST NOT FIRE  a clean file exits 0 and prints no QUARANTINE line' (($r.rc -eq 0) -and (@($r.out | Where-Object { $_ -match '^QUARANTINE-' }).Count -eq 0)) ('rc=' + $r.rc + ' ' + $r.text)
} catch { Write-Output ('FAIL  a case threw: ' + $_.Exception.Message); $script:bad++ }
finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } }
Write-Output ('test-household-in-food-scope self-test ' + $(if ($script:bad -eq 0 -and $script:n -eq 3) { 'pass' } else { 'FAIL' }) + ': ' + ($script:n - $script:bad) + ' of ' + $script:n + ' case(s) passed (3 expected)')
exit $(if ($script:bad -eq 0 -and $script:n -eq 3) { 0 } else { 1 })
