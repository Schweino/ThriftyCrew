<#
  purge-verdict-lows.ps1 - remove price-history entries whose price was set by a product a VERDICT REJECTED,
  then recompute record_low from what is left.

  WHY THIS EXISTS AND WHY IT IS NOT purge-bad-lows.
  purge-bad-lows deletes a week whose cheapest is >= 2x under the next-lowest week - a RATIO test. It cannot
  reach the lows that actually hurt, for two independent reasons:
    1. A wrong product is usually only 10-40% cheap, not 2x (bacon's pork-loin filet was 1.02x under, canned
       pinto beans' 12-lb DRY bag 1.32x). The ratio test never sees them.
    2. Prices carry forward daily, so a bad number occupies MANY consecutive rows. purge-bad-lows compares
       sorted[0] with sorted[1] - the second-lowest ROW, not the second-lowest VALUE - so as soon as a bad
       price survives into a second day the ratio is exactly 1.00 and the test is structurally dead.
  Widening the ratio is NOT the answer: at 2x on distinct values, 16 of 19 hits on today's real history are
  legitimate bulk or ad prices (limes $0.25 each, honeydew $1.49, Sam's yeast $0.215/oz). Deleting those would
  be fabricating a price history, and it teaches nobody anything.

  So this purge is EVIDENCE-DRIVEN instead: an entry goes only when a DROP verdict names the exact product that
  set it. That is both safer (a human already judged this product wrong for this commodity at this store) and
  more precise (it reaches a 1.02x error and leaves a genuine 3x sale alone).

  WHAT IT REMOVES. The STORE, not the week. A verdict rejects one store's product; the other five prices in
  that row are real and are the input to the sparkline and the trend tables. So the rejected store is removed
  from per_store and the row's cheapest is recomputed from the survivors. A row is deleted outright only when
  nothing survives.

  WHAT IT REFUSES TO DO. update-history.ps1 carries a plausibility floor that can hold record_low ABOVE the
  history minimum (it refuses a low >= 2x under the next-lowest week). Recomputing record_low as a plain
  minimum would silently UNDO that refusal. So a commodity whose stored record_low already disagrees with its
  own minimum is SKIPPED, named, and the run exits 3 (could-not-evaluate) - a human decides. Today that is
  0 of the affected commodities.

  AND IT OBEYS A HUMAN OVERTURN. verify-apply.ps1 removes a standing suppression when a later keep=true verdict
  names the same item; this purge subtracts the same overturns before it deletes anything, so the two cannot
  disagree about what is still rejected. A tool that DELETES prices must be the strict one.

  IDENTITY. Uses the shared quote-recovery/normalisation in verdict-lib.ps1 - the same definition verify-apply
  and the -Accept gate use. One wrinkle it must handle: the identities backfilled into verdict-suppressions.json
  came from the QUOTE inside a reason, which is often a fragment of the shipped product name ("Pork Loin Filet"
  vs "Smithfield Applewood Smoked Bacon Fresh Pork Loin Filet, 23 oz, 2 Pk."). Exact-norm equality misses those,
  which is exactly why bacon and broccoli survived the last purge. So a match is exact norm OR a TOKEN-BOUNDARY
  containment of the verdict's identity inside the cell name, scoped to the same (commodity, store), and only
  for identities of 2+ tokens. Every match is printed with both strings so it can be eyeballed.

  Usage:
    purge-verdict-lows.ps1              dry run - prints the before/after table, writes nothing
    purge-verdict-lows.ps1 -Apply       backs up, writes, re-parses
    purge-verdict-lows.ps1 -SelfTest    hermetic must-fire + clean-twin fixtures
  Exit: 0 = done (or nothing to do), 2 = failure, 3 = could-not-evaluate (no name evidence, or a floor
  refusal is in effect on an affected commodity).
#>
param([switch]$Apply, [switch]$SelfTest, [string]$HistoryFile = '', [string]$OutDir = '', [string]$SuppressionsFile = '')
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $root 'verdict-lib.ps1')   # Get-VerdictNorm / Get-VerdictQuotedItem - ONE definition of item identity

function Read-Json([string]$p) {
  # '' | ConvertFrom-Json returns $null WITHOUT throwing, and [string]$null is $null (not ''), so a zero-byte
  # file must be caught here rather than three frames later as a null-property error.
  $raw = ((Get-Content $p -Raw -Encoding UTF8) + '').Trim()
  if ($raw.Length -eq 0) { return $null }
  return ($raw | ConvertFrom-Json)
}

# ---------------------------------------------------------------- identity matching
function Test-IdentityMatch([string]$cellNorm, [string]$judgedNorm) {
  if ([string]::IsNullOrEmpty($cellNorm) -or [string]::IsNullOrEmpty($judgedNorm)) { return $false }
  if ($cellNorm -eq $judgedNorm) { return $true }
  # 2+ tokens only: a one-word identity ("bacon") would swallow every product in its own commodity.
  if (@($judgedNorm -split ' ').Count -lt 2) { return $false }
  return ((' ' + $cellNorm + ' ').Contains(' ' + $judgedNorm + ' '))
}

# ---------------------------------------------------------------- the purge itself
function Invoke-VerdictPurge($doc, $rejects, $names) {
  <#
    $doc     parsed price-history document (mutated in place when -Apply)
    $rejects "id|store" -> array of @{ judged_norm; judged; week; reason }
    $names   "week|id|store|price" -> item, plus "id|store|price" -> item (any-week fallback)
    returns  @{ changes; skipped; unknown; unresolved }
  #>
  $changes = @(); $skipped = @(); $script:unknown = 0; $script:unresolved = @(); $emptied = @()
  foreach ($c in @($doc.commodities)) {
    $id = [string]$c.id
    $rowsAll = @($c.history | Where-Object { $null -ne $_.cheapest_price })
    if ($rowsAll.Count -eq 0) { continue }

    # find every (row, store) whose product a verdict rejected
    $hits = @()
    foreach ($h in @($c.history)) {
      $wk = [string]$h.week_of
      $stores = @()
      if ($h.per_store) { $stores = @($h.per_store.PSObject.Properties.Name) }
      elseif ($h.cheapest_store) { $stores = @([string]$h.cheapest_store) }
      foreach ($st in $stores) {
        $rk = $id + '|' + $st
        if (-not $rejects.ContainsKey($rk)) { continue }
        $price = if ($h.per_store -and $h.per_store.PSObject.Properties[$st]) { [double]$h.per_store.$st } else { [double]$h.cheapest_price }
        # THE NAME LOOKUP MUST MATCH THE PRICE, NOT JUST THE WEEK. The board is rebuilt within a day, so a
        # (week,id,store) key alone can hand back a product that was never at this number - history's
        # bacon/Sam's 2026-07-14 is $3.96 while that day's comparison file holds the $3.68 pork-loin filet.
        # Labelling that row "filet" would delete a real Member's Mark bacon price. Same drift the verify
        # gate refuses to guess through, so: price-exact or nothing.
        $item = ''
        if ($names.ContainsKey($wk + '|' + $id + '|' + $st + '|' + $price)) { $item = [string]$names[$wk + '|' + $id + '|' + $st + '|' + $price] }
        elseif ($names.ContainsKey($id + '|' + $st + '|' + $price)) { $item = [string]$names[$id + '|' + $st + '|' + $price] }
        if (-not $item) {
          # NOT a finding and NOT an all-clear: this store is one a verdict has rejected before, but no board
          # we still hold prices it at this number, so the product cannot be identified. Say so out loud when
          # the unidentified cell is the row's WINNER, because that is the cell that can set a record low.
          $script:unknown++
          if ([string]$h.cheapest_store -eq $st) {
            $script:unresolved += ,([pscustomobject]@{ id = $id; store = $st; week = $wk; price = $price; is_record_low = ([math]::Abs(([double]$c.record_low.price) - $price) -lt 0.00005) })
          }
          continue
        }
        $cellNorm = Get-VerdictNorm $item
        foreach ($r in @($rejects[$rk])) {
          if (Test-IdentityMatch $cellNorm ([string]$r.judged_norm)) {
            $hits += [pscustomobject]@{ week = $wk; store = $st; price = $price; item = $item; judged = [string]$r.judged; judged_week = [string]$r.week; reason = [string]$r.reason }
            break
          }
        }
      }
    }
    if ($hits.Count -eq 0) { continue }

    # the floor guard: never silently undo update-history's record_low refusal
    $minAll = ($rowsAll | ForEach-Object { [double]$_.cheapest_price } | Measure-Object -Minimum).Minimum
    if ([math]::Abs(([double]$c.record_low.price) - $minAll) -gt 0.00005) {
      $skipped += [pscustomobject]@{ id = $id; rl = [double]$c.record_low.price; min = $minAll; hits = $hits.Count }
      continue
    }

    $before = [pscustomobject]@{ price = [double]$c.record_low.price; store = [string]$c.record_low.store; week = [string]$c.record_low.week_of }

    # apply: strip the rejected store from each row, recompute that row's cheapest, drop empty rows
    $keptRows = @()
    foreach ($h in @($c.history)) {
      $wk = [string]$h.week_of
      $drops = @($hits | Where-Object { $_.week -eq $wk })
      if ($drops.Count -eq 0) { $keptRows += ,$h; continue }
      if ($h.per_store) {
        foreach ($d in $drops) { if ($h.per_store.PSObject.Properties[$d.store]) { $h.per_store.PSObject.Properties.Remove($d.store) } }
        $left = @($h.per_store.PSObject.Properties)
        if ($left.Count -eq 0) { continue }                                # nothing real left in this row
        $best = @($left | Sort-Object { [double]$_.Value })[0]
        $h.cheapest_price = [double]$best.Value
        $h.cheapest_store = [string]$best.Name
      } else {
        continue                                                           # no per_store to fall back on
      }
      $keptRows += ,$h
    }
    $c.history = $keptRows

    # sort by price THEN week: Sort-Object is not stable in PS 5.1, so ties would otherwise reshuffle the
    # record_low week on every run and churn the page for no price change.
    $rem = @($keptRows | Where-Object { $null -ne $_.cheapest_price } | Sort-Object @{e={[double]$_.cheapest_price}}, @{e={[string]$_.week_of}})
    if ($rem.Count) {
      $c.record_low.price   = [double]$rem[0].cheapest_price
      $c.record_low.store   = [string]$rem[0].cheapest_store
      $c.record_low.week_of = [string]$rem[0].week_of
    }
    else {
      # EVERY row was purged, so there is no honest low left to promote (a single-store commodity whose
      # one store is the rejected one). Leaving record_low pointing at the price we just deleted would keep
      # the rejected wrong-product number on the board FOREVER, and the emptied history means the guard at
      # the top of the loop skips this commodity on every future run - so it could never self-heal.
      # (post-batch review 2026-07-30). Clear it and say so: an absent record low is honest, a retained
      # rejected one is not. The commodity re-earns a low the next time it prices legitimately.
      $c.record_low.price   = $null
      $c.record_low.store   = ''
      $c.record_low.week_of = ''
      $emptied += ,$id
    }
    $changes += [pscustomobject]@{
      id = $id; unit = [string]$c.unit; hits = $hits
      before = $before
      after  = [pscustomobject]@{ price = [double]$c.record_low.price; store = [string]$c.record_low.store; week = [string]$c.record_low.week_of }
    }
  }
  return @{ changes = $changes; skipped = $skipped; unknown = $script:unknown; unresolved = $script:unresolved; emptied = $emptied }
}

# ---------------------------------------------------------------- loaders
function Remove-OverturnedRejects($rej, $overturns) {
  # verify-apply.ps1's documented rule, applied here so the two cannot disagree: "A human overturn wins: a
  # keep=true verdict whose identity matches a suppressed item REMOVES the suppression." Without this the
  # purge deletes history for a product the estate has since RE-REVIEWED AND KEPT - chocolate-milk/Walmart
  # was dropped 2026-07-17 for a size mis-parse and explicitly kept on 2026-07-30 ("data bug fixed upstream,
  # mapping is correct"), yet its standing suppression is still on file because no live cell held that
  # product for verify-apply to un-suppress against. A tool that DELETES prices must be the strict one.
  $dropped = @()
  foreach ($k in @($rej.Keys)) {
    $keepList = @()
    foreach ($e in @($rej[$k])) {
      # THE OVERTURN MUST USE THE SAME MATCHING RULE AS THE DROP (post-batch review 2026-07-30).
      # The drop side matches a history cell by TOKEN CONTAINMENT (Test-IdentityMatch), because a
      # suppression identity is often a quote FRAGMENT - that is the whole reason containment exists. This
      # side compared the KEEP verdict by EXACT normalised identity, so for any fragment-backfilled
      # suppression (about a third of this purge's targets) a human's KEEP verdict, written the way
      # verify-apply writes them (the full shipped product name), could never cancel the reject. The
      # human-overturn safety net could not arm for exactly the entries most likely to need it.
      # Containment is tried BOTH ways round: the verdict may name the full product while the suppression
      # holds the fragment, or the reverse.
      # NB the overturn key is "<id>|<store>|<norm>" and $k is ALREADY "<id>|<store>", so the identity is
      # everything AFTER the "$k|" prefix - splitting on the first pipe would hand back "<store>|<norm>"
      # and silently stop matching, which is how the first draft of this fix made a human-KEPT row
      # purgeable again. Prefix-strip, never split.
      $isOverturned = $false
      $pfx = $k + '|'
      foreach ($ok in @($overturns.Keys)) {
        if (-not $ok.StartsWith($pfx)) { continue }
        $keptNorm = $ok.Substring($pfx.Length)
        if ((Test-IdentityMatch $keptNorm $e.judged_norm) -or (Test-IdentityMatch $e.judged_norm $keptNorm)) { $isOverturned = $true; break }
      }
      if ($isOverturned) { $dropped += ,($k + '|' + $e.judged_norm) }
      else { $keepList += ,$e }
    }
    if ($keepList.Count) { $rej[$k] = $keepList } else { $rej.Remove($k) }
  }
  return $dropped
}

function Get-Rejects([string]$suppFile, [string]$outDir) {
  # every confirmed DROP identity ever recorded, from the durable suppressions AND every verdict file.
  $rej = @{}
  function AddRej($tbl, $id, $store, $judged, $week, $reason) {
    if (-not $judged) { return }
    $k = ([string]$id) + '|' + ([string]$store)
    if (-not $tbl.ContainsKey($k)) { $tbl[$k] = @() }
    $n = Get-VerdictNorm $judged
    foreach ($e in @($tbl[$k])) { if ($e.judged_norm -eq $n) { return } }
    $tbl[$k] = @($tbl[$k]) + @([pscustomobject]@{ judged_norm = $n; judged = [string]$judged; week = [string]$week; reason = [string]$reason })
  }
  if ($suppFile -and (Test-Path $suppFile)) {
    $sd = Read-Json $suppFile
    if ($sd) { foreach ($se in @($sd.suppressions)) { AddRej $rej $se.id $se.store $se.item $se.week $se.reason } }
  }
  $overturns = @{}
  foreach ($f in @(Get-ChildItem (Join-Path $outDir 'verify-verdicts-*.json') -ErrorAction SilentlyContinue)) {
    $vd = Read-Json $f.FullName
    if (-not $vd) { continue }
    foreach ($cv in @($vd.verdicts)) {
      foreach ($e in @($cv.entries)) {
        $judged = ''
        if ($e.PSObject.Properties['item'] -and $e.item) { $judged = [string]$e.item } else { $judged = Get-VerdictQuotedItem ([string]$e.reason) }
        if (-not $judged) { continue }
        if ($e.keep -eq $false) { AddRej $rej $cv.id $e.store $judged $vd.week_of $e.reason }
        else { $overturns[([string]$cv.id) + '|' + ([string]$e.store) + '|' + (Get-VerdictNorm $judged)] = [string]$e.reason }
      }
    }
  }
  $ov = Remove-OverturnedRejects $rej $overturns
  foreach ($o in @($ov)) { Write-Host ('  OVERTURNED - a later keep verdict re-reviewed and KEPT this product, so its history is NOT purged: ' + $o) }
  return $rej
}

function Get-NameIndex([string]$outDir) {
  $names = @{}
  $amb   = @{}
  $files = @()
  $files += @(Get-ChildItem (Join-Path $outDir 'comparison-*.json') -ErrorAction SilentlyContinue)
  $files += @(Get-ChildItem (Join-Path $outDir 'verified-*.json')   -ErrorAction SilentlyContinue)
  foreach ($f in $files) {
    $d = Read-Json $f.FullName
    if (-not $d) { continue }
    $wk = [string]$d.week_of
    foreach ($row in @($d.comparison)) {
      $id = [string]$row.id
      foreach ($s in @($row.stores)) {
        $it = [string]$s.item
        if (-not $it) { continue }
        $k1 = $wk + '|' + $id + '|' + [string]$s.store + '|' + ([double]$s.per_unit)
        if (-not $names.ContainsKey($k1)) { $names[$k1] = $it }
        # any-week fallback for the days whose comparison file is gone. Only usable when this (id, store,
        # price) had exactly ONE product name across every board we still hold; two names at the same number
        # is ambiguous, and an ambiguous identity is skipped, never picked.
        $k2 = $id + '|' + [string]$s.store + '|' + ([double]$s.per_unit)
        if ($amb.ContainsKey($k2)) { continue }
        if ($names.ContainsKey($k2)) { if ([string]$names[$k2] -ne $it) { $names.Remove($k2); $amb[$k2] = $true } }
        else { $names[$k2] = $it }
      }
    }
  }
  return $names
}

# ---------------------------------------------------------------- self-test
if ($SelfTest) {
  $fail = 0
  function T($cond, $msg) { if ($cond) { Write-Host ("  PASS  " + $msg) } else { Write-Host ("  FAIL  " + $msg); $script:fail++ } }

  # --- unit: the quote-fragment shape that let bacon survive the ratio purge ---
  T (Test-IdentityMatch 'smithfield applewood smoked bacon fresh pork loin filet 23 oz 2 pk' 'pork loin filet') `
    'MUST-FIRE: a quote-backfilled identity fragment matches the full shipped product name (the bacon shape)'
  T (-not (Test-IdentityMatch 'member s mark naturally hickory smoked bacon 3 lb' 'pork loin filet')) `
    'CLEAN TWIN: real bacon at the same store/commodity does NOT match the rejected filet'
  T (-not (Test-IdentityMatch 'earthbound farm organic broccoli florets 2 lbs' 'broccoli normandy')) `
    'CLEAN TWIN: a different product sharing the commodity word does not match'
  T (-not (Test-IdentityMatch 'kroger strawberry applesauce' 'strawberry')) `
    'a ONE-token identity is refused (it would swallow the whole commodity)'

  # --- unit: a later KEEP verdict overturns the standing DROP (verify-apply's rule, one definition) ---
  $rj = @{ 'chocolate-milk|Walmart' = @([pscustomobject]@{ judged_norm = 'trumoo whole chocolate milk half gallon'; judged = 'TruMoo Whole Chocolate Milk Half Gallon'; week = '2026-07-17'; reason = 'size mis-parse' }) }
  $ovHit = Remove-OverturnedRejects $rj @{ 'chocolate-milk|Walmart|trumoo whole chocolate milk half gallon' = 'Re-reviewed and KEPT - data bug fixed upstream' }
  T (@($ovHit).Count -eq 1 -and -not $rj.ContainsKey('chocolate-milk|Walmart')) `
    'MUST-FIRE: a later KEEP verdict overturns the standing DROP, so the purge stops deleting a re-reviewed product'
  $rj2 = @{ "bacon|Sam's Club" = @([pscustomobject]@{ judged_norm = 'pork loin filet'; judged = 'Pork Loin Filet'; week = '2026-07-15'; reason = 'not bacon' }) }
  $ovMiss = Remove-OverturnedRejects $rj2 @{ "bacon|Sam's Club|member s mark naturally hickory smoked bacon 3 lb" = 'kept' }
  T (@($ovMiss).Count -eq 0 -and @($rj2["bacon|Sam's Club"]).Count -eq 1) `
    'CLEAN TWIN: a KEEP for a DIFFERENT product at the same (commodity,store) does not un-reject the judged one'

  # --- behavioural: frozen synthetic history, no live data ---
  # NOTE the -creplace and the __BAD__ token: -replace is case-INSENSITIVE in PowerShell, so a plain
  # 'LO' token also rewrites the "lo" inside "record_low" and the fixture silently stops being a fixture.
  $mkDoc = {
    param($lo)
    ConvertFrom-Json (@'
{"updated":"2026-07-29","weeks_on_record":3,"commodities":[
 {"id":"bacon","label":"Bacon","unit":"lb","record_low":{"price":__BAD__,"store":"Sam's Club","week_of":"2026-07-17"},
  "history":[
   {"week_of":"2026-07-15","cheapest_price":3.96,"cheapest_store":"Sam's Club","per_store":{"Sam's Club":3.96,"Baker's":3.99}},
   {"week_of":"2026-07-17","cheapest_price":__BAD__,"cheapest_store":"Sam's Club","per_store":{"Sam's Club":__BAD__,"Baker's":3.79}},
   {"week_of":"2026-07-18","cheapest_price":__BAD__,"cheapest_store":"Sam's Club","per_store":{"Sam's Club":__BAD__,"Baker's":3.79}}]}]}
'@ -creplace '__BAD__', $lo)
  }
  $rejects = @{ "bacon|Sam's Club" = @([pscustomobject]@{ judged_norm = 'pork loin filet'; judged = 'Pork Loin Filet'; week = '2026-07-15'; reason = 'marinated pork loin, not bacon' }) }
  # keys are week|id|store|price - the price is part of the key on purpose (see the drift note above)
  $names = @{
    "2026-07-17|bacon|Sam's Club|3.607" = 'Smithfield Applewood Smoked Bacon Fresh Pork Loin Filet, 23 oz, 2 Pk.'
    "2026-07-18|bacon|Sam's Club|3.607" = 'Smithfield Applewood Smoked Bacon Fresh Pork Loin Filet, 23 oz, 2 Pk.'
    "2026-07-15|bacon|Sam's Club|3.96"  = "Member's Mark Naturally Hickory Smoked Bacon (3 lb)"
    "2026-07-17|bacon|Baker's|3.79"     = 'Private Selection Thick Sliced Bacon'
    "2026-07-18|bacon|Baker's|3.79"     = 'Private Selection Thick Sliced Bacon'
    "2026-07-15|bacon|Baker's|3.99"     = 'Private Selection Thick Sliced Bacon'
  }
  # MUST FIRE: the 1.02x-under filet is removed even though no ratio test can see it
  $d1 = & $mkDoc 3.607
  $r1 = Invoke-VerdictPurge $d1 $rejects $names
  $c1 = @($d1.commodities)[0]
  T (@($r1.changes).Count -eq 1 -and [math]::Abs(([double]$c1.record_low.price) - 3.79) -lt 0.0001 -and ([string]$c1.record_low.store) -eq "Baker's") `
    ('MUST-FIRE: record_low 3.607 (Pork Loin Filet, 1.02x under the next row - invisible to purge-bad-lows) becomes 3.79 Baker' + [char]0x0027 + 's')
  T (@($c1.history).Count -eq 3 -and -not (@($c1.history)[1].per_store.PSObject.Properties["Sam's Club"]) -and (@($c1.history)[1].per_store.PSObject.Properties["Baker's"])) `
    'MUST-FIRE: only the rejected store leaves the row - the other store keeps its real price and the week survives'

  # CLEAN TWIN 1: identical history, but the cell holds real bacon -> nothing moves
  $namesClean = @{}
  foreach ($k in @($names.Keys)) { $namesClean[$k] = $names[$k] }
  $namesClean["2026-07-17|bacon|Sam's Club|3.607"] = "Member's Mark Naturally Hickory Smoked Bacon (3 lb)"
  $namesClean["2026-07-18|bacon|Sam's Club|3.607"] = "Member's Mark Naturally Hickory Smoked Bacon (3 lb)"
  $d2 = & $mkDoc 3.607
  $r2 = Invoke-VerdictPurge $d2 $rejects $namesClean
  T (@($r2.changes).Count -eq 0 -and [math]::Abs(([double](@($d2.commodities)[0].record_low.price)) - 3.607) -lt 0.0001) `
    'CLEAN TWIN: an unrejected product at the same store/week is left completely alone'

  # CLEAN TWIN 2: no name evidence at all -> refuse to act (never guess an identity)
  $d3 = & $mkDoc 3.607
  $r3 = Invoke-VerdictPurge $d3 $rejects @{}
  T (@($r3.changes).Count -eq 0) 'CLEAN TWIN: with no product-name evidence nothing is removed (identity is never inferred)'

  # CLEAN TWIN 3: the PRICE-DRIFT shape. The only name evidence for this week/store is at a DIFFERENT price -
  # live history bacon/Sam's 2026-07-14 is $3.96 while that day's comparison file holds the $3.68 filet. A
  # week-only lookup labels the row "filet" and deletes a real Member's Mark bacon price.
  $d5 = & $mkDoc 3.607
  $r5 = Invoke-VerdictPurge $d5 $rejects @{ "2026-07-15|bacon|Sam's Club|3.68" = 'Smithfield Applewood Smoked Bacon Fresh Pork Loin Filet, 23 oz, 2 Pk.' }
  T (@($r5.changes).Count -eq 0 -and (@($d5.commodities)[0].history)[0].per_store.PSObject.Properties["Sam's Club"]) `
    'CLEAN TWIN: a name that belongs to a different PRICE never labels this row (the board-rebuilt-same-day drift)'

  # MUST FIRE: the floor guard. record_low disagrees with the minimum -> skip + report, never undo the refusal.
  $d4 = & $mkDoc 3.607
  @($d4.commodities)[0].record_low.price = 3.79      # update-history refused the 3.607 low
  $r4 = Invoke-VerdictPurge $d4 $rejects $names
  T (@($r4.changes).Count -eq 0 -and @($r4.skipped).Count -eq 1 -and [math]::Abs(([double](@($d4.commodities)[0].record_low.price)) - 3.79) -lt 0.0001) `
    'MUST-FIRE: a commodity whose record_low is already held above its minimum is SKIPPED, not silently re-lowered'

  # MUST FIRE (post-batch review 2026-07-30): a commodity whose ENTIRE history is rejected - a single-store
  # commodity whose one store is the rejected one - used to keep record_low pointing at the price just
  # deleted, forever: the emptied history made the guard at the top of the loop skip it on every future run,
  # so it could never self-heal, and the run still exited 0 saying "record_low moved: 0".
  $d6 = [pscustomobject]@{ commodities = @([pscustomobject]@{
      id = 'solo-thing'; unit = 'lb'
      record_low = [pscustomobject]@{ price = 1.11; store = "Sam's Club"; week_of = '2026-07-15' }
      history = @([pscustomobject]@{ week_of = '2026-07-15'; cheapest_price = 1.11; cheapest_store = "Sam's Club"
                                     per_store = [pscustomobject]@{ "Sam's Club" = 1.11 } })
    }) }
  $soloRej = @{ "solo-thing|Sam's Club" = @(@{ judged_norm = (Get-VerdictNorm 'Bogus Solo Product'); judged = 'Bogus Solo Product'; week = '2026-07-15'; reason = 'wrong product' }) }
  $r6 = Invoke-VerdictPurge $d6 $soloRej @{ "2026-07-15|solo-thing|Sam's Club|1.11" = 'Bogus Solo Product' }
  T ((@($r6.emptied) -contains 'solo-thing') -and ($null -eq (@($d6.commodities)[0].record_low.price))) `
    'MUST-FIRE: a commodity whose whole history is purged has its record_low CLEARED, not left on the deleted price'

  # CLEAN TWIN: the same shape with a SURVIVING row must promote that row, never clear.
  $d7 = [pscustomobject]@{ commodities = @([pscustomobject]@{
      id = 'duo-thing'; unit = 'lb'
      record_low = [pscustomobject]@{ price = 1.11; store = "Sam's Club"; week_of = '2026-07-15' }
      history = @(
        [pscustomobject]@{ week_of = '2026-07-15'; cheapest_price = 1.11; cheapest_store = "Sam's Club"; per_store = [pscustomobject]@{ "Sam's Club" = 1.11 } },
        [pscustomobject]@{ week_of = '2026-07-16'; cheapest_price = 2.22; cheapest_store = 'Aldi';       per_store = [pscustomobject]@{ 'Aldi' = 2.22 } })
    }) }
  $duoRej = @{ "duo-thing|Sam's Club" = @(@{ judged_norm = (Get-VerdictNorm 'Bogus Solo Product'); judged = 'Bogus Solo Product'; week = '2026-07-15'; reason = 'wrong product' }) }
  $r7 = Invoke-VerdictPurge $d7 $duoRej @{ "2026-07-15|duo-thing|Sam's Club|1.11" = 'Bogus Solo Product' }
  T ((@($r7.emptied).Count -eq 0) -and ([math]::Abs(([double](@($d7.commodities)[0].record_low.price)) - 2.22) -lt 0.0001)) `
    'CLEAN TWIN: a surviving row is promoted to record_low rather than the low being cleared'

  # MUST FIRE (post-batch review 2026-07-30): the human overturn must use the SAME containment rule as the
  # drop. A suppression identity is often a quote FRAGMENT, so a KEEP verdict naming the FULL product name
  # could never cancel it under exact-equality - the safety net could not arm for a third of the targets.
  $d8 = & $mkDoc 3.607
  $fullKeep = @{ ("bacon|Sam's Club|" + (Get-VerdictNorm 'Smithfield Applewood Smoked Bacon Fresh Pork Loin Filet, 23 oz, 2 Pk.')) = $true }
  $rejFrag = @{ "bacon|Sam's Club" = @(@{ judged_norm = (Get-VerdictNorm 'Pork Loin Filet'); judged = 'Pork Loin Filet'; week = '2026-07-15'; reason = 'marinated pork loin, not bacon' }) }
  $dropped = Remove-OverturnedRejects $rejFrag $fullKeep
  T (@($dropped).Count -eq 1 -and $rejFrag.Count -eq 0) `
    'MUST-FIRE: a KEEP verdict naming the FULL product overturns a suppression held as a quote FRAGMENT'

  # CLEAN TWIN: an unrelated KEEP at the same (id,store) must NOT cancel the rejection.
  $rejFrag2 = @{ "bacon|Sam's Club" = @(@{ judged_norm = (Get-VerdictNorm 'Pork Loin Filet'); judged = 'Pork Loin Filet'; week = '2026-07-15'; reason = 'marinated pork loin, not bacon' }) }
  $otherKeep = @{ ("bacon|Sam's Club|" + (Get-VerdictNorm "Member's Mark Thick Cut Bacon 3 lb")) = $true }
  $dropped2 = Remove-OverturnedRejects $rejFrag2 $otherKeep
  T (@($dropped2).Count -eq 0 -and $rejFrag2.Count -eq 1) `
    'CLEAN TWIN: a KEEP on a DIFFERENT product at the same store leaves the rejection standing'

  if ($fail -eq 0) { Write-Host 'SELF-TEST PASS'; exit 0 }
  Write-Host ('SELF-TEST FAIL (' + $fail + ')'); exit 2
}

# ---------------------------------------------------------------- live run
if (-not $OutDir)      { $OutDir = Join-Path $root 'out' }
if (-not $HistoryFile) { $HistoryFile = Join-Path $root 'price-history.json' }
if (-not $SuppressionsFile) { $SuppressionsFile = Join-Path $root 'verdict-suppressions.json' }

$doc = Read-Json $HistoryFile
if (-not $doc -or -not @($doc.commodities).Count) { Write-Host 'BLIND - price-history.json is empty or unreadable; nothing was examined.'; exit 3 }
$rejects = Get-Rejects $SuppressionsFile $OutDir
$names   = Get-NameIndex $OutDir
Write-Host ('rejected identities: ' + $rejects.Count + ' (commodity,store) key(s)   product-name index: ' + $names.Count + ' entries')
if ($rejects.Count -eq 0 -or $names.Count -eq 0) {
  Write-Host 'BLIND - no DROP verdicts and/or no product-name evidence reached this run, so ZERO findings means nothing was examined.'
  exit 3
}

$res = Invoke-VerdictPurge $doc $rejects $names
$changes = @($res.changes); $skipped = @($res.skipped); $emptiedIds = @($res.emptied)

foreach ($ch in $changes) {
  Write-Host ''
  Write-Host ('=== ' + $ch.id + '  (' + $ch.unit + ')')
  foreach ($h in @($ch.hits)) {
    Write-Host ('    remove  ' + $h.week + '  ' + $h.store.PadRight(12) + ('{0,10}' -f $h.price) + '  "' + $h.item + '"')
  }
  Write-Host ('    verdict ' + (@($ch.hits)[0].judged_week) + ': "' + (@($ch.hits)[0].judged) + '" - ' + (@($ch.hits)[0].reason))
  Write-Host ('    record_low  ' + $ch.before.price + ' @ ' + $ch.before.store + ' ' + $ch.before.week + '   ->   ' + $ch.after.price + ' @ ' + $ch.after.store + ' ' + $ch.after.week)
}

$removed = 0; foreach ($ch in $changes) { $removed += @($ch.hits).Count }
Write-Host ''
Write-Host ('commodities changed: ' + $changes.Count + '   entries removed: ' + $removed + '   record_low moved: ' + @($changes | Where-Object { [math]::Abs($_.before.price - $_.after.price) -gt 0.00005 }).Count + '   cells at a rejected (id,store) with no price-exact name evidence, left alone: ' + [int]$res.unknown)
if ($emptiedIds.Count) {
  Write-Host ('record_low CLEARED (every history row was rejected, so there is no honest low left to promote; the commodity re-earns one when it next prices legitimately): ' + (($emptiedIds | Sort-Object) -join ', '))
}
if ($skipped.Count) {
  Write-Host ''
  Write-Host ('SKIPPED - a record_low refusal is already in effect on ' + $skipped.Count + ' affected commodit(ies); recomputing would undo it. Resolve by hand:')
  foreach ($s in $skipped) { Write-Host ('    ' + $s.id + '  record_low=' + $s.rl + ' but history minimum=' + $s.min + '  (' + $s.hits + ' rejected entr(ies) left in place)') }
}
$unres = @($res.unresolved)
if ($unres.Count) {
  Write-Host ''
  Write-Host ('COULD NOT EVALUATE - ' + $unres.Count + ' winning cell(s) sit at a store this commodity has had a product rejected at, but no board still on disk prices that store at that number, so the product cannot be named. NOT purged, NOT cleared:')
  foreach ($u in ($unres | Sort-Object id, week)) { Write-Host ('    ' + $u.id.PadRight(22) + $u.store.PadRight(13) + $u.week + '  ' + $u.price + $(if ($u.is_record_low) { '   <- this IS the commodity record low' } else { '' })) }
  # WRITE ONLY ON -Apply. The header promises the dry run "writes nothing", and it wrote this tracked file
  # before ever reaching the dry-run branch - so a look-don't-touch invocation dirtied the repo (post-batch
  # review 2026-07-30). The list is printed above either way, so the dry run loses no information.
  if ($Apply) {
    ([ordered]@{ generated = (Get-Date).ToString('s'); note = 'winning history cells at a verdict-rejected (commodity,store) whose product could not be identified from any surviving board; neither purged nor cleared'; cells = $unres } | ConvertTo-Json -Depth 5) | Set-Content (Join-Path $OutDir 'purge-verdict-lows-unresolved.json') -Encoding UTF8
  }
}

if (-not $Apply) { Write-Host ''; Write-Host 'DRY RUN - pass -Apply to write.'; if ($skipped.Count) { exit 3 }; exit 0 }
if ($changes.Count -eq 0) { Write-Host 'nothing to write.'; if ($skipped.Count) { exit 3 }; exit 0 }

$stamp = (Get-Date -Format 'yyyy-MM-dd-HHmmss')
$backup = Join-Path $OutDir ('price-history.backup-' + $stamp + '.json')
Copy-Item $HistoryFile $backup -Force
Write-Host ('backup: ' + $backup)

$tmp = $HistoryFile + '.tmp'
($doc | ConvertTo-Json -Depth 12) | Set-Content $tmp -Encoding UTF8
$check = Read-Json $tmp
if (-not $check -or @($check.commodities).Count -ne @($doc.commodities).Count) { Write-Host 'ABORT - the rewritten file did not re-parse with the same commodity count; original left untouched.'; Remove-Item $tmp -Force; exit 2 }
Move-Item $tmp $HistoryFile -Force
Write-Host 'price-history.json written and re-parsed clean.'
if ($skipped.Count) { exit 3 }
exit 0

