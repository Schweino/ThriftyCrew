<#
  audit-price-capture-reach.ps1 - does every price we CAPTURED actually reach the price table?

  BRAD, 2026-08-21: "we need to make sure that when we pull pricing, from ANY part of our codebase,
  its populating the table correctly. i believe we habe another routine recipe hunter that has an
  agent pull pricing for missing ingredients"

  He was right, and the number is not small. Measured the day he asked:

      ingredient-queue.json   99 store prices captured by the Recipe Hunter's pricing agent
                              97 of them appear NOWHERE on the board or in the price table
                              41 ingredients affected, 38 of which the board has no row for at all

  Those were captured 2026-08-16 - an agent opened seven stores, adjudicated which row was really
  the ingredient, and recorded a real price with a real size - and they have sat in a file nothing
  reads ever since.

  WHY NO EXISTING GUARD COULD SEE IT. Every guard in this estate starts from the board and asks
  whether what is ON it is right. This asks the opposite question: is anything we know MISSING from
  it? A price that never arrives cannot be wrong, cannot be stale, cannot fail parity, and cannot
  appear in a coverage count that only counts published cells. It is invisible by construction to a
  system that only audits its own output. That is the same shape as `tested is not run` and
  `dead guards sweep`, applied to data instead of code.

  THE ARCHITECTURE THIS DEFENDS. compare-deals reads exactly six input classes:
      out\regular\*-regular-*.json, out\ads-*.json, out\bakers\*, out\fareway\*, out\sams\*,
      extra-deals-*.json
  and the price table is derived from the same rows the ranker uses, so ANYTHING that lands in
  those six reaches the table by construction. There is no second way in, and there must not be -
  a direct-to-table writer would be a second implementation of every rule the engine enforces.
  So the rule is: a capture path either writes into one of the six, or its prices do not exist.
  This audit is what makes the second half of that sentence observable instead of theoretical.

  A GAP IS NOT AUTOMATICALLY A DEFECT, WHICH IS WHY THIS IS ADVISORY. Most of the queue's 97 are
  ingredients with no commodity id yet, and minting an id is deliberately gated (the commodity
  registrar rules variant-vs-duplicate with written evidence, because a careless new id splits a
  commodity that is already priced under another name). "Captured, adjudicated, waiting on an id"
  is a legitimate state. "Captured and forgotten for five days because nothing counts it" is not.

  Usage: audit-price-capture-reach.ps1 [-OutDir <dir>] [-Quiet] [-SelfTest]
  Exit 0 = clean or advisory findings. Exit 2 = self-test regression. Exit 3 = BLIND.
#>
param([string]$OutDir = '', [switch]$Quiet, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
. (Join-Path (Split-Path $root -Parent) 'lib\guard-contract.ps1')

# THE ROSTER OF SIDE STORES. Explicit on purpose: adding a new place that holds captured prices has
# to be a deliberate act, because the failure mode is a file nobody remembers. `expected` records
# whether its prices are supposed to reach the table at all - a legacy artifact that has been
# superseded is not a leak, and calling it one would train everyone to ignore this guard.
$SIDE_STORES = @(
  [ordered]@{
    file = 'ingredient-queue.json'
    what = 'Recipe Hunter pricing agent (ingredient-queue.ps1 -Record -Price)'
    expected = 'reach'
    why = 'An agent checked seven Omaha stores and adjudicated which row is really the ingredient. That is a real capture and it should price the board.'
  },
  [ordered]@{
    file = 'ingredient-prices.json'
    what = 'SMP pilot hand-priced ingredient table, updated 2026-07-06'
    expected = 'legacy'
    why = 'Superseded by the board itself. Recorded so its 537 prices are accounted for rather than rediscovered as a mystery every few months.'
  }
)

function Get-QueueObservations {
  <#
    .SYNOPSIS Every (term, store, price) the Recipe Hunter queue holds. Pure over a parsed document
              so the fixture can hand it a shape with no file on disk.
  #>
  param($Doc)
  $out = @()
  foreach ($it in @($Doc.items)) {
    if (-not $it.stores) { continue }
    foreach ($p in $it.stores.PSObject.Properties) {
      $s = $p.Value
      if ($null -eq $s -or $null -eq $s.price) { continue }
      $out += [pscustomobject]@{ key = [string]$it.term; store = [string]$p.Name; price = [double]$s.price
        size = [string]$s.size; item = [string]$s.item }
    }
  }
  return $out
}

function Measure-CaptureReach {
  <#
    .SYNOPSIS How many captured observations appear as a cell in the price table.
    .DESCRIPTION $TableKeys is a HashSet of "<id>|<store>". Pure, so the self-test exercises the real
                 comparison rather than a description of it.
  #>
  param([object[]]$Observations, $TableKeys, $TableIds)
  $reached = 0; $missing = @()
  foreach ($o in @($Observations)) {
    if ($TableKeys.Contains($o.key + '|' + $o.store)) { $reached++ }
    else { $missing += [pscustomobject]@{ key = $o.key; store = $o.store; price = $o.price; size = $o.size
             item = $o.item; commodity_known = $TableIds.Contains($o.key) } }
  }
  return [pscustomobject]@{ total = @($Observations).Count; reached = $reached; missing = $missing }
}

if ($SelfTest) {
  $f = 0
  function T($ok, $m) { if ($ok) { Write-Output "ok    $m" } else { Write-Output "FAIL  $m"; $script:f++ } }

  # Shape a queue document the way ingredient-queue.ps1 writes one.
  $doc = [pscustomobject]@{ items = @(
    [pscustomobject]@{ term = 'saffron'; stores = [pscustomobject]@{
      "Baker's" = [pscustomobject]@{ price = 28.99; size = '0.03 oz'; item = 'Spice Islands Saffron' }
      'Aldi'    = [pscustomobject]@{ price = $null; size = ''; item = '' }   # not-carried, no price
    } },
    [pscustomobject]@{ term = 'cumin-seeds'; stores = [pscustomobject]@{
      'Family Fare' = [pscustomobject]@{ price = 2.29; size = '2 oz'; item = "Sugar 'N Spice Cumin Whole" }
    } }
  ) }
  $obs = @(Get-QueueObservations -Doc $doc)
  T ($obs.Count -eq 2) "a null price is not an observation (got $($obs.Count), expected 2)"

  $keys = New-Object 'System.Collections.Generic.HashSet[string]'
  $ids = New-Object 'System.Collections.Generic.HashSet[string]'
  [void]$keys.Add("saffron|Baker's"); [void]$ids.Add('saffron')
  $m = Measure-CaptureReach -Observations $obs -TableKeys $keys -TableIds $ids

  # MUST FIRE: the captured-but-unreachable price is exactly what this exists to see.
  T ($m.reached -eq 1 -and $m.missing.Count -eq 1) "a captured price missing from the table is REPORTED (reached=$($m.reached) missing=$($m.missing.Count))"
  T ($m.missing[0].key -eq 'cumin-seeds' -and -not $m.missing[0].commodity_known) 'a missing price whose commodity has no board row at all is flagged as such'

  # CLEAN TWIN: when everything reaches, it must stay silent. A guard that always fires is ignored,
  # and this one is advisory - it has to earn attention.
  [void]$keys.Add('cumin-seeds|Family Fare'); [void]$ids.Add('cumin-seeds')
  $m2 = Measure-CaptureReach -Observations $obs -TableKeys $keys -TableIds $ids
  T ($m2.missing.Count -eq 0) 'when every captured price reaches the table the audit is silent'

  # CLEAN TWIN: the same commodity at a DIFFERENT store is still missing. Reach is per CELL, not per
  # commodity - "we price cumin somewhere" is not the same claim as "we price cumin at Family Fare",
  # and collapsing them would hide most of a real gap.
  $obs2 = @([pscustomobject]@{ key = 'cumin-seeds'; store = "Baker's"; price = 1.69; size = '1 oz'; item = 'Tampico' })
  $m3 = Measure-CaptureReach -Observations $obs2 -TableKeys $keys -TableIds $ids
  T ($m3.missing.Count -eq 1 -and $m3.missing[0].commodity_known) 'reach is measured per CELL - a known commodity at an unpriced store still counts as missing'

  Write-Output ("PRICE-CAPTURE-REACH " + $(if ($f) { "SELF-TEST FAILED ($f)" } else { 'SELF-TEST PASS' }))
  Write-GuardComplete -Name 'price-capture-reach' -Summary "selftest failed=$f"
  exit $(if ($f) { 2 } else { 0 })
}

$ptFile = Get-ChildItem (Join-Path $OutDir 'price-table-*.json') -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if (-not $ptFile) {
  Write-Output 'price-capture-reach: no price table found - cannot tell whether anything reaches it'
  Write-GuardComplete -Name 'price-capture-reach' -Summary 'BLIND: no price table'
  exit 3
}
$pt = Get-Content $ptFile.FullName -Raw | ConvertFrom-Json
$keys = New-Object 'System.Collections.Generic.HashSet[string]'
$ids = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($r in @($pt.items)) {
  [void]$ids.Add([string]$r.id)
  foreach ($p in $r.stores.PSObject.Properties) { [void]$keys.Add([string]$r.id + '|' + [string]$p.Name) }
}

$report = @()
foreach ($ss in $SIDE_STORES) {
  $path = Join-Path $root $ss.file
  if (-not (Test-Path $path)) { continue }
  $doc = $null
  try { $doc = Get-Content $path -Raw | ConvertFrom-Json } catch { }
  if (-not $doc) { continue }
  $obs = @()
  if ($ss.file -eq 'ingredient-queue.json') { $obs = @(Get-QueueObservations -Doc $doc) }
  else {
    # ingredient-prices.json: {item, stores:{Store:{price}}} keyed by product NAME, not commodity id,
    # so its keys cannot be matched to the table at all. Counted, never resolved - see `expected`.
    foreach ($it in @($doc.items)) {
      if (-not $it.stores) { continue }
      foreach ($p in $it.stores.PSObject.Properties) {
        if ($null -ne $p.Value -and $null -ne $p.Value.price) {
          $obs += [pscustomobject]@{ key = [string]$it.item; store = [string]$p.Name; price = [double]$p.Value.price; size = ''; item = [string]$it.item }
        }
      }
    }
  }
  $m = Measure-CaptureReach -Observations $obs -TableKeys $keys -TableIds $ids
  $report += [pscustomobject]@{ file = $ss.file; what = $ss.what; expected = $ss.expected; why = $ss.why
    captured = $m.total; reached = $m.reached; missing = $m.missing.Count
    missing_rows = @($m.missing) }
}

$doc2 = [ordered]@{
  updated = (Get-Date).ToString('s'); price_table = $ptFile.Name
  note = 'Prices captured somewhere in the codebase that do not appear in the price table. compare-deals reads six input classes and the table is derived from the same rows the ranker uses, so a capture path either writes into one of those six or its prices do not exist. Advisory: "captured, adjudicated, waiting on a commodity id" is a legitimate state; "captured and forgotten because nothing counts it" is not.'
  stores = @($report | ForEach-Object { [ordered]@{ file = $_.file; what = $_.what; expected = $_.expected
      captured = $_.captured; reached = $_.reached; missing = $_.missing
      missing_rows = @($_.missing_rows | Select-Object -First 200) } })
}
$outF = Join-Path $OutDir 'price-capture-reach.json'
[IO.File]::WriteAllText($outF, ($doc2 | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))

if (-not $Quiet) {
  Write-Output 'price-capture-reach  -  prices captured in the codebase vs prices in the table'
  foreach ($r in $report) {
    $tag = if ($r.expected -eq 'legacy') { 'LEGACY' } elseif ($r.missing -gt 0) { 'GAP' } else { 'ok' }
    Write-Output ("  [{0,-6}] {1,-26} captured {2,4}  reached {3,4}  MISSING {4,4}   {5}" -f $tag, $r.file, $r.captured, $r.reached, $r.missing, $r.what)
    if ($r.expected -eq 'reach' -and $r.missing -gt 0) {
      $noId = @($r.missing_rows | Where-Object { -not $_.commodity_known })
      $terms = @($r.missing_rows | ForEach-Object { $_.key } | Select-Object -Unique)
      Write-Output ("           {0} ingredient(s) affected; {1} of them have no board row at all (a new commodity id is gated - see the commodity registrar)" -f $terms.Count, (@($noId | ForEach-Object { $_.key } | Select-Object -Unique)).Count)
      foreach ($x in ($r.missing_rows | Select-Object -First 6)) {
        Write-Output ("           {0,-22} {1,-12} {2,7}  {3}" -f $x.key, $x.store, $x.price, $x.item)
      }
    }
  }
  Write-Output ("  -> " + $outF)
}
Write-GuardComplete -Name 'price-capture-reach' -Summary ("stores=" + $report.Count + " missing=" + (($report | Measure-Object missing -Sum).Sum))
exit 0
