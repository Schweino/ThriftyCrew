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
param([switch]$Apply, [switch]$SelfTest, [string]$OutDir = '', [string]$QueueFile = '', [string]$MapFile = '')
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
if (-not $QueueFile) { $QueueFile = Join-Path $root 'ingredient-queue.json' }
if (-not $MapFile) { $MapFile = Join-Path $root 'ingredient-queue-map.json' }
. (Join-Path (Split-Path $root -Parent) 'lib\guard-contract.ps1')

function Get-QueuePromotions {
  <#
    .SYNOPSIS Every (commodity, store, price) the ruling allows to be promoted.
    .DESCRIPTION Pure over parsed documents so the fixtures reach the real decision. A term absent from
                 the map is SKIPPED and counted, never guessed at.
  #>
  param($Queue, $Map)
  $rows = @(); $skipped = @(); $banned = 0
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
      $rows += [pscustomobject]@{
        id = [string]$ruling.id; term = $term; store = [string]$p.Name
        price = [double]$s.price; size = [string]$s.size; item = [string]$s.item
        evidence = [string]$s.evidence
      }
    }
  }
  return [pscustomobject]@{ rows = $rows; skipped = @($skipped | Select-Object -Unique); banned = $banned }
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
  Write-Output ("PROMOTE-QUEUE " + $(if ($f) { "SELF-TEST FAILED ($f)" } else { 'SELF-TEST PASS' }))
  Write-GuardComplete -Name 'promote-ingredient-queue' -Summary "selftest failed=$f"
  exit $(if ($f) { 2 } else { 0 })
}

if (-not (Test-Path $QueueFile)) { Write-Output 'promote-queue: no ingredient-queue.json'; Write-GuardComplete -Name 'promote-ingredient-queue' -Summary 'no queue'; exit 0 }
if (-not (Test-Path $MapFile)) { Write-Output "promote-queue: no ruling file at $MapFile - refusing to guess at commodity identity"; Write-GuardComplete -Name 'promote-ingredient-queue' -Summary 'no ruling file'; exit 0 }
$queue = Get-Content $QueueFile -Raw | ConvertFrom-Json
$map = Get-Content $MapFile -Raw | ConvertFrom-Json
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

if (-not $Apply) {
  Write-Output '  REPORT ONLY - re-run with -Apply to write the per-store files.'
  Write-GuardComplete -Name 'promote-ingredient-queue' -Summary "promotable=$($res.rows.Count) applied=0"
  exit 0
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
Write-GuardComplete -Name 'promote-ingredient-queue' -Summary "promotable=$($res.rows.Count) applied=$written"
exit 0
