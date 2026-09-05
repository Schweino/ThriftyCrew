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

  4. THE SAME PRODUCT, TWICE, AT TWO PRICES (2026-09-05) - the newer row of a product supersedes its own
     older row. The union is name-keyed, so a product captured on 08-15 and again on 08-27 presents as two
     independent candidates and the ranker takes the cheaper - which is the older one whenever the price
     went up. Measured on comparison-2026-09-02: 18 cells (7 crowns) were priced from an older capture at
     a price the SAME product's newer capture contradicted, e.g. Sam's bar soap at $0.4988 (08-15) against
     the same Caress bar's $0.6862 on 08-27.
     ORDER MATTERS, and getting it wrong resurrects bug 2. Superseding BEFORE the depth count thins the
     older capture, which is precisely how a thinner newer capture gets to evict a deeper older one -
     measured the day this shipped, that ordering moved 10 further cells nobody had measured (Walmart
     clam-chowder 0.132 -> 0.2445, facial-tissues 0.0069 -> 0.0103, marshmallows 0.0731 -> 0.105 and
     seven more), every one of them a whole-capture eviction rather than a stale twin. So the depth rule
     runs FIRST, on the untouched row set, and supersession then runs over the rows it kept. A row is
     therefore only ever dropped when the SAME product's newer row is itself eligible to price the cell:
     the information is refreshed, never lost, and no cell can lose its store.

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

# ONE implementation of 'these two rows are the same product', because there are now TWO callers of it:
# Remove-SupersededRows (drop the older row) and Update-PriceFromNewerSighting (keep the row, take the
# newer PRICE). A second hand-copy of transitive id-or-name grouping is precisely the class this estate
# keeps paying for - see the markdown stamp that lived as two pastes in the two builders until 2026-09-05.
# Returns @{ labelOf = <dated-row index -> group label>; dated = <the dated rows, in order> }.
function Get-ProductLabels {
  param([object[]]$Dated)
  $dated = @($Dated)
  $names = @($dated | ForEach-Object { [string]$_.name } | Select-Object -Unique)
  $canon = @{}
  foreach ($n in $names) { $canon[$n] = $n }
  foreach ($n in $names) {
    if ($n.Length -ne 60) { continue }
    $ext = @($names | Where-Object { $_.Length -gt 60 -and $_.StartsWith($n, [StringComparison]::Ordinal) })
    if ($ext.Count -eq 1) { $canon[$n] = [string]$ext[0] }
  }
  $labelOf = @{}; $keyLabel = @{}; $next = 0
  for ($i = 0; $i -lt $dated.Count; $i++) {
    $r = $dated[$i]
    $keys = @('nm:' + [string]$canon[[string]$r.name])
    $pk = ('' + $r.prod_key).Trim()
    if ($pk) { $keys += ('id:' + $pk) }
    $found = @()
    foreach ($k in $keys) { if ($keyLabel.ContainsKey($k)) { $found += $keyLabel[$k] } }
    $found = @($found | Select-Object -Unique)
    if (-not $found.Count) { $lab = $next; $next++ }
    else {
      $lab = $found[0]
      foreach ($old in @($found | Where-Object { $_ -ne $lab })) {
        foreach ($kk in @($keyLabel.Keys)) { if ($keyLabel[$kk] -eq $old) { $keyLabel[$kk] = $lab } }
        foreach ($ri in @($labelOf.Keys)) { if ($labelOf[$ri] -eq $old) { $labelOf[$ri] = $lab } }
      }
    }
    foreach ($k in $keys) { $keyLabel[$k] = $lab }
    $labelOf[$i] = $lab
  }
  return @{ labelOf = $labelOf; dated = $dated }
}

function Remove-SupersededRows {
  <#
    .SYNOPSIS Drop a dated row when the SAME product has a newer dated row in the same set.
    .DESCRIPTION Undated rows are never touched (they carry no capture date to compare).

    TWO ROWS ARE THE SAME PRODUCT IF EITHER SIGNAL SAYS SO, NOT IF THE PREFERRED ONE DOES.
    The first cut of this preferred prod_key and fell back to the name, and it silently did nothing for
    the case it was written for: Walmart's July batch rows carry NO item_id while their full-name twins in
    a newer capture DO, so 'id:54258473' and 'nm:Great Value Gluten-Free Vegetable Broth, 32 oz Carton,
    Shelf' landed in different groups and vegetable-broth kept pricing from 2026-07-18. A preference is
    the wrong shape here; identity has to be the UNION of the two relations:
      * same store product id (a store re-words a listing between captures and only the id survives), and
      * same name, where a 60-character name is the same as the ONE longer name that starts with it
        (that truncation is how the July batch was written; two candidate extensions means the truncation
        cannot prove which product it was and we do not guess).
    Rows are grouped transitively across both, so a three-capture chain id -> name -> truncated name is one
    product. This runs over the rows the depth rule already kept; see note 4 in the header for why.
  #>
  param([object[]]$Rows)
  $rows = @($Rows)
  $dated = @($rows | Where-Object { $_.src_date })
  if ($dated.Count -lt 2) { return @($rows) }

  $g = Get-ProductLabels $dated
  $labelOf = $g.labelOf

  $newestFor = @{}
  for ($i = 0; $i -lt $dated.Count; $i++) {
    $lab = $labelOf[$i]; $d = [string]$dated[$i].src_date
    if (-not $newestFor.ContainsKey($lab) -or $d -gt [string]$newestFor[$lab]) { $newestFor[$lab] = $d }
  }

  # Rebuild in the ORIGINAL order. The ranker's tie-breaks rely on a stable sort, so reordering here would
  # quietly change which of two equal-priced rows wins a cell.
  $out = New-Object System.Collections.Generic.List[object]
  $di = 0
  foreach ($r in $rows) {
    if (-not $r.src_date) { [void]$out.Add($r); continue }
    if ([string]$r.src_date -eq [string]$newestFor[$labelOf[$di]]) { [void]$out.Add($r) }
    $di++
  }
  # .ToArray(), NOT @($out). On this Windows PowerShell 5.1 build (5.1.26100.9168) the array-subexpression
  # operator over a System.Collections.Generic.List[object] throws "Argument types do not match" - verified
  # directly: .ToArray() and [object[]]$list both work, @($list) does not. It cost a whole rebuild to find,
  # because the exception surfaced at the `return` line with no mention of the list.
  return $out.ToArray()
}

function Update-PriceFromNewerSighting {
  <#
    .SYNOPSIS For a row the depth rule kept, take the PRICE from that product's most recent sighting.
    .DESCRIPTION DEPTH AND RECENCY ANSWER DIFFERENT QUESTIONS, and conflating them cost a real cell.
      The depth rule decides which CAPTURE's product set represents a commodity at a store - that is a
      coverage judgement, and it exists because a 1-row capture must not evict a 20-row one.
      But once a product is eligible, WHICH PRICE it carries is a question about that product alone, and
      the answer is simply its latest sighting. Depth has nothing to say about it.

      MEASURED 2026-09-05, lettuce at Sam's Club:
        2026-07-17  Romaine Hearts, 6 ct.  1.0367   <- 2 rows, so depth keeps this capture
        2026-07-29  Romaine Hearts, 6 ct.  0.81     <- 1 row, so depth discards the capture entirely
      The board published 1.0367 while the SAME PRODUCT had been seen twelve days later at 0.81, 22%
      cheaper. Nothing was wrong with the depth rule; it was being asked a question it cannot answer.

      IT CANNOT RESURRECT A THIN CAPTURE. This never adds a product to the eligible set and never changes
      which products represent the commodity - it only re-prices a row that was ALREADY going to price.
      A 1-row capture still cannot win a commodity it was not already winning.

      A NEWER SIGHTING WITH NO USABLE PRICE IS NOT A PRICE. Sam's 2026-09-01 Romaine row is newer than
      both of the above and carries unit_price $null (the sanity band refused it - see
      audit-band-censorship). Taking it would blank a real cell, so rows with no unit_price are skipped
      and the next newest usable sighting wins. Could-not-price is not a price.
  #>
  param([object[]]$Kept, [object[]]$All)
  $kept = @($Kept)
  $all  = @($All  | Where-Object { $_.src_date })
  if ($all.Count -lt 2 -or -not $kept.Count) { return $kept }
  $g = Get-ProductLabels $all
  $labelOf = $g.labelOf
  # newest USABLE row per product across every capture in the window, not just the kept ones
  $best = @{}
  for ($i = 0; $i -lt $all.Count; $i++) {
    $r = $all[$i]
    if ($null -eq $r.unit_price) { continue }
    $lab = $labelOf[$i]; $d = [string]$r.src_date
    if (-not $best.ContainsKey($lab) -or $d -gt [string]$best[$lab].src_date) { $best[$lab] = $r }
  }
  # index the kept rows into the same grouping by object identity
  $idx = @{}
  for ($i = 0; $i -lt $all.Count; $i++) { $idx[[System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($all[$i])] = $i }
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($r in $kept) {
    if (-not $r.src_date) { [void]$out.Add($r); continue }
    $h = [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($r)
    if (-not $idx.ContainsKey($h)) { [void]$out.Add($r); continue }
    $lab = $labelOf[$idx[$h]]
    if (-not $best.ContainsKey($lab)) { [void]$out.Add($r); continue }
    # TWO CASES, and the second is the one lettuce needed.
    #  a. the kept row HAS a price - only a strictly NEWER sighting may replace it.
    #  b. the kept row has NO usable price (the sanity band refused it, so unit_price is null) - it
    #     cannot price the cell at all, so the newest usable sighting of the SAME PRODUCT wins
    #     whatever its date. Sam's Romaine on 2026-09-01 is exactly this: newest, band-refused, and
    #     the only alternatives are older. Requiring 'newer' there leaves a real product unpriced and
    #     hands the cell to whatever else happens to be in the capture.
    if ($null -eq $r.unit_price) { [void]$out.Add($best[$lab]); continue }
    if ([string]$best[$lab].src_date -gt [string]$r.src_date) { [void]$out.Add($best[$lab]) }
    else { [void]$out.Add($r) }
  }
  return $out.ToArray()
}

function Select-FreshestCaptureRows {
  <#
    .SYNOPSIS The rows eligible to price one commodity at one store.
    .DESCRIPTION Undated rows always survive. Among dated rows the newest capture is always eligible,
                 and an older one joins it only when it holds MORE distinct products for this commodity
                 than the newest does. Ties go to the newer capture. Finally, among the captures that
                 survived, a product's older row is dropped when its own newer row is also eligible.
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
  # THE DEPTH DECISION IS COMPLETE HERE. Supersession runs on its output, never on its input.
  $kept = Remove-SupersededRows @($rows | Where-Object { -not $_.src_date -or $keepDates -contains [string]$_.src_date })
  # Depth chose the products; recency prices them. See Update-PriceFromNewerSighting for why these are
  # two questions and what conflating them cost.
  return Update-PriceFromNewerSighting -Kept @($kept) -All @($rows)
}
