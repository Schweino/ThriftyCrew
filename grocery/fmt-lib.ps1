# fmt-lib.ps1 - THE per-unit price formatter for every board surface.
#
# Extracted from build-deals-page.ps1 on 2026-07-31 so the formatter has a REACHABLE self-test. It used to
# be a private function halfway down a 1,500-line builder that loads five data files before it is defined,
# which meant the only way to exercise it was to build the whole board - so nobody ever did, and two display
# bugs sat live for weeks (see the fixtures below). A guard whose fixture cannot reach the code is not a
# guard; that is the fix-needs-reachable-selftest lesson, applied to a formatter.
#
#   . .\fmt-lib.ps1                                     dot-source (what the builder does)
#   powershell -File .\fmt-lib.ps1 -SelfTest            run the frozen fixtures (what test-auditors does)
param([switch]$SelfTest)

# THE ONE MONEY ROUNDING RULE (Brad's ruling, 2026-09-19, backlog I186 and I202). Every displayed price is
# first converted to an EXACT DECIMAL from its shortest round-trip spelling - the decimal the board JSON
# carries - and then rounded HALF UP (away from zero) to cents: 1.125 -> 1.13, 0.125 -> 13 cents,
# 1.005 -> 1.01. Every path below goes through these two helpers; none rounds a [double] itself.
#
# Until that ruling the file ran THREE behaviours and its own comment claimed one. The '{0:N2}' -f dollar
# branch rounded the double's 15-digit spelling half away from zero; [math]::Round($v,2) and the oz cents
# branch's [math]::Round($v*100) multiplied IN DOUBLE and rounded the product half to even, so 1.145
# (1.145*100 is exactly 114.5) came back 1.14 and 1.005 (1.005*100 is 100.49999999999999) came back 1.00.
# The same price could read a cent apart on the deals page and on its trend page. The sweep fixture at the
# end of the self-test is the measured account, and backlog I186 records how many cents the old paths moved.
#
# WHY 'R' AND NOT [decimal]$v. A [decimal] cast of a double keeps 15 significant digits; 'R' is the shortest
# spelling that round-trips, which is exactly the decimal the JSON carried for any value up to 15 digits.
# A caller holding ConvertFrom-Json's System.Decimal passes it through the [double] parameters unchanged in
# meaning: the double nearest 1.005 spells back as "1.005". The mode is named explicitly because the
# '{0:N2}' format's own midpoint rule changes to ToEven on .NET Core 2.1+ (PowerShell 7) with no code change.
# A non-finite value (NaN, Infinity) cannot be a decimal and keeps the format it always had.
function ConvertTo-TcMoneyDecimal([double]$v) {
  $inv = [System.Globalization.CultureInfo]::InvariantCulture
  return [decimal]::Parse($v.ToString('R', $inv), [System.Globalization.NumberStyles]::Float, $inv)
}
# Dollars and cents, two places, half up on the exact decimal. Culture formatting ('{0:N2}') is unchanged,
# so the thousands separator is exactly what every page printed before; the value it formats is already
# rounded, so N2 has nothing left to round.
function Format-TcMoney2([double]$v) {
  if ([double]::IsNaN($v) -or [double]::IsInfinity($v)) { return ('{0:N2}' -f $v) }
  $r = [decimal]::Round((ConvertTo-TcMoneyDecimal $v), 2, [System.MidpointRounding]::AwayFromZero)
  return ('{0:N2}' -f $r)
}
# Whole cents, half up on the exact decimal: the oz / fl oz cents branch.
function Get-TcMoneyCents([double]$v) {
  if ([double]::IsNaN($v) -or [double]::IsInfinity($v)) { return [math]::Round($v * 100) }
  $d = (ConvertTo-TcMoneyDecimal $v) * 100
  return [decimal]::Round($d, 0, [System.MidpointRounding]::AwayFromZero)
}

function Fmt-Price([double]$v, [string]$unit) {
  # SUB-CENT IS REAL, NOT A BUG. Verified 2026-07-31 against comparison-2026-07-31.json: cotton-swabs is
  # priced per swab at $0.0043 each, which the dollar formatter rendered as "$0.00 each" (live on the Price
  # Records strip as "Cotton Swabs $0.00 each, ties record") and the cent formatter rounded to "0&cent;".
  # The number was right; two decimal places was what was wrong.
  if ($v -gt 0 -and $v -lt 0.01) {
    $c = '{0:N1}' -f ($v * 100)
    switch ($unit) {
      'oz'    { return ($c + '&cent;/oz') }
      'floz'  { return ($c + '&cent;/fl oz') }
      'lb'    { return ($c + '&cent;/lb') }
      'gallon'{ return ($c + '&cent;/gal') }
      'dozen' { return ($c + '&cent;/dozen') }
      'each'  { return ($c + '&cent; each') }
      default { return ($c + '&cent;') }
    }
  }
  switch ($unit) {
    # ROLLOVER. The oz/floz branches always rendered cents and never rolled over, so an expensive per-ounce
    # item printed as "356&cent;/oz" (live: Mint (fresh) at Walmart). Nobody reads three digits of cents.
    # THE TEST IS ON THE ROUNDED CENTS, NOT THE RAW VALUE. Testing $v -ge 1 leaves a gap the width of half
    # a cent: beef jerky at $0.9962/oz is under a dollar, so it took the cents branch, and then rounded to
    # "100&cent;/oz" - the exact three-digit-cents bug this rollover exists to prevent, one cent below the
    # boundary. Rounding first and branching on the result closes it by construction.
    'oz'    { $c = Get-TcMoneyCents $v; if ($c -ge 100) { return ('$' + (Format-TcMoney2 $v) + '/oz') }; return ('' + $c + '&cent;/oz') }
    'floz'  { $c = Get-TcMoneyCents $v; if ($c -ge 100) { return ('$' + (Format-TcMoney2 $v) + '/fl oz') }; return ('' + $c + '&cent;/fl oz') }
    'lb'    { return ('$' + (Format-TcMoney2 $v) + '/lb') }
    'gallon'{ return ('$' + (Format-TcMoney2 $v) + '/gal') }
    'dozen' { return ('$' + (Format-TcMoney2 $v) + '/dozen') }
    'each'  { return ('$' + (Format-TcMoney2 $v) + ' each') }
    default { return ('$' + (Format-TcMoney2 $v)) }
  }
}
# PLAIN-TEXT twin, for anywhere the string lands inside an attribute (title="...") or a share payload.
# It has to exist because the HTML version emits &cent;, and every one of those call sites runs its text
# through HtmlEnc, which would turn the entity into a literal "&cent;" on screen. One implementation, two
# renderings: never a second copy of the rounding rules.
function Fmt-PriceText([double]$v, [string]$unit) {
  return ((Fmt-Price $v $unit) -replace '&cent;', ([char]0x00A2))
}
# THE PER-UNIT DIFFERENCE ("this much more here"). Lived as a private copy inside build-store-guide.ps1
# until 2026-08-31, alongside a second private copy of Fmt-Price that never got the sub-cent fix - which
# is why "Corn Tortillas $0.06 each  +$0.00 each  6% over" was live on /shop-smart-at-your-store/.
#
# The old copy's own comment said it: "many oz gaps are under a cent and would round to a dishonest +0".
# It then fixed that for oz and fl oz ONLY, and left lb, dozen, gallon and each rendering +$0.00 for any
# gap under half a cent. A gap the page simultaneously calls "6% over" cannot also be zero.
#
# One rule for every unit: under a cent renders as cents with one decimal, and a TRUE zero renders as a
# true zero, because "these two stores are the same price" is a real and useful answer.
function Fmt-Diff([double]$d, [string]$unit) {
  $centUnits = @('oz','floz')
  $suffix = switch ($unit) { 'oz'{'/oz'} 'floz'{'/fl oz'} 'lb'{'/lb'} 'gallon'{'/gal'} 'dozen'{'/dozen'} 'each'{' each'} default{''} }
  if ($d -gt 0 -and $d -lt 0.01) {
    return ('+' + ('{0:N1}' -f ($d * 100)) + '&cent;' + $suffix)
  }
  if ($centUnits -contains $unit -and $d -lt 1) {
    $c = [math]::Round($d * 100, 1)
    if ($c -eq [math]::Floor($c)) { return ('+' + ('{0:N0}' -f $c) + '&cent;' + $suffix) }
    return ('+' + ('{0:N1}' -f $c) + '&cent;' + $suffix)
  }
  return ('+$' + ('{0:N2}' -f $d) + $suffix)
}
# THE BARE PRICE, for surfaces that print the unit THEMSELVES. The trend pages compose
# "<div class=tp-price>$1.00<span class=tp-unit>/lb</span></div>", so they cannot use Fmt-Price - its
# output already carries the unit - and they grew a third private copy instead.
#
# That copy rounded to FOUR decimals below a dollar and trimmed trailing zeros, so apples at 0.9967
# printed "$0.9967/lb" in the headline stat, the dek AND the search description, while the board printed
# "$1.00/lb" for the same number. Two surfaces disagreeing about one price is worse than either being
# slightly wrong.
#
# Two decimals, like money. The ONE exception is the sub-cent case fmt-lib already exists to protect -
# cotton swabs at $0.0043 - where two decimals would print $0.00 and lose the number entirely.
function Fmt-PriceBare([double]$v) {
  if ($v -gt 0 -and $v -lt 0.01) {
    $s = $v.ToString('0.0000', [System.Globalization.CultureInfo]::InvariantCulture).TrimEnd('0')
    return ('$' + $s)
  }
  return ('$' + (Format-TcMoney2 $v))
}
function UnitLabel([string]$unit) {
  switch ($unit) { 'oz'{'per ounce'} 'floz'{'per fl ounce'} 'lb'{'per pound'} 'gallon'{'per gallon'} 'dozen'{'per dozen'} 'each'{'each'} default{$unit} }
}

if ($SelfTest) {
  # FROZEN FIXTURES. Per the guard-fixture rule these are the FOUNDING BUGS plus their clean twins, written
  # by hand and never regenerated from the live board. If a future refactor reintroduces either bug, these
  # fire; if it changes a correct case, the twin fires.
  $cases = @(
    # --- must-fire 1: the 356 cents bug (Mint (fresh), Walmart, live 2026-07-31)
    @{ v=3.56;   u='oz';   want='$3.56/oz';       why='MUST-FIRE: 3.56/oz must roll over to dollars, not print 356 cents' },
    @{ v=1.00;   u='oz';   want='$1.00/oz';       why='MUST-FIRE: exactly 100 cents is the rollover boundary' },
    @{ v=2.40;   u='floz'; want='$2.40/fl oz';    why='MUST-FIRE: fl oz rolls over on the same rule' },
    # --- clean twins: ordinary cent prices must keep reading as cents
    @{ v=0.35;   u='oz';   want='35&cent;/oz';    why='CLEAN TWIN: an ordinary per-ounce price stays in cents' },
    @{ v=0.99;   u='oz';   want='99&cent;/oz';    why='CLEAN TWIN: one cent below the boundary stays in cents' },
    # --- must-fire 3: the half-cent gap. Beef jerky at $0.9962/oz is under a dollar but rounds to 100
    #     cents, and the first version of this rollover printed "100&cent;/oz" one cent below its own
    #     boundary. Found by asserting on the built page, not by reading the code.
    @{ v=0.9962; u='oz';   want='$1.00/oz';       why='MUST-FIRE: a value that ROUNDS to 100 cents must render as dollars' },
    @{ v=0.995;  u='floz'; want='$1.00/fl oz';    why='MUST-FIRE: same half-cent gap on fl oz' },
    @{ v=0.994;  u='oz';   want='99&cent;/oz';    why='CLEAN TWIN: just under the rounding boundary stays in cents' },
    @{ v=0.128;  u='floz'; want='13&cent;/fl oz'; why='CLEAN TWIN: fl oz below a dollar stays in cents' },
    # RULED 2026-09-19 (backlog I186, I202, master plan D5): an exact half cent rounds HALF UP on the exact
    # decimal, on every branch. This case froze banker's rounding (12&cent;) from 2026-07-31 while the dollar
    # branch beside it already rounded half up, so one price could read a cent apart on two pages.
    @{ v=0.125;  u='floz'; want='13&cent;/fl oz'; why='RULED: an exact half cent rounds half up on the cents branch too' },
    # --- must-fire 2: the "$0.00 each" record card (cotton-swabs, Aldi, live 2026-07-31)
    @{ v=0.0043; u='each'; want='0.4&cent; each'; why='MUST-FIRE: a real sub-cent price must not render as $0.00' },
    @{ v=0.0043; u='oz';   want='0.4&cent;/oz';   why='MUST-FIRE: sub-cent must not round to 0 cents either' },
    # --- clean twins: everything else is untouched
    @{ v=0.0100; u='each'; want='$0.01 each';     why='CLEAN TWIN: exactly one cent is NOT sub-cent' },
    @{ v=4.98;   u='lb';   want='$4.98/lb';       why='CLEAN TWIN: per-pound formatting is unchanged' },
    @{ v=3.19;   u='dozen';want='$3.19/dozen';    why='CLEAN TWIN: per-dozen formatting is unchanged' },
    @{ v=2.79;   u='each'; want='$2.79 each';     why='CLEAN TWIN: ordinary each formatting is unchanged' },
    @{ v=0;      u='lb';   want='$0.00/lb';       why='CLEAN TWIN: a genuine zero is not sub-cent and is not hidden' }
  )
  $bad = 0
  foreach ($c in $cases) {
    $got = Fmt-Price ([double]$c.v) ([string]$c.u)
    if ($got -ne $c.want) { Write-Output ("  X " + $c.why + "  got '" + $got + "' want '" + $c.want + "'"); $bad++ }
    # the plain-text twin must agree with the HTML one on every case, entity aside. This is what stops the
    # tooltip formatter from drifting back into its own copy of the rounding rules.
    $wantT = $c.want -replace '&cent;', ([char]0x00A2)
    $gotT = Fmt-PriceText ([double]$c.v) ([string]$c.u)
    if ($gotT -ne $wantT) { Write-Output ("  X plain-text twin disagrees: " + $c.why + "  got '" + $gotT + "' want '" + $wantT + "'"); $bad++ }
  }
  # ---- Fmt-Diff. Same rule: the founding bug plus its clean twins. ----------------------------------
  $dcases = @(
    # MUST-FIRE: the live store-guide cells. "Corn Tortillas $0.06 each  +$0.00 each  6% over" was on
    # /shop-smart-at-your-store/ on 2026-08-31; 6% of 6 cents is 0.36 of a cent, which is not zero.
    @{ d=0.0036; u='each';  want='+0.4&cent; each';   why='MUST-FIRE: a sub-cent per-each gap must not print +$0.00' },
    @{ d=0.0012; u='lb';    want='+0.1&cent;/lb';     why='MUST-FIRE: sub-cent per-pound gap must not print +$0.00' },
    @{ d=0.004;  u='dozen'; want='+0.4&cent;/dozen';  why='MUST-FIRE: sub-cent per-dozen gap must not print +$0.00' },
    @{ d=0.0025; u='gallon';want='+0.3&cent;/gal';    why='MUST-FIRE: sub-cent per-gallon gap must not print +$0.00' },
    # CLEAN TWINS: everything the old private copy already got right must stay exactly as it was.
    @{ d=0.013;  u='oz';    want='+1.3&cent;/oz';     why='CLEAN TWIN: the one-decimal oz gap is unchanged' },
    @{ d=0.019;  u='floz';  want='+1.9&cent;/fl oz';  why='CLEAN TWIN: the one-decimal fl oz gap is unchanged' },
    @{ d=0.02;   u='oz';    want='+2&cent;/oz';       why='CLEAN TWIN: a whole-cent oz gap drops the decimal' },
    @{ d=1.25;   u='oz';    want='+$1.25/oz';         why='CLEAN TWIN: an oz gap of a dollar or more is dollars' },
    @{ d=0.47;   u='lb';    want='+$0.47/lb';         why='CLEAN TWIN: an ordinary per-pound gap is dollars' },
    @{ d=0.06;   u='each';  want='+$0.06 each';       why='CLEAN TWIN: a six-cent each gap is dollars, not 6 cents' },
    # A TRUE ZERO IS NOT A ROUNDING ARTEFACT. Two stores at the same price is a real answer and must not
    # be dressed up as "+0.0 cents".
    @{ d=0;      u='each';  want='+$0.00 each';       why='CLEAN TWIN: a genuine zero gap still reads as zero' }
  )
  foreach ($c in $dcases) {
    $got = Fmt-Diff ([double]$c.d) ([string]$c.u)
    if ($got -ne $c.want) { Write-Output ("  X " + $c.why + "  got '" + $got + "' want '" + $c.want + "'"); $bad++ }
  }
  # ---- Fmt-PriceBare. Founding bug: the trend pages' four-decimal prices. -----------------------------
  $bcases = @(
    # MUST-FIRE: live on /apples-price-omaha/ 2026-08-31, in the stat, the dek and the meta description.
    @{ v=0.9967; want='$1.00';   why='MUST-FIRE: 0.9967 is $1.00, not $0.9967 - the board says $1.00/lb for it' },
    @{ v=0.797;  want='$0.80';   why='MUST-FIRE: a chart axis label is money, not four decimals' },
    @{ v=0.127;  want='$0.13';   why='MUST-FIRE: three decimals round to two like every other price' },
    # RULED 2026-09-19: half up, the same rule as Fmt-Price. Until then this case froze $0.12 (banker's,
    # through [math]::Round in double) while the deals page printed $0.13 for the same number.
    @{ v=0.125;  want='$0.13';   why='RULED: an exact half cent rounds half up on the trend pages too' },
    # CLEAN TWINS
    @{ v=0.0043; want='$0.0043'; why='CLEAN TWIN: a real sub-cent price keeps its digits rather than becoming $0.00' },
    @{ v=0.01;   want='$0.01';   why='CLEAN TWIN: exactly one cent is not sub-cent' },
    @{ v=4.98;   want='$4.98';   why='CLEAN TWIN: an ordinary price is unchanged' },
    @{ v=12.5;   want='$12.50';  why='CLEAN TWIN: a whole half-dollar keeps two decimals' },
    @{ v=0;      want='$0.00';   why='CLEAN TWIN: a genuine zero is not sub-cent and is not hidden' }
  )
  foreach ($c in $bcases) {
    $got = Fmt-PriceBare ([double]$c.v)
    if ($got -ne $c.want) { Write-Output ("  X " + $c.why + "  got '" + $got + "' want '" + $c.want + "'"); $bad++ }
  }
  # ---- THE ONE ROUNDING RULE (Brad, 2026-09-19, backlog I186 + I202). ---------------------------------
  # MUST FIRE: the I202 table. Measured 2026-09-18, these five values printed on three rules across the
  # three paths: 0.125 read $0.13/lb, 12 cents/oz and $0.12 bare; 1.145 read $1.15/lb and $1.14 bare. Every
  # path must now print each one identically, half up. A value at or above a dollar takes the oz rollover,
  # so its oz spelling is dollars.
  $rcases = @(
    @{ v=0.125; lb='$0.13/lb'; oz='13&cent;/oz'; bare='$0.13' },
    @{ v=1.005; lb='$1.01/lb'; oz='$1.01/oz';    bare='$1.01' },
    @{ v=0.145; lb='$0.15/lb'; oz='15&cent;/oz'; bare='$0.15' },
    @{ v=1.145; lb='$1.15/lb'; oz='$1.15/oz';    bare='$1.15' },
    @{ v=4.435; lb='$4.44/lb'; oz='$4.44/oz';    bare='$4.44' }
  )
  $rn = 0
  foreach ($c in $rcases) {
    $got = @((Fmt-Price ([double]$c.v) 'lb'), (Fmt-Price ([double]$c.v) 'oz'), (Fmt-PriceBare ([double]$c.v)))
    $want = @($c.lb, $c.oz, $c.bare)
    for ($k = 0; $k -lt 3; $k++) {
      $rn++
      if (-not [string]::Equals($got[$k], $want[$k], [StringComparison]::Ordinal)) {
        Write-Output ("  X MUST FIRE: the I202 midpoint " + $c.v + " must print half up on every path  got '" + $got[$k] + "' want '" + $want[$k] + "'"); $bad++
      }
    }
  }
  # MUST FIRE: the binary-product bug. The double nearest 1.005 is 1.00499999999999989..., and
  # [math]::Round(1.005, 2) multiplied it in binary and printed $1.00 on the trend pages while the board
  # JSON said 1.005. The exact decimal is a midpoint, so it is $1.01.
  $rn++
  $g = Fmt-PriceBare ([double]1.005)
  if ($g -ne '$1.01') { Write-Output ("  X MUST FIRE: 1.005 is the decimal the board carries, so it prints `$1.01, not the binary product's `$1.00  got '" + $g + "'"); $bad++ }
  # CLEAN TWIN: a value that is NOT at a midpoint prints exactly what it always printed, on every path.
  foreach ($t in @(@{ v=1.144; lb='$1.14/lb'; oz='$1.14/oz'; bare='$1.14' }, @{ v=0.356; lb='$0.36/lb'; oz='36&cent;/oz'; bare='$0.36' }, @{ v=1234.5649; lb='$1,234.56/lb'; oz='$1,234.56/oz'; bare='$1,234.56' })) {
    $got = @((Fmt-Price ([double]$t.v) 'lb'), (Fmt-Price ([double]$t.v) 'oz'), (Fmt-PriceBare ([double]$t.v)))
    $want = @($t.lb, $t.oz, $t.bare)
    for ($k = 0; $k -lt 3; $k++) {
      $rn++
      if (-not [string]::Equals($got[$k], $want[$k], [StringComparison]::Ordinal)) {
        Write-Output ("  X CLEAN TWIN: a non-midpoint " + $t.v + " must print as before  got '" + $got[$k] + "' want '" + $want[$k] + "'"); $bad++
      }
    }
  }
  # MUST FIRE, THE SWEEP: every i.5 cents from 1.5 cents to 9,999.5 cents, as the double the board JSON
  # parses to (the decimal i.5/100, converted once), on the three paths. Each must round half up to i+1
  # cents. i = 0 (half a cent) is left out: it takes the sub-cent branch, which prints tenths of a cent and
  # does not round to a cent at all. The old paths disagreed on some of these; the count is in backlog I186.
  $sweepBad = 0; $sweepN = 0; $firstMiss = $null
  for ($i = 1; $i -le 9999; $i++) {
    $v = [double](([decimal]$i + 0.5) / 100)
    $want = '{0:N2}' -f (([decimal]$i + 1) / 100)
    $wantOz = if (($i + 1) -ge 100) { '$' + $want + '/oz' } else { '' + ($i + 1) + '&cent;/oz' }
    $pairs = @(@((Fmt-Price $v 'lb'), ('$' + $want + '/lb')), @((Fmt-Price $v 'oz'), $wantOz), @((Fmt-PriceBare $v), ('$' + $want)))
    foreach ($p in $pairs) {
      $sweepN++
      if (-not [string]::Equals($p[0], $p[1], [StringComparison]::Ordinal)) {
        $sweepBad++
        if ($null -eq $firstMiss) { $firstMiss = ('' + $v + " got '" + $p[0] + "' want '" + $p[1] + "'") }
      }
    }
  }
  if ($sweepN -ne 29997) { Write-Output ("  X the sweep ran " + $sweepN + " comparisons, not 29997"); $bad++ }
  if ($sweepBad -ne 0) { Write-Output ("  X MUST FIRE: the i.5-cent sweep rounds half up on every path  " + $sweepBad + " of " + $sweepN + " disagree; first " + $firstMiss); $bad++ }
  $rn++
  Write-Output ("  sweep: " + $sweepBad + " of " + $sweepN + " i.5-cent comparisons disagree with half up (3 paths x 9,999 values)")
  $total = ($cases.Count * 2) + $dcases.Count + $bcases.Count + $rn
  if ($bad -eq 0) { Write-Output ("fmt-lib SELF-TEST PASS (" + $total + " frozen cases)"); exit 0 }
  Write-Output ("fmt-lib SELF-TEST FAIL (" + $bad + " of " + $total + " cases)"); exit 2
}
