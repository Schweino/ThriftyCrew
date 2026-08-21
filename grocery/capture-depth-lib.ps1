<#
  capture-depth-lib.ps1 - WHICH CAPTURE IS ALLOWED TO PRICE A COMMODITY AT A STORE.

  ONE implementation, two callers. compare-deals ENFORCES this rule when it ranks rows;
  audit-capture-eviction AUDITS the published board against it. Until 2026-08-21 the audit carried a
  hand-restated copy with a comment asking whoever changed one to change the other, plus a
  test-auditors check that grepped both files for the same literal. That is the shape `two copies of a
  rule` describes: the copies agreed only for as long as someone remembered them, and the failure mode
  is silent - the audit goes on measuring a rule the engine no longer runs and keeps reading green.
  The lockstep guard could see the literal change; it could not see a change in MEANING.

  THE RULE, and the two live bugs that shaped it:

  1. THE ONIONS BUG (2026-07-30) - the newest capture wins.
     A 16-day-old 60-row hand-promotion was pricing Sam's onions at a stale-LOW $0.737/lb while Sam's
     own 07-29 feed said $0.8267 and Aldi was actually cheapest at $0.7967. Cheapest-per-store let the
     stale copy beat the live price. So: the freshest capture that covers a commodity wins it.

  2. THE FORMULA BUG (2026-08-06) - "covers" cannot mean ONE ROW.
     Sam's and Walmart captures are partial term-based pulls. A capture that swept one premium product
     beat a capture that swept twenty:
        sams-deals-2026-08-05.json  1,808 deals, exactly 1 baby-formula row: Bubs Goat Milk $1.4445/oz
        sams-deals-2026-07-29.json  2,475 deals, 20+ rows incl Member's Mark  $0.7704/oz
     58 cells estate-wide, worst 18.17x, every existing guard green. So an older in-window capture stays
     eligible when it knows AT LEAST AS MUCH about this commodity as the newest one does.
     The fix is deliberately NOT "prefer the cheapest", which would bring the onions bug straight back.

  3. DEPTH IS DISTINCT PRODUCTS, NOT ROWS (2026-08-21) - the reason this became a lib.
     Rule 2 was measured when one captured product produced exactly one candidate row. The everyday/sale
     split shipped earlier that day broke the identity: a product carrying a was-price now emits TWO
     candidates, its everyday half and its sale half. A capture holding ONE product could then present
     as depth 2 and out-rank today's capture on coverage it did not have. It took a live cell the same
     day - Walmart cherries, item id 46491694, one product in the 2026-07-14 capture counted as two:
         published  $2.50/lb sale     from a capture 38 days old
         charged    $6.97/lb everyday from the 2026-08-11 capture it displaced
     and $2.50 sat one cent off Aldi's crown, so the next price move would have handed the
     cheapest-in-Omaha verdict to a price Walmart stopped charging in July. That is the onions bug
     arriving through the exception added to fix the formula bug: same cell, same direction, stale and
     low beating live.
     Counting distinct names restores rule 2's original meaning exactly - where no capture holds a
     duplicate name the count is unchanged - so it can only ever affect captures the split inflated.

  WHAT IS NEVER FILTERED: a row with no src_date. That is a store whose out\regular file is its only
  everyday source; it carries no capture date to compare and must stay eligible beside the newest
  capture. Only Walmart and Sam's rows are dated (Get-RegularSrcDate says why).

  Staleness is bounded ELSEWHERE, by -SamsMaxAgeDays / -WalmartMaxAgeDays on the file set. This
  function is a second filter on top of that window and has no business discarding better information.
#>

function Get-CaptureDepth {
  <#
    .SYNOPSIS How much a capture knows about ONE commodity at ONE store, in distinct products.
    .DESCRIPTION Two rows in a single capture sharing a product name are the two halves of one shelf
                 price - an everyday half and a sale half emitted by the price split - never two
                 products. Counting rows here is what let a one-product capture out-rank a live one.
  #>
  param([object[]]$Rows)
  if (-not $Rows -or -not $Rows.Count) { return 0 }
  return @($Rows | ForEach-Object { [string]$_.name } | Select-Object -Unique).Count
}

function Select-FreshestCaptureRows {
  <#
    .SYNOPSIS The rows eligible to price one commodity at one store.
    .DESCRIPTION Undated rows always survive. Among dated rows the newest capture is always eligible,
                 and an older one joins it only when it holds MORE distinct products for this commodity
                 than the newest does. Ties go to the newer capture.
  #>
  param([object[]]$Rows)
  $rows = @($Rows)
  $dated = @($rows | Where-Object { $_.src_date })
  if (-not $dated.Count) { return @($rows) }
  $newest = @($dated | ForEach-Object { [string]$_.src_date } | Sort-Object -Descending)[0]
  $newestCount = Get-CaptureDepth @($dated | Where-Object { [string]$_.src_date -eq $newest })
  $keepDates = @($newest)
  foreach ($g in ($dated | Group-Object src_date)) {
    if ([string]$g.Name -eq $newest) { continue }
    if ((Get-CaptureDepth @($g.Group)) -gt $newestCount) { $keepDates += [string]$g.Name }
  }
  return @($rows | Where-Object { -not $_.src_date -or $keepDates -contains [string]$_.src_date })
}
