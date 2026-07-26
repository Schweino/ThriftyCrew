<#
  test-scale-hardening.ps1 - tests for the 2026-07-26 mass-import hardening (a guard/helper with no test
  can silently break and give false confidence). Covers: Set-RecipeVisibility (lib\json-db-io),
  Invoke-GhostApi (lib\ghost-lib), audit-db-agreement CHEAPEST-FALLBACK guard, audit-store-registry.
  Fixture-based where possible; the two guard negative-tests mutate a real file inside try/finally and
  ALWAYS restore. Exit 0 = all pass, 1 = a failure.
#>
$ErrorActionPreference = 'Stop'
$mp   = $PSScriptRoot
$root = Split-Path $mp -Parent
$pass = 0; $fail = 0
function Ok($name, $cond) { if ($cond) { Write-Output ("  PASS  " + $name); $script:pass++ } else { Write-Output ("  FAIL  " + $name); $script:fail++ } }

. (Join-Path $mp 'lib\json-db-io.ps1')
. (Join-Path $root 'lib\ghost-lib.ps1')

# ---- 1. Set-RecipeVisibility (key-scoped recipes-db patch) ----
Write-Output 'Set-RecipeVisibility:'
$fx = Join-Path $env:TEMP ('rdb-fixture-' + [guid]::NewGuid().ToString('N') + '.json')
try {
  $fixture = @{ readme='test'; recipes=@(
    @{ slug='alpha'; name='Alpha'; protein='beef'; visibility='paid' },
    @{ slug='beta';  name='Beta';  protein='pork'; visibility='paid' },
    @{ slug='gamma'; name='Gamma'; protein='chicken'; visibility='public' }
  ) } | ConvertTo-Json -Depth 6
  [IO.File]::WriteAllText($fx, $fixture)
  $n = Set-RecipeVisibility -DbPath $fx -Map @{ alpha='public'; gamma='paid' }
  $after = Get-Content $fx -Raw | ConvertFrom-Json
  $va = ($after.recipes | Where-Object slug -eq 'alpha').visibility
  $vb = ($after.recipes | Where-Object slug -eq 'beta').visibility
  $vg = ($after.recipes | Where-Object slug -eq 'gamma').visibility
  Ok 'returns changed count 2' ($n -eq 2)
  Ok 'alpha paid->public' ($va -eq 'public')
  Ok 'gamma public->paid' ($vg -eq 'paid')
  Ok 'beta untouched (paid)' ($vb -eq 'paid')
  Ok 'row count preserved' (@($after.recipes).Count -eq 3)
  # unknown slug is skipped, not fatal
  $n2 = Set-RecipeVisibility -DbPath $fx -Map @{ doesnotexist='public' }
  Ok 'unknown slug skipped (0 changed)' ($n2 -eq 0)
  # bad visibility value throws
  $threw = $false; try { Set-RecipeVisibility -DbPath $fx -Map @{ alpha='invalid' } | Out-Null } catch { $threw = $true }
  Ok 'bad visibility value throws' $threw
  # a same-value no-op changes nothing
  $n3 = Set-RecipeVisibility -DbPath $fx -Map @{ alpha='public' }
  Ok 'same-value no-op (0 changed)' ($n3 -eq 0)
} finally { Remove-Item $fx -ErrorAction SilentlyContinue }

# ---- 2. Invoke-GhostApi (timeout/retry wrapper) ----
Write-Output 'Invoke-GhostApi:'
Ok 'function defined' ([bool](Get-Command Invoke-GhostApi -ErrorAction SilentlyContinue))
$r200 = $null; try { $r200 = Invoke-GhostApi -Uri 'https://map-to-success.ghost.io/ghost/api/admin/site/' -Web -BasicParsing -TimeoutSec 15 } catch {}
Ok '200 on a good GET' ($r200 -and $r200.StatusCode -eq 200)
# a 404 must NOT be retried (fast) - 3 retries of a real backoff would take >6s; assert it fails in <5s
$t = [Diagnostics.Stopwatch]::StartNew(); $code = 0
try { Invoke-GhostApi -Uri 'https://www.thriftycrew.com/definitely-not-real-xyz-9182/' -Web -BasicParsing -TimeoutSec 15 } catch { try { $code = [int]$_.Exception.Response.StatusCode } catch {} }
$t.Stop()
Ok '404 rethrown fast (<5s, not retried)' ($t.Elapsed.TotalSeconds -lt 5)
Ok '404 status surfaced to caller' ($code -eq 404)

# ---- 3. audit-db-agreement: regression (clean on real data) + CHEAPEST-FALLBACK negative ----
Write-Output 'audit-db-agreement (CHEAPEST-FALLBACK guard):'
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $mp 'engine\audit-db-agreement.ps1') | Out-Null
Ok 'clean on live data (exit 0)' ($LASTEXITCODE -eq 0)
# negative: temporarily REMOVE an allowlisted exotic bid so its recipe lines become an unguarded fallback
$npF = Join-Path $mp 'db\no-board-price-ok.json'
$npBak = Get-Content $npF -Raw
try {
  $np = $npBak | ConvertFrom-Json
  $np.bids = @($np.bids | Where-Object { $_ -ne 'doubanjiang' })   # taiwanese-braised-beef uses it, off-feed
  ($np | ConvertTo-Json -Depth 5) | Set-Content $npF -Encoding UTF8
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $mp 'engine\audit-db-agreement.ps1') | Out-Null
  Ok 'flags an unallowlisted off-feed bid (exit 1)' ($LASTEXITCODE -eq 1)
} finally { [IO.File]::WriteAllText($npF, $npBak) }
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $mp 'engine\audit-db-agreement.ps1') | Out-Null
Ok 'clean again after restore (exit 0)' ($LASTEXITCODE -eq 0)

# ---- 4. audit-store-registry: regression + drift negative ----
Write-Output 'audit-store-registry:'
$sr = Join-Path $root 'grocery\audit-store-registry.ps1'
& powershell -NoProfile -ExecutionPolicy Bypass -File $sr | Out-Null
Ok 'clean on live estate (exit 0)' ($LASTEXITCODE -eq 0)
# negative: add a fake store to stores.json - it has ZERO board cells, so the guard must flag it
$stF = Join-Path $root 'grocery\stores.json'
$stBak = Get-Content $stF -Raw
try {
  $st = $stBak | ConvertFrom-Json
  $st.stores += [pscustomobject]@{ name='Phantom Mart'; order=99; regular_prefix='phantom'; urlkey='phantom'; ad_cycle='none'; capture='none'; price_mode='in-store'; notes='test fixture' }
  ($st | ConvertTo-Json -Depth 6) | Set-Content $stF -Encoding UTF8
  & powershell -NoProfile -ExecutionPolicy Bypass -File $sr | Out-Null
  Ok 'flags a registered store with no board cells (exit 2)' ($LASTEXITCODE -eq 2)
} finally { [IO.File]::WriteAllText($stF, $stBak) }
& powershell -NoProfile -ExecutionPolicy Bypass -File $sr | Out-Null
Ok 'clean again after restore (exit 0)' ($LASTEXITCODE -eq 0)

# ---- 5. health-heartbeat: healthy live + silent-death negative ----
Write-Output 'health-heartbeat (silent-death detector):'
$hb = Join-Path $root 'grocery\health-heartbeat.ps1'
& powershell -NoProfile -ExecutionPolicy Bypass -File $hb | Out-Null
Ok 'healthy on live estate (exit 0)' ($LASTEXITCODE -eq 0)
$cfgF = Join-Path $root 'grocery\expected-automations.json'
$cfgBak = Get-Content $cfgF -Raw
try {
  $c = $cfgBak | ConvertFrom-Json
  $c.windows_tasks += [pscustomobject]@{ name='SMP Phantom Nonexistent Task'; max_age_hours=30; why='test fixture' }
  ($c | ConvertTo-Json -Depth 6) | Set-Content $cfgF -Encoding UTF8
  & powershell -NoProfile -ExecutionPolicy Bypass -File $hb | Out-Null
  Ok 'flags a deleted/missing task (exit 2)' ($LASTEXITCODE -eq 2)
} finally { [IO.File]::WriteAllText($cfgF, $cfgBak) }
& powershell -NoProfile -ExecutionPolicy Bypass -File $hb | Out-Null
Ok 'healthy again after restore (exit 0)' ($LASTEXITCODE -eq 0)

Write-Output ("`n{0} passed, {1} failed" -f $pass, $fail)
if ($fail) { exit 1 } else { exit 0 }
