<#
  test-guards.ps1 - negative tests. A guard that cannot fail is worthless, so break each invariant on
  purpose, assert guards.ps1 exits 2, then restore and assert it exits 0 again.
  Every mutation is made on a COPY-then-restore basis; nothing is left changed.
#>
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$pass = 0; $failed = 0

function RunGuards {
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'guards.ps1') -Quiet | Out-Null
  return $LASTEXITCODE
}
function Check($name, $expect) {
  $rc = RunGuards
  if ($rc -eq $expect) { Write-Output ("  PASS  {0}  (exit {1})" -f $name, $rc); $script:pass++ }
  else { Write-Output ("  FAIL  {0}  expected exit {1}, got {2}" -f $name, $expect, $rc); $script:failed++ }
}

# baseline
Check 'baseline: guards pass on the current board' 0

# ---- 1. price-mode -----------------------------------------------------------------
$f = (Get-ChildItem (Join-Path $root 'out\regular\aldi-regular-*.json') | Sort-Object Name -Desc | Select-Object -First 1).FullName
$bak = Get-Content $f -Raw
$d = $bak | ConvertFrom-Json; $d.price_mode = 'delivery'
($d | ConvertTo-Json -Depth 6) | Set-Content $f -Encoding UTF8
Check 'price-mode: Aldi flipped to the marked-up DELIVERY catalogue' 2
Set-Content $f $bak -Encoding UTF8 -NoNewline

# ---- 2. household-in-food ----------------------------------------------------------
# INJECT the offending row rather than relying on one existing in a store file: the Family Fare file is
# regenerated daily, so the original "Lysol Mango & Hibiscus" row vanished and this test silently
# stopped testing anything (it passed by finding nothing). A negative test must create its own fixture.
$cf = Join-Path $root 'commodities.json'
$cbak = Get-Content $cf -Raw
$c = $cbak | ConvertFrom-Json
$m = $c | Where-Object { $_.id -eq 'mangoes' }
$m.exclude = @($m.exclude | Where-Object { $_ -ne 'cleaner' -and $_ -ne '\blysol\b' })
($c | ConvertTo-Json -Depth 6) | Set-Content $cf -Encoding UTF8

$wf = (Get-ChildItem (Join-Path $root 'out\regular\walmart-regular-*.json') | Sort-Object Name -Desc | Select-Object -First 1).FullName
$wbak = Get-Content $wf -Raw
$w = $wbak | ConvertFrom-Json
$rows = New-Object System.Collections.ArrayList
foreach ($r in $w.deals) { [void]$rows.Add($r) }
[void]$rows.Add([ordered]@{ store='Walmart'; item='Lysol Mango & Hibiscus Bathroom Cleaner 32 fl oz'; ad_price='$3.39'; size='32 fl oz'; regular=$null; source_ad='NEGATIVE TEST FIXTURE' })
$w.deals = $rows.ToArray()
($w | ConvertTo-Json -Depth 6) | Set-Content $wf -Encoding UTF8

Check 'household-in-food: a Lysol MANGO cleaner priced as fruit' 2

Set-Content $wf $wbak -Encoding UTF8 -NoNewline
Set-Content $cf $cbak -Encoding UTF8 -NoNewline

# ---- 3. rogue pin ------------------------------------------------------------------
$of = Join-Path $root 'board-price-overrides.json'
$obak = Get-Content $of -Raw
$o = $obak | ConvertFrom-Json
$cells = New-Object System.Collections.ArrayList
foreach ($x in $o.cells) { [void]$cells.Add($x) }
[void]$cells.Add([ordered]@{ id='eggs'; store='Walmart'; per_unit=99.0; source='NEGATIVE TEST'; set='test' })
$o.cells = $cells.ToArray()
($o | ConvertTo-Json -Depth 6) | Set-Content $of -Encoding UTF8
Check 'rogue pin: a pin that overrides the engine ($99/dozen eggs)' 2
Set-Content $of $obak -Encoding UTF8 -NoNewline

# ---- 4. factor mismatch ------------------------------------------------------------
$pf = Join-Path $root 'product-urls.json'
$pbak = Get-Content $pf -Raw
$p = $pbak | ConvertFrom-Json
# halve a link's recorded size -> its per-unit doubles vs the board = the 2x pack bug
$target = $p.items.'white-vinegar'.'Sam''s Club'
if ($target) { $target.size = '1 gal' }   # the truth is "2 pk 1 gal"
($p | ConvertTo-Json -Depth 8) | Set-Content $pf -Encoding UTF8
Check 'factor mismatch: Sam''s 2-pack vinegar recorded as ONE gallon (2x)' 2
Set-Content $pf $pbak -Encoding UTF8 -NoNewline

# ---- 5. multipack size -------------------------------------------------------------
$sf = (Get-ChildItem (Join-Path $root 'out\regular\sams-regular-*.json') | Sort-Object Name -Desc | Select-Object -First 1).FullName
$sbak = Get-Content $sf -Raw
$s = $sbak | ConvertFrom-Json
foreach ($r in $s.deals) { if ($r.item -match 'ReaLemon') { $r.size = '48 fl oz' } }   # truth: "2 pk 48 fl oz"
($s | ConvertTo-Json -Depth 6) | Set-Content $sf -Encoding UTF8
Check 'multipack size: Sam''s 2-pack ReaLemon recorded as ONE bottle' 2
Set-Content $sf $sbak -Encoding UTF8 -NoNewline

# ---- 6. stray file in out\regular --------------------------------------------------
# The one that actually bit us: a throttled 0-row diagnostic named "family-fare-regular-<date>.PARTIAL.json"
# both matched the store glob AND sorted after the real file ('p' > 'j'), so every consumer read the empty
# file as Family Fare's catalogue. Family Fare fell to ZERO everyday cells and the pull still logged success.
$strayF = Join-Path $root 'out\regular\family-fare-regular-2026-07-14.PARTIAL.json'
'{"store":"Family Fare","week_of":"2026-07-14","price_type":"everyday","deal_count":0,"deals":[]}' |
  Set-Content $strayF -Encoding UTF8
Check 'stray file: an empty .PARTIAL that outsorts the real Family Fare data' 2
Remove-Item $strayF -Force

# ---- restored? ---------------------------------------------------------------------
Check 'restored: guards pass again after every mutation is reverted' 0

Write-Output ''
Write-Output ("negative tests: $pass passed, $failed failed")
if ($failed -gt 0) { exit 1 }
exit 0
