<#
  board-drops.ps1 - THE ranking of "what actually got cheaper this week" on the Omaha board.

  Dot-source it, then call Get-BoardDrops. Returns a list ordered biggest-drop-first:
    @{ id; commodity; price; prior; pct; unit }

  WHY THIS IS A LIB: this logic was written for the masthead chip in build-deals-page.ps1 (the single
  "X down 23%" button). The Friday email needs the same ranking, ten deep. Copying it would have made
  two copies of the same math - the exact failure mode that put "$0.00/oz at Sam's Club" in a title
  attribute after the visible chip had already been fixed. One source, two callers, different -Top.

  EVERY GUARD BELOW IS LOAD-BEARING and each one exists because of a real wrong headline:

   * 4+ PRICED STORES. A headline drop on a one-store niche item ("Achiote Paste down 91%") is almost
     always a coverage change wearing a price change's clothes.
   * 30% OUTLIER GUARD vs the second-cheapest store. A cheapest price far below the rest of the field
     is usually a pack-basis error, not a sale.
   * 2+ PRIOR WEEKS of history, so a newly-tracked item cannot post a drop off a single reading.
   * 0% < drop <= 60%. A real grocery sale is 5-40%. Above 60% week over week is a data event, not a
     price event, and must never be headlined until a later week confirms it.

  The caller decides what is newsworthy: the board uses >= 10% for its chip, the email publishes what
  it gets and says so honestly when the list is short.
#>

function Get-BoardDrops {
  param(
    [Parameter(Mandatory=$true)]$Comparison,   # $doc.comparison (array of rows)
    [Parameter(Mandatory=$true)]$HistById,     # hashtable id -> @{ history = @(@{week_of;cheapest_price}) }
    [Parameter(Mandatory=$true)][string]$Week, # current week_of
    [int]$Top = 0,                             # 0 = all qualifying
    [int]$MinStores = 4,
    [double]$MaxOutlier = 0.30,
    [double]$MaxDrop = 0.60
  )

  # NO `return ,@()` ANYWHERE IN HERE. The comma idiom wraps the array in another array, and an EMPTY
  # result then arrives at the caller as @($null) - one element, every field blank. That shipped a
  # "  is down 0%, now 0/ at  " line into the first Friday email build. Return the array plainly and
  # let callers wrap with @(), which is correct for 0, 1 and n.
  $out = @()
  if (-not $HistById -or $HistById.Count -eq 0) { return $out }

  foreach ($r in $Comparison) {
    $h = $HistById[[string]$r.id]
    if (-not $h) { continue }

    $P = [double]$r.cheapest_price
    if ($P -le 0) { continue }

    # broadly priced only
    $rk = @($r.stores | Where-Object { [double]$_.per_unit -gt 0 } | Sort-Object per_unit)
    if (@($rk).Count -lt $MinStores) { continue }

    # outlier guard against the SECOND cheapest, not the mean: one bad pack basis moves a mean too little to catch
    $ru = [double]$rk[1].per_unit
    if ($ru -gt 0 -and (($ru - $P) / $ru) -gt $MaxOutlier) { continue }

    $prior = @($h.history | Where-Object { try { [datetime]$_.week_of -lt [datetime]$Week } catch { $false } })
    if (@($prior).Count -lt 2) { continue }

    $last = @($prior | Sort-Object week_of -Descending)[0]
    $lp = [double]$last.cheapest_price
    if ($lp -le 0) { continue }

    $pct = ($lp - $P) / $lp
    if ($pct -le 0 -or $pct -gt $MaxDrop) { continue }

    $out += [pscustomobject]@{
      id        = [string]$r.id
      commodity = [string]$r.commodity
      price     = $P
      prior     = $lp
      pct       = $pct
      store     = [string]$r.cheapest_store
      unit      = [string]$r.unit
    }
  }

  $out = @($out | Sort-Object pct -Descending)
  if ($Top -gt 0) { $out = @($out | Select-Object -First $Top) }
  return $out
}
