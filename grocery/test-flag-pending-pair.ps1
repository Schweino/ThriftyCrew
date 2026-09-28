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
# Multi-day fixtures (queue 2026-09-27-10d164): the board is comparison-2026-09-28.json and every day in $days gets its own
# guards-<day>.json, so the audit's own multi-file read is what is exercised.
$lmFixed = '"id":"lemons","unit":"each","store":"Family Fare","item":"Glad Drawstring Odor Shield Lemon Tall Kitchen 40 Ct","per_unit":0.2748,"row_type":"sale","ad":"$10.99","size":"40 ct","ad_from":"2026-09-27","ad_to":"2026-10-03","as_of":""'
$wmLemon = '{"store":"Walmart","per_unit":0.5,"unit":"each","type":"sale","item":"Fresh Bulk Yellow Lemons","ad":"$0.5","size":"each","ad_from":"2026-09-05","ad_to":"2026-10-05","as_of":"2026-09-05"}'
$bcRow = '{"commodity":"Bacon","id":"bacon","unit":"lb","cheapest_store":"Fareway","cheapest_price":1.596,"nomem_store":"Fareway","stores":[{"store":"Fareway","per_unit":1.596,"unit":"lb","type":"sale","item":"Fareway Hickory Smoked Bacon 2.5 lb (only $3.99/lb)","ad":"$9.97","size":"2.5 lb","ad_from":"2026-09-28","ad_to":"2026-10-03","as_of":""},{"store":"Walmart","per_unit":3.96,"unit":"lb","type":"everyday","item":"Great Value Hickory Smoked Bacon, Mega Pack, 24 oz","ad":"$5.94","size":"1.5 lb","ad_from":"","ad_to":"","as_of":"2026-08-31"}]}'
$bcCommon = '"id":"bacon","unit":"lb","store":"Fareway","item":"Fareway Hickory Smoked Bacon 2.5 lb (only $3.99/lb)","per_unit":1.596,"row_type":"sale","ad":"$9.97","size":"2.5 lb","ad_from":"2026-09-28","ad_to":"2026-10-03","as_of":""'
$bcFlags = '{"commodity":"Bacon","type":"outlier","detail":"Fareway $1.60 is 60% below runner-up Aldi $3.95 - verify the price/size parse",' + $bcCommon + '},{"commodity":"Bacon","type":"wow","detail":"cheapest moved down 47% vs last week ($2.99 -> $1.60) - unexplained: a NEW price at the cheapest store: Fareway ''Fareway Hickory Smoked Bacon 2.5 lb (only $3.99/lb)'' $1.5960 (was ''Fareway Hickory Smoked Bacon'' $2.9900)",' + $bcCommon + '}'
function Get-LemonBoard([bool]$withBacon, [string]$ffItem, [string]$ffPu) {
  $ff = '{"store":"Family Fare","per_unit":' + $ffPu + ',"unit":"each","type":"sale","item":"' + $ffItem + '","ad":"$10.99","size":"40 ct","ad_from":"2026-09-27","ad_to":"2026-10-03","as_of":""}'
  $rows = '{"commodity":"Lemons","id":"lemons","unit":"each","cheapest_store":"Family Fare","cheapest_price":' + $ffPu + ',"nomem_store":"Family Fare","stores":[' + $ff + ',' + $wmLemon + ']}'
  if ($withBacon) { $rows = $rows + ',' + $bcRow }
  return ('{"week_of":"2026-09-28","comparison":[' + $rows + ']}')
}
# guards-2026-09-27.json carries both flags for the Glad claim; guards-2026-09-28.json the outlier only ($withWow = $false).
function Get-LemonFlags([bool]$withWow) {
  $o = '{"commodity":"Lemons","type":"outlier","detail":"Family Fare $0.27 is 45% below runner-up Walmart $0.50 - verify the price/size parse",' + $lmFixed + '}'
  if (-not $withWow) { return ('[' + $o + ']') }
  return ('[' + $o + ',{"commodity":"Lemons","type":"wow","detail":"cheapest moved down 45% vs last week ($0.50 -> $0.27) - unexplained: a NEW price at the cheapest store: Family Fare ''Glad Drawstring Odor Shield Lemon Tall Kitchen 40 Ct'' $0.2748 (was ''8 Ct Lemon Bars'' $0.7488)",' + $lmFixed + '}]')
}
function Get-LemonLedger([string]$openStatus, [bool]$closedMatch) {
  $e = '{"key":"lemons|Family Fare","id":"lemons","commodity":"Lemons","store":"Family Fare","unit":"each","claim":{"item":"Glad Drawstring Odor Shield Lemon Tall Kitchen 40 Ct","per_unit":0.2748,"ad":"$10.99","size":"40 ct","row_type":"sale","ad_from":"2026-09-27","ad_to":"2026-10-03","as_of":"","deal_qty":null,"deal_condition":""},"claim_key":"glad drawstring odor shield lemon tall kitchen 40 ct|2748","flag_types":["outlier","wow"],"first_flagged":"2026-09-27","last_flagged":"2026-09-28","status":"STATUS","reason":"no read of this product later than 2026-09-27 has landed yet","verdict_at":"","answer":null,"attempts":1,"last_attempt":"2026-09-28","alerted_at":"","closed_at":"CLOSED","readings":[]}'
  $entries = '{}'; $closed = '[]'
  if ($openStatus) { $entries = '{"lemons|Family Fare":' + $e.Replace('STATUS', $openStatus).Replace('CLOSED', '') + '}' }
  if ($closedMatch) { $closed = '[' + $e.Replace('STATUS', 'match').Replace('CLOSED', '2026-09-28') + ']' }
  return ('{"generated":"2026-09-28","entries":' + $entries + ',"closed":' + $closed + '}')
}
function Invoke-Fv2([string]$name, [string]$board, [hashtable]$days, [string]$ledger) {
  $o = Join-Path $tmp $name
  New-Item -ItemType Directory -Path $o -Force -ErrorAction Stop | Out-Null
  [IO.File]::WriteAllText((Join-Path $o 'comparison-2026-09-28.json'), $board, $utf8)
  [IO.File]::WriteAllText((Join-Path $o 'flag-verification.json'), $ledger, $utf8)
  foreach ($d in $days.Keys) { [IO.File]::WriteAllText((Join-Path $o ('guards-' + $d + '.json')), [string]$days[$d], $utf8) }
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

  # ---- THE PAIR PERSISTS (queue 2026-09-27-10d164). Frozen from comparison-2026-09-28 and guards-2026-09-27/28 (lemons,
  # Family Fare 'Glad Drawstring ...' trash bags; bacon, Fareway). Day 1 carries outlier + unexplained NEW wow; day 2 the
  # outlier only, because the wow baseline (the 09-27 comparison) already held the Glad claim. Today's code read one day.
  $r = Invoke-Fv2 'must-fire-decay' (Get-LemonBoard $true 'Glad Drawstring Odor Shield Lemon Tall Kitchen 40 Ct' '0.2748') @{ '2026-09-27' = (Get-LemonFlags $true); '2026-09-28' = ('[' + (Get-LemonFlags $false).TrimStart('[').TrimEnd(']') + ',' + $bcFlags + ']') } (Get-LemonLedger 'pending' $false)
  $lq = @($r.q | Where-Object { $_ -eq 'QUARANTINE-CELL lemons|Family Fare|value' }); $bq = @($r.q | Where-Object { $_ -eq 'QUARANTINE-CELL bacon|Fareway|value' })
  Frc 'MUST FIRE  pair decays on day 2: Glad lemons crown paired on guards-2026-09-27, outlier only on guards-2026-09-28, ledger pending -> QUARANTINE-CELL lemons|Family Fare|value, and the 09-28 bacon|Fareway pair named exactly once (cells=2, exit 2)' (($r.rc -eq 2) -and ($lq.Count -eq 1) -and ($bq.Count -eq 1) -and ($r.q.Count -eq 2) -and ($r.text -match '2 guards file\(s\), days 2026-09-27,2026-09-28')) $r.text

  $r = Invoke-Fv2 'twin-decay-closed-match' (Get-LemonBoard $false 'Glad Drawstring Odor Shield Lemon Tall Kitchen 40 Ct' '0.2748') @{ '2026-09-27' = (Get-LemonFlags $true); '2026-09-28' = (Get-LemonFlags $false) } (Get-LemonLedger '' $true)
  Frc 'CLEAN TWIN  the same two days with the claim closed match -> released, nothing named (exit 0)' (($r.rc -eq 0) -and ($r.q.Count -eq 0)) $r.text

  $r = Invoke-Fv2 'twin-decay-changed-claim' (Get-LemonBoard $false 'Sunkist Lemons 2 Lb' '0.2998') @{ '2026-09-27' = (Get-LemonFlags $true); '2026-09-28' = '[]' } (Get-LemonLedger 'pending' $false)
  Frc 'CLEAN TWIN  day 2 publishes a DIFFERENT Family Fare lemons claim: the day-1 Glad pair does not carry to it (exit 0)' (($r.rc -eq 0) -and ($r.q.Count -eq 0)) $r.text

  $r = Invoke-Fv2 'twin-decay-before-ad-from' (Get-LemonBoard $false 'Glad Drawstring Odor Shield Lemon Tall Kitchen 40 Ct' '0.2748') @{ '2026-09-26' = (Get-LemonFlags $true); '2026-09-28' = (Get-LemonFlags $false) } (Get-LemonLedger 'pending' $false)
  Frc 'CLEAN TWIN  a pair dated 2026-09-26, before the claim''s ad_from 2026-09-27, is not carried (exit 0)' (($r.rc -eq 0) -and ($r.q.Count -eq 0)) $r.text

  $r = Invoke-Fv2 'not-fire-duplicate' (Get-LemonBoard $false 'Glad Drawstring Odor Shield Lemon Tall Kitchen 40 Ct' '0.2748') @{ '2026-09-27' = (Get-LemonFlags $true); '2026-09-28' = (Get-LemonFlags $true) } (Get-LemonLedger 'pending' $false)
  Frc 'MUST NOT FIRE  a pair present on BOTH days is not named twice: exactly one QUARANTINE-CELL lemons|Family Fare|value (cells=1)' (($r.rc -eq 2) -and ($r.q.Count -eq 1) -and ($r.text -match 'cells=1 stores=0')) $r.text
} catch {
  Frc 'harness' $false $_.Exception.Message
} finally {
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
$okAll = ($script:bad -eq 0 -and $script:n -eq 14)
Write-Output ('test-flag-pending-pair: ' + $script:n + ' case(s), ' + $script:bad + ' failed; self-test ' + $(if ($okAll) { 'pass' } else { 'FAIL' }))
exit $(if ($okAll) { 0 } else { 1 })
