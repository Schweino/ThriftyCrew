<#
  derived-size-density-lib.ps1 - is a BACK-COMPUTED package size physically possible?

  THE CLASS (2026-08-30). build-sams-deals.ps1 (and the Walmart builder forked from it) does not always
  read a package size off the product name. When the name says nothing in the unit the store PRICED by, it
  back-computes the size as linePrice / the store's own displayed unitPrice and stamps the row
  qty_basis "...; qty derived lp/up". 8,511 of 57,323 capture rows carry that stamp today. The quotient is
  the store's own arithmetic, so it is normally right - but nothing has ever asked whether its ANSWER is a
  size the product could physically have.

      "Member's Mark Peanut Oil, 35 lbs."  ad_price $55.96  sams_unit_price "$0.07/foz"
      -> stored size 55.96 / 0.07 = 799.429 fl oz
      35 lb = 15,875.7 g; peanut oil is 0.914 g/mL -> 17,369 mL = 587.3 fl oz.
      The stored size implies a density of 0.672 g/mL, below any edible oil. True rate $0.0953/fl oz.
      Priced off the derived size the cell publishes $0.07/fl oz - 26.5% under its own true rate - and
      takes the peanut-oil crown from Walmart LouAna 3 Gallon at $0.1223.

  Caught by hand, not by a guard, and blocked by a known-wrong entry - a per-product tripwire, not a rule.

  THIS IS THE CROSS-MEASURE HALF OF THE SAZON RULE. Build-Row already refuses a row when the name states a
  quantity IN THE PRICED UNIT and no reading of it reproduces the store's unit price. That rule compares
  UNIT TOKENS, so a name speaking in pounds against a price per fluid ounce is "silent in the priced unit"
  and the quotient is trusted unchallenged. Weight and volume are not the same unit, but they are not
  independent either: density binds them, and that binding is what this check spends.

  WHY EXISTING GUARDS MISS IT. audit-unit-basis-outlier's measure-kind check reads the SIZE string, and
  this one says "fl oz" - it agrees in kind with its volume-sized shelf-mates. Its ratio check needs 4+
  stores and a 4x median. Neither can see a derived size that is merely wrong.

  ---- THE BAND, AND WHY IT IS NOT 0.6 ----------------------------------------------------------------
  The obvious band to reach for is "0.6 to 1.6 g/mL, water is 1.0". Measured against the founding case,
  that band DOES NOT FIRE: peanut oil reads 0.672 and soybean oil 0.671, both comfortably inside it. A
  guard whose band cannot see its own founding bug is decorative, so the band is taken from the liquids
  that are actually sold this way instead of from round numbers:

      vanilla extract (ethanol-heavy) 0.88          the lightest real grocery liquid
      cooking + salad oils            0.91 - 0.93   peanut 0.914, canola 0.914, soybean 0.917, olive 0.915
      water, milk, broth, juice       1.00 - 1.05
      corn syrup / molasses / honey   1.38 - 1.45   the heaviest

  The band widens that real 0.88 - 1.45 range by ~15% on each side: DENSITY_FLOOR 0.75, DENSITY_CEIL 1.65.
  So a CORRECT row has to be off by more than 15% before it fires, and the two founding rows (off by 36%)
  fire with room to spare. The floor is the load-bearing edge - a derived size that is too LARGE is what
  makes a per-unit price too CHEAP, which is what wins a crown.

  ---- WHAT IT REFUSES TO JUDGE -----------------------------------------------------------------------
  The check needs the name's weight to BE the package weight, and it will not assume that. It abstains,
  out loud and counted, when it cannot know:

    - THE MULTIPACK, and this is the one that carries the check. A name that states the size of ONE unit
      of a multi-unit pack looks exactly like a bad derivation: Capri Sun "10 Pouches ... 6 oz" derives
      60.303 fl oz and reads 0.095 g/mL. The discriminator is not a keyword - "Knorr Professional
      Ultimate Liquid Concentrated Chicken Base, Shelf Stable, 32oz" derives 127.853 fl oz and says
      nothing about being a case of four - it is ARITHMETIC: a multipack's derived size is an integer
      multiple of the name's stated size. Measured over every flagged row in this estate, that separates
      the two populations completely:

          derived / stated     row
              10.05            Capri Sun, 10 Pouches, 6 oz
               6.07            Kemps IttiBitz 1.4 oz / 6 Pak
               5.99            Kool-Aid Bursts, 6 Bottles, 6.75 oz
               4.01            Sprayway Glass Cleaner, 19 oz., Choose Pack Size
               4.00            Knorr chicken base 32 oz            <- no pack marker in the name at all
               2.00            1-2-3 Vegetable Oil Red Label, 16.9 oz
               2.00            Zevo, Two 12 oz Sprays
          ------------------------------------------------------ every real defect is a NON-integer
               1.43            Member's Mark Peanut Oil, 35 lbs.
               1.43            Member's Mark Pure Soybean Oil, 35 lbs.
               0.33            Melinda's Jalapeno Ketchup, 12 Ounce

      So the check abstains when the ratio is within tolerance of a whole number from 2 to 48. The ratio
      is taken between the NUMERALS, treating a weight ounce and a fluid ounce as the same nominal unit
      (they are 4.2% apart) and a pound as 16 of them - converting to grams first would drag that 4.2%
      into the ratio and push a genuine 10-pack to 10.48. The cost is real and stated: a defect that
      happens to be exactly 2x or 3x is indistinguishable from a 2-pack or a 3-pack, and is abstained
      rather than flagged. It is reported under its own reason so it can be read.

    - the name carries a pack marker whose COUNT is unknowable, so no ratio can be checked against it:
      "Choose Pack Size", "Variety", "Bundle", "Case". Deliberately short - the arithmetic above is the
      instrument, and a long keyword list would start excusing rows on the strength of a word.
    - the name states more than one distinct weight, so which one is the package is a guess.
    - the store's displayed unit price is too coarse for the quotient to mean anything. unitPrice is
      rounded, so the derived size carries half-an-ulp/up of pure rounding error: 7% at Sam's $0.07/foz,
      but 25% at $0.02 and 50% at $0.01. Above 25% no density statement about the quotient is worth
      making, and Build-Row's own Q-tips comment says the same thing about the same quotient.
  Abstentions are REPORTED, never counted as agreement (could-not-run-is-not-a-failure).

  WEIGHT-OZ vs FLUID-OZ in a name is safe to get wrong, and that is why bare "oz" is in scope. An avdp
  ounce is 28.3495 g and a US fluid ounce of water is 29.5735 g - 4.2% apart. Misreading one for the other
  moves the implied density by 4.2%, a sixth of the margin the band already carries. Explicit "fl oz" /
  "fluid ounce" tokens are stripped before the scan anyway, so the common case never even arises.

  WHY A LIB AND NOT A COPY IN THE TEST: the frozen fixtures and the live arm must run the SAME code, the
  same reason as unit-vocabulary-lib.ps1 and dead-commodity-lib.ps1. And the qty_basis marker is READ OUT
  OF build-sams-deals.ps1 rather than retyped, so the day that string changes this check follows it
  instead of silently matching nothing and reporting all clear.
#>

# Exact conversions. No approximations here: the whole check is one division, and a sloppy constant would
# spend margin the band is holding for real defects.
$script:G_PER_LB    = 453.59237
$script:G_PER_OZ    = 28.349523125
$script:ML_PER_FLOZ = 29.5735295625

# The band, derived above. Named once so the fixtures and the live arm cannot disagree about it.
$script:DENSITY_FLOOR = 0.75
$script:DENSITY_CEIL  = 1.65
# Above this relative rounding error on the displayed unit price, the quotient is not a measurement.
$script:MAX_ROUND_ERR = 0.25

function Get-DensityBand {
  return [pscustomobject]@{ Floor = $script:DENSITY_FLOOR; Ceil = $script:DENSITY_CEIL; MaxRoundErr = $script:MAX_ROUND_ERR }
}

# THE MARKER, read out of the builder that writes it. Build-Row sets `$basis = 'derived lp/up'` and emits
# qty_basis as ($shape + '; qty ' + $basis). Retyping the literal here would mean the day someone reworded
# it, this check would match zero rows and report all clear - the shape of failure this estate keeps
# paying for. Returns $null when it cannot read it: BLIND, which the caller must report as a failure
# rather than as agreement.
function Get-DerivedQtyMarker([string]$Root) {
  $f = Join-Path $Root 'build-sams-deals.ps1'
  if (-not (Test-Path $f)) { return $null }
  $src = Get-Content $f -Raw
  # Build-Row assigns $basis twice - once to the derived marker, once to the name-reproduces-unit-price
  # one - so take the assignment that is about deriving rather than whichever comes first in the file.
  # The pattern is single-quoted so the regex sees a literal `$basis`, not an expanded variable: written
  # in double quotes, "\$basis" is a backslash followed by an EMPTY expansion of $basis, and the match
  # silently never fires. (Measured: it returned $null on the real file.)
  $b = $null
  foreach ($m in [regex]::Matches($src, '(?m)^\s*\$basis\s*=\s*''(?<b>[^'']{4,60})''\s*$')) {
    $c = [string]$m.Groups['b'].Value
    if ($c -match 'derived') { $b = $c; break }
  }
  # PARSE-INTEGRITY ANCHOR, not a second copy of the marker: an empty or runaway match would make the
  # sweep examine nothing or everything, and both of those read as clean.
  if (-not $b) { return $null }
  return $b
}

function Test-RowIsDerived($row, [string]$Marker) {
  if (-not $Marker) { return $false }
  if (-not $row) { return $false }
  if (-not $row.PSObject.Properties['qty_basis']) { return $false }
  return (([string]$row.qty_basis).Contains($Marker))
}

# A capture `size` string -> millilitres, or $null when it is not a volume at all (a weight, a count, or
# anything unparseable). Deliberately strict: it must be exactly "<number> <volume unit>", the shape
# Format-Qty writes, so a half-understood string is declined rather than guessed at.
function ConvertTo-MilliLitres([string]$Size) {
  if (-not $Size) { return $null }
  $s = ([string]$Size).Trim().ToLower()
  $m = [regex]::Match($s, '^(?<n>\d[\d,]*(?:\.\d+)?)\s*(?<u>[a-z. ]+?)\.?$')
  if (-not $m.Success) { return $null }
  $u = (($m.Groups['u'].Value) -replace '\.', '' -replace '\s+', ' ').Trim()
  $f = $null
  switch ($u) {
    'fl oz'         { $f = $script:ML_PER_FLOZ }
    'floz'          { $f = $script:ML_PER_FLOZ }
    'foz'           { $f = $script:ML_PER_FLOZ }
    'fluid ounce'   { $f = $script:ML_PER_FLOZ }
    'fluid ounces'  { $f = $script:ML_PER_FLOZ }
    'gal'           { $f = 3785.411784 }
    'gallon'        { $f = 3785.411784 }
    'gallons'       { $f = 3785.411784 }
    'qt'            { $f = 946.352946 }
    'quart'         { $f = 946.352946 }
    'quarts'        { $f = 946.352946 }
    'pt'            { $f = 473.176473 }
    'pint'          { $f = 473.176473 }
    'pints'         { $f = 473.176473 }
    'cup'           { $f = 236.5882365 }
    'cups'          { $f = 236.5882365 }
    'l'             { $f = 1000.0 }
    'liter'         { $f = 1000.0 }
    'liters'        { $f = 1000.0 }
    'litre'         { $f = 1000.0 }
    'litres'        { $f = 1000.0 }
    'ml'            { $f = 1.0 }
  }
  if ($null -eq $f) { return $null }
  $n = [double](($m.Groups['n'].Value) -replace ',', '')
  if ($n -le 0) { return $null }
  return ($n * $f)
}

# Every WEIGHT the product name states, in grams AND in nominal ounces. Fluid-ounce tokens are stripped
# first, so the number in front of one can never be read as a weight.
#   Grams      - for the density arithmetic, exact.
#   NominalOz  - for the multipack ratio, DELIBERATELY not exact: a pound is 16 of whatever ounce the
#                store meant, and the size string's fluid ounces are counted as the same nominal unit.
#                See the ratio note in the header - converting to grams here is what breaks it.
# Returns a (possibly empty) array of @{Grams; NominalOz; Text}.
function Get-NameStatedWeights([string]$Name) {
  $out = @()
  if (-not $Name) { return ,@($out) }
  $n = [string]$Name
  # strip explicit fluid measures - "16.9 fl. oz." must not contribute a weight
  $n = [regex]::Replace($n, '(?i)\bfl\.?\s*oz\.?', ' ')
  $n = [regex]::Replace($n, '(?i)\bfluid\s+ounces?\b', ' ')
  foreach ($m in [regex]::Matches($n, '(?i)(?<![\d.])(?<n>\d[\d,]*(?:\.\d+)?)\s*(?:lbs|lb|pounds|pound)(?![a-z])')) {
    $q = [double](($m.Groups['n'].Value) -replace ',', '')
    $out += [pscustomobject]@{ Grams = ($q * $script:G_PER_LB); NominalOz = ($q * 16.0); Text = $m.Value.Trim() }
  }
  foreach ($m in [regex]::Matches($n, '(?i)(?<![\d.])(?<n>\d[\d,]*(?:\.\d+)?)\s*(?:ounces|ounce|ozs|oz)(?![a-z])')) {
    $q = [double](($m.Groups['n'].Value) -replace ',', '')
    $out += [pscustomobject]@{ Grams = ($q * $script:G_PER_OZ); NominalOz = $q; Text = $m.Value.Trim() }
  }
  return ,@($out)
}

# Does the name declare a pack whose COUNT cannot be read? Deliberately SHORT: the multipack test that
# does the real work is Get-PackMultiple below, which is arithmetic. This list covers only the names that
# announce a pack while refusing to say how many, where no ratio can be checked against anything. Every
# word here has to earn its place, because each one excuses rows on the strength of a word rather than a
# number - which is how a narrow abstention turns into a blanket.
function Test-NamePackAmbiguous([string]$Name) {
  if (-not $Name) { return $false }
  return ([bool]([regex]::IsMatch([string]$Name, '(?i)(choose\s+(pack\s+size|size|count)|\bvariety\b|\bassort|\bbundle\b|\bcase\s+of\b)')))
}

# THE MULTIPACK TEST. Returns the whole number of named units the derived size works out to (2..48), or
# $null when the ratio is not a whole number and the row therefore is not pack-shaped. $Tolerance is the
# fraction of n the ratio may miss by; the caller passes the row's own unit-price rounding error, floored
# at the 5% that the weight-ounce/fluid-ounce conflation is worth.
function Get-PackMultiple([double]$DerivedNominal, [double]$StatedNominal, [double]$Tolerance) {
  if ($StatedNominal -le 0 -or $DerivedNominal -le 0) { return $null }
  $ratio = $DerivedNominal / $StatedNominal
  $n = [math]::Round($ratio)
  if ($n -lt 2 -or $n -gt 48) { return $null }
  if ([math]::Abs($ratio - $n) / $n -gt $Tolerance) { return $null }
  return [int]$n
}

# THE UNIT THE STORE PRICED BY, normalised into the engine's own vocabulary (2026-09-04, queue
# 2026-09-04-def37c). The stores write the same unit five ways - Sam's "$0.14/foz", Walmart "37.3 c/fl oz",
# "$1.73/count", "$2.37/ea" - and the number is worthless to a cross-check until you know whether it is the
# SAME KIND of unit the commodity is priced in. Measured over today's captures: oz, fl oz, foz, ea, count, lb.
#
# FLUID OUNCES ARE TESTED BEFORE OUNCES, and that order is the whole function. "fl oz" contains "oz", so an
# oz-first test reads a per-fluid-ounce price as a per-weight price - the unit-label-vs-unit-magnitude class
# this estate has already paid for once (an "each == each" that differed 16x).
# An unrecognised unit returns '' rather than a guess: a cross-check that cannot name the unit must abstain,
# not assume the units agree.
function ConvertTo-DisplayedUnitToken([string]$Text) {
  if (-not $Text) { return '' }
  # only what follows the slash is the unit; "$0.05/oz" and "37.3 c/fl oz" both put it there
  $u = $Text
  $slash = $Text.LastIndexOf('/')
  if ($slash -ge 0) { $u = $Text.Substring($slash + 1) }
  $u = $u.Trim().ToLower() -replace '[\.\s]+', ' '
  $u = $u.Trim()
  if ($u -match '^(fl(uid)?\s*oz(s)?|floz|foz)$')     { return 'floz' }
  if ($u -match '^(oz|ozs|ounce|ounces)$')            { return 'oz' }
  if ($u -match '^(lb|lbs|pound|pounds)$')            { return 'lb' }
  if ($u -match '^(ea|each|ct|count|pk|pack|pieces?)$') { return 'each' }
  return ''
}

# The store's displayed unit price, in dollars, WITH the half-width of its own rounding, AND the unit it
# is quoted in. Sam's writes "$0.07/foz" (2 decimals -> +/- $0.005); Walmart writes "50.7 c/fl oz"
# (1 decimal on cents -> +/- $0.0005). The half-width is read from the literal's own precision rather than
# assumed, because the abstention below is precisely a statement about how coarse that number is.
# Unit is ADDITIVE: every existing caller reads Value/Half/Text/Field and is unaffected.
function Get-DisplayedUnitPrice($row) {
  if (-not $row) { return $null }
  foreach ($f in @('sams_unit_price', 'wm_unit_price', 'unit_price')) {
    if (-not $row.PSObject.Properties[$f]) { continue }
    $t = ([string]$row.$f).Trim()
    if (-not $t) { continue }
    $m = [regex]::Match($t, '(?<n>\d[\d,]*(?:\.(?<d>\d+))?)')
    if (-not $m.Success) { continue }
    $v = [double](($m.Groups['n'].Value) -replace ',', '')
    $dec = 0
    if ($m.Groups['d'].Success) { $dec = $m.Groups['d'].Value.Length }
    $half = 0.5 * [math]::Pow(10, -$dec)
    # cents -> dollars, in BOTH the value and its half-width
    if ($t -match ([char]0x00A2) -or $t -match '(?i)\bcents?\b') { $v = $v / 100.0; $half = $half / 100.0 }
    if ($v -le 0) { continue }
    return [pscustomobject]@{ Value = $v; Half = $half; Text = $t; Field = $f; Unit = (ConvertTo-DisplayedUnitToken $t) }
  }
  return $null
}

# THE RULE. Returns a verdict object every time - never $true/$false, because "I did not judge this row"
# and "this row is fine" are different answers, and collapsing them is how a sweep reports all clear over
# rows it never looked at.
#   Status: 'skip'    - not in scope (not derived, or the size is not a volume, or the name states no weight)
#           'abstain' - in scope but not judgeable; Why says which of the reasons
#           'ok'      - judged, implied density inside the band
#           'flag'    - judged, implied density outside the band
function Test-DerivedSizeDensity($row, [string]$Marker) {
  $v = [pscustomobject]@{ Status = 'skip'; Density = $null; Grams = $null; MilliLitres = $null; WeightText = ''; Why = '' }
  if (-not (Test-RowIsDerived $row $Marker)) { $v.Why = 'qty_basis does not say the quantity was derived'; return $v }
  $size = ''
  if ($row.PSObject.Properties['size']) { $size = [string]$row.size }
  $ml = ConvertTo-MilliLitres $size
  if ($null -eq $ml) { $v.Why = ("derived size '" + $size + "' is not a volume"); return $v }
  $name = ''
  if ($row.PSObject.Properties['item']) { $name = [string]$row.item }
  # NOT @(Get-NameStatedWeights ...). The function comma-wraps its return so the array survives the
  # pipeline, and @() around a call that already did that wraps it a SECOND time: the result is a 1-element
  # array whose element is the real array, so $ws[0].Grams is an Object[] and an empty result counts 1.
  # Measured here today, both ways round. Assign the call, then use the variable.
  $ws = Get-NameStatedWeights $name
  if (@($ws).Count -eq 0) { $v.Why = 'the name states no weight to check the derived volume against'; return $v }

  $v.MilliLitres = $ml
  $distinct = @($ws | ForEach-Object { [math]::Round([double]$_.Grams, 3) } | Select-Object -Unique)
  if ($distinct.Count -gt 1) {
    $v.Status = 'abstain'
    $v.Why = ('the name states ' + $distinct.Count + ' different weights (' + ((@($ws) | ForEach-Object { $_.Text }) -join ', ') + ') - which one is the package is a guess')
    return $v
  }
  if (Test-NamePackAmbiguous $name) {
    $v.Status = 'abstain'
    $v.Why = 'the name declares a pack without saying how many, so its stated weight is per-unit and no ratio can be checked against it'
    return $v
  }
  $up = Get-DisplayedUnitPrice $row
  if ($null -eq $up) {
    $v.Status = 'abstain'
    $v.Why = 'the row carries no displayed unit price, so the rounding error on its own quotient cannot be measured'
    return $v
  }
  $rel = $up.Half / $up.Value
  if ($rel -gt $script:MAX_ROUND_ERR) {
    $v.Status = 'abstain'
    $v.Why = ('the displayed unit price ' + $up.Text + ' is rounded to +/-' + [math]::Round([double]$rel * 100, 1) + '% of itself, so the derived size is that uncertain before anything is wrong')
    return $v
  }
  # THE MULTIPACK TEST, last of the abstentions because it needs the row's own rounding error as its
  # tolerance. A derived size that is a whole-number multiple of the named size is what a pack of that
  # many looks like, and is not evidence of a bad quotient - see the ratio table in the header.
  $pk = Get-PackMultiple ([double]$ml / $script:ML_PER_FLOZ) ([double]$ws[0].NominalOz) ([math]::Max(0.05, $rel))
  if ($null -ne $pk) {
    $v.Status = 'abstain'
    $v.Why = ('the derived size is ' + $pk + 'x the ' + $ws[0].Text + ' the name states, so the row is shaped like a ' + $pk + '-pack of the named unit rather than like a bad quotient')
    return $v
  }

  $v.Grams = $ws[0].Grams
  $v.WeightText = $ws[0].Text
  $v.Density = $ws[0].Grams / $ml
  if ($v.Density -lt $script:DENSITY_FLOOR -or $v.Density -gt $script:DENSITY_CEIL) {
    $v.Status = 'flag'
    $v.Why = ('the name states ' + $ws[0].Text + ' = ' + [math]::Round([double]$ws[0].Grams, 0) + ' g but the derived size is ' + $size + ' = ' + [math]::Round([double]$ml, 0) + ' mL, an implied density of ' + [math]::Round([double]$v.Density, 3) + ' g/mL - outside ' + $script:DENSITY_FLOOR + '-' + $script:DENSITY_CEIL + ' g/mL, which no grocery liquid is')
  } else {
    $v.Status = 'ok'
    $v.Why = ('implied density ' + [math]::Round([double]$v.Density, 3) + ' g/mL')
  }
  return $v
}

# ---- RULED ROWS (the valve) -------------------------------------------------------------------------
# A flagged row is WRONG DATA, not a deliberate state, and it cannot be fixed where it sits: a capture is
# what the store said, and editing one launders evidence (dates-written-not-measured). So the valve is a
# ledger of rows a reasoner has ADJUDICATED and written the arithmetic for, and it pins the SIZE. That is
# the load-bearing part: the day the store's derivation changes - whether it gets fixed or gets a NEW
# wrong value - the ruling stops covering the row and the guard fires again. A ruling keyed on the product
# alone would silence that product forever, which is how a narrow exception becomes a permanent hole.
#
# NOT known-wrong.json, which is the instrument one level down: that file blocks a (commodity, store,
# product) from a BOARD CELL, and its commodity-retired predicate retires any entry whose commodity id is
# not in commodities.json. Member's Mark Pure Soybean Oil matches no commodity at all today, so a
# known-wrong entry for it would be reported retired and enforce nothing. The defect is in the CAPTURE and
# has to be ruled where it lives.
function Get-DerivedSizeRulings([string]$Root) {
  $p = Join-Path $Root 'derived-size-density-rulings.json'
  if (-not (Test-Path $p)) { return ,@() }
  $doc = Get-Content $p -Raw | ConvertFrom-Json
  if ($null -eq $doc) { return ,@() }
  if ($doc.PSObject.Properties['rulings']) { return ,@($doc.rulings) }
  return ,@($doc)
}

# The same normalisation known-wrong.json uses for product names, so a ruling survives the pipeline's own
# re-encodings of a name (smart quote vs mojibake pair, "Member's" vs "Members") without folding two
# different products together.
function ConvertTo-RulingName([string]$Name) {
  $s = ([string]$Name).ToLower() -replace "'", '' -replace ([char]0x2019), ''
  $s = [regex]::Replace($s, '[^a-z0-9]+', ' ')
  return $s.Trim()
}

# Returns Ruled (bool) + Why (always populated, so the caller can print either the ruling it honoured or
# the reason it refused to). A half-written entry is a REFUSAL, never a pass.
function Test-DerivedSizeRuling([string]$Store, [string]$Name, [string]$Size, $Rulings) {
  $nk = ConvertTo-RulingName $Name
  $sk = ([string]$Size).Trim().ToLower()
  foreach ($r in @($Rulings)) {
    if ((ConvertTo-RulingName ([string]$r.name)) -ne $nk) { continue }
    if (((([string]$r.size).Trim()).ToLower()) -ne $sk) { continue }
    if ((([string]$r.store).Trim()) -ne (([string]$Store).Trim())) { continue }
    $reason = ''; $review = ''; $by = ''
    if ($r.PSObject.Properties['reason'])    { $reason = ([string]$r.reason).Trim() }
    if ($r.PSObject.Properties['review_by']) { $review = ([string]$r.review_by).Trim() }
    if ($r.PSObject.Properties['ruled_by'])  { $by     = ([string]$r.ruled_by).Trim() }
    if (-not $reason) { return [pscustomobject]@{ Ruled = $false; Why = ("a ruling exists for '" + $Name + "' at size '" + $Size + "' but carries NO reason - an unexplained ruling is not a ruling") } }
    if (-not $by)     { return [pscustomobject]@{ Ruled = $false; Why = ("a ruling exists for '" + $Name + "' at size '" + $Size + "' but names NOBODY who ruled it") } }
    if (-not $review) { return [pscustomobject]@{ Ruled = $false; Why = ("a ruling exists for '" + $Name + "' at size '" + $Size + "' but carries NO review_by date - a ruling nobody has to revisit is a permanent hole") } }
    return [pscustomobject]@{ Ruled = $true; Why = ('ruled by ' + $by + ', review_by ' + $review + ': ' + $reason) }
  }
  return [pscustomobject]@{ Ruled = $false; Why = ("no ruling covers '" + $Name + "' at derived size '" + $Size + "'") }
}

# ---- THE CAPTURE SET --------------------------------------------------------------------------------
# Every capture file written by a builder that can stamp `qty derived lp/up`: Sam's, and the Walmart
# builder forked from it (its rows carry the same marker and the same quotient, in a wm_unit_price field
# denominated in cents). Historical files are IN SCOPE on purpose - compare-deals unions slices across a
# 14-day window, and a thin dated file can be promoted into the newest capture, so "it is not today's
# file" is not a reason a row cannot reach the board.
function Get-DerivedCaptureFiles([string]$Root) {
  $out = @()
  foreach ($g in @('out\sams\sams-deals-*.json', 'out\regular\walmart-regular-*.json')) {
    $out += @(Get-ChildItem (Join-Path $Root $g) -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
  }
  return ,@($out)
}

# One capture file's rows. The header-wrapped shape ({store, captured, deals:[...]}) and a bare array are
# both read; `@(Get-Content | ConvertFrom-Json)` does NOT unroll a top-level JSON array in PS 5.1 - it
# counts 1 - so the assignment happens first.
function Read-CaptureRows([string]$Path) {
  $doc = Get-Content $Path -Raw | ConvertFrom-Json
  if ($null -eq $doc) { return ,@() }
  if ($doc.PSObject.Properties['deals']) { return ,@($doc.deals) }
  return ,@($doc)
}
