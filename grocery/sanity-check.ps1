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

# THE STORE'S OWN ARITHMETIC, AND HOW CLOSE COUNTS AS AGREEING (2026-09-04, queue 2026-09-04-def37c).
# A store publishes its unit price rounded to the cent, so "$0.05/oz" is anything in [0.045, 0.055) and our
# 0.0499 reproduces it exactly. A pure percentage tolerance cannot express that: at Sam's saltines, ours
# reads 0.155 against a published "$0.15/oz" - 3.33% apart, one rounding step, and a 3% test calls that a
# disagreement. So the tolerance is the WIDER of half a cent and 3%, and it is INCLUSIVE: 0.005 <= 0.00501.
# The 0.00001 slack is against binary floating point, not against the data - 0.155-0.15 does not evaluate
# to exactly 0.005 in a double. Measured over 906 Sam's/Walmart cells: 687 agree, 0 disagree, and the ONE
# boundary case in the whole board is those saltines.
function Test-NativeAgrees([double]$Ours, [double]$Native) {
  if ($Native -le 0) { return $false }
  return ([math]::Abs($Ours - $Native) -le ([math]::Max(0.00501, 0.03 * $Native)))
}
# COMPARABLE = the store priced in the same unit the commodity is priced in. compare-deals only emits
# native_unit when the families already match, but this must hold on a board built by any producer: an
# each-vs-oz pair is a DIFFERENT QUESTION, not a disagreement, and reporting it as one is how a cross-check
# earns a reputation for crying wolf (5 of today's 38 verifiable outliers are exactly that shape).
function Test-NativeComparable($StoreRow, [string]$CommodityUnit) {
  if (-not $StoreRow) { return $false }
  if (-not $StoreRow.PSObject.Properties['native_unit_price'] -or -not $StoreRow.native_unit_price) { return $false }
  if (-not $StoreRow.PSObject.Properties['native_unit']) { return $false }
  $nu = ([string]$StoreRow.native_unit).Trim().ToLower()
  if (-not $nu) { return $false }
  return ($nu -eq ([string]$CommodityUnit).Trim().ToLower())
}

$flags = New-Object System.Collections.Generic.List[object]
$notComparable = 0
foreach ($r in $doc.comparison) {
  $ranked = @($r.stores | Sort-Object per_unit)
  $cUnit = [string]$r.unit
  # outlier vs runner-up
  if ($ranked.Count -ge 2) {
    $c0 = [double]$ranked[0].per_unit; $c1 = [double]$ranked[1].per_unit
    if ($c1 -gt 0 -and $c0 -lt ((1 - $OutlierFrac) * $c1)) {
      $pct = [math]::Round((1 - $c0/$c1) * 100)
      # OUTLIER-VERIFIED: the cheapest row is 35%+ under its runner-up AND the store itself publishes a
      # per-unit price that reproduces ours. That is a warehouse pack being genuinely cheap, not a parse
      # error, and it is the one shape a hand-written ack used to have to carry - with an expiry, so the
      # same reviewed-real cell re-paged every time the ack lapsed (this key: paged 07-29, acked to 08-13,
      # paged again 09-04). NOTHING IS DELETED: the flag still goes into guards-<week>.json, it just
      # carries a type the pager knows is quiet. Absence of a native price is NOT agreement - a row with
      # no published unit price stays an ordinary outlier and keeps paging.
      $v0 = $ranked[0]
      if ((Test-NativeComparable $v0 $cUnit) -and (Test-NativeAgrees $c0 ([double]$v0.native_unit_price))) {
        $nv = [double]$v0.native_unit_price
        $flags.Add([ordered]@{ commodity=$r.commodity; type='outlier-verified'; detail=("$($v0.store) `$$('{0:N4}' -f $c0)/$cUnit is $pct% below runner-up $($ranked[1].store) `$$('{0:N4}' -f $c1)/$cUnit, and the store publishes `$$('{0:N4}' -f $nv)/$cUnit - our arithmetic agrees with the store's own, so the price is real (product identity is NOT judged here)") })
      } else {
        $flags.Add([ordered]@{ commodity=$r.commodity; type='outlier'; detail=("$($ranked[0].store) `$$('{0:N2}' -f $c0) is $pct% below runner-up $($ranked[1].store) `$$('{0:N2}' -f $c1) - verify the price/size parse") })
      }
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
      # NOT COMPARABLE IS NOT A MISMATCH. Counted and reported on the console line rather than flagged, so
      # the number is visible without a reader having to disprove a wolf. (Before 2026-09-04 this check
      # compared the magnitudes with no unit test at all - and it had never once run, because no producer
      # populated native_unit_price. See the class memo: unit label vs unit magnitude.)
      if (-not (Test-NativeComparable $s $cUnit)) { $script:notComparable++; continue }
      $nu = [double]$s.native_unit_price; $ou = [double]$s.per_unit
      if (-not (Test-NativeAgrees $ou $nu)) {
        $flags.Add([ordered]@{ commodity=$r.commodity; type='native-mismatch'; detail=("$($s.store): our `$$('{0:N4}' -f $ou)/$cUnit vs store-published `$$('{0:N4}' -f $nu)/$cUnit on '$($s.item)' - one of the two is reading a different pack") })
      }
    }
  }
}

# -InputObject (not pipeline): an EMPTY array piped to ConvertTo-Json yields $null and Set-Content then
# writes NOTHING - so a clean day never cleared a previous day's flags and the daily job re-reported the
# stale guards file forever. -InputObject always emits at least "[]".
(ConvertTo-Json -InputObject $flags.ToArray() -Depth 5) | Set-Content (Join-Path $OutDir ("guards-"+$week+".json")) -Encoding UTF8
# SAY WHAT THE CROSS-CHECK COULD AND COULD NOT JUDGE. A silent check and a check with nothing to check
# read identically, and this one was dormant for its entire life because no producer ever populated the
# field it reads. The count is printed on every run, including a clean one.
$nVerified = @($flags.ToArray() | Where-Object { $_.type -eq 'outlier-verified' }).Count
Write-Output ("sanity: store-published unit price - $nVerified outlier(s) verified against the store's own arithmetic, $script:notComparable row(s) priced in a unit that is not comparable with their commodity's (reported, not flagged)")
if ($flags.Count -eq 0) {
  Write-Output ("SANITY OK  -  week ${week}: no outliers, no big week-over-week moves.")
  Write-GuardComplete -Name 'sanity-check'; exit 0
} else {
  Write-Output ("SANITY: " + $flags.Count + " item(s) to review before publishing (week $week):")
  foreach ($f in $flags.ToArray()) { Write-Output ("  [" + $f.type + "] " + $f.commodity + " - " + $f.detail) }
  Write-GuardComplete -Name 'sanity-check'; exit 1
}
