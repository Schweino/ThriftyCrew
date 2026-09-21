<#
  cell-quarantine-lib.ps1 - A BAD CELL QUARANTINES ITSELF, A BAD STORE DROPS ITSELF, AND ONLY A BOARD-SCOPED
  FAILURE OR THE CIRCUIT BREAKER HOLDS THE BOARD.

  Brad, 2026-09-21, verbatim: "The ENTIRE board shouldn't be held hostage because of one (or a few) bad items.
  Each item is unique/individual." His ruling on Q1 of design\PLAN-per-cell-quarantine-2026-09-21.md, what a
  quarantined cell shows a reader: "A" - its last verified published price, with that price's date.

  WHY. guards.ps1 held the whole board at 08:12 that day on ONE hard failure, the band-censorship ratchet's one new
  cell (vegetable-oil / Sam's Club), against about 2,705 priced cells. The type "GUARDS FAILED - board not
  published" fired on 15 of the previous 30 days, and on 2026-09-20 one of its two reasons was a SOURCE-CODE lint
  ratchet with no board cell behind it at all.

  THE CONTRACT - guards.ps1's exit codes, and every reader of them was censused before this was written
  (grocery\triage-plans\plan-2026-09-21-4.json, item discovered:per-cell-quarantine-2026-09-21):
    0  GUARDS OK             every hard invariant holds and nothing is quarantined. Publish.
    2  NOT PUBLISHABLE AS IT STANDS. Either a HOLD ("GUARDS FAILED": a board-scoped failure, the circuit breaker,
       a failure that could not be scoped to a published cell, a new failure on a board that is already
       quarantined) or QUARANTINE-REQUIRED ("GUARDS QUARANTINE-REQUIRED": every failure is scoped to cells or
       stores under the breaker, and out\cell-quarantine.json names them). On the second, apply-cell-quarantine.ps1
       holds those cells at their last verified published price or withholds them, and guards runs again.
       Exit 2 therefore keeps its old meaning for every reader that never learned the new tier.
    4  GUARDS QUARANTINED    the board carries N quarantined cells, each VERIFIED on this board to publish its last
       verified price (or nothing), and every other hard invariant holds. Publish, and page ONCE naming the cells.
       A reader that never learned 4 reads it as not-0, which is held: that fails CLOSED, never open.

  WHAT A QUARANTINED CELL SHOWS (ruling A), and the three cases where it shows NOTHING instead (withheld):
    * no previously published value for that cell        - nothing is invented;
    * the previous value is older than the board's own max_publish_age_days (the capture-policy quarter);
    * the previous value was a SALE: the published board carries no end date for it, and a sale we cannot date is a
      sale we cannot stand behind (guards' own guard 8 rule);
    * the guard condemned the VALUE and the previous value IS that value: republishing it would publish the exact
      number the guard just proved wrong. (A guard that condemns the SELECTION - band censorship says a cheaper real
      row was refused - does not condemn the number itself, so a last value equal to today's is still shown.)
  The previous value comes from the LAST PUBLISHED board: public\board.json as committed on origin/main, which is
  the byte-for-byte file the feed Worker serves (committing it IS the feed deploy). out\published-board.sig is a
  hash, not a record of values, so it cannot answer this. The price's date is the day that board was committed,
  unless the published row carries the cell in its `q` list, in which case the date it was FIRST held is carried
  forward, so a cell quarantined three days running still says the date its price was last verified.

  THIS FILE DECLARES NO param() BLOCK: it is dot-sourced by guards.ps1, apply-cell-quarantine.ps1,
  build-deals-page.ps1, export-feed.ps1 and test-cell-quarantine.ps1, and a dot-sourced param() runs in the caller.
#>

# ---- THE CIRCUIT BREAKER (control constants; registered in docs\CONTROL-CONSTANTS.md) ----------------------------
# Per-cell quarantine has one real failure mode: a systemic bug that hits hundreds of cells would be quarantined cell
# by cell and the board would publish mostly frozen. So past these bars the run HOLDS instead.
# FIRST PLAUSIBLE NUMBERS, NOT THE SURVIVORS OF A SWEEP (design\PLAN-per-cell-quarantine-2026-09-21.md). Nothing else
# was tried. The founding case is 1 cell of about 2,705 (0.04%), far under both. The comparison is on INTEGERS
# (cells x 100 against priced x bar) so a case exactly at a bar is exact, never decided by a double.
# Direction: an UPPER bound on quarantined cells. When the producer stops (guards does not run, or scopes nothing),
# no cell is quarantined and the breaker cannot fire - the chain verdict and health-heartbeat own that absence.
$script:TcQuarantineBoardPct = 2    # more than 2% of the staple board's priced cells quarantined  -> HOLD
$script:TcQuarantineStorePct = 10   # more than 10% of ONE store's priced cells quarantined        -> HOLD

function ConvertTo-TcDay([string]$Text) {
  $d = [datetime]::MinValue
  if ([datetime]::TryParseExact(([string]$Text).Trim(), 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }
  return $null
}

function Set-TcCellField($Object, [string]$Name, $Value) {
  if ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
  else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}

function Test-TcCellQuarantined($Cell) {
  # A cell held at its last verified price carries a `quarantine` object with the date it was verified. Renderers
  # read THIS, never a field of their own, so the page, the feed and the gate agree on which cells are held.
  if ($null -eq $Cell) { return $false }
  $p = $Cell.PSObject.Properties['quarantine']
  return [bool]($p -and $p.Value -and [string]$p.Value.since)
}

function New-TcGuardFailure {
  # One hard failure, structured. family: 'cell' (one commodity at one store), 'store' (a store's everyday prices),
  # 'board' (nothing on the board can be trusted). kind: 'value' (the guard condemned the NUMBER) or 'selection'
  # (the number is real but the wrong row was chosen). Ix is the failure's index in guards' $fail list.
  param([string]$Message, [string]$Family = 'board', [string]$Id = '', [string]$Store = '', [string]$Kind = 'value',
        $BadPerUnit = $null, [string]$BadItem = '', [string]$Check = '', [int]$Ix = -1)
  if (@('cell', 'store', 'board') -notcontains $Family) { throw "unknown guard failure family: $Family" }
  if (@('value', 'selection') -notcontains $Kind) { throw "unknown guard failure kind: $Kind" }
  $bp = $null; if ($null -ne $BadPerUnit -and [string]$BadPerUnit -ne '') { $bp = [double]$BadPerUnit }
  return [pscustomobject]@{ message = $Message; family = $Family; id = $Id; store = $Store; kind = $Kind; bad_per_unit = $bp; bad_item = $BadItem; check = $Check; ix = $Ix }
}

function ConvertTo-TcGuardFailures($Messages, $Scoped) {
  # Every entry of guards' $fail list becomes one or more structured failures. An entry nobody scoped is BOARD
  # family - so a guard that was never taught to scope its failure holds the board exactly as it did before.
  $byIx = @{}
  foreach ($s in @($Scoped)) { if ($null -eq $s) { continue }; $k = [int]$s.ix; if (-not $byIx.ContainsKey($k)) { $byIx[$k] = New-Object System.Collections.ArrayList }; [void]$byIx[$k].Add($s) }
  $out = New-Object System.Collections.ArrayList
  $i = 0
  foreach ($m in @($Messages)) {
    if ($byIx.ContainsKey($i)) { foreach ($s in $byIx[$i]) { [void]$out.Add($s) } }
    else { [void]$out.Add((New-TcGuardFailure -Message ([string]$m) -Family 'board' -Ix $i)) }
    $i++
  }
  return [pscustomobject]@{ failures = $out.ToArray() }
}

function Get-TcChildQuarantineScope($Lines) {
  # THE PROTOCOL A DELEGATED AUDIT USES TO SCOPE ITS OWN HARD FAILURE. On stdout, before its COMPLETE marker:
  #   QUARANTINE-CELL <commodity-id>|<store>|<value|selection>
  #   QUARANTINE-STORE <store>
  #   QUARANTINE-SCOPE complete cells=<N> stores=<M>
  # The last line is the child AFFIRMING that every hard finding it has is listed. Without it - or with a count that
  # does not match the lines, or with a malformed line - this returns $null and guards treats the failure as board
  # scoped: a child that cannot say what is wrong holds the board, exactly as before this protocol existed.
  $cells = New-Object System.Collections.ArrayList; $stores = New-Object System.Collections.ArrayList
  $complete = $null
  foreach ($l in @($Lines)) {
    $t = ([string]$l).Trim()
    if ($t.StartsWith('QUARANTINE-CELL ', [StringComparison]::Ordinal)) {
      $parts = $t.Substring(16).Split('|')
      if ($parts.Count -lt 2 -or -not $parts[0].Trim() -or -not $parts[1].Trim()) { return $null }
      $kind = 'value'; if ($parts.Count -ge 3 -and $parts[2].Trim() -eq 'selection') { $kind = 'selection' }
      [void]$cells.Add([pscustomobject]@{ id = $parts[0].Trim(); store = $parts[1].Trim(); kind = $kind })
    } elseif ($t.StartsWith('QUARANTINE-STORE ', [StringComparison]::Ordinal)) {
      $sn = $t.Substring(17).Trim(); if (-not $sn) { return $null }
      [void]$stores.Add($sn)
    } elseif ($t.StartsWith('QUARANTINE-SCOPE complete', [StringComparison]::Ordinal)) { $complete = $t }
  }
  if (-not $complete -or ($cells.Count + $stores.Count) -eq 0) { return $null }
  $mc = [regex]::Match($complete, 'cells=(\d+)'); if ($mc.Success -and [int]$mc.Groups[1].Value -ne $cells.Count) { return $null }
  $ms = [regex]::Match($complete, 'stores=(\d+)'); if ($ms.Success -and [int]$ms.Groups[1].Value -ne $stores.Count) { return $null }
  return [pscustomobject]@{ cells = $cells.ToArray(); stores = $stores.ToArray() }
}

function Get-TcBoardPricedCounts($Board) {
  $keys = @{}; $per = @{}; $total = 0
  foreach ($r in @($Board.comparison)) {
    if ($null -eq $r) { continue }
    foreach ($s in @($r.stores)) {
      if ($null -eq $s) { continue }
      $pu = 0.0; try { $pu = [double]$s.per_unit } catch { $pu = 0.0 }
      if ($pu -le 0) { continue }
      $st = [string]$s.store
      $keys[[string]$r.id + '|' + $st] = $true; $total++; $per[$st] = 1 + [int]$per[$st]
    }
  }
  return [pscustomobject]@{ total = $total; perStore = $per; keys = $keys }
}

function Find-TcBoardCellKeys($Board, [string]$Store, [string]$Item) {
  # For the guards that judge a CAPTURE ROW rather than a board cell (5 multipack, 10 store-charges): which published
  # cells carry that product at that store? Also the cells an applied quarantine already holds for it, because a
  # withheld cell is no longer on the board and must still be recognised as covered on the second run.
  $want = ([string]$Item).Trim()
  $keys = New-Object System.Collections.ArrayList
  if ($want) {
    foreach ($r in @($Board.comparison)) {
      foreach ($s in @($r.stores)) {
        if ($null -eq $s -or [string]$s.store -ne $Store) { continue }
        if ([string]::Equals(([string]$s.item).Trim(), $want, [StringComparison]::OrdinalIgnoreCase)) {
          $k = [string]$r.id + '|' + $Store; if (-not $keys.Contains($k)) { [void]$keys.Add($k) }
        }
      }
    }
    $b = Get-TcQuarantineBlock $Board
    if ($b) {
      foreach ($e in @($b.cells)) {
        if ($null -ne $e -and [string]$e.store -eq $Store -and [string]::Equals(([string]$e.bad_item).Trim(), $want, [StringComparison]::OrdinalIgnoreCase)) {
          $k = [string]$e.id + '|' + $Store; if (-not $keys.Contains($k)) { [void]$keys.Add($k) }
        }
      }
    }
  }
  return [pscustomobject]@{ keys = $keys.ToArray() }
}

function Get-TcQuarantineBlock($Board) {
  if ($null -eq $Board) { return $null }
  $p = $Board.PSObject.Properties['quarantine']
  if ($null -eq $p -or $null -eq $p.Value) { return $null }
  return $p.Value
}

function Test-TcQuarantineBlock($Board) {
  # THE SECOND RUN'S PROOF that an applied quarantine actually holds on THIS board: a held cell publishes exactly its
  # recorded last verified price and carries the marker renderers read, a withheld cell is absent, and a dropped
  # store prices nothing at an everyday price. Anything else is a problem, and a problem holds the board.
  $res = [pscustomobject]@{ present = $false; ok = $true; problems = @(); cells = @(); stores = @(); withheldPerStore = @{} }
  $b = Get-TcQuarantineBlock $Board
  if ($null -eq $b) { return $res }
  $res.present = $true
  $probs = New-Object System.Collections.ArrayList
  $byId = @{}; foreach ($r in @($Board.comparison)) { if ($r) { $byId[[string]$r.id] = $r } }
  $cells = @(@($b.cells) | Where-Object { $null -ne $_ })
  $stores = @(@($b.stores) | Where-Object { $null -ne $_ })
  foreach ($e in $cells) {
    $id = [string]$e.id; $st = [string]$e.store; $act = [string]$e.action
    $cell = $null
    if ($byId.ContainsKey($id)) { foreach ($s in @($byId[$id].stores)) { if ($s -and [string]$s.store -eq $st) { $cell = $s; break } } }
    if ($act -eq 'last-good') {
      if ($null -eq $cell) { [void]$probs.Add("$id/$st is recorded as held at its last verified price but the board carries no such cell") }
      elseif (-not (Test-TcCellQuarantined $cell)) { [void]$probs.Add("$id/$st carries no quarantine marker, so a renderer would publish it as a live price") }
      elseif ([math]::Abs([double]$cell.per_unit - [double]$e.per_unit) -ge 0.0001) { [void]$probs.Add(("{0}/{1} publishes {2} but its recorded last verified price is {3}" -f $id, $st, $cell.per_unit, $e.per_unit)) }
    } elseif ($act -eq 'withheld') {
      if ($null -ne $cell) { [void]$probs.Add("$id/$st is recorded as WITHHELD but the board still carries a price for it") }
      $res.withheldPerStore[$st] = 1 + [int]$res.withheldPerStore[$st]
    } else { [void]$probs.Add("$id/$st carries an unknown quarantine action '$act'") }
  }
  foreach ($e in $stores) {
    $st = [string]$e.store; $left = 0
    foreach ($r in @($Board.comparison)) { foreach ($s in @($r.stores)) { if ($s -and [string]$s.store -eq $st -and [string]$s.type -ne 'sale' -and [double]$s.per_unit -gt 0) { $left++ } } }
    if ($left -gt 0) { [void]$probs.Add("store $st is recorded as DROPPED but still prices $left cell(s) at an everyday price") }
  }
  $res.problems = $probs.ToArray(); $res.ok = ($probs.Count -eq 0); $res.cells = $cells; $res.stores = $stores
  return $res
}

function Test-TcQuarantineBreaker($CellKeys, $Counts, $ExtraPerStore) {
  # $CellKeys: id|store of every quarantined cell. $ExtraPerStore: withheld cells per store, which are no longer on
  # the board and so are added back to the denominator they were taken from.
  $q = 0; $qs = @{}
  foreach ($k in @($CellKeys)) { if (-not $k) { continue }; $q++; $st = ([string]$k -split '\|', 2)[1]; $qs[$st] = 1 + [int]$qs[$st] }
  $extraTotal = 0; if ($ExtraPerStore) { foreach ($v in @($ExtraPerStore.Values)) { $extraTotal += [int]$v } }
  $priced = [int]$Counts.total + $extraTotal
  $res = [pscustomobject]@{ tripped = $false; why = ''; quarantined = $q; priced = $priced; board_pct_bar = $script:TcQuarantineBoardPct; store_pct_bar = $script:TcQuarantineStorePct; stores = @() }
  if ($q -eq 0) { return $res }
  if (($q * 100) -gt ($priced * $script:TcQuarantineBoardPct)) {
    $res.tripped = $true; $res.why = ("{0} quarantined cell(s) of {1} priced is more than {2}% of the board" -f $q, $priced, $script:TcQuarantineBoardPct)
  }
  $rows = New-Object System.Collections.ArrayList
  foreach ($st in @($qs.Keys | Sort-Object)) {
    $ps = [int]$Counts.perStore[$st]; if ($ExtraPerStore -and $ExtraPerStore.ContainsKey($st)) { $ps += [int]$ExtraPerStore[$st] }
    $n = [int]$qs[$st]
    [void]$rows.Add([pscustomobject]@{ store = $st; quarantined = $n; priced = $ps })
    if (($n * 100) -gt ($ps * $script:TcQuarantineStorePct)) {
      $res.tripped = $true
      $w = ("{0} of {1} priced {2} cell(s) quarantined is more than {3}% of that store" -f $n, $ps, $st, $script:TcQuarantineStorePct)
      if ($res.why) { $res.why = $res.why + '; ' + $w } else { $res.why = $w }
    }
  }
  $res.stores = $rows.ToArray()
  return $res
}

function Get-TcGuardsDisposition($Failures, $Board) {
  # THE ONE DECISION: pass, quarantine (required), quarantined (applied and verified), or hold. Pure over its inputs.
  $counts = Get-TcBoardPricedCounts -Board $Board
  $blk = Test-TcQuarantineBlock -Board $Board
  $cov = @{}; foreach ($e in @($blk.cells)) { $cov[[string]$e.id + '|' + [string]$e.store] = $e }
  $covSt = @{}; foreach ($e in @($blk.stores)) { $covSt[[string]$e.store] = $true }
  $cells = [ordered]@{}; $stores = [ordered]@{}
  $hold = New-Object System.Collections.ArrayList
  foreach ($f in @($Failures)) {
    if ($null -eq $f) { continue }
    $fam = [string]$f.family
    if ($fam -eq 'cell') {
      $k = [string]$f.id + '|' + [string]$f.store
      if ($cov.ContainsKey($k)) {
        # COVERED - unless the guard condemns the HELD value itself. A held cell's failures on the second run are
        # expected (the same defect, judged against the same capture), but a VALUE finding whose number IS the held
        # price says the last verified price is wrong too, and that must not publish: hold.
        $ce = $cov[$k]
        if ([string]$ce.action -eq 'last-good' -and [string]$f.kind -ne 'selection' -and $null -ne $f.bad_per_unit -and [math]::Abs([double]$f.bad_per_unit - [double]$ce.per_unit) -lt 0.00005) {
          [void]$hold.Add('a guard condemns the HELD value itself on ' + $k + ' (' + [string]$ce.per_unit + '), so the last verified price is not safe to show either: ' + [string]$f.message)
        }
        continue
      }
      if (-not $counts.keys.ContainsKey($k)) { [void]$hold.Add('could not be scoped to a published cell (' + $k + ' is not a priced cell on this board): ' + [string]$f.message); continue }
      if (-not $cells.Contains($k)) { $cells[$k] = [pscustomobject]@{ id = [string]$f.id; store = [string]$f.store; kind = 'selection'; bad_per_unit = $null; bad_item = ''; reasons = (New-Object System.Collections.ArrayList) } }
      $c = $cells[$k]
      if ([string]$f.kind -ne 'selection') { $c.kind = 'value' }   # a value finding outranks a selection finding
      if ($null -ne $f.bad_per_unit -and $null -eq $c.bad_per_unit) { $c.bad_per_unit = [double]$f.bad_per_unit }
      if ([string]$f.bad_item -and -not $c.bad_item) { $c.bad_item = [string]$f.bad_item }
      if ($c.reasons -notcontains [string]$f.message) { [void]$c.reasons.Add([string]$f.message) }
    } elseif ($fam -eq 'store') {
      $st = [string]$f.store
      if (-not $st) { [void]$hold.Add('a store-scoped failure named no store: ' + [string]$f.message); continue }
      if ($covSt.ContainsKey($st)) { continue }
      if (-not $stores.Contains($st)) { $stores[$st] = [pscustomobject]@{ store = $st; reasons = (New-Object System.Collections.ArrayList) } }
      if ($stores[$st].reasons -notcontains [string]$f.message) { [void]$stores[$st].reasons.Add([string]$f.message) }
    } elseif ($fam -eq 'board') {
      [void]$hold.Add('board-scoped: ' + [string]$f.message)
    } else { throw ("unknown guard failure family '" + $fam + "': " + [string]$f.message) }
  }
  if ($blk.present -and -not $blk.ok) { foreach ($p in @($blk.problems)) { [void]$hold.Add('the applied quarantine does not hold on this board: ' + $p) } }
  if ($blk.present -and ($cells.Count -gt 0 -or $stores.Count -gt 0)) {
    [void]$hold.Add('a scoped failure appeared on a board that is ALREADY quarantined (' + ((@($cells.Keys) + @($stores.Keys)) -join ', ') + ') - a quarantine is applied once per build, so this holds')
  }
  if ($blk.present) { $cellKeys = @(@($blk.cells) | ForEach-Object { [string]$_.id + '|' + [string]$_.store }) }
  else { $cellKeys = @($cells.Keys) }
  $br = Test-TcQuarantineBreaker -CellKeys $cellKeys -Counts $counts -ExtraPerStore $blk.withheldPerStore
  if ($br.tripped) { [void]$hold.Add('CIRCUIT BREAKER: ' + $br.why + ' - that many bad cells is a systemic defect, not a few bad items') }
  $action = 'pass'
  if ($hold.Count -gt 0) { $action = 'hold' }
  elseif (-not $blk.present -and ($cells.Count -gt 0 -or $stores.Count -gt 0)) { $action = 'quarantine' }
  elseif ($blk.present -and (@($blk.cells).Count + @($blk.stores).Count) -gt 0) { $action = 'quarantined' }
  return [pscustomobject]@{ action = $action; reasons = $hold.ToArray(); cells = @($cells.Values); stores = @($stores.Values); breaker = $br; block = $blk; priced = $counts.total }
}

function Get-TcGuardsExitCode([string]$Action) {
  if ($Action -eq 'pass') { return 0 }
  if ($Action -eq 'quarantined') { return 4 }
  if ($Action -eq 'quarantine' -or $Action -eq 'hold') { return 2 }
  throw "unknown guards disposition: $Action"
}

function Get-TcGuardsVerdictLines($Disposition, [int]$FailCount) {
  # The words each tier prints. The HOLD and PASS lines are byte-identical to what guards printed before this file
  # existed, because readers and fixtures match them.
  $lines = New-Object System.Collections.ArrayList
  $a = [string]$Disposition.action
  if ($a -eq 'hold') {
    foreach ($r in @($Disposition.reasons)) { if (-not ([string]$r).StartsWith('board-scoped: ', [StringComparison]::Ordinal)) { [void]$lines.Add('  HOLD  ' + $r) } }
    [void]$lines.Add(("GUARDS FAILED: {0} hard invariant(s) violated. Board NOT safe to publish." -f $FailCount))
  } elseif ($a -eq 'quarantine') {
    foreach ($c in @($Disposition.cells)) { [void]$lines.Add(("  QUARANTINE  {0} / {1} [{2}]  {3}" -f $c.id, $c.store, $c.kind, (@($c.reasons) -join ' || '))) }
    foreach ($s in @($Disposition.stores)) { [void]$lines.Add(("  DROP STORE  {0}  {1}" -f $s.store, (@($s.reasons) -join ' || '))) }
    [void]$lines.Add(("GUARDS QUARANTINE-REQUIRED: {0} hard failure(s), every one scoped to {1} cell(s) and {2} store(s), under the circuit breaker ({3} of {4} priced cells). The board AS IT STANDS is not safe to publish: apply-cell-quarantine.ps1 holds those cells at their last verified published price, then guards runs again." -f $FailCount, @($Disposition.cells).Count, @($Disposition.stores).Count, $Disposition.breaker.quarantined, $Disposition.breaker.priced))
  } elseif ($a -eq 'quarantined') {
    $held = 0; $wh = 0
    foreach ($e in @($Disposition.block.cells)) {
      if ([string]$e.action -eq 'last-good') { $held++; [void]$lines.Add(("  QUARANTINED  {0} / {1}  held at {2} (last verified published {3})  - {4}" -f $e.id, $e.store, $e.per_unit, $e.since, (@($e.reasons) -join ' || '))) }
      else { $wh++; [void]$lines.Add(("  QUARANTINED  {0} / {1}  WITHHELD ({2})  - {3}" -f $e.id, $e.store, $e.why, (@($e.reasons) -join ' || '))) }
    }
    foreach ($s in @($Disposition.block.stores)) { [void]$lines.Add(("  DROPPED     {0}  {1} everyday cell(s) withheld - {2}" -f $s.store, $s.cells, (@($s.reasons) -join ' || '))) }
    [void]$lines.Add(("GUARDS QUARANTINED: {0} cell(s) held at their last verified published price, {1} withheld, {2} store(s) dropped - each verified on this board, and every other hard invariant holds. Safe to publish." -f $held, $wh, @($Disposition.block.stores).Count))
  } else { [void]$lines.Add('GUARDS OK: every hard invariant holds. Safe to publish.') }
  return [pscustomobject]@{ code = (Get-TcGuardsExitCode $a); lines = $lines.ToArray() }
}

function Write-TcQuarantinePlan([string]$OutDir, $Disposition, [string]$BoardPath) {
  # out\cell-quarantine.json: what guards decided about THIS board file, pinned to its bytes. The applier refuses a
  # plan whose board has changed since - a quarantine is only ever applied to the board guards actually saw.
  $sha = ''; if ($BoardPath -and (Test-Path -LiteralPath $BoardPath)) { $sha = (Get-FileHash -LiteralPath $BoardPath -Algorithm SHA256).Hash.ToLower() }
  $doc = [ordered]@{
    generated = (Get-Date).ToString('s'); written_by = 'guards.ps1'
    board_file = $(if ($BoardPath) { Split-Path $BoardPath -Leaf } else { '' }); board_sha256 = $sha
    action = [string]$Disposition.action; exit_code = (Get-TcGuardsExitCode ([string]$Disposition.action))
    reasons = @($Disposition.reasons)
    cells = @(@($Disposition.cells) | ForEach-Object { [ordered]@{ id = $_.id; store = $_.store; kind = $_.kind; bad_per_unit = $_.bad_per_unit; bad_item = $_.bad_item; reasons = @($_.reasons) } })
    stores = @(@($Disposition.stores) | ForEach-Object { [ordered]@{ store = $_.store; reasons = @($_.reasons) } })
    breaker = $Disposition.breaker
    note = 'Written by every guards run. action: pass | quarantine (required: run apply-cell-quarantine.ps1, then guards again) | quarantined (applied and verified) | hold. See grocery\cell-quarantine-lib.ps1.'
  }
  $path = Join-Path $OutDir 'cell-quarantine.json'
  ($doc | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding UTF8
  return $path
}

function Get-TcLastPublishedCells($BoardDoc, [string]$PublishedDate) {
  # id|store -> the value the LAST PUBLISHED board showed for that cell, read from its structured __rows twin:
  #   __rows[id] = { u, p: [[storeIx, perUnit, flags, label], ...], x: [...], q: [[storeIx, 'yyyy-MM-dd'], ...] }
  # flags: 1 sale, 2 membership, 4 bulk. q (added 2026-09-21) lists cells that board was itself holding at a last
  # verified price, with the date that price was verified, so the date is carried rather than refreshed.
  $cells = @{}
  $stores = @()
  if ($BoardDoc -and $BoardDoc.PSObject.Properties['__meta'] -and $BoardDoc.__meta) { $stores = @($BoardDoc.__meta.stores) }
  $rowsP = $null; if ($BoardDoc) { $rowsP = $BoardDoc.PSObject.Properties['__rows'] }
  if ($null -eq $rowsP -or $null -eq $rowsP.Value -or $stores.Count -eq 0) { return [pscustomobject]@{ cells = $cells; stores = $stores; n = 0 } }
  $n = 0
  foreach ($rp in $rowsP.Value.PSObject.Properties) {
    $id = [string]$rp.Name
    if ($id.EndsWith('::r', [StringComparison]::Ordinal)) { continue }   # recipe-only rows: the quarantine is over the staple board
    $v = $rp.Value
    $carried = @{}
    if ($v.PSObject.Properties['q']) { foreach ($qe in @($v.q)) { $qa = @($qe); if ($qa.Count -ge 2) { $carried[[int]$qa[0]] = [string]$qa[1] } } }
    foreach ($pe in @($v.p)) {
      $pa = @($pe); if ($pa.Count -lt 3) { continue }
      $ix = [int]$pa[0]; if ($ix -lt 0 -or $ix -ge $stores.Count) { continue }
      $isCarried = $carried.ContainsKey($ix)
      $date = $PublishedDate; if ($isCarried) { $date = $carried[$ix] }
      $label = ''; if ($pa.Count -ge 4) { $label = [string]$pa[3] }
      $cells[$id + '|' + [string]$stores[$ix]] = [pscustomobject]@{ per_unit = [double]$pa[1]; flags = [int]$pa[2]; label = $label; date = $date; carried = $isCarried }
      $n++
    }
  }
  return [pscustomobject]@{ cells = $cells; stores = $stores; n = $n }
}

function Invoke-TcGitBytes([string]$Repo, [string[]]$GitArgs) {
  # Raw bytes off git's stdout. PowerShell's own capture decodes a native child with the console codepage, which
  # would mangle every cent sign in the published labels; this reads the stream undecoded.
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = 'git'
  $psi.Arguments = ((@('-C', ('"' + $Repo + '"')) + @($GitArgs)) -join ' ')
  $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
  $pr = New-Object Diagnostics.Process; $pr.StartInfo = $psi
  [void]$pr.Start()
  $errTask = $pr.StandardError.ReadToEndAsync()
  $ms = New-Object IO.MemoryStream
  $pr.StandardOutput.BaseStream.CopyTo($ms)
  $pr.WaitForExit()
  $null = $errTask.Result
  return [pscustomobject]@{ rc = $pr.ExitCode; bytes = $ms.ToArray() }
}

function Read-TcLastPublishedBoard([string]$Repo) {
  # THE TRUE RECORD OF WHAT WAS LAST LIVE: public\board.json as committed on origin/main. Committing that file IS the
  # feed deploy, so origin/main's copy is what the Worker serves; a local HEAD can hold a commit nobody pushed. HEAD is
  # the fallback only when origin/main cannot be read. Returns $null when neither can: then every quarantined cell is
  # WITHHELD, because a value nobody can show was published is a value we would be inventing.
  foreach ($rev in @('origin/main', 'HEAD')) {
    $b = Invoke-TcGitBytes -Repo $Repo -GitArgs @('show', ($rev + ':public/board.json'))
    if ($b.rc -ne 0 -or $b.bytes.Length -eq 0) { continue }
    $txt = [Text.Encoding]::UTF8.GetString($b.bytes)
    if ($txt.Length -gt 0 -and $txt[0] -eq [char]0xFEFF) { $txt = $txt.Substring(1) }
    $doc = $null; try { $doc = $txt | ConvertFrom-Json } catch { continue }
    $dl = Invoke-TcGitBytes -Repo $Repo -GitArgs @('log', '-1', '--format=%cs', $rev, '--', 'public/board.json')
    $date = ([Text.Encoding]::UTF8.GetString($dl.bytes)).Trim()
    if ($null -eq (ConvertTo-TcDay $date)) { continue }
    $sha = Invoke-TcGitBytes -Repo $Repo -GitArgs @('log', '-1', '--format=%h', $rev, '--', 'public/board.json')
    $lp = Get-TcLastPublishedCells -BoardDoc $doc -PublishedDate $date
    return [pscustomobject]@{ cells = $lp.cells; n = $lp.n; source = ($rev + ':public/board.json'); commit = ([Text.Encoding]::UTF8.GetString($sha.bytes)).Trim(); date = $date }
  }
  return $null
}

function Update-TcRowWinners($Row) {
  # The row's cheapest/nomem winners, recomputed after a cell's per-unit moved or a cell left the row. ONE copy:
  # build-deals-page's pin overrides call this too, so a pinned row and a quarantined row are ranked the same way.
  $live = @(@($Row.stores) | Where-Object { $null -ne $_ -and [double]$_.per_unit -gt 0 })
  if ($live.Count -eq 0) { return }
  $w = $live | Sort-Object { [double]$_.per_unit } | Select-Object -First 1
  if ($Row.PSObject.Properties.Name -contains 'cheapest_price') { $Row.cheapest_price = [double]$w.per_unit; $Row.cheapest_store = [string]$w.store; if ($Row.PSObject.Properties.Name -contains 'cheapest_type') { $Row.cheapest_type = [string]$w.type } }
  if ($Row.PSObject.Properties.Name -contains 'nomem_price') {
    $nm = @($live | Where-Object { -not $_.membership }) | Sort-Object { [double]$_.per_unit } | Select-Object -First 1
    if ($nm) { $Row.nomem_price = [double]$nm.per_unit; $Row.nomem_store = [string]$nm.store; if ($Row.PSObject.Properties.Name -contains 'nomem_type') { $Row.nomem_type = [string]$nm.type } }
  }
}

function Invoke-TcCellQuarantine {
  # Applies a guards plan to a board IN MEMORY. The caller writes the board only when .ok is true, so a refusal can
  # never leave a half-quarantined board on disk.
  param($Board, $Plan, $LastPublished, [string]$Today, [int]$MaxAgeDays)
  $res = [pscustomobject]@{ ok = $false; refusal = ''; cells = @(); stores = @() }
  $todayD = ConvertTo-TcDay $Today
  if ($null -eq $todayD) { $res.refusal = "no usable date for today ('$Today')"; return $res }
  if ($MaxAgeDays -le 0) { $res.refusal = 'the board carries no max_publish_age_days, so no last value can be proven inside the publish window'; return $res }
  $byId = @{}; foreach ($r in @($Board.comparison)) { if ($r) { $byId[[string]$r.id] = $r } }
  $touched = @{}
  $entries = New-Object System.Collections.ArrayList
  foreach ($c in @($Plan.cells)) {
    if ($null -eq $c) { continue }
    $id = [string]$c.id; $st = [string]$c.store
    if (-not $byId.ContainsKey($id)) { $res.refusal = "the plan names $id / $st but the board has no row $id"; return $res }
    $row = $byId[$id]
    $cell = $null; foreach ($s in @($row.stores)) { if ($s -and [string]$s.store -eq $st) { $cell = $s; break } }
    if ($null -eq $cell) { $res.refusal = "the plan names $id / $st but that row prices nothing at $st"; return $res }
    $candPu = [double]$cell.per_unit
    $condemned = $candPu; if ($null -ne $c.bad_per_unit -and [string]$c.bad_per_unit -ne '') { $condemned = [double]$c.bad_per_unit }
    $kind = 'value'; if ([string]$c.kind -eq 'selection') { $kind = 'selection' }
    $reasons = @(@($c.reasons) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $lp = $null; if ($LastPublished -and $LastPublished.cells -and $LastPublished.cells.ContainsKey($id + '|' + $st)) { $lp = $LastPublished.cells[$id + '|' + $st] }
    $why = ''
    if ($null -eq $lp) { $why = 'no previously published value for this cell' }
    elseif ([double]$lp.per_unit -le 0) { $why = 'the previously published value is not a price' }
    elseif (([int]$lp.flags -band 1) -ne 0) { $why = 'the previously published value was a sale, and the published board carries no end date for it' }
    else {
      $lpD = ConvertTo-TcDay ([string]$lp.date)
      if ($null -eq $lpD) { $why = 'the previously published value carries no date' }
      else {
        $age = [int](($todayD - $lpD).TotalDays)
        if ($age -gt $MaxAgeDays) { $why = ("the previously published value is {0} days old, past the {1}-day publish window" -f $age, $MaxAgeDays) }
        elseif ($kind -eq 'value' -and [math]::Abs([double]$lp.per_unit - $condemned) -lt 0.00005) { $why = 'the previously published value IS the value this guard condemned' }
      }
    }
    if ($why) {
      $row.stores = @(@($row.stores) | Where-Object { $_ -and [string]$_.store -ne $st })
      if (@(@($row.stores) | Where-Object { [double]$_.per_unit -gt 0 }).Count -eq 0) { $res.refusal = "withholding $id / $st would leave $id with no priced store at all, and recipes cost from that row - hold the board instead"; return $res }
      [void]$entries.Add([pscustomobject]@{ id = $id; store = $st; action = 'withheld'; why = $why; per_unit = $null; since = ''; kind = $kind; bad_per_unit = $candPu; bad_item = [string]$cell.item; reasons = $reasons })
    } else {
      $same = ([math]::Abs([double]$lp.per_unit - $candPu) -lt 0.00005)
      $badItem = [string]$cell.item
      $cell.per_unit = [math]::Round([double]$lp.per_unit, 4)
      Set-TcCellField $cell 'type' 'everyday'
      if (-not $same) {
        # A DIFFERENT NUMBER MEANS THE ROW'S PRODUCT FIELDS NO LONGER DESCRIBE THE PRICE SHOWN. They are blanked, not
        # kept: a package price paired with a per-unit it does not produce is a price nobody observed.
        foreach ($f in @('item', 'ad', 'size', 'basis', 'ad_from', 'ad_to', 'ad_basis', 'as_of')) { if ($cell.PSObject.Properties[$f]) { $cell.$f = '' } }
        foreach ($f in @('native_unit_price', 'native_unit')) { if ($cell.PSObject.Properties[$f]) { $cell.$f = $null } }
        Set-TcCellField $cell 'membership' ([bool](([int]$lp.flags -band 2) -ne 0))
        Set-TcCellField $cell 'bulk' ([bool](([int]$lp.flags -band 4) -ne 0))
        Set-TcCellField $cell 'source_ad' 'last verified published price'
      }
      Set-TcCellField $cell 'quarantine' ([pscustomobject]@{ since = [string]$lp.date; kind = $kind; bad_per_unit = $candPu; bad_item = $badItem; reasons = $reasons })
      [void]$entries.Add([pscustomobject]@{ id = $id; store = $st; action = 'last-good'; why = ''; per_unit = $cell.per_unit; since = [string]$lp.date; kind = $kind; bad_per_unit = $candPu; bad_item = $badItem; reasons = $reasons })
    }
    $touched[$id] = $row
  }
  $storeEntries = New-Object System.Collections.ArrayList
  foreach ($sp in @($Plan.stores)) {
    if ($null -eq $sp) { continue }
    $st = [string]$sp.store; $gone = 0
    foreach ($r in @($Board.comparison)) {
      if ($null -eq $r) { continue }
      $drop = @(@($r.stores) | Where-Object { $_ -and [string]$_.store -eq $st -and [string]$_.type -ne 'sale' })
      if ($drop.Count -eq 0) { continue }
      $r.stores = @(@($r.stores) | Where-Object { $_ -and -not ([string]$_.store -eq $st -and [string]$_.type -ne 'sale') })
      if (@(@($r.stores) | Where-Object { [double]$_.per_unit -gt 0 }).Count -eq 0) { $res.refusal = "dropping $st's everyday prices would leave $([string]$r.id) with no priced store at all - hold the board instead"; return $res }
      $gone += $drop.Count; $touched[[string]$r.id] = $r
    }
    [void]$storeEntries.Add([pscustomobject]@{ store = $st; action = 'dropped-everyday'; cells = $gone; reasons = @(@($sp.reasons) | Where-Object { $_ } | ForEach-Object { [string]$_ }) })
  }
  foreach ($r in $touched.Values) { Update-TcRowWinners $r }
  $src = $null; if ($LastPublished) { $src = [pscustomobject]@{ source = [string]$LastPublished.source; commit = [string]$LastPublished.commit; date = [string]$LastPublished.date } }
  $block = [pscustomobject]@{
    applied_at = (Get-Date).ToString('s'); applied_by = 'apply-cell-quarantine.ps1'
    rule = 'A bad cell quarantines itself and a bad store drops itself (Brad, 2026-09-21). Ruling Q1 = A: a quarantined cell shows its last verified published price with that price''s date; with no such value it is withheld.'
    last_published = $src; cells = $entries.ToArray(); stores = $storeEntries.ToArray()
  }
  Set-TcCellField $Board 'quarantine' $block
  $res.ok = $true; $res.cells = $entries.ToArray(); $res.stores = $storeEntries.ToArray()
  return $res
}
