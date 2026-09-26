<#
  test-known-wrong-scope.ps1 -SelfTest - audit-known-wrong.ps1 names its BLOCKED cells in the QUARANTINE-CELL protocol
  (queue 2026-09-22-6e6a3b, Brad 2026-09-21: one bad item must not hold the board), and affirms a complete scope only
  when a cell hold can reach every blocked cell. Each case runs the real audit as a child against a per-run fixture
  tree and reads its output through the same Get-TcChildQuarantineScope guards.ps1 uses.
#>
# The self-test runs audit-known-wrong.ps1 over temp roots it builds; it loads cell-quarantine-lib.ps1.
# gate-inputs: grocery\audit-known-wrong.ps1, grocery\cell-quarantine-lib.ps1
[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
if (-not $SelfTest) { Write-Output 'test-known-wrong-scope: run with -SelfTest'; exit 3 }
. (Join-Path $PSScriptRoot 'cell-quarantine-lib.ps1')
$script:bad = 0; $script:n = 0
function Kc([string]$label, [bool]$ok, [string]$got) { $script:n++; if ($ok) { Write-Output ('ok    ' + $label) } else { Write-Output ('FAIL  ' + $label + ' :: ' + $got); $script:bad++ } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('kws-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
$audit = Join-Path $PSScriptRoot 'audit-known-wrong.ps1'
$utf8 = New-Object Text.UTF8Encoding($false)
$list = '{"entries":[{"key":"salmon|Walmart|cat food","commodity":"salmon","store":"Walmart","names":["Blue Buffalo Wilderness Adult Cat Salmon Recipe, 9.5 lb"],"retire_when":"ruling-reversed","evidence":"fixture","ruled_on":"2026-09-25","ruled_by":"fixture"}]}'
$wrong = '{"store":"Walmart","per_unit":4.1032,"item":"Blue Buffalo Wilderness Adult Cat Salmon Recipe, 9.5 lb","ad":"$38.98","size":"9.5 lb"}'
$good = '{"store":"Aldi","per_unit":5.18,"item":"Fremont Fish Market Atlantic Salmon Portions","ad":"$5.18","size":"lb"}'
function New-KwTree([string]$name, [string]$boardStores, [string]$recipeStores) {
  $root = Join-Path $tmp $name
  New-Item -ItemType Directory -Path (Join-Path $root 'out') -Force -ErrorAction Stop | Out-Null
  [IO.File]::WriteAllText((Join-Path $root 'known-wrong.json'), $list, $utf8)
  [IO.File]::WriteAllText((Join-Path $root 'out\comparison-2026-09-25.json'), ('{"comparison":[{"id":"salmon","unit":"lb","cheapest_store":"Walmart","stores":[' + $boardStores + ']}]}'), $utf8)
  if ($recipeStores) { [IO.File]::WriteAllText((Join-Path $root 'out\recipe-board.json'), ('{"comparison":[{"id":"salmon","unit":"lb","cheapest_store":"Walmart","stores":[' + $recipeStores + ']}]}'), $utf8) }
  return $root
}
function Invoke-Kw([string]$root) {
  $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $audit -Root $root -ListFile (Join-Path $root 'known-wrong.json'))
  return [pscustomobject]@{ rc = $LASTEXITCODE; out = $o; text = ($o -join ' / ') }
}
try {
  New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
  # MUST FIRE: the founding shape - a ruled-wrong product priced on the comparison board holds ONE cell, not the board.
  $r = Invoke-Kw (New-KwTree 'fire' ($wrong + ',' + $good) '')
  $sc = Get-TcChildQuarantineScope $r.out
  $cells = @(); if ($sc) { $cells = @($sc.cells) }
  Kc 'MUST FIRE  a BLOCKED comparison-board cell exits 2 and is named for guards as salmon / Walmart [value], scope complete' (($r.rc -eq 2) -and ($null -ne $sc) -and ($cells.Count -eq 1) -and ([string]$cells[0].id -eq 'salmon') -and ([string]$cells[0].store -eq 'Walmart') -and ([string]$cells[0].kind -eq 'value')) ('rc=' + $r.rc + ' ' + $r.text)
  Kc 'MUST FIRE  the named cell is only the blocked one: the Aldi salmon cell is never named' (@($r.out | Where-Object { $_ -match '^QUARANTINE-CELL salmon\|Aldi' }).Count -eq 0) $r.text
  # CLEAN TWIN: the blocked cell ALSO sits on recipe-board.json, which a cell quarantine cannot reach, so the audit still
  # fails AND still holds the whole board (no complete line), exactly as before this change.
  $r = Invoke-Kw (New-KwTree 'recipe' $good $wrong)
  $sc = Get-TcChildQuarantineScope $r.out
  Kc 'CLEAN TWIN  a blocked recipe-board cell still exits 2 and affirms no scope, so guards holds the board' (($r.rc -eq 2) -and ($null -eq $sc) -and ($r.text -match 'cell quarantine cannot reach')) ('rc=' + $r.rc + ' ' + $r.text)
  # MUST NOT FIRE: a clean board prints no quarantine line at all.
  $r = Invoke-Kw (New-KwTree 'clean' $good '')
  Kc 'MUST NOT FIRE  a clean board exits 0 and prints no QUARANTINE line' (($r.rc -eq 0) -and (@($r.out | Where-Object { $_ -match '^QUARANTINE-' }).Count -eq 0)) ('rc=' + $r.rc + ' ' + $r.text)
} catch { Write-Output ('FAIL  a case threw: ' + $_.Exception.Message); $script:bad++ }
finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } }
Write-Output ('test-known-wrong-scope self-test ' + $(if ($script:bad -eq 0 -and $script:n -eq 4) { 'pass' } else { 'FAIL' }) + ': ' + ($script:n - $script:bad) + ' of ' + $script:n + ' case(s) passed (4 expected)')
exit $(if ($script:bad -eq 0 -and $script:n -eq 4) { 0 } else { 1 })
