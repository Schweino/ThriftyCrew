<#
  test-tile-integrity-scope.ps1 -SelfTest - audit-tile-integrity.ps1 names each ACCURACY tile in the QUARANTINE-CELL
  protocol (queue 2026-09-22-6e6a3b, Brad 2026-09-21: one bad item must not hold the board), and affirms no scope on its
  HELD exit (stale name-drift flags), which still holds the whole board. Each case runs the real audit as a child with
  -OutDir and -ProductUrlsFile at a per-run fixture and reads its output through the same Get-TcChildQuarantineScope
  guards.ps1 uses. The founding row is the 2026-09-20 Sam's pads tile (0.1683/each on the board), here linked at a
  factor-off price so it is a PRICE-MISMATCH.
#>
[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
if (-not $SelfTest) { Write-Output 'test-tile-integrity-scope: run with -SelfTest'; exit 3 }
. (Join-Path $PSScriptRoot 'cell-quarantine-lib.ps1')
$script:bad = 0; $script:n = 0
function Tic([string]$label, [bool]$ok, [string]$got) { $script:n++; if ($ok) { Write-Output ('ok    ' + $label) } else { Write-Output ('FAIL  ' + $label + ' :: ' + $got); $script:bad++ } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('tis-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
$audit = Join-Path $PSScriptRoot 'audit-tile-integrity.ps1'
$utf8 = New-Object Text.UTF8Encoding($false)
function Invoke-Ti([string]$name, [string]$padsPrice, [switch]$StaleFlags) {
  $d = Join-Path $tmp $name
  New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null
  [IO.File]::WriteAllText((Join-Path $d 'comparison-2026-09-20.json'), ('{"comparison":[' +
    '{"id":"feminine-pads","unit":"each","stores":[{"store":"Sam''s Club","per_unit":0.1683,"type":"everyday","item":"Always Ultra Thin Long Super Pads with Wings, Size 2, 92 ct."}]},' +
    '{"id":"paper-towels","unit":"each","stores":[{"store":"Fareway","per_unit":1.0,"type":"everyday","item":"Frozen Twin Paper Towels"}]}]}'), $utf8)
  $pu = Join-Path $d 'product-urls.json'
  [IO.File]::WriteAllText($pu, ('{"items":{' +
    '"feminine-pads":{"Sam''s Club":{"url":"https://www.samsclub.com/ip/15235818162","name":"Always Ultra Thin Long Super Pads with Wings, Size 2, 92 ct.","price":"' + $padsPrice + '","size":"92 ct"}},' +
    '"paper-towels":{"Fareway":{"url":"https://shop.fareway.com/p/1","name":"Frozen Twin Paper Towels","price":"$6.00","size":"6 ct"}}}}'), $utf8)
  $nd = Join-Path $d 'name-drift.json'
  [IO.File]::WriteAllText($nd, '{ "flags": [] }', $utf8)
  $now = (Get-Date).ToUniversalTime()
  if ($StaleFlags) { (Get-Item $nd).LastWriteTimeUtc = $now.AddMinutes(-30); (Get-Item $pu).LastWriteTimeUtc = $now }
  else { (Get-Item $nd).LastWriteTimeUtc = $now.AddMinutes(10) }
  $o = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $audit -OutDir $d -ProductUrlsFile $pu -Quiet)
  return [pscustomobject]@{ rc = $LASTEXITCODE; out = $o; text = ($o -join ' / ') }
}
try {
  New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
  # MUST FIRE: the pads link at $4.00 for 92 ct (0.0435/each, a factor off 0.1683) holds ONE cell as a value.
  $r = Invoke-Ti 'fire' '$4.00'
  $sc = Get-TcChildQuarantineScope $r.out
  $cells = @(); if ($sc) { $cells = @($sc.cells) }
  Tic 'MUST FIRE  a PRICE-MISMATCH link exits 2 and is named for guards as feminine-pads / Sam''s Club [value], scope complete' (($r.rc -eq 2) -and ($null -ne $sc) -and ($cells.Count -eq 1) -and ([string]$cells[0].id -eq 'feminine-pads') -and ([string]$cells[0].store -eq 'Sam''s Club') -and ([string]$cells[0].kind -eq 'value')) ('rc=' + $r.rc + ' ' + $r.text)
  # CLEAN TWIN: the HELD exit (name-drift older than product-urls) still exits 2 and says HELD, with no scope affirmed,
  # so guards holds the board exactly as before this change.
  $r = Invoke-Ti 'held' '$4.00' -StaleFlags
  $sc = Get-TcChildQuarantineScope $r.out
  Tic 'CLEAN TWIN  stale name-drift flags still exit 2 HELD, with no scope affirmed' (($r.rc -eq 2) -and ($null -eq $sc) -and ($r.text -match 'HELD: out\\name-drift\.json')) ('rc=' + $r.rc + ' ' + $r.text)
  # MUST NOT FIRE: the link at the board's own price exits 0 and prints no quarantine line.
  $r = Invoke-Ti 'clean' '$15.48'
  Tic 'MUST NOT FIRE  a link at the board''s price exits 0 and prints no QUARANTINE line' (($r.rc -eq 0) -and (@($r.out | Where-Object { $_ -match '^QUARANTINE-' }).Count -eq 0)) ('rc=' + $r.rc + ' ' + $r.text)
} catch { Write-Output ('FAIL  a case threw: ' + $_.Exception.Message); $script:bad++ }
finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } }
Write-Output ('test-tile-integrity-scope self-test ' + $(if ($script:bad -eq 0 -and $script:n -eq 3) { 'pass' } else { 'FAIL' }) + ': ' + ($script:n - $script:bad) + ' of ' + $script:n + ' case(s) passed (3 expected)')
exit $(if ($script:bad -eq 0 -and $script:n -eq 3) { 0 } else { 1 })
