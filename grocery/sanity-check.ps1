<#
  sanity-check.ps1 - Live statistical guard on the weekly board (runs on real, changing data - complements the
  frozen regression test). Flags, per commodity, a winner that is either:
    * an OUTLIER: more than 35% below the next-cheapest entry (a classic in-band parse error - the price bands
      only catch order-of-magnitude junk, so a silent halving like the grapes bug sails through them but shows
      up as an outlier vs the peer set), or
    * a big WEEK-OVER-WEEK move: cheapest changed > 40% vs last week's price-history (dormant until >=2 weeks).
  Also cross-checks any entry that carries a store-published native_unit_price (>3% disagreement -> flag).
  Flags are ROUTED TO REVIEW (never auto-deleted) -> guards-<date>.json + console. Exit 1 if anything flags.
#>
param([string]$CompareFile = "", [string]$OutDir = "", [double]$OutlierFrac = 0.35, [double]$WowFrac = 0.40)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
if (-not $CompareFile) { $CompareFile = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName }
$doc = Get-Content $CompareFile -Raw | ConvertFrom-Json
$week = [string]$doc.week_of

# price history for WoW (prior week's cheapest per commodity)
$prior = @{}
$histFile = Join-Path $root 'price-history.json'
if (Test-Path $histFile) {
  $h = Get-Content $histFile -Raw | ConvertFrom-Json
  foreach ($c in $h.commodities) {
    $past = @($c.history | Where-Object { $_.week_of -ne $week } | Sort-Object week_of)
    if ($past.Count -gt 0) { $prior[[string]$c.id] = [double]$past[$past.Count-1].cheapest_price }
  }
}

$flags = New-Object System.Collections.Generic.List[object]
foreach ($r in $doc.comparison) {
  $ranked = @($r.stores | Sort-Object per_unit)
  # outlier vs runner-up
  if ($ranked.Count -ge 2) {
    $c0 = [double]$ranked[0].per_unit; $c1 = [double]$ranked[1].per_unit
    if ($c1 -gt 0 -and $c0 -lt ((1 - $OutlierFrac) * $c1)) {
      $pct = [math]::Round((1 - $c0/$c1) * 100)
      $flags.Add([ordered]@{ commodity=$r.commodity; type='outlier'; detail=("$($ranked[0].store) `$$('{0:N2}' -f $c0) is $pct% below runner-up $($ranked[1].store) `$$('{0:N2}' -f $c1) - verify the price/size parse") })
    }
  }
  # week-over-week
  if ($prior.ContainsKey([string]$r.id)) {
    $p = $prior[[string]$r.id]; $cur = [double]$r.cheapest_price
    if ($p -gt 0 -and ([math]::Abs($cur - $p)/$p -gt $WowFrac)) {
      $dir = if ($cur -lt $p) { 'down' } else { 'up' }
      $flags.Add([ordered]@{ commodity=$r.commodity; type='wow'; detail=("cheapest moved $dir " + [math]::Round([math]::Abs($cur-$p)/$p*100) + "% vs last week (`$$('{0:N2}' -f $p) -> `$$('{0:N2}' -f $cur))") })
    }
  }
  # native unit-price cross-check (activates when a pull captures the store's own per-unit number)
  foreach ($s in $r.stores) {
    if ($s.PSObject.Properties['native_unit_price'] -and $s.native_unit_price) {
      $nu = [double]$s.native_unit_price; $ou = [double]$s.per_unit
      if ($nu -gt 0 -and ([math]::Abs($ou-$nu)/$nu -gt 0.03)) {
        $flags.Add([ordered]@{ commodity=$r.commodity; type='native-mismatch'; detail=("$($s.store): our `$$('{0:N2}' -f $ou) vs store-published `$$('{0:N2}' -f $nu)") })
      }
    }
  }
}

# -InputObject (not pipeline): an EMPTY array piped to ConvertTo-Json yields $null and Set-Content then
# writes NOTHING - so a clean day never cleared a previous day's flags and the daily job re-reported the
# stale guards file forever. -InputObject always emits at least "[]".
(ConvertTo-Json -InputObject $flags.ToArray() -Depth 5) | Set-Content (Join-Path $OutDir ("guards-"+$week+".json")) -Encoding UTF8
if ($flags.Count -eq 0) {
  Write-Output ("SANITY OK  -  week ${week}: no outliers, no big week-over-week moves.")
  Write-GuardComplete -Name 'sanity-check'; exit 0
} else {
  Write-Output ("SANITY: " + $flags.Count + " item(s) to review before publishing (week $week):")
  foreach ($f in $flags.ToArray()) { Write-Output ("  [" + $f.type + "] " + $f.commodity + " - " + $f.detail) }
  Write-GuardComplete -Name 'sanity-check'; exit 1
}
