<#
  rebid-ingredient.ps1 - re-point ONE db\ingredients.json item at a different board commodity, and carry the
  same change into every db\recipes spec that costs it.

  WHY THIS EXISTS (2026-08-09): the recipe and weekly boards spell 33 shared commodities differently, and
  recipe-floor-id-map.json settles which pairs are the same thing. When the 08-08 cross-board de-dup dropped
  the recipe row, export-feed could alias the 30 pairs that share a unit - but a pair whose unit genuinely
  differs (apple priced 'each' against apples priced 'lb') cannot be aliased, because grams_per_unit is
  expressed in the served row's unit and aliasing across units serves a WRONG price instead of no price.
  Those have to move basis for real, in the db AND in the specs, which is what this does.

  A BID IS THREE FIELDS, NOT ONE. bid, unit and gpu only mean anything together: gpu is "grams in one unit
  of the priced basis", so moving 'each' (175 g per apple) to 'lb' without moving gpu to 453.592 leaves the
  item quoting a price 2.6x wrong while every guard reads green. This script refuses to move one without the
  others. See the estate memo on re-anchoring a pair.

  PROSE-SAFE. Targeted, object-scoped regex edits only - it NEVER re-serializes a spec, because the prose
  carries \uXXXX escapes that a ConvertTo-Json round trip would rewrite. Every file is parse-verified before
  it is written, and written BOM-less.

  A BID DOES NOT IDENTIFY AN ITEM (2026-08-16). Until this date the spec sweep selected blocks by matching
  "bid": "<the old bid>", on the assumption that one bid means one item. It does not: 14 bids in
  db\ingredients.json are shared by 2 or more rows (pasta by five; frozen-chopped-spinach by BOTH 'Spinach'
  and 'Frozen Chopped Spinach'; eggs by 'Eggs' and 'Egg Yolk'). Rebidding 'Spinach' from frozen to fresh
  would therefore have moved all 27 spinach recipes - including the 22 that say "thaw it and squeeze it
  dry" - onto a fresh-leaf price. The blast radius exceeded the item by 4.4x and every guard would have
  read green, because each rewritten block was individually well-formed.

  Blocks are now selected by IDENTITY: a block is rewritten only when its 'canon' (or, on the older specs
  that carry no canon, its 'item') is the row's name or one of the row's aliases. A block carrying the old
  bid whose identity is some OTHER row is listed as skipped, never touched; a block that carries neither
  canon nor item cannot be identified and REFUSES the whole run. Positive identification or nothing - the
  same rule the vocabulary plan applies to names.

  -FromBid overrides which bid to sweep for, for the case where the row has already been pointed at its new
  commodity (a fresh row added beside the frozen one) and the SPECS are what still carry the old basis.

  AFTER RUNNING, the cost basis has moved, so the rest of the chain must follow:
    engine\cost-recipes.ps1 -> pipeline\compute-v2-perserving.ps1 -> pipeline\regenerate-ingredient-map.ps1
    -> pipeline\reanchor-machine-fields.ps1 -Slugs <the touched slugs>   (display numbers)
    -> pipeline\db-build.ps1 + pipeline\audit-schema-constraints.ps1     (the FK that caught this class)
    -> grocery\export-feed.ps1, then republish the touched cards.

  AND IT INVALIDATES THE IDENTITY CACHE (2026-08-25, PLAN-ingredient-memory D2 / section 4.3). The
  header of db\ingredient-resolutions.json has always carried this rule -

      "_rule": "Invalidated by any registrar ruling that changes a commodity id."

  - and the mechanism to honour it (ingredient-resolutions.ps1 -Invalidate) was built, fixtured and
  had ZERO callers. This script is the estate's one sanctioned way to change which commodity id an
  ingredient points at, so it is where that rule belongs: after a successful -Apply that MOVES the
  bid, every cached resolution pointing at the OLD id is dropped, and an `invalidate` event records
  it. Without that, the very next map dispatch reads the stale row off the ladder's FIRST rung and
  re-derives the basis this script just spent a run correcting.

  BEST EFFORT, NEVER BLOCKING, NEVER SILENT. A rebid must not fail because a memory layer did; but a
  skipped invalidation is announced with the reason, because a cache nobody was told is stale is
  worse than no cache.

  Usage:
    rebid-ingredient.ps1 -Item 'Apple' -ToBid apples -ToUnit lb -ToGpu 453.592 -BuyPkgG 453.592 -BuyPkgLabel lb
    rebid-ingredient.ps1 -Item 'Apple' ... -Apply        (without -Apply it reports and writes nothing)
    rebid-ingredient.ps1 -SelfTest
#>
param(
  [string]$Item = '',
  [string]$ToBid = '',
  [string]$ToUnit = '',
  [double]$ToGpu = 0,
  [string]$FromBid = '',
  [double]$BuyPkgG = -1,
  [string]$BuyPkgLabel = '',
  [switch]$Apply,
  [switch]$SelfTest,
  # Scratch seams for the drill, the -Store idiom ingredient-resolutions.ps1 already carries. Empty
  # means the live ledger and the live event log, which is what a real rebid wants.
  [string]$ResolutionsStore = '',
  [string]$EventsFile = ''
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp   = Split-Path -Parent $here
$repo = Split-Path -Parent $mp

function Die([string]$s) { Write-Output ('rebid-ingredient: ' + $s); exit 1 }

# Which ingredient row does one scaler.ing block belong to? 'canon' is the resolved row name and is
# authoritative when present; ~36% of blocks (the pre-canon r300 era) carry only 'item', which on those
# specs IS the row name. Returns '' when the block declares neither, which is a refusal, not a default.
function Get-BlockIdentity([string]$block) {
  $c = ([regex]::Match($block, '"canon":\s*"([^"]*)"')).Groups[1].Value
  if ($c) { return $c }
  return ([regex]::Match($block, '"item":\s*"([^"]*)"')).Groups[1].Value
}

# The Windows Store python.exe on PATH is a stub that exits 49 without running anything, so the
# interpreter is always an absolute resolved path - never a bare `python`. Same list scorecard.ps1 uses.
function Get-MemoryPython {
  foreach ($c in @('C:\Codex\Python312\python.exe',
                   "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
                   'C:\Program Files\Python312\python.exe')) {
    if (Test-Path $c) { return $c }
  }
  return $null
}

function Invoke-MemoryInvalidation {
  <#
    .SYNOPSIS  Drop every cached resolution pointing at $OldBid, and record that we did. Returns
               @{ Ran; Invalidated; Why }.
    .DESCRIPTION
      THE _rule ON db\ingredient-resolutions.json, ENFORCED. That file is consulted as step 1 of
      map-preresolve's per-line ladder on EVERY recipe, before the vocabulary and before the board.
      A rebid that moves 'Apple' from `apples` to `apple-each` and leaves the cached row behind means
      the next dispatch to see the word "apple" is handed the id this run just decided was wrong -
      and handed it as a PRIOR RULING, which is the most authoritative rung there is.

      A NO-OP WHEN THE BID DID NOT MOVE, and that matters: -FromBid exists precisely for the case
      where the ingredients row already bids the new id and only the SPECS carry the old basis. There
      is no stale identity in that case, and invalidating anyway would throw away 27 good rows to fix
      a spec sweep.

      BEST EFFORT WITH A VISIBLE WARNING. The rebid has already been applied to disk by the time this
      runs; refusing to return would leave the estate half-moved. So every failure is a warning that
      names itself and a Ran=$false, never a throw and never silence.
  #>
  param([string]$OldBid, [string]$NewBid, [string]$Store = '', [string]$Events = '',
        [string]$Slug = '', [string]$Reason = '')
  $out = [pscustomobject]@{ Ran = $false; Invalidated = 0; Why = '' }
  if (-not $OldBid) { $out.Why = 'no previous bid to invalidate'; return $out }
  if ($OldBid -eq $NewBid) { $out.Why = 'the bid did not move - nothing cached is stale'; return $out }

  $irPs = Join-Path $here 'ingredient-resolutions.ps1'
  if (-not (Test-Path $irPs)) { $out.Why = "no ingredient-resolutions.ps1 at $irPs"; return $out }
  $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $irPs, '-Invalidate', '-ItemId', $OldBid)
  if ($Store) { $psArgs += @('-Store', $Store) }
  # No 2>&1 on a native call: redirecting a child's stderr under EAP=Stop makes its first line a
  # terminating throw. The estate has paid for that trap once already.
  $said = @()
  try { $said = @(& powershell @psArgs) } catch { $out.Why = $_.Exception.Message; return $out }
  if ($LASTEXITCODE -ne 0) {
    $out.Why = ("ingredient-resolutions -Invalidate exited {0}: {1}" -f $LASTEXITCODE, (($said | Select-Object -Last 1) -join ''))
    return $out
  }
  $out.Ran = $true
  $m = [regex]::Match(($said -join ' '), 'invalidated\s+(\d+)\s+row')
  if ($m.Success) { $out.Invalidated = [int]$m.Groups[1].Value }

  # THE EVENT. An invalidation that leaves no trace is the same sin as a veto that leaves none: a
  # week later the only way to explain why a cached identity vanished is a line in this log.
  $py = Get-MemoryPython
  if (-not $py) { $out.Why = 'no python interpreter for the event log (the event was NOT written)'; return $out }
  $la = Join-Path $here 'learn_apply.py'
  if (-not (Test-Path $la)) { $out.Why = "no learn_apply.py at $la (the event was NOT written)"; return $out }
  $ev = [ordered]@{
    kind = 'invalidate'; slug = $Slug; run = 'rebid-ingredient'; term = ''; key = ''
    decision = 'invalidate'; bid = $NewBid; projected = $false; surprise = $true
    held_reason = 'an invalidation removes rows, it never records one'; by = 'registrar'
    evidence = ("rebid moved '{0}' from '{1}' to '{2}'; {3} cached resolution(s) on the old id were dropped. {4}" -f $Item, $OldBid, $NewBid, $out.Invalidated, $Reason)
  }
  # THROUGH A FILE, NOT AN ARGV STRING. A JSON object on a command line is one quoting accident away
  # from a truncated event, and this estate has a name for that class.
  $tmpEv = Join-Path $env:TEMP ('ie-' + [guid]::NewGuid().ToString('N') + '.json')
  try {
    ($ev | ConvertTo-Json -Depth 4 -Compress) | Set-Content -Path $tmpEv -Encoding utf8
    $eargs = @($la, '--append-event', $tmpEv)
    if ($Events) { $eargs += @('--events', $Events) }
    $said2 = @(& $py @eargs)
    if ($LASTEXITCODE -ne 0) {
      $out.Why = ("learn_apply --append-event exited {0}: {1}" -f $LASTEXITCODE, (($said2 | Select-Object -Last 1) -join ''))
    }
  } catch { $out.Why = $_.Exception.Message }
  finally { if (Test-Path $tmpEv) { Remove-Item $tmpEv -Force -ErrorAction SilentlyContinue } }
  return $out
}

if ($SelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  $withCanon = '{"item":"Baby Spinach","canon":"Spinach","grams":397,"bid":"frozen-chopped-spinach","gpu":"28.350"}'
  $noCanon   = '{"item":"Spinach","grams":200,"bid":"frozen-chopped-spinach","gpu":"28.350"}'
  $frozen    = '{"item":"Frozen Chopped Spinach","grams":595,"bid":"frozen-chopped-spinach","gpu":"28.350"}'
  $blankBoth = '{"grams":100,"bid":"frozen-chopped-spinach","gpu":"28.350"}'
  T 'canon wins over item when both are present'   ((Get-BlockIdentity $withCanon) -eq 'Spinach')            (Get-BlockIdentity $withCanon)
  T 'item stands in when canon is absent'          ((Get-BlockIdentity $noCanon)   -eq 'Spinach')            (Get-BlockIdentity $noCanon)
  T 'a sibling row on the same bid reads as itself' ((Get-BlockIdentity $frozen)   -eq 'Frozen Chopped Spinach') (Get-BlockIdentity $frozen)
  # MUST FIRE: the whole point. Same bid, different item - selecting on bid alone would sweep this one in.
  T 'MUST FIRE  sibling identity is NOT the target' ((Get-BlockIdentity $frozen)   -ne 'Spinach')            (Get-BlockIdentity $frozen)
  T 'MUST FIRE  an unidentifiable block returns empty' ((Get-BlockIdentity $blankBoth) -eq '')               '(empty)'

  # ---------------------------------------------------------------------------------------------
  # THE IDENTITY-CACHE INVALIDATION (2026-08-25, PLAN-ingredient-memory 4.3).
  #
  # Against a SCRATCH ledger and a SCRATCH event log, through the real ingredient-resolutions.ps1
  # and the real learn_apply.py - the two things that would be broken by a wrong argument are the
  # two things a mocked call could not catch.
  # ---------------------------------------------------------------------------------------------
  $sTmp = Join-Path $env:TEMP ('rebid-mem-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force $sTmp | Out-Null
  try {
    $sStore = Join-Path $sTmp 'ledger.json'
    $sEvents = Join-Path $sTmp 'events.jsonl'
    # THREE ROWS AND NOT TWO: the PS 5.1 collection traps say a fixture over a collection uses at
    # least three elements, and TWO of them share the stale id so a fixture that dropped only the
    # first would still read green.
    $seed = @(
      [pscustomobject]@{ key='apple'; term='Apple'; item_id='apples'; bid_exists=$true; evidence='e'; by='mapper'; at='2026-08-20T00:00:00' },
      [pscustomobject]@{ key='granny smith apple'; term='Granny Smith Apple'; item_id='apples'; bid_exists=$true; evidence='e'; by='mapper'; at='2026-08-20T00:00:00' },
      [pscustomobject]@{ key='pepperoni'; term='Pepperoni'; item_id='turkey-pepperoni'; bid_exists=$true; evidence='e'; by='mapper'; at='2026-08-20T00:00:00' })
    ([pscustomobject]@{ count=3; resolutions=$seed } | ConvertTo-Json -Depth 6) | Set-Content $sStore -Encoding utf8

    $r = Invoke-MemoryInvalidation -OldBid 'apples' -NewBid 'apple-each' -Store $sStore -Events $sEvents -Slug 'drill' -Reason 'fixture'
    $left = @((Get-Content $sStore -Raw -Encoding utf8 | ConvertFrom-Json).resolutions)
    T 'MUST FIRE  a rebid that MOVES the bid drops every cached resolution on the old id' `
      ($r.Ran -and $r.Invalidated -eq 2 -and @($left).Count -eq 1 -and [string]$left[0].key -eq 'pepperoni') `
      ("ran=$($r.Ran) invalidated=$($r.Invalidated) left=" + (@($left | ForEach-Object { [string]$_.key }) -join ','))
    T 'MUST FIRE  and a row on a DIFFERENT id survives - the blast radius is the id, not the file' `
      (@($left | Where-Object { [string]$_.key -eq 'pepperoni' }).Count -eq 1) 'pepperoni gone'
    $evLines = @()
    if (Test-Path $sEvents) { $evLines = @(Get-Content $sEvents | Where-Object { $_.Trim() }) }
    $ev = $null
    if ($evLines.Count -eq 1) { $ev = $evLines[0] | ConvertFrom-Json }
    T 'MUST FIRE  the invalidation leaves exactly one `invalidate` event naming both ids' `
      ($null -ne $ev -and $ev.kind -eq 'invalidate' -and $ev.evidence -match 'apples' -and $ev.evidence -match 'apple-each' -and $ev.surprise -eq $true) `
      ("lines=" + $evLines.Count + " first=" + (($evLines | Select-Object -First 1) -join ''))
    T 'MUST FIRE  and it recorded NO resolution row of its own - an invalidation removes, never adds' `
      ($null -ne $ev -and $ev.projected -eq $false -and [string]$ev.bid -eq 'apple-each') ([string]$ev.projected)

    # CLEAN TWIN: -FromBid's case. The row already bids the new id and only the SPECS carry the old
    # basis, so nothing cached is stale and 27 good rows must not be thrown away to fix a spec sweep.
    ([pscustomobject]@{ count=3; resolutions=$seed } | ConvertTo-Json -Depth 6) | Set-Content $sStore -Encoding utf8
    $sEvents2 = Join-Path $sTmp 'events2.jsonl'
    $r2 = Invoke-MemoryInvalidation -OldBid 'apples' -NewBid 'apples' -Store $sStore -Events $sEvents2
    $left2 = @((Get-Content $sStore -Raw -Encoding utf8 | ConvertFrom-Json).resolutions)
    T 'CLEAN TWIN  a rebid that does NOT move the bid invalidates nothing and writes no event' `
      ((-not $r2.Ran) -and @($left2).Count -eq 3 -and (-not (Test-Path $sEvents2)) -and $r2.Why -match 'did not move') `
      ("ran=$($r2.Ran) left=$(@($left2).Count) why=$($r2.Why)")

    # ---- ADOPTING A FIRST BID (2026-08-29) -------------------------------------------------------
    # The row-edit regex is exercised directly, because the failure it pins was SILENT: `"bid": null`
    # is not a quoted value, so the quoted-bid replace matched nothing, unit/gpu/board moved, the
    # success banner printed, and the bid stayed null. Keto Bun sat in that state waiting on a ruling.
    function Edit-RowBid([string]$RowText, [string]$ToBid) {
      if ($RowText -match '"bid":\s*null') { return [regex]::Replace($RowText, '("bid":\s*)null', ('${1}"' + $ToBid + '"')) }
      return [regex]::Replace($RowText, '("bid":\s*")[^"]*(")', ('${1}' + $ToBid + '${2}'))
    }
    $nullRow = '{"item":"Keto Bun","bid":null,"gpu":50,"unit":"each"}'
    $gotNull = Edit-RowBid $nullRow 'keto-hamburger-buns'
    T 'MUST FIRE  a row carrying "bid": null ADOPTS the new bid, quoted' `
      (([string]($gotNull | ConvertFrom-Json).bid) -eq 'keto-hamburger-buns') ($gotNull)
    T '  ...and the result is still valid JSON with the other fields intact' `
      ((($gotNull | ConvertFrom-Json).gpu -eq 50) -and (($gotNull | ConvertFrom-Json).unit -eq 'each')) ($gotNull)
    # CLEAN TWIN: the ordinary quoted-bid move must be untouched by the null branch.
    $quotedRow = '{"item":"Apple","bid":"apples","gpu":175,"unit":"each"}'
    T 'CLEAN TWIN a quoted bid still re-points the ordinary way' `
      (([string]((Edit-RowBid $quotedRow 'apple-each') | ConvertFrom-Json).bid) -eq 'apple-each') (Edit-RowBid $quotedRow 'apple-each')
    # MUST FIRE: the literal string "null" as a BID is a real id, not the null shape. Guarding the
    # branch on the unquoted token rather than on the word keeps those apart.
    $wordRow = '{"item":"Odd","bid":"null","gpu":1,"unit":"each"}'
    T 'MUST NOT FIRE  a bid whose VALUE is the string "null" is not mistaken for an absent bid' `
      (([string]((Edit-RowBid $wordRow 'real-id') | ConvertFrom-Json).bid) -eq 'real-id') (Edit-RowBid $wordRow 'real-id')

    # MUST FIRE: a failure is VISIBLE. A rebid is never blocked by the memory layer, but a silent
    # skip is forbidden - a cache nobody was told is stale is worse than no cache.
    $r3 = Invoke-MemoryInvalidation -OldBid 'apples' -NewBid 'apple-each' -Store (Join-Path $sTmp 'no-such-dir\ledger.json') -Events $sEvents
    T 'MUST FIRE  an invalidation that could not run says why and does not throw' `
      ((-not $r3.Ran) -and $r3.Why) ("ran=$($r3.Ran) why=$($r3.Why)")

    # THE CALL SITE, pinned by source. The behaviour above is provable in isolation; what a fixture
    # over the function alone CANNOT prove is that the applied path calls it - and twice this estate
    # has watched a neuter come back 0 red for exactly that reason. Driving the real -Apply path
    # would need a whole scratch estate (smp-feed, db\ingredients, db\recipes), so this asserts the
    # cheaper true thing: the invocation exists and sits AFTER the dry-run gate, on the road that
    # only runs once files have been written.
    $src = [IO.File]::ReadAllText($PSCommandPath)
    $gate = $src.IndexOf("if (-not `$Apply) { Write-Output '  DRY RUN")
    # THE FIRST occurrence, not the last, and the COUNT with it. Written as LastIndexOf, this pin
    # came back 0 RED against a neuter that hoisted a SECOND call ABOVE the gate - a dry run would
    # then have wiped the cache for a rebid it never performed, and the fixture would not have
    # noticed. Third time this estate has watched a pin miss a call site.
    # The needle is BUILT rather than written out, or this line would itself be one of the matches.
    $needle = 'Invoke-MemoryInvalidation' + ' -OldBid $row' + 'Bid'
    $calls = @([regex]::Matches($src, [regex]::Escape($needle)))
    $first = -1
    if ($calls.Count) { $first = $calls[0].Index }
    T 'MUST FIRE  the -Apply path calls the invalidation EXACTLY ONCE, after the dry-run gate' `
      ($gate -gt 0 -and $calls.Count -eq 1 -and $first -gt $gate) ("gate=$gate calls=$($calls.Count) first=$first")
  } finally { Remove-Item $sTmp -Recurse -Force -ErrorAction SilentlyContinue }

  if ($bad) { Write-Output ("rebid-ingredient SELF-TEST FAIL ({0})" -f $bad); exit 1 }
  Write-Output 'rebid-ingredient SELF-TEST PASS'; exit 0
}

if (-not $Item)   { Die 'pass -Item <name> (or -SelfTest)' }
if (-not $ToBid)  { Die 'pass -ToBid <commodity id>' }
if (-not $ToUnit) { Die 'pass -ToUnit <unit>' }
if ($ToGpu -le 0) { Die 'pass -ToGpu <grams per one unit of the priced basis>' }

# THE TARGET MUST BE PRICEABLE BEFORE WE POINT AT IT. The whole failure class this script answers is a bid
# that names nothing, so refusing to create a NEW dangling bid is the one check that must never be optional.
$feedPath = Join-Path $repo 'grocery\out\smp-feed.json'
if (-not (Test-Path $feedPath)) { Die "no grocery\out\smp-feed.json - cannot verify that '$ToBid' is priceable" }
$feed = (Get-Content $feedPath -Raw -Encoding utf8 | ConvertFrom-Json).ingredients
$fr = $feed.PSObject.Properties[$ToBid]
if (-not $fr) { Die "'$ToBid' is not in the feed - it would be a dangling bid, which is the bug this script fixes" }
if ([string]$fr.Value.unit -ne $ToUnit) { Die "unit mismatch: feed serves '$ToBid' per '$($fr.Value.unit)', you asked for '$ToUnit'. gpu is expressed in the SERVED unit, so this would price the item wrong." }

$ingPath = Join-Path $mp 'db\ingredients.json'
$raw = [IO.File]::ReadAllText($ingPath)
$rowRx = '\{[^{}]*"item":\s*"' + [regex]::Escape($Item) + '",[^{}]*\}'
$m = [regex]::Match($raw, $rowRx)
if (-not $m.Success) { Die "no db\ingredients.json row for item '$Item' (or the row holds a nested object, which this editor will not touch)" }
$row = $m.Value
$rowBid  = ([regex]::Match($row, '"bid":\s*"([^"]*)"')).Groups[1].Value
$fromBid = if ($FromBid) { $FromBid } else { $rowBid }

# The names this row answers to. A spec's canon may be an adjudicated alias rather than the row's own name
# ('Andouille Smoked Sausage' -> row 'Pork Smoked Sausage'), so aliases are identity too.
$identity = @{}
$identity[$Item] = $true
foreach ($a in [regex]::Matches($row, '"aliases":\s*\[(?<b>[^\]]*)\]') | ForEach-Object { $_.Groups['b'].Value }) {
  foreach ($q in [regex]::Matches($a, '"([^"]*)"')) { $identity[$q.Groups[1].Value] = $true }
}

$new = $row
# ADOPTING A FIRST BID IS THE DEGENERATE RE-POINT, and until 2026-08-29 this script could not do it.
# The replace below only ever matched a QUOTED bid, so a row carrying `"bid": null` - the shape a
# vocabulary row takes while it waits for a product-class ruling - was left silently untouched: the
# unit, gpu and board all moved, the script printed its success banner, and the bid stayed null. That
# is the same class the spec layer had (see repair-missing-scaler-bid.ps1, built the same day): the
# estate could MOVE a bid and could not GIVE one. Keto Bun was the live case - Brad ruled the product
# class, keto-hamburger-buns was minted and priced, and nothing could wire the row to it.
if ($row -match '"bid":\s*null') {
  $new = [regex]::Replace($new, '("bid":\s*)null', ('${1}"' + $ToBid + '"'))
} else {
  $new = [regex]::Replace($new, '("bid":\s*")[^"]*(")',  ('${1}' + $ToBid + '${2}'))
}
$new = [regex]::Replace($new, '("unit":\s*")[^"]*(")', ('${1}' + $ToUnit + '${2}'))
$new = [regex]::Replace($new, '("gpu":\s*)[0-9.]+',    ('${1}' + $ToGpu))
# board names the NAMESPACE the new id lives in - it is not the DIRECTION of the move. The 2026-08-09
# original was written for a recipe->weekly sweep and hardcoded 'weekly' on that run's own assumption.
# A rebid INTO a recipe-namespace id then writes a false fact: 'Light Sour Cream' -> light-sour-cream
# (2026-08-28) is in grocery\recipe-commodities.json and on recipe-board.json, absent from the weekly
# catalog entirely, yet came out labelled weekly. cost-recipes merges every board into one id-keyed
# table so the PRICE was unharmed, but 201 rows use this field as a discriminator. Read the catalogs.
$recipeCat = Join-Path $repo 'grocery\recipe-commodities.json'
$newBoard  = 'weekly'
if ((Test-Path $recipeCat) -and ((Get-Content $recipeCat -Raw) -match ('"' + [regex]::Escape($ToBid) + '"'))) { $newBoard = 'recipe' }
# AND THE RECIPE FLOOR BOARD COUNTS TOO (2026-08-29). recipe-commodities.json is not the whole recipe
# namespace: out\recipe-board-everyday.json carries 184 hand-held rows and only 74 ids are in the
# catalog, so the check above alone calls a recipe-board commodity `weekly`. Measured on live data -
# bulgur-wheat is absent from recipe-commodities.json and its row correctly reads `recipe`, and
# keto-hamburger-buns (minted today onto that board) came out labelled `weekly`, which is precisely
# the false fact the note above this line exists to prevent. Ask both catalogs, not one.
if ($newBoard -eq 'weekly') {
  $floorBoard = Join-Path $repo 'grocery\out\recipe-board-everyday.json'
  if ((Test-Path $floorBoard) -and ((Get-Content $floorBoard -Raw) -match ('"id":\s*"' + [regex]::Escape($ToBid) + '"'))) { $newBoard = 'recipe' }
}
$new = [regex]::Replace($new, '("board":\s*")[^"]*(")', ('${1}' + $newBoard + '${2}'))
if ($BuyPkgG -ge 0)   { $new = [regex]::Replace($new, '("buy_pkg_g":\s*)[0-9.]+', ('${1}' + $BuyPkgG)) }
if ($BuyPkgLabel)     { $new = [regex]::Replace($new, '("buy_pkg_label":\s*")[^"]*(")', ('${1}' + $BuyPkgLabel + '${2}')) }
$rawNew = $raw.Substring(0, $m.Index) + $new + $raw.Substring($m.Index + $m.Length)
$null = $rawNew | ConvertFrom-Json

Write-Output ("rebid-ingredient: '{0}'  bid {1} -> {2}, unit -> {3}, gpu -> {4}" -f $Item, $fromBid, $ToBid, $ToUnit, $ToGpu)
if ($rowBid -eq $ToBid) { Write-Output "  (the row already bids '$ToBid' - this run moves the SPECS only)" }
Write-Output ('  identity: ' + (($identity.Keys | Sort-Object) -join ' | '))

# ---- the specs that cost this item ----
# Candidates carry the old bid; only those whose IDENTITY is this row are rewritten. See the header note.
$specRx = '\{[^{}]*"bid":\s*"' + [regex]::Escape($fromBid) + '"[^{}]*\}'
$touched = New-Object System.Collections.Generic.List[object]
$skipped = New-Object System.Collections.Generic.List[object]
$blind   = New-Object System.Collections.Generic.List[object]
foreach ($sf in (Get-ChildItem (Join-Path $mp 'db\recipes\*.json'))) {
  $sraw = [IO.File]::ReadAllText($sf.FullName)
  $ms = @([regex]::Matches($sraw, $specRx) | Where-Object {
    $who = Get-BlockIdentity $_.Value
    if (-not $who) { $blind.Add(($sf.BaseName + ' (a block on bid ' + $fromBid + ' declares neither canon nor item)')); return $false }
    if (-not $identity.ContainsKey($who)) { $skipped.Add(($sf.BaseName + ' :: ' + $who)); return $false }
    return $true
  })
  if ($ms.Count -eq 0) { continue }
  $out = $sraw; $off = 0
  foreach ($sm in $ms) {
    $blk = $sm.Value
    $nb = [regex]::Replace($blk, '("bid":\s*")[^"]*(")', ('${1}' + $ToBid + '${2}'))
    $nb = [regex]::Replace($nb,  '("gpu":\s*")[^"]*(")', ('${1}' + ('{0:0.000}' -f $ToGpu) + '${2}'))
    $out = $out.Substring(0, $sm.Index + $off) + $nb + $out.Substring($sm.Index + $off + $blk.Length)
    $off += ($nb.Length - $blk.Length)
  }
  $null = $out | ConvertFrom-Json
  $touched.Add([pscustomobject]@{ slug = $sf.BaseName; path = $sf.FullName; text = $out; n = $ms.Count })
}
# An unidentifiable block is the one case with no safe default: leaving it behind splits one item across two
# bases, and sweeping it in is the very over-reach this scoping exists to stop. Refuse and let a human name it.
if ($blind.Count -gt 0) {
  Die ('CANNOT IDENTIFY ' + $blind.Count + ' block(s) carrying bid ' + $fromBid + ' - no canon, no item: ' +
       ((@($blind) | Select-Object -First 5) -join '; ') + '. Nothing written.')
}
Write-Output ("  {0} spec(s) rewritten: {1}" -f $touched.Count, (($touched | ForEach-Object { $_.slug }) -join ', '))
if ($skipped.Count -gt 0) {
  Write-Output ("  {0} block(s) left on '{1}' - they belong to a DIFFERENT row sharing that bid:" -f $skipped.Count, $fromBid)
  foreach ($g in ($skipped | Group-Object { ($_ -split ' :: ')[1] })) {
    Write-Output ('      ' + $g.Name + '  x' + $g.Count)
  }
}

if (-not $Apply) { Write-Output '  DRY RUN - nothing written. Re-run with -Apply.'; exit 0 }
[IO.File]::WriteAllText($ingPath, $rawNew, (New-Object Text.UTF8Encoding($false)))
foreach ($t in $touched) { [IO.File]::WriteAllText($t.path, $t.text, (New-Object Text.UTF8Encoding($false))) }
Write-Output ("  APPLIED to db\ingredients.json + {0} spec(s). Now run cost-recipes -> compute-v2-perserving -> regenerate-ingredient-map -> reanchor-machine-fields -Slugs {1} -> db-build." -f $touched.Count, (($touched | ForEach-Object { $_.slug }) -join ','))

# ---- THE _rule, ENFORCED (2026-08-25, PLAN-ingredient-memory 4.3) ---------------------------------
# The files are on disk, so this can no longer refuse to happen; it can only succeed or say why not.
# `$rowBid` is what the db row bid BEFORE this run, which is the identity the cache may still hold.
# When -FromBid was used because the row already bid the new id, $rowBid -eq $ToBid and this is a
# no-op by construction - nothing cached is stale in that case.
$inv = Invoke-MemoryInvalidation -OldBid $rowBid -NewBid $ToBid -Store $ResolutionsStore -Events $EventsFile -Slug (($touched | ForEach-Object { $_.slug }) -join ',') -Reason 'run the cost chain above before the next map dispatch'
if ($inv.Ran) {
  Write-Output ("  identity cache: invalidated {0} cached resolution(s) on '{1}' - the next map dispatch will not be handed the old id as a prior ruling." -f $inv.Invalidated, $rowBid)
  if ($inv.Why) { Write-Output ("  WARNING  the invalidation ran but its event did not land: " + $inv.Why) }
} else {
  Write-Output ("  identity cache: NOT invalidated - " + $inv.Why)
}
