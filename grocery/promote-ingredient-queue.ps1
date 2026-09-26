<#
  promote-ingredient-queue.ps1 - move Recipe Hunter prices out of the queue and into the engine.

  BRAD, 2026-08-21: "we need to make sure that when we pull pricing, from ANY part of our codebase, its
  populating the table correctly. i believe we habe another routine recipe hunter that has an agent pull
  pricing for missing ingredients" - and then, when it turned out 97 of 99 had reached nothing: "Fix the
  97".

  WHAT WAS WRONG. The Recipe Hunter's pricing agent opens seven Omaha stores, adjudicates which row is
  really the ingredient, and records a real price with a real size via ingredient-queue.ps1 -Record.
  Nothing then moved those prices anywhere. They sat in ingredient-queue.json from 2026-08-16 onward,
  reaching neither the board nor the price table, because compare-deals reads six input classes and the
  queue is not one of them. There was no sanctioned path for a price captured out-of-band to enter the
  engine at all - which is the deeper reason they stranded, and this file is that path.

  IT WRITES INTO out\regular, WHICH IS AN ENGINE INPUT, AND NOT ANYWHERE ELSE. Deliberately not
  extra-deals: that channel is for ad-cycle pricing, is typed `sale` by default, and carries a 7-day
  gate - an everyday shelf price parked there would expire in a week and would publish as a discount it
  is not. And deliberately NOT into a store's own capture file: those are the honest record of what that
  store's puller saw, and merging a different agent's rows into one would destroy that. Each store gets
  its own file under a `hunter-` prefix; the engine keys the store off the file's `store` field, not its
  name, so the prefix is free.

  THE MAPPING IS A RULING, NOT A GUESS. ingredient-queue-map.json says which queue term is which
  commodity, one line each, with the evidence that decided it. This script reads ONLY that file and
  SKIPS anything absent. It does not slugify, fuzzy-match, or infer - because a matcher quietly deciding
  that "Yellow Bell Pepper" is `bell-peppers` on every run is exactly the uncontrolled id assignment the
  commodity registrar exists to prevent, and a careless id splits a commodity that is already priced
  under another name. 21 terms are ruled, 3 are banned by catalog policy (wine x2, ground chicken), and
  17 are held pending a NEW id because the catalog genuinely has no home for them - fresh oregano
  (dried-oregano exists, so fresh/dried IS a boundary here), 90/10 ground beef (the catalog splits by
  lean ratio), and every block cheese (there are no block-cheese ids at all).

  AS_OF IS THE DAY THE AGENT LOOKED, NEVER TODAY. These prices were captured on 2026-08-16. Stamping
  them with the run date would launder a five-day-old observation into a fresh one and defeat every
  staleness rule downstream - `dates written, not measured`, which surfaces as a wrong price.

  Usage:
    promote-ingredient-queue.ps1                 report only, writes nothing
    promote-ingredient-queue.ps1 -Apply          write the per-store files
    promote-ingredient-queue.ps1 -SelfTest       frozen fixtures
  Exit 0 = ran. Exit 2 = self-test regression.
#>
# The self-test runs on frozen in-memory fixtures; it reads neither the queue, the map nor out\.
# gate-inputs: lib\json-io.ps1, lib\guard-contract.ps1
param([switch]$Apply, [switch]$SelfTest, [string]$OutDir = '', [string]$QueueFile = '', [string]$MapFile = '')
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
if (-not $QueueFile) { $QueueFile = Join-Path $root 'ingredient-queue.json' }
if (-not $MapFile) { $MapFile = Join-Path $root 'ingredient-queue-map.json' }
. (Join-Path (Split-Path $root -Parent) 'lib\guard-contract.ps1')

# ---- A PRICE COPIED OFF OUR OWN BOARD IS NOT A STORE READ (2026-09-19, design\PLAN-board-accuracy-2026-09-19.md 4d) --
# FOUNDING BUG: the queue's Fareway 'Green Bell Pepper' $0.77 carried the evidence "price-ingredient tier 1 on today's
# captures (comparison-2026-08-15): ..." - an answer read back off the engine's own board - and -Apply wrote it into
# hunter-fareway-regular-2026-08-16.json as source_ad "in-store verified". The board then priced the cell from itself
# for a month (live shelf $1.17). On the queue as it stood on 2026-09-19, 13 of the 85 promotable rows carry evidence
# of this shape. A row the agent answered from disk never had a store look at it, so it is REFUSED here, named
# SELF-SOURCED and counted, and is re-priced by an agent that opens the store.
# The phrases are the ones the pricing agent actually writes when it answers from our data rather than a store:
#   a board file named as the source (comparison-YYYY-MM-DD), "price-ingredient tier 1", "from the priced board",
#   "board cell is/at" (quoting the board's own cell), and "ruled from disk" / "price-ingredient.ps1 -Name ..."
#   (a capture-file lookup, labelled in-store verified by the writer below). A bare mention of the word "board" is
#   NOT evidence: "should be re-verified before any board cell" (chipotle, a real store probe) must still promote.
# UNSOUND by construction: an agent that answers from the board in words not listed here passes. The list is what the
# 520 priced queue rows actually say on 2026-09-19, and the fixture below pins each spelling.
$script:SELF_SOURCED_EVIDENCE = @(
  '(?i)\bcomparison-\d{4}-\d{2}-\d{2}\b',
  '(?i)\bprice-ingredient(?:\.ps1)?\s+tier\s*1\b',
  '(?i)\bprice-ingredient(?:\.ps1)?\s+-Name\b',
  '(?i)\bprice-ingredient\s+CAPTURE\s+tier\b',
  '(?i)\bfrom\s+the\s+priced\s+board\b',
  '(?i)\bruled\s+from\s+disk\b',
  '(?i)\bboard\s+cell\s+(?:is|at)\b'
)
function Get-SelfSourcedEvidence([string]$Evidence) {
  if (-not $Evidence) { return '' }
  foreach ($rx in $script:SELF_SOURCED_EVIDENCE) {
    $m = [regex]::Match($Evidence, $rx)
    if ($m.Success) { return $m.Value }
  }
  return ''
}

function Get-QueuePromotions {
  <#
    .SYNOPSIS Every (commodity, store, price) the ruling allows to be promoted.
    .DESCRIPTION Pure over parsed documents so the fixtures reach the real decision. A term absent from
                 the map is SKIPPED and counted, never guessed at.
  #>
  param($Queue, $Map)
  $rows = @(); $skipped = @(); $banned = 0; $refused = @()
  foreach ($it in @($Queue.items)) {
    $term = [string]$it.term
    if (-not $it.stores) { continue }
    if ($Map.banned -and $Map.banned.PSObject.Properties[$term]) { $banned++; continue }
    $ruling = $null
    if ($Map.map -and $Map.map.PSObject.Properties[$term]) { $ruling = $Map.map.PSObject.Properties[$term].Value }
    if (-not $ruling -or -not $ruling.id) { $skipped += $term; continue }
    foreach ($p in $it.stores.PSObject.Properties) {
      $s = $p.Value
      if ($null -eq $s -or $null -eq $s.price) { continue }
      # A price with no SIZE cannot be turned into a per-unit number, and a cell that cannot be priced
      # per unit cannot be compared against another store - which is the entire job of the board.
      if (-not [string]$s.size) { continue }
      $self = Get-SelfSourcedEvidence ([string]$s.evidence)
      if ($self) {
        $refused += [pscustomobject]@{ reason = 'SELF-SOURCED'; id = [string]$ruling.id; term = $term; store = [string]$p.Name
                                       price = [double]$s.price; matched = $self }
        continue
      }
      $rows += [pscustomobject]@{
        id = [string]$ruling.id; term = $term; store = [string]$p.Name
        price = [double]$s.price; size = [string]$s.size; item = [string]$s.item
        evidence = [string]$s.evidence
      }
    }
  }
  return [pscustomobject]@{ rows = $rows; skipped = @($skipped | Select-Object -Unique); banned = $banned; refused = $refused }
}

if ($SelfTest) {
  $f = 0
  function T($ok, $m) { if ($ok) { Write-Output "ok    $m" } else { Write-Output "FAIL  $m"; $script:f++ } }
  $q = [pscustomobject]@{ items = @(
    [pscustomobject]@{ term = 'cumin-seeds'; stores = [pscustomobject]@{
      "Baker's" = [pscustomobject]@{ price = 1.69; size = '1 oz'; item = 'Tampico Cumin Whole' }
      'Aldi'    = [pscustomobject]@{ price = $null; size = ''; item = '' } } },
    [pscustomobject]@{ term = 'dry white wine'; stores = [pscustomobject]@{
      "Baker's" = [pscustomobject]@{ price = 8.99; size = '750 ml'; item = 'Pinot Grigio' } } },
    [pscustomobject]@{ term = 'gruyere'; stores = [pscustomobject]@{
      "Baker's" = [pscustomobject]@{ price = 6.99; size = '8 oz'; item = 'Gruyere' } } },
    [pscustomobject]@{ term = 'fennel'; stores = [pscustomobject]@{
      "Baker's" = [pscustomobject]@{ price = 3.99; size = ''; item = 'Fresh Fennel' } } }
  ) }
  $m = [pscustomobject]@{
    map = [pscustomobject]@{ 'cumin-seeds' = [pscustomobject]@{ id = 'cumin-seeds' }; 'fennel' = [pscustomobject]@{ id = 'fennel' } }
    banned = [pscustomobject]@{ 'dry white wine' = 'no wine' }
    pending_new_id = [pscustomobject]@{ 'gruyere' = 'no catalog home' }
  }
  $r = Get-QueuePromotions -Queue $q -Map $m
  T ($r.rows.Count -eq 1 -and $r.rows[0].id -eq 'cumin-seeds') "only the RULED term with a price and a size promotes (got $($r.rows.Count))"
  # MUST FIRE: a term the ruling does not cover must be skipped, never guessed. "gruyere" slugifies to a
  # perfectly plausible id, which is exactly why inferring here would be dangerous.
  T ($r.skipped -contains 'gruyere') 'an UNRULED term is skipped and reported, not slugified into an id'
  T ($r.banned -eq 1) 'a banned term is dropped and counted'
  # A null price is not an observation.
  T (-not (@($r.rows | Where-Object { $_.store -eq 'Aldi' })).Count) 'a null price is not promoted'
  # MUST FIRE: no size means no per-unit price, so the cell could never be compared.
  T (-not (@($r.rows | Where-Object { $_.term -eq 'fennel' })).Count) 'a price with no SIZE is refused - it cannot be made per-unit'

  # ---- SELF-SOURCED (2026-09-19, PLAN-board-accuracy 4d) ------------------------------------------------------------
  # FROZEN, never regenerated: the Fareway green-bell-pepper evidence as ingredient-queue.json carried it when -Apply
  # wrote the $0.77 row (git history of that file), and the store read that later replaced it ($1.17).
  $evBoard = 'price-ingredient tier 1 on today''s captures (comparison-2026-08-15): Fareway ''Green Bell Pepper'' \.77 each, plain fresh produce row, exact ingredient. No adjudication ambiguity.'
  $evStore = 'driver rung 1 ''green bell pepper'', 20 rows: ''Green Bell Pepper'' 1 each $1.17, the plain fresh pepper. The red/orange bells, sweet onion, scallions and cilantro in the same pile are suggestion tiles and were rejected.'
  $evChip  = 'probe ''chipotle powder'' returned NO-CANDIDATES; re-probe ''ground chipotle'' returned exactly one qualifying jar, Spice Islands Ground Chipotle Chile 2.3oz \.49. Pure ground chipotle, not a sauce or blend. Price looks high for the size and should be re-verified before any board cell.'
  $q2 = [pscustomobject]@{ items = @(
    [pscustomobject]@{ term = 'green bell pepper'; stores = [pscustomobject]@{
      'Fareway' = [pscustomobject]@{ price = 0.77; size = 'each'; item = 'Green Bell Pepper'; evidence = $evBoard }
      "Baker's" = [pscustomobject]@{ price = 0.89; size = '1 ct'; item = 'Fresh Large Green Bell Pepper'; evidence = 'server probe rung 1 ''green bell pepper'', 3 hits: Fresh Large Green Bell Pepper 1 ct $0.89' } } },
    [pscustomobject]@{ term = 'green bell pepper 2'; stores = [pscustomobject]@{
      'Fareway' = [pscustomobject]@{ price = 1.17; size = '1 each'; item = 'Green Bell Pepper'; evidence = $evStore } } },
    [pscustomobject]@{ term = 'chipotle-powder'; stores = [pscustomobject]@{
      "Baker's" = [pscustomobject]@{ price = 14.49; size = '2.3 oz'; item = 'Spice Islands Ground Chipotle Chile'; evidence = $evChip } } }
  ) }
  $m2 = [pscustomobject]@{ map = [pscustomobject]@{
    'green bell pepper' = [pscustomobject]@{ id = 'bell-peppers' }; 'green bell pepper 2' = [pscustomobject]@{ id = 'bell-peppers' }
    'chipotle-powder' = [pscustomobject]@{ id = 'chipotle-powder' } } }
  $r2 = Get-QueuePromotions -Queue $q2 -Map $m2
  $r2Ref = @($r2.refused)
  T ($r2Ref.Count -eq 1 -and $r2Ref[0].reason -eq 'SELF-SOURCED' -and $r2Ref[0].store -eq 'Fareway' -and $r2Ref[0].price -eq 0.77) ("MUST FIRE  the `$0.77 Fareway pepper answered from comparison-2026-08-15 is refused SELF-SOURCED and counted (refused=$($r2Ref.Count))")
  T (-not (@($r2.rows | Where-Object { $_.store -eq 'Fareway' -and $_.price -eq 0.77 })).Count) 'MUST FIRE  ...and it is NOT among the rows -Apply would write'
  T ((@($r2.rows | Where-Object { $_.store -eq 'Fareway' -and $_.price -eq 1.17 })).Count -eq 1) 'MUST NOT FIRE  the store read that replaced it ($1.17, driver rung 1) promotes'
  T ((@($r2.rows | Where-Object { $_.store -eq "Baker's" -and $_.term -eq 'green bell pepper' })).Count -eq 1) 'CLEAN TWIN  a store read beside a refused sibling in the SAME queue item still promotes - the refusal is per row, not per term'
  T ((@($r2.rows | Where-Object { $_.term -eq 'chipotle-powder' })).Count -eq 1) 'CLEAN TWIN  a real probe whose prose merely says "before any board cell" still promotes - the word board is not the evidence'
  # Each spelling the agent actually writes when it answered from our data, one case per pattern (a defence worth
  # having per spelling is worth a case per spelling), and the plain store read beside them.
  $spell = @(
    @{ e = 'Answered at tier 1 from the priced board, comparison-2026-08-15.json (week of 2026-08-15).'; want = 'comparison-2026-08-15' },
    @{ e = 'price-ingredient tier 1: ''bacon bits'' MAPS to the existing priced commodity'; want = 'price-ingredient tier 1' },
    @{ e = 'no browser this session; ruled from disk instead'; want = 'ruled from disk' },
    @{ e = 'returns the row via price-ingredient.ps1 -Name ''x'''; want = 'price-ingredient.ps1 -Name' },
    @{ e = 'price-ingredient CAPTURE tier: two Walmart captures agree'; want = 'price-ingredient CAPTURE tier' },
    @{ e = 'Answered at tier 1 from the priced board.'; want = 'from the priced board' },
    @{ e = 'Baker''s board cell is Kroger Thick Cut Bacon'; want = 'board cell is' }
  )
  $spellOk = 0
  foreach ($sp in $spell) { if ([string]::Equals((Get-SelfSourcedEvidence $sp.e), $sp.want, [StringComparison]::OrdinalIgnoreCase)) { $spellOk++ } else { Write-Output ("      spelling missed: [" + $sp.e + "] got [" + (Get-SelfSourcedEvidence $sp.e) + "]") } }
  T ($spellOk -eq $spell.Count) ("MUST FIRE  every self-sourced spelling the queue carries is named ($spellOk of $($spell.Count))")
  T ((Get-SelfSourcedEvidence 'Server tier rung 1 ''eggs'' = 12 hits (kroger-public)') -eq '') 'MUST NOT FIRE  a server-tier store probe is a store read'
  Write-Output ("PROMOTE-QUEUE " + $(if ($f) { "SELF-TEST FAILED ($f)" } else { 'SELF-TEST PASS' }))
  Exit-Guard -Name 'promote-ingredient-queue' -Summary "selftest failed=$f" -Code $(if ($f) { 2 } else { 0 })
}

if (-not (Test-Path $QueueFile)) { Write-Output 'promote-queue: no ingredient-queue.json'; Write-GuardComplete -Name 'promote-ingredient-queue' -Summary 'no queue'; exit 0 }
if (-not (Test-Path $MapFile)) { Write-Output "promote-queue: no ruling file at $MapFile - refusing to guess at commodity identity"; Write-GuardComplete -Name 'promote-ingredient-queue' -Summary 'no ruling file'; exit 0 }
$queue = Read-JsonFile $QueueFile
$map = Read-JsonFile $MapFile
$res = Get-QueuePromotions -Queue $queue -Map $map

Write-Output ("promote-queue: {0} price(s) promotable across {1} commodit(ies); {2} term(s) held pending a new id; {3} banned by catalog policy" -f `
    $res.rows.Count, (@($res.rows | ForEach-Object { $_.id } | Select-Object -Unique)).Count, $res.skipped.Count, $res.banned)

# The queue records WHEN each observation happened; every entry in this batch was captured on the day
# the agent ran. Read it from the queue rather than assuming, and fall back to the file's own stamp.
$asOf = ''
try { $asOf = ([datetime]$queue.updated).ToString('yyyy-MM-dd') } catch { }
if (-not $asOf) { $asOf = (Get-Item $QueueFile).LastWriteTime.ToString('yyyy-MM-dd') }
Write-Output ("  as_of {0} - the day the agent looked, NOT today; stamping the run date would launder a stale observation into a fresh one" -f $asOf)

$byStore = $res.rows | Group-Object store
foreach ($g in $byStore) {
  Write-Output ("   {0,-13} {1} price(s)" -f $g.Name, $g.Count)
}
if ($res.skipped.Count) { Write-Output ("  held pending a new commodity id: " + (($res.skipped | Sort-Object) -join ', ')) }
# SELF-SOURCED, NAMED AND COUNTED WITH ITS DENOMINATOR. These rows are never written; each is owed a store read.
$refusedN = @($res.refused).Count
Write-Output ("  refused SELF-SOURCED: {0} of {1} priced, ruled row(s) - their evidence is our own board or captures, not a store read" -f $refusedN, ($refusedN + $res.rows.Count))
foreach ($x in @($res.refused)) { Write-Output ("   SELF-SOURCED  {0,-13} {1} ({2}) `${3} - evidence says '{4}'" -f $x.store, $x.term, $x.id, $x.price, $x.matched) }

if (-not $Apply) {
  Write-Output '  REPORT ONLY - re-run with -Apply to write the per-store files.'
  Exit-Guard -Name 'promote-ingredient-queue' -Summary "promotable=$($res.rows.Count) refused_self_sourced=$refusedN applied=0" -Code 0
}

$regDir = Join-Path $OutDir 'regular'
if (-not (Test-Path $regDir)) { New-Item -ItemType Directory -Path $regDir -Force | Out-Null }
$written = 0
foreach ($g in $byStore) {
  $store = [string]$g.Name
  $slug = ($store -replace "[^A-Za-z0-9]", '').ToLower()
  $deals = @($g.Group | ForEach-Object {
    [ordered]@{
      store = $store; item = $_.item; ad_price = ('$' + $_.price); size = $_.size
      regular = ('$' + $_.price); current_price = [double]$_.price
      source_ad = 'Recipe Hunter pricing agent (in-store verified, ingredient-queue)'
      as_of = $asOf; found_by_term = $_.term; price_type = 'everyday'
      hunter_commodity = $_.id
    }
  })
  $doc = [ordered]@{
    store = $store; price_type = 'everyday'
    # Aldi and Fareway rows are refused by the engine unless the file MACHINE-PROVES an in-store
    # capture. The pricing agent verifies in-store mode before reading a price - that is written into
    # its own contract - so the claim is carried, not invented.
    price_mode = 'in-store'; mode_verified = $asOf
    source = 'promote-ingredient-queue.ps1 from ingredient-queue.json - prices an agent captured per store and adjudicated per product'
    generated = (Get-Date).ToString('s')
    note = 'Prices from the Recipe Hunter pricing agent, promoted into the engine because compare-deals reads out\regular and does not read the queue. Commodity ids come from ingredient-queue-map.json, which is a RULING - nothing here was slugified or inferred.'
    deals = $deals
  }
  $f = Join-Path $regDir ("hunter-$slug-regular-$asOf.json")
  [IO.File]::WriteAllText($f, ($doc | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
  $written++
  Write-Output ("  wrote {0} ({1} row(s))" -f (Split-Path $f -Leaf), $deals.Count)
}
Write-Output ("promote-queue: wrote {0} store file(s) into out\regular" -f $written)
Exit-Guard -Name 'promote-ingredient-queue' -Summary "promotable=$($res.rows.Count) refused_self_sourced=$refusedN applied=$written" -Code 0
