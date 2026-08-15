<#
  price-ingredient.ps1 - answer "what does this ingredient cost at the Omaha stores?" from data already on
  disk, in milliseconds.

  WHY THIS EXISTS. The V4 platform priced a missing ingredient by opening a distributed workflow: seven
  store producer lanes plus seven independent verifier lanes, an 8-state machine per store, leases, fencing,
  retries, an LLM pricing agent, and a full repo clone to temp per publish attempt. Publication required
  ALL SEVEN stores terminal AND independently verified before one price could go public. Measured on
  2026-08-14 it did not finish at all: 548 publish launches with the ready-count unchanged before and after
  every one. Two of the three ingredients it had been grinding on for hours - almonds and achiote-paste -
  were ALREADY PRICED and sitting in out\comparison-<date>.json the whole time; almonds resolved from that
  file at all 7 stores in 1.7ms. achiote-paste is stocked at 1 of 7 stores, so under a seven-terminal rule
  it could never have published at all.

  THE THREE RULES THAT FALL OUT OF THAT:
    1. LOOK IT UP FIRST. The daily pipeline already writes every store's prices, normalized to one unit per
       commodity. Pricing an ingredient is a read, not an acquisition.
    2. PARTIAL COVERAGE IS AN ANSWER. Four stores today beats seven stores never. Coverage is reported as a
       fact; it is never a gate.
    3. A WALLED STORE IS A MISSING CELL, NOT A STALL. Aldi throwing a bot wall must never be able to hold an
       ingredient open. Nothing here blocks, retries, or waits.

  It reads: out\comparison-<newest>.json (the priced board), commodities.json + commodity-search.json (how a
  name resolves to a commodity), and out\regular\*.json (raw captures) for terms no commodity claims yet.
  It writes nothing and calls nothing over the network.

  TIERS, cheapest first. Every answer says which tier produced it and what the evidence was.
    MAPPED   the term resolves to a board commodity -> every store's per-unit price, straight from the board.
    CAPTURE  no commodity claims it, but today's raw captures carry products matching the term -> candidate
             products with prices, so a commodity rule can be written from evidence instead of a guess.
    ABSENT   neither. Says so plainly rather than implying zero means free.

  Usage:
    .\price-ingredient.ps1 almonds
    .\price-ingredient.ps1 'achiote paste' '15 bean soup mix' saffron
    .\price-ingredient.ps1 -Name quinoa -Json
    .\price-ingredient.ps1 -SelfTest
#>
param(
  # Position 0 matters: under `powershell -File script.ps1 foo bar` the args arrive positionally, and
  # ValueFromRemainingArguments alone does not bind them without a position.
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Name = @(),
  [string]$OutDir = "",
  [string]$CompareFile = "",
  [string]$CommoditiesFile = "",
  [switch]$Json,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
if (-not $CommoditiesFile) { $CommoditiesFile = Join-Path $root 'commodities.json' }

function Read-Utf8Json([string]$Path) {
  # NOT Get-Content -Raw: in PS 5.1 that decodes with the ANSI codepage and mangles the non-ASCII this
  # catalog carries (a registered-sign inside a character class stops matching itself).
  return ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) -replace '^﻿', '') | ConvertFrom-Json
}

function Get-Slug([string]$s) { return (($s -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLowerInvariant()) }

# ---- resolve one term to a commodity id --------------------------------------------------------------
# Ordered most-certain first, and every hit records HOW it matched so a wrong answer is auditable rather
# than mysterious. An include-pattern hit is last because it is the loosest and the likeliest to be wrong.
function Resolve-Commodity($Term, $Commods, $SearchMap) {
  $slug = Get-Slug $Term
  $hit = $Commods | Where-Object { $_.id -eq $slug } | Select-Object -First 1
  if ($hit) { return @{ id = $hit.id; how = 'exact commodity id' } }
  $hit = $Commods | Where-Object { (Get-Slug ([string]$_.label)) -eq $slug } | Select-Object -First 1
  if ($hit) { return @{ id = $hit.id; how = 'commodity label' } }
  if ($SearchMap) {
    foreach ($p in $SearchMap.PSObject.Properties) {
      $terms = @([string]$p.Value -split '\s*[|,]\s*' | Where-Object { $_ })
      foreach ($t in $terms) { if ((Get-Slug $t) -eq $slug) { return @{ id = [string]$p.Name; how = "search term '$t'" } } }
    }
  }
  foreach ($c in $Commods) {
    foreach ($inc in @($c.include)) {
      if (-not $inc) { continue }
      # bounded: an include is authored data and one bad pattern must not hang a lookup (see the ReDoS that
      # cost this estate 11 hours on 2026-08-14)
      try {
        $rx = New-Object Text.RegularExpressions.Regex([string]$inc, [Text.RegularExpressions.RegexOptions]::IgnoreCase, [TimeSpan]::FromMilliseconds(100))
        if ($rx.IsMatch($Term)) { return @{ id = [string]$c.id; how = "include pattern /$inc/" } }
      } catch { }
    }
  }
  return $null
}

if ($SelfTest) {
  $bad = 0
  if ((Get-Slug 'Achiote Paste') -ne 'achiote-paste') { Write-Output '  X slug'; $bad++ }
  if ((Get-Slug '15 Bean Soup Mix') -ne '15-bean-soup-mix') { Write-Output '  X slug digits'; $bad++ }
  $fakeCommods = @(
    [pscustomobject]@{ id = 'almonds'; label = 'Almonds'; unit = 'oz'; include = @('\balmonds\b'); exclude = @() },
    [pscustomobject]@{ id = 'ground-beef-8020'; label = '80/20 Ground Beef'; unit = 'lb'; include = @('ground\s+beef'); exclude = @() }
  )
  $r = Resolve-Commodity 'almonds' $fakeCommods $null
  if (-not $r -or $r.id -ne 'almonds') { Write-Output '  X exact id did not resolve'; $bad++ }
  $r = Resolve-Commodity '80/20 Ground Beef' $fakeCommods $null
  if (-not $r -or $r.id -ne 'ground-beef-8020') { Write-Output '  X label did not resolve'; $bad++ }
  $r = Resolve-Commodity 'ground beef' $fakeCommods $null
  if (-not $r -or $r.id -ne 'ground-beef-8020') { Write-Output '  X include pattern did not resolve'; $bad++ }
  if ($null -ne (Resolve-Commodity 'nothing like this exists' $fakeCommods $null)) { Write-Output '  X a nonsense term resolved'; $bad++ }
  # MUST-FIRE: a pathological include must not hang the resolver. This is the founding-bug shape.
  $redos = [pscustomobject]@{ id = 'redos'; label = 'Redos'; unit = 'oz'
                              include = @('^(?:[\w&.-]+.{0,25}){0,6}(?:(?:organic|whole[- ]grain|white|red).{0,25})*quinoa$'); exclude = @() }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $null = Resolve-Commodity 'Just Bare boneless skinless chicken breasts, 18 oz., $4.99' @($redos) $null
  $sw.Stop()
  if ($sw.ElapsedMilliseconds -gt 2000) { Write-Output ("  X MUST-FIRE: a ReDoS include hung the resolver for {0}ms" -f $sw.ElapsedMilliseconds); $bad++ }
  if ($bad -eq 0) { Write-Output 'price-ingredient SELF-TEST PASS (slug, id/label/pattern resolution, nonsense rejected, ReDoS include bounded)'; exit 0 }
  Write-Output ("price-ingredient SELF-TEST FAIL ({0} problem(s))" -f $bad); exit 1
}

if (-not $Name -or $Name.Count -eq 0) { Write-Output 'price-ingredient: give one or more ingredient names. -SelfTest to verify.'; exit 1 }

# ---- load once ---------------------------------------------------------------------------------------
$swLoad = [Diagnostics.Stopwatch]::StartNew()
if (-not $CompareFile) {
  $newest = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $newest) { Write-Output "price-ingredient: BLIND - no comparison-*.json in $OutDir. Run compare-deals.ps1 first."; exit 3 }
  $CompareFile = $newest.FullName
}
$cmpDoc = Read-Utf8Json $CompareFile
$board = $cmpDoc.comparison
$boardIx = @{}
foreach ($r in $board) { $boardIx[[string]$r.id] = $r }
# NOT @(Read-Utf8Json ...). ConvertFrom-Json hands a JSON array back as ONE object, so the array subexpression
# wraps it AGAIN: @() around this call yields a 1-element array whose single element is all 573 commodities.
# `$_.id` on that element is then a 573-item array, `-eq $slug` returns the matching members (truthy), and the
# resolver hands back every id at once - which surfaced as "cannot convert Object[] to Double" three frames
# later. Assign first; the value is already Object[].
$commods = Read-Utf8Json $CommoditiesFile
if ($commods -isnot [array]) { $commods = ,$commods }
$searchF = Join-Path $root 'commodity-search.json'
$searchMap = if (Test-Path $searchF) { Read-Utf8Json $searchF } else { $null }
$swLoad.Stop()

# The raw-capture corpus is loaded ONCE, lazily, and only if some term actually falls through to tier 2.
# Re-reading and re-parsing out\regular\*.json per term cost 12.8s for a single ABSENT lookup; hoisted it is
# paid once for the whole batch and the mapped terms never pay it at all.
$captureRows = $null
function Get-CaptureRows {
  if ($null -ne $script:captureRows) { return $script:captureRows }
  $rows = New-Object System.Collections.ArrayList
  # NEWEST FILE PER STORE, not every file in the folder. out\regular\ keeps months of daily captures (135
  # files when this was written); reading them all cost 18s and would also answer from a two-month-old
  # capture, which is a worse sin than being slow. Names are <store>-regular-<date>.json, so the store key is
  # everything before '-regular-' and newest-by-name is newest-by-date.
  $newestPerStore = @(Get-ChildItem (Join-Path $OutDir 'regular\*.json') -ErrorAction SilentlyContinue |
    Group-Object { ($_.Name -split '-regular-')[0] } |
    ForEach-Object { $_.Group | Sort-Object Name -Descending | Select-Object -First 1 })
  foreach ($f in $newestPerStore) {
    $doc = $null
    try { $doc = Read-Utf8Json $f.FullName } catch { continue }
    $store = [string]$doc.store
    foreach ($d in @($doc.deals)) {
      $nm = [string]$d.item
      if ($nm) { [void]$rows.Add([pscustomobject]@{ store = $store; item = $nm; price = $d.current_price; size = [string]$d.size; as_of = [string]$d.as_of }) }
    }
  }
  $script:captureRows = $rows
  return $script:captureRows
}

$results = New-Object System.Collections.ArrayList
foreach ($term in $Name) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $res = Resolve-Commodity $term $commods $searchMap
  $row = $null
  if ($res) { $row = $boardIx[$res.id] }

  if ($row) {
    $stores = @($row.stores | Sort-Object per_unit)
    [void]$results.Add([pscustomobject]@{
      term = $term; tier = 'MAPPED'; commodity = $res.id; resolved_by = $res.how; unit = [string]$row.unit
      cheapest_store = [string]$row.cheapest_store; cheapest = [double]$row.cheapest_price
      coverage = ("{0} of 7 stores" -f @($stores).Count)
      stores = @($stores | ForEach-Object { [pscustomobject]@{ store = [string]$_.store; per_unit = [double]$_.per_unit; item = [string]$_.item; size = [string]$_.size } })
      ms = $sw.ElapsedMilliseconds })
    continue
  }

  # ---- TIER 2: no commodity claims it. Search the raw captures the pipeline already pulled. -----------
  # This is the honest answer to "we do not price this yet": here are the real products a store actually
  # carries under that name, with prices, so a commodity rule can be written from evidence.
  $cands = New-Object System.Collections.ArrayList
  $rxTerm = $null
  try { $rxTerm = New-Object Text.RegularExpressions.Regex([regex]::Escape($term), [Text.RegularExpressions.RegexOptions]::IgnoreCase, [TimeSpan]::FromMilliseconds(100)) } catch { }
  if ($rxTerm) {
    foreach ($cr in (Get-CaptureRows)) {
      try { if (-not $rxTerm.IsMatch($cr.item)) { continue } } catch { continue }
      [void]$cands.Add($cr)
      if ($cands.Count -ge 25) { break }
    }
  }
  $sw.Stop()
  if ($cands.Count -gt 0) {
    [void]$results.Add([pscustomobject]@{
      term = $term; tier = 'CAPTURE'; commodity = $(if ($res) { $res.id } else { $null })
      resolved_by = $(if ($res) { $res.how + ' (commodity exists but has no priced board cell)' } else { 'no commodity claims this term' })
      unit = $null; cheapest_store = $null; cheapest = $null
      coverage = ("{0} candidate product(s) across {1} store(s) in today's captures" -f $cands.Count, (@($cands | Select-Object -ExpandProperty store -Unique)).Count)
      stores = @($cands); ms = $sw.ElapsedMilliseconds })
  } else {
    [void]$results.Add([pscustomobject]@{
      term = $term; tier = 'ABSENT'; commodity = $(if ($res) { $res.id } else { $null })
      resolved_by = $(if ($res) { $res.how } else { 'no commodity claims this term' })
      unit = $null; cheapest_store = $null; cheapest = $null
      coverage = 'no board cell and no matching product in any capture'
      stores = @(); ms = $sw.ElapsedMilliseconds })
  }
}

if ($Json) {
  [pscustomobject]@{ board = (Split-Path $CompareFile -Leaf); week_of = [string]$cmpDoc.week_of
                     load_ms = $swLoad.ElapsedMilliseconds; results = @($results) } | ConvertTo-Json -Depth 6
  exit 0
}

Write-Output ("price-ingredient: {0} (week {1}), {2} commodities indexed in {3}ms" -f (Split-Path $CompareFile -Leaf), [string]$cmpDoc.week_of, $board.Count, $swLoad.ElapsedMilliseconds)
foreach ($r in $results) {
  Write-Output ''
  Write-Output ("{0}  '{1}'  [{2}ms]" -f $r.tier, $r.term, $r.ms)
  if ($r.tier -eq 'MAPPED') {
    Write-Output ("   commodity {0}  ({1})" -f $r.commodity, $r.resolved_by)
    Write-Output ("   cheapest  {0} `${1}/{2}   -   {3}" -f $r.cheapest_store, $r.cheapest, $r.unit, $r.coverage)
    foreach ($s in $r.stores) { Write-Output ("      {0,-13} {1,-10} {2}" -f $s.store, $s.per_unit, ([string]$s.item)) }
  } elseif ($r.tier -eq 'CAPTURE') {
    Write-Output ("   {0}" -f $r.resolved_by)
    Write-Output ("   NOT PRICED on the board. {0}:" -f $r.coverage)
    # some captures store current_price as a bare number, others as "$1.98"; do not print "$$1.98"
    foreach ($s in $r.stores | Select-Object -First 10) { Write-Output ("      {0,-13} `${1,-8} {2,-11} {3}" -f $s.store, (([string]$s.price).TrimStart('$')), $s.size, ([string]$s.item)) }
    Write-Output '   -> write a commodity rule from these, or rule them out. Nothing here is a price yet.'
  } else {
    Write-Output ("   {0}" -f $r.resolved_by)
    Write-Output '   ABSENT: no board cell and nothing in any capture matches. This is not a price of zero.'
  }
}
