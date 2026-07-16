<#
  pu-lib.ps1 - THE single per-unit implementation. Dot-source it; never re-type it.

  WHY THIS FILE EXISTS: there were two of these. build-deals-page / generate-board-overrides /
  audit-board-consistency computed a link's per-unit with LinkPU(); guards.ps1 / audit-everyday-mismatch /
  prune-bad-links computed it with a weaker Qty(). They disagreed, and every disagreement was invisible:

    * Qty() returned 0 for sizes LinkPU handles fine - "per lb", "dozen", a bare "lb", "24 fl oz" against an
      oz commodity, and a unit-price string like "$0.07/oz" parked in the size field. A 0 meant "cannot
      judge", and the audits SKIP what they cannot judge. So 185 of 2,156 linked everyday cells (8.6%) were
      never checked by the factor guard, while the guard reported "0 mismatches" as though it had checked
      them all. A blind spot that reports itself as a clean bill of health is worse than no guard.
    * Qty()'s number pattern was ([\d.]+), which matches a LONE ".". [double]"." throws, and guards.ps1 runs
      under $ErrorActionPreference='Stop', so one such size would have aborted the whole gate.
    * Earlier the same split made prune-bad-links drop 268 links where the audit only judged 254 bad.

  A gate judged by different arithmetic than the page it is gating is not a gate. One function, one answer.
  Returns $null when the size genuinely carries no unit basis - callers must treat $null as "unknown",
  never as zero.
#>

function Get-LinkPerUnit {
  param([string]$size, [string]$unit, [double]$price, [string]$name = '')

  $s = ([string]$size).ToLower().Trim()

  # 1. an explicit unit price already in the size field ("$0.07/oz", "0.12 / lb") wins outright
  $up = [regex]::Match($s, '\$?\s*([0-9]+(?:\.[0-9]+)?)\s*/\s*(fl\s*oz|floz|oz|lb|ea|each|ct|count)')
  if ($up.Success) {
    $v = [double]$up.Groups[1].Value
    $un = ($up.Groups[2].Value -replace '\s','') -replace 'fl',''
    switch ($unit) {
      'lb'    { if ($un -eq 'lb') { return $v }; if ($un -eq 'oz') { return $v * 16 } }
      'oz'    { if ($un -eq 'oz') { return $v }; if ($un -eq 'lb') { return $v / 16 } }
      'floz'  { if ($un -match 'oz') { return $v }; if ($un -eq 'lb') { return $v / 16 } }
      'each'  { if ($un -match '^(ea|each|ct|count)$') { return $v }; return $price }
      'dozen' { if ($un -match '^(ea|each|ct|count)$') { return $v * 12 }; return $price }
    }
  }

  if ($price -le 0) { return $null }

  $n = $null; $un = ''; $mpDone = $false

  # 2. multipack stated PACK-FIRST as "N pk/pack M <weight>" ("6 pk 4 oz", "2 pk 48 fl oz", "2 pk 1 gal"):
  #    the TOTAL is N*M in the weight/volume unit. This MUST be tried before the generic quantity match
  #    below, which lists 'pk' as a unit and so greedily reads "N pk" as the quantity, loses the per-item
  #    weight, and returns null - the exact reason 17 real multipack cells (applesauce 6pk, lemon-juice
  #    2pk, ...) sat unverified. Pack-first is fully resolved here; the weight-first multiply in step 4 is
  #    then skipped so we never multiply the pack count in twice.
  #    ONLY for weight/volume commodities. For an 'each'/'dozen' commodity, "4 pk 4 oz" means 4 ITEMS, not
  #    16 oz - collapsing it to a per-ounce number the 'each' switch then drops was a regression the
  #    differential test caught (fruit-cups, pudding-cups, microwave-popcorn). Those fall through to the
  #    generic match, which reads "N pk" as the count ($un='pk' -> price/N) exactly as before.
  #    'x' is the SAME form with a different spelling ("12 x 12 fl oz"), and it was not handled: the generic
  #    match below cannot read "12" followed by "x", so it slid to the SECOND number and returned 12 fl oz for
  #    a 144 fl oz case - a live 12x error on soda|Hy-Vee ($0.3933/floz published against a true $0.0328).
  #    Same bug family as the "6-pack 12 fl oz" hyphen case; only the separator differs.
  if ($unit -in @('oz','floz','lb','gallon')) {
    $mp = [regex]::Match($s, '([0-9]+)\s*(?:pk|pack|x|×)\s*([0-9]+(?:\.[0-9]+)?)\s*(fl\s*oz|floz|oz|lbs?|pound|gal|gallon|qt|quart|ml|ltr|liters?|litres?|l)\b')
    if ($mp.Success) {
      $n = [double]$mp.Groups[1].Value * [double]$mp.Groups[2].Value
      $un = ($mp.Groups[3].Value -replace '\s','') -replace 'fl','' -replace '^gallon$','gal' -replace '^quart$','qt' -replace '^pound$','lb' -replace '^(ltr|liters?|litres?)$','l'
      $mpDone = $true
    }
  }

  if (-not $mpDone) {
    # 2b. a quantity + unit anywhere in the size. NOTE the number pattern: (\d+(?:\.\d+)?), NOT ([\d.]+) -
    #     the latter matches a bare "." and [double]"." throws.
    # 'ltr'/'liter'/'litre' must be listed AFTER 'ml' (so "12 ml" still reads as ml) and BEFORE the bare 'l'.
    # The converter below has always known litres - it was the SIZE pattern that did not: the bare 'l\b' cannot
    # match "2 ltr" because a 't' follows the 'l', so soda came back unpriceable rather than wrong. A parse gap
    # that returns $null is the safe failure mode, but it is still a gap; 2 real cells sat unverifiable on it.
    $q = [regex]::Match($s, '(\d+(?:\.\d+)?)\s*(fl\s*oz|floz|oz|lbs?|pound|ct|count|ea|pk|gal|gallon|qt|quart|dozen|doz|ml|ltr|liters?|litres?|l)\b')
    if ($q.Success) {
      $n = [double]$q.Groups[1].Value
      $un = (($q.Groups[2].Value -replace '\s','') -replace 'fl','') -replace '^(ltr|liters?|litres?)$','l'
    } else {
      # 3. a BARE unit with no number ("lb", "per lb", "each", "dozen", "gal") means one of it
      $bu = [regex]::Match($s, '\b(lbs?|pound|gal|gallon|dozen|doz|each|ea)\b')
      if ($bu.Success) {
        $n = 1
        $un = $bu.Groups[1].Value -replace '^gallon$','gal' -replace '^doz$','dozen' -replace '^pound$','lb'
      }
    }
  }
  if ($null -eq $n) { return $null }

  # 4. multipack in the SIZE stated WEIGHT-FIRST ("16 oz 6 pk") multiplies a weight. Skipped when the
  #    pack-first branch already ran, so "6 pk 16 oz" is not multiplied by the pack count twice.
  if (-not $mpDone) {
    $pk = [regex]::Match($s, '([0-9]+)\s*(pk|pack)\b')
    if ($pk.Success -and $n -and ($un -match '^(oz|lbs?|gal)$')) { $n = $n * [double]$pk.Groups[1].Value }
  }

  # 5. multipack in the NAME. A link whose size is just "each" but whose NAME says "24 Pack" is 24 items, not
  #    1 - without this the whole pack price publishes as the per-item price (Fareway bottled water went out
  #    at $3.87 EACH). Only for 'each' commodities, and only when the size itself carries no count.
  if ($unit -eq 'each' -and $name -and (($null -eq $n) -or ($n -eq 1))) {
    $pn = [regex]::Match(([string]$name).ToLower(), '([0-9]+)\s*(?:pk\b|pack\b|ct\b|count\b)')
    if ($pn.Success) {
      $cnt = [double]$pn.Groups[1].Value
      if ($cnt -gt 1) { return $price / $cnt }
    }
  }

  switch ($unit) {
    'lb'     { if ($un -match '^(lbs?|pound)$' -and $n) { return $price / $n }
               if ($un -eq 'oz' -and $n) { return $price / ($n / 16) }
               return $null }
    # an oz commodity linked to a product sized in FL OZ: our fl-oz sizes are stripped to 'oz' above, so this
    # resolves rather than silently scoring 0 the way the old Qty() did.
    'oz'     { if ($un -eq 'oz' -and $n) { return $price / $n }
               if ($un -match '^(lbs?|pound)$' -and $n) { return $price / (16 * $n) }
               if ($un -eq 'g' -and $n) { return $price / ($n * 0.035274) }
               if ($un -eq 'gal' -and $n) { return $price / (128 * $n) }
               if ($un -eq 'qt' -and $n) { return $price / (32 * $n) }
               return $null }
    'floz'   { if ($un -match 'oz' -and $n) { return $price / $n }
               if ($un -eq 'gal' -and $n) { return $price / (128 * $n) }
               if ($un -eq 'qt' -and $n) { return $price / (32 * $n) }
               if ($un -eq 'l' -and $n) { return $price / ($n * 33.814) }
               if ($un -eq 'ml' -and $n) { return $price / ($n * 0.033814) }
               return $null }
    'each'   { if ($un -match '^(ct|count|ea|pk)$' -and $n) { return $price / $n }
               if ($un -match '^(dozen|doz)$') { return $price / 12 }
               if ($n -eq 1) { return $price }
               return $null }
    'dozen'  { if ($un -match '^(dozen|doz)$') { return $price }
               if ($un -match '^(ct|count|ea)$' -and $n) { return $price / ($n / 12) }
               if ($n -eq 1) { return $price }
               return $null }
    'gallon' { if ($un -eq 'gal' -and $n) { return $price / $n }
               if ($un -match '^(floz|oz)$' -and $n) { return $price / ($n / 128) }
               if ($n -eq 1) { return $price }
               return $null }
    default  { return $null }
  }
  return $null
}
