<#
  audit-ff-carry.ps1 - COMPLETENESS guard for the Family Fare Freshop pull. Catches the class where the pull
  silently drops a term (rate-limit -> HTTP 200 with 0 items) so a product FF actually carries shows "No price
  yet" on the board (the 2026-07-13 ground-pork bug). coverage-gaps CANNOT see this - it only scans the raw pull,
  and a dropped item was never pulled.

  How: read the latest family-fare-regular file's `empty_terms` (terms that returned nothing even after the pull's
  recovery passes), and re-probe each ONE more time against the Freshop API (token-less). If the API returns a real
  matching, priced product, FF genuinely carries it and the pull dropped it -> a confirmed victim. Small, targeted
  (only the still-empty terms), so it doesn't hammer the API.

  Advisory (does NOT hard-gate publish - a transient throttle should not take the board down; the pull's recovery
  passes are the primary defense). -Alert emails once per NEW victim-set.
#>
param([switch]$Alert, [string]$OutDir = "")
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$ff = Get-ChildItem (Join-Path $OutDir 'regular\family-fare-regular-*.json') -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if (-not $ff) { Write-Output 'ff-carry: SKIP (no FF regular file)'; exit 0 }
$doc = ConvertFrom-Json ([IO.File]::ReadAllText($ff.FullName))
$emptyTerms = @($doc.empty_terms)
if ($emptyTerms.Count -eq 0) { Write-Output 'ff-carry: OK  the FF pull left no empty terms'; exit 0 }

$tmp = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $root 'commodities.json'))); $commods = @($tmp)
$terms = (ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $root 'commodity-search.json')))).terms
# term-string -> commodity (to apply the right include/exclude)
$termToId = @{}; foreach ($p in $terms.PSObject.Properties) { $termToId[[string]$p.Value] = [string]$p.Name }
$byId = @{}; foreach ($c in $commods) { $byId[[string]$c.id] = $c }
function Match-Local($c, $name) {
  if (-not $c) { return $false }
  $n = $name.ToLower(); $hit = $false
  foreach ($inc in $c.include) { try { if ($n -match $inc) { $hit = $true; break } } catch {} }
  if (-not $hit) { return $false }
  foreach ($e in $c.exclude) { try { if ($n -match $e) { return $false } } catch {} }
  return $true
}
$ak = 'family_fare'; $sid = '6401'; $b = 'https://api.freshop.ncrcloud.com/1'; $UA = @{ 'User-Agent' = 'Mozilla/5.0' }
$victims = New-Object System.Collections.Generic.List[object]
foreach ($term in $emptyTerms) {
  $c = $byId[$termToId[[string]$term]]
  $items = @()
  try { $r = Invoke-RestMethod -Uri ("$b/products?app_key=$ak&store_id=$sid&q=" + [uri]::EscapeDataString([string]$term) + "&limit=15&fields=name,price,base_price") -Headers $UA -TimeoutSec 25; $items = @($r.items) } catch {}
  Start-Sleep -Milliseconds 400
  $good = @($items | Where-Object { $_.name -and (Match-Local $c ([string]$_.name)) -and ($_.base_price -or $_.price) })
  if ($good.Count) { $victims.Add([pscustomobject]@{ term = [string]$term; commodity = $termToId[[string]$term]; product = [string]$good[0].name }) }
}
# .ToArray(), NOT @($victims). In Windows PowerShell 5.1 the array-subexpression @( ) around a
# System.Collections.Generic.List[object] throws "ArgumentException: Argument types do not match" - it is fine
# around a List[string] and fine around the bare list, which is why this reads as harmless. It is not: this
# line threw on EVERY run since the script was wired into check-ad-cycles on 2026-07-13, after all 464 Freshop
# probes had already been made, and before the report, the OK line and the -Alert branch. check-ad-cycles pipes
# only stdout and a native child's crash is not a PowerShell exception, so its try/catch never fired and the
# failure printed nothing at all: 'ff-carry' appears 0 times in 2,716 lines of ad-cycle-log.txt. The FF
# pull-drop watch (the 2026-07-13 ground-pork class) was decorative for its entire life.
# ToArray() also keeps the JSON shape right at every size - [] at zero, [ {..} ] at one - where a bare list
# double-wraps and ConvertTo-Json would unwrap a single victim into an object.
$report = [ordered]@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); empty_terms = $emptyTerms.Count; confirmed_victims = $victims.ToArray() }
Set-Content (Join-Path $OutDir 'ff-carry-report.json') -Value ($report | ConvertTo-Json -Depth 4) -Encoding UTF8

if ($victims.Count -eq 0) { Write-Output ("ff-carry: OK  " + $emptyTerms.Count + " empty term(s) re-probed, none are actually carried by FF (genuinely not stocked)"); exit 0 }
Write-Output ("ff-carry: FOUND " + $victims.Count + " pull-drop victim(s) - FF carries these but the pull missed them:")
foreach ($v in $victims) { Write-Output ("  " + $v.commodity.PadRight(20) + " <- '" + $v.product + "'") }
if ($Alert) {
  $sig = (@($victims | ForEach-Object { $_.commodity } | Sort-Object) -join ';')
  $sigHash = [BitConverter]::ToString((New-Object Security.Cryptography.SHA256Managed).ComputeHash([Text.Encoding]::UTF8.GetBytes($sig))).Replace('-', '').Substring(0, 16)
  $sigF = Join-Path $OutDir 'ff-carry-alert.sig'
  $last = if (Test-Path $sigF) { (Get-Content $sigF -Raw).Trim() } else { '' }
  if ($sigHash -ne $last) {
    $body = "The Family Fare pull dropped item(s) FF actually carries (Freshop rate-limit survived the recovery passes). Board shows 'No price yet' for:`n" + (($victims | ForEach-Object { $_.commodity + ' <- ' + $_.product }) -join "`n") + "`nRe-run pull-regular-familyfare.ps1 (recovery should catch them) or investigate persistent throttling."
    try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject "Grocery: Family Fare pull dropped a carried item - review" -Body $body | Out-Null; Set-Content $sigF -Value $sigHash -Encoding UTF8 } catch {}
  }
}
exit 0
