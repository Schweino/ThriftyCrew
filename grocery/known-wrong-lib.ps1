# known-wrong-lib.ps1 - THE product-name normalizer and blocklist reader for adjudicated-wrong cells.
#
# Extracted 2026-08-01 from audit-known-wrong.ps1 so compare-deals.ps1 can enforce the SAME ruling with the
# SAME matching. Two copies of a matching rule is this estate's most reliable bug: pu-lib had three, the
# category-exclude library drifted 2,165 patterns from the baked copy, and the record tooltips carried a
# second price formatter that still printed "$0.00/oz" a day after the visible one was fixed. One
# implementation, two callers.
#
# WHY compare-deals NEEDS IT (the gap this closes):
#   known-wrong.json was read only by audit-known-wrong.ps1 and guards.ps1, BOTH of which run after the
#   board is built. So a ruling could block a publish but never correct a board. The wrong cell stayed on
#   the board, the gate went red, and every publish stopped until a human hand-edited a commodity rule.
#   Twenty-two accuracy findings were sitting there as tripwires rather than fixes.
#   Applied at compare time, a ruled-wrong (commodity, store, product) row is simply not eligible, so the
#   store falls through to its own next-best REAL row - which is what the shopper should have seen anyway.
#
# The functions below are VERBATIM from audit-known-wrong.ps1; do not "improve" them here without
# re-running that audit, whose published counts depend on this exact normal form.

# ---------------------------------------------------------------- normalizer
# Every non-alphanumeric byte becomes a space, so this is ENCODING-AGNOSTIC on purpose: "Coste" + n-tilde
# read as UTF-8 and the same bytes read as ANSI both land on the same normal form. Apostrophes are deleted
# rather than spaced so "Ken's" folds onto "Kens", and a stranded possessive "s" is re-joined so Aldi's
# "Clancy S Original Potato Chips" folds onto "Clancy's Original Potato Chips".
$KW_UNIT_TOKENS = @('oz','ozs','fl','lb','lbs','pound','pounds','ct','count','pk','pkg','pack','packs','pcs','pc','piece','pieces','g','gr','gram','grams','kg','ml','l','liter','liters','qt','quart','gal','gallon','each','ea','in','inch','sq','ft','roll','rolls','bag','bags','box','boxes','can','cans','bottle','bottles','jar','jars','pouch','pouches','tub','tubs','tray','trays','carton','cartons','case','cases','container','containers','sheet','sheets','load','loads','serving','servings','bar','bars','slice','slices','cup','cups','tbsp','tsp','pt','pint','pints')
function KwNorm([string]$Raw) {
  $s = ($Raw + '')
  if ($s.Length -eq 0) { return '' }
  $s = $s.Replace([string][char]0x2019, "'").Replace([string][char]0x2018, "'").Replace([string][char]0x00B4, "'").Replace([string][char]0x0060, "'")
  $s = $s.ToLower()
  $s = $s -replace "'", ''
  $s = $s -replace '[^a-z0-9]+', ' '
  $s = $s.Trim()
  if ($s.Length -eq 0) { return '' }
  $s = $s -replace '(?<=[a-z0-9]) s(?= |$)', 's'
  return (($s -replace '\s+', ' ').Trim())
}
function KwCore([string]$Norm) {
  $toks = @(($Norm + '') -split ' ' | Where-Object { $_ })
  $i = $toks.Count - 1
  while ($i -ge 0) {
    $t = $toks[$i]
    if ($t -match '^[0-9]+$' -or $KW_UNIT_TOKENS -contains $t) { $i-- } else { break }
  }
  if ($i -lt 0) { return '' }
  return (($toks[0..$i]) -join ' ')
}

<#
  Get-KnownWrongBlocks - the ACTIVE rulings, as a lookup compare-deals can test a row against.

  Returns a hashtable keyed "<commodityId>|<storeName>" whose value is a hashtable of normalized product
  names (both the full normal form and the unit-stripped core) that are ruled wrong for that cell.

  A REVERSED entry is skipped, exactly as the audit skips it: a reversal is the only way a ruling stops
  being enforced, and the entry stays in the file so the reversal itself is auditable. An entry with no
  usable names is skipped too rather than being allowed to match everything.
#>
function Get-KnownWrongBlocks {
  param([string]$Path)
  $out = @{}
  if (-not $Path -or -not (Test-Path $Path)) { return $out }
  $doc = $null
  try { $doc = Get-Content $Path -Raw | ConvertFrom-Json } catch { return $out }
  if (-not $doc) { return $out }
  $entries = @()
  if ($doc.PSObject.Properties.Name -contains 'entries') { $entries = @($doc.entries) }
  foreach ($e in @($entries | Where-Object { $_ })) {
    $props = $e.PSObject.Properties.Name
    # reversed => history, not a gate
    $revOn = if ($props -contains 'reversed_on') { ([string]$e.reversed_on).Trim() } else { '' }
    $revBy = if ($props -contains 'reversed_by') { ([string]$e.reversed_by).Trim() } else { '' }
    if ($revOn -and $revBy) { continue }
    $cid = if ($props -contains 'commodity') { [string]$e.commodity } else { '' }
    $st  = if ($props -contains 'store') { [string]$e.store } else { '' }
    if (-not $cid -or -not $st) { continue }
    $names = @()
    if ($props -contains 'names') { $names = @($e.names) } elseif ($props -contains 'name') { $names = @($e.name) }
    $names = @($names | Where-Object { $_ })
    if (-not $names.Count) { continue }
    $k = ($cid + '|' + $st)
    if (-not $out.ContainsKey($k)) { $out[$k] = @{} }
    foreach ($n in $names) {
      $nn = KwNorm ([string]$n)
      if ($nn) { $out[$k][$nn] = $true }
      $cc = KwCore $nn
      if ($cc) { $out[$k][$cc] = $true }
    }
  }
  return $out
}

# Is this (commodity, store, product name) ruled wrong? Tested on BOTH the full normal form and the
# unit-stripped core, because a store re-listing the same product with a new pack size must not escape a
# ruling by renaming "... 12 Oz" to "... 16 Oz".
function Test-KnownWrong {
  param([hashtable]$Blocks, [string]$CommodityId, [string]$Store, [string]$ProductName)
  if (-not $Blocks -or $Blocks.Count -eq 0) { return $false }
  $k = ([string]$CommodityId + '|' + [string]$Store)
  if (-not $Blocks.ContainsKey($k)) { return $false }
  $set = $Blocks[$k]
  $nn = KwNorm ([string]$ProductName)
  if (-not $nn) { return $false }
  if ($set.ContainsKey($nn)) { return $true }
  $cc = KwCore $nn
  if ($cc -and $set.ContainsKey($cc)) { return $true }
  return $false
}
