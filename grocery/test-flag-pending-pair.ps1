<#
  test-flag-pending-pair.ps1 -SelfTest - audit-flag-verification.ps1 HOLDS a crown flagged BOTH as an unverified outlier and
  as an unexplained new cheapest product while its check is pending (queue 2026-09-27-c744ba, Get-TcPendingPairCells in
  flag-verify-lib.ps1). Founding case, frozen from the real 2026-09-27 rows: Family Fare's "Screamin' Sicilian Pizza Co.
  Cheesy Marinara Loaded Breadstix 9 Ea" crowned frozen-pizza at $0.7767/each against Sam's $2.6367, flagged 'outlier' and
  'wow ... unexplained: a NEW price at the cheapest store' by sanity-check at 08:27, ledger 'pending', and it published.
  Second must-fire from guards-2026-09-23.json: raspberries|Fareway "AE Dairy Raspberry Yolite" $0.165/oz, same two flags.
  Each case runs the real audit as a child with -OutDir at a per-run fixture tree (board, ledger, guards flags) and reads
  its exit code and its QUARANTINE lines, exactly as guards.ps1 does. Fixtures are literals, never regenerated from a board.
#>
# gate-inputs: grocery\audit-flag-verification.ps1, grocery\flag-verify-lib.ps1
[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
if (-not $SelfTest) { Write-Output 'test-flag-pending-pair: run with -SelfTest'; exit 3 }
$script:bad = 0; $script:n = 0
function Frc([string]$label, [bool]$ok, [string]$got) { $script:n++; if ($ok) { Write-Output ('ok    ' + $label) } else { Write-Output ('FAIL  ' + $label + ' :: ' + $got); $script:bad++ } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fvpp-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
$audit = Join-Path $PSScriptRoot 'audit-flag-verification.ps1'
$utf8 = New-Object Text.UTF8Encoding($false)

$bsItem = 'Screamin'' Sicilian Pizza Co. Cheesy Marinara Loaded Breadstix 9 Ea'
$bsCell = '{"store":"Family Fare","per_unit":0.7767,"unit":"each","type":"sale","item":"Screamin'' Sicilian Pizza Co. Cheesy Marinara Loaded Breadstix 9 Ea","ad":"$6.99","size":"9 ea","ad_from":"2026-09-27","ad_to":"2026-10-03","as_of":""}'
$samsCell = '{"store":"Sam''s Club","per_unit":2.6367,"unit":"each","type":"everyday","item":"Member''s Mark Rising Crust Four Cheese Pizza, Frozen, 3 pk.","ad":"$7.91","size":"3 pk","as_of":"2026-09-27"}'
$ffPizza = '{"store":"Family Fare","per_unit":5.0,"unit":"each","type":"everyday","item":"Digiorno Rising Crust Supreme","ad":"$5.00","size":"1 ea","as_of":"2026-09-27"}'
function Get-PizzaBoard([bool]$fixed) {
  if ($fixed) { return ('{"week_of":"2026-09-27","comparison":[{"commodity":"Frozen Pizza","id":"frozen-pizza","unit":"each","cheapest_store":"Sam''s Club","cheapest_price":2.6367,"nomem_store":"Family Fare","stores":[' + $samsCell + ',' + $ffPizza + ']}]}') }
  return ('{"week_of":"2026-09-27","comparison":[{"commodity":"Frozen Pizza","id":"frozen-pizza","unit":"each","cheapest_store":"Family Fare","cheapest_price":0.7767,"nomem_store":"Family Fare","stores":[' + $bsCell + ',' + $samsCell + ']}]}')
}
# The two flags exactly as guards-2026-09-27.json (08:27) carries them; $otype / $wtype let a twin retype one.
function Get-PizzaFlags([string]$otype, [string]$wtype) {
  $wdetail = 'cheapest moved down 71% vs last week ($2.64 -> $0.78) - unexplained: a NEW price at the cheapest store: Family Fare ''Screamin'' Sicilian Pizza Co. Cheesy Marinara Loaded Breadstix 9 Ea'' $0.7767 (was ''Jack''s Original Thin Cheese Pizza 13.8 Oz'' $3.5000)'
  if ($wtype -eq 'wow-explained') { $wdetail = 'cheapest moved down 71% vs last week ($2.64 -> $0.78) - explained: a sale at the cheapest store' }
  $common = '"id":"frozen-pizza","unit":"each","store":"Family Fare","item":"Screamin'' Sicilian Pizza Co. Cheesy Marinara Loaded Breadstix 9 Ea","per_unit":0.7767,"row_type":"sale","ad":"$6.99","size":"9 ea","ad_from":"2026-09-27","ad_to":"2026-10-03","as_of":""'
  return ('[{"commodity":"Frozen Pizza","type":"' + $otype + '","detail":"Family Fare $0.78 is 71% below runner-up Sam''s Club $2.64 - verify the price/size parse",' + $common + '},' +
    '{"commodity":"Frozen Pizza","type":"' + $wtype + '","detail":"' + $wdetail + '",' + $common + '}]')
}
function Get-PizzaLedger([string]$openStatus, [bool]$closedMatch) {
  $claim = '"claim":{"item":"Screamin'' Sicilian Pizza Co. Cheesy Marinara Loaded Breadstix 9 Ea","per_unit":0.7767,"ad":"$6.99","size":"9 ea","row_type":"sale","ad_from":"2026-09-27","ad_to":"2026-10-03","as_of":"","deal_qty":null,"deal_condition":""},"claim_key":"screamin'' sicilian pizza co. cheesy marinara loaded breadstix 9 ea|7767"'
  $e = '{"key":"frozen-pizza|Family Fare","id":"frozen-pizza","commodity":"Frozen Pizza","store":"Family Fare","unit":"each",' + $claim + ',"flag_types":["outlier","wow"],"first_flagged":"2026-09-27","last_flagged":"2026-09-27","status":"STATUS","reason":"","verdict_at":"","answer":null,"attempts":1,"last_attempt":"2026-09-27","alerted_at":"","closed_at":"CLOSED","readings":[]}'
  $entries = '{}'; $closed = '[]'
  if ($openStatus) { $entries = '{"frozen-pizza|Family Fare":' + $e.Replace('STATUS', $openStatus).Replace('CLOSED', '') + '}' }
  if ($closedMatch) { $closed = '[' + $e.Replace('STATUS', 'match').Replace('CLOSED', '2026-09-27') + ']' }
  return ('{"generated":"2026-09-27","entries":' + $entries + ',"closed":' + $closed + '}')
}
function Invoke-Fv([string]$name, [string]$board, [string]$flags, [string]$ledger) {
  $o = Join-Path $tmp $name
  New-Item -ItemType Directory -Path $o -Force -ErrorAction Stop | Out-Null
  [IO.File]::WriteAllText((Join-Path $o 'comparison-2026-09-27.json'), $board, $utf8)
  [IO.File]::WriteAllText((Join-Path $o 'flag-verification.json'), $ledger, $utf8)
  if ($flags) { [IO.File]::WriteAllText((Join-Path $o 'guards-2026-09-27.json'), $flags, $utf8) }
  $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $audit -OutDir $o -NoRejudge)
  $rc = $LASTEXITCODE
  $ql = @($out | Where-Object { ([string]$_).StartsWith('QUARANTINE-CELL ', [StringComparison]::Ordinal) })
  return [pscustomobject]@{ rc = $rc; out = $out; q = $ql; text = ($out -join ' / ') }
}
try {
  New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
  $pend = Get-PizzaLedger 'pending' $false
  $r = Invoke-Fv 'must-fire-pizza' (Get-PizzaBoard $false) (Get-PizzaFlags 'outlier' 'wow') $pend
  Frc 'MUST FIRE  founding 2026-09-27: Breadstix crown at Family Fare $0.7767/each, outlier + unexplained NEW wow, ledger pending -> QUARANTINE-CELL frozen-pizza|Family Fare|value, scope complete cells=1, exit 2' (($r.rc -eq 2) -and ($r.q.Count -eq 1) -and ($r.q[0] -eq 'QUARANTINE-CELL frozen-pizza|Family Fare|value') -and ($r.text -match 'QUARANTINE-SCOPE complete cells=1 stores=0')) $r.text

  $r = Invoke-Fv 'must-fire-no-entry' (Get-PizzaBoard $false) (Get-PizzaFlags 'outlier' 'wow') (Get-PizzaLedger '' $false)
  Frc 'MUST FIRE  the same crown with NO ledger entry yet (verifier has not run) is named: no verdict is not a pass (exit 2)' (($r.rc -eq 2) -and ($r.q.Count -eq 1) -and ($r.q[0] -eq 'QUARANTINE-CELL frozen-pizza|Family Fare|value')) $r.text

  # Second founding row, guards-2026-09-23.json verbatim; runner-up per its own detail (Family Fare $0.29).
  $rbBoard = '{"week_of":"2026-09-27","comparison":[{"commodity":"Raspberries","id":"raspberries","unit":"oz","cheapest_store":"Fareway","cheapest_price":0.165,"nomem_store":"Fareway","stores":[{"store":"Fareway","per_unit":0.165,"unit":"oz","type":"everyday","item":"AE Dairy Raspberry Yolite","ad":"$0.99","size":"6 oz","as_of":"2026-09-26"},{"store":"Family Fare","per_unit":0.29,"unit":"oz","type":"everyday","item":"Fresh Red Raspberry","ad":"$1.74","size":"6 oz","as_of":"2026-09-26"}]}]}'
  $rbCommon = '"id":"raspberries","unit":"oz","store":"Fareway","item":"AE Dairy Raspberry Yolite","per_unit":0.165,"row_type":"everyday","ad":"$0.99","size":"6 oz","ad_from":"","ad_to":"","as_of":"2026-09-26"'
  $rbFlags = '[{"commodity":"Raspberries","type":"outlier","detail":"Fareway $0.17 is 42% below runner-up Family Fare $0.29 - verify the price/size parse",' + $rbCommon + '},{"commodity":"Raspberries","type":"wow","detail":"cheapest moved down 50% vs last week ($0.33 -> $0.17) - unexplained: a NEW price at the cheapest store: Fareway ''AE Dairy Raspberry Yolite'' $0.1650 (was last $0.8317)",' + $rbCommon + '}]'
  $r = Invoke-Fv 'must-fire-raspberry' $rbBoard $rbFlags '{"generated":"2026-09-23","entries":{},"closed":[]}'
  Frc 'MUST FIRE  2026-09-23: raspberries|Fareway AE Dairy Raspberry Yolite $0.165/oz with both flags -> QUARANTINE-CELL raspberries|Fareway|value (exit 2)' (($r.rc -eq 2) -and ($r.q.Count -eq 1) -and ($r.q[0] -eq 'QUARANTINE-CELL raspberries|Fareway|value')) $r.text

  $r = Invoke-Fv 'not-fire-outlier-verified' (Get-PizzaBoard $false) (Get-PizzaFlags 'outlier-verified' 'wow') $pend
  Frc 'MUST NOT FIRE  the outlier typed outlier-verified (the store''s own unit price reproduces ours) names no cell (exit 0)' (($r.rc -eq 0) -and ($r.q.Count -eq 0)) $r.text

  $r = Invoke-Fv 'not-fire-wow-explained' (Get-PizzaBoard $false) (Get-PizzaFlags 'outlier' 'wow-explained') $pend
  Frc 'MUST NOT FIRE  the wow typed wow-explained names no cell (exit 0)' (($r.rc -eq 0) -and ($r.q.Count -eq 0)) $r.text

  $r = Invoke-Fv 'twin-closed-match' (Get-PizzaBoard $false) (Get-PizzaFlags 'outlier' 'wow') (Get-PizzaLedger '' $true)
  Frc 'CLEAN TWIN  both flags but the ledger closed the same claim as a match (verified) -> released, exit 0' (($r.rc -eq 0) -and ($r.q.Count -eq 0)) $r.text

  $r = Invoke-Fv 'twin-wrong-product-once' (Get-PizzaBoard $false) (Get-PizzaFlags 'outlier' 'wow') (Get-PizzaLedger 'wrong-product' $false)
  Frc 'CLEAN TWIN  a wrong-product verdict on the same claim is still named, exactly ONCE (cells=1)' (($r.rc -eq 2) -and ($r.q.Count -eq 1) -and ($r.text -match 'cells=1 stores=0') -and ($r.text -match 'CONTRADICTED BY ITS STORE')) $r.text

  $r = Invoke-Fv 'twin-sams-crown' (Get-PizzaBoard $true) (Get-PizzaFlags 'outlier' 'wow') $pend
  Frc 'CLEAN TWIN  the fixed board (Sam''s Member''s Mark 3 pk crown $2.6367, no flags on it) with the stale 08:27 flags names nothing: the Breadstix claim is no longer published (exit 0)' (($r.rc -eq 0) -and ($r.q.Count -eq 0)) $r.text

  $r = Invoke-Fv 'blind-no-flags' (Get-PizzaBoard $false) '' $pend
  Frc 'CLEAN TWIN  no guards-<date>.json: the pair check says BLIND and the ledger path still runs (exit 0, pending names nothing)' (($r.rc -eq 0) -and ($r.text -match 'pending-pair check BLIND')) $r.text
} catch {
  Frc 'harness' $false $_.Exception.Message
} finally {
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
$okAll = ($script:bad -eq 0 -and $script:n -eq 9)
Write-Output ('test-flag-pending-pair: ' + $script:n + ' case(s), ' + $script:bad + ' failed; self-test ' + $(if ($okAll) { 'pass' } else { 'FAIL' }))
exit $(if ($okAll) { 0 } else { 1 })
