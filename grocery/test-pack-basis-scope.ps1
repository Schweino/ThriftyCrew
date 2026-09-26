<#
  test-pack-basis-scope.ps1 -SelfTest - audit-pack-basis.ps1 names each CONFIRMED pack-total cell in the QUARANTINE-CELL
  protocol (queue 2026-09-22-6e6a3b, Brad 2026-09-21: one bad item must not hold the board), and affirms no scope when
  -Strict makes an undecidable finding a failure. Each case runs the real audit as a child over a per-run fixture board
  and reads its output through the same Get-TcChildQuarantineScope guards.ps1 uses. The founding shape is Sam's
  "Pledge Furniture Polish, 3 ct., 29 oz." (29/3 = 9.67 oz, the can three peers sell).
#>
[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
if (-not $SelfTest) { Write-Output 'test-pack-basis-scope: run with -SelfTest'; exit 3 }
. (Join-Path $PSScriptRoot 'cell-quarantine-lib.ps1')
$script:bad = 0; $script:n = 0
function Pc([string]$label, [bool]$ok, [string]$got) { $script:n++; if ($ok) { Write-Output ('ok    ' + $label) } else { Write-Output ('FAIL  ' + $label + ' :: ' + $got); $script:bad++ } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('pbs-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
$audit = Join-Path $PSScriptRoot 'audit-pack-basis.ps1'
$utf8 = New-Object Text.UTF8Encoding($false)
$polish = '{"id":"furniture-polish","commodity":"Furniture polish","unit":"oz","cheapest_store":"Sam''s Club","stores":[' +
  '{"store":"Sam''s Club","per_unit":0.1438,"item":"Pledge Furniture Polish, 3 ct., 29 oz.","ad":"$12.51","size":"3 ct., 29 oz."},' +
  '{"store":"Walmart","per_unit":0.432,"item":"Pledge Lemon Furniture Polish 9.7 oz","ad":"$4.19","size":"9.7 oz"},' +
  '{"store":"Hy-Vee","per_unit":0.45,"item":"Pledge Furniture Polish 9.7 oz","ad":"$4.37","size":"9.7 oz"}]}'
$hummus = '{"id":"hummus","commodity":"Hummus","unit":"oz","cheapest_store":"Sam''s Club","stores":[' +
  '{"store":"Sam''s Club","per_unit":0.1,"item":"Member''s Mark Hummus Singles 16 ct 2.5 oz","ad":"$4.00","size":"16 ct 2.5 oz"},' +
  '{"store":"Walmart","per_unit":0.3,"item":"Sabra Classic Hummus 10 oz","ad":"$3.00","size":"10 oz"}]}'
function Invoke-Pb([string]$name, [string]$rows, [switch]$Strict) {
  $d = Join-Path $tmp $name
  New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null
  $bf = Join-Path $d 'comparison-2026-09-25.json'
  [IO.File]::WriteAllText($bf, ('{"comparison":[' + $rows + ']}'), $utf8)
  $allow = Join-Path $d 'no-allowlist.json'
  if ($Strict) { $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $audit -CompareFile $bf -ReportDir $d -AllowFile $allow -Strict) }
  else { $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $audit -CompareFile $bf -ReportDir $d -AllowFile $allow) }
  return [pscustomobject]@{ rc = $LASTEXITCODE; out = $o; text = ($o -join ' / ') }
}
try {
  New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
  # MUST FIRE: the founding Pledge pack total holds ONE cell, furniture-polish / Sam's Club, as a value.
  $r = Invoke-Pb 'fire' $polish
  $sc = Get-TcChildQuarantineScope $r.out
  $cells = @(); if ($sc) { $cells = @($sc.cells) }
  Pc 'MUST FIRE  a CONFIRMED pack total exits 2 and is named for guards as furniture-polish / Sam''s Club [value], scope complete' (($r.rc -eq 2) -and ($null -ne $sc) -and ($cells.Count -eq 1) -and ([string]$cells[0].id -eq 'furniture-polish') -and ([string]$cells[0].store -eq 'Sam''s Club') -and ([string]$cells[0].kind -eq 'value')) ('rc=' + $r.rc + ' ' + $r.text)
  # MUST FIRE: beside an undecidable (advisory) finding, only the confirmed cell is named.
  $r = Invoke-Pb 'mixed' ($polish + ',' + $hummus)
  $sc = Get-TcChildQuarantineScope $r.out
  $cells = @(); if ($sc) { $cells = @($sc.cells) }
  Pc 'MUST FIRE  with an advisory hummus finding beside it, exactly the one confirmed cell is named (hummus never is)' (($r.rc -eq 2) -and ($null -ne $sc) -and ($cells.Count -eq 1) -and (@($r.out | Where-Object { $_ -match '^QUARANTINE-CELL hummus' }).Count -eq 0)) ('rc=' + $r.rc + ' ' + $r.text)
  # CLEAN TWIN: -Strict makes the undecidable hummus a failure that names no cell, so the audit still exits 2 and
  # affirms no scope: guards holds the board, exactly as before this change.
  $r = Invoke-Pb 'strict' ($polish + ',' + $hummus) -Strict
  $sc = Get-TcChildQuarantineScope $r.out
  Pc 'CLEAN TWIN  -Strict over an undecidable finding still exits 2 and affirms no scope, so the board holds' (($r.rc -eq 2) -and ($null -eq $sc) -and ($r.text -match 'PACK-BASIS BLOCKED')) ('rc=' + $r.rc + ' ' + $r.text)
  # MUST NOT FIRE: an advisory finding alone exits 0 and prints no quarantine line.
  $r = Invoke-Pb 'advisory' $hummus
  Pc 'MUST NOT FIRE  an advisory-only board exits 0 and prints no QUARANTINE line' (($r.rc -eq 0) -and (@($r.out | Where-Object { $_ -match '^QUARANTINE-' }).Count -eq 0)) ('rc=' + $r.rc + ' ' + $r.text)
} catch { Write-Output ('FAIL  a case threw: ' + $_.Exception.Message); $script:bad++ }
finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } }
Write-Output ('test-pack-basis-scope self-test ' + $(if ($script:bad -eq 0 -and $script:n -eq 4) { 'pass' } else { 'FAIL' }) + ': ' + ($script:n - $script:bad) + ' of ' + $script:n + ' case(s) passed (4 expected)')
exit $(if ($script:bad -eq 0 -and $script:n -eq 4) { 0 } else { 1 })
