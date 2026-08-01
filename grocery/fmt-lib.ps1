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
    'oz'    { $c = [math]::Round($v*100); if ($c -ge 100) { return ('$' + ('{0:N2}' -f $v) + '/oz') }; return ('' + $c + '&cent;/oz') }
    'floz'  { $c = [math]::Round($v*100); if ($c -ge 100) { return ('$' + ('{0:N2}' -f $v) + '/fl oz') }; return ('' + $c + '&cent;/fl oz') }
    'lb'    { return ('$' + ('{0:N2}' -f $v) + '/lb') }
    'gallon'{ return ('$' + ('{0:N2}' -f $v) + '/gal') }
    'dozen' { return ('$' + ('{0:N2}' -f $v) + '/dozen') }
    'each'  { return ('$' + ('{0:N2}' -f $v) + ' each') }
    default { return ('$' + ('{0:N2}' -f $v)) }
  }
}
# PLAIN-TEXT twin, for anywhere the string lands inside an attribute (title="...") or a share payload.
# It has to exist because the HTML version emits &cent;, and every one of those call sites runs its text
# through HtmlEnc, which would turn the entity into a literal "&cent;" on screen. One implementation, two
# renderings: never a second copy of the rounding rules.
function Fmt-PriceText([double]$v, [string]$unit) {
  return ((Fmt-Price $v $unit) -replace '&cent;', ([char]0x00A2))
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
    # Documented, deliberately UNCHANGED: [math]::Round uses banker's rounding, so an exact half cent lands
    # on the even digit (12.5 -> 12, not 13). This fixture freezes today's behavior rather than quietly
    # changing a cent on every .5 cell mid-freeze. Whether money should round half-up here is Brad's call;
    # it is logged as an open item, not smuggled in with a redesign.
    @{ v=0.125;  u='floz'; want='12&cent;/fl oz'; why='FROZEN BEHAVIOR: exact half cent uses banker''s rounding' },
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
  if ($bad -eq 0) { Write-Output ("fmt-lib SELF-TEST PASS (" + ($cases.Count * 2) + " frozen cases)"); exit 0 }
  Write-Output ("fmt-lib SELF-TEST FAIL (" + $bad + " of " + $cases.Count + " cases)"); exit 2
}
