<#
  test-asof-evidence-scope.ps1 -SelfTest - audit-asof-evidence.ps1 names the board cell of each violated row in the
  QUARANTINE-CELL protocol when a store regresses (queue 2026-09-22-6e6a3b, Brad 2026-09-21: one bad item must not hold
  the board), and affirms no scope when a violation cannot be placed on the board. Each case runs the real audit as a
  child with -Root at a per-run fixture tree and reads its output through the same Get-TcChildQuarantineScope
  guards.ps1 uses. The founding shape is 2026-08-02's 'Fareway Ranch Dressing' $0.99, last seen in the 07-23 extract
  and published as_of 08-01.
#>
# The self-test runs audit-asof-evidence.ps1 (and what it loads) with -Root at a fixture tree it writes in temp.
# gate-inputs: grocery\audit-asof-evidence.ps1
[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
if (-not $SelfTest) { Write-Output 'test-asof-evidence-scope: run with -SelfTest'; exit 3 }
. (Join-Path $PSScriptRoot 'cell-quarantine-lib.ps1')
$script:bad = 0; $script:n = 0
function Aec([string]$label, [bool]$ok, [string]$got) { $script:n++; if ($ok) { Write-Output ('ok    ' + $label) } else { Write-Output ('FAIL  ' + $label + ' :: ' + $got); $script:bad++ } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('aes-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
$audit = Join-Path $PSScriptRoot 'audit-asof-evidence.ps1'
$utf8 = New-Object Text.UTF8Encoding($false)
function Invoke-Ae([string]$name, [string]$ranchAsOf, [bool]$ranchOnBoard) {
  $r = Join-Path $tmp $name
  foreach ($d in @('out\regular', 'out\fareway')) { New-Item -ItemType Directory -Path (Join-Path $r $d) -Force -ErrorAction Stop | Out-Null }
  [IO.File]::WriteAllText((Join-Path $r 'out\fareway\fareway-shop-2026-07-23.json'), '[{"name":"Fareway Ranch Dressing","price":"0.99"},{"name":"NatureSweet Cherubs Tomatoes","price":"9.99"}]', $utf8)
  [IO.File]::WriteAllText((Join-Path $r 'out\fareway\fareway-shop-2026-08-01.json'), '[{"name":"NatureSweet Cherubs Tomatoes","price":"3.99"}]', $utf8)
  [IO.File]::WriteAllText((Join-Path $r 'out\regular\fareway-regular-2026-08-01.json'), ('{"store":"Fareway","deals":[' +
    '{"store":"Fareway","item":"Fareway Ranch Dressing","ad_price":"$0.99","as_of":"' + $ranchAsOf + '"},' +
    '{"store":"Fareway","item":"NatureSweet Cherubs Tomatoes","ad_price":"$3.99","as_of":"2026-08-01"}]}'), $utf8)
  $ranch = ''; if ($ranchOnBoard) { $ranch = '{"id":"ranch-dressing","stores":[{"store":"Fareway","item":"Fareway Ranch Dressing","per_unit":0.0619}]},' }
  [IO.File]::WriteAllText((Join-Path $r 'out\comparison-2026-08-01.json'), ('{"comparison":[' + $ranch +
    '{"id":"tomatoes","stores":[{"store":"Fareway","item":"NatureSweet Cherubs Tomatoes","per_unit":0.399}]}]}'), $utf8)
  $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $audit -Root $r -Quiet)
  return [pscustomobject]@{ rc = $LASTEXITCODE; out = $o; text = ($o -join ' / ') }
}
try {
  New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
  # MUST FIRE: the founding laundered date holds ONE cell, ranch-dressing / Fareway, as a value.
  $r = Invoke-Ae 'fire' '2026-08-01' $true
  $sc = Get-TcChildQuarantineScope $r.out
  $cells = @(); if ($sc) { $cells = @($sc.cells) }
  Aec 'MUST FIRE  a row dated past its newest capture exits 2 and is named for guards as ranch-dressing / Fareway [value], scope complete' (($r.rc -eq 2) -and ($null -ne $sc) -and ($cells.Count -eq 1) -and ([string]$cells[0].id -eq 'ranch-dressing') -and ([string]$cells[0].store -eq 'Fareway') -and ([string]$cells[0].kind -eq 'value')) ('rc=' + $r.rc + ' ' + $r.text)
  # CLEAN TWIN: the same violation when no board cell carries the row still fails the audit (exit 2, the FAIL line)
  # and affirms no scope, so guards holds the board exactly as before this change.
  $r = Invoke-Ae 'offboard' '2026-08-01' $false
  $sc = Get-TcChildQuarantineScope $r.out
  Aec 'CLEAN TWIN  a violation no board cell carries still exits 2 and prints asof-evidence FAIL, with no scope affirmed' (($r.rc -eq 2) -and ($null -eq $sc) -and ($r.text -match 'asof-evidence FAIL')) ('rc=' + $r.rc + ' ' + $r.text)
  # MUST NOT FIRE: the row dated to the extract that holds it is no finding and prints no quarantine line. The fixture
  # carries no Aldi files, so the audit names Aldi BLIND and exits 3, never 0: the assertion is no FAIL and no line.
  $r = Invoke-Ae 'clean' '2026-07-23' $true
  Aec 'MUST NOT FIRE  a row dated to its own capture is no finding (exit 3 for the fixture''s blind Aldi, no FAIL) and prints no QUARANTINE line' (($r.rc -eq 3) -and ($r.text -notmatch 'asof-evidence FAIL') -and (@($r.out | Where-Object { $_ -match '^QUARANTINE-' }).Count -eq 0)) ('rc=' + $r.rc + ' ' + $r.text)
} catch { Write-Output ('FAIL  a case threw: ' + $_.Exception.Message); $script:bad++ }
finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } }
Write-Output ('test-asof-evidence-scope self-test ' + $(if ($script:bad -eq 0 -and $script:n -eq 3) { 'pass' } else { 'FAIL' }) + ': ' + ($script:n - $script:bad) + ' of ' + $script:n + ' case(s) passed (3 expected)')
exit $(if ($script:bad -eq 0 -and $script:n -eq 3) { 0 } else { 1 })
