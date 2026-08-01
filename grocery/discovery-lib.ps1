<#
  discovery-lib.ps1 - the ONE definition of a discovery candidate's identity, its settled verdict, and the
  basis check that reads its size string.

  Shared by discover-hyvee.ps1 (which must not re-surface a settled candidate), build-arrivals-docket.ps1
  (which ranks the open ones) and adjudicate-discovery.ps1 (which records the ruling). Three callers, one
  implementation - two copies of a matching rule is this estate's most reliable bug (pu-lib had three, the
  category-exclude library drifted 2,165 patterns from its baked copy).

  *** NO param() BLOCK, DELIBERATELY *** - dot-sourcing runs a script's param() in the CALLER's scope
  (capture-lib.ps1 learned that on 2026-07-29).
#>

function Get-DiscoveryKey {
  <#
    A candidate's durable identity: store, commodity, and the STORE'S OWN product id.

    Keyed on the product id and not the name on purpose. A ruling has to survive the store re-spelling its
    own product - this pipeline has shipped one product three ways in four days - and a name-keyed ledger
    would let a re-titled wrong product walk back onto the docket as if it had never been judged. The name
    is the fallback only when the store publishes no id (it always does at Hy-Vee; other stores may not).
  #>
  param([string]$Store, [string]$Commodity, [string]$ProductId, [string]$Product)
  $st = (([string]$Store) -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
  $cid = ([string]$Commodity).Trim().ToLowerInvariant()
  # NOT $pid. That is a READ-ONLY automatic variable holding this process's id, and under a non-Stop
  # ErrorActionPreference the assignment fails QUIETLY and the key silently becomes the PID - every
  # candidate in a run keying to the same value. pull-regular-hyvee.ps1 carries the same warning.
  $prodId = ([string]$ProductId).Trim()
  if ($prodId -ne '') { return ($st + '|' + $cid + '|' + $prodId) }
  return ($st + '|' + $cid + '|n:' + ((([string]$Product).ToLowerInvariant()) -replace '[^a-z0-9]', ''))
}

function Get-DiscoveryVerdicts {
  <#
    The SETTLED rulings, keyed by Get-DiscoveryKey. A candidate in here has already cost a human a decision
    and must never be asked again - a review queue that re-asks a settled question teaches its reader to
    skim, and a skimmed queue is the same as no queue.

    Returns an empty table when the file is missing or unreadable, and the CALLER decides what that means.
    Nothing here may silently turn "we could not read the ledger" into "nothing has been ruled".
  #>
  param([string]$Path)
  $out = @{}
  if (-not $Path -or -not (Test-Path $Path)) { return $out }
  $doc = $null
  # ((Get-Content -Raw) + '') because [string]$null is $null so .Trim() on a zero-byte file THROWS, and
  # '' | ConvertFrom-Json returns $null WITHOUT throwing. Both have produced silent wrong answers here.
  try {
    $raw = ((Get-Content -LiteralPath $Path -Raw -Encoding UTF8) + '').Trim()
    if ($raw -eq '') { return $out }
    $doc = $raw | ConvertFrom-Json
  } catch { return $out }
  if ($null -eq $doc) { return $out }
  $entries = @()
  if ($doc.PSObject.Properties.Name -contains 'entries') { $entries = @($doc.entries) }
  foreach ($e in @($entries | Where-Object { $_ })) {
    $k = [string]$e.key
    if ($k -eq '') { continue }
    $out[$k] = $e
  }
  return $out
}

function Test-DiscoveryBasisSuspect {
  <#
    Does this candidate's SIZE STRING name a different kind of quantity than the commodity is priced in?

    This is not a style check. The first live Hy-Vee discovery run surfaced "Pasta Roni Garlic & Olive Oil
    Vermicelli, 4.6 oz" as beating olive-oil by 21.8% - and it does, arithmetically, because 4.6 WEIGHT
    ounces were divided into the price as if they were 4.6 FLUID ounces. That candidate is wrong twice over
    (wrong product AND wrong basis) and only the basis half is machine-detectable, so it gets detected.

    This is the [[board-basis-ambiguity]] class: a REAL price attached to the WRONG basis, which is worse
    than a wrong price because every number in the row is individually defensible.

    Returns a reason string when the size and the unit disagree, '' when they agree or the question does not
    arise. It is a FLAG FOR A HUMAN, never a filter - a size we cannot parse must not become a silent drop.
  #>
  param([string]$Size, [string]$Unit)
  $s = ' ' + (([string]$Size).ToLowerInvariant()) + ' '
  # collapse "fl oz"/"fl. oz." FIRST, so the bare-weight test below cannot see the "oz" inside "fl oz"
  $s = $s -replace 'fl\.?\s*(oz|ounces?)', 'floz'
  $u = ([string]$Unit).Trim().ToLowerInvariant()
  $hasWeight = ($s -match '\d\s*-?\s*(ounces?|oz|pounds?|lbs?|grams?|kg|g)\b')
  $hasVolume = ($s -match '\d\s*-?\s*(floz|milliliters?|ml|liters?|gallons?|gal|quarts?|qt|pints?|pt|l)\b')
  if (($u -eq 'floz' -or $u -eq 'gallon') -and $hasWeight -and -not $hasVolume) {
    return ("size '" + $Size + "' names a WEIGHT but this commodity is priced per " + $u + " - the per-unit divided weight ounces as if they were fluid ounces")
  }
  if (($u -eq 'oz' -or $u -eq 'lb') -and $hasVolume -and -not $hasWeight) {
    return ("size '" + $Size + "' names a VOLUME but this commodity is priced per " + $u + " - the per-unit divided a volume into a weight basis")
  }
  return ''
}
