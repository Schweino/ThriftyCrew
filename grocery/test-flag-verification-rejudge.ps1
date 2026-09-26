<#
  test-flag-verification-rejudge.ps1 -SelfTest - audit-flag-verification.ps1 RE-JUDGES every open ledger entry with the
  current verifier code before it names a cell, so a verdict judged one chain earlier can neither hold nor pass a board
  (queue 2026-09-26-f73dc7). Founding case, frozen from 2026-09-26: guards read yellow-bell-pepper / Family Fare as
  wrong-price at 08:13 (judged 2026-09-22, before the engine stamped the "when you buy 10" condition) and the 17c0da
  verifier fix re-judged it a match at 08:26, after the board had already been held on the stale verdict.
  Each case runs the real audit as a child with -OutDir at a per-run fixture tree (board, ledger, the store's own capture)
  and reads its exit code and its QUARANTINE lines, exactly as guards.ps1 does.
#>
# gate-inputs: grocery\audit-flag-verification.ps1 grocery\flag-verify-lib.ps1
[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
if (-not $SelfTest) { Write-Output 'test-flag-verification-rejudge: run with -SelfTest'; exit 3 }
$script:bad = 0; $script:n = 0
function Frc([string]$label, [bool]$ok, [string]$got) { $script:n++; if ($ok) { Write-Output ('ok    ' + $label) } else { Write-Output ('FAIL  ' + $label + ' :: ' + $got); $script:bad++ } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fvrj-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
$audit = Join-Path $PSScriptRoot 'audit-flag-verification.ps1'
$utf8 = New-Object Text.UTF8Encoding($false)

# The Family Fare cell as comparison-2026-09-26 carried it; $stamped adds the engine's deal condition (what 17c0da reads).
function Get-PepBoard([bool]$stamped) {
  $deal = ''; if ($stamped) { $deal = ',"deal_qty":10,"deal_condition":"when you buy 10"' }
  return ('{"week_of":"2026-09-26","comparison":[{"commodity":"Yellow Bell Pepper","id":"yellow-bell-pepper","unit":"each","stores":[' +
    '{"store":"Family Fare","per_unit":1,"unit":"each","type":"sale","item":"Yellow Bell Pepper","ad":"10 for $10.00 with purchase of 10","size":"1 ea","note":"10 for $10","ad_from":"2026-09-20","ad_to":"2026-09-26","as_of":""' + $deal + '},' +
    '{"store":"Baker''s","per_unit":1.67,"unit":"each","type":"everyday","item":"Fresh Yellow Bell Pepper","ad":"$1.67","size":"1 ct","as_of":"2026-09-24"}]}]}')
}
# The stored ledger entry: $status as judged on 2026-09-22 (the claim carries no deal condition, as it did then).
function Get-PepLedger([string]$status) {
  $reason = ''; if ($status -eq 'wrong-price') { $reason = 'no reading of the store''s own figures gives our 1.0000/each: size field 1 ea -> 1.9900' }
  return ('{"generated":"2026-09-25","entries":{"yellow-bell-pepper|Family Fare":{"key":"yellow-bell-pepper|Family Fare","id":"yellow-bell-pepper","commodity":"Yellow Bell Pepper","store":"Family Fare","unit":"each",' +
    '"claim":{"item":"Yellow Bell Pepper","per_unit":1,"ad":"10 for $10.00 with purchase of 10","size":"1 ea","row_type":"sale","ad_from":"2026-09-20","ad_to":"2026-09-26","as_of":"","deal_qty":null,"deal_condition":""},' +
    '"claim_key":"yellow bell pepper|10000","flag_types":["outlier"],"first_flagged":"2026-09-21","last_flagged":"2026-09-25","status":"' + $status + '","reason":"' + $reason.Replace('"', '\"') + '","verdict_at":"2026-09-22","answer":null,' +
    '"attempts":3,"last_attempt":"2026-09-25","alerted_at":"","closed_at":"","readings":[]}},"closed":[]}')
}
function Invoke-Fv([string]$name, [bool]$stamped, [string]$status, [bool]$withCapture, [string[]]$extra) {
  $o = Join-Path $tmp $name
  New-Item -ItemType Directory -Path (Join-Path $o 'regular') -Force -ErrorAction Stop | Out-Null
  [IO.File]::WriteAllText((Join-Path $o 'comparison-2026-09-26.json'), (Get-PepBoard $stamped), $utf8)
  [IO.File]::WriteAllText((Join-Path $o 'flag-verification.json'), (Get-PepLedger $status), $utf8)
  # The store's own later read of the product: its $1.99 single, read 2026-09-25 inside the ad window.
  if ($withCapture) { [IO.File]::WriteAllText((Join-Path $o 'regular\family-fare-regular-2026-09-25.json'), '{"store":"Family Fare","deals":[{"store":"Family Fare","item":"Yellow Bell Pepper","current_price":1.99,"size":"1 ea","as_of":"2026-09-25"}]}', $utf8) }
  $args2 = @('-OutDir', $o) + @($extra)
  $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $audit @args2)
  $ql = @($out | Where-Object { ([string]$_).StartsWith('QUARANTINE-CELL ', [StringComparison]::Ordinal) })
  return [pscustomobject]@{ rc = $LASTEXITCODE; out = $out; q = $ql; text = ($out -join ' / ') }
}
try {
  New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
  # MUST NOT FIRE, the founding case: the stored wrong-price, re-judged NOW against the engine's stamped condition, is a match.
  $r = Invoke-Fv 'founding' $true 'wrong-price' $true @('-Today', '2026-09-26')
  Frc 'MUST NOT FIRE  founding 2026-09-26: a stored wrong-price the current verifier re-judges a match (yellow-bell-pepper / Family Fare, "when you buy 10") names no cell and exits 0' (($r.rc -eq 0) -and ($r.q.Count -eq 0) -and ($r.text -match 'RE-JUDGED NOW: yellow-bell-pepper\|Family Fare -> match')) ('rc=' + $r.rc + ' ' + $r.text)
  # CLEAN TWIN: the same inputs read from the STORED verdict only (-NoRejudge, the old road) still hold the cell - so the
  # re-judge, and nothing else in the fixture, is what released it.
  $r = Invoke-Fv 'stored' $true 'wrong-price' $true @('-Today', '2026-09-26', '-NoRejudge')
  Frc 'CLEAN TWIN  -NoRejudge over the same inputs names yellow-bell-pepper|Family Fare|value from the stored verdict (exit 2)' (($r.rc -eq 2) -and ($r.q.Count -eq 1) -and ($r.q[0] -eq 'QUARANTINE-CELL yellow-bell-pepper|Family Fare|value')) ('rc=' + $r.rc + ' ' + $r.text)
  # MUST FIRE, the other direction: a stored PENDING (no verdict yet) that the current code condemns is named THIS run,
  # not one chain later. The board carries no deal condition, so $1.00 each against the store's $1.99 single is wrong-price.
  $r = Invoke-Fv 'pending' $false 'pending' $true @('-Today', '2026-09-26')
  Frc 'MUST FIRE  a stored pending the current verifier judges wrong-price is named now (QUARANTINE-CELL yellow-bell-pepper|Family Fare|value, exit 2)' (($r.rc -eq 2) -and ($r.q.Count -eq 1) -and ($r.q[0] -eq 'QUARANTINE-CELL yellow-bell-pepper|Family Fare|value') -and ($r.text -match 'RE-JUDGED NOW: yellow-bell-pepper\|Family Fare -> wrong-price')) ('rc=' + $r.rc + ' ' + $r.text)
  # MUST FIRE, fail closed on missing evidence: no capture to re-read is a could-not-look, which never downgrades a stored
  # disagreement, so the cell is still named.
  $r = Invoke-Fv 'nocapture' $true 'wrong-price' $false @('-Today', '2026-09-26')
  Frc 'MUST FIRE  with no store capture to re-read, a stored wrong-price stays named (could-not-look never downgrades it)' (($r.rc -eq 2) -and ($r.q.Count -eq 1)) ('rc=' + $r.rc + ' ' + $r.text)
  # MUST FIRE, fail closed when the re-judge cannot RUN: a bad -Today throws inside it, the audit says so and names the
  # stored disagreement rather than passing it.
  $r = Invoke-Fv 'cannotrun' $true 'wrong-price' $true @('-Today', 'not-a-date')
  Frc 'MUST FIRE  a re-judge that cannot run says RE-JUDGE COULD NOT RUN and names the stored wrong-price (exit 2)' (($r.rc -eq 2) -and ($r.q.Count -eq 1) -and ($r.text -match 'RE-JUDGE COULD NOT RUN')) ('rc=' + $r.rc + ' ' + $r.text)
} catch { Write-Output ('FAIL  a case threw: ' + $_.Exception.Message); $script:bad++ }
finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } }
$okAll = ($script:bad -eq 0 -and $script:n -eq 5)
Write-Output ('test-flag-verification-rejudge self-test ' + $(if ($okAll) { 'pass' } else { 'FAIL' }) + ': ' + ($script:n - $script:bad) + ' of ' + $script:n + ' case(s) passed (5 expected)')
exit $(if ($okAll) { 0 } else { 1 })
